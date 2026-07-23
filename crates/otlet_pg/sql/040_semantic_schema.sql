CREATE TABLE otlet.semantic_materializations (
  id bigserial PRIMARY KEY,
  record_id bigint NOT NULL UNIQUE REFERENCES otlet.records(id),
  record_type text NOT NULL,
  source_table text,
  subject_id text,
  source_dependencies jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(source_dependencies) = 'array'),
  task_name text NOT NULL,
  model_name text NOT NULL,
  body jsonb NOT NULL,
  stale boolean NOT NULL DEFAULT false,
  source_hash text,
  content_hash text,
  contract_hash text,
  stale_reason text CHECK (stale_reason IN (
    'source_update',
    'source_delete',
    'candidate_removed',
    'candidate_changed',
    'contract_changed',
    'schema_drift',
    'manual',
    'content_revalidation_pending'
  )),
  freshness_basis text CHECK (freshness_basis IN (
    'content_hash_match',
    'mvcc_match',
    'revalidated_after_benign_update'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX semantic_materializations_lookup_idx
ON otlet.semantic_materializations (task_name, record_type, stale, subject_id);

CREATE INDEX semantic_materializations_subject_latest_idx
ON otlet.semantic_materializations (task_name, record_type, subject_id, updated_at DESC, id DESC);

CREATE INDEX semantic_materializations_source_delete_idx
ON otlet.semantic_materializations (updated_at, id)
WHERE stale AND stale_reason = 'source_delete';

CREATE INDEX semantic_materializations_source_idx
ON otlet.semantic_materializations (source_table, subject_id, task_name, record_type, stale);

CREATE INDEX semantic_materializations_dependencies_idx
ON otlet.semantic_materializations USING gin (source_dependencies jsonb_path_ops);

CREATE TABLE otlet.semantic_indexes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name),
  source_table text NOT NULL,
  subject_column text NOT NULL,
  input_columns text[],
  record_type text NOT NULL,
  model_name text NOT NULL REFERENCES otlet.models(name),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_refresh_at timestamptz,
  last_lookup_at timestamptz
);

CREATE TABLE otlet.semantic_join_indexes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name),
  candidate_query text NOT NULL,
  record_type text NOT NULL,
  model_name text NOT NULL REFERENCES otlet.models(name),
  max_candidate_rows integer NOT NULL DEFAULT 1000 CHECK (max_candidate_rows BETWEEN 1 AND 100000),
  candidate_plan jsonb NOT NULL CHECK (jsonb_typeof(candidate_plan) = 'array'),
  candidate_plan_cost numeric NOT NULL CHECK (candidate_plan_cost >= 0),
  candidate_preflight_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_refresh_at timestamptz,
  last_lookup_at timestamptz,
  last_materialized_at timestamptz
);

CREATE TABLE otlet.watches (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  kind text NOT NULL CHECK (kind IN ('row', 'pair')),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  semantic_index_name text UNIQUE REFERENCES otlet.semantic_indexes(name) ON DELETE SET NULL,
  semantic_join_index_name text UNIQUE REFERENCES otlet.semantic_join_indexes(name) ON DELETE SET NULL,
  source_table text,
  subject_column text,
  input_columns text[],
  pair_sources jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(pair_sources) = 'array'),
  candidate_query text,
  output_schema jsonb NOT NULL CHECK (jsonb_typeof(output_schema) = 'object'),
  action_types text[] NOT NULL DEFAULT '{}'::text[],
  stale_policy text NOT NULL DEFAULT 'refresh_then_fail_closed' CHECK (stale_policy IN (
    'lookup_only_fail_closed',
    'refresh_then_fail_closed'
  )),
  selection_policy jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(selection_policy) = 'object'),
  trigger_policy jsonb NOT NULL DEFAULT '{"on_change":"mark_stale"}'::jsonb CHECK (jsonb_typeof(trigger_policy) = 'object'),
  input_shaping jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(input_shaping) = 'object'),
  decision_contract jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(decision_contract) = 'object'),
  model_name text NOT NULL REFERENCES otlet.models(name),
  record_type text NOT NULL,
  runtime_options jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(runtime_options) = 'object'),
  max_candidate_rows integer NOT NULL DEFAULT 1000 CHECK (max_candidate_rows BETWEEN 1 AND 100000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (kind = 'row' AND semantic_index_name IS NOT NULL AND semantic_join_index_name IS NULL AND source_table IS NOT NULL AND subject_column IS NOT NULL AND pair_sources = '[]'::jsonb AND candidate_query IS NULL)
    OR
    (kind = 'pair' AND semantic_index_name IS NULL AND semantic_join_index_name IS NOT NULL AND source_table IS NULL AND subject_column IS NULL AND candidate_query IS NOT NULL)
  )
);

CREATE TABLE otlet.watch_pack_versions (
  id bigserial PRIMARY KEY,
  watch_name text NOT NULL CHECK (watch_name ~ '^[a-z0-9][a-z0-9_-]*$'),
  version_number integer NOT NULL CHECK (version_number > 0),
  content_digest text NOT NULL CHECK (content_digest ~ '^[0-9a-f]{32}$'),
  definition jsonb NOT NULL CHECK (
    jsonb_typeof(definition) = 'object'
    AND definition ->> 'format' = 'otlet.watch.v1'
    AND definition ->> 'name' = watch_name
    AND definition ->> 'content_digest' = content_digest
  ),
  created_by text NOT NULL DEFAULT session_user,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (watch_name, version_number),
  UNIQUE (watch_name, id)
);

CREATE INDEX watch_pack_versions_watch_created_idx
ON otlet.watch_pack_versions (watch_name, version_number DESC, id DESC);

CREATE TABLE otlet.watch_pack_heads (
  watch_name text PRIMARY KEY CHECK (watch_name ~ '^[a-z0-9][a-z0-9_-]*$'),
  version_id bigint NOT NULL UNIQUE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (watch_name, version_id)
    REFERENCES otlet.watch_pack_versions(watch_name, id)
);

CREATE FUNCTION otlet.reject_watch_pack_version_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet watch pack history is immutable';
END;
$$;

CREATE TRIGGER watch_pack_versions_immutable
BEFORE UPDATE OR DELETE ON otlet.watch_pack_versions
FOR EACH ROW EXECUTE FUNCTION otlet.reject_watch_pack_version_change();

CREATE TRIGGER watch_pack_versions_no_truncate
BEFORE TRUNCATE ON otlet.watch_pack_versions
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_watch_pack_version_change();

CREATE FUNCTION otlet.source_fields_are_allowed(
  input jsonb,
  input_shaping jsonb
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN jsonb_typeof(COALESCE($1, 'null'::jsonb)) IS DISTINCT FROM 'object' THEN false
    WHEN NOT COALESCE($2, '{}'::jsonb) ? 'source_fields' THEN COALESCE($1, '{}'::jsonb) = '{}'::jsonb
    WHEN jsonb_typeof(COALESCE($2, '{}'::jsonb) -> 'source_fields') IS DISTINCT FROM 'array' THEN false
    WHEN EXISTS (
      SELECT 1
      FROM jsonb_array_elements(COALESCE($2, '{}'::jsonb) -> 'source_fields') field(value)
      WHERE jsonb_typeof(field.value) IS DISTINCT FROM 'string'
    ) THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM jsonb_object_keys(COALESCE($1, '{}'::jsonb)) input_field
      WHERE NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE($2, '{}'::jsonb) -> 'source_fields') allowed(field_name)
        WHERE allowed.field_name = input_field
      )
    )
  END;
$$;

CREATE FUNCTION otlet.redact_jsonb_fields(
  value jsonb,
  redacted_fields text[],
  protected_fields text[] DEFAULT ARRAY[]::text[]
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  item_key text;
  item_value jsonb;
  result jsonb;
BEGIN
  IF redact_jsonb_fields.value IS NULL THEN
    RETURN NULL;
  END IF;

  CASE jsonb_typeof(redact_jsonb_fields.value)
    WHEN 'object' THEN
      result := '{}'::jsonb;
      FOR item_key, item_value IN
        SELECT entry.key, entry.value
        FROM jsonb_each(redact_jsonb_fields.value) entry(key, value)
      LOOP
        result := result || jsonb_build_object(
          item_key,
          CASE
            WHEN item_key = ANY(COALESCE(redacted_fields, ARRAY[]::text[]))
             AND NOT item_key = ANY(COALESCE(protected_fields, ARRAY[]::text[]))
              THEN to_jsonb('[REDACTED]'::text)
            ELSE otlet.redact_jsonb_fields(item_value, redacted_fields, protected_fields)
          END
        );
      END LOOP;
      RETURN result;
    WHEN 'array' THEN
      SELECT COALESCE(
        jsonb_agg(otlet.redact_jsonb_fields(item.value, redacted_fields, protected_fields) ORDER BY item.ordinality),
        '[]'::jsonb
      )
      INTO result
      FROM jsonb_array_elements(redact_jsonb_fields.value)
        WITH ORDINALITY item(value, ordinality);
      RETURN result;
    ELSE
      RETURN redact_jsonb_fields.value;
  END CASE;
END;
$$;

CREATE FUNCTION otlet.redact_operational_evidence(value jsonb) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT otlet.redact_jsonb_fields(
    COALESCE($1, '{}'::jsonb),
    ARRAY[
      'input',
      'input_text',
      'source_row',
      'raw_output',
      'candidate_output',
      'output',
      'prompt',
      'prompt_text',
      'actions',
      'payload'
    ],
    ARRAY[]::text[]
  );
$$;

CREATE FUNCTION otlet.enforce_evidence_storage() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  task_input_shaping jsonb;
  validate_source_input boolean := false;
BEGIN
  SELECT *
  INTO policy
  FROM otlet.production_policy
  WHERE name = 'default';

  IF TG_TABLE_NAME = 'jobs' THEN
    validate_source_input := TG_OP = 'INSERT';
    IF TG_OP = 'UPDATE' THEN
      validate_source_input := NEW.task_name IS DISTINCT FROM OLD.task_name
        OR NEW.input IS DISTINCT FROM OLD.input;
    END IF;
    IF validate_source_input THEN
      SELECT t.input_shaping
      INTO task_input_shaping
      FROM otlet.tasks t
      WHERE t.name = NEW.task_name;

      IF NOT otlet.source_fields_are_allowed(NEW.input, task_input_shaping) THEN
        RAISE EXCEPTION 'otlet job input contains a field outside the task source-field allowlist';
      END IF;
    END IF;
    IF octet_length(COALESCE(NEW.error, '')) > policy.max_error_bytes THEN
      RAISE EXCEPTION 'otlet job error exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'inference_receipts' THEN
    IF octet_length(COALESCE(NEW.raw_output, '')) > policy.max_raw_output_bytes THEN
      RAISE EXCEPTION 'otlet raw output exceeds evidence byte limit';
    END IF;
    IF octet_length(COALESCE(NEW.candidate_output, 'null'::jsonb)::text) > policy.max_structured_output_bytes THEN
      RAISE EXCEPTION 'otlet candidate output exceeds evidence byte limit';
    END IF;
    IF octet_length(COALESCE(NEW.trace_summary, '{}'::jsonb)::text) > policy.max_trace_bytes THEN
      RAISE EXCEPTION 'otlet trace exceeds evidence byte limit';
    END IF;
    IF octet_length(COALESCE(NEW.error, '')) > policy.max_error_bytes THEN
      RAISE EXCEPTION 'otlet receipt error exceeds evidence byte limit';
    END IF;
    IF octet_length(to_jsonb(NEW)::text) > policy.max_receipt_bytes THEN
      RAISE EXCEPTION 'otlet receipt exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'outputs' THEN
    IF octet_length(NEW.output::text) > policy.max_structured_output_bytes THEN
      RAISE EXCEPTION 'otlet structured output exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'actions' THEN
    IF octet_length(NEW.payload::text) > policy.max_action_bytes THEN
      RAISE EXCEPTION 'otlet action exceeds evidence byte limit';
    END IF;
    IF octet_length(COALESCE(NEW.error, '')) > policy.max_error_bytes
       OR octet_length(COALESCE(NEW.review_reason, '')) > policy.max_error_bytes THEN
      RAISE EXCEPTION 'otlet action error or review reason exceeds evidence byte limit';
    END IF;
    IF TG_OP = 'INSERT' THEN
      PERFORM 1
      FROM otlet.jobs j
      WHERE j.id = NEW.job_id
      FOR UPDATE;
      IF (
        SELECT count(*)
        FROM otlet.actions existing
        WHERE existing.job_id = NEW.job_id
      ) >= policy.max_actions_per_job THEN
        RAISE EXCEPTION 'otlet actions exceed per-job evidence count limit';
      END IF;
    END IF;
  ELSIF TG_TABLE_NAME = 'action_execution_receipts' THEN
    IF octet_length(COALESCE(NEW.error, '')) > policy.max_error_bytes
       OR octet_length(to_jsonb(NEW)::text) > policy.max_receipt_bytes THEN
      RAISE EXCEPTION 'otlet action execution receipt exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'worker_events' THEN
    NEW.detail := otlet.redact_operational_evidence(NEW.detail);
    IF octet_length(COALESCE(NEW.message, '')) > policy.max_event_message_bytes THEN
      RAISE EXCEPTION 'otlet worker event message exceeds evidence byte limit';
    END IF;
    IF octet_length(NEW.detail::text) > policy.max_event_detail_bytes THEN
      RAISE EXCEPTION 'otlet worker event detail exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME = 'runtime_slots' THEN
    IF octet_length(COALESCE(NEW.last_error, '')) > policy.max_error_bytes THEN
      RAISE EXCEPTION 'otlet runtime error exceeds evidence byte limit';
    END IF;
  ELSIF TG_TABLE_NAME IN ('records', 'semantic_materializations') THEN
    IF octet_length(NEW.body::text) > policy.max_structured_output_bytes THEN
      RAISE EXCEPTION 'otlet materialized output exceeds evidence byte limit';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER inference_receipts_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.inference_receipts
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER outputs_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.outputs
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER actions_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.actions
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER action_execution_receipts_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.action_execution_receipts
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER worker_events_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.worker_events
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER runtime_slots_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.runtime_slots
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER records_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.records
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();

CREATE TRIGGER semantic_materializations_evidence_storage
BEFORE INSERT OR UPDATE ON otlet.semantic_materializations
FOR EACH ROW EXECUTE FUNCTION otlet.enforce_evidence_storage();
