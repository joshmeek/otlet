log "Proving complete revision invalidation"

psql_exec -qAt <<'SQL'
BEGIN;

SELECT otlet.register_model(
  'revision_invalidation_model',
  '/tmp/revision-invalidation.gguf',
  repeat('8', 64),
  jsonb_build_object(
    'sha256', repeat('8', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'revision-invalidation',
    'quantization', 'none',
    'license', 'test'
  )
) \g /dev/null

CREATE TABLE public.revision_invalidation_source (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  review_reason text
);
INSERT INTO public.revision_invalidation_source
VALUES
  ('row-1', 'pending', NULL),
  ('row-2', 'pending', NULL),
  ('row-3', 'pending', NULL),
  ('row-4', 'pending', NULL),
  ('row-5', 'pending', NULL);

SELECT otlet.register_action_target(
  'revision_invalidation_target',
  'public.revision_invalidation_source'::regclass,
  'id',
  ARRAY['review_state', 'review_reason']::name[]
) \g /dev/null

SELECT otlet.create_watch(
  'revision_invalidation_probe',
  'row',
  'Return a decision and, when useful, one update_row action.',
  '{"type":"object"}'::jsonb,
  'revision_invalidation_model',
  'public.revision_invalidation_source'::regclass,
  'id',
  NULL,
  'revision_invalidation_fact',
  '{}',
  '{}',
  '{"on_change":"mark_stale"}',
  ARRAY['update_row'],
  'refresh_then_fail_closed',
  '{}',
  '{}'
) \g /dev/null

SELECT otlet.register_action_workflow_policy(
  'revision_invalidation_probe_task',
  'update_row',
  'revision_invalidation_target',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

CREATE TEMP TABLE revision_invalidation_proof (
  revision_a text NOT NULL,
  revision_b text,
  job_id bigint,
  receipt_id bigint,
  action_id bigint,
  materialization_id bigint,
  new_job_id bigint,
  queued_job_id bigint,
  expired_running_job_id bigint,
  expired_cancel_job_id bigint
) ON COMMIT DROP;

INSERT INTO revision_invalidation_proof (revision_a)
SELECT active_workload_revision_hash
FROM otlet.workload_revision_heads
WHERE task_name = 'revision_invalidation_probe_task';

DO $body$
DECLARE
  claimed_job_id bigint;
  claimed_token text;
  saved_receipt_id bigint;
  saved_action_id bigint;
  saved_materialization_id bigint;
BEGIN
  PERFORM otlet.run_task_subject('revision_invalidation_probe_task', 'row-1');

  UPDATE otlet.jobs
  SET status = 'running',
      attempts = attempts + 1,
      started_at = now(),
      leased_until = now() + interval '5 minutes',
      claim_token = gen_random_uuid()::text
  WHERE id = (
    SELECT id
    FROM otlet.jobs
    WHERE task_name = 'revision_invalidation_probe_task'
      AND subject_id = 'row-1'
      AND status = 'queued'
    ORDER BY id DESC
    LIMIT 1
  )
  RETURNING id, claim_token INTO claimed_job_id, claimed_token;

  IF claimed_job_id IS NULL THEN
    RAISE EXCEPTION 'revision invalidation proof did not claim its job';
  END IF;

  PERFORM 1
  FROM otlet.complete_job(
    job_id => claimed_job_id,
    output => '{"decision":"keep"}'::jsonb,
    raw_output => jsonb_build_object(
      'output', '{"decision":"keep"}'::jsonb,
      'actions', jsonb_build_array(jsonb_build_object(
        'type', 'update_row',
        'body', jsonb_build_object(
          'target', 'revision_invalidation_target',
          'identity', 'row-1',
          'changes', jsonb_build_object(
            'review_state', 'approved',
            'review_reason', 'revision A proposal'
          )
        )
      ))
    )::text,
    actions => jsonb_build_array(jsonb_build_object(
      'type', 'update_row',
      'body', jsonb_build_object(
        'target', 'revision_invalidation_target',
        'identity', 'row-1',
        'changes', jsonb_build_object(
          'review_state', 'approved',
          'review_reason', 'revision A proposal'
        )
      )
    )),
    started_at => now(),
    trace_summary => '{"schema_validation_status":"passed","mvcc":{"table":"public.revision_invalidation_source"}}'::jsonb,
    model_name => 'revision_invalidation_model',
    expected_claim_token => claimed_token
  );

  IF otlet.materialize_completed_semantic_job(claimed_job_id) <> 1 THEN
    RAISE EXCEPTION 'revision A output was not materialized';
  END IF;

  SELECT output.receipt_id
  INTO saved_receipt_id
  FROM otlet.outputs output
  WHERE output.job_id = claimed_job_id;

  SELECT action.id
  INTO saved_action_id
  FROM otlet.actions action
  WHERE action.job_id = claimed_job_id
    AND action.action_type = 'update_row';

  SELECT materialization.id
  INTO saved_materialization_id
  FROM otlet.semantic_materializations materialization
  WHERE materialization.task_name = 'revision_invalidation_probe_task'
    AND materialization.subject_id = 'row-1';

  IF saved_receipt_id IS NULL
     OR saved_action_id IS NULL
     OR saved_materialization_id IS NULL THEN
    RAISE EXCEPTION 'revision A evidence is incomplete';
  END IF;

  UPDATE revision_invalidation_proof
  SET job_id = claimed_job_id,
      receipt_id = saved_receipt_id,
      action_id = saved_action_id,
      materialization_id = saved_materialization_id;

  IF NOT EXISTS (
    SELECT 1
    FROM revision_invalidation_proof proof
    JOIN otlet.actions action ON action.id = proof.action_id
    JOIN otlet.semantic_materializations materialization
      ON materialization.id = proof.materialization_id
    WHERE action.status = 'proposed'
      AND action.approval_status = 'required'
      AND NOT materialization.stale
      AND materialization.contract_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'revision A did not create active mutation and semantic evidence';
  END IF;
END
$body$;

UPDATE otlet.tasks
SET input_query = E'-- revision B input query\n' || input_query
WHERE name = 'revision_invalidation_probe_task';

UPDATE revision_invalidation_proof
SET revision_b = otlet.capture_workload_revision('revision_invalidation_probe_task');

DO $body$
DECLARE
  proof revision_invalidation_proof%ROWTYPE;
  conflict_seen boolean := false;
  first_job_count bigint;
  first_materialization_count bigint;
  first_stale_count bigint;
  first_receipt_count bigint;
  first_authority_status text;
  first_action_state text;
  first_target_state text;
  admission_conflict_seen boolean := false;
  late_claim_token text;
  swept_jobs bigint;
  diff_edge_definition jsonb;
  diff_edge_hash text;
  status_active_job_id bigint;
  active_model_queue_bytes bigint;
  active_total_queue_bytes bigint;
  active_queued_jobs bigint;
  suspended_queued_jobs bigint;
  semantic_queue_depth bigint;
  semantic_available_slots bigint;
  old_max_queued_jobs_per_model integer;
  old_max_input_bytes_per_job bigint;
  old_max_queued_input_bytes_per_model bigint;
  old_max_queued_input_bytes_total bigint;
  old_max_queued_input_bytes_per_task bigint;
BEGIN
  SELECT * INTO proof FROM revision_invalidation_proof;

  IF proof.revision_b IS NULL OR proof.revision_b = proof.revision_a THEN
    RAISE EXCEPTION 'input-query change did not create revision B';
  END IF;
  IF ARRAY(
    SELECT path
    FROM otlet.workload_revision_diff(
      'revision_invalidation_probe_task',
      proof.revision_a,
      proof.revision_b
    )
  ) IS DISTINCT FROM ARRAY[
    '/source/query_contract/query/raw',
    '/source/query_contract/query/raw_hash'
  ]::text[] THEN
    RAISE EXCEPTION 'revision diff did not isolate the bound input query: %', ARRAY(
      SELECT path
      FROM otlet.workload_revision_diff(
        'revision_invalidation_probe_task',
        proof.revision_a,
        proof.revision_b
      )
    );
  END IF;

  SELECT jsonb_set(
    revision.definition,
    '{task,runtime_options}',
    '"scalar"'::jsonb
  )
  INTO diff_edge_definition
  FROM otlet.workload_revisions revision
  WHERE revision.workload_revision_hash = proof.revision_a;
  diff_edge_hash := otlet.identity_hash('workload_revision', diff_edge_definition);
  INSERT INTO otlet.workload_revisions (
    workload_revision_hash,
    task_name,
    definition
  ) VALUES (
    diff_edge_hash,
    'revision_invalidation_probe_task',
    diff_edge_definition
  );
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_diff(
      'revision_invalidation_probe_task',
      proof.revision_a,
      diff_edge_hash
    ) diff
    HAVING count(*) = 1
       AND bool_and(
         diff.path = '/task/runtime_options'
         AND diff.old_value = '{}'::jsonb
         AND diff.new_value = '"scalar"'::jsonb
       )
  ) THEN
    RAISE EXCEPTION 'revision diff omitted an empty-object to scalar transition';
  END IF;

  PERFORM otlet.promote_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_b,
    proof.revision_a
  );

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = 'revision_invalidation_probe_task'
      AND head.active_workload_revision_hash = proof.revision_b
      AND head.previous_workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'revision B promotion did not move the active head';
  END IF;
  PERFORM otlet.mark_semantic_stale(
    'public.revision_invalidation_source',
    'subject-1',
    'source_update'
  );
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.id = proof.materialization_id
      AND materialization.contract_hash = proof.revision_a
      AND materialization.stale
      AND materialization.stale_reason = 'contract_changed'
  ) THEN
    RAISE EXCEPTION 'revision A materialization was not preserved as contract_changed';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'suspended'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.review_queue queue
    WHERE queue.action_id = proof.action_id
      AND queue.queue_kind = 'suspended_authority'
      AND queue.next_operator_step = 'review'
  ) THEN
    RAISE EXCEPTION 'revision A mutation authority was not suspended';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM otlet.approve_action(proof.action_id, 'must remain suspended')
  ) THEN
    RAISE EXCEPTION 'suspended revision action was approved';
  END IF;

  PERFORM 1 FROM otlet.dry_run_action(proof.action_id);
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.actions action
    WHERE action.id = proof.action_id
      AND action.dry_run_status = 'failed'
      AND action.error = 'action workload revision is not active'
  ) THEN
    RAISE EXCEPTION 'suspended revision dry-run did not fail closed';
  END IF;

  PERFORM 1 FROM otlet.apply_action(proof.action_id);
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.actions action
    WHERE action.id = proof.action_id
      AND action.apply_status = 'failed'
      AND action.error = 'action workload revision is not active'
  ) THEN
    RAISE EXCEPTION 'suspended revision apply did not fail closed';
  END IF;
  IF (SELECT review_state FROM public.revision_invalidation_source WHERE id = 'row-1') <> 'pending' THEN
    RAISE EXCEPTION 'suspended revision mutated the target row';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
    JOIN otlet.outputs output ON output.receipt_id = receipt.id
    JOIN otlet.actions action ON action.receipt_id = receipt.id
    WHERE job.id = proof.job_id
      AND receipt.id = proof.receipt_id
      AND output.job_id = proof.job_id
      AND action.id = proof.action_id
      AND job.workload_revision_hash = proof.revision_a
      AND receipt.workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'promotion rewrote revision A job or receipt attribution';
  END IF;

  BEGIN
    PERFORM otlet.promote_workload_revision(
      'revision_invalidation_probe_task',
      proof.revision_a,
      proof.revision_a
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('promotion conflict' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    conflict_seen := true;
  END;
  IF NOT conflict_seen THEN
    RAISE EXCEPTION 'promotion accepted a stale expected revision';
  END IF;

  PERFORM otlet.repair_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_b
  );
  SELECT
    count(*),
    (SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = 'revision_invalidation_probe_task'),
    (SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = 'revision_invalidation_probe_task' AND stale),
    (SELECT count(*) FROM otlet.inference_receipts WHERE job_id = proof.job_id),
    (SELECT authority_status FROM otlet.action_status WHERE action_id = proof.action_id),
    (SELECT status || '|' || approval_status || '|' || dry_run_status || '|' || apply_status FROM otlet.actions WHERE id = proof.action_id),
    (SELECT review_state FROM public.revision_invalidation_source WHERE id = 'row-1')
  INTO
    first_job_count,
    first_materialization_count,
    first_stale_count,
    first_receipt_count,
    first_authority_status,
    first_action_state,
    first_target_state
  FROM otlet.jobs
  WHERE task_name = 'revision_invalidation_probe_task';

  PERFORM otlet.repair_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_b
  );
  IF first_job_count <> (
       SELECT count(*) FROM otlet.jobs WHERE task_name = 'revision_invalidation_probe_task'
     )
     OR first_materialization_count <> (
       SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = 'revision_invalidation_probe_task'
     )
     OR first_stale_count <> (
       SELECT count(*) FROM otlet.semantic_materializations WHERE task_name = 'revision_invalidation_probe_task' AND stale
     )
     OR first_receipt_count <> (
       SELECT count(*) FROM otlet.inference_receipts WHERE job_id = proof.job_id
     )
     OR first_authority_status IS DISTINCT FROM (
       SELECT authority_status FROM otlet.action_status WHERE action_id = proof.action_id
     )
     OR first_action_state IS DISTINCT FROM (
       SELECT status || '|' || approval_status || '|' || dry_run_status || '|' || apply_status
       FROM otlet.actions
       WHERE id = proof.action_id
     )
     OR first_target_state IS DISTINCT FROM (
       SELECT review_state FROM public.revision_invalidation_source WHERE id = 'row-1'
     ) THEN
    RAISE EXCEPTION 'revision B repair was not idempotent';
  END IF;

  PERFORM otlet.rollback_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_b,
    proof.revision_a
  );
  PERFORM otlet.repair_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_a
  );

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.id = proof.materialization_id
      AND materialization.contract_hash = proof.revision_a
      AND NOT materialization.stale
      AND materialization.stale_reason IS NULL
  ) THEN
    RAISE EXCEPTION 'revision A repair did not restore its materialization';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'active'
  ) THEN
    RAISE EXCEPTION 'revision A rollback did not restore action authority';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.approve_action(proof.action_id, 'rollback restored authority')
  ) THEN
    RAISE EXCEPTION 'revision A rollback did not restore approval authority';
  END IF;

  PERFORM otlet.run_task_subject(
    'revision_invalidation_probe_task',
    'row-2',
    proof.revision_a
  );
  SELECT job.id
  INTO proof.new_job_id
  FROM otlet.jobs job
  WHERE job.task_name = 'revision_invalidation_probe_task'
    AND job.subject_id = 'row-2'
    AND job.status = 'queued';

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.id = proof.new_job_id
      AND job.workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'new job did not bind to rolled-back revision A';
  END IF;
  PERFORM otlet.run_task_subject(
    'revision_invalidation_probe_task',
    'row-3',
    proof.revision_a
  );
  SELECT job.id
  INTO proof.queued_job_id
  FROM otlet.jobs job
  WHERE job.task_name = 'revision_invalidation_probe_task'
    AND job.subject_id = 'row-3'
    AND job.status = 'queued';

  PERFORM otlet.run_task_subject(
    'revision_invalidation_probe_task',
    'row-4',
    proof.revision_a
  );
  SELECT job.id
  INTO proof.expired_running_job_id
  FROM otlet.jobs job
  WHERE job.task_name = 'revision_invalidation_probe_task'
    AND job.subject_id = 'row-4'
    AND job.status = 'queued';
  UPDATE otlet.jobs
  SET status = 'running',
      attempts = attempts + 1,
      started_at = now() - interval '2 minutes',
      leased_until = now() - interval '1 minute',
      claim_token = gen_random_uuid()::text
  WHERE id = proof.expired_running_job_id;

  PERFORM otlet.run_task_subject(
    'revision_invalidation_probe_task',
    'row-5',
    proof.revision_a
  );
  SELECT job.id
  INTO proof.expired_cancel_job_id
  FROM otlet.jobs job
  WHERE job.task_name = 'revision_invalidation_probe_task'
    AND job.subject_id = 'row-5'
    AND job.status = 'queued';
  UPDATE otlet.jobs
  SET status = 'cancel_requested',
      attempts = attempts + 1,
      started_at = now() - interval '2 minutes',
      leased_until = now() - interval '1 minute',
      claim_token = gen_random_uuid()::text,
      error = 'revision changed during cancellation',
      cancel_requested_at = now() - interval '1 minute'
  WHERE id = proof.expired_cancel_job_id;

  UPDATE otlet.jobs
  SET status = 'running',
      attempts = attempts + 1,
      started_at = now(),
      leased_until = now() + interval '5 minutes',
      claim_token = gen_random_uuid()::text
  WHERE id = proof.new_job_id
  RETURNING claim_token INTO late_claim_token;

  UPDATE revision_invalidation_proof
  SET new_job_id = proof.new_job_id,
      queued_job_id = proof.queued_job_id,
      expired_running_job_id = proof.expired_running_job_id,
      expired_cancel_job_id = proof.expired_cancel_job_id;

  PERFORM otlet.promote_workload_revision(
    'revision_invalidation_probe_task',
    proof.revision_b,
    proof.revision_a
  );

  BEGIN
    PERFORM otlet.run_task_subject(
      'revision_invalidation_probe_task',
      'row-1',
      proof.revision_a
    );
    RAISE EXCEPTION 'subject admission accepted an inactive expected revision';
  EXCEPTION WHEN OTHERS THEN
    IF position('workload revision changed' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    admission_conflict_seen := true;
  END;
  IF NOT admission_conflict_seen THEN
    RAISE EXCEPTION 'subject admission did not fence revision drift';
  END IF;

  PERFORM otlet.run_task_subject(
    'revision_invalidation_probe_task',
    'row-3',
    proof.revision_b
  );
  SELECT job.id
  INTO status_active_job_id
  FROM otlet.jobs job
  WHERE job.task_name = 'revision_invalidation_probe_task'
    AND job.workload_revision_hash = proof.revision_b
    AND job.subject_id = 'row-3'
    AND job.status = 'queued';
  UPDATE otlet.jobs
  SET input = jsonb_set(
    input,
    '{row,review_reason}',
    to_jsonb(repeat('x', 4096)),
    true
  )
  WHERE id = proof.queued_job_id;

  SELECT octet_length(job.input::text)
  INTO active_model_queue_bytes
  FROM otlet.jobs job
  WHERE job.id = status_active_job_id;
  SELECT
    count(*) FILTER (
      WHERE job.status = 'queued'
        AND job.workload_revision_hash = head.active_workload_revision_hash
    )::bigint,
    count(*) FILTER (
      WHERE job.status = 'queued'
        AND job.workload_revision_hash IS DISTINCT FROM head.active_workload_revision_hash
    )::bigint,
    COALESCE(sum(octet_length(job.input::text)) FILTER (
      WHERE job.status = 'queued'
        AND job.workload_revision_hash = head.active_workload_revision_hash
    ), 0)::bigint
  INTO active_queued_jobs, suspended_queued_jobs, active_total_queue_bytes
  FROM otlet.jobs job
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name;

  SELECT
    policy.max_queued_jobs_per_model,
    policy.max_input_bytes_per_job,
    policy.max_queued_input_bytes_per_model,
    policy.max_queued_input_bytes_total,
    policy.max_queued_input_bytes_per_task
  INTO
    old_max_queued_jobs_per_model,
    old_max_input_bytes_per_job,
    old_max_queued_input_bytes_per_model,
    old_max_queued_input_bytes_total,
    old_max_queued_input_bytes_per_task
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';
  UPDATE otlet.production_policy
  SET max_queued_jobs_per_model = 1,
      max_input_bytes_per_job = active_model_queue_bytes,
      max_queued_input_bytes_per_model = active_model_queue_bytes,
      max_queued_input_bytes_total = active_total_queue_bytes,
      max_queued_input_bytes_per_task = active_total_queue_bytes
  WHERE name = 'default';

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.model_queue_status status
    WHERE status.model_name = 'revision_invalidation_model'
      AND status.queued_jobs = 1
      AND status.suspended_revision_queued_jobs = 1
      AND status.queued_input_bytes = active_model_queue_bytes
      AND status.total_queued_input_bytes = active_total_queue_bytes
      AND status.running_jobs = 2
      AND status.cancel_requested_jobs = 1
      AND status.available_queue_slots = 0
      AND status.available_model_queue_input_bytes = 0
      AND status.available_total_queue_input_bytes = 0
      AND status.queue_state = 'queue_full'
  ) THEN
    RAISE EXCEPTION 'queue status mixed suspended jobs into active capacity';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.workload_revision_status status
    WHERE status.task_name = 'revision_invalidation_probe_task'
      AND status.suspended_revision_queued_jobs = 1
  ) THEN
    RAISE EXCEPTION 'workload revision status omitted its suspended queue';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.production_status status
    WHERE status.queued_jobs = active_queued_jobs
      AND status.suspended_revision_queued_jobs = suspended_queued_jobs
      AND status.queued_input_bytes = active_total_queue_bytes
  ) THEN
    RAISE EXCEPTION 'production status mixed suspended jobs into active queue totals';
  END IF;

  SELECT plan.worker_queue_depth, plan.available_queue_slots
  INTO semantic_queue_depth, semantic_available_slots
  FROM otlet.semantic_plan_from_counts(
    p_name => 'revision_invalidation_status',
    p_task_name => 'revision_invalidation_probe_task',
    p_record_type => 'revision_invalidation_fact',
    p_model_name => 'revision_invalidation_model',
    p_source_relation => 'public.revision_invalidation_source',
    p_lookup_path => 'lookup',
    p_empty_reason => 'empty',
    p_fresh_reason => 'fresh',
    p_fail_closed_reason => 'fail_closed',
    p_partial_refresh_reason => 'partial_refresh',
    p_full_refresh_path => 'full_refresh',
    p_full_refresh_reason => 'full_refresh',
    p_total_subjects => 1,
    p_fresh_subjects => 0,
    p_stale_subjects => 0,
    p_missing_subjects => 1
  ) plan;
  IF semantic_queue_depth <> 4 OR semantic_available_slots <> 0 THEN
    RAISE EXCEPTION 'semantic queue status lost active queue or running capacity';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM otlet.verify_invariants(0) invariant
    WHERE (
      invariant.invariant_name IN (
        'queued_jobs_within_model_cap',
        'queued_input_bytes_within_model_cap'
      )
      AND invariant.object_id = 'revision_invalidation_model'
    ) OR invariant.invariant_name = 'total_queued_input_bytes_within_cap'
       OR (
         invariant.invariant_name = 'queued_input_within_per_job_cap'
         AND invariant.object_id = proof.queued_job_id::text
       )
  ) THEN
    RAISE EXCEPTION 'queue cap invariant counted suspended revision work';
  END IF;

  DELETE FROM otlet.jobs WHERE id = status_active_job_id;
  UPDATE otlet.production_policy
  SET max_queued_jobs_per_model = old_max_queued_jobs_per_model,
      max_input_bytes_per_job = old_max_input_bytes_per_job,
      max_queued_input_bytes_per_model = old_max_queued_input_bytes_per_model,
      max_queued_input_bytes_total = old_max_queued_input_bytes_total,
      max_queued_input_bytes_per_task = old_max_queued_input_bytes_per_task
  WHERE name = 'default';

  PERFORM 1
  FROM otlet.complete_job(
    job_id => proof.new_job_id,
    output => '{"decision":"late-a"}'::jsonb,
    raw_output => '{"output":{"decision":"late-a"},"actions":[]}',
    actions => '[]'::jsonb,
    started_at => now(),
    trace_summary => '{"schema_validation_status":"passed","mvcc":{"table":"public.revision_invalidation_source"}}'::jsonb,
    model_name => 'revision_invalidation_model',
    expected_claim_token => late_claim_token
  );
  IF otlet.materialize_completed_semantic_job(proof.new_job_id) <> 0
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.inference_receipts receipt
       WHERE receipt.job_id = proof.new_job_id
         AND receipt.workload_revision_hash = proof.revision_a
     ) THEN
    RAISE EXCEPTION 'late revision A completion escaped its revision fence';
  END IF;

  swept_jobs := otlet.sweep_expired_jobs();
  IF swept_jobs < 2
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.jobs job
       JOIN otlet.production_policy policy ON policy.name = 'default'
       JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
       WHERE job.id = proof.expired_running_job_id
         AND job.status = 'failed'
         AND job.attempts < policy.max_attempts
         AND receipt.workload_revision_hash = proof.revision_a
         AND receipt.selection_reason = 'workload_revision_changed_after_lease_expired'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.jobs job
       JOIN otlet.production_policy policy ON policy.name = 'default'
       JOIN otlet.inference_receipts receipt ON receipt.job_id = job.id
       WHERE job.id = proof.expired_cancel_job_id
         AND job.status = 'canceled'
         AND job.attempts < policy.max_attempts
         AND receipt.workload_revision_hash = proof.revision_a
         AND receipt.status = 'canceled'
     ) THEN
    RAISE EXCEPTION 'expired inactive revision jobs were stranded';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM otlet.claim_jobs('revision_invalidation_model', 1)
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.jobs job
    WHERE job.id = proof.queued_job_id
      AND job.status = 'queued'
      AND job.workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'inactive revision A queue remained actionable';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.semantic_index_current_rows(
      'revision_invalidation_probe',
      true,
      proof.revision_b
    )
  ) THEN
    RAISE EXCEPTION 'revision B exposed revision A semantic state';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'suspended'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.semantic_materializations materialization
    WHERE materialization.id = proof.materialization_id
      AND materialization.stale
      AND materialization.stale_reason = 'contract_changed'
  ) THEN
    RAISE EXCEPTION 'revision B re-promotion did not restore invalidation';
  END IF;

  PERFORM otlet.drop_watch_registry('revision_invalidation_probe');
  IF EXISTS (
    SELECT 1
    FROM otlet.workload_revision_heads head
    WHERE head.task_name = 'revision_invalidation_probe_task'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.action_id
      AND status.authority_status = 'suspended'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.review_queue queue
    WHERE queue.action_id = proof.action_id
      AND queue.queue_kind = 'suspended_authority'
      AND queue.next_operator_step = 'review'
  ) OR NOT EXISTS (
    SELECT 1
    FROM otlet.inference_receipts receipt
    WHERE receipt.id = proof.receipt_id
      AND receipt.workload_revision_hash = proof.revision_a
  ) THEN
    RAISE EXCEPTION 'watch drop did not retire authority while preserving evidence';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.claim_jobs('revision_invalidation_model', 1)
  ) THEN
    RAISE EXCEPTION 'watch drop left its queued work claimable';
  END IF;

  DROP TABLE public.revision_invalidation_source;
  IF EXISTS (
    SELECT 1
    FROM otlet.verify_invariants(0) invariant
    WHERE invariant.invariant_name = 'fresh_materialization_source_query_runs'
      AND invariant.object_id = 'revision_invalidation_probe'
  ) THEN
    RAISE EXCEPTION 'watch drop left an active source-query revision';
  END IF;
END
$body$;

SELECT 'revision_invalidation_contract=ok';
ROLLBACK;
SQL

revision_claim_lock_task="revision_claim_lock_probe"

cleanup_revision_claim_lock() {
  cleanup_task "$revision_claim_lock_task"
  psql_exec -qAt >/dev/null <<'SQL'
DROP TRIGGER IF EXISTS revision_claim_lock_delay ON otlet.jobs;
DROP FUNCTION IF EXISTS public.revision_claim_lock_delay();
DROP TABLE IF EXISTS public.revision_claim_lock_proof;
SQL
}

cleanup_revision_claim_lock
psql_exec -qAt >/dev/null <<'SQL'
SELECT otlet.register_model(
  'revision_claim_lock_model',
  '/tmp/revision-claim-lock.gguf',
  repeat('9', 64),
  jsonb_build_object(
    'sha256', repeat('9', 64),
    'bytes', 1,
    'source', 'fixture',
    'revision', 'revision-claim-lock',
    'quantization', 'none',
    'license', 'test'
  )
);
SELECT otlet.create_task(
  'revision_claim_lock_probe',
  NULL,
  'revision A',
  '{"type":"object"}'::jsonb,
  'revision_claim_lock_model'
);
CREATE TABLE public.revision_claim_lock_proof AS
SELECT
  otlet.capture_workload_revision('revision_claim_lock_probe') AS revision_a,
  NULL::text AS revision_b;
SELECT otlet.ensure_active_workload_revision('revision_claim_lock_probe');
SELECT otlet.promote_workload_revision(
  'revision_claim_lock_probe',
  proof.revision_a,
  head.active_workload_revision_hash
)
FROM public.revision_claim_lock_proof proof
JOIN otlet.workload_revision_heads head
  ON head.task_name = 'revision_claim_lock_probe'
WHERE head.active_workload_revision_hash IS DISTINCT FROM proof.revision_a;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('revision_claim_lock_probe', 'subject', '{}'::jsonb);
UPDATE otlet.tasks
SET instruction = 'revision B'
WHERE name = 'revision_claim_lock_probe';
UPDATE public.revision_claim_lock_proof
SET revision_b = otlet.capture_workload_revision('revision_claim_lock_probe');
CREATE FUNCTION public.revision_claim_lock_delay() RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.task_name = 'revision_claim_lock_probe'
     AND OLD.status = 'queued'
     AND NEW.status = 'running' THEN
    PERFORM pg_sleep(1);
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER revision_claim_lock_delay
BEFORE UPDATE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION public.revision_claim_lock_delay();
SQL

psql_exec -qAt >/dev/null <<'SQL' &
SET application_name = 'otlet_revision_claim_lock';
SELECT count(*)
FROM otlet.claim_jobs('revision_claim_lock_model', 1);
SQL
revision_claim_lock_pid="$!"
revision_claim_waiting=false
for _ in {1..40}; do
  if [ "$(psql_value <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM pg_stat_activity
  WHERE application_name = 'otlet_revision_claim_lock'
    AND wait_event = 'PgSleep'
);
SQL
)" = "t" ]; then
    revision_claim_waiting=true
    break
  fi
  sleep 0.05
done

if [ "$revision_claim_waiting" != true ]; then
  wait "$revision_claim_lock_pid" || true
  cleanup_revision_claim_lock
  echo "Claim serialization proof did not reach its controlled delay" >&2
  exit 1
fi

if revision_claim_promotion_output="$(
  docker exec \
    -e PGOPTIONS="-c lock_timeout=250ms $demo_pgoptions" \
    -i "$container" \
    psql -U postgres -d "$database" -v ON_ERROR_STOP=1 -qAt 2>&1 <<'SQL'
SELECT otlet.promote_workload_revision(
  'revision_claim_lock_probe',
  (SELECT revision_b FROM public.revision_claim_lock_proof),
  (SELECT revision_a FROM public.revision_claim_lock_proof)
);
SQL
)"; then
  wait "$revision_claim_lock_pid" || true
  cleanup_revision_claim_lock
  echo "Promotion crossed an in-flight claim" >&2
  exit 1
fi
if [[ "$revision_claim_promotion_output" != *"lock timeout"* ]]; then
  wait "$revision_claim_lock_pid" || true
  cleanup_revision_claim_lock
  echo "Claim serialization proof failed unexpectedly: $revision_claim_promotion_output" >&2
  exit 1
fi
if ! wait "$revision_claim_lock_pid"; then
  cleanup_revision_claim_lock
  echo "Controlled claim failed" >&2
  exit 1
fi

revision_claim_lock_contract="$(psql_value <<'SQL'
SELECT (
  job.status = 'running'
  AND job.workload_revision_hash = proof.revision_a
  AND head.active_workload_revision_hash = proof.revision_a
)::text
FROM otlet.jobs job
JOIN public.revision_claim_lock_proof proof ON true
JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name
WHERE job.task_name = 'revision_claim_lock_probe';
SELECT otlet.promote_workload_revision(
  'revision_claim_lock_probe',
  (SELECT revision_b FROM public.revision_claim_lock_proof),
  (SELECT revision_a FROM public.revision_claim_lock_proof)
);
SELECT (
  job.status = 'running'
  AND job.workload_revision_hash = proof.revision_a
  AND head.active_workload_revision_hash = proof.revision_b
)::text
FROM otlet.jobs job
JOIN public.revision_claim_lock_proof proof ON true
JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name
WHERE job.task_name = 'revision_claim_lock_probe';
SQL
)"
revision_claim_lock_contract="$(printf '%s\n' "$revision_claim_lock_contract" | sed -n '1p;3p' | paste -sd '|' -)"
cleanup_revision_claim_lock

echo "revision_claim_serialization_contract=$revision_claim_lock_contract"
[ "$revision_claim_lock_contract" = "true|true" ] || {
  echo "Claim serialization did not preserve revision attribution" >&2
  exit 1
}
