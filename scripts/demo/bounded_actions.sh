log "Proving bounded row updates"

psql_exec \
  -v watch_name="$bounded_action_watch" \
  -v model_name="$strong_model_name" \
  -v target_name="$bounded_action_target" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_bounded_actions CASCADE;
CREATE TABLE public.otlet_demo_bounded_actions (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  review_reason text,
  priority integer NOT NULL,
  protected_note text NOT NULL
);
INSERT INTO public.otlet_demo_bounded_actions VALUES
  ('row-1', 'pending', NULL, 0, 'DO_NOT_TOUCH_SENTINEL'),
  ('row-2', 'pending', NULL, 0, 'DO_NOT_TOUCH_SENTINEL'),
  ('row-3', 'pending', NULL, 0, 'DO_NOT_TOUCH_SENTINEL'),
  ('row-4', 'pending', NULL, 0, 'DO_NOT_TOUCH_SENTINEL'),
  ('row-5', 'pending', NULL, 0, 'DO_NOT_TOUCH_SENTINEL');

SELECT otlet.register_action_target(
  :'target_name',
  'public.otlet_demo_bounded_actions'::regclass,
  'id',
  ARRAY['review_state', 'review_reason', 'priority']::name[]
);

SELECT otlet.create_watch(
  :'watch_name',
  'row',
  'Return a decision and, when useful, one update_row action.',
  '{"type":"object"}'::jsonb,
  :'model_name',
  'public.otlet_demo_bounded_actions'::regclass,
  'id',
  NULL,
  'bounded_action_fact',
  '{}',
  '{}',
  '{"on_change":"mark_stale"}',
  ARRAY['update_row'],
  'refresh_then_fail_closed',
  '{}',
  '{}'
);

DO $body$
DECLARE
  proposal record;
  job_id bigint;
  job_input jsonb;
BEGIN
  FOR proposal IN
    SELECT *
    FROM (VALUES
      (
        'row-1',
        jsonb_build_array(
          jsonb_build_object(
            'type', 'update_row',
            'body', jsonb_build_object(
              'target', 'bounded_action_demo',
              'identity', 'row-1',
              'changes', jsonb_build_object(
                'review_state', 'approved',
                'review_reason', 'bounded apply',
                'priority', 1
              )
            )
          ),
          jsonb_build_object(
            'type', 'update_row',
            'body', jsonb_build_object(
              'target', 'bounded_action_demo',
              'identity', 'row-1',
              'changes', jsonb_build_object(
                'review_state', 'approved',
                'review_reason', 'bounded apply',
                'priority', 1
              )
            )
          ),
          jsonb_build_object(
            'type', 'update_row',
            'body', jsonb_build_object(
              'target', 'bounded_action_demo',
              'identity', 'row-1',
              'changes', jsonb_build_object('protected_note', 'changed')
            )
          ),
          jsonb_build_object(
            'type', 'update_row',
            'body', jsonb_build_object(
              'target', 'unknown_target',
              'identity', 'row-1',
              'changes', jsonb_build_object('review_state', 'approved')
            )
          ),
          jsonb_build_object(
            'type', 'update_row',
            'body', jsonb_build_object(
              'target', 'bounded_action_demo',
              'identity', 'row-2',
              'changes', jsonb_build_object('review_state', 'approved')
            )
          )
        )
      ),
      (
        'row-2',
        jsonb_build_array(jsonb_build_object(
          'type', 'update_row',
          'body', jsonb_build_object(
            'target', 'bounded_action_demo',
            'identity', 'row-2',
            'changes', jsonb_build_object(
              'review_state', 'approved',
              'review_reason', 'stale apply'
            )
          )
        ))
      ),
      (
        'row-4',
        jsonb_build_array(jsonb_build_object(
          'type', 'update_row',
          'body', jsonb_build_object(
            'target', 'bounded_action_demo',
            'identity', 'row-4',
            'changes', jsonb_build_object(
              'review_state', 'approved',
              'review_reason', 'disabled apply'
            )
          )
        ))
      ),
      (
        'row-5',
        jsonb_build_array(jsonb_build_object(
          'type', 'update_row',
          'body', jsonb_build_object(
            'target', 'bounded_action_demo',
            'identity', 'row-5',
            'changes', jsonb_build_object('priority', 'not-an-integer')
          )
        ))
      )
    ) proposals(subject_id, actions)
  LOOP
    SELECT jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object(
        'table', 'public.otlet_demo_bounded_actions',
        'subject_id', source.id,
        'ctid', source.ctid::text,
        'xmin', source.xmin::text
      ),
      'table', 'public.otlet_demo_bounded_actions',
      'row', to_jsonb(source)
    )
    INTO job_input
    FROM public.otlet_demo_bounded_actions source
    WHERE source.id = proposal.subject_id;

    INSERT INTO otlet.jobs (
      task_name,
      subject_id,
      input,
      status,
      attempts,
      started_at,
      leased_until
    )
    VALUES (
      'bounded_action_demo_task',
      proposal.subject_id,
      job_input,
      'running',
      1,
      now(),
      now() + interval '5 minutes'
    )
    RETURNING id INTO job_id;

    PERFORM otlet.complete_job(
      job_id => job_id,
      output => '{"decision":"reviewed"}'::jsonb,
      raw_output => jsonb_build_object(
        'output', '{"decision":"reviewed"}'::jsonb,
        'actions', proposal.actions
      )::text,
      actions => proposal.actions,
      started_at => now(),
      trace_summary => '{
        "schema_validation_status":"passed",
        "mvcc":{"table":"public.otlet_demo_bounded_actions"}
      }'::jsonb,
      model_name => (
        SELECT model_name
        FROM otlet.tasks
        WHERE name = 'bounded_action_demo_task'
      )
    );
  END LOOP;
END
$body$;
SQL

bounded_proposal_contract="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT
  count(*) FILTER (WHERE a.status = 'proposed')::text || '|' ||
  count(*) FILTER (WHERE a.status = 'rejected')::text || '|' ||
  count(*) FILTER (WHERE a.error = 'update_row column is not allowed')::text || '|' ||
  count(*) FILTER (WHERE a.error = 'unknown action target')::text || '|' ||
  count(*) FILTER (WHERE a.error = 'update_row identity must match job subject_id')::text || '|' ||
  count(*) FILTER (
    WHERE payload #>> '{body,changes,review_reason}' = 'bounded apply'
  )::text || '|' ||
  count(DISTINCT idempotency_key) FILTER (
    WHERE payload #>> '{body,changes,review_reason}' = 'bounded apply'
  )::text
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.action_type = 'update_row';
SQL
)"
echo "bounded_proposal_contract=$bounded_proposal_contract"
[ "$bounded_proposal_contract" = "5|3|1|1|1|2|1" ] || {
  echo "Expected bounded proposals and rejections 5|3|1|1|1|2|1, got $bounded_proposal_contract" >&2
  exit 1
}

bounded_rows_before_dry_run="$(psql_value <<'SQL'
SELECT md5(string_agg(otlet.semantic_canonical_jsonb(to_jsonb(source))::text, '' ORDER BY id))
FROM public.otlet_demo_bounded_actions source;
SQL
)"

psql_exec -v task_name="$bounded_action_task" >/dev/null <<'SQL'
SELECT otlet.dry_run_action(a.id)
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.action_type = 'update_row'
  AND a.status = 'proposed';
SQL

bounded_rows_after_dry_run="$(psql_value <<'SQL'
SELECT md5(string_agg(otlet.semantic_canonical_jsonb(to_jsonb(source))::text, '' ORDER BY id))
FROM public.otlet_demo_bounded_actions source;
SQL
)"
[ "$bounded_rows_before_dry_run" = "$bounded_rows_after_dry_run" ] || {
  echo "Expected bounded dry run to leave source rows unchanged" >&2
  exit 1
}

bounded_dry_run_contract="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT
  count(*) FILTER (WHERE receipt.status = 'passed')::text || '|' ||
  count(*) FILTER (WHERE receipt.status = 'failed')::text || '|' ||
  count(*) FILTER (
    WHERE receipt.status = 'passed'
      AND receipt.affected_rows = 1
      AND receipt.before_hash IS DISTINCT FROM receipt.result_hash
  )::text || '|' ||
  count(*) FILTER (
    WHERE receipt.status = 'failed'
      AND receipt.error = 'target value failed type validation'
  )::text
FROM otlet.action_execution_receipts receipt
JOIN otlet.actions action ON action.id = receipt.action_id
JOIN otlet.jobs job ON job.id = action.job_id
WHERE job.task_name = :'task_name'
  AND receipt.mode = 'dry_run';
SQL
)"
echo "bounded_dry_run_contract=$bounded_dry_run_contract"
[ "$bounded_dry_run_contract" = "4|1|4|1" ] || {
  echo "Expected bounded dry-run contract 4|1|4|1, got $bounded_dry_run_contract" >&2
  exit 1
}

psql_exec -v task_name="$bounded_action_task" >/dev/null <<'SQL'
SELECT otlet.approve_action(a.id, 'bounded action demo')
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.action_type = 'update_row'
  AND a.status = 'proposed'
  AND a.dry_run_status = 'passed';
SQL

bounded_apply_action_ids="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT string_agg(a.id::text, ',' ORDER BY a.id)
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.payload #>> '{body,changes,review_reason}' = 'bounded apply';
SQL
)"
IFS=',' read -r bounded_apply_action_id bounded_replay_action_id <<<"$bounded_apply_action_ids"

bounded_stale_action_id="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT a.id
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.payload #>> '{body,changes,review_reason}' = 'stale apply';
SQL
)"

bounded_disabled_action_id="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT a.id
FROM otlet.actions a
JOIN otlet.jobs j ON j.id = a.job_id
WHERE j.task_name = :'task_name'
  AND a.payload #>> '{body,changes,review_reason}' = 'disabled apply';
SQL
)"

bounded_queue_contract="$(psql_value -v task_name="$bounded_action_task" <<'SQL'
SELECT count(*) FILTER (
         WHERE action_type = 'update_row'
           AND queue_kind = 'ready_to_apply'
           AND next_operator_step = 'apply'
       )::text || '|' ||
       count(*) FILTER (
         WHERE action_type = 'update_row'
           AND queue_kind = 'pending_approval'
           AND next_operator_step = 'review_failure'
       )::text
FROM otlet.review_queue
WHERE task_name = :'task_name';
SQL
)"
echo "bounded_queue_contract=$bounded_queue_contract"
[ "$bounded_queue_contract" = "4|1" ] || {
  echo "Expected bounded review queue contract 4|1, got $bounded_queue_contract" >&2
  exit 1
}
