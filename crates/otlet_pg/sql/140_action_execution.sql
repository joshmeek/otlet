CREATE FUNCTION otlet.dry_run_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  context_row record;
  validation_error text;
  action_row otlet.actions%ROWTYPE;
  target_row otlet.action_targets%ROWTYPE;
  action_body jsonb;
  typed_input jsonb;
  before_row jsonb;
  normalized_changes jsonb;
  proposed_row jsonb;
  changed_columns name[];
  json_pairs text;
  before_hash text;
  result_hash text;
BEGIN
  SELECT *
  INTO context_row
  FROM otlet.validated_action_context(dry_run_action.action_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  action_row := context_row.action_row;
  validation_error := context_row.validation_error;
  IF action_row.content_hash IS NOT NULL
     AND context_row.current_content_hash IS DISTINCT FROM action_row.content_hash THEN
    validation_error := 'source identity stale';
  END IF;
  IF action_row.status = 'rejected' THEN
    validation_error := COALESCE(action_row.error, validation_error, 'rejected action cannot be dry-run');
  ELSIF action_row.status = 'applied' THEN
    validation_error := 'applied action cannot be dry-run';
  END IF;

  IF action_row.action_type = 'update_row' THEN
    action_body := action_row.payload -> 'body';
    SELECT * INTO target_row
    FROM otlet.action_targets t
    WHERE t.name = action_body ->> 'target';

    IF validation_error IS NULL THEN
      SELECT
        array_agg(key::name ORDER BY key),
        string_agg(format('%L, to_jsonb(p.%I)', key, key), ', ' ORDER BY key)
      INTO changed_columns, json_pairs
      FROM jsonb_object_keys(action_body -> 'changes') key;

      typed_input := jsonb_build_object(
        target_row.identity_column::text,
        action_body -> 'identity'
      ) || (action_body -> 'changes');

      BEGIN
        EXECUTE format(
          'SELECT to_jsonb(t), jsonb_build_object(%s) '
          'FROM %s t '
          'CROSS JOIN LATERAL jsonb_populate_record(NULL::%s, $1) p '
          'WHERE t.%I = p.%I',
          json_pairs,
          target_row.target_table,
          target_row.target_table,
          target_row.identity_column,
          target_row.identity_column
        )
        INTO before_row, normalized_changes
        USING typed_input;
      EXCEPTION WHEN OTHERS THEN
        validation_error := otlet.action_execution_error(SQLSTATE);
      END;

      IF validation_error IS NULL AND before_row IS NULL THEN
        validation_error := 'action target row does not exist';
      ELSIF validation_error IS NULL THEN
        proposed_row := before_row || normalized_changes;
        before_hash := md5(otlet.semantic_canonical_jsonb(before_row)::text);
        result_hash := md5(otlet.semantic_canonical_jsonb(proposed_row)::text);
      END IF;
    END IF;

    INSERT INTO otlet.action_execution_receipts (
      action_id,
      idempotency_key,
      mode,
      status,
      target_name,
      target_table,
      identity_hash,
      changed_columns,
      affected_rows,
      before_hash,
      result_hash,
      error
    )
    VALUES (
      action_row.id,
      COALESCE(action_row.idempotency_key, md5('invalid-action:' || action_row.id::text)),
      'dry_run',
      CASE WHEN validation_error IS NULL THEN 'passed' ELSE 'failed' END,
      COALESCE(action_body ->> 'target', ''),
      COALESCE(target_row.target_table::text, action_row.source_table, ''),
      md5(COALESCE(otlet.semantic_canonical_jsonb(action_body -> 'identity')::text, 'null')),
      COALESCE(changed_columns, ARRAY[]::name[]),
      CASE WHEN validation_error IS NULL THEN 1 ELSE 0 END,
      before_hash,
      result_hash,
      validation_error
    );
  END IF;

  UPDATE otlet.actions
  SET dry_run_status = CASE WHEN validation_error IS NULL THEN 'passed' ELSE 'failed' END,
      error = validation_error
  WHERE id = action_row.id
  RETURNING * INTO action_row;

  RETURN NEXT action_row;
END;
$$;

CREATE FUNCTION otlet.apply_action(action_id bigint) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  context_row record;
  action_row otlet.actions%ROWTYPE;
  schema_row otlet.action_type_schemas%ROWTYPE;
  validation_error text;
  next_status text;
  next_apply_status text;
  next_error text;
  next_applied_at timestamptz;
  target_row otlet.action_targets%ROWTYPE;
  action_body jsonb;
  typed_input jsonb;
  before_row jsonb;
  after_row jsonb;
  changed_columns name[];
  set_clause text;
  before_hash text;
  after_hash text;
  dry_run_receipt otlet.action_execution_receipts%ROWTYPE;
  applied_receipt otlet.action_execution_receipts%ROWTYPE;
  execution_receipt_written boolean := false;
BEGIN
  SELECT *
  INTO context_row
  FROM otlet.validated_action_context(apply_action.action_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  action_row := context_row.action_row;
  schema_row := context_row.schema_row;
  validation_error := context_row.validation_error;
  next_status := action_row.status;
  next_apply_status := action_row.apply_status;
  next_error := action_row.error;
  next_applied_at := action_row.applied_at;

  IF action_row.action_type = 'update_row' THEN
    action_body := action_row.payload -> 'body';
    IF action_row.idempotency_key IS NULL THEN
      validation_error := COALESCE(validation_error, 'update_row idempotency key is missing');
    ELSE
      PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(action_row.idempotency_key, 0)
      );
    END IF;

    IF action_row.idempotency_key IS NOT NULL
       AND action_row.approval_status = 'approved'
       AND action_row.dry_run_status = 'passed'
       AND action_row.status IN ('approved', 'applied') THEN
      SELECT * INTO applied_receipt
      FROM otlet.action_execution_receipts r
      WHERE r.idempotency_key = action_row.idempotency_key
        AND r.mode = 'apply'
        AND r.status = 'applied'
      ORDER BY r.id
      LIMIT 1;
    END IF;

    IF applied_receipt.id IS NOT NULL THEN
      INSERT INTO otlet.action_execution_receipts (
        action_id,
        idempotency_key,
        mode,
        status,
        target_name,
        target_table,
        identity_hash,
        changed_columns,
        affected_rows,
        before_hash,
        result_hash,
        replay_of_receipt_id
      )
      VALUES (
        action_row.id,
        action_row.idempotency_key,
        'apply',
        'replayed',
        applied_receipt.target_name,
        applied_receipt.target_table,
        applied_receipt.identity_hash,
        applied_receipt.changed_columns,
        0,
        applied_receipt.before_hash,
        applied_receipt.result_hash,
        applied_receipt.id
      );

      UPDATE otlet.actions
      SET status = 'applied',
          apply_status = 'replayed',
          applied_at = COALESCE(applied_at, now()),
          error = NULL
      WHERE id = action_row.id
      RETURNING * INTO action_row;
      RETURN NEXT action_row;
      RETURN;
    END IF;
  END IF;

  IF action_row.content_hash IS NOT NULL
     AND context_row.current_content_hash IS DISTINCT FROM action_row.content_hash THEN
    validation_error := 'source identity stale';
  END IF;

  IF validation_error IS NOT NULL THEN
    next_apply_status := 'failed';
    next_error := validation_error;
  ELSIF action_row.status = 'rejected' THEN
    next_apply_status := 'failed';
    next_error := COALESCE(action_row.error, 'rejected action cannot be applied');
  ELSIF action_row.approval_status = 'required' THEN
    next_apply_status := 'failed';
    next_error := 'action requires approval';
  ELSIF action_row.action_type = 'update_row'
     AND (action_row.status <> 'approved' OR action_row.approval_status <> 'approved') THEN
    next_apply_status := 'failed';
    next_error := 'update_row requires approval';
  ELSIF action_row.action_type = 'update_row'
     AND action_row.dry_run_status <> 'passed' THEN
    next_apply_status := 'failed';
    next_error := 'update_row requires passed dry run';
  ELSIF action_row.action_type = 'update_row' THEN
    SELECT * INTO target_row
    FROM otlet.action_targets t
    WHERE t.name = action_body ->> 'target';
    validation_error := otlet.action_target_validation_error(action_body ->> 'target');

    IF validation_error IS NULL THEN
      SELECT * INTO dry_run_receipt
      FROM otlet.action_execution_receipts r
      WHERE r.action_id = action_row.id
        AND r.mode = 'dry_run'
        AND r.status = 'passed'
      ORDER BY r.created_at DESC, r.id DESC
      LIMIT 1;
      IF NOT FOUND THEN
        validation_error := 'update_row requires passed dry run';
      END IF;
    END IF;

    IF validation_error IS NULL THEN
      SELECT
        array_agg(key::name ORDER BY key),
        string_agg(format('%I = p.%I', key, key), ', ' ORDER BY key)
      INTO changed_columns, set_clause
      FROM jsonb_object_keys(action_body -> 'changes') key;

      typed_input := jsonb_build_object(
        target_row.identity_column::text,
        action_body -> 'identity'
      ) || (action_body -> 'changes');

      BEGIN
        EXECUTE format(
          'SELECT to_jsonb(t) '
          'FROM %s t '
          'CROSS JOIN LATERAL jsonb_populate_record(NULL::%s, $1) p '
          'WHERE t.%I = p.%I '
          'FOR UPDATE OF t',
          target_row.target_table,
          target_row.target_table,
          target_row.identity_column,
          target_row.identity_column
        )
        INTO before_row
        USING typed_input;
      EXCEPTION WHEN OTHERS THEN
        validation_error := otlet.action_execution_error(SQLSTATE);
      END;

      IF validation_error IS NULL AND before_row IS NULL THEN
        validation_error := 'action target row does not exist';
      ELSIF validation_error IS NULL THEN
        before_hash := md5(otlet.semantic_canonical_jsonb(before_row)::text);
        IF before_hash IS DISTINCT FROM dry_run_receipt.before_hash THEN
          validation_error := 'source changed after dry run';
        END IF;
      END IF;
    END IF;

    IF validation_error IS NULL THEN
      BEGIN
        EXECUTE format(
          'WITH p AS ('
          '  SELECT * FROM jsonb_populate_record(NULL::%s, $1)'
          ') '
          'UPDATE %s t SET %s '
          'FROM p '
          'WHERE t.%I = p.%I '
          'RETURNING to_jsonb(t)',
          target_row.target_table,
          target_row.target_table,
          set_clause,
          target_row.identity_column,
          target_row.identity_column
        )
        INTO after_row
        USING typed_input;
      EXCEPTION WHEN OTHERS THEN
        validation_error := otlet.action_execution_error(SQLSTATE);
      END;

      IF validation_error IS NULL AND after_row IS NULL THEN
        validation_error := 'bounded update affected no row';
      ELSIF validation_error IS NULL THEN
        after_hash := md5(otlet.semantic_canonical_jsonb(after_row)::text);
      END IF;
    END IF;

    IF validation_error IS NULL THEN
      INSERT INTO otlet.action_execution_receipts (
        action_id,
        idempotency_key,
        mode,
        status,
        target_name,
        target_table,
        identity_hash,
        changed_columns,
        affected_rows,
        before_hash,
        result_hash
      )
      VALUES (
        action_row.id,
        action_row.idempotency_key,
        'apply',
        'applied',
        action_body ->> 'target',
        target_row.target_table::text,
        md5(otlet.semantic_canonical_jsonb(action_body -> 'identity')::text),
        changed_columns,
        1,
        before_hash,
        after_hash
      );
      execution_receipt_written := true;
      next_status := 'applied';
      next_apply_status := 'applied';
      next_applied_at := now();
      next_error := NULL;
    ELSE
      INSERT INTO otlet.action_execution_receipts (
        action_id,
        idempotency_key,
        mode,
        status,
        target_name,
        target_table,
        identity_hash,
        changed_columns,
        affected_rows,
        before_hash,
        error
      )
      VALUES (
        action_row.id,
        action_row.idempotency_key,
        'apply',
        'failed',
        COALESCE(action_body ->> 'target', ''),
        COALESCE(target_row.target_table::text, action_row.source_table, ''),
        md5(COALESCE(otlet.semantic_canonical_jsonb(action_body -> 'identity')::text, 'null')),
        COALESCE(changed_columns, ARRAY[]::name[]),
        0,
        before_hash,
        validation_error
      );
      execution_receipt_written := true;
      next_apply_status := 'failed';
      next_error := validation_error;
    END IF;
  ELSIF schema_row.applyable THEN
    next_status := 'applied';
    next_apply_status := 'applied';
    next_applied_at := now();
    next_error := NULL;
  ELSE
    next_apply_status := 'not_applicable';
    next_error := 'action type has no apply path';
  END IF;

  IF action_row.action_type = 'update_row'
     AND next_apply_status = 'failed'
     AND NOT execution_receipt_written THEN
    SELECT * INTO target_row
    FROM otlet.action_targets t
    WHERE t.name = action_body ->> 'target';
    SELECT array_agg(key::name ORDER BY key) INTO changed_columns
    FROM jsonb_object_keys(COALESCE(action_body -> 'changes', '{}'::jsonb)) key;
    INSERT INTO otlet.action_execution_receipts (
      action_id,
      idempotency_key,
      mode,
      status,
      target_name,
      target_table,
      identity_hash,
      changed_columns,
      affected_rows,
      error
    )
    VALUES (
      action_row.id,
      COALESCE(action_row.idempotency_key, md5('invalid-action:' || action_row.id::text)),
      'apply',
      'failed',
      COALESCE(action_body ->> 'target', ''),
      COALESCE(target_row.target_table::text, action_row.source_table, ''),
      md5(COALESCE(otlet.semantic_canonical_jsonb(action_body -> 'identity')::text, 'null')),
      COALESCE(changed_columns, ARRAY[]::name[]),
      0,
      next_error
    );
  END IF;

  UPDATE otlet.actions
  SET status = next_status,
      apply_status = next_apply_status,
      dry_run_status = CASE
        WHEN action_row.action_type = 'update_row' AND next_apply_status = 'failed'
          THEN 'failed'
        ELSE dry_run_status
      END,
      applied_at = next_applied_at,
      error = next_error
  WHERE id = action_row.id
  RETURNING * INTO action_row;

  RETURN NEXT action_row;
END;
$$;
