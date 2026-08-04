ALTER TABLE otlet.evaluation_cases
ADD COLUMN population_kind text NOT NULL CHECK (
  population_kind IN ('tuning', 'calibration', 'shadow', 'qualification')
),
ADD COLUMN lineage_hash text NOT NULL CHECK (
  lineage_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
);

CREATE UNIQUE INDEX evaluation_cases_lineage_idx
ON otlet.evaluation_cases (lineage_hash);

CREATE OR REPLACE FUNCTION otlet.validate_evaluation_case() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.evaluation.case.v2'
     OR NEW.definition ->> 'source_mode' IS DISTINCT FROM 'approved_shaped_snapshot'
     OR NEW.definition ->> 'task_name' IS DISTINCT FROM NEW.task_name
     OR NEW.definition ->> 'workload_revision_hash' IS DISTINCT FROM
       NEW.workload_revision_hash
     OR NEW.definition ->> 'label_id' IS DISTINCT FROM NEW.label_id::text
     OR NEW.definition ->> 'subject_id' IS DISTINCT FROM NEW.subject_id
     OR NEW.definition ->> 'source_table' IS DISTINCT FROM NEW.source_table
     OR NEW.definition ->> 'source_hash' IS DISTINCT FROM NEW.source_hash
     OR NEW.definition ->> 'shaped_input_hash' IS DISTINCT FROM NEW.shaped_input_hash
     OR NEW.definition ->> 'lineage_hash' IS DISTINCT FROM NEW.lineage_hash
     OR NEW.definition ->> 'population_kind' IS DISTINCT FROM NEW.population_kind
     OR NEW.definition ->> 'expected_answer' IS DISTINCT FROM NEW.expected_answer
     OR NEW.definition ->> 'expected_confidence' IS DISTINCT FROM NEW.expected_confidence
     OR NEW.definition ->> 'expected_action_type' IS DISTINCT FROM NEW.expected_action_type
     OR NEW.definition ->> 'label_source' IS DISTINCT FROM NEW.label_source
     OR NEW.shaped_input_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_shaped_snapshot', NEW.shaped_input)
     OR NEW.lineage_hash IS DISTINCT FROM otlet.identity_hash(
       'evaluation_case_lineage',
       jsonb_strip_nulls(jsonb_build_object(
         'task_name', NEW.task_name,
         'subject_id', NEW.subject_id,
         'source_table', NEW.source_table,
         'source_hash', NEW.source_hash,
         'shaped_input_hash', NEW.shaped_input_hash
       ))
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.eval_labels label
       JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
       JOIN otlet.jobs job ON job.id = receipt.job_id
       JOIN otlet.workload_revisions revision
         ON revision.task_name = job.task_name
        AND revision.workload_revision_hash = job.workload_revision_hash
       WHERE label.id = NEW.label_id
         AND job.task_name = NEW.task_name
         AND job.workload_revision_hash = NEW.workload_revision_hash
         AND job.subject_id = NEW.subject_id
         AND label.source_table IS NOT DISTINCT FROM NEW.source_table
         AND label.source_hash IS NOT DISTINCT FROM NEW.source_hash
         AND label.expected_answer = NEW.expected_answer
         AND label.expected_confidence = NEW.expected_confidence
         AND label.expected_action_type = NEW.expected_action_type
         AND label.label_source = NEW.label_source
         AND otlet.semantic_shaped_input(
           job.input,
           revision.definition #> '{task,input_shaping}'
         ) = NEW.shaped_input
     )
     OR NEW.case_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_case', NEW.definition) THEN
    RAISE EXCEPTION 'otlet evaluation case identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

DROP FUNCTION otlet.register_evaluation_case(bigint, text);

CREATE FUNCTION otlet.register_evaluation_case(
  label_id bigint,
  population_kind text,
  approval_reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  shaped_input jsonb;
  shaped_input_hash text;
  computed_lineage_hash text;
  definition jsonb;
  case_hash text;
  existing_case record;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF COALESCE(register_evaluation_case.population_kind, '') NOT IN (
    'tuning', 'calibration', 'shadow', 'qualification'
  ) THEN
    RAISE EXCEPTION 'otlet evaluation population must be tuning, calibration, shadow, or qualification';
  END IF;
  IF NULLIF(btrim(register_evaluation_case.approval_reason), '') IS NULL
     OR octet_length(register_evaluation_case.approval_reason) > 4096 THEN
    RAISE EXCEPTION 'otlet evaluation snapshot approval reason is required and bounded';
  END IF;

  SELECT
    label.id AS label_id,
    job.task_name,
    job.workload_revision_hash,
    job.subject_id,
    job.input,
    revision.definition #> '{task,input_shaping}' AS input_shaping,
    label.source_table,
    label.source_hash,
    label.expected_answer,
    label.expected_confidence,
    label.expected_action_type,
    label.label_source
  INTO source
  FROM otlet.eval_labels label
  JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
  JOIN otlet.jobs job ON job.id = receipt.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE label.id = register_evaluation_case.label_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation label has no replayable workload evidence';
  END IF;
  IF NOT otlet.source_fields_are_allowed(source.input, source.input_shaping) THEN
    RAISE EXCEPTION 'otlet evaluation source field allowlist is invalid';
  END IF;

  shaped_input := otlet.semantic_shaped_input(source.input, source.input_shaping);
  IF jsonb_typeof(shaped_input) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet evaluation shaped snapshot must be a JSON object';
  END IF;
  shaped_input_hash := otlet.identity_hash('evaluation_shaped_snapshot', shaped_input);
  computed_lineage_hash := otlet.identity_hash(
    'evaluation_case_lineage',
    jsonb_strip_nulls(jsonb_build_object(
      'task_name', source.task_name,
      'subject_id', source.subject_id,
      'source_table', source.source_table,
      'source_hash', source.source_hash,
      'shaped_input_hash', shaped_input_hash
    ))
  );
  definition := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.evaluation.case.v2',
    'source_mode', 'approved_shaped_snapshot',
    'task_name', source.task_name,
    'workload_revision_hash', source.workload_revision_hash,
    'label_id', source.label_id,
    'subject_id', source.subject_id,
    'source_table', source.source_table,
    'source_hash', source.source_hash,
    'shaped_input_hash', shaped_input_hash,
    'lineage_hash', computed_lineage_hash,
    'population_kind', register_evaluation_case.population_kind,
    'expected_answer', source.expected_answer,
    'expected_confidence', source.expected_confidence,
    'expected_action_type', source.expected_action_type,
    'label_source', source.label_source
  ));
  case_hash := otlet.identity_hash('evaluation_case', definition);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_evaluation_case_lineage:' || computed_lineage_hash, 0)
  );
  SELECT existing.case_hash, existing.population_kind, existing.lineage_hash
  INTO existing_case
  FROM otlet.evaluation_cases existing
  WHERE existing.label_id = source.label_id;
  IF FOUND THEN
    IF existing_case.case_hash IS DISTINCT FROM case_hash THEN
      RAISE EXCEPTION 'otlet evaluation label already has a different case identity';
    END IF;
    RETURN existing_case.case_hash;
  END IF;

  SELECT existing.case_hash, existing.population_kind, existing.lineage_hash
  INTO existing_case
  FROM otlet.evaluation_cases existing
  WHERE existing.lineage_hash = computed_lineage_hash;
  IF FOUND THEN
    RAISE EXCEPTION 'otlet evaluation snapshot lineage is already registered as %',
      existing_case.population_kind;
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.evaluation_cases (
    case_hash,
    task_name,
    workload_revision_hash,
    label_id,
    subject_id,
    source_table,
    source_hash,
    shaped_input,
    shaped_input_hash,
    population_kind,
    lineage_hash,
    expected_answer,
    expected_confidence,
    expected_action_type,
    label_source,
    definition,
    approval_reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    case_hash,
    source.task_name,
    source.workload_revision_hash,
    source.label_id,
    source.subject_id,
    source.source_table,
    source.source_hash,
    shaped_input,
    shaped_input_hash,
    register_evaluation_case.population_kind,
    computed_lineage_hash,
    source.expected_answer,
    source.expected_confidence,
    source.expected_action_type,
    source.label_source,
    definition,
    btrim(register_evaluation_case.approval_reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  RETURN case_hash;
END;
$$;

CREATE FUNCTION otlet.validate_evaluation_run_population() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  classified_cases bigint;
  populations bigint;
BEGIN
  SELECT count(*), count(DISTINCT evaluation_case.population_kind)
  INTO classified_cases, populations
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(NEW.case_hashes);
  IF classified_cases IS DISTINCT FROM cardinality(NEW.case_hashes)::bigint
     OR populations IS DISTINCT FROM 1::bigint THEN
    RAISE EXCEPTION 'otlet evaluation runs require one homogeneous case population';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_runs_c_population
BEFORE INSERT ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_run_population();

CREATE OR REPLACE VIEW otlet.evaluation_case_status AS
SELECT
  evaluation_case.case_hash,
  evaluation_case.task_name,
  evaluation_case.workload_revision_hash AS source_workload_revision_hash,
  evaluation_case.label_id,
  evaluation_case.subject_id,
  evaluation_case.source_table,
  evaluation_case.source_hash,
  evaluation_case.shaped_input_hash,
  'approved_shaped_snapshot'::text AS source_mode,
  evaluation_case.expected_answer,
  evaluation_case.expected_confidence,
  evaluation_case.expected_action_type,
  evaluation_case.label_source,
  evaluation_case.approval_reason,
  evaluation_case.authenticated_role_name AS approved_by,
  evaluation_case.active_role_name AS approved_as,
  evaluation_case.created_at,
  evaluation_case.population_kind,
  evaluation_case.lineage_hash
FROM otlet.evaluation_cases evaluation_case;

ALTER VIEW otlet.evaluation_replay_status
RENAME COLUMN same_population TO same_input_snapshot;

ALTER VIEW otlet.audit_evaluation_replay_export
RENAME COLUMN same_population TO same_input_snapshot;

CREATE VIEW otlet.evaluation_exposure_status AS
WITH execution_context AS (
  SELECT
    run.run_hash,
    run.contract_hash,
    run.task_name,
    run.authenticated_role_name,
    run.active_role_name,
    evaluation_case.case_hash,
    evaluation_case.population_kind,
    evaluation_case.lineage_hash,
    evaluation_case.shaped_input,
    execution.variant,
    execution.workload_revision_hash,
    execution.job_id,
    execution.created_at,
    revision.definition AS revision_definition,
    contract.definition AS contract_definition
  FROM otlet.evaluation_runs run
  JOIN otlet.workload_acceptance_contracts contract
    ON contract.contract_hash = run.contract_hash
  JOIN otlet.evaluation_executions execution ON execution.run_hash = run.run_hash
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = execution.case_hash
  JOIN otlet.workload_revisions revision
    ON revision.task_name = run.task_name
   AND revision.workload_revision_hash = execution.workload_revision_hash
), source_exposures AS (
  SELECT
    'source'::text AS exposure_stage,
    evaluation_case.task_name,
    evaluation_case.population_kind,
    evaluation_case.lineage_hash,
    evaluation_case.case_hash,
    NULL::text AS contract_hash,
    NULL::text AS run_hash,
    NULL::text AS variant,
    evaluation_case.workload_revision_hash,
    NULL::bigint AS job_id,
    'source'::text AS component_kind,
    'approved_shaped_snapshot'::text AS component_name,
    evaluation_case.shaped_input_hash AS component_hash,
    NULL::bigint AS receipt_id,
    NULL::integer AS attempt_index,
    NULL::text AS selection_role,
    evaluation_case.population_kind IN ('tuning', 'calibration')
      AS selection_influencing,
    evaluation_case.authenticated_role_name AS actor_name,
    evaluation_case.active_role_name,
    jsonb_build_object(
      'source_mode', 'approved_shaped_snapshot',
      'source_table', evaluation_case.source_table,
      'source_hash', evaluation_case.source_hash
    ) AS exposure_detail,
    evaluation_case.created_at AS exposed_at
  FROM otlet.evaluation_cases evaluation_case
), scheduled_exposures AS (
  SELECT
    'scheduled'::text AS exposure_stage,
    context.task_name,
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    component.kind AS component_kind,
    component.name AS component_name,
    component.hash AS component_hash,
    NULL::bigint AS receipt_id,
    NULL::integer AS attempt_index,
    component.selection_role,
    context.population_kind IN ('tuning', 'calibration') AS selection_influencing,
    context.authenticated_role_name AS actor_name,
    context.active_role_name,
    component.detail AS exposure_detail,
    context.created_at AS exposed_at
  FROM execution_context context
  CROSS JOIN LATERAL (
    SELECT
      'model'::text,
      model.role,
      otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', model.definition ->> 'name',
          'artifact_hash', model.definition ->> 'artifact_hash',
          'artifact_identity', model.definition -> 'artifact_identity'
        )
      ),
      model.role,
      model.definition
    FROM jsonb_each(context.revision_definition -> 'models') model(role, definition)
    WHERE jsonb_typeof(model.definition) = 'object'
    UNION ALL
    SELECT
      'prompt',
      'portable_prompt_v1',
      otlet.identity_text_hash('evaluation_prompt_exposure', prompt.hash),
      NULL::text,
      jsonb_build_object('prompt_hash', prompt.hash)
    FROM LATERAL (
      SELECT otlet.portable_prompt_hash(
        context.revision_definition #>> '{task,instruction}',
        context.revision_definition #> '{task,output_schema}',
        context.shaped_input,
        context.revision_definition #> '{runtime,effective_options}',
        context.revision_definition #> '{task,decision_contract}'
      ) AS hash
    ) prompt
    UNION ALL
    SELECT
      'threshold',
      threshold.name,
      otlet.identity_hash(
        'evaluation_threshold_exposure',
        jsonb_build_object('name', threshold.name, 'definition', threshold.definition)
      ),
      NULL::text,
      threshold.definition
    FROM jsonb_each(context.contract_definition -> 'thresholds') threshold(name, definition)
    UNION ALL
    SELECT
      'policy',
      policy.name,
      otlet.identity_hash(
        'evaluation_policy_exposure',
        jsonb_build_object('name', policy.name, 'definition', policy.definition)
      ),
      NULL::text,
      policy.definition
    FROM (VALUES
      ('decision_contract', context.revision_definition #> '{task,decision_contract}'),
      ('selection', context.revision_definition -> 'selection'),
      ('action_policies', context.revision_definition -> 'action_policies')
    ) policy(name, definition)
  ) component(kind, name, hash, selection_role, detail)
), portable_claim_exposures AS (
  SELECT
    'portable_claim'::text AS exposure_stage,
    context.task_name,
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    component.kind AS component_kind,
    component.name AS component_name,
    component.hash AS component_hash,
    receipt_link.receipt_id,
    COALESCE(linked_receipt.attempt_index, claim.attempt_index) AS attempt_index,
    claim.selection_role,
    context.population_kind IN ('tuning', 'calibration') AS selection_influencing,
    context.authenticated_role_name AS actor_name,
    context.active_role_name,
    component.detail AS exposure_detail,
    claim.claimed_at AS exposed_at
  FROM execution_context context
  JOIN otlet.portable_claims claim ON claim.job_id = context.job_id
  LEFT JOIN otlet.portable_receipt_links receipt_link
    ON receipt_link.claim_id = claim.id
  LEFT JOIN otlet.inference_receipts linked_receipt
    ON linked_receipt.id = receipt_link.receipt_id
  CROSS JOIN LATERAL (
    SELECT
      'model'::text,
      claim.selection_role,
      otlet.identity_hash(
        'model_identity',
        jsonb_build_object(
          'name', model.definition ->> 'name',
          'artifact_hash', model.definition ->> 'artifact_hash',
          'artifact_identity', model.definition -> 'artifact_identity'
        )
      ),
      jsonb_build_object(
        'worker_id', claim.worker_id,
        'model', model.definition,
        'runtime_identity_hash', claim.runtime_identity_hash,
        'selection_role', claim.selection_role
      )
    FROM LATERAL (
      SELECT context.revision_definition -> 'models' -> claim.selection_role AS definition
    ) model
    UNION ALL
    SELECT
      'prompt'::text,
      'portable_prompt_v1'::text,
      otlet.identity_text_hash('evaluation_prompt_exposure', prompt.hash),
      jsonb_build_object('prompt_hash', prompt.hash)
    FROM LATERAL (
      SELECT otlet.portable_prompt_hash(
        context.revision_definition #>> '{task,instruction}',
        context.revision_definition #> '{task,output_schema}',
        context.shaped_input,
        context.revision_definition #> '{runtime,effective_options}',
        context.revision_definition #> '{task,decision_contract}'
      ) AS hash
    ) prompt
  ) component(kind, name, hash, detail)
), attempt_exposures AS (
  SELECT
    'attempt'::text AS exposure_stage,
    context.task_name,
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    component.kind AS component_kind,
    component.name AS component_name,
    component.hash AS component_hash,
    receipt.id AS receipt_id,
    receipt.attempt_index,
    receipt.selection_role,
    context.population_kind IN ('tuning', 'calibration') AS selection_influencing,
    context.authenticated_role_name AS actor_name,
    context.active_role_name,
    component.detail AS exposure_detail,
    receipt.finished_at AS exposed_at
  FROM execution_context context
  JOIN otlet.inference_receipts receipt ON receipt.job_id = context.job_id
  CROSS JOIN LATERAL (VALUES
    (
      'model'::text,
      receipt.selection_role,
      receipt.model_identity_hash,
      jsonb_strip_nulls(jsonb_build_object(
        'model_name', receipt.model_name,
        'model_artifact_hash', receipt.model_artifact_hash,
        'model_identity_hash', receipt.model_identity_hash,
        'selection_role', receipt.selection_role
      ))
    ),
    (
      'prompt'::text,
      'portable_prompt_v1'::text,
      otlet.identity_text_hash('evaluation_prompt_exposure', receipt.prompt_hash),
      jsonb_strip_nulls(jsonb_build_object(
        'prompt_hash', receipt.prompt_hash,
        'input_hash', receipt.input_hash,
        'output_schema_hash', receipt.output_schema_hash
      ))
    )
  ) component(kind, name, hash, detail)
  WHERE component.kind <> 'prompt' OR receipt.prompt_hash IS NOT NULL
), result_exposures AS (
  SELECT
    'result'::text AS exposure_stage,
    context.task_name,
    context.population_kind,
    context.lineage_hash,
    context.case_hash,
    context.contract_hash,
    context.run_hash,
    context.variant,
    context.workload_revision_hash,
    context.job_id,
    'result'::text AS component_kind,
    context.variant AS component_name,
    result.result_hash AS component_hash,
    result.receipt_id,
    receipt.attempt_index,
    receipt.selection_role,
    context.population_kind IN ('tuning', 'calibration') AS selection_influencing,
    context.authenticated_role_name AS actor_name,
    context.active_role_name,
    jsonb_build_object(
      'output_hash', result.output_hash,
      'actions_hash', result.actions_hash,
      'decision_diff', result.decision_diff,
      'approval_diff', result.approval_diff,
      'mutation_diffs', result.mutation_diffs
    ) AS exposure_detail,
    result.created_at AS exposed_at
  FROM execution_context context
  JOIN otlet.evaluation_results result
    ON result.run_hash = context.run_hash
   AND result.case_hash = context.case_hash
   AND result.variant = context.variant
  JOIN otlet.inference_receipts receipt ON receipt.id = result.receipt_id
)
SELECT * FROM source_exposures
UNION ALL SELECT * FROM scheduled_exposures
UNION ALL SELECT * FROM portable_claim_exposures
UNION ALL SELECT * FROM attempt_exposures
UNION ALL SELECT * FROM result_exposures;

DROP FUNCTION otlet.record_workload_promotion_decision(
  text, text, text, jsonb, text, text[], text
);

CREATE FUNCTION otlet.record_workload_promotion_decision(
  contract_hash text,
  outcome text,
  evidence_hash text,
  evidence_summary jsonb,
  reason text,
  qualification_run_hashes text[] DEFAULT ARRAY[]::text[],
  exception_hashes text[] DEFAULT ARRAY[]::text[],
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  normalized_run_hashes text[];
  normalized_exception_hashes text[];
BEGIN
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = record_workload_promotion_decision.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;
  IF COALESCE(record_workload_promotion_decision.outcome, '')
       NOT IN ('promote', 'reject', 'defer')
     OR COALESCE(record_workload_promotion_decision.evidence_hash, '')
       !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     OR jsonb_typeof(record_workload_promotion_decision.evidence_summary)
       IS DISTINCT FROM 'object'
     OR record_workload_promotion_decision.evidence_summary = '{}'::jsonb
     OR octet_length(record_workload_promotion_decision.evidence_summary::text) > 32768
     OR NULLIF(btrim(record_workload_promotion_decision.reason), '') IS NULL
     OR octet_length(record_workload_promotion_decision.reason) > 4096
     OR octet_length(COALESCE(record_workload_promotion_decision.ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet workload promotion decision is invalid';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || contract.task_name, 0)
  );
  SELECT COALESCE(array_agg(DISTINCT hash ORDER BY hash), ARRAY[]::text[])
  INTO normalized_run_hashes
  FROM unnest(COALESCE(
    record_workload_promotion_decision.qualification_run_hashes,
    ARRAY[]::text[]
  )) hash;
  IF EXISTS (
    SELECT 1 FROM unnest(normalized_run_hashes) hash
    WHERE hash !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
       OR NOT EXISTS (
         SELECT 1
         FROM otlet.evaluation_runs run
         WHERE run.run_hash = hash
           AND run.contract_hash = contract.contract_hash
           AND run.task_name = contract.task_name
           AND run.baseline_workload_revision_hash = contract.baseline_workload_revision_hash
           AND run.candidate_workload_revision_hash = contract.candidate_workload_revision_hash
       )
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion decision references an invalid qualification run';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(normalized_run_hashes) hash
    JOIN otlet.evaluation_runs run ON run.run_hash = hash
    WHERE EXISTS (
      SELECT 1
      FROM otlet.evaluation_cases evaluation_case
      WHERE evaluation_case.case_hash = ANY(run.case_hashes)
        AND evaluation_case.population_kind <> 'qualification'
    )
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion decision references a nonqualification run';
  END IF;
  IF record_workload_promotion_decision.outcome = 'promote' THEN
    IF cardinality(normalized_run_hashes) = 0 THEN
      RAISE EXCEPTION 'otlet workload promotion requires qualification runs';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM unnest(normalized_run_hashes) hash
      JOIN otlet.evaluation_runs run ON run.run_hash = hash
      WHERE (
        SELECT count(*)
        FROM otlet.evaluation_results result
        WHERE result.run_hash = run.run_hash
      ) IS DISTINCT FROM cardinality(run.case_hashes)::bigint * 2
    ) THEN
      RAISE EXCEPTION 'otlet workload promotion qualification run is incomplete';
    END IF;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT hash ORDER BY hash), ARRAY[]::text[])
  INTO normalized_exception_hashes
  FROM unnest(COALESCE(
    record_workload_promotion_decision.exception_hashes,
    ARRAY[]::text[]
  )) hash;
  IF EXISTS (
    SELECT 1
    FROM unnest(normalized_exception_hashes) hash
    WHERE NOT EXISTS (
      SELECT 1
      FROM otlet.workload_acceptance_events event
      WHERE event.event_hash = hash
        AND event.contract_hash = contract.contract_hash
        AND event.event_kind = 'exception'
        AND (
          event.definition #>> '{payload,expires_at}' IS NULL
          OR (event.definition #>> '{payload,expires_at}')::timestamptz > clock_timestamp()
        )
    )
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion decision references an invalid exception';
  END IF;
  RETURN otlet.append_workload_acceptance_event(
    contract.contract_hash,
    'promotion_decision',
    jsonb_strip_nulls(jsonb_build_object(
      'candidate_workload_revision_hash', contract.candidate_workload_revision_hash,
      'baseline_workload_revision_hash', contract.baseline_workload_revision_hash,
      'outcome', record_workload_promotion_decision.outcome,
      'evidence_hash', record_workload_promotion_decision.evidence_hash,
      'evidence_summary', record_workload_promotion_decision.evidence_summary,
      'qualification_run_hashes', to_jsonb(normalized_run_hashes),
      'exception_hashes', to_jsonb(normalized_exception_hashes),
      'reason', btrim(record_workload_promotion_decision.reason),
      'ticket', NULLIF(btrim(record_workload_promotion_decision.ticket), '')
    ))
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_case() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_evaluation_case(bigint, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_run_population() FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_exposure_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_workload_promotion_decision(
  text, text, text, jsonb, text, text[], text[], text
) FROM PUBLIC;
