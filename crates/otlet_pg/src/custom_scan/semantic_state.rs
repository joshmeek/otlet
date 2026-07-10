fn load_semantic_states(
    index_kind: SemanticIndexKind,
    index_name: &str,
    expected_json: &str,
) -> Result<LoadedSemanticState, String> {
    if index_kind == SemanticIndexKind::Join {
        return load_semantic_join_states(index_name, expected_json);
    }
    pgrx::Spi::connect(|client| {
        let metadata_args = [index_name.into()];
        let metadata = client
            .select(
                "SELECT \
                   si.source_table, \
                   si.subject_column, \
                   CASE WHEN si.input_columns IS NULL THEN NULL ELSE to_jsonb(si.input_columns)::text END AS input_columns_json, \
                   quote_nullable(si.input_columns)::text AS input_columns_sql, \
                   quote_nullable(t.input_shaping::text)::text AS input_shaping_sql, \
                   si.task_name, \
                   si.record_type, \
                   otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract) AS contract_hash, \
                   COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::float8 AS model_ms, \
                   CASE \
                     WHEN COALESCE(rs.last_generate_ms, 0) > 0 THEN 'runtime_slot' \
                     ELSE 'static_fallback' \
                   END AS model_cost_source \
                 FROM otlet.semantic_indexes si \
                 JOIN otlet.tasks t ON t.name = si.task_name \
                 LEFT JOIN otlet.runtime_slots rs ON rs.model_name = t.model_name \
                 WHERE si.name = $1 \
                 LIMIT 1",
                Some(1),
                &metadata_args,
            )
            .map_err(to_string)?;
        if metadata.is_empty() {
            return Err(format!("otlet semantic index {index_name} does not exist"));
        }
        let row = metadata.first();
        let source_table = row
            .get_by_name::<String, _>("source_table")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no source table"))?;
        let subject_column = row
            .get_by_name::<String, _>("subject_column")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no subject column"))?;
        let task_name = row
            .get_by_name::<String, _>("task_name")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no task"))?;
        let input_columns = row
            .get_by_name::<String, _>("input_columns_json")
            .map_err(to_string)?
            .map(|json| serde_json::from_str::<Vec<String>>(&json).map_err(to_string))
            .transpose()?;
        let input_columns_sql = row
            .get_by_name::<String, _>("input_columns_sql")
            .map_err(to_string)?
            .unwrap_or_else(|| "NULL".to_owned());
        let input_shaping_sql = row
            .get_by_name::<String, _>("input_shaping_sql")
            .map_err(to_string)?
            .unwrap_or_else(|| "'{}'".to_owned());
        let record_type = row
            .get_by_name::<String, _>("record_type")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no record type"))?;
        let contract_hash = row
            .get_by_name::<String, _>("contract_hash")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no contract hash"))?;
        let model_ms = row
            .get_by_name::<f64, _>("model_ms")
            .map_err(to_string)?
            .unwrap_or(2500.0);
        let model_cost_source = row
            .get_by_name::<String, _>("model_cost_source")
            .map_err(to_string)?
            .unwrap_or_else(|| "static_fallback".to_owned());
        let source_rows_sql = source_rows_sql(
            &source_table,
            &subject_column,
            &input_columns_sql,
            &input_shaping_sql,
        );
        let freshness_status_sql = semantic_freshness_status_sql(
            "l",
            "src.content_hash",
            "$3::text",
            "src.source_hash",
        );
        let query_args = [
            task_name.as_str().into(),
            record_type.as_str().into(),
            contract_hash.as_str().into(),
            expected_json.into(),
        ];
        let query = format!(
            "WITH source_rows AS ( \
           {source_rows_sql} \
         ), \
         latest_materializations AS ( \
           SELECT DISTINCT ON (sm.subject_id) \
             sm.subject_id, \
             sm.stale, \
             sm.source_hash, \
             sm.content_hash, \
             sm.contract_hash, \
             sm.stale_reason, \
             sm.freshness_basis, \
             (sm.body @> $4::jsonb) AS matches_expected, \
             sm.updated_at, \
             sm.id \
           FROM source_rows src \
           JOIN otlet.semantic_materializations sm \
             ON sm.subject_id = src.subject_id \
           WHERE sm.task_name = $1 \
             AND sm.record_type = $2 \
           ORDER BY sm.subject_id, \
             (sm.content_hash IS NOT DISTINCT FROM src.content_hash AND sm.contract_hash IS NOT DISTINCT FROM $3::text) DESC, \
             sm.updated_at DESC, sm.id DESC \
         ), \
         active_jobs AS ( \
           SELECT DISTINCT j.subject_id \
           FROM otlet.jobs j \
           JOIN source_rows src ON src.subject_id = j.subject_id \
           WHERE j.task_name = $1 \
             AND j.status IN ('queued', 'running', 'cancel_requested') \
         ), \
         semantic_state AS ( \
           SELECT \
             src.subject_id, \
             CASE \
               WHEN a.subject_id IS NOT NULL AND (l.subject_id IS NULL OR status.is_stale) THEN 'in_flight' \
               WHEN l.subject_id IS NULL THEN 'missing' \
               WHEN status.is_stale THEN 'stale' \
               WHEN l.matches_expected THEN 'fresh_match' \
               ELSE 'fresh_non_match' \
             END AS semantic_state, \
             CASE \
               WHEN status.freshness_basis = 'content_hash_match' THEN COALESCE(l.freshness_basis, status.freshness_basis) \
               ELSE status.freshness_basis \
             END AS freshness_basis, \
             CASE \
               WHEN status.is_stale THEN COALESCE(status.stale_reason, 'content_revalidation_pending') \
               ELSE NULL \
             END AS stale_reason \
           FROM source_rows src \
           LEFT JOIN latest_materializations l USING (subject_id) \
           LEFT JOIN active_jobs a USING (subject_id) \
           LEFT JOIN LATERAL {freshness_status_sql} status ON l.subject_id IS NOT NULL \
         ) \
         SELECT subject_id, semantic_state, freshness_basis, stale_reason \
         FROM semantic_state \
         ORDER BY subject_id NULLS LAST"
        );
        let table = client
            .select(query.as_str(), None, &query_args)
            .map_err(to_string)?;
        let capacity = table.len().max(8);
        let mut subjects = HashMap::with_capacity(capacity);
        let mut subject_counts = PreloadedSubjectCounts::new();
        let mut freshness_basis_counts = BTreeMap::new();
        let mut stale_reason_counts = BTreeMap::new();
        let mut freshness_basis_by_subject = HashMap::with_capacity(capacity);
        for row in table {
            let Some(subject_id) = row
                .get_by_name::<String, _>("subject_id")
                .map_err(to_string)?
            else {
                continue;
            };
            let Some(label) = row
                .get_by_name::<String, _>("semantic_state")
                .map_err(to_string)?
            else {
                continue;
            };
            let state = SubjectSemanticState::from_label(&label).ok_or_else(|| {
                format!("otlet unexpected semantic_state from preload SPI: {label}")
            })?;
            if matches!(
                state,
                SubjectSemanticState::FreshMatch | SubjectSemanticState::FreshNonMatch
            ) && let Some(freshness_basis) = row
                .get_by_name::<String, _>("freshness_basis")
                .map_err(to_string)?
            {
                // One clone for the aggregate key; move the owned string into
                // the per-subject map.
                *freshness_basis_counts
                    .entry(freshness_basis.clone())
                    .or_insert(0) += 1;
                freshness_basis_by_subject.insert(subject_id.clone(), freshness_basis);
            }
            // Match SQL plan stale_reasons: count classified is_stale rows by reason.
            if matches!(
                state,
                SubjectSemanticState::Stale | SubjectSemanticState::InFlight
            ) && let Some(stale_reason) = row
                .get_by_name::<String, _>("stale_reason")
                .map_err(to_string)?
            {
                *stale_reason_counts.entry(stale_reason).or_insert(0) += 1;
            }
            subject_counts.record(state);
            subjects.insert(subject_id, state);
        }
        Ok(LoadedSemanticState {
            source_table,
            task_name,
            record_type,
            input_columns,
            freshness_basis_counts: freshness_basis_counts_json(&freshness_basis_counts),
            stale_reasons: freshness_basis_counts_json(&stale_reason_counts),
            model_ms,
            model_cost_source,
            freshness_basis_by_subject,
            subjects,
            subject_counts,
        })
    })
}

fn load_semantic_join_states(
    index_name: &str,
    expected_json: &str,
) -> Result<LoadedSemanticState, String> {
    pgrx::Spi::connect(|client| {
        let args = [index_name.into(), expected_json.into()];
        let query = "WITH meta AS ( \
                   SELECT \
                     sji.task_name, \
                     sji.record_type, \
                     COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::float8 AS model_ms, \
                     CASE \
                       WHEN COALESCE(rs.last_generate_ms, 0) > 0 THEN 'runtime_slot' \
                       ELSE 'static_fallback' \
                     END AS model_cost_source, \
                     COALESCE( \
                       (SELECT plan.stale_reasons::text \
                        FROM otlet.semantic_join_index_plan($1, false) plan \
                        LIMIT 1), \
                       '{}' \
                     ) AS stale_reasons \
                   FROM otlet.semantic_join_indexes sji \
                   JOIN otlet.tasks t ON t.name = sji.task_name \
                   LEFT JOIN otlet.runtime_slots rs ON rs.model_name = t.model_name \
                   WHERE sji.name = $1 \
                   LIMIT 1 \
                 ), \
                 current_rows AS ( \
                   SELECT subject_id, body, stale, freshness_basis \
                   FROM otlet.semantic_join_index_current_rows($1, false) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ), \
                 active_jobs AS ( \
                   SELECT DISTINCT j.subject_id \
                   FROM otlet.jobs j \
                   JOIN meta m ON m.task_name = j.task_name \
                   WHERE j.status IN ('queued', 'running', 'cancel_requested') \
                 ), \
                 subjects AS ( \
                   SELECT \
                     COALESCE(c.subject_id, a.subject_id) AS subject_id, \
                     CASE \
                       WHEN a.subject_id IS NOT NULL AND (c.subject_id IS NULL OR c.stale) THEN 'in_flight' \
                       WHEN c.subject_id IS NULL THEN 'missing' \
                       WHEN c.stale THEN 'stale' \
                       WHEN c.body @> $2::jsonb THEN 'fresh_match' \
                       ELSE 'fresh_non_match' \
                     END AS semantic_state, \
                     c.freshness_basis \
                   FROM current_rows c \
                   FULL JOIN active_jobs a USING (subject_id) \
                 ) \
                 SELECT \
                   m.task_name, \
                   m.record_type, \
                   m.model_ms, \
                   m.model_cost_source, \
                   m.stale_reasons, \
                   s.subject_id, \
                   s.semantic_state, \
                   s.freshness_basis \
                 FROM meta m \
                 LEFT JOIN subjects s ON true \
                 ORDER BY s.subject_id NULLS LAST";
        let table = client
            .select(query, None, &args)
            .map_err(to_string)?;
        if table.is_empty() {
            return Err(format!(
                "otlet semantic join index {index_name} does not exist"
            ));
        }
        let mut task_name = None;
        let mut record_type = None;
        let mut model_ms = 2500.0;
        let mut model_cost_source = "static_fallback".to_owned();
        let mut stale_reasons = "{}".to_owned();
        let capacity = table.len().max(8);
        let mut subjects = HashMap::with_capacity(capacity);
        let mut subject_counts = PreloadedSubjectCounts::new();
        let mut freshness_basis_counts = BTreeMap::new();
        let mut freshness_basis_by_subject = HashMap::with_capacity(capacity);
        let mut saw_meta = false;
        for row in table {
            if !saw_meta {
                saw_meta = true;
                task_name = row
                    .get_by_name::<String, _>("task_name")
                    .map_err(to_string)?;
                record_type = row
                    .get_by_name::<String, _>("record_type")
                    .map_err(to_string)?;
                model_ms = row
                    .get_by_name::<f64, _>("model_ms")
                    .map_err(to_string)?
                    .unwrap_or(2500.0);
                model_cost_source = row
                    .get_by_name::<String, _>("model_cost_source")
                    .map_err(to_string)?
                    .unwrap_or_else(|| "static_fallback".to_owned());
                stale_reasons = row
                    .get_by_name::<String, _>("stale_reasons")
                    .map_err(to_string)?
                    .unwrap_or_else(|| "{}".to_owned());
            }
            if let Some(subject_id) = row
                .get_by_name::<String, _>("subject_id")
                .map_err(to_string)?
            {
                let Some(label) = row
                    .get_by_name::<String, _>("semantic_state")
                    .map_err(to_string)?
                else {
                    continue;
                };
                let state = SubjectSemanticState::from_label(&label).ok_or_else(|| {
                    format!("otlet unexpected semantic_state from join preload SPI: {label}")
                })?;
                if matches!(
                    state,
                    SubjectSemanticState::FreshMatch | SubjectSemanticState::FreshNonMatch
                ) && let Some(freshness_basis) = row
                    .get_by_name::<String, _>("freshness_basis")
                    .map_err(to_string)?
                {
                    *freshness_basis_counts
                        .entry(freshness_basis.clone())
                        .or_insert(0) += 1;
                    freshness_basis_by_subject.insert(subject_id.clone(), freshness_basis);
                }
                subject_counts.record(state);
                subjects.insert(subject_id, state);
            }
        }
        let task_name = task_name
            .ok_or_else(|| format!("otlet semantic join index {index_name} has no task"))?;
        let record_type = record_type
            .ok_or_else(|| format!("otlet semantic join index {index_name} has no record type"))?;
        Ok(LoadedSemanticState {
            source_table: format!("otlet.semantic_join:{index_name}"),
            task_name,
            record_type,
            input_columns: None,
            freshness_basis_counts: freshness_basis_counts_json(&freshness_basis_counts),
            stale_reasons,
            model_ms,
            model_cost_source,
            freshness_basis_by_subject,
            subjects,
            subject_counts,
        })
    })
}

fn freshness_basis_counts_json(counts: &BTreeMap<String, u64>) -> String {
    serde_json::to_string(counts).unwrap_or_else(|_| "{}".to_owned())
}
