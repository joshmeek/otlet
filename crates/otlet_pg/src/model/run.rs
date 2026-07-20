struct RunContext {
    prompt_hash: String,
    input_hash: String,
    output_schema_hash: String,
    runtime_options_hash: String,
    runtime_options_status: Value,
    model_fingerprint_hash: Arc<str>,
    runtime_fingerprint: Value,
    runtime_fingerprint_hash: String,
    runtime_output_contract_hash: String,
    decision_contract_hash: String,
    decision_preset_name: String,
    decision_preset_contract_hash: String,
    input_content_hash: String,
    inference_cache_contract_hash: String,
    inference_cache_key_basis: &'static str,
    cache_key: u64,
    content_cache_key: u64,
    contract_cache_key: u64,
    row_cache_key: u64,
    model_cache_key: u64,
    row_identity: String,
    mvcc: Value,
    shaped_input_bytes: i64,
    original_shaped_input_bytes: i64,
    max_shaped_input_bytes: i64,
    input_truncated: bool,
    input_shaping_applied: bool,
}

pub(crate) fn run_job(job: &Job) -> Result<ModelRun, ModelError> {
    run_job_with_model_ref(
        job,
        JobModelRef {
            name: job.model_name.as_str(),
            artifact_path: job.artifact_path.as_str(),
            artifact_hash: job.artifact_hash.as_deref(),
        },
    )
}

/// Run inference using an alternate model without cloning the full Job first.
pub(crate) fn run_job_with_model(job: &Job, model: &JobModel) -> Result<ModelRun, ModelError> {
    run_job_with_model_ref(
        job,
        JobModelRef {
            name: model.name.as_str(),
            artifact_path: model.artifact_path.as_str(),
            artifact_hash: model.artifact_hash.as_deref(),
        },
    )
}

fn run_job_with_model_ref(job: &Job, model: JobModelRef<'_>) -> Result<ModelRun, ModelError> {
    let prepare_started = Instant::now();
    let digests = task_contract_digests(job);
    let options = digests
        .runtime_options
        .as_ref()
        .map_err(|err| ModelError::new(err.clone()))?;
    let model_fingerprint_hash = model_fingerprint_hash(model);
    let runtime_fingerprint = runtime_fingerprint(model, &model_fingerprint_hash, options);
    // Cache keys use content/contract/model digests only — look up before
    // allocating shaped JSON or prompt strings. Hits stream the same hashes.
    let cache_probe = RunContext {
        prompt_hash: String::new(),
        input_hash: String::new(),
        output_schema_hash: digests.output_schema_hash.clone(),
        runtime_options_hash: digests.runtime_options_hash.clone(),
        runtime_options_status: digests.runtime_options_status.clone(),
        model_fingerprint_hash: Arc::clone(&model_fingerprint_hash),
        runtime_fingerprint: runtime_fingerprint.document,
        runtime_fingerprint_hash: runtime_fingerprint.hash,
        runtime_output_contract_hash: runtime_fingerprint.output_contract_hash,
        decision_contract_hash: digests.decision_contract_hash.clone(),
        decision_preset_name: digests.decision_preset_name.clone(),
        decision_preset_contract_hash: digests.decision_preset_contract_hash.clone(),
        input_content_hash: job.input_content_hash.clone(),
        inference_cache_contract_hash: digests.inference_cache_contract_hash.clone(),
        inference_cache_key_basis: "content_hash_contract_hash_runtime_output_contract_hash_model_fingerprint",
        cache_key: 0,
        content_cache_key: 0,
        contract_cache_key: 0,
        row_cache_key: 0,
        model_cache_key: 0,
        row_identity: input_mvcc_row_identity(&job.input, &job.subject_id),
        mvcc: input_mvcc_payload(&job.input),
        shaped_input_bytes: 0,
        original_shaped_input_bytes: 0,
        max_shaped_input_bytes: job
            .input
            .get("max_shaped_input_bytes")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        input_truncated: false,
        input_shaping_applied: true,
    };
    let content_cache_key = inference_cache_content_key(job, &cache_probe);
    let contract_cache_key = inference_cache_contract_key(&cache_probe);
    let row_cache_key = inference_cache_row_key(job);
    let model_cache_key = inference_cache_model_key(model, &cache_probe);
    let cache_key = inference_cache_key(content_cache_key, contract_cache_key, model_cache_key);

    let cache_lookup = if options.inference_cache && !options.generation_trace {
        inference_cache_get(
            cache_key,
            row_cache_key,
            content_cache_key,
            contract_cache_key,
            model_cache_key,
        )
    } else if options.generation_trace {
        CacheLookup::disabled_for("disabled_for_generation_trace")
    } else {
        CacheLookup::disabled_for("disabled")
    };

    enum RawOutput {
        Cached(Arc<str>),
        Generated(String),
    }

    impl RawOutput {
        fn as_str(&self) -> &str {
            match self {
                Self::Cached(value) => value.as_ref(),
                Self::Generated(value) => value.as_str(),
            }
        }

        fn into_owned(self) -> String {
            match self {
                Self::Cached(value) => value.to_string(),
                Self::Generated(value) => value,
            }
        }
    }

    let (raw_output, mut metrics, context, runtime_prepare_ms) = if let Some(raw_output) =
        cache_lookup.raw_output
    {
        // Trusted cache entry already passed schema validation when stored.
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled"));
        }
        let (prompt_hash, input_hash, shaped_bytes, original_bytes, input_truncated) =
            shaped_prompt_hashes_for_cache_hit(
                options,
                &digests.instruction,
                cached_rendered_schema(&job.output_schema, &digests.output_schema_hash).as_ref(),
                &job.input,
            );
        let context = RunContext {
            prompt_hash,
            input_hash,
            cache_key,
            content_cache_key,
            contract_cache_key,
            row_cache_key,
            model_cache_key,
            shaped_input_bytes: shaped_bytes,
            original_shaped_input_bytes: original_bytes,
            input_truncated,
            ..cache_probe
        };
        let worker_memory = if options.max_worker_rss_bytes > 0 {
            let sample = process_memory_sample();
            enforce_worker_rss_budget(&sample, options.max_worker_rss_bytes)?;
            sample
        } else {
            ProcessMemorySample {
                policy: "skipped_on_inference_cache_hit_no_rss_budget",
                ..ProcessMemorySample::default()
            }
        };
        let memory_admission = ModelLoadAdmission::not_required(
            "inference_cache_hit",
            options.max_worker_rss_bytes,
            &worker_memory,
        );
        let memory_trace = build_memory_trace(
            &worker_memory,
            &worker_memory,
            &memory_admission,
            options.max_worker_rss_bytes,
        );
        (
            RawOutput::Cached(raw_output),
            ModelMetrics {
                artifact_path: model.artifact_path.to_owned(),
                load_ms: 0,
                ctx_ms: 0,
                model_memory_bytes: 0,
                model_parameters: 0,
                context_window_tokens: 0,
                model_device_policy: "preserve_existing_on_inference_cache_hit",
                memory_accounting_policy: LINKED_MEMORY_ACCOUNTING_POLICY,
                worker_process_rss_bytes: worker_memory.rss_bytes,
                worker_process_virtual_bytes: worker_memory.virtual_bytes,
                worker_memory_sample_policy: worker_memory.policy,
                worker_memory_budget_bytes: u64_to_i64_saturating(options.max_worker_rss_bytes),
                memory_trace,
                prompt_tokens: 0,
                prompt_cached_tokens_before: 0,
                prompt_reused_tokens: 0,
                prompt_decoded_tokens: 0,
                prompt_reuse_strategy: "inference_cache_hit",
                prompt_prefix_state_bytes: 0,
                prompt_prefix_cache_entries: 0,
                prompt_prefix_cache_bytes: 0,
                effective_llama_threads: 0,
                effective_llama_batch_threads: 0,
                generated_tokens: 0,
                runtime_prepare_ms: 0,
                tokenize_ms: 0,
                prompt_decode_ms: 0,
                first_token_ms: 0,
                ttft_ms: 0,
                generate_ms: 0,
                postprocess_ms: 0,
                cache_hit: false,
                inference_cache_hit: true,
                inference_cache_entries: cache_lookup.stats.entries,
                inference_cache_bytes: cache_lookup.stats.bytes,
                inference_cache_max_entries: inference_cache_max_entries(),
                inference_cache_max_bytes: inference_cache_max_bytes(),
                inference_cache_evictions: cache_lookup.stats.evictions,
                inference_cache_eviction_reason: cache_lookup.stats.eviction_reason,
                inference_cache_invalidation_reason: cache_lookup.reason,
                probability_summary: probability_unavailable(
                    "inference_cache_hit_no_generation_logits",
                ),
                detailed_trace: detailed_trace_unavailable(
                    "inference_cache_hit_no_generation_logits",
                    options,
                ),
                stop_reason: "inference_cache_hit",
            },
            context,
            elapsed_ms(prepare_started),
        )
    } else {
        validate_output_schema(&job.output_schema, &digests.output_schema_hash).map_err(|err| {
            ModelError::clean_failure(
                err,
                "invalid_output_schema_before_generation",
                "invalid_output_schema",
            )
        })?;
        let rendered_schema =
            cached_rendered_schema(&job.output_schema, &digests.output_schema_hash);
        let prompt_prefix = cached_prompt_prefix(
            &digests,
            options,
            &digests.instruction,
            rendered_schema.as_ref(),
        );
        let shaped_prompt = shaped_model_prompt(&job.input, &prompt_prefix);
        let context = RunContext {
            prompt_hash: shaped_prompt.prompt_hash,
            input_hash: shaped_prompt.input_hash,
            cache_key,
            content_cache_key,
            contract_cache_key,
            row_cache_key,
            model_cache_key,
            shaped_input_bytes: shaped_prompt.bytes,
            original_shaped_input_bytes: shaped_prompt.original_bytes,
            input_truncated: shaped_prompt.input_truncated,
            ..cache_probe
        };
        let prompt = PromptParts {
            full: shaped_prompt.full,
            prefix: prompt_prefix,
        };
        let runtime_prepare_ms = elapsed_ms(prepare_started);
        let linked = run_linked(
            job,
            model,
            &prompt.full,
            &prompt.prefix,
            options,
            &context.model_fingerprint_hash,
        )
        .map_err(|mut err| {
            err.prompt_hash = Some(context.prompt_hash.clone());
            err.input_hash = Some(context.input_hash.clone());
            err.output_schema_hash = Some(context.output_schema_hash.clone());
            err
        })?;
        let mut metrics = linked.metrics;
        metrics.inference_cache_hit = false;
        metrics.inference_cache_invalidation_reason = cache_lookup.reason;
        (
            RawOutput::Generated(linked.raw_output),
            metrics,
            context,
            runtime_prepare_ms,
        )
    };
    metrics.runtime_prepare_ms = runtime_prepare_ms;
    let cache_enabled = options.inference_cache && !options.generation_trace;
    let raw_output_hash = hash_text(raw_output.as_str());
    let postprocess_started = Instant::now();

    macro_rules! fail_postprocess {
        ($message:expr) => {{
            metrics.postprocess_ms = elapsed_ms(postprocess_started);
            let trace_summary = generation_trace_summary(&context, &metrics, &raw_output_hash);
            return Err(ModelError::with_context(
                $message,
                raw_output.into_owned(),
                &context,
                trace_summary,
                raw_output_hash.clone(),
            )
            .with_metrics(metrics));
        }};
    }

    let mut json = match parse_model_json(raw_output.as_str()) {
        Ok(parsed) => parsed,
        Err(err) => fail_postprocess!(err),
    };
    let raw_json = raw_output.as_str().trim().to_owned();
    let Some(object) = json.as_object_mut() else {
        fail_postprocess!("model JSON must be an object".to_owned());
    };
    if object.keys().any(|key| key != "output" && key != "actions") {
        fail_postprocess!("model JSON has unsupported top-level key".to_owned());
    }
    let Some(output) = object.remove("output") else {
        fail_postprocess!("model JSON missing output".to_owned());
    };
    let Some(actions_value) = object.remove("actions") else {
        fail_postprocess!("model JSON missing actions".to_owned());
    };
    let actions = match model_actions(actions_value) {
        Ok(actions) => actions,
        Err(err) => fail_postprocess!(err),
    };
    if let Err(err) = validate_output(&job.output_schema, &digests.output_schema_hash, &output) {
        fail_postprocess!(err);
    }
    if cache_enabled && !metrics.inference_cache_hit {
        let stats = inference_cache_put(
            context.cache_key,
            context.row_cache_key,
            context.content_cache_key,
            context.contract_cache_key,
            context.model_cache_key,
            raw_output.into_owned(),
        );
        metrics.inference_cache_entries = stats.entries;
        metrics.inference_cache_bytes = stats.bytes;
        metrics.inference_cache_evictions = stats.evictions;
        metrics.inference_cache_eviction_reason = stats.eviction_reason;
        metrics.postprocess_ms = elapsed_ms(postprocess_started);
        let trace_summary = generation_trace_summary(&context, &metrics, &raw_output_hash);
        return Ok(ModelRun {
            output,
            raw_output: raw_json,
            actions,
            metrics: Some(metrics),
            prompt_hash: context.prompt_hash,
            input_hash: context.input_hash,
            output_schema_hash: context.output_schema_hash,
            raw_output_hash,
            trace_summary,
        });
    }
    metrics.postprocess_ms = elapsed_ms(postprocess_started);
    let trace_summary = generation_trace_summary(&context, &metrics, &raw_output_hash);
    Ok(ModelRun {
        output,
        raw_output: raw_json,
        actions,
        metrics: Some(metrics),
        prompt_hash: context.prompt_hash,
        input_hash: context.input_hash,
        output_schema_hash: context.output_schema_hash,
        raw_output_hash,
        trace_summary,
    })
}

