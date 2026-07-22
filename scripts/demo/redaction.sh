log "Checking stored sensitive-evidence redaction"

redaction_result_file="$(mktemp "${TMPDIR:-/tmp}/otlet-redaction.XXXXXX")"
trap 'rm -f "$redaction_result_file"' EXIT

psql_value -v model_name="$strong_model_name" >"$redaction_result_file" <<'SQL'
BEGIN;
CREATE TEMP TABLE redaction_mode_constraint(ok boolean NOT NULL);
DO $$
BEGIN
  UPDATE otlet.production_policy
  SET sensitive_evidence_mode = 'invalid'
  WHERE name = 'default';
  INSERT INTO redaction_mode_constraint VALUES (false);
EXCEPTION WHEN check_violation THEN
  INSERT INTO redaction_mode_constraint VALUES (true);
END;
$$;
INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name, input_shaping)
VALUES (
  'redaction_contract',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'PROMPT-SENTINEL-🙂-DO-NOT-STORE',
  '{"type":"object"}'::jsonb,
  :'model_name',
  '{"source_fields":["secret"]}'::jsonb
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
VALUES (
  'redaction_contract',
  'redacted-write',
  '{"secret":"INPUT-SENTINEL-DO-NOT-COPY"}'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  gen_random_uuid()::text
)
RETURNING id \gset redacted_
SELECT id
FROM otlet.record_model_attempt(
  :redacted_id,
  :'model_name',
  output => '{"status":"review"}'::jsonb,
  raw_output => 'RAW-SENTINEL-🙂-DO-NOT-STORE',
  raw_output_hash => otlet.portable_text_hash('RAW-SENTINEL-🙂-DO-NOT-STORE'),
  prompt_hash => md5('PROMPT-SENTINEL-🙂-DO-NOT-STORE'),
  trace_summary => '{
    "schema_validation_status":"passed",
    "prompt":"PROMPT-SENTINEL-🙂-DO-NOT-STORE",
    "source_row":{"secret":"INPUT-SENTINEL-DO-NOT-COPY"},
    "detailed_trace":{
      "status":"available",
      "trace_contract":"receipt_trace_v2_bounded_token_steps",
      "chosen_text":"CHOSEN-SENTINEL-DO-NOT-STORE",
      "chosen_token_ids":[42],
      "captured_tokens":1,
      "top_k":1,
      "steps":[{
        "step":1,
        "token_id":42,
        "token_text":"TOKEN-SENTINEL-DO-NOT-STORE",
        "chosen_probability":0.9,
        "top_alternatives":[{
          "rank":1,
          "token_id":43,
          "token_text":"ALT-SENTINEL-DO-NOT-STORE",
          "probability":0.1
        }]
      }]
    }
  }'::jsonb,
  schema_validation_status => 'passed',
  selection_status => 'rejected',
  selection_reason => 'redaction_contract',
  expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE id = :redacted_id)
) \gset redacted_receipt_
SELECT assembled_prompt_storage || '|' ||
       (SELECT ok FROM redaction_mode_constraint)::text || '|' ||
       (r.raw_output IS NULL)::text || '|' ||
       (r.raw_output_hash = otlet.portable_text_hash('RAW-SENTINEL-🙂-DO-NOT-STORE'))::text || '|' ||
       (r.candidate_output = '{"status":"review"}'::jsonb)::text || '|' ||
       (r.trace_summary #>> '{detailed_trace,chosen_text}' IS NULL)::text || '|' ||
       (NOT jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].token_text'))::text || '|' ||
       (NOT jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].top_alternatives[*].token_text'))::text || '|' ||
       (r.trace_summary #>> '{detailed_trace,steps,0,token_id}' = '42')::text || '|' ||
       (r.trace_summary #>> '{detailed_trace,steps,0,chosen_probability}' = '0.9')::text || '|' ||
       (r.trace_summary #>> '{detailed_trace,text_storage}' = 'redacted')::text || '|' ||
       (r.trace_summary::text NOT LIKE '%PROMPT-SENTINEL%')::text || '|' ||
       (
         otlet.redact_trace_summary(
           '{"custom":{"keep":"yes"},"detailed_trace":{"chosen_text":"🙂","steps":"bad"}}'::jsonb,
           'redacted'
         ) #>> '{custom,keep}' = 'yes'
         AND otlet.redact_trace_summary(
           '{"custom":{"keep":"yes"},"detailed_trace":{"chosen_text":"🙂","steps":"bad"}}'::jsonb,
           'redacted'
         ) #> '{detailed_trace,steps}' = '[]'::jsonb
         AND otlet.redact_trace_summary(
           '{"custom":{"keep":"yes"},"detailed_trace":{"chosen_text":"🙂","steps":"bad"}}'::jsonb,
           'redacted'
         ) #>> '{detailed_trace,chosen_text}' IS NULL
         AND NOT jsonb_path_exists(
           otlet.redact_trace_summary(
             '{"detailed_trace":{"steps":[{"token_text":"","top_alternatives":[{"token_text":"\u0001"}]}]}}'::jsonb,
             'redacted'
           ),
           '$.detailed_trace.steps[*].token_text'
         )
         AND NOT jsonb_path_exists(
           otlet.redact_trace_summary(
             '{"detailed_trace":{"steps":[{"token_text":"","top_alternatives":[{"token_text":"\u0001"}]}]}}'::jsonb,
             'redacted'
           ),
           '$.detailed_trace.steps[*].top_alternatives[*].token_text'
         )
       )::text || '|' ||
       (NOT EXISTS (
         SELECT 1
         FROM information_schema.columns
         WHERE table_schema = 'otlet'
           AND table_name IN ('jobs', 'outputs')
           AND column_name = 'raw_output'
       ))::text
FROM otlet.inference_receipts r
CROSS JOIN otlet.redaction_policy_status s
WHERE r.id = :redacted_receipt_id;
ROLLBACK;
SQL
redaction_write_contract="$(sed -n '1p' "$redaction_result_file")"
echo "redaction_write_contract=$redaction_write_contract"
[ "$redaction_write_contract" = "hash_only|true|true|true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected hash-only prompt and text-free receipt storage, got $redaction_write_contract" >&2
  exit 1
}

psql_value -v model_name="$strong_model_name" >"$redaction_result_file" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'diagnostic',
    sensitive_evidence_retention = interval '1 day'
WHERE name = 'default';
INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name)
VALUES (
  'redaction_diagnostic_contract',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Diagnostic redaction contract',
  '{"type":"object"}'::jsonb,
  :'model_name'
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
VALUES (
  'redaction_diagnostic_contract',
  'diagnostic-old',
  '{}'::jsonb,
  'running',
  1,
  now(),
  now() + interval '5 minutes',
  gen_random_uuid()::text
)
RETURNING id \gset diagnostic_
SELECT id
FROM otlet.record_model_attempt(
  :diagnostic_id,
  :'model_name',
  output => '{"status":"review"}'::jsonb,
  raw_output => 'DIAGNOSTIC-RAW-SENTINEL',
  raw_output_hash => otlet.portable_text_hash('DIAGNOSTIC-RAW-SENTINEL'),
  trace_summary => '{
    "schema_validation_status":"passed",
    "prompt":"DIAGNOSTIC-PROMPT-SENTINEL",
    "detailed_trace":{
      "status":"available",
      "chosen_text":"DIAGNOSTIC-CHOSEN-SENTINEL",
      "chosen_token_ids":[7],
      "captured_tokens":1,
      "top_k":1,
      "steps":[{
        "step":1,
        "token_id":7,
        "token_text":"DIAGNOSTIC-TOKEN-SENTINEL",
        "chosen_probability":0.75,
        "top_alternatives":[{
          "rank":1,
          "token_id":8,
          "token_text":"DIAGNOSTIC-ALT-SENTINEL",
          "probability":0.25
        }]
      }]
    }
  }'::jsonb,
  schema_validation_status => 'passed',
  selection_status => 'rejected',
  selection_reason => 'redaction_diagnostic_contract',
  expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE id = :diagnostic_id)
) \gset diagnostic_receipt_
SELECT (raw_output = 'DIAGNOSTIC-RAW-SENTINEL')::text || '|' ||
       (trace_summary #>> '{detailed_trace,chosen_text}' = 'DIAGNOSTIC-CHOSEN-SENTINEL')::text || '|' ||
       (trace_summary #>> '{detailed_trace,steps,0,token_text}' = 'DIAGNOSTIC-TOKEN-SENTINEL')::text || '|' ||
       (trace_summary #>> '{detailed_trace,steps,0,top_alternatives,0,token_text}' = 'DIAGNOSTIC-ALT-SENTINEL')::text || '|' ||
       (trace_summary #>> '{detailed_trace,text_storage}' = 'diagnostic')::text || '|' ||
       (trace_summary -> 'prompt' IS NULL)::text || '|' ||
       (SELECT storage_compliant FROM otlet.redaction_policy_status)::text
FROM otlet.inference_receipts
WHERE id = :diagnostic_receipt_id;
UPDATE otlet.inference_receipts
SET finished_at = now() - interval '2 days'
WHERE id = :diagnostic_receipt_id;
CREATE TEMP TABLE redaction_old_dry AS
SELECT * FROM otlet.cleanup_policy_state(true);
CREATE TEMP TABLE redaction_old_apply AS
SELECT * FROM otlet.cleanup_policy_state(false);
SELECT (SELECT sensitive_raw_outputs = 1
               AND sensitive_chosen_texts = 1
               AND sensitive_token_texts = 1
               AND sensitive_alternative_token_texts = 1
               AND dry_run
        FROM redaction_old_dry)::text || '|' ||
       (SELECT sensitive_raw_outputs = 1
               AND sensitive_chosen_texts = 1
               AND sensitive_token_texts = 1
               AND sensitive_alternative_token_texts = 1
               AND NOT dry_run
        FROM redaction_old_apply)::text || '|' ||
       (SELECT raw_output IS NULL
               AND raw_output_hash = otlet.portable_text_hash('DIAGNOSTIC-RAW-SENTINEL')
               AND candidate_output = '{"status":"review"}'::jsonb
               AND trace_summary #>> '{detailed_trace,chosen_text}' IS NULL
               AND NOT jsonb_path_exists(trace_summary, '$.detailed_trace.steps[*].token_text')
               AND trace_summary #>> '{detailed_trace,steps,0,token_id}' = '7'
        FROM otlet.inference_receipts
        WHERE id = :diagnostic_receipt_id)::text || '|' ||
       (SELECT sensitive_raw_outputs = 0
               AND sensitive_chosen_texts = 0
               AND sensitive_token_texts = 0
               AND sensitive_alternative_token_texts = 0
        FROM otlet.cleanup_policy_state(false))::text;
ROLLBACK;
SQL
redaction_diagnostic_first="$(sed -n '1p' "$redaction_result_file")"
redaction_diagnostic_second="$(sed -n '2p' "$redaction_result_file")"
echo "redaction_diagnostic_contract=$redaction_diagnostic_first $redaction_diagnostic_second"
if [ "$redaction_diagnostic_first" != "true|true|true|true|true|true|true" ] ||
   [ "$redaction_diagnostic_second" != "true|true|true|true" ]; then
  echo "Expected bounded diagnostic evidence and idempotent cleanup, got $redaction_diagnostic_first $redaction_diagnostic_second" >&2
  exit 1
fi

psql_value -v model_name="$strong_model_name" >"$redaction_result_file" <<'SQL'
BEGIN;
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'diagnostic'
WHERE name = 'default';
INSERT INTO otlet.tasks (name, input_query, instruction, output_schema, model_name)
VALUES (
  'redaction_mode_switch_contract',
  'SELECT NULL::text AS subject_id, ''{}''::jsonb AS input WHERE false',
  'Mode switch contract',
  '{"type":"object"}'::jsonb,
  :'model_name'
);
INSERT INTO otlet.jobs (task_name, subject_id, input, status, attempts, started_at, leased_until, claim_token)
VALUES ('redaction_mode_switch_contract', 'young', '{}'::jsonb, 'running', 1, now(), now() + interval '5 minutes', gen_random_uuid()::text)
RETURNING id \gset young_
SELECT id
FROM otlet.record_model_attempt(
  :young_id,
  :'model_name',
  raw_output => 'YOUNG-DIAGNOSTIC-RAW',
  raw_output_hash => otlet.portable_text_hash('YOUNG-DIAGNOSTIC-RAW'),
  trace_summary => '{"detailed_trace":{"chosen_text":"YOUNG-CHOSEN","steps":[{"token_id":9,"token_text":"YOUNG-TOKEN"}]}}'::jsonb,
  selection_status => 'failed',
  selection_reason => 'redaction_mode_switch_contract',
  expected_claim_token => (SELECT claim_token FROM otlet.jobs WHERE id = :young_id)
) \gset young_receipt_
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'redacted'
WHERE name = 'default';
CREATE TEMP TABLE redaction_switch_dry AS
SELECT * FROM otlet.cleanup_policy_state(true);
CREATE TEMP TABLE redaction_switch_apply AS
SELECT * FROM otlet.cleanup_policy_state(false);
SELECT (SELECT sensitive_raw_outputs = 1
               AND sensitive_chosen_texts = 1
               AND sensitive_token_texts = 1
               AND dry_run
        FROM redaction_switch_dry)::text || '|' ||
       (SELECT count(*) = 1 FROM redaction_switch_apply)::text || '|' ||
       (SELECT raw_output IS NULL
               AND trace_summary #>> '{detailed_trace,chosen_text}' IS NULL
               AND NOT jsonb_path_exists(trace_summary, '$.detailed_trace.steps[*].token_text')
               AND trace_summary #>> '{detailed_trace,steps,0,token_id}' = '9'
        FROM otlet.inference_receipts
        WHERE id = :young_receipt_id)::text || '|' ||
       (SELECT storage_compliant FROM otlet.redaction_policy_status)::text;
ROLLBACK;
SQL
redaction_mode_switch_contract="$(sed -n '1p' "$redaction_result_file")"
echo "redaction_mode_switch_contract=$redaction_mode_switch_contract"
[ "$redaction_mode_switch_contract" = "true|true|true|true" ] || {
  echo "Expected a redacted-mode switch to scrub young diagnostic evidence, got $redaction_mode_switch_contract" >&2
  exit 1
}

psql_value >"$redaction_result_file" <<'SQL'
SELECT sensitive_evidence_mode || '|' ||
       raw_output_rows::text || '|' ||
       chosen_text_rows::text || '|' ||
       token_text_values::text || '|' ||
       alternative_token_text_values::text || '|' ||
       overdue_sensitive_rows::text || '|' ||
       storage_compliant::text
FROM otlet.redaction_policy_status;
SQL
redaction_status_contract="$(sed -n '1p' "$redaction_result_file")"
echo "redaction_status_contract=$redaction_status_contract"
[ "$redaction_status_contract" = "redacted|0|0|0|0|0|true" ] || {
  echo "Expected compliant redacted production storage, got $redaction_status_contract" >&2
  exit 1
}

rm -f "$redaction_result_file"
trap - EXIT
