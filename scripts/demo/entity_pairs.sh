log "Running entity-resolution demo"
psql_exec -v join_index_name="$join_index_name" >/dev/null <<'SQL'
SELECT otlet.drop_watch(:'join_index_name');
SQL
cleanup_task "$entity_task"
cleanup_task "$join_task"

psql_exec >/dev/null <<'SQL'
DROP VIEW IF EXISTS public.otlet_demo_vendor_pair_input;
DROP TABLE IF EXISTS public.otlet_demo_vendor_pair;
DROP TABLE IF EXISTS public.otlet_demo_vendor_entity;
CREATE TABLE public.otlet_demo_vendor_entity (
  id text PRIMARY KEY,
  legal_name text NOT NULL,
  website text,
  address text,
  notes text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.otlet_demo_vendor_pair (
  pair_id text PRIMARY KEY,
  left_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id),
  right_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id)
);
INSERT INTO public.otlet_demo_vendor_entity (id, legal_name, website, address, notes)
VALUES
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; tax id 36-9918821; remittance account ending 8821; AP contact ops@northstar-logistics.example'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821 and same tax id 36-9918821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor'),
  ('vendor-313', 'North Star Medical Logistics', 'northstarmedlog.example', '41 West Lake Street, Chicago, IL', 'medical logistics broker; same building and similar name, but verified separate legal entity; different tax id 92-4403130; different remittance account ending 1199; different domain, payment account, AP contact, and no acquisition note'),
  ('vendor-314', 'Northstar Freight Canada Inc.', 'northstar-canada.example', '88 King St W, Toronto, ON', 'Canadian freight carrier with similar brand; different country, tax id CA-771314, bank account ending 4410, AP contact, and no shared remittance account or acquisition note in the ledger');
INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES
  ('vendor-1001:vendor-42', 'vendor-1001', 'vendor-42'),
  ('vendor-1001:vendor-77', 'vendor-1001', 'vendor-77'),
  ('vendor-1001:vendor-313', 'vendor-1001', 'vendor-313'),
  ('vendor-1001:vendor-314', 'vendor-1001', 'vendor-314');
CREATE VIEW public.otlet_demo_vendor_pair_input AS
SELECT
  p.pair_id AS subject_id,
  jsonb_build_object(
    '_otlet_mvcc', jsonb_build_object(
      'table', 'public.otlet_demo_vendor_entity',
      'subject_id', p.pair_id,
      'left_id', p.left_id,
      'right_id', p.right_id,
      'left_ctid', l.ctid::text,
      'left_xmin', l.xmin::text,
      'right_ctid', r.ctid::text,
      'right_xmin', r.xmin::text
    ),
    'candidate_evidence', evidence.candidate_evidence,
    'evidence_counts', jsonb_build_object(
      'shared_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'shared_stable_identifiers'),
      'conflicting_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'conflicting_stable_identifiers'),
      'weak_matching_signals', jsonb_array_length(evidence.candidate_evidence -> 'weak_matching_signals'),
      'missing_or_unknown_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'missing_or_unknown_identifiers'),
      'row_quality_warnings', jsonb_array_length(evidence.candidate_evidence -> 'row_quality_warnings')
    ),
    'action_ids', jsonb_build_object('left_id', p.left_id, 'right_id', p.right_id)
  ) AS input
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity l ON l.id = p.left_id
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
CROSS JOIN LATERAL (
  SELECT CASE p.pair_id
    WHEN 'vendor-1001:vendor-42' THEN jsonb_build_object(
      'shared_stable_identifiers', jsonb_build_array(
        'same remittance account ending 8821',
        'same tax id 36-9918821',
        CASE
          WHEN r.notes ILIKE '%rebranded after acquisition%' THEN 'Northstar rebrand after acquisition'
          ELSE 'no rebrand evidence in notes'
        END
      ),
      'conflicting_stable_identifiers', '[]'::jsonb,
      'weak_matching_signals', jsonb_build_array('similar address'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-77' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'different industry and city',
        'no shared tax id, domain, payment account, AP contact, or remittance account'
      ),
      'weak_matching_signals', '[]'::jsonb,
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-313' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'medical logistics versus freight vendor',
        'different tax id 92-4403130',
        'different remittance account ending 1199',
        'different domain, payment account, AP contact, and no acquisition note'
      ),
      'weak_matching_signals', jsonb_build_array('same office building', 'similar North Star name'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    WHEN 'vendor-1001:vendor-314' THEN jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', jsonb_build_array(
        'different country and Canadian legal entity',
        'different tax id CA-771314',
        'different bank account ending 4410, AP contact, and no shared remittance account',
        'no acquisition or rebrand note connecting the records'
      ),
      'weak_matching_signals', jsonb_build_array('similar Northstar freight brand'),
      'missing_or_unknown_identifiers', '[]'::jsonb,
      'row_quality_warnings', '[]'::jsonb
    )
    ELSE jsonb_build_object(
      'shared_stable_identifiers', '[]'::jsonb,
      'conflicting_stable_identifiers', '[]'::jsonb,
      'weak_matching_signals', '[]'::jsonb,
      'missing_or_unknown_identifiers', jsonb_build_array('no decisive identity evidence'),
      'row_quality_warnings', '[]'::jsonb
    )
  END AS candidate_evidence
) evidence;
SQL

source_rows_before="$(psql_exec -qAt <<'SQL'
SELECT count(*)::text || '|' ||
       md5(string_agg(to_jsonb(v)::text, ',' ORDER BY v.id))
FROM public.otlet_demo_vendor_entity v;
SQL
)"

psql_exec \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v task_name="$entity_task" \
  -v record_type="$record_type" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  :'entity_instruction',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  :'cheap_model_name',
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
  '{"preset":"entity_resolution_evidence_v1"}'::jsonb
);

SELECT otlet.set_model_selection_policy(:'task_name', :'cheap_model_name', :'strong_model_name');
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$entity_task" 4 1800 1

entity_contract="$(psql_exec -qAt -v task_name="$entity_task" <<'SQL'
SELECT count(*) FILTER (WHERE r.status = 'complete')::text || '|' ||
       COALESCE(max(r.output->>'match') FILTER (WHERE r.subject_id = 'vendor-1001:vendor-42'), '') || '|' ||
       COALESCE(max(r.output->>'match') FILTER (WHERE r.subject_id = 'vendor-1001:vendor-77'), '') || '|' ||
       count(*) FILTER (WHERE r.receipt_id IS NOT NULL)::text || '|' ||
       count(*) FILTER (WHERE r.schema_validation_status = 'passed')::text
FROM otlet.runs r
WHERE r.task_name = :'task_name';
SQL
)"
echo "entity_resolution_contract=$entity_contract"
[ "$entity_contract" = "4|same_entity|different_entity|4|4" ] || {
  echo "Entity-resolution proof failed: $entity_contract" >&2
  exit 1
}

entity_selection_contracts="$(psql_value -v task_name="$entity_task" <<'SQL'
SELECT
  (
    SELECT task_name || '|' || cheap_model_name || '|' || strong_model_name || '|' ||
           COALESCE(task_max_attempt_ms::text, '') || '|' ||
           policy_max_attempt_ms::text || '|' ||
           effective_max_attempt_ms::text
    FROM otlet.model_selection_policy_status
    WHERE task_name = :'task_name'
  ) || E'\n' ||
  (
    SELECT (cheap_attempts >= 1)::text || '|' ||
           (strong_accepted >= 1)::text || '|' ||
           (escalated_jobs >= 1)::text || '|' ||
           cheap_attempts::text || '|' ||
           strong_attempts::text
    FROM otlet.model_selection_status
    WHERE task_name = :'task_name'
  );
SQL
)"
model_selection_policy_contract="$(sed -n '1p' <<<"$entity_selection_contracts")"
model_selection_status_contract="$(sed -n '2p' <<<"$entity_selection_contracts")"
echo "model_selection_policy_contract=$model_selection_policy_contract"
[ "$model_selection_policy_contract" = "$entity_task|$cheap_model_name|$strong_model_name||300000|300000" ] || {
  echo "Expected model selection policy contract, got $model_selection_policy_contract" >&2
  exit 1
}

model_selection_attempts="$(psql_value -v task_name="$entity_task" <<'SQL'
SELECT subject_id || '|' || attempt_index::text || '|' || selection_role || '|' ||
       selection_status || '|' || model_name || '|' ||
       COALESCE(output->>'confidence', '') || '|' || COALESCE(output->>'match', '')
FROM otlet.model_selection_attempts
WHERE task_name = :'task_name'
ORDER BY subject_id, attempt_index;
SQL
)"
while IFS= read -r line; do
  [ -n "$line" ] && echo "model_selection_attempt_contract=$line"
done <<<"$model_selection_attempts"

echo "model_selection_status_contract=$model_selection_status_contract"
require_regex "$model_selection_status_contract" '^true\|true\|true\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected cheap attempts, strong acceptance, and escalation"

model_swap_contract="$(psql_exec -qAt \
  -v started_at="$script_started" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" <<'SQL'
WITH swaps AS (
  SELECT detail
  FROM otlet.worker_events
  WHERE event_type = 'model_swap'
    AND created_at >= :'started_at'::timestamptz
)
SELECT (count(*) FILTER (WHERE detail ->> 'model_name' = :'cheap_model_name') >= 1)::text || '|' ||
       (count(*) FILTER (WHERE detail ->> 'model_name' = :'strong_model_name') >= 1)::text || '|' ||
       COALESCE(bool_and(
         COALESCE((detail ->> 'load_ms')::bigint, -1) >= 0
         AND COALESCE((detail ->> 'model_memory_bytes')::bigint, 0) > 0
         AND COALESCE((detail ->> 'worker_process_rss_bytes')::bigint, 0) > 0
         AND (
           COALESCE((detail ->> 'worker_memory_budget_bytes')::bigint, 0) = 0
           OR COALESCE((detail ->> 'worker_process_rss_bytes')::bigint, 0)
              <= COALESCE((detail ->> 'worker_memory_budget_bytes')::bigint, 0)
         )
       ), false)::text
FROM swaps;
SQL
)"
echo "model_swap_contract=$model_swap_contract"
[ "$model_swap_contract" = "true|true|true" ] || {
  echo "Expected model swap events for cheap and strong models with memory evidence, got $model_swap_contract" >&2
  exit 1
}

accepted_output_anomalies="$(psql_exec -qAt <<'SQL'
SELECT count(*)
FROM (
  SELECT job_id
  FROM otlet.outputs
  GROUP BY job_id
  HAVING count(*) <> 1
) bad;
SQL
)"
echo "accepted_output_anomalies=$accepted_output_anomalies"
[ "$accepted_output_anomalies" = "0" ] || {
  echo "Expected exactly one accepted output per completed job" >&2
  exit 1
}

action_contract="$(psql_exec -qAt -v task_name="$entity_task" <<'SQL'
WITH schema_check AS (
  SELECT string_agg(action_type, '|' ORDER BY action_type) AS value
  FROM otlet.action_type_schemas
  WHERE action_type IN ('merge_candidate', 'new_entity', 'note', 'review_flag')
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
  WHERE action_type IN ('create_record', 'merge_candidate', 'new_entity', 'note', 'review_flag')
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
require_contains "$action_contract" "action_schema_contract=merge_candidate|new_entity|note|review_flag" "Expected built-in action schemas"
require_contains "$action_contract" "action_type_contract=merge_candidate|new_entity" "Expected entity-resolution merge_candidate and new_entity actions"
require_contains "$action_contract" "action_status_contract=4|4|4|0" "Expected four trusted valid entity actions"
require_contains "$action_contract" "failed_attempt_action_contract=0" "Expected failed/rejected attempts to create no actions"
require_contains "$action_contract" "action_applyable_contract=create_record:true|merge_candidate:false|new_entity:false|note:true|review_flag:false" "Expected applyable metadata to be schema-driven"

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

log "Building entity-resolution pair watch"
psql_exec \
  -v join_index_name="$join_index_name" \
  -v cheap_model_name="$cheap_model_name" \
  -v strong_model_name="$strong_model_name" \
  -v record_type="$record_type" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
SELECT name, task_name, record_type, max_candidate_rows
FROM otlet.create_watch(
  watch_name => :'join_index_name',
  kind => 'pair',
  instruction => :'entity_instruction',
  output_schema => '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  model_name => :'cheap_model_name',
  candidate_query => $$
    SELECT subject_id, input
    FROM public.otlet_demo_vendor_pair_input
    ORDER BY subject_id
  $$,
  record_type => :'record_type',
  runtime_options => '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb,
  selection_policy => jsonb_build_object(
    'cheap_model_name', :'cheap_model_name',
    'strong_model_name', :'strong_model_name'
  ),
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  action_types => ARRAY['merge_candidate', 'new_entity', 'review_flag'],
  input_shaping => '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
  decision_contract => '{"preset":"entity_resolution_evidence_v1"}'::jsonb,
  max_candidate_rows => 10
);
SQL

queued="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT otlet.refresh_semantic_join_index(:'index_name');
SQL
)"
echo "semantic_join_refresh_queued=$queued"
[ "$queued" = "4" ] || {
  echo "Expected 4 semantic join jobs, got $queued" >&2
  exit 1
}
wait_task_complete "$join_task" 4 1800 1
throughput_contracts="$(psql_exec -qAt \
  -v task_name="$join_task" \
  -v record_type="$record_type" \
  -v model_name="$cheap_model_name" <<'SQL'
SELECT count(*) FILTER (WHERE a.action_type = 'create_record' AND a.status = 'complete')::text || '|' ||
       count(*) FILTER (WHERE r.record_type = :'record_type')::text
FROM otlet.jobs j
LEFT JOIN otlet.actions a ON a.job_id = j.id
LEFT JOIN otlet.records r ON r.action_id = a.id
WHERE j.task_name = :'task_name';

SELECT count(*)
FROM otlet.semantic_materializations
WHERE task_name = :'task_name'
  AND record_type = :'record_type'
  AND stale = false;

SELECT q.queue_state || '|' ||
       w.queued_jobs::text || '|' ||
       w.running_jobs::text || '|' ||
       w.last_batch_jobs::text || '|' ||
       w.last_batch_completed_jobs::text || '|' ||
       w.last_batch_failed_jobs::text
FROM otlet.worker_throughput_status w
JOIN otlet.model_queue_status q ON q.model_name = w.model_name
WHERE w.model_name = :'model_name';
SQL
)"
auto_records="$(sed -n '1p' <<<"$throughput_contracts")"
materialized="$(sed -n '2p' <<<"$throughput_contracts")"
throughput_status_contract="$(sed -n '3p' <<<"$throughput_contracts")"
echo "semantic_join_auto_records=$auto_records"
[ "$auto_records" = "4|4" ] || {
  echo "Expected 4 auto actions and records, got $auto_records" >&2
  exit 1
}

echo "semantic_join_auto_materialized=$materialized"
[ "$materialized" = "4" ] || {
  echo "Expected 4 automatic semantic join materializations, got $materialized" >&2
  exit 1
}

echo "throughput_status_contract=$throughput_status_contract"
[ "$throughput_status_contract" = "queue_accepting|0|0|4|4|0" ] || {
  echo "Expected throughput status contract queue_accepting|0|0|4|4|0, got $throughput_status_contract" >&2
  exit 1
}

join_status_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name');
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       fail_closed_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name', true);
SQL
)"
join_status_estimated="$(head -n 1 <<<"$join_status_contract")"
join_status_exact="$(tail -n 1 <<<"$join_status_contract")"
echo "semantic_join_status_contract=$join_status_contract"
[ "$join_status_estimated|$join_status_exact" = "semantic_join_lookup|4|4|0|0|0|0|estimated|semantic_join_lookup|4|4|0|0|0|0|exact" ] || {
  echo "Expected fresh semantic join status, got $join_status_contract" >&2
  exit 1
}

pair_watch_status_contract="$(psql_exec -qAt -v watch_name="$join_index_name" <<'SQL'
SELECT watch_name || '|' || kind || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       queued_jobs::text || '|' ||
       complete_jobs::text || '|' ||
       (proposed_actions >= 4)::text
FROM otlet.watch_status
WHERE watch_name = :'watch_name';
SQL
)"
echo "pair_watch_status_contract=$pair_watch_status_contract"
[ "$pair_watch_status_contract" = "$join_index_name|pair|4|4|0|0|0|4|true" ] || {
  echo "Expected pair watch status to show four fresh completed subjects, got $pair_watch_status_contract" >&2
  exit 1
}

join_lookup_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"same_entity"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"different_entity"}'::jsonb)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SQL
)"
echo "semantic_join_lookup_contract=$join_lookup_contract"
require_regex "$join_lookup_contract" '^4\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected semantic join lookup to include 4 rows, at least one same_entity, and at least one different_entity"

join_match_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT otlet.semantic_join_matches(:'index_name', 'vendor-1001:vendor-42', '{"match":"same_entity"}'::jsonb)::text || '|' ||
       otlet.semantic_join_matches(:'index_name', 'vendor-1001:vendor-77', '{"match":"different_entity"}'::jsonb)::text;
SQL
)"
echo "semantic_join_match_contract=$join_match_contract"
[ "$join_match_contract" = "true|true" ] || {
  echo "Expected semantic join matches, got $join_match_contract" >&2
  exit 1
}
join_customscan_plan="$(
  psql_exec -P border=2 -P null='' -v index_name="$join_index_name" <<'SQL'
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT subject_id
FROM (
  SELECT subject_id
  FROM public.otlet_demo_vendor_pair_input
  OFFSET 0
) pair_subjects
WHERE otlet.semantic_join_matches_auto(:'index_name', subject_id, '{"match":"same_entity"}'::jsonb);
SQL
)"
printf '%s\n' "$join_customscan_plan"
require_contains "$join_customscan_plan" "Otlet Node: Semantic Source CustomScan" "Expected join CustomScan explain details"
require_contains "$join_customscan_plan" "Semantic Index Kind: join" "Expected join CustomScan index kind"
require_contains "$join_customscan_plan" "Planner Selected Path: semantic_join_lookup" "Expected join CustomScan lookup path"
require_contains "$join_customscan_plan" "Count Basis: estimated" "Expected join CustomScan estimated count basis"
require_contains "$join_customscan_plan" "Model Cost Source:" "Expected join CustomScan model cost source"
require_contains "$join_customscan_plan" "Preloaded Fresh Subjects / Basis: 4" "Expected join CustomScan preload count and basis"
require_contains "$join_customscan_plan" "Emitted Freshness Basis:" "Expected join CustomScan emitted freshness basis breakdown"
require_contains "$join_customscan_plan" "Actual Fresh Subjects: 4" "Expected join CustomScan fresh count"
require_contains "$join_customscan_plan" "Actual Stale Subjects: 0" "Expected join CustomScan stale count"
require_contains "$join_customscan_plan" "Actual Lookup Rows: 4" "Expected join CustomScan lookup rows"
require_contains "$join_customscan_plan" "Infer Now Batches: 0" "Expected join CustomScan zero infer-now"
require_contains "$join_customscan_plan" "Child Plan Source Rows: 4" "Expected join CustomScan child rows"

join_current_row_contract="$(psql_exec -qAt -v index_name="$join_index_name" <<'SQL'
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true)
WHERE subject_id = 'vendor-1001:vendor-42';
SELECT selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       queue_subjects::text || '|' ||
       count_basis
FROM otlet.semantic_join_index_plan(:'index_name', true);
SQL
)"
join_subject_rows="$(head -n 1 <<<"$join_current_row_contract")"
join_sql_plan="$(tail -n 1 <<<"$join_current_row_contract")"
echo "semantic_join_current_row_contract=$join_subject_rows|$join_sql_plan"
[ "$join_subject_rows" = "1" ] || {
  echo "Expected semantic join current-row SQL to expose vendor-1001:vendor-42, got $join_subject_rows" >&2
  exit 1
}
require_regex "$join_sql_plan" '^semantic_join_lookup\|4\|4\|0\|0\|' "Expected semantic join SQL plan lookup with four fresh subjects"

log "Checking entity-resolution dependency update"
join_receipts_before_update="$(psql_exec -qAt -v task_name="$join_task" <<'SQL'
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
psql_exec >/dev/null <<'SQL'
SELECT otlet.watch_semantic_stale('public.otlet_demo_vendor_entity'::regclass, 'id');
UPDATE public.otlet_demo_vendor_entity
SET notes = notes || '; updated AP contact confirms remittance migration',
    updated_at = clock_timestamp()
WHERE id = 'vendor-1001';
SQL
join_stale_contract="$(psql_exec -qAt \
  -v index_name="$join_index_name" \
  -v task_name="$join_task" <<'SQL'
SELECT stale_subjects::text || '|' || fresh_subjects::text
FROM otlet.semantic_join_index_plan(:'index_name');
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SELECT count(*)::text
FROM otlet.inference_receipts ar
JOIN otlet.jobs j ON j.id = ar.job_id
WHERE j.task_name = :'task_name';
SQL
)"
join_stale_subjects="$(head -n 1 <<<"$join_stale_contract")"
join_fresh_after_lookup="$(sed -n '2p' <<<"$join_stale_contract")"
join_receipts_after_update="$(tail -n 1 <<<"$join_stale_contract")"
echo "semantic_join_stale_contract=$join_stale_subjects|fresh_after_lookup=$join_fresh_after_lookup|receipts=$join_receipts_before_update|$join_receipts_after_update"
if [ "$join_stale_subjects|$join_fresh_after_lookup" != "4|0|0" ] || [ "$join_receipts_before_update" != "$join_receipts_after_update" ]; then
  echo "Expected semantic join dependency update to fail closed with unchanged receipts, got $join_stale_subjects|$join_fresh_after_lookup|$join_receipts_before_update|$join_receipts_after_update" >&2
  exit 1
fi

log "Checking contract-change freshness invalidation"
psql_exec -v task_name="$join_task" >/dev/null <<'SQL'
WITH current_task AS (
  SELECT *
  FROM otlet.tasks
  WHERE name = :'task_name'
)
SELECT (otlet.create_task(
    name,
    input_query,
    instruction || ' Contract drift demo.',
    output_schema,
    model_name,
    runtime_options,
    input_shaping,
    decision_contract
  )).name
FROM current_task;
SQL
contract_change_contract="$(psql_exec -qAt \
  -v task_name="$join_task" \
  -v index_name="$join_index_name" <<'SQL'
SELECT count(*) FILTER (WHERE sm.stale_reason = 'contract_changed')::text || '|' ||
       count(*) FILTER (WHERE sm.stale)::text
FROM otlet.semantic_materializations sm
WHERE sm.task_name = :'task_name';
SELECT count(*)::text
FROM otlet.semantic_join_index_current_rows(:'index_name', true);
SQL
)"
contract_change_counts="$(head -n 1 <<<"$contract_change_contract")"
contract_change_fresh="$(tail -n 1 <<<"$contract_change_contract")"
echo "contract_change_contract=$contract_change_counts|fresh_after_contract_change=$contract_change_fresh"
[ "$contract_change_counts|$contract_change_fresh" = "4|4|0" ] || {
  echo "Expected contract-change freshness invalidation 4|4|0, got $contract_change_counts|$contract_change_fresh" >&2
  exit 1
}

trace_contract="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT count(*) FILTER (WHERE receipt_id > 0)::text || '|' ||
       count(*) FILTER (WHERE prompt_tokens > 0)::text || '|' ||
       count(*) FILTER (WHERE generated_tokens >= 0)::text || '|' ||
       count(*) FILTER (WHERE schema_validation_status = 'passed')::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "receipt_trace_contract=$trace_contract"
[ "$trace_contract" = "8|8|8|8" ] || {
  echo "Expected receipt trace contract 8|8|8|8, got $trace_contract" >&2
  exit 1
}

timing_contract="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT count(*) FILTER (WHERE finish_sql_ms IS NOT NULL)::text || '|' ||
       count(*) FILTER (WHERE materialize_ms IS NOT NULL AND accepted)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "receipt_timing_contract=$timing_contract"
[ "$timing_contract" = "8|8" ] || {
  echo "Expected receipt timing contract 8|8, got $timing_contract" >&2
  exit 1
}

visibility_status="$(psql_exec -qAt \
  -v entity_task="$entity_task" \
  -v join_task="$join_task" <<'SQL'
SELECT (count(*) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens), 0) > 0)::text || '|' ||
       (COALESCE(sum(detailed_trace_captured_tokens * detailed_trace_top_k), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_max_tokens), 0) > 0)::text || '|' ||
       (COALESCE(max(detailed_trace_top_k), 0) = 3)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name IN (:'entity_task', :'join_task')
  AND status = 'complete';
SQL
)"
echo "inference_visibility_status=$visibility_status"
require_contains "$visibility_status" "true|true|true|true|true" "Expected bounded token/top-k trace visibility counters"

cleanup_dry_run="$(psql_exec -qAt <<'SQL'
SELECT worker_events::text || '|' ||
       token_trace_rows::text || '|' ||
       token_alternative_rows::text || '|' ||
       eval_labels::text || '|' ||
       delete_stale_materializations::text || '|' ||
       rejected_receipt_raw_outputs::text || '|' ||
       failed_canceled_jobs::text || '|' ||
       dry_run::text
FROM otlet.cleanup_policy_state(true);
SQL
)"
echo "cleanup_policy_dry_run=$cleanup_dry_run"
require_regex "$cleanup_dry_run" '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|true$' "Expected cleanup dry run counts ending in true"
