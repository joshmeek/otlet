CREATE SCHEMA otlet;

CREATE TABLE otlet.production_policy (
  name text PRIMARY KEY DEFAULT 'default',
  stale_policy text NOT NULL DEFAULT 'refresh_then_fail_closed',
  max_queued_jobs_per_model integer NOT NULL DEFAULT 1000,
  max_attempts integer NOT NULL DEFAULT 3,
  max_attempt_ms integer NOT NULL DEFAULT 300000,
  default_runtime_options jsonb NOT NULL DEFAULT '{}'::jsonb,
  semantic_auto_wait_ms integer NOT NULL DEFAULT 10000,
  semantic_auto_infer_ms integer NOT NULL DEFAULT 15000,
  semantic_auto_max_rows integer NOT NULL DEFAULT 1,
  worker_claim_batch_size integer NOT NULL DEFAULT 8,
  worker_claim_task_cursor text NOT NULL DEFAULT '',
  job_lease_interval interval NOT NULL DEFAULT interval '5 minutes',
  worker_event_retention interval NOT NULL DEFAULT interval '7 days',
  trace_detail_retention interval NOT NULL DEFAULT interval '7 days',
  eval_label_retention interval NOT NULL DEFAULT interval '90 days',
  delete_stale_materialization_retention interval NOT NULL DEFAULT interval '30 days',
  sensitive_evidence_mode text NOT NULL DEFAULT 'redacted',
  sensitive_evidence_retention interval NOT NULL DEFAULT interval '7 days',
  failed_job_retention interval NOT NULL DEFAULT interval '30 days',
  CHECK (name = 'default'),
  CHECK (stale_policy IN (
    'lookup_only_fail_closed',
    'refresh_then_fail_closed'
  )),
  CHECK (max_queued_jobs_per_model BETWEEN 1 AND 1000000),
  CHECK (max_attempts BETWEEN 1 AND 20),
  CHECK (max_attempt_ms BETWEEN 1 AND 3600000),
  CHECK (jsonb_typeof(default_runtime_options) = 'object'),
  CHECK (semantic_auto_wait_ms BETWEEN 0 AND 30000),
  CHECK (semantic_auto_infer_ms BETWEEN 0 AND 30000),
  CHECK (semantic_auto_max_rows BETWEEN 0 AND 10),
  CHECK (worker_claim_batch_size BETWEEN 1 AND 128),
  CHECK (job_lease_interval >= interval '1 second'),
  CHECK (job_lease_interval <= interval '1 hour'),
  CHECK (eval_label_retention >= interval '1 day'),
  CHECK (delete_stale_materialization_retention >= interval '1 day'),
  CHECK (sensitive_evidence_mode IN ('redacted', 'diagnostic')),
  CHECK (sensitive_evidence_retention >= interval '1 day'),
  CHECK (failed_job_retention >= interval '1 day')
);

INSERT INTO otlet.production_policy (name)
VALUES ('default');

CREATE TABLE otlet.models (
  name text PRIMARY KEY,
  artifact_path text NOT NULL,
  artifact_hash text,
  max_active_jobs int NOT NULL DEFAULT 1 CHECK (max_active_jobs BETWEEN 1 AND 1024),
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.decision_rule_presets (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  decision_contract jsonb NOT NULL CHECK (jsonb_typeof(decision_contract) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION otlet.reject_decision_rule_preset_update() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet decision rule preset % is immutable; create a new preset name', OLD.name;
END;
$$;

CREATE TRIGGER decision_rule_presets_immutable
BEFORE UPDATE ON otlet.decision_rule_presets
FOR EACH ROW EXECUTE FUNCTION otlet.reject_decision_rule_preset_update();

CREATE FUNCTION otlet.semantic_canonical_jsonb(
  input jsonb
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE jsonb_typeof($1)
    WHEN 'object' THEN COALESCE(
      (
        SELECT jsonb_object_agg(key, otlet.semantic_canonical_jsonb(value) ORDER BY key)
        FROM jsonb_each($1)
      ),
      '{}'::jsonb
    )
    WHEN 'array' THEN COALESCE(
      (
        SELECT jsonb_agg(otlet.semantic_canonical_jsonb(value) ORDER BY ordinality)
        FROM jsonb_array_elements($1) WITH ORDINALITY AS items(value, ordinality)
      ),
      '[]'::jsonb
    )
    WHEN 'number' THEN to_jsonb(trim_scale(($1 #>> '{}')::numeric))
    ELSE $1
  END;
$$;

CREATE FUNCTION otlet.semantic_shaped_input(
  input jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  actual_input jsonb := COALESCE(input, '{}'::jsonb);
  shaping jsonb := COALESCE(input_shaping, '{}'::jsonb);
  shaped jsonb := actual_input;
  counts jsonb := '{}'::jsonb;
  ids jsonb := '{}'::jsonb;
  field_name text;
  target_key text;
  source_field text;
  bucket_key text;
  bucket_value jsonb;
  bucket_count integer;
  original_bytes integer;
  max_bytes integer := 0;
  canonical_text text;
BEGIN
  IF jsonb_typeof(shaped) IS DISTINCT FROM 'object' THEN
    RETURN shaped;
  END IF;

  shaped := shaped - '_otlet_mvcc' - 'otlet_mvcc';

  IF jsonb_typeof(shaping -> 'strip_keys') = 'array' THEN
    FOR field_name IN SELECT jsonb_array_elements_text(shaping -> 'strip_keys') LOOP
      shaped := shaped - field_name;
    END LOOP;
  END IF;

  IF NOT shaped ? 'evidence_counts'
     AND jsonb_typeof(shaping -> 'evidence_fields') = 'array' THEN
    FOR field_name IN SELECT jsonb_array_elements_text(shaping -> 'evidence_fields') LOOP
      IF jsonb_typeof(actual_input -> field_name) = 'object' THEN
        FOR bucket_key, bucket_value IN SELECT key, value FROM jsonb_each(actual_input -> field_name) LOOP
          bucket_count := CASE
            WHEN jsonb_typeof(bucket_value) = 'array' THEN jsonb_array_length(bucket_value)
            WHEN jsonb_typeof(bucket_value) = 'string' AND btrim(bucket_value #>> '{}') <> '' THEN 1
            WHEN jsonb_typeof(bucket_value) IN ('number', 'object') THEN 1
            WHEN jsonb_typeof(bucket_value) = 'boolean' AND bucket_value = 'true'::jsonb THEN 1
            ELSE 0
          END;
          counts := counts || jsonb_build_object(bucket_key, bucket_count);
        END LOOP;
      END IF;
    END LOOP;
    IF counts <> '{}'::jsonb THEN
      shaped := jsonb_set(shaped, '{evidence_counts}', counts, true);
    END IF;
  END IF;

  IF NOT shaped ? 'action_ids'
     AND jsonb_typeof(shaping -> 'action_id_fields') = 'object' THEN
    FOR target_key, source_field IN SELECT key, value FROM jsonb_each_text(shaping -> 'action_id_fields') LOOP
      IF actual_input ? source_field THEN
        ids := ids || jsonb_build_object(target_key, actual_input -> source_field);
      END IF;
    END LOOP;
    IF ids <> '{}'::jsonb THEN
      shaped := jsonb_set(shaped, '{action_ids}', ids, true);
    END IF;
  END IF;

  IF jsonb_typeof(shaping -> 'max_shaped_input_bytes') = 'number' THEN
    max_bytes := LEAST(
      GREATEST((shaping ->> 'max_shaped_input_bytes')::numeric, 0),
      1048576
    )::integer;
  END IF;
  canonical_text := otlet.semantic_canonical_jsonb(shaped)::text;
  original_bytes := length(canonical_text);
  IF max_bytes > 0 AND original_bytes > max_bytes THEN
    shaped := jsonb_build_object(
      '_otlet_input_truncated', true,
      'truncation_policy', 'max_shaped_input_bytes_fail_toward_abstention',
      'original_shaped_input_bytes', original_bytes,
      'max_shaped_input_bytes', max_bytes,
      'truncated_input_preview', left(canonical_text, LEAST(max_bytes, 1024))
    );
  END IF;

  RETURN shaped;
END;
$$;

CREATE FUNCTION otlet.semantic_content_hash(
  input jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT md5(otlet.semantic_canonical_jsonb(otlet.semantic_shaped_input($1, $2))::text);
$$;

CREATE FUNCTION otlet.semantic_project_row(
  row_data jsonb,
  input_columns text[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN $2 IS NULL THEN COALESCE($1, '{}'::jsonb)
    ELSE COALESCE(
      (
        SELECT jsonb_object_agg(key, value ORDER BY key)
        FROM jsonb_each(COALESCE($1, '{}'::jsonb))
        WHERE key = ANY($2)
      ),
      '{}'::jsonb
    )
  END;
$$;

CREATE FUNCTION otlet.task_contract_hash(
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT md5(jsonb_build_object(
    'instruction', COALESCE($1, ''),
    'output_schema', COALESCE($2, '{}'::jsonb),
    'model_name', COALESCE($3, ''),
    'runtime_options', COALESCE($4, '{}'::jsonb),
    'input_shaping', COALESCE($5, '{}'::jsonb),
    'decision_contract', COALESCE($6, '{}'::jsonb)
  )::text);
$$;

-- Truth table for semantic freshness:
-- content mismatch -> stale, reason = stale_reason or content_revalidation_pending
-- contract mismatch -> stale, reason = contract_changed
-- stale = false and content/contract match -> fresh
-- stale = true with source_update and content/contract match -> fresh revalidation candidate
-- any other stale reason with content/contract match -> stale
CREATE FUNCTION otlet.semantic_freshness_status(
  material_content_hash text,
  material_contract_hash text,
  material_stale boolean,
  material_stale_reason text,
  material_source_hash text,
  current_content_hash text,
  current_contract_hash text,
  current_source_hash text DEFAULT NULL
) RETURNS TABLE (
  is_fresh boolean,
  is_stale boolean,
  stale_reason text,
  freshness_basis text
)
LANGUAGE sql
IMMUTABLE
AS $$
  WITH classified AS (
    SELECT (
      material_content_hash IS NOT DISTINCT FROM current_content_hash
      AND material_contract_hash IS NOT DISTINCT FROM current_contract_hash
      AND (
        NOT COALESCE(material_stale, false)
        OR material_stale_reason = 'source_update'
      )
    ) AS fresh
  )
  SELECT
    fresh AS is_fresh,
    NOT fresh AS is_stale,
    CASE
      WHEN fresh THEN NULL::text
      WHEN material_contract_hash IS DISTINCT FROM current_contract_hash THEN 'contract_changed'
      ELSE COALESCE(material_stale_reason, 'content_revalidation_pending')
    END AS stale_reason,
    CASE
      WHEN NOT fresh THEN NULL::text
      WHEN COALESCE(material_stale, false) THEN 'revalidated_after_benign_update'
      WHEN material_source_hash IS NOT DISTINCT FROM current_source_hash THEN 'mvcc_match'
      ELSE 'content_hash_match'
    END AS freshness_basis
  FROM classified;
$$;

INSERT INTO otlet.decision_rule_presets (name, decision_contract)
VALUES (
  'entity_resolution_evidence_v1',
  jsonb_build_object(
    'prompt_prefix',
    'Return one JSON object only. Top-level keys must be output and actions. Never use ellipses or placeholder values. Use input.evidence_counts for the decision and input.candidate_evidence only for the short reason. input.action_ids are row IDs for action bodies, not identity evidence. confidence must be low, medium, or high, never unclear. Rule 1: if conflicting_stable_identifiers > 0, output different_entity with confidence high. Rule 2: else if shared_stable_identifiers > 0, output same_entity with confidence high. Rule 3: else output unclear with confidence medium. ',
    'answer_field', 'match',
    'abstain_values', jsonb_build_array('unclear'),
    'confidence_field', 'confidence',
    'accepted_confidence', jsonb_build_array('high')
  )
),
(
  'row_triage_decision_v1',
  jsonb_build_object(
    'prompt_prefix',
    'Return one JSON object only. Top-level keys must be output and actions. Never use ellipses or placeholder values. Use input.row.blockers and input.row.approvals for the decision. confidence must be low, medium, or high, never unclear. Rule 1: if blockers > 0, output flag with confidence high. Rule 2: else if approvals > 0, output pass with confidence high. Rule 3: else output unclear with confidence medium. ',
    'answer_field', 'decision',
    'abstain_values', jsonb_build_array('unclear'),
    'confidence_field', 'confidence',
    'accepted_confidence', jsonb_build_array('high', 'medium')
  )
);

CREATE TABLE otlet.tasks (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  input_query text,
  instruction text NOT NULL,
  output_schema jsonb NOT NULL,
  model_name text NOT NULL REFERENCES otlet.models(name),
  runtime_options jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(runtime_options) = 'object'),
  input_shaping jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(input_shaping) = 'object'),
  decision_contract jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(decision_contract) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION otlet.default_accept_field_checks() RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '{"answer_field":"match","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb;
$$;

CREATE TABLE otlet.model_selection_policies (
  task_name text PRIMARY KEY REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  cheap_model_name text NOT NULL REFERENCES otlet.models(name),
  strong_model_name text NOT NULL REFERENCES otlet.models(name),
  accept_field_checks jsonb NOT NULL DEFAULT otlet.default_accept_field_checks() CHECK (jsonb_typeof(accept_field_checks) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (cheap_model_name <> strong_model_name)
);

CREATE TABLE otlet.runtime_slots (
  model_name text PRIMARY KEY REFERENCES otlet.models(name),
  artifact_path text,
  status text NOT NULL DEFAULT 'cold',
  active_jobs int NOT NULL DEFAULT 0,
  loaded_at timestamptz,
  last_used_at timestamptz,
  last_error text,
  load_ms bigint,
  ctx_ms bigint,
  last_prompt_tokens bigint,
  last_generated_tokens bigint,
  last_generate_ms bigint,
  tokens_per_second numeric,
  model_memory_bytes bigint NOT NULL DEFAULT 0,
  model_parameters bigint NOT NULL DEFAULT 0,
  context_window_tokens bigint NOT NULL DEFAULT 0,
  model_device_policy text,
  resident_memory_tracked_bytes bigint NOT NULL DEFAULT 0,
  memory_accounting_policy text,
  worker_process_rss_bytes bigint NOT NULL DEFAULT 0,
  worker_process_virtual_bytes bigint NOT NULL DEFAULT 0,
  worker_memory_sample_policy text,
  jobs_completed bigint NOT NULL DEFAULT 0,
  failures bigint NOT NULL DEFAULT 0,
  cache_hits bigint NOT NULL DEFAULT 0,
  cache_misses bigint NOT NULL DEFAULT 0,
  inference_cache_hits bigint NOT NULL DEFAULT 0,
  inference_cache_misses bigint NOT NULL DEFAULT 0,
  inference_cache_entries bigint NOT NULL DEFAULT 0,
  inference_cache_bytes bigint NOT NULL DEFAULT 0,
  inference_cache_max_entries bigint NOT NULL DEFAULT 0,
  inference_cache_max_bytes bigint NOT NULL DEFAULT 0,
  inference_cache_evictions bigint NOT NULL DEFAULT 0,
  inference_cache_last_eviction_reason text,
  inference_cache_last_reason text
);

CREATE TABLE otlet.jobs (
  id bigserial PRIMARY KEY,
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  subject_id text NOT NULL,
  input jsonb NOT NULL,
  status text NOT NULL DEFAULT 'queued',
  attempts int NOT NULL DEFAULT 0,
  leased_until timestamptz,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  cancel_requested_at timestamptz,
  CHECK (status IN ('queued', 'running', 'complete', 'failed', 'canceled', 'cancel_requested'))
);

CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');

CREATE INDEX jobs_task_status_idx
ON otlet.jobs (task_name, status);

CREATE INDEX jobs_expired_lease_idx
ON otlet.jobs (leased_until, id)
WHERE status IN ('running', 'cancel_requested');

CREATE INDEX jobs_finished_terminal_idx
ON otlet.jobs (finished_at, created_at, id)
WHERE status IN ('failed', 'canceled');

CREATE INDEX jobs_complete_subject_finished_idx
ON otlet.jobs (task_name, subject_id, finished_at DESC NULLS LAST, id DESC)
WHERE status = 'complete';

CREATE TABLE otlet.inference_receipts (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  attempt_index int NOT NULL,
  selection_role text NOT NULL DEFAULT 'direct',
  selection_status text NOT NULL DEFAULT 'accepted',
  selection_reason text,
  task_name text NOT NULL,
  subject_id text NOT NULL,
  model_name text NOT NULL,
  model_artifact_path text NOT NULL,
  model_artifact_hash text,
  runtime_name text NOT NULL,
  runtime_endpoint text NOT NULL,
  runtime_options jsonb NOT NULL,
  prompt_hash text,
  input_hash text,
  output_schema_hash text,
  raw_output_hash text,
  raw_output text,
  candidate_output jsonb,
  prompt_tokens bigint,
  generated_tokens bigint,
  generate_ms bigint,
  tokens_per_second numeric,
  schema_validation_status text,
  trace_summary jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(trace_summary) = 'object'),
  otlet_version text NOT NULL DEFAULT '0.1.0',
  started_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL,
  error text,
  UNIQUE (job_id, attempt_index),
  CHECK (attempt_index > 0),
  CHECK (selection_role IN ('direct', 'cheap', 'strong')),
  CHECK (selection_status IN ('accepted', 'rejected', 'failed')),
  CHECK (candidate_output IS NULL OR jsonb_typeof(candidate_output) = 'object')
);

CREATE INDEX inference_receipts_task_model_role_finished_idx
ON otlet.inference_receipts (task_name, model_name, selection_role, finished_at DESC, id DESC);

CREATE INDEX inference_receipts_model_success_finished_idx
ON otlet.inference_receipts (model_name, finished_at DESC, id DESC)
INCLUDE (task_name, generate_ms)
WHERE status = 'complete'
  AND schema_validation_status = 'passed'
  AND COALESCE(generate_ms, 0) > 0;

CREATE INDEX inference_receipts_sensitive_evidence_retention_idx
ON otlet.inference_receipts (finished_at, id)
WHERE raw_output IS NOT NULL
   OR trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL;

CREATE INDEX inference_receipts_trace_steps_finished_idx
ON otlet.inference_receipts (finished_at, id)
WHERE jsonb_typeof(trace_summary #> '{detailed_trace,steps}') = 'array'
  AND jsonb_array_length(trace_summary #> '{detailed_trace,steps}') > 0;

CREATE INDEX inference_receipts_direct_rejected_review_idx
ON otlet.inference_receipts (finished_at, id)
WHERE selection_role = 'direct'
  AND selection_status = 'rejected'
  AND selection_reason = 'direct_rejected_by_decision_contract'
  AND schema_validation_status = 'passed'
  AND candidate_output IS NOT NULL;

CREATE TABLE otlet.worker_events (
  id bigserial PRIMARY KEY,
  event_type text NOT NULL,
  job_id bigint REFERENCES otlet.jobs(id),
  runtime_name text,
  message text,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX worker_events_type_created_idx
ON otlet.worker_events (event_type, created_at DESC, id DESC);

CREATE INDEX worker_events_type_model_created_idx
ON otlet.worker_events (event_type, (detail ->> 'model_name'), created_at DESC)
WHERE detail ? 'model_name';

CREATE INDEX worker_events_queue_suppressed_task_created_idx
ON otlet.worker_events ((detail ->> 'task_name'), created_at DESC, id DESC)
WHERE event_type = 'queue_admission_suppressed' AND detail ? 'task_name';

CREATE INDEX worker_events_job_id_idx
ON otlet.worker_events (job_id)
WHERE job_id IS NOT NULL;

CREATE TABLE otlet.outputs (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  receipt_id bigint NOT NULL UNIQUE REFERENCES otlet.inference_receipts(id),
  output jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX outputs_one_per_job_idx
ON otlet.outputs (job_id);

CREATE TABLE otlet.action_type_schemas (
  action_type text PRIMARY KEY,
  requires_approval boolean NOT NULL DEFAULT false,
  creates_record boolean NOT NULL DEFAULT false,
  applyable boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO otlet.action_type_schemas (
  action_type,
  requires_approval,
  creates_record,
  applyable
)
VALUES
  ('create_record', false, true, true),
  ('merge_candidate', true, false, false),
  ('new_entity', false, false, false),
  ('review_flag', false, false, false),
  ('note', false, true, true),
  ('update_row', true, false, true);

CREATE TABLE otlet.action_targets (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  target_table regclass NOT NULL,
  identity_column name NOT NULL,
  allowed_columns name[] NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (cardinality(allowed_columns) BETWEEN 1 AND 16),
  CHECK (NOT identity_column = ANY(allowed_columns))
);

CREATE TABLE otlet.actions (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  output_id bigint REFERENCES otlet.outputs(id),
  receipt_id bigint REFERENCES otlet.inference_receipts(id),
  action_type text NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  status text NOT NULL DEFAULT 'proposed',
  approval_status text NOT NULL DEFAULT 'not_required',
  dry_run_status text NOT NULL DEFAULT 'not_run',
  apply_status text NOT NULL DEFAULT 'not_applicable',
  source_table text,
  subject_id text,
  source_hash text,
  content_hash text,
  idempotency_key text,
  error text,
  review_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  applied_at timestamptz,
  CHECK (status IN ('proposed', 'complete', 'rejected', 'approved', 'applied')),
  CHECK (approval_status IN ('not_required', 'required', 'approved', 'rejected')),
  CHECK (dry_run_status IN ('not_run', 'passed', 'failed')),
  CHECK (apply_status IN ('not_applicable', 'applied', 'replayed', 'failed')),
  CHECK (action_type <> 'update_row' OR idempotency_key IS NOT NULL OR status = 'rejected')
);

CREATE INDEX actions_job_id_idx
ON otlet.actions (job_id);

CREATE INDEX actions_receipt_id_idx
ON otlet.actions (receipt_id)
WHERE receipt_id IS NOT NULL;

CREATE INDEX actions_review_queue_idx
ON otlet.actions (created_at, id)
WHERE (approval_status = 'required' AND status = 'proposed')
   OR (action_type = 'review_flag' AND status <> 'rejected');

CREATE TABLE otlet.action_execution_receipts (
  id bigserial PRIMARY KEY,
  action_id bigint NOT NULL REFERENCES otlet.actions(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('dry_run', 'apply')),
  status text NOT NULL CHECK (status IN ('passed', 'applied', 'replayed', 'failed')),
  target_name text NOT NULL,
  target_table text NOT NULL,
  identity_hash text NOT NULL,
  changed_columns name[] NOT NULL,
  affected_rows bigint NOT NULL DEFAULT 0 CHECK (affected_rows BETWEEN 0 AND 1),
  before_hash text,
  result_hash text,
  error text,
  replay_of_receipt_id bigint REFERENCES otlet.action_execution_receipts(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'failed') = (error IS NOT NULL)),
  CHECK ((status = 'replayed') = (replay_of_receipt_id IS NOT NULL))
);

CREATE INDEX action_execution_receipts_action_created_idx
ON otlet.action_execution_receipts (action_id, created_at DESC, id DESC);

CREATE INDEX action_execution_receipts_key_status_idx
ON otlet.action_execution_receipts (idempotency_key, status, id DESC);

CREATE UNIQUE INDEX action_execution_receipts_one_apply_idx
ON otlet.action_execution_receipts (idempotency_key)
WHERE mode = 'apply' AND status = 'applied';

CREATE TABLE otlet.records (
  id bigserial PRIMARY KEY,
  action_id bigint REFERENCES otlet.actions(id),
  record_type text NOT NULL,
  subject_id text,
  body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX records_action_id_idx
ON otlet.records (action_id)
WHERE action_id IS NOT NULL;

CREATE TABLE otlet.eval_labels (
  id bigserial PRIMARY KEY,
  action_id bigint REFERENCES otlet.actions(id),
  output_id bigint REFERENCES otlet.outputs(id),
  receipt_id bigint REFERENCES otlet.inference_receipts(id),
  source_table text,
  subject_id text NOT NULL,
  source_hash text,
  expected_answer text NOT NULL,
  expected_confidence text NOT NULL,
  expected_action_type text NOT NULL,
  label_source text NOT NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expected_confidence IN ('high', 'medium', 'low')),
  CHECK (label_source IN ('approved_action', 'rejected_action', 'manual_correction'))
);

CREATE INDEX eval_labels_subject_idx
ON otlet.eval_labels (source_table, subject_id, source_hash);

CREATE INDEX eval_labels_receipt_idx
ON otlet.eval_labels (receipt_id, action_id);

CREATE INDEX eval_labels_manual_action_idx
ON otlet.eval_labels (action_id)
WHERE label_source = 'manual_correction' AND action_id IS NOT NULL;

CREATE INDEX eval_labels_manual_output_idx
ON otlet.eval_labels (output_id)
WHERE label_source = 'manual_correction' AND output_id IS NOT NULL;

CREATE INDEX eval_labels_manual_receipt_idx
ON otlet.eval_labels (receipt_id)
WHERE label_source = 'manual_correction' AND receipt_id IS NOT NULL;

CREATE INDEX eval_labels_created_at_idx
ON otlet.eval_labels (created_at, id);

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
