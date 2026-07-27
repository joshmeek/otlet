pub(crate) fn preload_model(
    model: &JobModel,
    runtime_options: &Value,
) -> Result<ModelPreload, ModelError> {
    let options = parse_runtime_options(runtime_options).map_err(ModelError::new)?;
    let model = JobModelRef {
        name: model.name.as_str(),
        artifact_path: model.artifact_path.as_str(),
        artifact_hash: model.artifact_hash.as_str(),
        artifact_identity: &model.artifact_identity,
    };
    let model_fingerprint_hash = model_fingerprint_hash(model);
    let cache = LINKED_CACHE.get_or_init(|| Mutex::new(None));
    let mut cache = cache
        .lock()
        .map_err(|_| ModelError::new("linked llama.cpp cache lock poisoned"))?;
    let load = ensure_linked_model(&mut cache, model, &options, &model_fingerprint_hash)?;
    let loaded = cache
        .as_ref()
        .ok_or_else(|| ModelError::new("linked llama.cpp cache did not initialize"))?;
    let memory_after = process_memory_sample();
    Ok(ModelPreload {
        artifact_path: loaded.artifact_path.clone(),
        model_fingerprint_hash: model_fingerprint_hash.to_string(),
        load_ms: if load.cache_hit { 0 } else { loaded.load_ms },
        ctx_ms: if load.cache_hit { 0 } else { loaded.ctx_ms },
        model_memory_bytes: loaded.model_memory_bytes,
        model_parameters: loaded.model_parameters,
        context_window_tokens: loaded.context_window_tokens,
        model_device_policy: loaded.model_device_policy,
        memory_accounting_policy: loaded.memory_accounting_policy,
        worker_process_rss_bytes: memory_after.rss_bytes,
        worker_process_virtual_bytes: memory_after.virtual_bytes,
        worker_memory_sample_policy: memory_after.policy,
        memory_trace: build_memory_trace(
            &load.memory_before,
            &memory_after,
            &load.memory_admission,
            options.max_worker_rss_bytes,
        ),
    })
}

fn ensure_linked_model(
    cache: &mut Option<LinkedCache>,
    job_model: JobModelRef<'_>,
    options: &crate::runtime::RuntimeOptions,
    model_fingerprint_hash: &str,
) -> Result<LinkedLoadEvidence, ModelError> {
    use std::ffi::CString;

    if job_model.artifact_path.starts_with("hf:") {
        return Err(ModelError::new("linked llama.cpp runtime requires a local GGUF artifact path"));
    }
    verify_model_artifact(job_model)?;
    LINKED_BACKEND.get_or_init(|| unsafe {
        llama_cpp_sys_4::llama_backend_init();
    });

    let cache_hit = cache.as_ref().is_some_and(|cached| {
        cached.artifact_path == job_model.artifact_path
            && cached.model_fingerprint_hash.as_ref() == model_fingerprint_hash
    });
    let memory_before = process_memory_sample();
    let memory_admission = if cache_hit {
        ModelLoadAdmission::not_required(
            "resident_model_reused",
            options.max_worker_rss_bytes,
            &memory_before,
        )
    } else {
        linked_model_load_admission(job_model.artifact_path, options, &memory_before)
    };
    if memory_admission.rejected() {
        let memory_after = process_memory_sample();
        let memory_trace = build_memory_trace(
            &memory_before,
            &memory_after,
            &memory_admission,
            options.max_worker_rss_bytes,
        );
        return Err(ModelError::clean_failure(
            format!(
                "linked model load admission rejected: reason={} artifact_bytes={} allowed_additional_bytes={} max_worker_rss_bytes={}",
                memory_admission.reason,
                memory_admission.artifact_bytes,
                memory_admission.allowed_additional_bytes,
                options.max_worker_rss_bytes
            ),
            "model_load_admission_before_tensor_load",
            "model_load_admission_rejected",
        )
        .with_memory_trace(memory_trace));
    }

    if !cache_hit {
        let model_path = CString::new(job_model.artifact_path.as_bytes())
            .map_err(|_| ModelError::new("linked llama.cpp model path is invalid"))?;
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
            return Err(ModelError::new("linked llama.cpp model load failed"));
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
            return Err(ModelError::new("linked llama.cpp context start failed"));
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
            return Err(ModelError::new("linked llama.cpp model has no vocab"));
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

    Ok(LinkedLoadEvidence {
        cache_hit,
        memory_before,
        memory_admission,
    })
}

fn linked_model_load_admission(
    artifact_path: &str,
    options: &crate::runtime::RuntimeOptions,
    sample: &ProcessMemorySample,
) -> ModelLoadAdmission {
    let artifact_bytes = fs::metadata(artifact_path)
        .ok()
        .map(|metadata| u64_to_i64_saturating(metadata.len()))
        .unwrap_or(0);
    let worker_budget_bytes = u64_to_i64_saturating(options.max_worker_rss_bytes);
    let worker_budget_headroom_bytes = worker_budget_bytes
        .saturating_sub(sample.rss_bytes)
        .max(0);
    let cgroup_headroom_bytes = cgroup_memory_headroom(sample);
    let mut admission = ModelLoadAdmission {
        decision: "not_required",
        reason: "unbounded_worker_rss_reporting_only",
        policy: "linked_llama_no_alloc_model_kv_batch_projection_v1",
        artifact_bytes,
        worker_budget_bytes,
        worker_budget_headroom_bytes,
        system_available_headroom_bytes: sample.system_memory_available_bytes,
        cgroup_headroom_bytes,
        allowed_additional_bytes: 0,
        projected_model_bytes: 0,
        projected_context_kv_bytes: 0,
        projected_batch_compute_bytes: 0,
        projected_total_bytes: 0,
        llama_projected_fit: false,
    };
    if options.max_worker_rss_bytes == 0 {
        return admission;
    }
    admission.decision = "rejected";
    if !sample.supports_preload_admission() {
        admission.reason = "required_linux_memory_sample_unavailable";
        return admission;
    }
    if artifact_bytes <= 0 {
        admission.reason = "model_artifact_metadata_unavailable";
        return admission;
    }
    if worker_budget_headroom_bytes <= 0 {
        admission.reason = "current_worker_rss_meets_or_exceeds_budget";
        return admission;
    }
    let mut allowed_additional_bytes = worker_budget_headroom_bytes
        .min(sample.system_memory_available_bytes)
        .min(sample.system_memory_total_bytes);
    if sample.cgroup_memory_max_bytes > 0 {
        allowed_additional_bytes = allowed_additional_bytes.min(cgroup_headroom_bytes);
    }
    admission.allowed_additional_bytes = allowed_additional_bytes.max(0);
    if admission.allowed_additional_bytes < artifact_bytes {
        admission.reason = "artifact_floor_exceeds_available_headroom";
        return admission;
    }

    let projection = linked_model_load_projection(artifact_path, artifact_bytes);
    let Ok(projection) = projection else {
        admission.reason = "llama_projection_error";
        return admission;
    };
    admission.projected_model_bytes = projection.model_bytes;
    admission.projected_context_kv_bytes = projection.context_kv_bytes;
    admission.projected_batch_compute_bytes = projection.batch_compute_bytes;
    admission.projected_total_bytes = projection.total_bytes;
    admission.llama_projected_fit = projection.total_bytes <= admission.allowed_additional_bytes;
    if admission.llama_projected_fit {
        admission.decision = "allowed";
        admission.reason = "llama_projected_model_kv_batch_fit";
    } else {
        admission.reason = "llama_projected_model_kv_batch_exceeds_headroom";
    }
    admission
}

struct LinkedModelLoadProjection {
    model_bytes: i64,
    context_kv_bytes: i64,
    batch_compute_bytes: i64,
    total_bytes: i64,
}

fn linked_model_load_projection(
    artifact_path: &str,
    artifact_bytes: i64,
) -> Result<LinkedModelLoadProjection, ()> {
    let model_path = std::ffi::CString::new(artifact_path.as_bytes()).map_err(|_| ())?;
    let mut model_params = unsafe { llama_cpp_sys_4::llama_model_default_params() };
    model_params.n_gpu_layers = 0;
    model_params.no_alloc = true;
    model_params.use_mmap = false;
    model_params.use_mlock = false;
    let model_ptr = unsafe {
        llama_cpp_sys_4::llama_model_load_from_file(model_path.as_ptr(), model_params)
    };
    if model_ptr.is_null() {
        return Err(());
    }
    let model = LinkedModel { ptr: model_ptr };
    let model_bytes = artifact_bytes.max(u64_to_i64_saturating(unsafe {
        llama_cpp_sys_4::llama_model_size(model.ptr)
    }));
    let layers = i64::from(unsafe { llama_cpp_sys_4::llama_model_n_layer(model.ptr) }).max(1);
    let embedding = i64::from(unsafe { llama_cpp_sys_4::llama_model_n_embd(model.ptr) }).max(1);
    let heads = i64::from(unsafe { llama_cpp_sys_4::llama_model_n_head(model.ptr) }).max(1);
    let kv_heads =
        i64::from(unsafe { llama_cpp_sys_4::llama_model_n_head_kv(model.ptr) }).max(1);
    let head_width = embedding.saturating_add(heads - 1) / heads;
    // Two f16-sized K/V buffers, conservative for the supported q8/q4 settings
    let context_kv_bytes = 2_i64
        .saturating_mul(layers)
        .saturating_mul(i64::from(LINKED_CONTEXT_WINDOW_TOKENS))
        .saturating_mul(head_width)
        .saturating_mul(kv_heads)
        .saturating_mul(2);
    // Estimate prompt-decode workspace as one f32 activation plane per layer
    let batch_compute_bytes = layers
        .saturating_mul(usize_to_i64_saturating(linked_prompt_ubatch_tokens(
            linked_prompt_batch_tokens(),
        )))
        .saturating_mul(embedding)
        .saturating_mul(4);
    Ok(LinkedModelLoadProjection {
        model_bytes,
        context_kv_bytes,
        batch_compute_bytes,
        total_bytes: model_bytes
            .saturating_add(context_kv_bytes)
            .saturating_add(batch_compute_bytes),
    })
}
