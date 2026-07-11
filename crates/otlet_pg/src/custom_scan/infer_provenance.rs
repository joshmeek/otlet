struct InferNowProvenanceCounts {
    receipts: u64,
    receipt_id: u64,
    prompt_tokens: u64,
    generated_tokens: u64,
    generate_ms: u64,
    finish_sql_ms: u64,
    materialize_ms: u64,
    trace_version: String,
    probability_status: String,
    schema_force: String,
    detailed_trace_status: String,
    detailed_trace_captured_tokens: u64,
    detailed_trace_top_k: u64,
}

struct InferNowFailedProvenanceCounts {
    receipts: u64,
    receipt_id: u64,
}

fn record_infer_now_failed_provenance(
    runtime: &mut RuntimeState,
    job_id: i64,
) -> Result<(), String> {
    let provenance = with_latest_snapshot(|| infer_now_failed_provenance_counts(job_id))?;
    runtime.infer_failed_receipts = runtime
        .infer_failed_receipts
        .saturating_add(provenance.receipts);
    runtime.infer_failed_receipt_id = provenance.receipt_id;
    Ok(())
}

fn infer_now_failed_provenance_counts(
    job_id: i64,
) -> Result<InferNowFailedProvenanceCounts, String> {
    pgrx::Spi::connect(|client| {
        let args = [job_id.into()];
        let table = client
            .select(
                // Always one row (like count(*)); empty peek still yields 0|0.
                "SELECT CASE WHEN r.id IS NULL THEN 0 ELSE 1 END::bigint AS receipts, \
                        COALESCE(r.id, 0)::bigint AS receipt_id \
                 FROM (SELECT 1) AS _ \
                 LEFT JOIN LATERAL ( \
                   SELECT id \
                   FROM otlet.inference_receipts \
                   WHERE job_id = $1 AND status = 'failed' \
                   ORDER BY attempt_index DESC, id DESC \
                   LIMIT 1 \
                 ) r ON true",
                Some(1),
                &args,
            )
            .map_err(to_string)?;
        let row = table.first();
        Ok(InferNowFailedProvenanceCounts {
            receipts: row
                .get_by_name::<i64, _>("receipts")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
            receipt_id: row
                .get_by_name::<i64, _>("receipt_id")
                .map_err(to_string)?
                .map_or(0, nonnegative_count),
        })
    })
}

// Pure SELECT — CustomScan infer-now can run under a non-volatile planner/executor
// context, so UPDATE must stay on client.update(), not inside SELECT.
// Args: $1=job_id, $2=subject_id, $3=expected_json, $4=task_name, $5=record_type
const INFER_NOW_PROVENANCE_AND_ROW_STATE_SQL: &str = "WITH receipt AS ( \
                   SELECT \
                     id, \
                     prompt_tokens, \
                     generated_tokens, \
                     generate_ms, \
                     NULLIF(trace_summary ->> 'finish_sql_ms', '')::bigint AS finish_sql_ms, \
                     NULLIF(trace_summary ->> 'materialize_ms', '')::bigint AS materialize_ms, \
                     COALESCE(trace_summary ->> 'trace_version', '') AS trace_version, \
                     COALESCE(trace_summary -> 'probability_summary' ->> 'status', '') AS probability_status, \
                     COALESCE(trace_summary ->> 'schema_force', '') AS schema_force, \
                     COALESCE(trace_summary -> 'detailed_trace' ->> 'status', '') AS detailed_trace_status, \
                     NULLIF(trace_summary #>> '{detailed_trace,captured_tokens}', '')::bigint AS detailed_trace_captured_tokens, \
                     NULLIF(trace_summary #>> '{detailed_trace,top_k}', '')::bigint AS detailed_trace_top_k \
                   FROM otlet.inference_receipts \
                   WHERE job_id = $1 AND status = 'complete' \
                   ORDER BY attempt_index DESC, id DESC \
                   LIMIT 1 \
                 ), \
                 latest AS ( \
                   SELECT sm.subject_id, sm.stale, (sm.body @> $3::jsonb) AS matches_expected, \
                     sm.updated_at, sm.id \
                   FROM otlet.semantic_materializations sm \
                   WHERE sm.task_name = $4 \
                     AND sm.record_type = $5 \
                     AND sm.subject_id = $2 \
                   ORDER BY sm.updated_at DESC, sm.id DESC \
                   LIMIT 1 \
                 ), \
                 state AS ( \
                   SELECT CASE \
                     WHEN EXISTS ( \
                       SELECT 1 FROM otlet.jobs j \
                       WHERE j.task_name = $4 \
                         AND j.subject_id = $2 \
                         AND j.status IN ('queued', 'running', 'cancel_requested') \
                       LIMIT 1 \
                     ) AND (l.subject_id IS NULL OR l.stale) THEN 'in_flight' \
                     WHEN l.subject_id IS NULL THEN 'missing' \
                     WHEN l.stale THEN 'stale' \
                     WHEN l.matches_expected THEN 'fresh_match' \
                     ELSE 'fresh_non_match' \
                   END AS semantic_state \
                   FROM (VALUES ($2::text)) ss(subject_id) \
                   LEFT JOIN latest l USING (subject_id) \
                 ) \
                 SELECT \
                   CASE WHEN r.id IS NULL THEN 0 ELSE 1 END::bigint AS receipts, \
                   COALESCE(r.id, 0)::bigint AS receipt_id, \
                   COALESCE(r.prompt_tokens, 0)::bigint AS prompt_tokens, \
                   COALESCE(r.generated_tokens, 0)::bigint AS generated_tokens, \
                   COALESCE(r.generate_ms, 0)::bigint AS generate_ms, \
                   COALESCE(r.finish_sql_ms, 0)::bigint AS finish_sql_ms, \
                   COALESCE(r.materialize_ms, 0)::bigint AS materialize_ms, \
                   COALESCE(r.trace_version, '') AS trace_version, \
                   COALESCE(r.probability_status, '') AS probability_status, \
                   COALESCE(r.schema_force, '') AS schema_force, \
                   COALESCE(r.detailed_trace_status, '') AS detailed_trace_status, \
                   COALESCE(r.detailed_trace_captured_tokens, 0)::bigint AS detailed_trace_captured_tokens, \
                   COALESCE(r.detailed_trace_top_k, 0)::bigint AS detailed_trace_top_k, \
                   s.semantic_state \
                 FROM state s \
                 LEFT JOIN receipt r ON true";

// Args: $1=job_id, $2=index_name, $3=subject_id, $4=expected_json, $5=task_name
const INFER_NOW_PROVENANCE_AND_JOIN_STATE_SQL: &str = "WITH receipt AS ( \
                   SELECT \
                     id, \
                     prompt_tokens, \
                     generated_tokens, \
                     generate_ms, \
                     NULLIF(trace_summary ->> 'finish_sql_ms', '')::bigint AS finish_sql_ms, \
                     NULLIF(trace_summary ->> 'materialize_ms', '')::bigint AS materialize_ms, \
                     COALESCE(trace_summary ->> 'trace_version', '') AS trace_version, \
                     COALESCE(trace_summary -> 'probability_summary' ->> 'status', '') AS probability_status, \
                     COALESCE(trace_summary ->> 'schema_force', '') AS schema_force, \
                     COALESCE(trace_summary -> 'detailed_trace' ->> 'status', '') AS detailed_trace_status, \
                     NULLIF(trace_summary #>> '{detailed_trace,captured_tokens}', '')::bigint AS detailed_trace_captured_tokens, \
                     NULLIF(trace_summary #>> '{detailed_trace,top_k}', '')::bigint AS detailed_trace_top_k \
                   FROM otlet.inference_receipts \
                   WHERE job_id = $1 AND status = 'complete' \
                   ORDER BY attempt_index DESC, id DESC \
                   LIMIT 1 \
                 ), \
                 current_row AS ( \
                   SELECT sm.subject_id, sm.body, sm.stale \
                   FROM otlet.semantic_materializations sm \
                   JOIN otlet.semantic_join_indexes sji \
                     ON sji.task_name = sm.task_name \
                    AND sji.record_type = sm.record_type \
                   WHERE sji.name = $2 \
                     AND sm.subject_id = $3 \
                   ORDER BY sm.updated_at DESC, sm.id DESC \
                   LIMIT 1 \
                 ), \
                 state AS ( \
                   SELECT CASE \
                     WHEN EXISTS ( \
                       SELECT 1 FROM otlet.jobs j \
                       WHERE j.task_name = $5 \
                         AND j.subject_id = $3 \
                         AND j.status IN ('queued', 'running', 'cancel_requested') \
                       LIMIT 1 \
                     ) AND (c.subject_id IS NULL OR c.stale) THEN 'in_flight' \
                     WHEN c.subject_id IS NULL THEN 'missing' \
                     WHEN c.stale THEN 'stale' \
                     WHEN c.body @> $4::jsonb THEN 'fresh_match' \
                     ELSE 'fresh_non_match' \
                   END AS semantic_state \
                   FROM (VALUES ($3::text)) ss(subject_id) \
                   LEFT JOIN current_row c USING (subject_id) \
                 ) \
                 SELECT \
                   CASE WHEN r.id IS NULL THEN 0 ELSE 1 END::bigint AS receipts, \
                   COALESCE(r.id, 0)::bigint AS receipt_id, \
                   COALESCE(r.prompt_tokens, 0)::bigint AS prompt_tokens, \
                   COALESCE(r.generated_tokens, 0)::bigint AS generated_tokens, \
                   COALESCE(r.generate_ms, 0)::bigint AS generate_ms, \
                   COALESCE(r.finish_sql_ms, 0)::bigint AS finish_sql_ms, \
                   COALESCE(r.materialize_ms, 0)::bigint AS materialize_ms, \
                   COALESCE(r.trace_version, '') AS trace_version, \
                   COALESCE(r.probability_status, '') AS probability_status, \
                   COALESCE(r.schema_force, '') AS schema_force, \
                   COALESCE(r.detailed_trace_status, '') AS detailed_trace_status, \
                   COALESCE(r.detailed_trace_captured_tokens, 0)::bigint AS detailed_trace_captured_tokens, \
                   COALESCE(r.detailed_trace_top_k, 0)::bigint AS detailed_trace_top_k, \
                   s.semantic_state \
                 FROM state s \
                 LEFT JOIN receipt r ON true";

const INFER_NOW_STAMP_EXECUTOR_CONTEXT_SQL: &str = "UPDATE otlet.inference_receipts \
                 SET trace_summary = trace_summary || $2::jsonb \
                 WHERE id = ( \
                   SELECT r.id FROM otlet.inference_receipts r \
                   WHERE r.job_id = $1 AND r.status = 'complete' \
                   ORDER BY r.attempt_index DESC, r.id DESC \
                   LIMIT 1 \
                 )";

fn provenance_and_state_from_spi_table(
    table: pgrx::spi::SpiTupleTable<'_>,
) -> Result<(InferNowProvenanceCounts, SubjectSemanticState), String> {
    let row = table.first();
    let provenance = InferNowProvenanceCounts {
        receipts: row
            .get_by_name::<i64, _>("receipts")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        receipt_id: row
            .get_by_name::<i64, _>("receipt_id")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        prompt_tokens: row
            .get_by_name::<i64, _>("prompt_tokens")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        generated_tokens: row
            .get_by_name::<i64, _>("generated_tokens")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        generate_ms: row
            .get_by_name::<i64, _>("generate_ms")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        finish_sql_ms: row
            .get_by_name::<i64, _>("finish_sql_ms")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        materialize_ms: row
            .get_by_name::<i64, _>("materialize_ms")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        trace_version: row
            .get_by_name::<String, _>("trace_version")
            .map_err(to_string)?
            .unwrap_or_default(),
        probability_status: row
            .get_by_name::<String, _>("probability_status")
            .map_err(to_string)?
            .unwrap_or_default(),
        schema_force: row
            .get_by_name::<String, _>("schema_force")
            .map_err(to_string)?
            .unwrap_or_default(),
        detailed_trace_status: row
            .get_by_name::<String, _>("detailed_trace_status")
            .map_err(to_string)?
            .unwrap_or_default(),
        detailed_trace_captured_tokens: row
            .get_by_name::<i64, _>("detailed_trace_captured_tokens")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
        detailed_trace_top_k: row
            .get_by_name::<i64, _>("detailed_trace_top_k")
            .map_err(to_string)?
            .map_or(0, nonnegative_count),
    };
    let label = row
        .get_by_name::<String, _>("semantic_state")
        .map_err(to_string)?
        .ok_or_else(|| "otlet semantic_state SPI returned null".to_owned())?;
    let state = SubjectSemanticState::from_label(&label)
        .ok_or_else(|| format!("otlet unexpected semantic_state from SPI: {label}"))?;
    Ok((provenance, state))
}
