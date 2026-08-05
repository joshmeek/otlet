log "Checking evidence boundaries"

source_allowlist_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE source_allowlist_results(name text PRIMARY KEY, passed boolean NOT NULL);

CREATE TEMP TABLE evidence_source_single_task AS SELECT otlet.create_task(
  'evidence_source_single_demo',
  NULL,
  'Source allowlist proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
DO $$
BEGIN
  PERFORM otlet.admit_task_input(
    'evidence_source_single_demo',
    'single',
    '{"approved":"ok","unapproved":"SENSITIVE-FIXTURE-SOURCE"}'::jsonb
  );
  INSERT INTO source_allowlist_results VALUES ('single', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO source_allowlist_results VALUES (
    'single',
    SQLERRM LIKE '%outside the task source-field allowlist%'
  );
END;
$$;

CREATE TEMP TABLE evidence_source_bulk_task AS SELECT otlet.create_task(
  'evidence_source_bulk_demo',
  'SELECT ''bulk''::text AS subject_id,
          ''{"approved":"ok","unapproved":"SENSITIVE-FIXTURE-BULK"}''::jsonb AS input',
  'Source allowlist proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
DO $$
BEGIN
  PERFORM otlet.run_task('evidence_source_bulk_demo');
  INSERT INTO source_allowlist_results VALUES ('bulk', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO source_allowlist_results VALUES (
    'bulk',
    SQLERRM LIKE '%outside the task source-field allowlist%'
  );
END;
$$;

CREATE TEMP TABLE evidence_source_claim_task AS SELECT otlet.create_task(
  'evidence_source_claim_demo',
  NULL,
  'Source claim proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  input_shaping => '{"source_fields":["approved"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('evidence_source_claim_demo', 'claim', '{"approved":"ok"}'::jsonb);
UPDATE otlet.tasks
SET input_shaping = '{"source_fields":[]}'::jsonb
WHERE name = 'evidence_source_claim_demo';
CREATE TEMP TABLE evidence_claimed AS SELECT * FROM otlet.claim_jobs();

CREATE TABLE public.otlet_evidence_row_source (
  id text PRIMARY KEY,
  approved text NOT NULL,
  unapproved text NOT NULL
);
INSERT INTO public.otlet_evidence_row_source
VALUES ('row-1', 'visible', 'SENSITIVE-FIXTURE-ROW');
CREATE TEMP TABLE evidence_row_watch AS SELECT otlet.create_watch(
  watch_name => 'evidence_row_allowlist_demo',
  kind => 'row',
  table_name => 'public.otlet_evidence_row_source'::regclass,
  subject_column => 'id',
  input_columns => ARRAY['id', 'approved'],
  instruction => 'Return an empty object',
  output_schema => '{"type":"object"}'::jsonb,
  model_name => :'model_name'
);
CREATE TEMP TABLE evidence_row_run AS SELECT otlet.run_task('evidence_row_allowlist_demo_task');

SELECT
  (SELECT bool_and(passed) FROM source_allowlist_results)::text || '|' ||
  (SELECT count(*) = 0 FROM otlet.jobs WHERE task_name IN ('evidence_source_single_demo', 'evidence_source_bulk_demo'))::text || '|' ||
  (SELECT count(*) = 1 FROM evidence_claimed)::text || '|' ||
  (SELECT status = 'running' AND input = '{"approved":"ok"}'::jsonb FROM otlet.jobs WHERE task_name = 'evidence_source_claim_demo')::text || '|' ||
  (SELECT input_columns = ARRAY['approved', 'id']::text[] FROM otlet.semantic_indexes WHERE name = 'evidence_row_allowlist_demo')::text || '|' ||
  (SELECT (input #> '{row}') ? 'approved'
          AND NOT ((input #> '{row}') ? 'unapproved')
   FROM otlet.jobs WHERE task_name = 'evidence_row_allowlist_demo_task')::text;
ROLLBACK;
SQL
}
source_allowlist_contract="$(source_allowlist_contract_sql)"
unset -f source_allowlist_contract_sql
echo "source_allowlist_contract=$source_allowlist_contract"
[ "$source_allowlist_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected source allowlists on single, bulk, claim, and row-watch paths, got $source_allowlist_contract" >&2
  exit 1
}

decision_evidence_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE decision_evidence_results(
  name text PRIMARY KEY,
  passed boolean NOT NULL
);
CREATE TEMP TABLE decision_evidence_task AS SELECT otlet.create_task(
  task_name => 'decision_evidence_demo',
  input_query => NULL,
  instruction => 'Return a decision with source paths',
  output_schema => '{
    "type":"object",
    "required":["decision","evidence"],
    "additionalProperties":false,
    "properties":{
      "decision":{"type":"string"},
      "evidence":{
        "type":"array",
        "maxItems":32,
        "items":{
          "type":"array",
          "minItems":1,
          "maxItems":16,
          "items":{"type":"string","minLength":1,"maxLength":128}
        }
      }
    }
  }'::jsonb,
  model_name => :'model_name',
  input_shaping => '{
    "source_fields":["approved","approved_id"],
    "action_id_fields":{"subject_id":"approved_id"}
  }'::jsonb,
  decision_contract => '{
    "action_types":["review_flag"],
    "redact_output_fields":["evidence"],
    "redact_action_fields":["evidence"]
  }'::jsonb
);

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
) VALUES (
  'decision_evidence_demo',
  'accepted',
  '{
    "approved":{
      "aliases":[{"value":"ACME"},{"value":"Acme Inc"}]
    },
    "approved_id":"accepted"
  }'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  'decision-evidence-accepted'
) RETURNING id \gset decision_evidence_

CREATE TEMP TABLE decision_evidence_payload AS
WITH payload(output, actions) AS (VALUES (
  '{
    "decision":"review",
    "evidence":[
      ["approved","aliases","0","value"],
      ["approved","aliases","0","value"]
    ]
  }'::jsonb,
  '[
    {
      "type":"review_flag",
      "body":{"reason":"review first"}
    },
    {
      "type":"review_flag",
      "body":{
        "reason":"review second",
        "evidence":[["approved","aliases","1","value"]]
      }
    }
  ]'::jsonb
))
SELECT
  output,
  jsonb_build_object('output', output, 'actions', actions)::text AS raw_output,
  actions
FROM payload;

UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'diagnostic'
WHERE name = 'default';
CREATE TEMP TABLE decision_evidence_completed AS
SELECT count(*) AS output_count
FROM decision_evidence_payload payload
CROSS JOIN LATERAL otlet.complete_job(
  :decision_evidence_id,
  payload.output,
  payload.raw_output,
  payload.actions,
  expected_claim_token => 'decision-evidence-accepted'
) completed;

CREATE TEMP TABLE decision_evidence_retried AS
SELECT count(*) AS output_count
FROM decision_evidence_payload payload
CROSS JOIN LATERAL otlet.complete_job(
  :decision_evidence_id,
  payload.output,
  payload.raw_output,
  payload.actions,
  expected_claim_token => 'decision-evidence-accepted'
) completed;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
) VALUES (
  'decision_evidence_demo',
  'missing',
  '{
    "approved":{"aliases":[{"value":"present"}]},
    "approved_id":"missing"
  }'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  'decision-evidence-missing'
);
DO $$
BEGIN
  BEGIN
    PERFORM *
    FROM otlet.complete_job(
      (
        SELECT id FROM otlet.jobs
        WHERE task_name = 'decision_evidence_demo'
          AND subject_id = 'missing'
      ),
      '{
        "decision":"review",
        "evidence":[["approved","aliases","9","value"]]
      }'::jsonb,
      '{
        "output":{
          "decision":"review",
          "evidence":[["approved","aliases","9","value"]]
        },
        "actions":[]
      }',
      '[]'::jsonb,
      expected_claim_token => 'decision-evidence-missing'
    );
    INSERT INTO decision_evidence_results VALUES ('missing', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'missing',
      SQLERRM = 'otlet decision evidence path does not exist in shaped input'
    );
  END;
END;
$$;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
) VALUES (
  'decision_evidence_demo',
  'disallowed',
  '{
    "approved":{"aliases":[{"value":"present"}]},
    "approved_id":"disallowed"
  }'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  'decision-evidence-disallowed'
);
DO $$
BEGIN
  BEGIN
    PERFORM *
    FROM otlet.complete_job(
      (
        SELECT id FROM otlet.jobs
        WHERE task_name = 'decision_evidence_demo'
          AND subject_id = 'disallowed'
      ),
      '{
        "decision":"review",
        "evidence":[["action_ids","subject_id"]]
      }'::jsonb,
      '{
        "output":{
          "decision":"review",
          "evidence":[["action_ids","subject_id"]]
        },
        "actions":[]
      }',
      '[]'::jsonb,
      expected_claim_token => 'decision-evidence-disallowed'
    );
    INSERT INTO decision_evidence_results VALUES ('disallowed', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'disallowed',
      SQLERRM = 'otlet decision evidence path is outside input_shaping.source_fields'
    );
  END;
END;
$$;

INSERT INTO decision_evidence_results
SELECT
  'path_order',
  jsonb_array_length(otlet.decision_evidence_path_links(
    '[["a","b"],["b","a"]]'::jsonb,
    '{"a":{"b":"x"},"b":{"a":"x"}}'::jsonb,
    '{"source_fields":["a","b"]}'::jsonb,
    'output'
  )) = 2;

DO $$
DECLARE
  evidence_refs jsonb;
BEGIN
  SELECT jsonb_agg(jsonb_build_array('approved', value::text))
  INTO evidence_refs
  FROM generate_series(1, 33) value;
  BEGIN
    PERFORM otlet.decision_evidence_path_links(
      evidence_refs,
      '{}'::jsonb,
      '{"source_fields":["approved"]}'::jsonb,
      'output'
    );
    INSERT INTO decision_evidence_results VALUES ('path_count', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'path_count',
      SQLERRM = 'otlet decision evidence exceeds 32 paths'
    );
  END;
END;
$$;

DO $$
DECLARE
  evidence_path jsonb;
BEGIN
  SELECT jsonb_agg(to_jsonb('segment'::text))
  INTO evidence_path
  FROM generate_series(1, 17);
  BEGIN
    PERFORM otlet.decision_evidence_path_links(
      jsonb_build_array(evidence_path),
      '{}'::jsonb,
      '{"source_fields":["segment"]}'::jsonb,
      'output'
    );
    INSERT INTO decision_evidence_results VALUES ('path_segments', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'path_segments',
      SQLERRM = 'otlet decision evidence path must contain 1 to 16 text segments'
    );
  END;
END;
$$;

DO $$
DECLARE
  path_segments text[] := ARRAY[]::text[];
  shaped_input jsonb := '"present"'::jsonb;
  segment_index integer;
BEGIN
  FOR segment_index IN 1..16 LOOP
    path_segments := array_append(path_segments, 's' || segment_index::text);
  END LOOP;
  FOR segment_index IN REVERSE 16..1 LOOP
    shaped_input := jsonb_build_object(
      's' || segment_index::text,
      shaped_input
    );
  END LOOP;
  INSERT INTO decision_evidence_results
  SELECT
    'path_segment_limit',
    jsonb_array_length(otlet.decision_evidence_path_links(
      jsonb_build_array(to_jsonb(path_segments)),
      shaped_input,
      '{"source_fields":["s1"]}'::jsonb,
      'output'
    )) = 1;
END;
$$;

DO $$
DECLARE
  exact_segment text := repeat('é', 64);
  oversized_segment text := repeat('é', 64) || 'a';
  exact_accepted boolean;
BEGIN
  exact_accepted := jsonb_array_length(otlet.decision_evidence_path_links(
    jsonb_build_array(jsonb_build_array(exact_segment)),
    jsonb_build_object(exact_segment, 'present'),
    jsonb_build_object('source_fields', jsonb_build_array(exact_segment)),
    'output'
  )) = 1;
  BEGIN
    PERFORM otlet.decision_evidence_path_links(
      jsonb_build_array(jsonb_build_array(oversized_segment)),
      jsonb_build_object(oversized_segment, 'present'),
      jsonb_build_object(
        'source_fields',
        jsonb_build_array(oversized_segment)
      ),
      'output'
    );
    INSERT INTO decision_evidence_results VALUES ('segment_bytes', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'segment_bytes',
      exact_accepted
      AND SQLERRM =
        'otlet decision evidence path segment must contain 1 to 128 bytes'
    );
  END;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM otlet.decision_evidence_path_links(
      '[["approved","aliases","01"]]'::jsonb,
      '{"approved":{"aliases":["present"]}}'::jsonb,
      '{"source_fields":["approved"]}'::jsonb,
      'output'
    );
    INSERT INTO decision_evidence_results VALUES ('array_index', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'array_index',
      SQLERRM = 'otlet decision evidence array path is invalid'
    );
  END;
END;
$$;

DO $$
DECLARE
  evidence_refs jsonb;
  approved jsonb;
  actions jsonb;
  exact_accepted boolean;
BEGIN
  SELECT jsonb_agg(jsonb_build_array('approved', value::text)),
         jsonb_object_agg(value::text, to_jsonb(value))
  INTO evidence_refs, approved
  FROM generate_series(1, 32) value;
  SELECT jsonb_agg(jsonb_build_object(
    'body', jsonb_build_object('evidence', evidence_refs)
  ))
  INTO actions
  FROM generate_series(1, 3);
  exact_accepted := jsonb_array_length(otlet.validated_decision_evidence(
    jsonb_build_object('evidence', evidence_refs),
    actions,
    jsonb_build_object('approved', approved),
    '{"source_fields":["approved"]}'::jsonb,
    'otlet_decision_evidence_v1'
  )) = 128;
  SELECT jsonb_agg(jsonb_build_object(
    'body', jsonb_build_object('evidence', evidence_refs)
  ))
  INTO actions
  FROM generate_series(1, 4);
  BEGIN
    PERFORM otlet.validated_decision_evidence(
      jsonb_build_object('evidence', evidence_refs),
      actions,
      jsonb_build_object('approved', approved),
      '{"source_fields":["approved"]}'::jsonb,
      'otlet_decision_evidence_v1'
    );
    INSERT INTO decision_evidence_results VALUES ('result_paths', false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO decision_evidence_results VALUES (
      'result_paths',
      exact_accepted
      AND SQLERRM = 'otlet decision evidence exceeds 128 paths per result'
    );
  END;
END;
$$;

INSERT INTO decision_evidence_results
SELECT
  'revision_version',
  otlet.validated_decision_evidence(
    '{"evidence":[["approved"]]}'::jsonb,
    '[]'::jsonb,
    '{"approved":"present"}'::jsonb,
    '{"source_fields":["approved"]}'::jsonb,
    NULL
  ) = '[]'::jsonb;

CREATE TEMP TABLE decision_evidence_before_cleanup AS
SELECT trace_summary #> '{portable_validation,decision_evidence}' AS links
FROM otlet.inference_receipts
WHERE job_id = :decision_evidence_id;
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'redacted'
WHERE name = 'default';
UPDATE otlet.inference_receipts
SET finished_at = now() - interval '2 days'
WHERE job_id = :decision_evidence_id;
CREATE TEMP TABLE decision_evidence_cleanup AS
SELECT * FROM otlet.cleanup_policy_state(false);

SELECT concat_ws('|',
  (SELECT output_count = 1 FROM decision_evidence_completed),
  (SELECT output_count = 1 FROM decision_evidence_retried),
  (SELECT count(*) = 1 FROM otlet.inference_receipts
   WHERE job_id = :decision_evidence_id),
  (SELECT count(*) = 1 FROM otlet.outputs
   WHERE job_id = :decision_evidence_id),
  (SELECT count(*) = 2 FROM otlet.actions
   WHERE job_id = :decision_evidence_id),
  (SELECT count(*) = 2
          AND count(*) FILTER (WHERE target_kind = 'output') = 1
          AND count(*) FILTER (WHERE target_kind = 'action') = 1
          AND count(*) FILTER (
            WHERE target_kind = 'action'
              AND action_index = 1
              AND EXISTS (
                SELECT 1
                FROM otlet.actions action
                WHERE action.id = evidence.action_id
                  AND action.payload #>> '{body,reason}' = 'review second'
              )
          ) = 1
   FROM otlet.audit_decision_evidence_export evidence
   WHERE evidence.job_id = :decision_evidence_id),
  (SELECT output #>> '{evidence}' = '[REDACTED]'
   FROM otlet.outputs
   WHERE job_id = :decision_evidence_id)
    AND
  (SELECT count(*) = 1
   FROM otlet.actions
   WHERE job_id = :decision_evidence_id
     AND payload #>> '{body,reason}' = 'review second'
     AND payload #>> '{body,evidence}' = '[REDACTED]'),
  (SELECT value_hash = otlet.identity_hash(
            'decision_evidence_value',
            '"ACME"'::jsonb
          )
          AND evidence_path = ARRAY[
            'approved','aliases','0','value'
          ]::text[]
   FROM otlet.audit_decision_evidence_export
   WHERE job_id = :decision_evidence_id
     AND target_kind = 'output'),
  (SELECT value_hash = otlet.identity_hash(
            'decision_evidence_value',
            '"Acme Inc"'::jsonb
          )
          AND evidence_path = ARRAY[
            'approved','aliases','1','value'
          ]::text[]
   FROM otlet.audit_decision_evidence_export
   WHERE job_id = :decision_evidence_id
     AND target_kind = 'action'),
  (SELECT trace_summary #>
            '{portable_validation,decision_evidence}' =
          otlet.redact_trace_summary(trace_summary, 'redacted') #>
            '{portable_validation,decision_evidence}'
          AND trace_summary #> '{portable_validation,decision_evidence}' =
            (SELECT links FROM decision_evidence_before_cleanup)
          AND raw_output IS NULL
          AND (SELECT sensitive_raw_outputs >= 1 AND NOT dry_run
               FROM decision_evidence_cleanup)
          AND trace_summary::text NOT LIKE '%ACME%'
          AND trace_summary::text NOT LIKE '%Acme Inc%'
   FROM otlet.inference_receipts
   WHERE job_id = :decision_evidence_id),
  (SELECT trace_summary #>>
            '{portable_validation,decision_evidence_version}' =
          revision.definition #>> '{validator,decision_evidence_version}'
          AND revision.definition #>>
            '{validator,decision_evidence_version}' =
            'otlet_decision_evidence_v1'
   FROM otlet.inference_receipts receipt
   JOIN otlet.workload_revisions revision
     ON revision.task_name = receipt.task_name
    AND revision.workload_revision_hash = receipt.workload_revision_hash
   WHERE receipt.job_id = :decision_evidence_id),
  (SELECT bool_and(passed) FROM decision_evidence_results),
  (SELECT bool_and(
      status = 'running'
      AND claim_token = CASE subject_id
        WHEN 'missing' THEN 'decision-evidence-missing'
        WHEN 'disallowed' THEN 'decision-evidence-disallowed'
      END
    )
   FROM otlet.jobs
   WHERE task_name = 'decision_evidence_demo'
     AND subject_id IN ('missing', 'disallowed')),
  (SELECT count(*) = 0
   FROM otlet.inference_receipts receipt
   JOIN otlet.jobs job ON job.id = receipt.job_id
   WHERE job.task_name = 'decision_evidence_demo'
     AND job.subject_id IN ('missing', 'disallowed')),
  (SELECT count(*) = 0
   FROM otlet.outputs output
   JOIN otlet.jobs job ON job.id = output.job_id
   WHERE job.task_name = 'decision_evidence_demo'
     AND job.subject_id IN ('missing', 'disallowed')),
  (SELECT count(*) = 0
   FROM otlet.actions action
   JOIN otlet.jobs job ON job.id = action.job_id
   WHERE job.task_name = 'decision_evidence_demo'
     AND job.subject_id IN ('missing', 'disallowed')),
  (SELECT export_views @>
      ARRAY['otlet.audit_decision_evidence_export']::text[]
      AND policy_version = 6
   FROM otlet.redaction_policy_status)
);
ROLLBACK;
SQL
}
decision_evidence_contract="$(decision_evidence_contract_sql)"
unset -f decision_evidence_contract_sql
echo "decision_evidence_contract=$decision_evidence_contract"
[ "$decision_evidence_contract" = \
  "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ] || {
  echo "Expected validated output and action evidence links without copied source values, got $decision_evidence_contract" >&2
  exit 1
}

evidence_bound_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE evidence_bound_results(name text PRIMARY KEY, passed boolean NOT NULL);
CREATE TEMP TABLE evidence_bound_task AS SELECT otlet.create_task(
  'evidence_bound_demo',
  NULL,
  'Evidence bound proof',
  '{"type":"object"}'::jsonb,
  :'model_name'
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
VALUES ('evidence_bound_demo', 'bound', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text)
RETURNING id \gset bound_

UPDATE otlet.production_policy SET max_raw_output_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    raw_output => repeat('x', 17),
    selection_status => 'failed',
    expected_claim_token => otlet.jobs.claim_token
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('raw_output', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('raw_output', SQLERRM LIKE '%raw output exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_raw_output_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_structured_output_bytes = 32 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    jsonb_build_object('payload', repeat('x', 64)),
    '{}',
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE task_name = 'evidence_bound_demo')
  );
  INSERT INTO evidence_bound_results VALUES ('structured_output', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('structured_output', SQLERRM LIKE '%structured output exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_structured_output_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_action_bytes = 64 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    '{"match":"unclear"}'::jsonb,
    '{}',
    jsonb_build_array(jsonb_build_object(
      'type', 'review_flag',
      'body', jsonb_build_object('reason', repeat('x', 80))
    )),
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE task_name = 'evidence_bound_demo')
  );
  INSERT INTO evidence_bound_results VALUES ('action_bytes', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('action_bytes', SQLERRM LIKE '%action exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_action_bytes = 65536 WHERE name = 'default';

UPDATE otlet.production_policy SET max_actions_per_job = 0 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.complete_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    '{"match":"unclear"}'::jsonb,
    '{}',
    '[{"type":"review_flag","body":{"reason":"review"}}]'::jsonb,
    trace_summary => '{"schema_validation_status":"passed"}'::jsonb,
    expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE task_name = 'evidence_bound_demo')
  );
  INSERT INTO evidence_bound_results VALUES ('action_count', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('action_count', SQLERRM LIKE '%actions exceed%');
END;
$$;
UPDATE otlet.production_policy SET max_actions_per_job = 64 WHERE name = 'default';

UPDATE otlet.production_policy SET max_trace_bytes = 64 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    trace_summary => jsonb_build_object('trace', repeat('x', 80)),
    selection_status => 'failed',
    expected_claim_token => otlet.jobs.claim_token
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('trace', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('trace', SQLERRM LIKE '%trace exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_trace_bytes = 1048576 WHERE name = 'default';

UPDATE otlet.production_policy SET max_error_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM * FROM otlet.fail_job(
    (SELECT id FROM otlet.jobs WHERE task_name = 'evidence_bound_demo'),
    repeat('x', 17),
    expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE task_name = 'evidence_bound_demo')
  );
  INSERT INTO evidence_bound_results VALUES ('error', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('error', SQLERRM LIKE '%error exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_error_bytes = 4096 WHERE name = 'default';

UPDATE otlet.production_policy SET max_event_message_bytes = 16 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_worker_event('evidence_bound_message', message => repeat('x', 17));
  INSERT INTO evidence_bound_results VALUES ('event_message', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('event_message', SQLERRM LIKE '%event message exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_event_message_bytes = 4096 WHERE name = 'default';

UPDATE otlet.production_policy SET max_event_detail_bytes = 32 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_worker_event(
    'evidence_bound_detail',
    detail => jsonb_build_object('safe_metric', repeat('x', 40))
  );
  INSERT INTO evidence_bound_results VALUES ('event_detail', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('event_detail', SQLERRM LIKE '%event detail exceeds%');
END;
$$;
UPDATE otlet.production_policy SET max_event_detail_bytes = 262144 WHERE name = 'default';

UPDATE otlet.production_policy SET max_receipt_bytes = 512 WHERE name = 'default';
DO $$
BEGIN
  PERFORM otlet.record_model_attempt(
    otlet.jobs.id,
    otlet.tasks.model_name,
    selection_status => 'failed',
    expected_claim_token => otlet.jobs.claim_token
  )
  FROM otlet.jobs
  JOIN otlet.tasks ON otlet.tasks.name = otlet.jobs.task_name
  WHERE otlet.jobs.task_name = 'evidence_bound_demo';
  INSERT INTO evidence_bound_results VALUES ('receipt', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO evidence_bound_results VALUES ('receipt', SQLERRM LIKE '%receipt exceeds%');
END;
$$;

SELECT bool_and(passed)::text || '|' ||
       count(*)::text || '|' ||
       (SELECT status = 'running' FROM otlet.jobs WHERE id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.inference_receipts WHERE job_id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.outputs WHERE job_id = :bound_id)::text || '|' ||
       (SELECT count(*) = 0 FROM otlet.actions WHERE job_id = :bound_id)::text
FROM evidence_bound_results;
ROLLBACK;
SQL
}
evidence_bound_contract="$(evidence_bound_contract_sql)"
unset -f evidence_bound_contract_sql
echo "evidence_bound_contract=$evidence_bound_contract"
[ "$evidence_bound_contract" = "true|9|true|true|true|true" ] || {
  echo "Expected every stored evidence family to fail closed at its bound, got $evidence_bound_contract" >&2
  exit 1
}

evidence_redaction_contract_sql() {
  psql_value -v model_name="$cheap_model_name" <<'SQL'
BEGIN;
CREATE TEMP TABLE evidence_redaction_task AS SELECT otlet.create_task(
  'evidence_redaction_demo',
  NULL,
  'Evidence redaction proof',
  '{"type":"object"}'::jsonb,
  :'model_name',
  decision_contract => '{
    "redact_output_fields":["sensitive_note"],
    "redact_action_fields":["reason","sensitive_note"],
    "identity_fields":["case_id"],
    "action_types":["review_flag"]
  }'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
VALUES ('evidence_redaction_demo', 'redaction', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text)
RETURNING id \gset redaction_
CREATE TEMP TABLE evidence_redaction_completed AS SELECT count(*)
FROM otlet.complete_job(
  :redaction_id,
  '{"match":"unclear","case_id":"case-1","sensitive_note":"SENSITIVE-FIXTURE-OUTPUT"}'::jsonb,
  '{"output":{"match":"unclear","case_id":"case-1","sensitive_note":"SENSITIVE-FIXTURE-OUTPUT"},"actions":[{"type":"review_flag","body":{"left_id":"left-1","right_id":"right-1","reason":"SENSITIVE-FIXTURE-REASON","sensitive_note":"SENSITIVE-FIXTURE-ACTION"}}]}',
  '[{
    "type":"review_flag",
    "body":{
      "left_id":"left-1",
      "right_id":"right-1",
      "reason":"SENSITIVE-FIXTURE-REASON",
      "sensitive_note":"SENSITIVE-FIXTURE-ACTION"
    }
  }]'::jsonb,
  trace_summary => '{
    "schema_validation_status":"passed",
    "input":{"sensitive_note":"SENSITIVE-FIXTURE-TRACE"}
  }'::jsonb,
  model_name => :'model_name',
  expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE id = :redaction_id)
);
DO $$
BEGIN
  PERFORM otlet.record_worker_event(
    'evidence_redaction_probe',
    detail => '{
      "model_name":"probe",
      "input":{"sensitive_note":"SENSITIVE-FIXTURE-EVENT"}
    }'::jsonb
  );
END;
$$;

INSERT INTO otlet.jobs (
  task_name,
  subject_id,
  input,
  status,
  attempts,
  started_at,
  leased_until,
  claim_token
)
VALUES (
  'evidence_redaction_demo',
  'failure-redaction',
  '{}'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  gen_random_uuid()::text
)
RETURNING id \gset failure_
CREATE TEMP TABLE evidence_redaction_failed AS SELECT *
FROM otlet.fail_job(
  :failure_id,
  'SENSITIVE-FIXTURE-ERROR',
  model_name => :'model_name',
  expected_claim_token => (
    SELECT claim_token FROM otlet.jobs WHERE id = :failure_id
  )
);
WITH owner_role AS (
  SELECT oid
  FROM pg_catalog.pg_roles
  WHERE rolname = session_user
)
UPDATE otlet.jobs
SET application_owner_role_oid = owner_role.oid,
    application_authenticated_role_oid = owner_role.oid,
    application_invocation_role_oid = owner_role.oid,
    application_request_payload_hash = otlet.identity_hash(
      'application_request',
      '{"proof":"evidence_redaction"}'::jsonb
    )
FROM owner_role
WHERE id = :failure_id;

SELECT
  (SELECT output ->> 'case_id' = 'case-1'
          AND output ->> 'sensitive_note' = '[REDACTED]'
   FROM otlet.outputs WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT payload #>> '{body,left_id}' = 'left-1'
          AND payload #>> '{body,right_id}' = 'right-1'
          AND payload #>> '{body,reason}' = '[REDACTED]'
          AND payload #>> '{body,sensitive_note}' = '[REDACTED]'
   FROM otlet.actions WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT raw_output IS NULL
          AND trace_summary -> 'input' IS NULL
          AND trace_summary #>> '{evidence_redaction,structured_output}' = 'true'
          AND trace_summary #>> '{evidence_redaction,actions}' = 'true'
   FROM otlet.inference_receipts WHERE job_id = :redaction_id)::text || '|' ||
  (SELECT detail #>> '{input}' = '[REDACTED]'
   FROM otlet.worker_events WHERE event_type = 'evidence_redaction_probe')::text || '|' ||
  (SELECT structured_output_redacted AND actions_redacted
   FROM otlet.audit_receipt_export WHERE job_id = :redaction_id)::text || '|' ||
  ((SELECT bool_and(to_jsonb(surface)::text NOT LIKE '%SENSITIVE-FIXTURE%')
   FROM (
     SELECT to_jsonb(log_row) AS surface FROM otlet.operational_event_log log_row
     UNION ALL SELECT to_jsonb(metric_row) FROM otlet.worker_batch_timing_status metric_row
     UNION ALL SELECT to_jsonb(permission_row) FROM otlet.access_policy_status permission_row
     UNION ALL SELECT to_jsonb(redaction_row) FROM otlet.redaction_policy_status redaction_row
     UNION ALL SELECT to_jsonb(receipt_row) FROM otlet.audit_receipt_export receipt_row
     UNION ALL SELECT to_jsonb(evidence_row) FROM otlet.audit_decision_evidence_export evidence_row
     UNION ALL SELECT to_jsonb(review_row) FROM otlet.audit_review_export review_row
     UNION ALL SELECT to_jsonb(review_event_row) FROM otlet.audit_review_event_export review_event_row
     UNION ALL SELECT to_jsonb(failure_row) FROM otlet.failure_retry_status failure_row
       WHERE failure_row.job_id = :failure_id
     UNION ALL SELECT to_jsonb(application_row)
       FROM otlet.application_job_status(:failure_id) application_row
   ) surfaces)
   AND (SELECT count(*) = 2
        FROM otlet.failure_retry_status
        WHERE job_id = :failure_id)
   AND (SELECT count(*) = 1
        FROM otlet.application_job_status(:failure_id))
   AND (SELECT policy_version = 6
               AND withheld_fields @> ARRAY['job_error', 'receipt_error']::text[]
               AND export_views @> ARRAY[
                 'otlet.failure_retry_status',
                 'otlet.audit_decision_evidence_export'
               ]::text[]
        FROM otlet.redaction_policy_status))::text;
ROLLBACK;
SQL
}
evidence_redaction_contract="$(evidence_redaction_contract_sql)"
unset -f evidence_redaction_contract_sql
echo "evidence_redaction_contract=$evidence_redaction_contract"
[ "$evidence_redaction_contract" = "true|true|true|true|true|true" ] || {
  echo "Expected structured redaction and source-free operational surfaces, got $evidence_redaction_contract" >&2
  exit 1
}
