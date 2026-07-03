CREATE FUNCTION otlet.trace_readable_token_text(token_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN token_text IS NULL THEN NULL
    ELSE regexp_replace(
      replace(
        replace(
          replace(
            replace(token_text, E'\\', E'\\\\'),
            E'\n',
            E'\\n'
          ),
          E'\r',
          E'\\r'
        ),
        E'\t',
        E'\\t'
      ),
      '[[:cntrl:]]',
      '?',
      'g'
    )
  END;
$$;

CREATE VIEW otlet.inference_receipt_token_trace AS
SELECT
  r.id AS receipt_id,
  r.job_id,
  r.task_name,
  r.subject_id,
  r.status,
  r.model_name,
  r.runtime_name,
  r.prompt_hash,
  r.input_hash,
  r.output_schema_hash,
  r.raw_output_hash,
  r.trace_summary ->> 'model_fingerprint_hash' AS model_fingerprint_hash,
  r.trace_summary ->> 'runtime_options_hash' AS runtime_options_hash,
  r.trace_summary ->> 'row_identity' AS row_identity,
  r.trace_summary -> 'mvcc' AS mvcc,
  r.trace_summary ->> 'worker_handoff' AS worker_handoff,
  r.trace_summary ->> 'stale_policy' AS stale_policy,
  r.trace_summary ->> 'stop_reason' AS stop_reason,
  r.trace_summary -> 'detailed_trace' ->> 'trace_contract' AS trace_contract,
  r.trace_summary -> 'detailed_trace' ->> 'storage_policy' AS storage_policy,
  r.trace_summary -> 'detailed_trace' ->> 'logprob_policy' AS logprob_policy,
  COALESCE((r.trace_summary #>> '{detailed_trace,max_tokens}')::int, 0) AS max_tokens,
  COALESCE((r.trace_summary #>> '{detailed_trace,top_k}')::int, 0) AS top_k,
  step.ordinality::int AS step,
  (step.value ->> 'token_id')::bigint AS token_id,
  step.value ->> 'token_text' AS token_text,
  otlet.trace_readable_token_text(step.value ->> 'token_text') AS token_text_readable,
  CASE
    WHEN jsonb_typeof(step.value -> 'chosen_logit') = 'number'
      THEN (step.value ->> 'chosen_logit')::double precision
    ELSE NULL
  END AS chosen_logit,
  CASE
    WHEN jsonb_typeof(step.value -> 'chosen_probability') = 'number'
      THEN (step.value ->> 'chosen_probability')::double precision
    ELSE NULL
  END AS chosen_probability,
  CASE
    WHEN jsonb_typeof(step.value -> 'chosen_logprob') = 'number'
      THEN (step.value ->> 'chosen_logprob')::double precision
    ELSE NULL
  END AS chosen_logprob,
  CASE
    WHEN jsonb_typeof(step.value -> 'rank') = 'number'
      THEN (step.value ->> 'rank')::bigint
    ELSE NULL
  END AS chosen_rank,
  step.value ->> 'probability_status' AS probability_status,
  COALESCE(step.value -> 'top_alternatives', '[]'::jsonb) AS top_alternatives
FROM otlet.inference_receipts r
CROSS JOIN LATERAL jsonb_array_elements(
  CASE
    WHEN jsonb_typeof(r.trace_summary #> '{detailed_trace,steps}') = 'array'
      THEN r.trace_summary #> '{detailed_trace,steps}'
    ELSE '[]'::jsonb
  END
) WITH ORDINALITY AS step(value, ordinality);

CREATE VIEW otlet.inference_receipt_token_alternative_trace AS
SELECT
  t.receipt_id,
  t.job_id,
  t.task_name,
  t.subject_id,
  t.model_name,
  t.runtime_name,
  t.row_identity,
  t.trace_contract,
  t.step,
  alt.ordinality::int AS alternative_ordinality,
  (alt.value ->> 'rank')::bigint AS alternative_rank,
  (alt.value ->> 'token_id')::bigint AS token_id,
  alt.value ->> 'token_text' AS token_text,
  otlet.trace_readable_token_text(alt.value ->> 'token_text') AS token_text_readable,
  CASE
    WHEN jsonb_typeof(alt.value -> 'logit') = 'number'
      THEN (alt.value ->> 'logit')::double precision
    ELSE NULL
  END AS logit,
  CASE
    WHEN jsonb_typeof(alt.value -> 'probability') = 'number'
      THEN (alt.value ->> 'probability')::double precision
    ELSE NULL
  END AS probability,
  CASE
    WHEN jsonb_typeof(alt.value -> 'logprob') = 'number'
      THEN (alt.value ->> 'logprob')::double precision
    ELSE NULL
  END AS logprob
FROM otlet.inference_receipt_token_trace t
CROSS JOIN LATERAL jsonb_array_elements(t.top_alternatives) WITH ORDINALITY AS alt(value, ordinality);

CREATE VIEW otlet.inference_trace_summary AS
SELECT
  s.receipt_id,
  s.job_id,
  s.task_name,
  s.subject_id,
  s.status,
  r.error,
  s.model_name,
  s.runtime_name,
  s.prompt_tokens,
  s.generated_tokens,
  s.generate_ms,
  s.tokens_per_second,
  s.schema_validation_status,
  s.trace_version,
  s.runtime_options_status,
  s.executor_origin,
  s.executor_node,
  s.executor_boundary,
  s.semantic_index_kind,
  s.semantic_index_name,
  s.row_identity,
  s.mvcc,
  s.freshness_basis,
  s.worker_handoff,
  s.stale_policy,
  s.stop_reason,
  s.probability_status,
  s.probability_method,
  s.detailed_trace_status,
  s.detailed_trace_contract,
  s.detailed_trace_storage_policy,
  s.detailed_trace_logprob_policy,
  s.detailed_trace_max_tokens,
  s.detailed_trace_top_k,
  s.detailed_trace_captured_tokens,
  s.detailed_trace_skipped_tokens,
  s.model_cache_hit,
  s.inference_cache_hit,
  s.inference_cache_reason,
  pg_column_size(r.trace_summary)::bigint AS trace_summary_bytes,
  COALESCE((
    SELECT count(*)
    FROM otlet.inference_receipt_token_trace t
    WHERE t.receipt_id = s.receipt_id
  ), 0)::bigint AS token_steps,
  COALESCE((
    SELECT count(*)
    FROM otlet.inference_receipt_token_alternative_trace a
    WHERE a.receipt_id = s.receipt_id
  ), 0)::bigint AS top_k_alternatives,
  COALESCE((
    SELECT string_agg(t.token_text_readable, '' ORDER BY t.step)
    FROM otlet.inference_receipt_token_trace t
    WHERE t.receipt_id = s.receipt_id
  ), '') AS chosen_text_readable
FROM otlet.inference_receipt_trace_status s
JOIN otlet.inference_receipts r ON r.id = s.receipt_id;
