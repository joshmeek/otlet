fn load_semantic_states(
    index_kind: SemanticIndexKind,
    index_name: &str,
    expected_json: &str,
    workload_revision_hash: &str,
    policy: &SemanticAutoPolicy,
) -> Result<LoadedSemanticState, String> {
    if index_kind == SemanticIndexKind::Join {
        return load_semantic_join_states(
            index_name,
            expected_json,
            workload_revision_hash,
            policy,
        );
    }
    let preload_started = std::time::Instant::now();
    pgrx::Spi::connect(|client| {
        let metadata_args = [index_name.into(), workload_revision_hash.into()];
        let metadata = client
            .select(
                "SELECT \
                   revision.definition #>> '{source,source_table}' AS source_table, \
                   revision.definition #>> '{source,subject_column}' AS subject_column, \
                   (revision.definition #> '{source,input_columns}')::pg_catalog.text AS input_columns_json, \
                   CASE \
                     WHEN revision.definition #> '{source,input_columns}' IS NULL THEN 'NULL' \
                     ELSE quote_nullable(ARRAY( \
                       SELECT jsonb_array_elements_text( \
                         revision.definition #> '{source,input_columns}' \
                       ) \
                     ))::pg_catalog.text \
                   END AS input_columns_sql, \
                   quote_nullable((revision.definition #> '{task,input_shaping}')::pg_catalog.text)::pg_catalog.text AS input_shaping_sql, \
                   revision.task_name, \
                   revision.definition #>> '{source,record_type}' AS record_type, \
                   revision.workload_revision_hash AS contract_hash, \
                   COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::pg_catalog.float8 AS model_ms, \
                   CASE \
                     WHEN COALESCE(rs.last_generate_ms, 0) > 0 THEN 'runtime_slot' \
                     ELSE 'static_fallback' \
                   END AS model_cost_source \
                 FROM otlet.workload_revisions revision \
                 JOIN otlet.workload_revision_heads head \
                   ON head.task_name = revision.task_name \
                  AND head.active_workload_revision_hash = revision.workload_revision_hash \
                 LEFT JOIN otlet.runtime_slots rs \
                   ON rs.model_name = revision.definition #>> '{models,direct,name}' \
                 WHERE revision.definition #>> '{source,semantic_index_name}' = $1 \
                   AND revision.definition #>> '{source,kind}' = 'row' \
                   AND revision.workload_revision_hash = $2 \
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
            "$3::pg_catalog.text",
            "src.source_hash",
        );
        let query_args = [
            task_name.as_str().into(),
            record_type.as_str().into(),
            contract_hash.as_str().into(),
            expected_json.into(),
            i64::try_from(CUSTOM_SCAN_PRELOAD_ROW_ACCOUNTED_BYTES)
                .unwrap_or(i64::MAX)
                .into(),
            i64::try_from(CUSTOM_SCAN_PRELOAD_FRESHNESS_ACCOUNTED_BYTES)
                .unwrap_or(i64::MAX)
                .into(),
            i64::try_from(policy.preload_max_rows.saturating_add(1))
                .unwrap_or(i64::MAX)
                .into(),
        ];
        let query_prefix = format!(
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
             (sm.body @> $4::pg_catalog.jsonb) AS matches_expected, \
             sm.updated_at, \
             sm.id \
           FROM source_rows src \
           JOIN otlet.semantic_materializations_effective sm \
             ON sm.subject_id = src.subject_id \
           WHERE sm.task_name = $1 \
             AND sm.record_type = $2 \
             AND sm.contract_hash = $3 \
           ORDER BY sm.subject_id, \
             (sm.content_hash IS NOT DISTINCT FROM src.content_hash AND sm.contract_hash IS NOT DISTINCT FROM $3::pg_catalog.text) DESC, \
             sm.updated_at DESC, sm.id DESC \
         ), \
         active_jobs AS ( \
           SELECT DISTINCT j.subject_id \
           FROM otlet.jobs j \
           JOIN source_rows src ON src.subject_id = j.subject_id \
           WHERE j.task_name = $1 \
             AND j.workload_revision_hash = $3 \
             AND j.execution_mode = 'production' \
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
	         ) "
        );
        let preflight_query = format!(
            "{query_prefix} \
             SELECT \
               count(subject_id)::pg_catalog.int8 AS preload_rows, \
               COALESCE(sum( \
                 $5::pg_catalog.int8 + octet_length(subject_id)::pg_catalog.int8 + \
                 CASE \
                   WHEN semantic_state IN ('fresh_match', 'fresh_non_match') \
                     AND freshness_basis IS NOT NULL \
                   THEN $6::pg_catalog.int8 + \
                     octet_length(subject_id)::pg_catalog.int8 + \
                     octet_length(freshness_basis)::pg_catalog.int8 \
                   ELSE 0 \
                 END \
               ), 0)::pg_catalog.int8 AS preload_bytes \
             FROM semantic_state"
        );
        let preflight = client
            .select(preflight_query.as_str(), Some(1), &query_args)
            .map_err(to_string)?;
        let preflight_row = preflight.first();
        let preload_rows = preflight_row
            .get_by_name::<i64, _>("preload_rows")
            .map_err(to_string)?
            .map_or(0, nonnegative_count);
        let preload_bytes = preflight_row
            .get_by_name::<i64, _>("preload_bytes")
            .map_err(to_string)?
            .map_or(0, nonnegative_count);
        require_preload_within_caps(
            preload_rows,
            preload_bytes,
            preload_elapsed_ms(preload_started),
            policy,
        )?;
        let query = format!(
            "{query_prefix} \
             SELECT subject_id, semantic_state, freshness_basis, stale_reason \
             FROM semantic_state \
             ORDER BY subject_id NULLS LAST \
             LIMIT $7"
        );
        let table = client
            .select(query.as_str(), None, &query_args)
            .map_err(to_string)?;
        let mut subjects = HashMap::new();
        let mut subject_counts = PreloadedSubjectCounts::new();
        let mut freshness_basis_counts = BTreeMap::new();
        let mut stale_reason_counts = BTreeMap::new();
        let mut freshness_basis_by_subject = HashMap::new();
        let mut actual_preload_bytes = 0_u64;
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
            let freshness_basis = if matches!(
                state,
                SubjectSemanticState::FreshMatch | SubjectSemanticState::FreshNonMatch
            ) {
                row.get_by_name::<String, _>("freshness_basis")
                    .map_err(to_string)?
            } else {
                None
            };
            actual_preload_bytes = actual_preload_bytes.saturating_add(
                accounted_preload_row_bytes(&subject_id, freshness_basis.as_deref()),
            );
            require_preload_within_caps(
                (subjects.len() as u64).saturating_add(1),
                actual_preload_bytes,
                preload_elapsed_ms(preload_started),
                policy,
            )?;
            if let Some(freshness_basis) = freshness_basis {
                // Reuse the owned value after cloning the aggregate key
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
        let actual_preload_ms = preload_elapsed_ms(preload_started);
        require_preload_within_caps(
            subjects.len() as u64,
            actual_preload_bytes,
            actual_preload_ms,
            policy,
        )?;
        let actual_preload_rows = subjects.len() as u64;
        Ok(LoadedSemanticState {
            source_table,
            task_name,
            workload_revision_hash: contract_hash,
            record_type,
            input_columns,
            freshness_basis_counts: freshness_basis_counts_json(&freshness_basis_counts),
            stale_reasons: freshness_basis_counts_json(&stale_reason_counts),
            model_ms,
            model_cost_source,
            freshness_basis_by_subject,
            subjects,
            subject_counts,
            preload_rows: actual_preload_rows,
            preload_bytes: actual_preload_bytes,
            preload_ms: actual_preload_ms,
        })
    })
}

fn load_semantic_join_states(
    index_name: &str,
    expected_json: &str,
    workload_revision_hash: &str,
    policy: &SemanticAutoPolicy,
) -> Result<LoadedSemanticState, String> {
    let preload_started = std::time::Instant::now();
    pgrx::Spi::connect(|client| {
        let args = [
            index_name.into(),
            expected_json.into(),
            workload_revision_hash.into(),
            i64::try_from(CUSTOM_SCAN_PRELOAD_ROW_ACCOUNTED_BYTES)
                .unwrap_or(i64::MAX)
                .into(),
            i64::try_from(CUSTOM_SCAN_PRELOAD_FRESHNESS_ACCOUNTED_BYTES)
                .unwrap_or(i64::MAX)
                .into(),
            i64::try_from(policy.preload_max_rows.saturating_add(1))
                .unwrap_or(i64::MAX)
                .into(),
        ];
        let query_prefix = "WITH meta AS ( \
                   SELECT \
                     revision.task_name, \
                     revision.definition #>> '{source,record_type}' AS record_type, \
                     revision.workload_revision_hash, \
                     COALESCE(NULLIF(rs.last_generate_ms, 0), 2500)::pg_catalog.float8 AS model_ms, \
                     CASE \
                       WHEN COALESCE(rs.last_generate_ms, 0) > 0 THEN 'runtime_slot' \
                       ELSE 'static_fallback' \
                     END AS model_cost_source, \
                     COALESCE( \
                       (SELECT plan.stale_reasons::pg_catalog.text \
                        FROM otlet.semantic_join_index_plan($1, false, $3) plan \
                        LIMIT 1), \
                       '{}' \
                     ) AS stale_reasons \
                   FROM otlet.workload_revisions revision \
                   JOIN otlet.workload_revision_heads head \
                     ON head.task_name = revision.task_name \
                    AND head.active_workload_revision_hash = revision.workload_revision_hash \
                   LEFT JOIN otlet.runtime_slots rs \
                     ON rs.model_name = revision.definition #>> '{models,direct,name}' \
                   WHERE revision.definition #>> '{source,semantic_join_index_name}' = $1 \
                     AND revision.definition #>> '{source,kind}' = 'pair' \
                     AND revision.workload_revision_hash = $3 \
                   LIMIT 1 \
                 ), \
                 current_rows AS ( \
                   SELECT subject_id, body, stale, freshness_basis \
                   FROM otlet.semantic_join_index_current_rows($1, false, $3) \
                   WHERE EXISTS (SELECT 1 FROM meta) \
                 ), \
                 active_jobs AS ( \
                   SELECT DISTINCT j.subject_id \
                   FROM otlet.jobs j \
                   JOIN meta m ON m.task_name = j.task_name \
                   WHERE j.workload_revision_hash = $3 \
                     AND j.execution_mode = 'production' \
                     AND j.status IN ('queued', 'running', 'cancel_requested') \
                 ), \
                 subjects AS ( \
                   SELECT \
                     COALESCE(c.subject_id, a.subject_id) AS subject_id, \
                     CASE \
                       WHEN a.subject_id IS NOT NULL AND (c.subject_id IS NULL OR c.stale) THEN 'in_flight' \
                       WHEN c.subject_id IS NULL THEN 'missing' \
                       WHEN c.stale THEN 'stale' \
                       WHEN c.body @> $2::pg_catalog.jsonb THEN 'fresh_match' \
                       ELSE 'fresh_non_match' \
                     END AS semantic_state, \
                     c.freshness_basis \
                   FROM current_rows c \
                   FULL JOIN active_jobs a USING (subject_id) \
	                 ) ";
        let preflight_query = format!(
            "{query_prefix} \
             SELECT \
               count(s.subject_id)::pg_catalog.int8 AS preload_rows, \
               COALESCE(sum( \
                 $4::pg_catalog.int8 + octet_length(s.subject_id)::pg_catalog.int8 + \
                 CASE \
                   WHEN s.semantic_state IN ('fresh_match', 'fresh_non_match') \
                     AND s.freshness_basis IS NOT NULL \
                   THEN $5::pg_catalog.int8 + \
                     octet_length(s.subject_id)::pg_catalog.int8 + \
                     octet_length(s.freshness_basis)::pg_catalog.int8 \
                   ELSE 0 \
                 END \
               ), 0)::pg_catalog.int8 AS preload_bytes \
             FROM meta m \
             LEFT JOIN subjects s ON true"
        );
        let preflight = client
            .select(preflight_query.as_str(), Some(1), &args)
            .map_err(to_string)?;
        if preflight.is_empty() {
            return Err(format!(
                "otlet semantic join index {index_name} does not exist"
            ));
        }
        let preflight_row = preflight.first();
        let preload_rows = preflight_row
            .get_by_name::<i64, _>("preload_rows")
            .map_err(to_string)?
            .map_or(0, nonnegative_count);
        let preload_bytes = preflight_row
            .get_by_name::<i64, _>("preload_bytes")
            .map_err(to_string)?
            .map_or(0, nonnegative_count);
        require_preload_within_caps(
            preload_rows,
            preload_bytes,
            preload_elapsed_ms(preload_started),
            policy,
        )?;
        let query = format!(
            "{query_prefix} \
	                 SELECT \
	                   m.task_name, \
                   m.record_type, \
                   m.workload_revision_hash, \
                   m.model_ms, \
                   m.model_cost_source, \
                   m.stale_reasons, \
                   s.subject_id, \
                   s.semantic_state, \
                   s.freshness_basis \
	                 FROM meta m \
	                 LEFT JOIN subjects s ON true \
	                 ORDER BY s.subject_id NULLS LAST \
                   LIMIT $6"
        );
        let table = client
            .select(query.as_str(), None, &args)
            .map_err(to_string)?;
        if table.is_empty() {
            return Err(format!(
                "otlet semantic join index {index_name} does not exist"
            ));
        }
        let mut task_name = None;
        let mut record_type = None;
        let mut loaded_workload_revision_hash = None;
        let mut model_ms = 2500.0;
        let mut model_cost_source = "static_fallback".to_owned();
        let mut stale_reasons = "{}".to_owned();
        let mut subjects = HashMap::new();
        let mut subject_counts = PreloadedSubjectCounts::new();
        let mut freshness_basis_counts = BTreeMap::new();
        let mut freshness_basis_by_subject = HashMap::new();
        let mut actual_preload_bytes = 0_u64;
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
                loaded_workload_revision_hash = row
                    .get_by_name::<String, _>("workload_revision_hash")
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
                let freshness_basis = if matches!(
                    state,
                    SubjectSemanticState::FreshMatch | SubjectSemanticState::FreshNonMatch
                ) {
                    row.get_by_name::<String, _>("freshness_basis")
                        .map_err(to_string)?
                } else {
                    None
                };
                actual_preload_bytes = actual_preload_bytes.saturating_add(
                    accounted_preload_row_bytes(&subject_id, freshness_basis.as_deref()),
                );
                require_preload_within_caps(
                    (subjects.len() as u64).saturating_add(1),
                    actual_preload_bytes,
                    preload_elapsed_ms(preload_started),
                    policy,
                )?;
                if let Some(freshness_basis) = freshness_basis {
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
        let loaded_workload_revision_hash = loaded_workload_revision_hash.ok_or_else(|| {
            format!("otlet semantic join index {index_name} has no active workload revision")
        })?;
        let actual_preload_rows = subjects.len() as u64;
        let actual_preload_ms = preload_elapsed_ms(preload_started);
        require_preload_within_caps(
            actual_preload_rows,
            actual_preload_bytes,
            actual_preload_ms,
            policy,
        )?;
        Ok(LoadedSemanticState {
            source_table: format!("otlet.semantic_join:{index_name}"),
            task_name,
            workload_revision_hash: loaded_workload_revision_hash,
            record_type,
            input_columns: None,
            freshness_basis_counts: freshness_basis_counts_json(&freshness_basis_counts),
            stale_reasons,
            model_ms,
            model_cost_source,
            freshness_basis_by_subject,
            subjects,
            subject_counts,
            preload_rows: actual_preload_rows,
            preload_bytes: actual_preload_bytes,
            preload_ms: actual_preload_ms,
        })
    })
}

fn freshness_basis_counts_json(counts: &BTreeMap<String, u64>) -> String {
    serde_json::to_string(counts).unwrap_or_else(|_| "{}".to_owned())
}

fn accounted_preload_row_bytes(subject_id: &str, freshness_basis: Option<&str>) -> u64 {
    let subject_bytes = u64::try_from(subject_id.len()).unwrap_or(u64::MAX);
    let freshness_bytes = freshness_basis.map_or(0, |basis| {
        CUSTOM_SCAN_PRELOAD_FRESHNESS_ACCOUNTED_BYTES
            .saturating_add(subject_bytes)
            .saturating_add(u64::try_from(basis.len()).unwrap_or(u64::MAX))
    });
    CUSTOM_SCAN_PRELOAD_ROW_ACCOUNTED_BYTES
        .saturating_add(subject_bytes)
        .saturating_add(freshness_bytes)
}

fn preload_elapsed_ms(started: std::time::Instant) -> u64 {
    let nanos = started.elapsed().as_nanos();
    u64::try_from(nanos.saturating_add(999_999) / 1_000_000).unwrap_or(u64::MAX)
}

fn require_preload_within_caps(
    rows: u64,
    bytes: u64,
    elapsed_ms: u64,
    policy: &SemanticAutoPolicy,
) -> Result<(), String> {
    require_preload_within_limits(
        rows,
        bytes,
        elapsed_ms,
        policy.preload_max_rows,
        policy.preload_max_bytes,
        policy.preload_max_ms,
    )
}

fn require_preload_within_limits(
    rows: u64,
    bytes: u64,
    elapsed_ms: u64,
    max_rows: u64,
    max_bytes: u64,
    max_ms: u64,
) -> Result<(), String> {
    if let Some((dimension, actual, limit)) =
        preload_cap_violation(rows, bytes, elapsed_ms, max_rows, max_bytes, max_ms)
    {
        return Err(format!(
            "otlet semantic CustomScan preload hard cap exceeded: dimension={dimension} actual={actual} limit={limit}"
        ));
    }
    Ok(())
}

fn retain_runtime_semantic_state(
    runtime: &mut RuntimeState,
    subject_id: &str,
    state: SubjectSemanticState,
) -> Result<(), String> {
    if let Some(existing) = runtime.semantic_states.get_mut(subject_id) {
        *existing = state;
        return Ok(());
    }
    let rows = (runtime.semantic_states.len() as u64).saturating_add(1);
    let bytes = runtime
        .retained_state_bytes
        .saturating_add(accounted_preload_row_bytes(subject_id, None));
    require_preload_within_limits(
        rows,
        bytes,
        runtime.actual_preload_ms,
        runtime.preload_max_rows,
        runtime.preload_max_bytes,
        runtime.preload_max_ms,
    )?;
    runtime.semantic_states.insert(subject_id.to_owned(), state);
    runtime.retained_state_bytes = bytes;
    Ok(())
}
