ALTER TABLE otlet.production_policy
ADD COLUMN interactive_queue_age_p99_target_ms integer NOT NULL DEFAULT 30000,
ADD COLUMN asynchronous_queue_age_p99_target_ms integer NOT NULL DEFAULT 30000,
ADD COLUMN cancellation_observation_p99_target_ms integer NOT NULL DEFAULT 1000,
ADD CONSTRAINT production_policy_interactive_queue_age_p99_target_bound CHECK (
  interactive_queue_age_p99_target_ms BETWEEN 1 AND 3600000
),
ADD CONSTRAINT production_policy_asynchronous_queue_age_p99_target_bound CHECK (
  asynchronous_queue_age_p99_target_ms BETWEEN 1 AND 86400000
),
ADD CONSTRAINT production_policy_cancellation_observation_p99_target_bound CHECK (
  cancellation_observation_p99_target_ms BETWEEN 1 AND 300000
);

COMMENT ON COLUMN otlet.production_policy.interactive_queue_age_p99_target_ms IS
'Declared native infer-now request-to-start p99 target; compliance is not yet measured';
COMMENT ON COLUMN otlet.production_policy.asynchronous_queue_age_p99_target_ms IS
'Declared native durable-job create-to-job_started p99 target; compliance is not yet measured';
COMMENT ON COLUMN otlet.production_policy.cancellation_observation_p99_target_ms IS
'Declared native cancel-request-to-runtime-observation p99 target; compliance is not yet measured';

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_viewdef('otlet.production_policy_status'::regclass, true);
  old_fragment := $old$    max_queue_age
   FROM otlet.production_policy p$old$;
  new_fragment := $new$    max_queue_age,
    interactive_queue_age_p99_target_ms,
    asynchronous_queue_age_p99_target_ms,
    cancellation_observation_p99_target_ms
   FROM otlet.production_policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet service target status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.production_policy_status AS '
    || replace(definition, old_fragment, new_fragment);
END;
$migration$;
