struct LinkedRun {
    raw_output: String,
    metrics: ModelMetrics,
}

struct LinkedLoadEvidence {
    cache_hit: bool,
    memory_before: ProcessMemorySample,
    memory_admission: ModelLoadAdmission,
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
    prefix: Arc<str>,
    tokens: Arc<[llama_cpp_sys_4::llama_token]>,
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
            ModelError::new("linked llama.cpp batch capacity overflowed i32")
        })?;
        let value = unsafe { llama_cpp_sys_4::llama_batch_init(capacity_i32, 0, 1) };
        let batch = Self { value, capacity };
        if batch.value.token.is_null()
            || batch.value.pos.is_null()
            || batch.value.n_seq_id.is_null()
            || batch.value.seq_id.is_null()
            || batch.value.logits.is_null()
        {
            return Err(ModelError::new("linked llama.cpp batch allocation failed"));
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
            return Err(ModelError::new("linked llama.cpp batch token count is invalid"));
        }

        let index = usize::try_from(self.value.n_tokens).map_err(|_| {
            ModelError::new("linked llama.cpp batch token count overflowed usize")
        })?;
        if index >= self.capacity {
            return Err(ModelError::new(format!(
                "linked llama.cpp batch capacity exceeded: index {index} capacity {}",
                self.capacity
            )));
        }

        let seq_id = unsafe { *self.value.seq_id.add(index) };
        if seq_id.is_null() {
            return Err(ModelError::new("linked llama.cpp batch sequence slot is null"));
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
        .map_err(|_| ModelError::new("linked llama.cpp prompt contains null byte"))?;
    let text_len = i32::try_from(text.as_bytes().len()).map_err(|_| {
        ModelError::clean_failure(
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
        ModelError::new("linked llama.cpp prompt capacity overflowed usize")
    })?;
    let mut tokens = vec![0; capacity_usize];
    let tokens_len = i32::try_from(tokens.len()).map_err(|_| {
        ModelError::new("linked llama.cpp token buffer length overflowed i32")
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
        ModelError::new("linked llama.cpp tokenize result overflowed usize")
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
        return Err(ModelError::new("linked llama.cpp tokenize returned invalid token count"));
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
        ModelError::new("linked llama.cpp token piece buffer overflowed i32")
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
                ModelError::new("linked llama.cpp token piece size was invalid")
            })?;
        if required > LINKED_MAX_TOKEN_PIECE_BYTES {
            return Err(ModelError::new(format!(
                "linked llama.cpp token piece exceeded {LINKED_MAX_TOKEN_PIECE_BYTES} bytes"
            )));
        }
        buffer.resize(required, 0);
        let buffer_len = i32::try_from(buffer.len()).map_err(|_| {
            ModelError::new("linked llama.cpp token piece buffer overflowed i32")
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
        ModelError::new("linked llama.cpp token piece size overflowed usize")
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

fn linked_clear_context(context: *mut llama_cpp_sys_4::llama_context) {
    unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if !memory.is_null() {
            llama_cpp_sys_4::llama_memory_clear(memory, true);
        }
    }
}

