ALTER TABLE otlet.jobs
ADD COLUMN IF NOT EXISTS infer_now_request boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION otlet.clear_access_policy_grants(target_role regrole)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text := otlet.assert_access_policy_target(
    clear_access_policy_grants.target_role
  );
  granted_column record;
  granted_type regtype;
BEGIN
  FOR granted_column IN
    SELECT DISTINCT
      namespace.nspname,
      relation.relname,
      attribute.attname
    FROM pg_catalog.pg_namespace namespace
    JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid
    JOIN pg_catalog.pg_attribute attribute
      ON attribute.attrelid = relation.oid
    CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) privilege
    WHERE namespace.nspname = 'otlet'
      AND attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND privilege.grantee = clear_access_policy_grants.target_role::oid
    ORDER BY namespace.nspname, relation.relname, attribute.attname
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE ALL PRIVILEGES (%I) ON TABLE %I.%I FROM %I',
      granted_column.attname,
      granted_column.nspname,
      granted_column.relname,
      role_name
    );
  END LOOP;
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA otlet FROM %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA otlet FROM %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA otlet FROM %I',
    role_name
  );
  FOR granted_type IN
    SELECT type.oid::regtype
    FROM pg_catalog.pg_type type
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = type.typnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(type.typacl) privilege
    WHERE namespace.nspname = 'otlet'
      AND privilege.grantee = clear_access_policy_grants.target_role::oid
    ORDER BY type.oid
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE ALL PRIVILEGES ON TYPE %s FROM %I',
      granted_type,
      role_name
    );
  END LOOP;
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON SCHEMA otlet FROM %I',
    role_name
  );
END;
$$;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'otlet.jobs'::regclass
      AND constraint_row.conname = 'jobs_infer_now_request_origin_check'
  ) THEN
    ALTER TABLE otlet.jobs
    ADD CONSTRAINT jobs_infer_now_request_origin_check CHECK (
      NOT infer_now_request OR job_origin IN ('direct_ask', 'customscan')
    );
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION otlet.recover_orphaned_infer_now_jobs(
  cancel_unexpired boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  terminal_status text;
  recovered bigint := 0;
BEGIN
  FOR job_row IN
    SELECT job.*
    FROM otlet.jobs job
    WHERE job.infer_now_request
      AND job.status IN ('queued', 'running', 'cancel_requested')
      AND (
        recover_orphaned_infer_now_jobs.cancel_unexpired
        OR job.leased_until IS NULL
        OR job.leased_until < now()
      )
    ORDER BY job.id
    FOR UPDATE OF job
  LOOP
    IF job_row.status IN ('running', 'cancel_requested')
       AND job_row.leased_until >= now() THEN
      SELECT terminal.status INTO terminal_status
      FROM otlet.cancel_job(
        job_row.id,
        job_row.claim_token,
        'infer-now worker restarted before requester delivery'
      ) terminal
      LIMIT 1;
    ELSE
      SELECT terminal.status INTO terminal_status
      FROM otlet.request_job_cancellation(
        job_row.id,
        'infer-now worker restarted before requester delivery'
      ) terminal
      LIMIT 1;
    END IF;
    IF terminal_status NOT IN ('complete', 'failed', 'canceled') THEN
      RAISE EXCEPTION 'otlet infer-now recovery did not terminalize job %', job_row.id;
    END IF;
    recovered := recovered + 1;
  END LOOP;
  RETURN recovered;
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.recover_orphaned_infer_now_jobs(boolean)
FROM PUBLIC;

CREATE OR REPLACE FUNCTION otlet.native_worker_ready_count() RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT count(*)::bigint
  FROM pg_catalog.pg_stat_activity activity
    JOIN LATERAL (
      SELECT event.event_type
      FROM otlet.worker_events event
      WHERE event.runtime_name = 'linked_inproc'
        AND event.event_type IN ('worker_started', 'worker_startup_failed')
        AND event.detail ->> 'database' = current_database()
        AND event.detail ->> 'backend_pid' = activity.pid::text
        AND event.created_at >= activity.backend_start
      ORDER BY event.id DESC
      LIMIT 1
    ) lifecycle ON lifecycle.event_type = 'worker_started'
  WHERE activity.backend_type = 'otlet worker'
    AND activity.datname = current_database();
$$;

REVOKE EXECUTE ON FUNCTION otlet.native_worker_ready_count() FROM PUBLIC;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$    LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
  ),
  eligible_tasks$old$;
  new_fragment text := $new$    LEFT JOIN otlet.workload_revision_heads head ON head.task_name = j.task_name
    WHERE NOT j.infer_now_request
  ),
  eligible_tasks$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.claim_jobs(text,integer,jsonb)'::regprocedure
  );
  IF position(new_fragment IN definition) = 0 THEN
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet infer-now claim exclusion rewrite is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text :=
    ' AND (claim.status = ANY (ARRAY[''claimed''::text, ''renewed''::text]))';
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.native_cancellation_slo_status'::regclass,
    true
  );
  IF position(old_fragment IN definition) > 0 THEN
    EXECUTE 'CREATE OR REPLACE VIEW otlet.native_cancellation_slo_status AS '
      || pg_catalog.replace(definition, old_fragment, '');
  ELSIF position('claim.status' IN definition) > 0 THEN
    RAISE EXCEPTION 'otlet portable cancellation-gap exclusion rewrite is incomplete';
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  original_definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.operational_observability_status_internal'::regclass,
    true
  );
  original_definition := definition;
  IF position('otlet.native_worker_ready_count() AS sample_count' IN definition) = 0
     AND position('count(activity.pid) AS sample_count' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native liveness readiness rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    'count(activity.pid) AS sample_count',
    'otlet.native_worker_ready_count() AS sample_count'
  );
  definition := pg_catalog.replace(
    definition,
    'count(activity.pid)::numeric AS value_numeric',
    'otlet.native_worker_ready_count()::numeric AS value_numeric'
  );
  definition := pg_catalog.replace(
    definition,
    'WHEN count(activity.pid) > 0 THEN',
    'WHEN otlet.native_worker_ready_count() > 0 THEN'
  );
  definition := pg_catalog.replace(
    definition,
    E'FROM observation observed\n'
      || E'     LEFT JOIN pg_stat_activity activity ON activity.backend_type = ''otlet worker''::text AND activity.datname = current_database()\n'
      || E'  GROUP BY observed.observed_at',
    'FROM observation observed'
  );
  IF definition IS DISTINCT FROM original_definition THEN
    EXECUTE 'CREATE OR REPLACE VIEW otlet.operational_observability_status_internal AS '
      || definition;
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_declaration text := $old$  canceled_swept bigint := 0;
BEGIN$old$;
  new_declaration text := $new$  canceled_swept bigint := 0;
  infer_now_recovered bigint := 0;
BEGIN$new$;
  old_start text := $old$BEGIN
  SELECT p.max_attempts$old$;
  new_start text := $new$BEGIN
  infer_now_recovered := otlet.recover_orphaned_infer_now_jobs(false);

  SELECT p.max_attempts$new$;
  old_return text := $old$  RETURN swept + canceled_swept;$old$;
  new_return text := $new$  RETURN swept + canceled_swept + infer_now_recovered;$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.sweep_expired_jobs()'::regprocedure
  );
  IF position(new_declaration IN definition) = 0 THEN
    IF position(old_declaration IN definition) = 0
       OR position(old_start IN definition) = 0
       OR position(old_return IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet infer-now sweep recovery rewrite is incomplete';
    END IF;
    definition := pg_catalog.replace(
      definition, old_declaration, new_declaration
    );
    definition := pg_catalog.replace(definition, old_start, new_start);
    EXECUTE pg_catalog.replace(definition, old_return, new_return);
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$      finished_at = now()$old$;
  new_fragment text := $new$      finished_at = clock_timestamp()$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.finish_canceled_job(bigint,text,text,text,text,text,timestamptz,boolean,text,text,text,text,text)'::regprocedure
  );
  IF position(new_fragment IN definition) = 0 THEN
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet canceled-job finish timestamp rewrite is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$count(activity.pid) FILTER (WHERE activity.backend_type = 'otlet worker'::text AND activity.datname = current_database()) AS healthy_workers
           FROM pg_stat_activity activity$old$;
  new_fragment text := $new$otlet.native_worker_ready_count() AS healthy_workers$new$;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.route_readiness_status_internal'::regclass,
    true
  );
  IF position(new_fragment IN definition) = 0
     AND position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet native route startup readiness rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  IF definition IS DISTINCT FROM pg_catalog.pg_get_viewdef(
    'otlet.route_readiness_status_internal'::regclass,
    true
  ) THEN
    EXECUTE 'CREATE OR REPLACE VIEW otlet.route_readiness_status_internal AS '
      || definition;
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$event.created_at < clock_timestamp() - policy.worker_event_retention
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs job$old$;
  new_fragment text := $new$event.created_at < clock_timestamp() - policy.worker_event_retention
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_stat_activity activity
      CROSS JOIN LATERAL (
        SELECT lifecycle.id
        FROM otlet.worker_events lifecycle
        WHERE lifecycle.runtime_name = 'linked_inproc'
          AND lifecycle.event_type IN ('worker_started', 'worker_startup_failed')
          AND lifecycle.detail ->> 'database' = current_database()
          AND lifecycle.detail ->> 'backend_pid' = activity.pid::text
          AND lifecycle.created_at >= activity.backend_start
        ORDER BY lifecycle.id DESC
        LIMIT 1
      ) current_lifecycle
      WHERE activity.backend_type = 'otlet worker'
        AND activity.datname = current_database()
        AND current_lifecycle.id = event.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.jobs job$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_step_before_evidence()'::regprocedure
  );
  IF position(new_fragment IN definition) = 0 THEN
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet live worker-event cleanup fence is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$event.created_at < clock_timestamp() - policy.worker_event_retention
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.jobs job$old$;
  new_fragment text := $new$event.created_at < clock_timestamp() - policy.worker_event_retention
        AND NOT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_stat_activity activity
          CROSS JOIN LATERAL (
            SELECT lifecycle.id
            FROM otlet.worker_events lifecycle
            WHERE lifecycle.runtime_name = 'linked_inproc'
              AND lifecycle.event_type IN (
                'worker_started', 'worker_startup_failed'
              )
              AND lifecycle.detail ->> 'database' = current_database()
              AND lifecycle.detail ->> 'backend_pid' = activity.pid::text
              AND lifecycle.created_at >= activity.backend_start
            ORDER BY lifecycle.id DESC
            LIMIT 1
          ) current_lifecycle
          WHERE activity.backend_type = 'otlet worker'
            AND activity.datname = current_database()
            AND current_lifecycle.id = event.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.jobs job$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.maintenance_cleanup_pending_before_evidence()'::regprocedure
  );
  IF position(new_fragment IN definition) = 0 THEN
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet live worker-event pending fence is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END IF;
END;
$migration$;

DO $migration$
DECLARE
  function_name regprocedure;
  definition text;
  old_fragment text := $old$CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
      revision.definition #> '{source,query_contract,declared_sources}',
      '[]'::jsonb
    )) source(value)$old$;
  new_fragment text := $new$CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
      NULLIF(
        revision.definition #> '{source,query_contract,declared_sources}',
        'null'::jsonb
      ),
      '[]'::jsonb
    )) source(value)$new$;
BEGIN
  FOREACH function_name IN ARRAY ARRAY[
    'otlet.watch_source_relation_drift(text,text)'::regprocedure,
    'otlet.lock_task_source_relations(text)'::regprocedure
  ] LOOP
    definition := pg_catalog.pg_get_functiondef(function_name);
    IF position(new_fragment IN definition) > 0 THEN
      CONTINUE;
    END IF;
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet source-relation null normalization rewrite is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END LOOP;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text := $old$SELECT stale_reason AS reason, count(*) AS reason_count
        FROM classified
        WHERE stale
        GROUP BY stale_reason$old$;
  new_fragment text := $new$SELECT
          COALESCE(stale_reason, 'content_revalidation_pending') AS reason,
          count(*) AS reason_count
        FROM classified
        WHERE stale
        GROUP BY COALESCE(stale_reason, 'content_revalidation_pending')$new$;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.recompute_semantic_planner_statistics(text,text,bigint,text)'::regprocedure
  );
  IF position(new_fragment IN definition) = 0 THEN
    IF position(old_fragment IN definition) = 0 THEN
      RAISE EXCEPTION 'otlet semantic stale-reason rewrite is incomplete';
    END IF;
    EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
  END IF;
END;
$migration$;
