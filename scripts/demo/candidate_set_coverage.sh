log "Proving candidate-set coverage gates"
psql_candidate_exec -qAt \
  -v task_name="$join_task" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" <<'SQL'
BEGIN;
SELECT 1
FROM otlet.production_policy
WHERE name = 'default'
FOR UPDATE \g /dev/null

CREATE TEMP TABLE candidate_set_coverage_proof (
  task_name text,
  baseline_hash text,
  bad_hash text,
  good_hash text,
  decision_hash text,
  current_contract_hash text,
  cap_contract_hash text,
  miss_contract_hash text,
  empty_contract_hash text,
  invalid_contract_hash text,
  good_contract_hash text,
  decision_contract_hash text,
  cap_report_hash text,
  cap_report_retry_hash text,
  miss_report_hash text,
  empty_report_hash text,
  good_report_hash text,
  decision_report_hash text,
  first_label_id bigint,
  second_label_id bigint,
  thresholds jsonb,
  undeclared_allowed boolean NOT NULL DEFAULT false,
  failed_report_blocked boolean NOT NULL DEFAULT false,
  invalid_rank_blocked boolean NOT NULL DEFAULT false,
  decision_undeclared_allowed boolean NOT NULL DEFAULT false,
  duplicate_labels_blocked boolean NOT NULL DEFAULT false,
  stale_label_blocked boolean NOT NULL DEFAULT false,
  source_drift_blocked boolean NOT NULL DEFAULT false,
  rollback_toggle_blocked boolean NOT NULL DEFAULT false,
  conflicting_retry_blocked boolean NOT NULL DEFAULT false,
  immutable boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO candidate_set_coverage_proof (
  task_name,
  baseline_hash,
  current_contract_hash,
  thresholds
)
SELECT
  head.task_name,
  head.active_workload_revision_hash,
  current_contract.contract_hash,
  (
    SELECT jsonb_object_agg(category, jsonb_build_object(
      'metric', category,
      'statistic', 'rate',
      'operator', CASE WHEN category IN (
        'candidate_recall', 'downstream_outcome'
      ) THEN 'gte' ELSE 'lte' END,
      'value', CASE WHEN category IN (
        'candidate_recall', 'downstream_outcome'
      ) THEN 0.9 ELSE 0.1 END,
      'unit', 'ratio',
      'minimum_support', 1,
      'required', true
    ))
    FROM unnest(ARRAY[
      'candidate_recall',
      'false_trust',
      'abstention',
      'review_age',
      'review_minutes',
      'freshness',
      'latency',
      'database_impact',
      'unit_cost',
      'recovery',
      'downstream_outcome'
    ]) category
  )
FROM otlet.workload_revision_heads head
LEFT JOIN LATERAL otlet.current_workload_acceptance_contract(
  head.task_name
) current_contract ON true
WHERE head.task_name = :'task_name';

CREATE FUNCTION pg_temp.candidate_set_coverage_revision(
  baseline_hash text,
  candidate_query text DEFAULT NULL,
  candidate_cap integer DEFAULT NULL,
  decision_suffix text DEFAULT NULL,
  instruction_suffix text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  definition jsonb;
  query_contract jsonb;
  candidate_plan jsonb;
  candidate_plan_cost numeric;
  candidate_preflight_at timestamptz;
  revision_hash text;
BEGIN
  SELECT revision.definition
  INTO definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash =
    candidate_set_coverage_revision.baseline_hash;

  IF candidate_set_coverage_revision.candidate_query IS NOT NULL THEN
    query_contract := otlet.build_source_query_contract(
      candidate_set_coverage_revision.candidate_query
    );
    definition := jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            definition,
            '{source,candidate_query}',
            to_jsonb(query_contract #>> '{query,resolved}')
          ),
          '{source,query_contract}',
          query_contract
        ),
        '{source,max_candidate_rows}',
        to_jsonb(candidate_set_coverage_revision.candidate_cap)
      ),
      '{task,input_query}',
      to_jsonb(query_contract #>> '{query,resolved}')
    );
  END IF;
  IF candidate_set_coverage_revision.decision_suffix IS NOT NULL THEN
    definition := jsonb_set(
      definition,
      '{task,decision_contract,prompt_prefix}',
      to_jsonb(
        definition #>> '{task,decision_contract,prompt_prefix}' ||
        candidate_set_coverage_revision.decision_suffix
      )
    );
  END IF;
  IF candidate_set_coverage_revision.instruction_suffix IS NOT NULL THEN
    definition := jsonb_set(
      definition,
      '{task,instruction}',
      to_jsonb(
        definition #>> '{task,instruction}' ||
        candidate_set_coverage_revision.instruction_suffix
      )
    );
  END IF;

  PERFORM otlet.workload_definition_complexity_guard(definition);
  SELECT
    preflight.candidate_plan,
    preflight.candidate_plan_cost,
    preflight.candidate_preflight_at
  INTO candidate_plan, candidate_plan_cost, candidate_preflight_at
  FROM otlet.preflight_candidate_query(
    definition #>> '{source,candidate_query}',
    true,
    false,
    definition #> '{source,query_contract}'
  ) preflight;
  revision_hash := otlet.identity_hash('workload_revision', definition);
  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  ) VALUES (
    revision_hash,
    definition #>> '{task,name}',
    definition,
    candidate_plan,
    candidate_plan_cost,
    candidate_preflight_at
  );
  RETURN revision_hash;
END;
$$;

CREATE FUNCTION pg_temp.candidate_set_coverage_query(query_kind text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE candidate_set_coverage_query.query_kind
    WHEN 'cap' THEN $query$
      SELECT ranked.candidate_rank, pair.subject_id, pair.input
      FROM (VALUES
        (1::bigint, 'vendor-1001:vendor-42'),
        (2::bigint, 'vendor-1001:vendor-77'),
        (3::bigint, 'vendor-1001:vendor-313'),
        (4::bigint, 'vendor-1001:vendor-314')
      ) ranked(candidate_rank, subject_id)
      JOIN public.otlet_demo_vendor_pair_input pair USING (subject_id);
    $query$
    WHEN 'miss' THEN $query$
      SELECT ranked.candidate_rank, pair.subject_id, pair.input
      FROM (VALUES
        (1::bigint, 'vendor-1001:vendor-42'),
        (2::bigint, 'vendor-1001:vendor-77'),
        (3::bigint, 'vendor-1001:vendor-314')
      ) ranked(candidate_rank, subject_id)
      JOIN public.otlet_demo_vendor_pair_input pair USING (subject_id)
    $query$
    WHEN 'invalid' THEN $query$
      SELECT ranked.candidate_rank, pair.subject_id, pair.input
      FROM (VALUES
        (NULL::bigint, 'vendor-1001:vendor-42'),
        (2::bigint, 'vendor-1001:vendor-313'),
        (3::bigint, 'vendor-1001:vendor-77'),
        (4::bigint, 'vendor-1001:vendor-314')
      ) ranked(candidate_rank, subject_id)
      JOIN public.otlet_demo_vendor_pair_input pair USING (subject_id)
    $query$
    WHEN 'empty' THEN $query$
      SELECT
        1::bigint AS candidate_rank,
        pair.subject_id,
        pair.input
      FROM public.otlet_demo_vendor_pair_input pair
      WHERE false
    $query$
    WHEN 'good' THEN $query$
      SELECT ranked.candidate_rank, pair.subject_id, pair.input
      FROM (VALUES
        (1::bigint, 'vendor-1001:vendor-42'),
        (2::bigint, 'vendor-1001:vendor-313'),
        (3::bigint, 'vendor-1001:vendor-77'),
        (4::bigint, 'vendor-1001:vendor-314')
      ) ranked(candidate_rank, subject_id)
      JOIN public.otlet_demo_vendor_pair_input pair USING (subject_id)
    $query$
    ELSE NULL
  END;
END;
$$;

CREATE FUNCTION pg_temp.register_candidate_set_coverage_contract(
  baseline_hash text,
  candidate_hash text,
  coverage_query text,
  thresholds jsonb,
  current_contract_hash text
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  coverage_rule jsonb;
  starts_at timestamptz;
BEGIN
  coverage_rule := otlet.build_candidate_set_coverage_rule(
    register_candidate_set_coverage_contract.coverage_query,
    ARRAY['_otlet_mvcc', 'source'],
    2,
    1,
    1,
    1,
    0,
    0.4
  );
  starts_at := clock_timestamp() + interval '200 milliseconds';
  RETURN otlet.register_workload_acceptance_contract(
    (SELECT task_name
     FROM otlet.workload_revisions
     WHERE workload_revision_hash =
       register_candidate_set_coverage_contract.baseline_hash),
    register_candidate_set_coverage_contract.candidate_hash,
    register_candidate_set_coverage_contract.baseline_hash,
    jsonb_build_object(
      'mode', 'full',
      'rule', jsonb_build_object(
        'kind', 'candidate_set_coverage_probe',
        'candidate_coverage', coverage_rule
      )
    ),
    starts_at,
    starts_at + interval '200 milliseconds',
    '{"name":"active_pair_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    register_candidate_set_coverage_contract.thresholds,
    register_candidate_set_coverage_contract.current_contract_hash
  );
END;
$$;

DO $$
DECLARE
  action_id bigint;
  label_id bigint;
  task_name_value text;
BEGIN
  SELECT task_name INTO task_name_value
  FROM candidate_set_coverage_proof;
  SELECT action.id
  INTO action_id
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE job.task_name = task_name_value
    AND job.subject_id = 'vendor-1001:vendor-42'
    AND action.action_type = 'merge_candidate'
  ORDER BY job.id DESC, action.id DESC
  LIMIT 1;
  SELECT label.id
  INTO label_id
  FROM otlet.label_action(
    action_id,
    'same_entity',
    'high',
    'merge_candidate',
    'Candidate coverage positive',
    'manual_correction'
  ) label;
  PERFORM otlet.adjudicate_eval_label(
    label_id,
    'accepted',
    1,
    'Accept candidate coverage positive'
  );
  UPDATE candidate_set_coverage_proof SET first_label_id = label_id;

  SELECT action.id
  INTO action_id
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE job.task_name = task_name_value
    AND job.subject_id = 'vendor-1001:vendor-313'
    AND action.action_type = 'new_entity'
  ORDER BY job.id DESC, action.id DESC
  LIMIT 1;
  SELECT label.id
  INTO label_id
  FROM otlet.label_action(
    action_id,
    'same_entity',
    'high',
    'merge_candidate',
    'Candidate coverage corrected positive',
    'manual_correction'
  ) label;
  PERFORM otlet.adjudicate_eval_label(
    label_id,
    'accepted',
    1,
    'Accept corrected candidate coverage positive'
  );
  UPDATE candidate_set_coverage_proof SET second_label_id = label_id;
END;
$$;

UPDATE candidate_set_coverage_proof
SET bad_hash = pg_temp.candidate_set_coverage_revision(
  baseline_hash,
  $query$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    WHERE subject_id IN (
      'vendor-1001:vendor-42',
      'vendor-1001:vendor-77'
    )
    ORDER BY subject_id
  $query$,
  2
);

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    PERFORM otlet.promote_workload_revision(
      proof.task_name,
      proof.bad_hash,
      proof.baseline_hash
    );
    IF NOT EXISTS (
      SELECT 1 FROM otlet.workload_revision_heads head
      WHERE head.task_name = proof.task_name
        AND head.active_workload_revision_hash = proof.bad_hash
    ) THEN
      RAISE EXCEPTION 'undeclared candidate coverage did not allow promotion';
    END IF;
    RAISE EXCEPTION 'undeclared candidate coverage proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'undeclared candidate coverage proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET undeclared_allowed = true;
  END;
END;
$$;

UPDATE candidate_set_coverage_proof
SET cap_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  baseline_hash,
  bad_hash,
  pg_temp.candidate_set_coverage_query('cap'),
  thresholds,
  current_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

UPDATE candidate_set_coverage_proof
SET cap_report_hash = otlet.record_candidate_set_coverage(
  cap_contract_hash,
  'Record cap-exclusion candidate coverage'
);
UPDATE candidate_set_coverage_proof
SET cap_report_retry_hash = otlet.record_candidate_set_coverage(
  cap_contract_hash,
  'Record cap-exclusion candidate coverage'
);

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  IF proof.cap_report_hash IS DISTINCT FROM proof.cap_report_retry_hash
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.candidate_set_coverage_reports report
       WHERE report.report_hash = proof.cap_report_hash
         AND NOT report.gate_passed
         AND report.metrics ->> 'candidate_volume' = '4'
         AND report.metrics ->> 'candidate_query_rows' = '2'
         AND report.metrics ->> 'positive_pairs' = '2'
         AND report.metrics ->> 'positive_pairs_in_bounded_set' = '1'
         AND report.metrics ->> 'positive_pairs_excluded_by_cap' = '1'
         AND report.metrics ->> 'positive_pairs_missed_by_sql' = '0'
         AND report.metrics ->> 'positive_pair_coverage' = '0.500000000000'
         AND report.metrics ->> 'ordering_bias' = '0.666666666667'
         AND report.metrics #>> '{per_source,erp,positive_pairs}' = '1'
         AND report.metrics #>>
           '{per_source,erp,positive_pairs_in_bounded_set}' = '1'
         AND report.metrics #>>
           '{per_source,erp,positive_pair_coverage}' = '1.000000000000'
         AND report.metrics #>> '{per_source,crm,positive_pairs}' = '1'
         AND report.metrics #>>
           '{per_source,crm,positive_pairs_in_bounded_set}' = '0'
         AND report.metrics #>>
           '{per_source,crm,positive_pair_coverage}' = '0.000000000000'
         AND report.gate_failures @> '[
           "cap_excluded_positive_pairs_exceeded",
           "overall_coverage_below_minimum",
           "source_coverage_below_minimum",
           "ordering_bias_exceeded"
         ]'::jsonb
     ) THEN
    RAISE EXCEPTION 'candidate cap-exclusion report is invalid: %', (
      SELECT report.definition
      FROM otlet.candidate_set_coverage_reports report
      WHERE report.report_hash = proof.cap_report_hash
    );
  END IF;
  BEGIN
    PERFORM otlet.promote_workload_revision(
      proof.task_name,
      proof.bad_hash,
      proof.baseline_hash
    );
    RAISE EXCEPTION 'failed candidate coverage unexpectedly promoted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet pair workload promotion requires a current passing candidate-set coverage report' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET failed_report_blocked = true;
  END;
END;
$$;

UPDATE candidate_set_coverage_proof
SET miss_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  baseline_hash,
  bad_hash,
  pg_temp.candidate_set_coverage_query('miss'),
  thresholds,
  cap_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

UPDATE candidate_set_coverage_proof
SET miss_report_hash = otlet.record_candidate_set_coverage(
  miss_contract_hash,
  'Record SQL-missed candidate coverage'
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM candidate_set_coverage_proof proof
    JOIN otlet.candidate_set_coverage_reports report
      ON report.report_hash = proof.miss_report_hash
    WHERE NOT report.gate_passed
      AND report.metrics ->> 'candidate_volume' = '3'
      AND report.metrics ->> 'positive_pairs_excluded_by_cap' = '0'
      AND report.metrics ->> 'positive_pairs_missed_by_sql' = '1'
      AND report.metrics ->> 'ordering_bias' = '1.000000000000'
  ) THEN
    RAISE EXCEPTION 'candidate SQL-miss report is invalid';
  END IF;
END;
$$;

UPDATE candidate_set_coverage_proof
SET empty_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  baseline_hash,
  bad_hash,
  pg_temp.candidate_set_coverage_query('empty'),
  thresholds,
  miss_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

UPDATE candidate_set_coverage_proof
SET empty_report_hash = otlet.record_candidate_set_coverage(
  empty_contract_hash,
  'Record collapsed candidate coverage'
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM candidate_set_coverage_proof proof
    JOIN otlet.candidate_set_coverage_reports report
      ON report.report_hash = proof.empty_report_hash
    WHERE NOT report.gate_passed
      AND report.metrics ->> 'candidate_volume' = '0'
      AND report.metrics ->> 'bounded_candidate_volume' = '0'
      AND report.metrics ->> 'candidate_query_rows' = '2'
      AND report.metrics ->> 'positive_pairs' = '2'
      AND report.metrics ->> 'positive_pairs_in_candidate_set' = '0'
      AND report.metrics ->> 'positive_pairs_missed_by_sql' = '2'
      AND report.metrics ->> 'positive_pair_coverage' = '0.000000000000'
      AND report.gate_failures @> '[
        "candidate_sql_not_bounded_prefix",
        "overall_coverage_below_minimum",
        "source_coverage_below_minimum"
      ]'::jsonb
  ) THEN
    RAISE EXCEPTION 'candidate collapse report is invalid';
  END IF;
END;
$$;

UPDATE candidate_set_coverage_proof
SET good_hash = pg_temp.candidate_set_coverage_revision(
  baseline_hash,
  $query$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    WHERE subject_id IN (
      'vendor-1001:vendor-42',
      'vendor-1001:vendor-313'
    )
    ORDER BY subject_id
  $query$,
  2
);
UPDATE candidate_set_coverage_proof
SET invalid_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  baseline_hash,
  good_hash,
  pg_temp.candidate_set_coverage_query('invalid'),
  thresholds,
  empty_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    PERFORM otlet.record_candidate_set_coverage(
      proof.invalid_contract_hash,
      'Reject invalid coverage ranks'
    );
    RAISE EXCEPTION 'invalid candidate ranks unexpectedly recorded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet candidate-set coverage query must return 0 to 100000 unique subjects with contiguous unique ranks' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET invalid_rank_blocked = true;
  END;
END;
$$;

UPDATE candidate_set_coverage_proof
SET good_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  baseline_hash,
  good_hash,
  pg_temp.candidate_set_coverage_query('good'),
  thresholds,
  invalid_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

UPDATE candidate_set_coverage_proof
SET good_report_hash = otlet.record_candidate_set_coverage(
  good_contract_hash,
  'Record passing candidate coverage'
);

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.candidate_set_coverage_status status
    JOIN otlet.candidate_set_coverage_reports report
      ON report.report_hash = status.report_hash
    WHERE status.report_hash = proof.good_report_hash
      AND status.gate_passed
      AND status.report_current
      AND status.positive_pairs_in_bounded_set = 2
      AND status.positive_pairs_excluded_by_cap = 0
      AND status.positive_pairs_missed_by_sql = 0
      AND status.positive_pair_coverage = 1
      AND status.ordering_bias = 0.333333333333
      AND (
        SELECT count(*)
        FROM jsonb_object_keys(status.per_source)
      ) = 2
      AND status.per_source #>> '{erp,positive_pairs}' = '1'
      AND status.per_source #>>
        '{erp,positive_pairs_in_bounded_set}' = '1'
      AND status.per_source #>>
        '{erp,positive_pair_coverage}' = '1.000000000000'
      AND status.per_source #>> '{crm,positive_pairs}' = '1'
      AND status.per_source #>>
        '{crm,positive_pairs_in_bounded_set}' = '1'
      AND status.per_source #>>
        '{crm,positive_pair_coverage}' = '1.000000000000'
      AND status.measured_candidate_plan_cost =
        status.stored_candidate_plan_cost
      AND status.coverage_query_plan_cost <=
        status.candidate_plan_cost_limit
      AND report.definition::text NOT LIKE '%vendor-1001%'
  ) THEN
    RAISE EXCEPTION 'passing candidate-set coverage status is invalid';
  END IF;
  PERFORM otlet.promote_workload_revision(
    proof.task_name,
    proof.good_hash,
    proof.baseline_hash
  );
END;
$$;

UPDATE candidate_set_coverage_proof
SET decision_hash = pg_temp.candidate_set_coverage_revision(
  good_hash,
  decision_suffix => ' Candidate coverage decision revision.'
);

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    PERFORM otlet.promote_workload_revision(
      proof.task_name,
      proof.decision_hash,
      proof.good_hash
    );
    IF NOT EXISTS (
      SELECT 1 FROM otlet.workload_revision_heads head
      WHERE head.task_name = proof.task_name
        AND head.active_workload_revision_hash = proof.decision_hash
    ) THEN
      RAISE EXCEPTION 'undeclared decision coverage did not allow promotion';
    END IF;
    RAISE EXCEPTION 'undeclared decision coverage proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'undeclared decision coverage proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof
    SET decision_undeclared_allowed = true;
  END;
END;
$$;

UPDATE candidate_set_coverage_proof
SET decision_contract_hash = pg_temp.register_candidate_set_coverage_contract(
  good_hash,
  decision_hash,
  pg_temp.candidate_set_coverage_query('good'),
  thresholds,
  good_contract_hash
);
SELECT pg_sleep(0.45) \g /dev/null

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
  action_id bigint;
  duplicate_label_id bigint;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    SELECT action.id
    INTO action_id
    FROM otlet.actions action
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = proof.task_name
      AND job.subject_id = 'vendor-1001:vendor-42'
      AND action.action_type = 'merge_candidate'
    ORDER BY job.id DESC, action.id DESC
    LIMIT 1;
    SELECT label.id
    INTO duplicate_label_id
    FROM otlet.label_action(
      action_id,
      'same_entity',
      'high',
      'merge_candidate',
      'Duplicate candidate coverage positive',
      'manual_correction'
    ) label;
    PERFORM otlet.adjudicate_eval_label(
      duplicate_label_id,
      'accepted',
      1,
      'Accept duplicate candidate coverage positive'
    );
    BEGIN
      PERFORM otlet.record_candidate_set_coverage(
        proof.decision_contract_hash,
        'Reject duplicate current positives'
      );
      RAISE EXCEPTION 'duplicate candidate labels unexpectedly recorded';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'otlet candidate-set coverage has duplicate current positive labels' THEN
        RAISE;
      END IF;
    END;
    RAISE EXCEPTION 'candidate coverage duplicate-label proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'candidate coverage duplicate-label proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET duplicate_labels_blocked = true;
  END;
END;
$$;

UPDATE candidate_set_coverage_proof
SET decision_report_hash = otlet.record_candidate_set_coverage(
  decision_contract_hash,
  'Record decision-contract candidate coverage'
);

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
  action_id bigint;
  replacement_label_id bigint;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    SELECT action.id
    INTO action_id
    FROM otlet.actions action
    JOIN otlet.jobs job ON job.id = action.job_id
    WHERE job.task_name = proof.task_name
      AND job.subject_id = 'vendor-1001:vendor-42'
      AND action.action_type = 'merge_candidate'
    ORDER BY job.id DESC, action.id DESC
    LIMIT 1;
    SELECT label.id
    INTO replacement_label_id
    FROM otlet.label_action(
      action_id,
      'same_entity',
      'high',
      'merge_candidate',
      'Replace candidate coverage positive',
      'manual_correction'
    ) label;
    PERFORM otlet.adjudicate_eval_label(
      replacement_label_id,
      'accepted',
      1,
      'Supersede candidate coverage positive',
      proof.first_label_id
    );
    IF otlet.candidate_set_coverage_report_current(
         proof.decision_report_hash
       ) THEN
      RAISE EXCEPTION 'superseded label did not stale candidate coverage';
    END IF;
    BEGIN
      PERFORM otlet.promote_workload_revision(
        proof.task_name,
        proof.decision_hash,
        proof.good_hash
      );
      RAISE EXCEPTION 'stale-label candidate coverage unexpectedly promoted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'otlet pair workload promotion requires a current passing candidate-set coverage report' THEN
        RAISE;
      END IF;
    END;
    RAISE EXCEPTION 'candidate coverage stale-label proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'candidate coverage stale-label proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET stale_label_blocked = true;
  END;

  IF NOT otlet.candidate_set_coverage_report_current(
       proof.decision_report_hash
     ) THEN
    RAISE EXCEPTION 'candidate coverage did not recover after label rollback';
  END IF;
END;
$$;

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    UPDATE public.otlet_demo_vendor_entity
    SET notes = notes || '; candidate coverage drift probe'
    WHERE id = 'vendor-77';
    IF NOT otlet.candidate_set_coverage_report_current(
         proof.decision_report_hash
       ) THEN
      RAISE EXCEPTION 'unlabeled source drift unexpectedly changed label currency';
    END IF;
    BEGIN
      PERFORM otlet.promote_workload_revision(
        proof.task_name,
        proof.decision_hash,
        proof.good_hash
      );
      RAISE EXCEPTION 'source-drifted candidate coverage unexpectedly promoted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'otlet pair workload promotion requires a current passing candidate-set coverage report' THEN
        RAISE;
      END IF;
    END;
    RAISE EXCEPTION 'candidate coverage source-drift proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'candidate coverage source-drift proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET source_drift_blocked = true;
  END;

  PERFORM otlet.promote_workload_revision(
    proof.task_name,
    proof.decision_hash,
    proof.good_hash
  );
  PERFORM otlet.rollback_workload_revision(
    proof.task_name,
    proof.decision_hash,
    proof.good_hash
  );

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.administrative_change_events event
    WHERE event.object_type = 'task'
      AND event.object_name = proof.task_name
      AND event.operation = 'rollback'
      AND event.old_revision_hash = proof.decision_hash
      AND event.new_revision_hash = proof.good_hash
  ) OR EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = proof.task_name
      AND head.previous_workload_revision_hash IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'candidate coverage rollback direction was not consumed';
  END IF;

  BEGIN
    UPDATE public.otlet_demo_vendor_entity
    SET notes = notes || '; candidate coverage rollback-toggle probe'
    WHERE id = 'vendor-77';
    BEGIN
      PERFORM otlet.rollback_workload_revision(
        proof.task_name,
        proof.good_hash,
        proof.decision_hash
      );
      RAISE EXCEPTION 'stale rollback toggle unexpectedly promoted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'otlet pair workload promotion requires a current passing candidate-set coverage report' THEN
        RAISE;
      END IF;
    END;
    RAISE EXCEPTION 'candidate coverage rollback-toggle proof rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'candidate coverage rollback-toggle proof rollback' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET rollback_toggle_blocked = true;
  END;
END;
$$;

DO $$
DECLARE
  proof candidate_set_coverage_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM candidate_set_coverage_proof;
  BEGIN
    PERFORM otlet.record_candidate_set_coverage(
      proof.decision_contract_hash,
      'Conflicting candidate coverage retry'
    );
    RAISE EXCEPTION 'conflicting candidate coverage retry unexpectedly recorded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet candidate-set coverage contract already has a different report' THEN
      RAISE;
    END IF;
    UPDATE candidate_set_coverage_proof SET conflicting_retry_blocked = true;
  END;

  BEGIN
    UPDATE otlet.candidate_set_coverage_reports
    SET reason = 'forged update'
    WHERE report_hash = proof.good_report_hash;
    RAISE EXCEPTION 'candidate coverage update unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet candidate-set coverage evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    DELETE FROM otlet.candidate_set_coverage_reports
    WHERE report_hash = proof.good_report_hash;
    RAISE EXCEPTION 'candidate coverage delete unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet candidate-set coverage evidence is append only' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    TRUNCATE otlet.candidate_set_coverage_reports;
    RAISE EXCEPTION 'candidate coverage truncate unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet candidate-set coverage evidence is append only' THEN
      RAISE;
    END IF;
  END;
  UPDATE candidate_set_coverage_proof SET immutable = true;
END;
$$;

\ir /work/scripts/demo/entity_resolution_quality.sql

WITH contract AS (
  SELECT concat_ws('|',
    proof.undeclared_allowed,
    proof.failed_report_blocked,
    proof.invalid_rank_blocked,
    proof.decision_undeclared_allowed,
    proof.duplicate_labels_blocked,
    proof.stale_label_blocked,
    proof.source_drift_blocked,
    proof.rollback_toggle_blocked,
    proof.conflicting_retry_blocked,
    proof.immutable,
    (
      SELECT count(*)
      FROM otlet.candidate_set_coverage_reports
      WHERE task_name = :'task_name'
    ),
    (
      SELECT active_workload_revision_hash = proof.good_hash
      FROM otlet.workload_revision_heads
      WHERE task_name = :'task_name'
    ),
    NOT pg_catalog.has_table_privilege(
      'public', 'otlet.candidate_set_coverage_reports', 'SELECT'
    ),
    NOT pg_catalog.has_table_privilege(
      'public', 'otlet.candidate_set_coverage_status', 'SELECT'
    ),
    NOT pg_catalog.has_function_privilege(
      'public',
      'otlet.record_candidate_set_coverage(text,text)',
      'EXECUTE'
    ),
    (SELECT count(*) FROM otlet.verify_invariants())
  ) AS value
  FROM candidate_set_coverage_proof proof
)
SELECT CASE
  WHEN contract.value = 't|t|t|t|t|t|t|t|t|t|7|t|t|t|t|0'
    THEN 'candidate_set_coverage_contract=' || contract.value
  ELSE otlet.require_task_input_relation(
    'candidate-set coverage contract mismatch: ' || contract.value
  )::text
END
FROM contract;

ROLLBACK;
SQL
