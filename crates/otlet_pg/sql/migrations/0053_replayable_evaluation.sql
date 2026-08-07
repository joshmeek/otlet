CREATE TABLE otlet.evaluation_cases (
  case_hash text PRIMARY KEY CHECK (
    case_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  workload_revision_hash text NOT NULL,
  label_id bigint NOT NULL UNIQUE REFERENCES otlet.eval_labels(id),
  subject_id text NOT NULL,
  source_table text,
  source_hash text,
  shaped_input jsonb NOT NULL CHECK (jsonb_typeof(shaped_input) = 'object'),
  shaped_input_hash text NOT NULL CHECK (
    shaped_input_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  expected_answer text NOT NULL,
  expected_confidence text NOT NULL CHECK (
    expected_confidence IN ('high', 'medium', 'low')
  ),
  expected_action_type text NOT NULL,
  label_source text NOT NULL,
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  approval_reason text NOT NULL CHECK (
    NULLIF(btrim(approval_reason), '') IS NOT NULL
    AND octet_length(approval_reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  CHECK (source_hash IS NULL OR source_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$')
);

CREATE INDEX evaluation_cases_task_created_idx
ON otlet.evaluation_cases (task_name, created_at DESC, case_hash);

CREATE TABLE otlet.evaluation_runs (
  run_hash text PRIMARY KEY CHECK (
    run_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  task_name text NOT NULL REFERENCES otlet.tasks(name),
  baseline_workload_revision_hash text NOT NULL,
  candidate_workload_revision_hash text NOT NULL,
  run_key text NOT NULL CHECK (
    run_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ),
  case_hashes text[] NOT NULL CHECK (cardinality(case_hashes) > 0),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (contract_hash, run_key),
  UNIQUE (run_hash, task_name),
  FOREIGN KEY (task_name, baseline_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
  FOREIGN KEY (task_name, candidate_workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE INDEX evaluation_runs_task_created_idx
ON otlet.evaluation_runs (task_name, created_at DESC, run_hash);

CREATE TABLE otlet.evaluation_executions (
  run_hash text NOT NULL REFERENCES otlet.evaluation_runs(run_hash),
  case_hash text NOT NULL REFERENCES otlet.evaluation_cases(case_hash),
  variant text NOT NULL CHECK (variant IN ('baseline', 'candidate')),
  workload_revision_hash text NOT NULL,
  job_id bigint NOT NULL UNIQUE REFERENCES otlet.jobs(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (run_hash, case_hash, variant),
  FOREIGN KEY (workload_revision_hash)
    REFERENCES otlet.workload_revisions(workload_revision_hash)
);

CREATE INDEX evaluation_executions_job_idx
ON otlet.evaluation_executions (job_id, run_hash, case_hash, variant);

CREATE TABLE otlet.evaluation_results (
  result_hash text PRIMARY KEY CHECK (
    result_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  run_hash text NOT NULL,
  case_hash text NOT NULL,
  variant text NOT NULL CHECK (variant IN ('baseline', 'candidate')),
  job_id bigint NOT NULL UNIQUE REFERENCES otlet.jobs(id),
  output_id bigint NOT NULL UNIQUE REFERENCES otlet.outputs(id),
  receipt_id bigint NOT NULL REFERENCES otlet.inference_receipts(id),
  output_hash text NOT NULL CHECK (
    output_hash ~ '^[0-9a-f]{64}$'
  ),
  actions_hash text NOT NULL CHECK (
    actions_hash ~ '^[0-9a-f]{64}$'
  ),
  decision_diff jsonb NOT NULL CHECK (jsonb_typeof(decision_diff) = 'object'),
  approval_diff jsonb NOT NULL CHECK (jsonb_typeof(approval_diff) = 'object'),
  mutation_diffs jsonb NOT NULL CHECK (jsonb_typeof(mutation_diffs) = 'array'),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (run_hash, case_hash, variant)
    REFERENCES otlet.evaluation_executions(run_hash, case_hash, variant)
);

CREATE INDEX evaluation_results_run_case_idx
ON otlet.evaluation_results (run_hash, case_hash, variant);

CREATE FUNCTION otlet.guard_evaluation_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.evaluation_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet evaluation evidence is append only';
END;
$$;

CREATE FUNCTION otlet.validate_evaluation_case() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.evaluation.case.v1'
     OR NEW.definition ->> 'source_mode' IS DISTINCT FROM 'approved_shaped_snapshot'
     OR NEW.definition ->> 'task_name' IS DISTINCT FROM NEW.task_name
     OR NEW.definition ->> 'workload_revision_hash' IS DISTINCT FROM
       NEW.workload_revision_hash
     OR NEW.definition ->> 'label_id' IS DISTINCT FROM NEW.label_id::text
     OR NEW.definition ->> 'subject_id' IS DISTINCT FROM NEW.subject_id
     OR NEW.definition ->> 'source_table' IS DISTINCT FROM NEW.source_table
     OR NEW.definition ->> 'source_hash' IS DISTINCT FROM NEW.source_hash
     OR NEW.definition ->> 'shaped_input_hash' IS DISTINCT FROM NEW.shaped_input_hash
     OR NEW.definition ->> 'expected_answer' IS DISTINCT FROM NEW.expected_answer
     OR NEW.definition ->> 'expected_confidence' IS DISTINCT FROM NEW.expected_confidence
     OR NEW.definition ->> 'expected_action_type' IS DISTINCT FROM NEW.expected_action_type
     OR NEW.definition ->> 'label_source' IS DISTINCT FROM NEW.label_source
     OR NEW.shaped_input_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_shaped_snapshot', NEW.shaped_input)
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

CREATE FUNCTION otlet.validate_evaluation_run() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  canonical_case_hashes text[];
BEGIN
  SELECT array_agg(DISTINCT hash ORDER BY hash)
  INTO canonical_case_hashes
  FROM unnest(NEW.case_hashes) hash;
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.evaluation.run.v1'
     OR NEW.definition ->> 'contract_hash' IS DISTINCT FROM NEW.contract_hash
     OR NEW.definition ->> 'task_name' IS DISTINCT FROM NEW.task_name
     OR NEW.definition ->> 'baseline_workload_revision_hash' IS DISTINCT FROM
       NEW.baseline_workload_revision_hash
     OR NEW.definition ->> 'candidate_workload_revision_hash' IS DISTINCT FROM
       NEW.candidate_workload_revision_hash
     OR NEW.definition ->> 'run_key' IS DISTINCT FROM NEW.run_key
     OR NEW.definition -> 'case_hashes' IS DISTINCT FROM to_jsonb(NEW.case_hashes)
     OR NEW.definition ->> 'reason' IS DISTINCT FROM NEW.reason
     OR NEW.case_hashes IS DISTINCT FROM canonical_case_hashes
     OR cardinality(NEW.case_hashes) * 2 > (
       SELECT policy.max_admission_rows
       FROM otlet.production_policy policy
       WHERE policy.name = 'default'
     )
     OR EXISTS (
       SELECT 1
       FROM unnest(NEW.case_hashes) hash
       WHERE hash !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_contracts contract
       WHERE contract.contract_hash = NEW.contract_hash
         AND contract.task_name = NEW.task_name
         AND contract.baseline_workload_revision_hash =
           NEW.baseline_workload_revision_hash
         AND contract.candidate_workload_revision_hash =
           NEW.candidate_workload_revision_hash
     )
     OR (
       SELECT count(*)
       FROM otlet.evaluation_cases evaluation_case
       WHERE evaluation_case.case_hash = ANY(NEW.case_hashes)
         AND evaluation_case.task_name = NEW.task_name
     ) IS DISTINCT FROM cardinality(NEW.case_hashes)::bigint
     OR NEW.run_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_run', NEW.definition) THEN
    RAISE EXCEPTION 'otlet evaluation run identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.validate_evaluation_execution() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.evaluation_runs run
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = NEW.case_hash
     AND evaluation_case.task_name = run.task_name
    JOIN otlet.jobs job
      ON job.id = NEW.job_id
     AND job.task_name = run.task_name
     AND job.subject_id = evaluation_case.subject_id
     AND job.input = evaluation_case.shaped_input
     AND job.execution_mode = 'evaluation'
     AND job.workload_revision_hash = NEW.workload_revision_hash
    WHERE run.run_hash = NEW.run_hash
      AND NEW.case_hash = ANY(run.case_hashes)
      AND NEW.workload_revision_hash = CASE NEW.variant
        WHEN 'baseline' THEN run.baseline_workload_revision_hash
        WHEN 'candidate' THEN run.candidate_workload_revision_hash
      END
  ) THEN
    RAISE EXCEPTION 'otlet evaluation execution identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.validate_evaluation_result() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.evaluation.result.v1'
     OR NEW.definition ->> 'run_hash' IS DISTINCT FROM NEW.run_hash
     OR NEW.definition ->> 'case_hash' IS DISTINCT FROM NEW.case_hash
     OR NEW.definition ->> 'variant' IS DISTINCT FROM NEW.variant
     OR NEW.definition ->> 'job_id' IS DISTINCT FROM NEW.job_id::text
     OR NEW.definition ->> 'output_id' IS DISTINCT FROM NEW.output_id::text
     OR NEW.definition ->> 'receipt_id' IS DISTINCT FROM NEW.receipt_id::text
     OR NEW.definition ->> 'output_hash' IS DISTINCT FROM NEW.output_hash
     OR NEW.definition ->> 'actions_hash' IS DISTINCT FROM NEW.actions_hash
     OR NEW.definition -> 'decision_diff' IS DISTINCT FROM NEW.decision_diff
     OR NEW.definition -> 'approval_diff' IS DISTINCT FROM NEW.approval_diff
     OR NEW.definition -> 'mutation_diffs' IS DISTINCT FROM NEW.mutation_diffs
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.evaluation_executions execution
       JOIN otlet.jobs job
         ON job.id = execution.job_id
        AND job.status = 'complete'
        AND job.execution_mode = 'evaluation'
       JOIN otlet.outputs evaluation_output
         ON evaluation_output.id = NEW.output_id
        AND evaluation_output.job_id = job.id
       JOIN otlet.inference_receipts receipt
         ON receipt.id = NEW.receipt_id
        AND receipt.id = evaluation_output.receipt_id
        AND receipt.job_id = job.id
        AND receipt.status = 'complete'
        AND receipt.selection_status = 'accepted'
        AND receipt.schema_validation_status = 'passed'
        AND receipt.output_hash = NEW.output_hash
        AND receipt.actions_hash = NEW.actions_hash
       WHERE execution.run_hash = NEW.run_hash
         AND execution.case_hash = NEW.case_hash
         AND execution.variant = NEW.variant
         AND execution.job_id = NEW.job_id
     )
     OR NEW.result_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_result', NEW.definition) THEN
    RAISE EXCEPTION 'otlet evaluation result identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_cases_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evaluation_cases
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_cases_b_validate
BEFORE INSERT ON otlet.evaluation_cases
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_case();

CREATE TRIGGER evaluation_cases_truncate_guard
BEFORE TRUNCATE ON otlet.evaluation_cases
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_runs_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_runs_b_validate
BEFORE INSERT ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_run();

CREATE TRIGGER evaluation_runs_truncate_guard
BEFORE TRUNCATE ON otlet.evaluation_runs
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_executions_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evaluation_executions
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_executions_validate
BEFORE INSERT ON otlet.evaluation_executions
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_execution();

CREATE TRIGGER evaluation_executions_truncate_guard
BEFORE TRUNCATE ON otlet.evaluation_executions
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_results_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evaluation_results
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_results_b_validate
BEFORE INSERT ON otlet.evaluation_results
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_result();

CREATE TRIGGER evaluation_results_truncate_guard
BEFORE TRUNCATE ON otlet.evaluation_results
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.guard_evaluation_job_mode() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.execution_mode IS DISTINCT FROM OLD.execution_mode THEN
    RAISE EXCEPTION 'otlet job execution mode is immutable';
  END IF;
  IF TG_OP = 'INSERT'
     AND NEW.execution_mode = 'evaluation'
     AND current_setting('otlet.evaluation_append', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'otlet evaluation jobs must be created through start_replay_evaluation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_evaluation_mode_guard
BEFORE INSERT OR UPDATE OF execution_mode ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_job_mode();

CREATE FUNCTION otlet.register_evaluation_case(
  label_id bigint,
  approval_reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  shaped_input jsonb;
  shaped_input_hash text;
  definition jsonb;
  case_hash text;
  existing_hash text;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
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
  definition := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.evaluation.case.v1',
    'source_mode', 'approved_shaped_snapshot',
    'task_name', source.task_name,
    'workload_revision_hash', source.workload_revision_hash,
    'label_id', source.label_id,
    'subject_id', source.subject_id,
    'source_table', source.source_table,
    'source_hash', source.source_hash,
    'shaped_input_hash', shaped_input_hash,
    'expected_answer', source.expected_answer,
    'expected_confidence', source.expected_confidence,
    'expected_action_type', source.expected_action_type,
    'label_source', source.label_source
  ));
  case_hash := otlet.identity_hash('evaluation_case', definition);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_evaluation_case:' || source.label_id::text, 0)
  );
  SELECT existing.case_hash
  INTO existing_hash
  FROM otlet.evaluation_cases existing
  WHERE existing.label_id = source.label_id;
  IF FOUND THEN
    IF existing_hash IS DISTINCT FROM case_hash THEN
      RAISE EXCEPTION 'otlet evaluation label already has a different case identity';
    END IF;
    RETURN existing_hash;
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

CREATE FUNCTION otlet.evaluation_revision_diff(
  task_name text,
  baseline_workload_revision_hash text,
  candidate_workload_revision_hash text
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH changes AS MATERIALIZED (
    SELECT
      path,
      old_value,
      new_value,
      jsonb_build_object(
        'path', path,
        'old_value', old_value,
        'new_value', new_value
      ) AS change
    FROM otlet.workload_revision_diff(
      evaluation_revision_diff.task_name,
      evaluation_revision_diff.baseline_workload_revision_hash,
      evaluation_revision_diff.candidate_workload_revision_hash
    )
  ), categorized AS (
    SELECT 'model'::text AS component, change
    FROM changes WHERE path = '/models' OR path LIKE '/models/%'
    UNION ALL
    SELECT 'prompt', change
    FROM changes
    WHERE path = '/task/instruction'
       OR path = '/prompt_builder'
       OR path LIKE '/prompt_builder/%'
    UNION ALL
    SELECT 'schema', change
    FROM changes
    WHERE path = '/task/output_schema'
       OR path LIKE '/task/output_schema/%'
       OR path = '/task/decision_contract'
       OR path LIKE '/task/decision_contract/%'
       OR path = '/validator'
       OR path LIKE '/validator/%'
    UNION ALL
    SELECT 'runtime', change
    FROM changes
    WHERE path = '/runtime'
       OR path LIKE '/runtime/%'
       OR path = '/task/runtime_options'
       OR path LIKE '/task/runtime_options/%'
       OR path = '/decode'
       OR path LIKE '/decode/%'
    UNION ALL
    SELECT 'selection', change
    FROM changes WHERE path = '/selection' OR path LIKE '/selection/%'
    UNION ALL
    SELECT 'candidate', change
    FROM changes
    WHERE path = '/source'
       OR path LIKE '/source/%'
       OR path = '/task/input_query'
       OR path = '/task/input_shaping'
       OR path LIKE '/task/input_shaping/%'
  ), components(component) AS (
    VALUES ('model'), ('prompt'), ('schema'), ('runtime'), ('selection'), ('candidate')
  )
  SELECT jsonb_build_object(
    'components', jsonb_object_agg(
      component.component,
      jsonb_build_object(
        'changed', COALESCE(cardinality(grouped.changes), 0) > 0,
        'changes', to_jsonb(COALESCE(grouped.changes, ARRAY[]::jsonb[]))
      )
      ORDER BY component.component
    ),
    'all_changes', COALESCE(
      (SELECT jsonb_agg(change ORDER BY path) FROM changes),
      '[]'::jsonb
    )
  )
  FROM components component
  LEFT JOIN LATERAL (
    SELECT array_agg(categorized.change ORDER BY categorized.change ->> 'path') AS changes
    FROM categorized
    WHERE categorized.component = component.component
  ) grouped ON true;
$$;

CREATE FUNCTION otlet.evaluation_mutation_preview(
  task_name text,
  workload_revision_hash text,
  subject_id text,
  source_table text,
  job_input jsonb,
  output jsonb,
  action jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  revision_definition jsonb;
  action_type text := COALESCE(action ->> 'type', '');
  action_payload jsonb := action;
  action_body jsonb;
  action_policy jsonb;
  action_schema jsonb;
  validation_input jsonb := COALESCE(job_input, '{}'::jsonb);
  validation_error text;
  target_row otlet.action_targets%ROWTYPE;
  target_name text;
  pinned_target_hash text;
  current_target_hash text;
  typed_input jsonb;
  before_row jsonb;
  normalized_changes jsonb;
  proposed_row jsonb;
  changed_columns name[];
  json_pairs text;
BEGIN
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = evaluation_mutation_preview.task_name
    AND revision.workload_revision_hash = evaluation_mutation_preview.workload_revision_hash;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'non_authoritative', true,
      'error', 'evaluation workload revision is missing'
    );
  END IF;

  action_policy := revision_definition #> ARRAY[
    'action_policies', action_type, 'authority'
  ];
  action_schema := revision_definition #> ARRAY[
    'action_policies', action_type, 'schema'
  ];
  action_body := CASE
    WHEN jsonb_typeof(action_payload -> 'body') = 'object'
      THEN action_payload -> 'body'
    ELSE '{}'::jsonb
  END;
  target_name := action_policy ->> 'target_name';
  pinned_target_hash := action_policy ->> 'target_contract_hash';

  IF evaluation_mutation_preview.source_table IS NOT NULL THEN
    validation_input := validation_input || jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object('table', evaluation_mutation_preview.source_table)
    );
  END IF;
  IF action_type IS DISTINCT FROM 'update_row' THEN
    validation_error := 'action is not update_row';
  ELSIF jsonb_typeof(action_policy) IS DISTINCT FROM 'object'
     OR action_policy ->> 'origin' IS DISTINCT FROM 'workflow'
     OR COALESCE((action_policy ->> 'enabled')::boolean, false) IS NOT TRUE
     OR target_name IS NULL THEN
    validation_error := 'update_row has no enabled registered workflow target';
  ELSIF NULLIF(action_body ->> 'target', '') IS NOT NULL
     AND action_body ->> 'target' IS DISTINCT FROM target_name THEN
    validation_error := 'update_row target does not match workflow authority';
  ELSE
    action_payload := jsonb_set(
      action_payload,
      '{body,target}',
      to_jsonb(target_name),
      true
    );
    action_body := action_payload -> 'body';
    validation_error := otlet.action_validation_error(
      action_payload,
      evaluation_mutation_preview.output,
      evaluation_mutation_preview.subject_id,
      validation_input,
      COALESCE(action_schema, 'null'::jsonb)
    );
  END IF;

  IF target_name IS NOT NULL THEN
    BEGIN
      current_target_hash := otlet.action_target_contract_hash(target_name);
    EXCEPTION WHEN OTHERS THEN
      validation_error := COALESCE(validation_error, 'registered action target is unavailable');
    END;
  END IF;
  IF validation_error IS NULL THEN
    SELECT * INTO target_row
    FROM otlet.action_targets target
    WHERE target.name = target_name;
    validation_error := otlet.action_target_validation_error(target_name);
  END IF;

  IF validation_error IS NULL THEN
    SELECT
      array_agg(key::name ORDER BY key),
      string_agg(format('%L, to_jsonb(p.%I)', key, key), ', ' ORDER BY key)
    INTO changed_columns, json_pairs
    FROM jsonb_object_keys(action_body -> 'changes') key;
    typed_input := jsonb_build_object(
      target_row.identity_column::text,
      action_body -> 'identity'
    ) || (action_body -> 'changes');
    BEGIN
      EXECUTE format(
        'SELECT to_jsonb(t), jsonb_build_object(%s) '
        'FROM %s t '
        'CROSS JOIN LATERAL jsonb_populate_record(NULL::%s, $1) p '
        'WHERE t.%I = p.%I',
        json_pairs,
        target_row.target_table,
        target_row.target_table,
        target_row.identity_column,
        target_row.identity_column
      )
      INTO before_row, normalized_changes
      USING typed_input;
    EXCEPTION WHEN OTHERS THEN
      validation_error := otlet.action_execution_error(SQLSTATE);
    END;
    IF validation_error IS NULL AND before_row IS NULL THEN
      validation_error := 'action target row does not exist';
    ELSIF validation_error IS NULL THEN
      proposed_row := before_row || normalized_changes;
    END IF;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'non_authoritative', true,
    'target_name', target_name,
    'pinned_target_contract_hash', pinned_target_hash,
    'current_target_contract_hash', current_target_hash,
    'target_contract_matches',
      pinned_target_hash IS NOT NULL AND pinned_target_hash = current_target_hash,
    'identity_hash', CASE
      WHEN action_body ? 'identity'
        THEN otlet.identity_hash('action_identity', action_body -> 'identity')
    END,
    'changed_columns', to_jsonb(COALESCE(changed_columns, ARRAY[]::name[])),
    'before_hash', CASE
      WHEN before_row IS NOT NULL THEN otlet.identity_hash('mutation_row', before_row)
    END,
    'result_hash', CASE
      WHEN proposed_row IS NOT NULL THEN otlet.identity_hash('mutation_row', proposed_row)
    END,
    'error', validation_error
  ));
END;
$$;

CREATE FUNCTION otlet.start_replay_evaluation(
  contract_hash text,
  case_hashes text[],
  run_key text,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  policy otlet.production_policy%ROWTYPE;
  normalized_case_hashes text[];
  case_count integer;
  requested_jobs integer;
  requested_bytes bigint;
  largest_input bigint;
  definition jsonb;
  run_hash text;
  existing_run otlet.evaluation_runs%ROWTYPE;
  case_row otlet.evaluation_cases%ROWTYPE;
  variant text;
  revision_hash text;
  saved_job_id bigint;
  requested_model record;
  existing_jobs bigint;
  existing_bytes bigint;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF COALESCE(start_replay_evaluation.run_key, '')
       !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' THEN
    RAISE EXCEPTION 'otlet evaluation run key is invalid';
  END IF;
  IF NULLIF(btrim(start_replay_evaluation.reason), '') IS NULL
     OR octet_length(start_replay_evaluation.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet evaluation run reason is required and bounded';
  END IF;
  IF cardinality(start_replay_evaluation.case_hashes) IS NULL
     OR cardinality(start_replay_evaluation.case_hashes) = 0 THEN
    RAISE EXCEPTION 'otlet evaluation run requires at least one case';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(start_replay_evaluation.case_hashes) hash
    WHERE hash !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ) THEN
    RAISE EXCEPTION 'otlet evaluation case hash is invalid';
  END IF;

  SELECT array_agg(DISTINCT hash ORDER BY hash), count(DISTINCT hash)::integer
  INTO normalized_case_hashes, case_count
  FROM unnest(start_replay_evaluation.case_hashes) hash;
  IF case_count IS DISTINCT FROM cardinality(start_replay_evaluation.case_hashes) THEN
    RAISE EXCEPTION 'otlet evaluation case hashes must be unique';
  END IF;

  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = start_replay_evaluation.contract_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload acceptance contract does not exist';
  END IF;

  definition := jsonb_build_object(
    'format', 'otlet.evaluation.run.v1',
    'contract_hash', contract.contract_hash,
    'task_name', contract.task_name,
    'baseline_workload_revision_hash', contract.baseline_workload_revision_hash,
    'candidate_workload_revision_hash', contract.candidate_workload_revision_hash,
    'run_key', start_replay_evaluation.run_key,
    'case_hashes', to_jsonb(normalized_case_hashes),
    'reason', btrim(start_replay_evaluation.reason)
  );
  run_hash := otlet.identity_hash('evaluation_run', definition);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_evaluation_run:' || contract.contract_hash || ':' || start_replay_evaluation.run_key,
    0
  ));
  SELECT * INTO existing_run
  FROM otlet.evaluation_runs stored
  WHERE stored.contract_hash = contract.contract_hash
    AND stored.run_key = start_replay_evaluation.run_key;
  IF FOUND THEN
    IF existing_run.run_hash IS DISTINCT FROM run_hash THEN
      RAISE EXCEPTION 'otlet evaluation run key already has a different definition';
    END IF;
    RETURN existing_run.run_hash;
  END IF;

  SELECT * INTO policy
  FROM otlet.production_policy stored
  WHERE stored.name = 'default'
  FOR UPDATE;
  requested_jobs := case_count * 2;
  IF requested_jobs > policy.max_admission_rows THEN
    RAISE EXCEPTION 'otlet evaluation run exceeds the admission row cap';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_workload_revision:' || contract.task_name, 0)
  );
  PERFORM 1
  FROM otlet.tasks task
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  WHERE task.name = contract.task_name
    AND task.lifecycle_state = 'active'
  FOR UPDATE OF task, head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation task must be active';
  END IF;

  IF (
    SELECT count(*)
    FROM otlet.evaluation_cases evaluation_case
    WHERE evaluation_case.case_hash = ANY(normalized_case_hashes)
      AND evaluation_case.task_name = contract.task_name
  ) IS DISTINCT FROM case_count::bigint THEN
    RAISE EXCEPTION 'otlet evaluation cases must all belong to contract task %',
      contract.task_name;
  END IF;
  SELECT
    COALESCE(sum(octet_length(evaluation_case.shaped_input::text)), 0) * 2,
    COALESCE(max(octet_length(evaluation_case.shaped_input::text)), 0)
  INTO requested_bytes, largest_input
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(normalized_case_hashes);
  IF largest_input > policy.max_input_bytes_per_job THEN
    RAISE EXCEPTION 'otlet evaluation shaped snapshot exceeds the per-job byte cap';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  SELECT COALESCE(sum(octet_length(job.input::text)), 0)
  INTO existing_bytes
  FROM otlet.jobs job
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name
  WHERE job.status = 'queued'
    AND CASE job.execution_mode
      WHEN 'evaluation' THEN true
      ELSE job.workload_revision_hash = head.active_workload_revision_hash
    END;
  IF existing_bytes + requested_bytes > policy.max_queued_input_bytes_total THEN
    RAISE EXCEPTION 'otlet evaluation run exceeds the total queued-input byte cap';
  END IF;

  FOR requested_model IN
    WITH requested_revisions(workload_revision_hash) AS (
      VALUES
        (contract.baseline_workload_revision_hash),
        (contract.candidate_workload_revision_hash)
    ), revisions AS (
      SELECT revision.definition #>> '{models,direct,name}' AS model_name
      FROM requested_revisions requested
      JOIN otlet.workload_revisions revision
        ON revision.workload_revision_hash = requested.workload_revision_hash
      WHERE revision.task_name = contract.task_name
    )
    SELECT
      revision.model_name,
      count(*)::bigint * case_count AS jobs,
      count(*)::bigint * (requested_bytes / 2) AS bytes
    FROM revisions revision
    GROUP BY revision.model_name
  LOOP
    SELECT
      count(*),
      COALESCE(sum(octet_length(job.input::text)), 0)
    INTO existing_jobs, existing_bytes
    FROM otlet.jobs job
    JOIN otlet.workload_revisions revision
      ON revision.task_name = job.task_name
     AND revision.workload_revision_hash = job.workload_revision_hash
    LEFT JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name
    WHERE job.status = 'queued'
      AND CASE job.execution_mode
        WHEN 'evaluation' THEN true
        ELSE job.workload_revision_hash = head.active_workload_revision_hash
      END
      AND COALESCE(
        job.routed_model_name,
        revision.definition #>> '{models,direct,name}'
      ) = requested_model.model_name;
    IF existing_jobs + requested_model.jobs > policy.max_queued_jobs_per_model THEN
      RAISE EXCEPTION 'otlet evaluation run exceeds model % queue depth',
        requested_model.model_name;
    END IF;
    IF existing_bytes + requested_model.bytes > policy.max_queued_input_bytes_per_model THEN
      RAISE EXCEPTION 'otlet evaluation run exceeds model % queued-input byte cap',
        requested_model.model_name;
    END IF;
  END LOOP;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.evaluation_runs (
    run_hash,
    contract_hash,
    task_name,
    baseline_workload_revision_hash,
    candidate_workload_revision_hash,
    run_key,
    case_hashes,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    run_hash,
    contract.contract_hash,
    contract.task_name,
    contract.baseline_workload_revision_hash,
    contract.candidate_workload_revision_hash,
    start_replay_evaluation.run_key,
    normalized_case_hashes,
    definition,
    btrim(start_replay_evaluation.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );

  FOR case_row IN
    SELECT *
    FROM otlet.evaluation_cases evaluation_case
    WHERE evaluation_case.case_hash = ANY(normalized_case_hashes)
    ORDER BY evaluation_case.case_hash
  LOOP
    FOREACH variant IN ARRAY ARRAY['baseline', 'candidate'] LOOP
      revision_hash := CASE variant
        WHEN 'baseline' THEN contract.baseline_workload_revision_hash
        ELSE contract.candidate_workload_revision_hash
      END;
      INSERT INTO otlet.jobs (
        task_name,
        workload_revision_hash,
        subject_id,
        input,
        execution_mode
      ) VALUES (
        contract.task_name,
        revision_hash,
        case_row.subject_id,
        case_row.shaped_input,
        'evaluation'
      )
      RETURNING id INTO saved_job_id;

      INSERT INTO otlet.evaluation_executions (
        run_hash,
        case_hash,
        variant,
        workload_revision_hash,
        job_id
      ) VALUES (
        run_hash,
        case_row.case_hash,
        variant,
        revision_hash,
        saved_job_id
      );
    END LOOP;
  END LOOP;
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  PERFORM otlet.wake_worker();
  RETURN run_hash;
END;
$$;

CREATE FUNCTION otlet.record_evaluation_result(
  job_id bigint,
  output_id bigint,
  receipt_id bigint,
  output jsonb,
  actions jsonb
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  execution otlet.evaluation_executions%ROWTYPE;
  evaluation_case otlet.evaluation_cases%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  receipt_row otlet.inference_receipts%ROWTYPE;
  stored_output jsonb;
  revision_definition jsonb;
  decision_contract jsonb;
  answer_field text;
  confidence_field text;
  observed_answer text;
  observed_confidence text;
  decision_diff jsonb;
  approval_diff jsonb;
  mutation_diffs jsonb := '[]'::jsonb;
  action jsonb;
  action_type text;
  action_policy jsonb;
  action_schema jsonb;
  normalized_action jsonb;
  validation_input jsonb;
  validation_error text;
  proposed_action_types text[] := ARRAY[]::text[];
  valid_action_types text[] := ARRAY[]::text[];
  expected_action_present boolean;
  expected_requires_approval boolean := false;
  matches_expected boolean;
  output_hash text;
  actions_hash text;
  result_definition jsonb;
  result_hash text;
  existing_hash text;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  SELECT * INTO execution
  FROM otlet.evaluation_executions stored
  WHERE stored.job_id = record_evaluation_result.job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation execution does not exist for job %',
      record_evaluation_result.job_id;
  END IF;

  SELECT * INTO job_row
  FROM otlet.jobs job
  WHERE job.id = record_evaluation_result.job_id
    AND job.execution_mode = 'evaluation';
  SELECT evaluation_output.output
  INTO stored_output
  FROM otlet.outputs evaluation_output
  WHERE evaluation_output.id = record_evaluation_result.output_id
    AND evaluation_output.job_id = record_evaluation_result.job_id
    AND evaluation_output.receipt_id = record_evaluation_result.receipt_id;
  IF job_row.id IS NULL OR NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation terminal evidence is inconsistent';
  END IF;
  SELECT * INTO receipt_row
  FROM otlet.inference_receipts receipt
  WHERE receipt.id = record_evaluation_result.receipt_id
    AND receipt.job_id = record_evaluation_result.job_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation receipt is inconsistent';
  END IF;
  IF receipt_row.output_hash IS DISTINCT FROM
       otlet.portable_json_hash(record_evaluation_result.output)
     OR receipt_row.actions_hash IS DISTINCT FROM
       otlet.portable_json_hash(COALESCE(record_evaluation_result.actions, '[]'::jsonb)) THEN
    RAISE EXCEPTION 'otlet evaluation result envelope does not match its receipt';
  END IF;
  stored_output := record_evaluation_result.output;

  SELECT * INTO evaluation_case
  FROM otlet.evaluation_cases stored
  WHERE stored.case_hash = execution.case_hash;
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = execution.workload_revision_hash
    AND revision.task_name = job_row.task_name;
  IF evaluation_case.case_hash IS NULL OR NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation case or workload revision is missing';
  END IF;

  IF jsonb_typeof(COALESCE(record_evaluation_result.actions, '[]'::jsonb))
       IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet evaluation actions must be an array';
  END IF;
  decision_contract := revision_definition #> '{task,decision_contract}';
  answer_field := COALESCE(NULLIF(decision_contract ->> 'answer_field', ''), 'match');
  confidence_field := COALESCE(
    NULLIF(decision_contract ->> 'confidence_field', ''),
    'confidence'
  );
  observed_answer := stored_output ->> answer_field;
  observed_confidence := stored_output ->> confidence_field;
  decision_diff := jsonb_build_object(
    'expected_answer', evaluation_case.expected_answer,
    'observed_answer', to_jsonb(observed_answer),
    'answer_matches', observed_answer IS NOT DISTINCT FROM evaluation_case.expected_answer,
    'expected_confidence', evaluation_case.expected_confidence,
    'observed_confidence', to_jsonb(observed_confidence),
    'confidence_matches',
      observed_confidence IS NOT DISTINCT FROM evaluation_case.expected_confidence,
    'non_authoritative', true
  );

  validation_input := job_row.input;
  IF evaluation_case.source_table IS NOT NULL THEN
    validation_input := validation_input || jsonb_build_object(
      '_otlet_mvcc', jsonb_build_object('table', evaluation_case.source_table)
    );
  END IF;
  FOR action IN
    SELECT item.value
    FROM jsonb_array_elements(COALESCE(record_evaluation_result.actions, '[]'::jsonb))
      WITH ORDINALITY item(value, ordinality)
    ORDER BY item.ordinality
  LOOP
    action_type := COALESCE(action ->> 'type', 'invalid');
    proposed_action_types := array_append(proposed_action_types, action_type);
    action_policy := revision_definition #> ARRAY[
      'action_policies', action_type, 'authority'
    ];
    action_schema := revision_definition #> ARRAY[
      'action_policies', action_type, 'schema'
    ];
    normalized_action := action;
    validation_error := CASE
      WHEN NOT COALESCE(decision_contract -> 'action_types', '[]'::jsonb) ? action_type
        THEN 'action type is not allowed by workflow'
      ELSE NULL
    END;
    IF validation_error IS NULL AND action_type = 'update_row' THEN
      IF action_policy ->> 'origin' IS DISTINCT FROM 'workflow'
         OR COALESCE((action_policy ->> 'enabled')::boolean, false) IS NOT TRUE
         OR NULLIF(action_policy ->> 'target_name', '') IS NULL THEN
        validation_error := 'update_row has no enabled registered workflow target';
      ELSIF NULLIF(action #>> '{body,target}', '') IS NOT NULL
         AND action #>> '{body,target}' IS DISTINCT FROM action_policy ->> 'target_name' THEN
        validation_error := 'update_row target does not match workflow authority';
      ELSE
        normalized_action := jsonb_set(
          action,
          '{body,target}',
          to_jsonb(action_policy ->> 'target_name'),
          true
        );
      END IF;
    END IF;
    IF validation_error IS NULL THEN
      validation_error := otlet.action_validation_error(
        normalized_action,
        stored_output,
        job_row.subject_id,
        validation_input,
        COALESCE(action_schema, 'null'::jsonb)
      );
    END IF;
    IF validation_error IS NULL THEN
      valid_action_types := array_append(valid_action_types, action_type);
      IF action_type = evaluation_case.expected_action_type THEN
        expected_requires_approval := COALESCE(
          (action_schema ->> 'requires_approval')::boolean,
          false
        );
      END IF;
    END IF;
    IF action_type = 'update_row' THEN
      mutation_diffs := mutation_diffs || jsonb_build_array(
        otlet.evaluation_mutation_preview(
          job_row.task_name,
          job_row.workload_revision_hash,
          job_row.subject_id,
          evaluation_case.source_table,
          job_row.input,
          stored_output,
          action
        )
      );
    END IF;
  END LOOP;

  expected_action_present := evaluation_case.expected_action_type = ANY(valid_action_types);
  matches_expected := observed_answer IS NOT DISTINCT FROM evaluation_case.expected_answer
    AND observed_confidence IS NOT DISTINCT FROM evaluation_case.expected_confidence
    AND expected_action_present;
  approval_diff := jsonb_build_object(
    'expected_action_type', evaluation_case.expected_action_type,
    'proposed_action_types', to_jsonb(proposed_action_types),
    'valid_action_types', to_jsonb(valid_action_types),
    'expected_action_present', expected_action_present,
    'requires_approval', expected_requires_approval,
    'recommendation', CASE WHEN matches_expected THEN 'approve' ELSE 'reject' END,
    'matches_expected', matches_expected,
    'non_authoritative', true
  );

  output_hash := receipt_row.output_hash;
  actions_hash := receipt_row.actions_hash;
  result_definition := jsonb_build_object(
    'format', 'otlet.evaluation.result.v1',
    'run_hash', execution.run_hash,
    'case_hash', execution.case_hash,
    'variant', execution.variant,
    'job_id', job_row.id,
    'output_id', record_evaluation_result.output_id,
    'receipt_id', record_evaluation_result.receipt_id,
    'output_hash', output_hash,
    'actions_hash', actions_hash,
    'decision_diff', decision_diff,
    'approval_diff', approval_diff,
    'mutation_diffs', mutation_diffs
  );
  result_hash := otlet.identity_hash('evaluation_result', result_definition);

  SELECT stored.result_hash
  INTO existing_hash
  FROM otlet.evaluation_results stored
  WHERE stored.job_id = job_row.id;
  IF FOUND THEN
    IF existing_hash IS DISTINCT FROM result_hash THEN
      RAISE EXCEPTION 'otlet evaluation job has conflicting terminal evidence';
    END IF;
    RETURN existing_hash;
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.evaluation_results (
    result_hash,
    run_hash,
    case_hash,
    variant,
    job_id,
    output_id,
    receipt_id,
    output_hash,
    actions_hash,
    decision_diff,
    approval_diff,
    mutation_diffs,
    definition
  ) VALUES (
    result_hash,
    execution.run_hash,
    execution.case_hash,
    execution.variant,
    job_row.id,
    record_evaluation_result.output_id,
    record_evaluation_result.receipt_id,
    output_hash,
    actions_hash,
    decision_diff,
    approval_diff,
    mutation_diffs,
    result_definition
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  RETURN result_hash;
END;
$$;

CREATE VIEW otlet.evaluation_case_status AS
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
  evaluation_case.created_at
FROM otlet.evaluation_cases evaluation_case;

CREATE VIEW otlet.evaluation_replay_status AS
SELECT
  run.run_hash,
  run.contract_hash,
  run.task_name,
  run.run_key,
  run.baseline_workload_revision_hash,
  run.candidate_workload_revision_hash,
  evaluation_case.case_hash,
  evaluation_case.label_id,
  evaluation_case.subject_id,
  evaluation_case.shaped_input_hash,
  evaluation_case.expected_answer,
  evaluation_case.expected_confidence,
  evaluation_case.expected_action_type,
  otlet.evaluation_revision_diff(
    run.task_name,
    run.baseline_workload_revision_hash,
    run.candidate_workload_revision_hash
  ) AS revision_diff,
  baseline_execution.job_id AS baseline_job_id,
  baseline_job.status AS baseline_job_status,
  baseline_job.error AS baseline_job_error,
  baseline_receipts.receipts AS baseline_receipts,
  baseline_result.result_hash AS baseline_result_hash,
  baseline_result.output_hash AS baseline_output_hash,
  baseline_result.actions_hash AS baseline_actions_hash,
  baseline_result.decision_diff AS baseline_decision_diff,
  baseline_result.approval_diff AS baseline_approval_diff,
  baseline_result.mutation_diffs AS baseline_mutation_diffs,
  candidate_execution.job_id AS candidate_job_id,
  candidate_job.status AS candidate_job_status,
  candidate_job.error AS candidate_job_error,
  candidate_receipts.receipts AS candidate_receipts,
  candidate_result.result_hash AS candidate_result_hash,
  candidate_result.output_hash AS candidate_output_hash,
  candidate_result.actions_hash AS candidate_actions_hash,
  candidate_result.decision_diff AS candidate_decision_diff,
  candidate_result.approval_diff AS candidate_approval_diff,
  candidate_result.mutation_diffs AS candidate_mutation_diffs,
  baseline_execution.case_hash = candidate_execution.case_hash
    AND baseline_job.input = candidate_job.input AS same_population,
  true AS non_authoritative,
  run.authenticated_role_name AS started_by,
  run.active_role_name AS started_as,
  run.reason,
  run.created_at
FROM otlet.evaluation_runs run
JOIN otlet.evaluation_cases evaluation_case
  ON evaluation_case.case_hash = ANY(run.case_hashes)
JOIN otlet.evaluation_executions baseline_execution
  ON baseline_execution.run_hash = run.run_hash
 AND baseline_execution.case_hash = evaluation_case.case_hash
 AND baseline_execution.variant = 'baseline'
JOIN otlet.jobs baseline_job ON baseline_job.id = baseline_execution.job_id
LEFT JOIN LATERAL (
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'receipt_id', receipt.id,
      'attempt_index', receipt.attempt_index,
      'selection_role', receipt.selection_role,
      'selection_status', receipt.selection_status,
      'selection_reason', receipt.selection_reason,
      'model_name', receipt.model_name,
      'model_artifact_hash', receipt.model_artifact_hash,
      'runtime_name', receipt.runtime_name,
      'runtime_endpoint', receipt.runtime_endpoint,
      'runtime_options_hash', receipt.runtime_options_hash,
      'prompt_hash', receipt.prompt_hash,
      'input_hash', receipt.input_hash,
      'output_schema_hash', receipt.output_schema_hash,
      'output_hash', receipt.output_hash,
      'actions_hash', receipt.actions_hash,
      'schema_validation_status', receipt.schema_validation_status,
      'status', receipt.status
    ) ORDER BY receipt.attempt_index, receipt.id
  ), '[]'::jsonb) AS receipts
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = baseline_job.id
) baseline_receipts ON true
LEFT JOIN otlet.evaluation_results baseline_result
  ON baseline_result.run_hash = baseline_execution.run_hash
 AND baseline_result.case_hash = baseline_execution.case_hash
 AND baseline_result.variant = baseline_execution.variant
JOIN otlet.evaluation_executions candidate_execution
  ON candidate_execution.run_hash = run.run_hash
 AND candidate_execution.case_hash = evaluation_case.case_hash
 AND candidate_execution.variant = 'candidate'
JOIN otlet.jobs candidate_job ON candidate_job.id = candidate_execution.job_id
LEFT JOIN LATERAL (
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'receipt_id', receipt.id,
      'attempt_index', receipt.attempt_index,
      'selection_role', receipt.selection_role,
      'selection_status', receipt.selection_status,
      'selection_reason', receipt.selection_reason,
      'model_name', receipt.model_name,
      'model_artifact_hash', receipt.model_artifact_hash,
      'runtime_name', receipt.runtime_name,
      'runtime_endpoint', receipt.runtime_endpoint,
      'runtime_options_hash', receipt.runtime_options_hash,
      'prompt_hash', receipt.prompt_hash,
      'input_hash', receipt.input_hash,
      'output_schema_hash', receipt.output_schema_hash,
      'output_hash', receipt.output_hash,
      'actions_hash', receipt.actions_hash,
      'schema_validation_status', receipt.schema_validation_status,
      'status', receipt.status
    ) ORDER BY receipt.attempt_index, receipt.id
  ), '[]'::jsonb) AS receipts
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = candidate_job.id
) candidate_receipts ON true
LEFT JOIN otlet.evaluation_results candidate_result
  ON candidate_result.run_hash = candidate_execution.run_hash
 AND candidate_result.case_hash = candidate_execution.case_hash
 AND candidate_result.variant = candidate_execution.variant;

CREATE VIEW otlet.audit_evaluation_replay_export AS
SELECT
  status.run_hash,
  status.contract_hash,
  status.task_name,
  status.run_key,
  status.baseline_workload_revision_hash,
  status.candidate_workload_revision_hash,
  status.case_hash,
  status.label_id,
  status.subject_id,
  status.shaped_input_hash,
  status.expected_answer,
  status.expected_confidence,
  status.expected_action_type,
  status.revision_diff,
  status.baseline_job_id,
  status.baseline_job_status,
  status.baseline_job_error,
  status.baseline_receipts,
  status.baseline_result_hash,
  status.baseline_output_hash,
  status.baseline_actions_hash,
  status.baseline_decision_diff,
  status.baseline_approval_diff,
  status.baseline_mutation_diffs,
  status.candidate_job_id,
  status.candidate_job_status,
  status.candidate_job_error,
  status.candidate_receipts,
  status.candidate_result_hash,
  status.candidate_output_hash,
  status.candidate_actions_hash,
  status.candidate_decision_diff,
  status.candidate_approval_diff,
  status.candidate_mutation_diffs,
  status.same_population,
  status.non_authoritative,
  status.started_by,
  status.started_as,
  status.reason,
  status.created_at
FROM otlet.evaluation_replay_status status;

REVOKE ALL ON TABLE otlet.evaluation_cases FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_runs FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_executions FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_results FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_case_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_replay_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_evaluation_replay_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evaluation_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_case() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_run() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_execution() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_result() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_evaluation_job_mode() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_evaluation_case(bigint, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evaluation_revision_diff(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evaluation_mutation_preview(
  text, text, text, text, jsonb, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.start_replay_evaluation(
  text, text[], text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_evaluation_result(
  bigint, bigint, bigint, jsonb, jsonb
) FROM PUBLIC;
