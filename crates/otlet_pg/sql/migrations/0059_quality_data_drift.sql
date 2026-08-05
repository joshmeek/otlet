CREATE TABLE otlet.task_candidate_observations (
  observation_hash text PRIMARY KEY CHECK (
    observation_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  workload_revision_hash text NOT NULL,
  candidate_rows bigint NOT NULL CHECK (candidate_rows >= 0),
  candidate_bytes bigint NOT NULL CHECK (candidate_bytes >= 0),
  largest_input_bytes bigint NOT NULL CHECK (
    largest_input_bytes >= 0 AND largest_input_bytes <= candidate_bytes
  ),
  admitted boolean NOT NULL,
  rejection_reason text CHECK (rejection_reason IN (
    'row_cap',
    'queue_depth_cap',
    'input_byte_cap',
    'model_queued_input_byte_cap',
    'total_queued_input_byte_cap'
  )),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (
    (admitted AND rejection_reason IS NULL)
    OR (NOT admitted AND rejection_reason IS NOT NULL)
  )
);

CREATE INDEX task_candidate_observations_task_created_idx
ON otlet.task_candidate_observations (task_name, created_at DESC, observation_hash);

CREATE TABLE otlet.quality_data_drift_reports (
  report_hash text PRIMARY KEY CHECK (
    report_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL UNIQUE
    REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  evaluation_report_hash text NOT NULL UNIQUE
    REFERENCES otlet.evaluation_slice_reports(report_hash),
  candidate_observation_hash text NOT NULL
    REFERENCES otlet.task_candidate_observations(observation_hash),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL AND octet_length(reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION otlet.guard_quality_data_drift_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.quality_data_drift_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet quality and data drift evidence is append only';
END;
$$;

CREATE FUNCTION otlet.validate_task_candidate_observation() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
BEGIN
  IF ARRAY(
       SELECT key FROM jsonb_object_keys(NEW.definition) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'admitted',
       'candidate_bytes',
       'candidate_rows',
       'format',
       'largest_input_bytes',
       'observed_at',
       'rejection_reason',
       'task_name',
       'workload_revision_hash'
     ]::text[]
     OR NEW.definition ->> 'format' IS DISTINCT FROM
       'otlet.task_candidate_observation.v1'
     OR NEW.definition ->> 'task_name' IS DISTINCT FROM NEW.task_name
     OR NEW.definition ->> 'workload_revision_hash' IS DISTINCT FROM
       NEW.workload_revision_hash
     OR NEW.definition ->> 'candidate_rows' IS DISTINCT FROM NEW.candidate_rows::text
     OR NEW.definition ->> 'candidate_bytes' IS DISTINCT FROM NEW.candidate_bytes::text
     OR NEW.definition ->> 'largest_input_bytes' IS DISTINCT FROM
       NEW.largest_input_bytes::text
     OR (NEW.definition ->> 'admitted')::boolean IS DISTINCT FROM NEW.admitted
     OR NEW.definition ->> 'rejection_reason' IS DISTINCT FROM NEW.rejection_reason
     OR NEW.definition ->> 'observed_at' IS DISTINCT FROM to_char(
       NEW.created_at AT TIME ZONE 'UTC',
       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
     )
     OR NEW.observation_hash IS DISTINCT FROM
       otlet.identity_hash('task_candidate_observation', NEW.definition) THEN
    RAISE EXCEPTION 'otlet task candidate observation identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER task_candidate_observations_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.task_candidate_observations
FOR EACH ROW EXECUTE FUNCTION otlet.guard_quality_data_drift_append();

CREATE TRIGGER task_candidate_observations_b_validate
BEFORE INSERT ON otlet.task_candidate_observations
FOR EACH ROW EXECUTE FUNCTION otlet.validate_task_candidate_observation();

CREATE TRIGGER task_candidate_observations_truncate_guard
BEFORE TRUNCATE ON otlet.task_candidate_observations
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_quality_data_drift_append();

CREATE FUNCTION otlet.record_task_candidate_observation(
  task_name text,
  workload_revision_hash text,
  candidate_rows bigint,
  candidate_bytes bigint,
  largest_input_bytes bigint,
  admitted boolean,
  rejection_reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  observed_at timestamptz := clock_timestamp();
  definition jsonb;
  observation_hash text;
  previous_append text := current_setting('otlet.quality_data_drift_append', true);
BEGIN
  IF record_task_candidate_observation.candidate_rows < 0
     OR record_task_candidate_observation.candidate_bytes < 0
     OR record_task_candidate_observation.largest_input_bytes < 0
     OR record_task_candidate_observation.largest_input_bytes >
       record_task_candidate_observation.candidate_bytes
     OR record_task_candidate_observation.admitted IS NULL
     OR (
       record_task_candidate_observation.admitted
       AND record_task_candidate_observation.rejection_reason IS NOT NULL
     )
     OR (
       NOT record_task_candidate_observation.admitted
       AND COALESCE(record_task_candidate_observation.rejection_reason, '') NOT IN (
         'row_cap',
         'queue_depth_cap',
         'input_byte_cap',
         'model_queued_input_byte_cap',
         'total_queued_input_byte_cap'
       )
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_revisions revision
       WHERE revision.task_name = record_task_candidate_observation.task_name
         AND revision.workload_revision_hash =
           record_task_candidate_observation.workload_revision_hash
     ) THEN
    RAISE EXCEPTION 'otlet task candidate observation is invalid';
  END IF;

  definition := jsonb_build_object(
    'format', 'otlet.task_candidate_observation.v1',
    'task_name', record_task_candidate_observation.task_name,
    'workload_revision_hash',
      record_task_candidate_observation.workload_revision_hash,
    'candidate_rows', record_task_candidate_observation.candidate_rows,
    'candidate_bytes', record_task_candidate_observation.candidate_bytes,
    'largest_input_bytes', record_task_candidate_observation.largest_input_bytes,
    'admitted', record_task_candidate_observation.admitted,
    'rejection_reason', to_jsonb(record_task_candidate_observation.rejection_reason),
    'observed_at', to_char(
      observed_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    )
  );
  observation_hash := otlet.identity_hash('task_candidate_observation', definition);
  PERFORM set_config('otlet.quality_data_drift_append', 'on', true);
  INSERT INTO otlet.task_candidate_observations (
    observation_hash,
    task_name,
    workload_revision_hash,
    candidate_rows,
    candidate_bytes,
    largest_input_bytes,
    admitted,
    rejection_reason,
    definition,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name,
    created_at
  ) VALUES (
    observation_hash,
    record_task_candidate_observation.task_name,
    record_task_candidate_observation.workload_revision_hash,
    record_task_candidate_observation.candidate_rows,
    record_task_candidate_observation.candidate_bytes,
    record_task_candidate_observation.largest_input_bytes,
    record_task_candidate_observation.admitted,
    record_task_candidate_observation.rejection_reason,
    definition,
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user,
    observed_at
  );
  PERFORM set_config(
    'otlet.quality_data_drift_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN observation_hash;
END;
$$;

CREATE FUNCTION otlet.quality_data_input_shape(input jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  WITH RECURSIVE complexity AS (
    SELECT * FROM otlet.bounded_jsonb_complexity($1, 16, 4096)
  ), safe AS (
    SELECT $1 AS input
    FROM complexity
    WHERE json_depth <= 16 AND json_nodes <= 4096
  ), node(path, value) AS (
    SELECT ARRAY[]::text[], safe.input
    FROM safe
    UNION ALL
    SELECT node.path || child.segment, child.value
    FROM node
    CROSS JOIN LATERAL (
      SELECT member.key AS segment, member.value
      FROM jsonb_each(
        CASE WHEN jsonb_typeof(node.value) = 'object'
          THEN node.value ELSE '{}'::jsonb END
      ) member
      UNION ALL
      SELECT '*'::text, member.value
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(node.value) = 'array'
          THEN node.value ELSE '[]'::jsonb END
      ) member
    ) child
  ), signature AS (
    SELECT DISTINCT path, jsonb_typeof(value) AS value_type
    FROM node
  )
  SELECT CASE WHEN EXISTS (SELECT 1 FROM safe) THEN otlet.identity_hash(
    'quality_data_input_shape',
    COALESCE(jsonb_agg(
      jsonb_build_object('path', path, 'type', value_type)
      ORDER BY path, value_type
    ), '[]'::jsonb)
  ) END
  FROM signature;
$$;

CREATE FUNCTION otlet.quality_data_distribution_drift(
  baseline jsonb,
  observed jsonb
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT COALESCE(sum(abs(
    COALESCE((baseline ->> bucket)::numeric, 0)
    - COALESCE((observed ->> bucket)::numeric, 0)
  )), 0) / 2
  FROM (
    SELECT key AS bucket FROM jsonb_object_keys(baseline) key
    UNION
    SELECT key AS bucket FROM jsonb_object_keys(observed) key
  ) buckets;
$$;

CREATE FUNCTION otlet.quality_data_reviewer_overturn(report_hash text)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
  WITH report_case AS (
    SELECT evaluation_case.case_hash, label.action_id, label.receipt_id
    FROM otlet.evaluation_slice_reports report
    JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
    CROSS JOIN LATERAL unnest(run.case_hashes) listed(case_hash)
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = listed.case_hash
    JOIN otlet.eval_labels label ON label.id = evaluation_case.label_id
    WHERE report.report_hash = quality_data_reviewer_overturn.report_hash
  ), evidence AS (
    SELECT
      report_case.case_hash,
      review.id AS review_event_id,
      review.outcome,
      review.output_hash,
      review.reviewed_at
    FROM report_case
    LEFT JOIN LATERAL (
      SELECT event.*
      FROM otlet.review_events event
      WHERE event.outcome IN ('approve', 'reject', 'correct')
        AND (
          (report_case.action_id IS NOT NULL
            AND event.action_id = report_case.action_id)
          OR (report_case.action_id IS NULL
            AND event.receipt_id = report_case.receipt_id)
        )
      ORDER BY event.reviewed_at DESC, event.id DESC
      LIMIT 1
    ) review ON true
  ), rollup AS (
    SELECT
      count(review_event_id)::integer AS support,
      count(*) FILTER (WHERE outcome IN ('reject', 'correct'))::integer AS overturns,
      otlet.identity_hash(
        'quality_data_reviewer_overturn',
        COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'case_hash', case_hash,
          'review_event_id', review_event_id,
          'outcome', outcome,
          'output_hash', output_hash,
          'reviewed_at', reviewed_at
        )) ORDER BY case_hash), '[]'::jsonb)
      ) AS evidence_hash
    FROM evidence
  )
  SELECT jsonb_build_object(
    'value', CASE WHEN support > 0 THEN to_jsonb(overturns::numeric / support)
      ELSE 'null'::jsonb END,
    'support', support,
    'overturns', overturns,
    'evidence_hash', evidence_hash
  )
  FROM rollup;
$$;

CREATE FUNCTION otlet.quality_data_report_metrics(
  report_hash text,
  variant text
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH report_row AS MATERIALIZED (
    SELECT report.report_hash, report.run_hash
    FROM otlet.evaluation_slice_reports report
    WHERE report.report_hash = quality_data_report_metrics.report_hash
  ), report_case AS MATERIALIZED (
    SELECT evaluation_case.*
    FROM report_row report
    JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
    CROSS JOIN LATERAL unnest(run.case_hashes) listed(case_hash)
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = listed.case_hash
  ), case_shape AS (
    SELECT case_hash, otlet.quality_data_input_shape(shaped_input) AS shape_hash
    FROM report_case
  ), shape_bucket AS (
    SELECT shape_hash AS bucket, count(*)::integer AS bucket_support
    FROM case_shape
    WHERE shape_hash IS NOT NULL
    GROUP BY shape_hash
  ), shape_total AS (
    SELECT COALESCE(sum(bucket_support), 0)::integer AS support
    FROM shape_bucket
  ), shape_distribution AS (
    SELECT COALESCE(jsonb_object_agg(
      bucket.bucket,
      to_jsonb(bucket.bucket_support::numeric / NULLIF(total.support, 0))
      ORDER BY bucket.bucket
    ), '{}'::jsonb) AS distribution
    FROM shape_bucket bucket
    CROSS JOIN shape_total total
  ), class_bucket AS (
    SELECT expected_answer AS bucket, count(*)::integer AS bucket_support
    FROM report_case
    GROUP BY expected_answer
  ), class_total AS (
    SELECT COALESCE(sum(bucket_support), 0)::integer AS support
    FROM class_bucket
  ), class_distribution AS (
    SELECT COALESCE(jsonb_object_agg(
      bucket.bucket,
      to_jsonb(bucket.bucket_support::numeric / NULLIF(total.support, 0))
      ORDER BY bucket.bucket
    ), '{}'::jsonb) AS distribution
    FROM class_bucket bucket
    CROSS JOIN class_total total
  ), result_evidence AS (
    SELECT
      execution.case_hash,
      result.result_hash,
      CASE WHEN result.result_hash IS NOT NULL
        AND NULLIF(result.decision_diff ->> 'observed_answer', '') IS NOT NULL
        AND NOT COALESCE(
          revision.definition #> '{task,decision_contract,abstain_values}',
          '["unclear"]'::jsonb
        ) ? (result.decision_diff ->> 'observed_answer')
        AND jsonb_array_length(COALESCE(
          result.approval_diff -> 'valid_action_types',
          '[]'::jsonb
        )) > 0 THEN
        NOT (
          COALESCE((result.decision_diff ->> 'answer_matches')::boolean, false)
          AND COALESCE(
            (result.approval_diff ->> 'expected_action_present')::boolean,
            false
          )
          AND COALESCE(
            result.approval_diff -> 'valid_action_types',
            '[]'::jsonb
          ) <@ jsonb_build_array(
            result.approval_diff ->> 'expected_action_type'
          )
        )
      END AS false_trust
    FROM report_row report
    JOIN otlet.evaluation_executions execution
      ON execution.run_hash = report.run_hash
     AND execution.variant = quality_data_report_metrics.variant
    JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = execution.workload_revision_hash
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
  ), false_trust AS (
    SELECT
      count(false_trust)::integer AS support,
      avg(false_trust::integer)::numeric AS value,
      otlet.identity_hash(
        'quality_data_false_trust',
        COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'case_hash', case_hash,
          'result_hash', result_hash,
          'false_trust', false_trust
        )) ORDER BY case_hash), '[]'::jsonb)
      ) AS evidence_hash
    FROM result_evidence
  ), overall AS (
    SELECT status.metrics
    FROM otlet.evaluation_slice_status status
    WHERE status.report_hash = quality_data_report_metrics.report_hash
      AND status.variant = quality_data_report_metrics.variant
      AND status.slice_kind = 'overall'
      AND status.slice = '{"all":true}'::jsonb
  )
  SELECT jsonb_build_object(
    'case_support', (SELECT count(*) FROM report_case),
    'input_shape', jsonb_build_object(
      'distribution', (SELECT distribution FROM shape_distribution),
      'support', (SELECT support FROM shape_total)
    ),
    'class', jsonb_build_object(
      'distribution', (SELECT distribution FROM class_distribution),
      'support', (SELECT support FROM class_total)
    ),
    'abstention', overall.metrics -> 'abstention',
    'escalation', overall.metrics -> 'escalation',
    'reviewer_overturn', otlet.quality_data_reviewer_overturn(
      quality_data_report_metrics.report_hash
    ),
    'false_trust', jsonb_build_object(
      'value', to_jsonb(false_trust.value),
      'support', false_trust.support,
      'evidence_hash', false_trust.evidence_hash,
      'definition', 'answer_and_valid_expected_action'
    )
  )
  FROM overall
  CROSS JOIN false_trust;
$$;

CREATE FUNCTION otlet.quality_data_drift_declaration_valid(declaration jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  dimension text;
  maximum_drift jsonb;
  reviewer_overturn jsonb;
  reviewer_support integer;
  reviewer_overturns integer;
BEGIN
  IF jsonb_typeof(declaration) IS DISTINCT FROM 'object' THEN
    RETURN false;
  END IF;
  IF ARRAY(
    SELECT key FROM jsonb_object_keys(declaration) key ORDER BY key
  ) IS DISTINCT FROM ARRAY[
    'candidate_observation_hash',
    'format',
    'maximum_drift',
    'minimum_support',
    'report_hash',
    'reviewer_overturn',
    'variant'
  ]::text[] THEN
    RETURN false;
  END IF;
  IF declaration ->> 'format' IS DISTINCT FROM 'otlet.quality_data_drift.v1'
     OR COALESCE(declaration ->> 'report_hash', '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR COALESCE(declaration ->> 'candidate_observation_hash', '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR COALESCE(declaration ->> 'variant', '') NOT IN ('baseline', 'candidate')
     OR jsonb_typeof(declaration -> 'minimum_support') IS DISTINCT FROM 'number'
     OR declaration ->> 'minimum_support' !~ '^[1-9][0-9]{0,9}$'
     OR (declaration ->> 'minimum_support')::numeric > 2147483647
     OR jsonb_typeof(declaration -> 'maximum_drift') IS DISTINCT FROM 'object'
     OR jsonb_typeof(declaration -> 'reviewer_overturn') IS DISTINCT FROM 'object' THEN
    RETURN false;
  END IF;

  maximum_drift := declaration -> 'maximum_drift';
  IF ARRAY(
    SELECT key FROM jsonb_object_keys(maximum_drift) key ORDER BY key
  ) IS DISTINCT FROM ARRAY[
    'abstention',
    'candidate_volume',
    'class',
    'escalation',
    'false_trust',
    'input_shape',
    'reviewer_overturn'
  ]::text[] THEN
    RETURN false;
  END IF;
  FOREACH dimension IN ARRAY ARRAY[
    'input_shape',
    'candidate_volume',
    'class',
    'abstention',
    'escalation',
    'reviewer_overturn',
    'false_trust'
  ] LOOP
    IF jsonb_typeof(maximum_drift -> dimension) IS DISTINCT FROM 'number'
       OR (maximum_drift ->> dimension)::numeric < 0
       OR (
         dimension <> 'candidate_volume'
         AND (maximum_drift ->> dimension)::numeric > 1
       ) THEN
      RETURN false;
    END IF;
  END LOOP;

  reviewer_overturn := declaration -> 'reviewer_overturn';
  IF ARRAY(
    SELECT key FROM jsonb_object_keys(reviewer_overturn) key ORDER BY key
  ) IS DISTINCT FROM ARRAY[
    'evidence_hash', 'overturns', 'support', 'value'
  ]::text[]
     OR COALESCE(reviewer_overturn ->> 'evidence_hash', '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR jsonb_typeof(reviewer_overturn -> 'support') IS DISTINCT FROM 'number'
     OR reviewer_overturn ->> 'support' !~ '^(0|[1-9][0-9]{0,9})$'
     OR jsonb_typeof(reviewer_overturn -> 'overturns') IS DISTINCT FROM 'number'
     OR reviewer_overturn ->> 'overturns' !~ '^(0|[1-9][0-9]{0,9})$' THEN
    RETURN false;
  END IF;
  reviewer_support := (reviewer_overturn ->> 'support')::integer;
  reviewer_overturns := (reviewer_overturn ->> 'overturns')::integer;
  IF reviewer_overturns > reviewer_support
     OR (
       reviewer_support = 0
       AND reviewer_overturn -> 'value' IS DISTINCT FROM 'null'::jsonb
     )
     OR (
       reviewer_support > 0
       AND (
         jsonb_typeof(reviewer_overturn -> 'value') IS DISTINCT FROM 'number'
         OR (reviewer_overturn ->> 'value')::numeric IS DISTINCT FROM
           reviewer_overturns::numeric / reviewer_support
       )
     ) THEN
    RETURN false;
  END IF;
  RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN false;
END;
$$;

CREATE FUNCTION otlet.validate_quality_data_drift_contract() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  declaration jsonb;
  eligible_members jsonb;
  baseline_report record;
  baseline_observation record;
  selected_revision_hash text;
BEGIN
  IF NEW.definition #>> '{population,rule,kind}' IS DISTINCT FROM
       'quality_data_drift' THEN
    RETURN NEW;
  END IF;

  declaration := NEW.definition #> '{baseline,definition}';
  eligible_members := NEW.definition #> '{population,rule,eligible_members}';
  IF NOT otlet.quality_data_drift_declaration_valid(declaration) THEN
    RAISE EXCEPTION 'otlet quality and data drift baseline is invalid';
  END IF;
  IF NEW.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.evaluation_slice_member_manifest_valid(eligible_members) THEN
    RAISE EXCEPTION 'otlet quality and data drift requires an exact full manifest';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(eligible_members) member
    WHERE (member ->> 'included')::boolean IS DISTINCT FROM true
  ) THEN
    RAISE EXCEPTION 'otlet quality and data drift requires an exact full manifest';
  END IF;

  SELECT
    report.created_at,
    report.definition,
    run.task_name,
    run.baseline_workload_revision_hash,
    run.candidate_workload_revision_hash
  INTO baseline_report
  FROM otlet.evaluation_slice_reports report
  JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
  WHERE report.report_hash = declaration ->> 'report_hash';
  IF NOT FOUND
     OR baseline_report.task_name IS DISTINCT FROM NEW.task_name
     OR baseline_report.definition #>> '{population,sampling_method,mode}'
       IS DISTINCT FROM 'full'
     OR baseline_report.created_at > NEW.created_at
     OR baseline_report.created_at >= (
       NEW.definition #>> '{observation_window,starts_at}'
     )::timestamptz
     OR NOT EXISTS (
       SELECT 1
       FROM jsonb_array_elements(baseline_report.definition -> 'slices') slice
       WHERE slice ->> 'variant' = declaration ->> 'variant'
         AND slice ->> 'slice_kind' = 'overall'
     ) THEN
    RAISE EXCEPTION 'otlet quality and data drift baseline report is invalid';
  END IF;
  selected_revision_hash := CASE declaration ->> 'variant'
    WHEN 'baseline' THEN baseline_report.baseline_workload_revision_hash
    ELSE baseline_report.candidate_workload_revision_hash
  END;
  IF selected_revision_hash IS DISTINCT FROM NEW.baseline_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet quality and data drift baseline revision is invalid';
  END IF;

  SELECT observation.* INTO baseline_observation
  FROM otlet.task_candidate_observations observation
  WHERE observation.observation_hash = declaration ->> 'candidate_observation_hash';
  IF NOT FOUND
     OR baseline_observation.task_name IS DISTINCT FROM NEW.task_name
     OR baseline_observation.workload_revision_hash IS DISTINCT FROM
       NEW.baseline_workload_revision_hash
     OR baseline_observation.rejection_reason = 'row_cap'
     OR baseline_observation.created_at > NEW.created_at
     OR declaration -> 'reviewer_overturn' IS DISTINCT FROM
       otlet.quality_data_reviewer_overturn(declaration ->> 'report_hash') THEN
    RAISE EXCEPTION 'otlet quality and data drift baseline evidence is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_contracts_c_quality_data_drift
BEFORE INSERT ON otlet.workload_acceptance_contracts
FOR EACH ROW EXECUTE FUNCTION otlet.validate_quality_data_drift_contract();

CREATE FUNCTION otlet.validate_quality_data_drift_report() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF ARRAY(
       SELECT key FROM jsonb_object_keys(NEW.definition) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'baseline_candidate_observation_hash',
       'baseline_evaluation_report_hash',
       'contract_hash',
       'format',
       'non_authoritative',
       'observed_candidate_observation_hash',
       'observed_evaluation_report_hash',
       'reason',
       'signals'
     ]::text[]
     OR NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.quality_data_drift.report.v1'
     OR NEW.definition ->> 'contract_hash' IS DISTINCT FROM NEW.contract_hash
     OR NEW.definition ->> 'observed_evaluation_report_hash' IS DISTINCT FROM
       NEW.evaluation_report_hash
     OR NEW.definition ->> 'observed_candidate_observation_hash' IS DISTINCT FROM
       NEW.candidate_observation_hash
     OR NEW.definition ->> 'reason' IS DISTINCT FROM NEW.reason
     OR NEW.definition -> 'non_authoritative' IS DISTINCT FROM 'true'::jsonb
     OR jsonb_typeof(NEW.definition -> 'signals') IS DISTINCT FROM 'array'
     OR jsonb_array_length(NEW.definition -> 'signals') <> 7
     OR ARRAY(
       SELECT signal ->> 'dimension'
       FROM jsonb_array_elements(NEW.definition -> 'signals') signal
       ORDER BY signal ->> 'dimension'
     ) IS DISTINCT FROM ARRAY[
       'abstention',
       'candidate_volume',
       'class',
       'escalation',
       'false_trust',
       'input_shape',
       'reviewer_overturn'
     ]::text[]
     OR NEW.report_hash IS DISTINCT FROM
       otlet.identity_hash('quality_data_drift_report', NEW.definition) THEN
    RAISE EXCEPTION 'otlet quality and data drift report identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER quality_data_drift_reports_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.quality_data_drift_reports
FOR EACH ROW EXECUTE FUNCTION otlet.guard_quality_data_drift_append();

CREATE TRIGGER quality_data_drift_reports_b_validate
BEFORE INSERT ON otlet.quality_data_drift_reports
FOR EACH ROW EXECUTE FUNCTION otlet.validate_quality_data_drift_report();

CREATE TRIGGER quality_data_drift_reports_truncate_guard
BEFORE TRUNCATE ON otlet.quality_data_drift_reports
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_quality_data_drift_append();

CREATE FUNCTION otlet.record_quality_data_drift_report(
  contract_hash text,
  evaluation_report_hash text,
  candidate_observation_hash text,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  declaration jsonb;
  baseline_observation otlet.task_candidate_observations%ROWTYPE;
  observed_observation otlet.task_candidate_observations%ROWTYPE;
  observed_report record;
  baseline_metrics jsonb;
  observed_metrics jsonb;
  signals jsonb;
  definition jsonb;
  report_hash text;
  existing_report otlet.quality_data_drift_reports%ROWTYPE;
  minimum_support integer;
  previous_append text := current_setting('otlet.quality_data_drift_append', true);
BEGIN
  IF NULLIF(btrim(record_quality_data_drift_report.reason), '') IS NULL
     OR octet_length(record_quality_data_drift_report.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet quality and data drift report reason is required and bounded';
  END IF;
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = record_quality_data_drift_report.contract_hash
    AND stored.definition #>> '{population,rule,kind}' = 'quality_data_drift';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet quality and data drift contract does not exist';
  END IF;
  declaration := contract.definition #> '{baseline,definition}';
  minimum_support := (declaration ->> 'minimum_support')::integer;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_quality_data_drift_report:' || contract.contract_hash,
    0
  ));
  SELECT * INTO existing_report
  FROM otlet.quality_data_drift_reports stored
  WHERE stored.contract_hash = contract.contract_hash;
  IF FOUND THEN
    IF existing_report.evaluation_report_hash IS DISTINCT FROM
         record_quality_data_drift_report.evaluation_report_hash
       OR existing_report.candidate_observation_hash IS DISTINCT FROM
         record_quality_data_drift_report.candidate_observation_hash
       OR existing_report.reason IS DISTINCT FROM
         btrim(record_quality_data_drift_report.reason) THEN
      RAISE EXCEPTION 'otlet quality and data drift contract already has a different report';
    END IF;
    RETURN existing_report.report_hash;
  END IF;

  SELECT
    report.created_at,
    report.definition,
    run.task_name,
    run.candidate_workload_revision_hash
  INTO observed_report
  FROM otlet.evaluation_slice_reports report
  JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
  WHERE report.report_hash = record_quality_data_drift_report.evaluation_report_hash;
  IF NOT FOUND
     OR observed_report.definition ->> 'contract_hash' IS DISTINCT FROM
       contract.contract_hash
     OR observed_report.definition #>> '{population,sampling_method,mode}'
       IS DISTINCT FROM 'full'
     OR observed_report.task_name IS DISTINCT FROM contract.task_name
     OR observed_report.candidate_workload_revision_hash IS DISTINCT FROM
       contract.candidate_workload_revision_hash
     OR observed_report.created_at < (
       contract.definition #>> '{observation_window,ends_at}'
     )::timestamptz THEN
    RAISE EXCEPTION 'otlet quality and data drift observed report is invalid';
  END IF;

  SELECT * INTO baseline_observation
  FROM otlet.task_candidate_observations observation
  WHERE observation.observation_hash = declaration ->> 'candidate_observation_hash';
  SELECT * INTO observed_observation
  FROM otlet.task_candidate_observations observation
  WHERE observation.observation_hash =
    record_quality_data_drift_report.candidate_observation_hash;
  IF observed_observation.observation_hash IS NULL
     OR observed_observation.task_name IS DISTINCT FROM contract.task_name
     OR observed_observation.workload_revision_hash IS DISTINCT FROM
       contract.candidate_workload_revision_hash
     OR observed_observation.rejection_reason = 'row_cap'
     OR observed_observation.created_at < (
       contract.definition #>> '{observation_window,starts_at}'
     )::timestamptz
     OR observed_observation.created_at >= (
       contract.definition #>> '{observation_window,ends_at}'
     )::timestamptz THEN
    RAISE EXCEPTION 'otlet quality and data drift candidate observation is invalid';
  END IF;

  baseline_metrics := otlet.quality_data_report_metrics(
    declaration ->> 'report_hash',
    declaration ->> 'variant'
  );
  observed_metrics := otlet.quality_data_report_metrics(
    record_quality_data_drift_report.evaluation_report_hash,
    'candidate'
  );
  IF baseline_metrics IS NULL OR observed_metrics IS NULL THEN
    RAISE EXCEPTION 'otlet quality and data drift report metrics are incomplete';
  END IF;
  baseline_metrics := jsonb_set(
    baseline_metrics,
    '{reviewer_overturn}',
    declaration -> 'reviewer_overturn'
  );

  WITH measurement(
    dimension,
    unit,
    baseline_value,
    observed_value,
    baseline_support,
    observed_support,
    drift,
    required_support,
    detail
  ) AS (
    VALUES
      (
        'input_shape'::text,
        'total_variation_distance'::text,
        NULL::numeric,
        NULL::numeric,
        (baseline_metrics #>> '{input_shape,support}')::integer,
        (observed_metrics #>> '{input_shape,support}')::integer,
        CASE WHEN (baseline_metrics #>> '{input_shape,support}')::integer > 0
          AND (observed_metrics #>> '{input_shape,support}')::integer > 0
          THEN otlet.quality_data_distribution_drift(
            baseline_metrics #> '{input_shape,distribution}',
            observed_metrics #> '{input_shape,distribution}'
          )
        END,
        minimum_support,
        jsonb_build_object(
          'baseline_distribution', baseline_metrics #> '{input_shape,distribution}',
          'observed_distribution', observed_metrics #> '{input_shape,distribution}'
        )
      ),
      (
        'candidate_volume',
        'relative_change',
        baseline_observation.candidate_rows::numeric,
        observed_observation.candidate_rows::numeric,
        1,
        1,
        CASE
          WHEN baseline_observation.candidate_rows = 0
            AND observed_observation.candidate_rows = 0 THEN 0::numeric
          WHEN baseline_observation.candidate_rows = 0 THEN 1::numeric
          ELSE abs(
            observed_observation.candidate_rows - baseline_observation.candidate_rows
          )::numeric / baseline_observation.candidate_rows
        END,
        1,
        jsonb_build_object(
          'definition', 'pre_admission_source_query_rows',
          'baseline_observation_hash', baseline_observation.observation_hash,
          'observed_observation_hash', observed_observation.observation_hash,
          'baseline_admitted', baseline_observation.admitted,
          'observed_admitted', observed_observation.admitted
        )
      ),
      (
        'class',
        'total_variation_distance',
        NULL::numeric,
        NULL::numeric,
        (baseline_metrics #>> '{class,support}')::integer,
        (observed_metrics #>> '{class,support}')::integer,
        otlet.quality_data_distribution_drift(
          baseline_metrics #> '{class,distribution}',
          observed_metrics #> '{class,distribution}'
        ),
        minimum_support,
        jsonb_build_object(
          'baseline_distribution', baseline_metrics #> '{class,distribution}',
          'observed_distribution', observed_metrics #> '{class,distribution}'
        )
      ),
      (
        'abstention',
        'absolute_rate_delta',
        (baseline_metrics #>> '{abstention,value}')::numeric,
        (observed_metrics #>> '{abstention,value}')::numeric,
        (baseline_metrics #>> '{abstention,support}')::integer,
        (observed_metrics #>> '{abstention,support}')::integer,
        abs(
          (observed_metrics #>> '{abstention,value}')::numeric
          - (baseline_metrics #>> '{abstention,value}')::numeric
        ),
        minimum_support,
        jsonb_build_object('definition', 'terminal_answer_in_pinned_abstain_values')
      ),
      (
        'escalation',
        'absolute_rate_delta',
        (baseline_metrics #>> '{escalation,value}')::numeric,
        (observed_metrics #>> '{escalation,value}')::numeric,
        (baseline_metrics #>> '{escalation,support}')::integer,
        (observed_metrics #>> '{escalation,support}')::integer,
        abs(
          (observed_metrics #>> '{escalation,value}')::numeric
          - (baseline_metrics #>> '{escalation,value}')::numeric
        ),
        minimum_support,
        jsonb_build_object('definition', 'strong_role_receipt')
      ),
      (
        'reviewer_overturn',
        'absolute_rate_delta',
        (baseline_metrics #>> '{reviewer_overturn,value}')::numeric,
        (observed_metrics #>> '{reviewer_overturn,value}')::numeric,
        (baseline_metrics #>> '{reviewer_overturn,support}')::integer,
        (observed_metrics #>> '{reviewer_overturn,support}')::integer,
        abs(
          (observed_metrics #>> '{reviewer_overturn,value}')::numeric
          - (baseline_metrics #>> '{reviewer_overturn,value}')::numeric
        ),
        minimum_support,
        jsonb_build_object(
          'definition', 'latest_terminal_review_event',
          'baseline_evidence_hash',
            baseline_metrics #>> '{reviewer_overturn,evidence_hash}',
          'observed_evidence_hash',
            observed_metrics #>> '{reviewer_overturn,evidence_hash}'
        )
      ),
      (
        'false_trust',
        'absolute_rate_delta',
        (baseline_metrics #>> '{false_trust,value}')::numeric,
        (observed_metrics #>> '{false_trust,value}')::numeric,
        (baseline_metrics #>> '{false_trust,support}')::integer,
        (observed_metrics #>> '{false_trust,support}')::integer,
        abs(
          (observed_metrics #>> '{false_trust,value}')::numeric
          - (baseline_metrics #>> '{false_trust,value}')::numeric
        ),
        minimum_support,
        jsonb_build_object(
          'definition', 'trusted_non_abstain_answer_and_valid_action',
          'baseline_evidence_hash', baseline_metrics #>> '{false_trust,evidence_hash}',
          'observed_evidence_hash', observed_metrics #>> '{false_trust,evidence_hash}'
        )
      )
  ), classified AS (
    SELECT
      measurement.*,
      (declaration #>> ARRAY['maximum_drift', measurement.dimension])::numeric
        AS maximum_drift,
      measurement.drift IS NOT NULL
        AND measurement.baseline_support >= measurement.required_support
        AND measurement.observed_support >= measurement.required_support
        AS evidence_ready
    FROM measurement
  )
  SELECT jsonb_agg(jsonb_build_object(
    'dimension', dimension,
    'unit', unit,
    'baseline_value', to_jsonb(baseline_value),
    'observed_value', to_jsonb(observed_value),
    'baseline_support', baseline_support,
    'observed_support', observed_support,
    'minimum_support', required_support,
    'drift', to_jsonb(drift),
    'maximum_drift', maximum_drift,
    'evidence_ready', evidence_ready,
    'status', CASE
      WHEN NOT evidence_ready THEN 'insufficient_evidence'
      WHEN drift > maximum_drift THEN 'drifted'
      ELSE 'within_baseline'
    END,
    'alert', evidence_ready AND drift > maximum_drift,
    'measurement', detail
  ) ORDER BY dimension)
  INTO signals
  FROM classified;

  definition := jsonb_build_object(
    'format', 'otlet.quality_data_drift.report.v1',
    'contract_hash', contract.contract_hash,
    'baseline_evaluation_report_hash', declaration ->> 'report_hash',
    'observed_evaluation_report_hash',
      record_quality_data_drift_report.evaluation_report_hash,
    'baseline_candidate_observation_hash',
      baseline_observation.observation_hash,
    'observed_candidate_observation_hash',
      observed_observation.observation_hash,
    'signals', signals,
    'reason', btrim(record_quality_data_drift_report.reason),
    'non_authoritative', true
  );
  report_hash := otlet.identity_hash('quality_data_drift_report', definition);

  PERFORM set_config('otlet.quality_data_drift_append', 'on', true);
  INSERT INTO otlet.quality_data_drift_reports (
    report_hash,
    contract_hash,
    evaluation_report_hash,
    candidate_observation_hash,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    report_hash,
    contract.contract_hash,
    record_quality_data_drift_report.evaluation_report_hash,
    record_quality_data_drift_report.candidate_observation_hash,
    definition,
    btrim(record_quality_data_drift_report.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config(
    'otlet.quality_data_drift_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN report_hash;
END;
$$;

CREATE VIEW otlet.quality_data_drift_status AS
SELECT
  contract.contract_hash,
  contract.task_name,
  contract.baseline_workload_revision_hash,
  contract.candidate_workload_revision_hash,
  NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) AS current_contract,
  contract.definition #> '{observation_window}' AS observation_window,
  report.report_hash,
  COALESCE(
    report.definition ->> 'baseline_evaluation_report_hash',
    contract.definition #>> '{baseline,definition,report_hash}'
  ) AS baseline_evaluation_report_hash,
  report.definition ->> 'observed_evaluation_report_hash'
    AS observed_evaluation_report_hash,
  COALESCE(
    report.definition ->> 'baseline_candidate_observation_hash',
    contract.definition #>> '{baseline,definition,candidate_observation_hash}'
  ) AS baseline_candidate_observation_hash,
  report.definition ->> 'observed_candidate_observation_hash'
    AS observed_candidate_observation_hash,
  dimension.name AS dimension,
  dimension.unit,
  (signal.value ->> 'baseline_value')::numeric AS baseline_value,
  (signal.value ->> 'observed_value')::numeric AS observed_value,
  COALESCE((signal.value ->> 'baseline_support')::integer, 0)
    AS baseline_support,
  COALESCE((signal.value ->> 'observed_support')::integer, 0)
    AS observed_support,
  COALESCE(
    (signal.value ->> 'minimum_support')::integer,
    dimension.minimum_support
  ) AS minimum_support,
  (signal.value ->> 'drift')::numeric AS drift,
  dimension.maximum_drift,
  COALESCE((signal.value ->> 'evidence_ready')::boolean, false)
    AS evidence_ready,
  COALESCE(signal.value ->> 'status', 'insufficient_evidence') AS status,
  COALESCE((signal.value ->> 'alert')::boolean, false) AS alert,
  signal.value -> 'measurement' AS measurement,
  true AS non_authoritative,
  report.authenticated_role_name AS recorded_by,
  report.active_role_name AS recorded_as,
  report.reason,
  report.created_at
FROM otlet.workload_acceptance_contracts contract
CROSS JOIN LATERAL (
  VALUES
    (
      'input_shape'::text,
      'total_variation_distance'::text,
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,input_shape}')::numeric
    ),
    (
      'candidate_volume',
      'relative_change',
      1,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,candidate_volume}')::numeric
    ),
    (
      'class',
      'total_variation_distance',
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,class}')::numeric
    ),
    (
      'abstention',
      'absolute_rate_delta',
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,abstention}')::numeric
    ),
    (
      'escalation',
      'absolute_rate_delta',
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,escalation}')::numeric
    ),
    (
      'reviewer_overturn',
      'absolute_rate_delta',
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,reviewer_overturn}')::numeric
    ),
    (
      'false_trust',
      'absolute_rate_delta',
      (contract.definition #>> '{baseline,definition,minimum_support}')::integer,
      (contract.definition #>>
        '{baseline,definition,maximum_drift,false_trust}')::numeric
    )
) dimension(name, unit, minimum_support, maximum_drift)
LEFT JOIN otlet.quality_data_drift_reports report
  ON report.contract_hash = contract.contract_hash
LEFT JOIN LATERAL (
  SELECT item.value
  FROM jsonb_array_elements(report.definition -> 'signals') item(value)
  WHERE item.value ->> 'dimension' = dimension.name
) signal ON true
WHERE contract.definition #>> '{population,rule,kind}' = 'quality_data_drift';

REVOKE ALL ON TABLE otlet.task_candidate_observations FROM PUBLIC;
REVOKE ALL ON TABLE otlet.quality_data_drift_reports FROM PUBLIC;
REVOKE ALL ON TABLE otlet.quality_data_drift_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_quality_data_drift_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_task_candidate_observation() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_task_candidate_observation(
  text, text, bigint, bigint, bigint, boolean, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.quality_data_input_shape(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.quality_data_distribution_drift(jsonb, jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.quality_data_reviewer_overturn(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.quality_data_report_metrics(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.quality_data_drift_declaration_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_quality_data_drift_contract()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_quality_data_drift_report() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_quality_data_drift_report(
  text, text, text, text
) FROM PUBLIC;
