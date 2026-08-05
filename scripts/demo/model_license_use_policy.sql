CREATE TEMP TABLE model_license_use_proof (
  partial_policy_hash text,
  policy_hash text,
  repeated_policy_hash text,
  definition jsonb,
  initial_unconfigured boolean NOT NULL DEFAULT false,
  partial_unresolved boolean NOT NULL DEFAULT false,
  truth_table boolean NOT NULL DEFAULT false,
  malformed_blocked boolean NOT NULL DEFAULT false,
  raw_write_blocked boolean NOT NULL DEFAULT false,
  identity_tamper_blocked boolean NOT NULL DEFAULT false,
  non_string_license_blocked boolean NOT NULL DEFAULT false,
  exact_retry boolean NOT NULL DEFAULT false
) ON COMMIT DROP;
INSERT INTO model_license_use_proof DEFAULT VALUES;

SELECT otlet.register_model(
  model_name,
  '/tmp/' || model_name || '.gguf',
  artifact_hash,
  jsonb_build_object(
    'sha256', artifact_hash,
    'bytes', 1,
    'source', 'model-license-use-proof',
    'revision', 'v1',
    'quantization', 'fixture',
    'license', license
  )
)
FROM (VALUES
  ('license_use_allowed', repeat('a', 64), 'apache-2.0'),
  ('license_use_absent', repeat('b', 64), 'absent-license'),
  ('license_use_purpose', repeat('c', 64), 'purpose-license'),
  ('license_use_redistribution', repeat('d', 64), 'redistribution-license'),
  ('license_use_unresolved', repeat('e', 64), 'unknown')
) model(model_name, artifact_hash, license) \g /dev/null

UPDATE model_license_use_proof
SET initial_unconfigured = (
  SELECT count(*) = 5
    AND bool_and(status.policy_state = 'unresolved')
    AND bool_and(status.policy_reason = 'policy_missing')
    AND bool_and(status.unresolved_fields = ARRAY['policy']::text[])
    AND bool_and(status.policy_hash IS NULL)
  FROM otlet.model_license_use_policy_status status
  WHERE status.model_name LIKE 'license_use_%'
);

UPDATE model_license_use_proof
SET definition = jsonb_build_object(
  'format', 'otlet.model_license_use_policy.v1',
  'deployment_purpose', 'customer_support',
  'redistribution_mode', 'none',
  'license_allowlist', jsonb_build_array(
    jsonb_build_object(
      'license', 'apache-2.0',
      'deployment_purposes', jsonb_build_array('customer_support'),
      'redistribution_modes', jsonb_build_array('external', 'none'),
      'unresolved_fields', jsonb_build_array()
    ),
    jsonb_build_object(
      'license', 'purpose-license',
      'deployment_purposes', jsonb_build_array('internal_evaluation'),
      'redistribution_modes', jsonb_build_array('none'),
      'unresolved_fields', jsonb_build_array()
    ),
    jsonb_build_object(
      'license', 'redistribution-license',
      'deployment_purposes', jsonb_build_array('customer_support'),
      'redistribution_modes', jsonb_build_array('external'),
      'unresolved_fields', jsonb_build_array()
    ),
    jsonb_build_object(
      'license', 'unknown',
      'deployment_purposes', jsonb_build_array('customer_support'),
      'redistribution_modes', jsonb_build_array('none'),
      'unresolved_fields', jsonb_build_array('license_id')
    )
  )
);

UPDATE model_license_use_proof proof
SET partial_policy_hash = otlet.set_model_license_use_policy(
  jsonb_set(proof.definition, '{deployment_purpose}', 'null'::jsonb),
  'Record unresolved deployment purpose',
  'OTLET-61-PARTIAL'
);

UPDATE model_license_use_proof proof
SET partial_unresolved = (
  SELECT status.policy_hash = proof.partial_policy_hash
    AND status.license_match_state = 'owner_allowlisted'
    AND status.deployment_purpose_match_state = 'unresolved'
    AND status.redistribution_match_state = 'owner_allowlisted'
    AND status.policy_state = 'unresolved'
    AND status.policy_reason = 'deployment_purpose_unresolved'
    AND status.unresolved_fields = ARRAY['deployment_purpose']::text[]
  FROM otlet.model_license_use_policy_status status
  WHERE status.model_name = 'license_use_allowed'
);

UPDATE model_license_use_proof proof
SET policy_hash = otlet.set_model_license_use_policy(
  proof.definition,
  'Declare exact model license use rules',
  'OTLET-61'
);

UPDATE model_license_use_proof proof
SET repeated_policy_hash = otlet.set_model_license_use_policy(proof.definition),
    exact_retry = proof.policy_hash = otlet.set_model_license_use_policy(
      proof.definition
    )
      AND (
        SELECT count(*) = 2
        FROM otlet.administrative_change_events event
        WHERE event.object_type = 'model'
          AND event.object_name = 'license_use_policy:default'
      );

UPDATE model_license_use_proof proof
SET truth_table = (
  SELECT count(*) = 5
    AND count(*) FILTER (
      WHERE status.model_name = 'license_use_allowed'
        AND status.license_match_state = 'owner_allowlisted'
        AND status.deployment_purpose_match_state = 'owner_allowlisted'
        AND status.redistribution_match_state = 'owner_allowlisted'
        AND status.policy_state = 'owner_allowlisted'
        AND status.policy_reason = 'all_owner_rules_matched'
    ) = 1
    AND count(*) FILTER (
      WHERE status.model_name = 'license_use_absent'
        AND status.license_match_state = 'owner_not_allowlisted'
        AND status.policy_state = 'owner_not_allowlisted'
        AND status.policy_reason = 'license_not_allowlisted'
    ) = 1
    AND count(*) FILTER (
      WHERE status.model_name = 'license_use_purpose'
        AND status.license_match_state = 'owner_allowlisted'
        AND status.deployment_purpose_match_state = 'owner_not_allowlisted'
        AND status.redistribution_match_state = 'owner_allowlisted'
        AND status.policy_state = 'owner_not_allowlisted'
        AND status.policy_reason = 'deployment_purpose_not_allowlisted'
    ) = 1
    AND count(*) FILTER (
      WHERE status.model_name = 'license_use_redistribution'
        AND status.license_match_state = 'owner_allowlisted'
        AND status.deployment_purpose_match_state = 'owner_allowlisted'
        AND status.redistribution_match_state = 'owner_not_allowlisted'
        AND status.policy_state = 'owner_not_allowlisted'
        AND status.policy_reason = 'redistribution_mode_not_allowlisted'
    ) = 1
    AND count(*) FILTER (
      WHERE status.model_name = 'license_use_unresolved'
        AND status.license_match_state = 'owner_allowlisted'
        AND status.deployment_purpose_match_state = 'owner_allowlisted'
        AND status.redistribution_match_state = 'owner_allowlisted'
        AND status.policy_state = 'unresolved'
        AND status.policy_reason = 'owner_reported_unresolved_fields'
        AND status.unresolved_fields = ARRAY['license_id']::text[]
    ) = 1
    AND bool_and(status.policy_hash = proof.policy_hash)
    AND bool_and(status.policy_actor_oid = session_user::regrole::oid)
    AND bool_and(status.policy_actor_name = session_user)
    AND bool_and(status.policy_active_role_oid = current_user::regrole::oid)
    AND bool_and(status.policy_active_role_name = current_user)
    AND bool_and(status.policy_change_reason =
      'Declare exact model license use rules')
    AND bool_and(status.policy_change_ticket = 'OTLET-61')
  FROM otlet.model_license_use_policy_status status
  WHERE status.model_name LIKE 'license_use_%'
);

DO $body$
DECLARE
  proof model_license_use_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM model_license_use_proof;
  BEGIN
    PERFORM otlet.register_model(
      'license_use_non_string',
      '/tmp/license_use_non_string.gguf',
      repeat('f', 64),
      jsonb_build_object(
        'sha256', repeat('f', 64),
        'bytes', 1,
        'source', 'model-license-use-proof',
        'revision', 'v1',
        'quantization', 'fixture',
        'license', 5
      )
    );
    RAISE EXCEPTION 'non-string model license unexpectedly succeeded';
  EXCEPTION WHEN check_violation THEN
    UPDATE model_license_use_proof SET non_string_license_blocked = true;
  END;

  BEGIN
    PERFORM otlet.set_model_license_use_policy(
      proof.definition || '{"unexpected":true}'::jsonb,
      'Reject malformed model license policy'
    );
    RAISE EXCEPTION 'malformed model license use policy unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'otlet model license use policy definition is invalid' THEN
      RAISE;
    END IF;
    UPDATE model_license_use_proof SET malformed_blocked = true;
  END;

  BEGIN
    UPDATE otlet.model_license_use_policies
    SET definition = definition
    WHERE name = 'default';
    RAISE EXCEPTION 'raw model license use policy update unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <>
      'otlet model license use policy changes require set_model_license_use_policy' THEN
      RAISE;
    END IF;
    UPDATE model_license_use_proof SET raw_write_blocked = true;
  END;

  BEGIN
    PERFORM set_config('otlet.model_license_use_policy_write', 'on', true);
    UPDATE otlet.model_license_use_policies
    SET policy_hash = 'otlet:v1:sha256:' || repeat('0', 64)
    WHERE name = 'default';
    RAISE EXCEPTION 'model license use policy identity tamper unexpectedly succeeded';
  EXCEPTION WHEN check_violation THEN
    UPDATE model_license_use_proof SET identity_tamper_blocked = true;
  END;
END;
$body$;

CREATE TEMP TABLE model_license_use_contract ON COMMIT DROP AS
SELECT concat_ws('|',
  proof.initial_unconfigured,
  proof.partial_unresolved,
  proof.truth_table,
  proof.malformed_blocked,
  proof.raw_write_blocked,
  proof.identity_tamper_blocked,
  proof.non_string_license_blocked,
  proof.exact_retry,
  proof.policy_hash = proof.repeated_policy_hash,
  (SELECT policy.policy_hash = proof.policy_hash
     AND policy.definition = proof.definition
   FROM otlet.model_license_use_policies policy
   WHERE policy.name = 'default'),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.model_license_use_policies',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  )
    AND NOT pg_catalog.has_table_privilege(
      'public', 'otlet.model_license_use_policy_status', 'SELECT'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc function
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = function.pronamespace
      WHERE namespace.nspname = 'otlet'
        AND function.proname IN (
          'model_license_use_policy_valid',
          'guard_model_license_use_policy',
          'set_model_license_use_policy'
        )
        AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
    ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) AS contract
FROM model_license_use_proof proof;

SELECT pg_temp.assert_true(
  contract = 't|t|t|t|t|t|t|t|t|t|t|t',
  'model license and use policy contract mismatch: ' || contract
)
FROM model_license_use_contract;

SELECT 'model_license_use_policy_contract=' || contract
FROM model_license_use_contract;
