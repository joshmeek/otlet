CREATE FUNCTION otlet.source_role_descriptor(role_oid oid) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'oid', role_row.oid::text,
    'name', role_row.rolname,
    'superuser', role_row.rolsuper,
    'inherit', role_row.rolinherit,
    'bypass_rls', role_row.rolbypassrls,
    'config', COALESCE(to_jsonb(role_row.rolconfig), '[]'::jsonb),
    'memberships', COALESCE((
      WITH RECURSIVE inherited(roleid) AS (
        SELECT membership.roleid
        FROM pg_auth_members membership
        WHERE membership.member = source_role_descriptor.role_oid
          AND membership.inherit_option
        UNION
        SELECT membership.roleid
        FROM pg_auth_members membership
        JOIN inherited parent ON parent.roleid = membership.member
        WHERE membership.inherit_option
      )
      SELECT jsonb_agg(jsonb_build_object(
        'oid', inherited.roleid::text,
        'name', inherited_role.rolname
      ) ORDER BY inherited_role.rolname, inherited.roleid)
      FROM inherited
      JOIN pg_roles inherited_role ON inherited_role.oid = inherited.roleid
    ), '[]'::jsonb)
  ))
  FROM pg_roles role_row
  WHERE role_row.oid = source_role_descriptor.role_oid;
$$;

CREATE FUNCTION otlet.source_relation_descriptor(
  relation_oid oid,
  execution_role_oid oid,
  referenced_attnums jsonb
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'oid', relation.oid::text,
    'name', format('%I.%I', namespace.nspname, relation.relname),
    'namespace_oid', namespace.oid::text,
    'kind', relation.relkind,
    'owner_oid', relation.relowner::text,
    'persistence', relation.relpersistence,
    'has_inheritors', EXISTS (
      SELECT 1
      FROM pg_inherits inheritance
      WHERE inheritance.inhparent = relation.oid
    ),
    'row_security', relation.relrowsecurity,
    'force_row_security', relation.relforcerowsecurity,
    'rls_applies', relation.relrowsecurity
      AND NOT role_row.rolsuper
      AND NOT role_row.rolbypassrls
      AND (relation.relowner <> execution_role_oid OR relation.relforcerowsecurity),
    'schema_usage', has_schema_privilege(execution_role_oid, namespace.oid, 'USAGE'),
    'select_allowed', has_table_privilege(execution_role_oid, relation.oid, 'SELECT') OR NOT EXISTS (
      SELECT 1
      FROM pg_attribute attribute
      WHERE attribute.attrelid = relation.oid
        AND attribute.attnum > 0
        AND NOT attribute.attisdropped
        AND (
          COALESCE(referenced_attnums, '[]'::jsonb) @> '[0]'::jsonb
          OR COALESCE(referenced_attnums, '[]'::jsonb) @> to_jsonb(ARRAY[attribute.attnum])
        )
        AND NOT has_column_privilege(
          execution_role_oid,
          relation.oid,
          attribute.attnum,
          'SELECT'
        )
    ),
    'referenced_attnums', COALESCE(referenced_attnums, '[]'::jsonb),
    'columns', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'number', attribute.attnum,
        'name', attribute.attname,
        'type_oid', attribute.atttypid::text,
        'type_modifier', attribute.atttypmod,
        'not_null', attribute.attnotnull,
        'collation_oid', attribute.attcollation::text,
        'generated', attribute.attgenerated,
        'identity', attribute.attidentity,
        'select_allowed', CASE
          WHEN attribute.attnum > 0 THEN has_column_privilege(
            execution_role_oid,
            relation.oid,
            attribute.attnum,
            'SELECT'
          )
          ELSE has_table_privilege(execution_role_oid, relation.oid, 'SELECT')
        END
      ) ORDER BY attribute.attnum)
      FROM pg_attribute attribute
      WHERE attribute.attrelid = relation.oid
        AND NOT attribute.attisdropped
        AND (
          (
            COALESCE(referenced_attnums, '[]'::jsonb) @> '[0]'::jsonb
            AND attribute.attnum > 0
          )
          OR COALESCE(referenced_attnums, '[]'::jsonb) @> to_jsonb(ARRAY[attribute.attnum])
        )
    ), '[]'::jsonb),
    'view_definition', CASE
      WHEN relation.relkind = 'v' THEN pg_get_viewdef(relation.oid, false)
      ELSE NULL
    END,
    'view_security_invoker', CASE
      WHEN relation.relkind = 'v' THEN COALESCE(
        relation.reloptions @> ARRAY['security_invoker=true'],
        false
      )
      ELSE NULL
    END,
    'view_security_barrier', CASE
      WHEN relation.relkind = 'v' THEN COALESCE(
        relation.reloptions @> ARRAY['security_barrier=true'],
        false
      )
      ELSE NULL
    END,
    'partition_key', CASE
      WHEN relation.relkind = 'p' THEN pg_get_partkeydef(relation.oid)
      ELSE NULL
    END,
    'partitions', CASE
      WHEN relation.relkind = 'p' THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'oid', child.oid::text,
          'name', format('%I.%I', child_namespace.nspname, child.relname),
          'bound', pg_get_expr(child.relpartbound, child.oid)
        ) ORDER BY child.oid)
        FROM pg_inherits inheritance
        JOIN pg_class child ON child.oid = inheritance.inhrelid
        JOIN pg_namespace child_namespace ON child_namespace.oid = child.relnamespace
        WHERE inheritance.inhparent = relation.oid
      ), '[]'::jsonb)
      ELSE NULL
    END,
    'policies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'oid', policy.oid::text,
        'name', policy.polname,
        'permissive', policy.polpermissive,
        'command', policy.polcmd,
        'roles', to_jsonb(ARRAY(
          SELECT policy_role::text
          FROM unnest(policy.polroles) policy_role
          ORDER BY policy_role
        )),
        'using', pg_get_expr(policy.polqual, policy.polrelid)
      ) ORDER BY policy.polname, policy.oid)
      FROM pg_policy policy
      WHERE policy.polrelid = relation.oid
        AND policy.polcmd IN ('r', '*')
        AND relation.relrowsecurity
        AND NOT role_row.rolsuper
        AND NOT role_row.rolbypassrls
        AND (relation.relowner <> execution_role_oid OR relation.relforcerowsecurity)
        AND EXISTS (
          SELECT 1
          FROM unnest(policy.polroles) policy_role
          WHERE policy_role = 0
             OR pg_has_role(execution_role_oid, policy_role, 'MEMBER')
        )
    ), '[]'::jsonb)
  ))
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  JOIN pg_roles role_row ON role_row.oid = execution_role_oid
  WHERE relation.oid = source_relation_descriptor.relation_oid;
$$;

CREATE FUNCTION otlet.source_function_descriptor(
  function_oid oid,
  execution_role_oid oid
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_build_object(
    'oid', function_row.oid::text,
    'name', format('%I.%I(%s)',
      namespace.nspname,
      function_row.proname,
      pg_get_function_identity_arguments(function_row.oid)
    ),
    'namespace_oid', namespace.oid::text,
    'owner_oid', function_row.proowner::text,
    'kind', function_row.prokind,
    'language', language.lanname,
    'volatility', function_row.provolatile,
    'security_definer', function_row.prosecdef,
    'leakproof', function_row.proleakproof,
    'strict', function_row.proisstrict,
    'parallel', function_row.proparallel,
    'config', COALESCE(to_jsonb(function_row.proconfig), '[]'::jsonb),
    'schema_usage', has_schema_privilege(execution_role_oid, namespace.oid, 'USAGE'),
    'execute_allowed', has_function_privilege(execution_role_oid, function_row.oid, 'EXECUTE'),
    'parsed_sql_body', function_row.prosqlbody IS NOT NULL,
    'definition', CASE
      WHEN function_row.prokind = 'f' THEN pg_get_functiondef(function_row.oid)
      ELSE function_row.prosrc
    END
  )
  FROM pg_proc function_row
  JOIN pg_namespace namespace ON namespace.oid = function_row.pronamespace
  JOIN pg_language language ON language.oid = function_row.prolang
  WHERE function_row.oid = source_function_descriptor.function_oid;
$$;

CREATE FUNCTION otlet.source_query_binding_descriptor(
  relation_names jsonb,
  function_names jsonb,
  operator_names jsonb,
  path_namespaces jsonb
) RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  WITH path AS (
    SELECT
      (namespace.value ->> 'oid')::oid AS namespace_oid,
      namespace.ordinality
    FROM jsonb_array_elements(COALESCE(
      source_query_binding_descriptor.path_namespaces,
      '[]'::jsonb
    )) WITH ORDINALITY namespace(value, ordinality)
  ),
  relation_name AS (
    SELECT DISTINCT value #>> '{}' AS name
    FROM jsonb_array_elements(COALESCE(
      source_query_binding_descriptor.relation_names,
      '[]'::jsonb
    )) name(value)
  ),
  function_name AS (
    SELECT DISTINCT value #>> '{}' AS name
    FROM jsonb_array_elements(COALESCE(
      source_query_binding_descriptor.function_names,
      '[]'::jsonb
    )) name(value)
  ),
  operator_name AS (
    SELECT DISTINCT value #>> '{}' AS name
    FROM jsonb_array_elements(COALESCE(
      source_query_binding_descriptor.operator_names,
      '[]'::jsonb
    )) name(value)
  )
  SELECT jsonb_build_object(
    'relation_names', COALESCE((
      SELECT jsonb_agg(relation_name.name ORDER BY relation_name.name)
      FROM relation_name
    ), '[]'::jsonb),
    'function_names', COALESCE((
      SELECT jsonb_agg(function_name.name ORDER BY function_name.name)
      FROM function_name
    ), '[]'::jsonb),
    'operator_names', COALESCE((
      SELECT jsonb_agg(operator_name.name ORDER BY operator_name.name)
      FROM operator_name
    ), '[]'::jsonb),
    'relations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'oid', relation.oid::text,
        'namespace_oid', relation.relnamespace::text,
        'name', relation.relname,
        'kind', relation.relkind
      ) ORDER BY path.ordinality, relation.relname, relation.oid)
      FROM pg_class relation
      JOIN path ON path.namespace_oid = relation.relnamespace
      JOIN relation_name ON relation_name.name = relation.relname
    ), '[]'::jsonb),
    'functions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'oid', function_row.oid::text,
        'namespace_oid', function_row.pronamespace::text,
        'name', function_row.proname,
        'kind', function_row.prokind,
        'identity_arguments', pg_get_function_identity_arguments(function_row.oid),
        'input_type_oids', function_row.proargtypes::text,
        'all_type_oids', COALESCE(to_jsonb(function_row.proallargtypes), '[]'::jsonb),
        'argument_modes', COALESCE(to_jsonb(function_row.proargmodes), '[]'::jsonb),
        'argument_names', COALESCE(to_jsonb(function_row.proargnames), '[]'::jsonb),
        'default_count', function_row.pronargdefaults,
        'variadic_type_oid', function_row.provariadic::text
      ) ORDER BY path.ordinality, function_row.proname, function_row.oid)
      FROM pg_proc function_row
      JOIN path ON path.namespace_oid = function_row.pronamespace
      JOIN function_name ON function_name.name = function_row.proname
    ), '[]'::jsonb),
    'operators', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'oid', operator.oid::text,
        'namespace_oid', operator.oprnamespace::text,
        'name', operator.oprname,
        'kind', operator.oprkind,
        'left_type_oid', operator.oprleft::text,
        'right_type_oid', operator.oprright::text,
        'result_type_oid', operator.oprresult::text,
        'function_oid', operator.oprcode::text
      ) ORDER BY path.ordinality, operator.oprname, operator.oid)
      FROM pg_operator operator
      JOIN path ON path.namespace_oid = operator.oprnamespace
      JOIN operator_name ON operator_name.name = operator.oprname
    ), '[]'::jsonb)
  );
$$;

CREATE FUNCTION otlet.source_query_dependencies(root_relation_oid oid)
RETURNS TABLE(refclassid oid, refobjid oid, refobjsubid integer)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  WITH RECURSIVE dependencies(refclassid, refobjid, refobjsubid) AS (
    SELECT dependency.refclassid, dependency.refobjid, dependency.refobjsubid
    FROM pg_rewrite rewrite
    JOIN pg_depend dependency
      ON dependency.classid = 'pg_rewrite'::regclass
     AND dependency.objid = rewrite.oid
    WHERE rewrite.ev_class = source_query_dependencies.root_relation_oid
      AND dependency.deptype IN ('n', 'a')
    UNION
    SELECT 'pg_proc'::regclass::oid, (parsed.match)[2]::oid, 0
    FROM pg_rewrite rewrite
    CROSS JOIN LATERAL regexp_matches(
      rewrite.ev_action::text,
      ':(funcid|opfuncid|aggfnoid|winfnoid) ([0-9]+)',
      'g'
    ) parsed(match)
    WHERE rewrite.ev_class = source_query_dependencies.root_relation_oid
      AND (parsed.match)[2]::oid <> 0
    UNION
    SELECT 'pg_operator'::regclass::oid, (parsed.match)[1]::oid, 0
    FROM pg_rewrite rewrite
    CROSS JOIN LATERAL regexp_matches(
      rewrite.ev_action::text,
      ':opno ([0-9]+)',
      'g'
    ) parsed(match)
    WHERE rewrite.ev_class = source_query_dependencies.root_relation_oid
      AND (parsed.match)[1]::oid <> 0
    UNION
    SELECT child.refclassid, child.refobjid, child.refobjsubid
    FROM dependencies parent
    CROSS JOIN LATERAL (
      SELECT dependency.refclassid, dependency.refobjid, dependency.refobjsubid
      FROM pg_class relation
      JOIN pg_rewrite rewrite ON rewrite.ev_class = relation.oid
      JOIN pg_depend dependency
        ON dependency.classid = 'pg_rewrite'::regclass
       AND dependency.objid = rewrite.oid
      WHERE parent.refclassid = 'pg_class'::regclass
        AND relation.oid = parent.refobjid
        AND relation.relkind = 'v'
        AND dependency.deptype IN ('n', 'a')
      UNION
      SELECT 'pg_proc'::regclass::oid, (parsed.match)[2]::oid, 0
      FROM pg_class relation
      JOIN pg_rewrite rewrite ON rewrite.ev_class = relation.oid
      CROSS JOIN LATERAL regexp_matches(
        rewrite.ev_action::text,
        ':(funcid|opfuncid|aggfnoid|winfnoid) ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_class'::regclass
        AND relation.oid = parent.refobjid
        AND relation.relkind = 'v'
        AND (parsed.match)[2]::oid <> 0
      UNION
      SELECT 'pg_operator'::regclass::oid, (parsed.match)[1]::oid, 0
      FROM pg_class relation
      JOIN pg_rewrite rewrite ON rewrite.ev_class = relation.oid
      CROSS JOIN LATERAL regexp_matches(
        rewrite.ev_action::text,
        ':opno ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_class'::regclass
        AND relation.oid = parent.refobjid
        AND relation.relkind = 'v'
        AND (parsed.match)[1]::oid <> 0
      UNION
      SELECT dependency.refclassid, dependency.refobjid, dependency.refobjsubid
      FROM pg_depend dependency
      WHERE parent.refclassid = 'pg_proc'::regclass
        AND dependency.classid = 'pg_proc'::regclass
        AND dependency.objid = parent.refobjid
        AND dependency.deptype IN ('n', 'a')
      UNION
      SELECT 'pg_proc'::regclass::oid, trusted_dependency.function_oid, 0
      FROM unnest(CASE parent.refobjid
        WHEN 'otlet.identity_hash(text,jsonb)'::regprocedure::oid THEN ARRAY[
          'otlet.portable_json_hash(jsonb)'::regprocedure::oid,
          'otlet.semantic_canonical_jsonb(jsonb)'::regprocedure::oid
        ]
        WHEN 'otlet.semantic_shaped_input(jsonb,jsonb)'::regprocedure::oid THEN ARRAY[
          'otlet.semantic_canonical_jsonb(jsonb)'::regprocedure::oid
        ]
        WHEN 'otlet.portable_json_hash(jsonb)'::regprocedure::oid THEN ARRAY[
          'otlet.portable_text_hash(text)'::regprocedure::oid,
          'otlet.portable_canonical_json_text(jsonb)'::regprocedure::oid
        ]
        ELSE ARRAY[]::oid[]
      END) trusted_dependency(function_oid)
      WHERE parent.refclassid = 'pg_proc'::regclass
      UNION
      SELECT 'pg_proc'::regclass::oid, (parsed.match)[2]::oid, 0
      FROM pg_proc function_row
      CROSS JOIN LATERAL regexp_matches(
        function_row.prosqlbody::text,
        ':(funcid|opfuncid|aggfnoid|winfnoid) ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_proc'::regclass
        AND function_row.oid = parent.refobjid
        AND function_row.prosqlbody IS NOT NULL
        AND (parsed.match)[2]::oid <> 0
      UNION
      SELECT 'pg_operator'::regclass::oid, (parsed.match)[1]::oid, 0
      FROM pg_proc function_row
      CROSS JOIN LATERAL regexp_matches(
        function_row.prosqlbody::text,
        ':opno ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_proc'::regclass
        AND function_row.oid = parent.refobjid
        AND function_row.prosqlbody IS NOT NULL
        AND (parsed.match)[1]::oid <> 0
      UNION
      SELECT dependency.refclassid, dependency.refobjid, dependency.refobjsubid
      FROM pg_policy policy
      JOIN pg_class policy_relation ON policy_relation.oid = policy.polrelid
      JOIN pg_roles execution_role ON execution_role.oid = current_user::regrole::oid
      JOIN pg_depend dependency
        ON dependency.classid = 'pg_policy'::regclass
       AND dependency.objid = policy.oid
      WHERE parent.refclassid = 'pg_class'::regclass
        AND policy.polrelid = parent.refobjid
        AND policy.polcmd IN ('r', '*')
        AND policy_relation.relrowsecurity
        AND NOT execution_role.rolsuper
        AND NOT execution_role.rolbypassrls
        AND (
          policy_relation.relowner <> execution_role.oid
          OR policy_relation.relforcerowsecurity
        )
        AND EXISTS (
          SELECT 1
          FROM unnest(policy.polroles) policy_role
          WHERE policy_role = 0
             OR pg_has_role(execution_role.oid, policy_role, 'MEMBER')
        )
        AND dependency.deptype IN ('n', 'a')
      UNION
      SELECT 'pg_proc'::regclass::oid, (parsed.match)[2]::oid, 0
      FROM pg_policy policy
      JOIN pg_class policy_relation ON policy_relation.oid = policy.polrelid
      JOIN pg_roles execution_role ON execution_role.oid = current_user::regrole::oid
      CROSS JOIN LATERAL regexp_matches(
        COALESCE(policy.polqual::text, ''),
        ':(funcid|opfuncid|aggfnoid|winfnoid) ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_class'::regclass
        AND policy.polrelid = parent.refobjid
        AND policy.polcmd IN ('r', '*')
        AND policy_relation.relrowsecurity
        AND NOT execution_role.rolsuper
        AND NOT execution_role.rolbypassrls
        AND (
          policy_relation.relowner <> execution_role.oid
          OR policy_relation.relforcerowsecurity
        )
        AND EXISTS (
          SELECT 1
          FROM unnest(policy.polroles) policy_role
          WHERE policy_role = 0
             OR pg_has_role(execution_role.oid, policy_role, 'MEMBER')
        )
        AND (parsed.match)[2]::oid <> 0
      UNION
      SELECT 'pg_operator'::regclass::oid, (parsed.match)[1]::oid, 0
      FROM pg_policy policy
      JOIN pg_class policy_relation ON policy_relation.oid = policy.polrelid
      JOIN pg_roles execution_role ON execution_role.oid = current_user::regrole::oid
      CROSS JOIN LATERAL regexp_matches(
        COALESCE(policy.polqual::text, ''),
        ':opno ([0-9]+)',
        'g'
      ) parsed(match)
      WHERE parent.refclassid = 'pg_class'::regclass
        AND policy.polrelid = parent.refobjid
        AND policy.polcmd IN ('r', '*')
        AND policy_relation.relrowsecurity
        AND NOT execution_role.rolsuper
        AND NOT execution_role.rolbypassrls
        AND (
          policy_relation.relowner <> execution_role.oid
          OR policy_relation.relforcerowsecurity
        )
        AND EXISTS (
          SELECT 1
          FROM unnest(policy.polroles) policy_role
          WHERE policy_role = 0
             OR pg_has_role(execution_role.oid, policy_role, 'MEMBER')
        )
        AND (parsed.match)[1]::oid <> 0
    ) child
  )
  SELECT DISTINCT dependencies.refclassid, dependencies.refobjid, dependencies.refobjsubid
  FROM dependencies
  WHERE NOT (
    dependencies.refclassid = 'pg_class'::regclass
    AND dependencies.refobjid = source_query_dependencies.root_relation_oid
  );
$$;

CREATE FUNCTION otlet.build_source_query_contract(
  query text,
  declared_sources jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  raw_search_path text := current_setting('search_path');
  execution_role_oid oid := current_user::regrole::oid;
  probe_name text := 'otlet_source_probe_' || pg_backend_pid()::text || '_' ||
    substr(md5(clock_timestamp()::text || random()::text), 1, 12);
  probe_oid oid;
  resolved_query text;
  path_identity jsonb;
  normalized_declared jsonb := NULL;
  relation_contracts jsonb;
  function_contracts jsonb;
  relation_binding_names jsonb;
  function_binding_names jsonb;
  operator_binding_names jsonb;
  binding_contract jsonb;
  declared_source jsonb;
  declared_name text;
  declared_oid oid;
  declared_oids oid[] := ARRAY[]::oid[];
  actual_leaf_oids oid[] := ARRAY[]::oid[];
  unsafe_name text;
  bindable_query text;
BEGIN
  IF NULLIF(btrim(build_source_query_contract.query), '') IS NULL THEN
    RAISE EXCEPTION 'otlet source query is required';
  END IF;
  IF build_source_query_contract.declared_sources IS NOT NULL
     AND jsonb_typeof(build_source_query_contract.declared_sources) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet declared source relations must be a JSON array';
  END IF;
  bindable_query := regexp_replace(
    btrim(build_source_query_contract.query),
    ';[[:space:]]*$',
    ''
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'oid', namespace.oid::text,
    'name', namespace.nspname
  ) ORDER BY path.ordinality), '[]'::jsonb)
  INTO path_identity
  FROM unnest(current_schemas(true)) WITH ORDINALITY path(name, ordinality)
  JOIN pg_namespace namespace ON namespace.nspname = path.name
  WHERE namespace.nspname !~ '^pg_(toast_)?temp_';

  BEGIN
    EXECUTE format(
      E'CREATE TEMP VIEW %I AS SELECT source.subject_id::text AS subject_id, source.input::jsonb AS input FROM (\n%s\n) source',
      probe_name,
      bindable_query
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'otlet source query binding failed: %', SQLERRM;
  END;

  SELECT to_regclass(format('pg_temp.%I', probe_name))::oid INTO probe_oid;
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
  SELECT regexp_replace(
    btrim(pg_get_viewdef(probe_oid, false)),
    ';[[:space:]]*$',
    ''
  ) INTO resolved_query;
  PERFORM set_config('search_path', raw_search_path, true);

  SELECT format('%I.%I', namespace.nspname, relation.relname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname ~ '^pg_(toast_)?temp_'
  ORDER BY namespace.nspname, relation.relname
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query cannot depend on temporary relation %', unsafe_name;
  END IF;

  SELECT format('%I.%I', namespace.nspname, relation.relname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname IN ('pg_catalog', 'information_schema', 'otlet')
    AND NOT (
      namespace.nspname = 'otlet'
      AND relation.relname IN ('semantic_materializations', 'workload_revision_heads')
    )
  ORDER BY namespace.nspname, relation.relname
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query cannot read internal relation %', unsafe_name;
  END IF;

  SELECT format('%I.%I', namespace.nspname, relation.relname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'otlet')
    AND relation.relkind NOT IN ('r', 'p', 'v', 'm')
  ORDER BY namespace.nspname, relation.relname
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query relation % has unsupported kind', unsafe_name;
  END IF;

  SELECT format(
    '%I.%I.%I (%s)',
    relation_namespace.nspname,
    relation.relname,
    attribute.attname,
    format_type(attribute.atttypid, attribute.atttypmod)
  )
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace relation_namespace ON relation_namespace.oid = relation.relnamespace
  JOIN pg_attribute attribute
    ON attribute.attrelid = relation.oid
   AND attribute.attnum > 0
   AND NOT attribute.attisdropped
   AND (dependency.refobjsubid = 0 OR attribute.attnum = dependency.refobjsubid)
  JOIN pg_type attribute_type ON attribute_type.oid = attribute.atttypid
  JOIN pg_namespace type_namespace ON type_namespace.oid = attribute_type.typnamespace
  WHERE type_namespace.nspname <> 'pg_catalog'
  ORDER BY relation_namespace.nspname, relation.relname, attribute.attnum
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query uses unsupported source column type at %', unsafe_name;
  END IF;

  SELECT format('%I.%I', namespace.nspname, type_row.typname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_type type_row
    ON dependency.refclassid = 'pg_type'::regclass
   AND type_row.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = type_row.typnamespace
  WHERE namespace.nspname <> 'pg_catalog'
  ORDER BY namespace.nspname, type_row.typname, type_row.oid
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query uses unsupported PostgreSQL type %', unsafe_name;
  END IF;

  SELECT format('%I.%I', namespace.nspname, relation.relname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'otlet')
    AND relation.relkind = 'v'
    AND NOT COALESCE(relation.reloptions @> ARRAY['security_invoker=true'], false)
  ORDER BY namespace.nspname, relation.relname
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source view % must use security_invoker', unsafe_name;
  END IF;

  SELECT format('%I.%I(%s)',
    namespace.nspname,
    function_row.proname,
    pg_get_function_identity_arguments(function_row.oid)
  )
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_proc function_row
    ON dependency.refclassid = 'pg_proc'::regclass
   AND function_row.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = function_row.pronamespace
  JOIN pg_language language ON language.oid = function_row.prolang
  WHERE function_row.provolatile = 'v'
     OR function_row.prosecdef
     OR (
       namespace.nspname <> 'pg_catalog'
       AND NOT (
         function_row.oid IN (
           'otlet.identity_hash(text,jsonb)'::regprocedure::oid,
           'otlet.semantic_shaped_input(jsonb,jsonb)'::regprocedure::oid,
           'otlet.semantic_canonical_jsonb(jsonb)'::regprocedure::oid,
           'otlet.portable_json_hash(jsonb)'::regprocedure::oid,
           'otlet.portable_text_hash(text)'::regprocedure::oid,
           'otlet.portable_canonical_json_text(jsonb)'::regprocedure::oid
         )
         AND function_row.prokind = 'f'
         AND function_row.provolatile = 'i'
         AND language.lanname IN ('sql', 'plpgsql')
       )
       AND (
         function_row.prokind <> 'f'
         OR language.lanname <> 'sql'
         OR function_row.prosqlbody IS NULL
       )
     )
  ORDER BY namespace.nspname, function_row.proname, function_row.oid
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query function % is not read-only parsed SQL', unsafe_name;
  END IF;

  SELECT format('%I.%I', namespace.nspname, relation.relname)
  INTO unsafe_name
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE relation.relkind = 'p'
     OR (
       relation.relkind = 'r'
       AND EXISTS (
         SELECT 1
         FROM pg_inherits inheritance
         WHERE inheritance.inhparent = relation.oid
       )
     )
  ORDER BY namespace.nspname, relation.relname
  LIMIT 1;
  IF unsafe_name IS NOT NULL THEN
    RAISE EXCEPTION 'otlet source query cannot depend on inherited or partitioned table %',
      unsafe_name;
  END IF;

  SELECT COALESCE(jsonb_agg(DISTINCT relation.relname ORDER BY relation.relname), '[]'::jsonb)
  INTO relation_binding_names
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_class relation
    ON dependency.refclassid = 'pg_class'::regclass
   AND relation.oid = dependency.refobjid;

  SELECT COALESCE(jsonb_agg(DISTINCT function_row.proname ORDER BY function_row.proname), '[]'::jsonb)
  INTO function_binding_names
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_proc function_row
    ON dependency.refclassid = 'pg_proc'::regclass
   AND function_row.oid = dependency.refobjid;

  SELECT COALESCE(jsonb_agg(DISTINCT operator.oprname ORDER BY operator.oprname), '[]'::jsonb)
  INTO operator_binding_names
  FROM otlet.source_query_dependencies(probe_oid) dependency
  JOIN pg_operator operator
    ON dependency.refclassid = 'pg_operator'::regclass
   AND operator.oid = dependency.refobjid;

  binding_contract := otlet.source_query_binding_descriptor(
    relation_binding_names,
    function_binding_names,
    operator_binding_names,
    path_identity
  );

  SELECT COALESCE(jsonb_agg(
    otlet.source_relation_descriptor(
      relation_dependency.relation_oid,
      execution_role_oid,
      relation_dependency.attnums
    ) ORDER BY relation_dependency.relation_oid
  ), '[]'::jsonb)
  INTO relation_contracts
  FROM (
    SELECT
      relation.oid AS relation_oid,
      to_jsonb(array_agg(DISTINCT dependency.refobjsubid ORDER BY dependency.refobjsubid)) AS attnums
    FROM otlet.source_query_dependencies(probe_oid) dependency
    JOIN pg_class relation
      ON dependency.refclassid = 'pg_class'::regclass
     AND relation.oid = dependency.refobjid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'otlet')
       OR (
         namespace.nspname = 'otlet'
         AND relation.relname IN ('semantic_materializations', 'workload_revision_heads')
       )
    GROUP BY relation.oid
  ) relation_dependency;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(relation_contracts) relation(value)
    WHERE NOT COALESCE((relation.value ->> 'schema_usage')::boolean, false)
       OR NOT COALESCE((relation.value ->> 'select_allowed')::boolean, false)
  ) THEN
    RAISE EXCEPTION 'otlet source query execution role lacks source relation privileges';
  END IF;

  SELECT COALESCE(jsonb_agg(
    otlet.source_function_descriptor(function_row.oid, execution_role_oid)
    ORDER BY function_row.oid
  ), '[]'::jsonb)
  INTO function_contracts
  FROM (
    SELECT DISTINCT function_row.oid
    FROM otlet.source_query_dependencies(probe_oid) dependency
    JOIN pg_proc function_row
      ON dependency.refclassid = 'pg_proc'::regclass
     AND function_row.oid = dependency.refobjid
    JOIN pg_namespace namespace ON namespace.oid = function_row.pronamespace
    WHERE namespace.nspname <> 'pg_catalog'
  ) function_row;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(function_contracts) function_contract(value)
    WHERE NOT COALESCE((function_contract.value ->> 'schema_usage')::boolean, false)
       OR NOT COALESCE((function_contract.value ->> 'execute_allowed')::boolean, false)
  ) THEN
    RAISE EXCEPTION 'otlet source query execution role lacks source function privileges';
  END IF;

  IF build_source_query_contract.declared_sources IS NOT NULL THEN
    FOR declared_source IN
      SELECT value
      FROM jsonb_array_elements(build_source_query_contract.declared_sources) source(value)
    LOOP
      IF jsonb_typeof(declared_source) = 'string' THEN
        declared_name := declared_source #>> '{}';
      ELSIF jsonb_typeof(declared_source) = 'object' THEN
        declared_name := COALESCE(
          NULLIF(declared_source ->> 'table', ''),
          NULLIF(declared_source ->> 'source_table', ''),
          NULLIF(declared_source ->> 'name', '')
        );
      ELSE
        RAISE EXCEPTION 'otlet declared source entries must be strings or objects';
      END IF;

      declared_oid := to_regclass(declared_name)::oid;
      IF declared_oid IS NULL THEN
        RAISE EXCEPTION 'otlet declared source relation % does not exist', declared_name;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM pg_class relation
        WHERE relation.oid = declared_oid
          AND relation.relkind IN ('r', 'm')
      ) THEN
        RAISE EXCEPTION 'otlet declared source relation % must be a non-inherited table or materialized view',
          declared_name;
      END IF;
      declared_oids := array_append(declared_oids, declared_oid);
    END LOOP;

    SELECT COALESCE(array_agg(DISTINCT relation.oid ORDER BY relation.oid), ARRAY[]::oid[])
    INTO actual_leaf_oids
    FROM otlet.source_query_dependencies(probe_oid) dependency
    JOIN pg_class relation
      ON dependency.refclassid = 'pg_class'::regclass
     AND relation.oid = dependency.refobjid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', 'otlet')
      AND relation.relkind IN ('r', 'p', 'm');

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'oid', declared.oid::text,
      'name', format('%I.%I', namespace.nspname, relation.relname)
    ) ORDER BY declared.oid), '[]'::jsonb)
    INTO normalized_declared
    FROM (
      SELECT DISTINCT unnest(declared_oids) AS oid
    ) declared
    JOIN pg_class relation ON relation.oid = declared.oid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace;

    IF ARRAY(
      SELECT DISTINCT declared.oid
      FROM unnest(declared_oids) AS declared(oid)
      ORDER BY declared.oid
    )
       IS DISTINCT FROM actual_leaf_oids THEN
      RAISE EXCEPTION 'otlet declared source relations do not cover actual query reads';
    END IF;
  END IF;

  EXECUTE format('DROP VIEW pg_temp.%I', probe_name);

  RETURN jsonb_build_object(
    'format', 'otlet.source_query.v1',
    'query', jsonb_build_object(
      'raw', build_source_query_contract.query,
      'raw_hash', otlet.identity_text_hash('source_query', build_source_query_contract.query),
      'resolved', resolved_query,
      'resolved_hash', otlet.identity_text_hash('resolved_source_query', resolved_query)
    ),
    'identity', otlet.source_role_descriptor(execution_role_oid),
    'search_path', jsonb_build_object(
      'raw', raw_search_path,
      'namespaces', path_identity
    ),
    'binding', binding_contract,
    'declared_sources', normalized_declared,
    'relations', relation_contracts,
    'functions', function_contracts
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('search_path', raw_search_path, true);
  IF to_regclass(format('pg_temp.%I', probe_name)) IS NOT NULL THEN
    EXECUTE format('DROP VIEW pg_temp.%I', probe_name);
  END IF;
  RAISE;
END;
$$;

CREATE FUNCTION otlet.source_query_contract_error(
  contract jsonb,
  require_identity boolean DEFAULT false
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  stored_role_oid oid;
  dependency jsonb;
  current_descriptor jsonb;
BEGIN
  IF source_query_contract_error.contract IS NULL
     OR jsonb_typeof(source_query_contract_error.contract) = 'null' THEN
    RETURN NULL;
  END IF;
  IF source_query_contract_error.contract ->> 'format' IS DISTINCT FROM 'otlet.source_query.v1' THEN
    RETURN 'source query contract format is invalid';
  END IF;
  IF source_query_contract_error.contract #>> '{query,raw_hash}' IS DISTINCT FROM
     otlet.identity_text_hash(
       'source_query',
       source_query_contract_error.contract #>> '{query,raw}'
     ) THEN
    RETURN 'source query bytes changed';
  END IF;
  IF source_query_contract_error.contract #>> '{query,resolved_hash}' IS DISTINCT FROM
     otlet.identity_text_hash(
       'resolved_source_query',
       source_query_contract_error.contract #>> '{query,resolved}'
     ) THEN
    RETURN 'resolved source query changed';
  END IF;

  BEGIN
    stored_role_oid := (source_query_contract_error.contract #>> '{identity,oid}')::oid;
  EXCEPTION WHEN OTHERS THEN
    RETURN 'source execution identity is invalid';
  END;
  IF source_query_contract_error.require_identity
     AND current_user::regrole::oid IS DISTINCT FROM stored_role_oid THEN
    RETURN 'source execution identity changed';
  END IF;
  IF otlet.source_role_descriptor(stored_role_oid) IS DISTINCT FROM
     source_query_contract_error.contract -> 'identity' THEN
    RETURN 'source execution role drifted';
  END IF;

  FOR dependency IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(
      source_query_contract_error.contract #> '{search_path,namespaces}',
      '[]'::jsonb
    )) namespace(value)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_namespace namespace
      WHERE namespace.oid = (dependency ->> 'oid')::oid
        AND namespace.nspname = dependency ->> 'name'
    ) THEN
      RETURN 'source search_path drifted';
    END IF;
  END LOOP;

  current_descriptor := otlet.source_query_binding_descriptor(
    source_query_contract_error.contract #> '{binding,relation_names}',
    source_query_contract_error.contract #> '{binding,function_names}',
    source_query_contract_error.contract #> '{binding,operator_names}',
    source_query_contract_error.contract #> '{search_path,namespaces}'
  );
  IF current_descriptor IS DISTINCT FROM
     source_query_contract_error.contract -> 'binding' THEN
    RETURN 'source query binding drifted';
  END IF;

  FOR dependency IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(
      source_query_contract_error.contract -> 'relations',
      '[]'::jsonb
    )) relation(value)
    ORDER BY value ->> 'name'
  LOOP
    current_descriptor := otlet.source_relation_descriptor(
      (dependency ->> 'oid')::oid,
      stored_role_oid,
      dependency -> 'referenced_attnums'
    );
    IF current_descriptor IS DISTINCT FROM dependency THEN
      RETURN format('source relation %s drifted', COALESCE(dependency ->> 'name', dependency ->> 'oid'));
    END IF;
  END LOOP;

  FOR dependency IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(
      source_query_contract_error.contract -> 'functions',
      '[]'::jsonb
    )) function_contract(value)
    ORDER BY value ->> 'name'
  LOOP
    current_descriptor := otlet.source_function_descriptor(
      (dependency ->> 'oid')::oid,
      stored_role_oid
    );
    IF current_descriptor IS DISTINCT FROM dependency THEN
      RETURN format('source function %s drifted', COALESCE(dependency ->> 'name', dependency ->> 'oid'));
    END IF;
  END LOOP;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN 'source query dependency revalidation failed: ' || SQLERRM;
END;
$$;

CREATE FUNCTION otlet.source_query_contract_guard(
  contract jsonb,
  require_identity boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  dependency jsonb;
  relation_name text;
  contract_error text;
  effective_namespaces jsonb;
  stored_search_path text;
  probe_name text := 'otlet_source_guard_' || pg_backend_pid()::text || '_' ||
    substr(md5(clock_timestamp()::text || random()::text), 1, 12);
  probe_oid oid;
  rebound_query text;
  unsafe_name text;
BEGIN
  IF source_query_contract_guard.contract IS NULL
     OR jsonb_typeof(source_query_contract_guard.contract) = 'null' THEN
    RETURN;
  END IF;

  stored_search_path := source_query_contract_guard.contract #>> '{search_path,raw}';
  IF stored_search_path IS NULL THEN
    RAISE EXCEPTION 'otlet workload is suspended: source search_path is missing';
  END IF;
  PERFORM set_config('search_path', stored_search_path, true);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'oid', namespace.oid::text,
    'name', namespace.nspname
  ) ORDER BY path.ordinality), '[]'::jsonb)
  INTO effective_namespaces
  FROM unnest(current_schemas(true)) WITH ORDINALITY path(name, ordinality)
  JOIN pg_namespace namespace ON namespace.nspname = path.name
  WHERE namespace.nspname !~ '^pg_(toast_)?temp_';
  IF effective_namespaces IS DISTINCT FROM
     source_query_contract_guard.contract #> '{search_path,namespaces}' THEN
    RAISE EXCEPTION 'otlet workload is suspended: source search_path drifted';
  END IF;

  FOR dependency IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(
      source_query_contract_guard.contract -> 'relations',
      '[]'::jsonb
    )) relation(value)
    ORDER BY (value ->> 'oid')::oid
  LOOP
    SELECT format('%I.%I', namespace.nspname, relation.relname)
    INTO relation_name
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE relation.oid = (dependency ->> 'oid')::oid;
    IF relation_name IS NULL THEN
      RAISE EXCEPTION 'otlet workload is suspended: source relation % is missing',
        COALESCE(dependency ->> 'name', dependency ->> 'oid');
    END IF;
    EXECUTE format('LOCK TABLE %s IN ACCESS SHARE MODE', relation_name);
  END LOOP;

  contract_error := otlet.source_query_contract_error(
    source_query_contract_guard.contract,
    source_query_contract_guard.require_identity
  );
  IF contract_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload is suspended: %', contract_error;
  END IF;

  BEGIN
    EXECUTE format(
      E'CREATE TEMP VIEW %I AS SELECT source.subject_id::text AS subject_id, source.input::jsonb AS input FROM (\n%s\n) source',
      probe_name,
      regexp_replace(
        btrim(source_query_contract_guard.contract #>> '{query,raw}'),
        ';[[:space:]]*$',
        ''
      )
    );
    SELECT to_regclass(format('pg_temp.%I', probe_name))::oid INTO probe_oid;
    SELECT format('%I.%I', namespace.nspname, type_row.typname)
    INTO unsafe_name
    FROM pg_rewrite rewrite
    JOIN pg_depend dependency
      ON dependency.classid = 'pg_rewrite'::regclass
     AND dependency.objid = rewrite.oid
     AND dependency.refclassid = 'pg_type'::regclass
     AND dependency.deptype IN ('n', 'a')
    JOIN pg_type type_row ON type_row.oid = dependency.refobjid
    JOIN pg_namespace namespace ON namespace.oid = type_row.typnamespace
    WHERE rewrite.ev_class = probe_oid
      AND namespace.nspname <> 'pg_catalog'
    ORDER BY namespace.nspname, type_row.typname, type_row.oid
    LIMIT 1;
    IF unsafe_name IS NOT NULL THEN
      RAISE EXCEPTION 'source query binding drifted through unsupported PostgreSQL type %',
        unsafe_name;
    END IF;
    PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
    SELECT regexp_replace(
      btrim(pg_get_viewdef(probe_oid, false)),
      ';[[:space:]]*$',
      ''
    ) INTO rebound_query;
    PERFORM set_config('search_path', stored_search_path, true);
    EXECUTE format('DROP VIEW pg_temp.%I', probe_name);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('search_path', stored_search_path, true);
    IF to_regclass(format('pg_temp.%I', probe_name)) IS NOT NULL THEN
      EXECUTE format('DROP VIEW pg_temp.%I', probe_name);
    END IF;
    RAISE EXCEPTION 'otlet workload is suspended: source query rebinding failed: %', SQLERRM;
  END;
  IF rebound_query IS DISTINCT FROM
     source_query_contract_guard.contract #>> '{query,resolved}' THEN
    RAISE EXCEPTION 'otlet workload is suspended: source query binding drifted';
  END IF;
END;
$$;

CREATE FUNCTION otlet.bind_task_source_query_contract() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.input_query IS NULL THEN
    IF NEW.source_relations IS NOT NULL THEN
      RAISE EXCEPTION 'otlet task without input_query cannot declare source relations';
    END IF;
    NEW.source_query_contract := NULL;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT'
     OR NEW.input_query IS DISTINCT FROM OLD.input_query
     OR NEW.source_relations IS DISTINCT FROM OLD.source_relations
     OR NEW.source_query_contract IS DISTINCT FROM OLD.source_query_contract THEN
    NEW.source_query_contract := otlet.build_source_query_contract(
      NEW.input_query,
      NEW.source_relations
    );
    NEW.source_relations := NULLIF(
      NEW.source_query_contract -> 'declared_sources',
      'null'::jsonb
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_bind_source_query_contract
BEFORE INSERT OR UPDATE OF input_query, source_relations, source_query_contract ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.bind_task_source_query_contract();

CREATE FUNCTION otlet.require_workload_source_contract(
  task_name text,
  workload_revision_hash text
) RETURNS void
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  revision_definition jsonb;
BEGIN
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = require_workload_source_contract.task_name
    AND revision.workload_revision_hash = require_workload_source_contract.workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision is missing for task %',
      require_workload_source_contract.task_name;
  END IF;
  PERFORM otlet.source_query_contract_guard(
    revision_definition #> '{source,query_contract}',
    true
  );
  IF revision_definition #>> '{source,kind}' = 'pair' THEN
    PERFORM preflight.candidate_plan
    FROM otlet.preflight_candidate_query(
      revision_definition #>> '{source,candidate_query}',
      true,
      false
    ) preflight;
  END IF;
END;
$$;
