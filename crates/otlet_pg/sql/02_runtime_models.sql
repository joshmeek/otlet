CREATE FUNCTION otlet.register_runtime(
  runtime_name text,
  endpoint text DEFAULT 'linked'
) RETURNS otlet.runtimes
LANGUAGE sql
AS $$
  INSERT INTO otlet.runtimes (name, endpoint, status, last_error, checked_at)
  VALUES ($1, $2, 'unknown', NULL, NULL)
  ON CONFLICT (name) DO UPDATE
    SET endpoint = EXCLUDED.endpoint,
        status = 'unknown',
        last_error = NULL,
        checked_at = NULL
  RETURNING *;
$$;

CREATE FUNCTION otlet.register_model(
  model_name text,
  artifact_path text,
  runtime_name text DEFAULT 'linked_inproc',
  artifact_hash text DEFAULT NULL,
  max_active_jobs int DEFAULT 1
) RETURNS otlet.models
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.models%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM otlet.runtimes WHERE name = register_model.runtime_name) THEN
    RAISE EXCEPTION 'otlet runtime % does not exist', register_model.runtime_name;
  END IF;

  INSERT INTO otlet.models (name, artifact_path, artifact_hash, runtime_name, max_active_jobs)
  VALUES (
    register_model.model_name,
    register_model.artifact_path,
    register_model.artifact_hash,
    register_model.runtime_name,
    GREATEST(1, LEAST(COALESCE(register_model.max_active_jobs, 1), 1024))
  )
  ON CONFLICT (name) DO UPDATE
    SET artifact_path = EXCLUDED.artifact_path,
        artifact_hash = EXCLUDED.artifact_hash,
        runtime_name = EXCLUDED.runtime_name,
        max_active_jobs = EXCLUDED.max_active_jobs
  RETURNING * INTO saved;

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
