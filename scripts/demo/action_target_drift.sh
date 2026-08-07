log "Proving action-target contract drift"

action_target_drift_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
BEGIN;

CREATE TABLE public.otlet_demo_action_target_drift (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
CREATE TABLE public.otlet_demo_action_target_unrelated (
  id text PRIMARY KEY
);
INSERT INTO public.otlet_demo_action_target_drift VALUES
  ('old-action', 'pending', 'DO_NOT_TOUCH'),
  ('new-action', 'waiting', 'DO_NOT_TOUCH');

SELECT otlet.register_action_target(
  'action_target_drift_demo',
  'public.otlet_demo_action_target_drift'::regclass,
  'id',
  ARRAY['review_state']::name[]
) \g /dev/null

CREATE TEMP TABLE action_target_drift_proof (
  baseline_hash text NOT NULL,
  target_generation bigint NOT NULL,
  target_event_count bigint NOT NULL,
  descriptor_bound boolean NOT NULL DEFAULT false,
  type_bound boolean NOT NULL DEFAULT false,
  constraint_bound boolean NOT NULL DEFAULT false,
  index_bound boolean NOT NULL DEFAULT false,
  identity_bound boolean NOT NULL DEFAULT false,
  writable_bound boolean NOT NULL DEFAULT false,
  privilege_bound boolean NOT NULL DEFAULT false,
  rls_bound boolean NOT NULL DEFAULT false,
  unrelated_stable boolean NOT NULL DEFAULT false,
  revision_a text,
  revision_b text,
  old_action_id bigint,
  target_suspended boolean NOT NULL DEFAULT false,
  operational_generation_unlogged boolean NOT NULL DEFAULT false,
  dry_run_closed boolean NOT NULL DEFAULT false,
  apply_closed boolean NOT NULL DEFAULT false,
  suspension_persisted boolean NOT NULL DEFAULT false,
  reapproval_required boolean NOT NULL DEFAULT false,
  old_action_suspended boolean NOT NULL DEFAULT false,
  new_action_applied boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO action_target_drift_proof (
  baseline_hash,
  target_generation,
  target_event_count
)
SELECT
  otlet.action_target_contract_hash('action_target_drift_demo'),
  target.contract_generation,
  (
    SELECT count(*)
    FROM otlet.administrative_change_events event
    WHERE event.object_type = 'action_policy'
      AND event.object_name = 'target:' || target.name
  )
FROM otlet.action_targets target
WHERE target.name = 'action_target_drift_demo';

DO $body$
DECLARE
  baseline text := (SELECT baseline_hash FROM action_target_drift_proof);
BEGIN
  UPDATE action_target_drift_proof
  SET descriptor_bound =
    jsonb_typeof(otlet.action_target_contract_descriptor('action_target_drift_demo')->'identity') = 'object'
    AND jsonb_array_length(
      otlet.action_target_contract_descriptor('action_target_drift_demo')->'writable_columns'
    ) = 1
    AND jsonb_array_length(
      otlet.action_target_contract_descriptor('action_target_drift_demo')->'constraints'
    ) >= 1
    AND jsonb_array_length(
      otlet.action_target_contract_descriptor('action_target_drift_demo')->'indexes'
    ) >= 1
    AND otlet.action_target_contract_descriptor('action_target_drift_demo')
      #>> '{relation,row_security}' = 'false'
    AND otlet.action_target_validation_error('action_target_drift_demo') IS NULL;

  ALTER TABLE public.otlet_demo_action_target_drift
    ALTER COLUMN review_state TYPE varchar(32);
  UPDATE action_target_drift_proof
  SET type_bound = otlet.action_target_contract_hash('action_target_drift_demo') <> baseline;
  ALTER TABLE public.otlet_demo_action_target_drift
    ALTER COLUMN review_state TYPE text;

  ALTER TABLE public.otlet_demo_action_target_drift
    ADD CONSTRAINT action_target_probe_check CHECK (review_state <> 'blocked');
  UPDATE action_target_drift_proof
  SET constraint_bound = otlet.action_target_contract_hash('action_target_drift_demo') <> baseline;
  ALTER TABLE public.otlet_demo_action_target_drift
    DROP CONSTRAINT action_target_probe_check;

  CREATE UNIQUE INDEX action_target_probe_unique
  ON public.otlet_demo_action_target_drift (review_state);
  UPDATE action_target_drift_proof
  SET index_bound = otlet.action_target_contract_hash('action_target_drift_demo') <> baseline;
  DROP INDEX public.action_target_probe_unique;

  ALTER TABLE public.otlet_demo_action_target_drift RENAME COLUMN id TO renamed_id;
  UPDATE action_target_drift_proof
  SET identity_bound =
    otlet.action_target_contract_hash('action_target_drift_demo') <> baseline
    AND otlet.action_target_validation_error('action_target_drift_demo') =
      'action target identity must be its single-column primary key';
  ALTER TABLE public.otlet_demo_action_target_drift RENAME COLUMN renamed_id TO id;

  ALTER TABLE public.otlet_demo_action_target_drift ALTER COLUMN review_state DROP NOT NULL;
  UPDATE action_target_drift_proof
  SET writable_bound = otlet.action_target_contract_hash('action_target_drift_demo') <> baseline;
  ALTER TABLE public.otlet_demo_action_target_drift ALTER COLUMN review_state SET NOT NULL;

  GRANT UPDATE (review_state) ON public.otlet_demo_action_target_drift TO PUBLIC;
  UPDATE action_target_drift_proof
  SET privilege_bound = otlet.action_target_contract_hash('action_target_drift_demo') <> baseline;
  REVOKE UPDATE (review_state) ON public.otlet_demo_action_target_drift FROM PUBLIC;

  ALTER TABLE public.otlet_demo_action_target_drift ENABLE ROW LEVEL SECURITY;
  UPDATE action_target_drift_proof
  SET rls_bound =
    otlet.action_target_contract_hash('action_target_drift_demo') <> baseline
    AND otlet.action_target_validation_error('action_target_drift_demo') =
      'action target cannot use row level security';
  ALTER TABLE public.otlet_demo_action_target_drift DISABLE ROW LEVEL SECURITY;

  GRANT SELECT ON public.otlet_demo_action_target_unrelated TO PUBLIC;
  UPDATE action_target_drift_proof
  SET unrelated_stable = otlet.action_target_contract_hash('action_target_drift_demo') = baseline;
  REVOKE SELECT ON public.otlet_demo_action_target_unrelated FROM PUBLIC;

  IF otlet.action_target_contract_hash('action_target_drift_demo') <> baseline THEN
    RAISE EXCEPTION 'action target contract did not return to its baseline';
  END IF;
END
$body$;

SELECT otlet.create_watch(
  'action_target_drift_demo',
  'row',
  'Return one update_row action',
  '{"type":"object"}'::jsonb,
  :'model_name',
  'public.otlet_demo_action_target_drift'::regclass,
  'id',
  NULL,
  'action_target_drift_fact',
  '{}',
  '{}',
  '{"on_change":"mark_stale"}',
  ARRAY['update_row'],
  'refresh_then_fail_closed',
  '{}',
  '{}'
) \g /dev/null

SELECT otlet.register_action_workflow_policy(
  'action_target_drift_demo_task',
  'update_row',
  'action_target_drift_demo',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

CREATE FUNCTION pg_temp.propose_action_target_update(
  selected_subject text,
  selected_state text
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
  selected_job_id bigint;
  selected_action_id bigint;
  selected_claim_token text;
  selected_input jsonb;
  proposed_actions jsonb;
BEGIN
  SELECT jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_action_target_drift',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_demo_action_target_drift',
    'row', to_jsonb(source)
  )
  INTO selected_input
  FROM public.otlet_demo_action_target_drift source
  WHERE source.id = selected_subject;

  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until,
    claim_token
  ) VALUES (
    'action_target_drift_demo_task',
    selected_subject,
    selected_input,
    'running',
    1,
    now(),
    now() + interval '5 minutes',
    gen_random_uuid()::text
  )
  RETURNING id, claim_token INTO selected_job_id, selected_claim_token;

  proposed_actions := jsonb_build_array(jsonb_build_object(
    'type', 'update_row',
    'body', jsonb_build_object(
      'target', 'action_target_drift_demo',
      'identity', selected_subject,
      'changes', jsonb_build_object('review_state', selected_state)
    )
  ));
  PERFORM otlet.complete_job(
    job_id => selected_job_id,
    output => '{"decision":"reviewed"}'::jsonb,
    raw_output => jsonb_build_object(
      'output', '{"decision":"reviewed"}'::jsonb,
      'actions', proposed_actions
    )::text,
    actions => proposed_actions,
    started_at => now(),
    trace_summary => '{
      "schema_validation_status":"passed",
      "mvcc":{"table":"public.otlet_demo_action_target_drift"}
    }'::jsonb,
    model_name => (
      SELECT model_name
      FROM otlet.tasks
      WHERE name = 'action_target_drift_demo_task'
    ),
    expected_claim_token => selected_claim_token
  );

  SELECT id
  INTO selected_action_id
  FROM otlet.actions
  WHERE job_id = selected_job_id
    AND action_type = 'update_row';
  RETURN selected_action_id;
END
$body$;

UPDATE action_target_drift_proof
SET revision_a = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'action_target_drift_demo_task'
),
old_action_id = pg_temp.propose_action_target_update('old-action', 'approved');

SELECT otlet.dry_run_action(old_action_id)
FROM action_target_drift_proof \g /dev/null
SELECT otlet.approve_action(old_action_id, 'approved before target drift')
FROM action_target_drift_proof \g /dev/null

ALTER TABLE public.otlet_demo_action_target_drift
  ADD CONSTRAINT action_target_persistent_check
  CHECK (review_state IN ('pending', 'waiting', 'approved'));

UPDATE action_target_drift_proof proof
SET target_suspended =
  EXISTS (
    SELECT 1
    FROM otlet.action_workflow_policy_status status
    WHERE status.task_name = 'action_target_drift_demo_task'
      AND NOT status.target_contract_current
      AND NOT status.mutation_authorized
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.old_action_id
      AND status.authority_status = 'suspended'
  )
  AND EXISTS (
    SELECT 1
    FROM otlet.review_queue queue
    WHERE queue.action_id = proof.old_action_id
      AND queue.queue_kind = 'suspended_authority'
      AND queue.next_operator_step = 'review'
  );

SELECT otlet.dry_run_action(old_action_id)
FROM action_target_drift_proof \g /dev/null
UPDATE action_target_drift_proof proof
SET dry_run_closed = EXISTS (
  SELECT 1
  FROM otlet.actions action
  WHERE action.id = proof.old_action_id
    AND action.dry_run_status = 'failed'
    AND action.error = 'action workflow target contract changed'
);

UPDATE action_target_drift_proof proof
SET operational_generation_unlogged =
  (
    SELECT target.contract_generation = proof.target_generation + 1
    FROM otlet.action_targets target
    WHERE target.name = 'action_target_drift_demo'
  )
  AND (
    SELECT count(*) = proof.target_event_count
    FROM otlet.administrative_change_events event
    WHERE event.object_type = 'action_policy'
      AND event.object_name = 'target:action_target_drift_demo'
  )
  AND current_setting('otlet.administrative_suppress', true) IS DISTINCT FROM 'on';

SELECT otlet.apply_action(old_action_id)
FROM action_target_drift_proof \g /dev/null
UPDATE action_target_drift_proof proof
SET apply_closed = EXISTS (
  SELECT 1
  FROM otlet.actions action
  WHERE action.id = proof.old_action_id
    AND action.apply_status = 'failed'
    AND action.error = 'action workflow target contract changed'
) AND (
  SELECT review_state = 'pending'
  FROM public.otlet_demo_action_target_drift
  WHERE id = 'old-action'
);

ALTER TABLE public.otlet_demo_action_target_drift
  DROP CONSTRAINT action_target_persistent_check;
UPDATE action_target_drift_proof proof
SET suspension_persisted =
  otlet.action_target_contract_hash('action_target_drift_demo') <> proof.baseline_hash
  AND EXISTS (
    SELECT 1
    FROM otlet.action_status status
    WHERE status.action_id = proof.old_action_id
      AND status.authority_status = 'suspended'
  );

SELECT otlet.register_action_workflow_policy(
  'action_target_drift_demo_task',
  'update_row',
  'action_target_drift_demo',
  'bounded_mutation',
  'evaluated'
) \g /dev/null

UPDATE action_target_drift_proof
SET revision_b = (
  SELECT active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'action_target_drift_demo_task'
);

SELECT otlet.dry_run_action(old_action_id)
FROM action_target_drift_proof \g /dev/null
SELECT otlet.apply_action(old_action_id)
FROM action_target_drift_proof \g /dev/null

UPDATE action_target_drift_proof proof
SET old_action_suspended = proof.revision_a <> proof.revision_b
  AND EXISTS (
    SELECT 1
    FROM otlet.actions action
    WHERE action.id = proof.old_action_id
      AND action.dry_run_status = 'failed'
      AND action.apply_status = 'failed'
      AND action.error = 'action workload revision is not active'
  );

CREATE TEMP TABLE action_target_new_action AS
SELECT pg_temp.propose_action_target_update('new-action', 'approved') AS id;

SELECT otlet.dry_run_action(id) FROM action_target_new_action \g /dev/null
SELECT otlet.apply_action(id) FROM action_target_new_action \g /dev/null

UPDATE action_target_drift_proof
SET reapproval_required = EXISTS (
  SELECT 1
  FROM otlet.actions action
  JOIN action_target_new_action selected ON selected.id = action.id
  WHERE action.status = 'proposed'
    AND action.approval_status = 'required'
    AND action.dry_run_status = 'failed'
    AND action.apply_status = 'failed'
    AND action.error = 'action requires approval'
);

SELECT otlet.dry_run_action(id) FROM action_target_new_action \g /dev/null
SELECT otlet.approve_action(id, 'approved against repaired target contract')
FROM action_target_new_action \g /dev/null
SELECT otlet.apply_action(id) FROM action_target_new_action \g /dev/null

UPDATE action_target_drift_proof
SET new_action_applied = EXISTS (
  SELECT 1
  FROM otlet.actions action
  JOIN action_target_new_action selected ON selected.id = action.id
  WHERE action.status = 'applied'
    AND action.approval_status = 'approved'
    AND action.apply_status = 'applied'
) AND (
  SELECT review_state = 'approved' AND protected_note = 'DO_NOT_TOUCH'
  FROM public.otlet_demo_action_target_drift
  WHERE id = 'new-action'
) AND EXISTS (
  SELECT 1
  FROM otlet.action_workflow_policy_status status
  WHERE status.task_name = 'action_target_drift_demo_task'
    AND status.target_contract_current
    AND status.mutation_authorized
);

SELECT
  descriptor_bound::text || '|' ||
  type_bound::text || '|' ||
  constraint_bound::text || '|' ||
  index_bound::text || '|' ||
  identity_bound::text || '|' ||
  writable_bound::text || '|' ||
  privilege_bound::text || '|' ||
  rls_bound::text || '|' ||
  unrelated_stable::text || '|' ||
  target_suspended::text || '|' ||
  operational_generation_unlogged::text || '|' ||
  dry_run_closed::text || '|' ||
  apply_closed::text || '|' ||
  suspension_persisted::text || '|' ||
  reapproval_required::text || '|' ||
  old_action_suspended::text || '|' ||
  new_action_applied::text
FROM action_target_drift_proof;

ROLLBACK;
SQL
)"

echo "action_target_drift_contract=$action_target_drift_contract"
[ "$action_target_drift_contract" = "true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected action-target drift contract to pass, got $action_target_drift_contract" >&2
  exit 1
}
