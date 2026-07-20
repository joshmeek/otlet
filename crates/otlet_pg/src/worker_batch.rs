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
