CREATE TABLE otlet.semantic_correction_overrides (
  correction_hash text PRIMARY KEY CHECK (
    correction_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  subject_id text NOT NULL CHECK (NULLIF(subject_id, '') IS NOT NULL),
  record_type text NOT NULL CHECK (NULLIF(record_type, '') IS NOT NULL),
  workload_revision_hash text NOT NULL,
  relevant_contract_hash text NOT NULL CHECK (
    relevant_contract_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  source_table text,
  source_hash text NOT NULL CHECK (
    source_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  content_hash text NOT NULL CHECK (
    content_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  materialization_id bigint NOT NULL CHECK (materialization_id > 0),
  correction_label_id bigint NOT NULL UNIQUE CHECK (correction_label_id > 0),
  review_event_id bigint NOT NULL UNIQUE CHECK (review_event_id > 0),
  original_action_id bigint NOT NULL CHECK (original_action_id > 0),
  original_output_id bigint NOT NULL CHECK (original_output_id > 0),
  original_receipt_id bigint NOT NULL CHECK (original_receipt_id > 0),
  original_body_hash text NOT NULL CHECK (
    original_body_hash ~ '^[0-9a-f]{64}$'
  ),
  original_output_hash text NOT NULL CHECK (
    NULLIF(original_output_hash, '') IS NOT NULL
  ),
  original_raw_output_hash text CHECK (
    original_raw_output_hash IS NULL
    OR NULLIF(original_raw_output_hash, '') IS NOT NULL
  ),
  corrected_body jsonb NOT NULL CHECK (
    jsonb_typeof(corrected_body) = 'object'
  ),
  corrected_body_hash text NOT NULL CHECK (
    corrected_body_hash ~ '^[0-9a-f]{64}$'
    AND corrected_body_hash = otlet.portable_json_hash(corrected_body)
  ),
  expected_answer text NOT NULL CHECK (NULLIF(expected_answer, '') IS NOT NULL),
  expected_confidence text NOT NULL CHECK (
    expected_confidence IN ('high', 'medium', 'low')
  ),
  expected_action_type text NOT NULL CHECK (
    NULLIF(expected_action_type, '') IS NOT NULL
  ),
  correction_author_identity text NOT NULL CHECK (
    NULLIF(correction_author_identity, '') IS NOT NULL
  ),
  correction_author_role text NOT NULL CHECK (
    NULLIF(correction_author_role, '') IS NOT NULL
  ),
  correction_reason text NOT NULL CHECK (
    NULLIF(btrim(correction_reason), '') IS NOT NULL
    AND octet_length(correction_reason) <= 8192
  ),
  approver_identity text NOT NULL CHECK (
    NULLIF(approver_identity, '') IS NOT NULL
  ),
  approver_role text NOT NULL CHECK (
    NULLIF(approver_role, '') IS NOT NULL
  ),
  approval_confidence numeric NOT NULL CHECK (
    approval_confidence <> 'NaN'::numeric
    AND approval_confidence BETWEEN 0 AND 1
  ),
  approval_reason text NOT NULL CHECK (
    NULLIF(btrim(approval_reason), '') IS NOT NULL
    AND octet_length(approval_reason) <= 4096
  ),
  expires_at timestamptz NOT NULL CHECK (
    isfinite(expires_at)
    AND expires_at > created_at
  ),
  supersedes_correction_hash text REFERENCES
    otlet.semantic_correction_overrides(correction_hash),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (supersedes_correction_hash IS DISTINCT FROM correction_hash)
);

CREATE UNIQUE INDEX semantic_correction_overrides_root_idx
ON otlet.semantic_correction_overrides (task_name, record_type, subject_id)
WHERE supersedes_correction_hash IS NULL;

CREATE UNIQUE INDEX semantic_correction_overrides_successor_idx
ON otlet.semantic_correction_overrides (supersedes_correction_hash)
WHERE supersedes_correction_hash IS NOT NULL;

CREATE INDEX semantic_correction_overrides_current_idx
ON otlet.semantic_correction_overrides (
  task_name,
  record_type,
  subject_id,
  created_at DESC
);

CREATE FUNCTION otlet.semantic_correction_override_hash(
  correction otlet.semantic_correction_overrides
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT otlet.identity_hash(
    'semantic_correction',
    (to_jsonb($1) - ARRAY[
      'correction_hash',
      'expires_at',
      'created_at'
    ]) || jsonb_build_object(
      'expires_at', extract(epoch FROM ($1).expires_at),
      'created_at', extract(epoch FROM ($1).created_at)
    )
  );
$$;

ALTER TABLE otlet.semantic_correction_overrides
ADD CONSTRAINT semantic_correction_overrides_hash_check CHECK (
  correction_hash = otlet.semantic_correction_override_hash(
    semantic_correction_overrides.*
  )
);

CREATE FUNCTION otlet.reject_semantic_correction_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet semantic correction history is immutable';
END;
$$;

CREATE TRIGGER semantic_correction_overrides_change_guard
BEFORE UPDATE OR DELETE ON otlet.semantic_correction_overrides
FOR EACH ROW EXECUTE FUNCTION otlet.reject_semantic_correction_change();

CREATE TRIGGER semantic_correction_overrides_truncate_guard
BEFORE TRUNCATE ON otlet.semantic_correction_overrides
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_semantic_correction_change();

CREATE FUNCTION otlet.approve_semantic_correction(
  label_id bigint,
  review_event_id bigint,
  corrected_body jsonb,
  expires_at timestamptz,
  label_confidence numeric,
  reason text,
  supersedes_correction_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target record;
  original_materialization record;
  predecessor otlet.semantic_correction_overrides%ROWTYPE;
  existing otlet.semantic_correction_overrides%ROWTYPE;
  saved otlet.semantic_correction_overrides%ROWTYPE;
  current_input jsonb;
  current_source_hash text;
  current_content_hash text;
  approved_relevant_contract_hash text;
  answer_field text;
  confidence_field text;
  validation_error text;
  predecessor_label_id bigint;
  max_structured_output_bytes bigint;
  approved_at timestamptz;
BEGIN
  IF approve_semantic_correction.label_id IS NULL
     OR approve_semantic_correction.review_event_id IS NULL
     OR jsonb_typeof(COALESCE(
       approve_semantic_correction.corrected_body,
       'null'::jsonb
     )) IS DISTINCT FROM 'object'
     OR approve_semantic_correction.expires_at IS NULL
     OR NOT isfinite(approve_semantic_correction.expires_at)
     OR approve_semantic_correction.label_confidence IS NULL
     OR approve_semantic_correction.label_confidence = 'NaN'::numeric
     OR approve_semantic_correction.label_confidence NOT BETWEEN 0 AND 1
     OR NULLIF(btrim(approve_semantic_correction.reason), '') IS NULL
     OR octet_length(approve_semantic_correction.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet semantic correction approval is invalid';
  END IF;

  PERFORM otlet.lock_eval_label_series(
    ARRAY[approve_semantic_correction.label_id]
  );
  SELECT *
  INTO existing
  FROM otlet.semantic_correction_overrides correction
  WHERE correction.correction_label_id =
    approve_semantic_correction.label_id;
  IF FOUND THEN
    IF existing.review_event_id = approve_semantic_correction.review_event_id
       AND existing.corrected_body = approve_semantic_correction.corrected_body
       AND existing.expires_at = approve_semantic_correction.expires_at
       AND existing.approval_confidence =
         approve_semantic_correction.label_confidence
       AND existing.approval_reason =
         btrim(approve_semantic_correction.reason)
       AND existing.supersedes_correction_hash IS NOT DISTINCT FROM
         approve_semantic_correction.supersedes_correction_hash THEN
      RETURN existing.correction_hash;
    END IF;
    RAISE EXCEPTION 'otlet semantic correction approval conflicts with the stored decision';
  END IF;
  IF approve_semantic_correction.expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'otlet semantic correction approval is invalid';
  END IF;

  SELECT
    label.id AS label_id,
    label.action_id,
    label.output_id,
    label.receipt_id,
    label.task_name,
    label.subject_id,
    label.source_table,
    label.source_hash,
    label.content_hash,
    label.workload_revision_hash,
    label.label_source,
    label.expected_answer,
    label.expected_confidence,
    label.expected_action_type,
    label.reason AS label_reason,
    label.authenticated_role_name AS label_author_identity,
    label.active_role_name AS label_author_role,
    label.adjudication_state,
    event.outcome AS review_outcome,
    event.reviewer_identity,
    event.reviewer_role,
    event.reason AS review_reason,
    event.source_hash AS review_source_hash,
    event.content_hash AS review_content_hash,
    event.current_content_hash AS review_current_content_hash,
    event.source_freshness AS review_source_freshness,
    task.lifecycle_state,
    head.active_workload_revision_hash,
    active_revision.definition AS active_definition,
    label_revision.definition AS label_definition,
    output.output AS original_output,
    receipt.output_hash AS receipt_output_hash,
    receipt.raw_output_hash AS receipt_raw_output_hash
  INTO target
  FROM otlet.eval_labels label
  JOIN otlet.actions action ON action.id = label.action_id
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.outputs output ON output.id = label.output_id
  JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
  JOIN otlet.review_events event
    ON event.id = approve_semantic_correction.review_event_id
  JOIN otlet.tasks task ON task.name = label.task_name
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  JOIN otlet.workload_revisions active_revision
    ON active_revision.task_name = head.task_name
   AND active_revision.workload_revision_hash =
     head.active_workload_revision_hash
  JOIN otlet.workload_revisions label_revision
    ON label_revision.task_name = label.task_name
   AND label_revision.workload_revision_hash =
     label.workload_revision_hash
  WHERE label.id = approve_semantic_correction.label_id
    AND job.task_name = label.task_name
    AND job.subject_id = label.subject_id
    AND job.workload_revision_hash = label.workload_revision_hash
    AND output.receipt_id = label.receipt_id
    AND receipt.job_id = job.id
    AND event.action_id = label.action_id
    AND event.output_id = label.output_id
    AND event.receipt_id = label.receipt_id
    AND event.task_name = label.task_name
    AND event.subject_id = label.subject_id
  FOR UPDATE OF head;

  IF NOT FOUND
     OR target.label_source <> 'manual_correction'
     OR target.review_outcome <> 'correct'
     OR target.review_source_freshness <> 'fresh'
     OR target.review_source_hash IS DISTINCT FROM target.source_hash
     OR target.review_content_hash IS DISTINCT FROM target.content_hash
     OR target.review_current_content_hash IS DISTINCT FROM
       target.content_hash
     OR target.reviewer_identity <> target.label_author_identity
     OR target.reviewer_role <> target.label_author_role THEN
    RAISE EXCEPTION 'otlet semantic correction evidence is invalid';
  END IF;

  IF target.lifecycle_state <> 'active' THEN
    RAISE EXCEPTION 'otlet semantic correction task is not active';
  END IF;

  approved_relevant_contract_hash := otlet.pair_constraint_contract_hash(
    target.active_definition
  );
  IF approved_relevant_contract_hash IS DISTINCT FROM
       otlet.pair_constraint_contract_hash(target.label_definition) THEN
    RAISE EXCEPTION 'otlet semantic correction contract requires re-review';
  END IF;

  current_input := otlet.pair_constraint_current_input(
    target.task_name,
    target.subject_id,
    target.active_workload_revision_hash
  );
  IF current_input IS NULL THEN
    RAISE EXCEPTION 'otlet semantic correction source is unavailable';
  END IF;
  current_source_hash := otlet.semantic_source_hash(current_input);
  current_content_hash := otlet.semantic_content_hash(
    current_input,
    target.active_definition #> '{task,input_shaping}'
  );
  IF current_source_hash IS DISTINCT FROM target.source_hash
     OR current_content_hash IS DISTINCT FROM target.content_hash THEN
    RAISE EXCEPTION 'otlet semantic correction source requires re-review';
  END IF;

  SELECT
    materialization.id,
    materialization.body,
    materialization.stale,
    materialization.stale_reason
  INTO original_materialization
  FROM otlet.semantic_materializations materialization
  JOIN otlet.records record ON record.id = materialization.record_id
  JOIN otlet.actions record_action ON record_action.id = record.action_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = materialization.task_name
   AND revision.workload_revision_hash = materialization.contract_hash
  WHERE materialization.task_name = target.task_name
    AND materialization.record_type =
      target.active_definition #>> '{source,record_type}'
    AND materialization.subject_id = target.subject_id
    AND materialization.source_hash = target.source_hash
    AND materialization.content_hash = target.content_hash
    AND record_action.output_id = target.output_id
    AND record_action.receipt_id = target.receipt_id
    AND otlet.pair_constraint_contract_hash(revision.definition) =
      approved_relevant_contract_hash
  ORDER BY materialization.updated_at DESC, materialization.id DESC
  LIMIT 1;

  IF NOT FOUND
     OR original_materialization.body IS DISTINCT FROM target.original_output
     OR (
       original_materialization.stale
       AND original_materialization.stale_reason NOT IN (
         'source_update',
         'pair_constraint_conflict'
       )
     ) THEN
    RAISE EXCEPTION 'otlet semantic correction original materialization is unavailable';
  END IF;

  SELECT policy.max_structured_output_bytes
  INTO STRICT max_structured_output_bytes
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';
  IF octet_length(approve_semantic_correction.corrected_body::text) >
       max_structured_output_bytes THEN
    RAISE EXCEPTION 'otlet semantic correction exceeds evidence byte limit';
  END IF;

  validation_error := otlet.json_schema_validation_error(
    target.active_definition #> '{task,output_schema}',
    approve_semantic_correction.corrected_body
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet semantic correction output is invalid: %',
      validation_error;
  END IF;

  answer_field := COALESCE(
    NULLIF(
      target.active_definition #>> '{task,decision_contract,answer_field}',
      ''
    ),
    'match'
  );
  confidence_field := COALESCE(
    NULLIF(
      target.active_definition #>>
        '{task,decision_contract,confidence_field}',
      ''
    ),
    'confidence'
  );
  IF approve_semantic_correction.corrected_body ->> answer_field IS DISTINCT FROM
       target.expected_answer
     OR approve_semantic_correction.corrected_body ->> confidence_field IS DISTINCT FROM
       target.expected_confidence
     OR approve_semantic_correction.corrected_body = target.original_output THEN
    RAISE EXCEPTION 'otlet semantic correction does not match the approved label';
  END IF;

  SELECT correction.*
  INTO predecessor
  FROM otlet.semantic_correction_overrides correction
  WHERE correction.task_name = target.task_name
    AND correction.record_type =
      target.active_definition #>> '{source,record_type}'
    AND correction.subject_id = target.subject_id
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.semantic_correction_overrides successor
      WHERE successor.supersedes_correction_hash =
        correction.correction_hash
    )
  ORDER BY correction.created_at DESC, correction.correction_hash
  LIMIT 1;

  IF FOUND THEN
    IF predecessor.correction_hash IS DISTINCT FROM
         approve_semantic_correction.supersedes_correction_hash THEN
      RAISE EXCEPTION 'otlet semantic correction predecessor is invalid';
    END IF;
    SELECT label.id
    INTO predecessor_label_id
    FROM otlet.eval_labels label
    WHERE label.id = predecessor.correction_label_id;
  ELSIF approve_semantic_correction.supersedes_correction_hash IS NOT NULL THEN
    RAISE EXCEPTION 'otlet semantic correction predecessor is invalid';
  END IF;

  IF target.active_definition #>> '{source,kind}' = 'pair' THEN
    PERFORM otlet.require_entity_graph_clear(
      target.task_name,
      'semantic correction approval'
    );
  END IF;

  PERFORM otlet.adjudicate_eval_label(
    target.label_id,
    'accepted',
    approve_semantic_correction.label_confidence,
    btrim(approve_semantic_correction.reason),
    predecessor_label_id
  );
  SELECT
    label.adjudicated_authenticated_role_name,
    label.adjudicated_active_role_name,
    label.adjudicated_at
  INTO
    saved.approver_identity,
    saved.approver_role,
    approved_at
  FROM otlet.eval_labels label
  WHERE label.id = target.label_id;
  IF approved_at IS NULL
     OR approve_semantic_correction.expires_at <= approved_at THEN
    RAISE EXCEPTION 'otlet semantic correction approval is invalid';
  END IF;

  saved.task_name := target.task_name;
  saved.subject_id := target.subject_id;
  saved.record_type := target.active_definition #>> '{source,record_type}';
  saved.workload_revision_hash := target.workload_revision_hash;
  saved.relevant_contract_hash := approved_relevant_contract_hash;
  saved.source_table := target.source_table;
  saved.source_hash := target.source_hash;
  saved.content_hash := target.content_hash;
  saved.materialization_id := original_materialization.id;
  saved.correction_label_id := target.label_id;
  saved.review_event_id := approve_semantic_correction.review_event_id;
  saved.original_action_id := target.action_id;
  saved.original_output_id := target.output_id;
  saved.original_receipt_id := target.receipt_id;
  saved.original_body_hash := otlet.portable_json_hash(
    original_materialization.body
  );
  saved.original_output_hash := target.receipt_output_hash;
  saved.original_raw_output_hash := target.receipt_raw_output_hash;
  saved.corrected_body := approve_semantic_correction.corrected_body;
  saved.corrected_body_hash := otlet.portable_json_hash(
    approve_semantic_correction.corrected_body
  );
  saved.expected_answer := target.expected_answer;
  saved.expected_confidence := target.expected_confidence;
  saved.expected_action_type := target.expected_action_type;
  saved.correction_author_identity := target.reviewer_identity;
  saved.correction_author_role := target.reviewer_role;
  saved.correction_reason := target.review_reason;
  saved.approval_confidence := approve_semantic_correction.label_confidence;
  saved.approval_reason := btrim(approve_semantic_correction.reason);
  saved.expires_at := approve_semantic_correction.expires_at;
  saved.supersedes_correction_hash :=
    approve_semantic_correction.supersedes_correction_hash;
  saved.created_at := approved_at;
  saved.correction_hash := otlet.semantic_correction_override_hash(saved);

  INSERT INTO otlet.semantic_correction_overrides
  SELECT (saved).*;

  RETURN saved.correction_hash;
END;
$$;

CREATE FUNCTION otlet.semantic_correction_status_for_task(
  target_task_name text
) RETURNS TABLE (
  correction_hash text,
  correction_status text,
  task_name text,
  active_workload_revision_hash text,
  workload_revision_hash text,
  relevant_contract_hash text,
  current_relevant_contract_hash text,
  record_type text,
  subject_id text,
  source_table text,
  source_hash text,
  content_hash text,
  current_source_hash text,
  current_content_hash text,
  materialization_id bigint,
  correction_label_id bigint,
  review_event_id bigint,
  original_action_id bigint,
  original_output_id bigint,
  original_receipt_id bigint,
  original_body_hash text,
  original_output_hash text,
  original_raw_output_hash text,
  corrected_body_hash text,
  expected_answer text,
  expected_confidence text,
  expected_action_type text,
  correction_author_identity text,
  correction_author_role text,
  correction_reason text,
  approver_identity text,
  approver_role text,
  approval_confidence numeric,
  approval_reason text,
  expires_at timestamptz,
  supersedes_correction_hash text,
  superseded_by_correction_hash text,
  created_at timestamptz
)
LANGUAGE sql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH current_state AS (
    SELECT
      correction.*,
      successor.correction_hash AS superseded_by_correction_hash,
      task.lifecycle_state,
      head.active_workload_revision_hash,
      materialization.id IS NULL AS materialization_missing,
      materialization.stale AS materialization_stale,
      materialization.stale_reason AS materialization_stale_reason,
      active_revision.definition AS active_definition,
      otlet.pair_constraint_contract_hash(active_revision.definition)
        AS current_relevant_contract_hash,
      current_input.input
    FROM otlet.semantic_correction_overrides correction
    JOIN otlet.tasks task ON task.name = correction.task_name
    LEFT JOIN otlet.semantic_correction_overrides successor
      ON successor.supersedes_correction_hash = correction.correction_hash
    LEFT JOIN otlet.workload_revision_heads head
      ON head.task_name = correction.task_name
    LEFT JOIN otlet.semantic_materializations materialization
      ON materialization.id = correction.materialization_id
    LEFT JOIN otlet.workload_revisions active_revision
      ON active_revision.task_name = head.task_name
     AND active_revision.workload_revision_hash =
       head.active_workload_revision_hash
    LEFT JOIN LATERAL (
      SELECT otlet.pair_constraint_current_input(
        correction.task_name,
        correction.subject_id,
        head.active_workload_revision_hash
      ) AS input
    ) current_input ON head.active_workload_revision_hash IS NOT NULL
    WHERE correction.task_name = $1
  ), evaluated AS (
    SELECT
      state.*,
      CASE WHEN state.input IS NULL THEN NULL
        ELSE otlet.semantic_source_hash(state.input)
      END AS current_source_hash,
      CASE WHEN state.input IS NULL THEN NULL
        ELSE otlet.semantic_content_hash(
          state.input,
          state.active_definition #> '{task,input_shaping}'
        )
      END AS current_content_hash,
      EXISTS (
        SELECT 1
        FROM otlet.pair_constraint_facts fact
        WHERE fact.task_name = state.task_name
          AND fact.subject_id = state.subject_id
          AND fact.source_hash = state.source_hash
          AND fact.content_hash = state.content_hash
          AND fact.relevant_contract_hash = state.relevant_contract_hash
          AND fact.relation <> CASE state.expected_answer
            WHEN 'same_entity' THEN 'must_link'
            WHEN 'different_entity' THEN 'cannot_link'
            ELSE NULL
          END
      ) AS pair_constraint_conflict
    FROM current_state state
  )
  SELECT
    evaluated.correction_hash,
    CASE
      WHEN evaluated.superseded_by_correction_hash IS NOT NULL
        THEN 'superseded'
      WHEN evaluated.lifecycle_state <> 'active'
        OR evaluated.active_workload_revision_hash IS NULL
        THEN 'task_inactive'
      WHEN evaluated.expires_at <= statement_timestamp()
        THEN 'expired'
      WHEN evaluated.current_relevant_contract_hash IS DISTINCT FROM
        evaluated.relevant_contract_hash
        AND (
          (
            evaluated.materialization_missing
            OR evaluated.materialization_stale
            AND evaluated.materialization_stale_reason = 'source_update'
          )
          OR evaluated.current_source_hash IS DISTINCT FROM evaluated.source_hash
          OR evaluated.current_content_hash IS DISTINCT FROM
            evaluated.content_hash
        ) THEN 'reopened_source_and_contract'
      WHEN evaluated.current_relevant_contract_hash IS DISTINCT FROM
        evaluated.relevant_contract_hash THEN 'reopened_contract'
      WHEN (
          evaluated.materialization_missing
          OR evaluated.materialization_stale
          AND evaluated.materialization_stale_reason = 'source_update'
        )
        OR evaluated.current_source_hash IS DISTINCT FROM evaluated.source_hash
        OR evaluated.current_content_hash IS DISTINCT FROM
          evaluated.content_hash THEN 'reopened_source'
      WHEN evaluated.pair_constraint_conflict
        THEN 'reopened_pair_constraint'
      ELSE 'active'
    END,
    evaluated.task_name,
    evaluated.active_workload_revision_hash,
    evaluated.workload_revision_hash,
    evaluated.relevant_contract_hash,
    evaluated.current_relevant_contract_hash,
    evaluated.record_type,
    evaluated.subject_id,
    evaluated.source_table,
    evaluated.source_hash,
    evaluated.content_hash,
    evaluated.current_source_hash,
    evaluated.current_content_hash,
    evaluated.materialization_id,
    evaluated.correction_label_id,
    evaluated.review_event_id,
    evaluated.original_action_id,
    evaluated.original_output_id,
    evaluated.original_receipt_id,
    evaluated.original_body_hash,
    evaluated.original_output_hash,
    evaluated.original_raw_output_hash,
    evaluated.corrected_body_hash,
    evaluated.expected_answer,
    evaluated.expected_confidence,
    evaluated.expected_action_type,
    evaluated.correction_author_identity,
    evaluated.correction_author_role,
    evaluated.correction_reason,
    evaluated.approver_identity,
    evaluated.approver_role,
    evaluated.approval_confidence,
    evaluated.approval_reason,
    evaluated.expires_at,
    evaluated.supersedes_correction_hash,
    evaluated.superseded_by_correction_hash,
    evaluated.created_at
  FROM evaluated
  ORDER BY evaluated.created_at, evaluated.correction_hash;
$$;

CREATE VIEW otlet.semantic_correction_status AS
SELECT status.*
FROM (
  SELECT DISTINCT correction.task_name
  FROM otlet.semantic_correction_overrides correction
) task
CROSS JOIN LATERAL otlet.semantic_correction_status_for_task(
  task.task_name
) status;

CREATE VIEW otlet.semantic_materializations_effective AS
WITH classified AS (
  SELECT
    materialization.*,
    correction.correction_hash,
    correction.corrected_body,
    correction.created_at AS correction_created_at,
    task.lifecycle_state = 'active'
      AND correction.expires_at > statement_timestamp()
      AND correction.source_hash = materialization.source_hash
      AND correction.content_hash = materialization.content_hash
      AND correction.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision.definition)
      AND (
        NOT materialization.stale
        OR materialization.stale_reason = 'pair_constraint_conflict'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.pair_constraint_facts fact
        WHERE fact.task_name = materialization.task_name
          AND fact.subject_id = materialization.subject_id
          AND fact.source_hash = correction.source_hash
          AND fact.content_hash = correction.content_hash
          AND fact.relevant_contract_hash =
            correction.relevant_contract_hash
          AND fact.relation <> CASE correction.expected_answer
            WHEN 'same_entity' THEN 'must_link'
            WHEN 'different_entity' THEN 'cannot_link'
            ELSE NULL
          END
      ) AS correction_applies
  FROM otlet.semantic_materializations materialization
  JOIN otlet.tasks task ON task.name = materialization.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = materialization.task_name
   AND revision.workload_revision_hash = materialization.contract_hash
  LEFT JOIN LATERAL (
    SELECT candidate.*
    FROM otlet.semantic_correction_overrides candidate
    WHERE candidate.task_name = materialization.task_name
      AND candidate.record_type = materialization.record_type
      AND candidate.subject_id = materialization.subject_id
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_correction_overrides successor
        WHERE successor.supersedes_correction_hash =
          candidate.correction_hash
      )
    ORDER BY candidate.created_at DESC, candidate.correction_hash
    LIMIT 1
  ) correction ON true
)
SELECT
  classified.id,
  classified.record_id,
  classified.record_type,
  classified.source_table,
  classified.subject_id,
  classified.source_dependencies,
  classified.task_name,
  classified.model_name,
  CASE WHEN classified.correction_hash IS NULL
    THEN classified.body
    ELSE classified.corrected_body
  END AS body,
  CASE
    WHEN classified.correction_hash IS NULL THEN classified.stale
    WHEN NOT classified.correction_applies THEN true
    WHEN classified.stale_reason = 'source_update' THEN true
    ELSE false
  END AS stale,
  classified.source_hash,
  classified.content_hash,
  classified.contract_hash,
  CASE
    WHEN classified.correction_hash IS NULL THEN classified.stale_reason
    WHEN NOT classified.correction_applies
      THEN 'semantic_correction_re_review'
    ELSE 'semantic_correction'
  END AS stale_reason,
  CASE
    WHEN classified.correction_hash IS NULL THEN classified.freshness_basis
    WHEN classified.correction_applies THEN 'manual_correction'
    ELSE NULL
  END AS freshness_basis,
  classified.created_at,
  CASE WHEN classified.correction_hash IS NULL
    THEN classified.updated_at
    ELSE GREATEST(classified.updated_at, classified.correction_created_at)
  END AS updated_at,
  classified.correction_hash,
  CASE
    WHEN classified.correction_hash IS NULL THEN NULL
    WHEN classified.correction_applies THEN 'applied'
    ELSE 're_review'
  END AS correction_status
FROM classified;

CREATE OR REPLACE FUNCTION otlet.semantic_freshness_status(
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
    SELECT CASE
      WHEN material_stale_reason = 'semantic_correction' THEN
        NOT COALESCE(material_stale, false)
        AND material_content_hash IS NOT DISTINCT FROM current_content_hash
        AND material_contract_hash IS NOT DISTINCT FROM current_contract_hash
        AND material_source_hash IS NOT DISTINCT FROM current_source_hash
      ELSE
        material_content_hash IS NOT DISTINCT FROM current_content_hash
        AND material_contract_hash IS NOT DISTINCT FROM current_contract_hash
        AND (
          NOT COALESCE(material_stale, false)
          OR material_stale_reason = 'source_update'
        )
    END AS fresh
  )
  SELECT
    fresh AS is_fresh,
    NOT fresh AS is_stale,
    CASE
      WHEN fresh THEN NULL::text
      WHEN material_contract_hash IS DISTINCT FROM current_contract_hash
        THEN 'contract_changed'
      ELSE COALESCE(
        material_stale_reason,
        'content_revalidation_pending'
      )
    END AS stale_reason,
    CASE
      WHEN NOT fresh THEN NULL::text
      WHEN material_stale_reason = 'semantic_correction'
        THEN 'manual_correction'
      WHEN COALESCE(material_stale, false)
        THEN 'revalidated_after_benign_update'
      WHEN material_source_hash IS NOT DISTINCT FROM current_source_hash
        THEN 'mvcc_match'
      ELSE 'content_hash_match'
    END AS freshness_basis
  FROM classified;
$$;

DO $$
DECLARE
  target regprocedure;
  definition text;
BEGIN
  FOREACH target IN ARRAY ARRAY[
    'otlet.semantic_index_current_rows(text,boolean,text)'::regprocedure,
    'otlet.semantic_join_index_current_rows(text,boolean,text)'::regprocedure,
    'otlet.semantic_join_matches(text,text,jsonb)'::regprocedure,
    'otlet.semantic_matches(text,text,jsonb)'::regprocedure,
    'otlet.semantic_join_index_plan(text,boolean,text)'::regprocedure,
    'otlet.semantic_index_plan(text,boolean,text)'::regprocedure
  ]
  LOOP
    definition := pg_get_functiondef(target);
    IF position('otlet.semantic_materializations' IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet semantic correction reader rewrite is incomplete for %',
        target;
    END IF;
    EXECUTE replace(
      definition,
      'otlet.semantic_materializations',
      'otlet.semantic_materializations_effective'
    );
  END LOOP;
END;
$$;

ALTER VIEW otlet.review_queue
RENAME TO review_queue_without_semantic_corrections;

CREATE VIEW otlet.review_queue AS
SELECT queue.*
FROM otlet.review_queue_without_semantic_corrections queue
UNION ALL
SELECT
  'semantic_correction_re_review'::text,
  're_review_semantic_correction'::text,
  correction.task_name,
  correction.active_workload_revision_hash,
  COALESCE(
    revision.definition #>> '{source,watch_name}',
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{source,semantic_join_index_name}'
  ),
  correction.subject_id,
  correction.subject_id,
  correction.original_action_id,
  correction.original_output_id,
  correction.original_receipt_id,
  correction.expected_action_type,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::text,
  concat_ws(
    ': ',
    correction.correction_status,
    correction.approval_reason
  ),
  jsonb_strip_nulls(jsonb_build_object(
    'correction_hash', correction.correction_hash,
    'correction_status', correction.correction_status,
    'corrected_body_hash', correction.corrected_body_hash,
    'expires_at', correction.expires_at,
    'supersedes_correction_hash',
      correction.supersedes_correction_hash,
    'correction_label_id', correction.correction_label_id,
    'review_event_id', correction.review_event_id,
    'correction_author_identity',
      correction.correction_author_identity,
    'correction_author_role', correction.correction_author_role,
    'approver_identity', correction.approver_identity,
    'approver_role', correction.approver_role
  )),
  correction.source_table,
  correction.source_hash,
  correction.content_hash,
  correction.current_content_hash,
  true,
  correction.created_at
FROM otlet.semantic_correction_status correction
LEFT JOIN otlet.workload_revisions revision
  ON revision.task_name = correction.task_name
 AND revision.workload_revision_hash =
   correction.active_workload_revision_hash
WHERE correction.correction_status NOT IN ('active', 'superseded')
ORDER BY created_at, task_name, job_subject_id, queue_kind;

CREATE OR REPLACE VIEW otlet.audit_review_export AS
SELECT
  q.queue_kind,
  q.next_operator_step,
  q.task_name,
  q.workload_revision_hash,
  q.watch_name,
  q.job_subject_id,
  q.subject_id,
  q.action_id,
  q.output_id,
  q.receipt_id,
  q.action_type,
  a.authority_origin,
  a.authority_mode,
  a.evaluation_status,
  a.authority_policy_hash,
  a.subject_namespace,
  a.target_name,
  q.action_status,
  q.approval_status,
  q.dry_run_status,
  q.apply_status,
  otlet.identity_text_hash(
    'audit_idempotency_key',
    q.idempotency_key
  ) AS idempotency_key_hash,
  q.execution_receipt_id,
  q.execution_mode,
  q.execution_status,
  q.execution_affected_rows,
  q.execution_before_hash,
  q.execution_result_hash,
  q.execution_error,
  q.review_reason,
  q.source_table,
  q.source_hash,
  q.content_hash,
  q.current_content_hash,
  q.source_stale,
  q.created_at,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'conflict_hash'
  END AS entity_graph_conflict_hash,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'conflict_status'
  END AS entity_graph_conflict_status,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'cannot_fact_hash'
  END AS entity_graph_cannot_fact_hash,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'left_id'
  END AS entity_graph_left_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'right_id'
  END AS entity_graph_right_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN (q.output ->> 'review_event_id')::bigint
  END AS entity_graph_review_event_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'reviewer_identity'
  END AS entity_graph_reviewer_identity,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'reviewer_role'
  END AS entity_graph_reviewer_role,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'correction_hash'
  END AS semantic_correction_hash,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'correction_status'
  END AS semantic_correction_status,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'corrected_body_hash'
  END AS semantic_corrected_body_hash,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN (q.output ->> 'expires_at')::timestamptz
  END AS semantic_correction_expires_at,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'supersedes_correction_hash'
  END AS semantic_supersedes_correction_hash,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN (q.output ->> 'correction_label_id')::bigint
  END AS semantic_correction_label_id,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN (q.output ->> 'review_event_id')::bigint
  END AS semantic_correction_review_event_id,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'correction_author_identity'
  END AS semantic_correction_author_identity,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'correction_author_role'
  END AS semantic_correction_author_role,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'approver_identity'
  END AS semantic_correction_approver_identity,
  CASE WHEN q.queue_kind = 'semantic_correction_re_review'
    THEN q.output ->> 'approver_role'
  END AS semantic_correction_approver_role
FROM otlet.review_queue q
LEFT JOIN otlet.actions a ON a.id = q.action_id;

CREATE VIEW otlet.audit_semantic_correction_export AS
SELECT
  status.correction_hash,
  status.correction_status,
  status.task_name,
  status.active_workload_revision_hash,
  status.workload_revision_hash,
  status.relevant_contract_hash,
  status.current_relevant_contract_hash,
  status.record_type,
  status.subject_id,
  status.source_table,
  status.source_hash,
  status.content_hash,
  status.current_source_hash,
  status.current_content_hash,
  status.materialization_id,
  status.correction_label_id,
  status.review_event_id,
  status.original_action_id,
  status.original_output_id,
  status.original_receipt_id,
  status.original_body_hash,
  status.original_output_hash,
  status.original_raw_output_hash,
  status.corrected_body_hash,
  status.expected_answer,
  status.expected_confidence,
  status.expected_action_type,
  status.correction_author_identity,
  status.correction_author_role,
  status.correction_reason,
  status.approver_identity,
  status.approver_role,
  status.approval_confidence,
  status.approval_reason,
  status.expires_at,
  status.supersedes_correction_hash,
  status.superseded_by_correction_hash,
  status.created_at
FROM otlet.semantic_correction_status status;

DO $$
DECLARE
  definition text;
BEGIN
  definition := pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  IF position(
    '''otlet.audit_administrative_change_export''::text' IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet redaction export registry rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS ' ||
    replace(
      definition,
      '''otlet.audit_administrative_change_export''::text',
      '''otlet.audit_semantic_correction_export''::text, '
        || '''otlet.audit_administrative_change_export''::text'
    );
END;
$$;

CREATE OR REPLACE VIEW otlet.access_policy_status AS
WITH operator_functions(oid) AS (
  SELECT unnest(ARRAY[
    'otlet.approve_action(bigint,text)'::regprocedure::oid,
    'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
    'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure::oid,
    'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid,
    'otlet.defer_action(bigint,text)'::regprocedure::oid,
    'otlet.abstain_review(bigint,text)'::regprocedure::oid,
    'otlet.dry_run_action(bigint)'::regprocedure::oid,
    'otlet.apply_action(bigint)'::regprocedure::oid,
    'otlet.application_retry_job(bigint,text)'::regprocedure::oid,
    'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'::regprocedure::oid
  ])
),
operator_status AS (
  SELECT
    count(*)::bigint AS function_count,
    count(*) FILTER (WHERE function.prosecdef)::bigint
      AS security_definer_count,
    count(*) FILTER (
      WHERE function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
    )::bigint AS fixed_search_path_count
  FROM operator_functions expected
  JOIN pg_catalog.pg_proc function ON function.oid = expected.oid
),
portable_status AS (
  SELECT
    count(*)::bigint AS function_count,
    count(*) FILTER (WHERE function.prosecdef)::bigint
      AS security_definer_count,
    count(*) FILTER (
      WHERE function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
    )::bigint AS fixed_search_path_count
  FROM pg_catalog.pg_proc function
  JOIN pg_catalog.pg_namespace namespace
    ON namespace.oid = function.pronamespace
  WHERE namespace.nspname = 'otlet'
    AND function.proname IN (
      'portable_start_worker',
      'portable_claim_jobs',
      'portable_renew_job',
      'portable_record_attempt',
      'portable_complete_job',
      'portable_fail_job',
      'portable_cancel_job',
      'portable_worker_heartbeat'
    )
)
SELECT
  'owner_granted_roles'::text AS policy_name,
  1::integer AS policy_version,
  pg_catalog.has_schema_privilege('public', 'otlet', 'USAGE')
    AS public_schema_usage,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND pg_catalog.has_function_privilege(
        'public',
        function.oid,
        'EXECUTE'
      )
  ) AS public_executable_functions,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND (
        pg_catalog.has_table_privilege(
          'public', relation.oid, 'SELECT'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'INSERT'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'UPDATE'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'DELETE'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'TRUNCATE'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'REFERENCES'
        )
        OR pg_catalog.has_table_privilege(
          'public', relation.oid, 'TRIGGER'
        )
      )
  ) AS public_table_privileges,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relkind = 'S'
      AND (
        pg_catalog.has_sequence_privilege(
          'public', relation.oid, 'USAGE'
        )
        OR pg_catalog.has_sequence_privilege(
          'public', relation.oid, 'SELECT'
        )
        OR pg_catalog.has_sequence_privilege(
          'public', relation.oid, 'UPDATE'
        )
      )
  ) AS public_sequence_privileges,
  operator_status.function_count AS operator_functions,
  operator_status.security_definer_count
    AS operator_security_definer_functions,
  operator_status.fixed_search_path_count
    AS operator_fixed_search_path_functions,
  portable_status.function_count AS portable_rpc_functions,
  portable_status.security_definer_count
    AS portable_rpc_security_definer_functions,
  portable_status.fixed_search_path_count
    AS portable_rpc_fixed_search_path_functions
FROM operator_status
CROSS JOIN portable_status;

CREATE OR REPLACE FUNCTION otlet.finish_access_policy_grant(
  policy_name text,
  target_role regrole,
  old_revision_hash text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  new_revision_hash text;
BEGIN
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = finish_access_policy_grant.target_role::oid;

  IF finish_access_policy_grant.policy_name IN ('auditor', 'operator') THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text), '
      'otlet.semantic_correction_status_for_task(text) TO %I',
      role_name
    );
  END IF;
  IF finish_access_policy_grant.policy_name = 'operator' THEN
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text) TO %I',
      role_name
    );
  END IF;
  new_revision_hash := otlet.access_policy_revision(
    finish_access_policy_grant.target_role
  );
  PERFORM otlet.append_administrative_change(
    'access_policy',
    finish_access_policy_grant.policy_name || ':' || role_name,
    'grant',
    finish_access_policy_grant.old_revision_hash,
    new_revision_hash
  );
END;
$$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT role.rolname
    FROM pg_catalog.pg_class relation
    CROSS JOIN LATERAL pg_catalog.aclexplode(relation.relacl) privilege
    JOIN pg_catalog.pg_roles role ON role.oid = privilege.grantee
    WHERE relation.oid = 'otlet.audit_review_export'::regclass
      AND privilege.privilege_type = 'SELECT'
      AND role.oid <> relation.relowner
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_semantic_correction_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text), '
      'otlet.semantic_correction_status_for_task(text) TO %I',
      role_name
    );
  END LOOP;

  FOR role_name IN
    SELECT role.rolname
    FROM pg_catalog.pg_proc function
    CROSS JOIN LATERAL pg_catalog.aclexplode(function.proacl) privilege
    JOIN pg_catalog.pg_roles role ON role.oid = privilege.grantee
    WHERE function.oid =
      'otlet.correct_action(bigint,jsonb,text)'::regprocedure
      AND privilege.privilege_type = 'EXECUTE'
      AND role.oid <> function.proowner
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text) TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.semantic_correction_overrides FROM PUBLIC;
REVOKE ALL ON TABLE otlet.semantic_correction_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.semantic_materializations_effective FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue_without_semantic_corrections
  FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_semantic_correction_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_correction_override_hash(
  otlet.semantic_correction_overrides
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reject_semantic_correction_change()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.approve_semantic_correction(
  bigint, bigint, jsonb, timestamptz, numeric, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_correction_status_for_task(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.finish_access_policy_grant(
  text, regrole, text
) FROM PUBLIC;
