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
  '{"source_fields":["_otlet_mvcc","action_ids","candidate_evidence","evidence_counts"],"evidence_fields":["candidate_evidence"],"action_id_fields":{"left_id":"left_id","right_id":"right_id"}}'::jsonb,
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
