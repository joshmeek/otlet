CREATE SCHEMA otlet;

CREATE TABLE otlet.production_policy (
  name text PRIMARY KEY DEFAULT 'default',
  stale_policy text NOT NULL DEFAULT 'refresh_then_fail_closed',
  max_queued_jobs_per_model integer NOT NULL DEFAULT 1000,
  max_attempts integer NOT NULL DEFAULT 3,
  semantic_auto_wait_ms integer NOT NULL DEFAULT 10000,
  semantic_auto_infer_ms integer NOT NULL DEFAULT 15000,
  semantic_auto_max_rows integer NOT NULL DEFAULT 1,
  worker_claim_batch_size integer NOT NULL DEFAULT 8,
  job_lease_interval interval NOT NULL DEFAULT interval '5 minutes',
  worker_event_retention interval NOT NULL DEFAULT interval '7 days',
  trace_detail_retention interval NOT NULL DEFAULT interval '7 days',
  eval_label_retention interval NOT NULL DEFAULT interval '90 days',
  CHECK (name = 'default'),
  CHECK (stale_policy IN (
    'lookup_only_fail_closed',
    'refresh_then_fail_closed'
  )),
  CHECK (max_queued_jobs_per_model BETWEEN 1 AND 1000000),
  CHECK (max_attempts BETWEEN 1 AND 20),
  CHECK (semantic_auto_wait_ms BETWEEN 0 AND 30000),
  CHECK (semantic_auto_infer_ms BETWEEN 0 AND 30000),
  CHECK (semantic_auto_max_rows BETWEEN 0 AND 10),
  CHECK (worker_claim_batch_size BETWEEN 1 AND 128),
  CHECK (job_lease_interval >= interval '1 second'),
  CHECK (job_lease_interval <= interval '1 hour'),
  CHECK (eval_label_retention >= interval '1 day')
);

INSERT INTO otlet.production_policy (name)
VALUES ('default');

CREATE TABLE otlet.runtimes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  endpoint text NOT NULL DEFAULT 'linked',
  status text NOT NULL DEFAULT 'unknown',
  last_error text,
  checked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO otlet.runtimes (name, endpoint, status)
VALUES ('linked_inproc', 'linked', 'unknown');

CREATE TABLE otlet.models (
  name text PRIMARY KEY,
  artifact_path text NOT NULL,
  artifact_hash text,
  runtime_name text NOT NULL DEFAULT 'linked_inproc' REFERENCES otlet.runtimes(name),
  max_active_jobs int NOT NULL DEFAULT 1 CHECK (max_active_jobs BETWEEN 1 AND 1024),
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.model_versions (
  id bigserial PRIMARY KEY,
  model_name text NOT NULL REFERENCES otlet.models(name),
  artifact_path text NOT NULL,
  artifact_hash text,
  runtime_name text NOT NULL REFERENCES otlet.runtimes(name),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.decision_rule_presets (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  decision_contract jsonb NOT NULL CHECK (jsonb_typeof(decision_contract) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

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

CREATE TABLE otlet.model_selection_policies (
  task_name text PRIMARY KEY REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  cheap_model_name text NOT NULL REFERENCES otlet.models(name),
  strong_model_name text NOT NULL REFERENCES otlet.models(name),
  accept_field_checks jsonb NOT NULL DEFAULT '{"answer_field":"match","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb CHECK (jsonb_typeof(accept_field_checks) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (cheap_model_name <> strong_model_name)
);

CREATE TABLE otlet.runtime_slots (
  runtime_name text NOT NULL REFERENCES otlet.runtimes(name),
  model_name text NOT NULL REFERENCES otlet.models(name),
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
  inference_cache_evictions bigint NOT NULL DEFAULT 0,
  inference_cache_last_reason text,
  PRIMARY KEY (runtime_name, model_name)
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
  raw_output text,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  cancel_requested_at timestamptz
);

CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');

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
  CHECK (selection_status IN ('accepted', 'rejected', 'failed'))
);

CREATE TABLE otlet.worker_events (
  id bigserial PRIMARY KEY,
  event_type text NOT NULL,
  job_id bigint REFERENCES otlet.jobs(id),
  runtime_name text REFERENCES otlet.runtimes(name),
  message text,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.outputs (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  receipt_id bigint NOT NULL UNIQUE REFERENCES otlet.inference_receipts(id),
  output jsonb NOT NULL,
  raw_output text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX outputs_one_per_job_idx
ON otlet.outputs (job_id);

CREATE TABLE otlet.action_type_schemas (
  action_type text PRIMARY KEY,
  requires_approval boolean NOT NULL DEFAULT false,
  creates_record boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO otlet.action_type_schemas (
  action_type,
  requires_approval,
  creates_record
)
VALUES
  ('create_record', false, true),
  ('merge_candidate', true, false),
  ('new_entity', false, false),
  ('review_flag', false, false),
  ('note', false, true),
  ('follow_up_job', false, false);

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
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  applied_at timestamptz,
  CHECK (status IN ('proposed', 'complete', 'rejected', 'approved', 'applied')),
  CHECK (approval_status IN ('not_required', 'required', 'approved', 'rejected')),
  CHECK (dry_run_status IN ('not_run', 'passed', 'failed')),
  CHECK (apply_status IN ('not_applicable', 'applied', 'failed'))
);

CREATE TABLE otlet.records (
  id bigserial PRIMARY KEY,
  action_id bigint REFERENCES otlet.actions(id),
  record_type text NOT NULL,
  subject_id text,
  body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE otlet.eval_labels (
  id bigserial PRIMARY KEY,
  action_id bigint REFERENCES otlet.actions(id),
  output_id bigint REFERENCES otlet.outputs(id),
  receipt_id bigint REFERENCES otlet.inference_receipts(id),
  source_table text,
  subject_id text NOT NULL,
  source_hash text,
  expected_match text NOT NULL,
  expected_confidence text NOT NULL,
  expected_action_type text NOT NULL,
  label_source text NOT NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expected_match IN ('same_entity', 'different_entity', 'unclear')),
  CHECK (expected_confidence IN ('high', 'medium', 'low')),
  CHECK (label_source IN ('approved_action', 'rejected_action', 'manual_correction'))
);

CREATE INDEX eval_labels_subject_idx
ON otlet.eval_labels (source_table, subject_id, source_hash);

CREATE INDEX eval_labels_receipt_idx
ON otlet.eval_labels (receipt_id, action_id);

CREATE TABLE otlet.semantic_materializations (
  id bigserial PRIMARY KEY,
  record_id bigint NOT NULL UNIQUE REFERENCES otlet.records(id),
  record_type text NOT NULL,
  source_table text,
  subject_id text,
  task_name text NOT NULL,
  model_name text NOT NULL,
  body jsonb NOT NULL,
  stale boolean NOT NULL DEFAULT false,
  source_hash text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX semantic_materializations_lookup_idx
ON otlet.semantic_materializations (task_name, record_type, stale, subject_id);

CREATE INDEX semantic_materializations_source_idx
ON otlet.semantic_materializations (source_table, subject_id, task_name, record_type, stale);

CREATE TABLE otlet.semantic_indexes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name),
  source_table text NOT NULL,
  subject_column text NOT NULL,
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
