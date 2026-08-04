CREATE TABLE otlet.administrative_change_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  object_type text NOT NULL CHECK (object_type IN (
    'model',
    'task',
    'watch',
    'selection',
    'action_policy',
    'access_policy',
    'retention'
  )),
  object_name text NOT NULL CHECK (
    NULLIF(btrim(object_name), '') IS NOT NULL
    AND octet_length(object_name) <= 512
  ),
  operation text NOT NULL CHECK (
    operation ~ '^[a-z][a-z_]*$'
    AND octet_length(operation) <= 64
  ),
  actor_oid oid NOT NULL,
  actor_name text NOT NULL CHECK (NULLIF(btrim(actor_name), '') IS NOT NULL),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (NULLIF(btrim(active_role_name), '') IS NOT NULL),
  reason text CHECK (
    reason IS NULL OR (
      NULLIF(btrim(reason), '') IS NOT NULL
      AND octet_length(reason) <= 4096
    )
  ),
  ticket text CHECK (
    ticket IS NULL OR (
      NULLIF(btrim(ticket), '') IS NOT NULL
      AND octet_length(ticket) <= 512
    )
  ),
  old_revision_hash text CHECK (
    old_revision_hash IS NULL
    OR old_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  new_revision_hash text CHECK (
    new_revision_hash IS NULL
    OR new_revision_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (num_nonnulls(reason, ticket) >= 1),
  CHECK (num_nonnulls(old_revision_hash, new_revision_hash) >= 1),
  CHECK (old_revision_hash IS DISTINCT FROM new_revision_hash)
);

CREATE INDEX administrative_change_events_object_idx
ON otlet.administrative_change_events (
  object_type,
  object_name,
  changed_at DESC,
  event_id DESC
);

CREATE FUNCTION otlet.guard_administrative_change_events() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.administrative_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet administrative change events are append only';
END;
$$;

CREATE TRIGGER administrative_change_events_row_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.administrative_change_events
FOR EACH ROW EXECUTE FUNCTION otlet.guard_administrative_change_events();

CREATE TRIGGER administrative_change_events_truncate_guard
BEFORE TRUNCATE ON otlet.administrative_change_events
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_administrative_change_events();

CREATE FUNCTION otlet.set_administrative_change_context(
  reason text DEFAULT NULL,
  ticket text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actual_reason text := NULLIF(btrim(set_administrative_change_context.reason), '');
  actual_ticket text := NULLIF(btrim(set_administrative_change_context.ticket), '');
BEGIN
  IF actual_reason IS NULL AND actual_ticket IS NULL THEN
    RAISE EXCEPTION 'otlet administrative change requires a reason or ticket';
  END IF;
  IF octet_length(COALESCE(actual_reason, '')) > 4096 THEN
    RAISE EXCEPTION 'otlet administrative change reason exceeds 4096 bytes';
  END IF;
  IF octet_length(COALESCE(actual_ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet administrative change ticket exceeds 512 bytes';
  END IF;
  PERFORM set_config('otlet.administrative_reason', COALESCE(actual_reason, ''), true);
  PERFORM set_config('otlet.administrative_ticket', COALESCE(actual_ticket, ''), true);
END;
$$;

CREATE FUNCTION otlet.administrative_state_hash(
  object_type text,
  state jsonb
) RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.identity_hash('administrative_' || $1, $2);
$$;

CREATE FUNCTION otlet.append_administrative_change(
  object_type text,
  object_name text,
  operation text,
  old_revision_hash text,
  new_revision_hash text
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  actual_reason text := NULLIF(btrim(current_setting('otlet.administrative_reason', true)), '');
  actual_ticket text := NULLIF(btrim(current_setting('otlet.administrative_ticket', true)), '');
  role_setting text := current_setting('role', true);
  actor_oid oid;
  active_role_oid oid;
  active_role_name text;
  previous_append text := current_setting('otlet.administrative_append', true);
  saved_event_id bigint;
BEGIN
  IF append_administrative_change.old_revision_hash
     IS NOT DISTINCT FROM append_administrative_change.new_revision_hash THEN
    RETURN NULL;
  END IF;
  IF append_administrative_change.object_type NOT IN (
    'model',
    'task',
    'watch',
    'selection',
    'action_policy',
    'access_policy',
    'retention'
  ) THEN
    RAISE EXCEPTION 'otlet administrative object type % is unsupported',
      append_administrative_change.object_type;
  END IF;
  IF actual_reason IS NULL AND actual_ticket IS NULL THEN
    RAISE EXCEPTION 'otlet administrative change requires SET LOCAL otlet.administrative_reason or otlet.administrative_ticket';
  END IF;
  IF octet_length(COALESCE(actual_reason, '')) > 4096 THEN
    RAISE EXCEPTION 'otlet administrative change reason exceeds 4096 bytes';
  END IF;
  IF octet_length(COALESCE(actual_ticket, '')) > 512 THEN
    RAISE EXCEPTION 'otlet administrative change ticket exceeds 512 bytes';
  END IF;

  SELECT role.oid
  INTO actor_oid
  FROM pg_catalog.pg_roles role
  WHERE role.rolname = session_user;
  IF role_setting IS NULL OR role_setting = 'none' THEN
    active_role_oid := actor_oid;
    active_role_name := session_user;
  ELSE
    SELECT role.oid, role.rolname
    INTO active_role_oid, active_role_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = role_setting::regrole::oid;
  END IF;

  PERFORM set_config('otlet.administrative_append', 'on', true);
  INSERT INTO otlet.administrative_change_events (
    object_type,
    object_name,
    operation,
    actor_oid,
    actor_name,
    active_role_oid,
    active_role_name,
    reason,
    ticket,
    old_revision_hash,
    new_revision_hash
  ) VALUES (
    append_administrative_change.object_type,
    append_administrative_change.object_name,
    append_administrative_change.operation,
    actor_oid,
    session_user,
    active_role_oid,
    active_role_name,
    actual_reason,
    actual_ticket,
    append_administrative_change.old_revision_hash,
    append_administrative_change.new_revision_hash
  )
  RETURNING event_id INTO saved_event_id;
  PERFORM set_config(
    'otlet.administrative_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN saved_event_id;
END;
$$;

CREATE VIEW otlet.audit_administrative_change_export AS
SELECT
  event_id,
  object_type,
  object_name,
  operation,
  actor_oid,
  actor_name,
  active_role_oid,
  active_role_name,
  reason,
  ticket,
  old_revision_hash,
  new_revision_hash,
  changed_at
FROM otlet.administrative_change_events;

CREATE FUNCTION otlet.record_administrative_row_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET intervalstyle = 'postgres'
AS $$
DECLARE
  old_state jsonb;
  new_state jsonb;
  object_type text;
  object_name text;
  old_revision_hash text;
  new_revision_hash text;
BEGIN
  IF current_setting('otlet.administrative_suppress', true) = 'on' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP <> 'INSERT' THEN
    old_state := to_jsonb(OLD);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    new_state := to_jsonb(NEW);
  END IF;

  CASE TG_TABLE_NAME
    WHEN 'models' THEN
      object_type := 'model';
      object_name := COALESCE(new_state, old_state) ->> 'name';
      old_state := old_state - ARRAY['created_at', 'last_used_at'];
      new_state := new_state - ARRAY['created_at', 'last_used_at'];
    WHEN 'tasks' THEN
      object_type := 'task';
      object_name := COALESCE(new_state, old_state) ->> 'name';
      old_state := old_state - ARRAY[
        'created_at',
        'lifecycle_revision_hash',
        'lifecycle_previous_revision_hash',
        'lifecycle_promoted_at',
        'lifecycle_changed_at'
      ];
      new_state := new_state - ARRAY[
        'created_at',
        'lifecycle_revision_hash',
        'lifecycle_previous_revision_hash',
        'lifecycle_promoted_at',
        'lifecycle_changed_at'
      ];
    WHEN 'watches' THEN
      object_type := 'watch';
      object_name := COALESCE(new_state, old_state) ->> 'name';
      old_state := old_state - ARRAY['created_at', 'updated_at'];
      new_state := new_state - ARRAY['created_at', 'updated_at'];
    WHEN 'model_selection_policies' THEN
      object_type := 'selection';
      object_name := COALESCE(new_state, old_state) ->> 'task_name';
      old_state := old_state - ARRAY['created_at', 'updated_at'];
      new_state := new_state - ARRAY['created_at', 'updated_at'];
    WHEN 'action_targets' THEN
      object_type := 'action_policy';
      object_name := 'target:' || (COALESCE(new_state, old_state) ->> 'name');
      IF old_state IS NOT NULL THEN
        old_state := jsonb_set(
          old_state,
          '{target_table}',
          to_jsonb(OLD.target_table::oid::text)
        );
      END IF;
      IF new_state IS NOT NULL THEN
        new_state := jsonb_set(
          new_state,
          '{target_table}',
          to_jsonb(NEW.target_table::oid::text)
        );
      END IF;
      old_state := old_state - ARRAY['created_at', 'updated_at'];
      new_state := new_state - ARRAY['created_at', 'updated_at'];
    WHEN 'action_workflow_policies' THEN
      object_type := 'action_policy';
      object_name := 'workflow:'
        || (COALESCE(new_state, old_state) ->> 'task_name')
        || ':'
        || (COALESCE(new_state, old_state) ->> 'action_type');
      old_state := old_state - ARRAY['created_at', 'updated_at'];
      new_state := new_state - ARRAY['created_at', 'updated_at'];
    WHEN 'production_policy' THEN
      object_type := 'retention';
      object_name := COALESCE(new_state, old_state) ->> 'name';
      IF old_state IS NOT NULL THEN
        old_state := jsonb_build_object(
          'worker_event_retention', old_state -> 'worker_event_retention',
          'trace_detail_retention', old_state -> 'trace_detail_retention',
          'eval_label_retention', old_state -> 'eval_label_retention',
          'delete_stale_materialization_retention', old_state -> 'delete_stale_materialization_retention',
          'sensitive_evidence_mode', old_state -> 'sensitive_evidence_mode',
          'sensitive_evidence_retention', old_state -> 'sensitive_evidence_retention',
          'failed_job_retention', old_state -> 'failed_job_retention'
        );
      END IF;
      IF new_state IS NOT NULL THEN
        new_state := jsonb_build_object(
          'worker_event_retention', new_state -> 'worker_event_retention',
          'trace_detail_retention', new_state -> 'trace_detail_retention',
          'eval_label_retention', new_state -> 'eval_label_retention',
          'delete_stale_materialization_retention', new_state -> 'delete_stale_materialization_retention',
          'sensitive_evidence_mode', new_state -> 'sensitive_evidence_mode',
          'sensitive_evidence_retention', new_state -> 'sensitive_evidence_retention',
          'failed_job_retention', new_state -> 'failed_job_retention'
        );
      END IF;
    ELSE
      RAISE EXCEPTION 'otlet administrative trigger does not support table %', TG_TABLE_NAME;
  END CASE;

  IF old_state IS NOT NULL THEN
    old_revision_hash := otlet.administrative_state_hash(object_type, old_state);
  END IF;
  IF new_state IS NOT NULL THEN
    new_revision_hash := otlet.administrative_state_hash(object_type, new_state);
  END IF;
  PERFORM otlet.append_administrative_change(
    object_type,
    object_name,
    lower(TG_OP),
    old_revision_hash,
    new_revision_hash
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER models_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF name, artifact_path, artifact_hash,
  artifact_identity, max_active_jobs ON otlet.models
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER tasks_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF name, input_query, source_relations, source_query_contract,
  instruction, output_schema, model_name, runtime_options, input_shaping,
  decision_contract, lifecycle_state ON otlet.tasks
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER watches_administrative_change
AFTER INSERT OR UPDATE OR DELETE ON otlet.watches
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER model_selection_policies_administrative_change
AFTER INSERT OR UPDATE OR DELETE ON otlet.model_selection_policies
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER action_targets_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF name, target_table, identity_column,
  allowed_columns, enabled, contract_generation ON otlet.action_targets
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER action_workflow_policies_administrative_change
AFTER INSERT OR UPDATE OR DELETE ON otlet.action_workflow_policies
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE TRIGGER production_policy_retention_administrative_change
AFTER INSERT OR DELETE OR UPDATE OF worker_event_retention, trace_detail_retention,
  eval_label_retention, delete_stale_materialization_retention,
  sensitive_evidence_mode, sensitive_evidence_retention,
  failed_job_retention ON otlet.production_policy
FOR EACH ROW EXECUTE FUNCTION otlet.record_administrative_row_change();

CREATE FUNCTION otlet.access_policy_descriptor(target_role regrole) RETURNS jsonb
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

CREATE FUNCTION otlet.access_policy_revision(target_role regrole) RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.administrative_state_hash(
    'access_policy',
    otlet.access_policy_descriptor($1)
  );
$$;

CREATE FUNCTION otlet.finish_access_policy_grant(
  policy_name text,
  target_role regrole,
  old_revision_hash text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  new_revision_hash text;
BEGIN
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = finish_access_policy_grant.target_role::oid;

  IF finish_access_policy_grant.policy_name IN ('auditor', 'operator') THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.audit_administrative_change_export TO %I',
      role_name
    );
  END IF;
  new_revision_hash := otlet.access_policy_revision(
    finish_access_policy_grant.target_role
  );
  PERFORM otlet.append_administrative_change(
    'access_policy',
    finish_access_policy_grant.policy_name || ':' || role_name,
    'grant',
    finish_access_policy_grant.old_revision_hash,
    new_revision_hash
  );
END;
$$;

REVOKE ALL ON TABLE otlet.administrative_change_events FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_administrative_change_export FROM PUBLIC;
REVOKE ALL ON SEQUENCE otlet.administrative_change_events_event_id_seq FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_administrative_change_events() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_administrative_change_context(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.administrative_state_hash(text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.append_administrative_change(text, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_administrative_row_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.access_policy_descriptor(regrole) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.access_policy_revision(regrole) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.finish_access_policy_grant(text, regrole, text) FROM PUBLIC;
