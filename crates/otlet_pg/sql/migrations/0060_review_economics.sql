CREATE TABLE otlet.review_economics_reports (
  report_hash text PRIMARY KEY CHECK (
    report_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL UNIQUE
    REFERENCES otlet.workload_acceptance_contracts(contract_hash),
  evaluation_report_hash text NOT NULL
    REFERENCES otlet.evaluation_slice_reports(report_hash),
  observations jsonb NOT NULL CHECK (jsonb_typeof(observations) = 'array'),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  reason text NOT NULL CHECK (
    NULLIF(btrim(reason), '') IS NOT NULL AND octet_length(reason) <= 4096
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

CREATE FUNCTION otlet.guard_review_economics_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.review_economics_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet review economics evidence is append only';
END;
$$;

CREATE FUNCTION otlet.review_economics_observation_manifest_valid(
  observations jsonb
) RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  observation jsonb;
  reported_avoided_work_seconds numeric;
BEGIN
  IF jsonb_typeof(observations) IS DISTINCT FROM 'array'
     OR jsonb_array_length(observations) < 1
     OR jsonb_array_length(observations) > 16384
     OR octet_length(observations::text) > 262144 THEN
    RETURN false;
  END IF;
  IF observations IS DISTINCT FROM (
    SELECT jsonb_agg(item.value ORDER BY
      item.value ->> 'variant',
      item.value ->> 'case_hash'
    )
    FROM jsonb_array_elements(observations) item(value)
  ) THEN
    RETURN false;
  END IF;
  IF (
    SELECT count(*)
    FROM jsonb_array_elements(observations) item(value)
  ) IS DISTINCT FROM (
    SELECT count(DISTINCT (item.value ->> 'variant', item.value ->> 'case_hash'))
    FROM jsonb_array_elements(observations) item(value)
  ) THEN
    RETURN false;
  END IF;

  FOR observation IN SELECT value FROM jsonb_array_elements(observations)
  LOOP
    IF jsonb_typeof(observation) IS DISTINCT FROM 'object'
       OR ARRAY(
         SELECT key FROM jsonb_object_keys(observation) key ORDER BY key
       ) IS DISTINCT FROM ARRAY[
         'case_hash',
         'reported_at',
         'reported_avoided_work_seconds',
         'reported_disposition',
         'reported_downstream_success',
         'variant'
       ]::text[]
       OR COALESCE(observation ->> 'case_hash', '')
         !~ '^otlet:v1:sha256:[0-9a-f]{64}$'
       OR COALESCE(observation ->> 'variant', '') NOT IN ('baseline', 'candidate')
       OR COALESCE(observation ->> 'reported_disposition', '')
         NOT IN ('accepted', 'corrected', 'failed', 'rejected', 'unreviewed')
       OR jsonb_typeof(observation -> 'reported_downstream_success')
         NOT IN ('boolean', 'null')
       OR jsonb_typeof(observation -> 'reported_avoided_work_seconds')
         NOT IN ('number', 'null')
       OR COALESCE(observation ->> 'reported_at', '')
         !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{6}Z$' THEN
      RETURN false;
    END IF;
    IF observation -> 'reported_avoided_work_seconds' <> 'null'::jsonb THEN
      reported_avoided_work_seconds := (
        observation ->> 'reported_avoided_work_seconds'
      )::numeric;
      IF reported_avoided_work_seconds < 0
         OR reported_avoided_work_seconds > 31536000
         OR reported_avoided_work_seconds <>
           trunc(reported_avoided_work_seconds) THEN
        RETURN false;
      END IF;
    ELSE
      reported_avoided_work_seconds := NULL;
    END IF;
    IF observation ->> 'reported_disposition'
         IN ('failed', 'rejected', 'unreviewed')
       AND (
         observation -> 'reported_downstream_success'
           IS DISTINCT FROM 'false'::jsonb
         OR COALESCE(reported_avoided_work_seconds, 0) <> 0
       ) THEN
      RETURN false;
    END IF;
    IF observation -> 'reported_downstream_success' = 'false'::jsonb
       AND COALESCE(reported_avoided_work_seconds, 0) <> 0 THEN
      RETURN false;
    END IF;
    IF COALESCE(reported_avoided_work_seconds, 0) > 0
       AND observation -> 'reported_downstream_success'
         IS DISTINCT FROM 'true'::jsonb THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN false;
END;
$$;

CREATE FUNCTION otlet.review_economics_declaration_valid(declaration jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
  IF jsonb_typeof(declaration) IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key FROM jsonb_object_keys(declaration) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'cost_unit',
       'format',
       'minimum_support',
       'model_generation_cost_per_hour',
       'reviewer_cost_per_hour'
     ]::text[]
     OR declaration ->> 'format' IS DISTINCT FROM 'otlet.review_economics.v1'
     OR COALESCE(declaration ->> 'cost_unit', '') !~ '^[A-Z][A-Z0-9_]{0,15}$'
     OR jsonb_typeof(declaration -> 'minimum_support') IS DISTINCT FROM 'number'
     OR declaration ->> 'minimum_support' !~ '^[1-9][0-9]{0,9}$'
     OR (declaration ->> 'minimum_support')::numeric > 2147483647
     OR jsonb_typeof(declaration -> 'reviewer_cost_per_hour') IS DISTINCT FROM 'number'
     OR jsonb_typeof(declaration -> 'model_generation_cost_per_hour')
       IS DISTINCT FROM 'number' THEN
    RETURN false;
  END IF;
  IF (declaration ->> 'reviewer_cost_per_hour')::numeric < 0
     OR (declaration ->> 'reviewer_cost_per_hour')::numeric > 1000000000
     OR (declaration ->> 'model_generation_cost_per_hour')::numeric < 0
     OR (declaration ->> 'model_generation_cost_per_hour')::numeric
       > 1000000000 THEN
    RETURN false;
  END IF;
  RETURN true;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN false;
END;
$$;

CREATE FUNCTION otlet.validate_review_economics_contract() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  declaration jsonb;
  eligible_members jsonb;
BEGIN
  IF NEW.definition #>> '{population,rule,kind}' IS DISTINCT FROM
       'review_economics' THEN
    RETURN NEW;
  END IF;
  declaration := NEW.definition #> '{baseline,definition}';
  eligible_members := NEW.definition #> '{population,rule,eligible_members}';
  IF NOT otlet.review_economics_declaration_valid(declaration) THEN
    RAISE EXCEPTION 'otlet review economics declaration is invalid';
  END IF;
  IF NEW.baseline_workload_revision_hash = NEW.candidate_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet review economics requires distinct revisions';
  END IF;
  IF NEW.definition #>> '{population,mode}' IS DISTINCT FROM 'full'
     OR NOT otlet.evaluation_slice_member_manifest_valid(eligible_members)
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(eligible_members) member
       WHERE (member ->> 'included')::boolean IS DISTINCT FROM true
     ) THEN
    RAISE EXCEPTION 'otlet review economics requires an exact full manifest';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_contracts_d_review_economics
BEFORE INSERT ON otlet.workload_acceptance_contracts
FOR EACH ROW EXECUTE FUNCTION otlet.validate_review_economics_contract();

CREATE FUNCTION otlet.review_economics_comparison(
  baseline numeric,
  candidate numeric,
  baseline_support integer,
  candidate_support integer,
  minimum_support integer
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT jsonb_build_object(
    'baseline', to_jsonb(comparison.baseline),
    'candidate', to_jsonb(comparison.candidate),
    'baseline_support', comparison.baseline_support,
    'candidate_support', comparison.candidate_support,
    'minimum_support', comparison.minimum_support,
    'evidence_ready', comparison.evidence_ready,
    'absolute_delta', to_jsonb(CASE
      WHEN comparison.evidence_ready
        THEN round(comparison.candidate - comparison.baseline, 12)
    END),
    'relative_delta', to_jsonb(CASE
      WHEN comparison.evidence_ready
        AND comparison.baseline = 0
        AND comparison.candidate = 0 THEN 0::numeric
      WHEN comparison.evidence_ready AND comparison.baseline <> 0
        THEN round(
          (comparison.candidate - comparison.baseline) /
            abs(comparison.baseline),
          12
        )
    END)
  )
  FROM (VALUES (
    $1,
    $2,
    $3,
    $4,
    $5,
    $1 IS NOT NULL
      AND $2 IS NOT NULL
      AND $3 >= $5
      AND $4 >= $5
  )) comparison(
    baseline,
    candidate,
    baseline_support,
    candidate_support,
    minimum_support,
    evidence_ready
  )
$$;

CREATE FUNCTION otlet.review_economics_metrics(
  evaluation_report_hash text,
  variant text,
  observations jsonb,
  reviewer_cost_per_hour numeric,
  model_generation_cost_per_hour numeric
) RETURNS jsonb
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
  WITH report AS (
    SELECT stored.run_hash
    FROM otlet.evaluation_slice_reports stored
    WHERE stored.report_hash = $1
  ), reviewer AS (
    SELECT
      observation ->> 'case_hash' AS case_hash,
      observation ->> 'variant' AS variant,
      (observation ->> 'seconds')::numeric AS seconds,
      (observation ->> 'observed_at')::timestamptz AS observed_at
    FROM otlet.evaluation_slice_reports stored
    CROSS JOIN LATERAL jsonb_array_elements(
      stored.definition #> '{reviewer_time,observations}'
    ) observation
    WHERE stored.report_hash = $1
      AND observation ->> 'variant' = $2
  ), outcome AS (
    SELECT
      observation ->> 'case_hash' AS case_hash,
      observation ->> 'variant' AS variant,
      observation ->> 'reported_disposition' AS disposition,
      (observation ->> 'reported_downstream_success')::boolean
        AS downstream_success,
      (observation ->> 'reported_avoided_work_seconds')::numeric
        AS avoided_work_seconds
    FROM jsonb_array_elements($3) observation
    WHERE observation ->> 'variant' = $2
  ), receipt_evidence AS MATERIALIZED (
    SELECT
      execution.case_hash,
      execution.workload_revision_hash,
      receipt.model_name,
      receipt.model_artifact_hash,
      receipt.runtime_name,
      receipt.selection_role AS route,
      COALESCE(
        receipt.generate_ms::numeric,
        CASE WHEN jsonb_typeof(receipt.trace_summary -> 'generate_ms') = 'number'
          THEN (receipt.trace_summary ->> 'generate_ms')::numeric
        END
      ) AS model_generation_milliseconds,
      CASE
        WHEN jsonb_typeof(
          receipt.trace_summary #> '{memory,after,process_rss_bytes}'
        ) = 'number' THEN (
          receipt.trace_summary #>> '{memory,after,process_rss_bytes}'
        )::numeric
        WHEN jsonb_typeof(
          receipt.trace_summary -> 'worker_process_rss_bytes'
        ) = 'number' THEN (
          receipt.trace_summary ->> 'worker_process_rss_bytes'
        )::numeric
      END AS process_rss_bytes
    FROM report
    JOIN otlet.evaluation_executions execution
      ON execution.run_hash = report.run_hash
     AND execution.variant = $2
    JOIN otlet.inference_receipts receipt ON receipt.job_id = execution.job_id
  ), machine_case AS (
    SELECT
      receipt.case_hash,
      count(*)::integer AS receipt_count,
      count(receipt.model_generation_milliseconds)::integer
        AS model_generation_measurement_count,
      sum(receipt.model_generation_milliseconds)
        AS model_generation_milliseconds,
      count(receipt.process_rss_bytes)::integer AS rss_measurement_count,
      max(receipt.process_rss_bytes) AS peak_process_rss_bytes
    FROM receipt_evidence receipt
    GROUP BY receipt.case_hash
  ), evidence AS MATERIALIZED (
    SELECT
      execution.case_hash,
      execution.workload_revision_hash,
      reviewer.seconds AS reviewer_seconds,
      reviewer.observed_at AS reviewer_observed_at,
      job.finished_at,
      reviewer.case_hash IS NOT NULL AS touched,
      outcome.disposition,
      outcome.downstream_success,
      outcome.avoided_work_seconds,
      machine.receipt_count,
      machine.model_generation_measurement_count,
      machine.model_generation_milliseconds,
      machine.rss_measurement_count,
      machine.peak_process_rss_bytes
    FROM report
    JOIN otlet.evaluation_executions execution
      ON execution.run_hash = report.run_hash
     AND execution.variant = $2
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN reviewer
      ON reviewer.case_hash = execution.case_hash
     AND reviewer.variant = execution.variant
    LEFT JOIN outcome
      ON outcome.case_hash = execution.case_hash
     AND outcome.variant = execution.variant
    LEFT JOIN machine_case machine ON machine.case_hash = execution.case_hash
  ), rolled AS (
    SELECT
      count(*)::integer AS case_count,
      count(*) FILTER (WHERE evidence.touched)::integer AS touched_count,
      count(*) FILTER (
        WHERE evidence.disposition = 'corrected'
      )::integer AS corrected_count,
      count(*) FILTER (
        WHERE evidence.disposition IN ('accepted', 'corrected')
      )::integer AS outcome_count,
      count(*) FILTER (
        WHERE evidence.disposition = 'rejected'
      )::integer AS rejected_count,
      count(*) FILTER (
        WHERE evidence.disposition = 'unreviewed'
      )::integer AS unreviewed_count,
      count(*) FILTER (
        WHERE evidence.disposition = 'failed'
      )::integer AS failed_count,
      count(evidence.reviewer_seconds)::integer AS reviewer_support,
      COALESCE(sum(evidence.reviewer_seconds), 0::numeric) AS reviewer_seconds,
      count(evidence.reviewer_observed_at) FILTER (
        WHERE evidence.touched
      )::integer AS review_queue_support,
      avg(extract(epoch FROM (
        evidence.reviewer_observed_at - evidence.finished_at
      ))) FILTER (WHERE evidence.touched) AS mean_review_queue_seconds,
      max(extract(epoch FROM (
        evidence.reviewer_observed_at - evidence.finished_at
      ))) FILTER (WHERE evidence.touched) AS max_review_queue_seconds,
      count(*) FILTER (
        WHERE evidence.receipt_count > 0
          AND evidence.model_generation_measurement_count =
            evidence.receipt_count
      )::integer AS model_generation_support,
      sum(evidence.model_generation_milliseconds)
        AS model_generation_milliseconds,
      count(*) FILTER (
        WHERE evidence.receipt_count > 0
          AND evidence.rss_measurement_count = evidence.receipt_count
      )::integer AS process_rss_support,
      max(evidence.peak_process_rss_bytes) AS peak_process_rss_bytes,
      count(evidence.downstream_success) FILTER (
        WHERE evidence.disposition IN ('accepted', 'corrected')
      )::integer AS downstream_support,
      count(*) FILTER (
        WHERE evidence.disposition IN ('accepted', 'corrected')
          AND evidence.downstream_success
      )::integer AS downstream_success_count,
      count(evidence.avoided_work_seconds) FILTER (
        WHERE evidence.disposition IN ('accepted', 'corrected')
      )::integer AS avoided_work_support,
      sum(evidence.avoided_work_seconds) FILTER (
        WHERE evidence.disposition IN ('accepted', 'corrected')
      ) AS avoided_work_seconds
    FROM evidence
  ), attribution AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'workload_revision_hash', grouped.workload_revision_hash,
      'model_name', grouped.model_name,
      'model_artifact_hash', grouped.model_artifact_hash,
      'runtime_name', grouped.runtime_name,
      'route', grouped.route,
      'case_count', grouped.case_count,
      'receipt_count', grouped.receipt_count,
      'model_generation_milliseconds',
        to_jsonb(grouped.model_generation_milliseconds),
      'peak_process_rss_bytes', to_jsonb(grouped.peak_process_rss_bytes)
    ) ORDER BY
      grouped.workload_revision_hash,
      grouped.model_artifact_hash,
      grouped.runtime_name,
      grouped.route
    ), '[]'::jsonb) AS groups
    FROM (
      SELECT
        receipt.workload_revision_hash,
        receipt.model_name,
        receipt.model_artifact_hash,
        receipt.runtime_name,
        receipt.route,
        count(DISTINCT receipt.case_hash)::integer AS case_count,
        count(*)::integer AS receipt_count,
        CASE WHEN count(receipt.model_generation_milliseconds) = count(*)
          THEN sum(receipt.model_generation_milliseconds)
        END AS model_generation_milliseconds,
        CASE WHEN count(receipt.process_rss_bytes) = count(*)
          THEN max(receipt.process_rss_bytes)
        END AS peak_process_rss_bytes
      FROM receipt_evidence receipt
      GROUP BY
        receipt.workload_revision_hash,
        receipt.model_name,
        receipt.model_artifact_hash,
        receipt.runtime_name,
        receipt.route
    ) grouped
  ), metric AS (
    SELECT
      rolled.*,
      attribution.groups,
      round(rolled.reviewer_seconds / 3600 * $4, 12) AS reviewer_cost,
      round(
        rolled.model_generation_milliseconds / 3600000 * $5,
        12
      ) AS model_generation_cost
    FROM rolled CROSS JOIN attribution
  )
  SELECT jsonb_build_object(
    'variant', $2,
    'case_count', metric.case_count,
    'evaluation_reviewer_touch', jsonb_build_object(
      'count', metric.touched_count,
      'evidence_kind', 'content_bound_evaluation_reviewer_observation',
      'rate', to_jsonb(round(
        metric.touched_count::numeric / NULLIF(metric.case_count, 0),
        12
      ))
    ),
    'reported_correction', jsonb_build_object(
      'count', metric.corrected_count,
      'touched_support', metric.touched_count,
      'evidence_kind', 'authenticated_role_attested_external_observation',
      'rate', to_jsonb(round(
        metric.corrected_count::numeric / NULLIF(metric.touched_count, 0),
        12
      ))
    ),
    'reported_outcomes', jsonb_build_object(
      'accepted_or_corrected', metric.outcome_count,
      'rejected', metric.rejected_count,
      'unreviewed', metric.unreviewed_count,
      'failed', metric.failed_count,
      'evidence_kind', 'authenticated_role_attested_external_observation'
    ),
    'reviewer_time', jsonb_build_object(
      'support', metric.reviewer_support,
      'seconds', to_jsonb(metric.reviewer_seconds),
      'minutes', to_jsonb(round(metric.reviewer_seconds / 60, 12)),
      'minutes_per_reported_accepted_or_corrected', to_jsonb(round(
        metric.reviewer_seconds / 60 / NULLIF(metric.outcome_count, 0),
        12
      )),
      'evidence_kind', 'content_bound_evaluation_reviewer_observation',
      'denominator_evidence_kind',
        'authenticated_role_attested_external_observation'
    ),
    'evaluation_review_wait', jsonb_build_object(
      'support', metric.review_queue_support,
      'mean_seconds', to_jsonb(round(metric.mean_review_queue_seconds, 12)),
      'max_seconds', to_jsonb(round(metric.max_review_queue_seconds, 12)),
      'evidence_kind', 'content_bound_evaluation_reviewer_observation',
      'definition', 'reported_review_at_minus_evaluation_job_finished_at'
    ),
    'machine', jsonb_build_object(
      'support', metric.model_generation_support,
      'model_generation_milliseconds',
        to_jsonb(metric.model_generation_milliseconds),
      'process_rss_support', metric.process_rss_support,
      'peak_process_rss_bytes', to_jsonb(metric.peak_process_rss_bytes),
      'process_rss_definition', 'shared_worker_process_snapshot_not_costed',
      'costed_measurement', 'model_generation_time_only',
      'attribution', metric.groups
    ),
    'reported_downstream', jsonb_build_object(
      'support', metric.downstream_support,
      'success_count', metric.downstream_success_count,
      'evidence_kind', 'authenticated_role_attested_external_observation',
      'success_rate', to_jsonb(round(
        metric.downstream_success_count::numeric /
          NULLIF(metric.downstream_support, 0),
        12
      ))
    ),
    'reported_avoided_work', jsonb_build_object(
      'support', metric.avoided_work_support,
      'evidence_kind', 'authenticated_role_attested_external_observation',
      'seconds', to_jsonb(metric.avoided_work_seconds),
      'minutes', to_jsonb(round(metric.avoided_work_seconds / 60, 12)),
      'minutes_per_reported_accepted_or_corrected', to_jsonb(round(
        metric.avoided_work_seconds / 60 / NULLIF(metric.outcome_count, 0),
        12
      ))
    ),
    'estimated_cost', jsonb_build_object(
      'reviewer', to_jsonb(metric.reviewer_cost),
      'model_generation', to_jsonb(metric.model_generation_cost),
      'total', to_jsonb(round(
        metric.reviewer_cost + metric.model_generation_cost,
        12
      )),
      'per_reported_accepted_or_corrected', to_jsonb(round(
        (metric.reviewer_cost + metric.model_generation_cost) /
        NULLIF(metric.outcome_count, 0),
        12
      )),
      'denominator_evidence_kind',
        'authenticated_role_attested_external_observation'
    )
  )
  FROM metric
$$;

CREATE FUNCTION otlet.validate_review_economics_report() RETURNS trigger
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
     OR NOT otlet.review_economics_observation_manifest_valid(NEW.observations)
     OR ARRAY(
       SELECT key FROM jsonb_object_keys(NEW.definition) key ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'baseline_metrics',
       'candidate_metrics',
       'comparisons',
       'contract_hash',
       'cost',
       'evaluation_report_hash',
       'evidence_ready',
       'format',
       'minimum_support',
       'non_authoritative',
       'observations_hash',
       'reason'
     ]::text[]
     OR NEW.definition ->> 'format' IS DISTINCT FROM
       'otlet.review_economics.report.v1'
     OR NEW.definition ->> 'contract_hash' IS DISTINCT FROM NEW.contract_hash
     OR NEW.definition ->> 'evaluation_report_hash' IS DISTINCT FROM
       NEW.evaluation_report_hash
     OR NEW.definition ->> 'observations_hash' IS DISTINCT FROM
       otlet.identity_hash('review_economics_observations', NEW.observations)
     OR NEW.definition ->> 'reason' IS DISTINCT FROM NEW.reason
     OR jsonb_typeof(NEW.definition -> 'evidence_ready')
       IS DISTINCT FROM 'boolean'
     OR NEW.definition -> 'evidence_ready' IS DISTINCT FROM to_jsonb(NOT EXISTS (
       SELECT 1
       FROM jsonb_each(NEW.definition -> 'comparisons') comparison(key, value)
       WHERE comparison.value -> 'evidence_ready' IS DISTINCT FROM 'true'::jsonb
     ))
     OR NEW.definition -> 'non_authoritative' IS DISTINCT FROM 'true'::jsonb
     OR jsonb_typeof(NEW.definition -> 'baseline_metrics') IS DISTINCT FROM
       'object'
     OR jsonb_typeof(NEW.definition -> 'candidate_metrics') IS DISTINCT FROM
       'object'
     OR jsonb_typeof(NEW.definition -> 'cost') IS DISTINCT FROM 'object'
     OR jsonb_typeof(NEW.definition -> 'comparisons') IS DISTINCT FROM 'object'
     OR ARRAY(
       SELECT key
       FROM jsonb_object_keys(NEW.definition -> 'comparisons') key
       ORDER BY key
     ) IS DISTINCT FROM ARRAY[
       'estimated_cost_per_reported_accepted_or_corrected',
       'evaluation_reviewer_touch_rate',
       'evaluation_review_wait_mean_seconds',
       'model_generation_milliseconds',
       'reported_avoided_work_minutes_per_reported_accepted_or_corrected',
       'reported_correction_rate',
       'reported_downstream_success_rate',
       'reviewer_minutes_per_reported_accepted_or_corrected'
     ]::text[]
     OR NEW.report_hash IS DISTINCT FROM
       otlet.identity_hash('review_economics_report', NEW.definition) THEN
    RAISE EXCEPTION 'otlet review economics report identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER review_economics_reports_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.review_economics_reports
FOR EACH ROW EXECUTE FUNCTION otlet.guard_review_economics_append();

CREATE TRIGGER review_economics_reports_b_validate
BEFORE INSERT ON otlet.review_economics_reports
FOR EACH ROW EXECUTE FUNCTION otlet.validate_review_economics_report();

CREATE TRIGGER review_economics_reports_truncate_guard
BEFORE TRUNCATE ON otlet.review_economics_reports
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_review_economics_append();

CREATE FUNCTION otlet.record_review_economics_report(
  contract_hash text,
  evaluation_report_hash text,
  observations jsonb,
  reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
SET timezone = 'UTC'
AS $$
DECLARE
  contract otlet.workload_acceptance_contracts%ROWTYPE;
  declaration jsonb;
  evaluation_report record;
  baseline_metrics jsonb;
  candidate_metrics jsonb;
  comparisons jsonb;
  evidence_ready boolean;
  definition jsonb;
  report_hash text;
  existing_report otlet.review_economics_reports%ROWTYPE;
  minimum_support integer;
  window_starts_at timestamptz;
  window_ends_at timestamptz;
  previous_append text := current_setting('otlet.review_economics_append', true);
BEGIN
  IF NULLIF(btrim(record_review_economics_report.reason), '') IS NULL
     OR octet_length(record_review_economics_report.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet review economics report reason is required and bounded';
  END IF;
  IF NOT otlet.review_economics_observation_manifest_valid(
    record_review_economics_report.observations
  ) THEN
    RAISE EXCEPTION 'otlet review economics observations are invalid';
  END IF;
  SELECT * INTO contract
  FROM otlet.workload_acceptance_contracts stored
  WHERE stored.contract_hash = record_review_economics_report.contract_hash
    AND stored.definition #>> '{population,rule,kind}' = 'review_economics';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review economics contract does not exist';
  END IF;
  declaration := contract.definition #> '{baseline,definition}';
  minimum_support := (declaration ->> 'minimum_support')::integer;
  window_starts_at := (
    contract.definition #>> '{observation_window,starts_at}'
  )::timestamptz;
  window_ends_at := (
    contract.definition #>> '{observation_window,ends_at}'
  )::timestamptz;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_review_economics_report:' || contract.contract_hash,
    0
  ));
  SELECT * INTO existing_report
  FROM otlet.review_economics_reports stored
  WHERE stored.contract_hash = contract.contract_hash;
  IF FOUND THEN
    IF existing_report.evaluation_report_hash IS DISTINCT FROM
         record_review_economics_report.evaluation_report_hash
       OR existing_report.observations IS DISTINCT FROM
         record_review_economics_report.observations
       OR existing_report.reason IS DISTINCT FROM
         btrim(record_review_economics_report.reason) THEN
      RAISE EXCEPTION 'otlet review economics contract already has a different report';
    END IF;
    RETURN existing_report.report_hash;
  END IF;

  SELECT
    report.run_hash,
    report.created_at,
    report.definition,
    run.task_name,
    run.baseline_workload_revision_hash,
    run.candidate_workload_revision_hash,
    run.case_hashes
  INTO evaluation_report
  FROM otlet.evaluation_slice_reports report
  JOIN otlet.evaluation_runs run ON run.run_hash = report.run_hash
  WHERE report.report_hash =
    record_review_economics_report.evaluation_report_hash;
  IF NOT FOUND
     OR evaluation_report.definition ->> 'contract_hash' IS DISTINCT FROM
       contract.contract_hash
     OR evaluation_report.definition #>> '{population,sampling_method,mode}'
       IS DISTINCT FROM 'full'
     OR evaluation_report.task_name IS DISTINCT FROM contract.task_name
     OR evaluation_report.baseline_workload_revision_hash IS DISTINCT FROM
       contract.baseline_workload_revision_hash
     OR evaluation_report.candidate_workload_revision_hash IS DISTINCT FROM
       contract.candidate_workload_revision_hash
     OR evaluation_report.created_at < window_ends_at THEN
    RAISE EXCEPTION 'otlet review economics evaluation report is invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      (
        SELECT execution.case_hash, execution.variant
        FROM otlet.evaluation_executions execution
        WHERE execution.run_hash = evaluation_report.run_hash
        EXCEPT
        SELECT
          observation ->> 'case_hash',
          observation ->> 'variant'
        FROM jsonb_array_elements(
          record_review_economics_report.observations
        ) observation
      )
      UNION ALL
      (
        SELECT
          observation ->> 'case_hash',
          observation ->> 'variant'
        FROM jsonb_array_elements(
          record_review_economics_report.observations
        ) observation
        EXCEPT
        SELECT execution.case_hash, execution.variant
        FROM otlet.evaluation_executions execution
        WHERE execution.run_hash = evaluation_report.run_hash
      )
    ) difference
  ) THEN
    RAISE EXCEPTION 'otlet review economics observations must exactly match the paired run';
  END IF;

  IF EXISTS (
    WITH observation AS (
      SELECT item.value
      FROM jsonb_array_elements(
        record_review_economics_report.observations
      ) item(value)
    ), reviewer AS (
      SELECT item.value
      FROM jsonb_array_elements(
        evaluation_report.definition #> '{reviewer_time,observations}'
      ) item(value)
    )
    SELECT 1
    FROM observation
    JOIN otlet.evaluation_executions execution
      ON execution.run_hash = evaluation_report.run_hash
     AND execution.case_hash = observation.value ->> 'case_hash'
     AND execution.variant = observation.value ->> 'variant'
    JOIN otlet.jobs job ON job.id = execution.job_id
    LEFT JOIN otlet.evaluation_results result
      ON result.run_hash = execution.run_hash
     AND result.case_hash = execution.case_hash
     AND result.variant = execution.variant
    LEFT JOIN reviewer
      ON reviewer.value ->> 'case_hash' = execution.case_hash
     AND reviewer.value ->> 'variant' = execution.variant
    WHERE job.status NOT IN ('complete', 'failed')
       OR job.finished_at IS NULL
       OR (job.status = 'complete' AND result.result_hash IS NULL)
       OR (job.status = 'failed' AND result.result_hash IS NOT NULL)
       OR (observation.value ->> 'reported_disposition' = 'failed')
         IS DISTINCT FROM
         (job.status = 'failed')
       OR (observation.value ->> 'reported_at')::timestamptz < window_starts_at
       OR (observation.value ->> 'reported_at')::timestamptz >= window_ends_at
       OR (observation.value ->> 'reported_at')::timestamptz < job.finished_at
       OR (
         reviewer.value IS NOT NULL
         AND (
           (reviewer.value ->> 'observed_at')::timestamptz < job.finished_at
           OR (observation.value ->> 'reported_at')::timestamptz <
             (reviewer.value ->> 'observed_at')::timestamptz
           OR reviewer.value ->> 'evidence_hash' IS DISTINCT FROM
             otlet.identity_hash(
               'review_economics_reviewer_time',
               reviewer.value - 'evidence_hash'
             )
         )
       )
       OR (
         observation.value ->> 'reported_disposition'
           IN ('corrected', 'rejected')
         AND reviewer.value IS NULL
       )
       OR (
         observation.value ->> 'reported_disposition' = 'unreviewed'
         AND reviewer.value IS NOT NULL
       )
       OR (
         observation.value ->> 'reported_disposition' = 'accepted'
         AND NOT (
           COALESCE(
             (result.decision_diff ->> 'answer_matches')::boolean,
             false
           )
           AND COALESCE(
             (result.approval_diff ->> 'expected_action_present')::boolean,
             false
           )
         )
       )
       OR (
         observation.value ->> 'reported_disposition' = 'unreviewed'
         AND (
           COALESCE(
             (result.decision_diff ->> 'answer_matches')::boolean,
             false
           )
           AND COALESCE(
             (result.approval_diff ->> 'expected_action_present')::boolean,
             false
           )
         )
       )
  ) THEN
    RAISE EXCEPTION 'otlet review economics observation evidence is inconsistent';
  END IF;

  baseline_metrics := otlet.review_economics_metrics(
    record_review_economics_report.evaluation_report_hash,
    'baseline',
    record_review_economics_report.observations,
    (declaration ->> 'reviewer_cost_per_hour')::numeric,
    (declaration ->> 'model_generation_cost_per_hour')::numeric
  );
  candidate_metrics := otlet.review_economics_metrics(
    record_review_economics_report.evaluation_report_hash,
    'candidate',
    record_review_economics_report.observations,
    (declaration ->> 'reviewer_cost_per_hour')::numeric,
    (declaration ->> 'model_generation_cost_per_hour')::numeric
  );
  IF baseline_metrics IS NULL OR candidate_metrics IS NULL
     OR (baseline_metrics ->> 'case_count')::integer < minimum_support
     OR (candidate_metrics ->> 'case_count')::integer < minimum_support
     OR (baseline_metrics #>>
       '{reported_outcomes,accepted_or_corrected}')::integer
       < minimum_support
     OR (candidate_metrics #>>
       '{reported_outcomes,accepted_or_corrected}')::integer
       < minimum_support
     OR (baseline_metrics #>> '{reviewer_time,support}')::integer IS DISTINCT FROM
       (baseline_metrics #>> '{evaluation_reviewer_touch,count}')::integer
     OR (candidate_metrics #>> '{reviewer_time,support}')::integer IS DISTINCT FROM
       (candidate_metrics #>> '{evaluation_reviewer_touch,count}')::integer
     OR (baseline_metrics #>> '{evaluation_review_wait,support}')::integer
       IS DISTINCT FROM
       (baseline_metrics #>> '{evaluation_reviewer_touch,count}')::integer
     OR (candidate_metrics #>> '{evaluation_review_wait,support}')::integer
       IS DISTINCT FROM
       (candidate_metrics #>> '{evaluation_reviewer_touch,count}')::integer
     OR (baseline_metrics #>> '{machine,support}')::integer IS DISTINCT FROM
       (baseline_metrics ->> 'case_count')::integer
     OR (candidate_metrics #>> '{machine,support}')::integer IS DISTINCT FROM
       (candidate_metrics ->> 'case_count')::integer
     OR (baseline_metrics #>> '{machine,process_rss_support}')::integer
       IS DISTINCT FROM (baseline_metrics ->> 'case_count')::integer
     OR (candidate_metrics #>> '{machine,process_rss_support}')::integer
       IS DISTINCT FROM (candidate_metrics ->> 'case_count')::integer
     OR (baseline_metrics #>> '{reported_downstream,support}')::integer
       IS DISTINCT FROM
       (baseline_metrics #>>
         '{reported_outcomes,accepted_or_corrected}')::integer
     OR (candidate_metrics #>> '{reported_downstream,support}')::integer
       IS DISTINCT FROM (candidate_metrics #>>
         '{reported_outcomes,accepted_or_corrected}')::integer
     OR (baseline_metrics #>> '{reported_avoided_work,support}')::integer
       IS DISTINCT FROM (baseline_metrics #>>
         '{reported_outcomes,accepted_or_corrected}')::integer
     OR (candidate_metrics #>> '{reported_avoided_work,support}')::integer
       IS DISTINCT FROM (candidate_metrics #>>
         '{reported_outcomes,accepted_or_corrected}')::integer THEN
    RAISE EXCEPTION 'otlet review economics evidence is insufficient';
  END IF;

  comparisons := jsonb_build_object(
    'evaluation_reviewer_touch_rate', otlet.review_economics_comparison(
      (baseline_metrics #>> '{evaluation_reviewer_touch,rate}')::numeric,
      (candidate_metrics #>> '{evaluation_reviewer_touch,rate}')::numeric,
      (baseline_metrics ->> 'case_count')::integer,
      (candidate_metrics ->> 'case_count')::integer,
      minimum_support
    ),
    'reported_correction_rate', otlet.review_economics_comparison(
      (baseline_metrics #>> '{reported_correction,rate}')::numeric,
      (candidate_metrics #>> '{reported_correction,rate}')::numeric,
      (baseline_metrics #>> '{reported_correction,touched_support}')::integer,
      (candidate_metrics #>> '{reported_correction,touched_support}')::integer,
      minimum_support
    ),
    'reviewer_minutes_per_reported_accepted_or_corrected',
      otlet.review_economics_comparison(
        (baseline_metrics #>>
          '{reviewer_time,minutes_per_reported_accepted_or_corrected}')::numeric,
        (candidate_metrics #>>
          '{reviewer_time,minutes_per_reported_accepted_or_corrected}')::numeric,
        (baseline_metrics #>>
          '{reported_outcomes,accepted_or_corrected}')::integer,
        (candidate_metrics #>>
          '{reported_outcomes,accepted_or_corrected}')::integer,
        minimum_support
      ),
    'evaluation_review_wait_mean_seconds', otlet.review_economics_comparison(
      (baseline_metrics #>> '{evaluation_review_wait,mean_seconds}')::numeric,
      (candidate_metrics #>> '{evaluation_review_wait,mean_seconds}')::numeric,
      (baseline_metrics #>> '{evaluation_review_wait,support}')::integer,
      (candidate_metrics #>> '{evaluation_review_wait,support}')::integer,
      minimum_support
    ),
    'model_generation_milliseconds', otlet.review_economics_comparison(
      (baseline_metrics #>>
        '{machine,model_generation_milliseconds}')::numeric,
      (candidate_metrics #>>
        '{machine,model_generation_milliseconds}')::numeric,
      (baseline_metrics #>> '{machine,support}')::integer,
      (candidate_metrics #>> '{machine,support}')::integer,
      minimum_support
    ),
    'reported_downstream_success_rate', otlet.review_economics_comparison(
      (baseline_metrics #>> '{reported_downstream,success_rate}')::numeric,
      (candidate_metrics #>> '{reported_downstream,success_rate}')::numeric,
      (baseline_metrics #>> '{reported_downstream,support}')::integer,
      (candidate_metrics #>> '{reported_downstream,support}')::integer,
      minimum_support
    ),
    'reported_avoided_work_minutes_per_reported_accepted_or_corrected',
      otlet.review_economics_comparison(
        (baseline_metrics #>>
          '{reported_avoided_work,minutes_per_reported_accepted_or_corrected}')::numeric,
        (candidate_metrics #>>
          '{reported_avoided_work,minutes_per_reported_accepted_or_corrected}')::numeric,
        (baseline_metrics #>> '{reported_avoided_work,support}')::integer,
        (candidate_metrics #>> '{reported_avoided_work,support}')::integer,
        minimum_support
      ),
    'estimated_cost_per_reported_accepted_or_corrected',
      otlet.review_economics_comparison(
        (baseline_metrics #>>
          '{estimated_cost,per_reported_accepted_or_corrected}')::numeric,
        (candidate_metrics #>>
          '{estimated_cost,per_reported_accepted_or_corrected}')::numeric,
        (baseline_metrics #>>
          '{reported_outcomes,accepted_or_corrected}')::integer,
        (candidate_metrics #>>
          '{reported_outcomes,accepted_or_corrected}')::integer,
        minimum_support
      )
  );
  SELECT bool_and(
    comparison.value -> 'evidence_ready' = 'true'::jsonb
  ) INTO evidence_ready
  FROM jsonb_each(comparisons) comparison(key, value);
  definition := jsonb_build_object(
    'format', 'otlet.review_economics.report.v1',
    'contract_hash', contract.contract_hash,
    'evaluation_report_hash',
      record_review_economics_report.evaluation_report_hash,
    'observations_hash', otlet.identity_hash(
      'review_economics_observations',
      record_review_economics_report.observations
    ),
    'minimum_support', minimum_support,
    'cost', jsonb_build_object(
      'unit', declaration ->> 'cost_unit',
      'reviewer_per_hour',
        (declaration ->> 'reviewer_cost_per_hour')::numeric,
      'model_generation_per_hour',
        (declaration ->> 'model_generation_cost_per_hour')::numeric
    ),
    'baseline_metrics', baseline_metrics,
    'candidate_metrics', candidate_metrics,
    'comparisons', comparisons,
    'evidence_ready', evidence_ready,
    'reason', btrim(record_review_economics_report.reason),
    'non_authoritative', true
  );
  report_hash := otlet.identity_hash('review_economics_report', definition);

  PERFORM set_config('otlet.review_economics_append', 'on', true);
  INSERT INTO otlet.review_economics_reports (
    report_hash,
    contract_hash,
    evaluation_report_hash,
    observations,
    definition,
    reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    report_hash,
    contract.contract_hash,
    record_review_economics_report.evaluation_report_hash,
    record_review_economics_report.observations,
    definition,
    btrim(record_review_economics_report.reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config(
    'otlet.review_economics_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN report_hash;
END;
$$;

CREATE VIEW otlet.review_economics_status AS
SELECT
  contract.contract_hash,
  contract.task_name,
  contract.baseline_workload_revision_hash,
  contract.candidate_workload_revision_hash,
  NOT EXISTS (
    SELECT 1
    FROM otlet.workload_acceptance_contracts successor
    WHERE successor.task_name = contract.task_name
      AND successor.supersedes_contract_hash = contract.contract_hash
  ) AS current_contract,
  contract.definition -> 'observation_window' AS observation_window,
  contract.definition #>> '{baseline,definition,cost_unit}' AS cost_unit,
  (contract.definition #>>
    '{baseline,definition,reviewer_cost_per_hour}')::numeric
    AS reviewer_cost_per_hour,
  (contract.definition #>>
    '{baseline,definition,model_generation_cost_per_hour}')::numeric
    AS model_generation_cost_per_hour,
  (contract.definition #>> '{baseline,definition,minimum_support}')::integer
    AS minimum_support,
  report.report_hash,
  report.evaluation_report_hash,
  report.definition -> 'baseline_metrics' AS baseline_metrics,
  report.definition -> 'candidate_metrics' AS candidate_metrics,
  report.definition -> 'comparisons' AS comparisons,
  COALESCE((report.definition ->> 'evidence_ready')::boolean, false)
    AS evidence_ready,
  CASE WHEN report.report_hash IS NULL
    THEN 'insufficient_evidence'
    WHEN (report.definition ->> 'evidence_ready')::boolean THEN 'ready'
    ELSE 'partial_evidence'
  END AS status,
  true AS non_authoritative,
  report.authenticated_role_name AS recorded_by,
  report.active_role_name AS recorded_as,
  report.reason,
  report.created_at
FROM otlet.workload_acceptance_contracts contract
LEFT JOIN otlet.review_economics_reports report
  ON report.contract_hash = contract.contract_hash
WHERE contract.definition #>> '{population,rule,kind}' = 'review_economics';

REVOKE ALL ON TABLE otlet.review_economics_reports FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_economics_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_review_economics_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_economics_observation_manifest_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_economics_declaration_valid(jsonb)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_review_economics_contract() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_economics_comparison(
  numeric, numeric, integer, integer, integer
)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_economics_metrics(
  text, text, jsonb, numeric, numeric
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_review_economics_report() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_review_economics_report(
  text, text, jsonb, text
) FROM PUBLIC;
