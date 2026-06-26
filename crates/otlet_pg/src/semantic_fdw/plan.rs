fn set_text(value: &mut pg_sys::Datum, is_null: &mut bool, text: Option<&str>) {
    if let Some(text) = text {
        *value = text.into_datum().unwrap();
        *is_null = false;
    } else {
        *value = pg_sys::Datum::from(0usize);
        *is_null = true;
    }
}

fn set_jsonb(value: &mut pg_sys::Datum, is_null: &mut bool, body: Option<&Value>) {
    if let Some(body) = body {
        *value = JsonB(body.clone()).into_datum().unwrap();
        *is_null = false;
    } else {
        *value = pg_sys::Datum::from(0usize);
        *is_null = true;
    }
}

fn set_bool(value: &mut pg_sys::Datum, is_null: &mut bool, flag: Option<bool>) {
    if let Some(flag) = flag {
        *value = flag.into_datum().unwrap();
        *is_null = false;
    } else {
        *value = pg_sys::Datum::from(0usize);
        *is_null = true;
    }
}

unsafe fn semantic_options(relid: pg_sys::Oid) -> Result<SemanticFdwOptions, String> {
    unsafe {
        let table = pg_sys::GetForeignTable(relid);
        if table.is_null() {
            return Err("otlet semantic FDW could not read foreign table metadata".into());
        }

        let mut index_name = None;
        let mut join_index_name = None;
        let options = (*table).options;
        let len = pg_sys::list_length(options);

        for idx in 0..len {
            let def = pg_sys::list_nth(options, idx) as *mut pg_sys::DefElem;
            if def.is_null() || (*def).defname.is_null() {
                continue;
            }
            let name = CStr::from_ptr((*def).defname).to_string_lossy();
            let value = CStr::from_ptr(pg_sys::defGetString(def))
                .to_string_lossy()
                .into_owned();
            match name.as_ref() {
                "index_name" => index_name = Some(value),
                "join_index_name" => join_index_name = Some(value),
                _ => return Err(format!("otlet semantic FDW unknown option {name}")),
            }
        }

        let (index_name, access_kind) = match (index_name, join_index_name) {
            (Some(index_name), None) => (index_name, SemanticAccessKind::RowIndex),
            (None, Some(index_name)) => (index_name, SemanticAccessKind::JoinIndex),
            (None, None) => {
                return Err(
                    "otlet semantic FDW requires option index_name or join_index_name".into(),
                );
            }
            (Some(_), Some(_)) => {
                return Err(
                    "otlet semantic FDW options index_name and join_index_name are mutually exclusive"
                        .into(),
                );
            }
        };
        Ok(SemanticFdwOptions {
            index_name,
            access_kind,
        })
    }
}

fn load_plan(opts: &SemanticFdwOptions) -> Result<SemanticFdwPlan, String> {
    let plan_function = match opts.access_kind {
        SemanticAccessKind::RowIndex => "otlet.semantic_index_plan",
        SemanticAccessKind::JoinIndex => "otlet.semantic_join_index_plan",
    };
    let query = format!(
        "SELECT selected_path, reason, task_name, record_type, model_name, runtime_name, source_relation, \
         total_subjects, fresh_subjects, stale_subjects, missing_subjects, inflight_subjects, \
         lookup_subjects, wait_subjects, queue_subjects, infer_now_subjects, fail_closed_subjects, \
         freshness::float8 AS freshness, model_ms::float8 AS model_ms, model_cost_source, \
         cache_hit_ms::float8 AS cache_hit_ms, lookup_ms::float8 AS lookup_ms, \
         queue_ms::float8 AS queue_ms, infer_now_ms::float8 AS infer_now_ms, \
         path_cost::float8 AS path_cost, worker_queue_depth, available_queue_slots \
         FROM {}({})",
        plan_function,
        sql_literal(&opts.index_name)
    );

    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        Ok(SemanticFdwPlan {
            selected_path: row
                .get_by_name::<String, _>("selected_path")
                .map_err(to_string)?
                .unwrap_or_default(),
            reason: row
                .get_by_name::<String, _>("reason")
                .map_err(to_string)?
                .unwrap_or_default(),
            task_name: row
                .get_by_name::<String, _>("task_name")
                .map_err(to_string)?
                .unwrap_or_default(),
            record_type: row
                .get_by_name::<String, _>("record_type")
                .map_err(to_string)?
                .unwrap_or_default(),
            model_name: row
                .get_by_name::<String, _>("model_name")
                .map_err(to_string)?
                .unwrap_or_default(),
            runtime_name: row
                .get_by_name::<String, _>("runtime_name")
                .map_err(to_string)?
                .unwrap_or_default(),
            source_relation: row
                .get_by_name::<String, _>("source_relation")
                .map_err(to_string)?
                .unwrap_or_default(),
            total_subjects: row
                .get_by_name::<i64, _>("total_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            fresh_subjects: row
                .get_by_name::<i64, _>("fresh_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            stale_subjects: row
                .get_by_name::<i64, _>("stale_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            missing_subjects: row
                .get_by_name::<i64, _>("missing_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            inflight_subjects: row
                .get_by_name::<i64, _>("inflight_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            lookup_subjects: row
                .get_by_name::<i64, _>("lookup_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            wait_subjects: row
                .get_by_name::<i64, _>("wait_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            queue_subjects: row
                .get_by_name::<i64, _>("queue_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            infer_now_subjects: row
                .get_by_name::<i64, _>("infer_now_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            fail_closed_subjects: row
                .get_by_name::<i64, _>("fail_closed_subjects")
                .map_err(to_string)?
                .unwrap_or_default(),
            freshness: row
                .get_by_name::<f64, _>("freshness")
                .map_err(to_string)?
                .unwrap_or(1.0),
            model_ms: row
                .get_by_name::<f64, _>("model_ms")
                .map_err(to_string)?
                .unwrap_or(2500.0),
            model_cost_source: row
                .get_by_name::<String, _>("model_cost_source")
                .map_err(to_string)?
                .unwrap_or_else(|| "static_fallback".to_string()),
            cache_hit_ms: row
                .get_by_name::<f64, _>("cache_hit_ms")
                .map_err(to_string)?
                .unwrap_or(0.05),
            lookup_ms: row
                .get_by_name::<f64, _>("lookup_ms")
                .map_err(to_string)?
                .unwrap_or(1.0),
            queue_ms: row
                .get_by_name::<f64, _>("queue_ms")
                .map_err(to_string)?
                .unwrap_or(1.0),
            infer_now_ms: row
                .get_by_name::<f64, _>("infer_now_ms")
                .map_err(to_string)?
                .unwrap_or(0.0),
            path_cost: row
                .get_by_name::<f64, _>("path_cost")
                .map_err(to_string)?
                .unwrap_or(1.0),
            worker_queue_depth: row
                .get_by_name::<i64, _>("worker_queue_depth")
                .map_err(to_string)?
                .unwrap_or_default(),
            available_queue_slots: row
                .get_by_name::<i64, _>("available_queue_slots")
                .map_err(to_string)?
                .unwrap_or_default(),
        })
    })
}

fn load_scan_state(
    opts: SemanticFdwOptions,
    pushdown: SemanticPushdown,
    base_pushdown: SemanticPushdown,
) -> Result<SemanticFdwState, String> {
    pgrx::Spi::connect_mut(|client| {
        let plan = load_effective_plan(&opts, &pushdown)?;
        let queued_jobs = match plan.selected_path.as_str() {
            "queue_refresh" => scalar_i64(
                client,
                &format!(
                    "SELECT {}({})::bigint",
                    if opts.access_kind == SemanticAccessKind::JoinIndex {
                        "otlet.refresh_semantic_join_index"
                    } else {
                        "otlet.refresh_semantic_index"
                    },
                    sql_literal(&opts.index_name)
                ),
            )?,
            "fresh_inference_scan" | "fresh_pair_inference" => scalar_i64(
                client,
                &format!(
                    "SELECT otlet.run_task({})::bigint",
                    sql_literal(&plan.task_name)
                ),
            )?,
            _ => 0,
        };

        let mut rows = Vec::new();

        if queued_jobs == 0 && is_lookup_path(&plan.selected_path) {
            let subject_filter = sql_subject_filter("latest.subject_id", &pushdown.subjects);
            let body_filter = sql_body_filter("latest.body", &pushdown);
            let stale_filter = sql_stale_filter(pushdown.stale);
            let source_hash_filter = sql_source_hash_filter("latest.source_hash", &pushdown);
            let query = lookup_rows_query(
                &opts,
                &subject_filter,
                &body_filter,
                &stale_filter,
                &source_hash_filter,
            );
            let table = client
                .select(query.as_str(), None, &[])
                .map_err(to_string)?;

            for row in table {
                let body_text = row
                    .get_by_name::<String, _>("body")
                    .map_err(to_string)?
                    .unwrap_or_else(|| "null".to_string());
                rows.push(SemanticFdwRow {
                    subject_id: row.get_by_name("subject_id").map_err(to_string)?,
                    body: Some(serde_json::from_str(&body_text).map_err(to_string)?),
                    stale: row.get_by_name("stale").map_err(to_string)?,
                    source_hash: row.get_by_name("source_hash").map_err(to_string)?,
                    updated_at: row.get_by_name("updated_at").map_err(to_string)?,
                });
            }
        }

        Ok(SemanticFdwState {
            rows_loaded: rows.len() as i64,
            rows,
            next: 0,
            rows_emitted: 0,
            queued_jobs,
            rescans: 0,
            fdw_expr_states: ptr::null_mut(),
            outer_expr_typid: pg_sys::InvalidOid,
            opts,
            plan,
            pushdown,
            base_pushdown,
        })
    })
}

fn is_lookup_path(path: &str) -> bool {
    matches!(
        path,
        "semantic_lookup" | "semantic_join_lookup" | "lookup_fail_closed"
    )
}

fn lookup_rows_query(
    opts: &SemanticFdwOptions,
    subject_filter: &str,
    body_filter: &str,
    stale_filter: &str,
    source_hash_filter: &str,
) -> String {
    match opts.access_kind {
        SemanticAccessKind::RowIndex => format!(
            "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
             FROM otlet.semantic_index_current_rows({}, true) latest \
             WHERE true{}{}{}{} \
             ORDER BY latest.subject_id",
            sql_literal(&opts.index_name),
            subject_filter,
            body_filter,
            stale_filter,
            source_hash_filter
        ),
        SemanticAccessKind::JoinIndex => format!(
            "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
             FROM otlet.semantic_join_index_current_rows({}, true) latest \
             WHERE true{}{}{}{} \
             ORDER BY latest.subject_id",
            sql_literal(&opts.index_name),
            subject_filter,
            body_filter,
            stale_filter,
            source_hash_filter
        ),
    }
}

fn load_explain_state(
    opts: SemanticFdwOptions,
    pushdown: SemanticPushdown,
    base_pushdown: SemanticPushdown,
) -> Result<SemanticFdwState, String> {
    Ok(SemanticFdwState {
        rows: Vec::new(),
        next: 0,
        rows_loaded: 0,
        rows_emitted: 0,
        queued_jobs: 0,
        rescans: 0,
        fdw_expr_states: ptr::null_mut(),
        outer_expr_typid: pg_sys::InvalidOid,
        plan: load_effective_plan(&opts, &pushdown)?,
        opts,
        pushdown,
        base_pushdown,
    })
}

fn load_analyze_sample_rows(
    opts: &SemanticFdwOptions,
    limit: usize,
) -> Result<(i64, Vec<SemanticFdwRow>), String> {
    pgrx::Spi::connect(|client| {
        let total_query = match opts.access_kind {
            SemanticAccessKind::RowIndex => format!(
                "SELECT count(*)::bigint FROM otlet.semantic_index_current_rows({}, true)",
                sql_literal(&opts.index_name)
            ),
            SemanticAccessKind::JoinIndex => format!(
                "SELECT count(*)::bigint FROM otlet.semantic_join_index_current_rows({}, true)",
                sql_literal(&opts.index_name)
            ),
        };
        let total_rows = scalar_select_i64(client, &total_query)?;
        if total_rows == 0 || limit == 0 {
            return Ok((total_rows, Vec::new()));
        }

        let sample_query = match opts.access_kind {
            SemanticAccessKind::RowIndex => format!(
                "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
                 FROM otlet.semantic_index_current_rows({}, true) latest \
                 ORDER BY latest.subject_id \
                 LIMIT {}",
                sql_literal(&opts.index_name),
                limit
            ),
            SemanticAccessKind::JoinIndex => format!(
                "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
                 FROM otlet.semantic_join_index_current_rows({}, true) latest \
                 ORDER BY latest.subject_id \
                 LIMIT {}",
                sql_literal(&opts.index_name),
                limit
            ),
        };
        let table = client
            .select(sample_query.as_str(), None, &[])
            .map_err(to_string)?;
        let mut rows = Vec::new();
        for row in table {
            let body_text = row
                .get_by_name::<String, _>("body")
                .map_err(to_string)?
                .unwrap_or_else(|| "null".to_string());
            rows.push(SemanticFdwRow {
                subject_id: row.get_by_name("subject_id").map_err(to_string)?,
                body: Some(serde_json::from_str(&body_text).map_err(to_string)?),
                stale: row.get_by_name("stale").map_err(to_string)?,
                source_hash: row.get_by_name("source_hash").map_err(to_string)?,
                updated_at: row.get_by_name("updated_at").map_err(to_string)?,
            });
        }
        Ok((total_rows, rows))
    })
}
