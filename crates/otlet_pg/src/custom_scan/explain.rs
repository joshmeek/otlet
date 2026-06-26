#[pgrx::pg_guard]
unsafe extern "C-unwind" fn explain_semantic_custom_scan(
    node: *mut pg_sys::CustomScanState,
    _ancestors: *mut pg_sys::List,
    es: *mut pg_sys::ExplainState,
) {
    unsafe {
        explain_text("Otlet Node", "Semantic Source CustomScan", es);
        explain_text("Semantic Predicate Owner", "otlet_customscan_executor", es);
        explain_text("Child Semantic Filter", "stripped_before_child_plan", es);
        let state = node as *mut OtletSemanticCustomScanState;
        if !(*state).runtime.is_null() {
            let runtime = &*(*state).runtime;
            explain_semantic_metadata(
                SemanticExplainMetadata {
                    index_name: &runtime.index_name,
                    index_kind: Some(runtime_index_kind_text(runtime)),
                    predicate_kind: runtime.predicate_kind.as_str(),
                    expected_json: &runtime.expected_json,
                    action_type: runtime.action_type.as_deref(),
                },
                es,
            );
            explain_semantic_policy(
                runtime.auto_policy,
                runtime.allow_refresh,
                runtime.wait_ms,
                runtime.infer_ms,
                runtime.infer_max_rows,
                infer_now_input_path(runtime.infer_ms),
                source_tuple_provider(runtime),
                es,
            );
            explain_text("Source Relation", &runtime.source_table, es);
            explain_text("Task", &runtime.task_name, es);
            explain_text("Record Type", &runtime.record_type, es);
            if let Some(private) = custom_private_from_plan(node) {
                explain_planner_stats(&private.planner_stats, es);
            }
            explain_counter(
                "Known Semantic Subjects",
                runtime.semantic_states.len() as u64,
                es,
            );
            explain_counter(
                "Preloaded Fresh Match Subjects",
                runtime_state_count(runtime, SubjectSemanticState::FreshMatch),
                es,
            );
            explain_counter(
                "Preloaded Fresh Non Match Subjects",
                runtime_state_count(runtime, SubjectSemanticState::FreshNonMatch),
                es,
            );
            explain_counter(
                "Preloaded Stale Subjects",
                runtime_state_count(runtime, SubjectSemanticState::Stale),
                es,
            );
            explain_counter(
                "Preloaded In Flight Subjects",
                runtime_state_count(runtime, SubjectSemanticState::InFlight),
                es,
            );
            explain_scan_counters!(
                runtime,
                nonempty_str(&runtime.infer_now_last_error),
                estimated_model_cost_ms(runtime.infer_ms, runtime.infer_max_rows),
                es
            );
            explain_runtime_trace(runtime, es);
        } else if let Some(private) = custom_private_from_plan(node) {
            explain_semantic_metadata(
                SemanticExplainMetadata {
                    index_name: &private.index_name,
                    index_kind: Some(private.index_kind.as_str()),
                    predicate_kind: private.predicate_kind.as_str(),
                    expected_json: &private.expected_json,
                    action_type: private.action_type.as_deref(),
                },
                es,
            );
            explain_semantic_policy(
                private.auto_policy,
                private.allow_refresh,
                private.wait_ms,
                private.infer_ms,
                private.infer_max_rows,
                infer_now_input_path(private.infer_ms),
                source_tuple_provider_from_state(state),
                es,
            );
            explain_pg_cstr("Source Relation", (*state).source_table, es);
            explain_pg_cstr("Task", (*state).task_name, es);
            explain_pg_cstr("Record Type", (*state).record_type, es);
            explain_planner_stats(&private.planner_stats, es);
            explain_counter("Known Semantic Subjects", (*state).known_subjects, es);
            explain_counter(
                "Preloaded Fresh Match Subjects",
                (*state).preloaded_fresh_matches,
                es,
            );
            explain_counter(
                "Preloaded Fresh Non Match Subjects",
                (*state).preloaded_fresh_non_matches,
                es,
            );
            explain_counter(
                "Preloaded Stale Subjects",
                (*state).preloaded_stale_subjects,
                es,
            );
            explain_counter(
                "Preloaded In Flight Subjects",
                (*state).preloaded_inflight_subjects,
                es,
            );
            explain_scan_counters!(
                &*state,
                pg_cstr_str((*state).infer_now_last_error),
                estimated_model_cost_ms(private.infer_ms, private.infer_max_rows),
                es
            );
            explain_state_trace(state, es);
        }
    }
}
fn free_buffered_rows(runtime: &mut RuntimeState) {
    while let Some(slot) = runtime.pending_output_rows.pop_front() {
        unsafe {
            pg_sys::ExecDropSingleTupleTableSlot(slot);
        }
    }
}

unsafe fn explain_text(label: &str, value: &str, es: *mut pg_sys::ExplainState) {
    unsafe {
        pg_sys::ExplainPropertyText(cstr(label).as_ptr(), cstr(value).as_ptr(), es);
    }
}

unsafe fn explain_pg_cstr(label: &str, value: *const c_char, es: *mut pg_sys::ExplainState) {
    unsafe {
        if !value.is_null() {
            pg_sys::ExplainPropertyText(cstr(label).as_ptr(), value, es);
        }
    }
}

struct SemanticExplainMetadata<'a> {
    index_name: &'a str,
    index_kind: Option<&'static str>,
    predicate_kind: &'static str,
    expected_json: &'a str,
    action_type: Option<&'a str>,
}

unsafe fn explain_semantic_metadata(
    metadata: SemanticExplainMetadata<'_>,
    es: *mut pg_sys::ExplainState,
) {
    unsafe {
        explain_text("Semantic Index", metadata.index_name, es);
        if let Some(index_kind) = metadata.index_kind {
            explain_text("Semantic Index Kind", index_kind, es);
        }
        explain_text("Semantic Predicate Kind", metadata.predicate_kind, es);
        explain_text("Semantic Predicate", metadata.expected_json, es);
        explain_optional_text("Semantic Action Type", metadata.action_type, es);
    }
}

unsafe fn explain_semantic_policy(
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    input_path: &str,
    source_tuple_provider: &str,
    es: *mut pg_sys::ExplainState,
) {
    unsafe {
        explain_text(
            "Refresh Policy",
            refresh_policy_from_parts(auto_policy, allow_refresh, wait_ms, infer_ms),
            es,
        );
        explain_text(
            "Worker Handoff",
            worker_handoff_from_parts(auto_policy, allow_refresh, wait_ms, infer_ms),
            es,
        );
        explain_counter("Infer Now Timeout Ms", infer_ms as u64, es);
        explain_counter("Infer Now Max Rows", infer_max_rows as u64, es);
        if infer_ms > 0 {
            explain_infer_now_queue(es);
        }
        explain_text("Infer Now Input Path", input_path, es);
        explain_text("Source Tuple Provider", source_tuple_provider, es);
    }
}

unsafe fn explain_planner_stats(stats: &SemanticPlannerStats, es: *mut pg_sys::ExplainState) {
    unsafe {
        explain_text("Planner Selected Path", &stats.selected_path, es);
        explain_text("Planner Semantic Reason", &stats.reason, es);
        explain_counter("Planner Source Rows", stats.source_rows, es);
        explain_counter("Planner Fresh Match Rows", stats.fresh_matches, es);
        explain_counter("Planner Fresh Non Match Rows", stats.fresh_non_matches, es);
        explain_counter("Planner Stale Rows", stats.stale_rows, es);
        explain_counter("Planner Missing Rows", stats.missing_rows, es);
        explain_counter("Planner In Flight Rows", stats.inflight_rows, es);
        explain_counter("Planner Cache Reusable Rows", stats.cache_reusable_rows, es);
        explain_counter(
            "Planner Lookup Decision Rows",
            stats.lookup_decision_rows,
            es,
        );
        explain_counter("Planner Wait Decision Rows", stats.wait_decision_rows, es);
        explain_counter("Planner Infer Decision Rows", stats.infer_decision_rows, es);
        explain_counter(
            "Planner Queue Refresh Decision Rows",
            stats.queue_decision_rows,
            es,
        );
        explain_counter(
            "Planner Fail Closed Decision Rows",
            stats.fail_closed_decision_rows,
            es,
        );
        explain_text(
            "Planner Model Cost Ms",
            &format!("{:.2}", stats.model_ms),
            es,
        );
        explain_text(
            "Planner Custom Path Cost",
            &format!("{:.2}", stats.path_cost),
            es,
        );
    }
}

unsafe fn explain_infer_now_queue(es: *mut pg_sys::ExplainState) {
    unsafe {
        let snapshot = crate::infer_now::queue_snapshot();
        explain_text(
            "Infer Now Admission Policy",
            crate::infer_now::INFER_NOW_ADMISSION_POLICY,
            es,
        );
        explain_counter("Infer Now Queue Slots", snapshot.slot_count as u64, es);
        explain_counter(
            "Infer Now Queue Depth",
            (snapshot.requested_slots + snapshot.running_slots) as u64,
            es,
        );
        explain_counter(
            "Infer Now Queue Available Slots",
            snapshot.available_slots as u64,
            es,
        );
        explain_counter("Infer Now Busy Rejections", snapshot.busy_rejections, es);
    }
}

unsafe fn explain_counter(label: &str, value: u64, es: *mut pg_sys::ExplainState) {
    unsafe {
        pg_sys::ExplainPropertyInteger(
            cstr(label).as_ptr(),
            ptr::null(),
            value.min(i64::MAX as u64) as i64,
            es,
        );
    }
}

fn runtime_state_count(runtime: &RuntimeState, state: SubjectSemanticState) -> u64 {
    runtime
        .semantic_states
        .values()
        .filter(|value| **value == state)
        .count() as u64
}

unsafe fn explain_runtime_trace(runtime: &RuntimeState, es: *mut pg_sys::ExplainState) {
    if runtime.infer_trace_receipt_id == 0 {
        return;
    }

    let trace = InferNowTraceExplain {
        receipt_id: runtime.infer_trace_receipt_id,
        prompt_tokens: runtime.infer_trace_prompt_tokens,
        generated_tokens: runtime.infer_trace_generated_tokens,
        generate_ms: runtime.infer_trace_generate_ms,
        version: nonempty_str(&runtime.infer_trace_version),
        tokens_per_second: nonempty_str(&runtime.infer_trace_tokens_per_second),
        probability_status: nonempty_str(&runtime.infer_trace_probability_status),
        probability_method: nonempty_str(&runtime.infer_trace_probability_method),
        schema_force: nonempty_str(&runtime.infer_trace_schema_force),
        worker_rss_bytes: runtime.infer_trace_worker_rss_bytes,
        worker_virtual_bytes: runtime.infer_trace_worker_virtual_bytes,
        worker_memory_policy: nonempty_str(&runtime.infer_trace_worker_memory_policy),
        model_cache_hits: runtime.infer_trace_model_cache_hits,
        model_cache_misses: runtime.infer_trace_model_cache_misses,
        inference_cache_hits: runtime.infer_trace_inference_cache_hits,
        inference_cache_misses: runtime.infer_trace_inference_cache_misses,
        inference_cache_entries: runtime.infer_trace_inference_cache_entries,
        inference_cache_bytes: runtime.infer_trace_inference_cache_bytes,
        inference_cache_evictions: runtime.infer_trace_inference_cache_evictions,
        inference_cache_reason: nonempty_str(&runtime.infer_trace_inference_cache_reason),
        detailed_status: nonempty_str(&runtime.infer_trace_detailed_status),
        detailed_captured_tokens: runtime.infer_trace_detailed_captured_tokens,
        detailed_skipped_tokens: runtime.infer_trace_detailed_skipped_tokens,
        detailed_top_k: runtime.infer_trace_detailed_top_k,
    };
    unsafe { explain_infer_now_trace(&trace, es) };
}

unsafe fn explain_state_trace(
    state: *mut OtletSemanticCustomScanState,
    es: *mut pg_sys::ExplainState,
) {
    unsafe {
        if state.is_null() || (*state).infer_trace_receipt_id == 0 {
            return;
        }
        let trace = InferNowTraceExplain {
            receipt_id: (*state).infer_trace_receipt_id,
            prompt_tokens: (*state).infer_trace_prompt_tokens,
            generated_tokens: (*state).infer_trace_generated_tokens,
            generate_ms: (*state).infer_trace_generate_ms,
            version: pg_cstr_str((*state).infer_trace_version),
            tokens_per_second: pg_cstr_str((*state).infer_trace_tokens_per_second),
            probability_status: pg_cstr_str((*state).infer_trace_probability_status),
            probability_method: pg_cstr_str((*state).infer_trace_probability_method),
            schema_force: pg_cstr_str((*state).infer_trace_schema_force),
            worker_rss_bytes: (*state).infer_trace_worker_rss_bytes,
            worker_virtual_bytes: (*state).infer_trace_worker_virtual_bytes,
            worker_memory_policy: pg_cstr_str((*state).infer_trace_worker_memory_policy),
            model_cache_hits: (*state).infer_trace_model_cache_hits,
            model_cache_misses: (*state).infer_trace_model_cache_misses,
            inference_cache_hits: (*state).infer_trace_inference_cache_hits,
            inference_cache_misses: (*state).infer_trace_inference_cache_misses,
            inference_cache_entries: (*state).infer_trace_inference_cache_entries,
            inference_cache_bytes: (*state).infer_trace_inference_cache_bytes,
            inference_cache_evictions: (*state).infer_trace_inference_cache_evictions,
            inference_cache_reason: pg_cstr_str((*state).infer_trace_inference_cache_reason),
            detailed_status: pg_cstr_str((*state).infer_trace_detailed_status),
            detailed_captured_tokens: (*state).infer_trace_detailed_captured_tokens,
            detailed_skipped_tokens: (*state).infer_trace_detailed_skipped_tokens,
            detailed_top_k: (*state).infer_trace_detailed_top_k,
        };
        explain_infer_now_trace(&trace, es);
    }
}

unsafe fn explain_infer_now_trace(trace: &InferNowTraceExplain<'_>, es: *mut pg_sys::ExplainState) {
    unsafe {
        explain_counter("Infer Now Trace Receipt Id", trace.receipt_id, es);
        explain_text(
            "Infer Now Trace Inspect SQL",
            &format!(
                "SELECT * FROM otlet.inference_trace_summary WHERE receipt_id = {}",
                trace.receipt_id
            ),
            es,
        );
        explain_counter("Infer Now Trace Prompt Tokens", trace.prompt_tokens, es);
        explain_counter(
            "Infer Now Trace Generated Tokens",
            trace.generated_tokens,
            es,
        );
        explain_counter("Infer Now Trace Generate Ms", trace.generate_ms, es);
        explain_optional_text("Infer Now Trace Version", trace.version, es);
        explain_optional_text(
            "Infer Now Trace Tokens Per Second",
            trace.tokens_per_second,
            es,
        );
        explain_optional_text("Infer Now Probability Status", trace.probability_status, es);
        explain_optional_text("Infer Now Probability Method", trace.probability_method, es);
        explain_optional_text("Infer Now Schema Force", trace.schema_force, es);
        explain_counter("Infer Now Worker RSS Bytes", trace.worker_rss_bytes, es);
        explain_counter("Infer Now Worker VMS Bytes", trace.worker_virtual_bytes, es);
        explain_optional_text(
            "Infer Now Worker Memory Policy",
            trace.worker_memory_policy,
            es,
        );
        explain_counter("Infer Now Model Cache Hits", trace.model_cache_hits, es);
        explain_counter("Infer Now Model Cache Misses", trace.model_cache_misses, es);
        explain_counter(
            "Infer Now Inference Cache Hits",
            trace.inference_cache_hits,
            es,
        );
        explain_counter(
            "Infer Now Inference Cache Misses",
            trace.inference_cache_misses,
            es,
        );
        explain_counter(
            "Infer Now Inference Cache Entries",
            trace.inference_cache_entries,
            es,
        );
        explain_counter(
            "Infer Now Inference Cache Bytes",
            trace.inference_cache_bytes,
            es,
        );
        explain_counter(
            "Infer Now Inference Cache Evictions",
            trace.inference_cache_evictions,
            es,
        );
        explain_optional_text(
            "Infer Now Inference Cache Reason",
            trace.inference_cache_reason,
            es,
        );
        explain_optional_text("Infer Now Detailed Trace Status", trace.detailed_status, es);
        explain_counter(
            "Infer Now Detailed Trace Captured Tokens",
            trace.detailed_captured_tokens,
            es,
        );
        explain_counter(
            "Infer Now Detailed Trace Skipped Tokens",
            trace.detailed_skipped_tokens,
            es,
        );
        explain_counter("Infer Now Detailed Trace Top K", trace.detailed_top_k, es);
    }
}

unsafe fn explain_optional_text(label: &str, value: Option<&str>, es: *mut pg_sys::ExplainState) {
    if let Some(value) = value {
        unsafe {
            explain_text(label, value, es);
        }
    }
}
