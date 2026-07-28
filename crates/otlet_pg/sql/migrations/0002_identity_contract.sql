CREATE FUNCTION otlet.semantic_canonical_jsonb(
  input jsonb
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE jsonb_typeof($1)
    WHEN 'object' THEN COALESCE(
      (
        SELECT jsonb_object_agg(key, otlet.semantic_canonical_jsonb(value) ORDER BY key)
        FROM jsonb_each($1)
      ),
      '{}'::jsonb
    )
    WHEN 'array' THEN COALESCE(
      (
        SELECT jsonb_agg(otlet.semantic_canonical_jsonb(value) ORDER BY ordinality)
        FROM jsonb_array_elements($1) WITH ORDINALITY AS items(value, ordinality)
      ),
      '[]'::jsonb
    )
    WHEN 'number' THEN to_jsonb(trim_scale(($1 #>> '{}')::numeric))
    ELSE $1
  END;
$$;

CREATE FUNCTION otlet.semantic_shaped_input(
  input jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  actual_input jsonb := COALESCE(input, '{}'::jsonb);
  shaping jsonb := COALESCE(input_shaping, '{}'::jsonb);
  shaped jsonb := actual_input;
  counts jsonb := '{}'::jsonb;
  ids jsonb := '{}'::jsonb;
  field_name text;
  target_key text;
  source_field text;
  bucket_key text;
  bucket_value jsonb;
  bucket_count integer;
  original_bytes integer;
  max_bytes integer := 0;
  canonical_text text;
BEGIN
  IF jsonb_typeof(shaped) IS DISTINCT FROM 'object' THEN
    RETURN shaped;
  END IF;

  shaped := shaped - '_otlet_mvcc' - 'otlet_mvcc';

  IF jsonb_typeof(shaping -> 'strip_keys') = 'array' THEN
    FOR field_name IN SELECT jsonb_array_elements_text(shaping -> 'strip_keys') LOOP
      shaped := shaped - field_name;
    END LOOP;
  END IF;

  IF NOT shaped ? 'evidence_counts'
     AND jsonb_typeof(shaping -> 'evidence_fields') = 'array' THEN
    FOR field_name IN SELECT jsonb_array_elements_text(shaping -> 'evidence_fields') LOOP
      IF jsonb_typeof(actual_input -> field_name) = 'object' THEN
        FOR bucket_key, bucket_value IN SELECT key, value FROM jsonb_each(actual_input -> field_name) LOOP
          bucket_count := CASE
            WHEN jsonb_typeof(bucket_value) = 'array' THEN jsonb_array_length(bucket_value)
            WHEN jsonb_typeof(bucket_value) = 'string' AND btrim(bucket_value #>> '{}') <> '' THEN 1
            WHEN jsonb_typeof(bucket_value) IN ('number', 'object') THEN 1
            WHEN jsonb_typeof(bucket_value) = 'boolean' AND bucket_value = 'true'::jsonb THEN 1
            ELSE 0
          END;
          counts := counts || jsonb_build_object(bucket_key, bucket_count);
        END LOOP;
      END IF;
    END LOOP;
    IF counts <> '{}'::jsonb THEN
      shaped := jsonb_set(shaped, '{evidence_counts}', counts, true);
    END IF;
  END IF;

  IF NOT shaped ? 'action_ids'
     AND jsonb_typeof(shaping -> 'action_id_fields') = 'object' THEN
    FOR target_key, source_field IN SELECT key, value FROM jsonb_each_text(shaping -> 'action_id_fields') LOOP
      IF actual_input ? source_field THEN
        ids := ids || jsonb_build_object(target_key, actual_input -> source_field);
      END IF;
    END LOOP;
    IF ids <> '{}'::jsonb THEN
      shaped := jsonb_set(shaped, '{action_ids}', ids, true);
    END IF;
  END IF;

  IF jsonb_typeof(shaping -> 'max_shaped_input_bytes') = 'number' THEN
    max_bytes := LEAST(
      GREATEST((shaping ->> 'max_shaped_input_bytes')::numeric, 0),
      1048576
    )::integer;
  END IF;
  canonical_text := otlet.semantic_canonical_jsonb(shaped)::text;
  original_bytes := length(canonical_text);
  IF max_bytes > 0 AND original_bytes > max_bytes THEN
    shaped := jsonb_build_object(
      '_otlet_input_truncated', true,
      'truncation_policy', 'max_shaped_input_bytes_fail_toward_abstention',
      'original_shaped_input_bytes', original_bytes,
      'max_shaped_input_bytes', max_bytes,
      'truncated_input_preview', left(canonical_text, LEAST(max_bytes, 1024))
    );
  END IF;

  RETURN shaped;
END;
$$;

CREATE FUNCTION otlet.semantic_content_hash(
  input jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT md5(otlet.semantic_canonical_jsonb(otlet.semantic_shaped_input($1, $2))::text);
$$;

CREATE FUNCTION otlet.semantic_project_row(
  row_data jsonb,
  input_columns text[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN $2 IS NULL THEN COALESCE($1, '{}'::jsonb)
    ELSE COALESCE(
      (
        SELECT jsonb_object_agg(key, value ORDER BY key)
        FROM jsonb_each(COALESCE($1, '{}'::jsonb))
        WHERE key = ANY($2)
      ),
      '{}'::jsonb
    )
  END;
$$;

CREATE FUNCTION otlet.task_contract_hash(
  instruction text,
  output_schema jsonb,
  model_name text,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT md5(jsonb_build_object(
    'instruction', COALESCE($1, ''),
    'output_schema', COALESCE($2, '{}'::jsonb),
    'model_name', COALESCE($3, ''),
    'runtime_options', COALESCE($4, '{}'::jsonb),
    'input_shaping', COALESCE($5, '{}'::jsonb),
    'decision_contract', COALESCE($6, '{}'::jsonb)
  )::text);
$$;

-- Truth table for semantic freshness:
-- content mismatch -> stale, reason = stale_reason or content_revalidation_pending
-- contract mismatch -> stale, reason = contract_changed
-- stale = false and content/contract match -> fresh
-- stale = true with source_update and content/contract match -> fresh revalidation candidate
-- any other stale reason with content/contract match -> stale
CREATE FUNCTION otlet.semantic_freshness_status(
  material_content_hash text,
  material_contract_hash text,
  material_stale boolean,
  material_stale_reason text,
  material_source_hash text,
  current_content_hash text,
  current_contract_hash text,
  current_source_hash text DEFAULT NULL
) RETURNS TABLE (
  is_fresh boolean,
  is_stale boolean,
  stale_reason text,
  freshness_basis text
)
LANGUAGE sql
IMMUTABLE
AS $$
  WITH classified AS (
    SELECT (
      material_content_hash IS NOT DISTINCT FROM current_content_hash
      AND material_contract_hash IS NOT DISTINCT FROM current_contract_hash
      AND (
        NOT COALESCE(material_stale, false)
        OR material_stale_reason = 'source_update'
      )
    ) AS fresh
  )
  SELECT
    fresh AS is_fresh,
    NOT fresh AS is_stale,
    CASE
      WHEN fresh THEN NULL::text
      WHEN material_contract_hash IS DISTINCT FROM current_contract_hash THEN 'contract_changed'
      ELSE COALESCE(material_stale_reason, 'content_revalidation_pending')
    END AS stale_reason,
    CASE
      WHEN NOT fresh THEN NULL::text
      WHEN COALESCE(material_stale, false) THEN 'revalidated_after_benign_update'
      WHEN material_source_hash IS NOT DISTINCT FROM current_source_hash THEN 'mvcc_match'
      ELSE 'content_hash_match'
    END AS freshness_basis
  FROM classified;
$$;

INSERT INTO otlet.decision_rule_presets (name, decision_contract)
VALUES (
  'entity_resolution_evidence_v1',
  jsonb_build_object(
    'prompt_prefix',
    'Return one JSON object only. Top-level keys must be output and actions. Never use ellipses or placeholder values. Use input.evidence_counts for the decision and input.candidate_evidence only for the short reason. input.action_ids are row IDs for action bodies, not identity evidence. confidence must be low, medium, or high, never unclear. Rule 1: if conflicting_stable_identifiers > 0, output different_entity with confidence high. Rule 2: else if shared_stable_identifiers > 0, output same_entity with confidence high. Rule 3: else output unclear with confidence medium. ',
    'answer_field', 'match',
    'abstain_values', jsonb_build_array('unclear'),
    'confidence_field', 'confidence',
    'accepted_confidence', jsonb_build_array('high'),
    'action_types', jsonb_build_array('merge_candidate', 'new_entity', 'review_flag')
  )
),
(
  'row_triage_decision_v1',
  jsonb_build_object(
    'prompt_prefix',
    'Return one JSON object only. Top-level keys must be output and actions. Never use ellipses or placeholder values. Use input.row.blockers and input.row.approvals for the decision. confidence must be low, medium, or high, never unclear. Rule 1: if blockers > 0, output flag with confidence high. Rule 2: else if approvals > 0, output pass with confidence high. Rule 3: else output unclear with confidence medium. ',
    'answer_field', 'decision',
    'abstain_values', jsonb_build_array('unclear'),
    'confidence_field', 'confidence',
    'accepted_confidence', jsonb_build_array('high', 'medium'),
    'action_types', jsonb_build_array('review_flag')
  )
);
