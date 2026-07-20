CREATE FUNCTION otlet.register_model(
  model_name text,
  artifact_path text,
  artifact_hash text DEFAULT NULL,
  max_active_jobs int DEFAULT 1
) RETURNS otlet.models
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.models%ROWTYPE;
BEGIN
  INSERT INTO otlet.models (name, artifact_path, artifact_hash, max_active_jobs)
  VALUES (
    register_model.model_name,
    register_model.artifact_path,
    register_model.artifact_hash,
    GREATEST(1, LEAST(COALESCE(register_model.max_active_jobs, 1), 1024))
  )
  ON CONFLICT (name) DO UPDATE
    SET artifact_path = EXCLUDED.artifact_path,
        artifact_hash = EXCLUDED.artifact_hash,
        max_active_jobs = EXCLUDED.max_active_jobs
  RETURNING * INTO saved;

  DELETE FROM otlet.runtime_slots s
  WHERE s.model_name = saved.name
    AND s.artifact_path IS DISTINCT FROM saved.artifact_path;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.wake_worker() RETURNS boolean
AS 'MODULE_PATHNAME', 'otlet_wake_worker'
LANGUAGE C STRICT;

CREATE FUNCTION otlet.worker_wake_state() RETURNS jsonb
AS 'MODULE_PATHNAME', 'otlet_worker_wake_state'
LANGUAGE C STRICT;

CREATE FUNCTION otlet.worker_infer_now(
  task_name text,
  subject_id text,
  input jsonb,
  timeout_ms integer DEFAULT 10000,
  model_name text DEFAULT NULL,
  instruction text DEFAULT NULL,
  output_schema jsonb DEFAULT NULL,
  runtime_options jsonb DEFAULT NULL
) RETURNS bigint
AS 'MODULE_PATHNAME', 'otlet_worker_infer_now'
LANGUAGE C;

CREATE FUNCTION otlet.worker_infer_now_state() RETURNS jsonb
AS 'MODULE_PATHNAME', 'otlet_worker_infer_now_state'
LANGUAGE C STRICT;
