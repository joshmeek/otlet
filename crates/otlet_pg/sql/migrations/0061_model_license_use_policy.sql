CREATE FUNCTION otlet.model_license_use_policy_valid(definition jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rule jsonb;
  dimension text;
  values_json jsonb;
  value_json jsonb;
  value_text text;
BEGIN
  IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
     OR octet_length(definition::text) > 65536 THEN
    RETURN false;
  END IF;
  IF ARRAY(
       SELECT key
       FROM jsonb_object_keys(definition) key
       ORDER BY key COLLATE "C"
     ) IS DISTINCT FROM ARRAY[
       'deployment_purpose',
       'format',
       'license_allowlist',
       'redistribution_mode'
     ]::text[]
     OR definition ->> 'format' IS DISTINCT FROM
       'otlet.model_license_use_policy.v1' THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(definition -> 'deployment_purpose')
       NOT IN ('string', 'null')
     OR jsonb_typeof(definition -> 'redistribution_mode')
       NOT IN ('string', 'null')
     OR jsonb_typeof(definition -> 'license_allowlist')
       IS DISTINCT FROM 'array' THEN
    RETURN false;
  END IF;
  IF jsonb_array_length(definition -> 'license_allowlist') > 256 THEN
    RETURN false;
  END IF;
  IF definition -> 'deployment_purpose' <> 'null'::jsonb
     AND (
       definition ->> 'deployment_purpose' !~
         '^[a-z0-9][a-z0-9_-]{0,127}$'
       OR definition ->> 'deployment_purpose' IS DISTINCT FROM
         lower(btrim(definition ->> 'deployment_purpose'))
     ) THEN
    RETURN false;
  END IF;
  IF definition -> 'redistribution_mode' <> 'null'::jsonb
     AND (
       definition ->> 'redistribution_mode' !~
         '^[a-z0-9][a-z0-9_-]{0,127}$'
       OR definition ->> 'redistribution_mode' IS DISTINCT FROM
         lower(btrim(definition ->> 'redistribution_mode'))
     ) THEN
    RETURN false;
  END IF;
  IF definition -> 'license_allowlist' IS DISTINCT FROM (
    SELECT COALESCE(
      jsonb_agg(
        item.value ORDER BY (item.value ->> 'license') COLLATE "C"
      ),
      '[]'::jsonb
    )
    FROM jsonb_array_elements(definition -> 'license_allowlist') item(value)
  ) OR (
    SELECT count(*)
    FROM jsonb_array_elements(definition -> 'license_allowlist') item(value)
  ) IS DISTINCT FROM (
    SELECT count(DISTINCT (item.value ->> 'license') COLLATE "C")
    FROM jsonb_array_elements(definition -> 'license_allowlist') item(value)
  ) THEN
    RETURN false;
  END IF;

  FOR rule IN
    SELECT item.value
    FROM jsonb_array_elements(definition -> 'license_allowlist') item(value)
  LOOP
    IF jsonb_typeof(rule) IS DISTINCT FROM 'object' THEN
      RETURN false;
    END IF;
    IF ARRAY(
         SELECT key
         FROM jsonb_object_keys(rule) key
         ORDER BY key COLLATE "C"
       ) IS DISTINCT FROM ARRAY[
         'deployment_purposes',
         'license',
         'redistribution_modes',
         'unresolved_fields'
       ]::text[] THEN
      RETURN false;
    END IF;
    IF jsonb_typeof(rule -> 'license') IS DISTINCT FROM 'string'
       OR NULLIF(btrim(rule ->> 'license'), '') IS NULL
       OR rule ->> 'license' IS DISTINCT FROM btrim(rule ->> 'license')
       OR octet_length(rule ->> 'license') > 512 THEN
      RETURN false;
    END IF;
    FOREACH dimension IN ARRAY ARRAY[
      'deployment_purposes',
      'redistribution_modes',
      'unresolved_fields'
    ]::text[]
    LOOP
      values_json := rule -> dimension;
      IF jsonb_typeof(values_json) IS DISTINCT FROM 'array' THEN
        RETURN false;
      END IF;
      IF (dimension <> 'unresolved_fields' AND jsonb_array_length(values_json) < 1)
         OR jsonb_array_length(values_json) > 64
         OR values_json IS DISTINCT FROM (
           SELECT COALESCE(
             jsonb_agg(
               item.value ORDER BY (item.value #>> '{}') COLLATE "C"
             ),
             '[]'::jsonb
           )
           FROM jsonb_array_elements(values_json) item(value)
         )
         OR (
           SELECT count(*) FROM jsonb_array_elements(values_json)
         ) IS DISTINCT FROM (
           SELECT count(DISTINCT (item.value #>> '{}') COLLATE "C")
           FROM jsonb_array_elements(values_json) item(value)
         ) THEN
        RETURN false;
      END IF;
      FOR value_json IN SELECT item.value FROM jsonb_array_elements(values_json) item(value)
      LOOP
        value_text := value_json #>> '{}';
        IF jsonb_typeof(value_json) IS DISTINCT FROM 'string'
           OR value_text !~ '^[a-z0-9][a-z0-9_-]{0,127}$'
           OR value_text IS DISTINCT FROM lower(btrim(value_text))
           OR (
             dimension = 'unresolved_fields'
             AND value_text IN (
               'deployment_purpose',
               'policy',
               'redistribution_mode'
             )
           ) THEN
          RETURN false;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN true;
END;
$$;

CREATE TABLE otlet.model_license_use_policies (
  name text PRIMARY KEY DEFAULT 'default' CHECK (name = 'default'),
  policy_hash text NOT NULL CHECK (
    policy_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  definition jsonb NOT NULL CHECK (
    otlet.model_license_use_policy_valid(definition)
    AND policy_hash = otlet.identity_hash('model_license_use_policy', definition)
  )
);

CREATE FUNCTION otlet.guard_model_license_use_policy() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE')
     AND current_setting('otlet.model_license_use_policy_write', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet model license use policy changes require set_model_license_use_policy';
END;
$$;

CREATE TRIGGER model_license_use_policies_row_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.model_license_use_policies
FOR EACH ROW EXECUTE FUNCTION otlet.guard_model_license_use_policy();

CREATE TRIGGER model_license_use_policies_truncate_guard
BEFORE TRUNCATE ON otlet.model_license_use_policies
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_model_license_use_policy();

CREATE FUNCTION otlet.set_model_license_use_policy(
  definition jsonb,
  reason text DEFAULT NULL,
  ticket text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  old_policy_hash text;
  new_policy_hash text;
  operation text;
  previous_write text := current_setting(
    'otlet.model_license_use_policy_write',
    true
  );
BEGIN
  IF NOT otlet.model_license_use_policy_valid(
    set_model_license_use_policy.definition
  ) THEN
    RAISE EXCEPTION 'otlet model license use policy definition is invalid';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('otlet_model_license_use_policy:default', 0)
  );
  SELECT policy.policy_hash
  INTO old_policy_hash
  FROM otlet.model_license_use_policies policy
  WHERE policy.name = 'default';
  new_policy_hash := otlet.identity_hash(
    'model_license_use_policy',
    set_model_license_use_policy.definition
  );
  IF old_policy_hash IS NOT DISTINCT FROM new_policy_hash THEN
    RETURN new_policy_hash;
  END IF;
  PERFORM otlet.set_administrative_change_context(
    set_model_license_use_policy.reason,
    set_model_license_use_policy.ticket
  );
  operation := CASE WHEN old_policy_hash IS NULL THEN 'insert' ELSE 'update' END;
  PERFORM set_config('otlet.model_license_use_policy_write', 'on', true);
  INSERT INTO otlet.model_license_use_policies (
    name,
    policy_hash,
    definition
  ) VALUES (
    'default',
    new_policy_hash,
    set_model_license_use_policy.definition
  )
  ON CONFLICT (name) DO UPDATE
  SET policy_hash = EXCLUDED.policy_hash,
      definition = EXCLUDED.definition;
  PERFORM set_config(
    'otlet.model_license_use_policy_write',
    COALESCE(previous_write, ''),
    true
  );
  PERFORM otlet.append_administrative_change(
    'model',
    'license_use_policy:default',
    operation,
    old_policy_hash,
    new_policy_hash
  );
  RETURN new_policy_hash;
END;
$$;

CREATE VIEW otlet.model_license_use_policy_status AS
WITH registered AS (
  SELECT
    model.name AS model_name,
    model.artifact_hash,
    model.artifact_identity,
    model.artifact_identity ->> 'license' AS reported_license,
    otlet.identity_hash(
      'model_identity',
      jsonb_build_object(
        'name', model.name,
        'artifact_hash', model.artifact_hash,
        'artifact_identity', model.artifact_identity
      )
    ) AS model_identity_hash
  FROM otlet.models model
), policy AS (
  SELECT
    stored.policy_hash,
    stored.definition,
    event.actor_oid,
    event.actor_name,
    event.active_role_oid,
    event.active_role_name,
    event.reason,
    event.ticket,
    event.changed_at
  FROM otlet.model_license_use_policies stored
  LEFT JOIN LATERAL (
    SELECT
      change.actor_oid,
      change.actor_name,
      change.active_role_oid,
      change.active_role_name,
      change.reason,
      change.ticket,
      change.changed_at
    FROM otlet.administrative_change_events change
    WHERE change.object_type = 'model'
      AND change.object_name = 'license_use_policy:default'
      AND change.new_revision_hash = stored.policy_hash
    ORDER BY change.changed_at DESC, change.event_id DESC
    LIMIT 1
  ) event ON true
  WHERE stored.name = 'default'
), matched AS (
  SELECT
    registered.*,
    policy.*,
    policy.definition ->> 'deployment_purpose' AS deployment_purpose,
    policy.definition ->> 'redistribution_mode' AS redistribution_mode,
    rule.value AS matched_rule,
    CASE
      WHEN policy.policy_hash IS NULL THEN ARRAY['policy']::text[]
      ELSE ARRAY_REMOVE(ARRAY[
        CASE WHEN policy.definition -> 'deployment_purpose' = 'null'::jsonb
          THEN 'deployment_purpose' END,
        CASE WHEN policy.definition -> 'redistribution_mode' = 'null'::jsonb
          THEN 'redistribution_mode' END
      ]::text[], NULL) || COALESCE(ARRAY(
        SELECT field.value #>> '{}'
        FROM jsonb_array_elements(
          COALESCE(rule.value -> 'unresolved_fields', '[]'::jsonb)
        ) field(value)
      ), '{}'::text[])
    END AS unresolved_fields
  FROM registered
  LEFT JOIN policy ON true
  LEFT JOIN LATERAL (
    SELECT item.value
    FROM jsonb_array_elements(
      COALESCE(policy.definition -> 'license_allowlist', '[]'::jsonb)
    ) item(value)
    WHERE (item.value ->> 'license') COLLATE "C" =
      registered.reported_license COLLATE "C"
    LIMIT 1
  ) rule ON true
), component_states AS (
  SELECT
    matched.*,
    CASE
      WHEN matched.policy_hash IS NULL THEN 'unresolved'
      WHEN matched.matched_rule IS NULL THEN 'owner_not_allowlisted'
      ELSE 'owner_allowlisted'
    END AS license_match_state,
    CASE
      WHEN matched.policy_hash IS NULL
        OR 'deployment_purpose' = ANY(matched.unresolved_fields)
        THEN 'unresolved'
      WHEN matched.matched_rule IS NOT NULL
        AND matched.matched_rule -> 'deployment_purposes'
          ? matched.deployment_purpose
        THEN 'owner_allowlisted'
      ELSE 'owner_not_allowlisted'
    END AS deployment_purpose_match_state,
    CASE
      WHEN matched.policy_hash IS NULL
        OR 'redistribution_mode' = ANY(matched.unresolved_fields)
        THEN 'unresolved'
      WHEN matched.matched_rule IS NOT NULL
        AND matched.matched_rule -> 'redistribution_modes'
          ? matched.redistribution_mode
        THEN 'owner_allowlisted'
      ELSE 'owner_not_allowlisted'
    END AS redistribution_match_state
  FROM matched
)
SELECT
  component.model_name,
  component.artifact_hash,
  component.artifact_identity,
  component.model_identity_hash,
  component.reported_license,
  component.policy_hash,
  component.deployment_purpose,
  component.redistribution_mode,
  component.license_match_state,
  component.deployment_purpose_match_state,
  component.redistribution_match_state,
  CASE
    WHEN cardinality(component.unresolved_fields) > 0 THEN 'unresolved'
    WHEN component.license_match_state = 'owner_allowlisted'
      AND component.deployment_purpose_match_state = 'owner_allowlisted'
      AND component.redistribution_match_state = 'owner_allowlisted'
      THEN 'owner_allowlisted'
    ELSE 'owner_not_allowlisted'
  END AS policy_state,
  CASE
    WHEN component.policy_hash IS NULL THEN 'policy_missing'
    WHEN 'deployment_purpose' = ANY(component.unresolved_fields)
      THEN 'deployment_purpose_unresolved'
    WHEN 'redistribution_mode' = ANY(component.unresolved_fields)
      THEN 'redistribution_mode_unresolved'
    WHEN cardinality(component.unresolved_fields) > 0
      THEN 'owner_reported_unresolved_fields'
    WHEN component.license_match_state = 'owner_not_allowlisted'
      THEN 'license_not_allowlisted'
    WHEN component.deployment_purpose_match_state = 'owner_not_allowlisted'
      THEN 'deployment_purpose_not_allowlisted'
    WHEN component.redistribution_match_state = 'owner_not_allowlisted'
      THEN 'redistribution_mode_not_allowlisted'
    ELSE 'all_owner_rules_matched'
  END AS policy_reason,
  component.unresolved_fields,
  component.actor_oid AS policy_actor_oid,
  component.actor_name AS policy_actor_name,
  component.active_role_oid AS policy_active_role_oid,
  component.active_role_name AS policy_active_role_name,
  component.reason AS policy_change_reason,
  component.ticket AS policy_change_ticket,
  component.changed_at AS policy_changed_at
FROM component_states component;

REVOKE ALL ON TABLE otlet.model_license_use_policies FROM PUBLIC;
REVOKE ALL ON TABLE otlet.model_license_use_policy_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.model_license_use_policy_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_model_license_use_policy()
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_model_license_use_policy(jsonb, text, text)
FROM PUBLIC;
