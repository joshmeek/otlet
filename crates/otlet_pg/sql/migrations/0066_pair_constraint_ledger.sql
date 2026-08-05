ALTER TABLE otlet.semantic_materializations
DROP CONSTRAINT semantic_materializations_stale_reason_check,
ADD CONSTRAINT semantic_materializations_stale_reason_check CHECK (
  stale_reason IN (
    'source_update',
    'source_delete',
    'candidate_removed',
    'candidate_changed',
    'contract_changed',
    'schema_drift',
    'manual',
    'content_revalidation_pending',
    'pair_constraint_conflict'
  )
);

CREATE FUNCTION otlet.pair_constraint_contract_hash(definition jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT otlet.identity_hash(
    'pair_constraint_contract',
    jsonb_build_object(
      'source', COALESCE($1 -> 'source', '{}'::jsonb),
      'input_query', COALESCE($1 #> '{task,input_query}', 'null'::jsonb),
      'input_shaping', COALESCE($1 #> '{task,input_shaping}', '{}'::jsonb),
      'output_schema', COALESCE($1 #> '{task,output_schema}', '{}'::jsonb),
      'decision_contract', COALESCE($1 #> '{task,decision_contract}', '{}'::jsonb),
      'validator', COALESCE($1 -> 'validator', '{}'::jsonb)
    )
  );
$$;

CREATE TABLE otlet.pair_constraint_facts (
  fact_hash text PRIMARY KEY CHECK (
    fact_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  subject_id text NOT NULL CHECK (NULLIF(subject_id, '') IS NOT NULL),
  left_id text NOT NULL CHECK (NULLIF(left_id, '') IS NOT NULL),
  right_id text NOT NULL CHECK (NULLIF(right_id, '') IS NOT NULL),
  relation text NOT NULL CHECK (relation IN ('must_link', 'cannot_link')),
  evidence_kind text NOT NULL CHECK (
    evidence_kind IN ('correction', 'repeated_rejection')
  ),
  workload_revision_hash text NOT NULL,
  relevant_contract_hash text NOT NULL CHECK (
    relevant_contract_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  source_hash text NOT NULL CHECK (
    source_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  content_hash text NOT NULL CHECK (
    content_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  source_freshness text NOT NULL CHECK (source_freshness = 'fresh'),
  correction_label_id bigint,
  prior_review_event_id bigint,
  review_event_id bigint NOT NULL UNIQUE,
  reviewer_identity text NOT NULL CHECK (
    NULLIF(reviewer_identity, '') IS NOT NULL
  ),
  reviewer_role text NOT NULL CHECK (NULLIF(reviewer_role, '') IS NOT NULL),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (left_id COLLATE "C" < right_id COLLATE "C"),
  CHECK (prior_review_event_id IS DISTINCT FROM review_event_id),
  CHECK (
    (evidence_kind = 'correction'
      AND correction_label_id IS NOT NULL
      AND prior_review_event_id IS NULL)
    OR
    (evidence_kind = 'repeated_rejection'
      AND correction_label_id IS NULL
      AND prior_review_event_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX pair_constraint_facts_correction_idx
ON otlet.pair_constraint_facts (correction_label_id)
WHERE correction_label_id IS NOT NULL;

CREATE INDEX pair_constraint_facts_current_idx
ON otlet.pair_constraint_facts (
  task_name,
  subject_id,
  relevant_contract_hash,
  source_hash,
  content_hash
);

CREATE FUNCTION otlet.reject_pair_constraint_fact_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet pair constraint facts are immutable';
END;
$$;

CREATE TRIGGER pair_constraint_facts_immutable
BEFORE UPDATE OR DELETE ON otlet.pair_constraint_facts
FOR EACH ROW EXECUTE FUNCTION otlet.reject_pair_constraint_fact_change();

CREATE TRIGGER pair_constraint_facts_no_truncate
BEFORE TRUNCATE ON otlet.pair_constraint_facts
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_pair_constraint_fact_change();

CREATE FUNCTION otlet.record_pair_constraint_fact() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target record;
  prior_event_id bigint;
  raw_left_id text;
  raw_right_id text;
  canonical_left_id text;
  canonical_right_id text;
  fact_relation text;
  fact_evidence_kind text;
  fact_contract_hash text;
  saved_fact_hash text;
BEGIN
  IF NEW.action_id IS NULL
     OR NEW.outcome NOT IN ('correct', 'reject')
     OR NEW.source_freshness <> 'fresh'
     OR NEW.source_hash IS NULL
     OR NEW.content_hash IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT
    action.action_type,
    job.workload_revision_hash,
    job.input #>> '{action_ids,left_id}' AS left_id,
    job.input #>> '{action_ids,right_id}' AS right_id,
    revision.definition,
    correction.id AS correction_label_id,
    correction.expected_answer
  INTO target
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  LEFT JOIN LATERAL (
    SELECT label.*
    FROM otlet.eval_labels label
    WHERE label.action_id = action.id
      AND label.label_source = 'manual_correction'
      AND label.task_name = NEW.task_name
      AND label.workload_revision_hash = job.workload_revision_hash
      AND label.source_hash = NEW.source_hash
      AND label.content_hash = NEW.content_hash
      AND label.authenticated_role_name = NEW.reviewer_identity
      AND label.active_role_name = NEW.reviewer_role
    ORDER BY label.label_revision DESC, label.id DESC
    LIMIT 1
  ) correction ON NEW.outcome = 'correct'
  WHERE action.id = NEW.action_id
    AND job.id = NEW.job_id
    AND job.task_name = NEW.task_name
    AND job.subject_id = NEW.subject_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  raw_left_id := NULLIF(target.left_id, '');
  raw_right_id := NULLIF(target.right_id, '');
  IF raw_left_id IS NULL
     OR raw_right_id IS NULL
     OR raw_left_id = raw_right_id THEN
    RETURN NULL;
  END IF;
  IF raw_left_id COLLATE "C" < raw_right_id COLLATE "C" THEN
    canonical_left_id := raw_left_id;
    canonical_right_id := raw_right_id;
  ELSE
    canonical_left_id := raw_right_id;
    canonical_right_id := raw_left_id;
  END IF;

  IF NEW.outcome = 'correct' THEN
    IF target.correction_label_id IS NULL THEN
      RETURN NULL;
    END IF;
    fact_relation := CASE target.expected_answer
      WHEN 'same_entity' THEN 'must_link'
      WHEN 'different_entity' THEN 'cannot_link'
      ELSE NULL
    END;
    fact_evidence_kind := 'correction';
  ELSE
    fact_relation := CASE target.action_type
      WHEN 'merge_candidate' THEN 'cannot_link'
      WHEN 'new_entity' THEN 'must_link'
      ELSE NULL
    END;
    fact_evidence_kind := 'repeated_rejection';
  END IF;

  IF fact_relation IS NULL THEN
    RETURN NULL;
  END IF;

  fact_contract_hash := otlet.pair_constraint_contract_hash(target.definition);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    concat_ws(':', 'otlet_pair_constraint', NEW.task_name, NEW.subject_id),
    0
  ));

  IF fact_evidence_kind = 'repeated_rejection' THEN
    SELECT prior.id
    INTO prior_event_id
    FROM otlet.review_events prior
    JOIN otlet.actions prior_action ON prior_action.id = prior.action_id
    JOIN otlet.jobs prior_job ON prior_job.id = prior_action.job_id
    WHERE prior.outcome = 'reject'
      AND prior.source_freshness = 'fresh'
      AND prior.action_id <> NEW.action_id
      AND prior_job.id <> NEW.job_id
      AND prior.receipt_id <> NEW.receipt_id
      AND prior.task_name = NEW.task_name
      AND prior.subject_id = NEW.subject_id
      AND prior_job.workload_revision_hash = target.workload_revision_hash
      AND prior.source_hash = NEW.source_hash
      AND prior.content_hash = NEW.content_hash
      AND NULLIF(prior_job.input #>> '{action_ids,left_id}', '') IN (
        canonical_left_id,
        canonical_right_id
      )
      AND NULLIF(prior_job.input #>> '{action_ids,right_id}', '') IN (
        canonical_left_id,
        canonical_right_id
      )
      AND CASE prior_action.action_type
        WHEN 'merge_candidate' THEN 'cannot_link'
        WHEN 'new_entity' THEN 'must_link'
        ELSE NULL
      END = fact_relation
    ORDER BY prior.id DESC
    LIMIT 1;
    IF prior_event_id IS NULL THEN
      RETURN NULL;
    END IF;
  END IF;

  INSERT INTO otlet.pair_constraint_facts (
    fact_hash,
    task_name,
    subject_id,
    left_id,
    right_id,
    relation,
    evidence_kind,
    workload_revision_hash,
    relevant_contract_hash,
    source_hash,
    content_hash,
    source_freshness,
    correction_label_id,
    prior_review_event_id,
    review_event_id,
    reviewer_identity,
    reviewer_role
  ) VALUES (
    otlet.identity_hash('pair_constraint_fact', jsonb_build_object(
      'task_name', NEW.task_name,
      'subject_id', NEW.subject_id,
      'left_id', canonical_left_id,
      'right_id', canonical_right_id,
      'relation', fact_relation,
      'relevant_contract_hash', fact_contract_hash,
      'source_hash', NEW.source_hash,
      'content_hash', NEW.content_hash
    )),
    NEW.task_name,
    NEW.subject_id,
    canonical_left_id,
    canonical_right_id,
    fact_relation,
    fact_evidence_kind,
    target.workload_revision_hash,
    fact_contract_hash,
    NEW.source_hash,
    NEW.content_hash,
    NEW.source_freshness,
    target.correction_label_id,
    prior_event_id,
    NEW.id,
    NEW.reviewer_identity,
    NEW.reviewer_role
  )
  ON CONFLICT (fact_hash) DO NOTHING
  RETURNING fact_hash INTO saved_fact_hash;

  IF saved_fact_hash IS NOT NULL THEN
    UPDATE otlet.semantic_materializations materialization
    SET stale = true,
        stale_reason = 'pair_constraint_conflict',
        updated_at = clock_timestamp()
    FROM otlet.workload_revisions revision
    WHERE materialization.task_name = NEW.task_name
      AND materialization.subject_id = NEW.subject_id
      AND materialization.source_hash = NEW.source_hash
      AND materialization.content_hash = NEW.content_hash
      AND revision.task_name = materialization.task_name
      AND revision.workload_revision_hash = materialization.contract_hash
      AND otlet.pair_constraint_contract_hash(revision.definition) =
        fact_contract_hash
      AND CASE materialization.body ->> 'match'
        WHEN 'same_entity' THEN 'must_link'
        WHEN 'different_entity' THEN 'cannot_link'
        ELSE NULL
      END IS DISTINCT FROM fact_relation
      AND materialization.body ->> 'match' IN (
        'same_entity',
        'different_entity'
      );
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER review_events_pair_constraint_fact
AFTER INSERT ON otlet.review_events
FOR EACH ROW EXECUTE FUNCTION otlet.record_pair_constraint_fact();

CREATE FUNCTION otlet.pair_constraint_current_input(
  task_name text,
  subject_id text,
  workload_revision_hash text
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  RETURN otlet.current_task_subject_input_snapshot(
    pair_constraint_current_input.task_name,
    pair_constraint_current_input.subject_id,
    pair_constraint_current_input.workload_revision_hash
  );
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

CREATE VIEW otlet.pair_constraint_status AS
WITH current_state AS (
  SELECT
    fact.*,
    task.lifecycle_state,
    head.active_workload_revision_hash,
    otlet.pair_constraint_contract_hash(active_revision.definition)
      AS active_relevant_contract_hash,
    active_revision.definition #> '{task,input_shaping}' AS active_input_shaping,
    current_input.input
  FROM otlet.pair_constraint_facts fact
  JOIN otlet.tasks task ON task.name = fact.task_name
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = fact.task_name
  LEFT JOIN otlet.workload_revisions active_revision
    ON active_revision.task_name = head.task_name
   AND active_revision.workload_revision_hash =
     head.active_workload_revision_hash
  LEFT JOIN LATERAL (
    SELECT otlet.pair_constraint_current_input(
      fact.task_name,
      fact.subject_id,
      head.active_workload_revision_hash
    ) AS input
  ) current_input ON head.active_workload_revision_hash IS NOT NULL
), evaluated AS (
  SELECT
    current_state.*,
    CASE WHEN input IS NULL THEN NULL
      ELSE otlet.semantic_source_hash(input)
    END AS current_source_hash,
    CASE WHEN input IS NULL THEN NULL
      ELSE otlet.semantic_content_hash(input, active_input_shaping)
    END AS current_content_hash,
    active_relevant_contract_hash IS NOT DISTINCT FROM relevant_contract_hash
      AS contract_current,
    input IS NOT NULL
      AND otlet.semantic_source_hash(input) = source_hash
      AND otlet.semantic_content_hash(input, active_input_shaping) = content_hash
      AS source_current
  FROM current_state
)
SELECT
  evaluated.fact_hash,
  evaluated.task_name,
  evaluated.subject_id,
  evaluated.left_id,
  evaluated.right_id,
  evaluated.relation,
  evaluated.evidence_kind,
  evaluated.workload_revision_hash,
  evaluated.relevant_contract_hash,
  evaluated.source_hash,
  evaluated.content_hash,
  evaluated.source_freshness,
  evaluated.correction_label_id,
  evaluated.prior_review_event_id,
  evaluated.review_event_id,
  evaluated.reviewer_identity,
  evaluated.reviewer_role,
  prior.reviewer_identity AS prior_reviewer_identity,
  prior.reviewer_role AS prior_reviewer_role,
  review.reason AS review_reason,
  evaluated.lifecycle_state,
  evaluated.active_workload_revision_hash,
  evaluated.active_relevant_contract_hash,
  evaluated.current_source_hash,
  evaluated.current_content_hash,
  COALESCE(evaluated.contract_current, false) AS contract_current,
  COALESCE(evaluated.source_current, false) AS source_current,
  CASE
    WHEN evaluated.lifecycle_state <> 'active'
      OR evaluated.active_workload_revision_hash IS NULL THEN 'task_inactive'
    WHEN NOT COALESCE(evaluated.contract_current, false)
      AND NOT COALESCE(evaluated.source_current, false)
      THEN 'reopened_source_and_contract'
    WHEN NOT COALESCE(evaluated.contract_current, false)
      THEN 'reopened_contract'
    WHEN NOT COALESCE(evaluated.source_current, false)
      THEN 'reopened_source'
    ELSE 'active'
  END AS fact_state,
  evaluated.created_at
FROM evaluated
JOIN otlet.review_events review ON review.id = evaluated.review_event_id
LEFT JOIN otlet.review_events prior
  ON prior.id = evaluated.prior_review_event_id;

CREATE FUNCTION otlet.guard_pair_constraint_materialization() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  proposed_relation text;
BEGIN
  IF NEW.stale OR NEW.body ->> 'match' NOT IN (
    'same_entity',
    'different_entity'
  ) THEN
    RETURN NEW;
  END IF;
  proposed_relation := CASE NEW.body ->> 'match'
    WHEN 'same_entity' THEN 'must_link'
    WHEN 'different_entity' THEN 'cannot_link'
  END;

  IF TG_OP = 'INSERT' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(
      concat_ws(':', 'otlet_pair_constraint', NEW.task_name, NEW.subject_id),
      0
    ));
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.pair_constraint_status fact
    WHERE fact.task_name = NEW.task_name
      AND fact.subject_id = NEW.subject_id
      AND fact.fact_state = 'active'
      AND fact.active_workload_revision_hash = NEW.contract_hash
      AND fact.source_hash = NEW.source_hash
      AND fact.content_hash = NEW.content_hash
      AND fact.relation <> proposed_relation
  ) THEN
    RAISE EXCEPTION 'otlet active pair constraint conflicts with semantic result';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER semantic_materializations_pair_constraint
BEFORE INSERT OR UPDATE ON otlet.semantic_materializations
FOR EACH ROW EXECUTE FUNCTION otlet.guard_pair_constraint_materialization();

REVOKE ALL ON TABLE otlet.pair_constraint_facts FROM PUBLIC;
REVOKE ALL ON TABLE otlet.pair_constraint_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.pair_constraint_contract_hash(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reject_pair_constraint_fact_change()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_pair_constraint_fact()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.pair_constraint_current_input(text,text,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_pair_constraint_materialization()
  FROM PUBLIC;
