fn load_effective_plan(
    opts: &SemanticFdwOptions,
    pushdown: &SemanticPushdown,
) -> Result<SemanticFdwPlan, String> {
    let mut plan = load_plan(opts)?;
    if let Some(pushed_subject_ids) = pushdown.subjects() {
        plan.count_basis = "pushdown_scoped".to_string();
        let subjects = unique_subject_ids(pushed_subject_ids);
        if subjects.is_empty() {
            plan.selected_path = lookup_path(opts).to_string();
            plan.reason = "pushed subject filter empty".to_string();
            clear_subject_counts(&mut plan);
            return Ok(plan);
        }

        let stats = subject_scope_stats(opts, &subjects)?;
        let unresolved_subjects = stats.source_rows.saturating_sub(stats.fresh_rows);
        plan.total_subjects = stats.source_rows;
        plan.fresh_subjects = stats.fresh_rows;
        plan.stale_subjects = 0;
        plan.missing_subjects = unresolved_subjects;
        plan.inflight_subjects = 0;
        plan.lookup_subjects = stats.fresh_rows;
        plan.wait_subjects = 0;
        plan.queue_subjects = 0;
        plan.infer_now_subjects = 0;
        plan.fail_closed_subjects = 0;
        plan.stale_reasons = "{}".to_string();
        plan.freshness = scoped_freshness(stats.source_rows, unresolved_subjects);
        plan.lookup_ms = scoped_lookup_ms(stats.fresh_rows);
        plan.queue_ms = plan.lookup_ms + unresolved_subjects as f64 * plan.model_ms.max(1.0);
        plan.infer_now_ms = 0.0;

        if stats.source_rows == 0 {
            plan.selected_path = lookup_path(opts).to_string();
            plan.reason = "pushed subject rows absent from source".to_string();
            finish_path_cost(&mut plan);
            return Ok(plan);
        }

        if unresolved_subjects == 0 {
            plan.selected_path = lookup_path(opts).to_string();
            plan.reason = "pushed subject rows fresh".to_string();
            finish_path_cost(&mut plan);
            return Ok(plan);
        }

        if plan.selected_path == "wait_for_refresh" {
            plan.reason = "pushed subject refresh already active".to_string();
            plan.wait_subjects = plan.inflight_subjects;
            finish_path_cost(&mut plan);
            return Ok(plan);
        }

        if plan.selected_path == "lookup_fail_closed" {
            plan.fail_closed_subjects = unresolved_subjects;
            plan.reason = "pushed subject rows stale or missing; policy fail closed".to_string();
        } else {
            plan.selected_path = "queue_refresh".to_string();
            plan.reason = "pushed subject rows stale or missing".to_string();
            plan.queue_subjects = unresolved_subjects.min(plan.available_queue_slots);
        }
        finish_path_cost(&mut plan);
    }

    Ok(plan)
}

fn subject_scope_stats(
    opts: &SemanticFdwOptions,
    subjects: &[String],
) -> Result<SubjectScopeStats, String> {
    let subject_array = sql_text_array(subjects);
    let (source_query, materialized_query) = match opts.access_kind {
        SemanticAccessKind::RowIndex => row_subject_scope_queries(opts, &subject_array)?,
        SemanticAccessKind::JoinIndex => join_subject_scope_queries(opts, &subject_array)?,
    };
    pgrx::Spi::connect(|client| {
        let source_rows = scalar_select_i64(client, &source_query)?;
        let fresh_rows = scalar_select_i64(client, &materialized_query)?;
        Ok::<SubjectScopeStats, String>(SubjectScopeStats {
            source_rows,
            fresh_rows: fresh_rows.min(source_rows),
        })
    })
}

fn row_subject_scope_queries(
    opts: &SemanticFdwOptions,
    subject_array: &str,
) -> Result<(String, String), String> {
    let query = format!(
        "SELECT source_table, subject_column \
         FROM otlet.semantic_indexes \
         WHERE name = {}",
        sql_literal(&opts.index_name)
    );
    let (source_table, subject_column) = pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        let source_table = row
            .get_by_name::<String, _>("source_table")
            .map_err(to_string)?
            .ok_or_else(|| "semantic index source_table returned null".to_string())?;
        let subject_column = row
            .get_by_name::<String, _>("subject_column")
            .map_err(to_string)?
            .ok_or_else(|| "semantic index subject_column returned null".to_string())?;
        Ok::<(String, String), String>((source_table, subject_column))
    })?;

    Ok((
        format!(
            "SELECT count(DISTINCT ({})::text)::bigint \
             FROM {} \
             WHERE ({})::text = ANY ({}::text[])",
            sql_identifier(&subject_column),
            source_table,
            sql_identifier(&subject_column),
            subject_array
        ),
        format!(
            "SELECT count(DISTINCT sm.subject_id)::bigint \
             FROM otlet.semantic_index_current_rows({}, true) sm \
             WHERE sm.subject_id = ANY ({}::text[])",
            sql_literal(&opts.index_name),
            subject_array
        ),
    ))
}

fn join_subject_scope_queries(
    opts: &SemanticFdwOptions,
    subject_array: &str,
) -> Result<(String, String), String> {
    let query = format!(
        "SELECT candidate_query, max_candidate_rows \
         FROM otlet.semantic_join_indexes \
         WHERE name = {}",
        sql_literal(&opts.index_name)
    );
    let (candidate_query, max_candidate_rows) = pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        let candidate_query = row
            .get_by_name::<String, _>("candidate_query")
            .map_err(to_string)?
            .ok_or_else(|| "semantic join index candidate_query returned null".to_string())?;
        let max_candidate_rows = row
            .get_by_name::<i32, _>("max_candidate_rows")
            .map_err(to_string)?
            .unwrap_or(1000)
            .max(1);
        Ok::<(String, i32), String>((candidate_query, max_candidate_rows))
    })?;

    Ok((
        format!(
            "SELECT count(DISTINCT subject_id)::bigint \
             FROM ( \
               SELECT subject_id::text AS subject_id \
               FROM ({}) otlet_join_candidate \
               ORDER BY subject_id \
               LIMIT {} \
             ) scoped_candidates \
             WHERE subject_id = ANY ({}::text[])",
            candidate_query,
            max_candidate_rows,
            subject_array
        ),
        format!(
            "SELECT count(DISTINCT sm.subject_id)::bigint \
             FROM otlet.semantic_join_index_current_rows({}, true) sm \
             WHERE sm.subject_id = ANY ({}::text[])",
            sql_literal(&opts.index_name),
            subject_array
        ),
    ))
}

fn lookup_path(opts: &SemanticFdwOptions) -> &'static str {
    match opts.access_kind {
        SemanticAccessKind::RowIndex => "semantic_lookup",
        SemanticAccessKind::JoinIndex => "semantic_join_lookup",
    }
}

fn scoped_lookup_ms(rows: i64) -> f64 {
    (1.0 + rows.max(0) as f64 * 0.05).max(1.0)
}

fn scoped_freshness(rows: i64, unresolved_subjects: i64) -> f64 {
    if rows <= 0 {
        1.0
    } else {
        ((rows - unresolved_subjects).max(0) as f64 / rows as f64).clamp(0.0, 1.0)
    }
}

fn clear_subject_counts(plan: &mut SemanticFdwPlan) {
    plan.total_subjects = 0;
    plan.fresh_subjects = 0;
    plan.stale_subjects = 0;
    plan.missing_subjects = 0;
    plan.inflight_subjects = 0;
    plan.lookup_subjects = 0;
    plan.wait_subjects = 0;
    plan.queue_subjects = 0;
    plan.infer_now_subjects = 0;
    plan.fail_closed_subjects = 0;
    plan.stale_reasons = "{}".to_string();
    plan.freshness = 1.0;
    plan.lookup_ms = scoped_lookup_ms(0);
    plan.queue_ms = plan.lookup_ms;
    plan.infer_now_ms = 0.0;
    plan.path_cost = plan.lookup_ms;
}

fn finish_path_cost(plan: &mut SemanticFdwPlan) {
    plan.path_cost = match plan.selected_path.as_str() {
        "semantic_lookup" | "semantic_join_lookup" | "lookup_fail_closed" => plan.lookup_ms,
        "wait_for_refresh" => plan.lookup_ms + plan.wait_subjects as f64 * 0.50,
        "bounded_infer_now" => plan.lookup_ms + plan.infer_now_ms,
        _ => plan.queue_ms,
    }
    .max(1.0);
}
