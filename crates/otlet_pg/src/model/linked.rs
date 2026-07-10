fn run_linked(
    job: &Job,
    job_model: JobModelRef<'_>,
    prompt: &str,
    prompt_prefix: &str,
    options: &crate::runtime::RuntimeOptions,
    model_fingerprint_hash: &str,
) -> Result<LinkedRun, ModelError> {
    use std::ffi::CString;

    let attempt_start = Instant::now();
    if job_model.artifact_path.starts_with("hf:") {
        return Err(ModelError::new_static("linked llama.cpp runtime requires a local GGUF artifact path"));
    }
    LINKED_BACKEND.get_or_init(|| unsafe {
        llama_cpp_sys_4::llama_backend_init();
    });

    let cache = LINKED_CACHE.get_or_init(|| Mutex::new(None));
    let mut cache = cache
        .lock()
        .map_err(|_| ModelError::new_static("linked llama.cpp cache lock poisoned"))?;
    let cache_hit = cache.as_ref().is_some_and(|cached| {
        cached.artifact_path == job_model.artifact_path
            && cached.model_fingerprint_hash.as_ref() == model_fingerprint_hash
    });

    if !cache_hit {
        let model_path = CString::new(job_model.artifact_path.as_bytes())
            .map_err(|_| ModelError::new_static("linked llama.cpp model path is invalid"))?;
        let mut model_params = unsafe { llama_cpp_sys_4::llama_model_default_params() };
        model_params.n_gpu_layers = 0;
        model_params.use_mmap = linked_env_bool("OTLET_LLAMA_MMAP", model_params.use_mmap);
        model_params.use_mlock = linked_env_bool("OTLET_LLAMA_MLOCK", model_params.use_mlock);
        let prompt_batch_tokens = linked_prompt_batch_tokens();
        let prompt_micro_batch_tokens = linked_prompt_ubatch_tokens(prompt_batch_tokens);
        let decode_threads = linked_decode_threads(options);
        let batch_threads = linked_batch_threads(options, decode_threads);

        let load_start = Instant::now();
        let model_ptr = unsafe {
            llama_cpp_sys_4::llama_model_load_from_file(model_path.as_ptr(), model_params)
        };
        let load_ms = elapsed_ms(load_start);
        if model_ptr.is_null() {
            return Err(ModelError::new_static("linked llama.cpp model load failed"));
        }
        let model = LinkedModel { ptr: model_ptr };

        let mut ctx_params = unsafe { llama_cpp_sys_4::llama_context_default_params() };
        ctx_params.n_ctx = LINKED_CONTEXT_WINDOW_TOKENS;
        ctx_params.n_batch = usize_to_u32_saturating(prompt_batch_tokens);
        ctx_params.n_ubatch = usize_to_u32_saturating(prompt_micro_batch_tokens);
        ctx_params.no_perf = linked_env_bool("OTLET_LLAMA_NO_PERF", true);
        linked_apply_flash_attn_type(&mut ctx_params);
        linked_apply_kv_cache_type(&mut ctx_params);
        // llama.cpp defaults to GGML_DEFAULT_N_THREADS (4); use measured host
        // defaults unless a probe pins generation or prompt-decode threads.
        ctx_params.n_threads = decode_threads;
        ctx_params.n_threads_batch = batch_threads;
        let ctx_start = Instant::now();
        let context_ptr = unsafe { llama_cpp_sys_4::llama_init_from_model(model.ptr, ctx_params) };
        let ctx_ms = elapsed_ms(ctx_start);
        if context_ptr.is_null() {
            return Err(ModelError::new_static("linked llama.cpp context start failed"));
        }
        let context = LinkedContext { ptr: context_ptr };
        let model_memory_bytes =
            u64_to_i64_saturating(unsafe { llama_cpp_sys_4::llama_model_size(model.ptr) });
        let model_parameters =
            u64_to_i64_saturating(unsafe { llama_cpp_sys_4::llama_model_n_params(model.ptr) });
        let context_window_tokens =
            u64_to_i64_saturating(u64::from(unsafe { llama_cpp_sys_4::llama_n_ctx(context.ptr) }));

        let vocab = unsafe { llama_cpp_sys_4::llama_model_get_vocab(model.ptr) };
        if vocab.is_null() {
            return Err(ModelError::new_static("linked llama.cpp model has no vocab"));
        }

        *cache = Some(LinkedCache {
            artifact_path: job_model.artifact_path.to_owned(),
            model_fingerprint_hash: Arc::<str>::from(model_fingerprint_hash),
            _model: model,
            context,
            vocab,
            kv_tokens: Vec::with_capacity(512),
            prompt_prefix_states: Vec::with_capacity(LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES),
            batch: None,
            load_ms,
            ctx_ms,
            model_memory_bytes,
            model_parameters,
            context_window_tokens,
            model_device_policy: LINKED_MODEL_DEVICE_POLICY,
            memory_accounting_policy: LINKED_MEMORY_ACCOUNTING_POLICY,
        });
    }

    let cache = cache
        .as_mut()
        .ok_or_else(|| ModelError::new_static("linked llama.cpp cache did not initialize"))?;
    let decode_threads = linked_decode_threads(options);
    let batch_threads = linked_batch_threads(options, decode_threads);
    unsafe {
        llama_cpp_sys_4::llama_set_n_threads(cache.context.ptr, decode_threads, batch_threads);
    }
    let tokenize_start = Instant::now();
    let tokens = tokenize_linked(cache.vocab, prompt)?;
    // Skip prefix tokenization when the string cannot be a prefix of the prompt.
    let prompt_prefix_tokens = if !prompt_prefix.is_empty() && prompt.starts_with(prompt_prefix) {
        tokenize_linked(cache.vocab, prompt_prefix)?
    } else {
        Vec::new()
    };
    let tokenize_ms = elapsed_ms(tokenize_start);
    if tokens.is_empty() {
        return Err(ModelError::new_static("linked llama.cpp prompt produced no tokens"));
    }

    validate_linked_token_budget(tokens.len(), options.max_tokens, cache.context_window_tokens)?;

    if options.max_worker_rss_bytes > 0 {
        let resident_memory = process_memory_sample();
        enforce_worker_rss_budget(&resident_memory, options.max_worker_rss_bytes)?;
    }

    if linked_cancel_requested(job.id)? {
        return Err(ModelError::new_static("canceled"));
    }
    let mut cancel_probe = CancelProbe::new();

    // Reuse the KV cache for the shared prompt prefix (same instruction/schema
    // across a task's jobs) so only the diverging suffix is re-decoded.
    let prompt_decode_start = Instant::now();
    let prompt_cached_tokens_before = cache.kv_tokens.len();
    let prompt_batch_tokens = linked_prompt_batch_tokens();
    let owned_batch = match cache.batch.take() {
        Some(batch) if batch.capacity == prompt_batch_tokens => batch,
        _ => LinkedBatch::new(prompt_batch_tokens)?,
    };
    // Raw dest pointer lets Drop restore the batch without holding a borrow on
    // LinkedCache, so prompt-prefix helpers can still mutate cache fields.
    let mut batch_slot = LinkedBatchSlot {
        batch: Some(owned_batch),
        dest: std::ptr::from_mut(&mut cache.batch),
    };
    let batch = batch_slot
        .batch
        .as_mut()
        .ok_or_else(|| ModelError::new_static("linked llama.cpp batch did not initialize"))?;
    batch.reset();
    let mut prompt_reused_tokens = 0;
    let mut prompt_decoded_tokens = tokens.len();
    let mut prompt_reuse_strategy: &'static str = "full_prompt_decode";
    let mut prompt_prefix_state_bytes = 0_i64;
    let prefix_reusable = linked_prompt_prefix_reusable(&tokens, &prompt_prefix_tokens);
    if prefix_reusable {
        let prompt_prefix_hash = hash_text(prompt_prefix);
        if let Some(state_bytes) =
            linked_restore_prompt_prefix_state(cache, &prompt_prefix_hash, &prompt_prefix_tokens)
        {
            prompt_reused_tokens = prompt_prefix_tokens.len();
            prompt_decoded_tokens = tokens.len().saturating_sub(prompt_reused_tokens);
            prompt_reuse_strategy = "prefix_state_restored";
            prompt_prefix_state_bytes = usize_to_i64_saturating(state_bytes);
            linked_decode_prompt_tokens(
                job,
                cache.context.ptr,
                batch,
                &tokens[prompt_reused_tokens..],
                prompt_reused_tokens,
                prompt_batch_tokens,
                &mut cache.kv_tokens,
                &mut cancel_probe,
                true,
            )?;
        } else {
            linked_clear_context(cache.context.ptr);
            cache.kv_tokens.clear();
            linked_decode_prompt_tokens(
                job,
                cache.context.ptr,
                batch,
                &prompt_prefix_tokens,
                0,
                prompt_batch_tokens,
                &mut cache.kv_tokens,
                &mut cancel_probe,
                false,
            )?;
            let saved_prefix =
                linked_save_prompt_prefix_state(cache, &prompt_prefix_hash, &prompt_prefix_tokens);
            prompt_reuse_strategy = saved_prefix.strategy;
            prompt_prefix_state_bytes = usize_to_i64_saturating(saved_prefix.state_bytes);
            linked_decode_prompt_tokens(
                job,
                cache.context.ptr,
                batch,
                &tokens[prompt_prefix_tokens.len()..],
                prompt_prefix_tokens.len(),
                prompt_batch_tokens,
                &mut cache.kv_tokens,
                &mut cancel_probe,
                true,
            )?;
        }
    } else {
        let common_prefix =
            linked_reuse_prompt_prefix(cache.context.ptr, &mut cache.kv_tokens, &tokens);
        prompt_reused_tokens = common_prefix;
        prompt_decoded_tokens = tokens.len().saturating_sub(common_prefix);
        if common_prefix > 0 {
            prompt_reuse_strategy = "kv_prefix_reused";
        } else if !prompt_prefix_tokens.is_empty() {
            prompt_reuse_strategy = "prefix_token_mismatch";
        }
        linked_decode_prompt_tokens(
            job,
            cache.context.ptr,
            batch,
            &tokens[common_prefix..],
            common_prefix,
            prompt_batch_tokens,
            &mut cache.kv_tokens,
            &mut cancel_probe,
            true,
        )?;
    }
    let prompt_decode_ms = elapsed_ms(prompt_decode_start);

    let sampler_ptr = unsafe { llama_cpp_sys_4::llama_sampler_init_greedy() };
    if sampler_ptr.is_null() {
        return Err(ModelError::new_static("linked llama.cpp sampler start failed"));
    }
    let sampler = LinkedSampler { ptr: sampler_ptr };
    let mut output = Vec::with_capacity(linked_output_capacity(options.max_tokens));
    let mut json_completion = JsonCompletion::new();
    let mut position = tokens.len();
    let mut generated_tokens = 0_i64;
    let mut probability_trace = ProbabilityTrace::new(options);
    let mut detailed_trace = DetailedGenerationTrace::new(options);
    let mut stop_reason: &'static str = "max_tokens";
    let mut token_piece_buf = vec![0_u8; 128];
    let mut first_token_ms = 0_i64;
    let mut first_token_seen = false;
    let generate_start = Instant::now();

    for _ in 0..options.max_tokens {
        if linked_attempt_timed_out(attempt_start, job.max_attempt_ms) {
            return Err(ModelError::attempt_timeout());
        }
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new_static("canceled"));
        }
        let token =
            unsafe { llama_cpp_sys_4::llama_sampler_sample(sampler.ptr, cache.context.ptr, -1) };
        let wants_detail = detailed_trace.wants_sample();
        let sample = if wants_detail || probability_trace.wants_sample() {
            unsafe {
                probability_sample(
                    cache.context.ptr,
                    cache.vocab,
                    token,
                    // top alternatives are only surfaced by the detailed trace
                    if wants_detail {
                        options.generation_trace_top_k
                    } else {
                        0
                    },
                )
            }
        } else {
            None
        };
        probability_trace.observe(sample.as_ref());
        if unsafe { llama_cpp_sys_4::llama_vocab_is_eog(cache.vocab, token) } {
            stop_reason = "eog_token";
            break;
        }

        unsafe {
            llama_cpp_sys_4::llama_sampler_accept(sampler.ptr, token);
        }
        generated_tokens += 1;
        if !first_token_seen {
            first_token_ms = elapsed_ms(generate_start);
            first_token_seen = true;
        }
        let piece_start = output.len();
        linked_token_to_piece_into(cache.vocab, token, &mut token_piece_buf, &mut output)?;
        let trace_piece = String::from_utf8_lossy(&output[piece_start..]);
        detailed_trace.observe(token, &trace_piece, sample);
        if let Some(end) = json_completion.observe(&output[piece_start..]) {
            output.truncate(end);
            stop_reason = "json_complete";
            break;
        }

        batch.reset();
        batch.add(
            token,
            i32::try_from(position).map_err(|_| {
                ModelError::new_static("linked llama.cpp generation position overflowed i32")
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
        cache.kv_tokens.push(token);
        if linked_attempt_timed_out(attempt_start, job.max_attempt_ms) {
            return Err(ModelError::attempt_timeout());
        }
        position += 1;
    }
    let generate_ms = elapsed_ms(generate_start);
    let ttft_ms = if first_token_seen {
        tokenize_ms
            .saturating_add(prompt_decode_ms)
            .saturating_add(first_token_ms)
    } else {
        0
    };
    let worker_memory = process_memory_sample();
    enforce_worker_rss_budget(&worker_memory, options.max_worker_rss_bytes)?;
    let output = String::from_utf8(output).map_err(|err| {
        ModelError::new(format!(
            "linked llama.cpp output was not valid UTF-8: {}",
            err.utf8_error()
        ))
    })?;

    Ok(LinkedRun {
        raw_output: output.trim().to_owned(),
        metrics: ModelMetrics {
            artifact_path: cache.artifact_path.clone(),
            load_ms: cache.load_ms,
            ctx_ms: cache.ctx_ms,
            model_memory_bytes: cache.model_memory_bytes,
            model_parameters: cache.model_parameters,
            context_window_tokens: cache.context_window_tokens,
            model_device_policy: cache.model_device_policy.to_owned(),
            memory_accounting_policy: cache.memory_accounting_policy.to_owned(),
            worker_process_rss_bytes: worker_memory.rss_bytes,
            worker_process_virtual_bytes: worker_memory.virtual_bytes,
            worker_memory_sample_policy: worker_memory.policy.to_owned(),
            worker_memory_budget_bytes: u64_to_i64_saturating(options.max_worker_rss_bytes),
            worker_memory_budget_policy: worker_memory_budget_policy(options.max_worker_rss_bytes)
                .to_owned(),
            prompt_tokens: usize_to_i64_saturating(tokens.len()),
            prompt_cached_tokens_before: usize_to_i64_saturating(prompt_cached_tokens_before),
            prompt_reused_tokens: usize_to_i64_saturating(prompt_reused_tokens),
            prompt_decoded_tokens: usize_to_i64_saturating(prompt_decoded_tokens),
            prompt_reuse_strategy: prompt_reuse_strategy.to_owned(),
            prompt_prefix_state_bytes,
            prompt_prefix_cache_entries: usize_to_i64_saturating(cache.prompt_prefix_states.len()),
            prompt_prefix_cache_bytes: usize_to_i64_saturating(linked_prompt_prefix_cache_bytes(cache)),
            effective_llama_threads: i64::from(decode_threads),
            effective_llama_batch_threads: i64::from(batch_threads),
            generated_tokens,
            tokenize_ms,
            prompt_decode_ms,
            first_token_ms,
            ttft_ms,
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
            probability_summary: probability_trace.summary(),
            detailed_trace: detailed_trace.summary(stop_reason),
            stop_reason: stop_reason.to_owned(),
        },
    })
}

fn linked_attempt_timed_out(start: Instant, max_attempt_ms: i64) -> bool {
    max_attempt_ms > 0
        && start.elapsed().as_millis() >= u128::try_from(max_attempt_ms).unwrap_or(u128::MAX)
}

fn linked_decode_threads(options: &crate::runtime::RuntimeOptions) -> i32 {
    if options.llama_threads > 0 {
        return u64_to_i32_saturating(options.llama_threads);
    }
    linked_default_decode_threads()
}

fn linked_batch_threads(options: &crate::runtime::RuntimeOptions, decode_threads: i32) -> i32 {
    if options.llama_batch_threads > 0 {
        return u64_to_i32_saturating(options.llama_batch_threads);
    }
    linked_env_i32("OTLET_LLAMA_BATCH_THREADS").unwrap_or(decode_threads)
}

fn linked_default_decode_threads() -> i32 {
    static DECODE_THREADS: OnceLock<i32> = OnceLock::new();
    *DECODE_THREADS.get_or_init(|| {
        if let Some(threads) = linked_env_usize("OTLET_LLAMA_THREADS") {
            return usize_to_i32_saturating(threads);
        }
        usize_to_i32_saturating(
            std::thread::available_parallelism()
                .map(std::num::NonZero::get)
                .unwrap_or(4)
                .min(LINKED_DEFAULT_MAX_DECODE_THREADS),
        )
    })
}

fn linked_env_i32(name: &str) -> Option<i32> {
    linked_env_usize(name).map(usize_to_i32_saturating)
}

fn linked_env_usize(name: &str) -> Option<usize> {
    let value = std::env::var(name).ok()?;
    let parsed = value.parse::<usize>().ok()?;
    (parsed > 0).then_some(parsed)
}

fn linked_env_bool(name: &str, default: bool) -> bool {
    match std::env::var(name) {
        Ok(value) if matches!(value.as_str(), "1" | "true" | "on" | "yes") => true,
        Ok(value) if matches!(value.as_str(), "0" | "false" | "off" | "no") => false,
        _ => default,
    }
}

fn linked_apply_flash_attn_type(params: &mut llama_cpp_sys_4::llama_context_params) {
    let Ok(value) = std::env::var("OTLET_LLAMA_FLASH_ATTN") else {
        return;
    };
    params.flash_attn_type = match value.as_str() {
        "1" | "true" | "on" | "yes" | "enabled" => llama_cpp_sys_4::LLAMA_FLASH_ATTN_TYPE_ENABLED,
        "0" | "false" | "off" | "no" | "disabled" => {
            llama_cpp_sys_4::LLAMA_FLASH_ATTN_TYPE_DISABLED
        }
        "auto" => llama_cpp_sys_4::LLAMA_FLASH_ATTN_TYPE_AUTO,
        _ => params.flash_attn_type,
    };
}

fn linked_apply_kv_cache_type(params: &mut llama_cpp_sys_4::llama_context_params) {
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE")
        && let Some(cache_type) = linked_ggml_type(&value)
    {
        params.type_k = cache_type;
        params.type_v = cache_type;
    }
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE_K")
        && let Some(cache_type) = linked_ggml_type(&value)
    {
        params.type_k = cache_type;
    }
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE_V")
        && let Some(cache_type) = linked_ggml_type(&value)
    {
        params.type_v = cache_type;
    }
}

fn linked_ggml_type(value: &str) -> Option<llama_cpp_sys_4::ggml_type> {
    // Env values are tiny; compare case-insensitively without allocating.
    if value.eq_ignore_ascii_case("f16") {
        Some(llama_cpp_sys_4::GGML_TYPE_F16)
    } else if value.eq_ignore_ascii_case("q8") || value.eq_ignore_ascii_case("q8_0") {
        Some(llama_cpp_sys_4::GGML_TYPE_Q8_0)
    } else if value.eq_ignore_ascii_case("q4") || value.eq_ignore_ascii_case("q4_0") {
        Some(llama_cpp_sys_4::GGML_TYPE_Q4_0)
    } else {
        None
    }
}

fn linked_prompt_batch_tokens() -> usize {
    static PROMPT_BATCH_TOKENS: OnceLock<usize> = OnceLock::new();
    *PROMPT_BATCH_TOKENS.get_or_init(|| {
        if let Some(tokens) = linked_env_usize("OTLET_LLAMA_BATCH_TOKENS") {
            return tokens.min(LINKED_CONTEXT_WINDOW_TOKENS as usize);
        }
        LINKED_PROMPT_BATCH_TOKENS
    })
}

fn linked_prompt_ubatch_tokens(prompt_batch_tokens: usize) -> usize {
    static PROMPT_UBATCH_TOKENS: OnceLock<usize> = OnceLock::new();
    (*PROMPT_UBATCH_TOKENS.get_or_init(|| {
        linked_env_usize("OTLET_LLAMA_UBATCH_TOKENS").unwrap_or(LINKED_PROMPT_UBATCH_TOKENS)
    }))
    .min(prompt_batch_tokens)
    .min(LINKED_CONTEXT_WINDOW_TOKENS as usize)
}

fn linked_output_capacity(max_tokens: u64) -> usize {
    let token_budget = usize::try_from(max_tokens).unwrap_or(usize::MAX / 8);
    token_budget.saturating_mul(8).min(16 * 1024)
}

#[allow(clippy::too_many_arguments)]
fn linked_decode_prompt_tokens(
    job: &Job,
    context: *mut llama_cpp_sys_4::llama_context,
    batch: &mut LinkedBatch,
    tokens: &[llama_cpp_sys_4::llama_token],
    start_position: usize,
    prompt_batch_tokens: usize,
    kv_tokens: &mut Vec<llama_cpp_sys_4::llama_token>,
    cancel_probe: &mut CancelProbe,
    final_logits: bool,
) -> Result<(), ModelError> {
    let mut decoded_tokens = 0;
    for chunk in tokens.chunks(prompt_batch_tokens) {
        batch.reset();
        for (chunk_index, token) in chunk.iter().enumerate() {
            let position = start_position + decoded_tokens + chunk_index;
            batch.add(
                *token,
                i32::try_from(position).map_err(|_| {
                    ModelError::new_static("linked llama.cpp prompt position overflowed i32")
                })?,
                final_logits && decoded_tokens + chunk_index + 1 == tokens.len(),
            )?;
        }
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new_static("canceled"));
        }
        let decode_status = unsafe { llama_cpp_sys_4::llama_decode(context, batch.value) };
        if decode_status != 0 {
            return Err(ModelError::new(format!(
                "linked llama.cpp prompt decode failed: {decode_status}"
            )));
        }
        kv_tokens.extend_from_slice(chunk);
        decoded_tokens += chunk.len();
    }

    Ok(())
}

/// Cooperative cancellation is checked on a time slice instead of around every
/// llama.cpp call, so the SPI round-trip does not tax each generated token.
struct CancelProbe {
    last_check: Instant,
}

impl CancelProbe {
    fn new() -> Self {
        Self {
            last_check: Instant::now(),
        }
    }

    fn due(&mut self) -> bool {
        if self.last_check.elapsed().as_millis() >= u128::from(LINKED_CANCELLATION_SLICE_MS) {
            self.last_check = Instant::now();
            true
        } else {
            false
        }
    }
}

fn linked_prompt_prefix_reusable(
    tokens: &[llama_cpp_sys_4::llama_token],
    prefix_tokens: &[llama_cpp_sys_4::llama_token],
) -> bool {
    !prefix_tokens.is_empty() && prefix_tokens.len() < tokens.len() && tokens.starts_with(prefix_tokens)
}

fn linked_restore_prompt_prefix_state(
    cache: &mut LinkedCache,
    prompt_prefix_hash: &str,
    prompt_prefix_tokens: &[llama_cpp_sys_4::llama_token],
) -> Option<usize> {
    let index = cache
        .prompt_prefix_states
        .iter()
        .position(|entry| {
            entry.hash == prompt_prefix_hash
                && entry.tokens == prompt_prefix_tokens
                && !entry.state.is_empty()
        })?;

    linked_clear_context(cache.context.ptr);
    let state_len = cache.prompt_prefix_states[index].state.len();
    let restored = unsafe {
        llama_cpp_sys_4::llama_state_seq_set_data(
            cache.context.ptr,
            cache.prompt_prefix_states[index].state.as_ptr(),
            state_len,
            0,
        )
    };
    if restored != state_len {
        cache.prompt_prefix_states.remove(index);
        cache.kv_tokens.clear();
        linked_clear_context(cache.context.ptr);
        return None;
    }

    if index != 0 {
        let entry = cache.prompt_prefix_states.remove(index);
        cache.prompt_prefix_states.insert(0, entry);
    }

    cache.kv_tokens.clear();
    cache.kv_tokens.extend_from_slice(prompt_prefix_tokens);
    Some(state_len)
}

struct SavedPromptPrefix {
    strategy: &'static str,
    state_bytes: usize,
}

fn linked_save_prompt_prefix_state(
    cache: &mut LinkedCache,
    prompt_prefix_hash: &str,
    prompt_prefix_tokens: &[llama_cpp_sys_4::llama_token],
) -> SavedPromptPrefix {
    let state_size =
        unsafe { llama_cpp_sys_4::llama_state_seq_get_size(cache.context.ptr, 0) };
    if state_size == 0 {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_unavailable",
            state_bytes: 0,
        };
    }
    if state_size > LINKED_PROMPT_PREFIX_STATE_MAX_BYTES {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_too_large",
            state_bytes: 0,
        };
    }

    let mut state = vec![0_u8; state_size];
    let written = unsafe {
        llama_cpp_sys_4::llama_state_seq_get_data(
            cache.context.ptr,
            state.as_mut_ptr(),
            state.len(),
            0,
        )
    };
    if written != state.len() {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_save_failed",
            state_bytes: 0,
        };
    }

    linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
    cache.prompt_prefix_states.insert(
        0,
        PromptPrefixState {
            hash: prompt_prefix_hash.to_owned(),
            tokens: prompt_prefix_tokens.to_vec(),
            state,
        },
    );
    linked_evict_prompt_prefix_states(cache);
    SavedPromptPrefix {
        strategy: "prefix_state_saved",
        state_bytes: state_size,
    }
}

fn linked_remove_prompt_prefix_state(cache: &mut LinkedCache, prompt_prefix_hash: &str) {
    cache
        .prompt_prefix_states
        .retain(|entry| entry.hash != prompt_prefix_hash);
}

fn linked_evict_prompt_prefix_states(cache: &mut LinkedCache) {
    while cache.prompt_prefix_states.len() > LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES
        || linked_prompt_prefix_cache_bytes(cache) > LINKED_PROMPT_PREFIX_STATE_MAX_BYTES
    {
        if cache.prompt_prefix_states.pop().is_none() {
            break;
        }
    }
}

fn linked_prompt_prefix_cache_bytes(cache: &LinkedCache) -> usize {
    cache
        .prompt_prefix_states
        .iter()
        .map(|entry| entry.state.len())
        .sum()
}

/// Keeps the longest common prefix between the tokens already decoded into the
/// context memory and the new prompt, removes everything past it, and returns
/// how many prompt tokens can be skipped. At least one prompt token is always
/// re-decoded so generation has fresh logits. `kv_tokens` is truncated to the
/// retained prefix before any new decode happens, so a failed decode later can
/// never leave it claiming tokens the memory does not hold.
fn linked_reuse_prompt_prefix(
    context: *mut llama_cpp_sys_4::llama_context,
    kv_tokens: &mut Vec<llama_cpp_sys_4::llama_token>,
    tokens: &[llama_cpp_sys_4::llama_token],
) -> usize {
    let mut common = kv_tokens
        .iter()
        .zip(tokens.iter())
        .take_while(|(kept, new)| kept == new)
        .count();
    if common >= tokens.len() {
        common = tokens.len().saturating_sub(1);
    }

    if common == 0 {
        linked_clear_context(context);
        kv_tokens.clear();
        return 0;
    }

    let removed = unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if memory.is_null() {
            false
        } else {
            // Remove from the divergence point onward; this also clears any
            // stale generated tokens from the previous run.
            llama_cpp_sys_4::llama_memory_seq_rm(memory, 0, usize_to_i32_saturating(common), -1)
        }
    };
    if !removed {
        linked_clear_context(context);
        kv_tokens.clear();
        return 0;
    }

    kv_tokens.truncate(common);
    common
}

fn validate_linked_token_budget(
    prompt_tokens: usize,
    max_tokens: u64,
    context_window_tokens: i64,
) -> Result<(), ModelError> {
    let Ok(context_window_tokens) = usize::try_from(context_window_tokens) else {
        return Err(ModelError::clean_failure_static(
            "linked llama.cpp context window is invalid",
            "prompt_token_budget_before_generation",
            "invalid_context_window",
        ));
    };
    if prompt_tokens >= context_window_tokens {
        return Err(ModelError::clean_failure(
            format!(
                "linked llama.cpp prompt has {prompt_tokens} tokens, exceeds context window {context_window_tokens}"
            ),
            "prompt_token_budget_before_generation",
            "prompt_exceeds_context_window",
        ));
    }

    let max_tokens = usize::try_from(max_tokens).unwrap_or(usize::MAX);
    if prompt_tokens.saturating_add(max_tokens) > context_window_tokens {
        return Err(ModelError::clean_failure(
            format!(
                "linked llama.cpp prompt has {prompt_tokens} tokens plus max_tokens {max_tokens}, exceeds context window {context_window_tokens}"
            ),
            "prompt_token_budget_before_generation",
            "prompt_and_generation_exceed_context_window",
        ));
    }

    Ok(())
}

struct LinkedRun {
    raw_output: String,
    metrics: ModelMetrics,
}

struct LinkedCache {
    artifact_path: String,
    model_fingerprint_hash: Arc<str>,
    context: LinkedContext,
    _model: LinkedModel,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    /// Tokens known to occupy positions `0..len` of the context memory; used
    /// to reuse the KV cache for shared prompt prefixes across jobs.
    kv_tokens: Vec<llama_cpp_sys_4::llama_token>,
    prompt_prefix_states: Vec<PromptPrefixState>,
    /// Reused across jobs while the model stays resident.
    batch: Option<LinkedBatch>,
    load_ms: i64,
    ctx_ms: i64,
    model_memory_bytes: i64,
    model_parameters: i64,
    context_window_tokens: i64,
    model_device_policy: &'static str,
    memory_accounting_policy: &'static str,
}

unsafe impl Send for LinkedCache {}

struct PromptPrefixState {
    hash: String,
    tokens: Vec<llama_cpp_sys_4::llama_token>,
    state: Vec<u8>,
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

struct LinkedBatchSlot {
    batch: Option<LinkedBatch>,
    dest: *mut Option<LinkedBatch>,
}

impl Drop for LinkedBatchSlot {
    fn drop(&mut self) {
        if let Some(batch) = self.batch.take() {
            // Safety: dest points at LinkedCache.batch for this run_linked call
            unsafe {
                *self.dest = Some(batch);
            }
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
            ModelError::new_static("linked llama.cpp batch capacity overflowed i32")
        })?;
        let value = unsafe { llama_cpp_sys_4::llama_batch_init(capacity_i32, 0, 1) };
        let batch = Self { value, capacity };
        if batch.value.token.is_null()
            || batch.value.pos.is_null()
            || batch.value.n_seq_id.is_null()
            || batch.value.seq_id.is_null()
            || batch.value.logits.is_null()
        {
            return Err(ModelError::new_static("linked llama.cpp batch allocation failed"));
        }

        Ok(batch)
    }

    const fn reset(&mut self) {
        self.value.n_tokens = 0;
    }

    fn add(
        &mut self,
        token: llama_cpp_sys_4::llama_token,
        position: llama_cpp_sys_4::llama_pos,
        logits: bool,
    ) -> Result<(), ModelError> {
        if self.value.n_tokens < 0 {
            return Err(ModelError::new_static("linked llama.cpp batch token count is invalid"));
        }

        let index = usize::try_from(self.value.n_tokens).map_err(|_| {
            ModelError::new_static("linked llama.cpp batch token count overflowed usize")
        })?;
        if index >= self.capacity {
            return Err(ModelError::new(format!(
                "linked llama.cpp batch capacity exceeded: index {index} capacity {}",
                self.capacity
            )));
        }

        let seq_id = unsafe { *self.value.seq_id.add(index) };
        if seq_id.is_null() {
            return Err(ModelError::new_static("linked llama.cpp batch sequence slot is null"));
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
        .map_err(|_| ModelError::new_static("linked llama.cpp prompt contains null byte"))?;
    let text_len = i32::try_from(text.as_bytes().len()).map_err(|_| {
        ModelError::clean_failure_static(
            "linked llama.cpp prompt is too large to tokenize",
            "prompt_token_budget_before_generation",
            "prompt_exceeds_context_window",
        )
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
    if u32::try_from(capacity).unwrap_or(u32::MAX) > LINKED_CONTEXT_WINDOW_TOKENS {
        return Err(ModelError::clean_failure(
            format!(
                "linked llama.cpp prompt has at least {capacity} tokens, exceeds context window {LINKED_CONTEXT_WINDOW_TOKENS}"
            ),
            "prompt_token_budget_before_generation",
            "prompt_exceeds_context_window",
        ));
    }

    let capacity_usize = usize::try_from(capacity).map_err(|_| {
        ModelError::new_static("linked llama.cpp prompt capacity overflowed usize")
    })?;
    let mut tokens = vec![0; capacity_usize];
    let tokens_len = i32::try_from(tokens.len()).map_err(|_| {
        ModelError::new_static("linked llama.cpp token buffer length overflowed i32")
    })?;
    let actual = unsafe {
        llama_cpp_sys_4::llama_tokenize(
            vocab,
            text.as_ptr(),
            text_len,
            tokens.as_mut_ptr(),
            tokens_len,
            true,
            true,
        )
    };
    if actual < 0 {
        return Err(ModelError::new(format!(
            "linked llama.cpp tokenize failed: {actual}"
        )));
    }
    let actual_usize = usize::try_from(actual).map_err(|_| {
        ModelError::new_static("linked llama.cpp tokenize result overflowed usize")
    })?;
    if actual_usize > tokens.len() {
        return Err(ModelError::new(format!(
            "linked llama.cpp tokenize wrote more tokens than allocated: {actual} > {}",
            tokens.len()
        )));
    }
    tokens.truncate(actual_usize);
    Ok(tokens)
}

fn token_capacity_from_probe(size: i32) -> Result<i32, ModelError> {
    if size == i32::MIN {
        return Err(ModelError::new_static("linked llama.cpp tokenize returned invalid token count"));
    }

    Ok(size.abs())
}

fn linked_token_to_piece_into(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
    buffer: &mut Vec<u8>,
    output: &mut Vec<u8>,
) -> Result<(), ModelError> {
    if buffer.len() < 128 {
        buffer.resize(128, 0);
    }
    let buffer_len = i32::try_from(buffer.len()).map_err(|_| {
        ModelError::new_static("linked llama.cpp token piece buffer overflowed i32")
    })?;
    let mut size = unsafe {
        llama_cpp_sys_4::llama_token_to_piece(
            vocab,
            token,
            buffer.as_mut_ptr().cast(),
            buffer_len,
            0,
            true,
        )
    };
    if size < 0 {
        let required = size
            .checked_neg()
            .and_then(|value| usize::try_from(value).ok())
            .ok_or_else(|| {
                ModelError::new_static("linked llama.cpp token piece size was invalid")
            })?;
        if required > LINKED_MAX_TOKEN_PIECE_BYTES {
            return Err(ModelError::new(format!(
                "linked llama.cpp token piece exceeded {LINKED_MAX_TOKEN_PIECE_BYTES} bytes"
            )));
        }
        buffer.resize(required, 0);
        let buffer_len = i32::try_from(buffer.len()).map_err(|_| {
            ModelError::new_static("linked llama.cpp token piece buffer overflowed i32")
        })?;
        size = unsafe {
            llama_cpp_sys_4::llama_token_to_piece(
                vocab,
                token,
                buffer.as_mut_ptr().cast(),
                buffer_len,
                0,
                true,
            )
        };
    }
    if size <= 0 {
        return Ok(());
    }
    let size = usize::try_from(size).map_err(|_| {
        ModelError::new_static("linked llama.cpp token piece size overflowed usize")
    })?;
    if size > buffer.len() {
        return Err(ModelError::new(format!(
            "linked llama.cpp token piece exceeded its buffer: {size} > {}",
            buffer.len()
        )));
    }
    output.extend_from_slice(&buffer[..size]);
    Ok(())
}

fn linked_token_to_piece(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
) -> String {
    let mut output = Vec::new();
    let mut buffer = vec![0_u8; 128];
    let _ = linked_token_to_piece_into(vocab, token, &mut buffer, &mut output);
    String::from_utf8_lossy(&output).into_owned()
}

fn linked_clear_context(context: *mut llama_cpp_sys_4::llama_context) {
    unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if !memory.is_null() {
            llama_cpp_sys_4::llama_memory_clear(memory, true);
        }
    }
}

struct JsonCompletion {
    depth: i32,
    in_string: bool,
    escape: bool,
    seen_open: bool,
    bytes_seen: usize,
    complete_end: Option<usize>,
}

impl JsonCompletion {
    const fn new() -> Self {
        Self {
            depth: 0,
            in_string: false,
            escape: false,
            seen_open: false,
            bytes_seen: 0,
            complete_end: None,
        }
    }

    fn observe(&mut self, bytes: &[u8]) -> Option<usize> {
        if self.complete_end.is_some() {
            return self.complete_end;
        }

        for (index, byte) in bytes.iter().copied().enumerate() {
            if self.in_string {
                if self.escape {
                    self.escape = false;
                } else if byte == b'\\' {
                    self.escape = true;
                } else if byte == b'"' {
                    self.in_string = false;
                }
                continue;
            }

            match byte {
                b'"' => self.in_string = true,
                b'{' => {
                    self.depth += 1;
                    self.seen_open = true;
                }
                b'}' => {
                    self.depth -= 1;
                    if self.seen_open && self.depth == 0 {
                        self.complete_end = Some(self.bytes_seen + index + 1);
                        return self.complete_end;
                    }
                    if self.depth < 0 {
                        self.complete_end = Some(self.bytes_seen + index);
                        return self.complete_end;
                    }
                }
                _ => {}
            }
        }

        self.bytes_seen += bytes.len();
        None
    }
}

#[cfg(test)]
mod tests {
    use super::JsonCompletion;

    #[test]
    fn json_completion_accepts_utf8_split_across_pieces() {
        let mut completion = JsonCompletion::new();
        let prefix = b"{\"text\":\"";
        let split_utf8 = [0xe2, 0x82, 0xac];
        let suffix = b"\"} trailing";

        assert_eq!(completion.observe(prefix), None);
        assert_eq!(completion.observe(&split_utf8), None);
        assert_eq!(
            completion.observe(suffix),
            Some(prefix.len() + split_utf8.len() + 2)
        );
    }

    #[test]
    fn json_completion_keeps_escape_state_across_pieces() {
        let mut completion = JsonCompletion::new();
        let prefix = b"{\"text\":\"quoted\\";
        let suffix = b"\"\"}";

        assert_eq!(completion.observe(prefix), None);
        assert_eq!(
            completion.observe(suffix),
            Some(prefix.len() + suffix.len())
        );
    }
}

fn linked_cancel_requested(job_id: i64) -> Result<bool, ModelError> {
    let result: pgrx::spi::Result<Result<bool, ModelError>> =
        pgrx::bgworkers::BackgroundWorker::transaction(|| {
            // Read-only probe — use select so the plan stays non-volatile.
            pgrx::Spi::connect(|client| {
                let args = [job_id.into()];
                let rows = client.select(
                    "SELECT status = 'cancel_requested' FROM otlet.jobs WHERE id = $1 LIMIT 1",
                    Some(1),
                    &args,
                )?;
                if rows.is_empty() {
                    // Fail closed: a vanished job mid-decode must not keep generating.
                    return Ok(Err(ModelError::new_static(
                        "linked cancellation check: job row missing",
                    )));
                }

                match rows.first().get::<bool>(1)? {
                    Some(canceled) => Ok(Ok(canceled)),
                    None => Ok(Err(ModelError::new_static(
                        "linked cancellation check: cancel flag unreadable",
                    ))),
                }
            })
        });

    match result {
        Ok(inner) => inner,
        Err(err) => Err(ModelError::new(format!(
            "linked cancellation check failed: {err}"
        ))),
    }
}
