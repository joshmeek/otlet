CREATE FUNCTION otlet.decision_evidence_path_links(
  evidence_refs jsonb,
  shaped_input jsonb,
  input_shaping jsonb,
  target_kind text,
  action_index integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  links jsonb := '[]'::jsonb;
  reference jsonb;
  path_item jsonb;
  path_segments text[];
  segment text;
  current_value jsonb;
  array_offset integer;
  link jsonb;
BEGIN
  IF decision_evidence_path_links.evidence_refs IS NULL THEN
    RETURN links;
  END IF;
  IF jsonb_typeof(decision_evidence_path_links.evidence_refs)
       IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet decision evidence must be an array of JSON paths';
  END IF;
  IF jsonb_array_length(decision_evidence_path_links.evidence_refs) > 32 THEN
    RAISE EXCEPTION 'otlet decision evidence exceeds 32 paths';
  END IF;
  IF decision_evidence_path_links.target_kind NOT IN ('output', 'action')
     OR (
       decision_evidence_path_links.target_kind = 'output'
       AND decision_evidence_path_links.action_index IS NOT NULL
     )
     OR (
       decision_evidence_path_links.target_kind = 'action'
       AND COALESCE(decision_evidence_path_links.action_index, -1) < 0
     ) THEN
    RAISE EXCEPTION 'otlet decision evidence target is invalid';
  END IF;
  IF jsonb_typeof(COALESCE(
       decision_evidence_path_links.input_shaping,
       '{}'::jsonb
     ) -> 'source_fields') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet decision evidence source-field allowlist is invalid';
  END IF;
  IF jsonb_typeof(decision_evidence_path_links.shaped_input)
       IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet decision evidence requires an object input snapshot';
  END IF;

  FOR reference IN
    SELECT value
    FROM jsonb_array_elements(decision_evidence_path_links.evidence_refs)
  LOOP
    IF jsonb_typeof(reference) IS DISTINCT FROM 'array'
       OR jsonb_array_length(reference) NOT BETWEEN 1 AND 16 THEN
      RAISE EXCEPTION 'otlet decision evidence path must contain 1 to 16 text segments';
    END IF;

    path_segments := ARRAY[]::text[];
    FOR path_item IN SELECT value FROM jsonb_array_elements(reference) LOOP
      IF jsonb_typeof(path_item) IS DISTINCT FROM 'string'
         OR NULLIF(path_item #>> '{}', '') IS NULL
         OR octet_length(path_item #>> '{}') > 128 THEN
        RAISE EXCEPTION 'otlet decision evidence path segment must contain 1 to 128 bytes';
      END IF;
      path_segments := array_append(path_segments, path_item #>> '{}');
    END LOOP;

    IF NOT (
      COALESCE(decision_evidence_path_links.input_shaping, '{}'::jsonb)
        -> 'source_fields'
    ) ? path_segments[1] THEN
      RAISE EXCEPTION 'otlet decision evidence path is outside input_shaping.source_fields';
    END IF;

    current_value := decision_evidence_path_links.shaped_input;
    FOREACH segment IN ARRAY path_segments LOOP
      CASE jsonb_typeof(current_value)
        WHEN 'object' THEN
          IF NOT current_value ? segment THEN
            RAISE EXCEPTION 'otlet decision evidence path does not exist in shaped input';
          END IF;
          current_value := current_value -> segment;
        WHEN 'array' THEN
          IF segment !~ '^(0|[1-9][0-9]{0,8})$' THEN
            RAISE EXCEPTION 'otlet decision evidence array path is invalid';
          END IF;
          array_offset := segment::integer;
          IF array_offset >= jsonb_array_length(current_value) THEN
            RAISE EXCEPTION 'otlet decision evidence path does not exist in shaped input';
          END IF;
          current_value := current_value -> array_offset;
        ELSE
          RAISE EXCEPTION 'otlet decision evidence path does not exist in shaped input';
      END CASE;
    END LOOP;

    link := jsonb_strip_nulls(jsonb_build_object(
      'target_kind', decision_evidence_path_links.target_kind,
      'action_index', decision_evidence_path_links.action_index,
      'path', to_jsonb(path_segments),
      'value_hash', otlet.identity_hash(
        'decision_evidence_value',
        current_value
      )
    ));
    IF NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(links) existing(value)
      WHERE existing.value = link
    ) THEN
      links := links || jsonb_build_array(link);
    END IF;
  END LOOP;

  RETURN links;
END;
$$;

CREATE FUNCTION otlet.validated_decision_evidence(
  output jsonb,
  actions jsonb,
  shaped_input jsonb,
  input_shaping jsonb,
  validator_version text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  links jsonb;
  action_row record;
BEGIN
  IF validated_decision_evidence.validator_version
       IS DISTINCT FROM 'otlet_decision_evidence_v1' THEN
    RETURN '[]'::jsonb;
  END IF;

  links := otlet.decision_evidence_path_links(
    CASE
      WHEN jsonb_typeof(validated_decision_evidence.output) = 'object'
        THEN validated_decision_evidence.output -> 'evidence'
    END,
    validated_decision_evidence.shaped_input,
    validated_decision_evidence.input_shaping,
    'output'
  );

  FOR action_row IN
    SELECT value, ordinality
    FROM jsonb_array_elements(COALESCE(
      validated_decision_evidence.actions,
      '[]'::jsonb
    )) WITH ORDINALITY action(value, ordinality)
  LOOP
    links := links || otlet.decision_evidence_path_links(
      CASE
        WHEN jsonb_typeof(action_row.value #> '{body}') = 'object'
          THEN action_row.value #> '{body,evidence}'
      END,
      validated_decision_evidence.shaped_input,
      validated_decision_evidence.input_shaping,
      'action',
      (action_row.ordinality - 1)::integer
    );
    IF jsonb_array_length(links) > 128 THEN
      RAISE EXCEPTION 'otlet decision evidence exceeds 128 paths per result';
    END IF;
  END LOOP;

  RETURN links;
END;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.current_workload_revision_definition(text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$'schema_force', 'postgres_portable_json_schema_validation'$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet decision evidence workload revision rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$'schema_force', 'postgres_portable_json_schema_validation'$needle$,
    $replacement$'schema_force', 'postgres_portable_json_schema_validation',
      'decision_evidence_version', 'otlet_decision_evidence_v1'$replacement$
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.action_validation_error(jsonb,jsonb,text,jsonb,jsonb)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$WHERE key NOT IN ('target', 'identity', 'changes')$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet decision evidence action rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$WHERE key NOT IN ('target', 'identity', 'changes')$needle$,
    $replacement$WHERE key NOT IN ('target', 'identity', 'changes', 'evidence')$replacement$
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.validate_portable_result(bigint,jsonb,text,jsonb,text,text,text,text,text,text,jsonb)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$'action_validation', action_validation
  );$needle$ IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet decision evidence result rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$'action_validation', action_validation
  );$needle$,
    $replacement$'action_validation', action_validation
  ) || CASE
    WHEN revision_definition #>>
      '{validator,decision_evidence_version}' =
      'otlet_decision_evidence_v1' THEN jsonb_build_object(
      'decision_evidence_version', 'otlet_decision_evidence_v1',
      'decision_evidence', otlet.validated_decision_evidence(
        validate_portable_result.output,
        COALESCE(validate_portable_result.actions, '[]'::jsonb),
        shaped_input,
        task_row.input_shaping,
        'otlet_decision_evidence_v1'
      )
    )
    ELSE '{}'::jsonb
  END;$replacement$
  );
END;
$migration$;

CREATE VIEW otlet.audit_decision_evidence_export AS
WITH evidence_links AS (
  SELECT
    receipt.id AS receipt_id,
    receipt.job_id,
    receipt.workload_revision_hash,
    receipt.task_name,
    receipt.subject_id,
    receipt.output_hash,
    receipt.actions_hash,
    receipt.finished_at,
    output.id AS output_id,
    link.value,
    link.ordinality
  FROM otlet.inference_receipts receipt
  JOIN otlet.outputs output ON output.receipt_id = receipt.id
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      receipt.trace_summary #>
        '{portable_validation,decision_evidence}',
      '[]'::jsonb
    )
  ) WITH ORDINALITY link(value, ordinality)
)
SELECT
  evidence.receipt_id,
  evidence.job_id,
  evidence.workload_revision_hash,
  evidence.task_name,
  evidence.subject_id,
  evidence.output_id,
  action.id AS action_id,
  evidence.value ->> 'target_kind' AS target_kind,
  CASE
    WHEN evidence.value ->> 'target_kind' = 'action'
      THEN (evidence.value ->> 'action_index')::integer
  END AS action_index,
  ARRAY(
    SELECT jsonb_array_elements_text(evidence.value -> 'path')
  ) AS evidence_path,
  evidence.value ->> 'value_hash' AS value_hash,
  evidence.output_hash,
  evidence.actions_hash,
  evidence.ordinality::integer AS link_ordinal,
  evidence.finished_at
FROM evidence_links evidence
LEFT JOIN LATERAL (
  SELECT candidate.id
  FROM otlet.actions candidate
  WHERE candidate.receipt_id = evidence.receipt_id
  ORDER BY candidate.id
  OFFSET CASE
    WHEN evidence.value ->> 'target_kind' = 'action'
      THEN (evidence.value ->> 'action_index')::integer
    ELSE 0
  END
  LIMIT 1
) action ON evidence.value ->> 'target_kind' = 'action';

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  IF position(
    '''otlet.audit_administrative_change_export''::text' IN definition
  ) = 0 OR position('3 AS policy_version' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet decision evidence redaction registry rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    '''otlet.audit_administrative_change_export''::text',
    '''otlet.audit_decision_evidence_export''::text, '
      || '''otlet.audit_administrative_change_export''::text'
  );
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS ' ||
    pg_catalog.replace(definition, '3 AS policy_version', '4 AS policy_version');
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.finish_access_policy_grant(text,regrole,text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export TO %I'$needle$ IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet decision evidence access grant rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export TO %I'$needle$,
    $replacement$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export TO %I'$replacement$
  );
END;
$migration$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name
        FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) IN ('auditor', 'operator')
      AND pg_catalog.has_table_privilege(
        role.oid,
        'otlet.audit_review_export',
        'SELECT'
      )
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_decision_evidence_export TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.audit_decision_evidence_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.decision_evidence_path_links(
  jsonb, jsonb, jsonb, text, integer
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validated_decision_evidence(
  jsonb, jsonb, jsonb, jsonb, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.action_validation_error(
  jsonb, jsonb, text, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_portable_result(
  bigint, jsonb, text, jsonb, text, text, text, text, text, text, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.finish_access_policy_grant(
  text, regrole, text
) FROM PUBLIC;
