use pgrx::JsonB;
use serde_json::Value;

#[derive(Clone)]
pub(crate) struct Job {
    pub(crate) id: i64,
    pub(crate) task_name: String,
    pub(crate) subject_id: String,
    pub(crate) instruction: String,
    pub(crate) output_schema: Value,
    pub(crate) input: Value,
    pub(crate) input_content_hash: String,
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: Option<String>,
    pub(crate) model_name: String,
    pub(crate) runtime_options: Value,
    pub(crate) input_shaping: Value,
    pub(crate) decision_contract: Value,
    pub(crate) max_attempt_ms: i64,
}

#[derive(Clone)]
pub(crate) struct JobModel {
    pub(crate) name: String,
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: Option<String>,
}

#[derive(Clone)]
pub(crate) struct ModelSelectionPolicy {
    pub(crate) cheap: JobModel,
    pub(crate) strong: JobModel,
    pub(crate) accept_field_checks: Value,
}

#[derive(Clone, Copy)]
pub(crate) struct JobModelRef<'a> {
    pub(crate) name: &'a str,
    pub(crate) artifact_path: &'a str,
    pub(crate) artifact_hash: Option<&'a str>,
}

impl Job {
    pub(crate) fn model_ref(&self) -> JobModelRef<'_> {
        JobModelRef {
            name: self.model_name.as_str(),
            artifact_path: self.artifact_path.as_str(),
            artifact_hash: self.artifact_hash.as_deref(),
        }
    }
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
            artifact_hash: $row.get::<String>(9)?,
            model_name: required_col!($row, String, 10),
            runtime_options: required_col!($row, JsonB, 11).0,
            input_shaping: required_col!($row, JsonB, 12).0,
            decision_contract: required_col!($row, JsonB, 13).0,
            max_attempt_ms: i64::from(required_col!($row, i32, 14)),
        }
    };
}

pub(crate) fn claim_jobs() -> pgrx::spi::Result<Vec<Job>> {
    pgrx::Spi::connect_mut(|client| {
        let rows = client.update(
            r"
WITH claimed AS (
  SELECT
    j.id,
    j.task_name,
    j.subject_id,
    j.input,
    t.instruction,
    t.output_schema,
    t.input_shaping,
    t.decision_contract,
    t.runtime_options,
    m.artifact_path,
    m.artifact_hash,
    m.name AS model_name,
    p.default_runtime_options,
    p.max_attempt_ms,
    otlet.semantic_shaped_input(j.input, t.input_shaping) AS shaped_input
  FROM otlet.claim_jobs() j
  JOIN otlet.tasks t ON t.name = j.task_name
  JOIN otlet.models m ON m.name = t.model_name
  CROSS JOIN otlet.production_policy p
)
SELECT
  id,
  task_name,
  subject_id,
  instruction,
  output_schema,
  shaped_input,
  md5(otlet.semantic_canonical_jsonb(shaped_input)::text),
  artifact_path,
  artifact_hash,
  model_name,
  default_runtime_options || runtime_options,
  input_shaping,
  decision_contract,
  otlet.effective_task_max_attempt_ms(default_runtime_options || runtime_options, max_attempt_ms)
FROM claimed
	",
            None,
            &[],
        )?;

        let mut jobs = Vec::with_capacity(rows.len());
        for row in rows {
            jobs.push(job_from_row!(row));
        }
        Ok(jobs)
    })
}

pub(crate) fn insert_infer_now_job(
    task_name: &str,
    subject_id: &str,
    input_json: &str,
) -> pgrx::spi::Result<Option<Job>> {
    pgrx::Spi::connect_mut(|client| {
        let args = [task_name.into(), subject_id.into(), input_json.into()];
        let rows = client.update(
            r"
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    leased_until,
    started_at,
    finished_at
  )
  VALUES ($1, $2, $3::jsonb, 'running', 1, now() + (SELECT job_lease_interval FROM otlet.production_policy), now(), NULL)
  ON CONFLICT (task_name, subject_id)
  WHERE status IN ('queued', 'running', 'cancel_requested')
  DO NOTHING
  RETURNING *
)
SELECT
  id,
  task_name,
  subject_id,
  instruction,
  output_schema,
  shaped_input,
  md5(otlet.semantic_canonical_jsonb(shaped_input)::text),
  artifact_path,
  artifact_hash,
  model_name,
  default_runtime_options || runtime_options,
  input_shaping,
  decision_contract,
  otlet.effective_task_max_attempt_ms(default_runtime_options || runtime_options, max_attempt_ms)
FROM (
  SELECT
    j.id,
    j.task_name,
    j.subject_id,
    t.instruction,
    t.output_schema,
    t.input_shaping,
    t.decision_contract,
    t.runtime_options,
    m.artifact_path,
    m.artifact_hash,
    m.name AS model_name,
    p.default_runtime_options,
    p.max_attempt_ms,
    otlet.semantic_shaped_input(j.input, t.input_shaping) AS shaped_input
  FROM inserted j
  JOIN otlet.tasks t ON t.name = j.task_name
  JOIN otlet.models m ON m.name = t.model_name
  CROSS JOIN otlet.production_policy p
) shaped
	",
            Some(1),
            &args,
        )?;

        if rows.is_empty() {
            return Ok(None);
        }

        let row = rows.first();
        Ok(Some(job_from_row!(row)))
    })
}

pub(crate) fn model_selection_policy(
    task_name: &str,
) -> pgrx::spi::Result<Option<ModelSelectionPolicy>> {
    pgrx::Spi::connect(|client| {
        let args = [task_name.into()];
        let rows = client.select(
            r"
SELECT
  cheap.name,
  cheap.artifact_path,
  cheap.artifact_hash,
  strong.name,
  strong.artifact_path,
  strong.artifact_hash,
  p.accept_field_checks
FROM otlet.model_selection_policies p
JOIN otlet.models cheap ON cheap.name = p.cheap_model_name
JOIN otlet.models strong ON strong.name = p.strong_model_name
WHERE p.task_name = $1
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
                artifact_hash: row.get::<String>(3)?,
            },
            strong: JobModel {
                name: required_col!(row, String, 4),
                artifact_path: required_col!(row, String, 5),
                artifact_hash: row.get::<String>(6)?,
            },
            accept_field_checks: required_col!(row, JsonB, 7).0,
        }))
    })
}
