CREATE VIEW otlet.definition_complexity_limits AS
SELECT
  65536::bigint AS max_instruction_bytes,
  262144::bigint AS max_query_bytes,
  262144::bigint AS max_output_schema_bytes,
  65536::bigint AS max_runtime_json_bytes,
  65536::bigint AS max_input_shaping_bytes,
  262144::bigint AS max_decision_contract_bytes,
  1048576::bigint AS max_definition_bytes,
  32::integer AS max_json_depth,
  8192::bigint AS max_json_nodes,
  4096::bigint AS max_identifiers,
  4096::bigint AS max_query_identifiers,
  262144::bigint AS max_prompt_template_bytes;

CREATE FUNCTION otlet.bounded_jsonb_complexity(
  input jsonb,
  max_depth integer,
  max_nodes bigint
) RETURNS TABLE (
  json_depth integer,
  json_nodes bigint,
  identifier_count bigint
)
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  WITH RECURSIVE walk(value, depth, identifiers) AS (
    SELECT bounded_jsonb_complexity.input, 1, 0::bigint
    UNION ALL
    SELECT child.value, walk.depth + 1, child.identifiers
    FROM walk
    CROSS JOIN LATERAL (
      SELECT member.value, 1::bigint AS identifiers
      FROM jsonb_each(
        CASE WHEN jsonb_typeof(walk.value) = 'object'
          THEN walk.value ELSE '{}'::jsonb END
      ) member
      UNION ALL
      SELECT
        element.value,
        CASE WHEN jsonb_typeof(element.value) = 'string' THEN 1::bigint ELSE 0::bigint END
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(walk.value) = 'array'
          THEN walk.value ELSE '[]'::jsonb END
      ) element
    ) child
    WHERE walk.depth <= bounded_jsonb_complexity.max_depth
  ), bounded AS (
    SELECT *
    FROM walk
    LIMIT GREATEST(bounded_jsonb_complexity.max_nodes, 1) + 1
  )
  SELECT
    max(depth)::integer,
    count(*)::bigint,
    COALESCE(sum(identifiers), 0)::bigint
  FROM bounded
$$;

CREATE FUNCTION otlet.definition_complexity_report(
  definition jsonb
) RETURNS TABLE (
  instruction_bytes bigint,
  query_bytes bigint,
  output_schema_bytes bigint,
  runtime_json_bytes bigint,
  input_shaping_bytes bigint,
  decision_contract_bytes bigint,
  definition_bytes bigint,
  json_depth integer,
  json_nodes bigint,
  identifier_count bigint,
  query_identifier_count bigint,
  prompt_template_bytes bigint,
  error text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  limits otlet.definition_complexity_limits%ROWTYPE;
  input_query text := definition_complexity_report.definition #>> '{task,input_query}';
  instruction text := COALESCE(
    definition_complexity_report.definition #>> '{task,instruction}',
    ''
  );
  output_schema jsonb := COALESCE(
    definition_complexity_report.definition #> '{task,output_schema}',
    '{}'::jsonb
  );
  runtime_options jsonb := COALESCE(
    definition_complexity_report.definition #> '{task,runtime_options}',
    '{}'::jsonb
  );
  effective_runtime_options jsonb := COALESCE(
    definition_complexity_report.definition #> '{runtime,effective_options}',
    runtime_options
  );
  input_shaping jsonb := COALESCE(
    definition_complexity_report.definition #> '{task,input_shaping}',
    '{}'::jsonb
  );
  decision_contract jsonb := COALESCE(
    definition_complexity_report.definition #> '{task,decision_contract}',
    '{}'::jsonb
  );
BEGIN
  SELECT * INTO limits FROM otlet.definition_complexity_limits;

  instruction_bytes := octet_length(instruction)::bigint;
  query_bytes := octet_length(COALESCE(input_query, ''))::bigint;
  output_schema_bytes := octet_length(output_schema::text)::bigint;
  runtime_json_bytes := octet_length(runtime_options::text)::bigint;
  input_shaping_bytes := octet_length(input_shaping::text)::bigint;
  decision_contract_bytes := octet_length(decision_contract::text)::bigint;
  definition_bytes := octet_length(COALESCE(
    definition_complexity_report.definition,
    'null'::jsonb
  )::text)::bigint;

  IF instruction_bytes > limits.max_instruction_bytes THEN
    error := format('instruction exceeds %s bytes', limits.max_instruction_bytes);
  ELSIF query_bytes > limits.max_query_bytes THEN
    error := format('query exceeds %s bytes', limits.max_query_bytes);
  ELSIF output_schema_bytes > limits.max_output_schema_bytes THEN
    error := format('output schema exceeds %s bytes', limits.max_output_schema_bytes);
  ELSIF runtime_json_bytes > limits.max_runtime_json_bytes THEN
    error := format('runtime JSON exceeds %s bytes', limits.max_runtime_json_bytes);
  ELSIF input_shaping_bytes > limits.max_input_shaping_bytes THEN
    error := format('input shaping exceeds %s bytes', limits.max_input_shaping_bytes);
  ELSIF decision_contract_bytes > limits.max_decision_contract_bytes THEN
    error := format('decision contract exceeds %s bytes', limits.max_decision_contract_bytes);
  ELSIF definition_bytes > limits.max_definition_bytes THEN
    error := format('definition exceeds %s bytes', limits.max_definition_bytes);
  END IF;
  IF error IS NOT NULL THEN
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT metrics.json_depth, metrics.json_nodes, metrics.identifier_count
  INTO json_depth, json_nodes, identifier_count
  FROM otlet.bounded_jsonb_complexity(
    COALESCE(definition_complexity_report.definition, 'null'::jsonb),
    limits.max_json_depth,
    limits.max_json_nodes
  ) metrics;

  IF json_depth > limits.max_json_depth THEN
    error := format('JSON nesting exceeds depth %s', limits.max_json_depth);
  ELSIF json_nodes > limits.max_json_nodes THEN
    error := format('JSON node count exceeds %s', limits.max_json_nodes);
  ELSIF identifier_count > limits.max_identifiers THEN
    error := format('identifier count exceeds %s', limits.max_identifiers);
  END IF;
  IF error IS NOT NULL THEN
    RETURN NEXT;
    RETURN;
  END IF;

  query_identifier_count := regexp_count(
    COALESCE(input_query, ''),
    '[[:alpha:]_][[:alnum:]_$]*|"([^"]|"")*"'
  )::bigint;
  IF query_identifier_count > limits.max_query_identifiers THEN
    error := format('query identifier count exceeds %s', limits.max_query_identifiers);
    RETURN NEXT;
    RETURN;
  END IF;

  prompt_template_bytes := octet_length(otlet.portable_prompt_text(
    instruction,
    output_schema,
    '{}'::jsonb,
    effective_runtime_options,
    decision_contract
  ))::bigint;
  IF prompt_template_bytes > limits.max_prompt_template_bytes THEN
    error := format('prompt template exceeds %s bytes', limits.max_prompt_template_bytes);
  END IF;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.workload_definition_complexity_guard(
  definition jsonb
) RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  complexity_error text;
BEGIN
  SELECT report.error
  INTO complexity_error
  FROM otlet.definition_complexity_report(
    workload_definition_complexity_guard.definition
  ) report;
  IF complexity_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet definition complexity rejected: %', complexity_error;
  END IF;
END;
$$;

CREATE FUNCTION otlet.task_definition_complexity_guard(
  input_query text,
  instruction text,
  output_schema jsonb,
  runtime_options jsonb DEFAULT '{}'::jsonb,
  input_shaping jsonb DEFAULT '{}'::jsonb,
  decision_contract jsonb DEFAULT '{}'::jsonb,
  source_definition jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  PERFORM otlet.workload_definition_complexity_guard(jsonb_build_object(
    'format', 'otlet.task.definition.input.v1',
    'task', jsonb_build_object(
      'input_query', task_definition_complexity_guard.input_query,
      'instruction', task_definition_complexity_guard.instruction,
      'output_schema', task_definition_complexity_guard.output_schema,
      'runtime_options', COALESCE(task_definition_complexity_guard.runtime_options, '{}'::jsonb),
      'input_shaping', COALESCE(task_definition_complexity_guard.input_shaping, '{}'::jsonb),
      'decision_contract', COALESCE(task_definition_complexity_guard.decision_contract, '{}'::jsonb)
    ),
    'source', task_definition_complexity_guard.source_definition
  ));
END;
$$;

CREATE FUNCTION otlet.source_query_complexity_guard(
  query text
) RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  PERFORM otlet.task_definition_complexity_guard(
    source_query_complexity_guard.query,
    '',
    '{}'::jsonb
  );
END;
$$;

CREATE FUNCTION otlet.source_query_dependency_complexity_guard(
  root_relation_oid oid
) RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  dependency_count bigint;
  max_identifiers bigint;
BEGIN
  SELECT limits.max_identifiers
  INTO max_identifiers
  FROM otlet.definition_complexity_limits limits;
  SELECT count(*)
  INTO dependency_count
  FROM otlet.source_query_dependencies(
    source_query_dependency_complexity_guard.root_relation_oid,
    max_identifiers + 1,
    true
  );
  IF dependency_count > max_identifiers THEN
    RAISE EXCEPTION 'otlet definition complexity rejected: source dependency count exceeds %',
      max_identifiers;
  END IF;
END;
$$;

CREATE FUNCTION otlet.action_target_catalog_complexity_guard(
  target_name text
) RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  limits otlet.definition_complexity_limits%ROWTYPE;
  catalog_items bigint;
  catalog_bytes bigint;
BEGIN
  SELECT * INTO limits FROM otlet.definition_complexity_limits;
  WITH RECURSIVE target AS (
    SELECT
      target_row.target_table::oid AS relation_oid,
      target_row.allowed_columns,
      otlet.action_execution_role_oid() AS execution_role_oid
    FROM otlet.action_targets target_row
    WHERE target_row.name = action_target_catalog_complexity_guard.target_name
  ), relevant_types(type_oid) AS (
    SELECT attribute.atttypid
    FROM target
    JOIN pg_attribute attribute ON attribute.attrelid = target.relation_oid
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
    UNION
    SELECT type_row.typbasetype
    FROM target
    JOIN pg_attribute attribute ON attribute.attrelid = target.relation_oid
    JOIN pg_type type_row ON type_row.oid = attribute.atttypid
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND type_row.typbasetype <> 0
    UNION
    SELECT type_row.typelem
    FROM target
    JOIN pg_attribute attribute ON attribute.attrelid = target.relation_oid
    JOIN pg_type type_row ON type_row.oid = attribute.atttypid
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND type_row.typelem <> 0
  ), inherited(roleid) AS (
    SELECT membership.roleid
    FROM target
    JOIN pg_auth_members membership ON membership.member = target.execution_role_oid
    WHERE membership.inherit_option
    UNION ALL
    SELECT membership.roleid
    FROM inherited parent
    JOIN pg_auth_members membership ON membership.member = parent.roleid
    WHERE membership.inherit_option
  ) CYCLE roleid SET is_cycle USING membership_path,
  bounded_inherited AS MATERIALIZED (
    SELECT inherited.roleid
    FROM inherited
    LIMIT limits.max_identifiers + 1
  ), catalog_values(value) AS (
    SELECT concat_ws('|', 'target', target.allowed_columns::text)
    FROM target
    UNION ALL
    SELECT concat_ws(
      '|',
      'relation',
      relation.relname::text,
      relation.reloptions::text,
      relation.relpartbound::text
    )
    FROM target
    JOIN pg_class relation ON relation.oid = target.relation_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'column',
      attribute.attname::text,
      attribute.attacl::text,
      default_row.adbin::text
    )
    FROM target
    JOIN pg_attribute attribute ON attribute.attrelid = target.relation_oid
    LEFT JOIN pg_attrdef default_row
      ON default_row.adrelid = attribute.attrelid
     AND default_row.adnum = attribute.attnum
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
    UNION ALL
    SELECT concat_ws(
      '|',
      'relation_acl',
      acl.grantor::text,
      acl.grantee::text,
      acl.privilege_type,
      acl.is_grantable::text
    )
    FROM target
    JOIN pg_class relation ON relation.oid = target.relation_oid
    CROSS JOIN LATERAL aclexplode(COALESCE(
      relation.relacl,
      acldefault('r', relation.relowner)
    )) acl
    UNION ALL
    SELECT concat_ws(
      '|',
      'column_acl',
      acl.grantor::text,
      acl.grantee::text,
      acl.privilege_type,
      acl.is_grantable::text
    )
    FROM target
    JOIN pg_attribute attribute ON attribute.attrelid = target.relation_oid
    CROSS JOIN LATERAL aclexplode(attribute.attacl) acl
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
    UNION ALL
    SELECT concat_ws(
      '|',
      'type',
      type_row.typname::text,
      type_row.typacl::text
    )
    FROM relevant_types
    JOIN pg_type type_row ON type_row.oid = relevant_types.type_oid
    UNION ALL
    SELECT concat_ws('|', 'enum', enum_row.enumlabel)
    FROM relevant_types
    JOIN pg_enum enum_row ON enum_row.enumtypid = relevant_types.type_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'domain_constraint',
      constraint_row.conname::text,
      constraint_row.conbin::text
    )
    FROM relevant_types
    JOIN pg_constraint constraint_row ON constraint_row.contypid = relevant_types.type_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'relation_constraint',
      constraint_row.conname::text,
      constraint_row.conbin::text,
      constraint_row.conkey::text,
      constraint_row.confkey::text
    )
    FROM target
    JOIN pg_constraint constraint_row
      ON constraint_row.conrelid = target.relation_oid
      OR constraint_row.confrelid = target.relation_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'index',
      index_row.indkey::text,
      index_row.indclass::text,
      index_row.indcollation::text,
      index_row.indoption::text,
      index_row.indexprs::text,
      index_row.indpred::text
    )
    FROM target
    JOIN pg_index index_row ON index_row.indrelid = target.relation_oid
    WHERE index_row.indisunique
       OR index_row.indisprimary
       OR index_row.indisexclusion
    UNION ALL
    SELECT concat_ws('|', 'rewrite', rewrite.ev_action::text)
    FROM target
    JOIN pg_rewrite rewrite ON rewrite.ev_class = target.relation_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'policy',
      policy.polname::text,
      policy.polroles::text,
      policy.polqual::text
    )
    FROM target
    JOIN pg_policy policy ON policy.polrelid = target.relation_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'inheritance',
      inheritance.inhparent::text,
      inheritance.inhrelid::text
    )
    FROM target
    JOIN pg_inherits inheritance
      ON inheritance.inhparent = target.relation_oid
      OR inheritance.inhrelid = target.relation_oid
    UNION ALL
    SELECT concat_ws(
      '|',
      'executor',
      function_row.proname::text,
      function_row.proconfig::text
    )
    FROM pg_proc function_row
    WHERE function_row.oid IN (
      to_regprocedure('otlet.dry_run_action(bigint)'),
      to_regprocedure('otlet.apply_action(bigint)')
    )
    UNION ALL
    SELECT concat_ws('|', 'role', role_row.rolname::text, role_row.rolconfig::text)
    FROM target
    JOIN pg_roles role_row ON role_row.oid = target.execution_role_oid
    UNION ALL
    SELECT concat_ws('|', 'membership', role_row.rolname::text)
    FROM bounded_inherited
    JOIN pg_roles role_row ON role_row.oid = bounded_inherited.roleid
  ), bounded AS MATERIALIZED (
    SELECT catalog_values.value
    FROM catalog_values
    LIMIT limits.max_identifiers + 1
  )
  SELECT count(*), COALESCE(sum(octet_length(bounded.value)), 0)
  INTO catalog_items, catalog_bytes
  FROM bounded;

  IF catalog_items > limits.max_identifiers THEN
    RAISE EXCEPTION 'otlet definition complexity rejected: action target catalog item count exceeds %',
      limits.max_identifiers;
  ELSIF catalog_bytes > limits.max_definition_bytes THEN
    RAISE EXCEPTION 'otlet definition complexity rejected: action target catalog text exceeds % bytes',
      limits.max_definition_bytes;
  END IF;
END;
$$;

CREATE FUNCTION otlet.bounded_action_target_contract(
  target_name text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target_contract jsonb;
BEGIN
  PERFORM otlet.action_target_catalog_complexity_guard(
    bounded_action_target_contract.target_name
  );
  target_contract := otlet.action_target_contract_descriptor(
    bounded_action_target_contract.target_name
  );
  PERFORM otlet.workload_definition_complexity_guard(jsonb_build_object(
    'format', 'otlet.action.target.contract.v1',
    'action_target', target_contract
  ));
  RETURN target_contract;
END;
$$;

CREATE FUNCTION otlet.validate_action_workflow_policy_complexity() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.bounded_action_target_contract(NEW.target_name);
  PERFORM otlet.workload_definition_complexity_guard(jsonb_build_object(
    'format', 'otlet.action.workflow.policy.v1',
    'action_workflow_policy', to_jsonb(NEW)
  ));
  RETURN NEW;
END;
$$;

CREATE TRIGGER action_workflow_policies_00_definition_complexity
BEFORE INSERT OR UPDATE ON otlet.action_workflow_policies
FOR EACH ROW EXECUTE FUNCTION otlet.validate_action_workflow_policy_complexity();

CREATE FUNCTION otlet.validate_decision_rule_preset_complexity() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.task_definition_complexity_guard(
    NULL,
    '',
    '{}'::jsonb,
    decision_contract => NEW.decision_contract
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER decision_rule_presets_00_definition_complexity
BEFORE INSERT ON otlet.decision_rule_presets
FOR EACH ROW EXECUTE FUNCTION otlet.validate_decision_rule_preset_complexity();

CREATE FUNCTION otlet.validate_default_runtime_complexity() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.task_definition_complexity_guard(
    NULL,
    '',
    '{}'::jsonb,
    runtime_options => NEW.default_runtime_options
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER production_policy_00_default_runtime_complexity
BEFORE INSERT OR UPDATE OF default_runtime_options ON otlet.production_policy
FOR EACH ROW EXECUTE FUNCTION otlet.validate_default_runtime_complexity();

CREATE FUNCTION otlet.validate_model_selection_complexity() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM otlet.workload_definition_complexity_guard(jsonb_build_object(
    'selection', NEW.accept_field_checks
  ));
  RETURN NEW;
END;
$$;

CREATE TRIGGER model_selection_policies_00_definition_complexity
BEFORE INSERT OR UPDATE OF accept_field_checks ON otlet.model_selection_policies
FOR EACH ROW EXECUTE FUNCTION otlet.validate_model_selection_complexity();

CREATE FUNCTION otlet.validate_watch_definition_complexity() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  max_identifiers bigint;
BEGIN
  SELECT limits.max_identifiers
  INTO max_identifiers
  FROM otlet.definition_complexity_limits limits;
  IF COALESCE(cardinality(NEW.action_types), 0) > max_identifiers
     OR COALESCE(cardinality(NEW.input_columns), 0) > max_identifiers THEN
    RAISE EXCEPTION 'otlet definition complexity rejected: identifier count exceeds %',
      max_identifiers;
  END IF;
  PERFORM otlet.task_definition_complexity_guard(
    NEW.candidate_query,
    '',
    NEW.output_schema,
    NEW.runtime_options,
    NEW.input_shaping,
    NEW.decision_contract,
    jsonb_build_object(
      'name', NEW.name,
      'kind', NEW.kind,
      'task_name', NEW.task_name,
      'record_type', NEW.record_type,
      'source_table', NEW.source_table,
      'subject_column', NEW.subject_column,
      'selection_policy', NEW.selection_policy,
      'trigger_policy', NEW.trigger_policy,
      'action_types', to_jsonb(NEW.action_types),
      'input_columns', to_jsonb(NEW.input_columns),
      'pair_sources', NEW.pair_sources
    )
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER watches_00_definition_complexity
BEFORE INSERT OR UPDATE ON otlet.watches
FOR EACH ROW EXECUTE FUNCTION otlet.validate_watch_definition_complexity();

CREATE VIEW otlet.definition_complexity_status AS
SELECT
  head.task_name,
  head.active_workload_revision_hash AS workload_revision_hash,
  report.instruction_bytes,
  report.query_bytes,
  report.output_schema_bytes,
  report.runtime_json_bytes,
  report.input_shaping_bytes,
  report.decision_contract_bytes,
  report.definition_bytes,
  report.json_depth,
  report.json_nodes,
  report.identifier_count,
  report.query_identifier_count,
  report.prompt_template_bytes,
  report.error
FROM otlet.workload_revision_heads head
JOIN otlet.workload_revisions revision
  ON revision.task_name = head.task_name
 AND revision.workload_revision_hash = head.active_workload_revision_hash
CROSS JOIN LATERAL otlet.definition_complexity_report(revision.definition) report;

REVOKE ALL ON TABLE otlet.definition_complexity_limits FROM PUBLIC;
REVOKE ALL ON TABLE otlet.definition_complexity_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.bounded_jsonb_complexity(jsonb, integer, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.definition_complexity_report(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.workload_definition_complexity_guard(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.task_definition_complexity_guard(text, text, jsonb, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.source_query_complexity_guard(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.source_query_dependency_complexity_guard(oid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.action_target_catalog_complexity_guard(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.bounded_action_target_contract(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_action_workflow_policy_complexity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_decision_rule_preset_complexity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_default_runtime_complexity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_model_selection_complexity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_watch_definition_complexity() FROM PUBLIC;
