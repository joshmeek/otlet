struct InferNowProvenanceCounts {
    receipts: u64,
    receipt_id: u64,
    prompt_tokens: u64,
    generated_tokens: u64,
    generate_ms: u64,
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

fn record_infer_now_executor_context(runtime: &RuntimeState, job_id: i64) -> Result<(), String> {
    let context = json!({
        "executor_origin": "customscan_infer_now",
        "executor_node": "Otlet Semantic Source CustomScan",
        "executor_boundary": "CustomScan owned Postgres-planned source child scan",
        "planner_selected_path": runtime.planner_selected_path.as_str(),
        "source_tuple_provider": source_tuple_provider(runtime),
        "refresh_policy": refresh_policy_from_parts(
            runtime.auto_policy,
            runtime.allow_refresh,
            runtime.wait_ms,
            runtime.infer_ms
        ),
        "semantic_index_kind": runtime.index_kind.as_str(),
        "semantic_index_name": runtime.index_name.as_str()
    });
    pgrx::Spi::connect_mut(|client| {
        let args = [job_id.into(), JsonB(context).into()];
        client
            .update(
                "UPDATE otlet.inference_receipts \
                 SET trace_summary = trace_summary || $2 \
                 WHERE job_id = $1 AND status = 'complete'",
                None,
                &args,
            )
            .map_err(to_string)?;
        Ok::<(), String>(())
    })
}

fn infer_now_failed_provenance_counts(
    job_id: i64,
) -> Result<InferNowFailedProvenanceCounts, String> {
    let query = format!(
        "SELECT count(*)::bigint AS receipts, \
                COALESCE(max(id), 0)::bigint AS receipt_id \
         FROM otlet.inference_receipts \
         WHERE job_id = {job_id} AND status = 'failed'"
    );
    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
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

fn infer_now_provenance_counts(job_id: i64) -> Result<InferNowProvenanceCounts, String> {
    let query = format!(
        "WITH receipt AS ( \
           SELECT * \
           FROM otlet.inference_receipts \
           WHERE job_id = {job_id} AND status = 'complete' \
           ORDER BY id DESC \
           LIMIT 1 \
         ) \
         SELECT \
           (SELECT count(*)::bigint FROM otlet.inference_receipts WHERE job_id = {job_id} AND status = 'complete') AS receipts, \
           COALESCE((SELECT id FROM receipt), 0)::bigint AS receipt_id, \
           COALESCE((SELECT prompt_tokens FROM receipt), 0)::bigint AS prompt_tokens, \
           COALESCE((SELECT generated_tokens FROM receipt), 0)::bigint AS generated_tokens, \
           COALESCE((SELECT generate_ms FROM receipt), 0)::bigint AS generate_ms, \
           COALESCE((SELECT trace_summary ->> 'trace_version' FROM receipt), '') AS trace_version, \
           COALESCE((SELECT trace_summary -> 'probability_summary' ->> 'status' FROM receipt), '') AS probability_status, \
           COALESCE((SELECT trace_summary ->> 'schema_force' FROM receipt), '') AS schema_force, \
           COALESCE((SELECT trace_summary -> 'detailed_trace' ->> 'status' FROM receipt), '') AS detailed_trace_status, \
           COALESCE(NULLIF((SELECT trace_summary #>> '{{detailed_trace,captured_tokens}}' FROM receipt), '')::bigint, 0)::bigint AS detailed_trace_captured_tokens, \
           COALESCE(NULLIF((SELECT trace_summary #>> '{{detailed_trace,top_k}}' FROM receipt), '')::bigint, 0)::bigint AS detailed_trace_top_k"
    );
    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        Ok(InferNowProvenanceCounts {
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
        })
    })
}
