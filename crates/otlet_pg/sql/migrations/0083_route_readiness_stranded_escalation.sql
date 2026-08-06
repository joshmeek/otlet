CREATE VIEW otlet.route_readiness_status_internal AS
WITH revision_candidate AS (
  SELECT
    head.task_name,
    head.active_workload_revision_hash AS workload_revision_hash,
    true AS active_revision,
    0::bigint AS queued_evaluation_jobs,
    0::bigint AS queued_production_jobs
  FROM otlet.workload_revision_heads head

  UNION ALL

  SELECT
    job.task_name,
    job.workload_revision_hash,
    false,
    (job.execution_mode = 'evaluation')::integer::bigint,
    (job.execution_mode = 'production')::integer::bigint
  FROM otlet.jobs job
  WHERE job.status = 'queued'
), relevant_revision AS (
  SELECT
    candidate.task_name,
    candidate.workload_revision_hash,
    bool_or(candidate.active_revision) AS active_revision,
    sum(candidate.queued_evaluation_jobs) AS queued_evaluation_jobs,
    sum(candidate.queued_production_jobs) AS queued_production_jobs
  FROM revision_candidate candidate
  GROUP BY candidate.task_name, candidate.workload_revision_hash
), native_runtime AS (
  SELECT
    otlet.linked_runtime_capabilities() AS contract,
    count(activity.pid) FILTER (
      WHERE activity.backend_type = 'otlet worker'
        AND activity.datname = current_database()
    )::bigint AS healthy_workers
  FROM pg_catalog.pg_stat_activity activity
), route AS (
  SELECT
    relevant.task_name,
    relevant.workload_revision_hash,
    relevant.active_revision,
    relevant.queued_evaluation_jobs,
    relevant.queued_production_jobs,
    task.lifecycle_state AS task_lifecycle_state,
    model_route.selection_role,
    model_route.model_name,
    model_route.model_definition,
    revision.definition AS workload_definition,
    COALESCE(
      revision.definition #> '{runtime,effective_options}',
      '{}'::jsonb
    ) AS effective_runtime_options,
    otlet.model_definition_registration_state(
      model_route.model_definition
    ) AS registration_state
  FROM relevant_revision relevant
  JOIN otlet.tasks task ON task.name = relevant.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = relevant.task_name
   AND revision.workload_revision_hash = relevant.workload_revision_hash
  CROSS JOIN LATERAL otlet.workload_revision_model_routes(
    revision.definition
  ) model_route
  WHERE model_route.selection_role IN ('direct', 'cheap', 'strong')
), route_runtime AS (
  SELECT
    route.*,
    slot.status AS native_slot_state,
    native.contract IS NOT NULL
      AND jsonb_typeof(route.effective_runtime_options) = 'object'
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_object_keys(route.effective_runtime_options) option_name
        WHERE NOT COALESCE(
          native.contract -> 'supported_runtime_options' ? option_name,
          false
        )
      ) AS native_runtime_compatible,
    native.healthy_workers AS native_healthy_workers,
    portable.registered_workers AS portable_registered_workers,
    portable.compatible_workers AS portable_compatible_workers,
    portable.eligible_workers AS portable_eligible_workers
  FROM route
  CROSS JOIN native_runtime native
  LEFT JOIN otlet.runtime_slots slot ON slot.model_name = route.model_name
  LEFT JOIN LATERAL (
    SELECT
      count(*)::bigint AS registered_workers,
      count(*) FILTER (WHERE worker.runtime_compatible)::bigint
        AS compatible_workers,
      count(*) FILTER (
        WHERE worker.runtime_compatible
          AND worker.protocol_active
          AND worker.role_ready
          AND worker.enabled
          AND worker.desired_state = 'running'
          AND worker.reported_state IN ('idle', 'running')
          AND worker.model_status = 'ready'
          AND worker.incarnation_nonce_hash IS NOT NULL
          AND worker.last_heartbeat_at >=
            statement_timestamp() - interval '2 minutes'
      )::bigint AS eligible_workers
    FROM (
      SELECT
        portable_worker.*,
        protocol.status = 'active' AS protocol_active,
        database_role.oid IS NOT NULL
          AND pg_catalog.has_schema_privilege(
            database_role.oid,
            'otlet',
            'USAGE'
          )
          AND pg_catalog.has_table_privilege(
            database_role.oid,
            'otlet.portable_protocol_status',
            'SELECT'
          )
          AND (
            SELECT count(*) = 8
              AND count(*) FILTER (WHERE function.prosecdef) = 8
              AND count(*) FILTER (
                WHERE function.proconfig @>
                  ARRAY['search_path=pg_catalog, otlet, pg_temp']
              ) = 8
              AND count(*) FILTER (
                WHERE pg_catalog.has_function_privilege(
                  database_role.oid,
                  function.oid,
                  'EXECUTE'
                )
              ) = 8
            FROM pg_catalog.pg_proc function
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = function.pronamespace
            WHERE namespace.nspname = 'otlet'
              AND function.proname IN (
                'portable_start_worker',
                'portable_claim_jobs',
                'portable_renew_job',
                'portable_record_attempt',
                'portable_complete_job',
                'portable_fail_job',
                'portable_cancel_job',
                'portable_worker_heartbeat'
              )
          ) AS role_ready,
        COALESCE((otlet.portable_runtime_option_status(
          route.workload_definition,
          route.model_definition,
          jsonb_build_object(
            'runtime_contract',
              portable_worker.runtime_identity -> 'runtime_contract',
            'model_artifact_hash', portable_worker.model_artifact_hash,
            'model_artifact_bytes', portable_worker.model_artifact_bytes,
            'current_rss_bytes', portable_worker.current_rss_bytes,
            'default_llama_threads', 1
          )
        ) ->> 'compatible')::boolean, false) AS runtime_compatible
      FROM otlet.portable_workers portable_worker
      LEFT JOIN otlet.portable_protocol_versions protocol
        ON protocol.protocol_version = portable_worker.protocol_version
      LEFT JOIN pg_catalog.pg_roles database_role
        ON database_role.oid = portable_worker.database_role_oid
      WHERE portable_worker.model_name = route.model_name
        AND portable_worker.model_artifact_hash =
          route.model_definition ->> 'artifact_hash'
        AND portable_worker.model_artifact_bytes =
          (route.model_definition #>> '{artifact_identity,bytes}')::bigint
    ) worker
  ) portable ON true
), status AS (
  SELECT
    route_runtime.*,
    CASE
      WHEN route_runtime.registration_state IN (
        'active', 'deprecated', 'draining'
      )
      AND route_runtime.native_runtime_compatible
      AND route_runtime.native_slot_state IS DISTINCT FROM 'error'
      THEN route_runtime.native_healthy_workers
      ELSE 0::bigint
    END AS native_eligible_workers
  FROM route_runtime
)
SELECT
  status.task_name,
  status.workload_revision_hash,
  status.active_revision,
  status.queued_evaluation_jobs,
  status.queued_production_jobs,
  status.task_lifecycle_state,
  status.selection_role,
  status.model_name,
  status.model_definition ->> 'artifact_hash' AS model_artifact_hash,
  (status.model_definition #>> '{artifact_identity,bytes}')::bigint
    AS model_artifact_bytes,
  status.registration_state,
  status.registration_state IN ('active', 'deprecated', 'draining')
    AS model_claim_ready,
  status.registration_state IN (
    'active', 'deprecated', 'draining', 'disabled'
  )
    AS artifact_ready,
  status.effective_runtime_options,
  status.native_runtime_compatible,
  status.native_slot_state,
  status.native_healthy_workers,
  status.native_eligible_workers,
  status.portable_registered_workers,
  status.portable_compatible_workers,
  status.portable_eligible_workers,
  status.native_eligible_workers + status.portable_eligible_workers
    AS eligible_healthy_workers,
  status.task_lifecycle_state = 'active'
    AND (status.active_revision OR status.queued_evaluation_jobs > 0)
    AND status.registration_state IN ('active', 'deprecated', 'draining')
    AND status.native_eligible_workers + status.portable_eligible_workers > 0
    AS route_ready,
  CASE
    WHEN status.task_lifecycle_state <> 'active'
      THEN 'task_' || status.task_lifecycle_state
    WHEN NOT status.active_revision AND status.queued_evaluation_jobs = 0
      THEN 'workload_revision_inactive'
    WHEN status.registration_state = 'registration_missing'
      THEN 'model_missing'
    WHEN status.registration_state = 'identity_mismatch'
      THEN 'model_identity_mismatch'
    WHEN status.registration_state LIKE 'artifact_%'
      THEN 'artifact_not_ready'
    WHEN status.registration_state NOT IN ('active', 'deprecated', 'draining')
      THEN 'model_not_claimable'
    WHEN NOT status.native_runtime_compatible
      AND status.portable_compatible_workers = 0
      THEN 'runtime_incompatible'
    WHEN status.native_runtime_compatible
      AND status.native_healthy_workers > 0
      AND status.native_slot_state = 'error'
      AND status.portable_eligible_workers = 0
      THEN 'native_runtime_error'
    WHEN status.native_eligible_workers + status.portable_eligible_workers = 0
      THEN 'no_eligible_healthy_worker'
    ELSE 'ready'
  END AS readiness_reason
FROM status;

CREATE VIEW otlet.stranded_escalation_status_internal AS
SELECT
  job.id AS job_id,
  job.task_name,
  job.workload_revision_hash,
  job.job_origin,
  job.execution_mode,
  route.model_name AS strong_model_name,
  cheap.receipt_id AS cheap_receipt_id,
  COALESCE(cheap.finished_at, job.created_at) AS escalated_at,
  GREATEST(
    statement_timestamp() - COALESCE(cheap.finished_at, job.created_at),
    interval '0 seconds'
  ) AS escalation_age,
  CASE
    WHEN cheap.receipt_id IS NULL THEN 'missing_cheap_escalation_receipt'
    WHEN cheap.selection_status = 'rejected'
      THEN 'escalated_after_cheap_rejection'
    WHEN cheap.selection_status = 'failed'
      THEN 'escalated_after_cheap_failure'
    ELSE 'unexpected_cheap_escalation_state'
  END AS escalation_reason,
  route.eligible_healthy_workers,
  route.readiness_reason AS route_readiness_reason,
  CASE
    WHEN route.task_lifecycle_state <> 'active'
      THEN 'task_' || route.task_lifecycle_state
    WHEN job.execution_mode = 'production' AND NOT route.active_revision
      THEN 'workload_revision_inactive'
    ELSE route.readiness_reason
  END AS stranded_reason
FROM otlet.jobs job
JOIN otlet.workload_revisions revision
  ON revision.task_name = job.task_name
 AND revision.workload_revision_hash = job.workload_revision_hash
JOIN otlet.route_readiness_status_internal route
  ON route.task_name = job.task_name
 AND route.workload_revision_hash = job.workload_revision_hash
 AND route.selection_role = 'strong'
 AND route.model_name = job.routed_model_name
LEFT JOIN LATERAL (
  SELECT
    receipt.id AS receipt_id,
    receipt.finished_at,
    receipt.selection_status
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = job.id
    AND receipt.selection_role = 'cheap'
  ORDER BY receipt.attempt_index DESC, receipt.id DESC
  LIMIT 1
) cheap ON true
WHERE job.status = 'queued'
  AND job.routed_model_name =
    revision.definition #>> '{selection,strong_model_name}'
  AND (
    NOT route.route_ready
    OR (
      job.execution_mode = 'production'
      AND NOT route.active_revision
    )
  );

CREATE FUNCTION otlet.route_readiness_status_rows()
RETURNS SETOF otlet.route_readiness_status_internal
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT * FROM otlet.route_readiness_status_internal;
$$;

CREATE VIEW otlet.route_readiness_status AS
SELECT * FROM otlet.route_readiness_status_rows();

CREATE FUNCTION otlet.stranded_escalation_status_rows()
RETURNS SETOF otlet.stranded_escalation_status_internal
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT * FROM otlet.stranded_escalation_status_internal;
$$;

CREATE VIEW otlet.stranded_escalation_status AS
SELECT * FROM otlet.stranded_escalation_status_rows();

COMMENT ON VIEW otlet.route_readiness_status IS
'Direct, cheap, and strong workload routes with artifact, runtime, and eligible healthy-worker readiness';
COMMENT ON VIEW otlet.stranded_escalation_status IS
'Immediately stranded queued strong fallbacks with database-authored handoff age and low-cardinality reason';

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
  granted_role text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.grant_auditor_access(regrole)'::regprocedure
  );
  old_fragment := $old$    'otlet.native_cancellation_slo_status TO %I',$old$;
  new_fragment := $new$    'otlet.native_cancellation_slo_status, '
    'otlet.route_readiness_status, '
    'otlet.stranded_escalation_status TO %I',$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet route readiness auditor grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    'otlet.source_query_contract_error(jsonb, boolean) TO %I',$old$;
  new_fragment := $new$    'otlet.source_query_contract_error(jsonb, boolean), '
    'otlet.route_readiness_status_rows(), '
    'otlet.stranded_escalation_status_rows() TO %I',$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'otlet route readiness auditor function grant rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);

  FOR granted_role IN
    SELECT role.rolname
    FROM pg_catalog.pg_roles role
    JOIN LATERAL pg_catalog.aclexplode(
      (SELECT relation.relacl
       FROM pg_catalog.pg_class relation
       WHERE relation.oid =
         'otlet.native_cancellation_slo_status'::regclass)
    ) privilege ON privilege.grantee = role.oid
    WHERE privilege.privilege_type = 'SELECT'
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.route_readiness_status, '
        || 'otlet.stranded_escalation_status TO %I',
      granted_role
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION otlet.route_readiness_status_rows(), '
        || 'otlet.stranded_escalation_status_rows() TO %I',
      granted_role
    );
  END LOOP;
END;
$migration$;

REVOKE ALL ON TABLE otlet.route_readiness_status_internal FROM PUBLIC;
REVOKE ALL ON TABLE otlet.stranded_escalation_status_internal FROM PUBLIC;
REVOKE ALL ON TABLE otlet.route_readiness_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.stranded_escalation_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.route_readiness_status_rows() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.stranded_escalation_status_rows() FROM PUBLIC;
