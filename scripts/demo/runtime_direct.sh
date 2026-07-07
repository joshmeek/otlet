log "Running direct ask demo"
psql_exec >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.readme_vendor_note;
CREATE TABLE public.readme_vendor_note (
  id text PRIMARY KEY,
  vendor_name text NOT NULL,
  note text NOT NULL
);
INSERT INTO public.readme_vendor_note VALUES (
  'note-1',
  'Northstar Logistics LLC',
  'AP says the bank account changed two days after a domain change. The request came from a new contact using urgent language. The invoice amount matches the open PO, but the remittance account does not match the vendor master record.'
);
SQL

direct_ask_output="$(
  psql_exec -qAt -v model_name="$strong_model_name" <<'SQL'
WITH asked AS (
  SELECT *
  FROM otlet.ask(
    :'model_name',
    'Read one vendor note. Return one JSON object with exactly two top-level keys: "output" then "actions". output has summary under 12 words, route, and reason under 10 words. route must be approve, review_payment, or block_payment. actions must be the empty array []. Do not close the outer object until after "actions":[] has been written. No markdown.',
    (SELECT jsonb_build_object('vendor_name', vendor_name, 'note', note)
     FROM public.readme_vendor_note
     WHERE id = 'note-1'),
    '{"type":"object","required":["summary","route","reason"],"additionalProperties":false,"properties":{"summary":{"type":"string"},"route":{"enum":["approve","review_payment","block_payment"]},"reason":{"type":"string"}}}'::jsonb,
    '{"max_tokens":128,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":16,"generation_trace_top_k":3}'::jsonb
  )
)
SELECT output->>'route' AS route, job_id, receipt_id
FROM asked
\gset direct_ask_
SELECT 'direct_ask_contract=' || :'direct_ask_route' || '|' || :'direct_ask_job_id' || '|' || :'direct_ask_receipt_id';
SELECT 'direct_ask_receipt_contract=' || s.model_name || '|' || s.status || '|' ||
       s.schema_validation_status || '|' || s.detailed_trace_captured_tokens::text
FROM otlet.inference_receipt_trace_status s
WHERE s.receipt_id = :'direct_ask_receipt_id'::bigint;
SELECT 'direct_ask_cache_contract=' || s.inference_cache_hit::text || '|' ||
       COALESCE(s.inference_cache_reason, '') || '|' ||
       COALESCE(s.inference_cache_key_basis, '') || '|' ||
       (COALESCE(s.inference_cache_max_entries, 0) > 0)::text || '|' ||
       COALESCE(s.inference_cache_eviction_reason, '')
FROM otlet.inference_receipt_trace_status s
WHERE s.receipt_id = :'direct_ask_receipt_id'::bigint;
SQL
)"
printf '%s\n' "$direct_ask_output"
direct_ask_contract="$(sed -n 's/^direct_ask_contract=//p' <<<"$direct_ask_output")"
direct_ask_receipt_contract="$(sed -n 's/^direct_ask_receipt_contract=//p' <<<"$direct_ask_output")"
direct_ask_cache_contract="$(sed -n 's/^direct_ask_cache_contract=//p' <<<"$direct_ask_output")"
require_regex "$direct_ask_contract" '^review_payment\|[1-9][0-9]*\|[1-9][0-9]*$' "Expected direct ask to return review_payment with job and receipt ids"
require_regex "$direct_ask_receipt_contract" "^$strong_model_name\\|complete\\|passed\\|[1-9][0-9]*$" "Expected direct ask receipt evidence"
[ "$direct_ask_cache_contract" = "false|disabled_for_generation_trace|content_hash_contract_hash_model_fingerprint|true|none" ] || {
  echo "Expected direct ask trace to make cache-disabled-under-generation-trace explicit, got $direct_ask_cache_contract" >&2
  exit 1
}

log "Checking opt-in direct decision contract gate"
psql_exec \
  -v task_name="$direct_gate_task" \
  -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_direct_gate;
CREATE TABLE public.otlet_demo_direct_gate (
  id text PRIMARY KEY,
  note text NOT NULL
);
INSERT INTO public.otlet_demo_direct_gate VALUES ('direct-gate-1', 'No decisive signal; send to review');

SELECT otlet.create_task(
  :'task_name',
  $query$
    SELECT
      src.id AS subject_id,
      jsonb_build_object('row', to_jsonb(src)) AS input
    FROM public.otlet_demo_direct_gate src
  $query$,
  'Return exactly one JSON object. output.decision must be unclear, output.confidence must be medium, output.reason must be short, and actions must be []. No markdown.',
  '{
    "type": "object",
    "required": ["decision", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "decision": {"enum": ["unclear"]},
      "confidence": {"enum": ["medium"]},
      "reason": {"type": "string", "maxLength": 80}
    }
  }'::jsonb,
  :'model_name',
  '{"max_tokens":96,"reasoning":"off","inference_cache":false}'::jsonb,
  '{}'::jsonb,
  '{"answer_field":"decision","abstain_values":["unclear"],"confidence_field":"confidence","accepted_confidence":["high"],"enforce_on_direct":true}'::jsonb
);

SELECT otlet.run_task(:'task_name');
SQL
wait_task_failed "$direct_gate_task" 1 900 1
direct_gate_contract="$(psql_value "
SELECT j.status || '|' ||
       r.selection_status || '|' ||
       r.selection_reason || '|' ||
       r.schema_validation_status || '|' ||
       (SELECT count(*) FROM otlet.outputs WHERE job_id = j.id)::text || '|' ||
       (SELECT count(*) FROM otlet.review_queue WHERE receipt_id = r.id)::text || '|' ||
       COALESCE((SELECT output->>'decision' FROM otlet.review_queue WHERE receipt_id = r.id LIMIT 1), '')
FROM otlet.jobs j
JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = '$direct_gate_task'
ORDER BY j.id DESC, r.id DESC
LIMIT 1;
")"
echo "direct_gate_contract=$direct_gate_contract"
[ "$direct_gate_contract" = "failed|rejected|direct_rejected_by_decision_contract|passed|0|1|unclear" ] || {
  echo "Expected opt-in direct gate to reject an abstention without trusted output and expose review_queue, got $direct_gate_contract" >&2
  exit 1
}

log "Checking decision-contract prompt identity"
psql_exec \
  -v model_name="$strong_model_name" \
  -v preset_task="$prompt_identity_preset_task" \
  -v direct_task="$prompt_identity_direct_task" \
  -v entity_instruction="$entity_instruction" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    '{
      "type": "object",
      "required": ["match", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "match": {"enum": ["same_entity", "different_entity", "unclear"]},
        "confidence": {"enum": ["low", "medium", "high"]},
        "reason": {"type": "string", "maxLength": 240}
      }
    }'::jsonb AS output_schema,
    '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options,
    '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb AS input_shaping
)
SELECT otlet.create_task(
  :'preset_task',
  $source$
    SELECT 'prompt-identity'::text AS subject_id,
           jsonb_build_object(
             'left_id', 'vendor-1001',
             'right_id', 'vendor-42',
             'candidate_evidence', jsonb_build_object(
               'shared_stable_identifiers', jsonb_build_array('same tax id 36-9918821'),
               'conflicting_stable_identifiers', '[]'::jsonb,
               'weak_matching_signals', jsonb_build_array('similar name'),
               'missing_or_unknown_identifiers', '[]'::jsonb,
               'row_quality_warnings', '[]'::jsonb
             )
           ) AS input
  $source$::text,
  :'entity_instruction',
  output_schema,
  :'model_name',
  runtime_options,
  input_shaping,
  '{"preset":"entity_resolution_evidence_v1"}'::jsonb
)
FROM params;

WITH params AS (
  SELECT
    '{
      "type": "object",
      "required": ["match", "confidence", "reason"],
      "additionalProperties": false,
      "properties": {
        "match": {"enum": ["same_entity", "different_entity", "unclear"]},
        "confidence": {"enum": ["low", "medium", "high"]},
        "reason": {"type": "string", "maxLength": 240}
      }
    }'::jsonb AS output_schema,
    '{"max_tokens":256,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options,
    '{"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb AS input_shaping
)
SELECT otlet.create_task(
  :'direct_task',
  $source$
    SELECT 'prompt-identity'::text AS subject_id,
           jsonb_build_object(
             'left_id', 'vendor-1001',
             'right_id', 'vendor-42',
             'candidate_evidence', jsonb_build_object(
               'shared_stable_identifiers', jsonb_build_array('same tax id 36-9918821'),
               'conflicting_stable_identifiers', '[]'::jsonb,
               'weak_matching_signals', jsonb_build_array('similar name'),
               'missing_or_unknown_identifiers', '[]'::jsonb,
               'row_quality_warnings', '[]'::jsonb
             )
           ) AS input
  $source$::text,
  :'entity_instruction',
  output_schema,
  :'model_name',
  runtime_options,
  input_shaping,
  (SELECT decision_contract FROM otlet.decision_rule_presets WHERE name = 'entity_resolution_evidence_v1')
)
FROM params;

SELECT otlet.run_task(:'preset_task');
SELECT otlet.run_task(:'direct_task');
SQL
wait_task_complete "$prompt_identity_preset_task" 1 900 1
wait_task_complete "$prompt_identity_direct_task" 1 900 1
prompt_identity_contract="$(psql_value "
WITH receipts AS (
  SELECT task_name, prompt_hash, status, schema_validation_status
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN ('$prompt_identity_preset_task', '$prompt_identity_direct_task')
)
SELECT count(*)::text || '|' ||
       count(DISTINCT prompt_hash)::text || '|' ||
       bool_and(status = 'complete')::text || '|' ||
       bool_and(schema_validation_status = 'passed')::text
FROM receipts;
")"
echo "prompt_identity_contract=$prompt_identity_contract"
[ "$prompt_identity_contract" = "2|1|true|true" ] || {
  echo "Expected preset and expanded decision contract to produce byte-identical prompts, got $prompt_identity_contract" >&2
  exit 1
}

psql_exec \
  -v model_name="$strong_model_name" \
  -v raw_task="input_shape_mvcc_raw_demo" \
  -v hand_task="input_shape_mvcc_hand_demo" \
  -v trunc_task="input_shape_truncate_demo" >/dev/null <<'SQL'
WITH params AS (
  SELECT
    'Return status ok with confidence high and no actions.'::text AS instruction,
    '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]},"confidence":{"enum":["high"]}}}'::jsonb AS output_schema,
    '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options
)
SELECT otlet.create_task(
  :'raw_task',
  $source$
    SELECT 'shape-mvcc'::text AS subject_id,
           '{"_otlet_mvcc":{"table":"public.shape","subject_id":"shape-mvcc","ctid":"(0,1)","xmin":"7"},"row":{"status":"ok"}}'::jsonb AS input
  $source$::text,
  instruction,
  output_schema,
  :'model_name',
  runtime_options,
  '{}'::jsonb,
  '{"answer_field":"status","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
)
FROM params;

WITH params AS (
  SELECT
    'Return status ok with confidence high and no actions.'::text AS instruction,
    '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]},"confidence":{"enum":["high"]}}}'::jsonb AS output_schema,
    '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb AS runtime_options
)
SELECT otlet.create_task(
  :'hand_task',
  $source$
    SELECT 'shape-mvcc'::text AS subject_id,
           '{"row":{"status":"ok"}}'::jsonb AS input
  $source$::text,
  instruction,
  output_schema,
  :'model_name',
  runtime_options,
  '{}'::jsonb,
  '{"answer_field":"status","abstain_values":[],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
)
FROM params;

SELECT otlet.create_task(
  :'trunc_task',
  $source$
    SELECT 'shape-truncate'::text AS subject_id,
           jsonb_build_object('row', jsonb_build_object('payload', repeat('oversized input ', 400))) AS input
  $source$::text,
  'If input._otlet_input_truncated is true, return status truncated with confidence high and no actions. Return JSON only.',
  '{"type":"object","required":["status","confidence"],"additionalProperties":false,"properties":{"status":{"enum":["truncated"]},"confidence":{"enum":["high"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":64,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"max_shaped_input_bytes":256}'::jsonb,
  '{"answer_field":"status","abstain_values":["truncated"],"confidence_field":"confidence","accepted_confidence":["high"]}'::jsonb
);

SELECT otlet.run_task(:'raw_task');
SELECT otlet.run_task(:'hand_task');
SELECT otlet.run_task(:'trunc_task');
SQL
wait_task_complete "input_shape_mvcc_raw_demo" 1 900 1
wait_task_complete "input_shape_mvcc_hand_demo" 1 900 1
wait_task_complete "input_shape_truncate_demo" 1 900 1
input_shape_mvcc_contract="$(psql_value "
WITH receipts AS (
  SELECT task_name, prompt_hash, input_shaping_applied
  FROM otlet.inference_receipt_trace_status
  WHERE task_name IN ('input_shape_mvcc_raw_demo', 'input_shape_mvcc_hand_demo')
)
SELECT count(*)::text || '|' ||
       count(DISTINCT prompt_hash)::text || '|' ||
       bool_or(input_shaping_applied)::text || '|' ||
       (NOT (otlet.semantic_shaped_input('{\"_otlet_mvcc\":{\"xmin\":\"7\"},\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb) ? '_otlet_mvcc'))::text || '|' ||
       (
         otlet.semantic_content_hash('{\"_otlet_mvcc\":{\"xmin\":\"7\"},\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb)
         = otlet.semantic_content_hash('{\"row\":{\"status\":\"ok\"}}'::jsonb, '{}'::jsonb)
       )::text
FROM receipts;
")"
echo "input_shape_mvcc_contract=$input_shape_mvcc_contract"
[ "$input_shape_mvcc_contract" = "2|1|true|true|true" ] || {
  echo "Expected MVCC stripping to produce equal prompt/content hashes, got $input_shape_mvcc_contract" >&2
  exit 1
}
input_shape_truncate_contract="$(psql_value "
SELECT input_truncated::text || '|' ||
       input_shaping_applied::text || '|' ||
       (original_shaped_input_bytes > max_shaped_input_bytes)::text || '|' ||
       max_shaped_input_bytes::text || '|' ||
       (shaped_input_bytes > 0)::text
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'input_shape_truncate_demo'
ORDER BY receipt_id DESC
LIMIT 1;
")"
echo "input_shape_truncate_contract=$input_shape_truncate_contract"
[ "$input_shape_truncate_contract" = "true|true|true|256|true" ] || {
  echo "Expected oversized shaped input truncation evidence, got $input_shape_truncate_contract" >&2
  exit 1
}

input_shape_sql_contract="$(psql_value "
WITH sample AS (
  SELECT
    '{\"_otlet_mvcc\":{\"xmin\":\"7\"},\"keep\":\"visible\",\"strip_me\":\"volatile\",\"left_id\":\"left-1\",\"candidate_evidence\":{\"shared\":[\"a\",\"b\"],\"warning\":\"manual check\",\"ignored\":false}}'::jsonb AS input,
    '{\"strip_keys\":[\"strip_me\"],\"evidence_fields\":[\"candidate_evidence\"],\"action_id_fields\":{\"left_id\":\"left_id\"}}'::jsonb AS shaping
), expected AS (
  SELECT '{\"keep\":\"visible\",\"left_id\":\"left-1\",\"candidate_evidence\":{\"shared\":[\"a\",\"b\"],\"warning\":\"manual check\",\"ignored\":false},\"evidence_counts\":{\"shared\":2,\"warning\":1,\"ignored\":0},\"action_ids\":{\"left_id\":\"left-1\"}}'::jsonb AS shaped
)
SELECT (otlet.semantic_shaped_input(input, shaping) = expected.shaped)::text || '|' ||
       (NOT (otlet.semantic_shaped_input(input, shaping) ? '_otlet_mvcc'))::text || '|' ||
       (NOT (otlet.semantic_shaped_input(input, shaping) ? 'strip_me'))::text
FROM sample, expected;
")"
echo "input_shape_sql_contract=$input_shape_sql_contract"
[ "$input_shape_sql_contract" = "true|true|true" ] || {
  echo "Expected SQL input shaping vector to match Rust semantics, got $input_shape_sql_contract" >&2
  exit 1
}
