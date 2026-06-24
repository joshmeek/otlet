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
        let mut min_freshness: f64 = 1.0;
        let mut allow_refresh = true;
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
                "min_freshness" => {
                    min_freshness = value.parse::<f64>().map_err(|_| {
                        format!(
                            "otlet semantic FDW option min_freshness must be numeric between 0 and 1, got {value}"
                        )
                    })?;
                    if !min_freshness.is_finite() || !(0.0..=1.0).contains(&min_freshness) {
                        return Err(format!(
                            "otlet semantic FDW option min_freshness must be numeric between 0 and 1, got {value}"
                        ));
                    }
                }
                "allow_refresh" => {
                    allow_refresh = match value.as_str() {
                        "true" => true,
                        "false" => false,
                        _ => {
                            return Err(format!(
                                "otlet semantic FDW option allow_refresh must be true or false, got {value}"
                            ));
                        }
                    }
                }
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
            min_freshness,
            allow_refresh,
        })
    }
}

fn load_plan(opts: &SemanticFdwOptions) -> Result<SemanticFdwPlan, String> {
    let query = match opts.access_kind {
        SemanticAccessKind::RowIndex => format!(
            "SELECT selected_path, reason, task_name, total_rows, refresh_rows, \
             freshness::float8 AS freshness, \
             estimated_lookup_ms::float8 AS estimated_lookup_ms, \
             estimated_refresh_ms::float8 AS estimated_refresh_ms, \
             estimated_fresh_inference_ms::float8 AS estimated_fresh_inference_ms \
             FROM otlet.semantic_index_plan({}, {}, {})",
            sql_literal(&opts.index_name),
            opts.min_freshness,
            opts.allow_refresh
        ),
        SemanticAccessKind::JoinIndex => format!(
            "SELECT selected_path, reason, task_name, total_pairs AS total_rows, refresh_pairs AS refresh_rows, \
             freshness::float8 AS freshness, \
             estimated_lookup_ms::float8 AS estimated_lookup_ms, \
             estimated_refresh_ms::float8 AS estimated_refresh_ms, \
             estimated_fresh_inference_ms::float8 AS estimated_fresh_inference_ms \
             FROM otlet.semantic_join_index_plan({}, {})",
            sql_literal(&opts.index_name),
            opts.allow_refresh
        ),
    };

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
            total_rows: row
                .get_by_name::<i64, _>("total_rows")
                .map_err(to_string)?
                .unwrap_or_default(),
            refresh_rows: row
                .get_by_name::<i64, _>("refresh_rows")
                .map_err(to_string)?
                .unwrap_or_default(),
            freshness: row
                .get_by_name::<f64, _>("freshness")
                .map_err(to_string)?
                .unwrap_or(1.0),
            estimated_lookup_ms: row
                .get_by_name::<f64, _>("estimated_lookup_ms")
                .map_err(to_string)?
                .unwrap_or(1.0),
            estimated_refresh_ms: row
                .get_by_name::<f64, _>("estimated_refresh_ms")
                .map_err(to_string)?
                .unwrap_or(1.0),
            estimated_fresh_inference_ms: row
                .get_by_name::<f64, _>("estimated_fresh_inference_ms")
                .map_err(to_string)?
                .unwrap_or(1.0),
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
            "refresh_then_lookup" => scalar_i64(
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
    matches!(path, "semantic_lookup" | "semantic_join_lookup")
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
             FROM otlet.semantic_index_lookup({}, true) latest \
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
             FROM otlet.semantic_join_index_lookup({}, true) latest \
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
