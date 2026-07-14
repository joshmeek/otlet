CREATE FUNCTION otlet.output_schema_enum_values(
  output_schema jsonb,
  field_name text
) RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN jsonb_typeof(COALESCE($1, '{}'::jsonb) #> ARRAY['properties', COALESCE(NULLIF($2, ''), 'match'), 'enum']) = 'array'
      THEN ARRAY(
        SELECT value
        FROM jsonb_array_elements_text(COALESCE($1, '{}'::jsonb) #> ARRAY['properties', COALESCE(NULLIF($2, ''), 'match'), 'enum']) AS enum_value(value)
      )
    ELSE NULL
  END;
$$;

CREATE FUNCTION otlet.action_declared_answer(
  action_type text,
  answer_field text
) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT CASE COALESCE(NULLIF($2, ''), 'match')
    WHEN 'match' THEN CASE $1
      WHEN 'merge_candidate' THEN 'same_entity'
      WHEN 'new_entity' THEN 'different_entity'
      WHEN 'review_flag' THEN 'unclear'
      ELSE NULL
    END
    WHEN 'decision' THEN CASE $1
      WHEN 'review_flag' THEN 'flag'
      ELSE NULL
    END
    ELSE NULL
  END;
$$;

CREATE FUNCTION otlet.label_action(
  action_id bigint,
  expected_answer text DEFAULT NULL,
  expected_confidence text DEFAULT NULL,
  expected_action_type text DEFAULT NULL,
  reason text DEFAULT NULL,
  label_source text DEFAULT NULL
) RETURNS SETOF otlet.eval_labels
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  action_row otlet.actions%ROWTYPE;
  schema_row otlet.action_type_schemas%ROWTYPE;
  task_row otlet.tasks%ROWTYPE;
  output_body jsonb;
  receipt_trace jsonb;
  saved_label otlet.eval_labels%ROWTYPE;
  answer_field text;
  confidence_field text;
  answer_values text[];
  abstain_values text[] := ARRAY[]::text[];
  output_answer text;
  action_answer text;
  fallback_rejected_answer text;
  final_source text;
  final_answer text;
  final_confidence text;
  final_action_type text;
BEGIN
  SELECT a.*
  INTO action_row
  FROM otlet.actions a
  WHERE a.id = label_action.action_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT t.*
  INTO task_row
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE j.id = action_row.job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet label_action could not find task for action %', action_row.id;
  END IF;

  SELECT *
  INTO schema_row
  FROM otlet.action_type_schemas s
  WHERE s.action_type = action_row.action_type;

  SELECT o.output
  INTO output_body
  FROM otlet.outputs o
  WHERE o.id = action_row.output_id;

  SELECT r.trace_summary
  INTO receipt_trace
  FROM otlet.inference_receipts r
  WHERE r.id = action_row.receipt_id;

  answer_field := COALESCE(NULLIF(task_row.decision_contract ->> 'answer_field', ''), 'match');
  confidence_field := COALESCE(NULLIF(task_row.decision_contract ->> 'confidence_field', ''), 'confidence');
  answer_values := otlet.output_schema_enum_values(task_row.output_schema, answer_field);
  output_answer := NULLIF(output_body ->> answer_field, '');
  action_answer := otlet.action_declared_answer(action_row.action_type, answer_field);

  IF jsonb_typeof(task_row.decision_contract -> 'abstain_values') = 'array' THEN
    SELECT COALESCE(array_agg(value), ARRAY[]::text[])
    INTO abstain_values
    FROM jsonb_array_elements_text(task_row.decision_contract -> 'abstain_values') AS abstain(value);
  END IF;

  IF schema_row.requires_approval
     AND action_answer IS NOT NULL
     AND NOT action_answer = ANY(abstain_values)
     AND answer_values IS NOT NULL THEN
    SELECT value
    INTO fallback_rejected_answer
    FROM unnest(answer_values) WITH ORDINALITY AS answer(value, ord)
    WHERE value <> action_answer
      AND NOT value = ANY(abstain_values)
    ORDER BY ord
    LIMIT 1;
  END IF;

  final_source := COALESCE(
    NULLIF(label_action.label_source, ''),
    CASE
      WHEN action_row.status IN ('approved', 'applied') OR action_row.approval_status = 'approved' THEN 'approved_action'
      WHEN action_row.status = 'rejected' OR action_row.approval_status = 'rejected' THEN 'rejected_action'
      ELSE 'manual_correction'
    END
  );

  final_answer := COALESCE(
    NULLIF(label_action.expected_answer, ''),
    CASE
      WHEN final_source = 'approved_action' THEN COALESCE(action_answer, output_answer)
      WHEN final_source = 'rejected_action' THEN COALESCE(fallback_rejected_answer, output_answer)
      ELSE output_answer
    END
  );

  IF NULLIF(final_answer, '') IS NULL THEN
    RAISE EXCEPTION 'otlet expected_answer is required for task % field %', task_row.name, answer_field;
  END IF;

  IF answer_values IS NOT NULL AND NOT final_answer = ANY(answer_values) THEN
    RAISE EXCEPTION 'otlet expected_answer % is not valid for task % field %', final_answer, task_row.name, answer_field;
  END IF;

  final_confidence := COALESCE(
    NULLIF(label_action.expected_confidence, ''),
    output_body ->> confidence_field,
    CASE WHEN final_answer = ANY(abstain_values) THEN 'medium' ELSE 'high' END
  );
  final_action_type := COALESCE(NULLIF(label_action.expected_action_type, ''), action_row.action_type);

  INSERT INTO otlet.eval_labels (
    action_id,
    output_id,
    receipt_id,
    source_table,
    subject_id,
    source_hash,
    expected_answer,
    expected_confidence,
    expected_action_type,
    label_source,
    reason
  )
  VALUES (
    action_row.id,
    action_row.output_id,
    action_row.receipt_id,
    COALESCE(action_row.source_table, receipt_trace #>> '{mvcc,table}'),
    COALESCE(action_row.subject_id, ''),
    COALESCE(
      action_row.source_hash,
      receipt_trace #>> '{mvcc,source_hash}',
      md5((receipt_trace -> 'mvcc')::text)
    ),
    final_answer,
    final_confidence,
    final_action_type,
    final_source,
    label_action.reason
  )
  RETURNING * INTO saved_label;

  RETURN NEXT saved_label;
END;
$$;

CREATE FUNCTION otlet.correct_action(
  action_id bigint,
  corrected jsonb DEFAULT '{}'::jsonb,
  reason text DEFAULT NULL
) RETURNS SETOF otlet.eval_labels
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  rejected_action otlet.actions%ROWTYPE;
  correction jsonb := COALESCE(correct_action.corrected, '{}'::jsonb);
BEGIN
  SELECT *
  INTO rejected_action
  FROM otlet.reject_action(
    correct_action.action_id,
    COALESCE(NULLIF(correct_action.reason, ''), 'manual correction')
  );

  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT *
  FROM otlet.label_action(
    rejected_action.id,
    expected_answer => COALESCE(
      NULLIF(correction ->> 'expected_answer', ''),
      NULLIF(correction ->> 'answer', ''),
      NULLIF(correction ->> 'decision', ''),
      NULLIF(correction ->> 'match', '')
    ),
    expected_confidence => COALESCE(
      NULLIF(correction ->> 'expected_confidence', ''),
      NULLIF(correction ->> 'confidence', '')
    ),
    expected_action_type => COALESCE(
      NULLIF(correction ->> 'expected_action_type', ''),
      NULLIF(correction ->> 'action_type', '')
    ),
    reason => correct_action.reason,
    label_source => 'manual_correction'
  );
END;
$$;

CREATE FUNCTION otlet.export_eval_cases(max_rows integer DEFAULT 1000)
RETURNS TABLE (
  label_id bigint,
  fixture_source text,
  case_kind text,
  manual_gold boolean,
  source_table text,
  subject_id text,
  source_hash text,
  expected_answer text,
  expected_confidence text,
  expected_action_type text,
  label_source text,
  reason text,
  action_id bigint,
  output_id bigint,
  receipt_id bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    l.id,
    'otlet_eval_labels_generated'::text,
    CASE
      WHEN l.label_source = 'manual_correction' THEN 'gold'
      WHEN declared.action_answer IS NOT NULL
        AND l.expected_answer <> declared.action_answer THEN 'false_trusted'
      WHEN l.expected_answer = ANY(contract.abstain_values) THEN 'abstention'
      WHEN l.expected_answer = contract.primary_answer THEN 'positive'
      WHEN contract.primary_answer IS NOT NULL THEN 'hard_negative'
      ELSE 'gold'
    END,
    l.label_source = 'manual_correction',
    l.source_table,
    l.subject_id,
    l.source_hash,
    l.expected_answer,
    l.expected_confidence,
    l.expected_action_type,
    l.label_source,
    l.reason,
    l.action_id,
    l.output_id,
    l.receipt_id,
    l.created_at
  FROM otlet.eval_labels l
  LEFT JOIN otlet.actions a ON a.id = l.action_id
  LEFT JOIN otlet.jobs j ON j.id = a.job_id
  LEFT JOIN otlet.tasks t ON t.name = j.task_name
  LEFT JOIN LATERAL (
    SELECT
      COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS answer_field,
      COALESCE(
        (
          SELECT array_agg(value)
          FROM jsonb_array_elements_text(COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb)) AS abstain(value)
        ),
        ARRAY[]::text[]
      ) AS abstain_values,
      (
        SELECT value
        FROM unnest(otlet.output_schema_enum_values(t.output_schema, COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match'))) WITH ORDINALITY AS answer(value, ord)
        WHERE NOT value = ANY(
          COALESCE(
            (
              SELECT array_agg(abstain_value)
              FROM jsonb_array_elements_text(COALESCE(t.decision_contract -> 'abstain_values', '[]'::jsonb)) AS abstain(abstain_value)
            ),
            ARRAY[]::text[]
          )
        )
        ORDER BY ord
        LIMIT 1
      ) AS primary_answer
  ) contract ON true
  LEFT JOIN LATERAL (
    SELECT otlet.action_declared_answer(COALESCE(NULLIF(l.expected_action_type, ''), a.action_type), contract.answer_field) AS action_answer
  ) declared ON true
  ORDER BY l.created_at DESC, l.id DESC
  LIMIT GREATEST(0, LEAST(COALESCE(max_rows, 1000), 100000));
$$;
