use crate::job::Job;
use crate::runtime::{parse_runtime_options, runtime_option_status};
use serde_json::{Value, json};
use std::fs;
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, UNIX_EPOCH};

pub(crate) struct ModelRun {
    pub(crate) output: Value,
    pub(crate) raw_output: String,
    pub(crate) actions: Value,
    pub(crate) metrics: Option<ModelMetrics>,
    pub(crate) prompt_hash: String,
    pub(crate) input_hash: String,
    pub(crate) output_schema_hash: String,
    pub(crate) raw_output_hash: String,
    pub(crate) trace_summary: Value,
}

pub(crate) struct ModelMetrics {
    pub(crate) artifact_path: String,
    pub(crate) load_ms: i64,
    pub(crate) ctx_ms: i64,
    pub(crate) model_memory_bytes: i64,
    pub(crate) model_parameters: i64,
    pub(crate) context_window_tokens: i64,
    pub(crate) model_device_policy: String,
    pub(crate) memory_accounting_policy: String,
    pub(crate) worker_process_rss_bytes: i64,
    pub(crate) worker_process_virtual_bytes: i64,
    pub(crate) worker_memory_sample_policy: String,
    pub(crate) worker_memory_budget_bytes: i64,
    pub(crate) worker_memory_budget_policy: String,
    pub(crate) prompt_tokens: i64,
    pub(crate) generated_tokens: i64,
    pub(crate) generate_ms: i64,
    pub(crate) cache_hit: bool,
    pub(crate) inference_cache_hit: bool,
    pub(crate) inference_cache_entries: i64,
    pub(crate) inference_cache_bytes: i64,
    pub(crate) inference_cache_evictions: i64,
    pub(crate) inference_cache_invalidation_reason: String,
    pub(crate) probability_summary: Value,
    pub(crate) detailed_trace: Value,
    pub(crate) stop_reason: String,
}

pub(crate) struct ModelError {
    pub(crate) message: String,
    pub(crate) raw_output: Option<String>,
    pub(crate) prompt_hash: Option<String>,
    pub(crate) input_hash: Option<String>,
    pub(crate) output_schema_hash: Option<String>,
    pub(crate) raw_output_hash: Option<String>,
    pub(crate) schema_validation_status: Option<String>,
    pub(crate) trace_summary: Option<Value>,
}

impl ModelError {
    fn new(message: String) -> Self {
        Self {
            message,
            raw_output: None,
            prompt_hash: None,
            input_hash: None,
            output_schema_hash: None,
            raw_output_hash: None,
            schema_validation_status: None,
            trace_summary: None,
        }
    }

    fn with_context(
        message: String,
        raw_output: String,
        context: &RunContext,
        trace_summary: Value,
    ) -> Self {
        let raw_output_hash = hash_text(&raw_output);
        let mut trace_summary = trace_summary;
        if let Value::Object(object) = &mut trace_summary {
            object.insert(
                "schema_validation_status".to_owned(),
                Value::String("failed".to_owned()),
            );
            object.insert(
                "schema_force".to_owned(),
                Value::String("post_generation_json_schema_validation_failed".to_owned()),
            );
            object.insert(
                "stop_reason".to_owned(),
                Value::String("schema_or_json_validation_failed".to_owned()),
            );
        }
        Self {
            message,
            raw_output: Some(raw_output),
            prompt_hash: Some(context.prompt_hash.clone()),
            input_hash: Some(context.input_hash.clone()),
            output_schema_hash: Some(context.output_schema_hash.clone()),
            raw_output_hash: Some(raw_output_hash),
            schema_validation_status: Some("failed".to_owned()),
            trace_summary: Some(trace_summary),
        }
    }
}

struct RunContext {
    prompt_hash: String,
    input_hash: String,
    output_schema_hash: String,
    runtime_options_hash: String,
    runtime_options_status: Value,
    model_fingerprint_hash: String,
    cache_key: String,
    row_cache_key: String,
    model_cache_key: String,
    row_identity: String,
    mvcc: Value,
}

pub(crate) fn run_job(job: &Job) -> Result<ModelRun, ModelError> {
    let options = parse_runtime_options(&job.runtime_options).map_err(ModelError::new)?;
    validate_output_schema(&job.output_schema).map_err(ModelError::new)?;
    let prompt = format!(
        "{}You are a Postgres-local data review worker.\nReturn one valid JSON object. No prose. No markdown.\nThe JSON object must have top-level \"output\" and \"actions\" keys.\n\"output\" must satisfy Output schema and use only values allowed by that schema.\n\"actions\" must be an array. Use [] when no action is needed.\nNever put actions inside \"output\".\nIf any issue is found, set output.needs_review to true and output.status to \"needs_review\" when allowed.\n\nInstruction:\n{}\n\nOutput schema:\n{}\n\nInput:\n{}",
        if options.reasoning == "off" {
            "/no_think "
        } else {
            ""
        },
        job.instruction,
        job.output_schema,
        job.input
    );
    let context = RunContext {
        prompt_hash: hash_text(&prompt),
        input_hash: hash_json(&job.input),
        output_schema_hash: hash_json(&job.output_schema),
        runtime_options_hash: hash_json(&job.runtime_options),
        runtime_options_status: runtime_option_status(&job.runtime_options),
        model_fingerprint_hash: hash_text(&model_fingerprint(job)),
        cache_key: String::new(),
        row_cache_key: String::new(),
        model_cache_key: String::new(),
        row_identity: input_mvcc_row_identity(&job.input, &job.subject_id),
        mvcc: input_mvcc_payload(&job.input),
    };
    let context = RunContext {
        cache_key: inference_cache_key(job, &context),
        row_cache_key: inference_cache_row_key(job),
        model_cache_key: inference_cache_model_key(job, &context),
        ..context
    };

    if job.runtime_endpoint != "linked" {
        return Err(ModelError::new(format!(
            "otlet only supports linked in-process inference; runtime endpoint {} is not supported",
            job.runtime_endpoint
        )));
    }

    let cache_lookup = if options.inference_cache && !options.generation_trace {
        inference_cache_get(
            &context.cache_key,
            &context.row_cache_key,
            &context.model_cache_key,
        )
    } else if options.generation_trace {
        CacheLookup::disabled_for("disabled_for_generation_trace")
    } else {
        CacheLookup::disabled()
    };

    let (raw_output, mut metrics) = if let Some(raw_output) = cache_lookup.raw_output {
        if linked_cancel_requested(job.id)? {
            return Err(ModelError::new("canceled".to_owned()));
        }
        let worker_memory = process_memory_sample();
        enforce_worker_rss_budget(&worker_memory, options.max_worker_rss_bytes)?;
        (
            raw_output,
            ModelMetrics {
                artifact_path: job.artifact_path.clone(),
                load_ms: 0,
                ctx_ms: 0,
                model_memory_bytes: 0,
                model_parameters: 0,
                context_window_tokens: 0,
                model_device_policy: "preserve_existing_on_inference_cache_hit".to_owned(),
                memory_accounting_policy: LINKED_MEMORY_ACCOUNTING_POLICY.to_owned(),
                worker_process_rss_bytes: worker_memory.rss_bytes,
                worker_process_virtual_bytes: worker_memory.virtual_bytes,
                worker_memory_sample_policy: worker_memory.policy,
                worker_memory_budget_bytes: u64_to_i64_saturating(options.max_worker_rss_bytes),
                worker_memory_budget_policy: worker_memory_budget_policy(
                    options.max_worker_rss_bytes,
                )
                .to_owned(),
                prompt_tokens: 0,
                generated_tokens: 0,
                generate_ms: 0,
                cache_hit: false,
                inference_cache_hit: true,
                inference_cache_entries: cache_lookup.stats.entries,
                inference_cache_bytes: cache_lookup.stats.bytes,
                inference_cache_evictions: cache_lookup.stats.evictions,
                inference_cache_invalidation_reason: cache_lookup.reason,
                probability_summary: probability_unavailable(
                    "inference_cache_hit_no_generation_logits",
                ),
                detailed_trace: detailed_trace_unavailable(
                    "inference_cache_hit_no_generation_logits",
                    &options,
                ),
                stop_reason: "inference_cache_hit".to_owned(),
            },
        )
    } else {
        let linked = run_linked(job, &prompt, &options).map_err(|mut err| {
            err.prompt_hash = Some(context.prompt_hash.clone());
            err.input_hash = Some(context.input_hash.clone());
            err.output_schema_hash = Some(context.output_schema_hash.clone());
            err
        })?;
        let mut metrics = linked.metrics;
        metrics.inference_cache_hit = false;
        metrics.inference_cache_invalidation_reason = cache_lookup.reason;
        (linked.raw_output, metrics)
    };
    let cache_enabled = options.inference_cache && !options.generation_trace;
    let raw_output_hash = hash_text(&raw_output);
    let trace_summary = generation_trace_summary(&context, &metrics, &raw_output_hash);

    let (json, raw_json) = parse_model_json(raw_output.as_str()).map_err(|err| {
        ModelError::with_context(err, raw_output.clone(), &context, trace_summary.clone())
    })?;
    let json = normalize_model_envelope(json).map_err(|err| {
        ModelError::with_context(err, raw_output.clone(), &context, trace_summary.clone())
    })?;
    let output = json.get("output").cloned().ok_or_else(|| {
        ModelError::with_context(
            "model JSON missing output".to_owned(),
            raw_output.clone(),
            &context,
            trace_summary.clone(),
        )
    })?;
    let actions = model_actions(&json).map_err(|err| {
        ModelError::with_context(err, raw_output.clone(), &context, trace_summary.clone())
    })?;
    validate_output(&job.output_schema, &output).map_err(|err| {
        ModelError::with_context(err, raw_output.clone(), &context, trace_summary.clone())
    })?;

    if cache_enabled && !metrics.inference_cache_hit {
        let stats = inference_cache_put(
            context.cache_key.clone(),
            context.row_cache_key.clone(),
            context.model_cache_key.clone(),
            raw_output.clone(),
        );
        metrics.inference_cache_entries = stats.entries;
        metrics.inference_cache_bytes = stats.bytes;
        metrics.inference_cache_evictions = stats.evictions;
    }
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

static LINKED_BACKEND: OnceLock<()> = OnceLock::new();

static LINKED_CACHE: OnceLock<Mutex<Option<LinkedCache>>> = OnceLock::new();

static INFERENCE_CACHE: OnceLock<Mutex<InferenceCache>> = OnceLock::new();

const INFERENCE_CACHE_MAX_ENTRIES: usize = 128;
const INFERENCE_CACHE_MAX_BYTES: usize = 1024 * 1024;
const PROBABILITY_TRACE_MAX_TOKENS: i64 = 64;
const DETAILED_TRACE_CONTRACT: &str = "receipt_trace_v2_bounded_token_steps";
const DETAILED_TRACE_STORAGE_POLICY: &str =
    "off_by_default_bounded_jsonb_in_receipt_no_unbounded_prompt_or_logit_blob_cache";
const LINKED_CANCELLATION_CHECK_INTERVAL_TOKENS: i64 = 1;
const LINKED_CANCELLATION_POLICY: &str =
    "cooperative_before_prompt_decode_after_prompt_decode_and_each_generated_token";
const LINKED_PROMPT_DECODE_CANCELLATION_BOUNDARY: &str =
    "llama_decode_blocking_checked_before_and_after";
const LINKED_CONTEXT_WINDOW_TOKENS: u32 = 4096;
const LINKED_PROMPT_BATCH_TOKENS: usize = 512;
const LINKED_MAX_TOKEN_PIECE_BYTES: usize = 16 * 1024;
const LINKED_MODEL_DEVICE_POLICY: &str = "cpu_only_n_gpu_layers_0";
const LINKED_MEMORY_ACCOUNTING_POLICY: &str = "llama_model_size_measured_context_window_measured_inference_cache_bytes_measured_no_prompt_token_blob_storage";

include!("trace.rs");
include!("linked.rs");
include!("cache.rs");
include!("output.rs");
