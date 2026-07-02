fn load_semantic_states(
    index_kind: SemanticIndexKind,
    index_name: &str,
    expected_json: &str,
) -> Result<LoadedSemanticState, String> {
    if index_kind == SemanticIndexKind::Join {
        return load_semantic_join_states(index_name, expected_json);
    }
    pgrx::Spi::connect(|client| {
        let metadata_query = format!(
            "SELECT \
               si.source_table, \
               si.subject_column, \
               si.task_name, \
               si.record_type, \
               otlet.task_contract_hash(t.instruction, t.output_schema, t.model_name, t.runtime_options, t.input_shaping, t.decision_contract) AS contract_hash \
             FROM otlet.semantic_indexes si \
             JOIN otlet.tasks t ON t.name = si.task_name \
             WHERE si.name = {} \
             LIMIT 1",
            sql_literal(index_name)
        );
        let metadata = client
            .select(metadata_query.as_str(), Some(1), &[])
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
        let record_type = row
            .get_by_name::<String, _>("record_type")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no record type"))?;
        let contract_hash = row
            .get_by_name::<String, _>("contract_hash")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic index {index_name} has no contract hash"))?;
        let source_rows_sql = source_rows_sql(&source_table, &subject_column);
        let matches_expected_sql = row_predicate_match_sql("sm.body", expected_json);
        let query = format!(
            "WITH latest_materializations AS ( \
           SELECT DISTINCT ON (sm.subject_id) \
             sm.subject_id, \
             sm.stale, \
             sm.source_hash, \
             sm.content_hash, \
             sm.contract_hash, \
             {} AS matches_expected, \
             sm.updated_at, \
             sm.id \
           FROM otlet.semantic_materializations sm \
           WHERE sm.task_name = {} \
             AND sm.record_type = {} \
           ORDER BY sm.subject_id, sm.updated_at DESC, sm.id DESC \
         ), \
         active_jobs AS ( \
           SELECT DISTINCT j.subject_id \
           FROM otlet.jobs j \
           WHERE j.task_name = {} \
             AND j.status IN ('queued', 'running', 'cancel_requested') \
         ), \
         source_rows AS ( \
           {} \
         ), \
         semantic_state AS ( \
           SELECT \
             src.subject_id, \
             CASE \
               WHEN a.subject_id IS NOT NULL AND (l.subject_id IS NULL OR l.content_hash IS DISTINCT FROM src.content_hash OR l.contract_hash IS DISTINCT FROM {}) THEN 'in_flight' \
               WHEN l.subject_id IS NULL THEN 'missing' \
               WHEN l.content_hash IS DISTINCT FROM src.content_hash OR l.contract_hash IS DISTINCT FROM {} THEN 'stale' \
               WHEN l.matches_expected THEN 'fresh_match' \
               ELSE 'fresh_non_match' \
             END AS semantic_state \
           FROM source_rows src \
           LEFT JOIN latest_materializations l USING (subject_id) \
           LEFT JOIN active_jobs a USING (subject_id) \
         ) \
         SELECT subject_id, semantic_state \
         FROM semantic_state \
         ORDER BY subject_id NULLS LAST",
            matches_expected_sql,
            sql_literal(&task_name),
            sql_literal(&record_type),
            sql_literal(&task_name),
            source_rows_sql,
            sql_literal(&contract_hash),
            sql_literal(&contract_hash)
        );
        let table = client
            .select(query.as_str(), None, &[])
            .map_err(to_string)?;
        let mut subjects = HashMap::new();
        for row in table {
            if let Some(subject_id) = row
                .get_by_name::<String, _>("subject_id")
                .map_err(to_string)?
            {
                if let Some(state) = row
                    .get_by_name::<String, _>("semantic_state")
                    .map_err(to_string)?
                    .and_then(|state| SubjectSemanticState::from_label(&state))
                {
                    subjects.insert(subject_id, state);
                }
            }
        }
        Ok(LoadedSemanticState {
            source_table,
            task_name,
            record_type,
            subjects,
        })
    })
}

fn load_semantic_join_states(
    index_name: &str,
    expected_json: &str,
) -> Result<LoadedSemanticState, String> {
    pgrx::Spi::connect(|client| {
        let metadata_query = format!(
            "SELECT task_name, record_type \
             FROM otlet.semantic_join_indexes \
             WHERE name = {} \
             LIMIT 1",
            sql_literal(index_name)
        );
        let metadata = client
            .select(metadata_query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        if metadata.is_empty() {
            return Err(format!(
                "otlet semantic join index {index_name} does not exist"
            ));
        }
        let row = metadata.first();
        let task_name = row
            .get_by_name::<String, _>("task_name")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic join index {index_name} has no task"))?;
        let record_type = row
            .get_by_name::<String, _>("record_type")
            .map_err(to_string)?
            .ok_or_else(|| format!("otlet semantic join index {index_name} has no record type"))?;
        let query = format!(
            "WITH current_rows AS ( \
               SELECT subject_id, body, stale \
               FROM otlet.semantic_join_index_current_rows({}, false) \
             ), \
             active_jobs AS ( \
               SELECT DISTINCT subject_id \
               FROM otlet.jobs \
               WHERE task_name = {} \
                 AND status IN ('queued', 'running', 'cancel_requested') \
             ) \
             SELECT \
               COALESCE(c.subject_id, a.subject_id) AS subject_id, \
               CASE \
                 WHEN a.subject_id IS NOT NULL AND (c.subject_id IS NULL OR c.stale) THEN 'in_flight' \
                 WHEN c.subject_id IS NULL THEN 'missing' \
                 WHEN c.stale THEN 'stale' \
                 WHEN c.body @> {}::jsonb THEN 'fresh_match' \
                 ELSE 'fresh_non_match' \
               END AS semantic_state \
             FROM current_rows c \
             FULL JOIN active_jobs a USING (subject_id) \
             ORDER BY subject_id NULLS LAST",
            sql_literal(index_name),
            sql_literal(&task_name),
            sql_literal(expected_json)
        );
        let table = client
            .select(query.as_str(), None, &[])
            .map_err(to_string)?;
        let mut subjects = HashMap::new();
        for row in table {
            if let Some(subject_id) = row
                .get_by_name::<String, _>("subject_id")
                .map_err(to_string)?
            {
                if let Some(state) = row
                    .get_by_name::<String, _>("semantic_state")
                    .map_err(to_string)?
                    .and_then(|state| SubjectSemanticState::from_label(&state))
                {
                    subjects.insert(subject_id, state);
                }
            }
        }
        Ok(LoadedSemanticState {
            source_table: format!("otlet.semantic_join:{index_name}"),
            task_name,
            record_type,
            subjects,
        })
    })
}
