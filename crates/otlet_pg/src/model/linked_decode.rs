fn run_linked(
    job: &Job,
    job_model: JobModelRef<'_>,
    prompt: &str,
    prompt_prefix: &str,
    options: &crate::runtime::RuntimeOptions,
    model_fingerprint_hash: &str,
) -> Result<LinkedRun, ModelError> {
    let attempt_start = Instant::now();
    let attempt_deadline = linked_attempt_deadline(attempt_start, job.max_attempt_ms);
    let cache = LINKED_CACHE.get_or_init(|| Mutex::new(None));
    let mut cache = cache
        .lock()
        .map_err(|_| ModelError::new("linked llama.cpp cache lock poisoned"))?;
    let load = ensure_linked_model(&mut cache, job_model, options, model_fingerprint_hash)?;
    let cache_hit = load.cache_hit;
    let memory_before = load.memory_before;
    let memory_admission = load.memory_admission;

    let cache = cache
        .as_mut()
        .ok_or_else(|| ModelError::new("linked llama.cpp cache did not initialize"))?;
    let decode_threads = linked_decode_threads(options);
    let batch_threads = linked_batch_threads(options, decode_threads);
    unsafe {
        llama_cpp_sys_4::llama_set_n_threads(cache.context.ptr, decode_threads, batch_threads);
    }
    let tokenize_start = Instant::now();
    let tokens = tokenize_linked(cache.vocab, prompt)?;
    let prompt_prefix_hash = if !prompt_prefix.is_empty() && prompt.starts_with(prompt_prefix) {
        Some(hash_text(prompt_prefix))
    } else {
        None
    };
    let prompt_prefix_tokens = if let Some(hash) = prompt_prefix_hash.as_deref() {
        if let Some(tokens) =
            linked_cached_prompt_prefix_tokens(&mut cache.prompt_prefix_states, hash, prompt_prefix)
        {
            tokens
        } else {
            Arc::from(tokenize_linked(cache.vocab, prompt_prefix)?)
        }
    } else {
        Arc::from(Vec::new())
    };
    let tokenize_ms = elapsed_ms(tokenize_start);
    if tokens.is_empty() {
        return Err(ModelError::new("linked llama.cpp prompt produced no tokens"));
    }

    validate_linked_token_budget(tokens.len(), options.max_tokens, cache.context_window_tokens)?;

    if options.max_worker_rss_bytes > 0 {
        let resident_memory = process_memory_sample();
        if let Err(err) =
            enforce_worker_rss_budget(&resident_memory, options.max_worker_rss_bytes)
        {
            return Err(err.with_memory_trace(build_memory_trace(
                &memory_before,
                &resident_memory,
                &memory_admission,
                options.max_worker_rss_bytes,
            )));
        }
    }

    if linked_cancel_requested(job.id)? {
        return Err(ModelError::new("canceled"));
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
        .ok_or_else(|| ModelError::new("linked llama.cpp batch did not initialize"))?;
    batch.reset();
    let mut prompt_reused_tokens = 0;
    let mut prompt_decoded_tokens = tokens.len();
    let mut prompt_reuse_strategy: &'static str = "full_prompt_decode";
    let mut prompt_prefix_state_bytes = 0_i64;
    let prefix_reusable = linked_prompt_prefix_reusable(&tokens, &prompt_prefix_tokens);
    if prefix_reusable {
        let prompt_prefix_hash = prompt_prefix_hash
            .as_deref()
            .expect("reusable prompt prefix has a hash");
        if let Some(state_bytes) =
            linked_restore_prompt_prefix_state(cache, prompt_prefix_hash, &prompt_prefix_tokens)
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
            let saved_prefix = linked_save_prompt_prefix_state(
                cache,
                prompt_prefix_hash,
                prompt_prefix,
                Arc::clone(&prompt_prefix_tokens),
            );
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
        return Err(ModelError::new("linked llama.cpp sampler start failed"));
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
    let mut alternative_piece_output = Vec::new();
    let mut first_token_ms = 0_i64;
    let mut first_token_seen = false;
    let generate_start = Instant::now();

    if linked_attempt_timed_out(attempt_deadline) {
        return Err(ModelError::attempt_timeout());
    }
    for _ in 0..options.max_tokens {
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled"));
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
                    &mut token_piece_buf,
                    &mut alternative_piece_output,
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
        detailed_trace.observe(token, &output[piece_start..], sample);
        if let Some(end) = json_completion.observe(&output[piece_start..]) {
            output.truncate(end);
            stop_reason = "json_complete";
            break;
        }

        batch.reset();
        batch.add(
            token,
            i32::try_from(position).map_err(|_| {
                ModelError::new("linked llama.cpp generation position overflowed i32")
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
        if linked_attempt_timed_out(attempt_deadline) {
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
    if let Err(err) = enforce_worker_rss_budget(&worker_memory, options.max_worker_rss_bytes) {
        return Err(err.with_memory_trace(build_memory_trace(
            &memory_before,
            &worker_memory,
            &memory_admission,
            options.max_worker_rss_bytes,
        )));
    }
    let memory_trace = build_memory_trace(
        &memory_before,
        &worker_memory,
        &memory_admission,
        options.max_worker_rss_bytes,
    );
    let output = String::from_utf8(output).map_err(|err| {
        ModelError::new(format!(
            "linked llama.cpp output was not valid UTF-8: {}",
            err.utf8_error()
        ))
    })?;
    let output = trim_model_output(output);

    Ok(LinkedRun {
        raw_output: output,
        metrics: ModelMetrics {
            artifact_path: cache.artifact_path.clone(),
            load_ms: cache.load_ms,
            ctx_ms: cache.ctx_ms,
            model_memory_bytes: cache.model_memory_bytes,
            model_parameters: cache.model_parameters,
            context_window_tokens: cache.context_window_tokens,
            model_device_policy: cache.model_device_policy,
            memory_accounting_policy: cache.memory_accounting_policy,
            worker_process_rss_bytes: worker_memory.rss_bytes,
            worker_process_virtual_bytes: worker_memory.virtual_bytes,
            worker_memory_sample_policy: worker_memory.policy,
            worker_memory_budget_bytes: u64_to_i64_saturating(options.max_worker_rss_bytes),
            memory_trace,
            prompt_tokens: usize_to_i64_saturating(tokens.len()),
            prompt_cached_tokens_before: usize_to_i64_saturating(prompt_cached_tokens_before),
            prompt_reused_tokens: usize_to_i64_saturating(prompt_reused_tokens),
            prompt_decoded_tokens: usize_to_i64_saturating(prompt_decoded_tokens),
            prompt_reuse_strategy,
            prompt_prefix_state_bytes,
            prompt_prefix_cache_entries: usize_to_i64_saturating(cache.prompt_prefix_states.len()),
            prompt_prefix_cache_bytes: usize_to_i64_saturating(
                linked_prompt_prefix_cache_bytes(&cache.prompt_prefix_states),
            ),
            effective_llama_threads: i64::from(decode_threads),
            effective_llama_batch_threads: i64::from(batch_threads),
            generated_tokens,
            runtime_prepare_ms: 0,
            tokenize_ms,
            prompt_decode_ms,
            first_token_ms,
            ttft_ms,
            generate_ms,
            postprocess_ms: 0,
            cache_hit,
            inference_cache_hit: false,
            inference_cache_entries: 0,
            inference_cache_bytes: 0,
            inference_cache_max_entries: inference_cache_max_entries(),
            inference_cache_max_bytes: inference_cache_max_bytes(),
            inference_cache_evictions: 0,
            inference_cache_eviction_reason: "none",
            inference_cache_invalidation_reason: "miss",
            probability_summary: probability_trace.summary(),
            detailed_trace: detailed_trace.summary(stop_reason),
            stop_reason,
        },
    })
}

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
                    ModelError::new("linked llama.cpp prompt position overflowed i32")
                })?,
                final_logits && decoded_tokens + chunk_index + 1 == tokens.len(),
            )?;
        }
        if cancel_probe.due() && linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled"));
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
fn validate_linked_token_budget(
    prompt_tokens: usize,
    max_tokens: u64,
    context_window_tokens: i64,
) -> Result<(), ModelError> {
    let Ok(context_window_tokens) = usize::try_from(context_window_tokens) else {
        return Err(ModelError::clean_failure(
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

