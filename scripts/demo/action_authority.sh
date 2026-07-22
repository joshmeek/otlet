log "Proving workflow-bound action authority"

action_authority_contract="$(psql_value -v model_name="$strong_model_name" <<'SQL'
BEGIN;

CREATE TEMP TABLE action_authority_params(model_name text NOT NULL);
INSERT INTO action_authority_params VALUES (:'model_name');

CREATE TABLE public.otlet_demo_action_authority (
  id text PRIMARY KEY,
  review_state text NOT NULL,
  protected_note text NOT NULL
);
CREATE TABLE public.otlet_demo_action_redirect (
  id text PRIMARY KEY,
  review_state text NOT NULL
);
INSERT INTO public.otlet_demo_action_authority
SELECT name, 'pending', 'DO_NOT_TOUCH'
FROM unnest(ARRAY[
  'redirect',
  'recommendation',
  'unevaluated',
  'adversarial',
  'unapproved',
  'stale',
  'success'
]) name;
INSERT INTO public.otlet_demo_action_redirect VALUES ('redirect', 'pending');

DO $body$
BEGIN
  PERFORM otlet.create_watch(
    watch_name => 'action_authority_demo',
    kind => 'row',
    instruction => 'Return a recommendation and one update_row action',
    output_schema => '{"type":"object"}'::jsonb,
    model_name => (SELECT model_name FROM action_authority_params),
    table_name => 'public.otlet_demo_action_authority'::regclass,
    subject_column => 'id',
    action_types => ARRAY['update_row']
  );
  PERFORM otlet.register_action_target(
    'action_authority_canonical',
    'public.otlet_demo_action_authority'::regclass,
    'id',
    ARRAY['review_state']::name[]
  );
  PERFORM otlet.register_action_target(
    'action_authority_redirect',
    'public.otlet_demo_action_redirect'::regclass,
    'id',
    ARRAY['review_state']::name[]
  );
  PERFORM otlet.register_action_workflow_policy(
    'action_authority_demo_task',
    'update_row',
    'action_authority_canonical',
    'bounded_mutation',
    'evaluated'
  );
END
$body$;

CREATE FUNCTION pg_temp.propose_authority_action(
  selected_subject text,
  proposed_target text,
  proposed_state text
) RETURNS bigint
LANGUAGE plpgsql
AS $body$
DECLARE
  selected_job_id bigint;
  selected_action_id bigint;
  selected_input jsonb;
  proposed_actions jsonb;
BEGIN
  SELECT jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_action_authority',
      'subject_id', source.id,
      'ctid', source.ctid::text,
      'xmin', source.xmin::text
    ),
    'table', 'public.otlet_demo_action_authority',
    'row', to_jsonb(source)
  )
  INTO selected_input
  FROM public.otlet_demo_action_authority source
  WHERE source.id = selected_subject;

  INSERT INTO otlet.jobs (
    task_name,
    subject_id,
    input,
    status,
    attempts,
    started_at,
    leased_until
  )
  VALUES (
    'action_authority_demo_task',
    selected_subject,
    selected_input,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id INTO selected_job_id;

  proposed_actions := jsonb_build_array(jsonb_build_object(
    'type', 'update_row',
    'body', jsonb_build_object(
      'target', proposed_target,
      'identity', selected_subject,
      'changes', jsonb_build_object('review_state', proposed_state)
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
      "mvcc":{"table":"public.otlet_demo_action_authority"}
    }'::jsonb,
    model_name => (SELECT model_name FROM otlet.tasks WHERE name = 'action_authority_demo_task')
  );

  SELECT id
  INTO selected_action_id
  FROM otlet.actions
  WHERE job_id = selected_job_id
  ORDER BY id DESC
  LIMIT 1;
  RETURN selected_action_id;
END
$body$;

DO $body$
DECLARE
  selected_job_id bigint;
BEGIN
  PERFORM otlet.create_task(
    'action_authority_default_task',
    NULL,
    'Return a recommendation',
    '{"type":"object"}'::jsonb,
    (SELECT model_name FROM action_authority_params)
  );
  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at)
  VALUES ('action_authority_default_task', 'default', '{}'::jsonb, 'running', 1, now())
  RETURNING id INTO selected_job_id;
  PERFORM otlet.complete_job(
    job_id => selected_job_id,
    output => '{"decision":"review"}'::jsonb,
    raw_output => '{"output":{"decision":"review"},"actions":[{"type":"review_flag","body":{"left_id":"left","right_id":"right","severity":"high","reason":"default"}}]}',
    actions => '[{"type":"review_flag","body":{"left_id":"left","right_id":"right","severity":"high","reason":"default"}}]'::jsonb,
    started_at => now(),
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    model_name => (SELECT model_name FROM action_authority_params)
  );
END
$body$;

SELECT pg_temp.propose_authority_action(
  'redirect',
  'action_authority_redirect',
  'redirected'
) AS id \gset redirect_

SELECT *
FROM otlet.register_action_workflow_policy(
  'action_authority_demo_task',
  'update_row',
  'action_authority_canonical',
  'recommendation_only',
  'evaluated'
) \gset recommendation_policy_
SELECT pg_temp.propose_authority_action(
  'recommendation',
  'action_authority_canonical',
  'changed'
) AS id \gset recommendation_
SELECT dry_run_status FROM otlet.dry_run_action(:recommendation_id) \gset recommendation_dry_
SELECT approval_status FROM otlet.approve_action(:recommendation_id) \gset recommendation_approval_
SELECT apply_status, error FROM otlet.apply_action(:recommendation_id) \gset recommendation_apply_

SELECT *
FROM otlet.register_action_workflow_policy(
  'action_authority_demo_task',
  'update_row',
  'action_authority_canonical',
  'bounded_mutation',
  'unevaluated'
) \gset unevaluated_policy_
SELECT pg_temp.propose_authority_action(
  'unevaluated',
  'action_authority_canonical',
  'changed'
) AS id \gset unevaluated_
SELECT dry_run_status FROM otlet.dry_run_action(:unevaluated_id) \gset unevaluated_dry_
SELECT approval_status FROM otlet.approve_action(:unevaluated_id) \gset unevaluated_approval_
SELECT apply_status, error FROM otlet.apply_action(:unevaluated_id) \gset unevaluated_apply_

SELECT *
FROM otlet.register_action_workflow_policy(
  'action_authority_demo_task',
  'update_row',
  'action_authority_canonical',
  'bounded_mutation',
  'adversarial'
) \gset adversarial_policy_
SELECT pg_temp.propose_authority_action(
  'adversarial',
  'action_authority_canonical',
  'changed'
) AS id \gset adversarial_
SELECT dry_run_status FROM otlet.dry_run_action(:adversarial_id) \gset adversarial_dry_
SELECT approval_status FROM otlet.approve_action(:adversarial_id) \gset adversarial_approval_
SELECT apply_status, error FROM otlet.apply_action(:adversarial_id) \gset adversarial_apply_

SELECT *
FROM otlet.register_action_workflow_policy(
  'action_authority_demo_task',
  'update_row',
  'action_authority_canonical',
  'bounded_mutation',
  'evaluated'
) \gset evaluated_policy_
SELECT pg_temp.propose_authority_action(
  'unapproved',
  'action_authority_canonical',
  'changed'
) AS id \gset unapproved_
SELECT dry_run_status FROM otlet.dry_run_action(:unapproved_id) \gset unapproved_dry_
SELECT apply_status, error FROM otlet.apply_action(:unapproved_id) \gset unapproved_apply_

SELECT pg_temp.propose_authority_action(
  'stale',
  'action_authority_canonical',
  'changed'
) AS id \gset stale_
SELECT dry_run_status FROM otlet.dry_run_action(:stale_id) \gset stale_dry_
SELECT approval_status FROM otlet.approve_action(:stale_id) \gset stale_approval_
UPDATE public.otlet_demo_action_authority
SET review_state = 'owner_changed'
WHERE id = 'stale';
SELECT apply_status, error FROM otlet.apply_action(:stale_id) \gset stale_apply_

SELECT pg_temp.propose_authority_action(
  'success',
  'action_authority_canonical',
  'changed'
) AS id \gset success_
SELECT dry_run_status FROM otlet.dry_run_action(:success_id) \gset success_dry_
SELECT approval_status FROM otlet.approve_action(:success_id) \gset success_approval_
SELECT apply_status, error FROM otlet.apply_action(:success_id) \gset success_apply_

SELECT
  EXISTS (
    SELECT 1
    FROM otlet.actions a
    JOIN otlet.jobs j ON j.id = a.job_id
    WHERE j.task_name = 'action_authority_default_task'
      AND a.status = 'rejected'
      AND a.error = 'action type review_flag is not allowed by workflow'
  )::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.actions a
    WHERE a.id = :redirect_id
      AND a.status = 'rejected'
      AND a.error = 'update_row target does not match workflow authority'
      AND a.target_name = 'action_authority_canonical'
      AND a.payload #>> '{body,target}' = 'action_authority_canonical'
      AND (SELECT review_state FROM public.otlet_demo_action_redirect WHERE id = 'redirect') = 'pending'
  )::text || '|' ||
  (:'recommendation_apply_apply_status' = 'failed'
    AND :'recommendation_apply_error' = 'action workflow is recommendation only'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'recommendation') = 'pending')::text || '|' ||
  (:'unevaluated_apply_apply_status' = 'failed'
    AND :'unevaluated_apply_error' = 'action workflow is not evaluated for mutation'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'unevaluated') = 'pending')::text || '|' ||
  (:'adversarial_apply_apply_status' = 'failed'
    AND :'adversarial_apply_error' = 'action workflow is not evaluated for mutation'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'adversarial') = 'pending')::text || '|' ||
  (:'unapproved_apply_apply_status' = 'failed'
    AND :'unapproved_apply_error' = 'action requires approval'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'unapproved') = 'pending')::text || '|' ||
  (:'stale_apply_apply_status' = 'failed'
    AND :'stale_apply_error' = 'source identity stale'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'stale') = 'owner_changed')::text || '|' ||
  (:'success_apply_apply_status' = 'applied'
    AND (SELECT review_state FROM public.otlet_demo_action_authority WHERE id = 'success') = 'changed'
    AND (SELECT protected_note FROM public.otlet_demo_action_authority WHERE id = 'success') = 'DO_NOT_TOUCH')::text || '|' ||
  EXISTS (
    SELECT 1
    FROM otlet.action_workflow_policy_status
    WHERE task_name = 'action_authority_demo_task'
      AND mutation_authorized
      AND task_contract_current
      AND target_contract_current
      AND target_error IS NULL
  )::text || '|' ||
  (
    SELECT count(*) = 1
       AND bool_and(action_type = 'update_row')
    FROM otlet.action_type_schemas
    WHERE applyable
  )::text;

ROLLBACK;
SQL
)"

echo "action_authority_contract=$action_authority_contract"
[ "$action_authority_contract" = "true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected workflow authority to reject redirection, recommendation-only, unevaluated, adversarial, unapproved, and stale mutations, got $action_authority_contract" >&2
  exit 1
}
