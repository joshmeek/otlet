#[pgrx::pg_guard]
unsafe extern "C-unwind" fn create_semantic_custom_scan_state(
    _cscan: *mut pg_sys::CustomScan,
) -> *mut pg_sys::Node {
    unsafe {
        let state = pg_sys::palloc0(size_of::<OtletSemanticCustomScanState>())
            .cast::<OtletSemanticCustomScanState>();
        (*state).css.ss.ps.type_ = pg_sys::NodeTag::T_CustomScanState;
        (*state).css.methods = &raw const CUSTOM_EXEC_METHODS;
        (*state).runtime = ptr::null_mut();
        state.cast()
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn begin_semantic_custom_scan(
    node: *mut pg_sys::CustomScanState,
    _estate: *mut pg_sys::EState,
    eflags: std::ffi::c_int,
) {
    unsafe {
        let state = node.cast::<OtletSemanticCustomScanState>();
        let Some(mut private) = custom_private_from_plan(node) else {
            return;
        };
        let relation = (*node).ss.ss_currentRelation;
        if relation.is_null() && private.index_kind == SemanticIndexKind::Row {
            pgrx::error!("otlet semantic CustomScan could not open source relation");
        }
        let (child_plan, owns_child_plan) = init_custom_child_plan(node, eflags);
        if !relation.is_null() && !(*node).ss.ps.state.is_null() {
            pg_sys::ExecInitScanTupleSlot(
                (*node).ss.ps.state,
                &raw mut (*node).ss,
                (*relation).rd_att,
                pg_sys::table_slot_callbacks(relation),
            );
        } else if relation.is_null() && !child_plan.is_null() && !(*node).ss.ps.state.is_null() {
            let mut ops_fixed = false;
            let child_ops = pg_sys::ExecGetResultSlotOps(child_plan, &raw mut ops_fixed);
            pg_sys::ExecInitScanTupleSlot(
                (*node).ss.ps.state,
                &raw mut (*node).ss,
                pg_sys::ExecGetResultType(child_plan),
                child_ops,
            );
        }
        if child_plan.is_null() {
            pgrx::error!("otlet semantic CustomScan requires a PG-created child plan");
        }
        let stashed_stats = private.planner_stats.take();
        let mut loaded_state = load_semantic_states(
            private.index_kind,
            &private.index_name,
            &private.expected_json,
        )
        .unwrap_or_else(|err| pgrx::error!("{err}"));
        // Prefer plan-time vocabulary from custom_private; overlay exact preload
        // counts. Keep executor knobs from plan-time private data.
        let (planner_stats, preloaded_counts) =
            planner_stats_from_loaded_state(&private, stashed_stats, &mut loaded_state);
        let policy = SemanticAutoPolicy {
            auto_policy: private.auto_policy,
            allow_refresh: private.allow_refresh,
            wait_ms: private.wait_ms,
            infer_ms: private.infer_ms,
            infer_max_rows: private.infer_max_rows,
        };
        snapshot_planner_state(state, &planner_stats, &policy);
        (*state).index_kind = private.index_kind;
        // Child plan is required above; snapshot for EXPLAIN after runtime free.
        (*state).has_child_plan = !child_plan.is_null();
        (*state).source_table = pg_cstr(&loaded_state.source_table);
        (*state).task_name = pg_cstr(&loaded_state.task_name);
        (*state).record_type = pg_cstr(&loaded_state.record_type);
        (*state).known_subjects = loaded_state.subjects.len() as u64;
        (*state).preloaded_fresh_matches = preloaded_counts.fresh_matches;
        (*state).preloaded_fresh_non_matches = preloaded_counts.fresh_non_matches;
        (*state).preloaded_freshness_basis = pg_cstr(&loaded_state.freshness_basis_counts);
        (*state).emitted_freshness_basis = pg_cstr("");
        (*state).preloaded_stale_subjects = preloaded_counts.stale;
        (*state).preloaded_missing_subjects = preloaded_counts.missing;
        (*state).preloaded_inflight_subjects = preloaded_counts.inflight;
        let mut runtime = RuntimeState {
            index_kind: private.index_kind,
            index_name: private.index_name,
            expected_json: private.expected_json,
            auto_policy: policy.auto_policy,
            allow_refresh: policy.allow_refresh,
            wait_ms: policy.wait_ms,
            infer_ms: policy.infer_ms,
            infer_max_rows: policy.infer_max_rows,
            planner_selected_path: planner_stats.selected_path,
            planner_reason: planner_stats.reason,
            planner_stale_reasons: planner_stats.stale_reasons,
            planner_model_cost_source: planner_stats.model_cost_source,
            planner_model_ms: planner_stats.model_ms,
            planner_count_basis: planner_stats.count_basis,
            planner_path_cost: planner_stats.path_cost,
            planner_infer_decision_rows: planner_stats.infer_decision_rows,
            planner_fail_closed_decision_rows: planner_stats.fail_closed_decision_rows,
            source_table: loaded_state.source_table,
            task_name: loaded_state.task_name,
            record_type: loaded_state.record_type,
            // Filled after child_plan is set so provider/policy strings match runtime.
            infer_now_executor_context_json: String::new(),
            input_columns: loaded_state.input_columns,
            preloaded_freshness_basis: loaded_state.freshness_basis_counts,
            preloaded_fresh_matches: preloaded_counts.fresh_matches,
            preloaded_fresh_non_matches: preloaded_counts.fresh_non_matches,
            preloaded_stale_subjects: preloaded_counts.stale,
            preloaded_missing_subjects: preloaded_counts.missing,
            preloaded_inflight_subjects: preloaded_counts.inflight,
            source_reltype: if relation.is_null() {
                pg_sys::InvalidOid
            } else {
                (*(*relation).rd_rel).reltype
            },
            subject_attno: private.subject_attno,
            subject_typid: private.subject_typid,
            join_input_attno: resolve_join_input_attno(child_plan, private.index_kind),
            child_plan,
            owns_child_plan,
            semantic_states: loaded_state.subjects,
            subject_freshness_basis: loaded_state.freshness_basis_by_subject,
            emitted_freshness_basis: EmittedFreshnessCounts::default(),
            rows_seen: 0,
            rows_returned: 0,
            lookup_rows: 0,
            infer_resolved_rows: 0,
            infer_returned_rows: 0,
            fail_closed_rows: 0,
            fresh_matches: 0,
            fresh_non_matches: 0,
            stale_rows: 0,
            missing_rows: 0,
            inflight_rows: 0,
            queued_refreshes: 0,
            refresh_queue_skips: 0,
            refresh_queue_batches: 0,
            refresh_queue_errors: 0,
            infer_now_batches: 0,
            infer_now_ms: 0,
            infer_now_timeouts: 0,
            infer_now_failures: 0,
            infer_now_last_error: String::new(),
            infer_receipts: 0,
            infer_failed_receipts: 0,
            infer_failed_receipt_id: 0,
            infer_trace_receipt_id: 0,
            infer_trace_prompt_tokens: 0,
            infer_trace_generated_tokens: 0,
            infer_trace_generate_ms: 0,
            infer_trace_finish_sql_ms: 0,
            infer_trace_materialize_ms: 0,
            infer_trace_version: String::new(),
            infer_trace_runtime_fingerprint_hash: String::new(),
            infer_trace_probability_status: String::new(),
            infer_trace_schema_force: String::new(),
            infer_trace_detailed_status: String::new(),
            infer_trace_detailed_captured_tokens: 0,
            infer_trace_detailed_top_k: 0,
            child_plan_rows: 0,
            queued_refresh_subjects: HashSet::with_capacity(
                usize::try_from(private.infer_max_rows.max(8)).unwrap_or(8),
            ),
            pending_refresh_subjects: Vec::with_capacity(CUSTOM_SCAN_REFRESH_BATCH_SIZE),
            pending_output_rows: VecDeque::with_capacity(
                usize::try_from(private.infer_max_rows)
                    .unwrap_or(0)
                    .max(1),
            ),
        };
        runtime.infer_now_executor_context_json =
            freeze_infer_now_executor_context_json(&runtime);
        (*state).runtime = Box::into_raw(Box::new(runtime));
    }
}

unsafe fn snapshot_planner_state(
    state: *mut OtletSemanticCustomScanState,
    planner_stats: &SemanticPlannerStats,
    policy: &SemanticAutoPolicy,
) {
    unsafe {
        (*state).auto_policy = policy.auto_policy;
        (*state).allow_refresh = policy.allow_refresh;
        (*state).wait_ms = policy.wait_ms;
        (*state).infer_ms = policy.infer_ms;
        (*state).infer_max_rows = policy.infer_max_rows;
        (*state).planner_selected_path = pg_cstr(&planner_stats.selected_path);
        (*state).planner_reason = pg_cstr(&planner_stats.reason);
        (*state).planner_stale_reasons = pg_cstr(&planner_stats.stale_reasons);
        (*state).planner_model_cost_source = pg_cstr(&planner_stats.model_cost_source);
        (*state).planner_model_ms = planner_stats.model_ms;
        (*state).planner_count_basis = pg_cstr(&planner_stats.count_basis);
        (*state).planner_path_cost = planner_stats.path_cost;
        (*state).planner_infer_decision_rows = planner_stats.infer_decision_rows;
        (*state).planner_fail_closed_decision_rows = planner_stats.fail_closed_decision_rows;
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn exec_semantic_custom_scan(
    node: *mut pg_sys::CustomScanState,
) -> *mut pg_sys::TupleTableSlot {
    unsafe {
        pg_sys::ExecScan(
            &raw mut (*node).ss,
            Some(semantic_custom_scan_access),
            Some(semantic_custom_scan_recheck),
        )
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn semantic_custom_scan_access(
    scan_state: *mut pg_sys::ScanState,
) -> *mut pg_sys::TupleTableSlot {
    unsafe {
        let node = scan_state.cast::<pg_sys::CustomScanState>();
        let state = node.cast::<OtletSemanticCustomScanState>();
        if (*state).runtime.is_null() {
            return clear_slot((*node).ss.ss_ScanTupleSlot);
        }
        let runtime = &mut *(*state).runtime;

        loop {
            if let Some(slot) = emit_buffered_row(node, runtime) {
                flush_refresh_queue_or_warn(runtime);
                return slot;
            }
            let Some(slot) = next_source_slot(node, runtime) else {
                flush_refresh_queue_or_warn(runtime);
                return clear_slot((*node).ss.ss_ScanTupleSlot);
            };
            runtime.rows_seen += 1;

            let mut isnull = false;
            let value = pg_sys::slot_getattr(
                slot,
                std::ffi::c_int::from(runtime.subject_attno),
                &raw mut isnull,
            );
            if isnull {
                continue;
            }
            let Some(subject_id) = datum_to_text(value, runtime.subject_typid) else {
                continue;
            };
            match runtime
                .semantic_states
                .get(&subject_id)
                .copied()
                .unwrap_or(SubjectSemanticState::Missing)
            {
                SubjectSemanticState::FreshMatch => {
                    runtime.fresh_matches += 1;
                    runtime.lookup_rows += 1;
                    record_emitted_freshness_basis(runtime, &subject_id);
                    runtime.rows_returned += 1;
                    flush_refresh_queue_or_warn(runtime);
                    return slot;
                }
                SubjectSemanticState::FreshNonMatch => {
                    runtime.fresh_non_matches += 1;
                    runtime.lookup_rows += 1;
                }
                SubjectSemanticState::Stale => {
                    runtime.stale_rows += 1;
                    if let Some(slot) =
                        resolve_stale_or_missing_subject(node, runtime, &subject_id, slot)
                    {
                        flush_refresh_queue_or_warn(runtime);
                        return slot;
                    }
                }
                SubjectSemanticState::Missing => {
                    runtime.missing_rows += 1;
                    if let Some(slot) =
                        resolve_stale_or_missing_subject(node, runtime, &subject_id, slot)
                    {
                        flush_refresh_queue_or_warn(runtime);
                        return slot;
                    }
                }
                SubjectSemanticState::InFlight => {
                    runtime.inflight_rows += 1;
                    if let Some(slot) =
                        resolve_inflight_subject(runtime, &subject_id, slot)
                    {
                        flush_refresh_queue_or_warn(runtime);
                        return slot;
                    }
                }
            }
        }
    }
}

unsafe fn resolve_stale_or_missing_subject(
    node: *mut pg_sys::CustomScanState,
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Option<*mut pg_sys::TupleTableSlot> {
    unsafe {
        if should_prefetch_infer_now(runtime) {
            if let Err(err) = prefetch_infer_now_batch(node, runtime, subject_id, slot) {
                runtime.infer_now_failures = runtime.infer_now_failures.saturating_add(1);
                truncate_infer_now_error_into(&mut runtime.infer_now_last_error, &err);
                pgrx::warning!("otlet semantic CustomScan infer-now batch failed: {err}");
            }
            return emit_buffered_row(node, runtime);
        }

        match wait_for_refresh_if_allowed(runtime, subject_id, false).unwrap_or_else(|err| {
            pgrx::warning!("otlet semantic CustomScan wait failed: {err}");
            SemanticResolution::Unresolved
        }) {
            SemanticResolution::Match => {
                record_emitted_freshness_basis(runtime, subject_id);
                runtime.rows_returned += 1;
                return Some(slot);
            }
            SemanticResolution::NonMatch => return None,
            SemanticResolution::Unresolved => {}
        }

        match infer_now_or_record_failure(runtime, subject_id, slot) {
            SemanticResolution::Match => {
                runtime.infer_resolved_rows += 1;
                runtime.infer_returned_rows += 1;
                record_emitted_freshness_basis(runtime, subject_id);
                runtime.rows_returned += 1;
                Some(slot)
            }
            SemanticResolution::NonMatch => {
                runtime.infer_resolved_rows += 1;
                None
            }
            SemanticResolution::Unresolved => {
                queue_refresh_if_allowed(runtime, subject_id);
                runtime.fail_closed_rows += 1;
                None
            }
        }
    }
}

fn resolve_inflight_subject(
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Option<*mut pg_sys::TupleTableSlot> {
    match wait_for_refresh_if_allowed(runtime, subject_id, true).unwrap_or_else(|err| {
        pgrx::warning!("otlet semantic CustomScan wait failed: {err}");
        SemanticResolution::Unresolved
    }) {
        SemanticResolution::Match => {
            record_emitted_freshness_basis(runtime, subject_id);
            runtime.rows_returned += 1;
            Some(slot)
        }
        SemanticResolution::NonMatch => None,
        SemanticResolution::Unresolved => {
            runtime.fail_closed_rows += 1;
            None
        }
    }
}

unsafe fn init_custom_child_plan(
    node: *mut pg_sys::CustomScanState,
    eflags: std::ffi::c_int,
) -> (*mut pg_sys::PlanState, bool) {
    unsafe {
        if node.is_null() {
            return (ptr::null_mut(), false);
        }
        if !(*node).custom_ps.is_null() && pg_sys::list_length((*node).custom_ps) > 0 {
            return (
                pg_sys::list_nth((*node).custom_ps, 0).cast::<pg_sys::PlanState>(),
                false,
            );
        }
        if (*node).ss.ps.plan.is_null() {
            return (ptr::null_mut(), false);
        }
        let scan = (*node).ss.ps.plan.cast::<pg_sys::CustomScan>();
        if (*scan).custom_plans.is_null() || pg_sys::list_length((*scan).custom_plans) == 0 {
            return (ptr::null_mut(), false);
        }
        let child_plan = pg_sys::list_nth((*scan).custom_plans, 0).cast::<pg_sys::Plan>();
        if child_plan.is_null() {
            return (ptr::null_mut(), false);
        }
        let child_state = pg_sys::ExecInitNode(child_plan, (*node).ss.ps.state, eflags);
        if child_state.is_null() {
            return (ptr::null_mut(), false);
        }
        (*node).custom_ps = list_make1(child_state.cast());
        (child_state, true)
    }
}

unsafe fn next_source_slot(
    _node: *mut pg_sys::CustomScanState,
    runtime: &mut RuntimeState,
) -> Option<*mut pg_sys::TupleTableSlot> {
    unsafe {
        if !runtime.child_plan.is_null() {
            let result_slot = pg_sys::ExecProcNode(runtime.child_plan);
            if slot_is_empty(result_slot) {
                return None;
            }
            if is_semantic_join_runtime(runtime) {
                runtime.child_plan_rows += 1;
                return Some(result_slot);
            }
            let child_scan_state = runtime.child_plan.cast::<pg_sys::ScanState>();
            let slot = if child_scan_state.is_null()
                || slot_is_empty((*child_scan_state).ss_ScanTupleSlot)
            {
                result_slot
            } else {
                (*child_scan_state).ss_ScanTupleSlot
            };
            runtime.child_plan_rows += 1;
            return Some(slot);
        }

        pgrx::error!("otlet semantic CustomScan missing PG-created child plan");
    }
}

unsafe fn slot_is_empty(slot: *mut pg_sys::TupleTableSlot) -> bool {
    let empty_flag = u16::try_from(pg_sys::TTS_FLAG_EMPTY).unwrap_or(u16::MAX);
    unsafe { slot.is_null() || ((*slot).tts_flags & empty_flag) != 0 }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn semantic_custom_scan_recheck(
    _scan_state: *mut pg_sys::ScanState,
    _slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    true
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn rescan_semantic_custom_scan(node: *mut pg_sys::CustomScanState) {
    unsafe {
        let state = node.cast::<OtletSemanticCustomScanState>();
        if !(*state).runtime.is_null() {
            let runtime = &mut *(*state).runtime;
            flush_refresh_queue_or_warn(runtime);
            free_buffered_rows(runtime);
            runtime.rows_seen = 0;
            runtime.rows_returned = 0;
            runtime.lookup_rows = 0;
            runtime.infer_resolved_rows = 0;
            runtime.infer_returned_rows = 0;
            runtime.fail_closed_rows = 0;
            runtime.fresh_matches = 0;
            runtime.fresh_non_matches = 0;
            runtime.stale_rows = 0;
            runtime.missing_rows = 0;
            runtime.inflight_rows = 0;
            runtime.queued_refreshes = 0;
            runtime.refresh_queue_skips = 0;
            runtime.refresh_queue_batches = 0;
            runtime.refresh_queue_errors = 0;
            runtime.infer_now_batches = 0;
            runtime.infer_now_ms = 0;
            runtime.infer_now_timeouts = 0;
            runtime.infer_now_failures = 0;
            runtime.infer_now_last_error.clear();
            runtime.infer_receipts = 0;
            runtime.infer_failed_receipts = 0;
            runtime.infer_failed_receipt_id = 0;
            runtime.infer_trace_receipt_id = 0;
            runtime.infer_trace_prompt_tokens = 0;
            runtime.infer_trace_generated_tokens = 0;
            runtime.infer_trace_generate_ms = 0;
            runtime.infer_trace_finish_sql_ms = 0;
            runtime.infer_trace_materialize_ms = 0;
            runtime.infer_trace_version.clear();
            runtime.infer_trace_runtime_fingerprint_hash.clear();
            runtime.infer_trace_probability_status.clear();
            runtime.infer_trace_schema_force.clear();
            runtime.infer_trace_detailed_status.clear();
            runtime.infer_trace_detailed_captured_tokens = 0;
            runtime.infer_trace_detailed_top_k = 0;
            runtime.child_plan_rows = 0;
            runtime.emitted_freshness_basis.clear();
            runtime.queued_refresh_subjects.clear();
            runtime.pending_refresh_subjects.clear();
            runtime.pending_output_rows.clear();
            if !runtime.child_plan.is_null() {
                pg_sys::ExecReScan(runtime.child_plan);
            }
        }
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn end_semantic_custom_scan(node: *mut pg_sys::CustomScanState) {
    unsafe {
        let state = node.cast::<OtletSemanticCustomScanState>();
        if !(*state).runtime.is_null() {
            let runtime = &mut *(*state).runtime;
            flush_refresh_queue_or_warn(runtime);
            free_buffered_rows(runtime);
            if runtime.owns_child_plan && !runtime.child_plan.is_null() {
                pg_sys::ExecEndNode(runtime.child_plan);
                runtime.child_plan = ptr::null_mut();
            }
            snapshot_runtime_counters(state, runtime);
            drop(Box::from_raw((*state).runtime));
            (*state).runtime = ptr::null_mut();
        }
    }
}
