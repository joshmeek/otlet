\set ON_ERROR_STOP on

SELECT otlet.drop_watch('entity_resolution_starter');
DELETE FROM otlet.eval_labels
WHERE workload_name = 'entity_resolution_starter'
  AND action_id IS NULL
  AND output_id IS NULL
  AND receipt_id IS NULL;

DROP TABLE IF EXISTS public.otlet_entity_resolution_starter_pair;
DROP TABLE IF EXISTS public.otlet_entity_resolution_starter_record;

CREATE TABLE public.otlet_entity_resolution_starter_record (
  id text PRIMARY KEY,
  fixture_kind text NOT NULL CHECK (fixture_kind IN ('vendor', 'account', 'catalog_item')),
  display_name text NOT NULL,
  domain text,
  stable_id text NOT NULL,
  location text,
  notes text NOT NULL
);

CREATE TABLE public.otlet_entity_resolution_starter_pair (
  pair_id text PRIMARY KEY,
  left_id text NOT NULL REFERENCES public.otlet_entity_resolution_starter_record(id),
  right_id text NOT NULL REFERENCES public.otlet_entity_resolution_starter_record(id),
  expected_match text NOT NULL CHECK (expected_match IN ('same_entity', 'different_entity'))
);

INSERT INTO public.otlet_entity_resolution_starter_record (
  id, fixture_kind, display_name, domain, stable_id, location, notes
)
VALUES
  ('vendor-northstar', 'vendor', 'Northstar Logistics LLC', 'northstar-logistics.example', 'tax:36-9918821', 'Chicago IL', 'Freight vendor with remittance account 8821'),
  ('vendor-nstar', 'vendor', 'N-Star Freight Services', 'nstar-freight.example', 'tax:36-9918821', 'Chicago IL', 'Northstar rebrand with remittance account 8821'),
  ('vendor-clearwater', 'vendor', 'Clearwater Medical Supplies', 'clearwatermed.example', 'tax:86-4477001', 'Phoenix AZ', 'Medical supplier with a separate tax identity'),
  ('account-acme', 'account', 'Acme Holdings operating account', 'acme.example', 'bank:021000021:8821', 'New York NY', 'Primary treasury account'),
  ('account-acme-ap', 'account', 'Acme Holdings AP', 'payments.acme.example', 'bank:021000021:8821', 'New York NY', 'Same routing and account identity'),
  ('account-riverline', 'account', 'Riverline Labs operating account', 'riverline.example', 'bank:121000248:1199', 'San Francisco CA', 'Separate beneficiary and account identity'),
  ('catalog-filter', 'catalog_item', 'Industrial air filter 20x20 MERV 13', 'filters.example', 'sku:af-2020-m13', NULL, 'Manufacturer SKU AF-2020-M13'),
  ('catalog-filter-case', 'catalog_item', 'Case of MERV13 20 x 20 filters', 'supply.example', 'sku:af-2020-m13', NULL, 'Same manufacturer SKU sold by the case'),
  ('catalog-filter-small', 'catalog_item', 'Industrial air filter 16x25 MERV 13', 'filters.example', 'sku:af-1625-m13', NULL, 'Different manufacturer SKU and dimensions');

INSERT INTO public.otlet_entity_resolution_starter_pair (
  pair_id, left_id, right_id, expected_match
)
VALUES
  ('vendor:same', 'vendor-northstar', 'vendor-nstar', 'same_entity'),
  ('vendor:different', 'vendor-northstar', 'vendor-clearwater', 'different_entity'),
  ('account:same', 'account-acme', 'account-acme-ap', 'same_entity'),
  ('account:different', 'account-acme', 'account-riverline', 'different_entity'),
  ('catalog-item:same', 'catalog-filter', 'catalog-filter-case', 'same_entity'),
  ('catalog-item:different', 'catalog-filter', 'catalog-filter-small', 'different_entity');

CREATE TEMP TABLE entity_resolution_starter_pack AS
WITH fixtures AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'fixture_kind', left_record.fixture_kind,
      'subject_id', pair.pair_id,
      'left', to_jsonb(left_record),
      'right', to_jsonb(right_record)
    )
    ORDER BY pair.pair_id
  ) AS value
  FROM public.otlet_entity_resolution_starter_pair pair
  JOIN public.otlet_entity_resolution_starter_record left_record ON left_record.id = pair.left_id
  JOIN public.otlet_entity_resolution_starter_record right_record ON right_record.id = pair.right_id
), labels AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'workload_name', 'entity_resolution_starter',
      'case_key', pair.pair_id,
      'case_weight', 1,
      'task_name', 'entity_resolution_starter_task',
      'source_table', 'public.otlet_entity_resolution_starter_record',
      'subject_id', pair.pair_id,
      'expected_answer', pair.expected_match,
      'expected_confidence', 'high',
      'expected_action_type', CASE pair.expected_match
        WHEN 'same_entity' THEN 'merge_candidate'
        ELSE 'new_entity'
      END,
      'label_source', 'manual_correction',
      'reason', 'starter pack fixture'
    )
    ORDER BY pair.pair_id
  ) AS value
  FROM public.otlet_entity_resolution_starter_pair pair
), expected_receipts AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'subject_id', pair_id,
      'selection_role', 'direct',
      'selection_status', 'accepted',
      'schema_validation_status', 'passed'
    )
    ORDER BY pair_id
  ) AS value
  FROM public.otlet_entity_resolution_starter_pair
), review_outcomes AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'subject_id', pair_id,
      'outcome', CASE expected_match WHEN 'same_entity' THEN 'approve' ELSE 'not_required' END
    )
    ORDER BY pair_id
  ) AS value
  FROM public.otlet_entity_resolution_starter_pair
), model AS (
  SELECT artifact_identity
  FROM otlet.models
  WHERE name = :'strong_model_name'
)
SELECT otlet.validate_watch_pack(jsonb_build_object(
  'format', 'otlet.watch.v1',
  'name', 'entity_resolution_starter',
  'kind', 'pair',
  'instruction', 'Decide whether each pair is the same entity. A shared stable identifier with no conflict means same_entity. A conflicting stable identifier with no shared identifier means different_entity. Use unclear only when neither rule applies. Return high confidence for either decisive rule. same_entity uses merge_candidate with left_id, right_id, confidence, and reason. different_entity uses new_entity with entity_id equal to input.action_ids.right_id and reason. Keep output and action reasons under 12 words. Do not include evidence in actions. Quote every key and string. No markdown.',
  'output_schema', '{
    "type":"object",
    "required":["match","confidence","reason"],
    "additionalProperties":false,
    "properties":{
      "match":{"enum":["same_entity","different_entity","unclear"]},
      "confidence":{"enum":["low","medium","high"]},
      "reason":{"type":"string","maxLength":240}
    }
  }'::jsonb,
  'model_name', :'strong_model_name',
  'model_artifact_identity', model.artifact_identity,
  'table_name', NULL,
  'subject_column', NULL,
  'candidate_query', $query$
    SELECT
      pair.pair_id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_entity_resolution_starter_record',
          'subject_id', pair.pair_id,
          'left_id', pair.left_id,
          'right_id', pair.right_id,
          'left_ctid', left_record.ctid::text,
          'left_xmin', left_record.xmin::text,
          'right_ctid', right_record.ctid::text,
          'right_xmin', right_record.xmin::text
        ),
        'fixture_kind', left_record.fixture_kind,
        'candidate_evidence', jsonb_build_object(
          'shared_stable_identifiers', CASE
            WHEN left_record.stable_id = right_record.stable_id
              THEN jsonb_build_array('same stable identifier ' || left_record.stable_id)
            ELSE '[]'::jsonb
          END,
          'conflicting_stable_identifiers', CASE
            WHEN left_record.stable_id <> right_record.stable_id
              THEN jsonb_build_array('different stable identifiers ' || left_record.stable_id || ' and ' || right_record.stable_id)
            ELSE '[]'::jsonb
          END,
          'weak_matching_signals', CASE
            WHEN left_record.location IS NOT DISTINCT FROM right_record.location
              THEN jsonb_build_array('same location')
            ELSE '[]'::jsonb
          END,
          'missing_or_unknown_identifiers', '[]'::jsonb,
          'row_quality_warnings', '[]'::jsonb
        ),
        'evidence_counts', jsonb_build_object(
          'shared_stable_identifiers', CASE WHEN left_record.stable_id = right_record.stable_id THEN 1 ELSE 0 END,
          'conflicting_stable_identifiers', CASE WHEN left_record.stable_id <> right_record.stable_id THEN 1 ELSE 0 END,
          'weak_matching_signals', CASE WHEN left_record.location IS NOT DISTINCT FROM right_record.location THEN 1 ELSE 0 END,
          'missing_or_unknown_identifiers', 0,
          'row_quality_warnings', 0
        ),
        'action_ids', jsonb_build_object('left_id', pair.left_id, 'right_id', pair.right_id)
      ) AS input
    FROM public.otlet_entity_resolution_starter_pair pair
    JOIN public.otlet_entity_resolution_starter_record left_record ON left_record.id = pair.left_id
    JOIN public.otlet_entity_resolution_starter_record right_record ON right_record.id = pair.right_id
    ORDER BY pair.pair_id
    LIMIT 100
  $query$,
  'record_type', 'entity_hypothesis',
  'runtime_options', '{"max_tokens":384,"reasoning":"off","inference_cache":true}'::jsonb,
  'selection_policy', jsonb_build_object('mode', 'single_model', 'model_name', :'strong_model_name'),
  'trigger_policy', '{"on_change":"mark_stale"}'::jsonb,
  'action_types', '["merge_candidate","new_entity","review_flag"]'::jsonb,
  'stale_policy', 'refresh_then_fail_closed',
  'input_shaping', '{
    "source_fields":["_otlet_mvcc","action_ids","candidate_evidence","evidence_counts","fixture_kind"],
    "evidence_fields":["candidate_evidence"],
    "action_id_fields":{"left_id":"left_id","right_id":"right_id"}
  }'::jsonb,
  'decision_contract', '{"preset":"entity_resolution_evidence_v1"}'::jsonb,
  'max_candidate_rows', 100,
  'input_columns', NULL,
  'pair_sources', '[{"table":"public.otlet_entity_resolution_starter_record","subject_column":"id"}]'::jsonb,
  'version_metadata', '{"version":"1.0.0","workload":"entity_resolution","policy":"single_strong_local"}'::jsonb,
  'fixtures', fixtures.value,
  'labels', labels.value,
  'expected_receipts', expected_receipts.value,
  'review_outcomes', review_outcomes.value,
  'evaluation_gates', '{
    "min_coverage":1,
    "min_quality":1,
    "max_abstention":0,
    "min_action_quality":1,
    "max_latency_ms":300000,
    "max_reviewer_time_ms":300000
  }'::jsonb
)) AS definition
FROM fixtures, labels, expected_receipts, review_outcomes, model;

SELECT *
FROM otlet.lint_watch_pack((SELECT definition FROM entity_resolution_starter_pack));

SELECT *
FROM otlet.import_watch((SELECT definition FROM entity_resolution_starter_pack), true);

SELECT otlet.import_eval_cases(
  (SELECT definition -> 'labels' FROM entity_resolution_starter_pack)
) AS imported_labels;
