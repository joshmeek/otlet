runtime_contract="$(psql_exec -qAt -v model_name="$cheap_model_name" <<'SQL'
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       (COALESCE(inference_cache_max_entries, 0) > 0)::text || '|' ||
       (COALESCE(inference_cache_max_bytes, 0) > 0)::text || '|' ||
       COALESCE(inference_cache_last_eviction_reason, '') || '|' ||
       COALESCE(worker_memory_sample_policy, '')
FROM otlet.runtime_status
WHERE model_name = :'model_name'
LIMIT 1;
SQL
)"
echo "runtime_status_contract=$runtime_contract"
for term in \
  "ready|ready" \
  "|true|" \
  "|true|true|" \
  "|none|" \
  "linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run"; do
  require_contains "$runtime_contract" "$term" "Expected runtime status to contain $term"
done

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
SELECT otlet.drop_watch('plan_1m_demo');
DROP TABLE IF EXISTS public.otlet_plan_1m;
SQL

colon_subject_watch="colon_subject_demo"
colon_subject_task="${colon_subject_watch}_task"
psql_exec -v watch_name="$colon_subject_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'watch_name');
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
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
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
    now() + interval '5 minutes'
  FROM public.otlet_demo_colon_subject src
  WHERE src.id = 'tenant:colon-fragment-only:1'
  RETURNING id
)
SELECT id FROM inserted;
SELECT otlet.complete_job(
  id,
  '{"decision":"pass","confidence":"high","reason":"colon subject"}'::jsonb,
  '{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}',
  '[]'::jsonb,
  NULL,
  NULL,
  NULL,
  md5('{"output":{"decision":"pass","confidence":"high","reason":"colon subject"},"actions":[]}'),
  now(),
  '{"schema_validation_status":"passed"}'::jsonb,
  :'model_name'
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
    'complete',
    subject_id,
    'public.otlet_demo_colon_subject',
    md5(input::text)
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
SELECT otlet.drop_watch(:'watch_name');
DROP TABLE IF EXISTS public.otlet_demo_colon_subject;
SQL

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
       (SELECT count(*) > 0 FROM otlet.audit_receipt_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_review_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.audit_eval_label_export)::text || '|' ||
       (SELECT count(*) > 0 FROM otlet.semantic_dependency_audit)::text || '|' ||
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
[ "$audit_export_contract" = "1|true|true|true|true|true|true" ] || {
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
[ "$prepared_metadata_contract" = "1|0" ] || {
  echo "Expected prepared CustomScan to reload current semantic metadata, got $prepared_metadata_contract" >&2
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
