ALTER TABLE otlet.workload_acceptance_events
DROP CONSTRAINT workload_acceptance_events_event_kind_check;

ALTER TABLE otlet.workload_acceptance_events
ADD CHECK (event_kind IN (
  'exception',
  'promotion_decision',
  'model_qualification',
  'promotion_activation',
  'promotion_rollback'
));

CREATE UNIQUE INDEX workload_acceptance_events_one_promotion_activation_idx
ON otlet.workload_acceptance_events ((
  definition #>> '{payload,promotion_decision_event_hash}'
))
WHERE event_kind = 'promotion_activation';

CREATE UNIQUE INDEX workload_acceptance_events_one_promotion_rollback_idx
ON otlet.workload_acceptance_events ((
  definition #>> '{payload,promotion_activation_event_hash}'
))
WHERE event_kind = 'promotion_rollback';

CREATE OR REPLACE FUNCTION otlet.append_workload_acceptance_event(
  contract_hash text,
  event_kind text,
  payload jsonb
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  task_name text;
  previous_event_hash text;
  previous_event_order bigint;
  new_event_order bigint;
  definition jsonb;
  event_hash text;
  created_at timestamptz;
  authenticated_oid oid := session_user::regrole::oid;
  active_oid oid := current_user::regrole::oid;
  previous_append text := current_setting('otlet.workload_acceptance_append', true);
BEGIN
  IF append_workload_acceptance_event.event_kind NOT IN (
    'exception',
    'promotion_decision',
    'model_qualification',
    'promotion_activation',
    'promotion_rollback'
  ) THEN
    RAISE EXCEPTION 'otlet workload acceptance event kind is invalid';
  END IF;
  IF jsonb_typeof(append_workload_acceptance_event.payload) IS DISTINCT FROM 'object'
     OR octet_length(append_workload_acceptance_event.payload::text) > 65536 THEN
    RAISE EXCEPTION 'otlet workload acceptance event payload must be a bounded object';
  END IF;
  SELECT contract.task_name
  INTO task_name
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = append_workload_acceptance_event.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_acceptance_event:' || append_workload_acceptance_event.contract_hash,
    0
  ));
  SELECT event.event_hash, event.event_order
  INTO previous_event_hash, previous_event_order
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = append_workload_acceptance_event.contract_hash
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events successor
      WHERE successor.contract_hash = event.contract_hash
        AND successor.supersedes_event_hash = event.event_hash
    );
  new_event_order := COALESCE(previous_event_order, 0) + 1;
  created_at := clock_timestamp();
  definition := jsonb_build_object(
    'format', 'otlet.workload_acceptance.event.v1',
    'event_kind', append_workload_acceptance_event.event_kind,
    'contract_hash', append_workload_acceptance_event.contract_hash,
    'event_order', new_event_order,
    'supersedes_event_hash', to_jsonb(previous_event_hash),
    'payload', append_workload_acceptance_event.payload
  );
  event_hash := otlet.identity_hash(
    'workload_acceptance_event',
    jsonb_build_object(
      'definition', definition,
      'authenticated_role_oid', authenticated_oid::text,
      'active_role_oid', active_oid::text,
      'created_at_epoch', EXTRACT(epoch FROM created_at)
    )
  );

  PERFORM set_config('otlet.workload_acceptance_append', 'on', true);
  INSERT INTO otlet.workload_acceptance_events (
    event_hash,
    contract_hash,
    task_name,
    event_kind,
    event_order,
    definition,
    supersedes_event_hash,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name,
    created_at
  ) VALUES (
    event_hash,
    append_workload_acceptance_event.contract_hash,
    task_name,
    append_workload_acceptance_event.event_kind,
    new_event_order,
    definition,
    previous_event_hash,
    authenticated_oid,
    session_user,
    active_oid,
    current_user,
    created_at
  );
  PERFORM set_config(
    'otlet.workload_acceptance_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN event_hash;
END;
$$;

CREATE FUNCTION otlet.validate_promotion_shadow_run() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract_definition jsonb;
  population_kind text;
  population_count bigint;
  active_hash text;
BEGIN
  SELECT contract.definition
  INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = NEW.contract_hash;
  IF contract_definition #>> '{population,rule,kind}' IS DISTINCT FROM
       'promotion_shadow' THEN
    RETURN NEW;
  END IF;

  SELECT min(evaluation_case.population_kind),
         count(DISTINCT evaluation_case.population_kind)
  INTO population_kind, population_count
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(NEW.case_hashes);
  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = NEW.task_name;
  IF population_count IS DISTINCT FROM 1 OR population_kind <> 'shadow'
     OR contract_definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.evaluation_slice_member_manifest_valid(
       contract_definition #> '{population,rule,eligible_members}'
     )
     OR active_hash IS DISTINCT FROM NEW.baseline_workload_revision_hash
     OR EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_contracts successor
       WHERE successor.task_name = NEW.task_name
         AND successor.supersedes_contract_hash = NEW.contract_hash
     ) THEN
    RAISE EXCEPTION 'otlet promotion shadow run requires the current full manifest and active baseline';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_runs_e_promotion_shadow
BEFORE INSERT ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.validate_promotion_shadow_run();

CREATE VIEW otlet.workload_shadow_comparison_status AS
WITH comparison AS (
  SELECT
    report.report_hash,
    run.run_hash,
    run.contract_hash,
    run.task_name,
    run.baseline_workload_revision_hash,
    run.candidate_workload_revision_hash,
    cardinality(run.case_hashes) AS case_count,
    report.definition,
    report.created_at,
    baseline.value -> 'metrics' AS baseline_metrics,
    candidate.value -> 'metrics' AS candidate_metrics
  FROM otlet.evaluation_slice_reports report
  JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
  JOIN otlet.workload_acceptance_contracts contract
    ON contract.contract_hash = run.contract_hash
  JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') baseline(value)
    ON baseline.value ->> 'variant' = 'baseline'
   AND baseline.value ->> 'slice_kind' = 'overall'
  JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') candidate(value)
    ON candidate.value ->> 'variant' = 'candidate'
   AND candidate.value ->> 'slice_kind' = 'overall'
  WHERE report.definition #>> '{population,population_kind}' = 'shadow'
    AND contract.definition #>> '{population,mode}' = 'full'
    AND contract.definition #>> '{population,rule,kind}' = 'promotion_shadow'
    AND otlet.evaluation_slice_member_manifest_valid(
      contract.definition #> '{population,rule,eligible_members}'
    )
)
SELECT
  comparison.report_hash,
  comparison.run_hash,
  comparison.contract_hash AS shadow_contract_hash,
  comparison.task_name,
  comparison.baseline_workload_revision_hash,
  comparison.candidate_workload_revision_hash,
  comparison.case_count,
  comparison.baseline_metrics,
  comparison.candidate_metrics,
  true AS non_authoritative,
  (
    SELECT head.active_workload_revision_hash =
      comparison.baseline_workload_revision_hash
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = comparison.task_name
  )
  AND (
    SELECT count(*) = 1
    FROM otlet.evaluation_runs run
    WHERE run.contract_hash = comparison.contract_hash
  )
  AND (
    SELECT count(*) = 1
    FROM otlet.evaluation_slice_reports report
    JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
    WHERE run.contract_hash = comparison.contract_hash
  )
  AND (
    SELECT count(*) = comparison.case_count::bigint * 2
      AND bool_and(job.status = 'complete')
      AND bool_and(result.result_hash IS NOT NULL)
    FROM otlet.evaluation_executions execution
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    WHERE execution.run_hash = comparison.run_hash
  )
  AND (
    SELECT count(*) = comparison.case_count::bigint
      AND bool_and(replay.same_input_snapshot)
      AND bool_and(replay.non_authoritative)
    FROM otlet.evaluation_replay_status replay
    WHERE replay.run_hash = comparison.run_hash
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
    WHERE execution.run_hash = comparison.run_hash
      AND receipt.schema_validation_status IS DISTINCT FROM 'passed'
  )
  AND (
    SELECT count(*) = 7
      AND bool_and((metric.value ->> 'meets_minimum_support')::boolean)
    FROM jsonb_each(comparison.baseline_metrics) metric
  )
  AND (
    SELECT count(*) = 7
      AND bool_and((metric.value ->> 'meets_minimum_support')::boolean)
    FROM jsonb_each(comparison.candidate_metrics) metric
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.actions action ON action.job_id = execution.job_id
    WHERE execution.run_hash = comparison.run_hash
  ) AS comparison_ready,
  comparison.created_at
FROM comparison;

CREATE OR REPLACE FUNCTION otlet.promote_workload_revision(
  task_name text,
  target_workload_revision_hash text,
  expected_active_workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  active_hash text;
  ledger_operation text := COALESCE(
    NULLIF(current_setting('otlet.workload_revision_operation', true), ''),
    'promote'
  );
BEGIN
  IF ledger_operation NOT IN ('promote', 'rollback') THEN
    RAISE EXCEPTION 'otlet workload revision operation is invalid';
  END IF;
  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || promote_workload_revision.task_name,
    0
  ));

  PERFORM otlet.require_workload_source_contract(
    promote_workload_revision.task_name,
    promote_workload_revision.target_workload_revision_hash
  );

  SELECT head.active_workload_revision_hash
  INTO active_hash
  FROM otlet.workload_revision_heads head
  WHERE head.task_name = promote_workload_revision.task_name
  FOR UPDATE;

  IF NOT FOUND THEN
    IF promote_workload_revision.expected_active_workload_revision_hash IS NOT NULL THEN
      RAISE EXCEPTION 'otlet workload revision promotion conflict: task % has no active revision',
        promote_workload_revision.task_name;
    END IF;
    INSERT INTO otlet.workload_revision_heads (
      task_name,
      active_workload_revision_hash
    ) VALUES (
      promote_workload_revision.task_name,
      promote_workload_revision.target_workload_revision_hash
    );
  ELSE
    IF promote_workload_revision.expected_active_workload_revision_hash IS NULL
       OR active_hash IS DISTINCT FROM
         promote_workload_revision.expected_active_workload_revision_hash THEN
      RAISE EXCEPTION 'otlet workload revision promotion conflict for task %',
        promote_workload_revision.task_name;
    END IF;
    IF active_hash = promote_workload_revision.target_workload_revision_hash THEN
      RETURN active_hash;
    END IF;

    UPDATE otlet.workload_revision_heads head
    SET previous_workload_revision_hash = active_hash,
        active_workload_revision_hash =
          promote_workload_revision.target_workload_revision_hash,
        promoted_at = clock_timestamp()
    WHERE head.task_name = promote_workload_revision.task_name;
  END IF;

  UPDATE otlet.semantic_materializations materialization
  SET stale = true,
      stale_reason = 'contract_changed',
      updated_at = now()
  WHERE materialization.task_name = promote_workload_revision.task_name
    AND materialization.contract_hash IS DISTINCT FROM
      promote_workload_revision.target_workload_revision_hash;

  PERFORM otlet.append_administrative_change(
    'task',
    promote_workload_revision.task_name,
    ledger_operation,
    active_hash,
    promote_workload_revision.target_workload_revision_hash
  );
  RETURN promote_workload_revision.target_workload_revision_hash;
END;
$$;

CREATE FUNCTION otlet.guard_governed_workload_promotion() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  old_hash text;
BEGIN
  IF current_setting('otlet.workload_promotion_apply', true) = 'on' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    old_hash := OLD.active_workload_revision_hash;
  END IF;
  IF NEW.active_workload_revision_hash IS NOT DISTINCT FROM old_hash THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' AND EXISTS (
    SELECT 1
    FROM otlet.tasks task
    WHERE task.name = NEW.task_name
      AND task.lifecycle_state = 'active'
      AND task.lifecycle_revision_hash = NEW.active_workload_revision_hash
      AND task.lifecycle_previous_revision_hash IS NOT DISTINCT FROM
        NEW.previous_workload_revision_hash
      AND task.lifecycle_promoted_at IS NOT DISTINCT FROM NEW.promoted_at
  ) THEN
    RETURN NEW;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts contract
    WHERE contract.task_name = NEW.task_name
      AND contract.candidate_workload_revision_hash IN (
        NEW.active_workload_revision_hash,
        old_hash
      )
      AND contract.definition #>> '{population,rule,kind}' = 'promotion_shadow'
  ) THEN
    RAISE EXCEPTION 'otlet qualified workload revision requires governed promotion or rollback';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_governed_promotion
BEFORE INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.guard_governed_workload_promotion();

CREATE FUNCTION otlet.activate_workload_promotion(
  decision_event_hash text,
  expected_active_workload_revision_hash text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  decision otlet.workload_acceptance_events%ROWTYPE;
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  shadow_contract otlet.workload_acceptance_contracts%ROWTYPE;
  shadow_report otlet.evaluation_slice_reports%ROWTYPE;
  shadow_run otlet.evaluation_runs%ROWTYPE;
  qualification_event otlet.workload_acceptance_events%ROWTYPE;
  head otlet.workload_revision_heads%ROWTYPE;
  decision_run_hashes text[];
  qualification_run_hashes text[];
  qualification_label_ids bigint[];
  expected_role_count integer;
  approved_role_count integer;
  shadow_result_hashes text[];
  activation_payload jsonb;
  existing_event otlet.workload_acceptance_events%ROWTYPE;
  activation_event_hash text;
  previous_reason text := current_setting('otlet.administrative_reason', true);
  previous_ticket text := current_setting('otlet.administrative_ticket', true);
  previous_operation text := current_setting('otlet.workload_revision_operation', true);
  previous_apply text := current_setting('otlet.workload_promotion_apply', true);
BEGIN
  SELECT * INTO decision
  FROM otlet.workload_acceptance_events event
  WHERE event.event_hash = activate_workload_promotion.decision_event_hash;
  IF NOT FOUND OR decision.event_kind <> 'promotion_decision'
     OR decision.definition #>> '{payload,outcome}' <> 'promote' THEN
    RAISE EXCEPTION 'otlet workload promotion activation requires a promote decision';
  END IF;
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = decision.contract_hash;
  IF contract.candidate_workload_revision_hash IS NOT DISTINCT FROM
       contract.baseline_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload promotion activation requires distinct revisions';
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || contract.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_acceptance:' || contract.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_acceptance_event:' || contract.contract_hash,
    0
  ));

  SELECT * INTO existing_event
  FROM otlet.workload_acceptance_events event
  WHERE event.event_kind = 'promotion_activation'
    AND event.definition #>> '{payload,promotion_decision_event_hash}' =
      decision.event_hash;
  IF FOUND THEN
    IF activate_workload_promotion.expected_active_workload_revision_hash
         IS DISTINCT FROM
       existing_event.definition #>> '{payload,prior_workload_revision_hash}' THEN
      RAISE EXCEPTION 'otlet workload promotion activation retry conflicts';
    END IF;
    RETURN existing_event.event_hash;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) OR EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_events later
    WHERE later.contract_hash = decision.contract_hash
      AND later.event_kind = 'promotion_decision'
      AND later.event_order > decision.event_order
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion activation decision is not current';
  END IF;

  SELECT * INTO shadow_report
  FROM otlet.evaluation_slice_reports report
  WHERE report.report_hash = decision.definition #>> '{payload,evidence_hash}';
  IF NOT FOUND
     OR decision.definition #>> '{payload,evidence_summary,shadow_report_hash}'
       IS DISTINCT FROM shadow_report.report_hash
     OR decision.definition #> '{payload,evidence_summary,non_authoritative}'
       IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'otlet workload promotion activation shadow evidence is invalid';
  END IF;
  SELECT * INTO shadow_run
  FROM otlet.evaluation_runs run
  WHERE run.run_hash = shadow_report.run_hash;
  SELECT * INTO shadow_contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = shadow_run.contract_hash;
  IF contract.supersedes_contract_hash IS DISTINCT FROM shadow_contract.contract_hash
     OR shadow_contract.task_name IS DISTINCT FROM contract.task_name
     OR shadow_contract.baseline_workload_revision_hash IS DISTINCT FROM
       contract.baseline_workload_revision_hash
     OR shadow_contract.candidate_workload_revision_hash IS DISTINCT FROM
       contract.candidate_workload_revision_hash
     OR shadow_report.created_at >= decision.created_at
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_shadow_comparison_status status
       WHERE status.report_hash = shadow_report.report_hash
         AND status.comparison_ready
     ) THEN
    RAISE EXCEPTION 'otlet workload promotion activation shadow comparison is not ready';
  END IF;

  SELECT * INTO qualification_event
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = contract.contract_hash
    AND event.event_kind = 'model_qualification';
  IF NOT FOUND OR qualification_event.event_order >= decision.event_order THEN
    RAISE EXCEPTION 'otlet workload promotion activation qualification is invalid';
  END IF;
  SELECT array_agg(value ORDER BY value)
  INTO decision_run_hashes
  FROM jsonb_array_elements_text(
    decision.definition #> '{payload,qualification_run_hashes}'
  ) hash(value);
  SELECT array_agg(value ORDER BY value)
  INTO qualification_run_hashes
  FROM jsonb_array_elements_text(
    qualification_event.definition #> '{payload,run_hashes}'
  ) hash(value);
  IF decision_run_hashes IS DISTINCT FROM qualification_run_hashes THEN
    RAISE EXCEPTION 'otlet workload promotion activation qualification runs differ';
  END IF;

  SELECT array_agg(DISTINCT evaluation_case.label_id ORDER BY evaluation_case.label_id)
  INTO qualification_label_ids
  FROM unnest(qualification_run_hashes) hash(run_hash)
  JOIN otlet.evaluation_runs run ON run.run_hash = hash.run_hash
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = ANY(run.case_hashes);
  PERFORM otlet.lock_eval_label_series(qualification_label_ids);
  PERFORM 1
  FROM otlet.models model
  JOIN jsonb_array_elements(
    qualification_event.definition #> '{payload,roles}'
  ) role(value) ON role.value ->> 'model_name' = model.name
  ORDER BY model.name
  FOR UPDATE OF model;

  expected_role_count := jsonb_array_length(
    qualification_event.definition #> '{payload,roles}'
  );
  SELECT count(*)::integer
  INTO approved_role_count
  FROM otlet.production_model_qualification_status status
  WHERE status.qualification_event_hash = qualification_event.event_hash
    AND status.production_approved;
  IF approved_role_count IS DISTINCT FROM expected_role_count THEN
    RAISE EXCEPTION 'otlet workload promotion activation model qualification is not current';
  END IF;

  IF EXISTS (
    WITH expected AS (
      SELECT
        role.value ->> 'selection_role' AS selection_role,
        role.value ->> 'model_name' AS model_name,
        role.value ->> 'artifact_hash' AS artifact_hash,
        role.value -> 'artifact_identity' AS artifact_identity,
        role.value ->> 'model_identity_hash' AS model_identity_hash,
        role.value ->> 'runtime_identity_hash' AS runtime_identity_hash
      FROM jsonb_array_elements(
        qualification_event.definition #> '{payload,roles}'
      ) role(value)
    ), actual AS (
      SELECT
        receipt.selection_role,
        receipt.model_name,
        receipt.model_artifact_hash AS artifact_hash,
        receipt.model_artifact_identity AS artifact_identity,
        receipt.model_identity_hash,
        otlet.identity_hash(
          'production_model_runtime_identity',
          jsonb_build_object(
            'runtime_name', receipt.runtime_name,
            'runtime_endpoint', receipt.runtime_endpoint,
            'runtime_options_hash', receipt.runtime_options_hash,
            'portable_runtime_identity_hash', portable.runtime_identity_hash
          )
        ) AS runtime_identity_hash
      FROM otlet.evaluation_executions execution
      JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
      LEFT JOIN LATERAL (
        SELECT claim.runtime_identity_hash
        FROM otlet.portable_receipt_links link
        JOIN otlet.portable_claims claim ON claim.id = link.claim_id
        WHERE link.receipt_id = receipt.id
        LIMIT 1
      ) portable ON true
      WHERE execution.run_hash = shadow_run.run_hash
        AND execution.variant = 'candidate'
    )
    SELECT 1
    FROM expected
    FULL JOIN actual USING (
      selection_role,
      model_name,
      artifact_hash,
      artifact_identity,
      model_identity_hash,
      runtime_identity_hash
    )
    WHERE expected.selection_role IS NULL OR actual.selection_role IS NULL
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion activation shadow runtime differs';
  END IF;

  SELECT * INTO head
  FROM otlet.workload_revision_heads stored
  WHERE stored.task_name = contract.task_name
  FOR UPDATE;
  IF activate_workload_promotion.expected_active_workload_revision_hash
       IS DISTINCT FROM contract.baseline_workload_revision_hash
     OR head.active_workload_revision_hash IS DISTINCT FROM
       contract.baseline_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload promotion activation head conflict';
  END IF;

  SELECT array_agg(result.result_hash ORDER BY result.result_hash)
  INTO shadow_result_hashes
  FROM otlet.evaluation_results result
  WHERE result.run_hash = shadow_run.run_hash;
  activation_payload := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.workload_promotion.activation.v1',
    'promotion_decision_event_hash', decision.event_hash,
    'qualification_event_hash', qualification_event.event_hash,
    'qualification_hash',
      qualification_event.definition #>> '{payload,qualification_hash}',
    'qualification_run_hashes', to_jsonb(qualification_run_hashes),
    'shadow_contract_hash', shadow_contract.contract_hash,
    'shadow_run_hash', shadow_run.run_hash,
    'shadow_report_hash', shadow_report.report_hash,
    'shadow_result_hashes', to_jsonb(shadow_result_hashes),
    'task_name', contract.task_name,
    'prior_workload_revision_hash', contract.baseline_workload_revision_hash,
    'resulting_workload_revision_hash', contract.candidate_workload_revision_hash,
    'reason', decision.definition #>> '{payload,reason}',
    'ticket', decision.definition #>> '{payload,ticket}'
  ));
  activation_event_hash := otlet.append_workload_acceptance_event(
    contract.contract_hash,
    'promotion_activation',
    activation_payload
  );
  PERFORM otlet.set_administrative_change_context(
    decision.definition #>> '{payload,reason}',
    decision.definition #>> '{payload,ticket}'
  );
  PERFORM set_config('otlet.workload_revision_operation', 'promote', true);
  PERFORM set_config('otlet.workload_promotion_apply', 'on', true);
  PERFORM otlet.promote_workload_revision(
    contract.task_name,
    contract.candidate_workload_revision_hash,
    contract.baseline_workload_revision_hash
  );
  PERFORM set_config('otlet.administrative_reason', COALESCE(previous_reason, ''), true);
  PERFORM set_config('otlet.administrative_ticket', COALESCE(previous_ticket, ''), true);
  PERFORM set_config('otlet.workload_revision_operation', COALESCE(previous_operation, ''), true);
  PERFORM set_config('otlet.workload_promotion_apply', COALESCE(previous_apply, ''), true);
  RETURN activation_event_hash;
END;
$$;

CREATE FUNCTION otlet.rollback_workload_promotion(
  activation_event_hash text,
  expected_active_workload_revision_hash text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  activation otlet.workload_acceptance_events%ROWTYPE;
  head otlet.workload_revision_heads%ROWTYPE;
  existing_event otlet.workload_acceptance_events%ROWTYPE;
  rollback_payload jsonb;
  rollback_event_hash text;
  previous_reason text := current_setting('otlet.administrative_reason', true);
  previous_ticket text := current_setting('otlet.administrative_ticket', true);
  previous_operation text := current_setting('otlet.workload_revision_operation', true);
  previous_apply text := current_setting('otlet.workload_promotion_apply', true);
BEGIN
  IF NULLIF(btrim(rollback_workload_promotion.reason), '') IS NULL
     OR octet_length(rollback_workload_promotion.reason) > 4096
     OR octet_length(COALESCE(rollback_workload_promotion.ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet workload promotion rollback reason is required and bounded';
  END IF;
  SELECT * INTO activation
  FROM otlet.workload_acceptance_events event
  WHERE event.event_hash = rollback_workload_promotion.activation_event_hash
    AND event.event_kind = 'promotion_activation';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload promotion activation does not exist';
  END IF;

  PERFORM 1
  FROM otlet.production_policy policy
  WHERE policy.name = 'default'
  FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_revision:' || activation.task_name,
    0
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_acceptance_event:' || activation.contract_hash,
    0
  ));

  SELECT * INTO existing_event
  FROM otlet.workload_acceptance_events event
  WHERE event.event_kind = 'promotion_rollback'
    AND event.definition #>> '{payload,promotion_activation_event_hash}' =
      activation.event_hash;
  IF FOUND THEN
    IF rollback_workload_promotion.expected_active_workload_revision_hash
         IS DISTINCT FROM
       existing_event.definition #>> '{payload,prior_workload_revision_hash}'
       OR btrim(rollback_workload_promotion.reason) IS DISTINCT FROM
         existing_event.definition #>> '{payload,reason}'
       OR NULLIF(btrim(rollback_workload_promotion.ticket), '') IS DISTINCT FROM
         existing_event.definition #>> '{payload,ticket}' THEN
      RAISE EXCEPTION 'otlet workload promotion rollback retry conflicts';
    END IF;
    RETURN existing_event.event_hash;
  END IF;

  IF rollback_workload_promotion.expected_active_workload_revision_hash
       IS DISTINCT FROM
       activation.definition #>> '{payload,resulting_workload_revision_hash}'
     OR EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_events later
       WHERE later.task_name = activation.task_name
         AND later.event_kind = 'promotion_activation'
         AND (later.created_at, later.event_hash) >
           (activation.created_at, activation.event_hash)
     ) THEN
    RAISE EXCEPTION 'otlet workload promotion rollback activation is not current';
  END IF;
  SELECT * INTO head
  FROM otlet.workload_revision_heads stored
  WHERE stored.task_name = activation.task_name
  FOR UPDATE;
  IF head.active_workload_revision_hash IS DISTINCT FROM
       activation.definition #>> '{payload,resulting_workload_revision_hash}'
     OR head.previous_workload_revision_hash IS DISTINCT FROM
       activation.definition #>> '{payload,prior_workload_revision_hash}' THEN
    RAISE EXCEPTION 'otlet workload promotion rollback is not one step';
  END IF;

  rollback_payload := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.workload_promotion.rollback.v1',
    'promotion_activation_event_hash', activation.event_hash,
    'task_name', activation.task_name,
    'prior_workload_revision_hash', head.active_workload_revision_hash,
    'resulting_workload_revision_hash', head.previous_workload_revision_hash,
    'reason', btrim(rollback_workload_promotion.reason),
    'ticket', NULLIF(btrim(rollback_workload_promotion.ticket), '')
  ));
  rollback_event_hash := otlet.append_workload_acceptance_event(
    activation.contract_hash,
    'promotion_rollback',
    rollback_payload
  );
  PERFORM otlet.set_administrative_change_context(
    rollback_workload_promotion.reason,
    rollback_workload_promotion.ticket
  );
  PERFORM set_config('otlet.workload_revision_operation', 'rollback', true);
  PERFORM set_config('otlet.workload_promotion_apply', 'on', true);
  PERFORM otlet.rollback_workload_revision(
    activation.task_name,
    rollback_workload_promotion.expected_active_workload_revision_hash,
    NULL
  );
  PERFORM set_config('otlet.administrative_reason', COALESCE(previous_reason, ''), true);
  PERFORM set_config('otlet.administrative_ticket', COALESCE(previous_ticket, ''), true);
  PERFORM set_config('otlet.workload_revision_operation', COALESCE(previous_operation, ''), true);
  PERFORM set_config('otlet.workload_promotion_apply', COALESCE(previous_apply, ''), true);
  RETURN rollback_event_hash;
END;
$$;

CREATE VIEW otlet.workload_promotion_status AS
SELECT
  activation.event_hash AS activation_event_hash,
  activation.definition #>> '{payload,promotion_decision_event_hash}'
    AS promotion_decision_event_hash,
  activation.definition #>> '{payload,qualification_event_hash}'
    AS qualification_event_hash,
  activation.definition #>> '{payload,shadow_contract_hash}' AS shadow_contract_hash,
  activation.definition #>> '{payload,shadow_run_hash}' AS shadow_run_hash,
  activation.definition #>> '{payload,shadow_report_hash}' AS shadow_report_hash,
  activation.contract_hash,
  activation.task_name,
  activation.definition #>> '{payload,prior_workload_revision_hash}'
    AS prior_workload_revision_hash,
  activation.definition #>> '{payload,resulting_workload_revision_hash}'
    AS resulting_workload_revision_hash,
  rollback.event_hash AS rollback_event_hash,
  CASE
    WHEN rollback.event_hash IS NOT NULL
      AND head.active_workload_revision_hash =
        activation.definition #>> '{payload,prior_workload_revision_hash}'
      THEN 'rolled_back'
    WHEN rollback.event_hash IS NULL
      AND head.active_workload_revision_hash =
        activation.definition #>> '{payload,resulting_workload_revision_hash}'
      AND head.previous_workload_revision_hash =
        activation.definition #>> '{payload,prior_workload_revision_hash}'
      THEN 'active'
    ELSE 'superseded'
  END AS promotion_state,
  rollback.event_hash IS NULL
    AND head.active_workload_revision_hash =
      activation.definition #>> '{payload,resulting_workload_revision_hash}'
    AND head.previous_workload_revision_hash =
      activation.definition #>> '{payload,prior_workload_revision_hash}'
    AS rollback_ready,
  activation.authenticated_role_name AS activated_by,
  activation.active_role_name AS activated_as,
  activation.definition #>> '{payload,reason}' AS activation_reason,
  activation.definition #>> '{payload,ticket}' AS activation_ticket,
  activation.created_at AS activated_at,
  rollback.authenticated_role_name AS rolled_back_by,
  rollback.active_role_name AS rolled_back_as,
  rollback.definition #>> '{payload,reason}' AS rollback_reason,
  rollback.definition #>> '{payload,ticket}' AS rollback_ticket,
  rollback.created_at AS rolled_back_at
FROM otlet.workload_acceptance_events activation
LEFT JOIN otlet.workload_revision_heads head ON head.task_name = activation.task_name
LEFT JOIN otlet.workload_acceptance_events rollback
  ON rollback.event_kind = 'promotion_rollback'
 AND rollback.definition #>> '{payload,promotion_activation_event_hash}' =
   activation.event_hash
WHERE activation.event_kind = 'promotion_activation';

REVOKE ALL ON TABLE otlet.workload_shadow_comparison_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.workload_promotion_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_promotion_shadow_run() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_governed_workload_promotion() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.activate_workload_promotion(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.rollback_workload_promotion(text, text, text, text)
FROM PUBLIC;
