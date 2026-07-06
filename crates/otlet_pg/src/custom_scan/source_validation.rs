unsafe fn is_otlet_function(funcid: pg_sys::Oid, expected_name: &str) -> bool {
    unsafe {
        let func_name = pg_sys::get_func_name(funcid);
        if func_name.is_null() {
            return false;
        }
        let name = CStr::from_ptr(func_name).to_string_lossy();
        if name.as_ref() != expected_name {
            return false;
        }
        let namespace = pg_sys::get_func_namespace(funcid);
        let namespace_name = pg_sys::get_namespace_name(namespace);
        !namespace_name.is_null()
            && CStr::from_ptr(namespace_name).to_string_lossy().as_ref() == "otlet"
    }
}

#[derive(Clone, Copy)]
struct SubjectVar {
    attno: i16,
    typid: pg_sys::Oid,
}

unsafe fn subject_var(node: *mut pg_sys::Expr, rti: pg_sys::Index) -> Option<SubjectVar> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() {
            return None;
        }
        let candidate = if (*node).type_ == pg_sys::NodeTag::T_CoerceViaIO {
            let coerce = node as *mut pg_sys::CoerceViaIO;
            if (*coerce).resulttype != pg_sys::TEXTOID {
                return None;
            }
            strip_relabel((*coerce).arg)
        } else {
            node
        };
        if candidate.is_null() || (*candidate).type_ != pg_sys::NodeTag::T_Var {
            return None;
        }
        let var = candidate as *mut pg_sys::Var;
        if (*var).varno < 0 || u32::try_from((*var).varno).ok() != Some(rti) || (*var).varattno <= 0
        {
            return None;
        }
        Some(SubjectVar {
            attno: (*var).varattno,
            typid: (*var).vartype,
        })
    }
}

unsafe fn path_target_has_subject_var(
    target: *mut pg_sys::PathTarget,
    rti: pg_sys::Index,
    subject_attno: i16,
) -> bool {
    unsafe {
        if target.is_null() || (*target).exprs.is_null() {
            return false;
        }
        for idx in 0..pg_sys::list_length((*target).exprs) {
            let expr = strip_relabel(pg_sys::list_nth((*target).exprs, idx) as *mut pg_sys::Expr);
            if expr.is_null() || (*expr).type_ != pg_sys::NodeTag::T_Var {
                continue;
            }
            let var = expr as *mut pg_sys::Var;
            if (*var).varno >= 0
                && u32::try_from((*var).varno).ok() == Some(rti)
                && (*var).varattno == subject_attno
            {
                return true;
            }
        }
        false
    }
}

unsafe fn path_target_has_rel_var(target: *mut pg_sys::PathTarget, rti: pg_sys::Index) -> bool {
    unsafe {
        if target.is_null() || (*target).exprs.is_null() {
            return false;
        }
        for idx in 0..pg_sys::list_length((*target).exprs) {
            let expr = strip_relabel(pg_sys::list_nth((*target).exprs, idx) as *mut pg_sys::Expr);
            if expr.is_null() || (*expr).type_ != pg_sys::NodeTag::T_Var {
                continue;
            }
            let var = expr as *mut pg_sys::Var;
            if (*var).varno >= 0
                && u32::try_from((*var).varno).ok() == Some(rti)
                && (*var).varattno > 0
            {
                return true;
            }
        }
        false
    }
}

unsafe fn rel_has_lateral_ref(rel: *mut pg_sys::RelOptInfo) -> bool {
    unsafe {
        !rel.is_null()
            && (!(*rel).direct_lateral_relids.is_null()
                || !(*rel).lateral_relids.is_null()
                || !(*rel).lateral_vars.is_null())
    }
}

fn validate_semantic_index_source(
    index_name: &str,
    relid: pg_sys::Oid,
    subject_attno: i16,
    expected_json: &str,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    auto_policy: bool,
) -> Option<(SemanticPlannerStats, Option<Vec<String>>)> {
    let metadata_query = format!(
        "SELECT \
           si.source_table, \
           si.subject_column, \
           CASE WHEN si.input_columns IS NULL THEN NULL ELSE to_jsonb(si.input_columns)::text END AS input_columns_json \
         FROM otlet.semantic_indexes si \
         WHERE si.name = {} AND si.source_table::regclass = {}::oid \
         LIMIT 1",
        sql_literal(index_name),
        relid.to_u32()
    );

    match pgrx::Spi::connect(|client| {
        let metadata = client
            .select(metadata_query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        if metadata.is_empty() {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(None);
        }
        let row = metadata.first();
        let Some(source_table) = row
            .get_by_name::<String, _>("source_table")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(None);
        };
        let Some(subject_column) = row
            .get_by_name::<String, _>("subject_column")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(None);
        };
        if source_table.is_empty() || subject_column.is_empty() {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(None);
        }
        let input_columns = row
            .get_by_name::<String, _>("input_columns_json")
            .map_err(to_string)?
            .map(|json| serde_json::from_str::<Vec<String>>(&json).map_err(to_string))
            .transpose()?;
        let subject_column_cstr = CString::new(subject_column.as_str()).map_err(to_string)?;
        let indexed_attno = unsafe { pg_sys::get_attnum(relid, subject_column_cstr.as_ptr()) };
        if indexed_attno != subject_attno {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(None);
        }

        let stats_query = format!(
            "WITH plan AS ( \
               SELECT * \
               FROM otlet.semantic_index_plan({}, true) \
             ), \
             current_rows AS ( \
               SELECT subject_id, body, stale \
               FROM otlet.semantic_index_current_rows({}, false) \
             ) \
             SELECT \
               COALESCE((SELECT total_subjects FROM plan), 0)::bigint AS source_rows, \
               count(*) FILTER (WHERE stale = false AND body @> {}::jsonb)::bigint AS fresh_matches, \
               count(*) FILTER (WHERE stale = false AND NOT (body @> {}::jsonb))::bigint AS fresh_non_matches, \
               COALESCE((SELECT stale_subjects FROM plan), 0)::bigint AS stale_rows, \
               COALESCE((SELECT missing_subjects FROM plan), 0)::bigint AS missing_rows, \
               COALESCE((SELECT inflight_subjects FROM plan), 0)::bigint AS inflight_rows, \
               0::bigint AS cache_reusable_rows, \
               COALESCE((SELECT model_ms FROM plan), 2500)::float8 AS model_ms, \
               COALESCE((SELECT model_cost_source FROM plan), 'static_fallback')::text AS model_cost_source, \
               COALESCE((SELECT count_basis FROM plan), 'exact')::text AS count_basis, \
               COALESCE((SELECT stale_reasons::text FROM plan), '{{}}'::text) AS stale_reasons \
             FROM current_rows",
            sql_literal(index_name),
            sql_literal(index_name),
            sql_literal(expected_json),
            sql_literal(expected_json)
        );
        let stats_table = client
            .select(stats_query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = stats_table.first();
        let mut stats = SemanticPlannerStats {
            selected_path: "semantic_lookup".to_string(),
            reason: String::new(),
            source_rows: row
                .get_by_name::<i64, _>("source_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            fresh_matches: row
                .get_by_name::<i64, _>("fresh_matches")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            fresh_non_matches: row
                .get_by_name::<i64, _>("fresh_non_matches")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            stale_rows: row
                .get_by_name::<i64, _>("stale_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            missing_rows: row
                .get_by_name::<i64, _>("missing_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            inflight_rows: row
                .get_by_name::<i64, _>("inflight_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            cache_reusable_rows: row
                .get_by_name::<i64, _>("cache_reusable_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            infer_decision_rows: 0,
            fail_closed_decision_rows: 0,
            model_ms: row
                .get_by_name::<f64, _>("model_ms")
                .map_err(to_string)?
                .unwrap_or(2500.0)
                .max(1.0),
            model_cost_source: row
                .get_by_name::<String, _>("model_cost_source")
                .map_err(to_string)?
                .unwrap_or_else(|| "static_fallback".to_string()),
            path_cost: 0.0,
            stale_reasons: row
                .get_by_name::<String, _>("stale_reasons")
                .map_err(to_string)?
                .unwrap_or_else(|| "{}".to_string()),
            count_basis: row
                .get_by_name::<String, _>("count_basis")
                .map_err(to_string)?
                .unwrap_or_else(|| "exact".to_string()),
        };
        finish_planner_stats(
            &mut stats,
            allow_refresh,
            wait_ms,
            infer_ms,
            infer_max_rows,
            auto_policy,
        );
        Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>)>, String>(Some((
            stats,
            input_columns,
        )))
    }) {
        Ok(stats) => stats,
        Err(err) => {
            pgrx::warning!("otlet semantic CustomScan planner probe failed: {err}");
            None
        }
    }
}

fn validate_semantic_join_index_source(
    index_name: &str,
    expected_json: &str,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    auto_policy: bool,
) -> Option<SemanticPlannerStats> {
    let stats_query = format!(
        "WITH plan AS ( \
           SELECT * \
           FROM otlet.semantic_join_index_plan({}) \
         ), \
         current_rows AS ( \
           SELECT subject_id, body, stale \
           FROM otlet.semantic_join_index_current_rows({}, false) \
         ) \
         SELECT \
           COALESCE((SELECT total_subjects FROM plan), 0)::bigint AS source_rows, \
           count(*) FILTER (WHERE stale = false AND body @> {}::jsonb)::bigint AS fresh_matches, \
           count(*) FILTER (WHERE stale = false AND NOT (body @> {}::jsonb))::bigint AS fresh_non_matches, \
           COALESCE((SELECT stale_subjects FROM plan), 0)::bigint AS stale_rows, \
           COALESCE((SELECT missing_subjects FROM plan), 0)::bigint AS missing_rows, \
           COALESCE((SELECT inflight_subjects FROM plan), 0)::bigint AS inflight_rows, \
           0::bigint AS cache_reusable_rows, \
           COALESCE((SELECT model_ms FROM plan), 2500)::float8 AS model_ms, \
           COALESCE((SELECT model_cost_source FROM plan), 'static_fallback')::text AS model_cost_source, \
           COALESCE((SELECT count_basis FROM plan), 'estimated')::text AS count_basis, \
           COALESCE((SELECT stale_reasons::text FROM plan), '{{}}'::text) AS stale_reasons \
         FROM current_rows",
        sql_literal(index_name),
        sql_literal(index_name),
        sql_literal(expected_json),
        sql_literal(expected_json)
    );
    match pgrx::Spi::connect(|client| {
        let table = client
            .select(stats_query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        if table.is_empty() {
            return Ok::<Option<SemanticPlannerStats>, String>(None);
        }
        let row = table.first();
        let mut stats = SemanticPlannerStats {
            selected_path: "semantic_join_lookup".to_string(),
            reason: String::new(),
            source_rows: row
                .get_by_name::<i64, _>("source_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            fresh_matches: row
                .get_by_name::<i64, _>("fresh_matches")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            fresh_non_matches: row
                .get_by_name::<i64, _>("fresh_non_matches")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            stale_rows: row
                .get_by_name::<i64, _>("stale_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            missing_rows: row
                .get_by_name::<i64, _>("missing_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            inflight_rows: row
                .get_by_name::<i64, _>("inflight_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            cache_reusable_rows: row
                .get_by_name::<i64, _>("cache_reusable_rows")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            infer_decision_rows: 0,
            fail_closed_decision_rows: 0,
            model_ms: row
                .get_by_name::<f64, _>("model_ms")
                .map_err(to_string)?
                .unwrap_or(2500.0)
                .max(1.0),
            model_cost_source: row
                .get_by_name::<String, _>("model_cost_source")
                .map_err(to_string)?
                .unwrap_or_else(|| "static_fallback".to_string()),
            path_cost: 0.0,
            stale_reasons: row
                .get_by_name::<String, _>("stale_reasons")
                .map_err(to_string)?
                .unwrap_or_else(|| "{}".to_string()),
            count_basis: row
                .get_by_name::<String, _>("count_basis")
                .map_err(to_string)?
                .unwrap_or_else(|| "estimated".to_string()),
        };
        finish_planner_stats(
            &mut stats,
            allow_refresh,
            wait_ms,
            infer_ms,
            infer_max_rows,
            auto_policy,
        );
        if stats.selected_path == "semantic_lookup" {
            stats.selected_path = "semantic_join_lookup".to_string();
        }
        stats.reason = format!("semantic join candidate row-source: {}", stats.reason);
        Ok::<Option<SemanticPlannerStats>, String>(Some(stats))
    }) {
        Ok(stats) => stats,
        Err(err) => {
            pgrx::warning!("otlet semantic join CustomScan planner probe failed: {err}");
            None
        }
    }
}
