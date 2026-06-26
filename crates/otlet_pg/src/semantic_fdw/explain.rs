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
            explain_text("Record Type", &snapshot.plan.record_type, es);
            explain_text("Model Name", &snapshot.plan.model_name, es);
            explain_text("Runtime Name", &snapshot.plan.runtime_name, es);
            explain_text("Source Relation", &snapshot.plan.source_relation, es);
            explain_integer("Total Subjects", snapshot.plan.total_subjects, es);
            explain_integer("Fresh Subjects", snapshot.plan.fresh_subjects, es);
            explain_integer("Stale Subjects", snapshot.plan.stale_subjects, es);
            explain_integer("Missing Subjects", snapshot.plan.missing_subjects, es);
            explain_integer("In Flight Subjects", snapshot.plan.inflight_subjects, es);
            explain_integer("Lookup Subjects", snapshot.plan.lookup_subjects, es);
            explain_integer("Wait Subjects", snapshot.plan.wait_subjects, es);
            explain_integer("Queue Subjects", snapshot.plan.queue_subjects, es);
            explain_integer("Infer Now Subjects", snapshot.plan.infer_now_subjects, es);
            explain_integer("Fail Closed Subjects", snapshot.plan.fail_closed_subjects, es);
            explain_float("Freshness", snapshot.plan.freshness, "", es);
            explain_float("Model Cost", snapshot.plan.model_ms, "ms", es);
            explain_text("Model Cost Source", &snapshot.plan.model_cost_source, es);
            explain_float("Cache Hit Cost", snapshot.plan.cache_hit_ms, "ms", es);
            explain_float("Estimated Lookup", snapshot.plan.lookup_ms, "ms", es);
            explain_float("Estimated Queue", snapshot.plan.queue_ms, "ms", es);
            explain_float("Estimated Infer Now", snapshot.plan.infer_now_ms, "ms", es);
            explain_float("Path Cost", snapshot.plan.path_cost, "", es);
            explain_integer("Worker Queue Depth", snapshot.plan.worker_queue_depth, es);
            explain_integer(
                "Available Queue Slots",
                snapshot.plan.available_queue_slots,
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
        }
    }
}
