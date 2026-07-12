CREATE FUNCTION otlet.action_target_validation_error(target_name text) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  target otlet.action_targets%ROWTYPE;
  relation_row record;
  column_name name;
BEGIN
  SELECT * INTO target
  FROM otlet.action_targets t
  WHERE t.name = action_target_validation_error.target_name;

  IF NOT FOUND THEN
    RETURN 'unknown action target';
  ELSIF NOT target.enabled THEN
    RETURN 'action target is disabled';
  END IF;

  SELECT
    c.relkind,
    c.relpersistence,
    c.relispartition,
    c.relrowsecurity,
    c.relforcerowsecurity,
    n.nspname
  INTO relation_row
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = target.target_table;

  IF NOT FOUND THEN
    RETURN 'action target table does not exist';
  ELSIF relation_row.relkind <> 'r' THEN
    RETURN 'action target must be an ordinary table';
  ELSIF relation_row.relispartition THEN
    RETURN 'action target cannot be a partition';
  ELSIF relation_row.relpersistence = 't' THEN
    RETURN 'action target cannot be temporary';
  ELSIF relation_row.nspname IN ('pg_catalog', 'information_schema', 'otlet')
     OR relation_row.nspname LIKE 'pg_toast%' THEN
    RETURN 'action target schema is not allowed';
  ELSIF relation_row.relrowsecurity OR relation_row.relforcerowsecurity THEN
    RETURN 'action target cannot use row level security';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid
     AND a.attnum = i.indkey[0]
    WHERE i.indrelid = target.target_table
      AND i.indisprimary
      AND i.indnkeyatts = 1
      AND a.attname = target.identity_column
      AND NOT a.attisdropped
  ) THEN
    RETURN 'action target identity must be its single-column primary key';
  END IF;

  IF cardinality(target.allowed_columns) IS NULL
     OR cardinality(target.allowed_columns) NOT BETWEEN 1 AND 16
     OR target.identity_column = ANY(target.allowed_columns)
     OR EXISTS (SELECT 1 FROM unnest(target.allowed_columns) c WHERE c IS NULL)
     OR cardinality(target.allowed_columns) <> (
       SELECT count(DISTINCT c)::integer FROM unnest(target.allowed_columns) c
     ) THEN
    RETURN 'action target allowed columns are invalid';
  END IF;

  FOREACH column_name IN ARRAY target.allowed_columns LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = target.target_table
        AND a.attname = column_name
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.attgenerated = ''
        AND a.attidentity = ''
    ) THEN
      RETURN 'action target column is not writable';
    ELSIF NOT pg_catalog.has_column_privilege(
      current_user,
      target.target_table,
      column_name,
      'SELECT'
    ) OR NOT pg_catalog.has_column_privilege(
      current_user,
      target.target_table,
      column_name,
      'UPDATE'
    ) THEN
      RETURN 'action target column privilege is missing';
    END IF;
  END LOOP;

  IF NOT pg_catalog.has_column_privilege(
    current_user,
    target.target_table,
    target.identity_column,
    'SELECT'
  ) THEN
    RETURN 'action target identity privilege is missing';
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.register_action_target(
  target_name text,
  target_table regclass,
  identity_column name,
  allowed_columns name[]
) RETURNS otlet.action_targets
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.action_targets%ROWTYPE;
  validation_error text;
  normalized_columns name[];
BEGIN
  IF target_name IS NULL OR target_name !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'otlet action target name is invalid';
  END IF;

  SELECT array_agg(c ORDER BY c) INTO normalized_columns
  FROM unnest(allowed_columns) c;

  INSERT INTO otlet.action_targets (
    name,
    target_table,
    identity_column,
    allowed_columns,
    enabled
  )
  VALUES (
    target_name,
    target_table,
    identity_column,
    normalized_columns,
    true
  )
  ON CONFLICT (name) DO UPDATE
    SET target_table = EXCLUDED.target_table,
        identity_column = EXCLUDED.identity_column,
        allowed_columns = EXCLUDED.allowed_columns,
        enabled = true,
        updated_at = now()
  RETURNING * INTO saved;

  validation_error := otlet.action_target_validation_error(saved.name);
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet %', validation_error;
  END IF;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.disable_action_target(target_name text) RETURNS otlet.action_targets
LANGUAGE plpgsql
AS $$
DECLARE
  saved otlet.action_targets%ROWTYPE;
BEGIN
  UPDATE otlet.action_targets t
  SET enabled = false,
      updated_at = now()
  WHERE t.name = disable_action_target.target_name
  RETURNING * INTO saved;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet action target % does not exist', target_name;
  END IF;

  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.update_row_idempotency_key(
  action_body jsonb,
  source_content_hash text
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT md5(
    concat_ws(
      E'\x1f',
      $1 ->> 'target',
      otlet.semantic_canonical_jsonb($1 -> 'identity')::text,
      $2,
      otlet.semantic_canonical_jsonb($1 -> 'changes')::text
    )
  );
$$;

CREATE FUNCTION otlet.action_execution_error(sqlstate text) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE
    WHEN $1 IN ('22P02', '22003', '22007', '22008', '23502')
      THEN 'target value failed type validation'
    WHEN $1 IN ('42P01', '42703', '42804')
      THEN 'action target changed'
    WHEN $1 = '42501'
      THEN 'action target privilege denied'
    ELSE 'bounded update execution failed'
  END;
$$;

CREATE FUNCTION otlet.action_validation_error(
  action jsonb,
  output jsonb DEFAULT NULL,
  job_subject_id text DEFAULT NULL,
  job_input jsonb DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_action_type text := COALESCE(action ->> 'type', '');
  body jsonb;
  schema_row otlet.action_type_schemas%ROWTYPE;
  expected_left_id text;
  expected_right_id text;
  output_confidence text := NULLIF(output ->> 'confidence', '');
  output_rank int;
  action_rank int;
  unsupported_key text;
  target_row otlet.action_targets%ROWTYPE;
  target_error text;
  changed_key text;
  changed_count integer;
  action_identity text;
  source_table_name text;
BEGIN
  IF jsonb_typeof(action) IS DISTINCT FROM 'object' THEN
    RETURN 'action must be an object';
  END IF;

  IF v_action_type = '' THEN
    RETURN 'action missing type';
  END IF;

  SELECT *
  INTO schema_row
  FROM otlet.action_type_schemas s
  WHERE s.action_type = v_action_type;

  IF NOT FOUND THEN
    RETURN 'unsupported action type';
  END IF;

  body := CASE
    WHEN v_action_type = 'create_record' THEN action - 'type'
    ELSE action -> 'body'
  END;

  IF v_action_type <> 'create_record' THEN
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(action) AS key
    WHERE key NOT IN ('type', 'body')
    ORDER BY key
    LIMIT 1;

    IF unsupported_key IS NOT NULL THEN
      RETURN 'action has unsupported key';
    END IF;
  END IF;

  IF jsonb_typeof(body) IS DISTINCT FROM 'object' THEN
    RETURN 'action body must be an object';
  END IF;

  expected_left_id := NULLIF(job_input #>> '{action_ids,left_id}', '');
  expected_right_id := NULLIF(job_input #>> '{action_ids,right_id}', '');

  output_rank := CASE output_confidence WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;

  IF v_action_type = 'create_record' THEN
    IF NULLIF(body ->> 'record_type', '') IS NULL THEN
      RETURN 'create_record missing record_type';
    ELSIF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'create_record missing subject_id';
    ELSIF jsonb_typeof(body -> 'body') IS DISTINCT FROM 'object' THEN
      RETURN 'create_record missing body';
    END IF;
    SELECT key
    INTO unsupported_key
    FROM jsonb_object_keys(body) AS key
    WHERE key NOT IN ('record_type', 'subject_id', 'body')
    ORDER BY key
    LIMIT 1;
    IF unsupported_key IS NOT NULL THEN
      RETURN 'create_record unsupported payload field: ' || unsupported_key;
    END IF;
  ELSIF v_action_type = 'merge_candidate' THEN
    IF NULLIF(body ->> 'left_id', '') IS NULL THEN
      RETURN 'merge_candidate missing left_id';
    ELSIF NULLIF(body ->> 'right_id', '') IS NULL THEN
      RETURN 'merge_candidate missing right_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'merge_candidate missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'same_entity' THEN
      RETURN 'merge_candidate requires same_entity output';
    ELSIF expected_left_id IS NULL OR expected_right_id IS NULL THEN
      RETURN 'merge_candidate requires input.action_ids left_id and right_id';
    ELSIF body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id THEN
      RETURN 'merge_candidate subject ids must match job subject_id';
    ELSIF body ? 'confidence' AND body ->> 'confidence' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'merge_candidate confidence must be low, medium, or high';
    END IF;
    action_rank := CASE body ->> 'confidence' WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 ELSE NULL END;
    IF output_rank IS NOT NULL AND action_rank IS NOT NULL AND action_rank > output_rank THEN
      RETURN 'merge_candidate confidence cannot exceed output confidence';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'merge_candidate missing decisive evidence';
    END IF;
  ELSIF v_action_type = 'new_entity' THEN
    IF NULLIF(body ->> 'entity_id', '') IS NULL THEN
      RETURN 'new_entity missing entity_id';
    ELSIF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'new_entity missing reason';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'different_entity' THEN
      RETURN 'new_entity requires different_entity output';
    ELSIF expected_right_id IS NULL THEN
      RETURN 'new_entity requires input.action_ids right_id';
    ELSIF body ->> 'entity_id' <> expected_right_id THEN
      RETURN 'new_entity entity_id must match job right subject_id';
    END IF;
    IF body ? 'evidence'
       AND NOT (
         (jsonb_typeof(body -> 'evidence') = 'array' AND jsonb_array_length(body -> 'evidence') > 0)
         OR (jsonb_typeof(body -> 'evidence') = 'string' AND btrim(body ->> 'evidence') <> '')
       ) THEN
      RETURN 'new_entity missing separation evidence';
    END IF;
  ELSIF v_action_type = 'review_flag' THEN
    IF NULLIF(body ->> 'reason', '') IS NULL THEN
      RETURN 'review_flag missing reason';
    ELSIF body ? 'severity' AND body ->> 'severity' NOT IN ('low', 'medium', 'high') THEN
      RETURN 'review_flag severity must be low, medium, or high';
    ELSIF NULLIF(output ->> 'match', '') IS NOT NULL AND output ->> 'match' <> 'unclear' THEN
      RETURN 'review_flag requires unclear output';
    ELSIF expected_left_id IS NOT NULL
       AND NULLIF(body ->> 'left_id', '') IS NOT NULL
       AND (body ->> 'left_id' <> expected_left_id OR body ->> 'right_id' <> expected_right_id) THEN
      RETURN 'review_flag subject ids must match job subject_id';
    END IF;
  ELSIF v_action_type = 'note' THEN
    IF NULLIF(body ->> 'subject_id', '') IS NULL THEN
      RETURN 'note missing subject_id';
    ELSIF NULLIF(body ->> 'text', '') IS NULL THEN
      RETURN 'note missing text';
    END IF;
  ELSIF v_action_type = 'update_row' THEN
    IF pg_column_size(action) > 16384 THEN
      RETURN 'update_row exceeds 16384 byte limit';
    END IF;
    SELECT key INTO unsupported_key
    FROM jsonb_object_keys(body) key
    WHERE key NOT IN ('target', 'identity', 'changes')
    ORDER BY key
    LIMIT 1;
    IF unsupported_key IS NOT NULL THEN
      RETURN 'update_row has unsupported body key';
    ELSIF NULLIF(body ->> 'target', '') IS NULL THEN
      RETURN 'update_row missing target';
    ELSIF jsonb_typeof(body -> 'identity') NOT IN ('string', 'number') THEN
      RETURN 'update_row identity must be a string or number';
    ELSIF jsonb_typeof(body -> 'changes') IS DISTINCT FROM 'object' THEN
      RETURN 'update_row changes must be a non-empty object';
    END IF;
    SELECT count(*)::integer INTO changed_count
    FROM jsonb_object_keys(body -> 'changes');
    IF changed_count = 0 THEN
      RETURN 'update_row changes must be a non-empty object';
    ELSIF changed_count > 16 THEN
      RETURN 'update_row changes exceed 16 columns';
    END IF;

    SELECT * INTO target_row
    FROM otlet.action_targets t
    WHERE t.name = body ->> 'target';
    target_error := otlet.action_target_validation_error(body ->> 'target');
    IF target_error IS NOT NULL THEN
      RETURN target_error;
    END IF;

    action_identity := body #>> '{identity}';
    source_table_name := job_input #>> '{_otlet_mvcc,table}';
    IF source_table_name IS NULL THEN
      source_table_name := job_input #>> '{otlet_mvcc,table}';
    END IF;
    IF action_identity IS DISTINCT FROM job_subject_id THEN
      RETURN 'update_row identity must match job subject_id';
    ELSIF target_row.target_table::oid IS DISTINCT FROM to_regclass(source_table_name)::oid THEN
      RETURN 'update_row target must match source table';
    END IF;

    SELECT key INTO changed_key
    FROM jsonb_object_keys(body -> 'changes') key
    WHERE NOT key::name = ANY(target_row.allowed_columns)
    ORDER BY key
    LIMIT 1;
    IF changed_key IS NOT NULL THEN
      RETURN 'update_row column is not allowed';
    END IF;

    SELECT changed.key INTO changed_key
    FROM jsonb_each(body -> 'changes') changed
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = target_row.target_table
     AND a.attname = changed.key
     AND a.attnum > 0
     AND NOT a.attisdropped
    WHERE changed.value = 'null'::jsonb
      AND a.attnotnull
    ORDER BY changed.key
    LIMIT 1;
    IF changed_key IS NOT NULL THEN
      RETURN 'update_row cannot set a required column to null';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.complete_job(
  job_id bigint,
  output jsonb,
  raw_output text,
  actions jsonb DEFAULT '[]'::jsonb,
  prompt_hash text DEFAULT NULL,
  input_hash text DEFAULT NULL,
  output_schema_hash text DEFAULT NULL,
  raw_output_hash text DEFAULT NULL,
  started_at timestamptz DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  model_name text DEFAULT NULL,
  selection_role text DEFAULT 'direct',
  selection_status text DEFAULT 'accepted',
  selection_reason text DEFAULT NULL
) RETURNS SETOF otlet.outputs
LANGUAGE plpgsql
AS $$
DECLARE
  saved_output otlet.outputs%ROWTYPE;
  saved_receipt otlet.inference_receipts%ROWTYPE;
  job_row otlet.jobs%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  model_row otlet.models%ROWTYPE;
  action jsonb;
  action_payload jsonb;
  action_body jsonb;
  saved_action_id bigint;
  action_error text;
  action_type_name text;
  action_status text;
  action_approval_status text;
  action_rejected_by_watch boolean;
  action_subject_id text;
  action_requires_approval boolean;
  action_creates_record boolean;
  action_record_type text;
  action_record_body jsonb;
  action_idempotency_key text;
  has_action_type_restriction boolean := false;
  finish_started timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO job_row
  FROM otlet.jobs
  WHERE id = complete_job.job_id
    AND status IN ('running', 'cancel_requested')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT t.model_name, t.input_shaping
  INTO task_row.model_name, task_row.input_shaping
  FROM otlet.tasks t
  WHERE t.name = job_row.task_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', job_row.task_name;
  END IF;
  SELECT m.name
  INTO model_row.name
  FROM otlet.models m
  WHERE m.name = COALESCE(complete_job.model_name, task_row.model_name);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet model % does not exist',
      COALESCE(complete_job.model_name, task_row.model_name);
  END IF;

  -- Fail before mutating job/receipt state on a bad envelope.
  IF jsonb_typeof(COALESCE(complete_job.actions, '[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'otlet complete_job actions must be an array';
  END IF;
  IF jsonb_typeof(COALESCE(complete_job.trace_summary, '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet complete_job trace_summary must be a JSON object';
  END IF;
  IF COALESCE(complete_job.selection_role, 'direct') NOT IN ('direct', 'cheap', 'strong') THEN
    RAISE EXCEPTION 'otlet complete_job selection_role must be direct, cheap, or strong';
  END IF;
  IF COALESCE(complete_job.selection_status, 'accepted') NOT IN ('accepted', 'rejected', 'failed') THEN
    RAISE EXCEPTION 'otlet complete_job selection_status must be accepted, rejected, or failed';
  END IF;
  IF COALESCE(complete_job.selection_status, 'accepted') <> 'accepted' THEN
    RAISE EXCEPTION 'otlet complete_job requires selection_status accepted';
  END IF;
  IF COALESCE(complete_job.trace_summary ->> 'schema_validation_status', 'not_run')
     IS DISTINCT FROM 'passed' THEN
    RAISE EXCEPTION 'otlet complete_job requires schema_validation_status passed';
  END IF;

  IF job_row.status = 'cancel_requested' THEN
    PERFORM 1
    FROM otlet.finish_canceled_job(
      complete_job.job_id,
      complete_job.raw_output,
      complete_job.prompt_hash,
      complete_job.input_hash,
      complete_job.output_schema_hash,
      COALESCE(complete_job.raw_output_hash, md5(complete_job.raw_output)),
      complete_job.started_at,
      true,
      model_row.name
    );
    RETURN;
  END IF;

  UPDATE otlet.jobs
  SET status = 'complete',
      leased_until = NULL,
      error = NULL,
      finished_at = now()
  WHERE id = complete_job.job_id
  RETURNING * INTO job_row;

  SELECT *
  INTO saved_receipt
  FROM otlet.record_model_attempt(
    job_row.id,
    model_row.name,
    output => complete_job.output,
    raw_output => complete_job.raw_output,
    prompt_hash => complete_job.prompt_hash,
    input_hash => complete_job.input_hash,
    output_schema_hash => complete_job.output_schema_hash,
    raw_output_hash => COALESCE(complete_job.raw_output_hash, md5(complete_job.raw_output)),
    started_at => complete_job.started_at,
    trace_summary => complete_job.trace_summary,
    selection_role => COALESCE(complete_job.selection_role, 'direct'),
    selection_status => COALESCE(complete_job.selection_status, 'accepted'),
    selection_reason => complete_job.selection_reason,
    error => NULL
  );

  -- outputs_one_per_job_idx; qualify column vs complete_job.job_id param.
  SELECT *
  INTO saved_output
  FROM otlet.outputs o
  WHERE o.job_id = job_row.id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM otlet.touch_runtime_slot(model_row.name, 'ready', 0, NULL);
  PERFORM otlet.record_worker_event(
    'job_completed',
    job_row.id,
    'linked_inproc',
    'otlet worker completed job',
    jsonb_build_object(
      'task_name', job_row.task_name,
      'subject_id', job_row.subject_id,
      'model_name', model_row.name,
      'selection_role', COALESCE(complete_job.selection_role, 'direct'),
      'selection_reason', complete_job.selection_reason
    )
  );

  -- One probe for the job's task: skip per-action watch scans when unrestricted.
  SELECT EXISTS (
    SELECT 1
    FROM otlet.watches w
    WHERE w.task_name = job_row.task_name
      AND cardinality(w.action_types) > 0
  )
  INTO has_action_type_restriction;

  FOR action IN SELECT value FROM jsonb_array_elements(COALESCE(complete_job.actions, '[]'::jsonb)) LOOP
    action_payload := CASE
      WHEN jsonb_typeof(action) = 'object' THEN action
      ELSE jsonb_build_object('invalid_action', action)
    END;
    action_body := CASE
      WHEN jsonb_typeof(action_payload -> 'body') = 'object' THEN action_payload -> 'body'
      ELSE '{}'::jsonb
    END;
    action_type_name := COALESCE(NULLIF(action ->> 'type', ''), 'invalid');
    action_error := otlet.action_validation_error(action, complete_job.output, job_row.subject_id, job_row.input);
    action_rejected_by_watch := false;
    action_requires_approval := false;
    action_creates_record := false;
    action_idempotency_key := NULL;
    IF action_error IS NULL THEN
      SELECT
        CASE
          WHEN has_action_type_restriction THEN EXISTS (
            SELECT 1
            FROM otlet.watches w
            WHERE w.task_name = job_row.task_name
              AND cardinality(w.action_types) > 0
              AND NOT action_type_name = ANY(w.action_types)
          )
          ELSE false
        END,
        COALESCE(s.requires_approval, false),
        COALESCE(s.creates_record, false)
      INTO action_rejected_by_watch, action_requires_approval, action_creates_record
      FROM (SELECT 1) seed
      LEFT JOIN otlet.action_type_schemas s ON s.action_type = action_type_name;

      IF action_rejected_by_watch THEN
        action_error := 'action type ' || action_type_name || ' is not allowed by watch';
        action_requires_approval := false;
        action_creates_record := false;
      END IF;
    END IF;
    action_subject_id := COALESCE(
      NULLIF(action_payload ->> 'subject_id', ''),
      NULLIF(action_payload ->> 'entity_id', ''),
      NULLIF(action_payload ->> 'right_id', ''),
      NULLIF(action_body ->> 'subject_id', ''),
      NULLIF(action_body ->> 'entity_id', ''),
      NULLIF(action_body ->> 'right_id', ''),
      job_row.subject_id
    );
    action_status := CASE
      WHEN action_error IS NOT NULL THEN 'rejected'
      WHEN action_creates_record AND NOT action_requires_approval THEN 'complete'
      ELSE 'proposed'
    END;
    action_approval_status := CASE
      WHEN action_error IS NOT NULL THEN 'not_required'
      WHEN action_requires_approval THEN 'required'
      ELSE 'not_required'
    END;
    IF action_error IS NULL AND action_type_name = 'update_row' THEN
      action_idempotency_key := otlet.update_row_idempotency_key(
        action_body,
        otlet.semantic_content_hash(job_row.input, task_row.input_shaping)
      );
    END IF;

    INSERT INTO otlet.actions (
      job_id,
      output_id,
      receipt_id,
      action_type,
      payload,
      status,
      approval_status,
      subject_id,
      source_table,
      source_hash,
      content_hash,
      idempotency_key,
      error
    )
    VALUES (
      complete_job.job_id,
      saved_output.id,
      saved_receipt.id,
      action_type_name,
      action_payload,
      action_status,
      action_approval_status,
      action_subject_id,
      complete_job.trace_summary #>> '{mvcc,table}',
      COALESCE(
        complete_job.trace_summary #>> '{mvcc,source_hash}',
        md5((complete_job.trace_summary -> 'mvcc')::text)
      ),
      otlet.semantic_content_hash(job_row.input, task_row.input_shaping),
      action_idempotency_key,
      action_error
    )
    RETURNING id INTO saved_action_id;

    IF action_creates_record THEN
      action_record_type := CASE
        WHEN action_type_name = 'note' THEN COALESCE(NULLIF(action_payload ->> 'record_type', ''), 'note')
        ELSE action_payload ->> 'record_type'
      END;
      action_record_body := action_body;

      INSERT INTO otlet.records (action_id, record_type, subject_id, body)
      VALUES (
        saved_action_id,
        action_record_type,
        action_subject_id,
        action_record_body
      );
    END IF;
  END LOOP;

  UPDATE otlet.inference_receipts r
  SET trace_summary = r.trace_summary || jsonb_build_object(
    'finish_sql_ms',
    GREATEST(
      0,
      CEIL(EXTRACT(epoch FROM (clock_timestamp() - finish_started)) * 1000)
    )::bigint
  )
  WHERE r.id = saved_receipt.id;

  RETURN NEXT saved_output;
END;
$$;

CREATE FUNCTION otlet.approve_action(
  action_id bigint,
  review_reason text DEFAULT NULL
) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'approved',
      approval_status = 'approved',
      approved_at = now(),
      error = NULL,
      review_reason = NULLIF(approve_action.review_reason, '')
  WHERE id = approve_action.action_id
    AND status = 'proposed'
    AND approval_status = 'required'
  RETURNING * INTO action_row;

  IF FOUND THEN
    RETURN NEXT action_row;
  END IF;
END;
$$;

CREATE FUNCTION otlet.reject_action(
  action_id bigint,
  reason text DEFAULT 'rejected',
  review_reason text DEFAULT NULL
) RETURNS SETOF otlet.actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
BEGIN
  UPDATE otlet.actions
  SET status = 'rejected',
      approval_status = 'rejected',
      error = reject_action.reason,
      review_reason = COALESCE(NULLIF(reject_action.review_reason, ''), NULLIF(reject_action.reason, ''))
  WHERE id = reject_action.action_id
    AND status <> 'applied'
  RETURNING * INTO action_row;

  IF FOUND THEN
    RETURN NEXT action_row;
  END IF;
END;
$$;

CREATE FUNCTION otlet.validated_action_context(action_id bigint)
RETURNS TABLE (
  action_row otlet.actions,
  schema_row otlet.action_type_schemas,
  job_row otlet.jobs,
  output_body jsonb,
  current_content_hash text,
  validation_error text
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    a,
    s,
    j,
    o.output,
    otlet.current_task_subject_content_hash(j.task_name, j.subject_id),
    otlet.action_validation_error(a.payload, o.output, j.subject_id, j.input)
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  LEFT JOIN otlet.action_type_schemas s ON s.action_type = a.action_type
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  WHERE a.id = validated_action_context.action_id
  FOR UPDATE OF a;
END;
$$;

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
