use pgrx::JsonB;
use serde_json::Value;

pub(crate) struct Job {
    pub(crate) id: i64,
    pub(crate) task_name: String,
    pub(crate) workload_revision_hash: String,
    pub(crate) execution_mode: String,
    pub(crate) subject_id: String,
    pub(crate) instruction: String,
    pub(crate) output_schema: Value,
    pub(crate) input: Value,
    pub(crate) input_content_hash: String,
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: String,
    pub(crate) artifact_identity: Value,
    pub(crate) model_name: String,
    pub(crate) selection_role: String,
    pub(crate) runtime_options: Value,
    pub(crate) input_shaping: Value,
    pub(crate) decision_contract: Value,
    pub(crate) max_attempt_ms: i64,
    pub(crate) claim_token: String,
}

pub(crate) struct JobModel {
    pub(crate) name: String,
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: String,
    pub(crate) artifact_identity: Value,
}

pub(crate) enum InferNowJobAdmission {
    Inserted(Job),
    Active,
    Capacity,
    Conflict,
}

pub(crate) struct ModelSelectionPolicy {
    pub(crate) cheap: JobModel,
    pub(crate) strong: JobModel,
    pub(crate) accept_field_checks: Value,
}

#[derive(Clone, Copy)]
pub(crate) struct JobModelRef<'a> {
    pub(crate) name: &'a str,
    pub(crate) artifact_path: &'a str,
    pub(crate) artifact_hash: &'a str,
    pub(crate) artifact_identity: &'a Value,
}

macro_rules! required_col {
    ($row:expr, $ty:ty, $idx:expr) => {
        $row.get::<$ty>($idx)?
            // PGRX SpiError has no custom null-column variant; fail the claim instead of panicking
            .ok_or(pgrx::spi::SpiError::InvalidPosition)?
    };
}

macro_rules! job_from_row {
    ($row:expr) => {
        Job {
            id: required_col!($row, i64, 1),
            task_name: required_col!($row, String, 2),
            subject_id: required_col!($row, String, 3),
            instruction: required_col!($row, String, 4),
            output_schema: required_col!($row, JsonB, 5).0,
            input: required_col!($row, JsonB, 6).0,
            input_content_hash: required_col!($row, String, 7),
            artifact_path: required_col!($row, String, 8),
            artifact_hash: required_col!($row, String, 9),
            artifact_identity: required_col!($row, JsonB, 10).0,
            model_name: required_col!($row, String, 11),
            selection_role: required_col!($row, String, 12),
            runtime_options: required_col!($row, JsonB, 13).0,
            input_shaping: required_col!($row, JsonB, 14).0,
            decision_contract: required_col!($row, JsonB, 15).0,
            max_attempt_ms: i64::from(required_col!($row, i32, 16)),
            claim_token: required_col!($row, String, 17),
            workload_revision_hash: required_col!($row, String, 18),
            execution_mode: required_col!($row, String, 19),
        }
    };
}

pub(crate) fn claim_jobs() -> pgrx::spi::Result<Vec<Job>> {
    pgrx::Spi::connect_mut(|client| {
        let claimed_rows = client.update("SELECT id FROM otlet.claim_jobs()", None, &[])?;
        let mut claimed_ids = Vec::with_capacity(claimed_rows.len());
        for row in claimed_rows {
            claimed_ids.push(required_col!(row, i64, 1));
        }
        if claimed_ids.is_empty() {
            return Ok(Vec::new());
        }

        let rows = client.select(
            r"
WITH claimed AS (
  SELECT id, claim_order
  FROM unnest($1::bigint[]) WITH ORDINALITY AS claimed(id, claim_order)
)
SELECT
  j.id,
  j.task_name,
  j.subject_id,
  definition #>> '{task,instruction}',
  definition #> '{task,output_schema}',
  shaped_input,
  otlet.semantic_content_hash(shaped_input),
  selected_model ->> 'artifact_path',
  selected_model ->> 'artifact_hash',
  selected_model -> 'artifact_identity',
  selected_model ->> 'name',
  CASE WHEN j.routed_model_name IS NOT NULL THEN 'strong' ELSE 'direct' END,
  definition #> '{runtime,effective_options}',
  definition #> '{task,input_shaping}',
  definition #> '{task,decision_contract}',
  (definition #>> '{runtime,effective_max_attempt_ms}')::integer,
  j.claim_token,
  j.workload_revision_hash,
  j.execution_mode
FROM claimed
JOIN otlet.jobs j ON j.id = claimed.id
JOIN otlet.workload_revisions revision
  ON revision.task_name = j.task_name
 AND revision.workload_revision_hash = j.workload_revision_hash
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN j.routed_model_name IS NOT NULL THEN definition #> '{models,strong}'
      ELSE definition #> '{models,direct}'
    END AS selected_model,
    CASE j.execution_mode
      WHEN 'evaluation' THEN j.input
      ELSE otlet.semantic_shaped_input(
        j.input,
        definition #> '{task,input_shaping}'
      )
    END AS shaped_input
) selected
ORDER BY claimed.claim_order
",
            None,
            &[claimed_ids.as_slice().into()],
        )?;

        let mut jobs = Vec::with_capacity(rows.len());
        for row in rows {
            jobs.push(job_from_row!(row));
        }
        Ok(jobs)
    })
}

pub(crate) fn replay_watch_reconciliation() -> pgrx::spi::Result<()> {
    pgrx::Spi::connect_mut(|client| {
        client.update(
            "SELECT otlet.replay_watch_reconciliation(false)",
            Some(1),
            &[],
        )?;
        Ok(())
    })
}

pub(crate) fn insert_infer_now_job(
    task_name: &str,
    subject_id: &str,
    expected_workload_revision_hash: Option<&str>,
    input_json: &str,
) -> pgrx::spi::Result<InferNowJobAdmission> {
    pgrx::Spi::connect_mut(|client| {
        let active_rows = client.select(
            "SELECT otlet.ensure_active_workload_revision($1)",
            Some(1),
            &[task_name.into()],
        )?;
        let active_revision_hash = active_rows
            .first()
            .get::<String>(1)?
            .ok_or(pgrx::spi::SpiError::InvalidPosition)?;
        if expected_workload_revision_hash.is_some_and(|expected| expected != active_revision_hash)
        {
            return Ok(InferNowJobAdmission::Active);
        }
        let args = [
            task_name.into(),
            subject_id.into(),
            input_json.into(),
            active_revision_hash.as_str().into(),
        ];
        client.select(
            "SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission'))",
            Some(1),
            &[],
        )?;
        let active_rows = client.select(
            r"
SELECT
  count(j.id)::bigint,
  COALESCE(bool_or(j.id IS NOT NULL AND j.input IS DISTINCT FROM $3::jsonb), false),
  capacity.available_active_job_slots
FROM otlet.workload_revisions revision
LEFT JOIN otlet.model_claim_capacity capacity
  ON capacity.model_name = revision.definition #>> '{models,direct,name}'
LEFT JOIN otlet.jobs j
  ON j.task_name = revision.task_name
 AND j.workload_revision_hash = revision.workload_revision_hash
 AND j.subject_id = $2
 AND j.execution_mode = 'production'
 AND j.status IN ('queued', 'running', 'cancel_requested')
WHERE revision.task_name = $1
  AND revision.workload_revision_hash = $4
GROUP BY capacity.available_active_job_slots
	",
            Some(1),
            &args,
        )?;
        let active_row = active_rows.first();
        if active_row.get::<bool>(2)?.unwrap_or(false) {
            return Ok(InferNowJobAdmission::Conflict);
        }
        if active_row.get::<i64>(1)?.unwrap_or(0) > 0 {
            return Ok(InferNowJobAdmission::Active);
        }
        if active_row.get::<i64>(3)?.unwrap_or(0) <= 0 {
            return Ok(InferNowJobAdmission::Capacity);
        }
        let rows = client.update(
            r"
WITH revision AS MATERIALIZED (
  SELECT r.workload_revision_hash, r.definition
  FROM otlet.workload_revisions r
  WHERE r.task_name = $1
    AND r.workload_revision_hash = $4
),
inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    status,
    attempts,
    leased_until,
    claim_token,
    started_at,
    finished_at
  )
  SELECT
    $1,
    revision.workload_revision_hash,
    $2,
    $3::jsonb,
    'running',
    1,
    now() + make_interval(
      secs => (revision.definition #>> '{runtime,lease_ms}')::double precision / 1000.0
    ),
    gen_random_uuid()::text,
    now(),
    NULL
  FROM revision
  RETURNING *
)
SELECT
  id,
  task_name,
  subject_id,
  definition #>> '{task,instruction}',
  definition #> '{task,output_schema}',
  shaped_input,
  otlet.semantic_content_hash(shaped_input),
  selected_model ->> 'artifact_path',
  selected_model ->> 'artifact_hash',
  selected_model -> 'artifact_identity',
  selected_model ->> 'name',
  selection_role,
  definition #> '{runtime,effective_options}',
  definition #> '{task,input_shaping}',
  definition #> '{task,decision_contract}',
  (definition #>> '{runtime,effective_max_attempt_ms}')::integer,
  claim_token,
  workload_revision_hash,
  execution_mode
FROM (
  SELECT
    j.id,
    j.task_name,
    j.subject_id,
    j.workload_revision_hash,
    j.execution_mode,
    revision.definition,
    revision.definition #> '{models,direct}' AS selected_model,
    'direct'::text AS selection_role,
    j.claim_token,
    otlet.semantic_shaped_input(
      j.input,
      revision.definition #> '{task,input_shaping}'
    ) AS shaped_input
  FROM inserted j
  JOIN revision
    ON revision.workload_revision_hash = j.workload_revision_hash
) shaped
	",
            Some(1),
            &args,
        )?;

        if rows.is_empty() {
            return Ok(InferNowJobAdmission::Active);
        }

        let row = rows.first();
        Ok(InferNowJobAdmission::Inserted(job_from_row!(row)))
    })
}

pub(crate) fn model_selection_policy(
    workload_revision_hash: &str,
) -> pgrx::spi::Result<Option<ModelSelectionPolicy>> {
    pgrx::Spi::connect(|client| {
        let args = [workload_revision_hash.into()];
        let rows = client.select(
            r"
SELECT
  revision.definition #>> '{models,cheap,name}',
  revision.definition #>> '{models,cheap,artifact_path}',
  revision.definition #>> '{models,cheap,artifact_hash}',
  revision.definition #> '{models,cheap,artifact_identity}',
  revision.definition #>> '{models,strong,name}',
  revision.definition #>> '{models,strong,artifact_path}',
  revision.definition #>> '{models,strong,artifact_hash}',
  revision.definition #> '{models,strong,artifact_identity}',
  revision.definition #> '{selection,accept_field_checks}'
FROM otlet.workload_revisions revision
WHERE revision.workload_revision_hash = $1
  AND jsonb_typeof(revision.definition -> 'selection') = 'object'
		",
            Some(1),
            &args,
        )?;

        if rows.is_empty() {
            return Ok(None);
        }

        let row = rows.first();
        Ok(Some(ModelSelectionPolicy {
            cheap: JobModel {
                name: required_col!(row, String, 1),
                artifact_path: required_col!(row, String, 2),
                artifact_hash: required_col!(row, String, 3),
                artifact_identity: required_col!(row, JsonB, 4).0,
            },
            strong: JobModel {
                name: required_col!(row, String, 5),
                artifact_path: required_col!(row, String, 6),
                artifact_hash: required_col!(row, String, 7),
                artifact_identity: required_col!(row, JsonB, 8).0,
            },
            accept_field_checks: required_col!(row, JsonB, 9).0,
        }))
    })
}
