fn subject_state_count(
    subjects: &HashMap<String, SubjectSemanticState>,
    expected: SubjectSemanticState,
) -> u64 {
    subjects
        .values()
        .filter(|state| **state == expected)
        .count() as u64
}

unsafe fn snapshot_runtime_counters(
    state: *mut OtletSemanticCustomScanState,
    runtime: &RuntimeState,
) {
    unsafe {
        (*state).rows_seen = runtime.rows_seen;
        (*state).rows_returned = runtime.rows_returned;
        (*state).lookup_rows = runtime.lookup_rows;
        (*state).wait_resolved_rows = runtime.wait_resolved_rows;
        (*state).wait_returned_rows = runtime.wait_returned_rows;
        (*state).infer_resolved_rows = runtime.infer_resolved_rows;
        (*state).infer_returned_rows = runtime.infer_returned_rows;
        (*state).fail_closed_rows = runtime.fail_closed_rows;
        (*state).fresh_matches = runtime.fresh_matches;
        (*state).fresh_non_matches = runtime.fresh_non_matches;
        (*state).stale_rows = runtime.stale_rows;
        (*state).missing_rows = runtime.missing_rows;
        (*state).inflight_rows = runtime.inflight_rows;
        (*state).queued_refreshes = runtime.queued_refreshes;
        (*state).waited_refreshes = runtime.waited_refreshes;
        (*state).wait_elapsed_ms = runtime.wait_elapsed_ms;
        (*state).infer_now_batches = runtime.infer_now_batches;
        (*state).infer_now_ms = runtime.infer_now_ms;
        (*state).infer_now_request_wait_ms = runtime.infer_now_request_wait_ms;
        (*state).infer_now_start_latency_ms = runtime.infer_now_start_latency_ms;
        (*state).infer_now_worker_run_ms = runtime.infer_now_worker_run_ms;
        (*state).infer_now_timeouts = runtime.infer_now_timeouts;
        (*state).infer_now_abort_requests = runtime.infer_now_abort_requests;
        (*state).infer_now_cancel_job_id = runtime.infer_now_cancel_job_id;
        (*state).infer_now_failures = runtime.infer_now_failures;
        (*state).infer_now_last_error = pg_cstr(&runtime.infer_now_last_error);
        (*state).infer_prefetch_submissions = runtime.infer_prefetch_submissions;
        (*state).infer_prefetch_source_rows = runtime.infer_prefetch_source_rows;
        (*state).infer_buffered_rows = runtime.infer_buffered_rows;
        (*state).infer_slot_inputs = runtime.infer_slot_inputs;
        (*state).infer_spi_inputs = runtime.infer_spi_inputs;
        (*state).infer_receipts = runtime.infer_receipts;
        (*state).infer_failed_receipts = runtime.infer_failed_receipts;
        (*state).infer_failed_receipt_id = runtime.infer_failed_receipt_id;
        (*state).infer_outputs = runtime.infer_outputs;
        (*state).infer_actions = runtime.infer_actions;
        (*state).infer_materializations = runtime.infer_materializations;
        (*state).infer_trace_receipt_id = runtime.infer_trace_receipt_id;
        (*state).infer_trace_prompt_tokens = runtime.infer_trace_prompt_tokens;
        (*state).infer_trace_generated_tokens = runtime.infer_trace_generated_tokens;
        (*state).infer_trace_generate_ms = runtime.infer_trace_generate_ms;
        (*state).infer_trace_version = pg_cstr(&runtime.infer_trace_version);
        (*state).infer_trace_tokens_per_second = pg_cstr(&runtime.infer_trace_tokens_per_second);
        (*state).infer_trace_probability_status = pg_cstr(&runtime.infer_trace_probability_status);
        (*state).infer_trace_probability_method = pg_cstr(&runtime.infer_trace_probability_method);
        (*state).infer_trace_schema_force = pg_cstr(&runtime.infer_trace_schema_force);
        (*state).infer_trace_worker_rss_bytes = runtime.infer_trace_worker_rss_bytes;
        (*state).infer_trace_worker_virtual_bytes = runtime.infer_trace_worker_virtual_bytes;
        (*state).infer_trace_worker_memory_policy =
            pg_cstr(&runtime.infer_trace_worker_memory_policy);
        (*state).infer_trace_model_cache_hits = runtime.infer_trace_model_cache_hits;
        (*state).infer_trace_model_cache_misses = runtime.infer_trace_model_cache_misses;
        (*state).infer_trace_inference_cache_hits = runtime.infer_trace_inference_cache_hits;
        (*state).infer_trace_inference_cache_misses = runtime.infer_trace_inference_cache_misses;
        (*state).infer_trace_inference_cache_entries = runtime.infer_trace_inference_cache_entries;
        (*state).infer_trace_inference_cache_bytes = runtime.infer_trace_inference_cache_bytes;
        (*state).infer_trace_inference_cache_evictions =
            runtime.infer_trace_inference_cache_evictions;
        (*state).infer_trace_inference_cache_reason =
            pg_cstr(&runtime.infer_trace_inference_cache_reason);
        (*state).infer_trace_detailed_status = pg_cstr(&runtime.infer_trace_detailed_status);
        (*state).infer_trace_detailed_captured_tokens =
            runtime.infer_trace_detailed_captured_tokens;
        (*state).infer_trace_detailed_skipped_tokens = runtime.infer_trace_detailed_skipped_tokens;
        (*state).infer_trace_detailed_top_k = runtime.infer_trace_detailed_top_k;
        (*state).child_plan_rows = runtime.child_plan_rows;
        (*state).direct_scan_rows = runtime.direct_scan_rows;
        (*state).subject_state_refreshes = runtime.subject_state_refreshes;
        (*state).semantic_cache_hits = runtime.semantic_cache_hits;
        (*state).semantic_cache_misses = runtime.semantic_cache_misses;
    }
}
