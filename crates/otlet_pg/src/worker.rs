use crate::job::{
    Job, ModelSelectionPolicy, claim_jobs, insert_infer_now_job, model_selection_policy,
};
use crate::model::{
    ModelError, ModelMetrics, ModelPreload, ModelRun, preload_model, run_job, run_job_with_model,
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
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGTERM);
    let database = match configured_worker_database() {
        Ok(database) => database,
        Err(error) => pgrx::error!("{error}"),
    };
    pgrx::log!("otlet worker connecting database={database}");
    BackgroundWorker::connect_worker_to_spi(Some(&database), None);

    crate::wake::register_worker_latch();
    pgrx::log!("otlet worker started database={database}");

    let recovery_interval = Duration::from_millis(crate::wake::MISSED_WAKE_RECOVERY_MS);
    let mut last_expired_sweep = Instant::now()
        .checked_sub(EXPIRED_JOB_SWEEP_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut last_schema_probe = Instant::now()
        .checked_sub(SCHEMA_READY_PROBE_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut schema_probe_due = true;
    let mut startup_recorded = false;
    let mut startup_probe_due = true;
    let mut last_startup_probe = Instant::now()
        .checked_sub(SCHEMA_READY_PROBE_INTERVAL)
        .unwrap_or_else(Instant::now);
    let mut preload_checked = false;

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

        if !startup_recorded
            && (startup_probe_due || last_startup_probe.elapsed() >= SCHEMA_READY_PROBE_INTERVAL)
        {
            startup_probe_due = false;
            last_startup_probe = Instant::now();
            let startup_result = BackgroundWorker::transaction(startup_runtime_options)
                .map_err(|error| error.to_string())
                .and_then(|options| {
                    crate::runtime::parse_runtime_options(&options)
                        .map(|parsed| parsed.max_worker_rss_bytes)
                });
            match startup_result {
                Ok(max_worker_rss_bytes) => {
                    match BackgroundWorker::transaction(|| {
                        record_worker_started(max_worker_rss_bytes)
                    }) {
                        Ok(()) => startup_recorded = true,
                        Err(err) => pgrx::warning!("otlet worker startup status failed: {err}"),
                    }
                }
                Err(error) => {
                    record_worker_startup_failure(&error);
                    pgrx::warning!("otlet worker startup preflight failed: {error}");
                }
            }
        }
        if !startup_recorded {
            continue;
        }

        if !preload_checked {
            preload_checked = true;
            match BackgroundWorker::transaction(startup_preload_config) {
                Ok(Some(config)) => run_startup_preload(config),
                Ok(None) => {}
                Err(err) => pgrx::warning!("otlet model preload lookup failed: {err}"),
            }
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
    pgrx::log!("otlet worker stopped database={database}");
}

fn configured_worker_database() -> Result<String, String> {
    match std::env::var("OTLET_DATABASE") {
        Ok(database) => validate_worker_database(database),
        Err(std::env::VarError::NotPresent) => Ok("postgres".to_owned()),
        Err(std::env::VarError::NotUnicode(_)) => {
            Err("OTLET_DATABASE must be valid UTF-8".to_owned())
        }
    }
}

fn validate_worker_database(database: String) -> Result<String, String> {
    if database.is_empty() {
        return Err("OTLET_DATABASE must name a database".to_owned());
    }
    if database.len() > 63 {
        return Err("OTLET_DATABASE must be at most 63 bytes".to_owned());
    }
    if !database
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(
            "OTLET_DATABASE may contain only ASCII letters, digits, underscore, dot, and hyphen"
                .to_owned(),
        );
    }
    Ok(database)
}

fn startup_runtime_options() -> pgrx::spi::Result<Value> {
    pgrx::Spi::get_one::<JsonB>(
        "SELECT default_runtime_options FROM otlet.production_policy WHERE name = 'default'",
    )?
    .map(|options| options.0)
    .ok_or(pgrx::spi::SpiError::InvalidPosition)
}

fn record_worker_started(max_worker_rss_bytes: u64) -> pgrx::spi::Result<()> {
    pgrx::Spi::connect_mut(|client| {
        let max_worker_rss_bytes = i64::try_from(max_worker_rss_bytes).unwrap_or(i64::MAX);
        client.update(
            "SELECT otlet.record_worker_event(\
               'worker_started', NULL, 'linked_inproc', 'otlet worker connected', \
               jsonb_build_object(\
                 'database', current_database(), \
                 'role', current_user, \
                 'default_max_worker_rss_bytes', $1))",
            Some(1),
            &[max_worker_rss_bytes.into()],
        )?;
        Ok(())
    })
}

fn record_worker_startup_failure(error: &str) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            client.update(
                "SELECT otlet.record_worker_event(\
                   'worker_startup_failed', NULL, 'linked_inproc', 'otlet worker startup preflight failed', \
                   jsonb_build_object('database', current_database(), 'role', current_user, 'error', $1))",
                Some(1),
                &[error.into()],
            )?;
            Ok(())
        })
    });
    if let Err(status_error) = result {
        pgrx::warning!("otlet worker startup failure status failed: {status_error}");
    }
}

struct StartupPreload {
    model_name: String,
    model: Option<crate::job::JobModel>,
    runtime_options: Value,
}

fn startup_preload_config() -> pgrx::spi::Result<Option<StartupPreload>> {
    pgrx::Spi::connect(|client| {
        let rows = client.select(
            "SELECT p.preload_model_name, m.artifact_path, m.artifact_hash, m.artifact_identity, p.default_runtime_options FROM otlet.production_policy p LEFT JOIN otlet.models m ON m.name = p.preload_model_name WHERE p.name = 'default' AND p.preload_model_name IS NOT NULL LIMIT 1",
            Some(1),
            &[],
        )?;
        if rows.is_empty() {
            return Ok(None);
        }
        let row = rows.first();
        let model_name = row
            .get::<String>(1)?
            .ok_or(pgrx::spi::SpiError::InvalidPosition)?;
        let artifact_path = row.get::<String>(2)?;
        let artifact_hash = row.get::<String>(3)?;
        let artifact_identity = row.get::<JsonB>(4)?.map(|value| value.0);
        Ok(Some(StartupPreload {
            model: artifact_path.zip(artifact_hash).zip(artifact_identity).map(
                |((artifact_path, artifact_hash), artifact_identity)| crate::job::JobModel {
                    name: model_name.clone(),
                    artifact_path,
                    artifact_hash,
                    artifact_identity,
                },
            ),
            model_name,
            runtime_options: row
                .get::<JsonB>(5)?
                .ok_or(pgrx::spi::SpiError::InvalidPosition)?
                .0,
        }))
    })
}

fn run_startup_preload(config: StartupPreload) {
    let result = config
        .model
        .as_ref()
        .ok_or_else(|| ModelError::new("preload model is not registered"))
        .and_then(|model| preload_model(model, &config.runtime_options));
    match result {
        Ok(preload) => record_model_preload_success(&config.model_name, &preload),
        Err(err) => record_model_preload_failure(&config.model_name, &err),
    }
}

fn record_model_preload_success(model_name: &str, preload: &ModelPreload) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [
                model_name.into(),
                preload.artifact_path.as_str().into(),
                preload.load_ms.into(),
                preload.ctx_ms.into(),
                preload.model_memory_bytes.into(),
                preload.model_parameters.into(),
                preload.context_window_tokens.into(),
                preload.model_device_policy.into(),
                preload.memory_accounting_policy.into(),
                preload.worker_process_rss_bytes.into(),
                preload.worker_process_virtual_bytes.into(),
                preload.worker_memory_sample_policy.into(),
                preload.model_fingerprint_hash.as_str().into(),
                JsonB(preload.memory_trace.clone()).into(),
            ];
            client.update(
                "SELECT otlet.touch_runtime_slot($1, 'ready', 0, NULL)",
                Some(1),
                &args[..1],
            )?;
            client.update(
                "UPDATE otlet.runtime_slots SET artifact_path=$2, status='ready', active_jobs=0, loaded_at=now(), last_used_at=now(), last_error=NULL, load_ms=$3, ctx_ms=$4, model_memory_bytes=$5, model_parameters=$6, context_window_tokens=$7, model_device_policy=$8, resident_memory_tracked_bytes=GREATEST($5,0), memory_accounting_policy=$9, worker_process_rss_bytes=$10, worker_process_virtual_bytes=$11, worker_memory_sample_policy=$12 WHERE model_name=$1",
                Some(1),
                &args[..12],
            )?;
            client.update(
                "SELECT otlet.record_worker_event('model_preload_succeeded', NULL, 'linked_inproc', 'model preload succeeded', jsonb_build_object('model_name',$1,'artifact_path',$2,'load_ms',$3,'ctx_ms',$4,'model_memory_bytes',$5,'worker_process_rss_bytes',$10,'model_fingerprint_hash',$13,'memory',$14))",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet model preload status failed: {err}");
    }
}

fn record_model_preload_failure(model_name: &str, error: &ModelError) {
    let result: pgrx::spi::Result<()> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let trace = error
                .trace_summary
                .clone()
                .unwrap_or_else(|| serde_json::json!({}));
            let args = [
                model_name.into(),
                error.message.as_str().into(),
                JsonB(trace).into(),
            ];
            client.update(
                "SELECT otlet.touch_runtime_slot(m.name, 'error', 0, $2) FROM otlet.models m WHERE m.name=$1",
                Some(1),
                &args[..2],
            )?;
            client.update(
                "SELECT otlet.record_worker_event('model_preload_failed', NULL, 'linked_inproc', 'model preload failed', jsonb_build_object('model_name',$1,'error',$2,'trace',$3))",
                Some(1),
                &args,
            )?;
            Ok(())
        })
    });
    if let Err(err) = result {
        pgrx::warning!("otlet model preload failure status failed: {err}");
    }
    pgrx::warning!(
        "otlet model preload failed for {}: {}",
        model_name,
        error.message
    );
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
                         COALESCE((SELECT t->'runtime_options' FROM src), '{}'::jsonb), \
                         COALESCE((SELECT t->'input_shaping' FROM src), '{\"source_fields\":[]}'::jsonb) \
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
            "SELECT to_regprocedure('otlet.claim_jobs(text,integer)') IS NOT NULL AND to_regprocedure('otlet.materialize_completed_semantic_job(bigint)') IS NOT NULL AND to_regprocedure('otlet.complete_and_materialize_job(bigint,jsonb,text,jsonb,text,text,text,text,jsonb,text,text,text,text)') IS NOT NULL",
            Some(1),
            &[],
        )?;
        Ok(rows.first().get::<bool>(1)?.unwrap_or(false))
    })
}

include!("worker_batch.rs");
include!("worker_selection.rs");
include!("worker_completion.rs");

#[cfg(test)]
mod startup_tests {
    use super::validate_worker_database;

    #[test]
    fn worker_database_rejects_invalid_names() {
        assert_eq!(
            validate_worker_database("otlet_data".to_owned()).unwrap(),
            "otlet_data"
        );
        assert!(validate_worker_database(String::new()).is_err());
        assert!(validate_worker_database("x".repeat(64)).is_err());
        assert!(validate_worker_database("otlet\ndata".to_owned()).is_err());
        assert!(validate_worker_database("otlet/data".to_owned()).is_err());
    }
}
