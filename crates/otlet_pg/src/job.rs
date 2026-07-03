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
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: Option<String>,
    pub(crate) model_name: String,
    pub(crate) runtime_name: String,
    pub(crate) runtime_endpoint: String,
    pub(crate) runtime_options: Value,
    pub(crate) input_shaping: Value,
    pub(crate) decision_contract: Value,
    pub(crate) max_attempt_ms: i64,
}

pub(crate) struct JobModel {
    pub(crate) name: String,
    pub(crate) artifact_path: String,
    pub(crate) artifact_hash: Option<String>,
    pub(crate) runtime_name: String,
    pub(crate) runtime_endpoint: String,
}

pub(crate) struct ModelSelectionPolicy {
    pub(crate) cheap: JobModel,
    pub(crate) strong: JobModel,
    pub(crate) accept_field_checks: Value,
    pub(crate) skip_cheap: bool,
    pub(crate) probe_due: bool,
}

impl Job {
    pub(crate) fn with_model(&self, model: &JobModel) -> Self {
        Self {
            artifact_path: model.artifact_path.clone(),
            artifact_hash: model.artifact_hash.clone(),
            model_name: model.name.clone(),
            runtime_name: model.runtime_name.clone(),
            runtime_endpoint: model.runtime_endpoint.clone(),
            ..self.clone()
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
            artifact_path: required_col!($row, String, 7),
            artifact_hash: $row.get::<String>(8)?,
            model_name: required_col!($row, String, 9),
            runtime_name: required_col!($row, String, 10),
            runtime_endpoint: required_col!($row, String, 11),
            runtime_options: required_col!($row, JsonB, 12).0,
            input_shaping: required_col!($row, JsonB, 13).0,
            decision_contract: required_col!($row, JsonB, 14).0,
            max_attempt_ms: required_col!($row, i32, 15) as i64,
        }
    };
}

pub(crate) fn claim_jobs() -> pgrx::spi::Result<Vec<Job>> {
    pgrx::Spi::connect_mut(|client| {
        let rows = client.update(
            r#"
SELECT
  j.id,
  j.task_name,
  j.subject_id,
  t.instruction,
  t.output_schema,
  j.input,
  m.artifact_path,
  m.artifact_hash,
  m.name,
  r.name,
  r.endpoint,
  t.runtime_options,
  t.input_shaping,
  t.decision_contract,
  p.max_attempt_ms
FROM otlet.claim_jobs() j
JOIN otlet.tasks t ON t.name = j.task_name
JOIN otlet.models m ON m.name = t.model_name
JOIN otlet.runtimes r ON r.name = m.runtime_name
CROSS JOIN otlet.production_policy p
"#,
            None,
            &[],
        )?;

        rows.into_iter().map(|row| Ok(job_from_row!(row))).collect()
    })
}

pub(crate) fn insert_infer_now_job(
    task_name: &str,
    subject_id: &str,
    input: &Value,
) -> pgrx::spi::Result<Option<Job>> {
    pgrx::Spi::connect_mut(|client| {
        let args = [
            task_name.into(),
            subject_id.into(),
            JsonB(input.clone()).into(),
        ];
        let rows = client.update(
            r#"
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
  VALUES ($1, $2, $3, 'running', 1, now() + (SELECT job_lease_interval FROM otlet.production_policy), now(), NULL)
  ON CONFLICT (task_name, subject_id)
  WHERE status IN ('queued', 'running', 'cancel_requested')
  DO NOTHING
  RETURNING *
)
SELECT
  j.id,
  j.task_name,
  j.subject_id,
  t.instruction,
  t.output_schema,
  j.input,
  m.artifact_path,
  m.artifact_hash,
  m.name,
  r.name,
  r.endpoint,
  t.runtime_options,
  t.input_shaping,
  t.decision_contract,
  p.max_attempt_ms
FROM inserted j
JOIN otlet.tasks t ON t.name = j.task_name
JOIN otlet.models m ON m.name = t.model_name
JOIN otlet.runtimes r ON r.name = m.runtime_name
CROSS JOIN otlet.production_policy p
"#,
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
            r#"
SELECT
  cheap.name,
  cheap.artifact_path,
  cheap.artifact_hash,
  cheap.runtime_name,
  cheap_runtime.endpoint,
  strong.name,
  strong.artifact_path,
  strong.artifact_hash,
  strong.runtime_name,
  strong_runtime.endpoint,
  p.accept_field_checks,
  COALESCE(recent.skip_cheap, false),
  COALESCE(recent.probe_due, false)
FROM otlet.model_selection_policies p
JOIN otlet.models cheap ON cheap.name = p.cheap_model_name
JOIN otlet.runtimes cheap_runtime ON cheap_runtime.name = cheap.runtime_name
JOIN otlet.models strong ON strong.name = p.strong_model_name
JOIN otlet.runtimes strong_runtime ON strong_runtime.name = strong.runtime_name
LEFT JOIN LATERAL otlet.model_selection_recent_acceptance(p.task_name) recent ON true
WHERE p.task_name = $1
"#,
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
                runtime_name: required_col!(row, String, 4),
                runtime_endpoint: required_col!(row, String, 5),
            },
            strong: JobModel {
                name: required_col!(row, String, 6),
                artifact_path: required_col!(row, String, 7),
                artifact_hash: row.get::<String>(8)?,
                runtime_name: required_col!(row, String, 9),
                runtime_endpoint: required_col!(row, String, 10),
            },
            accept_field_checks: required_col!(row, JsonB, 11).0,
            skip_cheap: required_col!(row, bool, 12),
            probe_due: required_col!(row, bool, 13),
        }))
    })
}
