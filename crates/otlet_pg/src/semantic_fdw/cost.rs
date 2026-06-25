fn load_effective_plan(
    opts: &SemanticFdwOptions,
    pushdown: &SemanticPushdown,
) -> Result<SemanticFdwPlan, String> {
    let mut plan = load_plan(opts)?;
    if let Some(reason) = &pushdown.empty_result_reason {
        plan.selected_path = "semantic_lookup".to_string();
        plan.reason = reason.clone();
        plan.total_rows = 0;
        plan.refresh_rows = 0;
        plan.freshness = 1.0;
        plan.estimated_lookup_ms = scoped_lookup_ms(0);
        plan.estimated_refresh_ms = plan.estimated_lookup_ms;
        plan.estimated_fresh_inference_ms = 0.0;
        return Ok(plan);
    }
    if pushdown.stale == Some(true) {
        plan.selected_path = "semantic_lookup".to_string();
        plan.reason = "pushed stale=true returns no rows under fail-closed policy".to_string();
        plan.total_rows = 0;
        plan.refresh_rows = 0;
        plan.freshness = 1.0;
        plan.estimated_lookup_ms = scoped_lookup_ms(0);
        plan.estimated_refresh_ms = plan.estimated_lookup_ms;
        plan.estimated_fresh_inference_ms = 0.0;
        return Ok(plan);
    }

    if opts.access_kind == SemanticAccessKind::RowIndex
        && let Some(pushed_subject_ids) = pushdown.subjects()
    {
        let subjects = unique_subject_ids(pushed_subject_ids);
        if subjects.is_empty() {
            plan.selected_path = "semantic_lookup".to_string();
            plan.reason = "pushed subject filter empty".to_string();
            plan.total_rows = 0;
            plan.refresh_rows = 0;
            plan.freshness = 1.0;
            plan.estimated_lookup_ms = scoped_lookup_ms(0);
            plan.estimated_refresh_ms = plan.estimated_lookup_ms;
            plan.estimated_fresh_inference_ms = 0.0;
            return apply_materialization_filter_plan(opts, pushdown, plan);
        }

        let stats = subject_scope_stats(opts, &subjects)?;
        let refresh_rows = stats.source_rows.saturating_sub(stats.fresh_rows);
        let global_total_rows = plan.total_rows;
        let global_refresh_rows = plan.refresh_rows;
        let global_lookup_ms = plan.estimated_lookup_ms;
        let global_refresh_ms = plan.estimated_refresh_ms;
        let global_fresh_inference_ms = plan.estimated_fresh_inference_ms;
        let lookup_ms = scoped_lookup_ms(stats.source_rows);

        plan.total_rows = stats.source_rows;
        plan.refresh_rows = refresh_rows;
        plan.freshness = scoped_freshness(stats.source_rows, refresh_rows);
        plan.estimated_lookup_ms = lookup_ms;
        plan.estimated_refresh_ms = scoped_refresh_ms(
            global_lookup_ms,
            global_refresh_ms,
            global_refresh_rows,
            lookup_ms,
            refresh_rows,
        );
        plan.estimated_fresh_inference_ms = scoped_fresh_inference_ms(
            global_fresh_inference_ms,
            global_total_rows,
            stats.source_rows,
        );

        if stats.source_rows == 0 {
            plan.selected_path = "semantic_lookup".to_string();
            plan.reason = "pushed subject rows absent from source".to_string();
            return apply_materialization_filter_plan(opts, pushdown, plan);
        }

        if refresh_rows == 0 {
            plan.selected_path = "semantic_lookup".to_string();
            plan.reason = "pushed subject rows fresh".to_string();
            return apply_materialization_filter_plan(opts, pushdown, plan);
        }

        if plan.selected_path == "wait_for_refresh" {
            plan.reason = "pushed subject refresh already active".to_string();
            return Ok(plan);
        }

        plan.selected_path = "refresh_then_lookup".to_string();
        plan.reason = "pushed subject rows stale or missing".to_string();
    }

    apply_materialization_filter_plan(opts, pushdown, plan)
}

fn apply_materialization_filter_plan(
    opts: &SemanticFdwOptions,
    pushdown: &SemanticPushdown,
    mut plan: SemanticFdwPlan,
) -> Result<SemanticFdwPlan, String> {
    if !pushdown.has_concrete_materialization_filters() || !is_lookup_path(&plan.selected_path) {
        return Ok(plan);
    }

    let rows = matching_materialization_rows(opts, pushdown)?;
    plan.total_rows = rows;
    plan.estimated_lookup_ms = scoped_lookup_ms(rows);
    if plan.refresh_rows == 0 {
        plan.estimated_refresh_ms = plan.estimated_lookup_ms;
    }
    plan.reason = format!("{}; semantic materialization filter pushed", plan.reason);
    Ok(plan)
}

fn subject_scope_stats(
    opts: &SemanticFdwOptions,
    subjects: &[String],
) -> Result<SubjectScopeStats, String> {
    let subject_array = sql_text_array(subjects);
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

    let source_query = format!(
        "SELECT count(DISTINCT ({})::text)::bigint \
         FROM {} \
         WHERE ({})::text = ANY ({}::text[])",
        sql_identifier(&subject_column),
        source_table,
        sql_identifier(&subject_column),
        subject_array
    );
    let materialized_query = format!(
        "SELECT count(DISTINCT sm.subject_id)::bigint \
         FROM otlet.semantic_index_current_rows({}, true) sm \
         WHERE sm.subject_id = ANY ({}::text[])",
        sql_literal(&opts.index_name),
        subject_array
    );
    pgrx::Spi::connect(|client| {
        let source_rows = scalar_select_i64(client, &source_query)?;
        let fresh_rows = scalar_select_i64(client, &materialized_query)?;
        Ok::<SubjectScopeStats, String>(SubjectScopeStats {
            source_rows,
            fresh_rows: fresh_rows.min(source_rows),
        })
    })
}

fn matching_materialization_rows(
    opts: &SemanticFdwOptions,
    pushdown: &SemanticPushdown,
) -> Result<i64, String> {
    let subject_filter = sql_subject_filter("latest.subject_id", &pushdown.subjects);
    let body_filter = sql_body_filter("latest.body", pushdown);
    let source_hash_filter = sql_source_hash_filter("latest.source_hash", pushdown);
    let query = match opts.access_kind {
        SemanticAccessKind::RowIndex => format!(
            "SELECT count(*)::bigint \
             FROM otlet.semantic_index_current_rows({}, true) latest \
             WHERE true{}{}{}",
            sql_literal(&opts.index_name),
            subject_filter,
            body_filter,
            source_hash_filter
        ),
        SemanticAccessKind::JoinIndex => format!(
            "SELECT count(*)::bigint \
             FROM otlet.semantic_join_index_current_rows({}, true) latest \
             WHERE true{}{}{}",
            sql_literal(&opts.index_name),
            subject_filter,
            body_filter,
            source_hash_filter
        ),
    };
    pgrx::Spi::connect(|client| scalar_select_i64(client, &query))
}

fn scoped_lookup_ms(rows: i64) -> f64 {
    (1.0 + rows.max(0) as f64 * 0.05).max(1.0)
}

fn scoped_refresh_ms(
    global_lookup_ms: f64,
    global_refresh_ms: f64,
    global_refresh_rows: i64,
    scoped_lookup_ms: f64,
    refresh_rows: i64,
) -> f64 {
    if refresh_rows <= 0 {
        return scoped_lookup_ms;
    }
    let global_refresh_rows = global_refresh_rows.max(1) as f64;
    let refresh_cost = (global_refresh_ms - global_lookup_ms).max(1.0);
    scoped_lookup_ms + (refresh_cost / global_refresh_rows) * refresh_rows as f64
}

fn scoped_fresh_inference_ms(global_fresh_inference_ms: f64, global_rows: i64, rows: i64) -> f64 {
    if rows <= 0 {
        return 0.0;
    }
    let global_rows = global_rows.max(1) as f64;
    (global_fresh_inference_ms.max(1.0) / global_rows) * rows as f64
}

fn scoped_freshness(rows: i64, refresh_rows: i64) -> f64 {
    if rows <= 0 {
        1.0
    } else {
        ((rows - refresh_rows).max(0) as f64 / rows as f64).clamp(0.0, 1.0)
    }
}
