ALTER TABLE otlet.jobs
ALTER COLUMN created_at SET DEFAULT clock_timestamp();

ALTER TABLE otlet.inference_receipts
ALTER COLUMN finished_at SET DEFAULT clock_timestamp();

CREATE FUNCTION otlet.evaluation_slice_member_manifest_valid(
  eligible_members jsonb
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN jsonb_typeof($1) IS DISTINCT FROM 'array' THEN false
    WHEN jsonb_array_length($1) = 0 THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements($1) member
      WHERE jsonb_typeof(member) IS DISTINCT FROM 'object'
         OR jsonb_typeof(member -> 'included') IS DISTINCT FROM 'boolean'
         OR COALESCE(member ->> 'lineage_hash', '')
           !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
         OR (
           member ? 'case_hash'
           AND COALESCE(member ->> 'case_hash', '')
             !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
         )
         OR CASE (member ->> 'included')::boolean
           WHEN true THEN
             ARRAY(
               SELECT key FROM jsonb_object_keys(member) key ORDER BY key
             ) IS DISTINCT FROM ARRAY['case_hash', 'included', 'lineage_hash']::text[]
           ELSE
             ARRAY(
               SELECT key FROM jsonb_object_keys(member) key ORDER BY key
             ) NOT IN (
               ARRAY['exclusion_reason', 'included', 'lineage_hash']::text[],
               ARRAY[
                 'case_hash', 'exclusion_reason', 'included', 'lineage_hash'
               ]::text[]
             )
             OR NULLIF(btrim(member ->> 'exclusion_reason'), '') IS NULL
             OR octet_length(member ->> 'exclusion_reason') > 1024
         END
    )
  END;
$$;

CREATE FUNCTION otlet.stamp_job_wall_clock() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF NEW.status = 'running' AND OLD.status IS DISTINCT FROM 'running' THEN
    NEW.started_at := clock_timestamp();
  END IF;
  IF NEW.status IN ('complete', 'failed', 'canceled')
     AND OLD.status NOT IN ('complete', 'failed', 'canceled') THEN
    NEW.finished_at := clock_timestamp();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_wall_clock
BEFORE UPDATE ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.stamp_job_wall_clock();

CREATE FUNCTION otlet.validate_evaluation_slice_run() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  contract_definition jsonb;
  eligible_members jsonb;
  declared_case_hashes text[];
  eligible_count integer;
  labeled_count integer;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
BEGIN
  SELECT contract.definition INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = NEW.contract_hash;
  eligible_members := contract_definition #> '{population,rule,eligible_members}';
  IF eligible_members IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT otlet.evaluation_slice_member_manifest_valid(eligible_members)
     OR jsonb_array_length(eligible_members) > (
       SELECT policy.max_admission_rows
       FROM otlet.production_policy policy
       WHERE policy.name = 'default'
     ) THEN
    RAISE EXCEPTION 'otlet evaluation contract requires a bounded predeclared member manifest';
  END IF;
  SELECT
    array_agg(member ->> 'case_hash' ORDER BY member ->> 'case_hash')
      FILTER (WHERE (member ->> 'included')::boolean),
    count(*)::integer,
    count(*) FILTER (WHERE member ? 'case_hash')::integer
  INTO declared_case_hashes, eligible_count, labeled_count
  FROM jsonb_array_elements(eligible_members) member;
  IF (
       SELECT count(DISTINCT member ->> 'lineage_hash')
       FROM jsonb_array_elements(eligible_members) member
     ) IS DISTINCT FROM eligible_count::bigint
     OR (
       SELECT count(DISTINCT member ->> 'case_hash')
       FROM jsonb_array_elements(eligible_members) member
       WHERE member ? 'case_hash'
     ) IS DISTINCT FROM labeled_count::bigint THEN
    RAISE EXCEPTION 'otlet evaluation eligible member identities must be unique';
  END IF;
  IF declared_case_hashes IS DISTINCT FROM NEW.case_hashes THEN
    RAISE EXCEPTION 'otlet evaluation run must exactly match the predeclared sample';
  END IF;
  IF contract_definition #>> '{population,mode}' = 'full'
     AND cardinality(declared_case_hashes) IS DISTINCT FROM eligible_count THEN
    RAISE EXCEPTION 'otlet full evaluation population cannot exclude members';
  END IF;
  window_starts_at := (
    contract_definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract_definition #>> '{observation_window,ends_at}'
  )::timestamptz;
  IF clock_timestamp() < window_starts_at
     OR clock_timestamp() >= window_ends_at THEN
    RAISE EXCEPTION 'otlet evaluation run is outside the observation window';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_runs_d_slices
BEFORE INSERT ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_slice_run();

CREATE TABLE otlet.evaluation_slice_reports (
  report_hash text PRIMARY KEY CHECK (
    report_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  run_hash text NOT NULL UNIQUE REFERENCES otlet.evaluation_runs(run_hash),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL
    AND octet_length(reason) <= 4096
  ),
  authenticated_role_oid oid NOT NULL,
  authenticated_role_name text NOT NULL CHECK (
    NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
  ),
  active_role_oid oid NOT NULL,
  active_role_name text NOT NULL CHECK (
    NULLIF(btrim(active_role_name), '') IS NOT NULL
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION otlet.validate_evaluation_slice_report() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  json_depth integer;
  json_nodes bigint;
BEGIN
  SELECT complexity.json_depth, complexity.json_nodes
  INTO json_depth, json_nodes
  FROM otlet.bounded_jsonb_complexity(NEW.definition, 16, 8192) complexity;

  IF octet_length(NEW.definition::text) > 262144
     OR json_depth > 16
     OR json_nodes > 8192
     OR ARRAY(
       SELECT key FROM jsonb_object_keys(NEW.definition) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'contract_hash',
       'format',
       'minimum_support',
       'non_authoritative',
       'population',
       'reason',
       'reviewer_time',
       'run_hash',
       'slices'
     ]::text[]
     OR NEW.definition ->> 'format' IS DISTINCT FROM 'otlet.evaluation.slices.v1'
     OR NEW.definition ->> 'run_hash' IS DISTINCT FROM NEW.run_hash
     OR NEW.definition ->> 'reason' IS DISTINCT FROM NEW.reason
     OR NEW.definition -> 'non_authoritative' IS DISTINCT FROM 'true'::jsonb
     OR jsonb_typeof(NEW.definition -> 'population') IS DISTINCT FROM 'object'
     OR jsonb_typeof(NEW.definition -> 'minimum_support') IS DISTINCT FROM 'object'
     OR jsonb_typeof(NEW.definition -> 'reviewer_time') IS DISTINCT FROM 'object'
     OR jsonb_typeof(NEW.definition -> 'slices') IS DISTINCT FROM 'array'
     OR NOT EXISTS (
       SELECT 1
       FROM otlet.evaluation_runs run
       WHERE run.run_hash = NEW.run_hash
         AND run.contract_hash = NEW.definition ->> 'contract_hash'
     )
     OR NEW.report_hash IS DISTINCT FROM
       otlet.identity_hash('evaluation_slice_report', NEW.definition) THEN
    RAISE EXCEPTION 'otlet evaluation slice report identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_slice_reports_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.evaluation_slice_reports
FOR EACH ROW EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE TRIGGER evaluation_slice_reports_b_validate
BEFORE INSERT ON otlet.evaluation_slice_reports
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_slice_report();

CREATE TRIGGER evaluation_slice_reports_truncate_guard
BEFORE TRUNCATE ON otlet.evaluation_slice_reports
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_evaluation_append();

CREATE FUNCTION otlet.record_evaluation_slice_report(
  run_hash text,
  reviewer_time jsonb,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  run otlet.evaluation_runs%ROWTYPE;
  contract_definition jsonb;
  eligible_members jsonb;
  normalized_members jsonb;
  normalized_exclusions jsonb;
  normalized_reviewer_time jsonb;
  declared_case_hashes text[];
  run_population_kind text;
  population_kinds bigint;
  eligible_count integer;
  labeled_count integer;
  included_count integer;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
  support_contract jsonb;
  slices jsonb;
  definition jsonb;
  report_hash text;
  existing_hash text;
  json_depth integer;
  json_nodes bigint;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF NULLIF(btrim(record_evaluation_slice_report.reason), '') IS NULL
     OR octet_length(record_evaluation_slice_report.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet evaluation slice report reason is required and bounded';
  END IF;
  IF jsonb_typeof(record_evaluation_slice_report.reviewer_time)
       IS DISTINCT FROM 'array'
     OR octet_length(record_evaluation_slice_report.reviewer_time::text) > 131072 THEN
    RAISE EXCEPTION 'otlet evaluation slice report observations are invalid';
  END IF;
  SELECT complexity.json_depth, complexity.json_nodes
  INTO json_depth, json_nodes
  FROM otlet.bounded_jsonb_complexity(
    record_evaluation_slice_report.reviewer_time,
    8,
    8192
  ) complexity;
  IF json_depth > 8 OR json_nodes > 8192 THEN
    RAISE EXCEPTION 'otlet evaluation slice report observations exceed complexity bounds';
  END IF;

  SELECT * INTO run
  FROM otlet.evaluation_runs stored
  WHERE stored.run_hash = record_evaluation_slice_report.run_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation run does not exist';
  END IF;
  SELECT contract.definition INTO contract_definition
  FROM otlet.workload_acceptance_contracts contract
  WHERE contract.contract_hash = run.contract_hash;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_evaluation_slice_report:' || run.run_hash, 0)
  );
  eligible_members := contract_definition #> '{population,rule,eligible_members}';
  IF NOT otlet.evaluation_slice_member_manifest_valid(eligible_members)
     OR jsonb_array_length(eligible_members) > (
       SELECT policy.max_admission_rows
       FROM otlet.production_policy policy
       WHERE policy.name = 'default'
     ) THEN
    RAISE EXCEPTION 'otlet evaluation contract requires a bounded predeclared member manifest';
  END IF;

  SELECT
    jsonb_agg(
      jsonb_strip_nulls(jsonb_build_object(
        'lineage_hash', member ->> 'lineage_hash',
        'case_hash', member ->> 'case_hash',
        'included', (member ->> 'included')::boolean,
        'exclusion_reason', NULLIF(btrim(member ->> 'exclusion_reason'), '')
      ))
      ORDER BY member ->> 'lineage_hash'
    ),
    array_agg(member ->> 'case_hash' ORDER BY member ->> 'case_hash')
      FILTER (WHERE (member ->> 'included')::boolean),
    count(*)::integer,
    count(*) FILTER (WHERE member ? 'case_hash')::integer,
    count(*) FILTER (WHERE (member ->> 'included')::boolean)::integer
  INTO
    normalized_members,
    declared_case_hashes,
    eligible_count,
    labeled_count,
    included_count
  FROM jsonb_array_elements(eligible_members) member;
  IF (
       SELECT count(DISTINCT member ->> 'lineage_hash')
       FROM jsonb_array_elements(eligible_members) member
     ) IS DISTINCT FROM eligible_count::bigint
     OR (
       SELECT count(DISTINCT member ->> 'case_hash')
       FROM jsonb_array_elements(eligible_members) member
       WHERE member ? 'case_hash'
     ) IS DISTINCT FROM labeled_count::bigint THEN
    RAISE EXCEPTION 'otlet evaluation eligible member identities must be unique';
  END IF;
  IF declared_case_hashes IS DISTINCT FROM run.case_hashes THEN
    RAISE EXCEPTION 'otlet evaluation run must exactly match the predeclared sample';
  END IF;
  IF contract_definition #>> '{population,mode}' = 'full'
     AND included_count IS DISTINCT FROM eligible_count THEN
    RAISE EXCEPTION 'otlet full evaluation population cannot exclude members';
  END IF;

  SELECT
    min(evaluation_case.population_kind),
    count(DISTINCT evaluation_case.population_kind)
  INTO run_population_kind, population_kinds
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(run.case_hashes);
  IF population_kinds IS DISTINCT FROM 1::bigint THEN
    RAISE EXCEPTION 'otlet evaluation run population is invalid';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(eligible_members) member
    WHERE member ? 'case_hash'
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.evaluation_cases evaluation_case
        WHERE evaluation_case.case_hash = member ->> 'case_hash'
          AND evaluation_case.task_name = run.task_name
          AND evaluation_case.population_kind = run_population_kind
          AND evaluation_case.lineage_hash = member ->> 'lineage_hash'
      )
  ) OR EXISTS (
    SELECT 1
    FROM jsonb_array_elements(eligible_members) member
    WHERE NOT member ? 'case_hash'
      AND EXISTS (
        SELECT 1
        FROM otlet.evaluation_cases evaluation_case
        WHERE evaluation_case.lineage_hash = member ->> 'lineage_hash'
      )
  ) THEN
    RAISE EXCEPTION 'otlet evaluation member manifest does not match label lineage';
  END IF;
  SELECT COALESCE(jsonb_agg(
    jsonb_strip_nulls(jsonb_build_object(
      'lineage_hash', member ->> 'lineage_hash',
      'case_hash', member ->> 'case_hash',
      'reason', btrim(member ->> 'exclusion_reason')
    ))
    ORDER BY member ->> 'lineage_hash'
  ), '[]'::jsonb)
  INTO normalized_exclusions
  FROM jsonb_array_elements(eligible_members) member
  WHERE NOT (member ->> 'included')::boolean;

  window_starts_at := (
    contract_definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract_definition #>> '{observation_window,ends_at}'
  )::timestamptz;
  IF clock_timestamp() < window_ends_at THEN
    RAISE EXCEPTION 'otlet evaluation observation window is still open';
  END IF;
  IF run.created_at < window_starts_at OR run.created_at >= window_ends_at THEN
    RAISE EXCEPTION 'otlet evaluation run is outside the observation window';
  END IF;

  IF jsonb_array_length(record_evaluation_slice_report.reviewer_time)
       > included_count * 2
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(record_evaluation_slice_report.reviewer_time) observation
       WHERE jsonb_typeof(observation) IS DISTINCT FROM 'object'
          OR ARRAY(
            SELECT key FROM jsonb_object_keys(observation) key ORDER BY key
          ) IS DISTINCT FROM ARRAY[
            'case_hash', 'evidence_hash', 'observed_at', 'seconds', 'variant'
          ]::text[]
          OR COALESCE(observation ->> 'case_hash', '')
            !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
          OR observation ->> 'case_hash' <> ALL(run.case_hashes)
          OR COALESCE(observation ->> 'variant', '') NOT IN ('baseline', 'candidate')
          OR jsonb_typeof(observation -> 'seconds') IS DISTINCT FROM 'number'
          OR (observation ->> 'seconds')::numeric < 0
          OR (observation ->> 'seconds')::numeric > 86400
          OR COALESCE(observation ->> 'evidence_hash', '')
            !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
          OR COALESCE(observation ->> 'observed_at', '')
            !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{6}Z$'
     ) OR (
       SELECT count(DISTINCT concat_ws(
         ':', observation ->> 'case_hash', observation ->> 'variant'
       ))
       FROM jsonb_array_elements(record_evaluation_slice_report.reviewer_time) observation
     ) IS DISTINCT FROM
       jsonb_array_length(record_evaluation_slice_report.reviewer_time)::bigint THEN
    RAISE EXCEPTION 'otlet evaluation reviewer time observations are invalid';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(record_evaluation_slice_report.reviewer_time) observation
    WHERE (observation ->> 'observed_at')::timestamptz < window_starts_at
       OR (observation ->> 'observed_at')::timestamptz >= window_ends_at
  ) THEN
    RAISE EXCEPTION 'otlet evaluation reviewer observation is outside the observation window';
  END IF;
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'case_hash', observation ->> 'case_hash',
      'variant', observation ->> 'variant',
      'seconds', (observation ->> 'seconds')::numeric,
      'evidence_hash', observation ->> 'evidence_hash',
      'observed_at', observation ->> 'observed_at'
    ) ORDER BY observation ->> 'case_hash', observation ->> 'variant'
  ), '[]'::jsonb)
  INTO normalized_reviewer_time
  FROM jsonb_array_elements(record_evaluation_slice_report.reviewer_time) observation;

  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    WHERE execution.run_hash = run.run_hash
      AND (
        job.status NOT IN ('complete', 'failed')
        OR NOT EXISTS (
          SELECT 1 FROM otlet.inference_receipts receipt
          WHERE receipt.job_id = job.id
        )
        OR (job.status = 'complete' AND result.result_hash IS NULL)
        OR (job.status = 'failed' AND result.result_hash IS NOT NULL)
        OR (
          job.status = 'complete'
          AND result.receipt_id IS DISTINCT FROM (
            SELECT receipt.id
            FROM otlet.inference_receipts receipt
            WHERE receipt.job_id = job.id
            ORDER BY receipt.attempt_index DESC, receipt.id DESC
            LIMIT 1
          )
        )
      )
  ) THEN
    RAISE EXCEPTION 'otlet evaluation slice report requires terminal paired evidence';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    WHERE execution.run_hash = run.run_hash
      AND (
        execution.created_at < window_starts_at
        OR execution.created_at >= window_ends_at
        OR job.created_at < window_starts_at
        OR job.created_at >= window_ends_at
        OR job.started_at IS NULL
        OR job.started_at < window_starts_at
        OR job.started_at >= window_ends_at
        OR job.finished_at IS NULL
        OR job.finished_at < window_starts_at
        OR job.finished_at >= window_ends_at
        OR job.finished_at < job.started_at
        OR (
          result.result_hash IS NOT NULL
          AND (
            result.created_at < window_starts_at
            OR result.created_at >= window_ends_at
          )
        )
      )
  ) OR EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
    WHERE execution.run_hash = run.run_hash
      AND (
        receipt.started_at < window_starts_at
        OR receipt.started_at >= window_ends_at
        OR receipt.finished_at < window_starts_at
        OR receipt.finished_at >= window_ends_at
        OR receipt.finished_at < receipt.started_at
      )
  ) THEN
    RAISE EXCEPTION 'otlet evaluation evidence is outside the observation window';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.evaluation_executions execution
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
    WHERE execution.run_hash = run.run_hash
      AND (
        receipt.generate_ms < 0
        OR CASE
          WHEN jsonb_typeof(receipt.trace_summary -> 'generate_ms') = 'number'
            THEN (receipt.trace_summary ->> 'generate_ms')::numeric < 0
              OR (receipt.trace_summary ->> 'generate_ms')::numeric > 9223372036854775807
              OR (receipt.trace_summary ->> 'generate_ms')::numeric
                <> trunc((receipt.trace_summary ->> 'generate_ms')::numeric)
          ELSE false
        END
        OR CASE
          WHEN jsonb_typeof(
            receipt.trace_summary #> '{memory,after,process_rss_bytes}'
          ) = 'number' THEN
            (receipt.trace_summary #>> '{memory,after,process_rss_bytes}')::numeric < 0
            OR (receipt.trace_summary #>> '{memory,after,process_rss_bytes}')::numeric
              > 9223372036854775807
            OR (receipt.trace_summary #>> '{memory,after,process_rss_bytes}')::numeric
              <> trunc((
                receipt.trace_summary #>> '{memory,after,process_rss_bytes}'
              )::numeric)
          ELSE false
        END
        OR CASE
          WHEN jsonb_typeof(
            receipt.trace_summary -> 'worker_process_rss_bytes'
          ) = 'number' THEN
            (receipt.trace_summary ->> 'worker_process_rss_bytes')::numeric < 0
            OR (receipt.trace_summary ->> 'worker_process_rss_bytes')::numeric
              > 9223372036854775807
            OR (receipt.trace_summary ->> 'worker_process_rss_bytes')::numeric
              <> trunc((
                receipt.trace_summary ->> 'worker_process_rss_bytes'
              )::numeric)
          ELSE false
        END
      )
  ) THEN
    RAISE EXCEPTION 'otlet evaluation machine measurements must be non-negative bounded integers';
  END IF;

  IF EXISTS (
    WITH expected(category, metric, statistic, unit) AS (
      VALUES
        ('candidate_recall', 'quality', 'rate', 'ratio'),
        ('false_trust', 'false_trust', 'rate', 'ratio'),
        ('abstention', 'abstention', 'rate', 'ratio'),
        ('recovery', 'escalation', 'rate', 'ratio'),
        ('latency', 'latency_ms', 'mean', 'milliseconds'),
        ('database_impact', 'memory_bytes', 'max', 'bytes'),
        ('review_minutes', 'reviewer_seconds', 'mean', 'seconds')
    )
    SELECT 1
    FROM expected
    WHERE contract_definition #>> ARRAY['thresholds', category, 'metric']
            IS DISTINCT FROM metric
       OR contract_definition #>> ARRAY['thresholds', category, 'statistic']
            IS DISTINCT FROM statistic
       OR contract_definition #>> ARRAY['thresholds', category, 'unit']
            IS DISTINCT FROM unit
  ) OR EXISTS (
    WITH expected(category, metric) AS (
      VALUES
        ('candidate_recall', 'quality'),
        ('false_trust', 'false_trust'),
        ('abstention', 'abstention'),
        ('recovery', 'escalation'),
        ('latency', 'latency_ms'),
        ('database_impact', 'memory_bytes'),
        ('review_minutes', 'reviewer_seconds')
    )
    SELECT 1
    FROM jsonb_each(contract_definition -> 'thresholds') threshold(category, definition)
    JOIN expected ON expected.metric = threshold.definition ->> 'metric'
    WHERE expected.category <> threshold.category
  ) THEN
    RAISE EXCEPTION 'otlet evaluation thresholds do not map the required slice metrics';
  END IF;
  WITH expected(category, metric, statistic, unit) AS (
    VALUES
      ('candidate_recall', 'quality', 'rate', 'ratio'),
      ('false_trust', 'false_trust', 'rate', 'ratio'),
      ('abstention', 'abstention', 'rate', 'ratio'),
      ('recovery', 'escalation', 'rate', 'ratio'),
      ('latency', 'latency_ms', 'mean', 'milliseconds'),
      ('database_impact', 'memory_bytes', 'max', 'bytes'),
      ('review_minutes', 'reviewer_seconds', 'mean', 'seconds')
  )
  SELECT jsonb_object_agg(
    metric,
    jsonb_build_object(
      'threshold', category,
      'statistic', statistic,
      'unit', unit,
      'minimum_support', (
        contract_definition #>> ARRAY['thresholds', category, 'minimum_support']
      )::integer
    )
    ORDER BY metric
  )
  INTO support_contract
  FROM expected;

  WITH execution_evidence AS MATERIALIZED (
    SELECT
      execution.variant,
      evaluation_case.case_hash,
      evaluation_case.expected_answer,
      evaluation_case.source_table,
      result.result_hash,
      result.decision_diff,
      result.approval_diff,
      revision.definition #> '{task,decision_contract}' AS decision_contract,
      receipt_evidence.escalated,
      receipt_evidence.latency_ms,
      receipt_evidence.memory_bytes,
      terminal_receipt.candidate_output AS terminal_output,
      reviewer.seconds AS reviewer_seconds
    FROM otlet.evaluation_executions execution
    JOIN otlet.evaluation_cases evaluation_case
      ON evaluation_case.case_hash = execution.case_hash
    JOIN otlet.workload_revisions revision
      ON revision.task_name = run.task_name
     AND revision.workload_revision_hash = execution.workload_revision_hash
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    CROSS JOIN LATERAL (
      WITH receipt AS (
        SELECT
          stored.selection_role,
          COALESCE(
            stored.generate_ms::numeric,
            CASE
              WHEN jsonb_typeof(stored.trace_summary -> 'generate_ms') = 'number'
                THEN (stored.trace_summary ->> 'generate_ms')::numeric
            END
          ) AS measured_generate_ms,
          CASE
            WHEN jsonb_typeof(
              stored.trace_summary #> '{memory,after,process_rss_bytes}'
            ) = 'number' THEN (
              stored.trace_summary #>> '{memory,after,process_rss_bytes}'
            )::numeric
            WHEN jsonb_typeof(
              stored.trace_summary -> 'worker_process_rss_bytes'
            ) = 'number' THEN (
              stored.trace_summary ->> 'worker_process_rss_bytes'
            )::numeric
          END AS measured_memory_bytes
        FROM otlet.inference_receipts stored
        WHERE stored.job_id = execution.job_id
      )
      SELECT
        bool_or(receipt.selection_role = 'strong') AS escalated,
        CASE WHEN count(receipt.measured_generate_ms) = count(*)
          THEN sum(receipt.measured_generate_ms)
        END AS latency_ms,
        CASE WHEN count(receipt.measured_memory_bytes) = count(*)
          THEN max(receipt.measured_memory_bytes)
        END AS memory_bytes
      FROM receipt
    ) receipt_evidence
    LEFT JOIN LATERAL (
      SELECT stored.candidate_output
      FROM otlet.inference_receipts stored
      WHERE stored.job_id = execution.job_id
      ORDER BY stored.attempt_index DESC, stored.id DESC
      LIMIT 1
    ) terminal_receipt ON true
    LEFT JOIN LATERAL (
      SELECT (observation ->> 'seconds')::numeric AS seconds
      FROM jsonb_array_elements(normalized_reviewer_time) observation
      WHERE observation ->> 'case_hash' = execution.case_hash
        AND observation ->> 'variant' = execution.variant
    ) reviewer ON true
    WHERE execution.run_hash = run.run_hash
  ), observation AS (
    SELECT
      evidence.*,
      CASE
        WHEN evidence.result_hash IS NOT NULL
          THEN evidence.decision_diff ->> 'observed_answer'
        ELSE evidence.terminal_output ->> COALESCE(
          NULLIF(evidence.decision_contract ->> 'answer_field', ''),
          'match'
        )
      END AS observed_answer
    FROM execution_evidence evidence
  ), metric_evidence AS (
    SELECT
      observation.*,
      COALESCE(
        (observation.approval_diff ->> 'matches_expected')::boolean,
        false
      ) AS quality,
      CASE WHEN observation.result_hash IS NOT NULL THEN
        NOT COALESCE(
          (observation.approval_diff ->> 'matches_expected')::boolean,
          false
        )
      END AS false_trust,
      CASE WHEN observation.observed_answer IS NOT NULL THEN
        COALESCE(
          observation.decision_contract -> 'abstain_values',
          '["unclear"]'::jsonb
        ) ? observation.observed_answer
      END AS abstention
    FROM observation
  ), expanded AS (
    SELECT evidence.*, slice.kind AS slice_kind, slice.value AS slice_value
    FROM metric_evidence evidence
    CROSS JOIN LATERAL (VALUES
      ('overall'::text, jsonb_build_object('all', true)),
      ('expected_answer', jsonb_build_object(
        'expected_answer', evidence.expected_answer
      )),
      ('source_table', jsonb_build_object(
        'source_table', evidence.source_table
      ))
    ) slice(kind, value)
  ), rollup AS (
    SELECT
      expanded.variant,
      expanded.slice_kind,
      expanded.slice_value,
      count(*)::integer AS case_support,
      avg(expanded.quality::integer)::numeric AS quality,
      count(expanded.quality)::integer AS quality_support,
      avg(expanded.false_trust::integer)::numeric AS false_trust,
      count(expanded.false_trust)::integer AS false_trust_support,
      avg(expanded.abstention::integer)::numeric AS abstention,
      count(expanded.abstention)::integer AS abstention_support,
      avg(expanded.escalated::integer)::numeric AS escalation,
      count(expanded.escalated)::integer AS escalation_support,
      avg(expanded.latency_ms)::numeric AS latency_ms,
      count(expanded.latency_ms)::integer AS latency_support,
      max(expanded.memory_bytes)::numeric AS memory_bytes,
      count(expanded.memory_bytes)::integer AS memory_support,
      avg(expanded.reviewer_seconds)::numeric AS reviewer_seconds,
      count(expanded.reviewer_seconds)::integer AS reviewer_support
    FROM expanded
    GROUP BY expanded.variant, expanded.slice_kind, expanded.slice_value
  ), metric AS (
    SELECT
      rollup.variant,
      rollup.slice_kind,
      rollup.slice_value,
      rollup.case_support,
      value.metric,
      value.statistic,
      value.unit,
      value.value,
      value.support,
      (support_contract #>> ARRAY[value.metric, 'minimum_support'])::integer
        AS minimum_support
    FROM rollup
    CROSS JOIN LATERAL (VALUES
      ('quality'::text, 'rate'::text, 'ratio'::text,
        rollup.quality, rollup.quality_support),
      ('false_trust', 'rate', 'ratio',
        rollup.false_trust, rollup.false_trust_support),
      ('abstention', 'rate', 'ratio',
        rollup.abstention, rollup.abstention_support),
      ('escalation', 'rate', 'ratio',
        rollup.escalation, rollup.escalation_support),
      ('latency_ms', 'mean', 'milliseconds',
        rollup.latency_ms, rollup.latency_support),
      ('memory_bytes', 'max', 'bytes',
        rollup.memory_bytes, rollup.memory_support),
      ('reviewer_seconds', 'mean', 'seconds',
        rollup.reviewer_seconds, rollup.reviewer_support)
    ) value(metric, statistic, unit, value, support)
  ), slice AS (
    SELECT
      metric.variant,
      metric.slice_kind,
      metric.slice_value,
      metric.case_support,
      jsonb_object_agg(
        metric.metric,
        jsonb_build_object(
          'statistic', metric.statistic,
          'unit', metric.unit,
          'value', to_jsonb(metric.value),
          'support', metric.support,
          'minimum_support', metric.minimum_support,
          'meets_minimum_support', metric.support >= metric.minimum_support
        )
        ORDER BY metric.metric
      ) AS metrics
    FROM metric
    GROUP BY
      metric.variant,
      metric.slice_kind,
      metric.slice_value,
      metric.case_support
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'variant', slice.variant,
      'slice_kind', slice.slice_kind,
      'slice', slice.slice_value,
      'case_support', slice.case_support,
      'metrics', slice.metrics
    ) ORDER BY slice.variant, slice.slice_kind, slice.slice_value::text
  )
  INTO slices
  FROM slice;

  definition := jsonb_build_object(
    'format', 'otlet.evaluation.slices.v1',
    'run_hash', run.run_hash,
    'contract_hash', run.contract_hash,
    'population', jsonb_build_object(
      'population_kind', run_population_kind,
      'sampling_method', jsonb_build_object(
        'mode', contract_definition #>> '{population,mode}',
        'rule', (contract_definition #> '{population,rule}') - 'eligible_members'
      ),
      'observation_window', contract_definition -> 'observation_window',
      'eligible_members', normalized_members,
      'eligible_count', eligible_count,
      'labeled_count', labeled_count,
      'included_count', included_count,
      'label_coverage', labeled_count::numeric / eligible_count,
      'sample_coverage', included_count::numeric / labeled_count,
      'excluded_cases', normalized_exclusions
    ),
    'minimum_support', support_contract,
    'reviewer_time', jsonb_build_object(
      'unit', 'seconds',
      'observations', normalized_reviewer_time
    ),
    'slices', slices,
    'reason', btrim(record_evaluation_slice_report.reason),
    'non_authoritative', true
  );
  report_hash := otlet.identity_hash('evaluation_slice_report', definition);

  SELECT stored.report_hash INTO existing_hash
  FROM otlet.evaluation_slice_reports stored
  WHERE stored.run_hash = run.run_hash;
  IF FOUND THEN
    IF existing_hash IS DISTINCT FROM report_hash THEN
      RAISE EXCEPTION 'otlet evaluation run already has a different slice report';
    END IF;
    RETURN existing_hash;
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.evaluation_slice_reports (
    report_hash,
    run_hash,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    report_hash,
    run.run_hash,
    definition,
    btrim(record_evaluation_slice_report.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  RETURN report_hash;
END;
$$;

CREATE VIEW otlet.evaluation_slice_status AS
SELECT
  report.report_hash,
  report.run_hash,
  report.definition ->> 'contract_hash' AS contract_hash,
  run.task_name,
  report.definition #>> '{population,population_kind}' AS population_kind,
  report.definition #> '{population,sampling_method}' AS sampling_method,
  report.definition #> '{population,observation_window}' AS observation_window,
  (report.definition #>> '{population,eligible_count}')::integer AS eligible_count,
  (report.definition #>> '{population,labeled_count}')::integer AS labeled_count,
  (report.definition #>> '{population,included_count}')::integer AS included_count,
  (report.definition #>> '{population,label_coverage}')::numeric AS label_coverage,
  (report.definition #>> '{population,sample_coverage}')::numeric AS sample_coverage,
  report.definition #> '{population,eligible_members}' AS eligible_members,
  report.definition #> '{population,excluded_cases}' AS excluded_cases,
  report.definition -> 'minimum_support' AS minimum_support,
  slice.value ->> 'variant' AS variant,
  slice.value ->> 'slice_kind' AS slice_kind,
  slice.value -> 'slice' AS slice,
  (slice.value ->> 'case_support')::integer AS case_support,
  slice.value -> 'metrics' AS metrics,
  true AS non_authoritative,
  report.authenticated_role_name AS recorded_by,
  report.active_role_name AS recorded_as,
  report.reason,
  report.created_at
FROM otlet.evaluation_slice_reports report
JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
CROSS JOIN LATERAL jsonb_array_elements(report.definition -> 'slices') slice(value);

REVOKE ALL ON TABLE otlet.evaluation_slice_reports FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_slice_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.evaluation_slice_member_manifest_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.stamp_job_wall_clock() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_slice_run() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_slice_report() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_evaluation_slice_report(
  text, jsonb, text
) FROM PUBLIC;
