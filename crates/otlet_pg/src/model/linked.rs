fn run_linked(
    job: &Job,
    prompt: &PromptParts,
    prompt_prefix_hash: &str,
    options: &crate::runtime::RuntimeOptions,
) -> Result<LinkedRun, ModelError> {
    use std::ffi::CString;

    let attempt_start = Instant::now();
    if job.artifact_path.starts_with("hf:") {
        return Err(ModelError::new(
            "linked llama.cpp runtime requires a local GGUF artifact path".to_owned(),
        ));
    }
    LINKED_BACKEND.get_or_init(|| unsafe {
        llama_cpp_sys_4::llama_backend_init();
    });

    let model_fingerprint_hash = hash_text(&model_fingerprint(job));
    let cache = LINKED_CACHE.get_or_init(|| Mutex::new(None));
    let mut cache = cache
        .lock()
        .map_err(|_| ModelError::new("linked llama.cpp cache lock poisoned".to_owned()))?;
    let cache_hit = cache.as_ref().is_some_and(|cached| {
        cached.artifact_path == job.artifact_path
            && cached.model_fingerprint_hash == model_fingerprint_hash
    });

    if !cache_hit {
        let model_path = CString::new(job.artifact_path.as_bytes())
            .map_err(|_| ModelError::new("linked llama.cpp model path is invalid".to_owned()))?;
        let mut model_params = unsafe { llama_cpp_sys_4::llama_model_default_params() };
        model_params.n_gpu_layers = 0;

        let load_start = Instant::now();
        let model_ptr = unsafe {
            llama_cpp_sys_4::llama_model_load_from_file(model_path.as_ptr(), model_params)
        };
        let load_ms = elapsed_ms(load_start);
        if model_ptr.is_null() {
            return Err(ModelError::new(
                "linked llama.cpp model load failed".to_owned(),
            ));
        }
        let model = LinkedModel { ptr: model_ptr };

        let mut ctx_params = unsafe { llama_cpp_sys_4::llama_context_default_params() };
        ctx_params.n_ctx = LINKED_CONTEXT_WINDOW_TOKENS;
        ctx_params.n_batch = LINKED_PROMPT_BATCH_TOKENS as u32;
        let ctx_start = Instant::now();
        let context_ptr = unsafe { llama_cpp_sys_4::llama_init_from_model(model.ptr, ctx_params) };
        let ctx_ms = elapsed_ms(ctx_start);
        if context_ptr.is_null() {
            return Err(ModelError::new(
                "linked llama.cpp context start failed".to_owned(),
            ));
        }
        let context = LinkedContext { ptr: context_ptr };
        let model_memory_bytes =
            u64_to_i64_saturating(unsafe { llama_cpp_sys_4::llama_model_size(model.ptr) });
        let model_parameters =
            u64_to_i64_saturating(unsafe { llama_cpp_sys_4::llama_model_n_params(model.ptr) });
        let context_window_tokens =
            u64_to_i64_saturating(unsafe { llama_cpp_sys_4::llama_n_ctx(context.ptr) } as u64);

        let vocab = unsafe { llama_cpp_sys_4::llama_model_get_vocab(model.ptr) };
        if vocab.is_null() {
            return Err(ModelError::new(
                "linked llama.cpp model has no vocab".to_owned(),
            ));
        }

        *cache = Some(LinkedCache {
            artifact_path: job.artifact_path.clone(),
            model_fingerprint_hash,
            _model: model,
            context,
            vocab,
            load_ms,
            ctx_ms,
            model_memory_bytes,
            model_parameters,
            context_window_tokens,
            model_device_policy: LINKED_MODEL_DEVICE_POLICY.to_owned(),
            memory_accounting_policy: LINKED_MEMORY_ACCOUNTING_POLICY.to_owned(),
            prefix_state: None,
        });
    }

    let cache = cache
        .as_mut()
        .ok_or_else(|| ModelError::new("linked llama.cpp cache did not initialize".to_owned()))?;
    let tokens = tokenize_linked(cache.vocab, &prompt.prompt)?;
    if tokens.is_empty() {
        return Err(ModelError::new(
            "linked llama.cpp prompt produced no tokens".to_owned(),
        ));
    }
    let prefix_tokens = tokenize_linked(cache.vocab, &prompt.prefix)?;
    let prefix_boundary_supported =
        !prefix_tokens.is_empty() && tokens.starts_with(prefix_tokens.as_slice());
    let prefix_token_count = if prefix_boundary_supported {
        prefix_tokens.len()
    } else {
        0
    };
    let mut prompt_prefix_reused_tokens = 0_i64;
    let mut prompt_prefix_reuse_status = if options.prefix_kv_reuse {
        "miss".to_owned()
    } else {
        "disabled".to_owned()
    };
    let mut prompt_prefix_reuse_reason = if options.prefix_kv_reuse {
        "no_retained_prefix_full_decode".to_owned()
    } else {
        "runtime_option_disabled".to_owned()
    };
    let mut decode_start = 0_usize;

    validate_linked_token_budget(tokens.len(), options.max_tokens, cache.context_window_tokens)?;

    if !options.prefix_kv_reuse {
        cache.prefix_state = None;
        linked_clear_context(cache.context.ptr);
    } else if !prefix_boundary_supported {
        cache.prefix_state = None;
        linked_clear_context(cache.context.ptr);
        prompt_prefix_reuse_status = "fallback".to_owned();
        prompt_prefix_reuse_reason = "prefix_token_boundary_mismatch_full_decode".to_owned();
    } else if let Some(state) = cache.prefix_state.clone() {
        if state.hash == prompt_prefix_hash && state.token_count == prefix_token_count {
            if linked_restore_prefix_state(cache.context.ptr, &state)? {
                decode_start = prefix_token_count;
                prompt_prefix_reused_tokens = prefix_token_count as i64;
                prompt_prefix_reuse_status = "hit".to_owned();
                prompt_prefix_reuse_reason = "retained_prefix_reused".to_owned();
            } else {
                cache.prefix_state = None;
                linked_clear_context(cache.context.ptr);
                prompt_prefix_reuse_status = "fallback".to_owned();
                prompt_prefix_reuse_reason = "prefix_state_restore_failed_full_decode".to_owned();
            }
        } else {
            cache.prefix_state = None;
            linked_clear_context(cache.context.ptr);
            prompt_prefix_reuse_status = "fallback".to_owned();
            prompt_prefix_reuse_reason = "prefix_hash_mismatch_full_decode".to_owned();
        }
    } else {
        linked_clear_context(cache.context.ptr);
    }

    let resident_memory = process_memory_sample();
    enforce_worker_rss_budget(&resident_memory, options.max_worker_rss_bytes)?;

    let mut batch = LinkedBatch::new(LINKED_PROMPT_BATCH_TOKENS)?;
    if options.prefix_kv_reuse && prefix_boundary_supported && decode_start == 0 {
        linked_decode_prompt_tokens(
            job,
            cache.context.ptr,
            &mut batch,
            &tokens[..prefix_token_count],
            0,
        )?;
        if let Some(state) =
            linked_capture_prefix_state(cache.context.ptr, prompt_prefix_hash, prefix_token_count)?
        {
            cache.prefix_state = Some(state);
        } else {
            cache.prefix_state = None;
            prompt_prefix_reuse_status = "miss_retention_failed".to_owned();
            prompt_prefix_reuse_reason = "prefix_state_capture_failed_full_decode".to_owned();
        }
        linked_decode_prompt_tokens(
            job,
            cache.context.ptr,
            &mut batch,
            &tokens[prefix_token_count..],
            prefix_token_count,
        )?;
    } else {
        linked_decode_prompt_tokens(
            job,
            cache.context.ptr,
            &mut batch,
            &tokens[decode_start..],
            decode_start,
        )?;
    }

    let sampler_ptr = unsafe { llama_cpp_sys_4::llama_sampler_init_greedy() };
    if sampler_ptr.is_null() {
        return Err(ModelError::new(
            "linked llama.cpp sampler start failed".to_owned(),
        ));
    }
    let sampler = LinkedSampler { ptr: sampler_ptr };
    let mut output = String::new();
    let mut position = tokens.len();
    let mut generated_tokens = 0_i64;
    let mut probability_trace = ProbabilityTrace::default();
    let mut detailed_trace = DetailedGenerationTrace::new(options);
    let mut json_logit_mask = JsonLogitMask::new(options.json_logit_mask);
    let mut stop_reason = "max_tokens".to_owned();
    let generate_start = Instant::now();

    for _ in 0..options.max_tokens {
        if linked_attempt_timed_out(attempt_start, job.max_attempt_ms) {
            return Err(ModelError::attempt_timeout());
        }
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
        }
        let token = if options.json_logit_mask {
            json_logit_mask
                .sample(cache.context.ptr, cache.vocab)
                .unwrap_or_else(|| unsafe {
                    llama_cpp_sys_4::llama_sampler_sample(sampler.ptr, cache.context.ptr, -1)
                })
        } else {
            unsafe { llama_cpp_sys_4::llama_sampler_sample(sampler.ptr, cache.context.ptr, -1) }
        };
        let sample = unsafe {
            probability_sample(
                cache.context.ptr,
                cache.vocab,
                token,
                options.generation_trace_top_k,
            )
        };
        probability_trace.observe(sample.as_ref());
        if unsafe { llama_cpp_sys_4::llama_vocab_is_eog(cache.vocab, token) } {
            stop_reason = "eog_token".to_owned();
            break;
        }

        unsafe {
            llama_cpp_sys_4::llama_sampler_accept(sampler.ptr, token);
        }
        generated_tokens += 1;
        let token_text = linked_token_to_piece(cache.vocab, token);
        json_logit_mask.observe_chosen(&token_text);
        output.push_str(&token_text);
        detailed_trace.observe(token, token_text, sample);
        if let Some(end) = linked_output_complete_end(&output) {
            output.truncate(end);
            stop_reason = "json_complete".to_owned();
            break;
        }

        batch.reset();
        batch.add(
            token,
            i32::try_from(position).map_err(|_| {
                ModelError::new("linked llama.cpp generation position overflowed i32".to_owned())
            })?,
            true,
        )?;
        let decode_status =
            unsafe { llama_cpp_sys_4::llama_decode(cache.context.ptr, batch.value) };
        if decode_status != 0 {
            return Err(ModelError::new(format!(
                "linked llama.cpp generation decode failed: {decode_status}"
            )));
        }
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
        }
        if linked_attempt_timed_out(attempt_start, job.max_attempt_ms) {
            return Err(ModelError::attempt_timeout());
        }
        position += 1;
    }
    let generate_ms = elapsed_ms(generate_start);
    let worker_memory = process_memory_sample();
    enforce_worker_rss_budget(&worker_memory, options.max_worker_rss_bytes)?;

    Ok(LinkedRun {
        raw_output: output.trim().to_owned(),
        metrics: ModelMetrics {
            artifact_path: cache.artifact_path.clone(),
            load_ms: cache.load_ms,
            ctx_ms: cache.ctx_ms,
            model_memory_bytes: cache.model_memory_bytes,
            model_parameters: cache.model_parameters,
            context_window_tokens: cache.context_window_tokens,
            model_device_policy: cache.model_device_policy.clone(),
            memory_accounting_policy: cache.memory_accounting_policy.clone(),
            worker_process_rss_bytes: worker_memory.rss_bytes,
            worker_process_virtual_bytes: worker_memory.virtual_bytes,
            worker_memory_sample_policy: worker_memory.policy,
            worker_memory_budget_bytes: u64_to_i64_saturating(options.max_worker_rss_bytes),
            worker_memory_budget_policy: worker_memory_budget_policy(options.max_worker_rss_bytes)
                .to_owned(),
            prompt_tokens: tokens.len() as i64,
            generated_tokens,
            generate_ms,
            cache_hit,
            inference_cache_hit: false,
            inference_cache_entries: 0,
            inference_cache_bytes: 0,
            inference_cache_max_entries: inference_cache_max_entries(),
            inference_cache_max_bytes: inference_cache_max_bytes(),
            inference_cache_evictions: 0,
            inference_cache_eviction_reason: "none".to_owned(),
            inference_cache_invalidation_reason: "miss".to_owned(),
            prompt_prefix_tokens: prefix_token_count as i64,
            prompt_suffix_tokens: tokens.len().saturating_sub(prefix_token_count) as i64,
            prompt_prefix_reused_tokens,
            prompt_prefix_reuse_status,
            prompt_prefix_reuse_reason,
            json_logit_mask_enabled: options.json_logit_mask,
            json_logit_mask_sampled_tokens: json_logit_mask.sampled_tokens,
            json_logit_mask_candidates_checked: json_logit_mask.candidates_checked,
            json_logit_mask_candidates_rejected: json_logit_mask.candidates_rejected,
            json_logit_mask_fallbacks: json_logit_mask.fallbacks,
            json_logit_mask_uncertain_pieces: json_logit_mask.uncertain_pieces,
            json_logit_mask_overhead_ms: json_logit_mask.overhead_ms,
            probability_summary: probability_trace.summary(),
            detailed_trace: detailed_trace.summary(&stop_reason),
            stop_reason,
        },
    })
}

fn linked_attempt_timed_out(start: Instant, max_attempt_ms: i64) -> bool {
    max_attempt_ms > 0 && start.elapsed().as_millis() >= max_attempt_ms as u128
}

fn linked_decode_prompt_tokens(
    job: &Job,
    context: *mut llama_cpp_sys_4::llama_context,
    batch: &mut LinkedBatch,
    tokens: &[llama_cpp_sys_4::llama_token],
    start_position: usize,
) -> Result<(), ModelError> {
    let mut decoded_tokens = 0;
    for chunk in tokens.chunks(LINKED_PROMPT_BATCH_TOKENS) {
        batch.reset();
        for (chunk_index, token) in chunk.iter().enumerate() {
            let position = start_position + decoded_tokens + chunk_index;
            batch.add(
                *token,
                i32::try_from(position).map_err(|_| {
                    ModelError::new("linked llama.cpp prompt position overflowed i32".to_owned())
                })?,
                decoded_tokens + chunk_index + 1 == tokens.len(),
            )?;
        }
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
        }
        let decode_status = unsafe { llama_cpp_sys_4::llama_decode(context, batch.value) };
        if decode_status != 0 {
            return Err(ModelError::new(format!(
                "linked llama.cpp prompt decode failed: {decode_status}"
            )));
        }
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
        }
        decoded_tokens += chunk.len();
    }

    Ok(())
}

#[derive(Clone)]
struct JsonLogitMask {
    enabled: bool,
    state: JsonPrefixState,
    sampled_tokens: i64,
    candidates_checked: i64,
    candidates_rejected: i64,
    fallbacks: i64,
    uncertain_pieces: i64,
    overhead_ms: i64,
}

impl JsonLogitMask {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            state: JsonPrefixState::default(),
            sampled_tokens: 0,
            candidates_checked: 0,
            candidates_rejected: 0,
            fallbacks: 0,
            uncertain_pieces: 0,
            overhead_ms: 0,
        }
    }

    fn sample(
        &mut self,
        context: *mut llama_cpp_sys_4::llama_context,
        vocab: *const llama_cpp_sys_4::llama_vocab,
    ) -> Option<llama_cpp_sys_4::llama_token> {
        if !self.enabled {
            return None;
        }

        let start = Instant::now();
        self.sampled_tokens += 1;
        let token = unsafe { self.sample_inner(context, vocab) };
        self.overhead_ms = self.overhead_ms.saturating_add(elapsed_ms(start));
        if token.is_none() {
            self.fallbacks += 1;
        }
        token
    }

    unsafe fn sample_inner(
        &mut self,
        context: *mut llama_cpp_sys_4::llama_context,
        vocab: *const llama_cpp_sys_4::llama_vocab,
    ) -> Option<llama_cpp_sys_4::llama_token> {
        unsafe {
            if context.is_null() || vocab.is_null() {
                return None;
            }
            let logits = llama_cpp_sys_4::llama_get_logits_ith(context, -1);
            let vocab_tokens = llama_cpp_sys_4::llama_vocab_n_tokens(vocab);
            if logits.is_null() || vocab_tokens <= 0 {
                return None;
            }

            let mut best_token = None;
            let mut best_logit = f32::NEG_INFINITY;
            for index in 0..vocab_tokens {
                let logit = *logits.add(index as usize);
                if !logit.is_finite() || logit <= best_logit {
                    continue;
                }

                let token = index as llama_cpp_sys_4::llama_token;
                self.candidates_checked += 1;
                if self.allows_token(vocab, token) {
                    best_token = Some(token);
                    best_logit = logit;
                } else {
                    self.candidates_rejected += 1;
                }
            }
            best_token
        }
    }

    fn allows_token(
        &mut self,
        vocab: *const llama_cpp_sys_4::llama_vocab,
        token: llama_cpp_sys_4::llama_token,
    ) -> bool {
        if unsafe { llama_cpp_sys_4::llama_vocab_is_eog(vocab, token) } {
            return self.state.is_complete();
        }

        let piece = linked_token_to_piece(vocab, token);
        if json_piece_uncertain(&piece) {
            self.uncertain_pieces += 1;
            return true;
        }

        let mut state = self.state.clone();
        state.push_str(&piece).is_ok()
    }

    fn observe_chosen(&mut self, piece: &str) {
        if !self.enabled {
            return;
        }
        if json_piece_uncertain(piece) {
            self.uncertain_pieces += 1;
            return;
        }
        if self.state.push_str(piece).is_err() {
            self.enabled = false;
            self.fallbacks += 1;
        }
    }
}

fn json_piece_uncertain(piece: &str) -> bool {
    piece.is_empty() || piece.contains('\u{fffd}')
}

#[derive(Clone)]
struct JsonPrefixState {
    mode: JsonMode,
    stack: Vec<JsonFrame>,
}

impl Default for JsonPrefixState {
    fn default() -> Self {
        Self {
            mode: JsonMode::Root,
            stack: Vec::new(),
        }
    }
}

impl JsonPrefixState {
    fn is_complete(&self) -> bool {
        matches!(self.mode, JsonMode::Done)
    }

    fn push_str(&mut self, text: &str) -> Result<(), ()> {
        for ch in text.chars() {
            self.push_char(ch)?;
        }
        Ok(())
    }

    fn push_char(&mut self, ch: char) -> Result<(), ()> {
        match &mut self.mode {
            JsonMode::String {
                kind,
                escape,
                unicode_remaining,
            } => {
                if *unicode_remaining > 0 {
                    if ch.is_ascii_hexdigit() {
                        *unicode_remaining -= 1;
                        return Ok(());
                    }
                    return Err(());
                }
                if *escape {
                    *escape = false;
                    if ch == 'u' {
                        *unicode_remaining = 4;
                    } else if !matches!(ch, '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't') {
                        return Err(());
                    }
                    return Ok(());
                }
                if ch == '\\' {
                    *escape = true;
                    return Ok(());
                }
                if ch == '"' {
                    let kind = *kind;
                    if matches!(kind, JsonStringKind::Key) {
                        self.mode = JsonMode::Normal;
                        self.set_object_expect(JsonObjectExpect::Colon)?;
                    } else {
                        self.finish_value()?;
                    }
                    return Ok(());
                }
                if ch.is_control() {
                    return Err(());
                }
                Ok(())
            }
            JsonMode::Number => {
                if ch.is_ascii_digit() || matches!(ch, '.' | 'e' | 'E' | '+' | '-') {
                    Ok(())
                } else {
                    self.finish_value()?;
                    self.push_char(ch)
                }
            }
            JsonMode::Literal { target, index } => {
                let Some(expected) = target.as_bytes().get(*index).copied() else {
                    self.finish_value()?;
                    return self.push_char(ch);
                };
                if ch as u8 != expected {
                    return Err(());
                }
                *index += 1;
                if *index == target.len() {
                    self.finish_value()?;
                }
                Ok(())
            }
            JsonMode::Root | JsonMode::Normal | JsonMode::Done => self.push_normal(ch),
        }
    }

    fn push_normal(&mut self, ch: char) -> Result<(), ()> {
        if ch.is_whitespace() {
            return Ok(());
        }
        if matches!(self.mode, JsonMode::Done) {
            return Err(());
        }

        match self.current_expect()? {
            JsonExpect::Root => {
                if ch == '{' {
                    self.stack.push(JsonFrame::Object(JsonObjectExpect::KeyOrEnd));
                    self.mode = JsonMode::Normal;
                    Ok(())
                } else {
                    Err(())
                }
            }
            JsonExpect::ObjectKeyOrEnd => match ch {
                '}' => {
                    self.stack.pop();
                    self.finish_value()
                }
                '"' => {
                    self.mode = JsonMode::String {
                        kind: JsonStringKind::Key,
                        escape: false,
                        unicode_remaining: 0,
                    };
                    Ok(())
                }
                _ => Err(()),
            },
            JsonExpect::ObjectColon => {
                if ch == ':' {
                    self.set_object_expect(JsonObjectExpect::Value)
                } else {
                    Err(())
                }
            }
            JsonExpect::ObjectValue | JsonExpect::ArrayValueOrEnd => {
                if matches!(self.current_expect()?, JsonExpect::ArrayValueOrEnd) && ch == ']' {
                    self.stack.pop();
                    return self.finish_value();
                }
                self.start_value(ch)
            }
            JsonExpect::ObjectCommaOrEnd => match ch {
                ',' => self.set_object_expect(JsonObjectExpect::KeyOrEnd),
                '}' => {
                    self.stack.pop();
                    self.finish_value()
                }
                _ => Err(()),
            },
            JsonExpect::ArrayCommaOrEnd => match ch {
                ',' => self.set_array_expect(JsonArrayExpect::ValueOrEnd),
                ']' => {
                    self.stack.pop();
                    self.finish_value()
                }
                _ => Err(()),
            },
        }
    }

    fn start_value(&mut self, ch: char) -> Result<(), ()> {
        match ch {
            '{' => {
                self.stack.push(JsonFrame::Object(JsonObjectExpect::KeyOrEnd));
                Ok(())
            }
            '[' => {
                self.stack.push(JsonFrame::Array(JsonArrayExpect::ValueOrEnd));
                Ok(())
            }
            '"' => {
                self.mode = JsonMode::String {
                    kind: JsonStringKind::Value,
                    escape: false,
                    unicode_remaining: 0,
                };
                Ok(())
            }
            '-' | '0'..='9' => {
                self.mode = JsonMode::Number;
                Ok(())
            }
            't' => {
                self.mode = JsonMode::Literal {
                    target: "true",
                    index: 1,
                };
                Ok(())
            }
            'f' => {
                self.mode = JsonMode::Literal {
                    target: "false",
                    index: 1,
                };
                Ok(())
            }
            'n' => {
                self.mode = JsonMode::Literal {
                    target: "null",
                    index: 1,
                };
                Ok(())
            }
            _ => Err(()),
        }
    }

    fn finish_value(&mut self) -> Result<(), ()> {
        self.mode = JsonMode::Normal;
        match self.stack.last_mut() {
            Some(JsonFrame::Object(expect)) => {
                *expect = JsonObjectExpect::CommaOrEnd;
                Ok(())
            }
            Some(JsonFrame::Array(expect)) => {
                *expect = JsonArrayExpect::CommaOrEnd;
                Ok(())
            }
            None => {
                self.mode = JsonMode::Done;
                Ok(())
            }
        }
    }

    fn current_expect(&self) -> Result<JsonExpect, ()> {
        match self.stack.last() {
            None => {
                if matches!(self.mode, JsonMode::Root) {
                    Ok(JsonExpect::Root)
                } else {
                    Err(())
                }
            }
            Some(JsonFrame::Object(JsonObjectExpect::KeyOrEnd)) => Ok(JsonExpect::ObjectKeyOrEnd),
            Some(JsonFrame::Object(JsonObjectExpect::Colon)) => Ok(JsonExpect::ObjectColon),
            Some(JsonFrame::Object(JsonObjectExpect::Value)) => Ok(JsonExpect::ObjectValue),
            Some(JsonFrame::Object(JsonObjectExpect::CommaOrEnd)) => {
                Ok(JsonExpect::ObjectCommaOrEnd)
            }
            Some(JsonFrame::Array(JsonArrayExpect::ValueOrEnd)) => {
                Ok(JsonExpect::ArrayValueOrEnd)
            }
            Some(JsonFrame::Array(JsonArrayExpect::CommaOrEnd)) => Ok(JsonExpect::ArrayCommaOrEnd),
        }
    }

    fn set_object_expect(&mut self, next: JsonObjectExpect) -> Result<(), ()> {
        let Some(JsonFrame::Object(expect)) = self.stack.last_mut() else {
            return Err(());
        };
        *expect = next;
        Ok(())
    }

    fn set_array_expect(&mut self, next: JsonArrayExpect) -> Result<(), ()> {
        let Some(JsonFrame::Array(expect)) = self.stack.last_mut() else {
            return Err(());
        };
        *expect = next;
        Ok(())
    }
}

#[derive(Clone)]
enum JsonMode {
    Root,
    Normal,
    String {
        kind: JsonStringKind,
        escape: bool,
        unicode_remaining: u8,
    },
    Number,
    Literal {
        target: &'static str,
        index: usize,
    },
    Done,
}

#[derive(Clone)]
enum JsonFrame {
    Object(JsonObjectExpect),
    Array(JsonArrayExpect),
}

#[derive(Clone, Copy)]
enum JsonStringKind {
    Key,
    Value,
}

#[derive(Clone, Copy)]
enum JsonObjectExpect {
    KeyOrEnd,
    Colon,
    Value,
    CommaOrEnd,
}

#[derive(Clone, Copy)]
enum JsonArrayExpect {
    ValueOrEnd,
    CommaOrEnd,
}

enum JsonExpect {
    Root,
    ObjectKeyOrEnd,
    ObjectColon,
    ObjectValue,
    ObjectCommaOrEnd,
    ArrayValueOrEnd,
    ArrayCommaOrEnd,
}

fn validate_linked_token_budget(
    prompt_tokens: usize,
    max_tokens: u64,
    context_window_tokens: i64,
) -> Result<(), ModelError> {
    let Ok(context_window_tokens) = usize::try_from(context_window_tokens) else {
        return Err(ModelError::new(
            "linked llama.cpp context window is invalid".to_owned(),
        ));
    };
    if prompt_tokens >= context_window_tokens {
        return Err(ModelError::new(format!(
            "linked llama.cpp prompt has {prompt_tokens} tokens, exceeds context window {context_window_tokens}"
        )));
    }

    let max_tokens = usize::try_from(max_tokens).unwrap_or(usize::MAX);
    if prompt_tokens.saturating_add(max_tokens) > context_window_tokens {
        return Err(ModelError::new(format!(
            "linked llama.cpp prompt has {prompt_tokens} tokens plus max_tokens {max_tokens}, exceeds context window {context_window_tokens}"
        )));
    }

    Ok(())
}

struct LinkedRun {
    raw_output: String,
    metrics: ModelMetrics,
}

struct LinkedCache {
    artifact_path: String,
    model_fingerprint_hash: String,
    context: LinkedContext,
    _model: LinkedModel,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    load_ms: i64,
    ctx_ms: i64,
    model_memory_bytes: i64,
    model_parameters: i64,
    context_window_tokens: i64,
    model_device_policy: String,
    memory_accounting_policy: String,
    prefix_state: Option<LinkedPrefixState>,
}

unsafe impl Send for LinkedCache {}

#[derive(Clone)]
struct LinkedPrefixState {
    hash: String,
    token_count: usize,
    data: Vec<u8>,
}

struct ProcessMemorySample {
    rss_bytes: i64,
    virtual_bytes: i64,
    policy: String,
}

struct LinkedModel {
    ptr: *mut llama_cpp_sys_4::llama_model,
}

impl Drop for LinkedModel {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_model_free(self.ptr);
        }
    }
}

unsafe impl Send for LinkedModel {}

struct LinkedContext {
    ptr: *mut llama_cpp_sys_4::llama_context,
}

unsafe impl Send for LinkedContext {}

impl Drop for LinkedContext {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_free(self.ptr);
        }
    }
}

struct LinkedBatch {
    value: llama_cpp_sys_4::llama_batch,
    capacity: usize,
}

impl LinkedBatch {
    fn new(capacity: usize) -> Result<Self, ModelError> {
        let capacity_i32 = i32::try_from(capacity).map_err(|_| {
            ModelError::new("linked llama.cpp batch capacity overflowed i32".to_owned())
        })?;
        let value = unsafe { llama_cpp_sys_4::llama_batch_init(capacity_i32, 0, 1) };
        let batch = Self { value, capacity };
        if batch.value.token.is_null()
            || batch.value.pos.is_null()
            || batch.value.n_seq_id.is_null()
            || batch.value.seq_id.is_null()
            || batch.value.logits.is_null()
        {
            return Err(ModelError::new(
                "linked llama.cpp batch allocation failed".to_owned(),
            ));
        }

        Ok(batch)
    }

    fn reset(&mut self) {
        self.value.n_tokens = 0;
    }

    fn add(
        &mut self,
        token: llama_cpp_sys_4::llama_token,
        position: llama_cpp_sys_4::llama_pos,
        logits: bool,
    ) -> Result<(), ModelError> {
        if self.value.n_tokens < 0 {
            return Err(ModelError::new(
                "linked llama.cpp batch token count is invalid".to_owned(),
            ));
        }

        let index = self.value.n_tokens as usize;
        if index >= self.capacity {
            return Err(ModelError::new(format!(
                "linked llama.cpp batch capacity exceeded: index {index} capacity {}",
                self.capacity
            )));
        }

        let seq_id = unsafe { *self.value.seq_id.add(index) };
        if seq_id.is_null() {
            return Err(ModelError::new(
                "linked llama.cpp batch sequence slot is null".to_owned(),
            ));
        }

        unsafe {
            *self.value.token.add(index) = token;
            *self.value.pos.add(index) = position;
            *self.value.n_seq_id.add(index) = 1;
            *seq_id.add(0) = 0;
            *self.value.logits.add(index) = i8::from(logits);
        }
        self.value.n_tokens += 1;
        Ok(())
    }
}

impl Drop for LinkedBatch {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_batch_free(self.value);
        }
    }
}

struct LinkedSampler {
    ptr: *mut llama_cpp_sys_4::llama_sampler,
}

impl Drop for LinkedSampler {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_sampler_free(self.ptr);
        }
    }
}

fn tokenize_linked(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    text: &str,
) -> Result<Vec<llama_cpp_sys_4::llama_token>, ModelError> {
    let text = std::ffi::CString::new(text)
        .map_err(|_| ModelError::new("linked llama.cpp prompt contains null byte".to_owned()))?;
    let text_len = i32::try_from(text.as_bytes().len()).map_err(|_| {
        ModelError::new("linked llama.cpp prompt is too large to tokenize".to_owned())
    })?;
    let size = unsafe {
        llama_cpp_sys_4::llama_tokenize(
            vocab,
            text.as_ptr(),
            text_len,
            std::ptr::null_mut(),
            0,
            true,
            true,
        )
    };
    let capacity = token_capacity_from_probe(size)?;
    if capacity <= 0 {
        return Ok(Vec::new());
    }
    if capacity as u32 > LINKED_CONTEXT_WINDOW_TOKENS {
        return Err(ModelError::new(format!(
            "linked llama.cpp prompt has at least {capacity} tokens, exceeds context window {LINKED_CONTEXT_WINDOW_TOKENS}"
        )));
    }

    let mut tokens = vec![0; capacity as usize];
    let actual = unsafe {
        llama_cpp_sys_4::llama_tokenize(
            vocab,
            text.as_ptr(),
            text_len,
            tokens.as_mut_ptr(),
            tokens.len() as i32,
            true,
            true,
        )
    };
    if actual < 0 {
        return Err(ModelError::new(format!(
            "linked llama.cpp tokenize failed: {actual}"
        )));
    }
    if actual as usize > tokens.len() {
        return Err(ModelError::new(format!(
            "linked llama.cpp tokenize wrote more tokens than allocated: {actual} > {}",
            tokens.len()
        )));
    }
    tokens.truncate(actual as usize);
    Ok(tokens)
}

fn token_capacity_from_probe(size: i32) -> Result<i32, ModelError> {
    if size == i32::MIN {
        return Err(ModelError::new(
            "linked llama.cpp tokenize returned invalid token count".to_owned(),
        ));
    }

    Ok(size.abs())
}

fn linked_token_to_piece(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
) -> String {
    let mut buffer = vec![0_u8; 128];
    let mut size = unsafe {
        llama_cpp_sys_4::llama_token_to_piece(
            vocab,
            token,
            buffer.as_mut_ptr().cast(),
            buffer.len() as i32,
            0,
            true,
        )
    };
    if size < 0 {
        let Some(required) = size.checked_neg().and_then(|value| usize::try_from(value).ok())
        else {
            return String::new();
        };
        if required > LINKED_MAX_TOKEN_PIECE_BYTES {
            return String::new();
        }
        buffer.resize(required, 0);
        size = unsafe {
            llama_cpp_sys_4::llama_token_to_piece(
                vocab,
                token,
                buffer.as_mut_ptr().cast(),
                buffer.len() as i32,
                0,
                true,
            )
        };
    }
    if size < 0 {
        return String::new();
    }
    if size > 0 {
        buffer.truncate(size as usize);
    }
    String::from_utf8_lossy(&buffer).to_string()
}

fn linked_clear_context(context: *mut llama_cpp_sys_4::llama_context) {
    unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if !memory.is_null() {
            llama_cpp_sys_4::llama_memory_clear(memory, true);
        }
    }
}

fn linked_capture_prefix_state(
    context: *mut llama_cpp_sys_4::llama_context,
    hash: &str,
    prefix_token_count: usize,
) -> Result<Option<LinkedPrefixState>, ModelError> {
    let size = unsafe {
        llama_cpp_sys_4::llama_state_seq_get_size(context, LINKED_ACTIVE_SEQUENCE_ID)
    };
    if size == 0 || size > LINKED_PREFIX_STATE_MAX_BYTES {
        return Ok(None);
    }

    let mut data = vec![0_u8; size];
    let copied = unsafe {
        llama_cpp_sys_4::llama_state_seq_get_data(
            context,
            data.as_mut_ptr(),
            data.len(),
            LINKED_ACTIVE_SEQUENCE_ID,
        )
    };
    if copied == 0 || copied > data.len() {
        return Ok(None);
    }
    data.truncate(copied);

    Ok(Some(LinkedPrefixState {
        hash: hash.to_owned(),
        token_count: prefix_token_count,
        data,
    }))
}

fn linked_restore_prefix_state(
    context: *mut llama_cpp_sys_4::llama_context,
    state: &LinkedPrefixState,
) -> Result<bool, ModelError> {
    linked_clear_context(context);
    let restored = unsafe {
        llama_cpp_sys_4::llama_state_seq_set_data(
            context,
            state.data.as_ptr(),
            state.data.len(),
            LINKED_ACTIVE_SEQUENCE_ID,
        )
    };
    Ok(restored == state.data.len())
}

fn linked_output_complete_end(output: &str) -> Option<usize> {
    let mut depth = 0_i32;
    let mut in_string = false;
    let mut escape = false;
    let mut seen_open = false;

    for (index, ch) in output.char_indices() {
        if in_string {
            if escape {
                escape = false;
            } else if ch == '\\' {
                escape = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }

        match ch {
            '"' => in_string = true,
            '{' => {
                depth += 1;
                seen_open = true;
            }
            '}' => {
                depth -= 1;
                if seen_open && depth == 0 {
                    return Some(index + ch.len_utf8());
                }
                if depth < 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
    }

    None
}

fn linked_cancel_requested(job_id: i64) -> Result<bool, ModelError> {
    let result: pgrx::spi::Result<bool> = pgrx::bgworkers::BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job_id.into()];
            let rows = client.update(
                "SELECT status = 'cancel_requested' FROM otlet.jobs WHERE id = $1",
                Some(1),
                &args,
            )?;
            if rows.is_empty() {
                return Ok(false);
            }

            Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
        })
    });

    result.map_err(|err| ModelError::new(format!("linked cancellation check failed: {err}")))
}
