\echo '[label-provenance] Proving label provenance and quality'

CREATE TEMP TABLE label_quality_proof (
  original_label_id bigint NOT NULL,
  original_action_id bigint NOT NULL,
  original_case_hash text NOT NULL,
  original_run_hash text NOT NULL,
  contract_hash text NOT NULL,
  conflict_label_id bigint,
  intermediate_label_id bigint,
  replacement_label_id bigint,
  replacement_case_hash text,
  replacement_run_hash text,
  fresh_label_id bigint,
  fresh_case_hash text,
  fresh_run_hash text,
  conflict_detected boolean NOT NULL DEFAULT false,
  conflict_registration_blocked boolean NOT NULL DEFAULT false,
  conflict_promotion_blocked boolean NOT NULL DEFAULT false,
  nonpromotion_allowed boolean NOT NULL DEFAULT false,
  conflict_resolved boolean NOT NULL DEFAULT false,
  adjudication_immutable boolean NOT NULL DEFAULT false,
  confidence_bounded boolean NOT NULL DEFAULT false,
  same_snapshot_replaced boolean NOT NULL DEFAULT false,
  superseded_promotion_blocked boolean NOT NULL DEFAULT false,
  update_revert_stale boolean NOT NULL DEFAULT false,
  stale_run_blocked boolean NOT NULL DEFAULT false,
  stale_promotion_blocked boolean NOT NULL DEFAULT false,
  fresh_successor_eligible boolean NOT NULL DEFAULT false,
  fresh_promotion_succeeded boolean NOT NULL DEFAULT false,
  cleanup_chain_safe boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO label_quality_proof (
  original_label_id,
  original_action_id,
  original_case_hash,
  original_run_hash,
  contract_hash
)
SELECT
  population_case.label_id,
  population_case.action_id,
  population_case.case_hash,
  proof.qualification_run_hash,
  proof.contract_hash
FROM evaluation_population_cases population_case
CROSS JOIN evaluation_population_lineage_proof proof
WHERE population_case.population_kind = 'qualification';

SELECT original_action_id AS action_id
FROM label_quality_proof \gset
SELECT label.id AS conflict_label_id
FROM otlet.label_action(
  :action_id,
  expected_answer => 'reject',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Independent conflicting label',
  label_source => 'manual_correction'
) label \gset
UPDATE label_quality_proof
SET conflict_label_id = :'conflict_label_id'::bigint;

SELECT pg_temp.assert_true(
  quality.authored_by = session_user
    AND quality.authored_as = session_user
    AND quality.label_revision = 2
    AND quality.adjudication_state = 'pending'
    AND quality.label_confidence IS NULL,
  'label author, role, revision, or pending state was not captured'
)
FROM label_quality_proof proof
JOIN otlet.eval_label_quality_status quality
  ON quality.label_id = proof.conflict_label_id;

UPDATE label_quality_proof proof
SET conflict_detected = (
  SELECT count(*) = 2
    AND bool_and(quality.contradictory)
    AND bool_and(NOT quality.qualification_eligible)
  FROM otlet.eval_label_quality_status quality
  WHERE quality.label_id IN (
    proof.original_label_id,
    proof.conflict_label_id
  )
);

DO $body$
DECLARE
  proof label_quality_proof%ROWTYPE;
  events_before bigint;
BEGIN
  SELECT * INTO proof FROM label_quality_proof;
  BEGIN
    PERFORM otlet.register_evaluation_case(
      proof.conflict_label_id,
      'qualification',
      'Conflicting label rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet qualification evaluation label is not eligible' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof SET conflict_registration_blocked = true;

  SELECT count(*) INTO events_before
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = proof.contract_hash;
  BEGIN
    PERFORM otlet.record_workload_promotion_decision(
      contract_hash => proof.contract_hash,
      outcome => 'promote',
      evidence_hash => otlet.identity_hash(
        'label_quality_conflict',
        jsonb_build_object('run_hash', proof.original_run_hash)
      ),
      evidence_summary => '{"status":"conflict_probe"}'::jsonb,
      reason => 'Conflicting label promotion rejection probe',
      qualification_run_hashes => ARRAY[proof.original_run_hash]
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion references an ineligible evaluation label' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof
  SET conflict_promotion_blocked = (
    SELECT count(*) = events_before
    FROM otlet.workload_acceptance_events event
    WHERE event.contract_hash = proof.contract_hash
  );

  PERFORM otlet.record_workload_promotion_decision(
    contract_hash => proof.contract_hash,
    outcome => 'defer',
    evidence_hash => otlet.identity_hash(
      'label_quality_defer',
      jsonb_build_object('run_hash', proof.original_run_hash)
    ),
    evidence_summary => '{"status":"conflict_deferred"}'::jsonb,
    reason => 'Defer while label conflict is unresolved',
    qualification_run_hashes => ARRAY[proof.original_run_hash]
  );
  UPDATE label_quality_proof SET nonpromotion_allowed = true;
END
$body$;

SELECT otlet.adjudicate_eval_label(
  conflict_label_id,
  'rejected',
  0.85,
  'Rejected dissenting label after adjudication'
)
FROM label_quality_proof \g /dev/null

UPDATE label_quality_proof proof
SET conflict_resolved = (
  SELECT original.qualification_eligible
    AND NOT original.contradictory
    AND conflict.adjudication_state = 'rejected'
    AND NOT conflict.qualification_eligible
  FROM otlet.eval_label_quality_status original
  JOIN otlet.eval_label_quality_status conflict
    ON conflict.label_id = proof.conflict_label_id
  WHERE original.label_id = proof.original_label_id
);

SELECT otlet.record_workload_promotion_decision(
  contract_hash => proof.contract_hash,
  outcome => 'promote',
  evidence_hash => otlet.identity_hash(
    'label_quality_resolved',
    jsonb_build_object('run_hash', proof.original_run_hash)
  ),
  evidence_summary => '{"status":"conflict_resolved"}'::jsonb,
  reason => 'Promote after rejecting the conflicting label',
  qualification_run_hashes => ARRAY[proof.original_run_hash]
)
FROM label_quality_proof proof \g /dev/null

DO $body$
DECLARE
  proof label_quality_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM label_quality_proof;
  BEGIN
    PERFORM otlet.adjudicate_eval_label(
      proof.conflict_label_id,
      'accepted',
      0.90,
      'Conflicting adjudication rewrite probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation label adjudication conflicts with the stored decision' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    UPDATE otlet.eval_labels
    SET reason = 'Direct provenance rewrite probe'
    WHERE id = proof.conflict_label_id;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation label provenance is immutable' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof SET adjudication_immutable = true;

  BEGIN
    PERFORM otlet.adjudicate_eval_label(
      proof.original_label_id,
      'accepted',
      1.01,
      'Out-of-range confidence rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation label adjudication is invalid' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof SET confidence_bounded = true;
END
$body$;

SELECT original_action_id AS action_id
FROM label_quality_proof \gset
SELECT label.id AS intermediate_label_id
FROM otlet.label_action(
  :action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Uncased same-snapshot successor',
  label_source => 'manual_correction'
) label \gset
UPDATE label_quality_proof
SET intermediate_label_id = :'intermediate_label_id'::bigint;
SELECT otlet.adjudicate_eval_label(
  intermediate_label_id,
  'accepted',
  0.95,
  'Accepted uncased replacement for the original label',
  original_label_id
)
FROM label_quality_proof \g /dev/null

SELECT original_action_id AS action_id
FROM label_quality_proof \gset
SELECT label.id AS replacement_label_id
FROM otlet.label_action(
  :action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Accepted multi-hop same-snapshot successor',
  label_source => 'manual_correction'
) label \gset
UPDATE label_quality_proof
SET replacement_label_id = :'replacement_label_id'::bigint;
SELECT otlet.adjudicate_eval_label(
  replacement_label_id,
  'accepted',
  0.96,
  'Accepted replacement through an uncased predecessor',
  intermediate_label_id
)
FROM label_quality_proof \g /dev/null
UPDATE label_quality_proof proof
SET replacement_case_hash = otlet.register_evaluation_case(
  proof.replacement_label_id,
  'qualification',
  'Accepted same-snapshot successor case'
);
UPDATE label_quality_proof proof
SET same_snapshot_replaced = (
  SELECT replacement.lineage_hash = original.lineage_hash
    AND replacement.case_hash <> original.case_hash
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_cases intermediate_case
      WHERE intermediate_case.label_id = proof.intermediate_label_id
    )
    AND EXISTS (
      SELECT 1
      FROM otlet.eval_labels replacement_label
      WHERE replacement_label.id = proof.replacement_label_id
        AND replacement_label.supersedes_label_id = proof.intermediate_label_id
    )
  FROM otlet.evaluation_cases replacement
  JOIN otlet.evaluation_cases original
    ON original.case_hash = proof.original_case_hash
  WHERE replacement.case_hash = proof.replacement_case_hash
);

DO $body$
DECLARE
  proof label_quality_proof%ROWTYPE;
  events_before bigint;
BEGIN
  SELECT * INTO proof FROM label_quality_proof;
  SELECT count(*) INTO events_before
  FROM otlet.workload_acceptance_events event
  WHERE event.contract_hash = proof.contract_hash;
  BEGIN
    PERFORM otlet.record_workload_promotion_decision(
      contract_hash => proof.contract_hash,
      outcome => 'promote',
      evidence_hash => otlet.identity_hash(
        'label_quality_superseded',
        jsonb_build_object('run_hash', proof.original_run_hash)
      ),
      evidence_summary => '{"status":"superseded_probe"}'::jsonb,
      reason => 'Superseded historical run promotion rejection probe',
      qualification_run_hashes => ARRAY[proof.original_run_hash]
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion references an ineligible evaluation label' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof
  SET superseded_promotion_blocked = (
    SELECT count(*) = events_before
    FROM otlet.workload_acceptance_events event
    WHERE event.contract_hash = proof.contract_hash
  );
END
$body$;

CREATE FUNCTION pg_temp.complete_label_quality_run(expected_run_hash text) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  model_name text;
  claimed otlet.jobs%ROWTYPE;
  job_prompt_hash text;
  output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  actions jsonb;
BEGIN
  FOREACH model_name IN ARRAY ARRAY[
    'evaluation_population_baseline',
    'evaluation_population_candidate'
  ]
  LOOP
    SELECT * INTO claimed FROM otlet.claim_jobs(model_name, 1);
    IF NOT FOUND OR NOT EXISTS (
      SELECT 1
      FROM otlet.evaluation_executions execution
      WHERE execution.job_id = claimed.id
        AND execution.run_hash = complete_label_quality_run.expected_run_hash
    ) THEN
      RAISE EXCEPTION 'label quality replay job was not claimed from the expected run';
    END IF;
    actions := jsonb_build_array(jsonb_build_object(
      'type', 'update_row',
      'body', jsonb_build_object(
        'target', 'evaluation_population_target',
        'identity', claimed.subject_id,
        'changes', jsonb_build_object('review_state', 'label_quality')
      )
    ));
    SELECT otlet.portable_prompt_hash(
      revision.definition #>> '{task,instruction}',
      revision.definition #> '{task,output_schema}',
      claimed.input,
      revision.definition #> '{runtime,effective_options}',
      revision.definition #> '{task,decision_contract}'
    ) INTO job_prompt_hash
    FROM otlet.workload_revisions revision
    WHERE revision.workload_revision_hash = claimed.workload_revision_hash;
    PERFORM otlet.complete_job(
      job_id => claimed.id,
      output => output,
      raw_output => jsonb_build_object(
        'output', output,
        'actions', actions
      )::text,
      actions => actions,
      prompt_hash => job_prompt_hash,
      started_at => claimed.started_at,
      trace_summary => '{"schema_validation_status":"passed","generate_ms":5}'::jsonb,
      model_name => model_name,
      expected_claim_token => claimed.claim_token
    );
  END LOOP;
  IF (
    SELECT count(*)
    FROM otlet.evaluation_results result
    WHERE result.run_hash = complete_label_quality_run.expected_run_hash
  ) <> 2 THEN
    RAISE EXCEPTION 'label quality replay did not retain two results';
  END IF;
END
$function$;

UPDATE label_quality_proof proof
SET replacement_run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY[proof.replacement_case_hash],
  'label-quality-replacement',
  'Complete the same-snapshot replacement run'
);
SELECT pg_temp.complete_label_quality_run(replacement_run_hash)
FROM label_quality_proof;

UPDATE public.otlet_demo_evaluation_population
SET protected_note = 'CHANGED'
WHERE id = 'qualification-1';
UPDATE public.otlet_demo_evaluation_population
SET protected_note = 'DO_NOT_TOUCH'
WHERE id = 'qualification-1';

UPDATE label_quality_proof proof
SET update_revert_stale = (
  SELECT NOT quality.source_revision_current
    AND quality.exclusion_reason = 'stale_source_revision'
    AND NOT quality.qualification_eligible
  FROM otlet.eval_label_quality_status quality
  WHERE quality.label_id = proof.replacement_label_id
);

DO $body$
DECLARE
  proof label_quality_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM label_quality_proof;
  BEGIN
    PERFORM otlet.start_replay_evaluation(
      proof.contract_hash,
      ARRAY[proof.replacement_case_hash],
      'label-quality-stale-run',
      'Stale label run rejection probe'
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet qualification evaluation run contains an ineligible label' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof SET stale_run_blocked = true;

  BEGIN
    PERFORM otlet.record_workload_promotion_decision(
      contract_hash => proof.contract_hash,
      outcome => 'promote',
      evidence_hash => otlet.identity_hash(
        'label_quality_stale',
        jsonb_build_object('run_hash', proof.replacement_run_hash)
      ),
      evidence_summary => '{"status":"stale_probe"}'::jsonb,
      reason => 'Stale label promotion rejection probe',
      qualification_run_hashes => ARRAY[proof.replacement_run_hash]
    );
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet workload promotion references an ineligible evaluation label' THEN
      RAISE;
    END IF;
  END;
  UPDATE label_quality_proof SET stale_promotion_blocked = true;
END
$body$;

CREATE FUNCTION pg_temp.complete_label_quality_production(
  expected_subject text
) RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
  claimed otlet.jobs%ROWTYPE;
  selected_model_name text;
  saved_action_id bigint;
  output jsonb := '{"decision":"approve","confidence":"high"}'::jsonb;
  actions jsonb;
BEGIN
  SELECT * INTO claimed FROM otlet.claim_jobs(NULL, 1);
  IF NOT FOUND
     OR claimed.task_name <> 'evaluation_population_probe_task'
     OR claimed.subject_id <> complete_label_quality_production.expected_subject THEN
    RAISE EXCEPTION 'label quality production job was not claimed exactly once';
  END IF;
  SELECT CASE
    WHEN claimed.routed_model_name =
         revision.definition #>> '{selection,strong_model_name}'
      THEN revision.definition #>> '{models,strong,name}'
    WHEN claimed.routed_model_name =
         revision.definition #>> '{selection,cheap_model_name}'
      THEN revision.definition #>> '{models,cheap,name}'
    ELSE revision.definition #>> '{models,direct,name}'
  END
  INTO selected_model_name
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = claimed.workload_revision_hash;
  actions := jsonb_build_array(jsonb_build_object(
    'type', 'update_row',
      'body', jsonb_build_object(
        'target', 'evaluation_population_target',
        'identity', claimed.subject_id,
        'changes', jsonb_build_object('review_state', 'label_quality')
      )
  ));
  PERFORM otlet.complete_job(
    job_id => claimed.id,
    output => output,
    raw_output => jsonb_build_object('output', output, 'actions', actions)::text,
    actions => actions,
    started_at => claimed.started_at,
    trace_summary => '{"schema_validation_status":"passed","generate_ms":5}'::jsonb,
    model_name => selected_model_name,
    expected_claim_token => claimed.claim_token
  );
  SELECT action.id INTO saved_action_id
  FROM otlet.actions action
  WHERE action.job_id = claimed.id;
  RETURN saved_action_id;
END
$function$;

SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'evaluation_population_probe_task',
    'qualification-1'
  ) = 1,
  'fresh source revision did not queue one production job'
);
SELECT pg_temp.complete_label_quality_production('qualification-1')
  AS fresh_action_id \gset
SELECT label.id AS fresh_label_id
FROM otlet.label_action(
  :fresh_action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Fresh exact-source successor',
  label_source => 'manual_correction'
) label \gset
UPDATE label_quality_proof
SET fresh_label_id = :'fresh_label_id'::bigint;
SELECT otlet.adjudicate_eval_label(
  fresh_label_id,
  'accepted',
  0.98,
  'Accepted fresh-source successor',
  replacement_label_id
)
FROM label_quality_proof \g /dev/null
UPDATE label_quality_proof proof
SET fresh_case_hash = otlet.register_evaluation_case(
  proof.fresh_label_id,
  'qualification',
  'Accepted fresh-source successor case'
);
UPDATE label_quality_proof proof
SET fresh_successor_eligible = (
  SELECT quality.label_revision > replacement.label_revision
    AND quality.supersedes_label_id = proof.replacement_label_id
    AND quality.current_label
    AND quality.source_revision_current
    AND quality.qualification_eligible
    AND quality.label_confidence = 0.98
  FROM otlet.eval_label_quality_status quality
  JOIN otlet.eval_labels replacement ON replacement.id = proof.replacement_label_id
  WHERE quality.label_id = proof.fresh_label_id
);

UPDATE label_quality_proof proof
SET fresh_run_hash = otlet.start_replay_evaluation(
  proof.contract_hash,
  ARRAY[proof.fresh_case_hash],
  'label-quality-fresh',
  'Complete the fresh-label qualification run'
);
SELECT pg_temp.complete_label_quality_run(fresh_run_hash)
FROM label_quality_proof;
SELECT otlet.record_workload_promotion_decision(
  contract_hash => proof.contract_hash,
  outcome => 'promote',
  evidence_hash => otlet.identity_hash(
    'label_quality_fresh',
    jsonb_build_object('run_hash', proof.fresh_run_hash)
  ),
  evidence_summary => '{"status":"fresh_successor_complete"}'::jsonb,
  reason => 'Promote after fresh label replacement and replay',
  qualification_run_hashes => ARRAY[proof.fresh_run_hash]
)
FROM label_quality_proof proof \g /dev/null
UPDATE label_quality_proof SET fresh_promotion_succeeded = true;

INSERT INTO public.otlet_demo_evaluation_population
VALUES ('cleanup-1', 'qualification', 'pending', 'DO_NOT_TOUCH');
SELECT pg_temp.assert_true(
  otlet.run_task_subject(
    'evaluation_population_probe_task',
    'cleanup-1'
  ) = 1,
  'cleanup-series source did not queue one production job'
);
SELECT pg_temp.complete_label_quality_production('cleanup-1')
  AS cleanup_action_id \gset
SELECT label.id AS cleanup_first_label_id
FROM otlet.label_action(
  :cleanup_action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Cleanup chain predecessor',
  label_source => 'manual_correction'
) label \gset
SELECT otlet.adjudicate_eval_label(
  :'cleanup_first_label_id'::bigint,
  'accepted',
  0.90,
  'Accepted cleanup chain predecessor'
) \g /dev/null
SELECT label.id AS cleanup_second_label_id
FROM otlet.label_action(
  :cleanup_action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Cleanup chain successor',
  label_source => 'manual_correction'
) label \gset
SELECT otlet.adjudicate_eval_label(
  :'cleanup_second_label_id'::bigint,
  'accepted',
  0.91,
  'Accepted cleanup chain successor',
  :'cleanup_first_label_id'::bigint
) \g /dev/null

CREATE TEMP TABLE label_cleanup_chain ON COMMIT DROP AS
SELECT
  :'cleanup_first_label_id'::bigint AS first_label_id,
  :'cleanup_second_label_id'::bigint AS second_label_id;

ALTER TABLE otlet.eval_labels DISABLE TRIGGER eval_labels_c_adjudication;
UPDATE otlet.eval_labels label
SET created_at = label.created_at - interval '2 days',
    adjudicated_at = label.adjudicated_at - interval '2 days'
FROM label_cleanup_chain chain
WHERE label.id IN (chain.first_label_id, chain.second_label_id);
ALTER TABLE otlet.eval_labels ENABLE TRIGGER eval_labels_c_adjudication;
UPDATE otlet.production_policy
SET eval_label_retention = interval '1 day'
WHERE name = 'default';

DO $body$
DECLARE
  chain label_cleanup_chain%ROWTYPE;
  cleanup_run otlet.maintenance_runs%ROWTYPE;
  cleanup_run_id bigint;
  direct_delete_blocked boolean := false;
  truncate_blocked boolean := false;
  dry_count bigint;
  deleted_count bigint;
BEGIN
  SELECT * INTO chain FROM label_cleanup_chain;
  BEGIN
    DELETE FROM otlet.eval_labels
    WHERE id = chain.second_label_id;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation label history is cleanup-managed' THEN
      RAISE;
    END IF;
    direct_delete_blocked := true;
  END;
  BEGIN
    TRUNCATE otlet.eval_labels CASCADE;
    RAISE EXCEPTION 'negative probe unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet evaluation label history is cleanup-managed' THEN
      RAISE;
    END IF;
    truncate_blocked := true;
  END;
  dry_count := otlet.cleanup_eval_label_series(
    clock_timestamp() - interval '1 day',
    true
  );
  cleanup_run_id := otlet.create_maintenance_run('cleanup');
  cleanup_run := otlet.run_maintenance_slice(cleanup_run_id, 0);
  deleted_count := cleanup_run.changed_rows;
  IF dry_count <> 2
     OR deleted_count <> 2
     OR cleanup_run.control_state <> 'complete'
     OR cleanup_run.processed_items <> 1
     OR EXISTS (
       SELECT 1
       FROM otlet.eval_labels
       WHERE id IN (chain.first_label_id, chain.second_label_id)
     )
     OR NOT direct_delete_blocked
     OR NOT truncate_blocked THEN
    RAISE EXCEPTION
      'evaluation label series cleanup contract failed dry=% deleted=% direct=% truncate=% remaining=%',
      dry_count,
      deleted_count,
      direct_delete_blocked,
      truncate_blocked,
      (SELECT count(*) FROM otlet.eval_labels
       WHERE id IN (chain.first_label_id, chain.second_label_id));
  END IF;
  UPDATE label_quality_proof SET cleanup_chain_safe = true;
END
$body$;

SELECT label.id AS cleanup_third_label_id
FROM otlet.label_action(
  :cleanup_action_id,
  expected_answer => 'approve',
  expected_confidence => 'high',
  expected_action_type => 'update_row',
  reason => 'Cleanup revision non-reuse probe',
  label_source => 'manual_correction'
) label \gset
UPDATE label_quality_proof proof
SET cleanup_chain_safe = proof.cleanup_chain_safe
  AND EXISTS (
    SELECT 1
    FROM otlet.eval_labels label
    WHERE label.id = :'cleanup_third_label_id'::bigint
      AND label.label_revision = 3
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.eval_label_series_revisions revision
    WHERE revision.task_name = 'evaluation_population_probe_task'
      AND revision.source_table = 'public.otlet_demo_evaluation_population'
      AND revision.subject_id = 'cleanup-1'
      AND revision.last_revision = 3
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.eval_labels label
    WHERE label.id = proof.fresh_label_id
  );

CREATE TEMP TABLE label_provenance_quality_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  conflict_detected,
  conflict_registration_blocked,
  conflict_promotion_blocked,
  nonpromotion_allowed,
  conflict_resolved,
  adjudication_immutable,
  confidence_bounded,
  same_snapshot_replaced,
  superseded_promotion_blocked,
  update_revert_stale,
  stale_run_blocked,
  stale_promotion_blocked,
  fresh_successor_eligible,
  fresh_promotion_succeeded,
  cleanup_chain_safe,
  NOT pg_catalog.has_function_privilege(
    'public',
    'otlet.adjudicate_eval_label(bigint,text,numeric,text,bigint)',
    'EXECUTE'
  ),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.eval_label_quality_status', 'SELECT'
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS label_provenance_quality_contract
FROM label_quality_proof;

SELECT pg_temp.assert_true(
  label_provenance_quality_contract =
    't|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t',
  'label provenance quality contract mismatch: ' ||
    label_provenance_quality_contract
)
FROM label_provenance_quality_contract;

SELECT 'label_provenance_quality_contract=' ||
  label_provenance_quality_contract
FROM label_provenance_quality_contract;

SET LOCAL transaction_read_only = on;
SELECT count(*)
FROM otlet.eval_label_quality_status \g /dev/null
SELECT count(*)
FROM otlet.audit_eval_label_export \g /dev/null
