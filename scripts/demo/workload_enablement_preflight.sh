log "Checking workload enablement preflight"

preflight_task="workload_enablement_preflight_demo"
cleanup_task "$preflight_task"

psql_exec -qAt -v task_name="$preflight_task" -v model_name="$strong_model_name" \
  >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT value::text AS subject_id,
           jsonb_build_object('value', value) AS input
    FROM generate_series(1, 3) value
  $$,
  'Return one JSON object with exactly two top-level keys: "output" then "actions". output must be {}. actions must be []. Do not close the outer object until actions has been written. No markdown.',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"max_tokens":128,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["value"]}'::jsonb
);
SELECT otlet.promote_configured_workload_revision(:'task_name');
SQL

preflight_revision="$(psql_value -v task_name="$preflight_task" <<'SQL'
SELECT active_workload_revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = :'task_name';
SQL
)"
preflight_fallback_contract="$(psql_value \
  -v task_name="$preflight_task" -v revision="$preflight_revision" <<'SQL'
BEGIN READ ONLY;
SELECT report.runtime_sample_scope || '|' ||
       (
         report.candidate_plan_status = 'ready'
         AND report.candidate_plan_error IS NULL
         AND report.candidate_plan_rows =
           jsonb_extract_path_text(
             report.candidate_plan, '0', 'Plan', 'Plan Rows'
           )::bigint
         AND report.candidate_plan_width_bytes =
           jsonb_extract_path_text(
             report.candidate_plan, '0', 'Plan', 'Plan Width'
           )::bigint
         AND report.candidate_plan_cost =
           jsonb_extract_path_text(
             report.candidate_plan, '0', 'Plan', 'Total Cost'
         )::numeric
         AND report.candidate_plan_rows = 3
         AND report.estimated_candidates = 3
         AND report.estimated_jobs = 3
         AND report.estimated_total_input_bytes =
           report.estimated_jobs * report.estimated_input_bytes_per_job
         AND report.estimated_peak_queue_input_bytes =
           report.estimated_total_input_bytes
         AND report.estimated_model_ms_p50 =
           report.estimated_jobs * report.model_ms_p50
         AND report.runtime_sample_scope <> 'active_revision'
         AND report.uncertainty_level = 'high'
         AND report.uncertainty_reasons @> ARRAY[
           'planner_cardinality_estimate'
         ]
         AND (
           report.input_observations > 0
           OR report.uncertainty_reasons @> ARRAY[
             'input_bytes_from_plan_width'
           ]
         )
         AND report.within_current_policy
       )::text
FROM otlet.workload_enablement_preflight(
  :'task_name', :'revision', 'backfill', 3, 3, 64, 3
) report;
ROLLBACK;
SQL
)"
case "$preflight_fallback_contract" in
  attempt_deadline_fallback\|true|task_route_history\|true|route_model_history\|true) ;;
  *)
    echo "Expected a valid unsupported-history preflight, got $preflight_fallback_contract" >&2
    exit 1
    ;;
esac

psql_exec -qAt -v task_name="$preflight_task" >/dev/null <<'SQL'
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$preflight_task" 3 300 1

preflight_observed_contract="$(psql_value \
  -v task_name="$preflight_task" -v revision="$preflight_revision" <<'SQL'
WITH expected AS (
  SELECT
    count(*)::bigint AS observations,
    percentile_disc(0.5) WITHIN GROUP (
      ORDER BY prompt_decode_ms + generate_ms
    ) AS model_median_ms,
    percentile_disc(0.5) WITHIN GROUP (
      ORDER BY accounted_worker_ms
    ) AS service_median_ms
  FROM (
    SELECT
      timing.prompt_decode_ms,
      timing.generate_ms,
      timing.accounted_worker_ms
    FROM otlet.runtime_stage_timing_status timing
    JOIN otlet.jobs job ON job.id = timing.job_id
    WHERE job.task_name = :'task_name'
      AND job.workload_revision_hash = :'revision'
      AND job.status = 'complete'
      AND NOT timing.inference_cache_hit
      AND timing.accounted_worker_ms > 0
      AND timing.prompt_decode_ms + timing.generate_ms > 0
    ORDER BY job.finished_at DESC, job.id DESC
    LIMIT 101
  ) samples
), report AS (
  SELECT *
  FROM otlet.workload_enablement_preflight(
    :'task_name', :'revision', 'backfill', 3, 3, 64, 3
  )
)
SELECT report.runtime_observations::text || '|' ||
       report.runtime_sample_scope || '|' ||
       report.candidate_plan_rows::text || '|' ||
       report.uncertainty_level || '|' ||
       (
         report.runtime_observations = expected.observations
         AND report.runtime_observations = 3
         AND report.model_ms_p50 = expected.model_median_ms
         AND report.service_ms_p50 = expected.service_median_ms
         AND report.input_observations > 0
         AND report.latest_observed_candidate_rows = 3
         AND report.estimated_candidates = 3
         AND report.estimated_total_input_bytes =
           report.estimated_jobs * report.estimated_input_bytes_per_job
         AND report.estimated_model_ms_p50 =
           report.estimated_jobs * report.model_ms_p50
         AND report.estimated_catch_up_ms_p25 <=
           report.estimated_catch_up_ms_p50
         AND report.estimated_catch_up_ms_p50 <=
           report.estimated_catch_up_ms_p75
         AND report.uncertainty_level = 'medium'
       )::text
FROM report CROSS JOIN expected;
SQL
)"
[ "$preflight_observed_contract" = "3|active_revision|3|medium|true" ] || {
  echo "Observed workload preflight mismatch: $preflight_observed_contract" >&2
  exit 1
}

preflight_surface_contract="$(psql_value \
  -v task_name="$preflight_task" \
  -v revision="$preflight_revision" \
  -v model_name="$strong_model_name" <<'SQL'
BEGIN;

CREATE FUNCTION pg_temp.expect_error(statement text, fragment text) RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    EXECUTE expect_error.statement;
  EXCEPTION WHEN OTHERS THEN
    RETURN position(expect_error.fragment IN SQLERRM) > 0;
  END;
  RETURN false;
END
$function$;

CREATE TABLE public.workload_preflight_row_source (
  id text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.workload_preflight_row_source
VALUES ('row-1', 'one'), ('row-2', 'two');
ANALYZE public.workload_preflight_row_source;
SELECT otlet.create_watch(
  watch_name => 'workload_preflight_row',
  kind => 'row',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  table_name => 'public.workload_preflight_row_source'::regclass,
  subject_column => 'id',
  runtime_options => '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb
) \g /dev/null

CREATE TABLE public.workload_preflight_pair_source (
  id text PRIMARY KEY,
  left_value text NOT NULL,
  right_value text NOT NULL
);
INSERT INTO public.workload_preflight_pair_source
VALUES ('pair-1', 'one', 'uno'), ('pair-2', 'two', 'dos');
ANALYZE public.workload_preflight_pair_source;
SELECT otlet.create_watch(
  watch_name => 'workload_preflight_pair',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  candidate_query => $$
    SELECT id AS subject_id,
           jsonb_build_object('left', left_value, 'right', right_value) AS input
    FROM public.workload_preflight_pair_source
  $$,
  record_type => 'workload_preflight_pair',
  runtime_options => '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  max_candidate_rows => 1,
  pair_sources => '[{"table":"public.workload_preflight_pair_source","subject_column":"id"}]'::jsonb
) \g /dev/null
SELECT otlet.create_watch(
  watch_name => 'workload_preflight_pair_empty',
  kind => 'pair',
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  candidate_query => $$
    SELECT id AS subject_id,
           jsonb_build_object('left', left_value, 'right', right_value) AS input
    FROM public.workload_preflight_pair_source
  $$,
  record_type => 'workload_preflight_pair_empty',
  runtime_options => '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  max_candidate_rows => 10000,
  pair_sources => '[{"table":"public.workload_preflight_pair_source","subject_column":"id"}]'::jsonb
) \g /dev/null

WITH revision AS (
  SELECT revision.workload_revision_hash, revision.definition
  FROM otlet.workload_revisions revision
  JOIN otlet.workload_revision_heads head
    ON head.task_name = revision.task_name
   AND head.active_workload_revision_hash = revision.workload_revision_hash
  WHERE revision.task_name = 'workload_preflight_pair_task'
), seeded_record AS (
  INSERT INTO otlet.records (record_type, subject_id, body)
  VALUES ('workload_preflight_pair', 'pair-1', '{}'::jsonb)
  RETURNING id
)
INSERT INTO otlet.semantic_materializations (
  record_id,
  record_type,
  subject_id,
  task_name,
  model_name,
  body,
  source_hash,
  content_hash,
  contract_hash,
  freshness_basis
)
SELECT
  seeded_record.id,
  'workload_preflight_pair',
  'pair-1',
  'workload_preflight_pair_task',
  revision.definition #>> '{models,direct,name}',
  '{}'::jsonb,
  otlet.semantic_source_hash('{"left":"one","right":"uno"}'::jsonb),
  otlet.semantic_content_hash(
    '{"left":"one","right":"uno"}'::jsonb,
    revision.definition #> '{task,input_shaping}'
  ),
  revision.workload_revision_hash,
  'content_hash_match'
FROM revision
CROSS JOIN seeded_record;

SELECT otlet.create_task(
  task_name => 'workload_preflight_suspended_queue',
  input_query => $$
    SELECT 'suspended'::text AS subject_id,
           '{"value":"suspended"}'::jsonb AS input
  $$,
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name',
  runtime_options => '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  input_shaping => '{"source_fields":["value"]}'::jsonb
) \g /dev/null
SELECT otlet.promote_configured_workload_revision(
  'workload_preflight_suspended_queue'
) AS suspended_revision \gset
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  job_origin
) VALUES (
  'workload_preflight_suspended_queue',
  :'suspended_revision',
  'suspended',
  '{"value":"suspended"}'::jsonb,
  'task_run'
);
SELECT otlet.set_task_lifecycle(
  'workload_preflight_suspended_queue',
  'paused',
  :'suspended_revision'
) \g /dev/null

SAVEPOINT before_semantic_read_only;
SET LOCAL transaction_read_only = on;
DO $proof$
BEGIN
  IF current_setting('transaction_read_only') <> 'on'
     OR NOT (
       SELECT source_kind = 'row' AND estimated_candidates = 2
       FROM otlet.workload_enablement_preflight(
         'workload_preflight_row_task',
         (
           SELECT active_workload_revision_hash
           FROM otlet.workload_revision_heads
           WHERE task_name = 'workload_preflight_row_task'
         ),
         'watch'
       )
     )
     OR NOT (
       SELECT source_kind = 'pair' AND estimated_candidates = 1
       FROM otlet.workload_enablement_preflight(
         'workload_preflight_pair_task',
         (
           SELECT active_workload_revision_hash
           FROM otlet.workload_revision_heads
           WHERE task_name = 'workload_preflight_pair_task'
         ),
         'watch'
       )
     )
     OR NOT (
       SELECT source_kind = 'pair' AND estimated_candidates = 2
       FROM otlet.workload_enablement_preflight(
         'workload_preflight_pair_empty_task',
         (
           SELECT active_workload_revision_hash
           FROM otlet.workload_revision_heads
           WHERE task_name = 'workload_preflight_pair_empty_task'
         ),
         'watch'
       )
     ) THEN
    RAISE EXCEPTION 'workload preflight semantic branches are not read-only';
  END IF;
END
$proof$;
ROLLBACK TO SAVEPOINT before_semantic_read_only;
RELEASE SAVEPOINT before_semantic_read_only;

CREATE TEMP TABLE row_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  'workload_preflight_row_task',
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_preflight_row_task'
  ),
  'watch'
);
CREATE TEMP TABLE row_backfill_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  'workload_preflight_row_task',
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_preflight_row_task'
  ),
  'backfill',
  2,
  2,
  1,
  1
);
CREATE TEMP TABLE pair_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  'workload_preflight_pair_task',
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_preflight_pair_task'
  ),
  'watch'
);
CREATE TEMP TABLE pair_empty_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  'workload_preflight_pair_empty_task',
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_preflight_pair_empty_task'
  ),
  'watch'
);
CREATE TEMP TABLE route_backlog_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  :'task_name', :'revision', 'backfill', 3, 3, 64, 3
);

UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 2,
    max_input_bytes_per_job = 64,
    max_queued_input_bytes_per_task = 80,
    max_queued_input_bytes_per_model = 80,
    max_queued_input_bytes_total = 80
WHERE name = 'default';
CREATE TEMP TABLE bounded_backfill_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  :'task_name', :'revision', 'backfill', 3, 1, 1, 1
);
SELECT otlet.create_task_backfill(
  :'task_name', :'revision', 3, 1, 1, 1
) \g /dev/null
CREATE TEMP TABLE unfinished_backfill_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  :'task_name', :'revision', 'backfill', 3, 1, 1, 1
);
INSERT INTO otlet.jobs (
  task_name,
  workload_revision_hash,
  subject_id,
  input,
  job_origin
) VALUES (
  :'task_name', :'revision', 'capacity-probe', '{"value":99}'::jsonb, 'task_run'
);
CREATE TEMP TABLE reserved_backfill_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  :'task_name', :'revision', 'backfill', 3, 1, 1, 1
);

UPDATE otlet.production_policy
SET max_admission_rows = 1,
    max_input_bytes_per_job = 1,
    max_candidate_query_cost = 1
WHERE name = 'default';
CREATE TEMP TABLE blocked_report AS
SELECT *
FROM otlet.workload_enablement_preflight(
  'workload_preflight_row_task',
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_preflight_row_task'
  ),
  'watch'
);

SELECT (
  (SELECT source_kind = 'row'
          AND enablement_kind = 'watch'
          AND candidate_plan_status = 'ready'
          AND candidate_plan_rows = 2
          AND estimated_candidates = 2
          AND estimated_jobs = 2
   FROM row_report)
  AND
  (SELECT source_kind = 'row'
          AND enablement_kind = 'backfill'
          AND estimated_peak_queue_input_bytes =
            LEAST(estimated_jobs, 1) * estimated_input_bytes_per_job
          AND estimated_catch_up_ms_p50 >=
            60000 + service_ms_p50
   FROM row_backfill_report)
  AND
  (SELECT source_kind = 'pair'
          AND enablement_kind = 'watch'
          AND candidate_plan_rows =
            jsonb_extract_path_text(
              candidate_plan, '0', 'Plan', 'Plan Rows'
            )::bigint
          AND estimated_candidates = 1
          AND estimated_jobs = 1
          AND policy_blockers @> ARRAY[
            'estimated_candidates_exceed_watch_max_candidate_rows'
          ]
          AND uncertainty_reasons @> ARRAY[
            'pair_candidate_membership_not_executed'
          ]
   FROM pair_report)
  AND
  (SELECT source_kind = 'pair'
          AND candidate_plan_rows = 2
          AND estimated_candidates = 2
          AND estimated_jobs = 2
   FROM pair_empty_report)
  AND
  (SELECT capacity ->> 'model_backlog_jobs' = '0'
   FROM route_backlog_report)
  AND
  (SELECT within_current_policy
          AND estimated_jobs = 3
          AND capacity ->> 'estimated_peak_queue_jobs' = '1'
          AND capacity ->> 'effective_available_model_queue_slots' = '1'
   FROM bounded_backfill_report)
  AND
  (SELECT NOT within_current_policy
          AND policy_blockers @> ARRAY['unfinished_backfill_exists']
   FROM unfinished_backfill_report)
  AND
  (SELECT NOT within_current_policy
          AND policy_blockers @> ARRAY[
            'unfinished_backfill_exists',
            'estimated_jobs_exceed_model_queue_slots',
            'estimated_queue_bytes_exceed_task_headroom',
            'estimated_queue_bytes_exceed_model_headroom',
            'estimated_queue_bytes_exceed_total_headroom'
          ]
   FROM reserved_backfill_report)
  AND
  (SELECT NOT within_current_policy
          AND candidate_plan_status = 'rejected'
          AND candidate_plan_error LIKE '%exceeds limit%'
          AND policy_blockers @> ARRAY[
            'candidate_plan_not_ready',
            'estimated_candidates_exceed_admission_rows',
            'estimated_input_exceeds_per_job_bytes'
          ]
   FROM blocked_report)
  AND pg_temp.expect_error(
    format(
      'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L)',
      :'task_name', :'revision', 'bulk'
    ),
    'kind must be'
  )
  AND pg_temp.expect_error(
    format(
      'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L, NULL)',
      :'task_name', :'revision', 'backfill'
    ),
    'max subjects'
  )
  AND pg_temp.expect_error(
    format(
      'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L)',
      :'task_name', :'revision', 'watch'
    ),
    'requires a watch task'
  )
  AND pg_temp.expect_error(
    format(
      'SELECT * FROM otlet.workload_enablement_preflight(%L, %L, %L)',
      :'task_name', repeat('0', 64), 'watch'
    ),
    'is not active'
  )
  AND (
    SELECT NOT function.prosecdef
      AND function.provolatile = 'v'
      AND function.proconfig @> ARRAY[
        'search_path=pg_catalog, otlet, pg_temp'
      ]
      AND NOT has_function_privilege('public', function.oid, 'EXECUTE')
    FROM pg_proc function
    WHERE function.oid =
      'otlet.workload_enablement_preflight(text,text,text,integer,integer,integer,integer)'::regprocedure
  )
)::text;

ROLLBACK;
SQL
)"
[ "$preflight_surface_contract" = "true" ] || {
  echo "Workload preflight surface mismatch: $preflight_surface_contract" >&2
  exit 1
}

echo "workload_enablement_preflight_contract=true|3|active_revision|3|medium"
