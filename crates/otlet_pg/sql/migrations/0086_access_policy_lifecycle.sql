CREATE OR REPLACE FUNCTION otlet.access_policy_descriptor(target_role regrole)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  WITH target AS (
    SELECT role.oid, role.rolname
    FROM pg_catalog.pg_roles role
    WHERE role.oid = $1::oid
  ), grants AS (
    SELECT
      'schema'::text AS object_kind,
      namespace.nspname::text AS object_name,
      privilege.privilege_type::text,
      privilege.is_grantable
    FROM target
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'otlet'
    CROSS JOIN LATERAL pg_catalog.aclexplode(namespace.nspacl) privilege
    WHERE privilege.grantee = target.oid

    UNION ALL

    SELECT
      CASE relation.relkind
        WHEN 'S' THEN 'sequence'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        ELSE 'relation'
      END,
      pg_catalog.format('%I.%I', namespace.nspname, relation.relname),
      privilege.privilege_type,
      privilege.is_grantable
    FROM target
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'otlet'
    JOIN pg_catalog.pg_class relation ON relation.relnamespace = namespace.oid
    CROSS JOIN LATERAL pg_catalog.aclexplode(relation.relacl) privilege
    WHERE privilege.grantee = target.oid

    UNION ALL

    SELECT
      'column',
      pg_catalog.format(
        '%I.%I.%I',
        namespace.nspname,
        relation.relname,
        attribute.attname
      ),
      privilege.privilege_type,
      privilege.is_grantable
    FROM target
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'otlet'
    JOIN pg_catalog.pg_class relation ON relation.relnamespace = namespace.oid
    JOIN pg_catalog.pg_attribute attribute ON attribute.attrelid = relation.oid
    CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) privilege
    WHERE attribute.attnum > 0
      AND NOT attribute.attisdropped
      AND privilege.grantee = target.oid

    UNION ALL

    SELECT
      'function',
      pg_catalog.format(
        '%I.%I(%s)',
        namespace.nspname,
        function.proname,
        pg_catalog.pg_get_function_identity_arguments(function.oid)
      ),
      privilege.privilege_type,
      privilege.is_grantable
    FROM target
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'otlet'
    JOIN pg_catalog.pg_proc function ON function.pronamespace = namespace.oid
    CROSS JOIN LATERAL pg_catalog.aclexplode(function.proacl) privilege
    WHERE privilege.grantee = target.oid

    UNION ALL

    SELECT
      'type',
      pg_catalog.format('%I.%I', namespace.nspname, type.typname),
      privilege.privilege_type,
      privilege.is_grantable
    FROM target
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'otlet'
    JOIN pg_catalog.pg_type type ON type.typnamespace = namespace.oid
    CROSS JOIN LATERAL pg_catalog.aclexplode(type.typacl) privilege
    WHERE privilege.grantee = target.oid
  )
  SELECT jsonb_build_object(
    'role_oid', target.oid::bigint,
    'role_name', target.rolname,
    'grants', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'object_kind', grants.object_kind,
          'object_name', grants.object_name,
          'privilege', grants.privilege_type,
          'grantable', grants.is_grantable
        ) ORDER BY
          grants.object_kind,
          grants.object_name,
          grants.privilege_type,
          grants.is_grantable
      ) FILTER (WHERE grants.object_kind IS NOT NULL),
      '[]'::jsonb
    )
  )
  FROM target
  LEFT JOIN grants ON true
  GROUP BY target.oid, target.rolname;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.append_administrative_change(text,text,text,text,text)'::regprocedure
  );
  IF pg_catalog.strpos(
    definition,
    'WHERE role.oid = role_setting::regrole::oid;'
  ) = 0 THEN
    RAISE EXCEPTION 'Otlet active administrative role lookup rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    'WHERE role.oid = role_setting::regrole::oid;',
    'WHERE role.rolname = role_setting;'
  );
END;
$migration$;

CREATE TABLE otlet.access_policy_roles (
  role_oid oid PRIMARY KEY,
  registered_role_name text NOT NULL UNIQUE CHECK (
    NULLIF(btrim(registered_role_name), '') IS NOT NULL
  ),
  capabilities text[] NOT NULL CHECK (
    cardinality(capabilities) BETWEEN 1 AND 5
    AND capabilities <@ ARRAY[
      'application',
      'auditor',
      'operator',
      'reviewer',
      'portable_worker',
      'administrator'
    ]::text[]
    AND array_position(capabilities, NULL) IS NULL
    AND (
      NOT ('administrator' = ANY(capabilities))
      OR capabilities = ARRAY['administrator']::text[]
    )
  ),
  policy_version integer NOT NULL CHECK (policy_version > 0),
  desired_grants jsonb NOT NULL CHECK (jsonb_typeof(desired_grants) = 'array'),
  desired_revision_hash text NOT NULL CHECK (
    desired_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  registered_by_oid oid NOT NULL,
  registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reconciled_by_oid oid NOT NULL,
  reconciled_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION otlet.access_policy_actor_oid() RETURNS oid
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_setting text := current_setting('role', true);
  actor_oid oid;
BEGIN
  SELECT role.oid
  INTO actor_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = CASE
    WHEN role_setting IS NULL OR role_setting = 'none' THEN session_user
    ELSE role_setting
  END;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'active access-policy actor does not exist';
  END IF;
  RETURN actor_oid;
END;
$$;

CREATE FUNCTION otlet.require_access_policy_manager(
  manage_administrator boolean
) RETURNS oid
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actor_oid oid := otlet.access_policy_actor_oid();
  owner_oid oid;
BEGIN
  SELECT relation.relowner
  INTO owner_oid
  FROM pg_catalog.pg_class relation
  WHERE relation.oid = 'otlet.access_policy_roles'::regclass;

  IF actor_oid = owner_oid THEN
    RETURN actor_oid;
  END IF;
  IF require_access_policy_manager.manage_administrator THEN
    RAISE EXCEPTION 'only the Otlet owner may manage administrator access';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.access_policy_roles policy
    JOIN pg_catalog.pg_roles role ON role.oid = policy.role_oid
    WHERE policy.capabilities = ARRAY['administrator']::text[]
      AND policy.policy_version = 1
      AND role.rolname = policy.registered_role_name
      AND NOT role.rolsuper
      AND NOT role.rolcreaterole
      AND NOT role.rolcreatedb
      AND NOT role.rolreplication
      AND NOT role.rolbypassrls
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_auth_members membership
        WHERE membership.member = policy.role_oid
      )
      AND policy.desired_grants = (
        otlet.access_policy_descriptor(policy.role_oid::regrole) -> 'grants'
      )
      AND policy.desired_revision_hash = otlet.administrative_state_hash(
        'access_policy',
        jsonb_build_object(
          'role_oid', policy.role_oid::bigint,
          'role_name', policy.registered_role_name,
          'capabilities', policy.capabilities,
          'policy_version', policy.policy_version,
          'grants', policy.desired_grants
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace namespace
        WHERE namespace.nspname = 'otlet'
          AND namespace.nspowner = policy.role_oid
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class relation
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'otlet'
          AND relation.relowner = policy.role_oid
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc function
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = function.pronamespace
        WHERE namespace.nspname = 'otlet'
          AND function.proowner = policy.role_oid
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_type type
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = type.typnamespace
        WHERE namespace.nspname = 'otlet'
          AND type.typowner = policy.role_oid
      )
      AND pg_catalog.pg_has_role(actor_oid, policy.role_oid, 'MEMBER')
  ) THEN
    RETURN actor_oid;
  END IF;
  RAISE EXCEPTION 'Otlet access-policy administration is denied';
END;
$$;

CREATE FUNCTION otlet.assert_access_policy_target(target_role regrole)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target record;
  owner_oid oid;
BEGIN
  SELECT *
  INTO target
  FROM pg_catalog.pg_roles role
  WHERE role.oid = assert_access_policy_target.target_role::oid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist',
      assert_access_policy_target.target_role::oid;
  END IF;

  SELECT relation.relowner
  INTO owner_oid
  FROM pg_catalog.pg_class relation
  WHERE relation.oid = 'otlet.access_policy_roles'::regclass;

  IF target.oid = owner_oid
     OR target.rolsuper
     OR target.rolcreaterole
     OR target.rolcreatedb
     OR target.rolreplication
     OR target.rolbypassrls THEN
    RAISE EXCEPTION 'Otlet access policies require an unprivileged dedicated role';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members membership
    WHERE membership.member = target.oid
  ) THEN
    RAISE EXCEPTION 'Otlet access-policy role % must not inherit or SET ROLE to another role',
      target.rolname;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace namespace
    WHERE namespace.nspname = 'otlet'
      AND namespace.nspowner = target.oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'otlet'
      AND relation.relowner = target.oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proowner = target.oid
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_type type
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = type.typnamespace
    WHERE namespace.nspname = 'otlet'
      AND type.typowner = target.oid
  ) THEN
    RAISE EXCEPTION 'Otlet access-policy role % must not own Otlet objects',
      target.rolname;
  END IF;
  RETURN target.rolname;
END;
$$;

CREATE FUNCTION otlet.clear_access_policy_grants(target_role regrole)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text := otlet.assert_access_policy_target(
    clear_access_policy_grants.target_role
  );
  granted_type regtype;
BEGIN
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA otlet FROM %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA otlet FROM %I',
    role_name
  );
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA otlet FROM %I',
    role_name
  );
  FOR granted_type IN
    SELECT type.oid::regtype
    FROM pg_catalog.pg_type type
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = type.typnamespace
    CROSS JOIN LATERAL pg_catalog.aclexplode(type.typacl) privilege
    WHERE namespace.nspname = 'otlet'
      AND privilege.grantee = clear_access_policy_grants.target_role::oid
    ORDER BY type.oid
  LOOP
    EXECUTE pg_catalog.format(
      'REVOKE ALL PRIVILEGES ON TYPE %s FROM %I',
      granted_type,
      role_name
    );
  END LOOP;
  EXECUTE pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON SCHEMA otlet FROM %I',
    role_name
  );
END;
$$;

CREATE FUNCTION otlet.apply_access_policy_capabilities(
  target_role regrole,
  capabilities text[]
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  capability text;
  role_name text := otlet.assert_access_policy_target(
    apply_access_policy_capabilities.target_role
  );
  old_revision_hash text;
BEGIN
  FOREACH capability IN ARRAY apply_access_policy_capabilities.capabilities
  LOOP
    CASE capability
      WHEN 'application' THEN
        PERFORM otlet.grant_application_access(target_role);
      WHEN 'auditor' THEN
        PERFORM otlet.grant_auditor_access(target_role);
      WHEN 'operator' THEN
        PERFORM otlet.grant_operator_access(target_role);
      WHEN 'reviewer' THEN
        PERFORM otlet.grant_reviewer_access(target_role);
      WHEN 'portable_worker' THEN
        PERFORM otlet.grant_portable_worker_access(target_role);
      WHEN 'administrator' THEN
        old_revision_hash := otlet.access_policy_revision(target_role);
        EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
        EXECUTE pg_catalog.format(
          'GRANT SELECT ON TABLE otlet.access_policy_role_status TO %I',
          role_name
        );
        EXECUTE pg_catalog.format(
          'GRANT EXECUTE ON FUNCTION '
          'otlet.access_policy_role_status_rows(), '
          'otlet.register_access_policy_capability(regrole,text,text,text), '
          'otlet.reconcile_access_policy_role(regrole,text,text), '
          'otlet.revoke_access_policy_capability(regrole,text,text,text) TO %I',
          role_name
        );
        PERFORM otlet.finish_access_policy_grant(
          'administrator',
          target_role,
          old_revision_hash
        );
      ELSE
        RAISE EXCEPTION 'unsupported Otlet access-policy capability %', capability;
    END CASE;
  END LOOP;
  RETURN otlet.access_policy_descriptor(target_role) -> 'grants';
END;
$$;

CREATE VIEW otlet.access_policy_role_status_internal AS
WITH installed AS (
  SELECT
    policy.*,
    role.rolname AS installed_role_name,
    role.rolsuper,
    role.rolcreaterole,
    role.rolcreatedb,
    role.rolreplication,
    role.rolbypassrls,
    CASE WHEN role.oid IS NULL THEN false ELSE
      EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace namespace
        WHERE namespace.nspname = 'otlet'
          AND namespace.nspowner = role.oid
      ) OR EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class relation
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'otlet'
          AND relation.relowner = role.oid
      ) OR EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc function
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = function.pronamespace
        WHERE namespace.nspname = 'otlet'
          AND function.proowner = role.oid
      ) OR EXISTS (
        SELECT 1
        FROM pg_catalog.pg_type type
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = type.typnamespace
        WHERE namespace.nspname = 'otlet'
          AND type.typowner = role.oid
      )
    END AS owns_otlet_objects,
    CASE WHEN role.oid IS NOT NULL THEN
      otlet.access_policy_descriptor(role.oid::regrole) -> 'grants'
    END AS installed_grants,
    COALESCE((
      SELECT jsonb_agg(parent.rolname ORDER BY parent.rolname)
      FROM pg_catalog.pg_auth_members membership
      JOIN pg_catalog.pg_roles parent ON parent.oid = membership.roleid
      WHERE membership.member = policy.role_oid
    ), '[]'::jsonb) AS inherited_roles
  FROM otlet.access_policy_roles policy
  LEFT JOIN pg_catalog.pg_roles role ON role.oid = policy.role_oid
), compared AS (
  SELECT
    installed.*,
    COALESCE((
      SELECT count(*)
      FROM jsonb_array_elements(installed.desired_grants) desired(grant_value)
      WHERE NOT COALESCE(installed.installed_grants, '[]'::jsonb)
        @> jsonb_build_array(desired.grant_value)
    ), 0)::bigint AS missing_privilege_count,
    COALESCE((
      SELECT count(*)
      FROM jsonb_array_elements(
        COALESCE(installed.installed_grants, '[]'::jsonb)
      ) actual(grant_value)
      WHERE NOT installed.desired_grants
        @> jsonb_build_array(actual.grant_value)
    ), 0)::bigint AS unexpected_privilege_count,
    installed.desired_revision_hash = otlet.administrative_state_hash(
      'access_policy',
      jsonb_build_object(
        'role_oid', installed.role_oid::bigint,
        'role_name', installed.registered_role_name,
        'capabilities', installed.capabilities,
        'policy_version', installed.policy_version,
        'grants', installed.desired_grants
      )
    ) AS desired_revision_valid
  FROM installed
)
SELECT
  'otlet.access_policy.status.v1'::text AS status_schema,
  1::integer AS current_policy_version,
  compared.role_oid,
  compared.registered_role_name,
  compared.installed_role_name,
  compared.capabilities,
  compared.policy_version AS desired_policy_version,
  compared.desired_grants,
  compared.installed_grants,
  compared.missing_privilege_count,
  compared.unexpected_privilege_count,
  compared.inherited_roles,
  compared.desired_revision_hash,
  compared.desired_revision_valid,
  compared.registered_by_oid,
  compared.registered_at,
  compared.reconciled_by_oid,
  compared.reconciled_at,
  CASE
    WHEN compared.installed_role_name IS NULL THEN 'role_missing'
    WHEN compared.installed_role_name <> compared.registered_role_name
      THEN 'role_identity_mismatch'
    WHEN compared.rolsuper
      OR compared.rolcreaterole
      OR compared.rolcreatedb
      OR compared.rolreplication
      OR compared.rolbypassrls THEN 'role_privilege_drift'
    WHEN compared.owns_otlet_objects THEN 'role_ownership_drift'
    WHEN compared.inherited_roles <> '[]'::jsonb THEN 'role_membership_drift'
    WHEN NOT compared.desired_revision_valid THEN 'manifest_hash_mismatch'
    WHEN compared.policy_version <> 1 THEN 'policy_upgrade_required'
    WHEN compared.missing_privilege_count > 0 THEN 'missing_privileges'
    WHEN compared.unexpected_privilege_count > 0 THEN 'unexpected_privileges'
    ELSE 'reconciled'
  END AS reconciliation_status,
  COALESCE(
    compared.installed_role_name = compared.registered_role_name
    AND NOT compared.rolsuper
    AND NOT compared.rolcreaterole
    AND NOT compared.rolcreatedb
    AND NOT compared.rolreplication
    AND NOT compared.rolbypassrls
    AND NOT compared.owns_otlet_objects
    AND compared.inherited_roles = '[]'::jsonb
    AND compared.desired_revision_valid
    AND compared.policy_version = 1
    AND compared.missing_privilege_count = 0
    AND compared.unexpected_privilege_count = 0,
    false
  ) AS reconciled
FROM compared;

CREATE FUNCTION otlet.access_policy_role_status_rows()
RETURNS SETOF otlet.access_policy_role_status_internal
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT * FROM otlet.access_policy_role_status_internal;
$$;

CREATE VIEW otlet.access_policy_role_status AS
SELECT * FROM otlet.access_policy_role_status_rows();

CREATE FUNCTION otlet.register_access_policy_capability(
  target_role regrole,
  capability text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actor_oid oid;
  role_name text;
  existing otlet.access_policy_roles%ROWTYPE;
  next_capabilities text[];
  next_grants jsonb;
  next_revision_hash text;
BEGIN
  capability := lower(NULLIF(btrim(capability), ''));
  IF capability IS NULL OR capability NOT IN (
    'application',
    'auditor',
    'operator',
    'reviewer',
    'portable_worker',
    'administrator'
  ) THEN
    RAISE EXCEPTION 'unsupported Otlet access-policy capability %', capability;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || target_role::oid::text,
      0
    )
  );
  role_name := otlet.assert_access_policy_target(target_role);

  SELECT * INTO existing
  FROM otlet.access_policy_roles policy
  WHERE policy.role_oid = target_role::oid
  FOR UPDATE;
  actor_oid := otlet.require_access_policy_manager(
    capability = 'administrator'
    OR 'administrator' = ANY(COALESCE(existing.capabilities, ARRAY[]::text[]))
  );
  PERFORM otlet.set_administrative_change_context(reason, ticket);
  IF FOUND AND existing.registered_role_name <> role_name THEN
    RAISE EXCEPTION 'Otlet access-policy role identity changed from % to %',
      existing.registered_role_name,
      role_name;
  END IF;
  SELECT array_agg(DISTINCT value ORDER BY value)
  INTO next_capabilities
  FROM unnest(
    COALESCE(existing.capabilities, ARRAY[]::text[]) || capability
  ) value;
  IF 'administrator' = ANY(next_capabilities)
     AND next_capabilities <> ARRAY['administrator']::text[] THEN
    RAISE EXCEPTION 'Otlet administrator access cannot be combined with another capability';
  END IF;
  IF FOUND
     AND existing.capabilities = next_capabilities
     AND existing.policy_version = 1
     AND existing.desired_grants = (
       otlet.access_policy_descriptor(target_role) -> 'grants'
     )
     AND existing.desired_revision_hash = otlet.administrative_state_hash(
       'access_policy',
       jsonb_build_object(
         'role_oid', target_role::oid::bigint,
         'role_name', existing.registered_role_name,
         'capabilities', existing.capabilities,
         'policy_version', existing.policy_version,
         'grants', existing.desired_grants
       )
     ) THEN
    RETURN;
  END IF;

  PERFORM otlet.clear_access_policy_grants(target_role);
  next_grants := otlet.apply_access_policy_capabilities(
    target_role,
    next_capabilities
  );
  next_revision_hash := otlet.administrative_state_hash(
    'access_policy',
    jsonb_build_object(
      'role_oid', target_role::oid::bigint,
      'role_name', role_name,
      'capabilities', next_capabilities,
      'policy_version', 1,
      'grants', next_grants
    )
  );

  INSERT INTO otlet.access_policy_roles (
    role_oid,
    registered_role_name,
    capabilities,
    policy_version,
    desired_grants,
    desired_revision_hash,
    registered_by_oid,
    reconciled_by_oid
  ) VALUES (
    target_role::oid,
    role_name,
    next_capabilities,
    1,
    next_grants,
    next_revision_hash,
    actor_oid,
    actor_oid
  )
  ON CONFLICT (role_oid) DO UPDATE
  SET capabilities = EXCLUDED.capabilities,
      policy_version = EXCLUDED.policy_version,
      desired_grants = EXCLUDED.desired_grants,
      desired_revision_hash = EXCLUDED.desired_revision_hash,
      reconciled_by_oid = EXCLUDED.reconciled_by_oid,
      reconciled_at = clock_timestamp();
  PERFORM otlet.append_administrative_change(
    'access_policy',
    role_name,
    'register_capability',
    existing.desired_revision_hash,
    next_revision_hash
  );
END;
$$;

CREATE FUNCTION otlet.reconcile_access_policy_role(
  target_role regrole,
  reason text,
  ticket text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actor_oid oid;
  role_name text;
  existing otlet.access_policy_roles%ROWTYPE;
  next_grants jsonb;
  next_revision_hash text;
  old_installed_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || target_role::oid::text,
      0
    )
  );
  SELECT * INTO existing
  FROM otlet.access_policy_roles policy
  WHERE policy.role_oid = target_role::oid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Otlet access-policy role % is not registered', target_role;
  END IF;
  actor_oid := otlet.require_access_policy_manager(
    'administrator' = ANY(existing.capabilities)
  );
  PERFORM otlet.set_administrative_change_context(reason, ticket);
  role_name := otlet.assert_access_policy_target(target_role);
  IF existing.registered_role_name <> role_name THEN
    RAISE EXCEPTION 'Otlet access-policy role identity changed from % to %',
      existing.registered_role_name,
      role_name;
  END IF;
  IF existing.policy_version = 1
     AND existing.desired_grants = (
       otlet.access_policy_descriptor(target_role) -> 'grants'
     )
     AND existing.desired_revision_hash = otlet.administrative_state_hash(
       'access_policy',
       jsonb_build_object(
         'role_oid', target_role::oid::bigint,
         'role_name', existing.registered_role_name,
         'capabilities', existing.capabilities,
         'policy_version', existing.policy_version,
         'grants', existing.desired_grants
       )
     ) THEN
    RETURN;
  END IF;

  old_installed_hash := otlet.administrative_state_hash(
    'access_policy',
    jsonb_build_object(
      'role_oid', target_role::oid::bigint,
      'role_name', role_name,
      'capabilities', existing.capabilities,
      'policy_version', existing.policy_version,
      'grants', otlet.access_policy_descriptor(target_role) -> 'grants'
    )
  );
  PERFORM otlet.clear_access_policy_grants(target_role);
  next_grants := otlet.apply_access_policy_capabilities(
    target_role,
    existing.capabilities
  );
  next_revision_hash := otlet.administrative_state_hash(
    'access_policy',
    jsonb_build_object(
      'role_oid', target_role::oid::bigint,
      'role_name', role_name,
      'capabilities', existing.capabilities,
      'policy_version', 1,
      'grants', next_grants
    )
  );
  UPDATE otlet.access_policy_roles policy
  SET policy_version = 1,
      desired_grants = next_grants,
      desired_revision_hash = next_revision_hash,
      reconciled_by_oid = actor_oid,
      reconciled_at = clock_timestamp()
  WHERE policy.role_oid = target_role::oid;
  PERFORM otlet.append_administrative_change(
    'access_policy',
    role_name,
    'reconcile',
    old_installed_hash,
    next_revision_hash
  );
END;
$$;

CREATE FUNCTION otlet.revoke_access_policy_capability(
  target_role regrole,
  capability text,
  reason text,
  ticket text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actor_oid oid;
  role_name text;
  existing otlet.access_policy_roles%ROWTYPE;
  next_capabilities text[];
  next_grants jsonb;
  next_revision_hash text;
BEGIN
  capability := lower(NULLIF(btrim(capability), ''));
  IF capability IS NULL OR capability NOT IN (
    'application',
    'auditor',
    'operator',
    'reviewer',
    'portable_worker',
    'administrator'
  ) THEN
    RAISE EXCEPTION 'unsupported Otlet access-policy capability %', capability;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || target_role::oid::text,
      0
    )
  );
  SELECT * INTO existing
  FROM otlet.access_policy_roles policy
  WHERE policy.role_oid = target_role::oid
  FOR UPDATE;
  IF NOT FOUND OR NOT (capability = ANY(existing.capabilities)) THEN
    RETURN;
  END IF;
  actor_oid := otlet.require_access_policy_manager(
    'administrator' = ANY(existing.capabilities)
  );
  PERFORM otlet.set_administrative_change_context(reason, ticket);
  role_name := otlet.assert_access_policy_target(target_role);
  IF existing.registered_role_name <> role_name THEN
    RAISE EXCEPTION 'Otlet access-policy role identity changed from % to %',
      existing.registered_role_name,
      role_name;
  END IF;
  SELECT array_agg(value ORDER BY value)
  INTO next_capabilities
  FROM unnest(existing.capabilities) value
  WHERE value <> capability;

  PERFORM otlet.clear_access_policy_grants(target_role);
  IF next_capabilities IS NULL THEN
    DELETE FROM otlet.access_policy_roles policy
    WHERE policy.role_oid = target_role::oid;
    next_revision_hash := NULL;
  ELSE
    next_grants := otlet.apply_access_policy_capabilities(
      target_role,
      next_capabilities
    );
    next_revision_hash := otlet.administrative_state_hash(
      'access_policy',
      jsonb_build_object(
        'role_oid', target_role::oid::bigint,
        'role_name', role_name,
        'capabilities', next_capabilities,
        'policy_version', 1,
        'grants', next_grants
      )
    );
    UPDATE otlet.access_policy_roles policy
    SET capabilities = next_capabilities,
        policy_version = 1,
        desired_grants = next_grants,
        desired_revision_hash = next_revision_hash,
        reconciled_by_oid = actor_oid,
        reconciled_at = clock_timestamp()
    WHERE policy.role_oid = target_role::oid;
  END IF;
  PERFORM otlet.append_administrative_change(
    'access_policy',
    role_name,
    'revoke_capability',
    existing.desired_revision_hash,
    next_revision_hash
  );
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.grant_auditor_access(regrole)'::regprocedure
  );
  old_fragment := $old$    'otlet.labeled_quality_status TO %I',$old$;
  new_fragment := $new$    'otlet.labeled_quality_status, '
    'otlet.access_policy_role_status TO %I',$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'Otlet access-policy auditor grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$  IF pg_catalog.to_regclass('otlet.portable_schema_migrations') IS NULL THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.access_policy_status TO %I',
      role_name
    );
  END IF;$old$;
  new_fragment := $new$  EXECUTE pg_catalog.format(
    'GRANT SELECT ON TABLE otlet.access_policy_status TO %I',
    role_name
  );$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'Otlet portable access-policy status grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$    'otlet.task_resource_status, '
    'otlet.native_cancellation_slo_status, '$old$;
  new_fragment := $new$    'otlet.task_resource_status, '
    'otlet.production_policy_status, '
    'otlet.native_cancellation_slo_status, '$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'Otlet production-policy auditor grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  old_fragment := $old$    'otlet.source_query_contract_error(jsonb, boolean), '
    'otlet.route_readiness_status_rows(), '$old$;
  new_fragment := $new$    'otlet.source_query_contract_error(jsonb, boolean), '
    'otlet.access_policy_role_status_rows(), '
    'otlet.export_eval_cases(integer), '
    'otlet.route_readiness_status_rows(), '$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'Otlet evaluation-export auditor grant rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  old_fragment := $old$'otlet.access_policy_status'::text, 'otlet.failure_retry_status'::text$old$;
  new_fragment := $new$'otlet.access_policy_status'::text, 'otlet.access_policy_role_status'::text, 'otlet.failure_retry_status'::text$new$;
  IF pg_catalog.strpos(definition, old_fragment) = 0 THEN
    RAISE EXCEPTION 'Otlet access-policy redaction status rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  IF pg_catalog.strpos(definition, '7 AS policy_version') = 0 THEN
    RAISE EXCEPTION 'Otlet access-policy redaction version is unexpected';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS '
    || pg_catalog.replace(
      definition,
      '7 AS policy_version',
      '8 AS policy_version'
    );
END;
$migration$;

ALTER FUNCTION otlet.verify_invariants(integer)
RENAME TO verify_invariants_before_access_policy;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.verify_invariants_before_access_policy(integer)'::regprocedure
  );
  IF position('verify_invariants.sample_limit' IN definition) > 0 THEN
    definition := pg_catalog.replace(
      definition,
      'verify_invariants.sample_limit',
      'verify_invariants_before_access_policy.sample_limit'
    );
    EXECUTE definition;
  END IF;
END;
$migration$;

CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_invariants_before_access_policy(
    verify_invariants.sample_limit
  ) invariant;

  RETURN QUERY
  SELECT
    'registered_access_policy_is_reconciled'::text,
    'access_policy'::text,
    status.role_oid::text,
    jsonb_build_object(
      'registered_role_name', status.registered_role_name,
      'installed_role_name', status.installed_role_name,
      'capabilities', status.capabilities,
      'reconciliation_status', status.reconciliation_status,
      'missing_privilege_count', status.missing_privilege_count,
      'unexpected_privilege_count', status.unexpected_privilege_count,
      'inherited_roles', status.inherited_roles
    )
  FROM otlet.access_policy_role_status status
  WHERE NOT status.reconciled
  ORDER BY status.role_oid
  LIMIT verify_invariants.sample_limit;
END;
$$;

COMMENT ON TABLE otlet.access_policy_roles IS
'Desired role capabilities and their last reconciled direct Otlet grants';
COMMENT ON VIEW otlet.access_policy_role_status_internal IS
'Owner-only desired versus installed direct Otlet privileges and role drift';
COMMENT ON VIEW otlet.access_policy_role_status IS
'Desired versus installed direct Otlet privileges with role and membership drift';

REVOKE ALL ON TABLE otlet.access_policy_roles FROM PUBLIC;
REVOKE ALL ON TABLE otlet.access_policy_role_status_internal FROM PUBLIC;
REVOKE ALL ON TABLE otlet.access_policy_role_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.access_policy_actor_oid() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.require_access_policy_manager(boolean)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.assert_access_policy_target(regrole)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.clear_access_policy_grants(regrole)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.apply_access_policy_capabilities(
  regrole,
  text[]
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.access_policy_role_status_rows() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.register_access_policy_capability(
  regrole,
  text,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reconcile_access_policy_role(
  regrole,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.revoke_access_policy_capability(
  regrole,
  text,
  text,
  text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants(integer) FROM PUBLIC;
