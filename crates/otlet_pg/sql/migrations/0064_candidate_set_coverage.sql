CREATE TABLE otlet.candidate_set_coverage_reports (
  report_hash text PRIMARY KEY CHECK (
    report_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL UNIQUE
    REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  baseline_workload_revision_hash text NOT NULL,
  candidate_workload_revision_hash text NOT NULL,
  candidate_manifest_hash text NOT NULL CHECK (
    candidate_manifest_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  positive_label_manifest_hash text NOT NULL CHECK (
    positive_label_manifest_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  metrics jsonb NOT NULL CHECK (jsonb_typeof(metrics) = 'object'),
  gate_failures jsonb NOT NULL CHECK (jsonb_typeof(gate_failures) = 'array'),
  gate_passed boolean NOT NULL,
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
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, contract_hash)
    REFERENCES otlet.workload_acceptance_contracts(task_name, contract_hash),
  FOREIGN KEY (task_name, baseline_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  FOREIGN KEY (task_name, candidate_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (baseline_workload_revision_hash <> candidate_workload_revision_hash)
);

CREATE FUNCTION otlet.candidate_set_coverage_rule_valid(rule jsonb)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  path_item jsonb;
BEGIN
  IF jsonb_typeof(candidate_set_coverage_rule_valid.rule) IS DISTINCT FROM
       'object'
     OR ARRAY(
       SELECT key
       FROM jsonb_object_keys(candidate_set_coverage_rule_valid.rule) key
       ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'coverage_query_contract',
       'kind',
       'maximum_cap_excluded_positive_pairs',
       'maximum_ordering_bias',
       'minimum_overall_coverage',
       'minimum_positive_support',
       'minimum_source_coverage',
       'minimum_source_support',
       'source_path'
     ]::text[]
     OR candidate_set_coverage_rule_valid.rule ->> 'kind' IS DISTINCT FROM
       'candidate_set_coverage'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'coverage_query_contract'
     ) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'source_path'
     ) IS DISTINCT FROM 'array' THEN
    RETURN false;
  END IF;
  IF jsonb_array_length(
       candidate_set_coverage_rule_valid.rule -> 'source_path'
     ) NOT BETWEEN 1 AND 8
     OR otlet.source_query_contract_error(
       candidate_set_coverage_rule_valid.rule -> 'coverage_query_contract',
       false
     ) IS NOT NULL THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'minimum_positive_support'
     ) IS DISTINCT FROM 'number'
     OR candidate_set_coverage_rule_valid.rule ->> 'minimum_positive_support'
       !~ '^[1-9][0-9]{0,5}$'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'minimum_source_support'
     ) IS DISTINCT FROM 'number'
     OR candidate_set_coverage_rule_valid.rule ->> 'minimum_source_support'
       !~ '^[1-9][0-9]{0,5}$'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule ->
         'maximum_cap_excluded_positive_pairs'
     ) IS DISTINCT FROM 'number'
     OR candidate_set_coverage_rule_valid.rule ->>
         'maximum_cap_excluded_positive_pairs' !~ '^(0|[1-9][0-9]{0,5})$'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'minimum_overall_coverage'
     ) IS DISTINCT FROM 'number'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'minimum_source_coverage'
     ) IS DISTINCT FROM 'number'
     OR jsonb_typeof(
       candidate_set_coverage_rule_valid.rule -> 'maximum_ordering_bias'
     ) IS DISTINCT FROM 'number' THEN
    RETURN false;
  END IF;
  IF (candidate_set_coverage_rule_valid.rule ->>
       'minimum_overall_coverage')::numeric NOT BETWEEN 0 AND 1
     OR (candidate_set_coverage_rule_valid.rule ->>
       'minimum_source_coverage')::numeric NOT BETWEEN 0 AND 1
     OR (candidate_set_coverage_rule_valid.rule ->>
       'maximum_ordering_bias')::numeric NOT BETWEEN 0 AND 1
     OR (candidate_set_coverage_rule_valid.rule ->>
       'minimum_source_support')::integer >
       (candidate_set_coverage_rule_valid.rule ->>
       'minimum_positive_support')::integer THEN
    RETURN false;
  END IF;

  FOR path_item IN
    SELECT value
    FROM jsonb_array_elements(
      candidate_set_coverage_rule_valid.rule -> 'source_path'
    ) item(value)
  LOOP
    IF jsonb_typeof(path_item) IS DISTINCT FROM 'string'
       OR NULLIF(btrim(path_item #>> '{}'), '') IS NULL
       OR octet_length(path_item #>> '{}') > 128 THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

CREATE FUNCTION otlet.build_candidate_set_coverage_rule(
  coverage_query text,
  source_path text[],
  minimum_positive_support integer,
  minimum_overall_coverage numeric,
  minimum_source_support integer,
  minimum_source_coverage numeric,
  maximum_cap_excluded_positive_pairs integer,
  maximum_ordering_bias numeric
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rule jsonb;
BEGIN
  rule := jsonb_build_object(
    'kind', 'candidate_set_coverage',
    'coverage_query_contract', otlet.build_source_query_contract(
      build_candidate_set_coverage_rule.coverage_query
    ),
    'source_path', to_jsonb(
      build_candidate_set_coverage_rule.source_path
    ),
    'minimum_positive_support',
      build_candidate_set_coverage_rule.minimum_positive_support,
    'minimum_overall_coverage',
      build_candidate_set_coverage_rule.minimum_overall_coverage,
    'minimum_source_support',
      build_candidate_set_coverage_rule.minimum_source_support,
    'minimum_source_coverage',
      build_candidate_set_coverage_rule.minimum_source_coverage,
    'maximum_cap_excluded_positive_pairs',
      build_candidate_set_coverage_rule.maximum_cap_excluded_positive_pairs,
    'maximum_ordering_bias',
      build_candidate_set_coverage_rule.maximum_ordering_bias
  );
  IF otlet.candidate_set_coverage_rule_valid(rule) IS NOT TRUE THEN
    RAISE EXCEPTION 'otlet candidate-set coverage rule is invalid';
  END IF;
  RETURN rule;
END;
$$;

CREATE FUNCTION otlet.candidate_set_coverage_workload_eligible(
  definition jsonb
) RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT COALESCE(
    $1 #>> '{source,kind}' = 'pair'
    AND COALESCE(
      $1 #> '{task,decision_contract,action_types}',
      '[]'::jsonb
    ) ? 'merge_candidate'
    AND otlet.action_declared_answer(
      'merge_candidate',
      COALESCE(NULLIF(
        $1 #>> '{task,decision_contract,answer_field}',
        ''
      ), 'match')
    ) = ANY(otlet.output_schema_enum_values(
      $1 #> '{task,output_schema}',
      COALESCE(NULLIF(
        $1 #>> '{task,decision_contract,answer_field}',
        ''
      ), 'match')
    )),
    false
  )
$$;

CREATE FUNCTION otlet.validate_candidate_set_coverage_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rule jsonb := NEW.definition #> '{population,rule,candidate_coverage}';
  baseline_definition jsonb;
  candidate_definition jsonb;
BEGIN
  IF rule IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR otlet.candidate_set_coverage_rule_valid(rule) IS NOT TRUE THEN
    RAISE EXCEPTION 'otlet candidate-set coverage declaration is invalid';
  END IF;

  SELECT revision.definition
  INTO baseline_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash =
      NEW.baseline_workload_revision_hash;
  SELECT revision.definition
  INTO candidate_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash =
      NEW.candidate_workload_revision_hash;

  IF baseline_definition #>> '{source,kind}' IS DISTINCT FROM 'pair'
     OR otlet.candidate_set_coverage_workload_eligible(
       candidate_definition
     ) IS NOT TRUE
     OR NEW.baseline_workload_revision_hash =
       NEW.candidate_workload_revision_hash
     OR ROW(
       baseline_definition #>> '{source,candidate_query}',
       baseline_definition #>> '{source,max_candidate_rows}',
       baseline_definition #> '{task,decision_contract}',
       baseline_definition #> '{task,output_schema}'
     ) IS NOT DISTINCT FROM ROW(
       candidate_definition #>> '{source,candidate_query}',
       candidate_definition #>> '{source,max_candidate_rows}',
       candidate_definition #> '{task,decision_contract}',
       candidate_definition #> '{task,output_schema}'
     ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage requires a changed pair contract';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = NEW.task_name
      AND head.active_workload_revision_hash =
        NEW.baseline_workload_revision_hash
  ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage baseline is not active';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_contracts_e_candidate_set_coverage
BEFORE INSERT ON otlet.workload_acceptance_contracts
FOR EACH ROW EXECUTE FUNCTION otlet.validate_candidate_set_coverage_contract();

CREATE FUNCTION otlet.candidate_set_positive_labels(contract_hash text)
RETURNS TABLE (
  label_id bigint,
  subject_id text,
  source_key text,
  source_type text,
  content_hash text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT
    quality.label_id,
    quality.subject_id,
    job.input #>> source_path.keys,
    jsonb_typeof(job.input #> source_path.keys),
    quality.content_hash
  FROM otlet.workload_acceptance_contracts contract
  JOIN otlet.workload_revisions revision
    ON revision.task_name = contract.task_name
   AND revision.workload_revision_hash =
     contract.candidate_workload_revision_hash
  CROSS JOIN LATERAL (
    SELECT array_agg(item.value ORDER BY item.ordinality)::text[] AS keys
    FROM jsonb_array_elements_text(
      contract.definition #>
        '{population,rule,candidate_coverage,source_path}'
    ) WITH ORDINALITY item(value, ordinality)
  ) source_path
  JOIN otlet.eval_label_quality_status quality
    ON quality.task_name = contract.task_name
   AND quality.qualification_eligible
   AND quality.expected_action_type = 'merge_candidate'
   AND quality.expected_answer = otlet.action_declared_answer(
     'merge_candidate',
     COALESCE(NULLIF(
       revision.definition #>> '{task,decision_contract,answer_field}',
       ''
     ), 'match')
   )
  JOIN otlet.actions action ON action.id = quality.action_id
  JOIN otlet.jobs job ON job.id = action.job_id
  WHERE contract.contract_hash = candidate_set_positive_labels.contract_hash
  ORDER BY quality.label_id
$$;

CREATE FUNCTION otlet.candidate_set_positive_manifest_hash(contract_hash text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.identity_hash(
    'candidate_set_positive_manifest',
    COALESCE(jsonb_agg(jsonb_build_object(
      'label_id', positive.label_id,
      'subject_id', positive.subject_id,
      'source', positive.source_key,
      'content_hash', positive.content_hash
    ) ORDER BY positive.label_id), '[]'::jsonb)
  )
  FROM otlet.candidate_set_positive_labels($1) positive
$$;

CREATE FUNCTION otlet.measure_candidate_set_coverage(contract_hash text)
RETURNS TABLE (
  candidate_manifest_hash text,
  positive_label_manifest_hash text,
  metrics jsonb,
  gate_failures jsonb,
  gate_passed boolean
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  target_definition jsonb;
  rule jsonb;
  coverage_contract jsonb;
  coverage_query text;
  coverage_ranked_query text;
  coverage_plan_cost numeric;
  target_plan_cost numeric;
  stored_target_plan_cost numeric;
  plan_cost_limit numeric;
  timeout_limit integer;
  timeout_ms integer;
  original_search_path text := current_setting('search_path');
  candidate_volume integer;
  candidate_cap integer;
  bounded_candidate_volume integer;
  candidate_query_rows integer;
  candidate_query_manifest_hash text;
  candidate_query_prefix_matches boolean;
  positive_pairs integer;
  positive_pairs_in_candidate_set integer;
  positive_pairs_in_bounded_set integer;
  positive_pairs_excluded_by_cap integer;
  positive_pairs_missed_by_sql integer;
  positive_pair_coverage numeric;
  ordering_bias numeric;
  per_source jsonb;
  source_support_failed boolean;
  source_coverage_failed boolean;
BEGIN
  SELECT stored.*
  INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = measure_candidate_set_coverage.contract_hash
    AND stored.definition #> '{population,rule,candidate_coverage}' IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet candidate-set coverage contract does not exist';
  END IF;
  rule := contract.definition #> '{population,rule,candidate_coverage}';
  coverage_contract := rule -> 'coverage_query_contract';
  coverage_query := regexp_replace(
    btrim(coverage_contract #>> '{query,raw}'),
    ';[[:space:]]*$',
    ''
  );
  coverage_ranked_query := format(
    $query$
      SELECT
        candidate.candidate_rank::bigint AS candidate_rank,
        candidate.subject_id::text AS subject_id,
        candidate.input::jsonb AS input
      FROM (%s) candidate
      ORDER BY candidate.candidate_rank::bigint NULLS FIRST
      LIMIT 100001
    $query$,
    coverage_query
  );
  SELECT revision.definition, revision.candidate_plan_cost
  INTO target_definition, stored_target_plan_cost
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = contract.task_name
    AND revision.workload_revision_hash =
      contract.candidate_workload_revision_hash;
  candidate_cap := (
    target_definition #>> '{source,max_candidate_rows}'
  )::integer;

  SELECT policy.candidate_query_statement_timeout_ms,
         policy.max_candidate_query_cost
  INTO timeout_limit, plan_cost_limit
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';
  timeout_ms := round(EXTRACT(epoch FROM
    current_setting('statement_timeout')::interval) * 1000)::integer;
  IF timeout_ms <= 0 OR timeout_ms > timeout_limit THEN
    RAISE EXCEPTION 'otlet candidate-set coverage requires statement_timeout between 1 ms and % ms',
      timeout_limit;
  END IF;

  PERFORM otlet.source_query_contract_guard(coverage_contract, true);
  SELECT preflight.candidate_plan_cost
  INTO coverage_plan_cost
  FROM otlet.preflight_candidate_query(
    coverage_ranked_query,
    true,
    false,
    coverage_contract
  ) preflight;

  IF to_regclass('pg_temp.otlet_candidate_set_coverage_measure') IS NULL THEN
    CREATE TEMP TABLE otlet_candidate_set_coverage_measure (
      candidate_rank bigint,
      subject_id text,
      input jsonb,
      input_hash text
    ) ON COMMIT DROP;
  ELSE
    TRUNCATE pg_temp.otlet_candidate_set_coverage_measure;
  END IF;
  PERFORM set_config(
    'search_path',
    otlet.source_query_safe_search_path(coverage_contract),
    true
  );
  BEGIN
    EXECUTE format(
      $query$
        INSERT INTO pg_temp.otlet_candidate_set_coverage_measure (
          candidate_rank,
          subject_id,
          input
        )
        SELECT
          candidate.candidate_rank,
          candidate.subject_id,
          candidate.input
        FROM (%s) candidate
      $query$,
      coverage_ranked_query
    );
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('search_path', original_search_path, true);
    RAISE EXCEPTION 'otlet candidate-set coverage query failed: %', SQLERRM;
  END;
  PERFORM set_config('search_path', original_search_path, true);

  SELECT count(*)::integer
  INTO candidate_volume
  FROM pg_temp.otlet_candidate_set_coverage_measure;
  IF candidate_volume NOT BETWEEN 0 AND 100000
     OR EXISTS (
       SELECT 1
       FROM pg_temp.otlet_candidate_set_coverage_measure candidate
       WHERE candidate.candidate_rank IS NULL
          OR NULLIF(btrim(candidate.subject_id), '') IS NULL
          OR octet_length(candidate.subject_id) > 1024
          OR candidate.input IS NULL
     )
     OR candidate_volume <> (
       SELECT count(DISTINCT candidate.candidate_rank)::integer
       FROM pg_temp.otlet_candidate_set_coverage_measure candidate
     )
     OR candidate_volume <> (
       SELECT count(DISTINCT candidate.subject_id)::integer
       FROM pg_temp.otlet_candidate_set_coverage_measure candidate
     )
     OR (
       candidate_volume > 0
       AND (
         (SELECT min(candidate.candidate_rank)
          FROM pg_temp.otlet_candidate_set_coverage_measure candidate) <> 1
         OR (SELECT max(candidate.candidate_rank)
             FROM pg_temp.otlet_candidate_set_coverage_measure candidate) <>
           candidate_volume
       )
     ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage query must return 0 to 100000 unique subjects with contiguous unique ranks';
  END IF;
  UPDATE pg_temp.otlet_candidate_set_coverage_measure candidate
  SET input_hash = otlet.identity_hash('candidate_set_input', candidate.input);
  SELECT otlet.identity_hash(
    'candidate_set_manifest',
    COALESCE(jsonb_agg(jsonb_build_object(
      'candidate_rank', candidate.candidate_rank,
      'subject_id', candidate.subject_id,
      'input_hash', candidate.input_hash
    ) ORDER BY candidate.candidate_rank), '[]'::jsonb)
  )
  INTO candidate_manifest_hash
  FROM pg_temp.otlet_candidate_set_coverage_measure candidate;

  PERFORM otlet.require_workload_source_contract(
    contract.task_name,
    contract.candidate_workload_revision_hash
  );
  SELECT preflight.candidate_plan_cost
  INTO target_plan_cost
  FROM otlet.preflight_candidate_query(
    target_definition #>> '{source,candidate_query}',
    true,
    false,
    target_definition #> '{source,query_contract}'
  ) preflight;
  IF to_regclass('pg_temp.otlet_candidate_set_coverage_target') IS NULL THEN
    CREATE TEMP TABLE otlet_candidate_set_coverage_target (
      subject_id text,
      input jsonb,
      input_hash text
    ) ON COMMIT DROP;
  ELSE
    TRUNCATE pg_temp.otlet_candidate_set_coverage_target;
  END IF;
  INSERT INTO pg_temp.otlet_candidate_set_coverage_target (
    subject_id,
    input,
    input_hash
  )
  SELECT
    candidate.subject_id,
    candidate.input,
    otlet.identity_hash('candidate_set_input', candidate.input)
  FROM otlet.validated_task_input_rows(
    target_definition #>> '{source,candidate_query}',
    candidate_cap + 1,
    workload_definition => target_definition
  ) candidate;
  SELECT count(*)::integer
  INTO candidate_query_rows
  FROM pg_temp.otlet_candidate_set_coverage_target;
  SELECT otlet.identity_hash(
    'candidate_query_manifest',
    COALESCE(jsonb_agg(jsonb_build_object(
      'subject_id', candidate.subject_id,
      'input_hash', candidate.input_hash
    ) ORDER BY candidate.subject_id COLLATE "C"), '[]'::jsonb)
  )
  INTO candidate_query_manifest_hash
  FROM pg_temp.otlet_candidate_set_coverage_target candidate;
  bounded_candidate_volume := LEAST(candidate_volume, candidate_cap);
  candidate_query_prefix_matches :=
    candidate_query_rows = bounded_candidate_volume
    AND NOT EXISTS (
      SELECT 1
      FROM pg_temp.otlet_candidate_set_coverage_target target
      LEFT JOIN pg_temp.otlet_candidate_set_coverage_measure candidate
        ON candidate.subject_id = target.subject_id
       AND candidate.candidate_rank <= candidate_cap
       AND candidate.input IS NOT DISTINCT FROM target.input
      WHERE candidate.subject_id IS NULL
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_temp.otlet_candidate_set_coverage_measure candidate
      LEFT JOIN pg_temp.otlet_candidate_set_coverage_target target
        ON target.subject_id = candidate.subject_id
       AND target.input IS NOT DISTINCT FROM candidate.input
      WHERE candidate.candidate_rank <= candidate_cap
        AND target.subject_id IS NULL
    );

  IF EXISTS (
    SELECT 1
    FROM otlet.candidate_set_positive_labels(contract.contract_hash) positive
    WHERE positive.source_type IS DISTINCT FROM 'string'
       OR NULLIF(btrim(positive.source_key), '') IS NULL
       OR octet_length(positive.source_key) > 128
  ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage source path is missing or invalid';
  END IF;
  IF EXISTS (
    SELECT positive.subject_id
    FROM otlet.candidate_set_positive_labels(contract.contract_hash) positive
    GROUP BY positive.subject_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage has duplicate current positive labels';
  END IF;
  positive_label_manifest_hash :=
    otlet.candidate_set_positive_manifest_hash(contract.contract_hash);

  WITH positives AS MATERIALIZED (
    SELECT *
    FROM otlet.candidate_set_positive_labels(contract.contract_hash)
  ), ranked AS (
    SELECT
      positive.source_key,
      candidate.candidate_rank,
      candidate.candidate_rank IS NOT NULL AS in_candidate_set,
      COALESCE(candidate.candidate_rank <= candidate_cap, false)
        AS in_bounded_set,
      COALESCE(candidate.candidate_rank > candidate_cap, false)
        AS excluded_by_cap,
      CASE
        WHEN candidate.candidate_rank IS NULL THEN 1::numeric
        WHEN candidate_volume <= 1 THEN 0::numeric
        ELSE (candidate.candidate_rank - 1)::numeric /
          (candidate_volume - 1)::numeric
      END AS normalized_rank
    FROM positives positive
    LEFT JOIN pg_temp.otlet_candidate_set_coverage_measure candidate
      USING (subject_id)
  ), source_metrics AS (
    SELECT
      source_key,
      count(*)::integer AS positive_pairs,
      count(*) FILTER (WHERE in_candidate_set)::integer
        AS positive_pairs_in_candidate_set,
      count(*) FILTER (WHERE in_bounded_set)::integer
        AS positive_pairs_in_bounded_set,
      count(*) FILTER (WHERE excluded_by_cap)::integer
        AS positive_pairs_excluded_by_cap,
      count(*) FILTER (WHERE NOT in_candidate_set)::integer
        AS positive_pairs_missed_by_sql,
      round(
        count(*) FILTER (WHERE in_bounded_set)::numeric /
          NULLIF(count(*), 0)::numeric,
        12
      ) AS positive_pair_coverage,
      round(avg(normalized_rank), 12) AS mean_normalized_rank
    FROM ranked
    GROUP BY source_key
  )
  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE in_candidate_set)::integer,
    count(*) FILTER (WHERE in_bounded_set)::integer,
    count(*) FILTER (WHERE excluded_by_cap)::integer,
    count(*) FILTER (WHERE NOT in_candidate_set)::integer,
    round(
      count(*) FILTER (WHERE in_bounded_set)::numeric /
        NULLIF(count(*), 0)::numeric,
      12
    ),
    round(COALESCE((
      SELECT max(source.mean_normalized_rank) -
        min(source.mean_normalized_rank)
      FROM source_metrics source
    ), 0), 12),
    COALESCE((
      SELECT jsonb_object_agg(source.source_key, jsonb_build_object(
        'positive_pairs', source.positive_pairs,
        'positive_pairs_in_candidate_set',
          source.positive_pairs_in_candidate_set,
        'positive_pairs_in_bounded_set',
          source.positive_pairs_in_bounded_set,
        'positive_pairs_excluded_by_cap',
          source.positive_pairs_excluded_by_cap,
        'positive_pairs_missed_by_sql',
          source.positive_pairs_missed_by_sql,
        'positive_pair_coverage', source.positive_pair_coverage,
        'mean_normalized_rank', source.mean_normalized_rank
      ) ORDER BY source.source_key)
      FROM source_metrics source
    ), '{}'::jsonb),
    COALESCE((
      SELECT bool_or(source.positive_pairs <
        (rule ->> 'minimum_source_support')::integer)
      FROM source_metrics source
    ), false),
    COALESCE((
      SELECT bool_or(source.positive_pair_coverage <
        (rule ->> 'minimum_source_coverage')::numeric)
      FROM source_metrics source
    ), false)
  INTO
    positive_pairs,
    positive_pairs_in_candidate_set,
    positive_pairs_in_bounded_set,
    positive_pairs_excluded_by_cap,
    positive_pairs_missed_by_sql,
    positive_pair_coverage,
    ordering_bias,
    per_source,
    source_support_failed,
    source_coverage_failed
  FROM ranked;

  SELECT COALESCE(jsonb_agg(failure ORDER BY ord), '[]'::jsonb)
  INTO gate_failures
  FROM (VALUES
    (1, 'candidate_sql_not_bounded_prefix',
      candidate_query_prefix_matches IS NOT TRUE),
    (2, 'positive_support_below_minimum',
      positive_pairs < (rule ->> 'minimum_positive_support')::integer),
    (3, 'source_support_below_minimum', source_support_failed),
    (4, 'overall_coverage_below_minimum',
      COALESCE(positive_pair_coverage, 0) <
        (rule ->> 'minimum_overall_coverage')::numeric),
    (5, 'source_coverage_below_minimum', source_coverage_failed),
    (6, 'cap_excluded_positive_pairs_exceeded',
      positive_pairs_excluded_by_cap >
        (rule ->> 'maximum_cap_excluded_positive_pairs')::integer),
    (7, 'ordering_bias_exceeded',
      ordering_bias > (rule ->> 'maximum_ordering_bias')::numeric)
  ) failed(ord, failure, failed)
  WHERE failed.failed;
  gate_passed := jsonb_array_length(gate_failures) = 0;
  metrics := jsonb_build_object(
    'candidate_volume', candidate_volume,
    'bounded_candidate_volume', bounded_candidate_volume,
    'candidate_query_rows', candidate_query_rows,
    'candidate_cap', candidate_cap,
    'candidates_excluded_by_cap',
      GREATEST(candidate_volume - candidate_cap, 0),
    'candidate_query_prefix_matches', candidate_query_prefix_matches,
    'candidate_query_manifest_hash', candidate_query_manifest_hash,
    'positive_pairs', positive_pairs,
    'positive_pairs_in_candidate_set', positive_pairs_in_candidate_set,
    'positive_pairs_in_bounded_set', positive_pairs_in_bounded_set,
    'positive_pairs_excluded_by_cap', positive_pairs_excluded_by_cap,
    'positive_pairs_missed_by_sql', positive_pairs_missed_by_sql,
    'positive_pair_coverage', to_jsonb(positive_pair_coverage),
    'ordering_bias', to_jsonb(ordering_bias),
    'per_source', per_source,
    'stored_candidate_plan_cost', to_jsonb(stored_target_plan_cost),
    'measured_candidate_plan_cost', to_jsonb(target_plan_cost),
    'coverage_query_plan_cost', to_jsonb(coverage_plan_cost),
    'candidate_plan_cost_limit', to_jsonb(plan_cost_limit)
  );
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.guard_candidate_set_coverage_append()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.candidate_set_coverage_append', true) = 'on'
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet candidate-set coverage evidence is append only';
END;
$$;

CREATE FUNCTION otlet.validate_candidate_set_coverage_report()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM
       'otlet.candidate_set_coverage.v1'
     OR NEW.definition ->> 'contract_hash' IS DISTINCT FROM NEW.contract_hash
     OR NEW.definition ->> 'task_name' IS DISTINCT FROM NEW.task_name
     OR NEW.definition ->> 'baseline_workload_revision_hash' IS DISTINCT FROM
       NEW.baseline_workload_revision_hash
     OR NEW.definition ->> 'candidate_workload_revision_hash' IS DISTINCT FROM
       NEW.candidate_workload_revision_hash
     OR NEW.definition ->> 'candidate_manifest_hash' IS DISTINCT FROM
       NEW.candidate_manifest_hash
     OR NEW.definition ->> 'positive_label_manifest_hash' IS DISTINCT FROM
       NEW.positive_label_manifest_hash
     OR NEW.definition -> 'metrics' IS DISTINCT FROM NEW.metrics
     OR NEW.definition -> 'gate_failures' IS DISTINCT FROM NEW.gate_failures
     OR (NEW.definition ->> 'gate_passed')::boolean IS DISTINCT FROM
       NEW.gate_passed
     OR NEW.definition ->> 'reason' IS DISTINCT FROM NEW.reason
     OR octet_length(NEW.definition::text) > 262144
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(NEW.gate_failures) failure(value)
       WHERE jsonb_typeof(failure.value) <> 'string'
     )
     OR NEW.gate_passed IS DISTINCT FROM
       (jsonb_array_length(NEW.gate_failures) = 0)
     OR NEW.report_hash IS DISTINCT FROM
       otlet.identity_hash('candidate_set_coverage_report', NEW.definition)
  THEN
    RAISE EXCEPTION 'otlet candidate-set coverage report identity is invalid';
  END IF;
  RETURN NEW;
EXCEPTION WHEN invalid_text_representation THEN
  RAISE EXCEPTION 'otlet candidate-set coverage report identity is invalid';
END;
$$;

CREATE TRIGGER candidate_set_coverage_reports_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.candidate_set_coverage_reports
FOR EACH ROW EXECUTE FUNCTION otlet.guard_candidate_set_coverage_append();

CREATE TRIGGER candidate_set_coverage_reports_b_validate
BEFORE INSERT ON otlet.candidate_set_coverage_reports
FOR EACH ROW EXECUTE FUNCTION otlet.validate_candidate_set_coverage_report();

CREATE TRIGGER candidate_set_coverage_reports_truncate_guard
BEFORE TRUNCATE ON otlet.candidate_set_coverage_reports
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_candidate_set_coverage_append();

CREATE FUNCTION otlet.record_candidate_set_coverage(
  contract_hash text,
  reason text
) RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  measured record;
  definition jsonb;
  report_hash text;
  existing otlet.candidate_set_coverage_reports%ROWTYPE;
  previous_append text := current_setting(
    'otlet.candidate_set_coverage_append',
    true
  );
BEGIN
  IF NULLIF(btrim(record_candidate_set_coverage.reason), '') IS NULL
     OR octet_length(record_candidate_set_coverage.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet candidate-set coverage reason is required and bounded';
  END IF;
  SELECT stored.*
  INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = record_candidate_set_coverage.contract_hash
    AND stored.definition #> '{population,rule,candidate_coverage}' IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = stored.task_name
        AND successor.supersedes_contract_hash = stored.contract_hash
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet current candidate-set coverage contract does not exist';
  END IF;
  IF clock_timestamp() < (
    contract.definition #>> '{observation_window,ends_at}'
  )::timestamptz THEN
    RAISE EXCEPTION 'otlet candidate-set coverage observation window is open';
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || contract.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_candidate_set_coverage:' || contract.contract_hash,
    0
  ));
  SELECT * INTO existing
  FROM otlet.candidate_set_coverage_reports report
  WHERE report.contract_hash = contract.contract_hash;
  IF FOUND THEN
    IF existing.reason IS DISTINCT FROM btrim(
      record_candidate_set_coverage.reason
    ) THEN
      RAISE EXCEPTION 'otlet candidate-set coverage contract already has a different report';
    END IF;
    RETURN existing.report_hash;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = contract.task_name
      AND head.active_workload_revision_hash =
        contract.baseline_workload_revision_hash
  ) THEN
    RAISE EXCEPTION 'otlet candidate-set coverage baseline is not active';
  END IF;

  SELECT *
  INTO measured
  FROM otlet.measure_candidate_set_coverage(contract.contract_hash);
  definition := jsonb_build_object(
    'format', 'otlet.candidate_set_coverage.v1',
    'contract_hash', contract.contract_hash,
    'task_name', contract.task_name,
    'baseline_workload_revision_hash',
      contract.baseline_workload_revision_hash,
    'candidate_workload_revision_hash',
      contract.candidate_workload_revision_hash,
    'candidate_manifest_hash', measured.candidate_manifest_hash,
    'positive_label_manifest_hash',
      measured.positive_label_manifest_hash,
    'metrics', measured.metrics,
    'gate_failures', measured.gate_failures,
    'gate_passed', measured.gate_passed,
    'reason', btrim(record_candidate_set_coverage.reason)
  );
  report_hash := otlet.identity_hash(
    'candidate_set_coverage_report',
    definition
  );

  PERFORM set_config('otlet.candidate_set_coverage_append', 'on', true);
  INSERT INTO otlet.candidate_set_coverage_reports (
    report_hash,
    contract_hash,
    task_name,
    baseline_workload_revision_hash,
    candidate_workload_revision_hash,
    candidate_manifest_hash,
    positive_label_manifest_hash,
    metrics,
    gate_failures,
    gate_passed,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    report_hash,
    contract.contract_hash,
    contract.task_name,
    contract.baseline_workload_revision_hash,
    contract.candidate_workload_revision_hash,
    measured.candidate_manifest_hash,
    measured.positive_label_manifest_hash,
    measured.metrics,
    measured.gate_failures,
    measured.gate_passed,
    definition,
    btrim(record_candidate_set_coverage.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config(
    'otlet.candidate_set_coverage_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN report_hash;
END;
$$;

CREATE FUNCTION otlet.candidate_set_coverage_report_current(report_hash text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT report.gate_passed
    AND head.active_workload_revision_hash =
      report.baseline_workload_revision_hash
    AND report.positive_label_manifest_hash =
      otlet.candidate_set_positive_manifest_hash(report.contract_hash)
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_contracts successor
      WHERE successor.task_name = report.task_name
        AND successor.supersedes_contract_hash = report.contract_hash
    )
  FROM otlet.candidate_set_coverage_reports report
  JOIN otlet.workload_revision_heads head ON head.task_name = report.task_name
  WHERE report.report_hash = candidate_set_coverage_report_current.report_hash
$$;

CREATE OR REPLACE FUNCTION otlet.rollback_workload_revision(
  task_name text,
  expected_active_workload_revision_hash text,
  target_workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rollback_hash text;
  result_hash text;
  previous_operation text := current_setting(
    'otlet.workload_revision_operation',
    true
  );
BEGIN
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || rollback_workload_revision.task_name,
    0
  ));
  SELECT COALESCE(
    rollback_workload_revision.target_workload_revision_hash,
    head.previous_workload_revision_hash
  )
  INTO rollback_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = rollback_workload_revision.task_name
    AND head.active_workload_revision_hash =
      rollback_workload_revision.expected_active_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision rollback conflict for task %',
      rollback_workload_revision.task_name;
  END IF;
  IF rollback_hash IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no workload revision to roll back to',
      rollback_workload_revision.task_name;
  END IF;

  PERFORM set_config('otlet.workload_revision_operation', 'rollback', true);
  BEGIN
    result_hash := otlet.promote_workload_revision(
      rollback_workload_revision.task_name,
      rollback_hash,
      rollback_workload_revision.expected_active_workload_revision_hash
    );
    UPDATE otlet.workload_revision_heads head
    SET previous_workload_revision_hash = NULL
    WHERE head.task_name = rollback_workload_revision.task_name
      AND head.active_workload_revision_hash = rollback_hash
      AND head.previous_workload_revision_hash =
        rollback_workload_revision.expected_active_workload_revision_hash;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config(
      'otlet.workload_revision_operation',
      COALESCE(previous_operation, ''),
      true
    );
    RAISE;
  END;
  PERFORM set_config(
    'otlet.workload_revision_operation',
    COALESCE(previous_operation, ''),
    true
  );
  RETURN result_hash;
END;
$$;

CREATE FUNCTION otlet.guard_candidate_set_coverage_promotion()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  baseline_definition jsonb;
  candidate_definition jsonb;
  report otlet.candidate_set_coverage_reports%ROWTYPE;
  measured record;
BEGIN
  IF TG_OP = 'INSERT'
     OR NEW.active_workload_revision_hash IS NOT DISTINCT FROM
       OLD.active_workload_revision_hash
     OR (
       current_setting('otlet.workload_revision_operation', true) = 'rollback'
       AND NEW.active_workload_revision_hash IS NOT DISTINCT FROM
           OLD.previous_workload_revision_hash
       AND NEW.previous_workload_revision_hash IS NOT DISTINCT FROM
           OLD.active_workload_revision_hash
     ) THEN
    RETURN NEW;
  END IF;

  SELECT revision.definition
  INTO baseline_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = OLD.active_workload_revision_hash;
  SELECT revision.definition
  INTO candidate_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.active_workload_revision_hash;
  IF otlet.candidate_set_coverage_workload_eligible(
       candidate_definition
     ) IS NOT TRUE
     OR ROW(
       baseline_definition #>> '{source,candidate_query}',
       baseline_definition #>> '{source,max_candidate_rows}',
       baseline_definition #> '{task,decision_contract}',
       baseline_definition #> '{task,output_schema}'
     ) IS NOT DISTINCT FROM ROW(
       candidate_definition #>> '{source,candidate_query}',
       candidate_definition #>> '{source,max_candidate_rows}',
       candidate_definition #> '{task,decision_contract}',
       candidate_definition #> '{task,output_schema}'
     ) THEN
    RETURN NEW;
  END IF;

  PERFORM otlet.require_workload_source_contract(
    NEW.task_name,
    NEW.active_workload_revision_hash
  );
  SELECT stored.*
  INTO report
  FROM otlet.candidate_set_coverage_reports stored
  WHERE stored.task_name = NEW.task_name
    AND stored.baseline_workload_revision_hash =
      OLD.active_workload_revision_hash
    AND stored.candidate_workload_revision_hash =
      NEW.active_workload_revision_hash
    AND otlet.candidate_set_coverage_report_current(stored.report_hash)
  ORDER BY stored.created_at DESC, stored.report_hash DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet pair workload promotion requires a current passing candidate-set coverage report';
  END IF;

  SELECT *
  INTO measured
  FROM otlet.measure_candidate_set_coverage(report.contract_hash);
  IF measured.gate_passed IS NOT TRUE
     OR measured.candidate_manifest_hash IS DISTINCT FROM
       report.candidate_manifest_hash
     OR measured.positive_label_manifest_hash IS DISTINCT FROM
       report.positive_label_manifest_hash
     OR measured.metrics ->> 'candidate_query_manifest_hash' IS DISTINCT FROM
       report.metrics ->> 'candidate_query_manifest_hash' THEN
    RAISE EXCEPTION 'otlet pair workload promotion requires a current passing candidate-set coverage report';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_candidate_set_coverage
BEFORE INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.guard_candidate_set_coverage_promotion();

CREATE VIEW otlet.candidate_set_coverage_status AS
SELECT
  report.report_hash,
  report.contract_hash,
  report.task_name,
  report.baseline_workload_revision_hash,
  report.candidate_workload_revision_hash,
  (report.metrics ->> 'candidate_volume')::integer AS candidate_volume,
  (report.metrics ->> 'bounded_candidate_volume')::integer
    AS bounded_candidate_volume,
  (report.metrics ->> 'candidate_query_rows')::integer
    AS candidate_query_rows,
  (report.metrics ->> 'candidate_cap')::integer AS candidate_cap,
  (report.metrics ->> 'candidates_excluded_by_cap')::integer
    AS candidates_excluded_by_cap,
  (report.metrics ->> 'positive_pairs')::integer AS positive_pairs,
  (report.metrics ->> 'positive_pairs_in_candidate_set')::integer
    AS positive_pairs_in_candidate_set,
  (report.metrics ->> 'positive_pairs_in_bounded_set')::integer
    AS positive_pairs_in_bounded_set,
  (report.metrics ->> 'positive_pairs_excluded_by_cap')::integer
    AS positive_pairs_excluded_by_cap,
  (report.metrics ->> 'positive_pairs_missed_by_sql')::integer
    AS positive_pairs_missed_by_sql,
  (report.metrics ->> 'positive_pair_coverage')::numeric
    AS positive_pair_coverage,
  (report.metrics ->> 'ordering_bias')::numeric AS ordering_bias,
  report.metrics -> 'per_source' AS per_source,
  (report.metrics ->> 'stored_candidate_plan_cost')::numeric
    AS stored_candidate_plan_cost,
  (report.metrics ->> 'measured_candidate_plan_cost')::numeric
    AS measured_candidate_plan_cost,
  (report.metrics ->> 'coverage_query_plan_cost')::numeric
    AS coverage_query_plan_cost,
  (report.metrics ->> 'candidate_plan_cost_limit')::numeric
    AS candidate_plan_cost_limit,
  report.gate_failures,
  report.gate_passed,
  report.candidate_manifest_hash,
  report.positive_label_manifest_hash,
  head.active_workload_revision_hash =
    report.baseline_workload_revision_hash AS active_baseline,
  NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = report.task_name
      AND successor.supersedes_contract_hash = report.contract_hash
  ) AS current_contract,
  report.positive_label_manifest_hash =
    otlet.candidate_set_positive_manifest_hash(report.contract_hash)
    AS label_manifest_current,
  otlet.candidate_set_coverage_report_current(report.report_hash)
    AS report_current,
  report.reason,
  report.authenticated_role_name AS recorded_by,
  report.active_role_name AS recorded_as,
  report.created_at
FROM otlet.candidate_set_coverage_reports report
LEFT JOIN otlet.workload_revision_heads head ON head.task_name = report.task_name;

REVOKE ALL ON TABLE otlet.candidate_set_coverage_reports FROM PUBLIC;
REVOKE ALL ON TABLE otlet.candidate_set_coverage_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.candidate_set_coverage_rule_valid(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.build_candidate_set_coverage_rule(
  text, text[], integer, numeric, integer, numeric, integer, numeric
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.candidate_set_coverage_workload_eligible(jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_candidate_set_coverage_contract()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.candidate_set_positive_labels(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.candidate_set_positive_manifest_hash(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.measure_candidate_set_coverage(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_candidate_set_coverage_append()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_candidate_set_coverage_report()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_candidate_set_coverage(text, text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.candidate_set_coverage_report_current(text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.rollback_workload_revision(text, text, text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_candidate_set_coverage_promotion()
  FROM PUBLIC;
