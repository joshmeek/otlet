CREATE VIEW otlet.semantic_program_status_rows AS
WITH source_programs AS (
  SELECT
    'row'::text AS program_type,
    sp.name AS program_name,
    sp.index_name,
    NULL::text AS action_type,
    sp.predicate,
    sp.expected,
    sp.compiler_version,
    'semantic_row_predicate'::text AS program_kind,
    sp.program_hash,
    sp.updated_at
  FROM otlet.semantic_programs sp
  UNION ALL
  SELECT
    'join',
    sp.name,
    sp.index_name,
    NULL::text,
    sp.predicate,
    sp.expected,
    sp.compiler_version,
    'semantic_join_predicate',
    sp.program_hash,
    sp.updated_at
  FROM otlet.semantic_join_programs sp
  UNION ALL
  SELECT
    'action',
    sp.name,
    sp.index_name,
    sp.action_type,
    sp.predicate,
    sp.expected,
    sp.compiler_version,
    'semantic_action_predicate',
    sp.program_hash,
    sp.updated_at
  FROM otlet.semantic_action_programs sp
)
SELECT
  p.program_type,
  p.program_name,
  p.index_name,
  p.action_type,
  p.predicate,
  p.expected,
  p.compiler_version,
  CASE WHEN p.compiler_version LIKE '%model%' THEN 'model' ELSE 'deterministic' END AS compiler_mode,
  p.program_kind,
  p.program_hash,
  md5(p.predicate) AS predicate_text_hash,
  md5(p.expected::text) AS expected_hash,
  md5('otlet_semantic_program_ast_v1') AS compiler_schema_hash,
  CASE
    WHEN p.program_type = 'action'
     AND jsonb_typeof(p.expected -> 'body') = 'object'
     AND body_keys.key_count = 1
     AND jsonb_typeof((p.expected -> 'body') -> body_keys.only_key) = 'boolean' THEN 'boolean_action_predicate'
    WHEN p.program_type = 'action'
     AND jsonb_typeof(p.expected -> 'body') = 'object'
     AND body_keys.key_count = 1
     AND jsonb_typeof((p.expected -> 'body') -> body_keys.only_key) = 'string' THEN 'label_action_predicate'
    WHEN p.program_type = 'action' THEN 'json_action_predicate'
    WHEN expected_keys.key_count = 1
     AND jsonb_typeof(p.expected -> expected_keys.only_key) = 'boolean' THEN 'boolean_predicate'
    WHEN expected_keys.key_count = 1
     AND jsonb_typeof(p.expected -> expected_keys.only_key) = 'string' THEN 'label_predicate'
    ELSE 'json_object_predicate'
  END AS predicate_shape,
  true AS customscan_eligible,
  jsonb_strip_nulls(jsonb_build_object(
    'kind', CASE p.program_type
      WHEN 'row' THEN 'row_match'
      WHEN 'join' THEN 'join_match'
      ELSE 'action_match'
    END,
    'program_type', p.program_type,
    'target', CASE p.program_type
      WHEN 'row' THEN 'output'
      WHEN 'join' THEN 'join_output'
      ELSE 'action.payload'
    END,
    'action_type', p.action_type,
    'field', CASE
      WHEN p.program_type <> 'action' AND expected_keys.key_count = 1 THEN expected_keys.only_key
      ELSE NULL
    END,
    'field_path', CASE
      WHEN p.program_type = 'action' AND body_keys.key_count = 1 THEN jsonb_build_array('body', body_keys.only_key)
      ELSE NULL
    END,
    'operator', CASE
      WHEN p.program_type = 'action' AND body_keys.key_count = 1 THEN 'equals'
      WHEN p.program_type = 'action' THEN 'contains'
      WHEN expected_keys.key_count = 1 THEN 'equals'
      ELSE 'contains'
    END,
    'value', CASE
      WHEN p.program_type = 'action' AND body_keys.key_count = 1 THEN (p.expected -> 'body') -> body_keys.only_key
      WHEN p.program_type = 'action' THEN p.expected
      WHEN expected_keys.key_count = 1 THEN p.expected -> expected_keys.only_key
      ELSE p.expected
    END,
    'expected', p.expected
  )) AS program_ast,
  p.updated_at
FROM source_programs p
LEFT JOIN LATERAL (
  SELECT count(*)::integer AS key_count, min(key) AS only_key
  FROM jsonb_object_keys(p.expected) AS keys(key)
) expected_keys ON true
LEFT JOIN LATERAL (
  SELECT count(*)::integer AS key_count, min(key) AS only_key
  FROM jsonb_object_keys(COALESCE(p.expected -> 'body', '{}'::jsonb)) AS keys(key)
) body_keys ON true;

CREATE VIEW otlet.semantic_program_model_compile_status AS
WITH compiler_jobs AS (
  SELECT
    j.id AS job_id,
    r.id AS receipt_id,
    j.input ->> 'compiler_kind' AS compiler_kind,
    j.subject_id AS program_name,
    j.input ->> 'index_name' AS index_name,
    j.input ->> 'action_type' AS action_type,
    j.input ->> 'predicate_text' AS predicate_text,
    j.status AS job_status,
    r.status AS receipt_status,
    t.model_name,
    md5(COALESCE(r.model_artifact_path, '') || chr(31) || COALESCE(r.model_artifact_hash, '')) AS model_fingerprint,
    o.output,
    CASE
      WHEN j.input ->> 'compiler_kind' = 'row' THEN 'otlet_semantic_program_model_v1'
      WHEN j.input ->> 'compiler_kind' = 'join' THEN 'otlet_semantic_join_program_model_v1'
      WHEN j.input ->> 'compiler_kind' = 'action' THEN 'otlet_semantic_action_program_model_v1'
      ELSE 'unknown'
    END AS compiler_version,
    r.error,
    j.created_at,
    j.started_at,
    j.finished_at
  FROM otlet.jobs j
  JOIN otlet.tasks t ON t.name = j.task_name
  LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id
  LEFT JOIN LATERAL (
    SELECT output
    FROM otlet.outputs o
    WHERE o.job_id = j.id
    ORDER BY o.id DESC
    LIMIT 1
  ) o ON true
  WHERE j.input ? 'compiler_kind'
    AND j.input ->> 'semantic_program_contract' = 'compile_once_store_ast_execute_materialized_state'
)
SELECT
  cj.job_id,
  cj.receipt_id,
  cj.compiler_kind,
  cj.program_name,
  cj.index_name,
  cj.action_type,
  cj.predicate_text,
  cj.job_status,
  cj.receipt_status,
  cj.model_name,
  cj.model_fingerprint,
  cj.output,
  cj.compiler_version,
  COALESCE(program.program_row_exists, false) AS program_row_exists,
  CASE
    WHEN cj.job_status = 'complete'
     AND cj.output ->> 'kind' IS NOT NULL
     AND cj.output ->> 'kind' <> 'unsupported'
     AND COALESCE(program.program_row_exists, false) THEN 'applied'
    WHEN cj.job_status = 'complete'
     AND cj.output ->> 'kind' IS NOT NULL
     AND cj.output ->> 'kind' <> 'unsupported' THEN 'complete_pending_apply'
    WHEN cj.job_status = 'complete' AND cj.output ->> 'kind' = 'unsupported' THEN 'rejected_unsupported'
    WHEN cj.job_status = 'failed' THEN 'failed_schema_or_runtime'
    WHEN cj.job_status IN ('queued', 'running', 'cancel_requested') THEN 'in_flight'
    ELSE cj.job_status
  END AS model_compile_status,
  cj.error,
  cj.created_at,
  cj.started_at,
  cj.finished_at
FROM compiler_jobs cj
LEFT JOIN LATERAL (
  SELECT true AS program_row_exists
  FROM otlet.semantic_program_status_rows ps
  WHERE ps.program_type = cj.compiler_kind
    AND ps.program_name = cj.program_name
    AND ps.index_name = cj.index_name
    AND ps.predicate = cj.predicate_text
    AND ps.compiler_version = cj.compiler_version
    AND (ps.program_type <> 'action' OR ps.action_type = cj.action_type)
  LIMIT 1
) program ON true;

CREATE VIEW otlet.semantic_program_ast_status AS
SELECT
  ps.program_type,
  ps.program_name,
  ps.index_name,
  ps.action_type,
  ps.predicate,
  ps.expected,
  ps.compiler_version,
  ps.compiler_mode,
  ps.program_hash,
  ps.predicate_text_hash,
  ps.expected_hash,
  ps.compiler_schema_hash,
  CASE WHEN ps.compiler_mode = 'model' THEN compiler.model_fingerprint ELSE NULL END AS model_fingerprint,
  CASE WHEN ps.compiler_mode = 'model' THEN compiler.receipt_id ELSE NULL END AS compiler_receipt_id,
  CASE
    WHEN ps.compiler_mode <> 'model' THEN 'not_applicable_deterministic_fast_path'
    WHEN compiler.receipt_id IS NOT NULL THEN 'available'
    ELSE 'missing'
  END AS compiler_receipt_status,
  CASE
    WHEN ps.compiler_mode <> 'model' THEN 'not_used_deterministic_fast_path'
    ELSE COALESCE(compiler.model_compile_status, 'model_compile_receipt_missing')
  END AS model_compile_status,
  ps.customscan_eligible,
  ps.program_ast,
  ps.updated_at
FROM otlet.semantic_program_status_rows ps
LEFT JOIN LATERAL (
  SELECT receipt_id, model_fingerprint, model_compile_status
  FROM otlet.semantic_program_model_compile_status cs
  WHERE cs.compiler_kind = ps.program_type
    AND cs.program_name = ps.program_name
    AND cs.index_name = ps.index_name
    AND cs.predicate_text = ps.predicate
    AND (ps.program_type <> 'action' OR cs.action_type = ps.action_type)
  ORDER BY cs.finished_at DESC NULLS LAST, cs.job_id DESC
  LIMIT 1
) compiler ON true;

CREATE VIEW otlet.semantic_program_catalog_status AS
WITH program_status AS (
  SELECT
    count(*)::bigint AS program_count,
    count(*) FILTER (WHERE program_type = 'row')::bigint AS row_program_count,
    count(*) FILTER (WHERE program_type = 'action')::bigint AS action_program_count,
    count(*) FILTER (WHERE program_type = 'join')::bigint AS join_program_count,
    count(*) FILTER (WHERE program_hash IS NOT NULL AND program_hash <> '')::bigint AS stable_hash_program_count,
    COALESCE(array_agg(
      program_type || ':' || program_name || ':' || index_name || ':' ||
      COALESCE(action_type, '') || ':' || predicate_shape || ':' ||
      compiler_version || ':' || program_hash
      ORDER BY program_type, program_name
    ), ARRAY[]::text[]) AS program_catalog,
    COALESCE(array_agg(DISTINCT compiler_version ORDER BY compiler_version), ARRAY[]::text[]) AS compiler_versions
  FROM otlet.semantic_program_status_rows
),
ast_status AS (
  SELECT
    count(*)::bigint AS ast_program_count,
    count(*) FILTER (WHERE compiler_mode = 'deterministic')::bigint AS deterministic_program_count,
    count(*) FILTER (WHERE compiler_mode <> 'deterministic')::bigint AS model_compiled_program_count,
    count(*) FILTER (WHERE compiler_receipt_id IS NOT NULL)::bigint AS compiler_receipt_count,
    count(*) FILTER (WHERE customscan_eligible)::bigint AS customscan_ast_program_count
  FROM otlet.semantic_program_ast_status
),
model_compile_status AS (
  SELECT
    count(*)::bigint AS model_compiler_job_count,
    count(*) FILTER (WHERE receipt_id IS NOT NULL)::bigint AS model_compiler_receipt_count,
    count(*) FILTER (WHERE model_compile_status IN ('rejected_unsupported', 'failed_schema_or_runtime'))::bigint AS rejected_model_compile_count,
    count(*) FILTER (WHERE model_compile_status = 'applied')::bigint AS applied_model_compile_count
  FROM otlet.semantic_program_model_compile_status
)
SELECT
  program_count,
  row_program_count,
  action_program_count,
  join_program_count,
  stable_hash_program_count,
  ast_program_count,
  deterministic_program_count,
  model_compiled_program_count,
  compiler_receipt_count,
  customscan_ast_program_count,
  model_compiler_job_count,
  model_compiler_receipt_count,
  rejected_model_compile_count,
  applied_model_compile_count,
  program_count AS no_mutation_program_count,
  program_count AS bounded_storage_program_count,
  compiler_versions,
  program_catalog
FROM program_status, ast_status, model_compile_status;
