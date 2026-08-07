log "Checking workload pack promotion"

workload_pack_promotion_output="$(mktemp)"
if ! psql_exec -qAt -v workload_pack_proof=true \
  >"$workload_pack_promotion_output" <<'SQL'
BEGIN;

SELECT otlet.set_administrative_change_context(
  'Build the workload pack proof fixture',
  'PACK-PROOF'
) \g /dev/null

CREATE TEMP TABLE workload_pack_parameters AS
SELECT
  'workload_pack_proof_cheap_model'::text AS cheap_model_name,
  'workload_pack_proof_strong_model'::text AS strong_model_name;

SELECT otlet.register_model(
  parameters.cheap_model_name,
  '/tmp/otlet-workload-pack-proof/cheap.gguf',
  repeat('c', 64),
  jsonb_build_object(
    'sha256', repeat('c', 64),
    'bytes', 1,
    'source', 'workload-pack-proof',
    'revision', 'cheap-v1',
    'quantization', 'test',
    'license', 'test',
    'secret_token', 'must-not-export'
  ),
  1
)
FROM workload_pack_parameters parameters
\g /dev/null

SELECT otlet.register_model(
  parameters.strong_model_name,
  '/tmp/otlet-workload-pack-proof/strong.gguf',
  repeat('d', 64),
  jsonb_build_object(
    'sha256', repeat('d', 64),
    'bytes', 1,
    'source', 'workload-pack-proof',
    'revision', 'strong-v1',
    'quantization', 'test',
    'license', 'test',
    'secret_token', 'must-not-export'
  ),
  1
)
FROM workload_pack_parameters parameters
\g /dev/null

SELECT otlet.reconcile_model_artifact_store(
  COALESCE((
    SELECT generation + 1
    FROM otlet.model_artifact_store_observations
    WHERE name = 'default'
  ), 1),
  (
    SELECT jsonb_build_object(
      'format', 'otlet.model_artifact_store.observation.v1',
      'evidence_source', 'deployment_reported',
      'store_root', '/tmp/otlet-workload-pack-proof',
      'capacity_bytes', sum((model.artifact_identity ->> 'bytes')::bigint) + 1,
      'available_bytes', 1,
      'artifacts', jsonb_agg(jsonb_build_object(
        'path', model.artifact_path,
        'sha256', model.artifact_hash,
        'bytes', (model.artifact_identity ->> 'bytes')::bigint
      ) ORDER BY model.artifact_path COLLATE "C")
    )
    FROM workload_pack_parameters parameters
    JOIN otlet.models model ON model.name IN (
      parameters.cheap_model_name,
      parameters.strong_model_name
    )
  ),
  'Observe initial workload pack proof artifacts',
  'PACK-PROOF'
) \g /dev/null

CREATE TABLE public.otlet_demo_workload_pack (
  id text PRIMARY KEY,
  source_payload text NOT NULL,
  result_payload text NOT NULL,
  secret_payload text NOT NULL,
  review_state text NOT NULL,
  review_reason text
);

INSERT INTO public.otlet_demo_workload_pack VALUES (
  'pack-row',
  'PACK_SOURCE_ROW_CANARY',
  'PACK_RESULT_CANARY',
  'PACK_SECRET_CANARY',
  'pending',
  NULL
);

SELECT otlet.register_action_target(
  'workload_pack_proof_target',
  'public.otlet_demo_workload_pack'::regclass,
  'id',
  ARRAY['review_state', 'review_reason']::name[]
) \g /dev/null

SELECT otlet.create_watch(
  watch_name => 'workload_pack_proof',
  kind => 'row',
  instruction => 'Return the baseline workload pack decision',
  output_schema => '{
    "type":"object",
    "required":["decision"],
    "properties":{"decision":{"type":"string","enum":["review","ignore"]}},
    "additionalProperties":false
  }'::jsonb,
  model_name => (
    SELECT strong_model_name FROM workload_pack_parameters
  ),
  table_name => 'public.otlet_demo_workload_pack'::regclass,
  subject_column => 'id',
  record_type => 'workload_pack_fact',
  runtime_options => '{"max_tokens":64}'::jsonb,
  selection_policy => jsonb_build_object(
    'cheap_model_name', (
      SELECT cheap_model_name FROM workload_pack_parameters
    ),
    'strong_model_name', (
      SELECT strong_model_name FROM workload_pack_parameters
    ),
    'accept_field_checks', jsonb_build_object(
      'answer_field', 'decision',
      'abstain_values', jsonb_build_array('review'),
      'confidence_field', 'confidence',
      'accepted_confidence', jsonb_build_array('high')
    )
  ),
  trigger_policy => '{"on_change":"mark_stale_and_enqueue"}'::jsonb,
  action_types => ARRAY['update_row'],
  stale_policy => 'refresh_then_fail_closed'
) \g /dev/null

SELECT otlet.set_model_selection_policy(
  'workload_pack_proof_task',
  (SELECT cheap_model_name FROM workload_pack_parameters),
  (SELECT strong_model_name FROM workload_pack_parameters),
  '{
    "answer_field":"decision",
    "abstain_values":["review"],
    "confidence_field":"confidence",
    "accepted_confidence":["high","medium"]
  }'::jsonb
) \g /dev/null

SELECT otlet.promote_configured_workload_revision(
  'workload_pack_proof_task'
) \g /dev/null

SELECT otlet.register_action_workflow_policy(
  'workload_pack_proof_task',
  'update_row',
  'workload_pack_proof_target',
  'recommendation_only',
  'unevaluated'
) \g /dev/null

CREATE TEMP TABLE workload_pack_checks (
  name text PRIMARY KEY,
  passed boolean NOT NULL
);

CREATE FUNCTION pg_temp.prove(name text, passed boolean) RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT COALESCE(prove.passed, false) THEN
    RAISE EXCEPTION 'workload pack proof failed: %', prove.name;
  END IF;
  INSERT INTO workload_pack_checks VALUES (prove.name, prove.passed);
END
$function$;

CREATE FUNCTION pg_temp.expect_prepare_error(
  definition jsonb,
  expected_spec_hash text,
  expected_revision_hash text,
  reason text,
  ticket text,
  expected_message text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  actual_message text;
BEGIN
  BEGIN
    PERFORM otlet.prepare_workload_pack(
      definition,
      expected_spec_hash,
      expected_revision_hash,
      reason,
      ticket
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    IF position(expected_message IN actual_message) = 0 THEN
      RAISE EXCEPTION 'expected %, got %', expected_message, actual_message;
    END IF;
    RETURN true;
  END;
  RAISE EXCEPTION 'expected workload pack preparation error containing %',
    expected_message;
END
$function$;

CREATE FUNCTION pg_temp.expect_apply_error(
  pack_hash text,
  expected_spec_hash text,
  expected_revision_hash text,
  reason text,
  ticket text,
  expected_message text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  actual_message text;
BEGIN
  BEGIN
    PERFORM otlet.apply_workload_pack(
      pack_hash,
      expected_spec_hash,
      expected_revision_hash,
      reason,
      ticket
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    IF position(expected_message IN actual_message) = 0 THEN
      RAISE EXCEPTION 'expected %, got %', expected_message, actual_message;
    END IF;
    RETURN true;
  END;
  RAISE EXCEPTION 'expected workload pack apply error containing %',
    expected_message;
END
$function$;

CREATE FUNCTION pg_temp.expect_rollback_error(
  application_event_hash text,
  expected_spec_hash text,
  expected_revision_hash text,
  reason text,
  ticket text,
  expected_message text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  actual_message text;
BEGIN
  BEGIN
    PERFORM otlet.rollback_workload_pack(
      application_event_hash,
      expected_spec_hash,
      expected_revision_hash,
      reason,
      ticket
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    IF position(expected_message IN actual_message) = 0 THEN
      RAISE EXCEPTION 'expected %, got %', expected_message, actual_message;
    END IF;
    RETURN true;
  END;
  RAISE EXCEPTION 'expected workload pack rollback error containing %',
    expected_message;
END
$function$;

CREATE FUNCTION pg_temp.storage_is_immutable(
  selected_pack_hash text,
  selected_event_hash text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
  event_rejected boolean := false;
  definition_rejected boolean := false;
BEGIN
  BEGIN
    UPDATE otlet.workload_pack_events
    SET pack_name = pack_name
    WHERE event_hash = selected_event_hash;
  EXCEPTION WHEN OTHERS THEN
    event_rejected := SQLERRM = 'otlet workload pack history is append only';
  END;
  BEGIN
    DELETE FROM otlet.workload_pack_definitions
    WHERE pack_hash = selected_pack_hash;
  EXCEPTION WHEN OTHERS THEN
    definition_rejected := SQLERRM = 'otlet workload pack history is append only';
  END;
  RETURN event_rejected AND definition_rejected;
END
$function$;

CREATE TEMP TABLE workload_pack_documents (
  stage text PRIMARY KEY,
  definition jsonb NOT NULL,
  pack_hash text,
  spec_hash text NOT NULL,
  revision_hash text,
  event_hash text,
  rollback_event_hash text
);

WITH baseline AS (
  SELECT otlet.export_workload_pack('workload_pack_proof', 1) AS definition
)
INSERT INTO workload_pack_documents (
  stage,
  definition,
  pack_hash,
  spec_hash,
  revision_hash
)
SELECT
  'baseline',
  definition,
  otlet.workload_pack_hash(definition),
  otlet.workload_pack_spec_hash(definition),
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_pack_proof_task'
  )
FROM baseline;

INSERT INTO workload_pack_documents (stage, definition, spec_hash)
SELECT
  'v1',
  jsonb_set(
    definition,
    '{watch,instruction}',
    to_jsonb('Return the version one workload pack decision'::text)
  ),
  otlet.workload_pack_spec_hash(jsonb_set(
    definition,
    '{watch,instruction}',
    to_jsonb('Return the version one workload pack decision'::text)
  ))
FROM workload_pack_documents
WHERE stage = 'baseline';

WITH version_two AS (
  SELECT jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            definition,
            '{version}',
            '2'::jsonb
          ),
          '{watch,instruction}',
          to_jsonb('Return the version two workload pack decision'::text)
        ),
        '{watch,output_schema}',
        '{
          "type":"object",
          "required":["decision","reason"],
          "properties":{
            "decision":{"type":"string","enum":["review","ignore"]},
            "reason":{"type":"string","maxLength":128}
          },
          "additionalProperties":false
        }'::jsonb
      ),
      '{watch,selection_policy,accept_field_checks,accepted_confidence}',
      '["high"]'::jsonb
    ),
    '{action_policies,update_row,enabled}',
    'false'::jsonb
  ) AS definition
  FROM workload_pack_documents
  WHERE stage = 'v1'
)
INSERT INTO workload_pack_documents (stage, definition, spec_hash)
SELECT 'v2', definition, otlet.workload_pack_spec_hash(definition)
FROM version_two;

SELECT pg_temp.prove(
  'canonical configuration-only export',
  (
    SELECT
      definition ->> 'format' = 'otlet.workload_pack.v1'
      AND definition ->> 'name' = 'workload_pack_proof'
      AND definition ->> 'version' = '1'
      AND definition #>> '{watch,format}' = 'otlet.watch.v1'
      AND ARRAY(
        SELECT key FROM jsonb_object_keys(definition) key
        ORDER BY key COLLATE "C"
      ) = ARRAY['action_policies', 'format', 'models', 'name', 'version', 'watch']
      AND ARRAY(
        SELECT key FROM jsonb_object_keys(definition -> 'models') key
        ORDER BY key COLLATE "C"
      ) = ARRAY['cheap', 'direct', 'strong']
      AND definition #>> '{watch,model_name}' = (
        SELECT model_name FROM otlet.tasks
        WHERE name = 'workload_pack_proof_task'
      )
      AND definition #> '{watch,selection_policy}' = (
        SELECT jsonb_build_object(
          'cheap_model_name', cheap_model_name,
          'strong_model_name', strong_model_name,
          'accept_field_checks', accept_field_checks
        )
        FROM otlet.model_selection_policies
        WHERE task_name = 'workload_pack_proof_task'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_each(definition -> 'models') role
        LEFT JOIN otlet.models model ON model.name = role.value ->> 'name'
        WHERE model.name IS NULL
           OR otlet.workload_pack_artifact_identity(model.artifact_identity)
             IS DISTINCT FROM role.value -> 'artifact_identity'
      )
      AND definition #> '{action_policies,update_row,allowed_columns}' =
        '["review_reason","review_state"]'::jsonb
    FROM workload_pack_documents
    WHERE stage = 'baseline'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'model context budget export',
  (
    SELECT bool_and(
      ARRAY(
        SELECT key
        FROM jsonb_object_keys(role.value -> 'artifact_identity') key
        ORDER BY key COLLATE "C"
      ) = ARRAY[
        'bytes', 'context_window_tokens', 'license', 'quantization',
        'revision', 'sha256', 'source'
      ]
      AND role.value #>> '{artifact_identity,context_window_tokens}' = '4096'
    )
    FROM workload_pack_documents document
    CROSS JOIN LATERAL jsonb_each(document.definition -> 'models') role
    WHERE document.stage = 'baseline'
  )
  AND otlet.workload_pack_artifact_identity('{}'::jsonb) ->>
    'context_window_tokens' = '4096'
  AND (
    WITH legacy AS (
      SELECT jsonb_set(
        jsonb_set(
          document.definition,
          '{models}',
          (
            SELECT jsonb_object_agg(
              role.key,
              jsonb_set(
                role.value,
                '{artifact_identity}',
                (role.value -> 'artifact_identity') - 'context_window_tokens'
              )
              ORDER BY role.key COLLATE "C"
            )
            FROM jsonb_each(document.definition -> 'models') role
          )
        ),
        '{watch,model_artifact_identity}',
        (document.definition #> '{watch,model_artifact_identity}') -
          'context_window_tokens'
      ) AS definition
      FROM workload_pack_documents document
      WHERE document.stage = 'baseline'
    )
    SELECT otlet.workload_pack_shape_error(legacy.definition) IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.workload_pack_capability_report(legacy.definition) report
        WHERE report.component = 'model'
          AND NOT report.compatible
      )
    FROM legacy
  )
) \g /dev/null

SELECT pg_temp.prove(
  'export exclusions',
  (
    SELECT
      position('PACK_SOURCE_ROW_CANARY' IN definition::text) = 0
      AND position('PACK_RESULT_CANARY' IN definition::text) = 0
      AND position('PACK_SECRET_CANARY' IN definition::text) = 0
      AND position('must-not-export' IN definition::text) = 0
      AND definition::text !~ '"(artifact_path|jobs|outputs|receipts|results|secrets|model_files|source_data|materializations|traces|labels|target_table_oid|owner_oid|acl|contract_generation|created_at|updated_at)":'
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_each(definition -> 'models') role
        JOIN otlet.models model ON model.name = role.value ->> 'name'
        WHERE position(model.artifact_path IN definition::text) > 0
      )
    FROM workload_pack_documents
    WHERE stage = 'baseline'
  )
) \g /dev/null

SELECT otlet.reconcile_model_artifact_store(
  (
    SELECT generation + 1
    FROM otlet.model_artifact_store_observations
    WHERE name = 'default'
  ),
  jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', '/tmp/otlet-workload-pack-proof',
    'capacity_bytes', 1,
    'available_bytes', 1,
    'artifacts', '[]'::jsonb
  ),
  'Observe missing workload pack proof artifacts',
  'PACK-PROOF'
) \g /dev/null

SELECT pg_temp.prove(
  'missing artifact readiness',
  (
    SELECT count(*) = 6
      AND bool_and(compatible)
      AND bool_and(NOT ready)
    FROM otlet.workload_pack_capability_report(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1')
    )
    WHERE component IN ('model', 'runtime')
  )
) \g /dev/null

SELECT otlet.reconcile_model_artifact_store(
  (
    SELECT generation + 1
    FROM otlet.model_artifact_store_observations
    WHERE name = 'default'
  ),
  (
    SELECT jsonb_build_object(
      'format', 'otlet.model_artifact_store.observation.v1',
      'evidence_source', 'deployment_reported',
      'store_root', '/tmp/otlet-workload-pack-proof',
      'capacity_bytes', sum((model.artifact_identity ->> 'bytes')::bigint) + 1,
      'available_bytes', 1,
      'artifacts', jsonb_agg(jsonb_build_object(
        'path', model.artifact_path,
        'sha256', model.artifact_hash,
        'bytes', (model.artifact_identity ->> 'bytes')::bigint
      ) ORDER BY model.artifact_path COLLATE "C")
    )
    FROM workload_pack_parameters parameters
    JOIN otlet.models model ON model.name IN (
      parameters.cheap_model_name,
      parameters.strong_model_name
    )
  ),
  'Observe verified workload pack proof artifacts',
  'PACK-PROOF'
) \g /dev/null

CREATE ROLE workload_pack_proof_worker
NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

SELECT otlet.register_portable_worker(
  'workload-pack-proof-worker',
  'workload_pack_proof_worker'::regrole,
  1,
  (SELECT cheap_model_name FROM workload_pack_parameters),
  'otlet-portable-worker',
  '0.1.0',
  jsonb_build_object(
    'engine', 'llama.cpp',
    'runtime_contract', otlet.portable_reference_runtime_contract()
  )
) \g /dev/null

UPDATE otlet.portable_workers
SET reported_state = 'idle',
    model_status = 'ready',
    last_seen_at = now() - interval '3 minutes',
    last_heartbeat_at = now() - interval '3 minutes'
WHERE worker_id = 'workload-pack-proof-worker';

SELECT pg_temp.prove(
  'valid lint and capability report',
  NOT EXISTS (
    SELECT 1 FROM otlet.lint_workload_pack(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1')
    )
  ) AND (
    SELECT count(*) = 10
      AND bool_and(compatible)
      AND count(*) FILTER (WHERE component = 'source') = 1
      AND count(*) FILTER (WHERE component = 'model' AND ready) = 3
      AND count(*) FILTER (WHERE component = 'runtime') = 3
      AND bool_and(
        component <> 'runtime'
        OR ready = (otlet.linked_runtime_capabilities() IS NOT NULL)
      )
    FROM otlet.workload_pack_capability_report(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1')
    )
  )
) \g /dev/null

SELECT pg_temp.prove(
  'stale portable readiness',
  (
    SELECT worker_health = 'stale'
    FROM otlet.portable_worker_status
    WHERE worker_id = 'workload-pack-proof-worker'
  ) AND (
    SELECT bool_and(
      ready = (otlet.linked_runtime_capabilities() IS NOT NULL)
    )
    FROM otlet.workload_pack_capability_report(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1')
    )
    WHERE component = 'runtime'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'invalid shape lint',
  (
    SELECT count(*) = 1
      AND min(path) = '$'
      AND min(code) = 'invalid_definition'
    FROM otlet.lint_workload_pack(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1')
        || '{"unsupported":true}'::jsonb
    )
  )
) \g /dev/null

SELECT pg_temp.prove(
  'invalid nested watch shape lint',
  (
    SELECT count(*) = 1
      AND min(path) = '$'
      AND min(code) = 'invalid_definition'
    FROM otlet.lint_workload_pack(jsonb_set(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      '{watch,pair_sources}',
      '{}'::jsonb
    ))
  )
) \g /dev/null

SELECT pg_temp.prove(
  'malformed action target lint',
  (
    SELECT count(*) = 1
      AND min(path) = '/action_policies/update_row/target_name'
      AND min(code) = 'action_target_mismatch'
    FROM otlet.lint_workload_pack(jsonb_set(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      '{action_policies,update_row,target_table}',
      to_jsonb('a.b.c'::text)
    ))
  )
) \g /dev/null

SELECT pg_temp.prove(
  'incompatible capability lint',
  (
    SELECT count(*) = 3
      AND bool_and(code = 'unsupported_runtime_option')
      AND bool_and(path LIKE '/models/%/runtime')
    FROM otlet.lint_workload_pack(jsonb_set(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      '{watch,runtime_options,unsupported_option}',
      'true'::jsonb,
      true
    ))
  )
) \g /dev/null

SELECT pg_temp.prove(
  'semantic diff',
  NOT EXISTS (
    SELECT 1
    FROM otlet.diff_workload_packs(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      jsonb_set(
        (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
        '{version}',
        '99'::jsonb
      )
    )
  ) AND (
    SELECT array_agg(category || ':' || path ORDER BY category COLLATE "C") = ARRAY[
      'action_authority:/action_policies',
      'prompt_schema:/watch/prompt_schema',
      'selection:/watch/selection_policy'
    ]
    FROM otlet.diff_workload_packs(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v2')
    )
  )
) \g /dev/null

UPDATE workload_pack_documents document
SET pack_hash = otlet.prepare_workload_pack(
  document.definition,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
  'Prepare workload pack v1',
  'PACK-1'
)
WHERE document.stage = 'v1';

SELECT pg_temp.prove(
  'v1 prepare exact retry',
  (
    SELECT pack_hash = otlet.prepare_workload_pack(
      definition,
      (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      'Prepare workload pack v1',
      'PACK-1'
    )
    FROM workload_pack_documents
    WHERE stage = 'v1'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'version preparation conflict',
  pg_temp.expect_prepare_error(
    jsonb_set(
      (SELECT definition FROM workload_pack_documents WHERE stage = 'v1'),
      '{watch,instruction}',
      to_jsonb('Conflicting version one definition'::text)
    ),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
    'Prepare workload pack v1',
    'PACK-1',
    'name and version already identify another preparation'
  )
) \g /dev/null

UPDATE workload_pack_documents document
SET event_hash = otlet.apply_workload_pack(
  document.pack_hash,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
  'Apply workload pack v1',
  'PACK-1'
)
WHERE document.stage = 'v1';

UPDATE workload_pack_documents
SET definition = otlet.export_workload_pack('workload_pack_proof', 1),
    spec_hash = otlet.workload_pack_spec_hash(
      otlet.export_workload_pack('workload_pack_proof', 1)
    ),
    revision_hash = (
      SELECT active_workload_revision_hash
      FROM otlet.workload_revision_heads
      WHERE task_name = 'workload_pack_proof_task'
    )
WHERE stage = 'v1';

SELECT pg_temp.prove(
  'v1 apply',
  (
    SELECT
      document.definition = stored.definition
      AND document.pack_hash = stored.pack_hash
      AND document.revision_hash = stored.candidate_workload_revision_hash
      AND document.event_hash = event.event_hash
      AND event.prior_pack_hash = (
        SELECT pack_hash FROM workload_pack_documents WHERE stage = 'baseline'
      )
    FROM workload_pack_documents document
    JOIN otlet.workload_pack_definitions stored USING (pack_hash)
    JOIN otlet.workload_pack_events event
      ON event.application_pack_hash = document.pack_hash
    WHERE document.stage = 'v1'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'v1 apply exact retry',
  (
    SELECT event_hash = otlet.apply_workload_pack(
      pack_hash,
      (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      'Apply workload pack v1',
      'PACK-1'
    )
    FROM workload_pack_documents
    WHERE stage = 'v1'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'v1 prepare post-apply exact retry',
  (
    SELECT pack_hash = otlet.prepare_workload_pack(
      definition,
      (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
      'Prepare workload pack v1',
      'PACK-1'
    )
    FROM workload_pack_documents
    WHERE stage = 'v1'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'v1 apply retry conflict',
  pg_temp.expect_apply_error(
    (SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v1'),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'baseline'),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'baseline'),
    'Conflicting apply retry',
    'PACK-1',
    'apply retry conflicts'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'stale prepare CAS',
  pg_temp.expect_prepare_error(
    (SELECT definition FROM workload_pack_documents WHERE stage = 'v2'),
    'otlet:v1:sha256:' || repeat('0', 64),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
    'Prepare workload pack v2',
    'PACK-2',
    'preparation conflict'
  ) AND pg_temp.expect_prepare_error(
    (SELECT definition FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
    'otlet:v1:sha256:' || repeat('0', 64),
    'Prepare workload pack v2',
    'PACK-2',
    'preparation conflict'
  )
) \g /dev/null

UPDATE workload_pack_documents document
SET pack_hash = otlet.prepare_workload_pack(
  document.definition,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
  'Prepare workload pack v2',
  'PACK-2'
)
WHERE document.stage = 'v2';

SELECT pg_temp.prove(
  'v2 prepare exact retry',
  (
    SELECT pack_hash = otlet.prepare_workload_pack(
      definition,
      (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
      (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
      'Prepare workload pack v2',
      'PACK-2'
    )
    FROM workload_pack_documents
    WHERE stage = 'v2'
  )
) \g /dev/null

CREATE FUNCTION pg_temp.workload_pack_snapshot() RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    'definition', otlet.export_workload_pack('workload_pack_proof', 1),
    'task', (
      SELECT to_jsonb(task) FROM otlet.tasks task
      WHERE task.name = 'workload_pack_proof_task'
    ),
    'watch', (
      SELECT to_jsonb(watch) FROM otlet.watches watch
      WHERE watch.name = 'workload_pack_proof'
    ),
    'selection', (
      SELECT to_jsonb(policy) FROM otlet.model_selection_policies policy
      WHERE policy.task_name = 'workload_pack_proof_task'
    ),
    'action_policies', COALESCE((
      SELECT jsonb_agg(to_jsonb(policy) ORDER BY policy.action_type)
      FROM otlet.action_workflow_policies policy
      WHERE policy.task_name = 'workload_pack_proof_task'
    ), '[]'::jsonb),
    'target', (
      SELECT to_jsonb(target) FROM otlet.action_targets target
      WHERE target.name = 'workload_pack_proof_target'
    ),
    'head', (
      SELECT to_jsonb(head) FROM otlet.workload_revision_heads head
      WHERE head.task_name = 'workload_pack_proof_task'
    ),
    'revisions', COALESCE((
      SELECT jsonb_agg(revision.workload_revision_hash ORDER BY revision.workload_revision_hash)
      FROM otlet.workload_revisions revision
      WHERE revision.task_name = 'workload_pack_proof_task'
    ), '[]'::jsonb),
    'definitions', COALESCE((
      SELECT jsonb_agg(to_jsonb(definition) ORDER BY definition.pack_version)
      FROM otlet.workload_pack_definitions definition
      WHERE definition.pack_name = 'workload_pack_proof'
    ), '[]'::jsonb),
    'events', COALESCE((
      SELECT jsonb_agg(to_jsonb(event) ORDER BY event.event_id)
      FROM otlet.workload_pack_events event
      WHERE event.pack_name = 'workload_pack_proof'
    ), '[]'::jsonb),
    'administrative_count', (SELECT count(*) FROM otlet.administrative_change_events),
    'triggers', COALESCE((
      SELECT jsonb_agg(
        pg_get_triggerdef(trigger.oid) ORDER BY trigger.tgname
      )
      FROM pg_catalog.pg_trigger trigger
      WHERE trigger.tgrelid = 'public.otlet_demo_workload_pack'::regclass
        AND NOT trigger.tgisinternal
        AND trigger.tgname LIKE 'otlet_%'
    ), '[]'::jsonb),
    'reconciliation', COALESCE((
      SELECT jsonb_agg(to_jsonb(reconciliation) ORDER BY reconciliation.watch_name)
      FROM otlet.watch_reconciliation reconciliation
      WHERE reconciliation.watch_name = 'workload_pack_proof'
    ), '[]'::jsonb),
    'source_rows', (
      SELECT jsonb_agg(to_jsonb(source) ORDER BY source.id)
      FROM public.otlet_demo_workload_pack source
    ),
    'jobs', (SELECT count(*) FROM otlet.jobs WHERE task_name = 'workload_pack_proof_task'),
    'outputs', (
      SELECT count(*) FROM otlet.outputs output
      JOIN otlet.jobs job ON job.id = output.job_id
      WHERE job.task_name = 'workload_pack_proof_task'
    ),
    'receipts', (
      SELECT count(*) FROM otlet.inference_receipts receipt
      JOIN otlet.jobs job ON job.id = receipt.job_id
      WHERE job.task_name = 'workload_pack_proof_task'
    )
  );
$function$;

CREATE TEMP TABLE workload_pack_failure_snapshot AS
SELECT pg_temp.workload_pack_snapshot() AS state;

CREATE TEMP SEQUENCE workload_pack_late_failure_sequence;

CREATE FUNCTION pg_temp.reject_late_workload_pack_apply() RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF nextval('pg_temp.workload_pack_late_failure_sequence') = 2 THEN
    RAISE EXCEPTION 'workload pack late apply failure';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$function$;

CREATE TRIGGER workload_pack_proof_late_failure
BEFORE INSERT OR UPDATE OR DELETE ON otlet.action_workflow_policies
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_late_workload_pack_apply();

SELECT pg_temp.prove(
  'late apply failure',
  pg_temp.expect_apply_error(
    (SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
    'Apply workload pack v2',
    'PACK-2',
    'workload pack late apply failure'
  ) AND (
    SELECT last_value = 2 FROM pg_temp.workload_pack_late_failure_sequence
  )
) \g /dev/null

SELECT pg_temp.prove(
  'late apply snapshot rollback',
  (SELECT state FROM workload_pack_failure_snapshot)
    = pg_temp.workload_pack_snapshot()
) \g /dev/null

DROP TRIGGER workload_pack_proof_late_failure
ON otlet.action_workflow_policies;

SELECT pg_temp.prove(
  'stale apply CAS',
  pg_temp.expect_apply_error(
    (SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'),
    'otlet:v1:sha256:' || repeat('0', 64),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
    'Apply workload pack v2',
    'PACK-2',
    'apply conflict'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'stale apply snapshot rollback',
  (SELECT state FROM workload_pack_failure_snapshot)
    = pg_temp.workload_pack_snapshot()
) \g /dev/null

UPDATE workload_pack_documents document
SET event_hash = otlet.apply_workload_pack(
  document.pack_hash,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
  'Apply workload pack v2',
  'PACK-2'
)
WHERE document.stage = 'v2';

UPDATE workload_pack_documents
SET definition = otlet.export_workload_pack('workload_pack_proof', 2),
    spec_hash = otlet.workload_pack_spec_hash(
      otlet.export_workload_pack('workload_pack_proof', 2)
    ),
    revision_hash = (
      SELECT active_workload_revision_hash
      FROM otlet.workload_revision_heads
      WHERE task_name = 'workload_pack_proof_task'
    )
WHERE stage = 'v2';

SELECT pg_temp.prove(
  'v2 apply and policy reconciliation',
  (
    SELECT
      document.definition = stored.definition
      AND document.pack_hash = stored.pack_hash
      AND document.revision_hash = stored.candidate_workload_revision_hash
      AND document.event_hash = event.event_hash
      AND event.prior_definition = (
        SELECT definition FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND event.prior_pack_hash = (
        SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND EXISTS (
        SELECT 1 FROM otlet.action_workflow_policies policy
        WHERE policy.task_name = 'workload_pack_proof_task'
          AND policy.action_type = 'update_row'
          AND NOT policy.enabled
      )
    FROM workload_pack_documents document
    JOIN otlet.workload_pack_definitions stored USING (pack_hash)
    JOIN otlet.workload_pack_events event
      ON event.application_pack_hash = document.pack_hash
    WHERE document.stage = 'v2'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'v2 apply exact retry',
  (
    SELECT event_hash = otlet.apply_workload_pack(
      pack_hash,
      (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
      (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
      'Apply workload pack v2',
      'PACK-2'
    )
    FROM workload_pack_documents
    WHERE stage = 'v2'
  )
) \g /dev/null

CREATE TEMP TABLE workload_pack_policy_snapshot AS
SELECT default_runtime_options
FROM otlet.production_policy
WHERE name = 'default';

CREATE TEMP TABLE workload_pack_status_drift (
  configured_revision_detected boolean NOT NULL DEFAULT false,
  invalid_source_detected boolean NOT NULL DEFAULT false
);
INSERT INTO workload_pack_status_drift DEFAULT VALUES;

UPDATE otlet.production_policy
SET default_runtime_options = default_runtime_options ||
    '{"workload_pack_status_probe":true}'::jsonb
WHERE name = 'default';
UPDATE workload_pack_status_drift
SET configured_revision_detected = (
  SELECT status.configured_drift
    AND NOT status.rollback_ready
    AND status.rollback_blocker = 'configured_drift'
    AND status.current_active_workload_revision_hash =
        status.active_workload_revision_hash
    AND status.configured_workload_revision_hash IS DISTINCT FROM
        status.active_workload_revision_hash
    AND status.configured_workload_revision_error IS NULL
    AND status.source_dependency_status = 'ready'
  FROM otlet.workload_pack_status status
  WHERE status.pack_hash = (
    SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'
  )
);
UPDATE otlet.production_policy policy
SET default_runtime_options = snapshot.default_runtime_options
FROM workload_pack_policy_snapshot snapshot
WHERE policy.name = 'default';

ALTER TABLE public.otlet_demo_workload_pack RENAME COLUMN id TO drift_id;
UPDATE workload_pack_status_drift
SET invalid_source_detected = (
  SELECT status.configured_drift
    AND NOT status.rollback_ready
    AND status.rollback_blocker = 'configured_drift'
    AND (
      status.configured_workload_revision_error IS NOT NULL
      OR status.source_dependency_error IS NOT NULL
    )
  FROM otlet.workload_pack_status status
  WHERE status.pack_hash = (
    SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'
  )
);
ALTER TABLE public.otlet_demo_workload_pack RENAME COLUMN drift_id TO id;

SELECT pg_temp.prove(
  'configured drift status',
  (SELECT configured_revision_detected AND invalid_source_detected
   FROM workload_pack_status_drift)
  AND (
    SELECT NOT status.configured_drift
      AND status.rollback_ready
      AND status.rollback_blocker IS NULL
      AND status.configured_workload_revision_error IS NULL
      AND status.source_dependency_status = 'ready'
    FROM otlet.workload_pack_status status
    WHERE status.pack_hash = (
      SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'
    )
  )
) \g /dev/null

SELECT pg_temp.prove(
  'latest application rollback',
  pg_temp.expect_rollback_error(
    (SELECT event_hash FROM workload_pack_documents WHERE stage = 'v1'),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v2'),
    'Rollback superseded workload pack v1',
    'PACK-1-ROLLBACK',
    'rollback is not the latest application'
  )
) \g /dev/null

CREATE TEMP TABLE workload_pack_rollback_snapshot AS
SELECT
  otlet.export_workload_pack('workload_pack_proof', 2) AS definition,
  (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_pack_proof_task'
  ) AS revision_hash;

SELECT pg_temp.prove(
  'stale rollback CAS',
  pg_temp.expect_rollback_error(
    (SELECT event_hash FROM workload_pack_documents WHERE stage = 'v2'),
    'otlet:v1:sha256:' || repeat('0', 64),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v2'),
    'Rollback workload pack v2',
    'PACK-ROLLBACK',
    'rollback conflict'
  ) AND (
    SELECT definition = otlet.export_workload_pack('workload_pack_proof', 2)
      AND revision_hash = (
        SELECT active_workload_revision_hash
        FROM otlet.workload_revision_heads
        WHERE task_name = 'workload_pack_proof_task'
      )
    FROM workload_pack_rollback_snapshot
  )
) \g /dev/null

UPDATE workload_pack_documents document
SET rollback_event_hash = otlet.rollback_workload_pack(
  document.event_hash,
  document.spec_hash,
  document.revision_hash,
  'Rollback workload pack v2',
  'PACK-ROLLBACK'
)
WHERE document.stage = 'v2';

SELECT pg_temp.prove(
  'rollback exact retry',
  (
    SELECT rollback_event_hash = otlet.rollback_workload_pack(
      event_hash,
      spec_hash,
      revision_hash,
      'Rollback workload pack v2',
      'PACK-ROLLBACK'
    )
    FROM workload_pack_documents
    WHERE stage = 'v2'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'rollback retry conflict',
  pg_temp.expect_rollback_error(
    (SELECT event_hash FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v2'),
    'Conflicting rollback retry',
    'PACK-ROLLBACK',
    'rollback retry conflicts'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'exact v2 to v1 rollback',
  otlet.export_workload_pack('workload_pack_proof', 1) = (
    SELECT definition FROM workload_pack_documents WHERE stage = 'v1'
  ) AND (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_pack_proof_task'
  ) = (
    SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'
  ) AND EXISTS (
    SELECT 1 FROM otlet.action_workflow_policies policy
    WHERE policy.task_name = 'workload_pack_proof_task'
      AND policy.action_type = 'update_row'
      AND policy.target_name = 'workload_pack_proof_target'
      AND policy.authority_mode = 'recommendation_only'
      AND policy.evaluation_status = 'unevaluated'
      AND policy.enabled
  )
) \g /dev/null

SELECT pg_temp.prove(
  'rollback metadata',
  (
    SELECT
      rollback.event_kind = 'rollback'
      AND rollback.application_pack_hash = application.application_pack_hash
      AND rollback.predecessor_event_hash = application.event_hash
      AND rollback.rollback_of_event_hash = application.event_hash
      AND rollback.prior_pack_hash = application.result_pack_hash
      AND rollback.result_pack_hash = application.prior_pack_hash
      AND rollback.prior_spec_hash = application.result_spec_hash
      AND rollback.result_spec_hash = application.prior_spec_hash
      AND rollback.prior_definition = application.result_definition
      AND rollback.result_definition = application.prior_definition
      AND rollback.prior_workload_revision_hash =
        application.result_workload_revision_hash
      AND rollback.result_workload_revision_hash =
        application.prior_workload_revision_hash
      AND administrative.object_type = 'workload_pack'
      AND administrative.object_name = 'workload_pack_proof'
      AND administrative.operation = 'rollback'
      AND administrative.reason = 'Rollback workload pack v2'
      AND administrative.ticket = 'PACK-ROLLBACK'
    FROM workload_pack_documents document
    JOIN otlet.workload_pack_events application
      ON application.event_hash = document.event_hash
    JOIN otlet.workload_pack_events rollback
      ON rollback.event_hash = document.rollback_event_hash
    JOIN otlet.administrative_change_events administrative
      ON administrative.event_id = rollback.administrative_event_id
    WHERE document.stage = 'v2'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'rollback status',
  (
    SELECT
      status.state = 'rolled_back'
      AND status.latest_event_kind = 'rollback'
      AND status.active_pack_hash = (
        SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND status.active_spec_hash = (
        SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND status.active_workload_revision_hash = (
        SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND NOT status.configured_drift
      AND NOT status.rollback_ready
      AND status.rollback_blocker = 'already_rolled_back'
    FROM otlet.workload_pack_status status
    WHERE status.pack_hash = (
      SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'
    )
  )
) \g /dev/null

INSERT INTO workload_pack_documents (stage, definition, spec_hash)
SELECT
  'v3',
  jsonb_set(
    jsonb_set(definition, '{version}', '3'::jsonb),
    '{watch,trigger_policy}',
    '{"on_change":"mark_stale"}'::jsonb
  ),
  otlet.workload_pack_spec_hash(jsonb_set(
    jsonb_set(definition, '{version}', '3'::jsonb),
    '{watch,trigger_policy}',
    '{"on_change":"mark_stale"}'::jsonb
  ))
FROM workload_pack_documents
WHERE stage = 'v1';

UPDATE workload_pack_documents document
SET pack_hash = otlet.prepare_workload_pack(
  document.definition,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
  'Prepare metadata-only workload pack v3',
  'PACK-3'
)
WHERE document.stage = 'v3';

UPDATE workload_pack_documents document
SET event_hash = otlet.apply_workload_pack(
  document.pack_hash,
  (SELECT spec_hash FROM workload_pack_documents WHERE stage = 'v1'),
  (SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'),
  'Apply metadata-only workload pack v3',
  'PACK-3'
)
WHERE document.stage = 'v3';

UPDATE workload_pack_documents
SET definition = otlet.export_workload_pack('workload_pack_proof', 3),
    spec_hash = otlet.workload_pack_spec_hash(
      otlet.export_workload_pack('workload_pack_proof', 3)
    ),
    revision_hash = (
      SELECT active_workload_revision_hash
      FROM otlet.workload_revision_heads
      WHERE task_name = 'workload_pack_proof_task'
    )
WHERE stage = 'v3';

SELECT pg_temp.prove(
  'metadata-only apply',
  (
    SELECT
      document.definition = stored.definition
      AND document.revision_hash = (
        SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'
      )
      AND event.prior_spec_hash IS DISTINCT FROM event.result_spec_hash
      AND event.prior_workload_revision_hash =
        event.result_workload_revision_hash
      AND status.state = 'applied'
      AND status.rollback_ready
      AND status.rollback_blocker IS NULL
      AND NOT status.configured_drift
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_trigger trigger
        WHERE trigger.tgrelid = 'public.otlet_demo_workload_pack'::regclass
          AND NOT trigger.tgisinternal
          AND trigger.tgname LIKE 'otlet_watch_v1_%'
      )
    FROM workload_pack_documents document
    JOIN otlet.workload_pack_definitions stored USING (pack_hash)
    JOIN otlet.workload_pack_events event
      ON event.event_hash = document.event_hash
    JOIN otlet.workload_pack_status status
      ON status.pack_hash = document.pack_hash
    WHERE document.stage = 'v3'
  )
) \g /dev/null

UPDATE workload_pack_documents document
SET rollback_event_hash = otlet.rollback_workload_pack(
  document.event_hash,
  document.spec_hash,
  document.revision_hash,
  'Rollback metadata-only workload pack v3',
  'PACK-3-ROLLBACK'
)
WHERE document.stage = 'v3';

SELECT pg_temp.prove(
  'metadata-only rollback',
  otlet.export_workload_pack('workload_pack_proof', 1) = (
    SELECT definition FROM workload_pack_documents WHERE stage = 'v1'
  ) AND (
    SELECT active_workload_revision_hash
    FROM otlet.workload_revision_heads
    WHERE task_name = 'workload_pack_proof_task'
  ) = (
    SELECT revision_hash FROM workload_pack_documents WHERE stage = 'v1'
  ) AND (
    SELECT
      rollback.application_pack_hash = application.application_pack_hash
      AND rollback.predecessor_event_hash = application.event_hash
      AND rollback.rollback_of_event_hash = application.event_hash
      AND rollback.prior_workload_revision_hash =
        rollback.result_workload_revision_hash
      AND rollback.result_definition = application.prior_definition
      AND administrative.reason = 'Rollback metadata-only workload pack v3'
      AND administrative.ticket = 'PACK-3-ROLLBACK'
      AND status.state = 'rolled_back'
      AND NOT status.configured_drift
      AND status.rollback_blocker = 'already_rolled_back'
    FROM workload_pack_documents document
    JOIN otlet.workload_pack_events application
      ON application.event_hash = document.event_hash
    JOIN otlet.workload_pack_events rollback
      ON rollback.event_hash = document.rollback_event_hash
    JOIN otlet.administrative_change_events administrative
      ON administrative.event_id = rollback.administrative_event_id
    JOIN otlet.workload_pack_status status
      ON status.pack_hash = document.pack_hash
    WHERE document.stage = 'v3'
  ) AND EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger trigger
    WHERE trigger.tgrelid = 'public.otlet_demo_workload_pack'::regclass
      AND NOT trigger.tgisinternal
      AND trigger.tgname LIKE 'otlet_watch_v1_%'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'append only storage',
  pg_temp.storage_is_immutable(
    (SELECT pack_hash FROM workload_pack_documents WHERE stage = 'v2'),
    (SELECT event_hash FROM workload_pack_documents WHERE stage = 'v2')
  )
) \g /dev/null

SELECT pg_temp.prove(
  'PUBLIC closure',
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_pack_definitions', 'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_pack_events', 'SELECT'
  )
  AND NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_pack_status', 'SELECT'
  )
  AND NOT pg_catalog.has_sequence_privilege(
    'public', 'otlet.workload_pack_events_event_id_seq', 'USAGE'
  )
  AND (
    SELECT bool_and(NOT pg_catalog.has_function_privilege(
      'public', signature, 'EXECUTE'
    ))
    FROM unnest(ARRAY[
      'otlet.guard_workload_pack_storage()'::regprocedure,
      'otlet.workload_pack_hash(jsonb)'::regprocedure,
      'otlet.workload_pack_spec_hash(jsonb)'::regprocedure,
      'otlet.workload_pack_artifact_identity(jsonb)'::regprocedure,
      'otlet.export_workload_pack(text,integer)'::regprocedure,
      'otlet.workload_pack_shape_error(jsonb)'::regprocedure,
      'otlet.workload_pack_capability_report(jsonb)'::regprocedure,
      'otlet.stage_workload_pack_configuration(jsonb)'::regprocedure,
      'otlet.preview_workload_pack(jsonb)'::regprocedure,
      'otlet.lint_workload_pack(jsonb)'::regprocedure,
      'otlet.diff_workload_packs(jsonb,jsonb)'::regprocedure,
      'otlet.prepare_workload_pack(jsonb,text,text,text,text)'::regprocedure,
      'otlet.apply_workload_pack(text,text,text,text,text,text)'::regprocedure,
      'otlet.rollback_workload_pack(text,text,text,text,text)'::regprocedure,
      'otlet.verify_workload_pack_invariants()'::regprocedure
    ]) signature
  )
) \g /dev/null

SELECT pg_temp.prove(
  'source row untouched and no generated work',
  EXISTS (
    SELECT 1
    FROM public.otlet_demo_workload_pack
    WHERE id = 'pack-row'
      AND source_payload = 'PACK_SOURCE_ROW_CANARY'
      AND result_payload = 'PACK_RESULT_CANARY'
      AND secret_payload = 'PACK_SECRET_CANARY'
      AND review_state = 'pending'
      AND review_reason IS NULL
  )
  AND NOT EXISTS (
    SELECT 1 FROM otlet.jobs WHERE task_name = 'workload_pack_proof_task'
  )
) \g /dev/null

SELECT pg_temp.prove(
  'zero invariants',
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
) \g /dev/null

SELECT count(*)::text || '|' || bool_and(passed)::text
FROM workload_pack_checks;

ROLLBACK;
SQL
then
  rm -f "$workload_pack_promotion_output"
  exit 1
fi

workload_pack_promotion_contract="$(tail -n 1 "$workload_pack_promotion_output")"
rm -f "$workload_pack_promotion_output"

echo "workload_pack_promotion_contract=$workload_pack_promotion_contract"
[ "$workload_pack_promotion_contract" = "39|true" ] || {
  echo "Expected complete workload-pack promotion proof, got $workload_pack_promotion_contract" >&2
  exit 1
}
