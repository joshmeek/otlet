#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_semantic_fdw_handler() -> *const pg_sys::Pg_finfo_record {
    &OTLET_SEMANTIC_FDW_FINFO
}

#[pgrx::pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_semantic_fdw_handler(
    _fcinfo: pg_sys::FunctionCallInfo,
) -> pg_sys::Datum {
    unsafe {
        let routine =
            pg_sys::palloc0(std::mem::size_of::<pg_sys::FdwRoutine>()) as *mut pg_sys::FdwRoutine;
        (*routine).type_ = pg_sys::NodeTag::T_FdwRoutine;
        (*routine).GetForeignRelSize = Some(otlet_semantic_get_foreign_rel_size);
        (*routine).GetForeignPaths = Some(otlet_semantic_get_foreign_paths);
        (*routine).GetForeignPlan = Some(otlet_semantic_get_foreign_plan);
        (*routine).BeginForeignScan = Some(otlet_semantic_begin_foreign_scan);
        (*routine).IterateForeignScan = Some(otlet_semantic_iterate_foreign_scan);
        (*routine).ReScanForeignScan = Some(otlet_semantic_rescan_foreign_scan);
        (*routine).EndForeignScan = Some(otlet_semantic_end_foreign_scan);
        (*routine).ExplainForeignScan = Some(otlet_semantic_explain_foreign_scan);
        (*routine).AnalyzeForeignTable = Some(otlet_semantic_analyze_foreign_table);
        (*routine).IsForeignRelUpdatable = Some(otlet_semantic_is_foreign_rel_updatable);
        (*routine).GetForeignRowMarkType = Some(otlet_semantic_get_foreign_row_mark_type);
        (*routine).ShutdownForeignScan = Some(otlet_semantic_shutdown_foreign_scan);
        (*routine).IsForeignScanParallelSafe = Some(otlet_semantic_is_foreign_scan_parallel_safe);
        pg_sys::Datum::from(routine as usize)
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_get_foreign_rel_size(
    _root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    foreigntableid: pg_sys::Oid,
) {
    unsafe {
        let rows = semantic_options(foreigntableid)
            .ok()
            .and_then(|opts| load_plan(&opts).ok())
            .map(|plan| plan.total_rows.max(1) as f64)
            .unwrap_or(1000.0);
        (*baserel).rows = rows;
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_get_foreign_paths(
    root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    foreigntableid: pg_sys::Oid,
) {
    unsafe {
        let pushdown =
            semantic_pushdown_from_restrictinfos((*baserel).baserestrictinfo, (*baserel).relid);
        let (rows, cost) = semantic_options(foreigntableid)
            .ok()
            .and_then(|opts| load_effective_plan(&opts, &pushdown).ok())
            .map(|plan| {
                let mut rows = if pushdown.has_filters() {
                    plan.total_rows.max(0) as f64
                } else {
                    plan.total_rows.max(1) as f64
                };
                let mut cost = match plan.selected_path.as_str() {
                    "semantic_lookup" => plan.estimated_lookup_ms,
                    "refresh_then_lookup" => plan.estimated_refresh_ms,
                    _ => plan.estimated_fresh_inference_ms,
                };
                if let Some(subjects) = pushdown.subjects() {
                    let pushed_rows = (subjects.len() as f64).min(rows).max(0.0);
                    if rows > 0.0 {
                        cost *= pushed_rows / rows;
                    }
                    rows = pushed_rows;
                } else if !pushdown.subject_param_filters.is_empty() {
                    if rows > 0.0 {
                        cost *= 1.0 / rows;
                    }
                    rows = 1.0_f64.min(rows).max(0.0);
                }
                (rows, cost.max(1.0))
            })
            .unwrap_or(((*baserel).rows.max(1.0), 1000.0));

        let path = pg_sys::create_foreignscan_path(
            root,
            baserel,
            ptr::null_mut(),
            rows,
            0,
            0.0,
            cost,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
        );
        pg_sys::add_path(baserel, path as *mut pg_sys::Path);

        let (join_clauses, required_outer) = subject_join_clauses(root, baserel, (*baserel).relid);
        if !join_clauses.is_null()
            && !required_outer.is_null()
            && pg_sys::bms_num_members(required_outer) > 0
        {
            let param_restrictinfo =
                pg_sys::list_concat_copy((*baserel).baserestrictinfo, join_clauses);
            let param_pushdown =
                semantic_pushdown_from_restrictinfos(param_restrictinfo, (*baserel).relid);
            let (param_rows, param_cost) = semantic_options(foreigntableid)
                .ok()
                .and_then(|opts| load_effective_plan(&opts, &param_pushdown).ok())
                .map(|plan| {
                    let mut rows = 1.0;
                    let mut cost = match plan.selected_path.as_str() {
                        "semantic_lookup" => plan.estimated_lookup_ms,
                        "refresh_then_lookup" => plan.estimated_refresh_ms,
                        _ => plan.estimated_fresh_inference_ms,
                    };
                    let base_rows = plan.total_rows.max(1) as f64;
                    if param_pushdown.has_concrete_materialization_filters() {
                        rows = (plan.total_rows.max(0) as f64).min(1.0);
                    }
                    if base_rows > 0.0 {
                        cost *= rows.max(1.0) / base_rows;
                    }
                    (rows, cost.max(0.05))
                })
                .unwrap_or((1.0, (cost / rows.max(1.0)).max(0.05)));
            let param_path = pg_sys::create_foreignscan_path(
                root,
                baserel,
                ptr::null_mut(),
                param_rows,
                0,
                0.0,
                param_cost,
                ptr::null_mut(),
                required_outer,
                ptr::null_mut(),
                param_restrictinfo,
                ptr::null_mut(),
            );
            pg_sys::add_path(baserel, param_path as *mut pg_sys::Path);
        }
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_get_foreign_plan(
    _root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    _foreigntableid: pg_sys::Oid,
    _best_path: *mut pg_sys::ForeignPath,
    tlist: *mut pg_sys::List,
    scan_clauses: *mut pg_sys::List,
    outer_plan: *mut pg_sys::Plan,
) -> *mut pg_sys::ForeignScan {
    unsafe {
        let quals = pg_sys::extract_actual_clauses(scan_clauses, false);
        let pushdown = semantic_pushdown_from_restrictinfos(scan_clauses, (*baserel).relid);
        let fdw_exprs = outer_subject_fdw_exprs(scan_clauses, (*baserel).relid);
        let fdw_private = fdw_private_from_pushdown(&pushdown);
        pg_sys::make_foreignscan(
            tlist,
            quals,
            (*baserel).relid,
            fdw_exprs,
            fdw_private,
            ptr::null_mut(),
            ptr::null_mut(),
            outer_plan,
        )
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_begin_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
    eflags: std::ffi::c_int,
) {
    unsafe {
        let rel = (*node).ss.ss_currentRelation;
        let relid = (*rel).rd_id;
        let opts = semantic_options(relid).unwrap_or_else(|err| pgrx::error!("{err}"));
        let base_pushdown = semantic_pushdown_from_fdw_private(node);
        let fdw_expr_states = init_fdw_expr_states(node);
        let outer_expr_typid = first_fdw_expr_typid(node);
        let state = if (eflags as u32 & pg_sys::EXEC_FLAG_EXPLAIN_ONLY) != 0 {
            let pushdown = base_pushdown.clone();
            load_explain_state(opts, pushdown, base_pushdown)
                .unwrap_or_else(|err| pgrx::error!("{err}"))
        } else {
            let pushdown = resolve_runtime_pushdown(
                node,
                base_pushdown.clone(),
                fdw_expr_states,
                outer_expr_typid,
            );
            let mut state = load_scan_state(opts, pushdown, base_pushdown)
                .unwrap_or_else(|err| pgrx::error!("{err}"));
            state.fdw_expr_states = fdw_expr_states;
            state.outer_expr_typid = outer_expr_typid;
            state
        };
        (*node).fdw_state = Box::into_raw(Box::new(state)) as *mut std::ffi::c_void;
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_iterate_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
) -> *mut pg_sys::TupleTableSlot {
    unsafe {
        let slot = (*node).ss.ss_ScanTupleSlot;
        pg_sys::ExecClearTuple(slot);

        let state = &mut *((*node).fdw_state as *mut SemanticFdwState);
        if state.next >= state.rows.len() {
            return slot;
        }

        let row = &state.rows[state.next];
        state.next += 1;
        state.rows_emitted += 1;

        let values = std::slice::from_raw_parts_mut((*slot).tts_values, 5);
        let nulls = std::slice::from_raw_parts_mut((*slot).tts_isnull, 5);
        nulls.fill(false);

        set_text(&mut values[0], &mut nulls[0], row.subject_id.as_deref());
        set_jsonb(&mut values[1], &mut nulls[1], row.body.as_ref());
        set_bool(&mut values[2], &mut nulls[2], row.stale);
        set_text(&mut values[3], &mut nulls[3], row.source_hash.as_deref());
        set_text(&mut values[4], &mut nulls[4], row.updated_at.as_deref());

        pg_sys::ExecStoreVirtualTuple(slot)
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_rescan_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
) {
    unsafe {
        let state = &mut *((*node).fdw_state as *mut SemanticFdwState);
        state.rescans += 1;
        if state.base_pushdown.has_runtime_filters() {
            let rows_loaded = state.rows_loaded;
            let rows_emitted = state.rows_emitted;
            let queued_jobs = state.queued_jobs;
            let rescans = state.rescans;
            let fdw_expr_states = state.fdw_expr_states;
            let outer_expr_typid = state.outer_expr_typid;
            let pushdown = resolve_runtime_pushdown(
                node,
                state.base_pushdown.clone(),
                fdw_expr_states,
                outer_expr_typid,
            );
            let mut new_state =
                load_scan_state(state.opts.clone(), pushdown, state.base_pushdown.clone())
                    .unwrap_or_else(|err| pgrx::error!("{err}"));
            new_state.rows_loaded += rows_loaded;
            new_state.rows_emitted += rows_emitted;
            new_state.queued_jobs += queued_jobs;
            new_state.rescans = rescans;
            new_state.fdw_expr_states = fdw_expr_states;
            new_state.outer_expr_typid = outer_expr_typid;
            *state = new_state;
            return;
        }
        state.next = 0;
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_end_foreign_scan(node: *mut pg_sys::ForeignScanState) {
    unsafe { drop_scan_state(node) }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_shutdown_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
) {
    unsafe { drop_scan_state(node) }
}

unsafe fn drop_scan_state(node: *mut pg_sys::ForeignScanState) {
    unsafe {
        if !node.is_null() && !(*node).fdw_state.is_null() {
            store_explain_snapshot(node);
            drop(Box::from_raw((*node).fdw_state as *mut SemanticFdwState));
            (*node).fdw_state = ptr::null_mut();
        }
    }
}

unsafe fn store_explain_snapshot(node: *mut pg_sys::ForeignScanState) {
    unsafe {
        if node.is_null() || (*node).fdw_state.is_null() || (*node).ss.ps.instrument.is_null() {
            return;
        }
        let state = &*((*node).fdw_state as *mut SemanticFdwState);
        if let Ok(mut snapshots) = fdw_explain_snapshots().lock() {
            snapshots.insert(node as usize, state.explain_snapshot());
        }
    }
}

fn take_explain_snapshot(
    node: *mut pg_sys::ForeignScanState,
) -> Option<SemanticFdwExplainSnapshot> {
    fdw_explain_snapshots()
        .lock()
        .ok()
        .and_then(|mut snapshots| snapshots.remove(&(node as usize)))
}

fn fdw_explain_snapshots() -> &'static Mutex<HashMap<usize, SemanticFdwExplainSnapshot>> {
    FDW_EXPLAIN_SNAPSHOTS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_is_foreign_rel_updatable(
    _rel: pg_sys::Relation,
) -> std::ffi::c_int {
    0
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_get_foreign_row_mark_type(
    _rte: *mut pg_sys::RangeTblEntry,
    _strength: pg_sys::LockClauseStrength::Type,
) -> pg_sys::RowMarkType::Type {
    pg_sys::RowMarkType::ROW_MARK_COPY
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_is_foreign_scan_parallel_safe(
    _root: *mut pg_sys::PlannerInfo,
    _rel: *mut pg_sys::RelOptInfo,
    _rte: *mut pg_sys::RangeTblEntry,
) -> bool {
    false
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_analyze_foreign_table(
    relation: pg_sys::Relation,
    func: *mut pg_sys::AcquireSampleRowsFunc,
    totalpages: *mut pg_sys::BlockNumber,
) -> bool {
    unsafe {
        if relation.is_null() || func.is_null() || totalpages.is_null() {
            return false;
        }
        *func = Some(otlet_semantic_acquire_sample_rows);
        *totalpages = 1;
        true
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_semantic_acquire_sample_rows(
    relation: pg_sys::Relation,
    _elevel: std::ffi::c_int,
    rows: *mut pg_sys::HeapTuple,
    targrows: std::ffi::c_int,
    totalrows: *mut f64,
    totaldeadrows: *mut f64,
) -> std::ffi::c_int {
    unsafe {
        if !totalrows.is_null() {
            *totalrows = 0.0;
        }
        if !totaldeadrows.is_null() {
            *totaldeadrows = 0.0;
        }
        if relation.is_null() || rows.is_null() || targrows <= 0 {
            return 0;
        }

        let opts = match semantic_options((*relation).rd_id) {
            Ok(opts) => opts,
            Err(err) => {
                pgrx::warning!("otlet semantic FDW analyze skipped: {err}");
                return 0;
            }
        };
        let (fresh_rows, samples) = match load_analyze_sample_rows(&opts, targrows as usize) {
            Ok(sample) => sample,
            Err(err) => {
                pgrx::warning!("otlet semantic FDW analyze skipped: {err}");
                return 0;
            }
        };

        if !totalrows.is_null() {
            *totalrows = fresh_rows as f64;
        }
        let mut count = 0usize;
        for row in samples.into_iter().take(targrows as usize) {
            let mut values = [pg_sys::Datum::from(0usize); 5];
            let mut nulls = [false; 5];
            set_text(&mut values[0], &mut nulls[0], row.subject_id.as_deref());
            set_jsonb(&mut values[1], &mut nulls[1], row.body.as_ref());
            set_bool(&mut values[2], &mut nulls[2], row.stale);
            set_text(&mut values[3], &mut nulls[3], row.source_hash.as_deref());
            set_text(&mut values[4], &mut nulls[4], row.updated_at.as_deref());

            let tuple =
                pg_sys::heap_form_tuple((*relation).rd_att, values.as_ptr(), nulls.as_ptr());
            if !tuple.is_null() {
                *rows.add(count) = tuple;
                count += 1;
            }
        }
        count as std::ffi::c_int
    }
}
