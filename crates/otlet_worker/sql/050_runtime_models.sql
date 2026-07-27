CREATE FUNCTION otlet.register_model(
  model_name text,
  artifact_path text,
  artifact_hash text,
  artifact_identity jsonb,
  max_active_jobs int DEFAULT 1
) RETURNS otlet.models
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.models%ROWTYPE;
BEGIN
  INSERT INTO otlet.models (name, artifact_path, artifact_hash, artifact_identity, max_active_jobs)
  VALUES (
    register_model.model_name,
    register_model.artifact_path,
    lower(register_model.artifact_hash),
    register_model.artifact_identity,
    GREATEST(1, LEAST(COALESCE(register_model.max_active_jobs, 1), 1024))
  )
  ON CONFLICT (name) DO UPDATE
  SET artifact_path = EXCLUDED.artifact_path,
      artifact_hash = EXCLUDED.artifact_hash,
      artifact_identity = EXCLUDED.artifact_identity,
      max_active_jobs = EXCLUDED.max_active_jobs
  RETURNING * INTO saved;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.wake_worker() RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT false
$$;

CREATE FUNCTION otlet.worker_wake_state() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'state', 'portable_external_worker',
    'delivery', 'database_polling'
  )
$$;

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
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet infer-now is unavailable in the portable SQL installation';
END;
$$;

CREATE FUNCTION otlet.worker_infer_now_state() RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'state', 'unavailable',
    'reason', 'portable_sql_installation_uses_queued_rpc_claims'
  )
$$;
