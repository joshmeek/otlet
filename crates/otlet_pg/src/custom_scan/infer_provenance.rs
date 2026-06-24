struct InferNowProvenanceCounts {
    receipts: u64,
    outputs: u64,
    actions: u64,
    materializations: u64,
    receipt_id: u64,
    prompt_tokens: u64,
    generated_tokens: u64,
    generate_ms: u64,
    trace_version: String,
    tokens_per_second: String,
    probability_status: String,
    probability_method: String,
    schema_force: String,
    worker_rss_bytes: u64,
    worker_virtual_bytes: u64,
    worker_memory_policy: String,
    model_cache_hit: bool,
    inference_cache_hit: bool,
    inference_cache_entries: u64,
    inference_cache_bytes: u64,
    inference_cache_evictions: u64,
    inference_cache_reason: String,
    detailed_trace_status: String,
    detailed_trace_captured_tokens: u64,
    detailed_trace_skipped_tokens: u64,
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
        "semantic_index_kind": runtime.index_kind.as_str(),
        "semantic_index_name": runtime.index_name.as_str(),
        "semantic_predicate_kind": runtime.predicate_kind.as_str(),
        "semantic_action_type": runtime.action_type.as_deref(),
        "semantic_program_name": runtime.program_name.as_deref(),
        "semantic_program_hash": runtime.program_hash.as_deref(),
        "semantic_program_predicate": runtime.program_predicate.as_deref()
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
         WHERE job_id = {} AND status = 'failed'",
        job_id
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
                .unwrap_or(0)
                .max(0) as u64,
            receipt_id: row
                .get_by_name::<i64, _>("receipt_id")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
        })
    })
}

fn infer_now_provenance_counts(job_id: i64) -> Result<InferNowProvenanceCounts, String> {
    let query = format!(
        "WITH receipt AS ( \
           SELECT * \
           FROM otlet.inference_receipts \
           WHERE job_id = {} AND status = 'complete' \
           ORDER BY id DESC \
           LIMIT 1 \
         ) \
         SELECT \
           (SELECT count(*)::bigint FROM otlet.inference_receipts WHERE job_id = {} AND status = 'complete') AS receipts, \
           (SELECT count(*)::bigint FROM otlet.outputs WHERE job_id = {}) AS outputs, \
           (SELECT count(*)::bigint FROM otlet.actions WHERE job_id = {}) AS actions, \
           ( \
             SELECT count(*)::bigint \
             FROM otlet.semantic_materializations sm \
             JOIN otlet.records r ON r.id = sm.record_id \
             JOIN otlet.actions a ON a.id = r.action_id \
             WHERE a.job_id = {} \
           ) AS materializations, \
           COALESCE((SELECT id FROM receipt), 0)::bigint AS receipt_id, \
           COALESCE((SELECT prompt_tokens FROM receipt), 0)::bigint AS prompt_tokens, \
           COALESCE((SELECT generated_tokens FROM receipt), 0)::bigint AS generated_tokens, \
           COALESCE((SELECT generate_ms FROM receipt), 0)::bigint AS generate_ms, \
           COALESCE((SELECT trace_summary ->> 'trace_version' FROM receipt), '') AS trace_version, \
           COALESCE((SELECT tokens_per_second::text FROM receipt), '') AS tokens_per_second, \
           COALESCE((SELECT trace_summary -> 'probability_summary' ->> 'status' FROM receipt), '') AS probability_status, \
           COALESCE((SELECT trace_summary -> 'probability_summary' ->> 'method' FROM receipt), '') AS probability_method, \
           COALESCE((SELECT trace_summary ->> 'schema_force' FROM receipt), '') AS schema_force, \
           COALESCE(NULLIF((SELECT trace_summary ->> 'worker_process_rss_bytes' FROM receipt), '')::bigint, 0)::bigint AS worker_rss_bytes, \
           COALESCE(NULLIF((SELECT trace_summary ->> 'worker_process_virtual_bytes' FROM receipt), '')::bigint, 0)::bigint AS worker_virtual_bytes, \
           COALESCE((SELECT trace_summary ->> 'worker_memory_sample_policy' FROM receipt), '') AS worker_memory_policy, \
           COALESCE((SELECT trace_summary ->> 'model_cache_hit' FROM receipt), 'false') = 'true' AS model_cache_hit, \
           COALESCE((SELECT trace_summary ->> 'inference_cache_hit' FROM receipt), 'false') = 'true' AS inference_cache_hit, \
           COALESCE(NULLIF((SELECT trace_summary ->> 'inference_cache_entries' FROM receipt), '')::bigint, 0)::bigint AS inference_cache_entries, \
           COALESCE(NULLIF((SELECT trace_summary ->> 'inference_cache_bytes' FROM receipt), '')::bigint, 0)::bigint AS inference_cache_bytes, \
           COALESCE(NULLIF((SELECT trace_summary ->> 'inference_cache_evictions' FROM receipt), '')::bigint, 0)::bigint AS inference_cache_evictions, \
           COALESCE((SELECT trace_summary ->> 'inference_cache_invalidation_reason' FROM receipt), '') AS inference_cache_reason, \
           COALESCE((SELECT trace_summary -> 'detailed_trace' ->> 'status' FROM receipt), '') AS detailed_trace_status, \
           COALESCE(NULLIF((SELECT trace_summary #>> '{{detailed_trace,captured_tokens}}' FROM receipt), '')::bigint, 0)::bigint AS detailed_trace_captured_tokens, \
           COALESCE(NULLIF((SELECT trace_summary #>> '{{detailed_trace,skipped_tokens}}' FROM receipt), '')::bigint, 0)::bigint AS detailed_trace_skipped_tokens, \
           COALESCE(NULLIF((SELECT trace_summary #>> '{{detailed_trace,top_k}}' FROM receipt), '')::bigint, 0)::bigint AS detailed_trace_top_k",
        job_id, job_id, job_id, job_id, job_id
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
                .unwrap_or(0)
                .max(0) as u64,
            outputs: row
                .get_by_name::<i64, _>("outputs")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            actions: row
                .get_by_name::<i64, _>("actions")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            materializations: row
                .get_by_name::<i64, _>("materializations")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            receipt_id: row
                .get_by_name::<i64, _>("receipt_id")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            prompt_tokens: row
                .get_by_name::<i64, _>("prompt_tokens")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            generated_tokens: row
                .get_by_name::<i64, _>("generated_tokens")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            generate_ms: row
                .get_by_name::<i64, _>("generate_ms")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            trace_version: row
                .get_by_name::<String, _>("trace_version")
                .map_err(to_string)?
                .unwrap_or_default(),
            tokens_per_second: row
                .get_by_name::<String, _>("tokens_per_second")
                .map_err(to_string)?
                .unwrap_or_default(),
            probability_status: row
                .get_by_name::<String, _>("probability_status")
                .map_err(to_string)?
                .unwrap_or_default(),
            probability_method: row
                .get_by_name::<String, _>("probability_method")
                .map_err(to_string)?
                .unwrap_or_default(),
            schema_force: row
                .get_by_name::<String, _>("schema_force")
                .map_err(to_string)?
                .unwrap_or_default(),
            worker_rss_bytes: row
                .get_by_name::<i64, _>("worker_rss_bytes")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            worker_virtual_bytes: row
                .get_by_name::<i64, _>("worker_virtual_bytes")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            worker_memory_policy: row
                .get_by_name::<String, _>("worker_memory_policy")
                .map_err(to_string)?
                .unwrap_or_default(),
            model_cache_hit: row
                .get_by_name::<bool, _>("model_cache_hit")
                .map_err(to_string)?
                .unwrap_or(false),
            inference_cache_hit: row
                .get_by_name::<bool, _>("inference_cache_hit")
                .map_err(to_string)?
                .unwrap_or(false),
            inference_cache_entries: row
                .get_by_name::<i64, _>("inference_cache_entries")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            inference_cache_bytes: row
                .get_by_name::<i64, _>("inference_cache_bytes")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            inference_cache_evictions: row
                .get_by_name::<i64, _>("inference_cache_evictions")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            inference_cache_reason: row
                .get_by_name::<String, _>("inference_cache_reason")
                .map_err(to_string)?
                .unwrap_or_default(),
            detailed_trace_status: row
                .get_by_name::<String, _>("detailed_trace_status")
                .map_err(to_string)?
                .unwrap_or_default(),
            detailed_trace_captured_tokens: row
                .get_by_name::<i64, _>("detailed_trace_captured_tokens")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            detailed_trace_skipped_tokens: row
                .get_by_name::<i64, _>("detailed_trace_skipped_tokens")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
            detailed_trace_top_k: row
                .get_by_name::<i64, _>("detailed_trace_top_k")
                .map_err(to_string)?
                .unwrap_or(0)
                .max(0) as u64,
        })
    })
}
