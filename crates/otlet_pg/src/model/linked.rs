fn run_linked(
    job: &Job,
    prompt: &str,
    options: &crate::runtime::RuntimeOptions,
    model_fingerprint_hash: &str,
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
        model_params.use_mmap = linked_env_bool("OTLET_LLAMA_MMAP", model_params.use_mmap);
        model_params.use_mlock = linked_env_bool("OTLET_LLAMA_MLOCK", model_params.use_mlock);
        let prompt_batch_tokens = linked_prompt_batch_tokens();
        let prompt_ubatch_tokens = linked_prompt_ubatch_tokens(prompt_batch_tokens);
        let decode_threads = linked_decode_threads(options);
        let batch_threads = linked_batch_threads(options, decode_threads);

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
        ctx_params.n_batch = prompt_batch_tokens as u32;
        ctx_params.n_ubatch = prompt_ubatch_tokens as u32;
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
            model_fingerprint_hash: model_fingerprint_hash.to_owned(),
            _model: model,
            context,
            vocab,
            kv_tokens: Vec::new(),
            load_ms,
            ctx_ms,
            model_memory_bytes,
            model_parameters,
            context_window_tokens,
            model_device_policy: LINKED_MODEL_DEVICE_POLICY.to_owned(),
            memory_accounting_policy: LINKED_MEMORY_ACCOUNTING_POLICY.to_owned(),
        });
    }

    let cache = cache
        .as_mut()
        .ok_or_else(|| ModelError::new("linked llama.cpp cache did not initialize".to_owned()))?;
    let decode_threads = linked_decode_threads(options);
    let batch_threads = linked_batch_threads(options, decode_threads);
    unsafe {
        llama_cpp_sys_4::llama_set_n_threads(cache.context.ptr, decode_threads, batch_threads);
    }
    let tokens = tokenize_linked(cache.vocab, prompt)?;
    if tokens.is_empty() {
        return Err(ModelError::new(
            "linked llama.cpp prompt produced no tokens".to_owned(),
        ));
    }

    validate_linked_token_budget(tokens.len(), options.max_tokens, cache.context_window_tokens)?;

    let resident_memory = process_memory_sample();
    enforce_worker_rss_budget(&resident_memory, options.max_worker_rss_bytes)?;

    if linked_cancel_requested(job.id)? {
        return Err(ModelError::new("canceled".to_owned()));
    }
    let mut cancel_probe = CancelProbe::new();

    // Reuse the KV cache for the shared prompt prefix (same instruction/schema
    // across a task's jobs) so only the diverging suffix is re-decoded.
    let common_prefix =
        linked_reuse_prompt_prefix(cache.context.ptr, &mut cache.kv_tokens, &tokens);

    let prompt_batch_tokens = linked_prompt_batch_tokens();
    let mut batch = LinkedBatch::new(prompt_batch_tokens)?;
    linked_decode_prompt_tokens(
        job,
        cache.context.ptr,
        &mut batch,
        &tokens[common_prefix..],
        common_prefix,
        prompt_batch_tokens,
        &mut cache.kv_tokens,
        &mut cancel_probe,
    )?;

    let sampler_ptr = unsafe { llama_cpp_sys_4::llama_sampler_init_greedy() };
    if sampler_ptr.is_null() {
        return Err(ModelError::new(
            "linked llama.cpp sampler start failed".to_owned(),
        ));
    }
    let sampler = LinkedSampler { ptr: sampler_ptr };
    let mut output = String::with_capacity(linked_output_capacity(options.max_tokens));
    let mut position = tokens.len();
    let mut generated_tokens = 0_i64;
    let mut probability_trace = ProbabilityTrace::new(options);
    let mut detailed_trace = DetailedGenerationTrace::new(options);
    let mut stop_reason = "max_tokens".to_owned();
    let mut token_piece_buf = vec![0_u8; 128];
    let generate_start = Instant::now();

    for _ in 0..options.max_tokens {
        if linked_attempt_timed_out(attempt_start, job.max_attempt_ms) {
            return Err(ModelError::attempt_timeout());
        }
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
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
            stop_reason = "eog_token".to_owned();
            break;
        }

        unsafe {
            llama_cpp_sys_4::llama_sampler_accept(sampler.ptr, token);
        }
        generated_tokens += 1;
        let piece_start = output.len();
        linked_token_to_piece_into(cache.vocab, token, &mut token_piece_buf, &mut output);
        detailed_trace.observe(token, &output[piece_start..], sample);
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
        cache.kv_tokens.push(token);
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
            probability_summary: probability_trace.summary(),
            detailed_trace: detailed_trace.summary(&stop_reason),
            stop_reason,
        },
    })
}

fn linked_attempt_timed_out(start: Instant, max_attempt_ms: i64) -> bool {
    max_attempt_ms > 0 && start.elapsed().as_millis() >= max_attempt_ms as u128
}

fn linked_decode_threads(options: &crate::runtime::RuntimeOptions) -> i32 {
    if options.llama_threads > 0 {
        return options.llama_threads.min(i32::MAX as u64) as i32;
    }
    linked_default_decode_threads()
}

fn linked_batch_threads(options: &crate::runtime::RuntimeOptions, decode_threads: i32) -> i32 {
    if options.llama_batch_threads > 0 {
        return options.llama_batch_threads.min(i32::MAX as u64) as i32;
    }
    linked_env_i32("OTLET_LLAMA_BATCH_THREADS").unwrap_or(decode_threads)
}

fn linked_default_decode_threads() -> i32 {
    static DECODE_THREADS: OnceLock<i32> = OnceLock::new();
    *DECODE_THREADS.get_or_init(|| {
        if let Some(threads) = linked_env_usize("OTLET_LLAMA_THREADS") {
            return threads.min(i32::MAX as usize) as i32;
        }
        std::thread::available_parallelism()
            .map(|threads| threads.get())
            .unwrap_or(4)
            .min(LINKED_DEFAULT_MAX_DECODE_THREADS)
            .min(i32::MAX as usize) as i32
    })
}

fn linked_env_i32(name: &str) -> Option<i32> {
    linked_env_usize(name).map(|value| value.min(i32::MAX as usize) as i32)
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
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE") {
        if let Some(cache_type) = linked_ggml_type(&value) {
            params.type_k = cache_type;
            params.type_v = cache_type;
        }
    }
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE_K") {
        if let Some(cache_type) = linked_ggml_type(&value) {
            params.type_k = cache_type;
        }
    }
    if let Ok(value) = std::env::var("OTLET_LLAMA_KV_TYPE_V") {
        if let Some(cache_type) = linked_ggml_type(&value) {
            params.type_v = cache_type;
        }
    }
}

fn linked_ggml_type(value: &str) -> Option<llama_cpp_sys_4::ggml_type> {
    match value.to_ascii_lowercase().as_str() {
        "f16" => Some(llama_cpp_sys_4::GGML_TYPE_F16),
        "q8" | "q8_0" => Some(llama_cpp_sys_4::GGML_TYPE_Q8_0),
        "q4" | "q4_0" => Some(llama_cpp_sys_4::GGML_TYPE_Q4_0),
        _ => None,
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
) -> Result<(), ModelError> {
    let mut decoded_tokens = 0;
    for chunk in tokens.chunks(prompt_batch_tokens) {
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
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
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
            llama_cpp_sys_4::llama_memory_seq_rm(memory, 0, common as i32, -1)
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
        return Err(ModelError::clean_failure(
            "linked llama.cpp context window is invalid".to_owned(),
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
    model_fingerprint_hash: String,
    context: LinkedContext,
    _model: LinkedModel,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    /// Tokens known to occupy positions `0..len` of the context memory; used
    /// to reuse the KV cache for shared prompt prefixes across jobs.
    kv_tokens: Vec<llama_cpp_sys_4::llama_token>,
    load_ms: i64,
    ctx_ms: i64,
    model_memory_bytes: i64,
    model_parameters: i64,
    context_window_tokens: i64,
    model_device_policy: String,
    memory_accounting_policy: String,
}

unsafe impl Send for LinkedCache {}

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
        ModelError::clean_failure(
            "linked llama.cpp prompt is too large to tokenize".to_owned(),
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
    if capacity as u32 > LINKED_CONTEXT_WINDOW_TOKENS {
        return Err(ModelError::clean_failure(
            format!(
                "linked llama.cpp prompt has at least {capacity} tokens, exceeds context window {LINKED_CONTEXT_WINDOW_TOKENS}"
            ),
            "prompt_token_budget_before_generation",
            "prompt_exceeds_context_window",
        ));
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

fn linked_token_to_piece_into(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
    buffer: &mut Vec<u8>,
    output: &mut String,
) {
    buffer.resize(128, 0);
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
            return;
        };
        if required > LINKED_MAX_TOKEN_PIECE_BYTES {
            return;
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
    if size <= 0 {
        return;
    }
    buffer.truncate(size as usize);
    output.push_str(&String::from_utf8_lossy(buffer));
}

fn linked_token_to_piece(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
) -> String {
    let mut output = String::new();
    let mut buffer = vec![0_u8; 128];
    linked_token_to_piece_into(vocab, token, &mut buffer, &mut output);
    output
}

fn linked_clear_context(context: *mut llama_cpp_sys_4::llama_context) {
    unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if !memory.is_null() {
            llama_cpp_sys_4::llama_memory_clear(memory, true);
        }
    }
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
