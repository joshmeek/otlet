CREATE FUNCTION otlet.reviewer_rubric_error(definition jsonb) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  rubric jsonb := definition #> '{task,decision_contract,review_rubric}';
  minimum_gold_cases integer;
  maximum_calibration_errors integer;
BEGIN
  IF rubric IS NULL OR jsonb_typeof(rubric) = 'null' THEN
    RETURN 'review rubric is required';
  END IF;
  IF jsonb_typeof(rubric) IS DISTINCT FROM 'object'
     OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(rubric) key)
       IS DISTINCT FROM ARRAY[
         'format',
         'instructions',
         'maximum_calibration_errors',
         'maximum_review_errors',
         'minimum_gold_cases'
     ]::text[]
     OR rubric ->> 'format' IS DISTINCT FROM 'otlet.review_rubric.v1'
     OR jsonb_typeof(rubric -> 'instructions') IS DISTINCT FROM 'string'
     OR NULLIF(btrim(rubric ->> 'instructions'), '') IS NULL
     OR octet_length(rubric ->> 'instructions') > 32768
     OR jsonb_typeof(rubric -> 'minimum_gold_cases') IS DISTINCT FROM 'number'
     OR rubric ->> 'minimum_gold_cases' !~ '^[1-9][0-9]?$'
     OR (rubric ->> 'minimum_gold_cases')::integer > 64
     OR jsonb_typeof(rubric -> 'maximum_calibration_errors')
       IS DISTINCT FROM 'number'
     OR rubric ->> 'maximum_calibration_errors' !~ '^(0|[1-9][0-9]?)$'
     OR (rubric ->> 'maximum_calibration_errors')::integer > 63
     OR jsonb_typeof(rubric -> 'maximum_review_errors')
       IS DISTINCT FROM 'number'
     OR rubric ->> 'maximum_review_errors' !~ '^(0|[1-9][0-9]{0,5})$' THEN
    RETURN 'review rubric is invalid';
  END IF;
  minimum_gold_cases := (rubric ->> 'minimum_gold_cases')::integer;
  maximum_calibration_errors :=
    (rubric ->> 'maximum_calibration_errors')::integer;
  IF maximum_calibration_errors >= minimum_gold_cases THEN
    RETURN 'review rubric calibration threshold must require one correct case';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.reviewer_rubric_hash(definition jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN jsonb_typeof(
      reviewer_rubric_hash.definition #>
        '{task,decision_contract,review_rubric}'
    ) = 'object' THEN otlet.identity_hash(
      'review_rubric',
      reviewer_rubric_hash.definition #>
        '{task,decision_contract,review_rubric}'
    )
  END;
$$;

CREATE FUNCTION otlet.validate_workload_reviewer_rubric() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rubric jsonb := NEW.definition #> '{task,decision_contract,review_rubric}';
  validation_error text;
BEGIN
  IF rubric IS NULL OR jsonb_typeof(rubric) = 'null' THEN
    RETURN NEW;
  END IF;
  validation_error := otlet.reviewer_rubric_error(NEW.definition);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revisions_reviewer_rubric_validate
BEFORE INSERT ON otlet.workload_revisions
FOR EACH ROW EXECUTE FUNCTION otlet.validate_workload_reviewer_rubric();

CREATE TABLE otlet.reviewer_calibrations (
  calibration_hash text PRIMARY KEY CHECK (
    calibration_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  calibration_key text NOT NULL CHECK (
    calibration_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  workload_revision_hash text NOT NULL,
  rubric_hash text NOT NULL CHECK (
    rubric_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  reviewer_oid oid NOT NULL,
  reviewer_name text NOT NULL CHECK (
    NULLIF(btrim(reviewer_name), '') IS NOT NULL
  ),
  case_hashes text[] NOT NULL CHECK (
    cardinality(case_hashes) BETWEEN 1 AND 64
  ),
  maximum_calibration_errors integer NOT NULL CHECK (
    maximum_calibration_errors BETWEEN 0 AND 63
  ),
  maximum_review_errors integer NOT NULL CHECK (
    maximum_review_errors BETWEEN 0 AND 999999
  ),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  created_by_oid oid NOT NULL,
  created_by_name text NOT NULL CHECK (
    NULLIF(btrim(created_by_name), '') IS NOT NULL
  ),
  created_as_oid oid NOT NULL,
  created_as_name text NOT NULL CHECK (
    NULLIF(btrim(created_as_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (reviewer_oid, task_name, calibration_key),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE INDEX reviewer_calibrations_reviewer_task_idx
ON otlet.reviewer_calibrations (
  reviewer_oid,
  reviewer_name,
  task_name,
  created_at DESC,
  calibration_hash
);

CREATE TABLE otlet.reviewer_calibration_responses (
  response_hash text PRIMARY KEY CHECK (
    response_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  calibration_hash text NOT NULL REFERENCES otlet.reviewer_calibrations(
    calibration_hash
  ),
  case_hash text NOT NULL REFERENCES otlet.evaluation_cases(case_hash),
  member_token text NOT NULL CHECK (
    member_token ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  answer text NOT NULL CHECK (
    NULLIF(btrim(answer), '') IS NOT NULL AND octet_length(answer) <= 512
  ),
  confidence text NOT NULL CHECK (confidence IN ('high', 'medium', 'low')),
  action_type text NOT NULL CHECK (
    NULLIF(btrim(action_type), '') IS NOT NULL
    AND octet_length(action_type) <= 128
  ),
  response_error boolean NOT NULL,
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reviewer_oid oid NOT NULL,
  reviewer_name text NOT NULL CHECK (
    NULLIF(btrim(reviewer_name), '') IS NOT NULL
  ),
  reviewer_role_oid oid NOT NULL,
  reviewer_role_name text NOT NULL CHECK (
    NULLIF(btrim(reviewer_role_name), '') IS NOT NULL
  ),
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (calibration_hash, case_hash),
  UNIQUE (calibration_hash, member_token)
);

CREATE TABLE otlet.reviewer_review_errors (
  review_error_hash text PRIMARY KEY CHECK (
    review_error_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  review_event_id bigint NOT NULL UNIQUE REFERENCES otlet.review_events(id),
  calibration_hash text NOT NULL REFERENCES otlet.reviewer_calibrations(
    calibration_hash
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  rubric_hash text NOT NULL CHECK (
    rubric_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  reviewer_oid oid NOT NULL,
  reviewer_name text NOT NULL CHECK (
    NULLIF(btrim(reviewer_name), '') IS NOT NULL
  ),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  recorded_by_oid oid NOT NULL,
  recorded_by_name text NOT NULL CHECK (
    NULLIF(btrim(recorded_by_name), '') IS NOT NULL
  ),
  recorded_as_oid oid NOT NULL,
  recorded_as_name text NOT NULL CHECK (
    NULLIF(btrim(recorded_as_name), '') IS NOT NULL
  ),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX reviewer_review_errors_reviewer_task_idx
ON otlet.reviewer_review_errors (
  reviewer_oid,
  reviewer_name,
  task_name,
  rubric_hash,
  recorded_at
);

CREATE FUNCTION otlet.reviewer_calibration_member_token(
  calibration_hash text,
  case_hash text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.identity_hash(
    'reviewer_calibration_member',
    jsonb_build_object(
      'calibration_hash', reviewer_calibration_member_token.calibration_hash,
      'case_hash', reviewer_calibration_member_token.case_hash
    )
  );
$$;

CREATE FUNCTION otlet.reviewer_gold_visibility_error(reviewer_oid oid)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_state record;
BEGIN
  SELECT role.rolsuper, role.rolcanlogin
  INTO role_state
  FROM pg_catalog.pg_roles role
  WHERE role.oid = reviewer_gold_visibility_error.reviewer_oid;
  IF NOT FOUND OR NOT role_state.rolcanlogin THEN
    RETURN 'reviewer identity must be a login role';
  END IF;
  IF role_state.rolsuper OR reviewer_gold_visibility_error.reviewer_oid = (
    SELECT database.datdba
    FROM pg_catalog.pg_database database
    WHERE database.datname = current_database()
  ) THEN
    RETURN 'reviewer identity has owner access to gold evidence';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles reachable_role
    WHERE (
        pg_catalog.pg_has_role(
          reviewer_gold_visibility_error.reviewer_oid,
          reachable_role.oid,
          'USAGE'
        )
        OR pg_catalog.pg_has_role(
          reviewer_gold_visibility_error.reviewer_oid,
          reachable_role.oid,
          'SET'
        )
      )
      AND (
        pg_catalog.has_function_privilege(
          reachable_role.oid,
          'otlet.export_eval_cases(integer)'::regprocedure::oid,
          'EXECUTE'
        )
        OR pg_catalog.has_function_privilege(
          reachable_role.oid,
          'otlet.label_action(bigint,text,text,text,text,text)'::regprocedure::oid,
          'EXECUTE'
        )
        OR pg_catalog.has_function_privilege(
          reachable_role.oid,
          'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid,
          'EXECUTE'
        )
        OR pg_catalog.has_function_privilege(
          reachable_role.oid,
          'otlet.semantic_correction_status_for_task(text)'::regprocedure::oid,
          'EXECUTE'
        )
        OR EXISTS (
          SELECT 1
          FROM unnest(ARRAY[
            'otlet.eval_labels'::regclass::oid,
            'otlet.eval_label_status'::regclass::oid,
            'otlet.eval_label_quality_status'::regclass::oid,
            'otlet.audit_eval_label_export'::regclass::oid,
            'otlet.eval_label_series_revisions'::regclass::oid,
            'otlet.evaluation_cases'::regclass::oid,
            'otlet.evaluation_case_status'::regclass::oid,
            'otlet.evaluation_runs'::regclass::oid,
            'otlet.evaluation_executions'::regclass::oid,
            'otlet.evaluation_results'::regclass::oid,
            'otlet.evaluation_exposure_status'::regclass::oid,
            'otlet.evaluation_replay_status'::regclass::oid,
            'otlet.audit_evaluation_replay_export'::regclass::oid,
            'otlet.evaluation_slice_reports'::regclass::oid,
            'otlet.evaluation_slice_status'::regclass::oid,
            'otlet.workload_acceptance_contracts'::regclass::oid,
            'otlet.workload_acceptance_status'::regclass::oid,
            'otlet.candidate_set_coverage_reports'::regclass::oid,
            'otlet.candidate_set_coverage_status'::regclass::oid,
            'otlet.entity_resolution_quality_status'::regclass::oid,
            'otlet.production_model_database_samples'::regclass::oid,
            'otlet.production_model_cancellation_probes'::regclass::oid,
            'otlet.production_model_qualification_status'::regclass::oid,
            'otlet.quality_data_drift_reports'::regclass::oid,
            'otlet.quality_data_drift_status'::regclass::oid,
            'otlet.review_economics_reports'::regclass::oid,
            'otlet.review_economics_status'::regclass::oid,
            'otlet.task_candidate_observations'::regclass::oid,
            'otlet.reviewer_review_errors'::regclass::oid,
            'otlet.audit_reviewer_calibration_export'::regclass::oid,
            'otlet.review_samples'::regclass::oid,
            'otlet.audit_review_sample_export'::regclass::oid,
            'otlet.review_queue'::regclass::oid,
            'otlet.review_queue_without_review_samples'::regclass::oid,
            'otlet.audit_review_export'::regclass::oid,
            'otlet.semantic_correction_overrides'::regclass::oid,
            'otlet.semantic_correction_status'::regclass::oid,
            'otlet.audit_semantic_correction_export'::regclass::oid,
            'otlet.semantic_materializations_effective'::regclass::oid,
            'otlet.pair_constraint_facts'::regclass::oid,
            'otlet.pair_constraint_status'::regclass::oid,
            'otlet.entity_graph_conflict_status'::regclass::oid,
            'otlet.review_queue_without_semantic_corrections'::regclass::oid,
            'otlet.reviewer_calibrations'::regclass::oid,
            'otlet.reviewer_calibration_responses'::regclass::oid
          ]) protected(relation_oid)
          WHERE pg_catalog.has_table_privilege(
            reachable_role.oid,
            protected.relation_oid,
            'SELECT'
          )
          OR pg_catalog.has_any_column_privilege(
            reachable_role.oid,
            protected.relation_oid,
            'SELECT'
          )
        )
      )
  ) THEN
    RETURN 'reviewer identity can read gold evidence';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.reviewer_calibration_assignment_error(
  task_name text,
  workload_revision_hash text,
  rubric_hash text,
  reviewer_oid oid,
  reviewer_name text,
  case_hashes text[]
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  rubric jsonb;
BEGIN
  SELECT revision.definition
  INTO source
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = reviewer_calibration_assignment_error.task_name
    AND revision.workload_revision_hash =
      reviewer_calibration_assignment_error.workload_revision_hash;
  IF NOT FOUND THEN
    RETURN 'reviewer calibration workload revision does not exist';
  END IF;
  rubric := source.definition #> '{task,decision_contract,review_rubric}';
  IF otlet.reviewer_rubric_error(source.definition) IS NOT NULL
     OR otlet.reviewer_rubric_hash(source.definition) IS DISTINCT FROM
       reviewer_calibration_assignment_error.rubric_hash THEN
    RETURN 'reviewer calibration rubric identity is invalid';
  END IF;
  IF cardinality(reviewer_calibration_assignment_error.case_hashes) <
       (rubric ->> 'minimum_gold_cases')::integer
     OR cardinality(reviewer_calibration_assignment_error.case_hashes) > 64
     OR reviewer_calibration_assignment_error.case_hashes IS DISTINCT FROM (
       SELECT array_agg(DISTINCT candidate ORDER BY candidate)
       FROM unnest(reviewer_calibration_assignment_error.case_hashes)
         candidate
     )
     OR EXISTS (
       SELECT 1
       FROM unnest(reviewer_calibration_assignment_error.case_hashes)
         candidate
       WHERE candidate !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     ) THEN
    RETURN 'reviewer calibration case manifest is invalid';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles role
    WHERE role.oid = reviewer_calibration_assignment_error.reviewer_oid
      AND role.rolname = reviewer_calibration_assignment_error.reviewer_name
      AND role.rolcanlogin
  ) THEN
    RETURN 'reviewer calibration identity is invalid';
  END IF;
  SELECT
    count(*) AS case_count,
    count(DISTINCT evaluation_case.lineage_hash) AS lineage_count,
    bool_and(
      evaluation_case.task_name =
        reviewer_calibration_assignment_error.task_name
      AND evaluation_case.population_kind = 'calibration'
      AND evaluation_case.label_source = 'manual_correction'
      AND quality.qualification_eligible
      AND otlet.reviewer_rubric_hash(case_revision.definition) =
        reviewer_calibration_assignment_error.rubric_hash
      AND label.authenticated_role_oid <>
        reviewer_calibration_assignment_error.reviewer_oid
      AND label.authenticated_role_name <>
        reviewer_calibration_assignment_error.reviewer_name
      AND label.adjudicated_authenticated_role_oid <>
        reviewer_calibration_assignment_error.reviewer_oid
      AND label.adjudicated_authenticated_role_name <>
        reviewer_calibration_assignment_error.reviewer_name
    ) AS valid
  INTO source
  FROM otlet.evaluation_cases evaluation_case
  JOIN otlet.eval_labels label ON label.id = evaluation_case.label_id
  JOIN otlet.eval_label_quality_status quality
    ON quality.label_id = evaluation_case.label_id
  JOIN otlet.workload_revisions case_revision
    ON case_revision.task_name = evaluation_case.task_name
   AND case_revision.workload_revision_hash =
     evaluation_case.workload_revision_hash
  WHERE evaluation_case.case_hash = ANY(
    reviewer_calibration_assignment_error.case_hashes
  );
  IF source.case_count IS DISTINCT FROM
       cardinality(reviewer_calibration_assignment_error.case_hashes)::bigint
     OR source.lineage_count IS DISTINCT FROM source.case_count
     OR source.valid IS DISTINCT FROM true THEN
    RETURN 'reviewer calibration gold cases are invalid';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.validate_reviewer_calibration() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  expected_definition jsonb;
  rubric jsonb;
  validation_error text;
BEGIN
  validation_error := otlet.reviewer_calibration_assignment_error(
    NEW.task_name,
    NEW.workload_revision_hash,
    NEW.rubric_hash,
    NEW.reviewer_oid,
    NEW.reviewer_name,
    NEW.case_hashes
  );
  SELECT revision.definition #> '{task,decision_contract,review_rubric}'
  INTO rubric
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.workload_revision_hash;
  expected_definition := jsonb_build_object(
    'format', 'otlet.reviewer_calibration.v1',
    'calibration_key', NEW.calibration_key,
    'task_name', NEW.task_name,
    'workload_revision_hash', NEW.workload_revision_hash,
    'rubric_hash', NEW.rubric_hash,
    'reviewer_oid', NEW.reviewer_oid::text,
    'reviewer_name', NEW.reviewer_name,
    'case_hashes', to_jsonb(NEW.case_hashes),
    'maximum_calibration_errors', NEW.maximum_calibration_errors,
    'maximum_review_errors', NEW.maximum_review_errors,
    'reason', NEW.reason
  );
  IF validation_error IS NOT NULL
     OR NEW.maximum_calibration_errors IS DISTINCT FROM
       (rubric ->> 'maximum_calibration_errors')::integer
     OR NEW.maximum_review_errors IS DISTINCT FROM
       (rubric ->> 'maximum_review_errors')::integer
     OR NEW.definition IS DISTINCT FROM expected_definition
     OR NEW.calibration_hash IS DISTINCT FROM otlet.identity_hash(
       'reviewer_calibration', expected_definition
     ) THEN
    RAISE EXCEPTION 'otlet reviewer calibration assignment is invalid: %',
      COALESCE(validation_error, 'identity mismatch');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER reviewer_calibrations_a_validate
BEFORE INSERT ON otlet.reviewer_calibrations
FOR EACH ROW EXECUTE FUNCTION otlet.validate_reviewer_calibration();

CREATE TRIGGER reviewer_calibrations_b_append
BEFORE INSERT OR UPDATE OR DELETE ON otlet.reviewer_calibrations
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER reviewer_calibrations_truncate_guard
BEFORE TRUNCATE ON otlet.reviewer_calibrations
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.validate_reviewer_calibration_response() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  expected_definition jsonb;
BEGIN
  SELECT assignment.*, evaluation_case.expected_answer,
    evaluation_case.expected_confidence,
    evaluation_case.expected_action_type
  INTO source
  FROM otlet.reviewer_calibrations assignment
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = NEW.case_hash
  WHERE assignment.calibration_hash = NEW.calibration_hash
    AND NEW.case_hash = ANY(assignment.case_hashes);
  expected_definition := jsonb_build_object(
    'format', 'otlet.reviewer_calibration_response.v1',
    'calibration_hash', NEW.calibration_hash,
    'case_hash', NEW.case_hash,
    'member_token', NEW.member_token,
    'answer', NEW.answer,
    'confidence', NEW.confidence,
    'action_type', NEW.action_type,
    'response_error', NEW.response_error,
    'reviewer_oid', NEW.reviewer_oid::text,
    'reviewer_name', NEW.reviewer_name
  );
  IF NOT FOUND
     OR NEW.member_token IS DISTINCT FROM
       otlet.reviewer_calibration_member_token(
         NEW.calibration_hash,
         NEW.case_hash
       )
     OR NEW.reviewer_oid IS DISTINCT FROM source.reviewer_oid
     OR NEW.reviewer_name IS DISTINCT FROM source.reviewer_name
     OR NEW.response_error IS DISTINCT FROM (
       ROW(NEW.answer, NEW.confidence, NEW.action_type) IS DISTINCT FROM
       ROW(
         source.expected_answer,
         source.expected_confidence,
         source.expected_action_type
       )
     )
     OR NEW.definition IS DISTINCT FROM expected_definition
     OR NEW.response_hash IS DISTINCT FROM otlet.identity_hash(
       'reviewer_calibration_response', expected_definition
     ) THEN
    RAISE EXCEPTION 'otlet reviewer calibration response is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER reviewer_calibration_responses_a_validate
BEFORE INSERT ON otlet.reviewer_calibration_responses
FOR EACH ROW EXECUTE FUNCTION otlet.validate_reviewer_calibration_response();

CREATE TRIGGER reviewer_calibration_responses_b_append
BEFORE INSERT OR UPDATE OR DELETE ON otlet.reviewer_calibration_responses
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER reviewer_calibration_responses_truncate_guard
BEFORE TRUNCATE ON otlet.reviewer_calibration_responses
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER reviewer_review_errors_b_append
BEFORE INSERT OR UPDATE OR DELETE ON otlet.reviewer_review_errors
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER reviewer_review_errors_truncate_guard
BEFORE TRUNCATE ON otlet.reviewer_review_errors
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.reviewer_calibration_state(calibration_hash text)
RETURNS TABLE (
  active_workload_revision_hash text,
  rubric_current boolean,
  gold_current boolean,
  case_count integer,
  response_count integer,
  calibration_error_count integer,
  completed_at timestamptz,
  review_count integer,
  review_error_count integer,
  state text,
  review_authorized boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  assignment otlet.reviewer_calibrations%ROWTYPE;
  active_rubric_hash text;
  identity_current boolean;
  visibility_error text;
BEGIN
  SELECT * INTO assignment
  FROM otlet.reviewer_calibrations calibration
  WHERE calibration.calibration_hash =
    reviewer_calibration_state.calibration_hash;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF (
      assignment.reviewer_oid IS DISTINCT FROM session_user::regrole::oid
      OR assignment.reviewer_name IS DISTINCT FROM session_user::text
    )
    AND session_user::regrole::oid <> (
      SELECT database.datdba
      FROM pg_catalog.pg_database database
      WHERE database.datname = current_database()
    )
    AND NOT pg_catalog.has_table_privilege(
      session_user,
      'otlet.audit_reviewer_calibration_export',
      'SELECT'
    ) THEN
    RAISE EXCEPTION 'otlet reviewer calibration belongs to another reviewer';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles role
    WHERE role.oid = assignment.reviewer_oid
      AND role.rolname = assignment.reviewer_name
      AND role.rolcanlogin
  ) INTO identity_current;

  SELECT
    head.active_workload_revision_hash,
    otlet.reviewer_rubric_hash(revision.definition)
  INTO active_workload_revision_hash, active_rubric_hash
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = assignment.task_name;
  rubric_current := active_rubric_hash IS NOT DISTINCT FROM
    assignment.rubric_hash;

  SELECT
    count(*) = cardinality(assignment.case_hashes)
      AND bool_and(
        quality.qualification_eligible
        AND evaluation_case.population_kind = 'calibration'
        AND evaluation_case.label_source = 'manual_correction'
      )
  INTO gold_current
  FROM otlet.evaluation_cases evaluation_case
  JOIN otlet.eval_label_quality_status quality
    ON quality.label_id = evaluation_case.label_id
  WHERE evaluation_case.case_hash = ANY(assignment.case_hashes);
  gold_current := COALESCE(gold_current, false);

  case_count := cardinality(assignment.case_hashes);
  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE response.response_error)::integer,
    max(response.submitted_at)
  INTO response_count, calibration_error_count, completed_at
  FROM otlet.reviewer_calibration_responses response
  WHERE response.calibration_hash = assignment.calibration_hash;
  IF response_count <> case_count THEN
    completed_at := NULL;
  END IF;

  review_count := 0;
  review_error_count := 0;
  IF completed_at IS NOT NULL
     AND calibration_error_count <= assignment.maximum_calibration_errors THEN
    SELECT count(*)::integer
    INTO review_count
    FROM otlet.review_events event
    WHERE event.reviewer_calibration_hash = assignment.calibration_hash;
    SELECT count(*)::integer
    INTO review_error_count
    FROM otlet.reviewer_review_errors review_error
    WHERE review_error.reviewer_oid = assignment.reviewer_oid
      AND review_error.task_name = assignment.task_name
      AND review_error.rubric_hash = assignment.rubric_hash
      AND review_error.recorded_at > assignment.created_at;
  END IF;

  visibility_error := otlet.reviewer_gold_visibility_error(
    assignment.reviewer_oid
  );
  state := CASE
    WHEN NOT identity_current THEN 'reviewer_identity_invalid'
    WHEN visibility_error IS NOT NULL THEN 'gold_visible'
    WHEN NOT rubric_current THEN 'rubric_changed'
    WHEN NOT gold_current THEN 'gold_invalid'
    WHEN response_count < case_count THEN 'pending'
    WHEN calibration_error_count > assignment.maximum_calibration_errors
      THEN 'calibration_threshold_breached'
    WHEN review_error_count > assignment.maximum_review_errors
      THEN 'review_error_threshold_breached'
    ELSE 'calibrated'
  END;
  review_authorized := state = 'calibrated';
  IF completed_at IS NULL
     AND assignment.reviewer_oid = session_user::regrole::oid
     AND assignment.reviewer_name = session_user::text THEN
    calibration_error_count := NULL;
  END IF;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.register_reviewer_calibration(
  task_name text,
  reviewer regrole,
  calibration_key text,
  case_hashes text[],
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  revision record;
  reviewer_name text;
  canonical_case_hashes text[];
  rubric jsonb;
  rubric_hash text;
  definition jsonb;
  calibration_hash text;
  existing otlet.reviewer_calibrations%ROWTYPE;
  validation_error text;
  prior_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF register_reviewer_calibration.calibration_key !~
       '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
     OR NULLIF(btrim(register_reviewer_calibration.reason), '') IS NULL
     OR octet_length(register_reviewer_calibration.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet reviewer calibration declaration is invalid';
  END IF;
  SELECT role.rolname
  INTO reviewer_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = register_reviewer_calibration.reviewer::oid
    AND role.rolcanlogin;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet reviewer identity must be a login role';
  END IF;
  validation_error := otlet.reviewer_gold_visibility_error(
    register_reviewer_calibration.reviewer::oid
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;
  IF NOT pg_catalog.has_function_privilege(
    register_reviewer_calibration.reviewer::oid,
    'otlet.submit_reviewer_calibration(text,text,text,text,text)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'otlet reviewer identity lacks reviewer access';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || register_reviewer_calibration.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_reviewer_calibration:' ||
      register_reviewer_calibration.reviewer::oid::text || ':' ||
      register_reviewer_calibration.task_name || ':' ||
      register_reviewer_calibration.calibration_key,
    0
  ));
  SELECT revision_row.definition, head.active_workload_revision_hash
  INTO revision
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision_row
    ON revision_row.task_name = head.task_name
   AND revision_row.workload_revision_hash =
     head.active_workload_revision_hash
  WHERE head.task_name = register_reviewer_calibration.task_name
  FOR UPDATE OF head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet reviewer calibration task has no active revision';
  END IF;
  rubric := revision.definition #> '{task,decision_contract,review_rubric}';
  validation_error := otlet.reviewer_rubric_error(revision.definition);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;
  rubric_hash := otlet.reviewer_rubric_hash(revision.definition);
  SELECT array_agg(DISTINCT candidate ORDER BY candidate)
  INTO canonical_case_hashes
  FROM unnest(COALESCE(
    register_reviewer_calibration.case_hashes,
    ARRAY[]::text[]
  )) candidate;
  IF canonical_case_hashes IS NULL THEN
    RAISE EXCEPTION 'otlet reviewer calibration case manifest is invalid';
  END IF;

  definition := jsonb_build_object(
    'format', 'otlet.reviewer_calibration.v1',
    'calibration_key', register_reviewer_calibration.calibration_key,
    'task_name', register_reviewer_calibration.task_name,
    'workload_revision_hash', revision.active_workload_revision_hash,
    'rubric_hash', rubric_hash,
    'reviewer_oid', register_reviewer_calibration.reviewer::oid::text,
    'reviewer_name', reviewer_name,
    'case_hashes', to_jsonb(canonical_case_hashes),
    'maximum_calibration_errors',
      (rubric ->> 'maximum_calibration_errors')::integer,
    'maximum_review_errors',
      (rubric ->> 'maximum_review_errors')::integer,
    'reason', btrim(register_reviewer_calibration.reason)
  );
  calibration_hash := otlet.identity_hash(
    'reviewer_calibration', definition
  );
  SELECT * INTO existing
  FROM otlet.reviewer_calibrations calibration
  WHERE calibration.reviewer_oid =
      register_reviewer_calibration.reviewer::oid
    AND calibration.task_name = register_reviewer_calibration.task_name
    AND calibration.calibration_key =
      register_reviewer_calibration.calibration_key;
  IF FOUND THEN
    IF existing.calibration_hash IS DISTINCT FROM calibration_hash
       OR existing.definition IS DISTINCT FROM definition THEN
      RAISE EXCEPTION 'otlet reviewer calibration key conflicts with its stored declaration';
    END IF;
    RETURN existing.calibration_hash;
  END IF;

  validation_error := otlet.reviewer_calibration_assignment_error(
    register_reviewer_calibration.task_name,
    revision.active_workload_revision_hash,
    rubric_hash,
    register_reviewer_calibration.reviewer::oid,
    reviewer_name,
    canonical_case_hashes
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.reviewer_calibrations prior
    JOIN LATERAL unnest(prior.case_hashes) prior_member(case_hash)
      ON true
    JOIN otlet.evaluation_cases prior_case
      ON prior_case.case_hash = prior_member.case_hash
    JOIN otlet.evaluation_cases selected_case
      ON selected_case.case_hash = ANY(canonical_case_hashes)
     AND selected_case.lineage_hash = prior_case.lineage_hash
    WHERE prior.reviewer_oid = register_reviewer_calibration.reviewer::oid
      AND prior.task_name = register_reviewer_calibration.task_name
  ) THEN
    RAISE EXCEPTION 'otlet reviewer calibration gold case was already exposed';
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.reviewer_calibrations (
    calibration_hash,
    calibration_key,
    task_name,
    workload_revision_hash,
    rubric_hash,
    reviewer_oid,
    reviewer_name,
    case_hashes,
    maximum_calibration_errors,
    maximum_review_errors,
    definition,
    reason,
    created_by_oid,
    created_by_name,
    created_as_oid,
    created_as_name
  ) VALUES (
    calibration_hash,
    register_reviewer_calibration.calibration_key,
    register_reviewer_calibration.task_name,
    revision.active_workload_revision_hash,
    rubric_hash,
    register_reviewer_calibration.reviewer::oid,
    reviewer_name,
    canonical_case_hashes,
    (rubric ->> 'maximum_calibration_errors')::integer,
    (rubric ->> 'maximum_review_errors')::integer,
    definition,
    btrim(register_reviewer_calibration.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RETURN calibration_hash;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RAISE;
END;
$$;

CREATE FUNCTION otlet.submit_reviewer_calibration(
  calibration_hash text,
  member_token text,
  answer text,
  confidence text,
  action_type text
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  existing otlet.reviewer_calibration_responses%ROWTYPE;
  calibration_state record;
  answer_values text[];
  action_types jsonb;
  response_error boolean;
  definition jsonb;
  response_hash text;
  role_setting text := current_setting('role', true);
  active_role_oid oid;
  active_role_name text;
  prior_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF submit_reviewer_calibration.calibration_hash !~
       '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR submit_reviewer_calibration.member_token !~
       '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR NULLIF(btrim(submit_reviewer_calibration.answer), '') IS NULL
     OR octet_length(submit_reviewer_calibration.answer) > 512
     OR submit_reviewer_calibration.confidence NOT IN ('high', 'medium', 'low')
     OR NULLIF(btrim(submit_reviewer_calibration.action_type), '') IS NULL
     OR octet_length(submit_reviewer_calibration.action_type) > 128 THEN
    RAISE EXCEPTION 'otlet reviewer calibration response is invalid';
  END IF;

  SELECT
    assignment.*,
    candidate.case_hash,
    revision.definition AS revision_definition,
    evaluation_case.expected_answer,
    evaluation_case.expected_confidence,
    evaluation_case.expected_action_type
  INTO source
  FROM otlet.reviewer_calibrations assignment
  CROSS JOIN LATERAL unnest(assignment.case_hashes) candidate(case_hash)
  JOIN otlet.workload_revisions revision
    ON revision.task_name = assignment.task_name
   AND revision.workload_revision_hash = assignment.workload_revision_hash
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = candidate.case_hash
  WHERE assignment.calibration_hash =
      submit_reviewer_calibration.calibration_hash
    AND otlet.reviewer_calibration_member_token(
      assignment.calibration_hash,
      candidate.case_hash
    ) = submit_reviewer_calibration.member_token
  FOR UPDATE OF assignment;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet reviewer calibration member does not exist';
  END IF;
  IF source.reviewer_oid IS DISTINCT FROM session_user::regrole::oid
     OR source.reviewer_name IS DISTINCT FROM session_user THEN
    RAISE EXCEPTION 'otlet reviewer calibration belongs to another reviewer';
  END IF;

  SELECT * INTO existing
  FROM otlet.reviewer_calibration_responses response
  WHERE response.calibration_hash = source.calibration_hash
    AND response.case_hash = source.case_hash;
  IF FOUND THEN
    IF existing.member_token = submit_reviewer_calibration.member_token
       AND existing.answer = btrim(submit_reviewer_calibration.answer)
       AND existing.confidence = submit_reviewer_calibration.confidence
       AND existing.action_type = btrim(submit_reviewer_calibration.action_type)
       AND existing.reviewer_oid = session_user::regrole::oid
       AND existing.reviewer_name = session_user THEN
      RETURN source.calibration_hash;
    END IF;
    RAISE EXCEPTION 'otlet reviewer calibration response conflicts with its stored answer';
  END IF;

  SELECT * INTO calibration_state
  FROM otlet.reviewer_calibration_state(source.calibration_hash);
  IF calibration_state.state IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'otlet reviewer calibration cannot accept responses while %',
      calibration_state.state;
  END IF;
  answer_values := otlet.output_schema_enum_values(
    source.revision_definition #> '{task,output_schema}',
    COALESCE(NULLIF(
      source.revision_definition #>>
        '{task,decision_contract,answer_field}',
      ''
    ), 'match')
  );
  action_types := COALESCE(
    source.revision_definition #> '{task,decision_contract,action_types}',
    '[]'::jsonb
  );
  IF answer_values IS NOT NULL
     AND NOT btrim(submit_reviewer_calibration.answer) = ANY(answer_values) THEN
    RAISE EXCEPTION 'otlet reviewer calibration answer is outside the decision contract';
  END IF;
  IF btrim(submit_reviewer_calibration.action_type) <> 'none'
     AND NOT action_types ? btrim(submit_reviewer_calibration.action_type) THEN
    RAISE EXCEPTION 'otlet reviewer calibration action type is outside the decision contract';
  END IF;

  response_error := ROW(
    btrim(submit_reviewer_calibration.answer),
    submit_reviewer_calibration.confidence,
    btrim(submit_reviewer_calibration.action_type)
  ) IS DISTINCT FROM ROW(
    source.expected_answer,
    source.expected_confidence,
    source.expected_action_type
  );
  definition := jsonb_build_object(
    'format', 'otlet.reviewer_calibration_response.v1',
    'calibration_hash', source.calibration_hash,
    'case_hash', source.case_hash,
    'member_token', submit_reviewer_calibration.member_token,
    'answer', btrim(submit_reviewer_calibration.answer),
    'confidence', submit_reviewer_calibration.confidence,
    'action_type', btrim(submit_reviewer_calibration.action_type),
    'response_error', response_error,
    'reviewer_oid', session_user::regrole::oid::text,
    'reviewer_name', session_user
  );
  response_hash := otlet.identity_hash(
    'reviewer_calibration_response', definition
  );
  IF role_setting IS NULL OR role_setting = 'none' THEN
    active_role_oid := session_user::regrole::oid;
    active_role_name := session_user;
  ELSE
    SELECT role.oid, role.rolname
    INTO active_role_oid, active_role_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = role_setting::regrole::oid;
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.reviewer_calibration_responses (
    response_hash,
    calibration_hash,
    case_hash,
    member_token,
    answer,
    confidence,
    action_type,
    response_error,
    definition,
    reviewer_oid,
    reviewer_name,
    reviewer_role_oid,
    reviewer_role_name
  ) VALUES (
    response_hash,
    source.calibration_hash,
    source.case_hash,
    submit_reviewer_calibration.member_token,
    btrim(submit_reviewer_calibration.answer),
    submit_reviewer_calibration.confidence,
    btrim(submit_reviewer_calibration.action_type),
    response_error,
    definition,
    session_user::regrole::oid,
    session_user,
    active_role_oid,
    active_role_name
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RETURN source.calibration_hash;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RAISE;
END;
$$;

CREATE VIEW otlet.reviewer_calibration_queue
WITH (security_barrier = true) AS
SELECT
  assignment.calibration_hash,
  assignment.calibration_key,
  assignment.task_name,
  assignment.workload_revision_hash,
  assignment.rubric_hash,
  member.ordinality::integer AS member_ordinal,
  otlet.reviewer_calibration_member_token(
    assignment.calibration_hash,
    member.case_hash
  ) AS member_token,
  revision.definition #> '{task,decision_contract,review_rubric}' AS rubric,
  evaluation_case.shaped_input,
  revision.definition #> ARRAY[
    'task',
    'output_schema',
    'properties',
    COALESCE(NULLIF(
      revision.definition #>> '{task,decision_contract,answer_field}',
      ''
    ), 'match'),
    'enum'
  ] AS answer_values,
  '["high", "medium", "low"]'::jsonb AS confidence_values,
  COALESCE(
    revision.definition #> '{task,decision_contract,action_types}',
    '[]'::jsonb
  ) || '["none"]'::jsonb AS action_types,
  assignment.created_at
FROM otlet.reviewer_calibrations assignment
CROSS JOIN LATERAL unnest(assignment.case_hashes)
  WITH ORDINALITY member(case_hash, ordinality)
JOIN otlet.evaluation_cases evaluation_case
  ON evaluation_case.case_hash = member.case_hash
JOIN otlet.workload_revisions revision
  ON revision.task_name = assignment.task_name
 AND revision.workload_revision_hash = assignment.workload_revision_hash
CROSS JOIN LATERAL otlet.reviewer_calibration_state(
  assignment.calibration_hash
) state
WHERE assignment.reviewer_oid = session_user::regrole::oid
  AND assignment.reviewer_name = session_user
  AND state.state = 'pending'
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.reviewer_calibration_responses response
    WHERE response.calibration_hash = assignment.calibration_hash
      AND response.case_hash = member.case_hash
  )
ORDER BY assignment.created_at, assignment.calibration_hash, member.ordinality;

CREATE VIEW otlet.reviewer_calibration_status
WITH (security_barrier = true) AS
SELECT
  assignment.calibration_hash,
  assignment.calibration_key,
  assignment.task_name,
  assignment.workload_revision_hash,
  state.active_workload_revision_hash,
  assignment.rubric_hash,
  state.rubric_current,
  state.gold_current,
  state.case_count,
  state.response_count,
  CASE WHEN state.completed_at IS NOT NULL
    THEN state.calibration_error_count
  END AS calibration_error_count,
  assignment.maximum_calibration_errors,
  state.completed_at,
  state.review_count,
  state.review_error_count,
  assignment.maximum_review_errors,
  state.state,
  state.review_authorized,
  assignment.created_at
FROM otlet.reviewer_calibrations assignment
CROSS JOIN LATERAL otlet.reviewer_calibration_state(
  assignment.calibration_hash
) state
WHERE assignment.reviewer_oid = session_user::regrole::oid
  AND assignment.reviewer_name = session_user
ORDER BY assignment.created_at DESC, assignment.calibration_hash;

CREATE VIEW otlet.audit_reviewer_calibration_export AS
SELECT
  assignment.calibration_hash,
  assignment.calibration_key,
  assignment.task_name,
  assignment.workload_revision_hash,
  state.active_workload_revision_hash,
  assignment.rubric_hash,
  assignment.reviewer_oid,
  assignment.reviewer_name,
  state.rubric_current,
  state.gold_current,
  state.case_count,
  state.response_count,
  CASE WHEN state.completed_at IS NOT NULL
    THEN state.calibration_error_count
  END AS calibration_error_count,
  assignment.maximum_calibration_errors,
  state.completed_at,
  state.review_count,
  state.review_error_count,
  assignment.maximum_review_errors,
  state.state,
  state.review_authorized,
  assignment.reason,
  assignment.created_by_name,
  assignment.created_as_name,
  assignment.created_at
FROM otlet.reviewer_calibrations assignment
CROSS JOIN LATERAL otlet.reviewer_calibration_state(
  assignment.calibration_hash
) state
ORDER BY assignment.created_at, assignment.calibration_hash;

CREATE FUNCTION otlet.reviewer_authority(
  task_name text,
  workload_revision_hash text,
  reviewer_oid oid
) RETURNS TABLE (
  rubric_hash text,
  calibration_hash text,
  authority_error text
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target_definition jsonb;
  active_rubric_hash text;
  calibration_state record;
  resolved_reviewer_name text;
BEGIN
  SELECT revision.definition
  INTO target_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = reviewer_authority.task_name
    AND revision.workload_revision_hash =
      reviewer_authority.workload_revision_hash;
  rubric_hash := otlet.reviewer_rubric_hash(target_definition);
  IF reviewer_authority.reviewer_oid = (
    SELECT database.datdba
    FROM pg_catalog.pg_database database
    WHERE database.datname = current_database()
  ) THEN
    calibration_hash := NULL;
    authority_error := NULL;
    RETURN NEXT;
    RETURN;
  END IF;
  IF target_definition IS NULL THEN
    authority_error := 'reviewer_rubric_missing';
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT role.rolname
  INTO resolved_reviewer_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = reviewer_authority.reviewer_oid;
  IF resolved_reviewer_name IS NULL THEN
    authority_error := 'reviewer_identity_invalid';
    RETURN NEXT;
    RETURN;
  END IF;
  IF rubric_hash IS NULL THEN
    calibration_hash := NULL;
    authority_error := NULL;
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT otlet.reviewer_rubric_hash(revision.definition)
  INTO active_rubric_hash
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = reviewer_authority.task_name;
  IF active_rubric_hash IS DISTINCT FROM rubric_hash THEN
    authority_error := 'rubric_changed';
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT assignment.calibration_hash
  INTO calibration_hash
  FROM otlet.reviewer_calibrations assignment
  WHERE assignment.task_name = reviewer_authority.task_name
    AND assignment.rubric_hash = reviewer_authority.rubric_hash
    AND assignment.reviewer_oid = reviewer_authority.reviewer_oid
    AND assignment.reviewer_name = resolved_reviewer_name
  ORDER BY assignment.created_at DESC, assignment.calibration_hash DESC
  LIMIT 1;
  IF calibration_hash IS NULL THEN
    authority_error := CASE
      WHEN EXISTS (
        SELECT 1
        FROM otlet.reviewer_calibrations prior
        WHERE prior.task_name = reviewer_authority.task_name
          AND prior.reviewer_oid = reviewer_authority.reviewer_oid
          AND prior.reviewer_name <> resolved_reviewer_name
      ) THEN 'reviewer_identity_invalid'
      WHEN EXISTS (
        SELECT 1
        FROM otlet.reviewer_calibrations prior
        WHERE prior.task_name = reviewer_authority.task_name
          AND prior.reviewer_oid = reviewer_authority.reviewer_oid
      ) THEN 'rubric_changed'
      ELSE 'calibration_required'
    END;
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT * INTO calibration_state
  FROM otlet.reviewer_calibration_state(calibration_hash);
  authority_error := CASE WHEN calibration_state.review_authorized
    THEN NULL ELSE calibration_state.state END;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.reviewer_review_queue_rows()
RETURNS TABLE (
  queue_kind text,
  next_reviewer_step text,
  task_name text,
  workload_revision_hash text,
  job_subject_id text,
  subject_id text,
  action_id bigint,
  receipt_id bigint,
  shaped_input jsonb,
  output jsonb,
  proposed_actions jsonb,
  review_rubric jsonb,
  response_contract jsonb,
  source_stale boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT
    queue.queue_kind,
    queue.next_operator_step,
    queue.task_name,
    queue.workload_revision_hash,
    queue.job_subject_id,
    queue.subject_id,
    queue.action_id,
    queue.receipt_id,
    otlet.semantic_shaped_input(
      job.input,
      revision.definition #> '{task,input_shaping}'
    ),
    queue.output,
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'action_id', proposed.id,
          'action_type', proposed.action_type,
          'payload', proposed.payload,
          'valid', proposed.status <> 'rejected'
            AND proposed.approval_status <> 'rejected'
            AND proposed.error IS NULL
        ) ORDER BY proposed.id
      )
      FROM otlet.actions proposed
      WHERE proposed.job_id = job.id
        AND proposed.output_id IS NOT DISTINCT FROM queue.output_id
        AND proposed.receipt_id IS NOT DISTINCT FROM queue.receipt_id
    ), '[]'::jsonb),
    revision.definition #> '{task,decision_contract,review_rubric}',
    jsonb_build_object(
      'answer_field', COALESCE(NULLIF(
        revision.definition #>> '{task,decision_contract,answer_field}',
        ''
      ), 'match'),
      'answer_values', COALESCE(
        revision.definition #> ARRAY[
          'task',
          'output_schema',
          'properties',
          COALESCE(NULLIF(
            revision.definition #>>
              '{task,decision_contract,answer_field}',
            ''
          ), 'match'),
          'enum'
        ],
        '[]'::jsonb
      ),
      'confidence_field', COALESCE(NULLIF(
        revision.definition #>>
          '{task,decision_contract,confidence_field}',
        ''
      ), 'confidence'),
      'confidence_values', '["high", "medium", "low"]'::jsonb,
      'action_types', COALESCE(
        revision.definition #> '{task,decision_contract,action_types}',
        '[]'::jsonb
      ) || '["none"]'::jsonb
    ),
    queue.source_stale,
    queue.created_at
  FROM otlet.review_queue queue
  LEFT JOIN otlet.actions focused_action
    ON focused_action.id = queue.action_id
  JOIN otlet.inference_receipts receipt ON receipt.id = queue.receipt_id
  JOIN otlet.jobs job
    ON job.id = COALESCE(focused_action.job_id, receipt.job_id)
  JOIN otlet.workload_revisions revision
    ON revision.task_name = queue.task_name
   AND revision.workload_revision_hash = queue.workload_revision_hash
  CROSS JOIN LATERAL otlet.reviewer_authority(
    queue.task_name,
    queue.workload_revision_hash,
    session_user::regrole::oid
  ) authority
  WHERE authority.authority_error IS NULL
    AND (
      (
        queue.action_id IS NOT NULL
        AND queue.next_operator_step IN ('approve', 'review', 'review_failure')
      )
      OR queue.queue_kind IN (
        'sampled_output',
        'abstention_output',
        'direct_rejected_output',
        'semantic_correction_re_review'
      )
    )
  ORDER BY queue.created_at, queue.task_name, queue.job_subject_id,
    queue.queue_kind;
$$;

CREATE VIEW otlet.reviewer_review_queue
WITH (security_barrier = true) AS
SELECT queue.*
FROM otlet.reviewer_review_queue_rows() queue;

ALTER TABLE otlet.review_events
ADD COLUMN reviewer_rubric_hash text CHECK (
  reviewer_rubric_hash IS NULL
  OR reviewer_rubric_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
),
ADD COLUMN reviewer_calibration_hash text REFERENCES
  otlet.reviewer_calibrations(calibration_hash),
ADD CONSTRAINT review_events_calibration_rubric_check CHECK (
  reviewer_calibration_hash IS NULL OR reviewer_rubric_hash IS NOT NULL
);

CREATE FUNCTION otlet.validate_review_event_reviewer_calibration()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  assignment otlet.reviewer_calibrations%ROWTYPE;
BEGIN
  IF NEW.reviewer_calibration_hash IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO assignment
  FROM otlet.reviewer_calibrations calibration
  WHERE calibration.calibration_hash = NEW.reviewer_calibration_hash;
  IF NOT FOUND
     OR NEW.task_name IS DISTINCT FROM assignment.task_name
     OR NEW.reviewer_rubric_hash IS DISTINCT FROM assignment.rubric_hash
     OR NEW.reviewer_identity IS DISTINCT FROM assignment.reviewer_name
     OR session_user::regrole::oid IS DISTINCT FROM assignment.reviewer_oid
     OR session_user::text IS DISTINCT FROM assignment.reviewer_name THEN
    RAISE EXCEPTION 'otlet review event calibration provenance is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER review_events_reviewer_calibration_validate
BEFORE INSERT ON otlet.review_events
FOR EACH ROW EXECUTE FUNCTION
  otlet.validate_review_event_reviewer_calibration();

CREATE FUNCTION otlet.lock_review_action_task(action_id bigint) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target_task_name text;
BEGIN
  SELECT job.task_name
  INTO target_task_name
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE action.id = lock_review_action_task.action_id;
  IF FOUND THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'otlet_workload_revision:' || target_task_name,
        0
      )
    );
  END IF;
END;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.approve_action(bigint,text)'::regprocedure
  ) INTO definition;
  IF position($needle$BEGIN
  SELECT *$needle$ IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet approve review lock rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$BEGIN
  SELECT *$needle$,
    $replacement$BEGIN
  PERFORM otlet.lock_review_action_task(approve_action.action_id);
  SELECT *$replacement$
  );

  SELECT pg_catalog.pg_get_functiondef(
    'otlet.reject_action(bigint,text,text)'::regprocedure
  ) INTO definition;
  IF position($needle$BEGIN
  UPDATE otlet.actions$needle$ IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet reject review lock rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$BEGIN
  UPDATE otlet.actions$needle$,
    $replacement$BEGIN
  PERFORM otlet.lock_review_action_task(reject_action.action_id);
  UPDATE otlet.actions$replacement$
  );

  SELECT pg_catalog.pg_get_functiondef(
    'otlet.correct_action(bigint,jsonb,text)'::regprocedure
  ) INTO definition;
  IF position($needle$BEGIN
  UPDATE otlet.actions$needle$ IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet correct review lock rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$BEGIN
  UPDATE otlet.actions$needle$,
    $replacement$BEGIN
  PERFORM otlet.lock_review_action_task(correct_action.action_id);
  UPDATE otlet.actions$replacement$
  );

  SELECT pg_catalog.pg_get_functiondef(
    'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamptz,numeric,text,text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$  PERFORM otlet.lock_eval_label_series(
    ARRAY[approve_semantic_correction.label_id]
  );$needle$ IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet semantic correction review lock rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$  PERFORM otlet.lock_eval_label_series(
    ARRAY[approve_semantic_correction.label_id]
  );$needle$,
    $replacement$  PERFORM otlet.lock_review_action_task(label.action_id)
  FROM otlet.eval_labels label
  WHERE label.id = approve_semantic_correction.label_id;
  PERFORM otlet.lock_eval_label_series(
    ARRAY[approve_semantic_correction.label_id]
  );$replacement$
  );

  SELECT pg_catalog.pg_get_functiondef(
    'otlet.label_review_sample(bigint,text,text,text,text,text)'::regprocedure
  ) INTO definition;
  IF position($needle$BEGIN
  IF NULLIF(btrim(label_review_sample.expected_answer), '') IS NULL$needle$
    IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet sampled review lock rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$BEGIN
  IF NULLIF(btrim(label_review_sample.expected_answer), '') IS NULL$needle$,
    $replacement$BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_workload_revision:' || job.task_name,
      0
    )
  )
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  WHERE receipt.id = label_review_sample.receipt_id;
  IF NULLIF(btrim(label_review_sample.expected_answer), '') IS NULL$replacement$
  );
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.record_review_event(
  outcome text,
  action_id bigint,
  receipt_id bigint,
  reason text
) RETURNS otlet.review_events
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actual_outcome text := lower(COALESCE(record_review_event.outcome, ''));
  actual_reason text := COALESCE(
    NULLIF(btrim(record_review_event.reason), ''),
    actual_outcome
  );
  role_setting text := pg_catalog.current_setting('role', true);
  reviewer_role_name text;
  target record;
  authority record;
  current_hash text;
  freshness text;
  saved otlet.review_events%ROWTYPE;
BEGIN
  IF actual_outcome NOT IN ('approve', 'reject', 'correct', 'defer', 'abstain') THEN
    RAISE EXCEPTION 'otlet review outcome % is not supported',
      record_review_event.outcome;
  END IF;
  IF num_nonnulls(record_review_event.action_id, record_review_event.receipt_id) <> 1 THEN
    RAISE EXCEPTION 'otlet review event requires exactly one action or receipt target';
  END IF;
  IF octet_length(actual_reason) > 8192 THEN
    RAISE EXCEPTION 'otlet review reason exceeds 8192 bytes';
  END IF;

  SELECT
    action.id AS action_id,
    COALESCE(action.output_id, output.id) AS output_id,
    receipt.id AS receipt_id,
    job.id AS job_id,
    job.task_name,
    job.subject_id,
    job.workload_revision_hash,
    COALESCE(
      action.source_table,
      receipt.trace_summary #>> '{mvcc,table}'
    ) AS source_table,
    COALESCE(
      action.source_hash,
      otlet.semantic_source_hash(job.input)
    ) AS source_hash,
    COALESCE(
      action.content_hash,
      otlet.semantic_content_hash(
        job.input,
        revision.definition #> '{task,input_shaping}'
      )
    ) AS content_hash,
    receipt.model_name,
    receipt.model_artifact_hash,
    receipt.prompt_hash,
    COALESCE(
      receipt.output_schema_hash,
      otlet.portable_json_hash(
        revision.definition #> '{task,output_schema}'
      )
    ) AS output_schema_hash,
    COALESCE(
      receipt.raw_output_hash,
      otlet.portable_json_hash(COALESCE(
        output.output,
        receipt.candidate_output,
        'null'::jsonb
      ))
    ) AS output_hash,
    receipt.trace_summary ->> 'runtime_fingerprint_hash'
      AS runtime_fingerprint_hash
  INTO target
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  JOIN otlet.workload_revisions revision
    ON revision.workload_revision_hash = job.workload_revision_hash
  LEFT JOIN otlet.actions action ON action.id = record_review_event.action_id
  LEFT JOIN otlet.outputs output ON output.receipt_id = receipt.id
  WHERE receipt.id = COALESCE(
      action.receipt_id,
      record_review_event.receipt_id
    )
    AND (record_review_event.action_id IS NULL OR action.id IS NOT NULL);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review target does not exist';
  END IF;

  PERFORM 1
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = target.task_name
  FOR UPDATE;
  SELECT * INTO authority
  FROM otlet.reviewer_authority(
    target.task_name,
    target.workload_revision_hash,
    session_user::regrole::oid
  );
  IF authority.authority_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet reviewer authority denied: %',
      authority.authority_error;
  END IF;

  current_hash := otlet.current_task_subject_content_hash(
    target.task_name,
    target.subject_id,
    target.workload_revision_hash
  );
  freshness := CASE
    WHEN target.content_hash IS NULL OR current_hash IS NULL THEN 'unavailable'
    WHEN target.content_hash = current_hash THEN 'fresh'
    ELSE 'stale'
  END;
  IF role_setting IS NULL OR role_setting = 'none' THEN
    reviewer_role_name := session_user;
  ELSE
    SELECT role.rolname
    INTO reviewer_role_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = role_setting::regrole;
  END IF;

  INSERT INTO otlet.review_events (
    outcome,
    reviewer_identity,
    reviewer_role,
    reason,
    job_id,
    task_name,
    subject_id,
    action_id,
    output_id,
    receipt_id,
    source_table,
    source_hash,
    content_hash,
    current_content_hash,
    source_freshness,
    model_name,
    model_artifact_hash,
    prompt_hash,
    output_schema_hash,
    output_hash,
    runtime_fingerprint_hash,
    reviewer_rubric_hash,
    reviewer_calibration_hash
  ) VALUES (
    actual_outcome,
    session_user,
    reviewer_role_name,
    actual_reason,
    target.job_id,
    target.task_name,
    target.subject_id,
    target.action_id,
    target.output_id,
    target.receipt_id,
    target.source_table,
    target.source_hash,
    target.content_hash,
    current_hash,
    freshness,
    target.model_name,
    target.model_artifact_hash,
    target.prompt_hash,
    target.output_schema_hash,
    target.output_hash,
    target.runtime_fingerprint_hash,
    authority.rubric_hash,
    authority.calibration_hash
  ) RETURNING * INTO saved;
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.reviewer_correct_action(
  action_id bigint,
  corrected jsonb DEFAULT '{}'::jsonb,
  reason text DEFAULT NULL
) RETURNS TABLE (
  label_id bigint,
  review_event_id bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  prior_review_event_id bigint;
  target record;
BEGIN
  PERFORM otlet.lock_review_action_task(reviewer_correct_action.action_id);
  SELECT
    COALESCE(
      NULLIF(reviewer_correct_action.corrected ->> 'expected_action_type', ''),
      NULLIF(reviewer_correct_action.corrected ->> 'action_type', ''),
      action.action_type
    ) AS expected_action_type,
    ARRAY(
      SELECT jsonb_array_elements_text(COALESCE(
        revision.definition #> '{task,decision_contract,action_types}',
        '[]'::jsonb
      ))
    ) AS allowed_action_types
  INTO target
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE action.id = reviewer_correct_action.action_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF jsonb_typeof(COALESCE(
       reviewer_correct_action.corrected,
       '{}'::jsonb
     )) IS DISTINCT FROM 'object'
     OR NOT (
       target.expected_action_type = 'none'
       OR target.expected_action_type = ANY(target.allowed_action_types)
     ) THEN
    RAISE EXCEPTION 'otlet reviewer correction action type is not declared';
  END IF;

  SELECT COALESCE(max(event.id), 0)
  INTO prior_review_event_id
  FROM otlet.review_events event
  WHERE event.action_id = reviewer_correct_action.action_id
    AND event.outcome = 'correct';

  SELECT label.id
  INTO label_id
  FROM otlet.correct_action(
    reviewer_correct_action.action_id,
    reviewer_correct_action.corrected,
    reviewer_correct_action.reason
  ) label;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT event.id
  INTO STRICT review_event_id
  FROM otlet.review_events event
  WHERE event.action_id = reviewer_correct_action.action_id
    AND event.outcome = 'correct'
    AND event.reviewer_identity = session_user
    AND event.id > prior_review_event_id
  ORDER BY event.id
  LIMIT 1;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.validate_reviewer_review_error() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  assignment otlet.reviewer_calibrations%ROWTYPE;
  event otlet.review_events%ROWTYPE;
  expected_definition jsonb;
BEGIN
  SELECT * INTO event
  FROM otlet.review_events review_event
  WHERE review_event.id = NEW.review_event_id;
  SELECT * INTO assignment
  FROM otlet.reviewer_calibrations calibration
  WHERE calibration.calibration_hash = NEW.calibration_hash;
  expected_definition := jsonb_build_object(
    'format', 'otlet.reviewer_review_error.v1',
    'review_event_id', NEW.review_event_id,
    'calibration_hash', NEW.calibration_hash,
    'task_name', NEW.task_name,
    'rubric_hash', NEW.rubric_hash,
    'reviewer_oid', NEW.reviewer_oid::text,
    'reviewer_name', NEW.reviewer_name,
    'reason', NEW.reason,
    'recorded_by_oid', NEW.recorded_by_oid::text,
    'recorded_by_name', NEW.recorded_by_name,
    'recorded_as_oid', NEW.recorded_as_oid::text,
    'recorded_as_name', NEW.recorded_as_name
  );
  IF event.id IS NULL
     OR assignment.calibration_hash IS NULL
     OR event.reviewer_calibration_hash IS DISTINCT FROM
       assignment.calibration_hash
     OR event.reviewer_rubric_hash IS DISTINCT FROM assignment.rubric_hash
     OR event.task_name IS DISTINCT FROM assignment.task_name
     OR event.reviewer_identity IS DISTINCT FROM assignment.reviewer_name
     OR NEW.task_name IS DISTINCT FROM assignment.task_name
     OR NEW.rubric_hash IS DISTINCT FROM assignment.rubric_hash
     OR NEW.reviewer_oid IS DISTINCT FROM assignment.reviewer_oid
     OR NEW.reviewer_name IS DISTINCT FROM assignment.reviewer_name
     OR NEW.definition IS DISTINCT FROM expected_definition
     OR NEW.review_error_hash IS DISTINCT FROM otlet.identity_hash(
       'reviewer_review_error',
       expected_definition
     ) THEN
    RAISE EXCEPTION 'otlet reviewer review error is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER reviewer_review_errors_a_validate
BEFORE INSERT ON otlet.reviewer_review_errors
FOR EACH ROW EXECUTE FUNCTION otlet.validate_reviewer_review_error();

CREATE FUNCTION otlet.record_reviewer_error(
  review_event_id bigint,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target record;
  active_role_oid oid;
  active_role_name text;
  role_setting text := pg_catalog.current_setting('role', true);
  definition jsonb;
  review_error_hash text;
  existing otlet.reviewer_review_errors%ROWTYPE;
  prior_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF session_user::regrole::oid <> (
    SELECT database.datdba
    FROM pg_catalog.pg_database database
    WHERE database.datname = current_database()
  ) THEN
    RAISE EXCEPTION 'otlet reviewer error recording requires database owner';
  END IF;
  IF record_reviewer_error.review_event_id IS NULL
     OR NULLIF(btrim(record_reviewer_error.reason), '') IS NULL
     OR octet_length(record_reviewer_error.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet reviewer review error declaration is invalid';
  END IF;

  SELECT event.task_name
  INTO target
  FROM otlet.review_events event
  WHERE event.id = record_reviewer_error.review_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet reviewer review event does not exist';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || target.task_name,
    0
  ));
  PERFORM 1
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = target.task_name
  FOR UPDATE;
  SELECT
    event.id AS review_event_id,
    event.task_name,
    event.reviewer_rubric_hash AS rubric_hash,
    event.reviewer_calibration_hash AS calibration_hash,
    assignment.reviewer_oid,
    assignment.reviewer_name
  INTO target
  FROM otlet.review_events event
  JOIN otlet.reviewer_calibrations assignment
    ON assignment.calibration_hash = event.reviewer_calibration_hash
  WHERE event.id = record_reviewer_error.review_event_id
    AND event.task_name = assignment.task_name
    AND event.reviewer_rubric_hash = assignment.rubric_hash
    AND event.reviewer_identity = assignment.reviewer_name
  FOR UPDATE OF event;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet reviewer review event lacks calibration provenance';
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    active_role_oid := session_user::regrole::oid;
    active_role_name := session_user;
  ELSE
    active_role_oid := role_setting::regrole::oid;
    SELECT role.rolname
    INTO active_role_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = active_role_oid;
  END IF;
  definition := jsonb_build_object(
    'format', 'otlet.reviewer_review_error.v1',
    'review_event_id', target.review_event_id,
    'calibration_hash', target.calibration_hash,
    'task_name', target.task_name,
    'rubric_hash', target.rubric_hash,
    'reviewer_oid', target.reviewer_oid::text,
    'reviewer_name', target.reviewer_name,
    'reason', btrim(record_reviewer_error.reason),
    'recorded_by_oid', session_user::regrole::oid::text,
    'recorded_by_name', session_user,
    'recorded_as_oid', active_role_oid::text,
    'recorded_as_name', active_role_name
  );
  review_error_hash := otlet.identity_hash(
    'reviewer_review_error',
    definition
  );

  SELECT * INTO existing
  FROM otlet.reviewer_review_errors review_error
  WHERE review_error.review_event_id = target.review_event_id;
  IF FOUND THEN
    IF existing.review_error_hash = review_error_hash
       AND existing.definition = definition THEN
      RETURN existing.review_error_hash;
    END IF;
    RAISE EXCEPTION 'otlet reviewer review error conflicts with its stored declaration';
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.reviewer_review_errors (
    review_error_hash,
    review_event_id,
    calibration_hash,
    task_name,
    rubric_hash,
    reviewer_oid,
    reviewer_name,
    definition,
    reason,
    recorded_by_oid,
    recorded_by_name,
    recorded_as_oid,
    recorded_as_name
  ) VALUES (
    review_error_hash,
    target.review_event_id,
    target.calibration_hash,
    target.task_name,
    target.rubric_hash,
    target.reviewer_oid,
    target.reviewer_name,
    definition,
    btrim(record_reviewer_error.reason),
    session_user::regrole::oid,
    session_user,
    active_role_oid,
    active_role_name
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RETURN review_error_hash;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('otlet.evaluation_append', COALESCE(prior_append, ''), true);
  RAISE;
END;
$$;

CREATE OR REPLACE VIEW otlet.audit_review_event_export AS
SELECT
  event.id AS review_event_id,
  event.outcome,
  event.reviewer_identity,
  event.reviewer_role,
  event.reason,
  event.job_id,
  event.task_name,
  event.subject_id,
  event.action_id,
  event.output_id,
  event.receipt_id,
  event.source_table,
  event.source_hash,
  event.content_hash,
  event.current_content_hash,
  event.source_freshness,
  event.model_name,
  event.model_artifact_hash,
  event.prompt_hash,
  event.output_schema_hash,
  event.output_hash,
  event.runtime_fingerprint_hash,
  event.reviewed_at,
  event.reviewer_rubric_hash,
  event.reviewer_calibration_hash
FROM otlet.review_events event;

CREATE FUNCTION otlet.guard_semantic_correction_reviewer_authority()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  authority record;
BEGIN
  PERFORM 1
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = NEW.task_name
  FOR UPDATE;
  SELECT * INTO authority
  FROM otlet.reviewer_authority(
    NEW.task_name,
    NEW.workload_revision_hash,
    session_user::regrole::oid
  );
  IF authority.authority_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet reviewer authority denied: %',
      authority.authority_error;
  END IF;
  PERFORM otlet.record_review_event(
    'approve',
    NEW.original_action_id,
    NULL,
    'Semantic correction approval: ' || NEW.approval_reason
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER semantic_correction_overrides_a_reviewer_authority
BEFORE INSERT ON otlet.semantic_correction_overrides
FOR EACH ROW EXECUTE FUNCTION
  otlet.guard_semantic_correction_reviewer_authority();

CREATE OR REPLACE VIEW otlet.access_policy_status AS
WITH reviewer_functions(oid) AS (
  SELECT unnest(ARRAY[
    'otlet.approve_action(bigint,text)'::regprocedure::oid,
    'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
    'otlet.reviewer_correct_action(bigint,jsonb,text)'::regprocedure::oid,
    'otlet.defer_action(bigint,text)'::regprocedure::oid,
    'otlet.abstain_review(bigint,text)'::regprocedure::oid,
    'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamp with time zone,numeric,text,text)'::regprocedure::oid,
    'otlet.label_review_sample(bigint,text,text,text,text,text)'::regprocedure::oid,
    'otlet.submit_reviewer_calibration(text,text,text,text,text)'::regprocedure::oid
  ])
), reviewer_status AS (
  SELECT
    count(*)::bigint AS function_count,
    count(*) FILTER (WHERE function.prosecdef)::bigint
      AS security_definer_count,
    count(*) FILTER (
      WHERE function.proconfig @>
        ARRAY['search_path=pg_catalog, otlet, pg_temp']
    )::bigint AS fixed_search_path_count
  FROM reviewer_functions expected
  JOIN pg_catalog.pg_proc function ON function.oid = expected.oid
), operator_functions(oid) AS (
  SELECT unnest(ARRAY[
    'otlet.dry_run_action(bigint)'::regprocedure::oid,
    'otlet.apply_action(bigint)'::regprocedure::oid,
    'otlet.application_retry_job(bigint,text)'::regprocedure::oid
  ])
), operator_status AS (
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
), portable_status AS (
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
  pg_catalog.has_schema_privilege(
    'public', 'otlet', 'USAGE'
  ) AS public_schema_usage,
  (
    SELECT count(*)::bigint
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND pg_catalog.has_function_privilege(
        'public', function.oid, 'EXECUTE'
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
        pg_catalog.has_table_privilege('public', relation.oid, 'SELECT')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'INSERT')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'UPDATE')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'DELETE')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'TRUNCATE')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'REFERENCES')
        OR pg_catalog.has_table_privilege('public', relation.oid, 'TRIGGER')
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
        pg_catalog.has_sequence_privilege('public', relation.oid, 'USAGE')
        OR pg_catalog.has_sequence_privilege('public', relation.oid, 'SELECT')
        OR pg_catalog.has_sequence_privilege('public', relation.oid, 'UPDATE')
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
    AS portable_rpc_fixed_search_path_functions,
  reviewer_status.function_count AS reviewer_functions,
  reviewer_status.security_definer_count
    AS reviewer_security_definer_functions,
  reviewer_status.fixed_search_path_count
    AS reviewer_fixed_search_path_functions
FROM operator_status
CROSS JOIN portable_status
CROSS JOIN reviewer_status;

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
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist',
      finish_access_policy_grant.target_role::oid;
  END IF;

  IF finish_access_policy_grant.policy_name IN ('auditor', 'operator') THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export, '
      'otlet.audit_review_sample_export, '
      'otlet.audit_reviewer_calibration_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text), '
      'otlet.semantic_correction_status_for_task(text), '
      'otlet.pair_constraint_contract_hash(jsonb), '
      'otlet.reviewer_calibration_state(text) TO %I',
      role_name
    );
  END IF;
  IF finish_access_policy_grant.policy_name = 'operator' THEN
    EXECUTE pg_catalog.format(
      'REVOKE EXECUTE ON FUNCTION '
      'otlet.approve_action(bigint,text), '
      'otlet.reject_action(bigint,text,text), '
      'otlet.label_action(bigint,text,text,text,text,text), '
      'otlet.correct_action(bigint,jsonb,text), '
      'otlet.reviewer_correct_action(bigint,jsonb,text), '
      'otlet.defer_action(bigint,text), '
      'otlet.abstain_review(bigint,text), '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text) FROM %I',
      role_name
    );
  ELSIF finish_access_policy_grant.policy_name = 'reviewer' THEN
    EXECUTE pg_catalog.format(
      'REVOKE EXECUTE ON FUNCTION '
      'otlet.correct_action(bigint,jsonb,text) FROM %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.reviewer_review_queue, '
      'otlet.reviewer_calibration_queue, '
      'otlet.reviewer_calibration_status TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.approve_action(bigint,text), '
      'otlet.reject_action(bigint,text,text), '
      'otlet.reviewer_correct_action(bigint,jsonb,text), '
      'otlet.defer_action(bigint,text), '
      'otlet.abstain_review(bigint,text), '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text), '
      'otlet.submit_reviewer_calibration(text,text,text,text,text), '
      'otlet.reviewer_calibration_state(text), '
      'otlet.reviewer_calibration_member_token(text,text), '
      'otlet.reviewer_review_queue_rows() TO %I',
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

CREATE OR REPLACE FUNCTION otlet.grant_operator_access(target_role regrole)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  old_revision_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || grant_operator_access.target_role::oid::text,
      0
    )
  );
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = grant_operator_access.target_role::oid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist',
      grant_operator_access.target_role::oid;
  END IF;
  PERFORM otlet.grant_auditor_access(grant_operator_access.target_role);
  old_revision_hash := otlet.access_policy_revision(
    grant_operator_access.target_role
  );
  EXECUTE pg_catalog.format(
    'GRANT USAGE ON TYPE otlet.actions TO %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'GRANT EXECUTE ON FUNCTION '
    'otlet.dry_run_action(bigint), '
    'otlet.apply_action(bigint), '
    'otlet.application_retry_job(bigint,text) TO %I',
    role_name
  );
  PERFORM otlet.finish_access_policy_grant(
    'operator',
    grant_operator_access.target_role,
    old_revision_hash
  );
END;
$$;

CREATE FUNCTION otlet.grant_reviewer_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  old_revision_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || grant_reviewer_access.target_role::oid::text,
      0
    )
  );
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = grant_reviewer_access.target_role::oid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist',
      grant_reviewer_access.target_role::oid;
  END IF;
  old_revision_hash := otlet.access_policy_revision(
    grant_reviewer_access.target_role
  );
  EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
  EXECUTE pg_catalog.format(
    'GRANT USAGE ON TYPE '
    'otlet.actions, otlet.eval_labels, otlet.review_events TO %I',
    role_name
  );
  PERFORM otlet.finish_access_policy_grant(
    'reviewer',
    grant_reviewer_access.target_role,
    old_revision_hash
  );
END;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  IF position(
    '''otlet.audit_review_sample_export''::text' IN definition
  ) = 0 OR position('5 AS policy_version' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet reviewer calibration redaction registry rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    '''otlet.audit_review_sample_export''::text',
    '''otlet.audit_reviewer_calibration_export''::text, ' ||
      '''otlet.audit_review_sample_export''::text'
  );
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS ' ||
    pg_catalog.replace(definition, '5 AS policy_version', '6 AS policy_version');
END;
$migration$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) IN ('auditor', 'operator')
      AND pg_catalog.has_table_privilege(
        role.oid,
        'otlet.audit_review_export',
        'SELECT'
      )
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_reviewer_calibration_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.reviewer_calibration_state(text) TO %I',
      role_name
    );
  END LOOP;

  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) = 'operator'
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE EXECUTE ON FUNCTION '
      'otlet.approve_action(bigint,text), '
      'otlet.reject_action(bigint,text,text), '
      'otlet.label_action(bigint,text,text,text,text,text), '
      'otlet.correct_action(bigint,jsonb,text), '
      'otlet.reviewer_correct_action(bigint,jsonb,text), '
      'otlet.defer_action(bigint,text), '
      'otlet.abstain_review(bigint,text), '
      'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text) FROM %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.reviewer_calibrations FROM PUBLIC;
REVOKE ALL ON TABLE otlet.reviewer_calibration_responses FROM PUBLIC;
REVOKE ALL ON TABLE otlet.reviewer_review_errors FROM PUBLIC;
REVOKE ALL ON TABLE otlet.reviewer_calibration_queue FROM PUBLIC;
REVOKE ALL ON TABLE otlet.reviewer_calibration_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.reviewer_review_queue FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_reviewer_calibration_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_rubric_error(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_rubric_hash(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_workload_reviewer_rubric()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_calibration_member_token(text,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_gold_visibility_error(oid)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_calibration_assignment_error(
  text,text,text,oid,text,text[]
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_reviewer_calibration()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_reviewer_calibration_response()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_reviewer_review_error()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  otlet.validate_review_event_reviewer_calibration() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lock_review_action_task(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_correct_action(bigint,jsonb,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_calibration_state(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_reviewer_calibration(
  text,regrole,text,text[],text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.submit_reviewer_calibration(
  text,text,text,text,text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_reviewer_error(bigint,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_authority(text,text,oid)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reviewer_review_queue_rows() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  otlet.guard_semantic_correction_reviewer_authority() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_operator_access(regrole) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_reviewer_access(regrole) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.finish_access_policy_grant(
  text,regrole,text
) FROM PUBLIC;
