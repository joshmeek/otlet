log "Checking watch action allowlist"
psql_exec \
  -v watch_name="$action_allowlist_watch" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_action_allowlist;
CREATE TABLE public.otlet_demo_action_allowlist (
  id text PRIMARY KEY,
  note text NOT NULL
);
INSERT INTO public.otlet_demo_action_allowlist VALUES ('allow-1', 'allowlist smoke row');

SELECT otlet.create_watch(
  :'watch_name',
  'row',
  'Return a decision and actions.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  :'model_name',
  'public.otlet_demo_action_allowlist'::regclass,
  'id',
  NULL,
  'action_allowlist_fact',
  '{"max_tokens":80,"reasoning":"off"}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

WITH inserted AS (
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  SELECT
    :'watch_name' || '_task',
    src.id,
    jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_action_allowlist',
        'subject_id', src.id,
        'ctid', src.ctid::text,
        'xmin', src.xmin::text
      ),
      'table', 'public.otlet_demo_action_allowlist',
      'row', to_jsonb(src)
    ),
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  FROM public.otlet_demo_action_allowlist src
  RETURNING id
)
SELECT otlet.complete_job(
  job_id => id,
  output => '{"decision":"flag","confidence":"high","reason":"allowlist smoke"}'::jsonb,
  raw_output => '{"output":{"decision":"flag","confidence":"high","reason":"allowlist smoke"},"actions":[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]}',
  actions => '[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]'::jsonb,
  raw_output_hash => md5('{"output":{"decision":"flag","confidence":"high","reason":"allowlist smoke"},"actions":[{"type":"note","body":{"subject_id":"allow-1","text":"not allowed"}}]}'),
  started_at => now(),
  trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
  model_name => :'model_name'
)
FROM inserted;
SQL
action_allowlist_contract="$(psql_exec -qAt -v task_name="$action_allowlist_task" <<'SQL'
SELECT count(*) FILTER (
         WHERE action_type = 'note'
           AND status = 'rejected'
           AND error = 'action type note is not allowed by watch'
       )::text || '|' ||
       count(*) FILTER (WHERE action_type = 'note' AND output_id IS NOT NULL AND receipt_id IS NOT NULL)::text || '|' ||
       (
         SELECT count(*)::text
         FROM otlet.records r
         JOIN otlet.actions a ON a.id = r.action_id
         JOIN otlet.jobs j ON j.id = a.job_id
         WHERE j.task_name = :'task_name'
       )
FROM otlet.action_status
WHERE task_name = :'task_name';
SQL
)"
echo "action_allowlist_contract=$action_allowlist_contract"
[ "$action_allowlist_contract" = "1|1|0" ] || {
  echo "Expected watch action allowlist to reject note without creating a record, got $action_allowlist_contract" >&2
  exit 1
}
