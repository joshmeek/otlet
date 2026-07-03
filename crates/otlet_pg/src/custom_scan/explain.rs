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
                    expected_json: &runtime.expected_json,
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
            explain_text("Planner Selected Path", &runtime.planner_selected_path, es);
            explain_text("Planner Reason", &runtime.planner_reason, es);
            explain_text("Planner Stale Reasons", &runtime.planner_stale_reasons, es);
            explain_text("Count Basis", &runtime.planner_count_basis, es);
            explain_text("Model Cost Source", &runtime.planner_model_cost_source, es);
            explain_counter(
                "Planner Infer Now Subjects",
                runtime.planner_infer_decision_rows,
                es,
            );
            explain_counter(
                "Planner Fail Closed Subjects",
                runtime.planner_fail_closed_decision_rows,
                es,
            );
            explain_text("Source Relation", &runtime.source_table, es);
            explain_text("Task", &runtime.task_name, es);
            explain_text("Record Type", &runtime.record_type, es);
            explain_counter(
                "Known Semantic Subjects",
                runtime.semantic_states.len() as u64,
                es,
            );
            explain_counter(
                "Preloaded Fresh Subjects",
                runtime_preloaded_fresh_count(runtime),
                es,
            );
            explain_optional_text(
                "Preloaded Freshness Basis",
                nonempty_str(&runtime.preloaded_freshness_basis),
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
            let policy = semantic_policy_for_selected_path(&private.selected_path);
            explain_semantic_metadata(
                SemanticExplainMetadata {
                    index_name: &private.index_name,
                    index_kind: Some(private.index_kind.as_str()),
                    expected_json: &private.expected_json,
                },
                es,
            );
            explain_semantic_policy(
                policy.auto_policy,
                policy.allow_refresh,
                policy.wait_ms,
                policy.infer_ms,
                policy.infer_max_rows,
                infer_now_input_path(policy.infer_ms),
                source_tuple_provider_from_state(state),
                es,
            );
            explain_text("Planner Selected Path", &private.selected_path, es);
            explain_text("Planner Reason", &private.reason, es);
            explain_text("Planner Stale Reasons", &private.stale_reasons, es);
            explain_text("Count Basis", &private.count_basis, es);
            explain_text("Model Cost Source", &private.model_cost_source, es);
            explain_counter("Planner Infer Now Subjects", private.infer_decision_rows, es);
            explain_counter(
                "Planner Fail Closed Subjects",
                private.fail_closed_decision_rows,
                es,
            );
            explain_pg_cstr("Source Relation", (*state).source_table, es);
            explain_pg_cstr("Task", (*state).task_name, es);
            explain_pg_cstr("Record Type", (*state).record_type, es);
            explain_counter("Known Semantic Subjects", (*state).known_subjects, es);
            explain_counter(
                "Preloaded Fresh Subjects",
                (*state)
                    .preloaded_fresh_matches
                    .saturating_add((*state).preloaded_fresh_non_matches),
                es,
            );
            explain_optional_text(
                "Preloaded Freshness Basis",
                pg_cstr_str((*state).preloaded_freshness_basis),
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
                estimated_model_cost_ms(policy.infer_ms, policy.infer_max_rows),
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
    expected_json: &'a str,
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
        explain_text("Semantic Predicate", metadata.expected_json, es);
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

fn runtime_preloaded_fresh_count(runtime: &RuntimeState) -> u64 {
    runtime_state_count(runtime, SubjectSemanticState::FreshMatch)
        .saturating_add(runtime_state_count(runtime, SubjectSemanticState::FreshNonMatch))
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
        probability_status: nonempty_str(&runtime.infer_trace_probability_status),
        schema_force: nonempty_str(&runtime.infer_trace_schema_force),
        detailed_status: nonempty_str(&runtime.infer_trace_detailed_status),
        detailed_captured_tokens: runtime.infer_trace_detailed_captured_tokens,
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
            probability_status: pg_cstr_str((*state).infer_trace_probability_status),
            schema_force: pg_cstr_str((*state).infer_trace_schema_force),
            detailed_status: pg_cstr_str((*state).infer_trace_detailed_status),
            detailed_captured_tokens: (*state).infer_trace_detailed_captured_tokens,
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
        explain_optional_text("Infer Now Probability Status", trace.probability_status, es);
        explain_optional_text("Infer Now Schema Force", trace.schema_force, es);
        explain_optional_text("Infer Now Detailed Trace Status", trace.detailed_status, es);
        explain_counter(
            "Infer Now Detailed Trace Captured Tokens",
            trace.detailed_captured_tokens,
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
