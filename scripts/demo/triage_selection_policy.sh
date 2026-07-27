log "Running non-ER triage selection policy"
psql_exec \
  -v cheap_policy_model="$strong_model_name" \
  -v strong_policy_model="$strong_alias_model_name" \
  -v row_triage_policy_watch="$row_triage_policy_watch" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_triage_policy_signal;
CREATE TABLE public.otlet_demo_triage_policy_signal (
  id text PRIMARY KEY,
  blockers integer NOT NULL,
  approvals integer NOT NULL,
  evidence text NOT NULL
);

SELECT otlet.create_watch(
  :'row_triage_policy_watch',
  'row',
  'Classify one operational row. Use input.row.blockers and input.row.approvals. If blockers > 0, output decision flag with confidence high and one review_flag action. If blockers = 0 and approvals > 0, output decision pass with confidence high and no actions. Otherwise output decision unclear with confidence medium and one review_flag action with severity medium and a short reason. Return JSON only.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["flag", "pass", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 160}
    }
  }'::jsonb,
  :'cheap_policy_model',
  'public.otlet_demo_triage_policy_signal'::regclass,
  'id',
  NULL,
  'demo_triage_policy_fact',
  '{"max_tokens":160,"reasoning":"off","inference_cache":true}'::jsonb,
  jsonb_build_object(
    'cheap_model_name', :'cheap_policy_model',
    'strong_model_name', :'strong_policy_model'
  ),
  '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  ARRAY['review_flag'],
  'refresh_then_fail_closed',
  '{"source_fields":["row"]}'::jsonb,
  '{"preset":"row_triage_decision_v1"}'::jsonb
);

INSERT INTO public.otlet_demo_triage_policy_signal
VALUES (
  'triage-unclear',
  0,
  0,
  'No decisive blocker and no approval evidence; send to human review'
);
SQL
wait_task_complete "$row_triage_policy_task" 1 900 1

row_triage_policy_contract="$(psql_exec -qAt -v task_name="$row_triage_policy_task" <<'SQL'
WITH attempts AS (
  SELECT selection_role, selection_status, selection_reason
  FROM otlet.model_selection_attempts
  WHERE task_name = :'task_name'
)
SELECT
  (SELECT count(*) FROM attempts WHERE selection_role = 'cheap' AND selection_status = 'rejected' AND selection_reason = 'abstained_output')::text || '|' ||
  (SELECT count(*) FROM attempts WHERE selection_role = 'strong' AND selection_status = 'accepted')::text || '|' ||
  COALESCE((SELECT output->>'decision' FROM otlet.runs WHERE task_name = :'task_name'), '') || '|' ||
  (SELECT count(*) FROM otlet.action_status WHERE task_name = :'task_name' AND action_type = 'review_flag')::text;
SQL
)"
echo "row_triage_policy_contract=$row_triage_policy_contract"
[ "$row_triage_policy_contract" = "1|1|unclear|1" ] || {
  echo "Expected declared triage policy to reject cheap unclear then accept strong unclear with one review action, got $row_triage_policy_contract" >&2
  exit 1
}
row_triage_preset_contract="$(psql_exec -qAt -v task_name="$row_triage_policy_task" <<'SQL'
SELECT COALESCE(t.decision_contract ->> 'preset', '') || '|' ||
       ((t.decision_contract ->> 'preset_contract_hash') ~ '^[0-9a-f]{32}$')::text || '|' ||
       COALESCE(p.accept_field_checks ->> 'answer_field', '') || '|' ||
       (p.accept_field_checks -> 'abstain_values' ? 'unclear')::text || '|' ||
       (p.accept_field_checks -> 'accepted_confidence' ? 'medium')::text
FROM otlet.tasks t
JOIN otlet.model_selection_policies p ON p.task_name = t.name
WHERE t.name = :'task_name';
SQL
)"
echo "row_triage_preset_contract=$row_triage_preset_contract"
[ "$row_triage_preset_contract" = "row_triage_decision_v1|true|decision|true|true" ] || {
  echo "Expected triage preset to drive selection policy labels, got $row_triage_preset_contract" >&2
  exit 1
}
set +e
model_selection_shape_output="$(
  psql_exec -qAt \
    -v task_name="$row_triage_policy_task" \
    -v cheap_policy_model="$strong_model_name" \
    -v strong_policy_model="$strong_alias_model_name" 2>&1 <<'SQL'
SELECT otlet.set_model_selection_policy(
  :'task_name',
  :'cheap_policy_model',
  :'strong_policy_model',
  '{"abstain_values":["unclear"]}'::jsonb
);
SQL
)"
model_selection_shape_status=$?
set -e
if [ "$model_selection_shape_status" -eq 0 ]; then
  echo "Expected orphan abstain_values policy to be rejected" >&2
  exit 1
fi
require_contains "$model_selection_shape_output" "otlet accept_field_checks.abstain_values requires answer_field" "Expected orphan abstain_values rejection message"
echo "model_selection_shape_contract=rejected"
row_triage_preset_trace_contract="$(psql_exec -qAt -v task_name="$row_triage_policy_task" <<'SQL'
SELECT COALESCE(s.decision_preset_name, '') || '|' ||
       (s.decision_preset_contract_hash = t.decision_contract ->> 'preset_contract_hash')::text || '|' ||
       (s.decision_preset_contract_hash = md5(otlet.semantic_canonical_jsonb(p.decision_contract)::text))::text
FROM otlet.inference_receipt_trace_status s
JOIN otlet.tasks t ON t.name = s.task_name
JOIN otlet.decision_rule_presets p ON p.name = s.decision_preset_name
WHERE s.task_name = :'task_name'
  AND s.selection_role = 'strong'
  AND s.selection_status = 'accepted'
ORDER BY s.receipt_id DESC
LIMIT 1;
SQL
)"
echo "row_triage_preset_trace_contract=$row_triage_preset_trace_contract"
[ "$row_triage_preset_trace_contract" = "row_triage_decision_v1|true|true" ] || {
  echo "Expected receipt trace status to expose row triage preset provenance, got $row_triage_preset_trace_contract" >&2
  exit 1
}
preset_immutability_contract="$(
  psql_exec -qAt <<'SQL'
DO $$
BEGIN
  UPDATE otlet.decision_rule_presets
  SET decision_contract = decision_contract || '{"demo_edit":true}'::jsonb
  WHERE name = 'row_triage_decision_v1';
  RAISE EXCEPTION 'expected preset update to be rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'otlet decision rule preset row_triage_decision_v1 is immutable%' THEN
      RAISE;
    END IF;
END;
$$;
SELECT 'raised';
SQL
)"
echo "preset_immutability_contract=$preset_immutability_contract"
[ "$preset_immutability_contract" = "raised" ] || {
  echo "Expected decision rule preset updates to be rejected, got $preset_immutability_contract" >&2
  exit 1
}
row_triage_abstention_contract="$(psql_exec -qAt -v task_name="$row_triage_policy_task" <<'SQL'
WITH task_abstentions AS (
  SELECT count(*)::bigint AS abstained_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  CROSS JOIN LATERAL (
    SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
           COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
  ) contract
  WHERE j.task_name = :'task_name'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
)
SELECT task_abstentions.abstained_outputs::text || '|' ||
       output_reliability_status.abstained_outputs::text
FROM task_abstentions
CROSS JOIN otlet.output_reliability_status;
SQL
)"
echo "row_triage_abstention_contract=$row_triage_abstention_contract"
require_regex "$row_triage_abstention_contract" '^[1-9][0-9]*\|[1-9][0-9]*$' "Expected nonzero abstention counters for the triage preset"

psql_exec \
  -v task_name="$skip_abstain_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
SELECT otlet.create_task(
  :'task_name',
  $source$
    SELECT 'skip-1'::text AS subject_id,
           '{"row":{"note":"no evidence available"}}'::jsonb AS input
  $source$::text,
  'Return decision skip with confidence medium and no actions. Return JSON only.',
  '{"type":"object","required":["decision","confidence"],"additionalProperties":false,"properties":{"decision":{"enum":["skip"]},"confidence":{"enum":["medium"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["row"]}'::jsonb,
  '{"answer_field":"decision","abstain_values":["skip"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);
SELECT otlet.run_task(:'task_name');
SQL
wait_task_complete "$skip_abstain_task" 1 900 1
skip_abstention_contract="$(psql_exec -qAt -v task_name="$skip_abstain_task" <<'SQL'
WITH task_abstentions AS (
  SELECT count(*)::bigint AS abstained_outputs
  FROM otlet.outputs o
  JOIN otlet.jobs j ON j.id = o.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  CROSS JOIN LATERAL (
    SELECT COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
           COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb) AS abstain_values
  ) contract
  WHERE j.task_name = :'task_name'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(contract.abstain_values) value(abstain_value)
      WHERE o.output ->> contract.answer_field = value.abstain_value
    )
)
SELECT task_abstentions.abstained_outputs::text || '|' ||
       (output_reliability_status.abstained_outputs >= task_abstentions.abstained_outputs)::text
FROM task_abstentions
CROSS JOIN otlet.output_reliability_status;
SQL
)"
echo "skip_abstention_contract=$skip_abstention_contract"
[ "$skip_abstention_contract" = "1|true" ] || {
  echo "Expected non-default skip abstention vocabulary to count, got $skip_abstention_contract" >&2
  exit 1
}
