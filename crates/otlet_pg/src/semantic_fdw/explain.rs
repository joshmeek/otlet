#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_explain_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
    es: *mut pg_sys::ExplainState,
) {
    unsafe {
        explain_text("Otlet Node", "Semantic Foreign Scan", es);
        explain_text("Executor Boundary", "Foreign Scan", es);
        explain_text(
            "Stale Result Policy",
            "fail_closed_zero_subject_rows_until_worker_refresh_commits",
            es,
        );
        explain_text("Worker Handoff", "shared_memory_xact_commit_latch", es);
        let snapshot = if !(*node).fdw_state.is_null() {
            let state = &*((*node).fdw_state as *mut SemanticFdwState);
            Some(state.explain_snapshot())
        } else {
            take_explain_snapshot(node)
        };
        if let Some(snapshot) = snapshot {
            explain_text(
                "Access Kind",
                match snapshot.opts.access_kind {
                    SemanticAccessKind::RowIndex => "semantic_index",
                    SemanticAccessKind::JoinIndex => "semantic_join_index",
                },
                es,
            );
            explain_text("Selected Path", &snapshot.plan.selected_path, es);
            explain_text("Reason", &snapshot.plan.reason, es);
            explain_text("Task Name", &snapshot.plan.task_name, es);
            explain_integer("Total Rows", snapshot.plan.total_rows, es);
            explain_integer("Refresh Rows", snapshot.plan.refresh_rows, es);
            explain_float("Freshness", snapshot.plan.freshness, "", es);
            explain_float(
                "Estimated Lookup",
                snapshot.plan.estimated_lookup_ms,
                "ms",
                es,
            );
            explain_float(
                "Estimated Refresh",
                snapshot.plan.estimated_refresh_ms,
                "ms",
                es,
            );
            explain_float(
                "Estimated Fresh Inference",
                snapshot.plan.estimated_fresh_inference_ms,
                "ms",
                es,
            );
            if (*es).analyze {
                explain_integer("Actual Rows Loaded", snapshot.rows_loaded, es);
                explain_integer("Actual Rows Emitted", snapshot.rows_emitted, es);
                explain_integer("Actual Queued Jobs", snapshot.queued_jobs, es);
                explain_integer("Actual Rescans", snapshot.rescans, es);
            }
            match snapshot.pushdown.subjects() {
                Some([subject_id]) => explain_text("Pushed Subject Id", subject_id, es),
                Some([]) => explain_text("Pushed Subject Filter", "empty", es),
                Some(subject_ids) => explain_text("Pushed Subject Ids", &subject_ids.join(","), es),
                None => {}
            }
            if !snapshot.pushdown.subject_param_filters.is_empty() {
                explain_text(
                    "Pushed Subject Params",
                    &snapshot
                        .pushdown
                        .subject_param_filters
                        .iter()
                        .map(subject_param_filter_label)
                        .collect::<Vec<_>>()
                        .join(","),
                    es,
                );
            }
            if let Some(outer_ref) = snapshot.pushdown.subject_outer {
                explain_text(
                    "Pushed Subject Outer Var",
                    &outer_var_ref_label(outer_ref),
                    es,
                );
            }
            if !snapshot.pushdown.body_contains.is_empty() {
                explain_text(
                    "Pushed Body Contains",
                    &snapshot.pushdown.body_contains.join(" AND "),
                    es,
                );
            }
            if !snapshot.pushdown.body_contains_params.is_empty() {
                explain_text(
                    "Pushed Body Contains Params",
                    &snapshot
                        .pushdown
                        .body_contains_params
                        .iter()
                        .map(|param_ref| format!("body @> {}", param_ref_label(*param_ref)))
                        .collect::<Vec<_>>()
                        .join(" AND "),
                    es,
                );
            }
            if !snapshot.pushdown.body_field_equals.is_empty() {
                explain_text(
                    "Pushed Body Field Equals",
                    &snapshot
                        .pushdown
                        .body_field_equals
                        .iter()
                        .map(|(field, value)| format!("{field}={value}"))
                        .collect::<Vec<_>>()
                        .join(" AND "),
                    es,
                );
            }
            if !snapshot.pushdown.body_field_equals_params.is_empty() {
                explain_text(
                    "Pushed Body Field Equals Params",
                    &snapshot
                        .pushdown
                        .body_field_equals_params
                        .iter()
                        .map(|(field, param_ref)| {
                            format!("{field}={}", param_ref_label(*param_ref))
                        })
                        .collect::<Vec<_>>()
                        .join(" AND "),
                    es,
                );
            }
            if let Some(stale) = snapshot.pushdown.stale {
                explain_text(
                    "Pushed Stale Filter",
                    if stale { "stale=true" } else { "stale=false" },
                    es,
                );
            }
            if let Some(param_ref) = snapshot.pushdown.stale_param {
                explain_text(
                    "Pushed Stale Param",
                    &format!("stale = {}", param_ref_label(param_ref)),
                    es,
                );
            }
            if let Some(source_hash) = &snapshot.pushdown.source_hash {
                explain_text("Pushed Source Hash", source_hash, es);
            }
            if let Some(param_ref) = snapshot.pushdown.source_hash_param {
                explain_text(
                    "Pushed Source Hash Param",
                    &format!("source_hash = {}", param_ref_label(param_ref)),
                    es,
                );
            }
            if let Some(reason) = &snapshot.pushdown.empty_result_reason {
                explain_text("Empty Result Reason", reason, es);
            }
        }
    }
}
