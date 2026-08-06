ALTER TABLE otlet.production_policy
ADD COLUMN customscan_preload_max_rows bigint NOT NULL DEFAULT 100000,
ADD COLUMN customscan_preload_max_bytes bigint NOT NULL DEFAULT 67108864,
ADD COLUMN customscan_preload_max_ms integer NOT NULL DEFAULT 30000,
ADD CONSTRAINT production_policy_customscan_preload_rows_bound CHECK (
  customscan_preload_max_rows BETWEEN 1 AND 1000000
),
ADD CONSTRAINT production_policy_customscan_preload_bytes_bound CHECK (
  customscan_preload_max_bytes BETWEEN 1024 AND 1073741824
),
ADD CONSTRAINT production_policy_customscan_preload_ms_bound CHECK (
  customscan_preload_max_ms BETWEEN 1 AND 300000
);

COMMENT ON COLUMN otlet.production_policy.customscan_preload_max_rows IS
'Hard limit on semantic subjects loaded by one native CustomScan';
COMMENT ON COLUMN otlet.production_policy.customscan_preload_max_bytes IS
'Hard limit on accounted semantic state bytes loaded by one native CustomScan';
COMMENT ON COLUMN otlet.production_policy.customscan_preload_max_ms IS
'Hard limit on semantic state preload elapsed milliseconds for one native CustomScan';

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_viewdef('otlet.production_policy_status'::regclass, true);
  old_fragment := $old$    cancellation_observation_p99_target_ms
   FROM otlet.production_policy p$old$;
  new_fragment := $new$    cancellation_observation_p99_target_ms,
    customscan_preload_max_rows,
    customscan_preload_max_bytes,
    customscan_preload_max_ms
   FROM otlet.production_policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet CustomScan preload policy status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.production_policy_status AS '
    || replace(definition, old_fragment, new_fragment);
END;
$migration$;
