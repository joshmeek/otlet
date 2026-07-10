struct PreloadedSubjectCounts {
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale: u64,
    inflight: u64,
    missing: u64,
}

fn count_preloaded_subject_states(
    subjects: &HashMap<String, SubjectSemanticState>,
) -> PreloadedSubjectCounts {
    let mut counts = PreloadedSubjectCounts {
        fresh_matches: 0,
        fresh_non_matches: 0,
        stale: 0,
        inflight: 0,
        missing: 0,
    };
    for state in subjects.values() {
        match state {
            SubjectSemanticState::FreshMatch => counts.fresh_matches += 1,
            SubjectSemanticState::FreshNonMatch => counts.fresh_non_matches += 1,
            SubjectSemanticState::Stale => counts.stale += 1,
            SubjectSemanticState::InFlight => counts.inflight += 1,
            SubjectSemanticState::Missing => counts.missing += 1,
        }
    }
    counts
}

fn planner_stats_from_loaded_state(
    private: &CustomScanPrivate,
    stashed_stats: Option<SemanticPlannerStats>,
    loaded_state: &mut LoadedSemanticState,
) -> (SemanticPlannerStats, PreloadedSubjectCounts) {
    let counts = count_preloaded_subject_states(&loaded_state.subjects);
    // Prefer plan-time vocabulary (reason/path/decisions/path_cost) from the
    // custom_private stash; overlay exact preload subject counts for EXPLAIN.
    if let Some(mut stats) = stashed_stats {
        stats.source_rows = loaded_state.subjects.len() as u64;
        stats.fresh_matches = counts.fresh_matches;
        stats.fresh_non_matches = counts.fresh_non_matches;
        stats.stale_rows = counts.stale;
        stats.missing_rows = counts.missing;
        stats.inflight_rows = counts.inflight;
        stats.model_ms = loaded_state.model_ms;
        stats.model_cost_source = std::mem::take(&mut loaded_state.model_cost_source);
        // Prefer preload-aggregated stale reasons when present (row path).
        // Join begin-scan may have moved plan-time stale_reasons into the SPI
        // arg; the join SELECT returns that value into loaded_state, so always
        // restore from preload (normalize empty to "{}").
        let preload_stale = std::mem::take(&mut loaded_state.stale_reasons);
        if private.index_kind == SemanticIndexKind::Join {
            stats.stale_reasons = if preload_stale.is_empty() {
                "{}".to_owned()
            } else {
                preload_stale
            };
        } else if preload_stale != "{}" {
            stats.stale_reasons = preload_stale;
        }
        if private.index_kind == SemanticIndexKind::Join && stats.selected_path == "semantic_lookup"
        {
            stats.selected_path = "semantic_join_lookup".to_owned();
        }
        return (stats, counts);
    }
    let mut stats = SemanticPlannerStats {
        selected_path: "semantic_lookup".to_owned(),
        reason: "derived_from_begin_scan_preload".to_owned(),
        source_rows: loaded_state.subjects.len() as u64,
        fresh_matches: counts.fresh_matches,
        fresh_non_matches: counts.fresh_non_matches,
        stale_rows: counts.stale,
        missing_rows: counts.missing,
        inflight_rows: counts.inflight,
        cache_reusable_rows: 0,
        infer_decision_rows: 0,
        fail_closed_decision_rows: 0,
        model_ms: loaded_state.model_ms,
        model_cost_source: std::mem::take(&mut loaded_state.model_cost_source),
        path_cost: 1.0,
        stale_reasons: std::mem::take(&mut loaded_state.stale_reasons),
        // Join SQL plans use estimated candidate coverage; row preload is exact.
        count_basis: if private.index_kind == SemanticIndexKind::Join {
            "estimated".to_owned()
        } else {
            "exact".to_owned()
        },
    };
    finish_planner_stats(
        &mut stats,
        private.allow_refresh,
        private.wait_ms,
        private.infer_ms,
        private.infer_max_rows,
        private.auto_policy,
    );
    if private.index_kind == SemanticIndexKind::Join && stats.selected_path == "semantic_lookup" {
        stats.selected_path = "semantic_join_lookup".to_owned();
    }
    (stats, counts)
}

fn record_emitted_freshness_basis(runtime: &mut RuntimeState, subject_id: &str) {
    let basis = runtime
        .subject_freshness_basis
        .get(subject_id)
        .map_or("runtime_refresh", String::as_str);
    if let Some(count) = runtime.emitted_freshness_basis.get_mut(basis) {
        *count += 1;
    } else {
        runtime.emitted_freshness_basis.insert(basis.to_owned(), 1);
    }
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
        (*state).has_child_plan = !runtime.child_plan.is_null() || runtime.owns_child_plan;
        (*state).emitted_freshness_basis =
            pg_cstr(&freshness_basis_counts_json(&runtime.emitted_freshness_basis));
    }
}
