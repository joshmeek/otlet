CREATE SCHEMA otlet;

CREATE TABLE otlet.production_policy (
  name text PRIMARY KEY DEFAULT 'default',
  stale_policy text NOT NULL DEFAULT 'refresh_then_fail_closed',
  max_queued_jobs_per_model integer NOT NULL DEFAULT 1000,
  max_admission_rows integer NOT NULL DEFAULT 1000,
  max_input_bytes_per_job bigint NOT NULL DEFAULT 1048576,
  max_queued_input_bytes_per_model bigint NOT NULL DEFAULT 67108864,
  max_queued_input_bytes_total bigint NOT NULL DEFAULT 268435456,
  max_candidate_query_cost numeric NOT NULL DEFAULT 1000000,
  candidate_query_statement_timeout_ms integer NOT NULL DEFAULT 2000,
  max_raw_output_bytes bigint NOT NULL DEFAULT 1048576,
  max_structured_output_bytes bigint NOT NULL DEFAULT 1048576,
  max_actions_per_job integer NOT NULL DEFAULT 64,
  max_action_bytes bigint NOT NULL DEFAULT 65536,
  max_trace_bytes bigint NOT NULL DEFAULT 1048576,
  max_error_bytes bigint NOT NULL DEFAULT 4096,
  max_event_message_bytes bigint NOT NULL DEFAULT 4096,
  max_event_detail_bytes bigint NOT NULL DEFAULT 262144,
  max_receipt_bytes bigint NOT NULL DEFAULT 4194304,
  max_attempts integer NOT NULL DEFAULT 3,
  max_attempt_ms integer NOT NULL DEFAULT 300000,
  default_runtime_options jsonb NOT NULL DEFAULT '{"max_worker_rss_bytes":8589934592}'::jsonb,
  preload_model_name text,
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
  terminal_evidence_retention interval NOT NULL DEFAULT interval '30 days',
  failed_job_retention interval NOT NULL DEFAULT interval '30 days',
  CHECK (name = 'default'),
  CHECK (stale_policy IN (
    'lookup_only_fail_closed',
    'refresh_then_fail_closed'
  )),
  CHECK (max_queued_jobs_per_model BETWEEN 1 AND 1000000),
  CHECK (max_admission_rows BETWEEN 1 AND 100000),
  CHECK (max_input_bytes_per_job BETWEEN 1 AND 16777216),
  CHECK (max_queued_input_bytes_per_model BETWEEN 1 AND 1073741824),
  CHECK (max_queued_input_bytes_total BETWEEN max_queued_input_bytes_per_model AND 4294967296),
  CHECK (max_candidate_query_cost BETWEEN 1 AND 1000000000000),
  CHECK (candidate_query_statement_timeout_ms BETWEEN 1 AND 30000),
  CHECK (max_raw_output_bytes BETWEEN 1 AND 16777216),
  CHECK (max_structured_output_bytes BETWEEN 1 AND 16777216),
  CHECK (max_actions_per_job BETWEEN 0 AND 1024),
  CHECK (max_action_bytes BETWEEN 1 AND 1048576),
  CHECK (max_trace_bytes BETWEEN 1 AND 16777216),
  CHECK (max_error_bytes BETWEEN 1 AND 65536),
  CHECK (max_event_message_bytes BETWEEN 1 AND 65536),
  CHECK (max_event_detail_bytes BETWEEN 1 AND 4194304),
  CHECK (max_receipt_bytes BETWEEN 1 AND 67108864),
  CHECK (max_attempts BETWEEN 1 AND 20),
  CHECK (max_attempt_ms BETWEEN 1 AND 3600000),
  CHECK (jsonb_typeof(default_runtime_options) = 'object'),
  CHECK (preload_model_name IS NULL OR preload_model_name ~ '^[a-z0-9][a-z0-9_-]*$'),
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
  CHECK (terminal_evidence_retention >= interval '1 day'),
  CHECK (failed_job_retention >= interval '1 day')
);

INSERT INTO otlet.production_policy (name)
VALUES ('default');

CREATE TABLE otlet.models (
  name text PRIMARY KEY,
  artifact_path text NOT NULL,
  artifact_hash text NOT NULL CHECK (artifact_hash ~ '^[0-9a-f]{64}$'),
  artifact_identity jsonb NOT NULL CHECK (
    jsonb_typeof(artifact_identity) = 'object'
    AND artifact_identity ->> 'sha256' = artifact_hash
    AND jsonb_typeof(artifact_identity -> 'bytes') = 'number'
    AND artifact_identity ->> 'bytes' ~ '^[1-9][0-9]*$'
    AND (artifact_identity ->> 'bytes')::numeric <= 9223372036854775807
    AND NULLIF(artifact_identity ->> 'source', '') IS NOT NULL
    AND NULLIF(artifact_identity ->> 'revision', '') IS NOT NULL
    AND NULLIF(artifact_identity ->> 'quantization', '') IS NOT NULL
    AND NULLIF(artifact_identity ->> 'license', '') IS NOT NULL
  ),
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
  claim_token text,
  terminal_claim_token text,
  terminal_request_hash text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  cancel_requested_at timestamptz,
  CHECK (status IN ('queued', 'running', 'complete', 'failed', 'canceled', 'cancel_requested')),
  CHECK ((status IN ('running', 'cancel_requested')) = (claim_token IS NOT NULL)),
  CHECK ((terminal_claim_token IS NULL) = (terminal_request_hash IS NULL)),
  CHECK (terminal_claim_token IS NULL OR status IN ('complete', 'failed', 'canceled'))
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
  model_artifact_hash text NOT NULL,
  model_artifact_identity jsonb NOT NULL CHECK (jsonb_typeof(model_artifact_identity) = 'object'),
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
