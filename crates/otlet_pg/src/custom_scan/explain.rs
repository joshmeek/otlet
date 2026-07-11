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
        let state = node.cast::<OtletSemanticCustomScanState>();
        explain_counter(
            "Child Plan Attached",
            u64::from((*state).has_child_plan),
            es,
        );
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
            if runtime.planner_path_cost.is_finite() && runtime.planner_path_cost > 0.0 {
                explain_text(
                    "Planner Path Cost",
                    &format!("{:.3}", runtime.planner_path_cost),
                    es,
                );
            }
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
            explain_text(
                "Preloaded Fresh Subjects / Basis",
                &fresh_subject_basis_line(
                    runtime
                        .preloaded_fresh_matches
                        .saturating_add(runtime.preloaded_fresh_non_matches),
                    &runtime.preloaded_freshness_basis,
                ),
                es,
            );
            explain_optional_text(
                "Emitted Freshness Basis",
                nonempty_str(&emitted_freshness_counts_json(&runtime.emitted_freshness_basis)),
                es,
            );
            explain_counter(
                "Preloaded Stale Subjects",
                runtime.preloaded_stale_subjects,
                es,
            );
            explain_counter(
                "Preloaded Missing Subjects",
                runtime.preloaded_missing_subjects,
                es,
            );
            explain_counter(
                "Preloaded In Flight Subjects",
                runtime.preloaded_inflight_subjects,
                es,
            );
            explain_scan_counters!(
                runtime,
                nonempty_str(&runtime.infer_now_last_error),
                estimated_model_cost_ms(
                    runtime.planner_model_ms,
                    runtime.planner_infer_decision_rows,
                ),
                es
            );
            explain_runtime_trace(runtime, es);
        } else if let Some(private) = custom_private_from_plan(node) {
            // Prefer begin-scan snapshots already on the CustomScanState
            // (pg_cstr + scalars) so EXPLAIN after runtime free avoids rebuilding
            // a SemanticPlannerStats. Fall back to stashed/SPI plan stats only
            // when the state snapshot is absent (pre-begin or legacy plans).
            explain_semantic_metadata(
                SemanticExplainMetadata {
                    index_name: &private.index_name,
                    index_kind: Some(private.index_kind.as_str()),
                    expected_json: &private.expected_json,
                },
                es,
            );
            let model_ms;
            let infer_decision_rows;
            if pg_cstr_str((*state).planner_selected_path).is_some() {
                explain_semantic_policy(
                    (*state).auto_policy,
                    (*state).allow_refresh,
                    (*state).wait_ms,
                    (*state).infer_ms,
                    (*state).infer_max_rows,
                    infer_now_input_path((*state).infer_ms),
                    source_tuple_provider_from_state(state),
                    es,
                );
                let _ = explain_planner_from_state(state, es);
                model_ms = if (*state).planner_model_ms.is_finite()
                    && (*state).planner_model_ms > 0.0
                {
                    (*state).planner_model_ms
                } else {
                    2500.0
                };
                infer_decision_rows = (*state).planner_infer_decision_rows;
            } else {
                // Borrow stashed stats when present; SPI reload only for legacy
                // plans missing both state snapshot and custom_private stash.
                let reloaded;
                let planner_stats = if let Some(stats) = private.planner_stats.as_ref() {
                    stats
                } else {
                    reloaded = reload_private_planner_stats_plan_only(&private);
                    &reloaded
                };
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
                explain_text("Planner Selected Path", &planner_stats.selected_path, es);
                explain_text("Planner Reason", &planner_stats.reason, es);
                explain_text("Planner Stale Reasons", &planner_stats.stale_reasons, es);
                explain_text("Count Basis", &planner_stats.count_basis, es);
                explain_text("Model Cost Source", &planner_stats.model_cost_source, es);
                if planner_stats.path_cost.is_finite() && planner_stats.path_cost > 0.0 {
                    explain_text(
                        "Planner Path Cost",
                        &format!("{:.3}", planner_stats.path_cost),
                        es,
                    );
                }
                explain_counter(
                    "Planner Infer Now Subjects",
                    planner_stats.infer_decision_rows,
                    es,
                );
                explain_counter(
                    "Planner Fail Closed Subjects",
                    planner_stats.fail_closed_decision_rows,
                    es,
                );
                model_ms = planner_stats.model_ms;
                infer_decision_rows = planner_stats.infer_decision_rows;
            }
            explain_pg_cstr("Source Relation", (*state).source_table, es);
            explain_pg_cstr("Task", (*state).task_name, es);
            explain_pg_cstr("Record Type", (*state).record_type, es);
            explain_counter("Known Semantic Subjects", (*state).known_subjects, es);
            let preloaded_fresh = (*state)
                .preloaded_fresh_matches
                .saturating_add((*state).preloaded_fresh_non_matches);
            explain_text(
                "Preloaded Fresh Subjects / Basis",
                &fresh_subject_basis_line(
                    preloaded_fresh,
                    pg_cstr_str((*state).preloaded_freshness_basis).unwrap_or(""),
                ),
                es,
            );
            explain_optional_text(
                "Emitted Freshness Basis",
                pg_cstr_str((*state).emitted_freshness_basis),
                es,
            );
            explain_counter(
                "Preloaded Stale Subjects",
                (*state).preloaded_stale_subjects,
                es,
            );
            explain_counter(
                "Preloaded Missing Subjects",
                (*state).preloaded_missing_subjects,
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
                estimated_model_cost_ms(model_ms, infer_decision_rows),
                es
            );
            explain_state_trace(state, es);
        }
    }
}

unsafe fn explain_planner_from_state(
    state: *mut OtletSemanticCustomScanState,
    es: *mut pg_sys::ExplainState,
) -> bool {
    unsafe {
        let Some(selected_path) = pg_cstr_str((*state).planner_selected_path) else {
            return false;
        };
        explain_text("Planner Selected Path", selected_path, es);
        explain_text(
            "Planner Reason",
            pg_cstr_str((*state).planner_reason).unwrap_or("planner snapshot"),
            es,
        );
        explain_text(
            "Planner Stale Reasons",
            pg_cstr_str((*state).planner_stale_reasons).unwrap_or("{}"),
            es,
        );
        explain_text(
            "Count Basis",
            pg_cstr_str((*state).planner_count_basis).unwrap_or("unknown"),
            es,
        );
        explain_text(
            "Model Cost Source",
            pg_cstr_str((*state).planner_model_cost_source).unwrap_or("static_fallback"),
            es,
        );
        if (*state).planner_path_cost.is_finite() && (*state).planner_path_cost > 0.0 {
            explain_text(
                "Planner Path Cost",
                &format!("{:.3}", (*state).planner_path_cost),
                es,
            );
        }
        explain_counter(
            "Planner Infer Now Subjects",
            (*state).planner_infer_decision_rows,
            es,
        );
        explain_counter(
            "Planner Fail Closed Subjects",
            (*state).planner_fail_closed_decision_rows,
            es,
        );
        true
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

#[derive(Clone, Copy)]
struct SemanticExplainMetadata<'explain> {
    index_name: &'explain str,
    index_kind: Option<&'static str>,
    expected_json: &'explain str,
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

#[allow(clippy::too_many_arguments)]
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
        explain_counter("Infer Now Timeout Ms", u64::from(infer_ms), es);
        explain_counter("Infer Now Max Rows", u64::from(infer_max_rows), es);
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
            i64::try_from(value).unwrap_or(i64::MAX),
            es,
        );
    }
}

fn fresh_subject_basis_line(count: u64, basis: &str) -> String {
    let basis = if basis.trim().is_empty() { "{}" } else { basis };
    format!("{count} {basis}")
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
        finish_sql_ms: runtime.infer_trace_finish_sql_ms,
        materialize_ms: runtime.infer_trace_materialize_ms,
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
            finish_sql_ms: (*state).infer_trace_finish_sql_ms,
            materialize_ms: (*state).infer_trace_materialize_ms,
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
        if trace.finish_sql_ms > 0 {
            explain_counter("Infer Now Trace Finish Sql Ms", trace.finish_sql_ms, es);
        }
        if trace.materialize_ms > 0 {
            explain_counter("Infer Now Trace Materialize Ms", trace.materialize_ms, es);
        }
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
