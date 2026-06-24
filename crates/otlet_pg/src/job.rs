use pgrx::JsonB;
use serde_json::Value;

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
        }
    };
}

pub(crate) fn claim_job() -> pgrx::spi::Result<Option<Job>> {
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
  t.runtime_options
FROM otlet.claim_job() j
JOIN otlet.tasks t ON t.name = j.task_name
JOIN otlet.models m ON m.name = t.model_name
JOIN otlet.runtimes r ON r.name = m.runtime_name
"#,
            Some(1),
            &[],
        )?;

        if rows.is_empty() {
            return Ok(None);
        }

        let row = rows.first();
        Ok(Some(job_from_row!(row)))
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
  VALUES ($1, $2, $3, 'running', 1, now() + interval '5 minutes', now(), NULL)
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
  t.runtime_options
FROM inserted j
JOIN otlet.tasks t ON t.name = j.task_name
JOIN otlet.models m ON m.name = t.model_name
JOIN otlet.runtimes r ON r.name = m.runtime_name
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
