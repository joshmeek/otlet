action_contract="$(psql_exec -qAt -v task_name="$entity_task" <<'SQL'
WITH schema_check AS (
  SELECT string_agg(action_type, '|' ORDER BY action_type) AS value
  FROM otlet.action_type_schemas
  WHERE action_type IN ('merge_candidate', 'new_entity', 'note', 'review_flag', 'update_row')
), type_check AS (
  SELECT COALESCE(string_agg(DISTINCT action_type, '|' ORDER BY action_type), '') AS value
  FROM otlet.action_status
  WHERE task_name = :'task_name'
    AND trusted_output
), status_check AS (
  SELECT count(*)::text || '|' ||
         count(*) FILTER (WHERE trusted_output)::text || '|' ||
         count(*) FILTER (WHERE receipt_id IS NOT NULL AND output_id IS NOT NULL)::text || '|' ||
         count(*) FILTER (WHERE status = 'rejected')::text AS value
  FROM otlet.action_status
  WHERE task_name = :'task_name'
), failed_check AS (
  SELECT count(*)::text AS value
  FROM otlet.action_status a
  JOIN otlet.inference_receipts r ON r.id = a.receipt_id
  WHERE a.task_name = :'task_name'
    AND r.selection_status <> 'accepted'
), applyable_check AS (
  SELECT string_agg(action_type || ':' || applyable::text, '|' ORDER BY action_type) AS value
  FROM otlet.action_type_schemas
  WHERE action_type IN ('create_record', 'merge_candidate', 'new_entity', 'note', 'review_flag', 'update_row')
)
SELECT concat_ws(E'\n',
  'action_schema_contract=' || schema_check.value,
  'action_type_contract=' || type_check.value,
  'action_status_contract=' || status_check.value,
  'failed_attempt_action_contract=' || failed_check.value,
  'action_applyable_contract=' || applyable_check.value
)
FROM schema_check, type_check, status_check, failed_check, applyable_check;
SQL
)"
printf '%s\n' "$action_contract"
require_contains "$action_contract" "action_schema_contract=merge_candidate|new_entity|note|review_flag|update_row" "Expected built-in action schemas"
require_contains "$action_contract" "action_type_contract=merge_candidate|new_entity" "Expected entity-resolution merge_candidate and new_entity actions"
require_contains "$action_contract" "action_status_contract=4|4|4|0" "Expected four trusted valid entity actions"
require_contains "$action_contract" "failed_attempt_action_contract=0" "Expected failed/rejected attempts to create no actions"
require_contains "$action_contract" "action_applyable_contract=create_record:true|merge_candidate:false|new_entity:false|note:true|review_flag:false|update_row:true" "Expected applyable metadata to be schema-driven"

merge_action_id="$(psql_exec -qAt -v task_name="$entity_task" <<'SQL'
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = :'task_name'
  AND action_type = 'merge_candidate';
SQL
)"
new_entity_action_id="$(psql_exec -qAt -v task_name="$entity_task" <<'SQL'
SELECT min(action_id)
FROM otlet.action_status
WHERE task_name = :'task_name'
  AND action_type = 'new_entity';
SQL
)"
[ -n "$merge_action_id" ] && [ -n "$new_entity_action_id" ] || {
  echo "Expected merge_candidate and new_entity action ids" >&2
  exit 1
}

action_approve_contract="$(psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
SELECT status || '|' || approval_status || '|' || COALESCE(review_reason, '')
FROM otlet.approve_action(:'action_id'::bigint, 'demo approval reason');
SQL
)"
echo "action_approve_contract=$action_approve_contract"
[ "$action_approve_contract" = "approved|approved|demo approval reason" ] || {
  echo "Expected merge_candidate approval, got $action_approve_contract" >&2
  exit 1
}

action_review_reason_contract="$(psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
SELECT approval_status || '|' || COALESCE(review_reason, '')
FROM otlet.action_status
WHERE action_id = :'action_id'::bigint;
SQL
)"
echo "action_review_reason_contract=$action_review_reason_contract"
[ "$action_review_reason_contract" = "approved|demo approval reason" ] || {
  echo "Expected approval reason in action_status, got $action_review_reason_contract" >&2
  exit 1
}

action_dry_run_contract="$(psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
SELECT status || '|' || approval_status || '|' || dry_run_status
FROM otlet.dry_run_action(:'action_id'::bigint);
SQL
)"
echo "action_dry_run_contract=$action_dry_run_contract"
[ "$action_dry_run_contract" = "approved|approved|passed" ] || {
  echo "Expected approved action dry-run pass, got $action_dry_run_contract" >&2
  exit 1
}

action_apply_contract="$(psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
SELECT status || '|' || approval_status || '|' || apply_status || '|' || COALESCE(error, '')
FROM otlet.apply_action(:'action_id'::bigint);
SQL
)"
echo "action_apply_contract=$action_apply_contract"
[ "$action_apply_contract" = "approved|approved|not_applicable|action type has no apply path" ] || {
  echo "Expected merge_candidate apply to stay not_applicable, got $action_apply_contract" >&2
  exit 1
}

action_reject_contract="$(psql_exec -qAt -v action_id="$new_entity_action_id" <<'SQL'
SELECT status || '|' || approval_status
FROM otlet.reject_action(:'action_id'::bigint, 'demo rejection');
SQL
)"
echo "action_reject_contract=$action_reject_contract"
[ "$action_reject_contract" = "rejected|rejected" ] || {
  echo "Expected new_entity rejection, got $action_reject_contract" >&2
  exit 1
}

cleanup_task "$posthoc_output_rule_task"
posthoc_output_rule_contract="$(
  psql_exec -qAt -v task_name="$posthoc_output_rule_task" -v model_name="$strong_model_name" <<'SQL'
CREATE TEMP TABLE posthoc_rule_result (
  ord int PRIMARY KEY,
  status text NOT NULL,
  error text NOT NULL
);
CREATE TEMP TABLE posthoc_rule_params (
  task_name text NOT NULL,
  model_name text NOT NULL
);
INSERT INTO posthoc_rule_params VALUES (:'task_name', :'model_name');
DO $$
DECLARE
  task_name_value text;
  model_name_value text;
  selected_job_id bigint;
  selected_action_id bigint;
  action_state otlet.actions%ROWTYPE;
BEGIN
  SELECT task_name, model_name
  INTO task_name_value, model_name_value
  FROM posthoc_rule_params;

  PERFORM otlet.create_task(
    task_name_value,
    $source$
      SELECT 'posthoc-left:posthoc-right'::text AS subject_id,
             '{"action_ids":{"left_id":"posthoc-left","right_id":"posthoc-right"}}'::jsonb AS input
    $source$::text,
    'Return JSON only.',
    '{"type":"object","required":["match","confidence"],"additionalProperties":false,"properties":{"match":{"enum":["same_entity","different_entity"]},"confidence":{"enum":["high"]}}}'::jsonb,
    model_name_value,
    '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
  );

  INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until)
  VALUES (
    task_name_value,
    'posthoc-left:posthoc-right',
    '{"action_ids":{"left_id":"posthoc-left","right_id":"posthoc-right"}}'::jsonb,
    'running',
    1,
    now(),
    now() + interval '5 minutes'
  )
  RETURNING id INTO selected_job_id;

  PERFORM otlet.complete_job(
    selected_job_id,
    '{"match":"same_entity","confidence":"high"}'::jsonb,
    '{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"posthoc-left","right_id":"posthoc-right","confidence":"high","reason":"same"}}]}',
    '[{"type":"merge_candidate","body":{"left_id":"posthoc-left","right_id":"posthoc-right","confidence":"high","reason":"same"}}]'::jsonb,
    NULL,
    NULL,
    NULL,
    md5('{"output":{"match":"same_entity","confidence":"high"},"actions":[{"type":"merge_candidate","body":{"left_id":"posthoc-left","right_id":"posthoc-right","confidence":"high","reason":"same"}}]}'),
    now(),
    '{"schema_validation_status":"passed"}'::jsonb,
    model_name_value
  );

  SELECT a.id
  INTO selected_action_id
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  WHERE j.task_name = task_name_value
  ORDER BY a.id DESC
  LIMIT 1;

  PERFORM otlet.approve_action(selected_action_id);

  SELECT *
  INTO action_state
  FROM otlet.apply_action(selected_action_id);
  INSERT INTO posthoc_rule_result
  VALUES (1, action_state.apply_status, COALESCE(action_state.error, ''));

  UPDATE otlet.outputs o
  SET output = '{"match":"different_entity","confidence":"high"}'::jsonb
  FROM otlet.jobs j
  WHERE o.job_id = j.id
    AND j.task_name = task_name_value;

  SELECT *
  INTO action_state
  FROM otlet.dry_run_action(selected_action_id);
  INSERT INTO posthoc_rule_result
  VALUES (2, action_state.dry_run_status, COALESCE(action_state.error, ''));

  SELECT *
  INTO action_state
  FROM otlet.apply_action(selected_action_id);
  INSERT INTO posthoc_rule_result
  VALUES (3, action_state.apply_status, COALESCE(action_state.error, ''));
END;
$$;
SELECT string_agg(status || '|' || error, '|' ORDER BY ord)
FROM posthoc_rule_result;
SQL
)"
echo "posthoc_output_rule_contract=$posthoc_output_rule_contract"
[ "$posthoc_output_rule_contract" = "not_applicable|action type has no apply path|failed|merge_candidate requires same_entity output|failed|merge_candidate requires same_entity output" ] || {
  echo "Expected post-hoc output_equals validation to fail dry-run/apply, got $posthoc_output_rule_contract" >&2
  exit 1
}

source_rows_after="$(psql_exec -qAt <<'SQL'
SELECT count(*)::text || '|' ||
       md5(string_agg(to_jsonb(v)::text, ',' ORDER BY v.id))
FROM public.otlet_demo_vendor_entity v;
SQL
)"
source_write_contract="$source_rows_before|$source_rows_after"
echo "source_write_contract=$source_write_contract"
[ "$source_rows_before" = "$source_rows_after" ] || {
  echo "Expected action approval/apply to leave source rows unchanged" >&2
  exit 1
}

psql_exec \
  -v merge_action_id="$merge_action_id" \
  -v new_entity_action_id="$new_entity_action_id" >/dev/null <<'SQL'
SELECT * FROM otlet.label_action(:'merge_action_id'::bigint);
SELECT * FROM otlet.label_action(:'new_entity_action_id'::bigint);
SQL
er_eval_label_contract="$(psql_exec -qAt \
  -v merge_action_id="$merge_action_id" \
  -v new_entity_action_id="$new_entity_action_id" <<'SQL'
WITH labels AS (
  SELECT *
  FROM otlet.eval_labels
  WHERE action_id IN (:'merge_action_id'::bigint, :'new_entity_action_id'::bigint)
), exported AS (
  SELECT *
  FROM otlet.export_eval_cases(50)
  WHERE action_id IN (:'merge_action_id'::bigint, :'new_entity_action_id'::bigint)
)
SELECT count(*)::text || '|' ||
       COALESCE(max(labels.expected_answer) FILTER (WHERE labels.action_id = :'merge_action_id'::bigint), '') || '|' ||
       COALESCE(max(exported.case_kind) FILTER (WHERE exported.action_id = :'merge_action_id'::bigint), '') || '|' ||
       COALESCE(max(labels.expected_answer) FILTER (WHERE labels.action_id = :'new_entity_action_id'::bigint), '') || '|' ||
       COALESCE(max(exported.case_kind) FILTER (WHERE exported.action_id = :'new_entity_action_id'::bigint), '')
FROM labels
JOIN exported USING (action_id);
SQL
)"
echo "er_eval_label_contract=$er_eval_label_contract"
[ "$er_eval_label_contract" = "2|same_entity|positive|different_entity|hard_negative" ] || {
  echo "Expected ER eval export parity after expected_answer rename, got $er_eval_label_contract" >&2
  exit 1
}

dry_run_source_identity_contract="$(
  psql_exec -qAt -v action_id="$merge_action_id" <<'SQL'
CREATE TEMP TABLE dry_run_source_identity_original(notes text);
CREATE TEMP TABLE dry_run_source_identity_result(ord int, phase text, status text, dry_run_status text, error text);
INSERT INTO dry_run_source_identity_original
SELECT notes FROM public.otlet_demo_vendor_entity WHERE id = 'vendor-42';
UPDATE public.otlet_demo_vendor_entity
SET notes = replace(notes, 'rebranded after acquisition', 'separate vendor without acquisition')
WHERE id = 'vendor-42';
INSERT INTO dry_run_source_identity_result
SELECT 1, 'after_update', status, dry_run_status, COALESCE(error, '')
FROM otlet.dry_run_action(:action_id);
UPDATE public.otlet_demo_vendor_entity
SET notes = (SELECT notes FROM dry_run_source_identity_original)
WHERE id = 'vendor-42';
INSERT INTO dry_run_source_identity_result
SELECT 2, 'after_revert', status, dry_run_status, COALESCE(error, '')
FROM otlet.dry_run_action(:action_id);
SELECT string_agg(phase || ':' || status || ':' || dry_run_status || ':' || error, '|' ORDER BY ord)
FROM dry_run_source_identity_result;
SQL
)"
echo "dry_run_source_identity_contract=$dry_run_source_identity_contract"
[ "$dry_run_source_identity_contract" = "after_update:approved:failed:source identity stale|after_revert:approved:passed:" ] || {
  echo "Expected dry-run source identity failure after edit and pass after revert, got $dry_run_source_identity_contract" >&2
  exit 1
}

