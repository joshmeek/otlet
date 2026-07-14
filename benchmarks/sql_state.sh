ensure_result_tables() {
  psql_exec >/dev/null <<'SQL'
CREATE SCHEMA IF NOT EXISTS otlet_bench_source;
CREATE TABLE IF NOT EXISTS otlet_bench_source.case_result (
  run_id text NOT NULL,
  model_key text NOT NULL,
  case_id text NOT NULL,
  track text NOT NULL,
  subject_id text NOT NULL,
  expected_match text,
  actual_match text,
  raw_match text,
  expected_confidence_floor text,
  actual_confidence text,
  raw_confidence text,
  expected_action_type text,
  actual_action_type text,
  raw_action_type text,
  schema_valid boolean NOT NULL DEFAULT false,
  match_correct boolean NOT NULL DEFAULT false,
  diagnostic_match_correct boolean NOT NULL DEFAULT false,
  confidence_correct boolean NOT NULL DEFAULT false,
  diagnostic_confidence_correct boolean NOT NULL DEFAULT false,
  action_correct boolean NOT NULL DEFAULT false,
  diagnostic_action_correct boolean NOT NULL DEFAULT false,
  false_merge boolean NOT NULL DEFAULT false,
  injection_resisted boolean NOT NULL DEFAULT true,
  materialized boolean NOT NULL DEFAULT false,
  source_hash_present boolean NOT NULL DEFAULT false,
  receipt_id bigint,
  output_id bigint,
  raw_output_hash text,
  error text,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, model_key, case_id)
);
CREATE TABLE IF NOT EXISTS otlet_bench_source.model_summary (
  run_id text NOT NULL,
  model_key text NOT NULL,
  model_name text NOT NULL,
  family text,
  tier text,
  quant text,
  declared_params_b numeric,
  active_params_b numeric,
  context_tokens bigint,
  license_note text,
  source_url text,
  artifact_path text,
  artifact_bytes bigint,
  external_artifact boolean NOT NULL DEFAULT false,
  run_status text NOT NULL,
  unsupported_reason text,
  total_cases bigint NOT NULL DEFAULT 0,
  schema_valid_rate numeric NOT NULL DEFAULT 0,
  entity_accuracy numeric NOT NULL DEFAULT 0,
  abstention_false_merge_rate numeric NOT NULL DEFAULT 0,
  hallucinated_trusted_action_rate numeric NOT NULL DEFAULT 0,
  stale_leak_count bigint NOT NULL DEFAULT 0,
  source_table_mutated boolean NOT NULL DEFAULT false,
  worker_crash_count bigint NOT NULL DEFAULT 0,
  p50_generate_ms numeric,
  p95_generate_ms numeric,
  mean_tokens_per_second numeric,
  p50_ttft_ms numeric,
  p95_ttft_ms numeric,
  p50_prompt_decode_ms numeric,
  p95_prompt_decode_ms numeric,
  mean_steady_tokens_per_second numeric,
  artifact_gb numeric,
  resident_gb numeric,
  jobs_per_second numeric,
  correct_jobs_per_second_per_gb numeric,
  quality_per_artifact_gb numeric,
  contract_score numeric NOT NULL DEFAULT 0,
  entity_resolution_score numeric NOT NULL DEFAULT 0,
  abstention_score numeric NOT NULL DEFAULT 0,
  dirty_data_score numeric NOT NULL DEFAULT 0,
  triage_score numeric NOT NULL DEFAULT 0,
  triage_abstention_score numeric NOT NULL DEFAULT 0,
  numeric_evidence_score numeric NOT NULL DEFAULT 0,
  extraction_score numeric NOT NULL DEFAULT 0,
  policy_check_score numeric NOT NULL DEFAULT 0,
  user_suite_score numeric NOT NULL DEFAULT 0,
  row_watch_score numeric NOT NULL DEFAULT 0,
  typed_action_score numeric NOT NULL DEFAULT 0,
  semantic_materialization_score numeric NOT NULL DEFAULT 0,
  confidence_score numeric NOT NULL DEFAULT 0,
  diagnostic_entity_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_triage_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_numeric_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_action_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_confidence_accuracy numeric NOT NULL DEFAULT 0,
  diagnostic_quality_score numeric NOT NULL DEFAULT 0,
  quality_score numeric NOT NULL DEFAULT 0,
  trusted_quality numeric NOT NULL DEFAULT 0,
  resource_fit numeric NOT NULL DEFAULT 0,
  overall_fit numeric NOT NULL DEFAULT 0,
  diagnostic_fit numeric NOT NULL DEFAULT 0,
  single_run_verdict text NOT NULL,
  cleanup_policy text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, model_key)
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'otlet_bench_source'
      AND table_name = 'model_summary'
      AND column_name = 'verdict'
  ) AND NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'otlet_bench_source'
      AND table_name = 'model_summary'
      AND column_name = 'single_run_verdict'
  ) THEN
    ALTER TABLE otlet_bench_source.model_summary
      RENAME COLUMN verdict TO single_run_verdict;
  END IF;
END $$;

ALTER TABLE otlet_bench_source.model_summary
  ADD COLUMN IF NOT EXISTS trusted_quality numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS resource_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS overall_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS diagnostic_fit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS p50_ttft_ms numeric,
  ADD COLUMN IF NOT EXISTS p95_ttft_ms numeric,
  ADD COLUMN IF NOT EXISTS p50_prompt_decode_ms numeric,
  ADD COLUMN IF NOT EXISTS p95_prompt_decode_ms numeric,
  ADD COLUMN IF NOT EXISTS mean_steady_tokens_per_second numeric,
  ADD COLUMN IF NOT EXISTS triage_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS triage_abstention_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS numeric_evidence_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS extraction_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS policy_check_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user_suite_score numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS diagnostic_triage_accuracy numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS diagnostic_numeric_accuracy numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS single_run_verdict text NOT NULL DEFAULT 'unusable';
SQL
}

insert_terminal_summary() {
  local model_key="$1"
  local model_name="$2"
  local family="$3"
  local tier="$4"
  local quant="$5"
  local declared_params_b="$6"
  local active_params_b="$7"
  local context_tokens="$8"
  local license_note="$9"
  local source_url="${10}"
  local artifact_path="${11}"
  local artifact_bytes="${12}"
  local external_artifact="${13}"
  local reason="${14}"
  local run_status="${15}"
  local verdict="${16}"
  psql_exec \
    -v run_id="$run_id" \
    -v model_key="$model_key" \
    -v model_name="$model_name" \
    -v family="$family" \
    -v tier="$tier" \
    -v quant="$quant" \
    -v declared_params_b="$declared_params_b" \
    -v active_params_b="$active_params_b" \
    -v context_tokens="$context_tokens" \
    -v license_note="$license_note" \
    -v source_url="$source_url" \
    -v artifact_path="$artifact_path" \
    -v artifact_bytes="$artifact_bytes" \
    -v external_artifact="$external_artifact" \
    -v reason="$reason" \
    -v run_status="$run_status" \
    -v verdict="$verdict" \
    -v cleanup_policy="$(cleanup_policy)" >/dev/null <<'SQL'
INSERT INTO otlet_bench_source.model_summary (
  run_id,
  model_key,
  model_name,
  family,
  tier,
  quant,
  declared_params_b,
  active_params_b,
  context_tokens,
  license_note,
  source_url,
  artifact_path,
  artifact_bytes,
  external_artifact,
  run_status,
  unsupported_reason,
  single_run_verdict,
  cleanup_policy
)
VALUES (
  :'run_id',
  :'model_key',
  :'model_name',
  :'family',
  :'tier',
  :'quant',
  NULLIF(:'declared_params_b', '')::numeric,
  NULLIF(:'active_params_b', '')::numeric,
  NULLIF(:'context_tokens', '')::bigint,
  :'license_note',
  :'source_url',
  :'artifact_path',
  (:'artifact_bytes')::bigint,
  (:'external_artifact')::boolean,
  :'run_status',
  :'reason',
  :'verdict',
  :'cleanup_policy'
)
ON CONFLICT (run_id, model_key) DO UPDATE
  SET run_status = EXCLUDED.run_status,
      unsupported_reason = EXCLUDED.unsupported_reason,
      single_run_verdict = EXCLUDED.single_run_verdict,
      cleanup_policy = EXCLUDED.cleanup_policy;
SQL
}

insert_unsupported_summary() {
  insert_terminal_summary "$@" not_supported not_supported
}

insert_failed_summary() {
  insert_terminal_summary "$@" failed too_unreliable
}

cleanup_policy() {
  printf 'models=%s sql_state=%s' "$keep_models" "$keep_sql_state"
}

task_prefix_like() {
  printf "%s\\_%%" "$run_id"
}

cleanup_sql_state() {
  local prefix
  prefix="$(task_prefix_like)"
  psql_exec -v prefix="$prefix" >/dev/null <<'SQL' || true
WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
),
bench_actions AS (
  SELECT a.id
  FROM otlet.actions a
  JOIN bench_jobs bj ON bj.id = a.job_id
),
bench_outputs AS (
  SELECT o.id
  FROM otlet.outputs o
  JOIN bench_jobs bj ON bj.id = o.job_id
),
bench_receipts AS (
  SELECT r.id
  FROM otlet.inference_receipts r
  JOIN bench_jobs bj ON bj.id = r.job_id
)
DELETE FROM otlet.eval_labels l
WHERE EXISTS (
    SELECT 1
    FROM bench_actions a
    WHERE a.id = l.action_id
  )
  OR EXISTS (
    SELECT 1
    FROM bench_outputs o
    WHERE o.id = l.output_id
  )
  OR EXISTS (
    SELECT 1
    FROM bench_receipts r
    WHERE r.id = l.receipt_id
  );

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.semantic_materializations sm
USING otlet.records r, otlet.actions a, bench_jobs bj
WHERE sm.record_id = r.id
  AND r.action_id = a.id
  AND a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.records r
USING otlet.actions a, bench_jobs bj
WHERE r.action_id = a.id
  AND a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.actions a
USING bench_jobs bj
WHERE a.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.outputs o
USING bench_jobs bj
WHERE o.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.inference_receipts r
USING bench_jobs bj
WHERE r.job_id = bj.id;

WITH bench_jobs AS (
  SELECT id
  FROM otlet.jobs
  WHERE task_name LIKE :'prefix' ESCAPE '\'
)
DELETE FROM otlet.worker_events e
USING bench_jobs bj
WHERE e.job_id = bj.id;

DELETE FROM otlet.jobs j
WHERE j.task_name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.model_selection_policies p
WHERE p.task_name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.watches w
WHERE w.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.semantic_join_indexes sji
WHERE sji.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.semantic_indexes si
WHERE si.name LIKE :'prefix' ESCAPE '\';

DELETE FROM otlet.tasks t
WHERE t.name LIKE :'prefix' ESCAPE '\';

DROP SCHEMA IF EXISTS otlet_bench_source CASCADE;
SQL
}

cleanup_models() {
  local names
  if [[ ! -s "$created_models" ]]; then
    return
  fi
  names="$(paste -sd, "$created_models")"
  psql_exec -v model_names="$names" >/dev/null <<'SQL'
WITH names AS (
  SELECT unnest(string_to_array(:'model_names', ',')) AS model_name
),
deleted_slots AS (
  DELETE FROM otlet.runtime_slots s
  USING names
  WHERE s.model_name = names.model_name
  RETURNING s.model_name
)
DELETE FROM otlet.models m
USING names
WHERE m.name = names.model_name;
SQL
}

created_model_residue_count() {
  local names
  if [[ ! -s "$created_models" ]]; then
    printf '0'
    return
  fi
  names="$(paste -sd, "$created_models")"
  psql_value -v model_names="$names" <<'SQL' || printf 'unknown'
WITH names AS (
  SELECT unnest(string_to_array(:'model_names', ',')) AS model_name
)
SELECT
  (SELECT count(*) FROM otlet.models m JOIN names ON names.model_name = m.name)
  + (SELECT count(*) FROM otlet.runtime_slots s JOIN names ON names.model_name = s.model_name);
SQL
}

scratch_bytes() {
  docker exec "$container" sh -lc "if [ -d $(sh_quote "$scratch_dir") ]; then du -sb $(sh_quote "$scratch_dir") 2>/dev/null | awk '{print \$1}'; else echo 0; fi"
}

container_dir_bytes() {
  local path="$1"
  docker exec "$container" sh -lc "if [ -d $(sh_quote "$path") ]; then du -sb $(sh_quote "$path") 2>/dev/null | awk '{print \$1}'; else echo 0; fi"
}


perform_cleanup() {
  if [[ "$cleanup_done" = "1" ]]; then
    return
  fi
  cleanup_done=1
  write_kv_header "$cleanup_tsv"

  local removed_bytes=0
  local scratch_removed=false
  local sql_removed=false
  local models_removed=false
  local model_residue=0

  if [[ "$keep_sql_state" = "1" ]]; then
    append_kv "$cleanup_tsv" sql_state_removed false
  else
    cleanup_sql_state
    sql_removed=true
    append_kv "$cleanup_tsv" sql_state_removed true
  fi

  if [[ "$keep_models" = "1" ]]; then
    append_kv "$cleanup_tsv" model_artifacts_removed false
    append_kv "$cleanup_tsv" scratch_dir_kept "$scratch_dir"
  else
    cleanup_models
    removed_bytes="$(scratch_bytes)"
    docker exec "$container" sh -lc "rm -rf $(sh_quote "$scratch_dir")" >/dev/null || true
    removed_bytes=$((removed_bytes + artifact_bytes_removed_early))
    model_residue="$(created_model_residue_count)"
    if [[ "$model_residue" = "0" ]]; then
      models_removed=true
    fi
    scratch_removed=true
    append_kv "$cleanup_tsv" model_artifacts_removed true
    append_kv "$cleanup_tsv" scratch_dir_removed "$scratch_dir"
    append_kv "$cleanup_tsv" model_artifact_bytes_removed "$removed_bytes"
  fi

  if [[ "$sensitive_mode_enabled" = "1" ]]; then
    psql_exec >/dev/null <<'SQL'
UPDATE otlet.production_policy
SET sensitive_evidence_mode = 'redacted'
WHERE name = 'default';
SELECT * FROM otlet.cleanup_policy_state(false);
SQL
    sensitive_mode_enabled=0
    append_kv "$cleanup_tsv" sensitive_evidence_mode_restored redacted
  fi

  append_kv "$cleanup_tsv" sql_cleanup_policy "$keep_sql_state"
  append_kv "$cleanup_tsv" model_cleanup_policy "$keep_models"
  append_kv "$cleanup_tsv" downloaded_path_count "$(wc -l < "$downloaded_paths" | tr -d ' ')"
  append_kv "$cleanup_tsv" created_model_count "$(wc -l < "$created_models" | tr -d ' ')"
  append_kv "$cleanup_tsv" created_model_residue_count "$model_residue"
  append_kv "$cleanup_tsv" cleanup_complete true
  append_kv "$cleanup_tsv" scratch_removed "$scratch_removed"
  append_kv "$cleanup_tsv" sql_removed "$sql_removed"
  append_kv "$cleanup_tsv" created_models_removed "$models_removed"
}
