log "Checking worker database-operation deadlines"

database_deadline_task="worker_database_deadline_probe"
database_deadline_lock_holder_pid=""

cleanup_worker_database_deadline() {
  if [ -n "$database_deadline_lock_holder_pid" ]; then
    kill "$database_deadline_lock_holder_pid" >/dev/null 2>&1 || true
    wait "$database_deadline_lock_holder_pid" >/dev/null 2>&1 || true
    database_deadline_lock_holder_pid=""
  fi
  psql_exec >/dev/null <<'SQL'
DROP TRIGGER IF EXISTS worker_database_deadline_delay ON otlet.jobs;
DROP FUNCTION IF EXISTS public.worker_database_deadline_delay();
SQL
  cleanup_task "$database_deadline_task"
}

cleanup_worker_database_deadline
trap cleanup_worker_database_deadline EXIT

psql_exec -v task_name="$database_deadline_task" >/dev/null <<'SQL'
SELECT otlet.register_model(
  'worker_database_deadline_model',
  '/tmp/worker-database-deadline-missing.gguf',
  repeat('6', 64),
  jsonb_build_object(
    'sha256', repeat('6', 64),
    'bytes', 24,
    'source', 'worker-database-deadline-proof',
    'revision', 'v1',
    'quantization', 'test',
    'license', 'test'
  )
);
SELECT otlet.create_task(
  :'task_name',
  NULL,
  'Worker database deadline proof',
  '{"type":"object"}'::jsonb,
  'worker_database_deadline_model',
  '{"max_tokens":1,"max_attempt_ms":1000,"reasoning":"off","inference_cache":false}'::jsonb
);

CREATE FUNCTION public.worker_database_deadline_delay() RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.task_name = 'worker_database_deadline_probe'
     AND OLD.subject_id = 'transaction-timeout'
     AND OLD.status = 'queued'
     AND NEW.status = 'running' THEN
    PERFORM pg_sleep(30);
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER worker_database_deadline_delay
BEFORE UPDATE OF status ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION public.worker_database_deadline_delay();
SQL

database_deadline_pid_before="$(psql_value -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' ORDER BY pid LIMIT 1;")"
[ -n "$database_deadline_pid_before" ] || {
  echo "Native worker was not running before the database deadline proof" >&2
  exit 1
}

psql_exec -v task_name="$database_deadline_task" >/dev/null <<'SQL'
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'transaction-timeout', '{}'::jsonb);
SQL

database_deadline_sleep_seen=false
for _ in $(seq 1 80); do
  if [ "$(psql_value -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'otlet worker' AND wait_event = 'PgSleep';")" = "1" ]; then
    database_deadline_sleep_seen=true
    break
  fi
  sleep 0.1
done
[ "$database_deadline_sleep_seen" = true ] || {
  echo "Worker transaction deadline proof did not reach its controlled sleep" >&2
  exit 1
}

database_deadline_transaction_restart=false
for _ in $(seq 1 180); do
  database_deadline_pid_after="$(psql_value -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' ORDER BY pid LIMIT 1;")"
  if [ -n "$database_deadline_pid_after" ] && [ "$database_deadline_pid_after" != "$database_deadline_pid_before" ]; then
    database_deadline_transaction_restart=true
    break
  fi
  sleep 0.1
done

database_deadline_transaction_contract="$(psql_value -v task_name="$database_deadline_task" <<'SQL'
SELECT concat_ws('|',
  status = 'queued',
  attempts = 0,
  claim_token IS NULL,
  (SELECT count(*) = 0 FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id)
)
FROM otlet.jobs job
WHERE task_name = :'task_name'
  AND subject_id = 'transaction-timeout';
SQL
)"
echo "worker_database_transaction_timeout_contract=$database_deadline_sleep_seen|$database_deadline_transaction_restart|$database_deadline_transaction_contract"
[ "$database_deadline_sleep_seen|$database_deadline_transaction_restart|$database_deadline_transaction_contract" = "true|true|t|t|t|t" ] || {
  echo "Expected a bounded transaction restart with no partial claim state" >&2
  exit 1
}

psql_exec >/dev/null <<'SQL'
DROP TRIGGER worker_database_deadline_delay ON otlet.jobs;
DROP FUNCTION public.worker_database_deadline_delay();
SQL
wait_task_failed "$database_deadline_task" 1 120 0.25

database_deadline_pid_before="$(psql_value -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' ORDER BY pid LIMIT 1;")"
[ -n "$database_deadline_pid_before" ] || {
  echo "Native worker was not running before the lock deadline proof" >&2
  exit 1
}

psql_exec -qAt -v task_name="$database_deadline_task" >/dev/null 2>&1 <<'SQL' &
SET application_name = 'otlet_worker_database_deadline_holder';
SELECT pg_advisory_lock(hashtext('otlet_queue_admission'));
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES (:'task_name', 'lock-timeout', '{}'::jsonb);
SELECT pg_sleep(60);
SELECT pg_advisory_unlock(hashtext('otlet_queue_admission'));
SQL
database_deadline_lock_holder_pid="$!"

database_deadline_holder_ready=false
for _ in $(seq 1 80); do
  if [ "$(psql_value -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'otlet_worker_database_deadline_holder' AND wait_event = 'PgSleep';")" = "1" ]; then
    database_deadline_holder_ready=true
    break
  fi
  sleep 0.1
done
[ "$database_deadline_holder_ready" = true ] || {
  echo "Worker lock deadline proof did not acquire its queue lock" >&2
  exit 1
}

database_deadline_lock_restart=false
for _ in $(seq 1 80); do
  database_deadline_pid_after="$(psql_value -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'otlet worker' ORDER BY pid LIMIT 1;")"
  if [ -n "$database_deadline_pid_after" ] && [ "$database_deadline_pid_after" != "$database_deadline_pid_before" ]; then
    database_deadline_lock_restart=true
    break
  fi
  sleep 0.1
done

database_deadline_lock_contract="$(psql_value -v task_name="$database_deadline_task" <<'SQL'
SELECT concat_ws('|',
  (SELECT count(*) = 1 FROM pg_stat_activity
   WHERE application_name = 'otlet_worker_database_deadline_holder'),
  status = 'queued',
  attempts = 0,
  claim_token IS NULL,
  (SELECT count(*) = 0 FROM otlet.inference_receipts receipt WHERE receipt.job_id = job.id)
)
FROM otlet.jobs job
WHERE task_name = :'task_name'
  AND subject_id = 'lock-timeout';
SQL
)"
echo "worker_database_lock_timeout_contract=$database_deadline_holder_ready|$database_deadline_lock_restart|$database_deadline_lock_contract"
[ "$database_deadline_holder_ready|$database_deadline_lock_restart|$database_deadline_lock_contract" = "true|true|t|t|t|t|t" ] || {
  echo "Expected a bounded lock restart with no partial claim state" >&2
  exit 1
}

psql_value -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'otlet_worker_database_deadline_holder';" >/dev/null
wait "$database_deadline_lock_holder_pid" >/dev/null 2>&1 || true
database_deadline_lock_holder_pid=""
wait_task_failed "$database_deadline_task" 2 120 0.25

database_deadline_contract="$(psql_value -v task_name="$database_deadline_task" <<'SQL'
WITH capability AS (
  SELECT database_operations
  FROM otlet.runtime_capability_status
  WHERE runtime_kind = 'native'
),
started AS (
  SELECT detail
  FROM otlet.worker_events
  WHERE event_type = 'worker_started'
  ORDER BY id DESC
  LIMIT 1
),
wake AS (
  SELECT otlet.worker_wake_state() AS state
),
worker AS (
  SELECT pid
  FROM pg_stat_activity
  WHERE backend_type = 'otlet worker'
)
SELECT concat_ws('|',
  capability.database_operations ->> 'transaction_timeout_ms',
  capability.database_operations ->> 'lock_timeout_ms',
  started.detail ->> 'database_transaction_timeout_ms',
  started.detail ->> 'database_lock_timeout_ms',
  (SELECT count(*) = 2 AND bool_and(status = 'failed' AND attempts = 1)
   FROM otlet.jobs WHERE task_name = :'task_name'),
  (SELECT count(*) = 2 FROM otlet.inference_receipts receipt
   JOIN otlet.jobs job ON job.id = receipt.job_id
   WHERE job.task_name = :'task_name'),
  (SELECT count(*) = 0 FROM otlet.outputs output
   JOIN otlet.jobs job ON job.id = output.job_id
   WHERE job.task_name = :'task_name'),
  (SELECT count(*) = 0 FROM otlet.verify_invariants()),
  (SELECT count(*) = 1 FROM worker),
  (wake.state ->> 'registered_workers')::integer = 1
    AND jsonb_array_length(wake.state -> 'worker_pids') = 1
    AND (wake.state ->> 'worker_pid')::integer = (SELECT pid FROM worker)
)
FROM capability, started, wake;
SQL
)"
echo "worker_database_operation_deadline_contract=$database_deadline_contract"
[ "$database_deadline_contract" = "10000|1000|10000|1000|t|t|t|t|t|t" ] || {
  echo "Expected declared, applied, recovered worker database deadlines, got $database_deadline_contract" >&2
  exit 1
}

cleanup_worker_database_deadline
trap - EXIT
