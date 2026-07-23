#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_set_rel_pathlist(
    root: *mut pg_sys::PlannerInfo,
    rel: *mut pg_sys::RelOptInfo,
    rti: pg_sys::Index,
    rte: *mut pg_sys::RangeTblEntry,
) {
    unsafe {
        if let Some(prev) = PREV_SET_REL_PATHLIST_HOOK {
            prev(root, rel, rti, rte);
        }

        if root.is_null() || rel.is_null() || rte.is_null() || (*rel).baserestrictinfo.is_null() {
            return;
        }
        if (*rte).rtekind != pg_sys::RTEKind::RTE_RELATION
            && (*rte).rtekind != pg_sys::RTEKind::RTE_SUBQUERY
        {
            return;
        }
        let relid = ((*rte).rtekind == pg_sys::RTEKind::RTE_RELATION).then(|| (*rte).relid);
        let Some(predicate) =
            find_semantic_match_predicate((*rel).baserestrictinfo, rti, relid, (*rte).rtekind)
        else {
            return;
        };
        if relation_has_rowmark(root, rti)
            || !(*root).parent_root.is_null()
            || (*root).hasLateralRTEs
            || rel_has_parameterized_restrictinfo(rel)
            || rel_has_lateral_ref(rel)
        {
            return;
        }
        let (target_has_subject, target_has_rel_var) =
            path_target_var_flags((*rel).reltarget, rti, predicate.subject_attno);
        let executor_owned_policy = predicate.auto_policy
            || predicate.allow_refresh
            || predicate.wait_ms > 0
            || predicate.infer_ms > 0;
        if !target_has_subject
            && (predicate.index_kind == SemanticIndexKind::Join
                || (!executor_owned_policy && !target_has_rel_var))
        {
            return;
        }
        let child_path = if predicate.index_kind == SemanticIndexKind::Join {
            sanitized_subquery_child_path(
                root,
                rel,
                (*rel).baserestrictinfo,
                predicate.restrict_info,
            )
        } else {
            ptr::null_mut()
        };
        if predicate.index_kind == SemanticIndexKind::Join && child_path.is_null() {
            return;
        }
        let filtered_row_cost = 1.0 + (*rel).rows.max(predicate.estimated_rows).max(1.0) * 0.02;
        let custom_total_cost = if predicate.index_kind == SemanticIndexKind::Join
            && (predicate.auto_policy
                || predicate.allow_refresh
                || predicate.wait_ms > 0
                || predicate.infer_ms > 0)
        {
            filtered_row_cost
        } else {
            predicate.planner_stats.path_cost.max(filtered_row_cost)
        };
        let custom_path =
            pg_sys::palloc0(size_of::<pg_sys::CustomPath>()).cast::<pg_sys::CustomPath>();
        (*custom_path).path.type_ = pg_sys::NodeTag::T_CustomPath;
        (*custom_path).path.pathtype = pg_sys::NodeTag::T_CustomScan;
        (*custom_path).path.parent = rel;
        (*custom_path).path.pathtarget = (*rel).reltarget;
        (*custom_path).path.param_info = ptr::null_mut();
        (*custom_path).path.parallel_aware = false;
        (*custom_path).path.parallel_safe = false;
        (*custom_path).path.parallel_workers = 0;
        (*custom_path).path.rows = predicate.estimated_rows.min((*rel).rows).max(0.0);
        (*custom_path).path.disabled_nodes = 0;
        (*custom_path).path.startup_cost = 1.0;
        (*custom_path).path.total_cost = custom_total_cost;
        (*custom_path).path.pathkeys = ptr::null_mut();
        (*custom_path).flags = pg_sys::CUSTOMPATH_SUPPORT_PROJECTION;
        (*custom_path).custom_paths = if child_path.is_null() {
            ptr::null_mut()
        } else {
            list_make1(child_path.cast())
        };
        (*custom_path).custom_restrictinfo = list_make1(predicate.restrict_info.cast());
        (*custom_path).custom_private = custom_private_from_predicate(&predicate);
        (*custom_path).methods = &raw const CUSTOM_PATH_METHODS;

        pg_sys::add_path(rel, custom_path.cast());
        pg_sys::set_cheapest(rel);
    }
}

unsafe fn relation_has_rowmark(root: *mut pg_sys::PlannerInfo, rti: pg_sys::Index) -> bool {
    unsafe {
        if root.is_null() || (*root).rowMarks.is_null() {
            return false;
        }
        for i in 0..pg_sys::list_length((*root).rowMarks) {
            let rowmark = pg_sys::list_nth((*root).rowMarks, i).cast::<pg_sys::PlanRowMark>();
            if !rowmark.is_null() && ((*rowmark).rti == rti || (*rowmark).prti == rti) {
                return true;
            }
        }
        false
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn plan_semantic_custom_path(
    root: *mut pg_sys::PlannerInfo,
    rel: *mut pg_sys::RelOptInfo,
    best_path: *mut pg_sys::CustomPath,
    tlist: *mut pg_sys::List,
    clauses: *mut pg_sys::List,
    custom_plans: *mut pg_sys::List,
) -> *mut pg_sys::Plan {
    unsafe {
        let private = custom_private_from_list((*best_path).custom_private);
        let is_join_index = private
            .as_ref()
            .is_some_and(|private| private.index_kind == SemanticIndexKind::Join);
        let child_scan = if is_join_index {
            planned_custom_child_plan(custom_plans)
        } else {
            postgres_child_scan_plan(root, rel, best_path, clauses)
        };
        if child_scan.is_null() {
            pgrx::error!("otlet semantic CustomScan could not plan stripped source child scan");
        }
        if is_join_index && !rel.is_null() {
            strip_owned_semantic_quals_from_plan(
                child_scan,
                (*best_path).custom_restrictinfo,
                (*rel).relid,
            );
        }

        let cscan =
            pg_sys::palloc0(size_of::<pg_sys::CustomScan>()).cast::<pg_sys::CustomScan>();
        (*cscan).scan.plan.type_ = pg_sys::NodeTag::T_CustomScan;
        (*cscan).scan.plan.disabled_nodes = (*best_path).path.disabled_nodes;
        (*cscan).scan.plan.startup_cost = (*best_path).path.startup_cost;
        (*cscan).scan.plan.total_cost = (*best_path).path.total_cost;
        (*cscan).scan.plan.plan_rows = (*best_path).path.rows;
        (*cscan).scan.plan.plan_width = if (*best_path).path.pathtarget.is_null() {
            0
        } else {
            (*(*best_path).path.pathtarget).width
        };
        (*cscan).scan.plan.parallel_aware = false;
        (*cscan).scan.plan.parallel_safe = false;
        (*cscan).scan.plan.async_capable = false;
        (*cscan).scan.plan.targetlist = tlist;
        (*cscan).scan.plan.qual = ptr::null_mut();
        (*cscan).scan.scanrelid = if is_join_index || rel.is_null() {
            0
        } else {
            (*rel).relid
        };
        (*cscan).flags = (*best_path).flags;
        (*cscan).custom_plans = list_make1(child_scan.cast());
        (*cscan).custom_exprs = ptr::null_mut();
        (*cscan).custom_private = pg_sys::list_copy_deep((*best_path).custom_private);
        (*cscan).custom_scan_tlist = if is_join_index {
            (*child_scan).targetlist
        } else {
            ptr::null_mut()
        };
        (*cscan).custom_relids = if rel.is_null() {
            ptr::null_mut()
        } else {
            pg_sys::bms_copy((*rel).relids)
        };
        (*cscan).methods = &raw const CUSTOM_SCAN_METHODS;
        cscan.cast()
    }
}

fn planner_stats_with_reason(reason: &'static str) -> SemanticPlannerStats {
    SemanticPlannerStats {
        selected_path: "semantic_lookup".to_owned(),
        reason: reason.to_owned(),
        source_rows: 0,
        fresh_matches: 0,
        fresh_non_matches: 0,
        stale_rows: 0,
        missing_rows: 0,
        inflight_rows: 0,
        cache_reusable_rows: 0,
        infer_decision_rows: 0,
        fail_closed_decision_rows: 0,
        model_ms: 2500.0,
        model_cost_source: "static_fallback".to_owned(),
        path_cost: 1.0,
        stale_reasons: "{}".to_owned(),
        count_basis: "unknown".to_owned(),
    }
}

fn finish_planner_stats(
    stats: &mut SemanticPlannerStats,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    auto_policy: bool,
) {
    let unresolved = stats
        .stale_rows
        .saturating_add(stats.missing_rows)
        .saturating_add(stats.inflight_rows);
    let base_scan = stats.source_rows.max(1) as f64 * 0.02 + 1.0;
    let lookup_cost = stats.fresh_matches.saturating_add(stats.fresh_non_matches) as f64 * 0.05;
    let model_cost = planner_model_cost_unit(stats.model_ms, infer_ms);
    stats.infer_decision_rows = 0;
    stats.fail_closed_decision_rows = 0;
    if auto_policy {
        let inferable_rows = stats.stale_rows.saturating_add(stats.missing_rows);
        let waited_rows = if wait_ms > 0 { stats.inflight_rows } else { 0 };
        let bounded_infer_rows = if infer_ms > 0 && infer_max_rows > 0 {
            inferable_rows.min(u64::from(infer_max_rows))
        } else {
            0
        };
        let infer_cost = planner_bounded_infer_cost(stats, bounded_infer_rows, model_cost);
        let queued_rows = if allow_refresh {
            inferable_rows.saturating_sub(bounded_infer_rows)
        } else {
            0
        };
        let fail_closed_rows = unresolved
            .saturating_sub(waited_rows)
            .saturating_sub(bounded_infer_rows)
            .saturating_sub(queued_rows);
        stats.infer_decision_rows = bounded_infer_rows;
        stats.fail_closed_decision_rows = fail_closed_rows;
        stats.path_cost = base_scan
            + lookup_cost
            + waited_rows as f64 * (f64::from(wait_ms) / 100.0)
            + infer_cost
            + queued_rows as f64 * 0.50;
        stats.selected_path = selected_path_from_decisions(
            bounded_infer_rows,
            waited_rows,
            queued_rows,
            fail_closed_rows,
        )
        .to_owned();
        if unresolved > 0 {
            stats.reason = format!(
                "auto semantic policy: fresh={} wait={} infer={} queue={} fail_closed={}",
                stats.fresh_matches, waited_rows, bounded_infer_rows, queued_rows, fail_closed_rows
            );
        } else {
            stats.reason = format!(
                "auto semantic policy: all source rows resolved from fresh semantic state; fresh={}",
                stats.fresh_matches
            );
        }
    } else if infer_ms > 0 && infer_max_rows > 0 && unresolved > 0 {
        let bounded_infer_rows = stats
            .stale_rows
            .saturating_add(stats.missing_rows)
            .min(u64::from(infer_max_rows));
        stats.infer_decision_rows = bounded_infer_rows;
        stats.fail_closed_decision_rows = unresolved.saturating_sub(bounded_infer_rows);
        stats.path_cost = base_scan
            + lookup_cost
            + planner_bounded_infer_cost(stats, bounded_infer_rows, model_cost);
        stats.selected_path = "bounded_infer_now".to_owned();
        stats.reason = format!(
            "bounded infer-now over {bounded_infer_rows} unresolved rows; fresh={} stale={} missing={} in_flight={}",
            stats.fresh_matches, stats.stale_rows, stats.missing_rows, stats.inflight_rows
        );
    } else if wait_ms > 0 && stats.inflight_rows > 0 {
        stats.fail_closed_decision_rows = unresolved.saturating_sub(stats.inflight_rows);
        stats.path_cost =
            base_scan + lookup_cost + (stats.inflight_rows as f64 * f64::from(wait_ms) / 100.0);
        stats.selected_path = "wait_for_refresh".to_owned();
        stats.reason = format!(
            "bounded wait for {} in-flight rows; fresh={} stale={} missing={}",
            stats.inflight_rows, stats.fresh_matches, stats.stale_rows, stats.missing_rows
        );
    } else if allow_refresh && unresolved > 0 {
        stats.path_cost = base_scan + lookup_cost + unresolved as f64 * 0.50;
        stats.selected_path = "queue_refresh".to_owned();
        stats.reason = format!(
            "queue refresh and fail closed for {unresolved} unresolved rows; fresh={}",
            stats.fresh_matches
        );
    } else if unresolved > 0 {
        stats.fail_closed_decision_rows = unresolved;
        stats.path_cost = base_scan + lookup_cost;
        stats.selected_path = "lookup_fail_closed".to_owned();
        stats.reason = format!(
            "fail closed for {unresolved} unresolved rows; fresh={}",
            stats.fresh_matches
        );
    } else {
        stats.path_cost = base_scan + lookup_cost;
        stats.selected_path = "semantic_lookup".to_owned();
        stats.reason = format!(
            "all source rows resolved from fresh semantic state; fresh={}",
            stats.fresh_matches
        );
    }
}

fn selected_path_from_decisions(
    infer_rows: u64,
    wait_rows: u64,
    queue_rows: u64,
    fail_closed_rows: u64,
) -> &'static str {
    if infer_rows > 0 {
        "bounded_infer_now"
    } else if wait_rows > 0 {
        "wait_for_refresh"
    } else if queue_rows > 0 {
        "queue_refresh"
    } else if fail_closed_rows > 0 {
        "lookup_fail_closed"
    } else {
        "semantic_lookup"
    }
}

fn planner_model_cost_unit(model_ms: f64, infer_ms: u32) -> f64 {
    let fallback_ms = if infer_ms > 0 {
        f64::from(infer_ms)
    } else {
        2500.0
    };
    let ms = if model_ms.is_finite() && model_ms > 0.0 {
        model_ms
    } else {
        fallback_ms
    };
    (ms / 100.0).max(0.01)
}

fn planner_bounded_infer_cost(
    stats: &SemanticPlannerStats,
    bounded_infer_rows: u64,
    model_cost: f64,
) -> f64 {
    let cache_reusable_rows = stats.cache_reusable_rows.min(bounded_infer_rows);
    let model_rows = bounded_infer_rows.saturating_sub(cache_reusable_rows);
    model_rows as f64 * model_cost + cache_reusable_rows as f64 * PLANNER_CACHE_HIT_COST_UNIT
}

const PLANNER_CACHE_HIT_COST_UNIT: f64 = 0.05;

fn estimated_result_rows(stats: &SemanticPlannerStats, predicate: &SemanticMatchPredicate) -> f64 {
    let mut rows = stats.fresh_matches;
    if predicate.auto_policy {
        if predicate.wait_ms > 0 {
            rows = rows.saturating_add(stats.inflight_rows);
        }
        if predicate.infer_ms > 0 && predicate.infer_max_rows > 0 {
            rows = rows.saturating_add(
                stats
                    .stale_rows
                    .saturating_add(stats.missing_rows)
                    .min(u64::from(predicate.infer_max_rows)),
            );
        }
    } else if predicate.infer_ms > 0 && predicate.infer_max_rows > 0 {
        rows = rows.saturating_add(
            stats
                .stale_rows
                .saturating_add(stats.missing_rows)
                .min(u64::from(predicate.infer_max_rows)),
        );
    } else if predicate.wait_ms > 0 {
        rows = rows.saturating_add(stats.inflight_rows);
    }
    rows as f64
}
