use crate::job::{Job, claim_job, insert_infer_now_job};
use crate::model::run_job;
use pgrx::JsonB;
use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use std::time::Duration;

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

        let mut drained = 0;
        loop {
            let job = match BackgroundWorker::transaction(claim_job) {
                Ok(Some(job)) => job,
                Ok(None) => break,
                Err(err) => {
                    pgrx::warning!("otlet worker claim failed: {err}");
                    break;
                }
            };
            process_job(job);
            drained += 1;
        }
        crate::wake::record_worker_drain(drained);
    }

    crate::wake::unregister_worker_latch();
    pgrx::log!("otlet worker stopped");
}

fn process_infer_now_request(request: crate::infer_now::InferNowRequest) {
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
    if !process_job(job) {
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

fn process_job(job: Job) -> bool {
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

    match run_job(&job) {
        Ok(run) => {
            let metrics = run.metrics;
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
                    ];
                    let rows = client.select(
                        "SELECT EXISTS(SELECT 1 FROM otlet.complete_job($1, $2, $3, $4, $5, $6, $7, $8, trace_summary => $9)) AS completed",
                        Some(1),
                        &args,
                    )?;
                    Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
                })
            });

            match result {
                Ok(true) => {
                    if let Some(metrics) = metrics {
                        let metric_result: pgrx::spi::Result<()> = BackgroundWorker::transaction(
                            || {
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
                                    ];
                                    client.update(
                                        "SELECT otlet.record_runtime_slot_metrics($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22)",
                                        Some(1),
                                        &args,
                                    )?;
                                    Ok(())
                                })
                            },
                        );
                        if let Err(err) = metric_result {
                            pgrx::warning!("otlet worker metric update failed: {err}");
                        }
                    }
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
        Err(err) => {
            let canceled = err.message == "canceled";
            let _: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
                pgrx::Spi::connect_mut(|client| {
                    let args = [
                        job.id.into(),
                        err.message.as_str().into(),
                        err.raw_output.as_deref().into(),
                        err.prompt_hash.as_deref().into(),
                        err.input_hash.as_deref().into(),
                        err.output_schema_hash.as_deref().into(),
                        err.raw_output_hash.as_deref().into(),
                    ];
                    client.update(
                        "SELECT otlet.fail_job($1, $2, $3, $4, $5, $6, $7)",
                        Some(1),
                        &args,
                    )?;
                    Ok(())
                })
            });
            if canceled {
                pgrx::log!("otlet worker canceled job {}", job.id);
            } else {
                pgrx::warning!("otlet worker failed job {}: {}", job.id, err.message);
            }
            false
        }
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
            "SELECT to_regprocedure('otlet.claim_job()') IS NOT NULL",
            Some(1),
            &[],
        )?;
        Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
    })
}
