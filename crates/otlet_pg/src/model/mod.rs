#![allow(clippy::result_large_err)]

use crate::job::{Job, JobModel, JobModelRef};
use crate::runtime::{parse_runtime_options, runtime_option_status};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};

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
    pub(crate) model_device_policy: &'static str,
    pub(crate) memory_accounting_policy: &'static str,
    pub(crate) worker_process_rss_bytes: i64,
    pub(crate) worker_process_virtual_bytes: i64,
    pub(crate) worker_memory_sample_policy: &'static str,
    pub(crate) worker_memory_budget_bytes: i64,
    pub(crate) memory_trace: Value,
    pub(crate) prompt_tokens: i64,
    pub(crate) prompt_cached_tokens_before: i64,
    pub(crate) prompt_reused_tokens: i64,
    pub(crate) prompt_decoded_tokens: i64,
    pub(crate) prompt_reuse_strategy: &'static str,
    pub(crate) prompt_prefix_state_bytes: i64,
    pub(crate) prompt_prefix_cache_entries: i64,
    pub(crate) prompt_prefix_cache_bytes: i64,
    pub(crate) effective_llama_threads: i64,
    pub(crate) effective_llama_batch_threads: i64,
    pub(crate) generated_tokens: i64,
    pub(crate) runtime_prepare_ms: i64,
    pub(crate) tokenize_ms: i64,
    pub(crate) prompt_decode_ms: i64,
    pub(crate) first_token_ms: i64,
    pub(crate) ttft_ms: i64,
    pub(crate) generate_ms: i64,
    pub(crate) postprocess_ms: i64,
    pub(crate) cache_hit: bool,
    pub(crate) inference_cache_hit: bool,
    pub(crate) inference_cache_entries: i64,
    pub(crate) inference_cache_bytes: i64,
    pub(crate) inference_cache_max_entries: i64,
    pub(crate) inference_cache_max_bytes: i64,
    pub(crate) inference_cache_evictions: i64,
    pub(crate) inference_cache_eviction_reason: &'static str,
    pub(crate) inference_cache_invalidation_reason: &'static str,
    pub(crate) probability_summary: Value,
    pub(crate) detailed_trace: Value,
    pub(crate) stop_reason: &'static str,
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
    pub(crate) metrics: Option<Box<ModelMetrics>>,
}

impl ModelError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            raw_output: None,
            prompt_hash: None,
            input_hash: None,
            output_schema_hash: None,
            raw_output_hash: None,
            schema_validation_status: None,
            trace_summary: None,
            metrics: None,
        }
    }

    fn attempt_timeout() -> Self {
        let mut err = Self::new("attempt_timeout");
        err.schema_validation_status = Some("failed".to_owned());
        err.trace_summary = Some(json!({
            "trace_version": "otlet_generation_trace_v1",
            "schema_validation_status": "failed",
            "schema_force": "attempt_timeout_before_schema_validation",
            "stop_reason": "attempt_timeout"
        }));
        err
    }

    fn clean_failure(message: impl Into<String>, schema_force: &str, stop_reason: &str) -> Self {
        let mut err = Self::new(message);
        err.schema_validation_status = Some("failed".to_owned());
        err.trace_summary = Some(json!({
            "trace_version": "otlet_generation_trace_v1",
            "schema_validation_status": "failed",
            "schema_force": schema_force,
            "stop_reason": stop_reason
        }));
        err
    }

    fn with_context(
        message: String,
        raw_output: String,
        context: &RunContext,
        trace_summary: Value,
        raw_output_hash: String,
    ) -> Self {
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
            metrics: None,
        }
    }

    fn with_metrics(mut self, metrics: ModelMetrics) -> Self {
        self.metrics = Some(Box::new(metrics));
        self
    }

    fn with_memory_trace(mut self, memory_trace: Value) -> Self {
        if let Some(Value::Object(trace)) = &mut self.trace_summary {
            trace.insert("memory".to_owned(), memory_trace);
        }
        self
    }
}

include!("run.rs");
include!("prompt_contracts.rs");
include!("trace.rs");
include!("artifact.rs");
include!("linked_support.rs");
include!("linked_load.rs");
include!("linked_decode.rs");
include!("linked_prefix_cache.rs");
include!("linked_ffi.rs");
include!("linked_tests.rs");
include!("cache.rs");
include!("cache_tests.rs");
include!("memory.rs");
include!("response.rs");
include!("fingerprint.rs");
