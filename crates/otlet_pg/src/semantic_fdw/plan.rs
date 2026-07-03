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
         path_cost::float8 AS path_cost, worker_queue_depth, available_queue_slots, \
         stale_reasons::text AS stale_reasons \
         FROM {}({})",
        plan_function,
        sql_literal(&opts.index_name)
    );

    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        macro_rules! text {
            ($name:literal) => {
                row.get_by_name::<String, _>($name)
                    .map_err(to_string)?
                    .unwrap_or_default()
            };
            ($name:literal, $default:literal) => {
                row.get_by_name::<String, _>($name)
                    .map_err(to_string)?
                    .unwrap_or_else(|| $default.to_string())
            };
        }
        macro_rules! i64_value {
            ($name:literal) => {
                row.get_by_name::<i64, _>($name)
                    .map_err(to_string)?
                    .unwrap_or_default()
            };
        }
        macro_rules! f64_value {
            ($name:literal, $default:literal) => {
                row.get_by_name::<f64, _>($name)
                    .map_err(to_string)?
                    .unwrap_or($default)
            };
        }
        Ok(SemanticFdwPlan {
            selected_path: text!("selected_path"),
            reason: text!("reason"),
            task_name: text!("task_name"),
            record_type: text!("record_type"),
            model_name: text!("model_name"),
            runtime_name: text!("runtime_name"),
            source_relation: text!("source_relation"),
            total_subjects: i64_value!("total_subjects"),
            fresh_subjects: i64_value!("fresh_subjects"),
            stale_subjects: i64_value!("stale_subjects"),
            missing_subjects: i64_value!("missing_subjects"),
            inflight_subjects: i64_value!("inflight_subjects"),
            lookup_subjects: i64_value!("lookup_subjects"),
            wait_subjects: i64_value!("wait_subjects"),
            queue_subjects: i64_value!("queue_subjects"),
            infer_now_subjects: i64_value!("infer_now_subjects"),
            fail_closed_subjects: i64_value!("fail_closed_subjects"),
            freshness: f64_value!("freshness", 1.0),
            model_ms: f64_value!("model_ms", 2500.0),
            model_cost_source: text!("model_cost_source", "static_fallback"),
            cache_hit_ms: f64_value!("cache_hit_ms", 0.05),
            lookup_ms: f64_value!("lookup_ms", 1.0),
            queue_ms: f64_value!("queue_ms", 1.0),
            infer_now_ms: f64_value!("infer_now_ms", 0.0),
            path_cost: f64_value!("path_cost", 1.0),
            worker_queue_depth: i64_value!("worker_queue_depth"),
            available_queue_slots: i64_value!("available_queue_slots"),
            stale_reasons: text!("stale_reasons", "{}"),
        })
    })
}

fn load_scan_state(
    opts: SemanticFdwOptions,
    pushdown: SemanticPushdown,
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
            let query = lookup_rows_query(&opts, &subject_filter);
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
            opts,
            plan,
            pushdown,
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
) -> String {
    match opts.access_kind {
        SemanticAccessKind::RowIndex => format!(
            "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
             FROM otlet.semantic_index_current_rows({}, true) latest \
             WHERE true{} \
             ORDER BY latest.subject_id",
            sql_literal(&opts.index_name),
            subject_filter
        ),
        SemanticAccessKind::JoinIndex => format!(
            "SELECT latest.subject_id, latest.body::text AS body, latest.stale, latest.source_hash, latest.updated_at::text AS updated_at \
             FROM otlet.semantic_join_index_current_rows({}, true) latest \
             WHERE true{} \
             ORDER BY latest.subject_id",
            sql_literal(&opts.index_name),
            subject_filter
        ),
    }
}

fn load_explain_state(
    opts: SemanticFdwOptions,
    pushdown: SemanticPushdown,
) -> Result<SemanticFdwState, String> {
    Ok(SemanticFdwState {
        rows: Vec::new(),
        next: 0,
        rows_loaded: 0,
        rows_emitted: 0,
        queued_jobs: 0,
        rescans: 0,
        plan: load_effective_plan(&opts, &pushdown)?,
        opts,
        pushdown,
    })
}
