log "Checking Postgres-owned portable result validation"
cleanup_task "portable_validation_demo"
cleanup_task "portable_unsupported_demo"
cleanup_task "portable_stale_demo"

psql_exec -qAt -v model_name="$strong_model_name" >/dev/null <<'SQL'
DROP TABLE IF EXISTS public.otlet_demo_portable_source;
CREATE TABLE public.otlet_demo_portable_source (
  id text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO public.otlet_demo_portable_source VALUES ('stale-1', 'before');
CREATE TEMP TABLE portable_validation_params AS
SELECT :'model_name'::text AS model_name;

DO $$
BEGIN
  BEGIN
    PERFORM otlet.create_task(
      'portable_unsupported_demo',
      NULL,
      'Unsupported schema probe',
      '{"oneOf":[{"type":"string"},{"type":"number"}]}'::jsonb,
      (SELECT model_name FROM portable_validation_params)
    );
    RAISE EXCEPTION 'unsupported schema was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uses unsupported keyword oneOf%' THEN
      RAISE;
    END IF;
  END;
END
$$;

SELECT otlet.create_task(
  'portable_validation_demo',
  NULL,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"type":"string","enum":["ok"],"maxLength":2}}}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb
);

DO $$
DECLARE
  selected_job otlet.jobs%ROWTYPE;
  wrong_model text;
BEGIN
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token
  )
  VALUES (
    'portable_validation_demo', 'identity', '{}'::jsonb,
    'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text
  )
  RETURNING * INTO selected_job;

  SELECT name INTO wrong_model
  FROM otlet.models
  WHERE name <> (SELECT model_name FROM portable_validation_params)
  ORDER BY name
  LIMIT 1;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]',
      '[]',
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'malformed raw output was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%raw output is malformed JSON%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"bad"}',
      '{"output":{"status":"bad"},"actions":[]}',
      '[]',
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'schema-invalid output was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%schema validation failed%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      prompt_hash => repeat('0', 64),
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'forged prompt hash was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%prompt hash is forged%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      input_hash => repeat('1', 64),
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'forged input hash was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%input hash is forged%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      output_schema_hash => repeat('2', 64),
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'forged schema hash was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%output schema hash is forged%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      raw_output_hash => repeat('3', 64),
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'forged raw hash was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%raw output hash is forged%' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      trace_summary => '{"schema_validation_status":"passed","runtime_options_hash":"forged"}',
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'forged runtime hash was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%runtime hash is forged%' THEN RAISE; END IF;
  END;

  IF wrong_model IS NOT NULL THEN
    BEGIN
      PERFORM * FROM otlet.complete_job(
        selected_job.id,
        '{"status":"ok"}',
        '{"output":{"status":"ok"},"actions":[]}',
        '[]',
        model_name => wrong_model,
        expected_claim_token => selected_job.claim_token
      );
      RAISE EXCEPTION 'forged model identity was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%model identity is forged%'
         AND SQLERRM NOT LIKE '%model identity does not match task selection role%' THEN
        RAISE;
      END IF;
    END;
  END IF;

  PERFORM * FROM otlet.complete_job(
    selected_job.id,
    '{"status":"ok"}',
    '{"output":{"status":"ok"},"actions":[]}',
    '[]',
    trace_summary => '{"schema_validation_status":"failed"}',
    model_name => (SELECT model_name FROM portable_validation_params),
    expected_claim_token => selected_job.claim_token
  );
END
$$;

INSERT INTO otlet.tasks (
  name, input_query, instruction, output_schema, model_name,
  runtime_options, input_shaping, decision_contract
)
VALUES (
  'portable_unsupported_demo', NULL, 'Unsupported stored schema',
  '{"oneOf":[{"type":"object"}]}'::jsonb, :'model_name',
  '{}'::jsonb, '{"source_fields":[]}'::jsonb, '{"action_types":[]}'::jsonb
);
DO $$
DECLARE
  selected_job otlet.jobs%ROWTYPE;
BEGIN
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token
  )
  VALUES (
    'portable_unsupported_demo', 'unsupported', '{}'::jsonb,
    'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text
  )
  RETURNING * INTO selected_job;
  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id, '{}'::jsonb, '{"output":{},"actions":[]}', '[]'::jsonb,
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'stored unsupported schema was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uses unsupported keyword oneOf%' THEN RAISE; END IF;
  END;
END
$$;

SELECT otlet.create_task(
  'portable_stale_demo',
  $$
    SELECT
      src.id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_portable_source',
          'subject_id', src.id,
          'ctid', src.ctid::text,
          'xmin', src.xmin::text
        ),
        'table', 'public.otlet_demo_portable_source',
        'row', jsonb_build_object('value', src.value)
      ) AS input
    FROM public.otlet_demo_portable_source src
  $$,
  'Return status ok and no actions',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  :'model_name',
  '{"max_tokens":16,"reasoning":"off","inference_cache":false}'::jsonb,
  '{"source_fields":["_otlet_mvcc","table","row"]}'::jsonb
);
DO $$
DECLARE
  selected_job otlet.jobs%ROWTYPE;
BEGIN
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token
  )
  SELECT
    'portable_stale_demo', q.subject_id, q.input,
    'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text
  FROM (
    SELECT
      src.id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_portable_source',
          'subject_id', src.id,
          'ctid', src.ctid::text,
          'xmin', src.xmin::text
        ),
        'table', 'public.otlet_demo_portable_source',
        'row', jsonb_build_object('value', src.value)
      ) AS input
    FROM public.otlet_demo_portable_source src
    WHERE src.id = 'stale-1'
  ) q
  RETURNING * INTO selected_job;

  UPDATE public.otlet_demo_portable_source SET value = 'after' WHERE id = 'stale-1';
  BEGIN
    PERFORM * FROM otlet.complete_job(
      selected_job.id,
      '{"status":"ok"}',
      '{"output":{"status":"ok"},"actions":[]}',
      '[]',
      expected_claim_token => selected_job.claim_token
    );
    RAISE EXCEPTION 'stale source result was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%source is stale%' THEN RAISE; END IF;
  END;
END
$$;

DO $$
DECLARE
  selected_job otlet.jobs%ROWTYPE;
BEGIN
  INSERT INTO otlet.jobs (
    task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token
  )
  VALUES (
    'portable_validation_demo', 'unauthorized-action', '{}'::jsonb,
    'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text
  )
  RETURNING * INTO selected_job;
  PERFORM * FROM otlet.complete_job(
    selected_job.id,
    '{"status":"ok"}',
    '{"output":{"status":"ok"},"actions":[{"type":"invented_action","body":{}}]}',
    '[{"type":"invented_action","body":{}}]',
    expected_claim_token => selected_job.claim_token
  );
END
$$;
SQL

psql_exec -qAt <<'SQL'
CREATE TEMP TABLE portable_validation_contract AS
SELECT (
  (SELECT count(*) FROM otlet.json_schema_support_report(
    '{"type":"object","required":["status"],"properties":{"status":{"type":"string"}}}'::jsonb
  )) || '|' ||
  (SELECT count(*) FROM otlet.json_schema_support_report(
    '{"oneOf":[{"type":"string"}]}'::jsonb
  ) WHERE keyword = 'oneOf') || '|' ||
  r.schema_validation_status || '|' ||
  (r.trace_summary ->> 'schema_validation_status') || '|' ||
  (r.trace_summary #>> '{portable_validation,version}') || '|' ||
  (length(r.task_identity_hash) = 64)::text || '|' ||
  (length(r.source_identity_hash) = 64)::text || '|' ||
  (length(r.model_identity_hash) = 64)::text || '|' ||
  (length(r.runtime_options_hash) = 64)::text || '|' ||
  (length(r.prompt_hash) = 64)::text || '|' ||
  (length(r.input_hash) = 64)::text || '|' ||
  (length(r.output_schema_hash) = 64)::text || '|' ||
  (length(r.output_hash) = 64)::text || '|' ||
  (length(r.actions_hash) = 64)::text || '|' ||
  a.status || '|' ||
  (a.error = 'action type invented_action is not allowed by workflow')::text
) AS value
FROM otlet.inference_receipts r
JOIN otlet.jobs j ON j.id = r.job_id
CROSS JOIN LATERAL (
  SELECT action_row.status, action_row.error
  FROM otlet.actions action_row
  JOIN otlet.jobs action_job ON action_job.id = action_row.job_id
  WHERE action_job.task_name = 'portable_validation_demo'
    AND action_job.subject_id = 'unauthorized-action'
  LIMIT 1
) a
WHERE j.task_name = 'portable_validation_demo'
  AND j.subject_id = 'identity';

DO $$
DECLARE
  actual text;
BEGIN
  SELECT value INTO actual FROM portable_validation_contract;
  IF actual IS DISTINCT FROM '0|1|passed|passed|otlet_portable_validation_v1|true|true|true|true|true|true|true|true|true|rejected|true' THEN
    RAISE EXCEPTION 'unexpected portable validation contract: %', actual;
  END IF;
END
$$;

SELECT 'portable_validation_contract=' || value
FROM portable_validation_contract;
SQL

cleanup_task "portable_validation_demo"
cleanup_task "portable_unsupported_demo"
cleanup_task "portable_stale_demo"
psql_exec -qAt -c "DROP TABLE IF EXISTS public.otlet_demo_portable_source" >/dev/null
