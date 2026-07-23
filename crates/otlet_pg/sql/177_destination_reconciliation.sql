CREATE TABLE otlet.destination_exports (
  id bigserial PRIMARY KEY,
  receipt_id bigint NOT NULL REFERENCES otlet.inference_receipts(id),
  recommendation_id text NOT NULL,
  decision_trace_sha256 text NOT NULL CHECK (decision_trace_sha256 ~ '^[0-9a-f]{64}$'),
  destination text NOT NULL CHECK (destination ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'),
  idempotency_key text NOT NULL CHECK (idempotency_key ~ '^sha256:[0-9a-f]{64}$'),
  state text NOT NULL DEFAULT 'exported' CHECK (
    state IN ('exported', 'received', 'applied', 'rejected', 'unknown')
  ),
  last_reason_code text,
  exported_at timestamptz NOT NULL DEFAULT now(),
  state_updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (receipt_id, destination),
  UNIQUE (destination, idempotency_key),
  CHECK (
    last_reason_code IS NULL
    OR last_reason_code ~ '^[a-z0-9][a-z0-9_.-]{0,127}$'
  )
);

CREATE TABLE otlet.destination_acknowledgements (
  id bigserial PRIMARY KEY,
  destination_export_id bigint NOT NULL REFERENCES otlet.destination_exports(id) ON DELETE CASCADE,
  acknowledgement_id text NOT NULL CHECK (
    acknowledgement_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$'
  ),
  acknowledgement_state text NOT NULL CHECK (
    acknowledgement_state IN ('received', 'applied', 'rejected')
  ),
  destination_execution_receipt_id text,
  replay_decision text NOT NULL CHECK (
    replay_decision IN ('fresh', 'duplicate_replay', 'not_applicable')
  ),
  replay_of_acknowledgement_id text,
  receiver_identity text NOT NULL CHECK (NULLIF(receiver_identity, '') IS NOT NULL),
  receiver_role text NOT NULL CHECK (NULLIF(receiver_role, '') IS NOT NULL),
  authentication_scheme text NOT NULL CHECK (authentication_scheme = 'ed25519'),
  receiver_key_sha256 text NOT NULL CHECK (receiver_key_sha256 ~ '^[0-9a-f]{64}$'),
  signed_payload_sha256 text NOT NULL CHECK (signed_payload_sha256 ~ '^[0-9a-f]{64}$'),
  signature_sha256 text NOT NULL CHECK (signature_sha256 ~ '^[0-9a-f]{64}$'),
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (destination_export_id, acknowledgement_id),
  CHECK (
    destination_execution_receipt_id IS NULL
    OR destination_execution_receipt_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$'
  ),
  CHECK (
    replay_of_acknowledgement_id IS NULL
    OR replay_of_acknowledgement_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$'
  ),
  CHECK ((replay_decision = 'duplicate_replay') = (replay_of_acknowledgement_id IS NOT NULL)),
  CHECK (
    (acknowledgement_state = 'applied') = (destination_execution_receipt_id IS NOT NULL)
  ),
  CHECK (
    (acknowledgement_state = 'applied' AND replay_decision IN ('fresh', 'duplicate_replay'))
    OR (acknowledgement_state <> 'applied' AND replay_decision = 'not_applicable')
  )
);

CREATE FUNCTION otlet.reject_destination_acknowledgement_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet destination acknowledgement history is immutable';
END;
$$;

CREATE TRIGGER destination_acknowledgements_immutable
BEFORE UPDATE OR DELETE ON otlet.destination_acknowledgements
FOR EACH ROW EXECUTE FUNCTION otlet.reject_destination_acknowledgement_change();

CREATE TRIGGER destination_acknowledgements_no_truncate
BEFORE TRUNCATE ON otlet.destination_acknowledgements
FOR EACH STATEMENT EXECUTE FUNCTION otlet.reject_destination_acknowledgement_change();

CREATE FUNCTION otlet.register_destination_export(
  receipt_id bigint,
  destination text
) RETURNS TABLE (
  destination_export_id bigint,
  recommendation_id text,
  idempotency_key text,
  reconciliation_state text
)
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  trace record;
  saved otlet.destination_exports%ROWTYPE;
BEGIN
  IF register_destination_export.destination !~ '^[a-z0-9][a-z0-9_.-]{0,127}$' THEN
    RAISE EXCEPTION 'otlet destination identifier is invalid';
  END IF;

  SELECT export.recommendation_id, export.decision_trace_sha256
  INTO trace
  FROM otlet.decision_trace_export export
  WHERE export.receipt_id = register_destination_export.receipt_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet destination export requires an accepted decision receipt';
  END IF;

  INSERT INTO otlet.destination_exports (
    receipt_id,
    recommendation_id,
    decision_trace_sha256,
    destination,
    idempotency_key
  )
  VALUES (
    register_destination_export.receipt_id,
    trace.recommendation_id,
    trace.decision_trace_sha256,
    register_destination_export.destination,
    'sha256:' || encode(sha256(convert_to(
      'otlet.destination.v1' || chr(10) ||
      register_destination_export.destination || chr(10) ||
      trace.recommendation_id,
      'UTF8'
    )), 'hex')
  )
  ON CONFLICT ON CONSTRAINT destination_exports_receipt_id_destination_key DO NOTHING;

  SELECT * INTO STRICT saved
  FROM otlet.destination_exports export
  WHERE export.receipt_id = register_destination_export.receipt_id
    AND export.destination = register_destination_export.destination;
  IF saved.recommendation_id IS DISTINCT FROM trace.recommendation_id
     OR saved.decision_trace_sha256 IS DISTINCT FROM trace.decision_trace_sha256 THEN
    RAISE EXCEPTION 'otlet recommendation changed after destination export';
  END IF;

  destination_export_id := saved.id;
  recommendation_id := saved.recommendation_id;
  idempotency_key := saved.idempotency_key;
  reconciliation_state := saved.state;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.mark_destination_unknown(
  destination_export_id bigint,
  reason_code text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  saved otlet.destination_exports%ROWTYPE;
BEGIN
  IF mark_destination_unknown.reason_code !~ '^[a-z0-9][a-z0-9_.-]{0,127}$' THEN
    RAISE EXCEPTION 'otlet destination unknown reason code is invalid';
  END IF;
  SELECT * INTO STRICT saved
  FROM otlet.destination_exports export
  WHERE export.id = mark_destination_unknown.destination_export_id
  FOR UPDATE;
  IF saved.state NOT IN ('exported', 'unknown') THEN
    RAISE EXCEPTION 'otlet acknowledged destination export cannot become unknown';
  END IF;
  UPDATE otlet.destination_exports export
  SET state = 'unknown',
      last_reason_code = mark_destination_unknown.reason_code,
      state_updated_at = now()
  WHERE export.id = saved.id;
  RETURN 'unknown';
END;
$$;

CREATE FUNCTION otlet.record_destination_acknowledgement(
  destination text,
  recommendation_id text,
  idempotency_key text,
  acknowledgement_id text,
  acknowledgement_state text,
  destination_execution_receipt_id text,
  replay_decision text,
  replay_of_acknowledgement_id text,
  receiver_key_sha256 text,
  signed_payload_sha256 text,
  signature_sha256 text
) RETURNS TABLE (
  destination_export_id bigint,
  reconciliation_state text,
  duplicate_acknowledgement boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_setting text := current_setting('role', true);
  receiver_role_name text;
  export otlet.destination_exports%ROWTYPE;
  existing otlet.destination_acknowledgements%ROWTYPE;
  replay_source otlet.destination_acknowledgements%ROWTYPE;
BEGIN
  IF record_destination_acknowledgement.acknowledgement_id
       !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$' THEN
    RAISE EXCEPTION 'otlet destination acknowledgement identifier is invalid';
  END IF;
  IF record_destination_acknowledgement.acknowledgement_state
       NOT IN ('received', 'applied', 'rejected') THEN
    RAISE EXCEPTION 'otlet destination acknowledgement state is invalid';
  END IF;
  IF record_destination_acknowledgement.receiver_key_sha256 !~ '^[0-9a-f]{64}$'
     OR record_destination_acknowledgement.signed_payload_sha256 !~ '^[0-9a-f]{64}$'
     OR record_destination_acknowledgement.signature_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'otlet destination acknowledgement authentication evidence is invalid';
  END IF;
  IF record_destination_acknowledgement.acknowledgement_state = 'applied' THEN
    IF record_destination_acknowledgement.destination_execution_receipt_id IS NULL
       OR record_destination_acknowledgement.replay_decision NOT IN ('fresh', 'duplicate_replay') THEN
      RAISE EXCEPTION 'otlet applied acknowledgement requires execution and replay evidence';
    END IF;
  ELSIF record_destination_acknowledgement.destination_execution_receipt_id IS NOT NULL
        OR record_destination_acknowledgement.replay_decision <> 'not_applicable' THEN
    RAISE EXCEPTION 'otlet non-applied acknowledgement cannot include execution evidence';
  END IF;

  SELECT * INTO STRICT export
  FROM otlet.destination_exports candidate
  WHERE candidate.destination = record_destination_acknowledgement.destination
    AND candidate.recommendation_id = record_destination_acknowledgement.recommendation_id
  FOR UPDATE;
  IF export.idempotency_key IS DISTINCT FROM record_destination_acknowledgement.idempotency_key THEN
    RAISE EXCEPTION 'otlet destination acknowledgement idempotency key conflicts';
  END IF;

  SELECT * INTO existing
  FROM otlet.destination_acknowledgements acknowledgement
  WHERE acknowledgement.destination_export_id = export.id
    AND acknowledgement.acknowledgement_id = record_destination_acknowledgement.acknowledgement_id;
  IF FOUND THEN
    IF existing.acknowledgement_state IS DISTINCT FROM record_destination_acknowledgement.acknowledgement_state
       OR existing.destination_execution_receipt_id IS DISTINCT FROM record_destination_acknowledgement.destination_execution_receipt_id
       OR existing.replay_decision IS DISTINCT FROM record_destination_acknowledgement.replay_decision
       OR existing.replay_of_acknowledgement_id IS DISTINCT FROM record_destination_acknowledgement.replay_of_acknowledgement_id
       OR existing.receiver_key_sha256 IS DISTINCT FROM record_destination_acknowledgement.receiver_key_sha256
       OR existing.signed_payload_sha256 IS DISTINCT FROM record_destination_acknowledgement.signed_payload_sha256
       OR existing.signature_sha256 IS DISTINCT FROM record_destination_acknowledgement.signature_sha256 THEN
      RAISE EXCEPTION 'otlet destination acknowledgement conflicts with recorded evidence';
    END IF;
    destination_export_id := export.id;
    reconciliation_state := export.state;
    duplicate_acknowledgement := true;
    RETURN NEXT;
    RETURN;
  END IF;

  IF record_destination_acknowledgement.replay_decision = 'duplicate_replay' THEN
    SELECT * INTO replay_source
    FROM otlet.destination_acknowledgements acknowledgement
    WHERE acknowledgement.destination_export_id = export.id
      AND acknowledgement.acknowledgement_id = record_destination_acknowledgement.replay_of_acknowledgement_id
      AND acknowledgement.acknowledgement_state = 'applied';
    IF NOT FOUND
       OR replay_source.destination_execution_receipt_id IS DISTINCT FROM record_destination_acknowledgement.destination_execution_receipt_id THEN
      RAISE EXCEPTION 'otlet destination replay acknowledgement is not linked to the applied receipt';
    END IF;
  ELSIF record_destination_acknowledgement.replay_of_acknowledgement_id IS NOT NULL THEN
    RAISE EXCEPTION 'otlet fresh acknowledgement cannot name a replay source';
  END IF;

  IF export.state = 'applied'
     AND (
       record_destination_acknowledgement.acknowledgement_state <> 'applied'
       OR record_destination_acknowledgement.replay_decision <> 'duplicate_replay'
     ) THEN
    RAISE EXCEPTION 'otlet applied destination acknowledgement is terminal';
  ELSIF export.state = 'rejected'
        AND record_destination_acknowledgement.acknowledgement_state <> 'rejected' THEN
    RAISE EXCEPTION 'otlet rejected destination acknowledgement is terminal';
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    receiver_role_name := session_user;
  ELSE
    SELECT rolname INTO receiver_role_name
    FROM pg_catalog.pg_roles
    WHERE oid = role_setting::regrole;
  END IF;

  INSERT INTO otlet.destination_acknowledgements (
    destination_export_id,
    acknowledgement_id,
    acknowledgement_state,
    destination_execution_receipt_id,
    replay_decision,
    replay_of_acknowledgement_id,
    receiver_identity,
    receiver_role,
    authentication_scheme,
    receiver_key_sha256,
    signed_payload_sha256,
    signature_sha256
  )
  VALUES (
    export.id,
    record_destination_acknowledgement.acknowledgement_id,
    record_destination_acknowledgement.acknowledgement_state,
    record_destination_acknowledgement.destination_execution_receipt_id,
    record_destination_acknowledgement.replay_decision,
    record_destination_acknowledgement.replay_of_acknowledgement_id,
    session_user,
    receiver_role_name,
    'ed25519',
    record_destination_acknowledgement.receiver_key_sha256,
    record_destination_acknowledgement.signed_payload_sha256,
    record_destination_acknowledgement.signature_sha256
  );

  UPDATE otlet.destination_exports saved
  SET state = record_destination_acknowledgement.acknowledgement_state,
      last_reason_code = NULL,
      state_updated_at = now()
  WHERE saved.id = export.id;

  destination_export_id := export.id;
  reconciliation_state := record_destination_acknowledgement.acknowledgement_state;
  duplicate_acknowledgement := false;
  RETURN NEXT;
END;
$$;

CREATE VIEW otlet.destination_reconciliation_status AS
SELECT
  export.id AS destination_export_id,
  export.receipt_id,
  export.recommendation_id,
  export.decision_trace_sha256,
  export.destination,
  export.idempotency_key,
  export.state,
  export.last_reason_code,
  export.exported_at,
  export.state_updated_at,
  COALESCE(acknowledgements.acknowledgement_count, 0)::bigint AS acknowledgement_count,
  latest.acknowledgement_id AS latest_acknowledgement_id,
  latest.acknowledgement_state AS latest_acknowledgement_state,
  latest.destination_execution_receipt_id,
  latest.replay_decision,
  latest.replay_of_acknowledgement_id,
  latest.receiver_identity,
  latest.receiver_role,
  latest.authentication_scheme,
  latest.receiver_key_sha256,
  latest.signed_payload_sha256,
  latest.signature_sha256,
  latest.acknowledged_at,
  COALESCE(executions.execution_receipt_ids, ARRAY[]::bigint[]) AS originating_execution_receipt_ids,
  COALESCE(executions.replay_of_receipt_ids, ARRAY[]::bigint[]) AS originating_replay_of_receipt_ids,
  export.state IN ('exported', 'unknown') AS acknowledgement_pending
FROM otlet.destination_exports export
LEFT JOIN LATERAL (
  SELECT count(*)::bigint AS acknowledgement_count
  FROM otlet.destination_acknowledgements acknowledgement
  WHERE acknowledgement.destination_export_id = export.id
) acknowledgements ON true
LEFT JOIN LATERAL (
  SELECT acknowledgement.*
  FROM otlet.destination_acknowledgements acknowledgement
  WHERE acknowledgement.destination_export_id = export.id
  ORDER BY acknowledgement.id DESC
  LIMIT 1
) latest ON true
LEFT JOIN LATERAL (
  SELECT
    array_agg(execution.id ORDER BY execution.id) AS execution_receipt_ids,
    array_agg(execution.replay_of_receipt_id ORDER BY execution.id)
      FILTER (WHERE execution.replay_of_receipt_id IS NOT NULL) AS replay_of_receipt_ids
  FROM otlet.actions action
  JOIN otlet.action_execution_receipts execution ON execution.action_id = action.id
  WHERE action.receipt_id = export.receipt_id
) executions ON true;
