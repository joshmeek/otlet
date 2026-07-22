production_policy_contract="$(psql_exec -qAt <<'SQL'
SELECT name || '|' || stale_policy || '|' || max_attempts::text || '|' ||
       max_attempt_ms::text || '|' || worker_claim_batch_size::text || '|' ||
       sensitive_evidence_mode || '|' || terminal_evidence_retention::text
FROM otlet.production_policy_status;
SQL
)"
echo "production_policy_contract=$production_policy_contract"

lease_interval_contract="$(psql_value <<'SQL'
SELECT EXTRACT(epoch FROM otlet.effective_job_lease_interval(
         '{}'::jsonb,
         300000,
         interval '5 minutes'
       ))::bigint::text || '|' ||
       EXTRACT(epoch FROM otlet.effective_job_lease_interval(
         '{"max_attempt_ms":1000}'::jsonb,
         300000,
         interval '1 second'
       ))::bigint::text;
SQL
)"
echo "lease_interval_contract=$lease_interval_contract"
[ "$lease_interval_contract" = "330|31" ] || {
  echo "Expected timeout-aware job leases with 30-second completion grace, got $lease_interval_contract" >&2
  exit 1
}

lease_fence_task="lease_fence_demo"
cleanup_task "$lease_fence_task"
lease_fence_contract="$(psql_value -v task_name="$lease_fence_task" -v model_name="$strong_model_name" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET job_lease_interval = interval '1 second',
    default_runtime_options = '{"max_attempt_ms":2000}'::jsonb,
    worker_claim_batch_size = 1,
    worker_claim_task_cursor = ''
WHERE name = 'default';
WITH created AS (
  SELECT otlet.create_task(
    :'task_name',
    'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
    'Lease fence smoke placeholder',
    '{"type":"object"}'::jsonb,
    :'model_name',
    '{"max_tokens":1,"reasoning":"off"}'::jsonb
  ) AS task
)
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT :'task_name', 'lease-fence-1', '{}'::jsonb
FROM created;
CREATE TEMP TABLE lease_claim AS
SELECT id, attempts, leased_until
FROM otlet.claim_jobs();
CREATE TEMP TABLE wrong_renew AS
SELECT renewed.*
FROM lease_claim claim
CROSS JOIN LATERAL otlet.renew_job_lease(claim.id, claim.attempts + 1) renewed;
CREATE TEMP TABLE current_renew AS
SELECT renewed.*
FROM lease_claim claim
CROSS JOIN LATERAL otlet.renew_job_lease(claim.id, claim.attempts) renewed;
SELECT (SELECT count(*) FROM lease_claim)::text || '|' ||
       (SELECT count(*) FROM wrong_renew)::text || '|' ||
       COALESCE((SELECT status FROM current_renew), '') || '|' ||
       COALESCE((SELECT (leased_until > now() + interval '30 seconds')::text FROM current_renew), 'false') || '|' ||
       COALESCE((SELECT (
         leased_until > now() + interval '31 seconds'
         AND leased_until < now() + interval '33 seconds'
       )::text FROM current_renew), 'false');
ROLLBACK;
SQL
)"
echo "lease_fence_contract=$lease_fence_contract"
[ "$lease_fence_contract" = "1|0|running|true|true" ] || {
  echo "Expected claim-attempt fencing and timeout-aware lease renewal, got $lease_fence_contract" >&2
  exit 1
}
[ "$production_policy_contract" = "default|refresh_then_fail_closed|3|300000|8|redacted|30 days" ] || {
  echo "Expected default production policy, got $production_policy_contract" >&2
  exit 1
}

production_status_contract="$(psql_exec -qAt <<'SQL'
SELECT no_expired_running_jobs::text || '|' ||
       complete_receipts_are_schema_validated::text || '|' ||
       cache_within_bounds::text || '|' ||
       trace_within_bounds::text
FROM otlet.production_status;
SQL
)"
echo "production_status_contract=$production_status_contract"
[ "$production_status_contract" = "true|true|true|true" ] || {
  echo "Expected healthy production status, got $production_status_contract" >&2
  exit 1
}

cleanup_policy_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET worker_event_retention = interval '100 years',
    failed_job_retention = interval '100 years'
WHERE name = 'default';
INSERT INTO otlet.tasks (
  name,
  input_query,
  instruction,
  output_schema,
  model_name
)
VALUES (
  'cleanup_policy_contract',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Cleanup policy contract placeholder',
  '{"type":"object"}'::jsonb,
  :'model_name'
)
ON CONFLICT (name) DO UPDATE
SET model_name = EXCLUDED.model_name;
CREATE TEMP TABLE cleanup_contract_jobs AS
WITH inserted AS (
  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    created_at,
    finished_at
  )
  VALUES
    ('cleanup_policy_contract', 'active-old-event', '{}'::jsonb, 'queued', now() - interval '200 years', NULL),
    ('cleanup_policy_contract', 'failed-recent-event', '{}'::jsonb, 'failed', now() - interval '200 years', now() - interval '200 years'),
    ('cleanup_policy_contract', 'failed-null-finished', '{}'::jsonb, 'failed', now() - interval '200 years', NULL),
    ('cleanup_policy_contract', 'complete-old-event', '{}'::jsonb, 'complete', now() - interval '200 years', now() - interval '200 years'),
    ('cleanup_policy_contract', 'complete-recent-event', '{}'::jsonb, 'complete', now(), now())
  RETURNING id, subject_id
)
SELECT * FROM inserted;
INSERT INTO otlet.worker_events (event_type, job_id, created_at)
SELECT
  'cleanup_policy_contract',
  id,
  CASE subject_id
    WHEN 'failed-recent-event' THEN now()
    WHEN 'complete-recent-event' THEN now()
    ELSE now() - interval '200 years'
  END
FROM cleanup_contract_jobs;
CREATE TEMP TABLE cleanup_contract_dry AS
SELECT * FROM otlet.cleanup_policy_state(true);
CREATE TEMP TABLE cleanup_contract_run AS
SELECT * FROM otlet.cleanup_policy_state(false);
SELECT (
         (SELECT worker_events = 3 AND failed_canceled_jobs = 2 AND dry_run FROM cleanup_contract_dry)
         AND (SELECT worker_events = 3 AND failed_canceled_jobs = 2 AND NOT dry_run FROM cleanup_contract_run)
       )::text || '|' ||
       ((SELECT count(*) FROM otlet.jobs WHERE task_name = 'cleanup_policy_contract') = 3)::text || '|' ||
       ((SELECT count(*) FROM otlet.worker_events WHERE event_type = 'cleanup_policy_contract') = 2)::text || '|' ||
       EXISTS (
         SELECT 1
         FROM otlet.worker_events e
         JOIN cleanup_contract_jobs j ON j.id = e.job_id
         WHERE j.subject_id = 'active-old-event'
       )::text || '|' ||
       EXISTS (
         SELECT 1
         FROM otlet.worker_events e
         JOIN cleanup_contract_jobs j ON j.id = e.job_id
         WHERE j.subject_id = 'complete-recent-event'
       )::text;
ROLLBACK;
SQL
)"
echo "cleanup_policy_contract=$cleanup_policy_contract"
[ "$cleanup_policy_contract" = "true|true|true|true|true" ] || {
  echo "Expected cleanup policy retention contract true|true|true|true|true, got $cleanup_policy_contract" >&2
  exit 1
}

psql_exec \
  -v join_index_name="$join_index_name" \
  -v row_triage_watch="$row_triage_watch" \
  -v row_scoped_watch="$row_scoped_watch" \
  -v row_customscan_watch="$row_customscan_watch" \
  -v row_triage_policy_watch="$row_triage_policy_watch" \
  -v numeric_triage_watch="$numeric_triage_watch" \
  -v pair_strip_watch="$pair_strip_watch" \
  -v action_allowlist_watch="$action_allowlist_watch" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'row_triage_watch');
SELECT otlet.drop_watch(:'row_scoped_watch');
SELECT otlet.drop_watch(:'row_customscan_watch');
SELECT otlet.drop_watch(:'row_triage_policy_watch');
SELECT otlet.drop_watch(:'numeric_triage_watch');
SELECT otlet.drop_watch(:'pair_strip_watch');
SELECT otlet.drop_watch(:'action_allowlist_watch');
SELECT otlet.drop_watch(:'join_index_name');
SQL
cleanup_task "row_review_demo"
cleanup_task "entity_hypothesis_demo"
cleanup_task "row_triage_demo"
cleanup_task "row_scoped_demo"
cleanup_task "row_customscan_demo"
cleanup_task "row_triage_policy_demo"
cleanup_task "$numeric_triage_task"
cleanup_task "$no_abstain_eval_task"
cleanup_task "$pair_strip_task"
cleanup_task "$skip_abstain_task"
cleanup_task "$prompt_identity_preset_task"
cleanup_task "$prompt_identity_direct_task"
cleanup_task "$output_envelope_task"
cleanup_task "$posthoc_output_rule_task"
cleanup_task "$action_allowlist_task"
cleanup_task "$direct_gate_task"
cleanup_task "input_shape_mvcc_raw_demo"
cleanup_task "input_shape_mvcc_hand_demo"
cleanup_task "input_shape_truncate_demo"
cleanup_task "$row_triage_task"
cleanup_task "$row_scoped_task"
cleanup_task "$row_customscan_task"
cleanup_task "$row_triage_policy_task"
cleanup_task "$entity_task"
cleanup_task "$join_task"

model_queue_status_contract="$(psql_exec -qAt -v model_name="$cheap_model_name" <<'SQL'
SELECT queue_state || '|' || queued_jobs::text || '|' || running_jobs::text
FROM otlet.model_queue_status
WHERE model_name = :'model_name';
SQL
)"
echo "model_queue_status_contract=$model_queue_status_contract"
[ "$model_queue_status_contract" = "queue_accepting|0|0" ] || {
  echo "Expected empty accepting model queue, got $model_queue_status_contract" >&2
  exit 1
}

queue_underfill_contract="$(psql_value <<'SQL'
BEGIN;
INSERT INTO otlet.models (name, artifact_path, artifact_hash, artifact_identity)
VALUES (
  'queue_underfill_contract_model',
  '/tmp/not-used.gguf',
  repeat('0', 64),
  jsonb_build_object('sha256', repeat('0', 64), 'bytes', 24, 'source', 'smoke', 'revision', 'v1', 'quantization', 'test', 'license', 'test')
);
INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name)
VALUES (
  'queue_underfill_contract_task',
  'SELECT ''subject-'' || lpad(i::text, 2, ''0'') AS subject_id, ''{}''::jsonb AS input FROM generate_series(1, 10) AS g(i)',
  'Queue underfill contract placeholder',
  '{"type":"object"}'::jsonb,
  'queue_underfill_contract_model'
);
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 5
WHERE name = 'default';
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT 'queue_underfill_contract_task', 'subject-' || lpad(i::text, 2, '0'), '{}'::jsonb
FROM generate_series(1, 3) AS g(i);
CREATE TEMP TABLE queue_underfill_result AS
SELECT otlet.run_task('queue_underfill_contract_task') AS queued;
SELECT (SELECT queued FROM queue_underfill_result)::text || '|' ||
       (SELECT count(*) FROM otlet.jobs WHERE task_name = 'queue_underfill_contract_task')::text || '|' ||
       (SELECT count(*)
        FROM otlet.worker_events
        WHERE event_type = 'queue_admission_suppressed'
          AND detail ->> 'task_name' = 'queue_underfill_contract_task')::text;
ROLLBACK;
SQL
)"
echo "queue_underfill_contract=$queue_underfill_contract"
[ "$queue_underfill_contract" = "0|3|1" ] || {
  echo "Expected all-or-nothing queue contract 0|3|1, got $queue_underfill_contract" >&2
  exit 1
}

queue_fairness_big_task="queue_fairness_big_demo"
queue_fairness_small_task="queue_fairness_small_demo"
cleanup_task "$queue_fairness_big_task"
cleanup_task "$queue_fairness_small_task"
queue_fairness_output="$(
  psql_exec \
    -qAt \
    -v big_task="$queue_fairness_big_task" \
    -v small_task="$queue_fairness_small_task" \
    -v model_name="$strong_model_name" <<'SQL'
CREATE TEMP TABLE queue_fairness_params (
  big_task text,
  small_task text,
  model_name text
);
INSERT INTO queue_fairness_params VALUES (:'big_task', :'small_task', :'model_name');
CREATE TEMP TABLE queue_fairness_claims (
  batch_no int,
  task_name text,
  job_id bigint
);

SELECT otlet.create_task(
  :'big_task',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Queue fairness smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);
SELECT otlet.create_task(
  :'small_task',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Queue fairness smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT :'big_task', 'big-' || lpad(i::text, 4, '0'), '{}'::jsonb
FROM generate_series(1, 1000) AS g(i);
INSERT INTO otlet.jobs (task_name, subject_id, input)
SELECT :'small_task', 'small-' || i::text, '{}'::jsonb
FROM generate_series(1, 4) AS g(i);

UPDATE otlet.production_policy
SET worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';

DO $$
DECLARE
  batch_no int;
  claimed_count int;
  claimed_task text;
  task_model text;
  task_runtime text;
  batch_task_names jsonb;
  job_row otlet.jobs%ROWTYPE;
  small_task_name text;
BEGIN
  SELECT small_task INTO small_task_name FROM queue_fairness_params;

  FOR batch_no IN 1..4 LOOP
    claimed_count := 0;
    claimed_task := NULL;
    batch_task_names := '[]'::jsonb;

    FOR job_row IN SELECT * FROM otlet.claim_jobs() LOOP
      claimed_count := claimed_count + 1;
      claimed_task := job_row.task_name;
      IF NOT batch_task_names ? job_row.task_name THEN
        batch_task_names := batch_task_names || to_jsonb(job_row.task_name);
      END IF;
      INSERT INTO queue_fairness_claims VALUES (batch_no, job_row.task_name, job_row.id);
      PERFORM otlet.complete_job(
        job_row.id,
        '{"status":"ok"}'::jsonb,
        '{"output":{"status":"ok"},"actions":[]}',
        '[]'::jsonb,
        trace_summary => '{"schema_validation_status":"passed","trace_version":"queue_fairness_smoke"}'::jsonb
      );
    END LOOP;

    IF claimed_count > 1 THEN
      SELECT t.model_name, 'linked_inproc'::text
      INTO task_model, task_runtime
      FROM otlet.tasks t
      WHERE t.name = claimed_task;

      PERFORM otlet.record_worker_event(
        'worker_batch_finished',
        NULL,
        task_runtime,
        'worker_batch_finished',
        jsonb_build_object(
          'task_name', claimed_task,
          'task_names', batch_task_names,
          'model_name', task_model,
          'job_count', claimed_count,
          'completed_jobs', claimed_count,
          'failed_jobs', 0
        )
      );
    END IF;

    EXIT WHEN (
      SELECT count(*)
      FROM otlet.jobs
      WHERE task_name = small_task_name
        AND status = 'complete'
    ) = 4;
  END LOOP;
END;
$$;

WITH params AS (
  SELECT * FROM queue_fairness_params
),
summary AS (
  SELECT
    count(*) FILTER (WHERE c.task_name = p.small_task)::bigint AS small_claimed,
    max(c.batch_no) FILTER (WHERE c.task_name = p.small_task) AS last_small_batch,
    count(*) FILTER (WHERE c.batch_no = 1) = 8
      AND count(DISTINCT c.task_name) FILTER (WHERE c.batch_no = 1) = 2 AS cross_task_batch
  FROM params p
  LEFT JOIN queue_fairness_claims c ON true
  GROUP BY p.small_task
),
status AS (
  SELECT w.recent_batch_tasks
  FROM params p
  JOIN otlet.worker_throughput_status w ON w.model_name = p.model_name
),
visible_batches AS (
  SELECT
    EXISTS (
      SELECT 1
      FROM status s, params p, jsonb_array_elements(s.recent_batch_tasks) item
      WHERE item ->> 'task_name' = p.big_task
         OR (item -> 'task_names') ? p.big_task
    ) AS has_big,
    EXISTS (
      SELECT 1
      FROM status s, params p, jsonb_array_elements(s.recent_batch_tasks) item
      WHERE item ->> 'task_name' = p.small_task
         OR (item -> 'task_names') ? p.small_task
    ) AS has_small
)
SELECT (small_claimed = 4)::text || '|' ||
       (last_small_batch <= 2)::text || '|' ||
       cross_task_batch::text || '|' ||
       (has_big AND has_small)::text
FROM summary, visible_batches;
SQL
)"
queue_fairness_contract="$(tail -n 1 <<<"$queue_fairness_output")"
echo "queue_fairness_contract=$queue_fairness_contract"
[ "$queue_fairness_contract" = "true|true|true|true" ] || {
  echo "Expected queue fairness contract true|true|true|true, got $queue_fairness_contract" >&2
  exit 1
}
jobs_status_check_contract="$(
  psql_exec -qAt -v task_name="$queue_fairness_big_task" <<'SQL'
CREATE TEMP TABLE jobs_status_params (task_name text);
INSERT INTO jobs_status_params VALUES (:'task_name');
DO $$
DECLARE
  status_task text;
BEGIN
  SELECT task_name INTO status_task FROM jobs_status_params;
  INSERT INTO otlet.jobs (task_name, subject_id, input, status)
  VALUES (status_task, 'bad-status', '{}'::jsonb, 'not_a_status');
  RAISE EXCEPTION 'expected jobs.status check violation';
EXCEPTION WHEN check_violation THEN
  NULL;
END $$;
SELECT 'rejected';
SQL
)"
echo "jobs_status_check_contract=$jobs_status_check_contract"
[ "$jobs_status_check_contract" = "rejected" ] || {
  echo "Expected invalid jobs.status insert to be rejected, got $jobs_status_check_contract" >&2
  exit 1
}
cleanup_task "$queue_fairness_big_task"
cleanup_task "$queue_fairness_small_task"

queue_race_task="queue_admission_race_demo"
cleanup_task "$queue_race_task"
psql_exec -v task_name="$queue_race_task" -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'race-' || i::text AS subject_id, '{}'::jsonb AS input
    FROM generate_series(1, 5) AS g(i)
  $source$::text,
  'Queue admission race smoke placeholder',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":1,"reasoning":"off"}'::jsonb
);
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 5,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL
psql_exec >/dev/null <<'SQL' &
BEGIN;
SELECT 1 FROM otlet.production_policy WHERE name = 'default' FOR UPDATE;
SELECT pg_sleep(10);
COMMIT;
SQL
queue_lock_pid="$!"
sleep 1
queue_race_pids=()
for _ in $(seq 1 8); do
  psql_exec -qAt -v task_name="$queue_race_task" >/dev/null <<'SQL' &
SELECT otlet.run_task(:'task_name');
SQL
  queue_race_pids+=("$!")
done
for pid in "${queue_race_pids[@]}"; do
  wait "$pid"
done
queue_race_contract="$(psql_exec -qAt -v task_name="$queue_race_task" <<'SQL'
SELECT (count(*) FILTER (WHERE status = 'queued') <= 5)::text || '|' ||
       (count(*) = 5)::text
FROM otlet.jobs
WHERE task_name = :'task_name';
SQL
)"
echo "queue_admission_race_contract=$queue_race_contract"
queue_cap_invariant_contract="$(psql_exec -qAt <<'SQL'
SELECT (count(*) = 0)::text
FROM otlet.verify_invariants()
WHERE invariant_name = 'queued_jobs_within_model_cap';
SQL
)"
echo "queue_cap_invariant_contract=$queue_cap_invariant_contract"
cleanup_task "$queue_race_task"
wait "$queue_lock_pid"
psql_exec >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET max_queued_jobs_per_model = 1000,
    max_attempt_ms = 300000,
    worker_claim_batch_size = 8,
    worker_claim_task_cursor = ''
WHERE name = 'default';
SQL
[ "$queue_race_contract" = "true|true" ] || {
  echo "Expected concurrent run_task admission to keep queued jobs at the cap, got $queue_race_contract" >&2
  exit 1
}
[ "$queue_cap_invariant_contract" = "true" ] || {
  echo "Expected queued-per-model invariant to hold at the admission cap, got $queue_cap_invariant_contract" >&2
  exit 1
}
