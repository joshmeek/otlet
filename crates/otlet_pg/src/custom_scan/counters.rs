fn subject_state_count(
    subjects: &HashMap<String, SubjectSemanticState>,
    expected: SubjectSemanticState,
) -> u64 {
    subjects
        .values()
        .filter(|state| **state == expected)
        .count() as u64
}

fn record_emitted_freshness_basis(runtime: &mut RuntimeState, subject_id: &str) {
    let basis = runtime
        .subject_freshness_basis
        .get(subject_id)
        .map_or("runtime_refresh", String::as_str);
    *runtime
        .emitted_freshness_basis
        .entry(basis.to_owned())
        .or_insert(0) += 1;
}

unsafe fn snapshot_runtime_counters(
    state: *mut OtletSemanticCustomScanState,
    runtime: &RuntimeState,
) {
    unsafe {
        (*state).rows_seen = runtime.rows_seen;
        (*state).rows_returned = runtime.rows_returned;
        (*state).lookup_rows = runtime.lookup_rows;
        (*state).infer_resolved_rows = runtime.infer_resolved_rows;
        (*state).infer_returned_rows = runtime.infer_returned_rows;
        (*state).fail_closed_rows = runtime.fail_closed_rows;
        (*state).fresh_matches = runtime.fresh_matches;
        (*state).fresh_non_matches = runtime.fresh_non_matches;
        (*state).stale_rows = runtime.stale_rows;
        (*state).missing_rows = runtime.missing_rows;
        (*state).inflight_rows = runtime.inflight_rows;
        (*state).queued_refreshes = runtime.queued_refreshes;
        (*state).infer_now_batches = runtime.infer_now_batches;
        (*state).infer_now_ms = runtime.infer_now_ms;
        (*state).infer_now_timeouts = runtime.infer_now_timeouts;
        (*state).infer_now_failures = runtime.infer_now_failures;
        (*state).infer_now_last_error = pg_cstr(&runtime.infer_now_last_error);
        (*state).infer_receipts = runtime.infer_receipts;
        (*state).infer_failed_receipts = runtime.infer_failed_receipts;
        (*state).infer_failed_receipt_id = runtime.infer_failed_receipt_id;
        (*state).infer_trace_receipt_id = runtime.infer_trace_receipt_id;
        (*state).infer_trace_prompt_tokens = runtime.infer_trace_prompt_tokens;
        (*state).infer_trace_generated_tokens = runtime.infer_trace_generated_tokens;
        (*state).infer_trace_generate_ms = runtime.infer_trace_generate_ms;
        (*state).infer_trace_version = pg_cstr(&runtime.infer_trace_version);
        (*state).infer_trace_probability_status = pg_cstr(&runtime.infer_trace_probability_status);
        (*state).infer_trace_schema_force = pg_cstr(&runtime.infer_trace_schema_force);
        (*state).infer_trace_detailed_status = pg_cstr(&runtime.infer_trace_detailed_status);
        (*state).infer_trace_detailed_captured_tokens =
            runtime.infer_trace_detailed_captured_tokens;
        (*state).infer_trace_detailed_top_k = runtime.infer_trace_detailed_top_k;
        (*state).child_plan_rows = runtime.child_plan_rows;
        (*state).emitted_freshness_basis =
            pg_cstr(&freshness_basis_counts_json(&runtime.emitted_freshness_basis));
    }
}
