log "Checking model and artifact-store lifecycle"
(
  set -euo pipefail

  lifecycle_store=/var/lib/postgresql/otlet-model-lifecycle-smoke
  lifecycle_old="$lifecycle_store/old.gguf"
  lifecycle_new="$lifecycle_store/new.gguf"
  resident_model=

  cleanup_model_lifecycle() {
    if [[ -n "$resident_model" ]]; then
      psql_exec -v model_name="$resident_model" >/dev/null <<'SQL' || true
SELECT otlet.set_model_lifecycle(
  :'model_name',
  'active',
  NULL,
  NULL,
  'restore model after lifecycle proof',
  NULL
);
SQL
    fi
    docker exec "$container" rm -rf "$lifecycle_store" >/dev/null 2>&1 || true
  }
  trap cleanup_model_lifecycle EXIT

  docker exec "$container" sh -c '
    set -eu
    rm -rf "$1"
    mkdir -p "$1"
    printf %s old > "$2"
    printf %s newer > "$3"
  ' sh "$lifecycle_store" "$lifecycle_old" "$lifecycle_new"
  lifecycle_old_hash="$(docker exec "$container" sha256sum "$lifecycle_old" | awk '{print $1}')"
  lifecycle_new_hash="$(docker exec "$container" sha256sum "$lifecycle_new" | awk '{print $1}')"
  lifecycle_old_bytes="$(docker exec "$container" stat -c %s "$lifecycle_old")"
  lifecycle_new_bytes="$(docker exec "$container" stat -c %s "$lifecycle_new")"
  read -r lifecycle_capacity lifecycle_available <<<"$(
    docker exec "$container" df -B1 --output=size,avail "$lifecycle_store" | tail -n 1
  )"
  lifecycle_projected_available=$((lifecycle_available + lifecycle_old_bytes))
  if (( lifecycle_projected_available > lifecycle_capacity )); then
    lifecycle_projected_available="$lifecycle_capacity"
  fi

  lifecycle_contract="$(
    psql_value \
      -v store_root="$lifecycle_store" \
      -v old_path="$lifecycle_old" \
      -v new_path="$lifecycle_new" \
      -v old_hash="$lifecycle_old_hash" \
      -v new_hash="$lifecycle_new_hash" \
      -v old_bytes="$lifecycle_old_bytes" \
      -v new_bytes="$lifecycle_new_bytes" \
      -v capacity_bytes="$lifecycle_capacity" \
      -v available_bytes="$lifecycle_available" \
      -v projected_available_bytes="$lifecycle_projected_available" <<'SQL'
BEGIN;
SELECT 1 FROM otlet.production_policy WHERE name = 'default' FOR UPDATE \g /dev/null
SELECT pg_advisory_xact_lock(hashtext('otlet_queue_admission')) \g /dev/null
SET LOCAL otlet.administrative_reason = 'model artifact lifecycle proof';
CREATE TEMP TABLE model_artifact_lifecycle_proof (
  identity_guarded boolean NOT NULL DEFAULT false,
  lifecycle_guarded boolean NOT NULL DEFAULT false,
  delete_guarded boolean NOT NULL DEFAULT false,
  truncate_guarded boolean NOT NULL DEFAULT false,
  observation_guarded boolean NOT NULL DEFAULT false,
  invalid_observation_guarded boolean NOT NULL DEFAULT false,
  invalid_space_guarded boolean NOT NULL DEFAULT false,
  restore_mismatch_seen boolean NOT NULL DEFAULT false,
  stale_observation_guarded boolean NOT NULL DEFAULT false,
  deprecated_admission_allowed boolean NOT NULL DEFAULT false,
  deprecated_retry_allowed boolean NOT NULL DEFAULT false,
  deprecated_revision_guarded boolean NOT NULL DEFAULT false,
  stale_lifecycle_guarded boolean NOT NULL DEFAULT false,
  draining_admission_guarded boolean NOT NULL DEFAULT false,
  draining_claim_allowed boolean NOT NULL DEFAULT false,
  disabled_claim_guarded boolean NOT NULL DEFAULT false,
  preload_insert_guarded boolean NOT NULL DEFAULT false,
  replacement_did_not_rebind boolean NOT NULL DEFAULT false,
  dependency_blocked boolean NOT NULL DEFAULT false,
  pruning_ready boolean NOT NULL DEFAULT false,
  free_space_reported boolean NOT NULL DEFAULT false,
  expected_absence_reported boolean NOT NULL DEFAULT false
);
INSERT INTO model_artifact_lifecycle_proof DEFAULT VALUES;

CREATE TEMP TABLE model_artifact_lifecycle_parameters (
  store_root text NOT NULL,
  new_path text NOT NULL,
  new_hash text NOT NULL,
  new_bytes bigint NOT NULL
);
INSERT INTO model_artifact_lifecycle_parameters
VALUES (:'store_root', :'new_path', :'new_hash', :'new_bytes'::bigint);

SELECT otlet.register_model(
  'model_artifact_lifecycle_old',
  :'old_path',
  :'old_hash',
  jsonb_build_object(
    'sha256', :'old_hash',
    'bytes', :'old_bytes'::bigint,
    'source', 'repository-demo',
    'revision', 'old-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  2
) \g /dev/null
SELECT otlet.register_model(
  'model_artifact_lifecycle_alias',
  :'old_path',
  :'old_hash',
  jsonb_build_object(
    'sha256', :'old_hash',
    'bytes', :'old_bytes'::bigint,
    'source', 'repository-demo',
    'revision', 'old-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  2
) \g /dev/null
SELECT otlet.register_model(
  'model_artifact_lifecycle_new',
  :'new_path',
  :'new_hash',
  jsonb_build_object(
    'sha256', :'new_hash',
    'bytes', :'new_bytes'::bigint,
    'source', 'repository-demo',
    'revision', 'new-v1',
    'quantization', 'test',
    'license', 'test'
  ),
  2
) \g /dev/null

CREATE TEMP TABLE model_artifact_lifecycle_observation (
  name text PRIMARY KEY,
  definition jsonb NOT NULL
);
INSERT INTO model_artifact_lifecycle_observation (name, definition)
VALUES
  ('exact', jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', :'store_root',
    'capacity_bytes', :'capacity_bytes'::bigint,
    'available_bytes', :'available_bytes'::bigint,
    'artifacts', jsonb_build_array(
      jsonb_build_object(
        'path', :'new_path',
        'sha256', :'new_hash',
        'bytes', :'new_bytes'::bigint
      ),
      jsonb_build_object(
        'path', :'old_path',
        'sha256', :'old_hash',
        'bytes', :'old_bytes'::bigint
      )
    )
  )),
  ('mismatch', jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', :'store_root',
    'capacity_bytes', :'capacity_bytes'::bigint,
    'available_bytes', :'available_bytes'::bigint,
    'artifacts', jsonb_build_array(
      jsonb_build_object(
        'path', :'new_path',
        'sha256', :'new_hash',
        'bytes', :'new_bytes'::bigint
      ),
      jsonb_build_object(
        'path', :'old_path',
        'sha256', repeat('9', 64),
        'bytes', :'old_bytes'::bigint
      )
    )
  )),
  ('pruned', jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', :'store_root',
    'capacity_bytes', :'capacity_bytes'::bigint,
    'available_bytes', :'projected_available_bytes'::bigint,
    'artifacts', jsonb_build_array(
      jsonb_build_object(
        'path', :'new_path',
        'sha256', :'new_hash',
        'bytes', :'new_bytes'::bigint
      )
    )
  ));

DO $proof$
DECLARE
  parameters model_artifact_lifecycle_parameters%ROWTYPE;
BEGIN
  SELECT * INTO STRICT parameters FROM model_artifact_lifecycle_parameters;
  BEGIN
    PERFORM otlet.register_model(
      'model_artifact_lifecycle_old',
      parameters.new_path,
      parameters.new_hash,
      jsonb_build_object(
        'sha256', parameters.new_hash,
        'bytes', parameters.new_bytes,
        'source', 'repository-demo',
        'revision', 'changed',
        'quantization', 'test',
        'license', 'test'
      )
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('artifact identity is immutable' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET identity_guarded = true;
  END;
  BEGIN
    UPDATE otlet.models
    SET lifecycle_state = 'disabled'
    WHERE name = 'model_artifact_lifecycle_old';
  EXCEPTION WHEN OTHERS THEN
    IF position('require set_model_lifecycle' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET lifecycle_guarded = true;
  END;
  BEGIN
    DELETE FROM otlet.models WHERE name = 'model_artifact_lifecycle_old';
  EXCEPTION WHEN OTHERS THEN
    IF position('model registrations are retained' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET delete_guarded = true;
  END;
  BEGIN
    TRUNCATE otlet.models CASCADE;
  EXCEPTION WHEN OTHERS THEN
    IF position('model registrations are retained' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET truncate_guarded = true;
  END;
  IF otlet.model_artifact_store_observation_valid(jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', parameters.store_root || '/../outside',
    'capacity_bytes', 10,
    'available_bytes', 9,
    'artifacts', '[]'::jsonb
  )) THEN
    RAISE EXCEPTION 'noncanonical artifact-store path was accepted';
  END IF;
  UPDATE model_artifact_lifecycle_proof SET invalid_observation_guarded = true;
  IF otlet.model_artifact_store_observation_valid(jsonb_build_object(
    'format', 'otlet.model_artifact_store.observation.v1',
    'evidence_source', 'deployment_reported',
    'store_root', parameters.store_root,
    'capacity_bytes', 100,
    'available_bytes', 90,
    'artifacts', jsonb_build_array(jsonb_build_object(
      'path', parameters.store_root || '/overcommitted.gguf',
      'sha256', repeat('0', 64),
      'bytes', 11
    ))
  )) THEN
    RAISE EXCEPTION 'inconsistent artifact-store free space was accepted';
  END IF;
  UPDATE model_artifact_lifecycle_proof SET invalid_space_guarded = true;
END
$proof$;

SELECT otlet.reconcile_model_artifact_store(
  1,
  (SELECT definition FROM model_artifact_lifecycle_observation
   WHERE name = 'exact'),
  'initial store observation',
  NULL
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.model_artifact_store_observations
    SET generation = generation + 1;
  EXCEPTION WHEN OTHERS THEN
    IF position('require reconcile_model_artifact_store' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET observation_guarded = true;
  END;
END
$proof$;
SELECT otlet.reconcile_model_artifact_store(
  2,
  (SELECT definition FROM model_artifact_lifecycle_observation
   WHERE name = 'mismatch'),
  'restore mismatch observation',
  NULL
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET restore_mismatch_seen = (
  SELECT artifact_reconciliation_state = 'hash_mismatch'
    AND NOT artifact_ready
  FROM otlet.model_lifecycle_status
  WHERE model_name = 'model_artifact_lifecycle_old'
);
SELECT otlet.reconcile_model_artifact_store(
  3,
  (SELECT definition FROM model_artifact_lifecycle_observation
   WHERE name = 'exact'),
  'restore corrected observation',
  NULL
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.reconcile_model_artifact_store(
      2,
      (SELECT definition FROM model_artifact_lifecycle_observation
       WHERE name = 'exact'),
      'stale observation',
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('generation is stale' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET stale_observation_guarded = true;
  END;
END
$proof$;

SELECT otlet.create_task(
  'model_artifact_lifecycle_task',
  NULL,
  'Return an empty object',
  '{"type":"object"}'::jsonb,
  'model_artifact_lifecycle_old'
) \g /dev/null
SELECT otlet.ensure_active_workload_revision(
  'model_artifact_lifecycle_task'
) \g /dev/null
SELECT otlet.set_model_lifecycle(
  'model_artifact_lifecycle_old',
  'deprecated',
  'model_artifact_lifecycle_new',
  NULL,
  'declare replacement',
  NULL
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET deprecated_retry_allowed = (
  SELECT otlet.promote_configured_workload_revision(
    'model_artifact_lifecycle_task'
  ) = active_workload_revision_hash
  FROM otlet.workload_revision_heads
  WHERE task_name = 'model_artifact_lifecycle_task'
);
DO $proof$
BEGIN
  BEGIN
    PERFORM otlet.set_model_lifecycle(
      'model_artifact_lifecycle_old',
      'draining',
      'model_artifact_lifecycle_new',
      repeat('0', 64),
      'stale lifecycle update',
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('lifecycle revision conflict' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof
    SET stale_lifecycle_guarded = (
      SELECT lifecycle_state = 'deprecated'
      FROM otlet.models
      WHERE name = 'model_artifact_lifecycle_old'
    );
  END;
END
$proof$;
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES
  ('model_artifact_lifecycle_task', 'existing-one', '{}'::jsonb),
  ('model_artifact_lifecycle_task', 'existing-two', '{}'::jsonb);
UPDATE model_artifact_lifecycle_proof
SET deprecated_admission_allowed = (
  SELECT count(*) = 2
  FROM otlet.jobs
  WHERE task_name = 'model_artifact_lifecycle_task'
);
DO $proof$
BEGIN
  BEGIN
    UPDATE otlet.tasks
    SET instruction = 'Changed while deprecated'
    WHERE name = 'model_artifact_lifecycle_task';
    PERFORM otlet.promote_configured_workload_revision(
      'model_artifact_lifecycle_task'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('route direct is deprecated' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof
    SET deprecated_revision_guarded = true;
  END;
END
$proof$;
UPDATE model_artifact_lifecycle_proof
SET replacement_did_not_rebind = (
  SELECT model_name = 'model_artifact_lifecycle_old'
  FROM otlet.tasks
  WHERE name = 'model_artifact_lifecycle_task'
);
SELECT otlet.set_model_lifecycle(
  'model_artifact_lifecycle_old',
  'draining',
  'model_artifact_lifecycle_new',
  NULL,
  'drain replaced model',
  NULL
) \g /dev/null
DO $proof$
BEGIN
  BEGIN
    INSERT INTO otlet.jobs (task_name, subject_id, input)
    VALUES ('model_artifact_lifecycle_task', 'new-work', '{}'::jsonb);
  EXCEPTION WHEN OTHERS THEN
    IF position('cannot accept new work' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof
    SET draining_admission_guarded = true;
  END;
END
$proof$;
UPDATE model_artifact_lifecycle_proof
SET draining_claim_allowed = (
  SELECT count(*) = 1
  FROM otlet.claim_jobs('model_artifact_lifecycle_old', 1)
);
SELECT otlet.set_model_lifecycle(
  'model_artifact_lifecycle_old',
  'disabled',
  'model_artifact_lifecycle_new',
  NULL,
  'disable replaced model',
  NULL
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET disabled_claim_guarded = (
  SELECT available_active_job_slots = 0
  FROM otlet.model_claim_capacity
  WHERE model_name = 'model_artifact_lifecycle_old'
) AND NOT EXISTS (
  SELECT 1 FROM otlet.claim_jobs('model_artifact_lifecycle_old', 1)
);
DO $proof$
BEGIN
  BEGIN
    INSERT INTO otlet.production_policy
    SELECT (jsonb_populate_record(
      policy,
      '{"preload_model_name":"model_artifact_lifecycle_old"}'::jsonb
    )).*
    FROM otlet.production_policy policy
    WHERE policy.name = 'default'
    ON CONFLICT (name) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    IF position('preload model must be an active ready registration' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
    UPDATE model_artifact_lifecycle_proof SET preload_insert_guarded = true;
  END;
END
$proof$;
DELETE FROM otlet.jobs
WHERE task_name = 'model_artifact_lifecycle_task';
SELECT otlet.set_model_lifecycle(
  'model_artifact_lifecycle_alias',
  'disabled',
  NULL,
  NULL,
  'disable shared artifact alias',
  NULL
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET dependency_blocked = (
  SELECT NOT prune_ready
    AND 'operational_dependencies' = ANY(blockers)
  FROM otlet.model_artifact_pruning_plan
  WHERE artifact_path = :'old_path'
);
UPDATE otlet.tasks
SET model_name = 'model_artifact_lifecycle_new'
WHERE name = 'model_artifact_lifecycle_task';
SELECT otlet.promote_configured_workload_revision(
  'model_artifact_lifecycle_task'
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET dependency_blocked = dependency_blocked AND (
  SELECT NOT prune_ready
    AND 'rollback_replay_dependencies' = ANY(blockers)
  FROM otlet.model_artifact_pruning_plan
  WHERE artifact_path = :'old_path'
);
UPDATE otlet.tasks
SET instruction = 'Second replacement revision'
WHERE name = 'model_artifact_lifecycle_task';
SELECT otlet.promote_configured_workload_revision(
  'model_artifact_lifecycle_task'
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET pruning_ready = (
  SELECT prune_ready
    AND action = 'delete_external_file'
    AND model_names = ARRAY[
      'model_artifact_lifecycle_alias',
      'model_artifact_lifecycle_old'
    ]::text[]
    AND matching_registrations = 2
    AND reclaimable_bytes = :'old_bytes'::bigint
    AND deletion_owner = 'deployment'
    AND dry_run
    AND plan_hash = (
      SELECT repeated.plan_hash
      FROM otlet.model_artifact_pruning_plan repeated
      WHERE repeated.artifact_path = :'old_path'
    )
  FROM otlet.model_artifact_pruning_plan
  WHERE artifact_path = :'old_path'
),
free_space_reported = (
  SELECT reconciliation_state = 'reconciled'
    AND capacity_bytes = :'capacity_bytes'::bigint
    AND available_bytes = :'available_bytes'::bigint
    AND reclaimable_bytes = :'old_bytes'::bigint
    AND projected_available_bytes = :'projected_available_bytes'::bigint
    AND deletion_owner = 'deployment'
  FROM otlet.model_artifact_store_status
);

SELECT otlet.reconcile_model_artifact_store(
  4,
  (SELECT definition FROM model_artifact_lifecycle_observation
   WHERE name = 'pruned'),
  'post-prune observation',
  NULL
) \g /dev/null
UPDATE model_artifact_lifecycle_proof
SET expected_absence_reported = (
  SELECT artifact_reconciliation_state = 'missing'
    AND artifact_availability_state = 'expected_absent'
  FROM otlet.model_lifecycle_status
  WHERE model_name = 'model_artifact_lifecycle_old'
) AND (
  SELECT expected_absent_models = 2
    AND unexpected_missing_models = 0
  FROM otlet.model_artifact_store_status
);

SELECT concat_ws('|',
  proof.identity_guarded,
  proof.lifecycle_guarded AND proof.delete_guarded AND proof.truncate_guarded,
  proof.observation_guarded AND proof.invalid_observation_guarded
    AND proof.invalid_space_guarded,
  proof.restore_mismatch_seen AND proof.stale_observation_guarded
    AND (SELECT bool_and(artifact_ready)
      FROM otlet.model_lifecycle_status
      WHERE model_name LIKE 'model_artifact_lifecycle_%'
        AND model_name <> 'model_artifact_lifecycle_old'
        AND model_name <> 'model_artifact_lifecycle_alias'),
  proof.deprecated_admission_allowed AND proof.deprecated_retry_allowed
    AND proof.deprecated_revision_guarded AND proof.stale_lifecycle_guarded,
  proof.draining_admission_guarded AND proof.draining_claim_allowed
    AND proof.disabled_claim_guarded AND proof.preload_insert_guarded,
  proof.replacement_did_not_rebind,
  proof.dependency_blocked,
  proof.pruning_ready,
  proof.free_space_reported AND proof.expected_absence_reported,
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.model_artifact_store_observations',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  ) AND NOT pg_catalog.has_table_privilege(
    'public', 'otlet.model_artifact_pruning_plan', 'SELECT'
  ) AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'set_model_lifecycle',
        'reconcile_model_artifact_store',
        'model_artifact_release_requested',
        'synchronize_portable_worker_model_release'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  ),
  NOT EXISTS (SELECT 1 FROM otlet.verify_invariants())
)
FROM model_artifact_lifecycle_proof proof;
ROLLBACK;
SQL
  )"

  lifecycle_files_untouched="$(
    docker exec "$container" sh -c '
      test "$(sha256sum "$1" | awk "{print \$1}")" = "$3"
      test "$(sha256sum "$2" | awk "{print \$1}")" = "$4"
      printf true
    ' sh "$lifecycle_old" "$lifecycle_new" "$lifecycle_old_hash" "$lifecycle_new_hash"
  )"
  lifecycle_contract="$lifecycle_contract|$lifecycle_files_untouched"
  echo "model_artifact_lifecycle_contract=$lifecycle_contract"
  [[ "$lifecycle_contract" = \
    "t|t|t|t|t|t|t|t|t|t|t|t|true" ]] || {
    echo "Model artifact lifecycle contract mismatch: $lifecycle_contract" >&2
    exit 1
  }

  psql_exec -v model_name="$cheap_model_name" >/dev/null <<'SQL'
SELECT count(*)
FROM otlet.ask(
  :'model_name',
  'Return exactly one JSON object with ready set to true. No markdown.',
  '{}'::jsonb,
  '{"type":"object","required":["ready"],"additionalProperties":false,"properties":{"ready":{"const":true}}}'::jsonb,
  '{"max_tokens":32,"reasoning":"off","inference_cache":false}'::jsonb
);
SQL
  resident_model="$(psql_value <<'SQL'
SELECT model.name
FROM otlet.models model
JOIN otlet.runtime_slots slot ON slot.model_name = model.name
WHERE model.lifecycle_state = 'active'
  AND slot.artifact_path = model.artifact_path
  AND NOT otlet.model_has_unfinished_work(model.name)
ORDER BY slot.last_used_at DESC NULLS LAST, model.name
LIMIT 1;
SQL
  )"
  [[ -n "$resident_model" ]] || {
    echo "Model lifecycle proof requires one idle resident native model" >&2
    exit 1
  }
  lifecycle_event_id="$(psql_value <<'SQL'
SELECT COALESCE(max(id), 0) FROM otlet.worker_events;
SQL
  )"
  psql_exec -v model_name="$resident_model" >/dev/null <<'SQL'
SELECT otlet.set_model_lifecycle(
  :'model_name',
  'draining',
  NULL,
  NULL,
  'native unload proof',
  NULL
);
SQL
  for _ in $(seq 1 100); do
    if [[ "$(psql_value -v model_name="$resident_model" -v event_id="$lifecycle_event_id" <<'SQL'
SELECT EXISTS (
  SELECT 1
  FROM otlet.worker_events event
  WHERE event.id > :'event_id'::bigint
    AND event.event_type = 'model_unloaded'
    AND event.detail ->> 'model_name' = :'model_name'
);
SQL
    )" = "t" ]]; then
      break
    fi
    sleep 0.1
  done
  native_unload_contract="$(
    psql_value -v model_name="$resident_model" -v event_id="$lifecycle_event_id" <<'SQL'
SELECT concat_ws('|',
  model.lifecycle_state = 'draining',
  slot.status = 'cold' AND slot.artifact_path IS NULL
    AND slot.resident_memory_tracked_bytes = 0,
  EXISTS (
    SELECT 1
    FROM otlet.worker_events event
    WHERE event.id > :'event_id'::bigint
      AND event.event_type = 'model_unloaded'
      AND event.detail ->> 'model_name' = model.name
  )
)
FROM otlet.models model
JOIN otlet.runtime_slots slot ON slot.model_name = model.name
WHERE model.name = :'model_name';
SQL
  )"
  echo "native_model_unload_contract=$native_unload_contract"
  [[ "$native_unload_contract" = "t|t|t" ]] || {
    echo "Native model unload contract mismatch: $native_unload_contract" >&2
    exit 1
  }
  psql_exec -v model_name="$resident_model" >/dev/null <<'SQL'
SELECT otlet.set_model_lifecycle(
  :'model_name',
  'active',
  NULL,
  NULL,
  'restore model after lifecycle proof',
  NULL
);
SQL
  resident_model=
)
