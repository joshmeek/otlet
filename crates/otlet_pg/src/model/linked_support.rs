pub(crate) struct ModelPreload {
    pub(crate) artifact_path: String,
    pub(crate) model_fingerprint_hash: String,
    pub(crate) load_ms: i64,
    pub(crate) ctx_ms: i64,
    pub(crate) model_memory_bytes: i64,
    pub(crate) model_parameters: i64,
    pub(crate) context_window_tokens: i64,
    pub(crate) model_device_policy: &'static str,
    pub(crate) memory_accounting_policy: &'static str,
    pub(crate) worker_process_rss_bytes: i64,
    pub(crate) worker_process_virtual_bytes: i64,
    pub(crate) worker_memory_sample_policy: &'static str,
    pub(crate) memory_trace: Value,
}

fn trim_model_output(output: String) -> String {
    if output.len() == output.trim().len() {
        output
    } else {
        output.trim().to_owned()
    }
}

fn linked_attempt_deadline(start: Instant, max_attempt_ms: i64) -> Option<Instant> {
    let milliseconds = u64::try_from(max_attempt_ms).ok().filter(|value| *value > 0)?;
    start.checked_add(Duration::from_millis(milliseconds))
}

fn linked_attempt_timed_out(deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|deadline| Instant::now() >= deadline)
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
struct CancelProbe {
    next_check: Instant,
}

impl CancelProbe {
    fn new() -> Self {
        Self {
            next_check: Instant::now() + Duration::from_millis(LINKED_CANCELLATION_SLICE_MS),
        }
    }

    fn due(&mut self) -> bool {
        let now = Instant::now();
        if now >= self.next_check {
            self.next_check = now + Duration::from_millis(LINKED_CANCELLATION_SLICE_MS);
            true
        } else {
            false
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

fn linked_cancel_requested(job_id: i64) -> Result<bool, ModelError> {
    match crate::infer_now::persist_timeout_cancel(job_id) {
        Ok(true) => return Ok(true),
        Ok(false) => {}
        Err(err) => return Err(ModelError::new(err)),
    }

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
                    return Ok(Err(ModelError::new(
                        "linked cancellation check: job row missing",
                    )));
                }

                match rows.first().get::<bool>(1)? {
                    Some(canceled) => Ok(Ok(canceled)),
                    None => Ok(Err(ModelError::new(
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
