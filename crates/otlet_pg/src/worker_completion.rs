fn accept_attempt_with_model(
    job: &Job,
    model_name: &str,
    run: ModelRun,
    selection_role: &str,
    selection_reason: &str,
) -> (bool, bool) {
    // Keep telemetry separate so a metric error cannot roll back completion
    // Returns (completed, semantic_materialized).
    let metrics = run.metrics.as_ref();
    if let Some(metrics) = metrics {
        record_metrics(job, model_name, metrics);
    }
    match crate::infer_now::persist_timeout_cancel(job.id) {
        Ok(true) => {
            let err = ModelError::new("canceled");
            return (
                fail_attempt_with_model(job, model_name, &err, selection_role, "canceled"),
                false,
            );
        }
        Ok(false) => {}
        Err(message) => {
            let err = ModelError::new(message);
            return (
                fail_attempt_with_model(
                    job,
                    model_name,
                    &err,
                    selection_role,
                    "infer_now_timeout_cancel_failed",
                ),
                false,
            );
        }
    }
    let result: pgrx::spi::Result<(bool, bool, Option<String>, Option<String>)> =
        BackgroundWorker::transaction(|| {
            pgrx::Spi::connect_mut(|client| {
                let args = [
                    job.id.into(),
                    JsonB(run.output).into(),
                    run.raw_output.as_str().into(),
                    JsonB(run.actions).into(),
                    run.prompt_hash.as_str().into(),
                    run.input_hash.as_str().into(),
                    run.output_schema_hash.as_str().into(),
                    run.raw_output_hash.as_str().into(),
                    JsonB(run.trace_summary).into(),
                    model_name.into(),
                    selection_role.into(),
                    selection_reason.into(),
                    job.claim_token.as_str().into(),
                ];
                let rows = client.select(
                "SELECT output_id, semantic_materialized, completion_error, materialization_error FROM otlet.complete_and_materialize_job($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) LIMIT 1",
                Some(1),
                &args,
            )?;
                let row = rows.first();
                Ok((
                    row.get::<i64>(1)?.is_some(),
                    row.get::<bool>(2)?.unwrap_or(false),
                    row.get::<String>(3)?,
                    row.get::<String>(4)?,
                ))
            })
        });

    match result {
        Ok((true, semantic_materialized, _, materialization_error)) => {
            if let Some(error) = &materialization_error {
                pgrx::warning!(
                    "otlet semantic materialization failed for job {}: {}",
                    job.id,
                    error
                );
            }
            pgrx::log!("otlet worker completed job {}", job.id);
            (true, semantic_materialized)
        }
        Ok((false, _, Some(error), _)) => {
            pgrx::warning!("otlet worker complete failed: {error}");
            let model_err = ModelError::new(format!("complete_job failed: {error}"));
            (
                fail_attempt_with_model(
                    job,
                    model_name,
                    &model_err,
                    selection_role,
                    "complete_job_spi_failed",
                ),
                false,
            )
        }
        Ok((false, _, None, _)) => {
            pgrx::warning!(
                "otlet worker complete produced no output row for job {}",
                job.id
            );
            let err = ModelError::new("complete_job_produced_no_output");
            (
                fail_attempt_with_model(
                    job,
                    model_name,
                    &err,
                    selection_role,
                    "complete_job_failed",
                ),
                false,
            )
        }
        Err(err) => {
            pgrx::warning!("otlet worker complete failed: {err}");
            let model_err = ModelError::new(format!("complete_job failed: {err}"));
            (
                fail_attempt_with_model(
                    job,
                    model_name,
                    &model_err,
                    selection_role,
                    "complete_job_spi_failed",
                ),
                false,
            )
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn record_model_attempt_receipt_with_model(
    job: &Job,
    model_name: &str,
    output: Option<&serde_json::Value>,
    raw_output: Option<&str>,
    prompt_hash: Option<&str>,
    input_hash: Option<&str>,
    output_schema_hash: Option<&str>,
    raw_output_hash: Option<&str>,
    trace_summary: Value,
    schema_validation_status: Option<&str>,
    selection_role: &str,
    selection_status: &str,
    selection_reason: &str,
    error: Option<&str>,
    metrics: Option<&ModelMetrics>,
) -> bool {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                job.id.into(),
                model_name.into(),
                output.cloned().map(JsonB).into(),
                raw_output.into(),
                prompt_hash.into(),
                input_hash.into(),
                output_schema_hash.into(),
                raw_output_hash.into(),
                JsonB(trace_summary).into(),
                schema_validation_status.into(),
                selection_role.into(),
                selection_status.into(),
                selection_reason.into(),
                error.into(),
                job.claim_token.as_str().into(),
            ];
            client.update(
                "SELECT otlet.record_model_attempt($1, $2, output => $3, raw_output => $4, prompt_hash => $5, input_hash => $6, output_schema_hash => $7, raw_output_hash => $8, trace_summary => $9, schema_validation_status => $10, selection_role => $11, selection_status => $12, selection_reason => $13, error => $14, expected_claim_token => $15)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet worker model-attempt receipt failed: {err}");
        return false;
    }
    if let Some(metrics) = metrics {
        record_metrics(job, model_name, metrics);
    }
    true
}

fn record_rejected_attempt_with_model(
    job: &Job,
    model_name: &str,
    run: ModelRun,
    selection_role: &str,
    selection_reason: &str,
) -> bool {
    let ModelRun {
        output,
        raw_output,
        prompt_hash,
        input_hash,
        output_schema_hash,
        raw_output_hash,
        trace_summary,
        metrics,
        ..
    } = run;
    record_model_attempt_receipt_with_model(
        job,
        model_name,
        Some(&output),
        Some(&raw_output),
        Some(&prompt_hash),
        Some(&input_hash),
        Some(&output_schema_hash),
        Some(&raw_output_hash),
        trace_summary,
        None,
        selection_role,
        "rejected",
        selection_reason,
        None,
        metrics.as_ref(),
    )
}

fn reject_direct_attempt(job: &Job, run: ModelRun, selection_reason: &str) -> bool {
    let metrics = run.metrics.as_ref();
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                job.id.into(),
                selection_reason.into(),
                run.raw_output.as_str().into(),
                run.prompt_hash.as_str().into(),
                run.input_hash.as_str().into(),
                run.output_schema_hash.as_str().into(),
                run.raw_output_hash.as_str().into(),
                JsonB(run.trace_summary.clone()).into(),
                job.model_name.as_str().into(),
                JsonB(run.output.clone()).into(),
                job.claim_token.as_str().into(),
            ];
            client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => 'passed', trace_summary => $8, model_name => $9, selection_role => 'direct', selection_status => 'rejected', selection_reason => 'direct_rejected_by_decision_contract', candidate_output => $10, expected_claim_token => $11)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        // Fail closed: do not leave the job running after a rejected direct attempt.
        pgrx::warning!("otlet worker direct rejection failed: {err}");
        let model_err = ModelError {
            message: selection_reason.to_owned(),
            raw_output: Some(run.raw_output),
            prompt_hash: Some(run.prompt_hash),
            input_hash: Some(run.input_hash),
            output_schema_hash: Some(run.output_schema_hash),
            raw_output_hash: Some(run.raw_output_hash),
            schema_validation_status: Some("passed".to_owned()),
            trace_summary: Some(run.trace_summary),
            metrics: run.metrics.map(Box::new),
        };
        return fail_attempt_with_model(
            job,
            job.model_name.as_str(),
            &model_err,
            "direct",
            selection_reason,
        );
    }
    if let Some(metrics) = metrics {
        record_metrics(job, job.model_name.as_str(), metrics);
    }
    false
}

fn record_failed_model_attempt_with_model(
    job: &Job,
    model_name: &str,
    err: &ModelError,
    selection_role: &str,
    selection_reason: &str,
) -> bool {
    record_model_attempt_receipt_with_model(
        job,
        model_name,
        None,
        err.raw_output.as_deref(),
        err.prompt_hash.as_deref(),
        err.input_hash.as_deref(),
        err.output_schema_hash.as_deref(),
        err.raw_output_hash.as_deref(),
        err.trace_summary
            .clone()
            .unwrap_or_else(|| EMPTY_TRACE_SUMMARY.clone()),
        err.schema_validation_status.as_deref(),
        selection_role,
        "failed",
        selection_reason,
        Some(&err.message),
        err.metrics.as_ref().map(|m| m.as_ref()),
    )
}

fn fail_attempt_result_with_model(
    job: &Job,
    model_name: &str,
    err: &ModelError,
    selection_role: &str,
    selection_reason: &str,
) -> JobProcessResult {
    let mut result = JobProcessResult::failed_with(err);
    result.completed =
        fail_attempt_with_model(job, model_name, err, selection_role, selection_reason);
    result
}

fn force_terminal_job_failure(job_id: i64, claim_token: &str, error: &str) {
    // Emergency fallback terminalizes the row when fail_job SPI fails
    // No receipt, metric, or event can be recorded through the failing path
    // A cancel request becomes canceled and other live work becomes failed
    let recovery: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job_id.into(), error.into(), claim_token.into()];
            client.update(
                "UPDATE otlet.jobs \
                 SET status = CASE \
                       WHEN status = 'cancel_requested' THEN 'canceled' \
                       ELSE 'failed' \
                     END, \
                     leased_until = NULL, \
                     terminal_claim_token = $3, \
                     terminal_request_hash = otlet.job_terminal_request_hash( \
                       'emergency-fail', jsonb_build_array($2) \
                     ), \
                     claim_token = NULL, \
                     error = $2, \
                     finished_at = COALESCE(finished_at, now()) \
                 WHERE id = $1 \
                   AND status IN ('running', 'cancel_requested') \
                   AND claim_token = $3 \
                   AND leased_until IS NOT NULL \
                   AND leased_until >= now()",
                Some(1),
                &args,
            )?;
            // Best-effort slot release so active_jobs does not stay stuck at 1.
            let _ = client.update(
                "SELECT otlet.touch_runtime_slot(m.name, 'error', 0, $2) \
                 FROM otlet.jobs j \
                 JOIN otlet.tasks t ON t.name = j.task_name \
                 JOIN otlet.models m ON m.name = t.model_name \
                 WHERE j.id = $1 AND j.status IN ('failed', 'canceled')",
                Some(1),
                &args,
            );
            Ok(())
        })
    });
    if let Err(recovery_err) = recovery {
        pgrx::warning!("otlet worker terminal job recovery failed: {recovery_err}");
    }
}

fn fail_attempt_with_model(
    job: &Job,
    model_name: &str,
    err: &ModelError,
    selection_role: &str,
    selection_reason: &str,
) -> bool {
    let metrics = err.metrics.as_ref().map(|m| m.as_ref());
    let rejected_memory = err.trace_summary.as_ref().and_then(|trace| {
        (trace
            .pointer("/memory/admission/decision")
            .and_then(Value::as_str)
            == Some("rejected"))
        .then(|| trace.get("memory").cloned())
        .flatten()
    });
    if let Some(metrics) = metrics {
        // Metrics are best effort and must not roll back terminal job state
        record_metrics(job, model_name, metrics);
    }
    let canceled = err.message == "canceled";
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let trace_summary = err.trace_summary.as_ref().unwrap_or(&EMPTY_TRACE_SUMMARY);
            let args = [
                job.id.into(),
                err.message.as_str().into(),
                err.raw_output.as_deref().into(),
                err.prompt_hash.as_deref().into(),
                err.input_hash.as_deref().into(),
                err.output_schema_hash.as_deref().into(),
                err.raw_output_hash.as_deref().into(),
                err.schema_validation_status.as_deref().into(),
                JsonB(trace_summary.clone()).into(),
                model_name.into(),
                selection_role.into(),
                selection_reason.into(),
                job.claim_token.as_str().into(),
            ];
            let rows = client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => $8, trace_summary => $9, model_name => $10, selection_role => $11, selection_reason => $12, expected_claim_token => $13)",
                Some(1),
                &args,
            )?;
            if rows.is_empty() {
                return Ok(());
            }
            if let Some(memory) = &rejected_memory {
                let event_args = [
                    job.id.into(),
                    job.task_name.as_str().into(),
                    model_name.into(),
                    JsonB(memory.clone()).into(),
                ];
                client.update(
                    "SELECT otlet.record_worker_event('model_admission_rejected', $1, 'linked_inproc', 'model load rejected before tensor allocation', jsonb_build_object('task_name', $2, 'model_name', $3, 'memory', $4))",
                    Some(1),
                    &event_args,
                )?;
            }
            Ok(())
        })
    });
    if let Err(fail_err) = result {
        pgrx::warning!("otlet worker fail_job call failed: {fail_err}");
        let recovery_error = format!("fail_job_spi_failed: {fail_err}; original: {}", err.message);
        force_terminal_job_failure(
            job.id,
            job.claim_token.as_str(),
            &recovery_error,
        );
    }
    if canceled {
        pgrx::log!("otlet worker canceled job {}", job.id);
    } else {
        pgrx::warning!("otlet worker failed job {}: {}", job.id, err.message);
    }
    false
}

fn record_metrics(job: &Job, model_name: &str, metrics: &ModelMetrics) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                model_name.into(),
                metrics.artifact_path.as_str().into(),
                metrics.load_ms.into(),
                metrics.ctx_ms.into(),
                metrics.prompt_tokens.into(),
                metrics.generated_tokens.into(),
                metrics.generate_ms.into(),
                metrics.cache_hit.into(),
                metrics.inference_cache_hit.into(),
                metrics.inference_cache_entries.into(),
                metrics.inference_cache_bytes.into(),
                metrics.inference_cache_evictions.into(),
                metrics.inference_cache_invalidation_reason.into(),
                metrics.model_memory_bytes.into(),
                metrics.model_parameters.into(),
                metrics.context_window_tokens.into(),
                metrics.model_device_policy.into(),
                metrics.memory_accounting_policy.into(),
                metrics.worker_process_rss_bytes.into(),
                metrics.worker_process_virtual_bytes.into(),
                metrics.worker_memory_sample_policy.into(),
                metrics.inference_cache_max_entries.into(),
                metrics.inference_cache_max_bytes.into(),
                metrics.inference_cache_eviction_reason.into(),
            ];
            client.update(
                "SELECT otlet.record_runtime_slot_metrics($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)",
                Some(1),
                &args,
            )?;
            if !metrics.cache_hit && !metrics.inference_cache_hit && metrics.model_memory_bytes > 0
            {
                let event_args = [
                    job.id.into(),
                    "linked_inproc".into(),
                    job.task_name.as_str().into(),
                    model_name.into(),
                    metrics.artifact_path.as_str().into(),
                    metrics.load_ms.into(),
                    metrics.model_memory_bytes.into(),
                    metrics.worker_process_rss_bytes.into(),
                    metrics.worker_memory_budget_bytes.into(),
                    JsonB(metrics.memory_trace.clone()).into(),
                ];
                client.update(
                    "SELECT otlet.record_worker_event('model_swap', $1, $2, 'model residency changed', jsonb_build_object('task_name', $3, 'model_name', $4, 'artifact_path', $5, 'load_ms', $6, 'model_memory_bytes', $7, 'worker_process_rss_bytes', $8, 'worker_memory_budget_bytes', $9, 'memory', $10))",
                    Some(1),
                    &event_args,
                )?;
            }
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet worker metric update failed: {err}");
    }
}
