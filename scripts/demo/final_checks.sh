runtime_contract="$(psql_exec -qAt <<'SQL'
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       (COALESCE(inference_cache_max_entries, 0) > 0)::text || '|' ||
       (COALESCE(inference_cache_max_bytes, 0) > 0)::text || '|' ||
       COALESCE(inference_cache_last_eviction_reason, '') || '|' ||
       COALESCE(worker_memory_sample_policy, '')
FROM otlet.runtime_status
WHERE runtime_status = 'ready'
  AND slot_state = 'ready'
ORDER BY last_used_at DESC NULLS LAST, model_name
LIMIT 1;
SQL
)"
echo "runtime_status_contract=$runtime_contract"
for term in \
  "ready|ready" \
  "|true|" \
  "|true|true|" \
  "|none|" \
  "linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1"; do
  require_contains "$runtime_contract" "$term" "Expected runtime status to contain $term"
done

task_cache_view_contract="$(psql_exec -qAt <<'SQL'
SELECT (to_regclass('otlet.task_inference_cache_status') IS NOT NULL)::text;
SQL
)"
echo "task_cache_view_contract=$task_cache_view_contract"
[ "$task_cache_view_contract" = "true" ] || {
  echo "Expected otlet.task_inference_cache_status to exist" >&2
  exit 1
}

log "Checking estimated planner on 1M-row source"
planner_1m_output="$(
  psql_exec -qAt -v model_name="$strong_model_name" <<'SQL'
DROP TABLE IF EXISTS public.otlet_plan_1m;
CREATE TABLE public.otlet_plan_1m AS
SELECT gs::text AS id, (gs % 10)::int AS bucket, 'plan row ' || gs::text AS note
FROM generate_series(1, 1000000) AS gs;
ALTER TABLE public.otlet_plan_1m ADD PRIMARY KEY (id);
ANALYZE public.otlet_plan_1m;
SELECT (otlet.create_watch(
  'plan_1m_demo',
  'row',
  'Classify one synthetic row. Return JSON only.',
  '{"type":"object","required":["decision"],"additionalProperties":false,"properties":{"decision":{"enum":["keep","drop"]}}}'::jsonb,
  :'model_name',
  'public.otlet_plan_1m'::regclass,
  'id',
  NULL,
  'plan_fact',
  '{"max_tokens":16,"reasoning":"off","inference_cache":true}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale"}'::jsonb,
  ARRAY[]::text[],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{}'::jsonb
)).name;
DROP TABLE IF EXISTS pg_temp.otlet_plan_1m_timing;
CREATE TEMP TABLE otlet_plan_1m_timing (
  count_basis text,
  total_subjects bigint,
  elapsed_ms numeric
);
DO $$
DECLARE
  started_at timestamptz;
  planned_row record;
  elapsed numeric;
BEGIN
  started_at := clock_timestamp();
  SELECT count_basis, total_subjects
  INTO planned_row
  FROM otlet.semantic_index_plan('plan_1m_demo');
  elapsed := EXTRACT(epoch FROM clock_timestamp() - started_at) * 1000;
  INSERT INTO pg_temp.otlet_plan_1m_timing
  VALUES (planned_row.count_basis, planned_row.total_subjects, elapsed);
END $$;
SELECT count_basis || '|' ||
       total_subjects::text || '|' ||
       round(elapsed_ms, 3)::text || '|' ||
       (elapsed_ms < 100)::text
FROM pg_temp.otlet_plan_1m_timing;
SQL
)"
planner_1m_contract="$(tail -n 1 <<<"$planner_1m_output")"
planner_1m_basis="$(cut -d'|' -f1 <<<"$planner_1m_contract")"
planner_1m_total="$(cut -d'|' -f2 <<<"$planner_1m_contract")"
planner_1m_fast="$(cut -d'|' -f4 <<<"$planner_1m_contract")"
echo "planner_1m_contract=$planner_1m_contract"
[ "$planner_1m_basis" = "estimated" ] && [ "$planner_1m_total" -ge 1000000 ] && [ "$planner_1m_fast" = "true" ] || {
  echo "Expected estimated 1M-row plan under 100ms, got $planner_1m_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
SELECT otlet.drop_watch_registry('plan_1m_demo');
DROP TABLE IF EXISTS public.otlet_plan_1m;
SQL

colon_subject_watch="colon_subject_demo"
colon_subject_task="${colon_subject_watch}_task"
psql_exec -v watch_name="$colon_subject_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch_registry(:'watch_name');
DROP TABLE IF EXISTS public.otlet_demo_colon_subject;
SQL
psql_exec \
  -v watch_name="$colon_subject_watch" \
  -v task_name="$colon_subject_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
CREATE TABLE public.otlet_demo_colon_subject (
  id text PRIMARY KEY,
  signal text NOT NULL
);
INSERT INTO public.otlet_demo_colon_subject VALUES ('tenant:colon-fragment-only:1', 'pass');

SELECT otlet.create_watch(
  watch_name => :'watch_name',
  kind => 'row',
  table_name => 'public.otlet_demo_colon_subject'::regclass,
  subject_column => 'id',
  instruction => 'Classify the row as pass. Return JSON only.',
  output_schema => '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["pass"]},
      "confidence": {"enum": ["high"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  model_name => :'model_name',
  record_type => 'colon_subject_record',
  runtime_options => '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb
);

CREATE TEMP TABLE colon_subject_claim AS
WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
  SELECT
    :'task_name',
    src.id,
    jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_colon_subject',
        'subject_id', src.id::text,
        'ctid', src.ctid::text,
        'xmin', src.xmin::text
      ),
      'table', 'public.otlet_demo_colon_subject',
      'row', otlet.semantic_project_row(to_jsonb(src), NULL::text[])
    ),
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  FROM public.otlet_demo_colon_subject src
  WHERE src.id = 'tenant:colon-fragment-only:1'
  RETURNING id, claim_token
)
SELECT id, claim_token FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"decision":"pass","confidence":"high","reason":"colon subject"}'::jsonb,
  '{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}',
  '[]'::jsonb,
  NULL,
  NULL,
  NULL,
  otlet.portable_text_hash('{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name',
  expected_claim_token => claim_token
)
FROM colon_subject_claim;
WITH output_row AS (
  SELECT
    j.id AS job_id,
    j.subject_id,
    j.input,
    o.id AS output_id,
    o.receipt_id,
    o.output
  FROM colon_subject_claim c
  JOIN otlet.jobs j ON j.id = c.id
  JOIN otlet.outputs o ON o.job_id = j.id
),
action_row AS (
  INSERT INTO otlet.actions (
    job_id,
    output_id,
    receipt_id,
    action_type,
    payload,
    authority_origin,
    authority_mode,
    evaluation_status,
    authority_policy_hash,
    subject_namespace,
    status,
    subject_id,
    source_table,
    source_hash
  )
  SELECT
    job_id,
    output_id,
    receipt_id,
    'create_record',
    jsonb_build_object(
      'type', 'create_record',
      'record_type', 'colon_subject_record',
      'subject_id', subject_id,
      'body', output
    ),
    'system',
    'recommendation_only',
    'unevaluated',
    otlet.default_action_authority_hash('colon_subject_demo_task', 'create_record'),
    'public.otlet_demo_colon_subject',
    'complete',
    subject_id,
    'public.otlet_demo_colon_subject',
    otlet.semantic_source_hash(input)
  FROM output_row
  RETURNING id, subject_id
)
INSERT INTO otlet.records (action_id, record_type, subject_id, body)
SELECT
  a.id,
  'colon_subject_record',
  o.subject_id,
  o.output
FROM action_row a
JOIN output_row o ON o.subject_id = a.subject_id;
SELECT otlet.materialize_semantic_index_subject(:'watch_name', 'tenant:colon-fragment-only:1');
SQL
colon_subject_contract="$(psql_exec -qAt \
  -v watch_name="$colon_subject_watch" \
  -v task_name="$colon_subject_task" <<'SQL'
CREATE TEMP TABLE colon_subject_contract_parts (
  key text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO colon_subject_contract_parts
SELECT 'before_mark',
       count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true)
WHERE subject_id = 'tenant:colon-fragment-only:1';
INSERT INTO colon_subject_contract_parts
SELECT 'fragment_mark',
       otlet.mark_semantic_stale(NULL, 'colon-fragment-only', 'manual')::text;
INSERT INTO colon_subject_contract_parts
SELECT 'after_fragment',
       count(*)::text
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND subject_id = 'tenant:colon-fragment-only:1'
  AND stale;
INSERT INTO colon_subject_contract_parts
SELECT 'exact_mark',
       otlet.mark_semantic_stale(NULL, 'tenant:colon-fragment-only:1', 'manual')::text;
INSERT INTO colon_subject_contract_parts
SELECT 'after_exact',
       count(*)::text
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND subject_id = 'tenant:colon-fragment-only:1'
  AND stale;
INSERT INTO colon_subject_contract_parts
SELECT 'lookup_after_exact',
       count(*)::text
FROM otlet.semantic_index_current_rows(:'watch_name', true)
WHERE subject_id = 'tenant:colon-fragment-only:1';
WITH validation AS (
  SELECT
    COALESCE(otlet.action_validation_error(
      '{"type":"merge_candidate","body":{"left_id":"tenant:left:1","right_id":"tenant:right:2","confidence":"high","reason":"same"}}'::jsonb,
      '{"match":"same_entity","confidence":"high","reason":"same"}'::jsonb,
      'tenant:left:1:tenant:right:2',
      '{"action_ids":{"left_id":"tenant:left:1","right_id":"tenant:right:2"}}'::jsonb
    ), 'ok') AS valid_pair,
    COALESCE(otlet.action_validation_error(
      '{"type":"merge_candidate","body":{"left_id":"tenant:left:1","right_id":"tenant:right:wrong","confidence":"high","reason":"same"}}'::jsonb,
      '{"match":"same_entity","confidence":"high","reason":"same"}'::jsonb,
      'tenant:left:1:tenant:right:2',
      '{"action_ids":{"left_id":"tenant:left:1","right_id":"tenant:right:2"}}'::jsonb
    ), 'ok') AS invalid_pair,
    COALESCE(otlet.action_validation_error(
      '{"type":"merge_candidate","body":{"left_id":"tenant:left:1","right_id":"tenant:right:2","confidence":"high","reason":"same"}}'::jsonb,
      '{"match":"same_entity","confidence":"high","reason":"same"}'::jsonb,
      'tenant:left:1:tenant:right:2',
      '{}'::jsonb
    ), 'ok') AS missing_action_ids
)
SELECT (SELECT value FROM colon_subject_contract_parts WHERE key = 'before_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'fragment_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'after_fragment') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'exact_mark') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'after_exact') || '|' ||
       (SELECT value FROM colon_subject_contract_parts WHERE key = 'lookup_after_exact') || '|' ||
       (SELECT valid_pair FROM validation) || '|' ||
       (SELECT invalid_pair FROM validation) || '|' ||
       (SELECT missing_action_ids FROM validation);
SQL
)"
echo "colon_subject_safety_contract=$colon_subject_contract"
[ "$colon_subject_contract" = "1|0|0|1|1|0|ok|merge_candidate subject ids must match job subject_id|merge_candidate requires input.action_ids left_id and right_id" ] || {
  echo "Expected colon subject IDs to validate and stale-mark only by exact subject, got $colon_subject_contract" >&2
  exit 1
}
psql_exec -v watch_name="$colon_subject_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch_registry(:'watch_name');
DROP TABLE IF EXISTS public.otlet_demo_colon_subject;
SQL

log "Checking authoritative semantic correction"
psql_exec -v watch_name="$row_triage_watch" >/dev/null <<'SQL'
INSERT INTO public.otlet_demo_triage_signal (
  id,
  blockers,
  approvals,
  evidence
) VALUES (
  'triage-correction-1',
  2,
  0,
  'A reviewer must replace this model decision without changing its receipt'
);
SELECT otlet.refresh_semantic_index(:'watch_name');
SELECT otlet.wake_worker();
SQL
row_correction_job_id="$(psql_value -v task_name="$row_triage_task" <<'SQL'
SELECT id
FROM otlet.jobs
WHERE task_name = :'task_name'
  AND subject_id = 'triage-correction-1'
ORDER BY id DESC
LIMIT 1;
SQL
)"
[ -n "$row_correction_job_id" ] || {
  echo "Expected an authoritative-correction proof job" >&2
  exit 1
}
row_correction_job_status=""
for _ in $(seq 1 900); do
  row_correction_job_status="$(psql_value -v job_id="$row_correction_job_id" <<'SQL'
SELECT status
FROM otlet.jobs
WHERE id = :'job_id'::bigint;
SQL
)"
  case "$row_correction_job_status" in
    complete) break ;;
    failed|canceled)
      echo "Authoritative-correction proof job ended $row_correction_job_status" >&2
      exit 1
      ;;
  esac
  sleep 1
done
[ "$row_correction_job_status" = "complete" ] || {
  echo "Timed out waiting for authoritative-correction proof job" >&2
  exit 1
}

row_authoritative_action_id="$(psql_value -v job_id="$row_correction_job_id" <<'SQL'
SELECT id
FROM otlet.actions
WHERE job_id = :'job_id'::bigint
  AND action_type = 'review_flag'
  AND error IS NULL
ORDER BY id
LIMIT 1;
SQL
)"
[ -n "$row_authoritative_action_id" ] || {
  echo "Expected an authoritative-correction review action" >&2
  exit 1
}
row_authoritative_label_id="$(psql_value \
  -v action_id="$row_authoritative_action_id" <<'SQL'
SELECT id
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"decision":"pass","confidence":"high","action_type":"review_flag"}'::jsonb,
  'reviewer cleared the signal'
);
SQL
)"
row_authoritative_review_event_id="$(psql_value \
  -v action_id="$row_authoritative_action_id" <<'SQL'
SELECT id
FROM otlet.review_events
WHERE action_id = :'action_id'::bigint
  AND outcome = 'correct'
ORDER BY id DESC
LIMIT 1;
SQL
)"
[ -n "$row_authoritative_label_id" ] \
  && [ -n "$row_authoritative_review_event_id" ] || {
  echo "Expected correction label and review evidence" >&2
  exit 1
}

row_correction_invalid_contract="$(psql_value \
  -v label_id="$row_authoritative_label_id" \
  -v event_id="$row_authoritative_review_event_id" <<'SQL'
CREATE TEMP TABLE correction_invalid_params (
  label_id bigint,
  event_id bigint
);
CREATE TEMP TABLE correction_invalid_result (message text);
INSERT INTO correction_invalid_params
VALUES (:'label_id'::bigint, :'event_id'::bigint);
DO $$
DECLARE
  params record;
BEGIN
  SELECT * INTO params FROM correction_invalid_params;
  BEGIN
    PERFORM otlet.approve_semantic_correction(
      params.label_id,
      params.event_id,
      '{"decision":"pass","confidence":"high"}'::jsonb,
      clock_timestamp() + interval '5 minutes',
      0.99,
      'invalid schema proof'
    );
    INSERT INTO correction_invalid_result VALUES ('no error');
  EXCEPTION WHEN others THEN
    INSERT INTO correction_invalid_result VALUES (SQLERRM);
  END;
END;
$$;
SELECT message || '|' || (
  SELECT adjudication_state
  FROM otlet.eval_labels
  WHERE id = :'label_id'::bigint
)
FROM correction_invalid_result;
SQL
)"
echo "row_correction_invalid_contract=$row_correction_invalid_contract"
require_contains "$row_correction_invalid_contract" \
  "otlet semantic correction output is invalid" \
  "Expected an invalid correction body to fail before approval"
require_contains "$row_correction_invalid_contract" \
  "|pending" \
  "Expected failed correction validation to leave the label pending"

row_correction_expires_at="$(psql_value <<'SQL'
SELECT clock_timestamp() + interval '30 seconds';
SQL
)"
row_correction_hash="$(psql_value \
  -v label_id="$row_authoritative_label_id" \
  -v event_id="$row_authoritative_review_event_id" \
  -v expires_at="$row_correction_expires_at" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT otlet.approve_semantic_correction(
  :'label_id'::bigint,
  :'event_id'::bigint,
  '{"decision":"pass","confidence":"high","reason":"Reviewer cleared the signal"}'::jsonb,
  :'expires_at'::timestamptz,
  0.99,
  'approved typed correction'
);
COMMIT;
SQL
)"
row_correction_active_contract="$(psql_value \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" \
  -v operator_role="$permission_operator_role" \
  -v correction_hash="$row_correction_hash" <<'SQL'
WITH current_row AS (
  SELECT *
  FROM otlet.semantic_index_current_rows(:'watch_name', true)
  WHERE subject_id = 'triage-correction-1'
), audit AS (
  SELECT *
  FROM otlet.audit_semantic_correction_export
  WHERE correction_hash = :'correction_hash'
), original AS (
  SELECT
    materialization.body,
    output.output,
    receipt.output_hash,
    receipt.raw_output_hash
  FROM audit
  JOIN otlet.semantic_materializations materialization
    ON materialization.id = audit.materialization_id
  JOIN otlet.outputs output
    ON output.id = audit.original_output_id
  JOIN otlet.inference_receipts receipt
    ON receipt.id = audit.original_receipt_id
)
SELECT concat_ws('|',
  (SELECT correction_status FROM audit),
  (SELECT body ->> 'decision' FROM current_row),
  (SELECT freshness_basis FROM current_row),
  otlet.semantic_matches(
    :'watch_name',
    'triage-correction-1',
    '{"decision":"pass"}'::jsonb
  ),
  NOT otlet.semantic_matches(
    :'watch_name',
    'triage-correction-1',
    '{"decision":"flag"}'::jsonb
  ),
  (SELECT body ->> 'decision' = 'flag' FROM original),
  (SELECT output ->> 'decision' = 'flag' FROM original),
  (SELECT otlet.portable_json_hash(body) = original_body_hash FROM original, audit),
  (SELECT output_hash = original_output_hash FROM original, audit),
  (SELECT raw_output_hash IS NOT DISTINCT FROM original_raw_output_hash FROM original, audit),
  (SELECT correction_author_identity = session_user FROM audit),
  (SELECT approver_identity = session_user FROM audit),
  (SELECT approver_role = :'operator_role' FROM audit),
  (SELECT count(*) = 0 FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'triage-correction-1')
);
SQL
)"
echo "row_correction_active_contract=$row_correction_active_contract"
[ "$row_correction_active_contract" = \
  "active|pass|manual_correction|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Expected active corrected state with unchanged model evidence, got $row_correction_active_contract" >&2
  exit 1
}

row_correction_customscan_plan="$(psql_exec \
  -P border=2 -P null='' -v watch_name="$row_triage_watch" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_triage_signal
WHERE otlet.semantic_matches_auto(
    :'watch_name',
    id,
    '{"decision":"pass"}'::jsonb
  );
SQL
)"
printf '%s\n' "$row_correction_customscan_plan"
require_contains "$row_correction_customscan_plan" \
  "Otlet Node: Semantic Source CustomScan" \
  "Expected corrected state in the native CustomScan path"
require_contains "$row_correction_customscan_plan" \
  "Rows Returned: 1" \
  "Expected CustomScan to return the corrected row"

row_correction_source_update_contract="$(psql_value \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" \
  -v correction_hash="$row_correction_hash" <<'SQL'
BEGIN;
UPDATE otlet.semantic_materializations
SET stale = true,
    stale_reason = 'source_update'
WHERE id = (
  SELECT materialization_id
  FROM otlet.semantic_correction_overrides
  WHERE correction_hash = :'correction_hash'
);
SELECT concat_ws('|',
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'watch_name', true)
   WHERE subject_id = 'triage-correction-1'),
  NOT otlet.semantic_matches(
    :'watch_name',
    'triage-correction-1',
    '{"decision":"pass"}'::jsonb
  ),
  (SELECT stale
      AND stale_reason = 'semantic_correction_re_review'
      AND body ->> 'decision' = 'pass'
   FROM otlet.semantic_materializations_effective
   WHERE correction_hash = :'correction_hash'
     AND id = (
       SELECT materialization_id
       FROM otlet.semantic_correction_overrides
       WHERE correction_hash = :'correction_hash'
     )),
  (SELECT correction_status
   FROM otlet.semantic_correction_status
   WHERE correction_hash = :'correction_hash'),
  (SELECT count(*)
   FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'triage-correction-1')
);
ROLLBACK;
SQL
)"
echo "row_correction_source_update_contract=$row_correction_source_update_contract"
[ "$row_correction_source_update_contract" = \
  "0|t|t|reopened_source|1" ] || {
  echo "Expected a source-update fence to reopen the correction, got $row_correction_source_update_contract" >&2
  exit 1
}

psql_exec -qAt -c "SELECT pg_sleep(30.1)" >/dev/null
row_correction_expired_contract="$(psql_value \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" \
  -v correction_hash="$row_correction_hash" <<'SQL'
SELECT concat_ws('|',
  (SELECT correction_status
   FROM otlet.semantic_correction_status
   WHERE correction_hash = :'correction_hash'),
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'watch_name', true)
   WHERE subject_id = 'triage-correction-1'),
  NOT otlet.semantic_matches(
    :'watch_name',
    'triage-correction-1',
    '{"decision":"pass"}'::jsonb
  ),
  (SELECT count(*) FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'triage-correction-1'),
  (SELECT semantic_correction_status = 'expired'
   FROM otlet.audit_review_export
   WHERE semantic_correction_hash = :'correction_hash')
);
SQL
)"
echo "row_correction_expired_contract=$row_correction_expired_contract"
[ "$row_correction_expired_contract" = "expired|0|t|1|t" ] || {
  echo "Expected an expired correction to fail closed into re-review, got $row_correction_expired_contract" >&2
  exit 1
}
row_correction_retry_hash="$(psql_value \
  -v label_id="$row_authoritative_label_id" \
  -v event_id="$row_authoritative_review_event_id" \
  -v expires_at="$row_correction_expires_at" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT otlet.approve_semantic_correction(
  :'label_id'::bigint,
  :'event_id'::bigint,
  '{"decision":"pass","confidence":"high","reason":"Reviewer cleared the signal"}'::jsonb,
  :'expires_at'::timestamptz,
  0.99,
  'approved typed correction'
);
COMMIT;
SQL
)"
[ "$row_correction_retry_hash" = "$row_correction_hash" ] || {
  echo "Expected an exact retry after expiry to return $row_correction_hash, got $row_correction_retry_hash" >&2
  exit 1
}

row_successor_label_id="$(psql_value \
  -v action_id="$row_authoritative_action_id" <<'SQL'
SELECT id
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"decision":"pass","confidence":"high","action_type":"review_flag"}'::jsonb,
  'reviewer renewed the correction'
);
SQL
)"
row_successor_review_event_id="$(psql_value \
  -v action_id="$row_authoritative_action_id" <<'SQL'
SELECT id
FROM otlet.review_events
WHERE action_id = :'action_id'::bigint
  AND outcome = 'correct'
ORDER BY id DESC
LIMIT 1;
SQL
)"
row_successor_correction_hash="$(psql_value \
  -v label_id="$row_successor_label_id" \
  -v event_id="$row_successor_review_event_id" \
  -v predecessor_hash="$row_correction_hash" <<'SQL'
SELECT otlet.approve_semantic_correction(
  :'label_id'::bigint,
  :'event_id'::bigint,
  '{"decision":"pass","confidence":"high","reason":"Reviewer renewed the correction"}'::jsonb,
  clock_timestamp() + interval '10 minutes',
  0.99,
  'approved correction re-review',
  :'predecessor_hash'
);
SQL
)"
row_correction_successor_contract="$(psql_value \
  -v watch_name="$row_triage_watch" \
  -v predecessor_hash="$row_correction_hash" \
  -v successor_hash="$row_successor_correction_hash" <<'SQL'
SELECT concat_ws('|',
  (SELECT correction_status FROM otlet.semantic_correction_status
   WHERE correction_hash = :'predecessor_hash'),
  (SELECT correction_status FROM otlet.semantic_correction_status
   WHERE correction_hash = :'successor_hash'),
  (SELECT supersedes_correction_hash = :'predecessor_hash'
   FROM otlet.semantic_correction_overrides
   WHERE correction_hash = :'successor_hash'),
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'watch_name', true)
   WHERE subject_id = 'triage-correction-1'
     AND body ->> 'decision' = 'pass')
);
SQL
)"
echo "row_correction_successor_contract=$row_correction_successor_contract"
[ "$row_correction_successor_contract" = "superseded|active|t|1" ] || {
  echo "Expected successor re-review to restore corrected state, got $row_correction_successor_contract" >&2
  exit 1
}

row_correction_contract_drift_contract="$(psql_value \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" \
  -v correction_hash="$row_successor_correction_hash" <<'SQL'
BEGIN;
WITH alternate AS (
  SELECT revision.workload_revision_hash
  FROM otlet.workload_revisions revision
  JOIN otlet.semantic_correction_overrides correction
    ON correction.correction_hash = :'correction_hash'
  WHERE revision.task_name = :'task_name'
    AND otlet.pair_constraint_contract_hash(revision.definition) <>
      correction.relevant_contract_hash
  ORDER BY revision.created_at DESC
  LIMIT 1
)
UPDATE otlet.workload_revision_heads head
SET previous_workload_revision_hash = head.active_workload_revision_hash,
    active_workload_revision_hash = alternate.workload_revision_hash,
    promoted_at = clock_timestamp()
FROM alternate
WHERE head.task_name = :'task_name';
SELECT concat_ws('|',
  (SELECT correction_status
   FROM otlet.semantic_correction_status
   WHERE correction_hash = :'correction_hash'),
  (SELECT count(*)
   FROM otlet.semantic_index_current_rows(:'watch_name', true)
   WHERE subject_id = 'triage-correction-1'),
  (SELECT count(*)
   FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'triage-correction-1')
);
ROLLBACK;
SQL
)"
echo "row_correction_contract_drift_contract=$row_correction_contract_drift_contract"
[ "$row_correction_contract_drift_contract" = "reopened_contract|0|1" ] || {
  echo "Expected relevant-contract drift to reopen the correction, got $row_correction_contract_drift_contract" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
UPDATE public.otlet_demo_triage_signal
SET evidence = 'The source changed after correction approval'
WHERE id = 'triage-correction-1';
SQL
row_correction_reopened_contract="$(psql_value \
  -v task_name="$row_triage_task" \
  -v watch_name="$row_triage_watch" \
  -v correction_hash="$row_successor_correction_hash" <<'SQL'
SELECT concat_ws('|',
  (SELECT correction_status FROM otlet.semantic_correction_status
   WHERE correction_hash = :'correction_hash'),
  (SELECT count(*) FROM otlet.semantic_index_current_rows(:'watch_name', true)
   WHERE subject_id = 'triage-correction-1'),
  NOT otlet.semantic_matches(
    :'watch_name',
    'triage-correction-1',
    '{"decision":"pass"}'::jsonb
  ),
  (SELECT count(*) FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'triage-correction-1'),
  (SELECT body ->> 'decision' = 'flag'
   FROM otlet.semantic_materializations
   WHERE task_name = :'task_name'
     AND subject_id = 'triage-correction-1'
   ORDER BY updated_at DESC, id DESC
   LIMIT 1),
  (SELECT output ->> 'decision' = 'flag'
   FROM otlet.outputs
   WHERE id = (
     SELECT original_output_id
     FROM otlet.semantic_correction_overrides
     WHERE correction_hash = :'correction_hash'
   ))
);
SQL
)"
echo "row_correction_reopened_contract=$row_correction_reopened_contract"
[ "$row_correction_reopened_contract" = "reopened_source|0|t|1|t|t" ] || {
  echo "Expected source change to reopen correction without altering model evidence, got $row_correction_reopened_contract" >&2
  exit 1
}

row_correction_immutable_contract="$(psql_value \
  -v correction_hash="$row_successor_correction_hash" <<'SQL'
CREATE TEMP TABLE correction_immutable_params (correction_hash text);
CREATE TEMP TABLE correction_immutable_result (operation text PRIMARY KEY);
INSERT INTO correction_immutable_params VALUES (:'correction_hash');
DO $$
DECLARE
  target_hash text;
BEGIN
  SELECT correction_hash INTO target_hash FROM correction_immutable_params;
  BEGIN
    UPDATE otlet.semantic_correction_overrides
    SET approval_reason = 'changed'
    WHERE correction_hash = target_hash;
  EXCEPTION WHEN others THEN
    INSERT INTO correction_immutable_result VALUES ('update');
  END;
  BEGIN
    DELETE FROM otlet.semantic_correction_overrides
    WHERE correction_hash = target_hash;
  EXCEPTION WHEN others THEN
    INSERT INTO correction_immutable_result VALUES ('delete');
  END;
  BEGIN
    TRUNCATE otlet.semantic_correction_overrides;
  EXCEPTION WHEN others THEN
    INSERT INTO correction_immutable_result VALUES ('truncate');
  END;
END;
$$;
SELECT count(*) FROM correction_immutable_result;
SQL
)"
echo "row_correction_immutable_contract=$row_correction_immutable_contract"
[ "$row_correction_immutable_contract" = "3" ] || {
  echo "Expected correction history to reject update, delete, and truncate" >&2
  exit 1
}

pair_correction_job_floor="$(psql_value -v task_name="$join_task" <<'SQL'
SELECT COALESCE(max(id), 0)
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"
psql_exec -v task_name="$join_task" >/dev/null <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '2000ms';
SELECT otlet.run_task_subject(
  :'task_name',
  'vendor-1001:vendor-313'
);
COMMIT;
SELECT otlet.wake_worker();
SQL
pair_correction_job_id="$(psql_value \
  -v task_name="$join_task" \
  -v job_floor="$pair_correction_job_floor" <<'SQL'
SELECT id
FROM otlet.jobs
WHERE task_name = :'task_name'
  AND subject_id = 'vendor-1001:vendor-313'
  AND id > :'job_floor'::bigint
ORDER BY id DESC
LIMIT 1;
SQL
)"
[ -n "$pair_correction_job_id" ] || {
  echo "Expected an authoritative pair-correction proof job" >&2
  exit 1
}
pair_correction_job_status=""
for _ in $(seq 1 900); do
  pair_correction_job_status="$(psql_value \
    -v job_id="$pair_correction_job_id" <<'SQL'
SELECT status
FROM otlet.jobs
WHERE id = :'job_id'::bigint;
SQL
)"
  case "$pair_correction_job_status" in
    complete) break ;;
    failed|canceled)
      echo "Authoritative pair-correction job ended $pair_correction_job_status" >&2
      exit 1
      ;;
  esac
  sleep 1
done
[ "$pair_correction_job_status" = "complete" ] || {
  echo "Timed out waiting for authoritative pair-correction job" >&2
  exit 1
}

pair_authoritative_action_id="$(psql_value \
  -v job_id="$pair_correction_job_id" <<'SQL'
SELECT action.id
FROM otlet.actions action
JOIN otlet.outputs output ON output.id = action.output_id
WHERE action.job_id = :'job_id'::bigint
  AND action.action_type = 'new_entity'
  AND output.output ->> 'match' = 'different_entity'
  AND action.error IS NULL
ORDER BY action.id
LIMIT 1;
SQL
)"
[ -n "$pair_authoritative_action_id" ] || {
  echo "Expected a different-entity action for pair-correction proof" >&2
  exit 1
}
pair_authoritative_label_id="$(psql_value \
  -v action_id="$pair_authoritative_action_id" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT id
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"match":"same_entity","confidence":"high","action_type":"merge_candidate"}'::jsonb,
  'reviewer linked the pair'
);
COMMIT;
SQL
)"
pair_authoritative_review_event_id="$(psql_value \
  -v action_id="$pair_authoritative_action_id" <<'SQL'
SELECT id
FROM otlet.review_events
WHERE action_id = :'action_id'::bigint
  AND outcome = 'correct'
ORDER BY id DESC
LIMIT 1;
SQL
)"
[ -n "$pair_authoritative_label_id" ] \
  && [ -n "$pair_authoritative_review_event_id" ] || {
  echo "Expected delegated pair correction evidence" >&2
  exit 1
}
pair_correction_hash="$(psql_value \
  -v label_id="$pair_authoritative_label_id" \
  -v event_id="$pair_authoritative_review_event_id" <<SQL
BEGIN;
SET LOCAL ROLE $permission_operator_role;
SELECT otlet.approve_semantic_correction(
  :'label_id'::bigint,
  :'event_id'::bigint,
  '{"match":"same_entity","confidence":"high","reason":"Reviewer linked the pair"}'::jsonb,
  clock_timestamp() + interval '1 hour',
  0.99,
  'approved pair correction'
);
COMMIT;
SQL
)"
pair_correction_active_contract="$(psql_value \
  -v task_name="$join_task" \
  -v index_name="$join_index_name" \
  -v operator_role="$permission_operator_role" \
  -v correction_hash="$pair_correction_hash" <<'SQL'
WITH current_pair AS (
  SELECT *
  FROM otlet.semantic_join_index_current_rows(:'index_name', true)
  WHERE subject_id = 'vendor-1001:vendor-313'
), audit AS (
  SELECT *
  FROM otlet.audit_semantic_correction_export
  WHERE correction_hash = :'correction_hash'
), original AS (
  SELECT materialization.body, output.output
  FROM audit
  JOIN otlet.semantic_materializations materialization
    ON materialization.id = audit.materialization_id
  JOIN otlet.outputs output ON output.id = audit.original_output_id
)
SELECT concat_ws('|',
  (SELECT correction_status FROM audit),
  (SELECT body ->> 'match' FROM current_pair),
  (SELECT freshness_basis FROM current_pair),
  otlet.semantic_join_matches(
    :'index_name',
    'vendor-1001:vendor-313',
    '{"match":"same_entity"}'::jsonb
  ),
  NOT otlet.semantic_join_matches(
    :'index_name',
    'vendor-1001:vendor-313',
    '{"match":"different_entity"}'::jsonb
  ),
  (SELECT body ->> 'match' = 'different_entity' FROM original),
  (SELECT output ->> 'match' = 'different_entity' FROM original),
  (SELECT correction_author_role = :'operator_role' FROM audit),
  (SELECT approver_role = :'operator_role' FROM audit),
  (SELECT count(*) = 1
   FROM otlet.pair_constraint_status fact
   WHERE fact.task_name = :'task_name'
     AND fact.subject_id = 'vendor-1001:vendor-313'
     AND fact.fact_state = 'active'
     AND fact.relation = 'must_link')
);
SQL
)"
echo "pair_correction_active_contract=$pair_correction_active_contract"
[ "$pair_correction_active_contract" = \
  "active|same_entity|manual_correction|t|t|t|t|t|t|t" ] || {
  echo "Expected active effective pair correction, got $pair_correction_active_contract" >&2
  exit 1
}

pair_correction_timezone_contract="$(psql_value \
  -v correction_hash="$pair_correction_hash" <<'SQL'
CREATE TEMP TABLE pair_correction_timezone_params (correction_hash text);
CREATE TEMP TABLE pair_correction_timezone_result (stable boolean);
INSERT INTO pair_correction_timezone_params VALUES (:'correction_hash');
DO $$
DECLARE
  correction otlet.semantic_correction_overrides%ROWTYPE;
  utc_hash text;
BEGIN
  SELECT stored.* INTO correction
  FROM otlet.semantic_correction_overrides stored
  JOIN pair_correction_timezone_params params USING (correction_hash);
  PERFORM set_config('TimeZone', 'UTC', true);
  utc_hash := otlet.semantic_correction_override_hash(correction);
  PERFORM set_config('TimeZone', 'America/New_York', true);
  INSERT INTO pair_correction_timezone_result
  VALUES (
    utc_hash = otlet.semantic_correction_override_hash(correction)
    AND utc_hash = correction.correction_hash
  );
END;
$$;
SELECT stable FROM pair_correction_timezone_result;
SQL
)"
echo "pair_correction_timezone_contract=$pair_correction_timezone_contract"
[ "$pair_correction_timezone_contract" = "t" ] || {
  echo "Expected timezone-independent correction identity, got $pair_correction_timezone_contract" >&2
  exit 1
}

pair_correction_conflict_contract="$(psql_value \
  -v action_id="$pair_authoritative_action_id" \
  -v task_name="$join_task" \
  -v predecessor_hash="$pair_correction_hash" <<SQL
BEGIN;
CREATE TEMP TABLE pair_correction_conflict_result (message text);
SET LOCAL ROLE $permission_operator_role;
SELECT id AS conflict_label_id
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"match":"different_entity","confidence":"high","action_type":"new_entity"}'::jsonb,
  'reviewer separated the pair'
) \gset
RESET ROLE;
SELECT id AS conflict_event_id
FROM otlet.review_events
WHERE action_id = :'action_id'::bigint
  AND outcome = 'correct'
ORDER BY id DESC
LIMIT 1
\gset
CREATE TEMP TABLE pair_correction_conflict_params AS
SELECT
  :conflict_label_id::bigint AS label_id,
  :conflict_event_id::bigint AS event_id,
  :'predecessor_hash'::text AS predecessor_hash;
DO \$\$
DECLARE
  params record;
BEGIN
  SELECT * INTO params FROM pair_correction_conflict_params;
  BEGIN
    PERFORM otlet.approve_semantic_correction(
      params.label_id,
      params.event_id,
      '{"match":"different_entity","confidence":"high","reason":"Reviewer separated the pair"}'::jsonb,
      clock_timestamp() + interval '1 hour',
      0.99,
      'contradictory pair correction',
      params.predecessor_hash
    );
    INSERT INTO pair_correction_conflict_result VALUES ('no error');
  EXCEPTION WHEN others THEN
    INSERT INTO pair_correction_conflict_result VALUES (SQLERRM);
  END;
END;
\$\$;
SELECT concat_ws('|',
  (SELECT correction_status
   FROM otlet.semantic_correction_status
   WHERE correction_hash = :'predecessor_hash'),
  (SELECT count(*)
   FROM otlet.review_queue
   WHERE queue_kind = 'semantic_correction_re_review'
     AND task_name = :'task_name'
     AND subject_id = 'vendor-1001:vendor-313'),
  (SELECT message LIKE 'otlet entity graph blocker prevents%'
   FROM pair_correction_conflict_result)
);
ROLLBACK;
SQL
)"
echo "pair_correction_conflict_contract=$pair_correction_conflict_contract"
[ "$pair_correction_conflict_contract" = "reopened_pair_constraint|1|t" ] || {
  echo "Expected pair conflict to reopen correction and block approval, got $pair_correction_conflict_contract" >&2
  exit 1
}

cleanup_permission_roles
trap - EXIT

performance_ratio_contract="$(psql_exec -qAt <<'SQL'
SELECT trusted_output_rows::text || '|' ||
       model_invocations::text || '|' ||
       round(model_invocations_per_trusted_row, 3)::text || '|' ||
       model_processed_tokens::text || '|' ||
       round(model_processed_tokens_per_trusted_row, 3)::text
FROM otlet.production_status;
SQL
)"
echo "performance_ratio_contract=$performance_ratio_contract"
require_regex "$performance_ratio_contract" '^[1-9][0-9]*\|[1-9][0-9]*\|[0-9]+(\.[0-9]+)?\|[1-9][0-9]*\|[0-9]+(\.[0-9]+)?$' "Expected production_status to expose positive model-work ratios"

audit_export_contract="$(psql_value <<'SQL'
SELECT (SELECT count(*) FROM otlet.redaction_policy_status)::text || '|' ||
       (SELECT sensitive_evidence_mode = 'redacted' AND storage_compliant FROM otlet.redaction_policy_status)::text || '|' ||
       (SELECT raw_output_rows = 0 AND token_text_values = 0 AND alternative_token_text_values = 0 FROM otlet.redaction_policy_status)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_receipt_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_review_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_review_event_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_eval_label_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_semantic_correction_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.semantic_dependency_audit)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.operational_event_log)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.worker_batch_timing_status)::text || '|' ||
       (SELECT NOT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = 'otlet'
            AND table_name = 'audit_receipt_export'
            AND column_name IN ('trace_summary', 'raw_output', 'prompt')
        ))::text;
SQL
)"
echo "audit_export_contract=$audit_export_contract"
[ "$audit_export_contract" = "1|true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected audit export surfaces and redaction withholdings, got $audit_export_contract" >&2
  exit 1
}

prepared_metadata_output="$(psql_value -v watch_name="$row_customscan_watch" <<'SQL'
BEGIN;
PREPARE otlet_prepared_metadata_probe AS
SELECT count(*)
FROM public.otlet_demo_customscan_signal
WHERE otlet.semantic_matches(:'watch_name', id, '{}'::jsonb);
EXECUTE otlet_prepared_metadata_probe;
UPDATE otlet.semantic_indexes
SET record_type = 'prepared_metadata_probe'
WHERE name = :'watch_name';
EXECUTE otlet_prepared_metadata_probe;
ROLLBACK;
SQL
)"
prepared_metadata_contract="$(head -n 1 <<<"$prepared_metadata_output")|$(tail -n 1 <<<"$prepared_metadata_output")"
echo "prepared_metadata_contract=$prepared_metadata_contract"
[ "$prepared_metadata_contract" = "1|1" ] || {
  echo "Expected prepared CustomScan to ignore unpromoted metadata, got $prepared_metadata_contract" >&2
  exit 1
}

materialization_failure_status_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
BEGIN;
INSERT INTO otlet.worker_events (event_type, message, detail)
VALUES (
  'semantic_materialization_failed',
  'demo rolled-back materialization failure visibility smoke',
  jsonb_build_object(
    'task_name', 'materialization_failure_status_demo',
    'model_name', :'model_name',
    'error', 'rolled back smoke'
  )
);
SELECT (semantic_materialization_failed_events >= 1)::text || '|' ||
       (semantic_materialization_last_failed_at IS NOT NULL)::text
FROM otlet.production_status;
ROLLBACK;
SQL
)"
echo "materialization_failure_status_contract=$materialization_failure_status_contract"
[ "$materialization_failure_status_contract" = "true|true" ] || {
  echo "Expected materialization failure status contract true|true, got $materialization_failure_status_contract" >&2
  exit 1
}

identity_vector_contract="$(psql_value <<'SQL'
SELECT concat_ws('|',
  otlet.identity_hash(
    'test_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'test_vector',
    '{"a":[1.00,"é"],"b":2}'::jsonb
  ) = 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_hash(
    'other_vector',
    '{"b":2.00,"a":[1.0,"é"]}'::jsonb
  ) <> 'otlet:v1:sha256:118dc186d3433180c95a2bd91652a2bf78953c0c6aa376ad8559a13cdb0dd109',
  otlet.identity_text_hash(
    'text_vector',
    E'Otlet\n🙂'
  ) = 'otlet:v1:sha256:96077dacfe042898c24b4f06ed6d91b8d21e13a52d36738fe1009032d0d13f72',
  otlet.task_contract_hash('vector', '{"type":"object"}'::jsonb, 'vector_model')
    ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
);
SQL
)"
echo "identity_vector_contract=$identity_vector_contract"
[ "$identity_vector_contract" = "t|t|t|t|t" ] || {
  echo "Expected versioned identity vectors t|t|t|t|t, got $identity_vector_contract" >&2
  exit 1
}

invariant_contract="$(psql_exec -qAt <<'SQL'
SELECT count(*) FROM otlet.verify_invariants();
SQL
)"
echo "invariant_contract=$invariant_contract"
if [ "$invariant_contract" != "0" ]; then
  psql_exec -P border=2 -P null='' <<'SQL'
SELECT invariant_name, object_type, object_id, detail
FROM otlet.verify_invariants()
ORDER BY invariant_name, object_type, object_id
LIMIT 20;
SQL
  echo "Expected zero Otlet invariant violations, got $invariant_contract" >&2
  exit 1
fi

crash_scan
log "Otlet demo passed"
