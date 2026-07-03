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
        (*routine).ShutdownForeignScan = Some(otlet_semantic_shutdown_foreign_scan);
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
            .map(|plan| plan.total_subjects.max(1) as f64)
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
                    plan.total_subjects.max(0) as f64
                } else {
                    plan.total_subjects.max(1) as f64
                };
                let mut cost = plan.path_cost;
                if let Some(subjects) = pushdown.subjects() {
                    let pushed_rows = (subjects.len() as f64).min(rows).max(0.0);
                    if rows > 0.0 {
                        cost *= pushed_rows / rows;
                    }
                    rows = pushed_rows;
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
        let fdw_private = fdw_private_from_pushdown(&pushdown);
        pg_sys::make_foreignscan(
            tlist,
            quals,
            (*baserel).relid,
            ptr::null_mut(),
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
        let pushdown = semantic_pushdown_from_fdw_private(node);
        let state = if (eflags as u32 & pg_sys::EXEC_FLAG_EXPLAIN_ONLY) != 0 {
            load_explain_state(opts, pushdown).unwrap_or_else(|err| pgrx::error!("{err}"))
        } else {
            load_scan_state(opts, pushdown).unwrap_or_else(|err| pgrx::error!("{err}"))
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

        let values = std::slice::from_raw_parts_mut((*slot).tts_values, 6);
        let nulls = std::slice::from_raw_parts_mut((*slot).tts_isnull, 6);
        nulls.fill(false);

        set_text(&mut values[0], &mut nulls[0], row.subject_id.as_deref());
        set_jsonb(&mut values[1], &mut nulls[1], row.body.as_ref());
        set_bool(&mut values[2], &mut nulls[2], row.stale);
        set_text(&mut values[3], &mut nulls[3], row.source_hash.as_deref());
        set_text(
            &mut values[4],
            &mut nulls[4],
            row.freshness_basis.as_deref(),
        );
        set_text(&mut values[5], &mut nulls[5], row.updated_at.as_deref());

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
