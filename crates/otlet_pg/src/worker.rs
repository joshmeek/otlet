use crate::job::{
    Job, ModelSelectionPolicy, claim_jobs, insert_infer_now_job, model_selection_policy,
};
use crate::model::{
    ModelError, ModelMetrics, ModelRun, clear_task_contract_digests, run_job, run_job_with_model,
};
use pgrx::JsonB;
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use serde_json::Value;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

static EMPTY_TRACE_SUMMARY: LazyLock<Value> = LazyLock::new(|| serde_json::json!({}));

/// Bound idle expired-job sweeps so empty-queue wake loops do not re-scan leases
/// every latch. Lease reclaim still runs at least this often and after any drain.
const EXPIRED_JOB_SWEEP_INTERVAL: Duration = Duration::from_secs(30);
/// Bound idle schema probes the same way: DROP/upgrade still fail closed on the
/// next probe, claim errors, or after productive drain.
const SCHEMA_READY_PROBE_INTERVAL: Duration = Duration::from_secs(30);

#[pgrx::pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_worker_main(_arg: pgrx::pg_sys::Datum) {
    // SIGTERM handling lets Postgres stop the worker cleanly
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGTERM);
    BackgroundWorker::connect_worker_to_spi(Some("postgres"), None);

    crate::wake::register_worker_latch();
    pgrx::log!("otlet worker started");

    let recovery_interval = Duration::from_millis(crate::wake::MISSED_WAKE_RECOVERY_MS);
    let mut last_expired_sweep = Instant::now()
        .checked_sub(EXPIRED_JOB_SWEEP_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut last_schema_probe = Instant::now()
        .checked_sub(SCHEMA_READY_PROBE_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut schema_probe_due = true;

    while BackgroundWorker::wait_latch(Some(recovery_interval)) {
        if schema_probe_due || last_schema_probe.elapsed() >= SCHEMA_READY_PROBE_INTERVAL {
            let schema_ready = match BackgroundWorker::transaction(otlet_schema_ready) {
                Ok(ready) => ready,
                Err(err) => {
                    pgrx::warning!("otlet worker schema readiness check failed: {err}");
                    false
                }
            };
            last_schema_probe = Instant::now();
            if !schema_ready {
                // Keep probing until the extension surface is back.
                schema_probe_due = true;
                continue;
            }
            schema_probe_due = false;
        }

        while let Some(request) = crate::infer_now::take_request() {
            process_infer_now_request(request);
            schema_probe_due = true;
        }

        if last_expired_sweep.elapsed() >= EXPIRED_JOB_SWEEP_INTERVAL {
            let sweep_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
                pgrx::Spi::connect_mut(|client| {
                    client.update("SELECT otlet.sweep_expired_jobs()", Some(1), &[])?;
                    Ok(())
                })
            });
            if let Err(err) = sweep_result {
                pgrx::warning!("otlet worker expired job sweep failed: {err}");
                schema_probe_due = true;
            }
            last_expired_sweep = Instant::now();
        }

        let mut drained = 0;
        loop {
            let jobs = match BackgroundWorker::transaction(claim_jobs) {
                Ok(jobs) if jobs.is_empty() => break,
                Ok(jobs) => jobs,
                Err(err) => {
                    pgrx::warning!("otlet worker claim failed: {err}");
                    schema_probe_due = true;
                    break;
                }
            };

            let batch_owned = jobs.first().filter(|_| jobs.len() > 1).map(|job| {
                let mut task_names = jobs
                    .iter()
                    .map(|job| job.task_name.clone())
                    .collect::<Vec<_>>();
                task_names.sort_unstable();
                task_names.dedup();
                (
                    job.task_name.clone(),
                    task_names,
                    job.model_name.clone(),
                    i64::try_from(jobs.len()).unwrap_or(i64::MAX),
                )
            });

            let batch_start = Instant::now();
            let batch_result = process_job_batch(jobs);
            let batch_ms = millis_since(batch_start);

            if let Some((task_name, task_names, model_name, job_count)) = batch_owned {
                record_worker_batch_finished(
                    &task_name,
                    &task_names,
                    &model_name,
                    job_count,
                    batch_result.completed,
                    batch_result.failed,
                    batch_ms,
                    batch_result.model_swaps,
                );
                drained += u64::try_from(job_count).unwrap_or(0);
            } else {
                drained += u64::try_from(batch_result.completed + batch_result.failed).unwrap_or(0);
            }
        }
        crate::wake::record_worker_drain(drained);
        if drained > 0 {
            // After productive work, reclaim expired leases and re-check schema promptly.
            last_expired_sweep = Instant::now()
                .checked_sub(EXPIRED_JOB_SWEEP_INTERVAL)
                .unwrap_or_else(Instant::now);
            schema_probe_due = true;
        }
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

    let crate::infer_now::InferNowRequest {
        id,
        task_name,
        subject_id,
        input_json,
        ..
    } = request;
    let job = match BackgroundWorker::transaction(|| {
        insert_infer_now_job(&task_name, &subject_id, &input_json)
    }) {
        Ok(Some(job)) => job,
        Ok(None) => {
            crate::infer_now::finish_request(id, 0, Some("infer-now active job already exists"));
            return;
        }
        Err(err) => {
            crate::infer_now::finish_request(
                id,
                0,
                Some(&format!("infer-now job insert failed: {err}")),
            );
            return;
        }
    };

    let job_id = job.id;
    // Reuse request-owned strings; insert_infer_now_job stores them verbatim.
    crate::infer_now::mark_request_job_started(id, job_id);
    let mut process_result = process_job(job);
    if !process_result.completed {
        // Prefer in-process failure text; fall back to jobs.error for paths that
        // only returned a bool (reject/complete) without a ModelError.
        let error = process_result
            .failure_message
            .take()
            .unwrap_or_else(|| infer_now_job_error(job_id));
        crate::infer_now::finish_request(id, job_id, Some(&error));
        return;
    }

    // accept_attempt already materializes via materialize_completed_semantic_job.
    // Skip the follow-up subject materialize when that SPI succeeded; keep the
    // fallback when it failed so infer-now still fail-closes on missing state.
    if !process_result.semantic_materialized
        && let Err(err) = materialize_infer_now_subject(&task_name, &subject_id)
    {
        crate::infer_now::finish_request(
            id,
            job_id,
            Some(&format!("infer-now materialization failed: {err}")),
        );
        return;
    }

    crate::infer_now::finish_request(id, job_id, None);
}

fn ensure_inline_task(request: &crate::infer_now::InferNowRequest) -> Result<(), String> {
    let Some(inline_task_json) = request.inline_task_json.as_deref() else {
        return Ok(());
    };

    let setup_result: pgrx::spi::Result<Result<(), String>> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            // One statement: parse inline_task JSON in SQL, gate on model, create_task.
            // Keeps slot text as `$2::jsonb` — no Rust Value→JsonB round-trip.
            let args = [request.task_name.as_str().into(), inline_task_json.into()];
            let rows = client.select(
                "WITH src AS ( \
                   SELECT COALESCE($2::jsonb, '{}'::jsonb) AS t \
                 ), \
                 model_ok AS ( \
                   SELECT true AS ok FROM otlet.models \
                   WHERE name = COALESCE((SELECT t->>'model_name' FROM src), '') \
                   LIMIT 1 \
                 ) \
                 SELECT \
                   CASE \
                     WHEN (SELECT ok FROM model_ok) THEN ( \
                       SELECT otlet.create_task( \
                         $1, \
                         NULL::text, \
                         COALESCE((SELECT t->>'instruction' FROM src), ''), \
                         COALESCE((SELECT t->'output_schema' FROM src), '{\"type\":\"object\"}'::jsonb), \
                         COALESCE((SELECT t->>'model_name' FROM src), ''), \
                         COALESCE((SELECT t->'runtime_options' FROM src), '{}'::jsonb) \
                       )::text \
                     ) \
                     ELSE NULL \
                   END AS created, \
                   COALESCE((SELECT ok FROM model_ok), false) AS model_ok, \
                   COALESCE((SELECT t->>'model_name' FROM src), '') AS model_name",
                Some(1),
                &args,
            )?;
            let row = rows.first();
            if !row.get::<bool>(2)?.unwrap_or(false) {
                let model_name = row.get::<String>(3)?.unwrap_or_default();
                return Ok(Err(format!("model is not registered: {model_name}")));
            }
            let created = row.get::<String>(1)?;
            if created.as_deref().is_none_or(str::is_empty) {
                return Ok(Err("inline task create_task returned no task".to_owned()));
            }
            Ok(Ok(()))
        })
    });
    match setup_result {
        Ok(result) => result,
        Err(err) => Err(err.to_string()),
    }
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
        Ok(None) => "infer-now job failed without job error".to_owned(),
        Err(err) => format!("infer-now job failed; error lookup failed: {err}"),
    }
}

#[derive(Default)]
struct JobProcessResult {
    completed: bool,
    model_swaps: i64,
    strong_fallback: Option<&'static str>,
    /// In-process failure text for infer-now; avoids a follow-up jobs.error SPI.
    failure_message: Option<String>,
    /// True when accept_attempt's materialize_completed_semantic_job SPI succeeded.
    semantic_materialized: bool,
}

impl JobProcessResult {
    fn completed(completed: bool) -> Self {
        Self {
            completed,
            ..Self::default()
        }
    }

    fn failed_with(err: &ModelError) -> Self {
        Self::from_error(false, err)
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
        result.failure_message = Some(err.message.clone());
        if let Some(metrics) = err.metrics.as_ref() {
            result.add_metrics(metrics);
        }
        result
    }

    const fn add_metrics(&mut self, metrics: &ModelMetrics) {
        if !metrics.cache_hit && !metrics.inference_cache_hit && metrics.model_memory_bytes > 0 {
            self.model_swaps += 1;
        }
    }

    fn add_result_metrics(&mut self, result: &Self) {
        self.model_swaps += result.model_swaps;
    }
}

#[derive(Default)]
struct BatchProcessResult {
    completed: i64,
    failed: i64,
    model_swaps: i64,
}

#[derive(Default)]
struct ModelSelectionPolicyCache {
    cached: Option<(String, Option<ModelSelectionPolicy>)>,
}

impl ModelSelectionPolicyCache {
    fn get(&mut self, task_name: &str) -> pgrx::spi::Result<Option<&ModelSelectionPolicy>> {
        if self
            .cached
            .as_ref()
            .is_none_or(|(cached_task, _)| cached_task != task_name)
        {
            let policy = BackgroundWorker::transaction(|| model_selection_policy(task_name))?;
            self.cached = Some((task_name.to_owned(), policy));
        }
        Ok(self.cached.as_ref().and_then(|(_, policy)| policy.as_ref()))
    }
}

impl BatchProcessResult {
    const fn add_metrics(&mut self, result: &JobProcessResult) {
        self.model_swaps += result.model_swaps;
    }

    const fn add_finished(&mut self, result: &JobProcessResult) {
        if result.completed {
            self.completed += 1;
        } else {
            self.failed += 1;
        }
        self.add_metrics(result);
    }
}

fn process_job_batch(jobs: Vec<Job>) -> BatchProcessResult {
    // One transaction for the whole claim batch: mark_job_started is warn-only
    // and must stay outside the policy-lookup txn (SPI errors abort that txn).
    clear_task_contract_digests();
    mark_jobs_started(&jobs);
    let mut batch = BatchProcessResult::default();
    let mut policy_cache = ModelSelectionPolicyCache::default();
    let mut strong_jobs = Vec::with_capacity(jobs.len().min(8));
    for job in jobs {
        let mut result = process_job_deferred(&job, &mut policy_cache, true);
        if let Some(reason) = result.strong_fallback.take() {
            // Move the original Job; strong model comes from the batch policy cache.
            strong_jobs.push((result, job, reason));
        } else {
            batch.add_finished(&result);
        }
    }

    for (mut result, job, reason) in strong_jobs {
        let strong_result = match policy_cache.get(&job.task_name) {
            Ok(Some(policy)) => run_strong_attempt_with_model(&job, &policy.strong, reason),
            Ok(None) => {
                let err = ModelError::new("strong_fallback_missing_policy");
                fail_attempt_result_with_model(
                    &job,
                    job.model_name.as_str(),
                    &err,
                    "strong",
                    "strong_fallback_missing_policy",
                )
            }
            Err(err) => {
                let model_err =
                    ModelError::new(format!("strong fallback policy lookup failed: {err}"));
                fail_attempt_result_with_model(
                    &job,
                    job.model_name.as_str(),
                    &model_err,
                    "strong",
                    "strong_fallback_policy_lookup_failed",
                )
            }
        };
        result.completed = strong_result.completed;
        result.add_result_metrics(&strong_result);
        if !strong_result.completed {
            result.failure_message = strong_result.failure_message;
        }
        batch.add_finished(&result);
    }

    batch
}

fn process_job(job: Job) -> JobProcessResult {
    clear_task_contract_digests();
    let mut policy_cache = ModelSelectionPolicyCache::default();
    let mut result = process_job_deferred(&job, &mut policy_cache, false);
    if let Some(reason) = result.strong_fallback.take() {
        let strong_result = match policy_cache.get(&job.task_name) {
            Ok(Some(policy)) => run_strong_attempt_with_model(&job, &policy.strong, reason),
            Ok(None) => {
                let err = ModelError::new("strong_fallback_missing_policy");
                fail_attempt_result_with_model(
                    &job,
                    job.model_name.as_str(),
                    &err,
                    "strong",
                    "strong_fallback_missing_policy",
                )
            }
            Err(err) => {
                let model_err =
                    ModelError::new(format!("strong fallback policy lookup failed: {err}"));
                fail_attempt_result_with_model(
                    &job,
                    job.model_name.as_str(),
                    &model_err,
                    "strong",
                    "strong_fallback_policy_lookup_failed",
                )
            }
        };
        result.completed = strong_result.completed;
        result.add_result_metrics(&strong_result);
        if !strong_result.completed {
            result.failure_message = strong_result.failure_message;
        }
    }
    result
}

fn process_job_deferred(
    job: &Job,
    policy_cache: &mut ModelSelectionPolicyCache,
    already_marked: bool,
) -> JobProcessResult {
    // Keep start marking separate: its failure only warns and must not abort
    // the policy lookup transaction (SPI errors abort the current txn).
    if !already_marked {
        mark_jobs_started(std::slice::from_ref(job));
    }

    match policy_cache.get(&job.task_name) {
        Ok(Some(policy)) => process_selected_job(job, policy),
        Ok(None) => process_direct_job(job),
        Err(err) => {
            pgrx::warning!("otlet model selection policy lookup failed: {err}");
            fail_attempt_result_with_model(
                job,
                job.model_name.as_str(),
                &ModelError {
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
            )
        }
    }
}

fn mark_jobs_started(jobs: &[Job]) {
    if jobs.is_empty() {
        return;
    }
    // One SPI statement with a typed bigint[] arg — same per-id side effects as
    // N mark_job_started calls, without building a dynamic ARRAY literal.
    let ids: Vec<i64> = jobs.iter().map(|job| job.id).collect();
    let start_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [ids.as_slice().into()];
            client.update(
                "SELECT otlet.mark_job_started(id) FROM unnest($1::bigint[]) AS id",
                Some(jobs.len() as i64),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = start_result {
        pgrx::warning!("otlet worker start event batch failed: {err}");
    }
}

fn process_direct_job(job: &Job) -> JobProcessResult {
    if let Some(result) = guard_job_lease(job, job.model_name.as_str(), "direct") {
        return result;
    }
    match run_job(job) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            if job
                .decision_contract
                .get("enforce_on_direct")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                let (accepted, _) =
                    accepted_by_direct_decision(&run.output, &job.decision_contract);
                if !accepted {
                    result.completed =
                        reject_direct_attempt(job, run, "direct_rejected_by_decision_contract");
                    if !result.completed {
                        result.failure_message =
                            Some("direct_rejected_by_decision_contract".to_owned());
                    }
                    return result;
                }
            }
            let (completed, semantic_materialized) = accept_attempt_with_model(
                job,
                job.model_name.as_str(),
                run,
                "direct",
                "accepted_by_direct_task",
            );
            result.completed = completed;
            result.semantic_materialized = semantic_materialized;
            if !result.completed {
                result.failure_message = Some("complete_job_produced_no_output".to_owned());
            }
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "direct_attempt_failed");
            fail_attempt_result_with_model(
                job,
                job.model_name.as_str(),
                &err,
                "direct",
                selection_reason,
            )
        }
    }
}

/// Same field defaults and accept rules as the former `direct_accept_field_checks`
/// + `accepted_by_policy` path, without allocating a temporary accept-checks object.
fn accepted_by_direct_decision(output: &Value, decision_contract: &Value) -> (bool, &'static str) {
    static DEFAULT_ABSTAIN: LazyLock<Value> = LazyLock::new(|| serde_json::json!(["unclear"]));
    static EMPTY_CONFIDENCE: LazyLock<Value> = LazyLock::new(|| serde_json::json!([]));

    // Defaults match the old json!({... unwrap_or ...}) materialization; empty
    // field names still skip checks via the same filters as accepted_by_policy.
    let confidence_field = decision_contract
        .get("confidence_field")
        .and_then(Value::as_str)
        .unwrap_or("confidence");
    if !confidence_field.is_empty() {
        let Some(confidence) = output.get(confidence_field).and_then(Value::as_str) else {
            return (false, "missing_confidence_field");
        };
        let accepted_confidence = decision_contract
            .get("accepted_confidence")
            .unwrap_or(&EMPTY_CONFIDENCE);
        if !value_string_array_allows(accepted_confidence, confidence) {
            return (false, "confidence_below_policy");
        }
    }

    let answer_field = decision_contract
        .get("answer_field")
        .and_then(Value::as_str)
        .unwrap_or("match");
    if answer_field.is_empty() {
        return (true, "accepted_by_policy");
    }
    let Some(answer) = output.get(answer_field).and_then(Value::as_str) else {
        return (false, "missing_decision_field");
    };
    let abstain_values = decision_contract
        .get("abstain_values")
        .unwrap_or(&DEFAULT_ABSTAIN);
    if value_string_array_contains(abstain_values, answer) {
        return (false, "abstained_output");
    }

    (true, "accepted_by_policy")
}

fn value_string_array_allows(items: &Value, expected: &str) -> bool {
    let Some(items) = items.as_array() else {
        return true;
    };
    let mut has_strings = false;
    for item in items.iter().filter_map(Value::as_str) {
        has_strings = true;
        if item == expected {
            return true;
        }
    }
    !has_strings
}

fn value_string_array_contains(items: &Value, expected: &str) -> bool {
    items.as_array().is_some_and(|items| {
        items
            .iter()
            .filter_map(Value::as_str)
            .any(|item| item == expected)
    })
}

fn process_selected_job(job: &Job, policy: &ModelSelectionPolicy) -> JobProcessResult {
    // Run cheap model without cloning the full Job; SPI helpers take model_name.
    let cheap_name = policy.cheap.name.as_str();
    if let Some(result) = guard_job_lease(job, cheap_name, "cheap") {
        return result;
    }
    match run_job_with_model(job, &policy.cheap) {
        Ok(run) => {
            let (accepted, reason) = accepted_by_policy(&run.output, &policy.accept_field_checks);
            if accepted {
                let mut result = JobProcessResult::from_run(false, &run);
                let (completed, semantic_materialized) =
                    accept_attempt_with_model(job, cheap_name, run, "cheap", reason);
                result.completed = completed;
                result.semantic_materialized = semantic_materialized;
                if !result.completed {
                    result.failure_message = Some("complete_job_produced_no_output".to_owned());
                }
                return result;
            }
            let mut result = JobProcessResult::from_run(false, &run);
            if !record_rejected_attempt_with_model(job, cheap_name, run, "cheap", reason) {
                let err = ModelError::new("rejected_attempt_receipt_failed");
                return fail_attempt_result_with_model(
                    job,
                    cheap_name,
                    &err,
                    "cheap",
                    "rejected_receipt_failed",
                );
            }
            result.strong_fallback = Some("escalated_after_cheap_rejection");
            result
        }
        Err(err) if err.message == "canceled" => {
            fail_attempt_result_with_model(job, cheap_name, &err, "cheap", "canceled")
        }
        Err(err) if err.raw_output.is_some() => {
            let mut result = JobProcessResult::from_error(false, &err);
            if !record_failed_model_attempt_with_model(
                job,
                cheap_name,
                &err,
                "cheap",
                "schema_validation_failed",
            ) {
                return fail_attempt_result_with_model(
                    job,
                    cheap_name,
                    &err,
                    "cheap",
                    "failed_attempt_receipt_failed",
                );
            }
            result.strong_fallback = Some("escalated_after_cheap_schema_failure");
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "cheap_runtime_failed");
            fail_attempt_result_with_model(job, cheap_name, &err, "cheap", selection_reason)
        }
    }
}

fn run_strong_attempt_with_model(
    job: &Job,
    strong: &crate::job::JobModel,
    reason: &str,
) -> JobProcessResult {
    if let Some(result) = guard_job_lease(job, strong.name.as_str(), "strong") {
        return result;
    }
    match run_job_with_model(job, strong) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            let (completed, semantic_materialized) =
                accept_attempt_with_model(job, strong.name.as_str(), run, "strong", reason);
            result.completed = completed;
            result.semantic_materialized = semantic_materialized;
            if !result.completed {
                result.failure_message = Some("complete_job_produced_no_output".to_owned());
            }
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "strong_attempt_failed");
            fail_attempt_result_with_model(
                job,
                strong.name.as_str(),
                &err,
                "strong",
                selection_reason,
            )
        }
    }
}

fn guard_job_lease(job: &Job, model_name: &str, selection_role: &str) -> Option<JobProcessResult> {
    match renew_job_lease(job) {
        Ok(false) => None,
        Ok(true) => {
            let err = ModelError::new("canceled");
            Some(fail_attempt_result_with_model(
                job,
                model_name,
                &err,
                selection_role,
                "canceled",
            ))
        }
        Err(message) => {
            pgrx::warning!(
                "otlet worker skipped job {} after lease fence failure: {}",
                job.id,
                message
            );
            let err = ModelError::new(message);
            Some(JobProcessResult::failed_with(&err))
        }
    }
}

fn renew_job_lease(job: &Job) -> Result<bool, String> {
    let result: pgrx::spi::Result<Option<bool>> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job.id.into(), job.claim_attempt.into()];
            let rows = client.update(
                "SELECT status FROM otlet.renew_job_lease($1, $2) LIMIT 1",
                Some(1),
                &args,
            )?;
            if rows.is_empty() {
                return Ok(None);
            }
            Ok(rows
                .first()
                .get::<String>(1)?
                .map(|status| status == "cancel_requested"))
        })
    });

    match result {
        Ok(Some(canceled)) => Ok(canceled),
        Ok(None) => Err("job lease fence lost: claim attempt is no longer active".to_owned()),
        Err(err) => Err(format!("job lease renewal failed: {err}")),
    }
}

fn failure_selection_reason<'reason>(err: &ModelError, fallback: &'reason str) -> &'reason str {
    if err.message == "attempt_timeout" {
        "attempt_timeout"
    } else {
        fallback
    }
}

fn accepted_by_policy(output: &Value, accept_field_checks: &Value) -> (bool, &'static str) {
    // Same field readers as accepted_by_direct_decision; policy JSON uses empty
    // arrays (no LazyLock defaults) so confidence/answer empty-field filters
    // and missing accepted_confidence allow-all still match prior behavior.
    if let Some(confidence_field) = accept_field_checks
        .get("confidence_field")
        .and_then(Value::as_str)
        .filter(|field| !field.is_empty())
    {
        let Some(confidence) = output.get(confidence_field).and_then(Value::as_str) else {
            return (false, "missing_confidence_field");
        };
        let accepted_confidence = accept_field_checks
            .get("accepted_confidence")
            .unwrap_or(&Value::Null);
        if !value_string_array_allows(accepted_confidence, confidence) {
            return (false, "confidence_below_policy");
        }
    }

    let Some(answer_field) = accept_field_checks
        .get("answer_field")
        .and_then(Value::as_str)
        .filter(|field| !field.is_empty())
    else {
        return (true, "accepted_by_policy");
    };
    let Some(answer) = output.get(answer_field).and_then(Value::as_str) else {
        return (false, "missing_decision_field");
    };
    let abstain_values = accept_field_checks
        .get("abstain_values")
        .unwrap_or(&Value::Null);
    if value_string_array_contains(abstain_values, answer) {
        return (false, "abstained_output");
    }

    (true, "accepted_by_policy")
}

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
                ];
                let rows = client.select(
                "SELECT output_id, semantic_materialized, completion_error, materialization_error FROM otlet.complete_and_materialize_job($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) LIMIT 1",
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
            ];
            client.update(
                "SELECT otlet.record_model_attempt($1, $2, output => $3, raw_output => $4, prompt_hash => $5, input_hash => $6, output_schema_hash => $7, raw_output_hash => $8, trace_summary => $9, schema_validation_status => $10, selection_role => $11, selection_status => $12, selection_reason => $13, error => $14)",
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
            ];
            client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => 'passed', trace_summary => $8, model_name => $9, selection_role => 'direct', selection_status => 'rejected', selection_reason => 'direct_rejected_by_decision_contract', candidate_output => $10)",
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

fn force_terminal_job_failure(job_id: i64, error: &str) {
    // Error-path only: when fail_job SPI fails, still terminalize the row so it
    // cannot stay running with a live lease. No receipt/metrics/events here.
    // cancel_requested → canceled (matches fail_job → finish_canceled_job);
    // running → failed.
    let recovery: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job_id.into(), error.into()];
            client.update(
                "UPDATE otlet.jobs \
                 SET status = CASE \
                       WHEN status = 'cancel_requested' THEN 'canceled' \
                       ELSE 'failed' \
                     END, \
                     leased_until = NULL, \
                     error = $2, \
                     finished_at = COALESCE(finished_at, now()) \
                 WHERE id = $1 \
                   AND status IN ('running', 'cancel_requested')",
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
            ];
            client.update(
                "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7, schema_validation_status => $8, trace_summary => $9, model_name => $10, selection_role => $11, selection_reason => $12)",
                Some(1),
                &args,
            )?;
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
        force_terminal_job_failure(job.id, &recovery_error);
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

fn record_worker_batch_finished(
    task_name: &str,
    task_names: &[String],
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
                "linked_inproc".into(),
                task_name.into(),
                JsonB(Value::Array(
                    task_names.iter().cloned().map(Value::String).collect(),
                ))
                .into(),
                model_name.into(),
                job_count.into(),
                completed.into(),
                failed.into(),
                batch_ms.into(),
                model_swaps.into(),
            ];
            client.update(
                "SELECT otlet.record_worker_event('worker_batch_finished', $1, $2, 'worker_batch_finished', jsonb_build_object('task_name', $3, 'task_names', $4, 'model_name', $5, 'job_count', $6, 'completed_jobs', $7, 'failed_jobs', $8, 'batch_ms', $9, 'model_swaps', $10))",
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

fn materialize_infer_now_subject(task_name: &str, subject_id: &str) -> pgrx::spi::Result<i64> {
    BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [task_name.into(), subject_id.into()];
            // Match materialize_completed_semantic_job: refresh both row and join indexes.
            let rows = client.select(
                "SELECT COALESCE(sum(refreshed), 0)::bigint AS materialized \
                 FROM ( \
                   SELECT otlet.materialize_semantic_index_subject(si.name, $2) AS refreshed \
                   FROM otlet.semantic_indexes si \
                   WHERE si.task_name = $1 \
                   UNION ALL \
                   SELECT otlet.materialize_semantic_join_index_subject(sji.name, $2) AS refreshed \
                   FROM otlet.semantic_join_indexes sji \
                   WHERE sji.task_name = $1 \
                 ) m",
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
            "SELECT to_regprocedure('otlet.claim_jobs()') IS NOT NULL AND to_regprocedure('otlet.materialize_completed_semantic_job(bigint)') IS NOT NULL AND to_regprocedure('otlet.complete_and_materialize_job(bigint,jsonb,text,jsonb,text,text,text,text,jsonb,text,text,text)') IS NOT NULL",
            Some(1),
            &[],
        )?;
        Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
    })
}
