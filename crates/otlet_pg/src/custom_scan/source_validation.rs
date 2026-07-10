type OtletFunctionCache = Option<(pg_sys::TimestampTz, HashMap<(u32, &'static str), bool>)>;

unsafe fn is_otlet_function(funcid: pg_sys::Oid, expected_name: &str) -> bool {
    unsafe {
        // Statement-scoped cache: func OIDs are stable within a plan, and
        // semantic_matches* clauses may probe the same OID repeatedly.
        let expected_static: &'static str = match expected_name {
            "semantic_matches" => "semantic_matches",
            "semantic_matches_auto" => "semantic_matches_auto",
            "semantic_join_matches" => "semantic_join_matches",
            "semantic_join_matches_auto" => "semantic_join_matches_auto",
            _ => return is_otlet_function_uncached(funcid, expected_name),
        };
        let stmt_start = pg_sys::GetCurrentStatementStartTimestamp();
        thread_local! {
            static CACHE: std::cell::RefCell<OtletFunctionCache> =
                const { std::cell::RefCell::new(None) };
        }
        if let Some(cached) = CACHE.with(|cell| {
            let mut guard = cell.borrow_mut();
            match guard.as_mut() {
                Some((cached_start, map)) if *cached_start == stmt_start => {
                    map.get(&(funcid.to_u32(), expected_static)).copied()
                }
                _ => {
                    *guard = Some((stmt_start, HashMap::with_capacity(8)));
                    None
                }
            }
        }) {
            return cached;
        }
        let result = is_otlet_function_uncached(funcid, expected_name);
        CACHE.with(|cell| {
            let mut guard = cell.borrow_mut();
            if let Some((cached_start, map)) = guard.as_mut()
                && *cached_start == stmt_start
            {
                map.insert((funcid.to_u32(), expected_static), result);
            }
        });
        result
    }
}

unsafe fn is_otlet_function_uncached(funcid: pg_sys::Oid, expected_name: &str) -> bool {
    unsafe {
        let func_name = pg_sys::get_func_name(funcid);
        if func_name.is_null() {
            return false;
        }
        let name_match = CStr::from_ptr(func_name).to_bytes() == expected_name.as_bytes();
        pg_sys::pfree(func_name.cast());
        if !name_match {
            return false;
        }
        let namespace = pg_sys::get_func_namespace(funcid);
        let namespace_name = pg_sys::get_namespace_name(namespace);
        if namespace_name.is_null() {
            return false;
        }
        let namespace_match = CStr::from_ptr(namespace_name).to_bytes() == b"otlet";
        pg_sys::pfree(namespace_name.cast());
        namespace_match
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
            let coerce = node.cast::<pg_sys::CoerceViaIO>();
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
        let var = candidate.cast::<pg_sys::Var>();
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

unsafe fn path_target_var_flags(
    target: *mut pg_sys::PathTarget,
    rti: pg_sys::Index,
    subject_attno: i16,
) -> (bool, bool) {
    unsafe {
        if target.is_null() || (*target).exprs.is_null() {
            return (false, false);
        }
        let mut has_subject = false;
        let mut has_rel_var = false;
        for idx in 0..pg_sys::list_length((*target).exprs) {
            let expr = strip_relabel(pg_sys::list_nth((*target).exprs, idx).cast::<pg_sys::Expr>());
            if expr.is_null() || (*expr).type_ != pg_sys::NodeTag::T_Var {
                continue;
            }
            let var = expr.cast::<pg_sys::Var>();
            if (*var).varno < 0 || u32::try_from((*var).varno).ok() != Some(rti) {
                continue;
            }
            if (*var).varattno == subject_attno {
                has_subject = true;
            }
            if (*var).varattno > 0 {
                has_rel_var = true;
            }
            if has_subject && has_rel_var {
                break;
            }
        }
        (has_subject, has_rel_var)
    }
}

unsafe fn path_target_has_subject_var(
    target: *mut pg_sys::PathTarget,
    rti: pg_sys::Index,
    subject_attno: i16,
) -> bool {
    path_target_var_flags(target, rti, subject_attno).0
}

unsafe fn path_target_has_rel_var(target: *mut pg_sys::PathTarget, rti: pg_sys::Index) -> bool {
    path_target_var_flags(target, rti, 0).1
}

unsafe fn rel_has_lateral_ref(rel: *mut pg_sys::RelOptInfo) -> bool {
    unsafe {
        !rel.is_null()
            && (!(*rel).direct_lateral_relids.is_null()
                || !(*rel).lateral_relids.is_null()
                || !(*rel).lateral_vars.is_null())
    }
}

fn nonnegative_count(value: i64) -> u64 {
    value.max(0).cast_unsigned()
}

#[allow(clippy::too_many_arguments)]
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
) -> Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)> {
    match pgrx::Spi::connect(|client| {
        // One SELECT: metadata + plan/current_rows stats (same fail-closed gates).
        let args = [
            index_name.into(),
            (relid.to_u32() as i32).into(),
            expected_json.into(),
        ];
        let table = client
            .select(
                "WITH meta AS ( \
                   SELECT \
                     si.source_table, \
                     si.subject_column, \
                     CASE WHEN si.input_columns IS NULL THEN NULL ELSE to_jsonb(si.input_columns)::text END AS input_columns_json, \
                     quote_nullable(si.input_columns)::text AS input_columns_sql, \
                     quote_nullable(t.input_shaping::text)::text AS input_shaping_sql, \
                     si.task_name, \
                     si.record_type, \
                     otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract) AS contract_hash \
                   FROM otlet.semantic_indexes si \
                   JOIN otlet.tasks t ON t.name = si.task_name \
                   WHERE si.name = $1 AND si.source_table::regclass = $2::oid \
                   LIMIT 1 \
                 ), \
                 plan AS ( \
                   SELECT \
                     total_subjects, \
                     stale_subjects, \
                     missing_subjects, \
                     inflight_subjects, \
                     model_ms, \
                     model_cost_source, \
                     count_basis, \
                     stale_reasons \
                   FROM otlet.semantic_index_plan($1, true) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ), \
                 current_rows AS ( \
                   SELECT subject_id, body, stale \
                   FROM otlet.semantic_index_current_rows($1, false) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ) \
                 SELECT \
                   (SELECT source_table FROM meta) AS source_table, \
                   (SELECT subject_column FROM meta) AS subject_column, \
                   (SELECT input_columns_json FROM meta) AS input_columns_json, \
                   (SELECT input_columns_sql FROM meta) AS input_columns_sql, \
                   (SELECT input_shaping_sql FROM meta) AS input_shaping_sql, \
                   (SELECT task_name FROM meta) AS task_name, \
                   (SELECT record_type FROM meta) AS record_type, \
                   (SELECT contract_hash FROM meta) AS contract_hash, \
                   COALESCE((SELECT total_subjects FROM plan), 0)::bigint AS source_rows, \
                   (SELECT count(*) FROM current_rows WHERE stale = false AND body @> $3::jsonb)::bigint AS fresh_matches, \
                   (SELECT count(*) FROM current_rows WHERE stale = false AND NOT (body @> $3::jsonb))::bigint AS fresh_non_matches, \
                   COALESCE((SELECT stale_subjects FROM plan), 0)::bigint AS stale_rows, \
                   COALESCE((SELECT missing_subjects FROM plan), 0)::bigint AS missing_rows, \
                   COALESCE((SELECT inflight_subjects FROM plan), 0)::bigint AS inflight_rows, \
                   0::bigint AS cache_reusable_rows, \
                   COALESCE((SELECT model_ms FROM plan), 2500)::float8 AS model_ms, \
                   COALESCE((SELECT model_cost_source FROM plan), 'static_fallback')::text AS model_cost_source, \
                   COALESCE((SELECT count_basis FROM plan), 'exact')::text AS count_basis, \
                   COALESCE((SELECT stale_reasons::text FROM plan), '{}'::text) AS stale_reasons",
                Some(1),
                &args,
            )
            .map_err(to_string)?;
        if table.is_empty() {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        }
        let row = table.first();
        let Some(source_table) = row
            .get_by_name::<String, _>("source_table")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        };
        let Some(subject_column) = row
            .get_by_name::<String, _>("subject_column")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        };
        if source_table.is_empty() || subject_column.is_empty() {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        }
        let input_columns = row
            .get_by_name::<String, _>("input_columns_json")
            .map_err(to_string)?
            .map(|json| serde_json::from_str::<Vec<String>>(&json).map_err(to_string))
            .transpose()?;
        let subject_column_cstr = CString::new(subject_column.as_str()).map_err(to_string)?;
        let indexed_attno = unsafe { pg_sys::get_attnum(relid, subject_column_cstr.as_ptr()) };
        if indexed_attno != subject_attno {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        }
        let Some(task_name) = row
            .get_by_name::<String, _>("task_name")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        };
        let Some(record_type) = row
            .get_by_name::<String, _>("record_type")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        };
        let Some(contract_hash) = row
            .get_by_name::<String, _>("contract_hash")
            .map_err(to_string)?
        else {
            return Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(None);
        };
        let input_columns_sql = row
            .get_by_name::<String, _>("input_columns_sql")
            .map_err(to_string)?
            .unwrap_or_else(|| "NULL".to_owned());
        let input_shaping_sql = row
            .get_by_name::<String, _>("input_shaping_sql")
            .map_err(to_string)?
            .unwrap_or_else(|| "'{}'".to_owned());
        let row_preload_meta = Some(RowPreloadMeta {
            source_table,
            subject_column,
            input_columns_sql,
            input_shaping_sql,
            task_name,
            record_type,
            contract_hash,
        });

        let mut stats = SemanticPlannerStats {
            selected_path: "semantic_lookup".to_owned(),
            reason: String::new(),
            source_rows: row
                .get_by_name::<i64, _>("source_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            fresh_matches: row
                .get_by_name::<i64, _>("fresh_matches")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            fresh_non_matches: row
                .get_by_name::<i64, _>("fresh_non_matches")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            stale_rows: row
                .get_by_name::<i64, _>("stale_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            missing_rows: row
                .get_by_name::<i64, _>("missing_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            inflight_rows: row
                .get_by_name::<i64, _>("inflight_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            cache_reusable_rows: row
                .get_by_name::<i64, _>("cache_reusable_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
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
                .unwrap_or_else(|| "static_fallback".to_owned()),
            path_cost: 0.0,
            stale_reasons: row
                .get_by_name::<String, _>("stale_reasons")
                .map_err(to_string)?
                .unwrap_or_else(|| "{}".to_owned()),
            count_basis: row
                .get_by_name::<String, _>("count_basis")
                .map_err(to_string)?
                .unwrap_or_else(|| "exact".to_owned()),
        };
        finish_planner_stats(
            &mut stats,
            allow_refresh,
            wait_ms,
            infer_ms,
            infer_max_rows,
            auto_policy,
        );
        Ok::<Option<(SemanticPlannerStats, Option<Vec<String>>, Option<RowPreloadMeta>)>, String>(Some((
            stats,
            input_columns,
            row_preload_meta,
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
) -> Option<(SemanticPlannerStats, Option<JoinPreloadMeta>)> {
    match pgrx::Spi::connect(|client| {
        let stats_args = [index_name.into(), expected_json.into()];
        let stats_table = client
            .select(
                "WITH meta AS ( \
                   SELECT \
                     sji.task_name, \
                     sji.record_type \
                   FROM otlet.semantic_join_indexes sji \
                   WHERE sji.name = $1 \
                   LIMIT 1 \
                 ), \
                 plan AS ( \
                   SELECT \
                     total_subjects, \
                     stale_subjects, \
                     missing_subjects, \
                     inflight_subjects, \
                     model_ms, \
                     model_cost_source, \
                     count_basis, \
                     stale_reasons \
                   FROM otlet.semantic_join_index_plan($1) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ), \
                 current_rows AS ( \
                   SELECT subject_id, body, stale \
                   FROM otlet.semantic_join_index_current_rows($1, false) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ) \
                 SELECT \
                   (SELECT true FROM meta) AS meta_ok, \
                   (SELECT task_name FROM meta) AS task_name, \
                   (SELECT record_type FROM meta) AS record_type, \
                   COALESCE((SELECT total_subjects FROM plan), 0)::bigint AS source_rows, \
                   (SELECT count(*) FROM current_rows WHERE stale = false AND body @> $2::jsonb)::bigint AS fresh_matches, \
                   (SELECT count(*) FROM current_rows WHERE stale = false AND NOT (body @> $2::jsonb))::bigint AS fresh_non_matches, \
                   COALESCE((SELECT stale_subjects FROM plan), 0)::bigint AS stale_rows, \
                   COALESCE((SELECT missing_subjects FROM plan), 0)::bigint AS missing_rows, \
                   COALESCE((SELECT inflight_subjects FROM plan), 0)::bigint AS inflight_rows, \
                   0::bigint AS cache_reusable_rows, \
                   COALESCE((SELECT model_ms FROM plan), 2500)::float8 AS model_ms, \
                   COALESCE((SELECT model_cost_source FROM plan), 'static_fallback')::text AS model_cost_source, \
                   COALESCE((SELECT count_basis FROM plan), 'estimated')::text AS count_basis, \
                   COALESCE((SELECT stale_reasons::text FROM plan), '{}'::text) AS stale_reasons",
                Some(1),
                &stats_args,
            )
            .map_err(to_string)?;
        if stats_table.is_empty() {
            return Ok::<Option<(SemanticPlannerStats, Option<JoinPreloadMeta>)>, String>(None);
        }
        let row = stats_table.first();
        if row
            .get_by_name::<bool, _>("meta_ok")
            .map_err(to_string)?
            .is_none()
        {
            return Ok::<Option<(SemanticPlannerStats, Option<JoinPreloadMeta>)>, String>(None);
        }
        let mut stats = SemanticPlannerStats {
            selected_path: "semantic_lookup".to_owned(),
            reason: String::new(),
            source_rows: row
                .get_by_name::<i64, _>("source_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            fresh_matches: row
                .get_by_name::<i64, _>("fresh_matches")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            fresh_non_matches: row
                .get_by_name::<i64, _>("fresh_non_matches")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            stale_rows: row
                .get_by_name::<i64, _>("stale_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            missing_rows: row
                .get_by_name::<i64, _>("missing_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            inflight_rows: row
                .get_by_name::<i64, _>("inflight_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            cache_reusable_rows: row
                .get_by_name::<i64, _>("cache_reusable_rows")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
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
                .unwrap_or_else(|| "static_fallback".to_owned()),
            path_cost: 0.0,
            stale_reasons: row
                .get_by_name::<String, _>("stale_reasons")
                .map_err(to_string)?
                .unwrap_or_else(|| "{}".to_owned()),
            count_basis: row
                .get_by_name::<String, _>("count_basis")
                .map_err(to_string)?
                .unwrap_or_else(|| "estimated".to_owned()),
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
            stats.selected_path = "semantic_join_lookup".to_owned();
        }
        stats.reason = format!("semantic join candidate row-source: {}", stats.reason);
        let join_meta = match (
            row.get_by_name::<String, _>("task_name").map_err(to_string)?,
            row.get_by_name::<String, _>("record_type").map_err(to_string)?,
        ) {
            (Some(task_name), Some(record_type)) => Some(JoinPreloadMeta {
                task_name,
                record_type,
            }),
            _ => None,
        };
        Ok::<Option<(SemanticPlannerStats, Option<JoinPreloadMeta>)>, String>(Some((
            stats,
            join_meta,
        )))
    }) {
        Ok(stats) => stats,
        Err(err) => {
            pgrx::warning!("otlet semantic join CustomScan planner probe failed: {err}");
            None
        }
    }
}
