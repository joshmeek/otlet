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
  ('create_record', false, true, false),
  ('merge_candidate', true, false, false),
  ('new_entity', false, false, false),
  ('review_flag', false, false, false),
  ('note', false, true, false),
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

CREATE TABLE otlet.action_workflow_policies (
  task_name text NOT NULL REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  action_type text NOT NULL REFERENCES otlet.action_type_schemas(action_type),
  target_name text NOT NULL REFERENCES otlet.action_targets(name),
  subject_namespace text NOT NULL,
  authority_mode text NOT NULL DEFAULT 'recommendation_only',
  evaluation_status text NOT NULL DEFAULT 'unevaluated',
  task_contract_hash text NOT NULL,
  target_contract_hash text NOT NULL,
  policy_hash text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_name, action_type),
  CHECK (action_type = 'update_row'),
  CHECK (NULLIF(subject_namespace, '') IS NOT NULL),
  CHECK (authority_mode IN ('recommendation_only', 'bounded_mutation')),
  CHECK (evaluation_status IN ('unevaluated', 'evaluated', 'adversarial')),
  CHECK (task_contract_hash ~ '^[0-9a-f]{32}$'),
  CHECK (target_contract_hash ~ '^[0-9a-f]{32}$'),
  CHECK (policy_hash ~ '^[0-9a-f]{32}$')
);

CREATE TABLE otlet.actions (
  id bigserial PRIMARY KEY,
  job_id bigint NOT NULL REFERENCES otlet.jobs(id),
  output_id bigint REFERENCES otlet.outputs(id),
  receipt_id bigint REFERENCES otlet.inference_receipts(id),
  action_type text NOT NULL,
  authority_origin text NOT NULL,
  authority_mode text NOT NULL,
  evaluation_status text NOT NULL,
  authority_policy_hash text NOT NULL,
  subject_namespace text NOT NULL,
  target_name text REFERENCES otlet.action_targets(name),
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
  CHECK (authority_origin IN ('workflow', 'system')),
  CHECK (authority_mode IN ('recommendation_only', 'bounded_mutation')),
  CHECK (evaluation_status IN ('unevaluated', 'evaluated', 'adversarial')),
  CHECK (authority_policy_hash ~ '^[0-9a-f]{32}$'),
  CHECK (NULLIF(subject_namespace, '') IS NOT NULL),
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

CREATE TABLE otlet.review_events (
  id bigserial PRIMARY KEY,
  outcome text NOT NULL CHECK (outcome IN ('approve', 'reject', 'correct', 'defer', 'abstain')),
  reviewer_identity text NOT NULL CHECK (NULLIF(reviewer_identity, '') IS NOT NULL),
  reviewer_role text NOT NULL CHECK (NULLIF(reviewer_role, '') IS NOT NULL),
  reason text NOT NULL CHECK (NULLIF(reason, '') IS NOT NULL AND octet_length(reason) <= 8192),
  job_id bigint NOT NULL CHECK (job_id > 0),
  task_name text NOT NULL CHECK (NULLIF(task_name, '') IS NOT NULL),
  subject_id text NOT NULL,
  action_id bigint CHECK (action_id > 0),
  output_id bigint CHECK (output_id > 0),
  receipt_id bigint NOT NULL CHECK (receipt_id > 0),
  source_table text,
  source_hash text,
  content_hash text,
  current_content_hash text,
  source_freshness text NOT NULL CHECK (source_freshness IN ('fresh', 'stale', 'unavailable')),
  model_name text NOT NULL CHECK (NULLIF(model_name, '') IS NOT NULL),
  model_artifact_hash text NOT NULL CHECK (NULLIF(model_artifact_hash, '') IS NOT NULL),
  prompt_hash text,
  output_schema_hash text NOT NULL CHECK (NULLIF(output_schema_hash, '') IS NOT NULL),
  output_hash text NOT NULL CHECK (NULLIF(output_hash, '') IS NOT NULL),
  runtime_fingerprint_hash text,
  reviewed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX review_events_target_reviewed_idx
ON otlet.review_events (action_id, output_id, receipt_id, reviewed_at DESC, id DESC);

CREATE INDEX review_events_reviewer_reviewed_idx
ON otlet.review_events (reviewer_identity, reviewer_role, reviewed_at DESC, id DESC);

CREATE FUNCTION otlet.reject_review_event_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet review event history is immutable';
END;
$$;

CREATE TRIGGER review_events_immutable
BEFORE UPDATE OR DELETE ON otlet.review_events
FOR EACH ROW EXECUTE FUNCTION otlet.reject_review_event_change();

CREATE TRIGGER review_events_no_truncate
BEFORE TRUNCATE ON otlet.review_events
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_review_event_change();
