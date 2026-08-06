log "Proving workload acceptance contracts"

workload_acceptance_delegate="otlet_acceptance_delegate_$$"
workload_acceptance_contract="$({
  psql_exec -qAt \
    -v model_name="$strong_model_name" \
    -v delegate_role="$workload_acceptance_delegate" <<'SQL'
BEGIN;

CREATE TEMP TABLE workload_acceptance_proof (
  baseline_revision_hash text,
  candidate_revision_hash text,
  thresholds jsonb,
  first_contract_hash text,
  current_contract_hash text,
  exception_hash text,
  decision_hash text,
  first_observation_starts_at timestamptz,
  observation_starts_at timestamptz,
  observation_ends_at timestamptz,
  job_count bigint,
  receipt_count bigint,
  output_count bigint,
  action_count bigint,
  materialization_count bigint
) ON COMMIT DROP;

INSERT INTO workload_acceptance_proof (
  thresholds,
  observation_starts_at,
  observation_ends_at,
  job_count,
  receipt_count,
  output_count,
  action_count,
  materialization_count
)
SELECT
  jsonb_object_agg(
    category,
    jsonb_build_object(
      'metric', category,
      'statistic', CASE
        WHEN category IN ('review_age', 'review_minutes', 'freshness', 'latency', 'recovery')
          THEN 'p95'
        ELSE 'rate'
      END,
      'operator', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 'gte'
        ELSE 'lte'
      END,
      'value', CASE
        WHEN category IN ('candidate_recall', 'downstream_outcome') THEN 0.90
        ELSE 0.10
      END,
      'unit', 'ratio',
      'minimum_support', 10,
      'required', true
    )
  ),
  date_trunc('day', statement_timestamp()) + interval '1 day',
  date_trunc('day', statement_timestamp()) + interval '32 days',
  (SELECT count(*) FROM otlet.jobs),
  (SELECT count(*) FROM otlet.inference_receipts),
  (SELECT count(*) FROM otlet.outputs),
  (SELECT count(*) FROM otlet.actions),
  (SELECT count(*) FROM otlet.semantic_materializations)
FROM unnest(ARRAY[
  'candidate_recall',
  'false_trust',
  'abstention',
  'review_age',
  'review_minutes',
  'freshness',
  'latency',
  'database_impact',
  'unit_cost',
  'recovery',
  'downstream_outcome'
]) category;

SELECT otlet.create_task(
  'workload_acceptance_contract_probe',
  NULL,
  'Return a declared evaluation fixture',
  '{"type":"object"}'::jsonb,
  :'model_name'
) \g /dev/null

UPDATE workload_acceptance_proof
SET baseline_revision_hash = otlet.ensure_active_workload_revision(
  'workload_acceptance_contract_probe'
);

UPDATE otlet.tasks
SET instruction = 'Return a candidate evaluation fixture'
WHERE name = 'workload_acceptance_contract_probe';

UPDATE workload_acceptance_proof
SET candidate_revision_hash = otlet.capture_workload_revision(
  'workload_acceptance_contract_probe'
);

UPDATE workload_acceptance_proof
SET
  first_observation_starts_at = statement_timestamp() + interval '2 seconds',
  first_contract_hash = otlet.register_workload_acceptance_contract(
    'workload_acceptance_contract_probe',
    candidate_revision_hash,
    baseline_revision_hash,
    '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
    statement_timestamp() + interval '2 seconds',
    observation_ends_at,
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    thresholds
  );

SELECT pg_sleep(2.1) \g /dev/null

DO $$
DECLARE
  proof workload_acceptance_proof%ROWTYPE;
  repeated_hash text;
BEGIN
  SELECT * INTO proof FROM workload_acceptance_proof;
  repeated_hash := otlet.register_workload_acceptance_contract(
    'workload_acceptance_contract_probe',
    proof.candidate_revision_hash,
    proof.baseline_revision_hash,
    '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
    proof.first_observation_starts_at,
    proof.observation_ends_at,
    '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
    proof.thresholds
  );
  IF repeated_hash IS DISTINCT FROM proof.first_contract_hash
     OR (SELECT count(*) FROM otlet.workload_acceptance_contracts) <> 1 THEN
    RAISE EXCEPTION 'workload acceptance registration is not idempotent';
  END IF;
END;
$$;

UPDATE workload_acceptance_proof
SET current_contract_hash = otlet.register_workload_acceptance_contract(
  'workload_acceptance_contract_probe',
  candidate_revision_hash,
  baseline_revision_hash,
  '{"mode":"sample","rule":{"kind":"stable_hash","basis":"subject_id","rate":0.25}}'::jsonb,
  observation_starts_at,
  observation_ends_at,
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
  jsonb_set(thresholds, '{false_trust,value}', '0.05'::jsonb),
  first_contract_hash
);

DO $$
DECLARE
  proof workload_acceptance_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM workload_acceptance_proof;
  IF proof.first_contract_hash = proof.current_contract_hash
     OR (SELECT count(*) FROM otlet.workload_acceptance_contracts) <> 2
     OR (SELECT contract_hash FROM otlet.current_workload_acceptance_contract(
       'workload_acceptance_contract_probe'
     )) IS DISTINCT FROM proof.current_contract_hash THEN
    RAISE EXCEPTION 'workload acceptance version chain is invalid';
  END IF;

  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'workload_acceptance_contract_probe',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash,
      '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
      proof.first_observation_starts_at,
      proof.observation_ends_at,
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds
    );
    RAISE EXCEPTION 'superseded exact contract unexpectedly returned';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'otlet workload acceptance contract version conflict%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'workload_acceptance_contract_probe',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash,
      '{"mode":"sample","rule":{"kind":"stable_hash","basis":"subject_id","rate":0.5}}'::jsonb,
      proof.observation_starts_at,
      proof.observation_ends_at,
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds,
      proof.first_contract_hash
    );
    RAISE EXCEPTION 'stale contract version unexpectedly registered';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'otlet workload acceptance contract version conflict%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'workload_acceptance_contract_probe',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash,
      '{"mode":"sample","rule":{"kind":"stable_hash","basis":"subject_id","rate":0.5}}'::jsonb,
      proof.observation_starts_at,
      proof.observation_ends_at,
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds - 'candidate_recall',
      proof.current_contract_hash
    );
    RAISE EXCEPTION 'contract with a missing threshold unexpectedly registered';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%exactly the 11 required acceptance categories%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'workload_acceptance_contract_probe',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash,
      '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
      proof.observation_ends_at,
      proof.observation_starts_at,
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds,
      proof.current_contract_hash
    );
    RAISE EXCEPTION 'contract with an invalid observation window unexpectedly registered';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%observation window end must be after start%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.register_workload_acceptance_contract(
      'workload_acceptance_contract_probe',
      proof.candidate_revision_hash,
      proof.baseline_revision_hash,
      '{"mode":"full","rule":{"kind":"all_declared_subjects"}}'::jsonb,
      statement_timestamp() - interval '2 days',
      statement_timestamp() - interval '1 day',
      '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
      proof.thresholds,
      proof.current_contract_hash
    );
    RAISE EXCEPTION 'post-hoc acceptance contract unexpectedly registered';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%must be registered before its observation window%' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SAVEPOINT workload_acceptance_rollback;
SELECT otlet.register_workload_acceptance_contract(
  'workload_acceptance_contract_probe',
  candidate_revision_hash,
  baseline_revision_hash,
  '{"mode":"sample","rule":{"kind":"stable_hash","basis":"subject_id","rate":0.5}}'::jsonb,
  observation_starts_at,
  observation_ends_at,
  '{"name":"active_revision","definition":{"kind":"workload_revision"}}'::jsonb,
  thresholds,
  current_contract_hash
) FROM workload_acceptance_proof \g /dev/null
ROLLBACK TO SAVEPOINT workload_acceptance_rollback;

UPDATE workload_acceptance_proof
SET exception_hash = otlet.record_workload_acceptance_exception(
  current_contract_hash,
  'unit_cost',
  '{"required":false,"status":"declared_unavailable"}'::jsonb,
  '{"deployment":"local"}'::jsonb,
  'Unit cost evidence is not available before resource attribution',
  'OTLET-52'
);

UPDATE workload_acceptance_proof
SET decision_hash = otlet.record_workload_promotion_decision(
  contract_hash => current_contract_hash,
  outcome => 'defer',
  evidence_hash => otlet.identity_hash(
    'workload_acceptance_evidence',
    jsonb_build_object('candidate_workload_revision_hash', candidate_revision_hash)
  ),
  evidence_summary => '{"status":"declared_not_evaluated","authoritative":false}'::jsonb,
  reason => 'Replayable evaluation has not run',
  exception_hashes => ARRAY[exception_hash],
  ticket => 'OTLET-52'
);

SELECT format('CREATE ROLE %I NOLOGIN', :'delegate_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA otlet TO %I', :'delegate_role') \gexec
SELECT format(
  'GRANT SELECT ON otlet.workload_acceptance_contracts, '
  'otlet.workload_acceptance_events, workload_acceptance_proof TO %I',
  :'delegate_role'
) \gexec
SELECT format(
  'GRANT INSERT ON otlet.workload_acceptance_events TO %I',
  :'delegate_role'
) \gexec
SELECT format(
  'GRANT EXECUTE ON FUNCTION '
  'otlet.record_workload_acceptance_exception(text,text,jsonb,jsonb,text,text,timestamptz), '
  'otlet.append_workload_acceptance_event(text,text,jsonb), '
  'otlet.identity_hash(text,jsonb), '
  'otlet.semantic_canonical_jsonb(jsonb), '
  'otlet.portable_json_hash(jsonb), '
  'otlet.portable_text_hash(text), '
  'otlet.portable_canonical_json_text(jsonb) TO %I',
  :'delegate_role'
) \gexec
SELECT format('SET LOCAL ROLE %I', :'delegate_role') \gexec
SELECT otlet.record_workload_acceptance_exception(
  current_contract_hash,
  'review_age',
  '{"required":false,"status":"temporarily_waived"}'::jsonb,
  '{"deployment":"local"}'::jsonb,
  'Delegated reviewer attribution proof',
  'OTLET-52'
)
FROM workload_acceptance_proof \g /dev/null
RESET ROLE;

DO $$
DECLARE
  proof workload_acceptance_proof%ROWTYPE;
BEGIN
  SELECT * INTO proof FROM workload_acceptance_proof;
  BEGIN
    PERFORM otlet.record_workload_acceptance_exception(
      proof.current_contract_hash,
      'unknown_threshold',
      '{"required":false}'::jsonb,
      '{}'::jsonb,
      'invalid threshold probe'
    );
    RAISE EXCEPTION 'unknown threshold exception unexpectedly recorded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%threshold unknown_threshold does not exist%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM otlet.record_workload_promotion_decision(
      contract_hash => proof.current_contract_hash,
      outcome => 'defer',
      evidence_hash => otlet.identity_hash('invalid_acceptance_evidence', '{}'::jsonb),
      evidence_summary => '{"status":"invalid"}'::jsonb,
      reason => 'invalid exception probe',
      exception_hashes => ARRAY[otlet.identity_hash('missing_exception', '{}'::jsonb)]
    );
    RAISE EXCEPTION 'invalid exception reference unexpectedly recorded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%references an invalid exception%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    UPDATE otlet.workload_acceptance_contracts
    SET definition = definition
    WHERE contract_hash = proof.current_contract_hash;
    RAISE EXCEPTION 'acceptance contract update unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append only%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    DELETE FROM otlet.workload_acceptance_events
    WHERE event_hash = proof.decision_hash;
    RAISE EXCEPTION 'acceptance event delete unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append only%' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    TRUNCATE
      otlet.workload_acceptance_events,
      otlet.workload_pack_events;
    RAISE EXCEPTION 'acceptance event truncate unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append only%' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SELECT concat_ws('|',
  (SELECT count(*) = 2 FROM otlet.workload_acceptance_contracts),
  (SELECT count(*) = 3 FROM otlet.workload_acceptance_events),
  (SELECT bool_and(
     contract_hash = otlet.identity_hash('workload_acceptance_contract', definition)
   ) FROM otlet.workload_acceptance_contracts),
  (SELECT bool_and(
     authenticated_role_name = session_user
     AND active_role_name = current_user
   ) FROM otlet.workload_acceptance_contracts),
  (SELECT bool_and(
     authenticated_role_name = session_user
   )
   AND count(*) FILTER (WHERE active_role_name = session_user) = 2
   AND count(*) FILTER (WHERE active_role_name = :'delegate_role') = 1
   AND array_agg(event_order ORDER BY event_order) = ARRAY[1, 2, 3]::bigint[]
   FROM otlet.workload_acceptance_events),
  (SELECT count(*) = 1
   FROM otlet.workload_acceptance_status status
   JOIN workload_acceptance_proof proof
     ON proof.current_contract_hash = status.contract_hash
   WHERE status.current
     AND status.threshold_categories = 11
     AND status.exceptions = 2
     AND status.promotion_decisions = 1
     AND status.latest_event_kind = 'exception'
     AND status.latest_promotion_outcome = 'defer'),
  (SELECT head.active_workload_revision_hash = proof.baseline_revision_hash
   FROM otlet.workload_revision_heads head
   CROSS JOIN workload_acceptance_proof proof
   WHERE head.task_name = 'workload_acceptance_contract_probe'),
  (SELECT count(*) FROM otlet.jobs) = proof.job_count,
  (SELECT count(*) FROM otlet.inference_receipts) = proof.receipt_count,
  (SELECT count(*) FROM otlet.outputs) = proof.output_count,
  (SELECT count(*) FROM otlet.actions) = proof.action_count,
  (SELECT count(*) FROM otlet.semantic_materializations) = proof.materialization_count,
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_acceptance_contracts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  ),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_acceptance_events', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'
  ),
  NOT pg_catalog.has_table_privilege(
    'public', 'otlet.workload_acceptance_status', 'SELECT'
  ),
  NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc function
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = function.pronamespace
    WHERE namespace.nspname = 'otlet'
      AND function.proname IN (
        'register_workload_acceptance_contract',
        'record_workload_acceptance_exception',
        'record_workload_promotion_decision'
      )
      AND pg_catalog.has_function_privilege('public', function.oid, 'EXECUTE')
  )
)
FROM workload_acceptance_proof proof;

ROLLBACK;
SQL
} | tail -n 1)"

expected_workload_acceptance_contract="t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t"
if [ "$workload_acceptance_contract" != "$expected_workload_acceptance_contract" ]; then
  echo "Workload acceptance contract mismatch: $workload_acceptance_contract" >&2
  exit 1
fi

echo "workload_acceptance_contract=$workload_acceptance_contract"
