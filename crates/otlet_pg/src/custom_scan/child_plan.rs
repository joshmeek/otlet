unsafe fn postgres_child_scan_plan(
    root: *mut pg_sys::PlannerInfo,
    rel: *mut pg_sys::RelOptInfo,
    best_path: *mut pg_sys::CustomPath,
    clauses: *mut pg_sys::List,
) -> *mut pg_sys::Plan {
    unsafe {
        if root.is_null() || rel.is_null() || best_path.is_null() {
            return ptr::null_mut();
        }
        let old_baserestrictinfo = (*rel).baserestrictinfo;
        let old_pathlist = (*rel).pathlist;
        let old_partial_pathlist = (*rel).partial_pathlist;
        let old_cheapest_startup_path = (*rel).cheapest_startup_path;
        let old_cheapest_total_path = (*rel).cheapest_total_path;
        let old_cheapest_unique_path = (*rel).cheapest_unique_path;
        let old_cheapest_parameterized_paths = (*rel).cheapest_parameterized_paths;
        (*rel).baserestrictinfo =
            non_semantic_restrictinfos(clauses, (*best_path).custom_restrictinfo);
        (*rel).pathlist = ptr::null_mut();
        (*rel).partial_pathlist = ptr::null_mut();
        (*rel).cheapest_startup_path = ptr::null_mut();
        (*rel).cheapest_total_path = ptr::null_mut();
        (*rel).cheapest_unique_path = ptr::null_mut();
        (*rel).cheapest_parameterized_paths = ptr::null_mut();

        let seq_path = pg_sys::create_seqscan_path(root, rel, ptr::null_mut(), 0);
        if !seq_path.is_null() {
            pg_sys::add_path(rel, seq_path);
        }
        pg_sys::create_index_paths(root, rel);
        let child_path = cheapest_postgres_child_scan_path(rel).unwrap_or(seq_path);
        let child_plan = if child_path.is_null() {
            ptr::null_mut()
        } else {
            pg_sys::create_plan(root, child_path)
        };
        strip_owned_semantic_quals_from_plan(
            child_plan,
            (*best_path).custom_restrictinfo,
            (*rel).relid,
        );
        (*rel).baserestrictinfo = old_baserestrictinfo;
        (*rel).pathlist = old_pathlist;
        (*rel).partial_pathlist = old_partial_pathlist;
        (*rel).cheapest_startup_path = old_cheapest_startup_path;
        (*rel).cheapest_total_path = old_cheapest_total_path;
        (*rel).cheapest_unique_path = old_cheapest_unique_path;
        (*rel).cheapest_parameterized_paths = old_cheapest_parameterized_paths;
        child_plan
    }
}

unsafe fn planned_custom_child_plan(custom_plans: *mut pg_sys::List) -> *mut pg_sys::Plan {
    unsafe {
        if custom_plans.is_null() || pg_sys::list_length(custom_plans) == 0 {
            ptr::null_mut()
        } else {
            pg_sys::list_nth(custom_plans, 0).cast::<pg_sys::Plan>()
        }
    }
}

unsafe fn sanitized_subquery_child_path(
    root: *mut pg_sys::PlannerInfo,
    rel: *mut pg_sys::RelOptInfo,
    clauses: *mut pg_sys::List,
    semantic_restrictinfo: *mut pg_sys::RestrictInfo,
) -> *mut pg_sys::Path {
    unsafe {
        if root.is_null() || rel.is_null() || (*rel).pathlist.is_null() {
            return ptr::null_mut();
        }
        let existing = cheapest_subquery_scan_path(rel);
        if existing.is_null() {
            return ptr::null_mut();
        }
        let subquery_path = existing.cast::<pg_sys::SubqueryScanPath>();
        if subquery_path.is_null() || (*subquery_path).subpath.is_null() {
            return ptr::null_mut();
        }
        let old_baserestrictinfo = (*rel).baserestrictinfo;
        (*rel).baserestrictinfo =
            non_semantic_restrictinfos(clauses, list_make1(semantic_restrictinfo.cast()));
        let sanitized = pg_sys::create_subqueryscan_path(
            root,
            rel,
            (*subquery_path).subpath,
            false,
            (*existing).pathkeys,
            if (*existing).param_info.is_null() {
                ptr::null_mut()
            } else {
                (*(*existing).param_info).ppi_req_outer
            },
        );
        (*rel).baserestrictinfo = old_baserestrictinfo;
        if sanitized.is_null() {
            ptr::null_mut()
        } else {
            sanitized.cast()
        }
    }
}

unsafe fn cheapest_subquery_scan_path(rel: *mut pg_sys::RelOptInfo) -> *mut pg_sys::Path {
    unsafe {
        if rel.is_null() || (*rel).pathlist.is_null() {
            return ptr::null_mut();
        }
        let mut best: *mut pg_sys::Path = ptr::null_mut();
        for idx in 0..pg_sys::list_length((*rel).pathlist) {
            let path = pg_sys::list_nth((*rel).pathlist, idx).cast::<pg_sys::Path>();
            if path.is_null() || (*path).pathtype != pg_sys::NodeTag::T_SubqueryScan {
                continue;
            }
            if best.is_null() || (*path).total_cost < (*best).total_cost {
                best = path;
            }
        }
        best
    }
}

unsafe fn cheapest_postgres_child_scan_path(
    rel: *mut pg_sys::RelOptInfo,
) -> Option<*mut pg_sys::Path> {
    unsafe {
        if rel.is_null() || (*rel).pathlist.is_null() {
            return None;
        }
        let mut best: *mut pg_sys::Path = ptr::null_mut();
        for idx in 0..pg_sys::list_length((*rel).pathlist) {
            let path = pg_sys::list_nth((*rel).pathlist, idx).cast::<pg_sys::Path>();
            if path.is_null() || !is_supported_child_scan_path(path) {
                continue;
            }
            if best.is_null() || (*path).total_cost < (*best).total_cost {
                best = path;
            }
        }
        if best.is_null() { None } else { Some(best) }
    }
}

unsafe fn is_supported_child_scan_path(path: *mut pg_sys::Path) -> bool {
    unsafe {
        matches!(
            (*path).pathtype,
            pg_sys::NodeTag::T_SeqScan
                | pg_sys::NodeTag::T_IndexScan
                | pg_sys::NodeTag::T_BitmapHeapScan
        )
    }
}

unsafe fn strip_owned_semantic_quals_from_plan(
    plan: *mut pg_sys::Plan,
    semantic_restrictinfos: *mut pg_sys::List,
    rti: pg_sys::Index,
) {
    unsafe {
        if plan.is_null() {
            return;
        }
        (*plan).qual = non_semantic_plan_quals((*plan).qual, semantic_restrictinfos, rti);
    }
}

unsafe fn non_semantic_plan_quals(
    clauses: *mut pg_sys::List,
    semantic_restrictinfos: *mut pg_sys::List,
    rti: pg_sys::Index,
) -> *mut pg_sys::List {
    unsafe {
        let mut output: *mut pg_sys::List = ptr::null_mut();
        for idx in 0..pg_sys::list_length(clauses) {
            let clause = pg_sys::list_nth(clauses, idx);
            if clause.is_null() || is_owned_semantic_plan_qual(clause, semantic_restrictinfos, rti)
            {
                continue;
            }
            output = if output.is_null() {
                list_make1(clause)
            } else {
                pg_sys::lappend(output, clause)
            };
        }
        output
    }
}

unsafe fn is_owned_semantic_plan_qual(
    clause: *mut std::ffi::c_void,
    semantic_restrictinfos: *mut pg_sys::List,
    rti: pg_sys::Index,
) -> bool {
    unsafe {
        if is_semantic_restrictinfo(clause, semantic_restrictinfos) {
            return true;
        }
        let clause_expr = actual_clause_expr(clause);
        if clause_expr.is_null() {
            return false;
        }
        let Some(clause_predicate) = semantic_match_from_clause(clause_expr, rti) else {
            return false;
        };
        for idx in 0..pg_sys::list_length(semantic_restrictinfos) {
            let semantic =
                pg_sys::list_nth(semantic_restrictinfos, idx).cast::<pg_sys::RestrictInfo>();
            if semantic.is_null() {
                continue;
            }
            let semantic_expr = actual_clause_expr(semantic.cast());
            if semantic_expr.is_null() {
                continue;
            }
            if let Some(semantic_predicate) = semantic_match_from_clause(semantic_expr, rti)
                && same_semantic_signature(&clause_predicate, &semantic_predicate)
            {
                return true;
            }
        }
        false
    }
}

fn same_semantic_signature(left: &SemanticMatchPredicate, right: &SemanticMatchPredicate) -> bool {
    left.index_kind == right.index_kind
        && left.index_name == right.index_name
        && left.expected_json == right.expected_json
        && left.auto_policy == right.auto_policy
        && left.allow_refresh == right.allow_refresh
        && left.wait_ms == right.wait_ms
        && left.infer_ms == right.infer_ms
        && left.infer_max_rows == right.infer_max_rows
        && left.subject_attno == right.subject_attno
        && left.subject_typid == right.subject_typid
}

unsafe fn non_semantic_restrictinfos(
    clauses: *mut pg_sys::List,
    semantic_restrictinfos: *mut pg_sys::List,
) -> *mut pg_sys::List {
    unsafe {
        let mut restrictinfos: *mut pg_sys::List = ptr::null_mut();
        for idx in 0..pg_sys::list_length(clauses) {
            let clause = pg_sys::list_nth(clauses, idx);
            if clause.is_null() || is_semantic_restrictinfo(clause, semantic_restrictinfos) {
                continue;
            }
            restrictinfos = if restrictinfos.is_null() {
                list_make1(clause)
            } else {
                pg_sys::lappend(restrictinfos, clause)
            };
        }
        restrictinfos
    }
}

unsafe fn is_semantic_restrictinfo(
    clause: *mut std::ffi::c_void,
    semantic_restrictinfos: *mut pg_sys::List,
) -> bool {
    unsafe {
        for idx in 0..pg_sys::list_length(semantic_restrictinfos) {
            let semantic =
                pg_sys::list_nth(semantic_restrictinfos, idx).cast::<pg_sys::RestrictInfo>();
            if semantic.is_null() {
                continue;
            }
            if clause == semantic.cast() {
                return true;
            }
            let actual = actual_clause_expr(clause);
            if !actual.is_null() && actual == (*semantic).clause {
                return true;
            }
        }
        false
    }
}

unsafe fn actual_clause_expr(clause: *mut std::ffi::c_void) -> *mut pg_sys::Expr {
    unsafe {
        let node = clause.cast::<pg_sys::Node>();
        if node.is_null() {
            return ptr::null_mut();
        }
        if (*node).type_ == pg_sys::NodeTag::T_RestrictInfo {
            let rinfo = clause.cast::<pg_sys::RestrictInfo>();
            if rinfo.is_null() {
                ptr::null_mut()
            } else {
                (*rinfo).clause
            }
        } else {
            clause.cast::<pg_sys::Expr>()
        }
    }
}
