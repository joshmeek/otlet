use crate::job::{
    Job, ModelSelectionPolicy, claim_jobs, insert_infer_now_job, model_selection_policy,
};
use crate::model::{ModelError, ModelMetrics, ModelRun, run_job};
use pgrx::JsonB;
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use std::time::{Duration, Instant};

#[pgrx::pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_worker_main(_arg: pgrx::pg_sys::Datum) {
    // SIGTERM handling lets Postgres stop the worker cleanly
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);

    crate::wake::register_worker_latch();
    pgrx::log!("otlet worker started");

    let recovery_interval = Duration::from_millis(crate::wake::MISSED_WAKE_RECOVERY_MS);

    while BackgroundWorker::wait_latch(Some(recovery_interval)) {
        let schema_ready = match BackgroundWorker::transaction(otlet_schema_ready) {
            Ok(ready) => ready,
            Err(err) => {
                pgrx::warning!("otlet worker schema readiness check failed: {err}");
                false
            }
        };
        if !schema_ready {
            continue;
        }

        while let Some(request) = crate::infer_now::take_request() {
            process_infer_now_request(request);
        }

        let sweep_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
            pgrx::Spi::connect_mut(|client| {
                client.update("SELECT otlet.sweep_expired_jobs()", Some(1), &[])?;
                Ok(())
            })
        });
        if let Err(err) = sweep_result {
            pgrx::warning!("otlet worker expired job sweep failed: {err}");
        }

        let mut drained = 0;
        loop {
            let jobs = match BackgroundWorker::transaction(claim_jobs) {
                Ok(jobs) if jobs.is_empty() => break,
                Ok(jobs) => jobs,
                Err(err) => {
                    pgrx::warning!("otlet worker claim failed: {err}");
                    break;
                }
            };

            let batch = jobs.first().filter(|_| jobs.len() > 1).map(|job| {
                (
                    job.runtime_name.clone(),
                    job.task_name.clone(),
                    job.model_name.clone(),
                    jobs.len() as i64,
                )
            });

            let batch_start = Instant::now();
            let batch_result = process_job_batch(jobs);
            let batch_ms = millis_since(batch_start);

            if let Some((runtime_name, task_name, model_name, job_count)) = batch {
                record_worker_batch_finished(
                    &runtime_name,
                    &task_name,
                    &model_name,
                    job_count,
                    batch_result.completed,
                    batch_result.failed,
                    batch_ms,
                    batch_result.model_swaps,
                );
                drained += job_count as u64;
            } else {
                drained += (batch_result.completed + batch_result.failed) as u64;
            }
        }
        crate::wake::record_worker_drain(drained);
    }

    crate::wake::unregister_worker_latch();
    pgrx::log!("otlet worker stopped");
}

fn process_infer_now_request(request: crate::infer_now::InferNowRequest) {
    if let Err(err) = ensure_inline_task(&request) {
        crate::infer_now::finish_request(
            request.id,
            0,
            Some(&format!("infer-now inline task setup failed: {err}")),
        );
        return;
    }

    let job = match BackgroundWorker::transaction(|| {
        insert_infer_now_job(&request.task_name, &request.subject_id, &request.input)
    }) {
        Ok(Some(job)) => job,
        Ok(None) => {
            crate::infer_now::finish_request(
                request.id,
                0,
                Some("infer-now active job already exists"),
            );
            return;
        }
        Err(err) => {
            crate::infer_now::finish_request(
                request.id,
                0,
                Some(&format!("infer-now job insert failed: {err}")),
            );
            return;
        }
    };

    let job_id = job.id;
    crate::infer_now::mark_request_job_started(request.id, job_id);
    let task_name = job.task_name.clone();
    let subject_id = job.subject_id.clone();
    if !process_job(job).completed {
        let error = infer_now_job_error(job_id);
        crate::infer_now::finish_request(request.id, job_id, Some(&error));
        return;
    }

    if let Err(err) = materialize_infer_now_subject(&task_name, &subject_id) {
        crate::infer_now::finish_request(
            request.id,
            job_id,
            Some(&format!("infer-now materialization failed: {err}")),
        );
        return;
    }

    crate::infer_now::finish_request(request.id, job_id, None);
}

fn ensure_inline_task(request: &crate::infer_now::InferNowRequest) -> pgrx::spi::Result<()> {
    let Some(inline_task) = request.inline_task.as_ref() else {
        return Ok(());
    };
    let model_name = inline_task
        .get("model_name")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let instruction = inline_task
        .get("instruction")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let output_schema = inline_task
        .get("output_schema")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({"type":"object"}));
    let runtime_options = inline_task
        .get("runtime_options")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));

    BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                request.task_name.as_str().into(),
                instruction.into(),
                JsonB(output_schema).into(),
                model_name.into(),
                JsonB(runtime_options).into(),
            ];
            client.update(
                "SELECT otlet.create_task($1, NULL::text, $2, $3, $4, $5)",
                Some(5),
                &args,
            )?;
            Ok(())
        })
    })
}

fn infer_now_job_error(job_id: i64) -> String {
    let result: pgrx::spi::Result<Option<String>> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect(|client| {
            let args = [job_id.into()];
            let rows =
                client.select("SELECT error FROM otlet.jobs WHERE id = $1", Some(1), &args)?;
            Ok(rows
                .first()
                .get::<String>(1)?
                .filter(|error| !error.is_empty()))
        })
    });

    match result {
        Ok(Some(error)) => error,
        Ok(None) => "infer-now job failed without job error".to_string(),
        Err(err) => format!("infer-now job failed; error lookup failed: {err}"),
    }
}

#[derive(Default)]
struct JobProcessResult {
    completed: bool,
    model_swaps: i64,
    strong_fallback: Option<(Job, &'static str)>,
}

impl JobProcessResult {
    fn completed(completed: bool) -> Self {
        Self {
            completed,
            ..Self::default()
        }
    }

    fn from_run(completed: bool, run: &ModelRun) -> Self {
        let mut result = Self::completed(completed);
        if let Some(metrics) = run.metrics.as_ref() {
            result.add_metrics(metrics);
        }
        result
    }

    fn from_error(completed: bool, err: &ModelError) -> Self {
        let mut result = Self::completed(completed);
        if let Some(metrics) = err.metrics.as_ref() {
            result.add_metrics(metrics);
        }
        result
    }

    fn add_metrics(&mut self, metrics: &ModelMetrics) {
        if !metrics.cache_hit && !metrics.inference_cache_hit && metrics.model_memory_bytes > 0 {
            self.model_swaps += 1;
        }
    }

    fn add_result_metrics(&mut self, result: &JobProcessResult) {
        self.model_swaps += result.model_swaps;
    }
}

#[derive(Default)]
struct BatchProcessResult {
    completed: i64,
    failed: i64,
    model_swaps: i64,
}

impl BatchProcessResult {
    fn add_metrics(&mut self, result: &JobProcessResult) {
        self.model_swaps += result.model_swaps;
    }

    fn add_finished(&mut self, result: JobProcessResult) {
        if result.completed {
            self.completed += 1;
        } else {
            self.failed += 1;
        }
        self.add_metrics(&result);
    }
}

fn process_job_batch(jobs: Vec<Job>) -> BatchProcessResult {
    let mut batch = BatchProcessResult::default();
    let mut strong_jobs = Vec::new();
    for job in jobs {
        let mut result = process_job_deferred(job);
        if let Some((strong_job, reason)) = result.strong_fallback.take() {
            strong_jobs.push((result, strong_job, reason));
        } else {
            batch.add_finished(result);
        }
    }

    for (mut result, job, reason) in strong_jobs {
        let strong_result = run_strong_attempt_result(job, reason);
        result.completed = strong_result.completed;
        result.add_result_metrics(&strong_result);
        batch.add_finished(result);
    }

    batch
}

fn process_job(job: Job) -> JobProcessResult {
    let mut result = process_job_deferred(job);
    if let Some((job, reason)) = result.strong_fallback.take() {
        let strong_result = run_strong_attempt_result(job, reason);
        result.completed = strong_result.completed;
        result.add_result_metrics(&strong_result);
    }
    result
}

fn process_job_deferred(job: Job) -> JobProcessResult {
    mark_job_started(&job);

    match BackgroundWorker::transaction(|| model_selection_policy(&job.task_name)) {
        Ok(Some(policy)) => process_selected_job(job, policy),
        Ok(None) => process_direct_job(job),
        Err(err) => {
            pgrx::warning!("otlet model selection policy lookup failed: {err}");
            JobProcessResult::completed(fail_attempt(
                &job,
                ModelError {
                    message: format!("model selection policy lookup failed: {err}"),
                    raw_output: None,
                    prompt_hash: None,
                    input_hash: None,
                    output_schema_hash: None,
                    raw_output_hash: None,
                    schema_validation_status: None,
                    trace_summary: None,
                    metrics: None,
                },
                "direct",
                "policy_lookup_failed",
            ))
        }
    }
}

fn mark_job_started(job: &Job) {
    let start_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job.id.into()];
            client.update("SELECT otlet.mark_job_started($1)", Some(1), &args)?;
            Ok(())
        })
    });
    if let Err(err) = start_result {
        pgrx::warning!("otlet worker start event failed: {err}");
    }
}

fn process_direct_job(job: Job) -> JobProcessResult {
    match run_job(&job) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            if let Some(accept_checks) = direct_accept_field_checks(&job) {
                let (accepted, _) = accepted_by_policy(&run.output, &accept_checks);
                if !accepted {
                    result.completed =
                        reject_direct_attempt(&job, run, "direct_rejected_by_decision_contract");
                    return result;
                }
            }
            result.completed = accept_attempt(&job, run, "direct", "accepted_by_direct_task");
            result
        }
        Err(err) => {
            let mut result = JobProcessResult::from_error(false, &err);
            let selection_reason = failure_selection_reason(&err, "direct_attempt_failed");
            result.completed = fail_attempt(&job, err, "direct", selection_reason);
            result
        }
    }
}

fn direct_accept_field_checks(job: &Job) -> Option<serde_json::Value> {
    if !job
        .decision_contract
        .get("enforce_on_direct")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
    {
        return None;
    }

    Some(serde_json::json!({
        "answer_field": job
            .decision_contract
            .get("answer_field")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("match"),
        "abstain_values": job
            .decision_contract
            .get("abstain_values")
            .cloned()
            .unwrap_or_else(|| serde_json::json!(["unclear"])),
        "confidence_field": job
            .decision_contract
            .get("confidence_field")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("confidence"),
        "accepted_confidence": job
            .decision_contract
            .get("accepted_confidence")
            .cloned()
            .unwrap_or_else(|| serde_json::json!([]))
    }))
}

fn process_selected_job(job: Job, policy: ModelSelectionPolicy) -> JobProcessResult {
    let cheap_job = job.with_model(&policy.cheap);
    match run_job(&cheap_job) {
        Ok(run) => {
            let (accepted, reason) = accepted_by_policy(&run.output, &policy.accept_field_checks);
            if accepted {
                let mut result = JobProcessResult::from_run(false, &run);
                result.completed = accept_attempt(&cheap_job, run, "cheap", &reason);
                return result;
            }
            let mut result = JobProcessResult::from_run(false, &run);
            record_metrics_from_run(&cheap_job, &run);
            if !record_rejected_attempt(&cheap_job, run, "cheap", &reason) {
                return result;
            }
            result.strong_fallback = Some((
                job.with_model(&policy.strong),
                "escalated_after_cheap_rejection",
            ));
            result
        }
        Err(err) if err.message == "canceled" => {
            JobProcessResult::completed(fail_attempt(&cheap_job, err, "cheap", "canceled"))
        }
        Err(err) if err.raw_output.is_some() => {
            let mut result = JobProcessResult::from_error(false, &err);
            record_metrics_from_error(&cheap_job, &err);
            if !record_failed_model_attempt(&cheap_job, &err, "cheap", "schema_validation_failed") {
                return result;
            }
            result.strong_fallback = Some((
                job.with_model(&policy.strong),
                "escalated_after_cheap_schema_failure",
            ));
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "cheap_runtime_failed");
            JobProcessResult::completed(fail_attempt(&cheap_job, err, "cheap", selection_reason))
        }
    }
}

fn run_strong_attempt_result(job: Job, reason: &str) -> JobProcessResult {
    match run_job(&job) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            result.completed = accept_attempt(&job, run, "strong", reason);
            result
        }
        Err(err) => {
            let mut result = JobProcessResult::from_error(false, &err);
            let selection_reason = failure_selection_reason(&err, "strong_attempt_failed");
            result.completed = fail_attempt(&job, err, "strong", selection_reason);
            result
        }
    }
}

fn failure_selection_reason<'a>(err: &ModelError, fallback: &'a str) -> &'a str {
    if err.message == "attempt_timeout" {
        "attempt_timeout"
    } else {
        fallback
    }
}

fn accepted_by_policy(
    output: &serde_json::Value,
    accept_field_checks: &serde_json::Value,
) -> (bool, String) {
    if let Some(confidence_field) = accept_field_checks
        .get("confidence_field")
        .and_then(serde_json::Value::as_str)
        .filter(|field| !field.is_empty())
    {
        let Some(confidence) = output
            .get(confidence_field)
            .and_then(serde_json::Value::as_str)
        else {
            return (false, "missing_confidence_field".to_owned());
        };
        let accepted_confidence = json_string_array(accept_field_checks, "accepted_confidence");
        if !accepted_confidence.is_empty()
            && !accepted_confidence
                .iter()
                .any(|allowed| allowed == confidence)
        {
            return (false, "confidence_below_policy".to_owned());
        }
    }

    let Some(answer_field) = accept_field_checks
        .get("answer_field")
        .and_then(serde_json::Value::as_str)
        .filter(|field| !field.is_empty())
    else {
        return (true, "accepted_by_policy".to_owned());
    };
    let Some(answer) = output.get(answer_field).and_then(serde_json::Value::as_str) else {
        return (false, "missing_decision_field".to_owned());
    };
    if json_string_array(accept_field_checks, "abstain_values")
        .iter()
        .any(|abstain| abstain == answer)
    {
        return (false, "abstained_output".to_owned());
    }

    (true, "accepted_by_policy".to_owned())
}

fn json_string_array(value: &serde_json::Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn accept_attempt(job: &Job, run: ModelRun, selection_role: &str, selection_reason: &str) -> bool {
    record_metrics_from_run(job, &run);
    let result: pgrx::spi::Result<bool> = BackgroundWorker::transaction(|| {
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
                job.model_name.as_str().into(),
                selection_role.into(),
                selection_reason.into(),
            ];
            let rows = client.select(
                "SELECT EXISTS(SELECT 1 FROM otlet.complete_job($1, $2, $3, $4, $5, $6, $7, $8, trace_summary => $9, model_name => $10, selection_role => $11, selection_reason => $12)) AS completed",
                Some(1),
                &args,
            )?;
            Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
        })
    });

    match result {
        Ok(true) => {
            materialize_completed_semantic_job(job);
            pgrx::log!("otlet worker completed job {}", job.id);
            true
        }
        Ok(false) => {
            pgrx::warning!(
                "otlet worker complete produced no output row for job {}",
                job.id
            );
            false
        }
        Err(err) => {
            pgrx::warning!("otlet worker complete failed: {err}");
            false
        }
    }
}

fn record_rejected_attempt(
    job: &Job,
    run: ModelRun,
    selection_role: &str,
    selection_reason: &str,
) -> bool {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                job.id.into(),
                job.model_name.as_str().into(),
                run.raw_output.as_str().into(),
                run.prompt_hash.as_str().into(),
                run.input_hash.as_str().into(),
                run.output_schema_hash.as_str().into(),
                run.raw_output_hash.as_str().into(),
                JsonB(run.trace_summary).into(),
                selection_role.into(),
                selection_reason.into(),
            ];
            client.update(
                "SELECT otlet.record_model_attempt($1, $2, raw_output => $3, prompt_hash => $4, input_hash => $5, output_schema_hash => $6, raw_output_hash => $7, trace_summary => $8, selection_role => $9, selection_status => 'rejected', selection_reason => $10)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet worker rejected-attempt receipt failed: {err}");
        return false;
    }
    true
}

fn reject_direct_attempt(job: &Job, run: ModelRun, selection_reason: &str) -> bool {
    record_metrics_from_run(job, &run);
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
                JsonB(run.trace_summary).into(),
                job.model_name.as_str().into(),
            ];
            client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => 'passed', trace_summary => $8, model_name => $9, selection_role => 'direct', selection_status => 'rejected', selection_reason => 'direct_rejected_by_decision_contract')",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet worker direct rejection failed: {err}");
    }
    false
}

fn record_failed_model_attempt(
    job: &Job,
    err: &ModelError,
    selection_role: &str,
    selection_reason: &str,
) -> bool {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let trace_summary = err
                .trace_summary
                .clone()
                .unwrap_or_else(|| serde_json::json!({}));
            let args = [
                job.id.into(),
                job.model_name.as_str().into(),
                err.raw_output.as_deref().into(),
                err.prompt_hash.as_deref().into(),
                err.input_hash.as_deref().into(),
                err.output_schema_hash.as_deref().into(),
                err.raw_output_hash.as_deref().into(),
                JsonB(trace_summary).into(),
                err.schema_validation_status.as_deref().into(),
                selection_role.into(),
                selection_reason.into(),
                err.message.as_str().into(),
            ];
            client.update(
                "SELECT otlet.record_model_attempt($1, $2, raw_output => $3, prompt_hash => $4, input_hash => $5, output_schema_hash => $6, raw_output_hash => $7, trace_summary => $8, schema_validation_status => $9, selection_role => $10, selection_status => 'failed', selection_reason => $11, error => $12)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(receipt_err) = result {
        pgrx::warning!("otlet worker failed-attempt receipt failed: {receipt_err}");
        return false;
    }
    true
}

fn fail_attempt(job: &Job, err: ModelError, selection_role: &str, selection_reason: &str) -> bool {
    record_metrics_from_error(job, &err);
    let canceled = err.message == "canceled";
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let trace_summary = err
                .trace_summary
                .clone()
                .unwrap_or_else(|| serde_json::json!({}));
            let args = [
                job.id.into(),
                err.message.as_str().into(),
                err.raw_output.as_deref().into(),
                err.prompt_hash.as_deref().into(),
                err.input_hash.as_deref().into(),
                err.output_schema_hash.as_deref().into(),
                err.raw_output_hash.as_deref().into(),
                err.schema_validation_status.as_deref().into(),
                JsonB(trace_summary).into(),
                job.model_name.as_str().into(),
                selection_role.into(),
                selection_reason.into(),
            ];
            client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => $8, trace_summary => $9, model_name => $10, selection_role => $11, selection_reason => $12)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(fail_err) = result {
        pgrx::warning!("otlet worker fail_job call failed: {fail_err}");
    }
    if canceled {
        pgrx::log!("otlet worker canceled job {}", job.id);
    } else {
        pgrx::warning!("otlet worker failed job {}: {}", job.id, err.message);
    }
    false
}

fn record_metrics_from_run(job: &Job, run: &ModelRun) {
    if let Some(metrics) = run.metrics.as_ref() {
        record_metrics(job, metrics);
    }
}

fn record_metrics_from_error(job: &Job, err: &ModelError) {
    if let Some(metrics) = err.metrics.as_ref() {
        record_metrics(job, metrics);
    }
}

fn record_metrics(job: &Job, metrics: &ModelMetrics) {
    let metric_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                job.runtime_name.as_str().into(),
                job.model_name.as_str().into(),
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
                metrics.inference_cache_invalidation_reason.as_str().into(),
                metrics.model_memory_bytes.into(),
                metrics.model_parameters.into(),
                metrics.context_window_tokens.into(),
                metrics.model_device_policy.as_str().into(),
                metrics.memory_accounting_policy.as_str().into(),
                metrics.worker_process_rss_bytes.into(),
                metrics.worker_process_virtual_bytes.into(),
                metrics.worker_memory_sample_policy.as_str().into(),
                metrics.inference_cache_max_entries.into(),
                metrics.inference_cache_max_bytes.into(),
                metrics.inference_cache_eviction_reason.as_str().into(),
            ];
            client.update(
                "SELECT otlet.record_runtime_slot_metrics($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25)",
                Some(1),
                &args,
            )?;
            if !metrics.cache_hit && !metrics.inference_cache_hit && metrics.model_memory_bytes > 0
            {
                let event_args = [
                    job.id.into(),
                    job.runtime_name.as_str().into(),
                    job.task_name.as_str().into(),
                    job.model_name.as_str().into(),
                    metrics.artifact_path.as_str().into(),
                    metrics.load_ms.into(),
                    metrics.model_memory_bytes.into(),
                    metrics.worker_process_rss_bytes.into(),
                    metrics.worker_memory_budget_bytes.into(),
                ];
                client.update(
                    "SELECT otlet.record_worker_event('model_swap', $1, $2, 'model residency changed', jsonb_build_object('task_name', $3, 'model_name', $4, 'artifact_path', $5, 'load_ms', $6, 'model_memory_bytes', $7, 'worker_process_rss_bytes', $8, 'worker_memory_budget_bytes', $9))",
                    Some(1),
                    &event_args,
                )?;
            }
            Ok(())
        })
    });
    if let Err(err) = metric_result {
        pgrx::warning!("otlet worker metric update failed: {err}");
    }
}

fn record_worker_batch_finished(
    runtime_name: &str,
    task_name: &str,
    model_name: &str,
    job_count: i64,
    completed: i64,
    failed: i64,
    batch_ms: i64,
    model_swaps: i64,
) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                Option::<i64>::None.into(),
                runtime_name.into(),
                task_name.into(),
                model_name.into(),
                job_count.into(),
                completed.into(),
                failed.into(),
                batch_ms.into(),
                model_swaps.into(),
            ];
            client.update(
                "SELECT otlet.record_worker_event('worker_batch_finished', $1, $2, 'worker_batch_finished', jsonb_build_object('task_name', $3, 'model_name', $4, 'job_count', $5, 'completed_jobs', $6, 'failed_jobs', $7, 'batch_ms', $8, 'model_swaps', $9))",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet worker batch event failed: {err}");
    }
}

fn millis_since(start: Instant) -> i64 {
    i64::try_from(start.elapsed().as_millis()).unwrap_or(i64::MAX)
}

fn materialize_completed_semantic_job(job: &Job) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job.id.into()];
            client.update(
                "SELECT otlet.materialize_completed_semantic_job($1)",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        record_semantic_materialization_failed(job, &err.to_string());
    }
}

fn record_semantic_materialization_failed(job: &Job, error: &str) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                job.id.into(),
                job.runtime_name.as_str().into(),
                job.task_name.as_str().into(),
                job.subject_id.as_str().into(),
                job.model_name.as_str().into(),
                error.into(),
            ];
            client.update(
                "SELECT otlet.record_worker_event('semantic_materialization_failed', $1, $2, 'otlet semantic materialization failed', jsonb_build_object('task_name', $3, 'subject_id', $4, 'model_name', $5, 'error', $6))",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet semantic materialization failure event failed: {err}");
    }
}

fn materialize_infer_now_subject(task_name: &str, subject_id: &str) -> pgrx::spi::Result<i64> {
    BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [task_name.into(), subject_id.into()];
            let rows = client.select(
                "SELECT COALESCE(sum(otlet.materialize_semantic_index_subject(si.name, $2)), 0)::bigint AS materialized \
                 FROM otlet.semantic_indexes si \
                 WHERE si.task_name = $1",
                Some(1),
                &args,
            )?;
            Ok(rows.first().get::<i64>(1)?.unwrap_or(0))
        })
    })
}

fn otlet_schema_ready() -> pgrx::spi::Result<bool> {
    pgrx::Spi::connect(|client| {
        let rows = client.select(
            "SELECT to_regprocedure('otlet.claim_jobs()') IS NOT NULL AND to_regprocedure('otlet.materialize_completed_semantic_job(bigint)') IS NOT NULL",
            Some(1),
            &[],
        )?;
        Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
    })
}
