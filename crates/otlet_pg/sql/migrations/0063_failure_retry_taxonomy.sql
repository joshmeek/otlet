CREATE TABLE otlet.failure_taxonomy (
  failure_reason_code text PRIMARY KEY CHECK (
    failure_reason_code ~ '^otlet[.]failure[.]v[1-9][0-9]*[.][a-z0-9][a-z0-9_]{0,127}$'
  ),
  taxonomy_version integer NOT NULL CHECK (taxonomy_version > 0),
  reason_code text NOT NULL CHECK (reason_code ~ '^[a-z0-9][a-z0-9_]{0,127}$'),
  stage text NOT NULL CHECK (stage IN (
    'unknown',
    'worker_startup',
    'claim',
    'admission',
    'model_load',
    'inference',
    'output_validation',
    'selection',
    'completion',
    'cancellation'
  )),
  retryability text NOT NULL CHECK (retryability IN (
    'automatic',
    'manual_retry',
    'after_owner_action',
    'never'
  )),
  owner_action text NOT NULL CHECK (owner_action ~ '^[a-z0-9][a-z0-9_]{0,127}$'),
  recommended_retry_mode text CHECK (
    recommended_retry_mode IS NULL
    OR recommended_retry_mode IN ('original_snapshot', 'latest_source')
  ),
  raw_detail_visibility text NOT NULL CHECK (
    raw_detail_visibility = 'database_owner_only'
  ),
  UNIQUE (taxonomy_version, reason_code),
  CHECK (
    failure_reason_code =
      'otlet.failure.v' || taxonomy_version::text || '.' || reason_code
  )
);

INSERT INTO otlet.failure_taxonomy (
  failure_reason_code,
  taxonomy_version,
  reason_code,
  stage,
  retryability,
  owner_action,
  recommended_retry_mode,
  raw_detail_visibility
)
VALUES
  ('otlet.failure.v1.canceled', 1, 'canceled', 'cancellation', 'manual_retry', 'application_retry_job', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.source_contract_rejected', 1, 'source_contract_rejected', 'admission', 'after_owner_action', 'repair_workload', 'latest_source', 'database_owner_only'),
  ('otlet.failure.v1.workload_revision_unavailable', 1, 'workload_revision_unavailable', 'claim', 'after_owner_action', 'repair_workload', 'latest_source', 'database_owner_only'),
  ('otlet.failure.v1.attempts_exhausted', 1, 'attempts_exhausted', 'claim', 'manual_retry', 'application_retry_job', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.attempt_timeout', 1, 'attempt_timeout', 'inference', 'manual_retry', 'application_retry_job', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.artifact_rejected', 1, 'artifact_rejected', 'model_load', 'after_owner_action', 'replace_artifact', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.model_identity_rejected', 1, 'model_identity_rejected', 'model_load', 'after_owner_action', 'repair_worker_registration', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.runtime_configuration_rejected', 1, 'runtime_configuration_rejected', 'admission', 'after_owner_action', 'repair_runtime_options', 'latest_source', 'database_owner_only'),
  ('otlet.failure.v1.resource_admission_rejected', 1, 'resource_admission_rejected', 'admission', 'after_owner_action', 'repair_runtime_capacity', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.output_validation_failed', 1, 'output_validation_failed', 'output_validation', 'after_owner_action', 'inspect_model_and_contract', 'latest_source', 'database_owner_only'),
  ('otlet.failure.v1.decision_rejected', 1, 'decision_rejected', 'selection', 'never', 'review_or_correct', NULL, 'database_owner_only'),
  ('otlet.failure.v1.database_contract_rejected', 1, 'database_contract_rejected', 'completion', 'after_owner_action', 'repair_database_contract', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.runtime_failed', 1, 'runtime_failed', 'inference', 'manual_retry', 'application_retry_job', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.terminalization_failed', 1, 'terminalization_failed', 'completion', 'after_owner_action', 'repair_database_contract', 'original_snapshot', 'database_owner_only'),
  ('otlet.failure.v1.claim_lost', 1, 'claim_lost', 'claim', 'automatic', 'wait', NULL, 'database_owner_only'),
  ('otlet.failure.v1.unclassified', 1, 'unclassified', 'unknown', 'after_owner_action', 'inspect_owner_detail', 'original_snapshot', 'database_owner_only');

CREATE FUNCTION otlet.reject_failure_taxonomy_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'otlet failure taxonomy rows are immutable; add a new taxonomy version';
END;
$$;

CREATE TRIGGER failure_taxonomy_immutable
BEFORE UPDATE OR DELETE ON otlet.failure_taxonomy
FOR EACH ROW EXECUTE FUNCTION otlet.reject_failure_taxonomy_change();

CREATE FUNCTION otlet.failure_reason_from_slug(slug text) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  normalized text := lower(btrim(COALESCE(failure_reason_from_slug.slug, '')));
BEGIN
  IF normalized LIKE 'otlet_error:%:%' THEN
    normalized := split_part(normalized, ':', 2);
  END IF;
  IF normalized LIKE 'otlet.failure.v1.%' THEN
    normalized := substring(normalized FROM length('otlet.failure.v1.') + 1);
  END IF;
  IF normalized IN (
    'canceled',
    'source_contract_rejected',
    'workload_revision_unavailable',
    'attempts_exhausted',
    'attempt_timeout',
    'artifact_rejected',
    'model_identity_rejected',
    'runtime_configuration_rejected',
    'resource_admission_rejected',
    'output_validation_failed',
    'decision_rejected',
    'database_contract_rejected',
    'runtime_failed',
    'terminalization_failed',
    'claim_lost',
    'unclassified'
  ) THEN
    RETURN 'otlet.failure.v1.' || normalized;
  END IF;

  IF normalized = '' THEN
    RETURN NULL;
  ELSIF normalized IN (
    'canceled',
    'cancel_requested',
    'job_canceled'
  ) THEN
    RETURN 'otlet.failure.v1.canceled';
  ELSIF normalized IN (
    'source_field_allowlist_violation',
    'source_contract_rejected'
  ) OR normalized LIKE '%source field allowlist violation%' THEN
    RETURN 'otlet.failure.v1.source_contract_rejected';
  ELSIF normalized IN (
    'workload_revision_missing',
    'workload_revision_changed_after_lease_expired'
  ) OR normalized LIKE '%missing workload revision%'
     OR normalized LIKE '%workload revision changed%' THEN
    RETURN 'otlet.failure.v1.workload_revision_unavailable';
  ELSIF normalized = 'job_lease_expired_after_max_attempts'
     OR normalized LIKE '%lease expired after max attempts%' THEN
    RETURN 'otlet.failure.v1.attempts_exhausted';
  ELSIF normalized = 'attempt_timeout'
     OR normalized LIKE '%attempt timeout%' THEN
    RETURN 'otlet.failure.v1.attempt_timeout';
  ELSIF normalized IN (
    'model_artifact_identity_invalid',
    'model_artifact_identity_mismatch',
    'model_hash_mismatch',
    'model_identity_missing',
    'model_identity_mismatch',
    'model_not_allowlisted',
    'portable_model_identity_missing',
    'portable_model_identity_mismatch'
  ) THEN
    RETURN 'otlet.failure.v1.model_identity_rejected';
  ELSIF normalized LIKE 'model_artifact_%' THEN
    RETURN 'otlet.failure.v1.artifact_rejected';
  ELSIF normalized IN (
    'configuration_error',
    'configuration_invalid',
    'invalid_context_window',
    'prompt_and_generation_exceed_context_window',
    'prompt_exceeds_context_window',
    'portable_runtime_options_rejected',
    'runtime_contract_mismatch',
    'runtime_options_rejected'
  ) THEN
    RETURN 'otlet.failure.v1.runtime_configuration_rejected';
  ELSIF normalized IN (
    'artifact_exceeds_max_worker_rss_bytes',
    'current_rss_exceeds_max_worker_rss_bytes',
    'model_load_admission_rejected',
    'portable_worker_rss_budget_exceeded',
    'portable_worker_rss_unavailable',
    'worker_rss_budget_exceeded',
    'worker_rss_sample_unavailable',
    'worker_rss_unavailable'
  ) THEN
    RETURN 'otlet.failure.v1.resource_admission_rejected';
  ELSIF normalized IN (
    'invalid_model_json',
    'invalid_output_envelope',
    'invalid_output_schema',
    'portable_model_output_invalid_envelope',
    'portable_model_output_invalid_json',
    'schema_or_json_validation_failed',
    'schema_validation_failed'
  ) THEN
    RETURN 'otlet.failure.v1.output_validation_failed';
  ELSIF normalized IN (
    'abstained_output',
    'confidence_below_policy',
    'direct_rejected_by_decision_contract',
    'missing_confidence_field',
    'missing_decision_field'
  ) THEN
    RETURN 'otlet.failure.v1.decision_rejected';
  ELSIF normalized IN (
    'complete_job_failed',
    'complete_job_produced_no_output',
    'complete_job_spi_failed',
    'failed_attempt_receipt_failed',
    'failure_persistence_failed',
    'rejected_receipt_failed',
    'result_persistence_failed'
  ) OR normalized LIKE 'fail_job_spi_failed:%' THEN
    RETURN 'otlet.failure.v1.terminalization_failed';
  ELSIF normalized IN (
    'credentials_rejected',
    'database_contract_denied',
    'database_contract_invalid',
    'database_contract_missing',
    'database_rejected',
    'portable_result_rejected_by_database',
    'protocol_incompatible',
    'result_rejected_by_database',
    'runtime_not_allowlisted',
    'tls_not_active',
    'tls_verification_failed'
  ) THEN
    RETURN 'otlet.failure.v1.database_contract_rejected';
  ELSIF normalized = 'claim_lost' THEN
    RETURN 'otlet.failure.v1.claim_lost';
  ELSIF normalized IN (
    'cheap_runtime_failed',
    'direct_attempt_failed',
    'infer_now_timeout_cancel_failed',
    'local_inference_failed',
    'model_error',
    'runtime_failed',
    'strong_attempt_failed',
    'worker_failed'
  ) THEN
    RETURN 'otlet.failure.v1.runtime_failed';
  END IF;

  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.classify_failure_reason(
  failure_status text,
  selection_role text DEFAULT NULL,
  selection_reason text DEFAULT NULL,
  schema_validation_status text DEFAULT NULL,
  trace_summary jsonb DEFAULT '{}'::jsonb,
  error text DEFAULT NULL,
  runtime_name text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  classified text;
BEGIN
  IF classify_failure_reason.failure_status NOT IN ('failed', 'rejected', 'canceled') THEN
    RETURN NULL;
  END IF;
  IF classify_failure_reason.failure_status = 'canceled' THEN
    RETURN 'otlet.failure.v1.canceled';
  END IF;

  classified := otlet.failure_reason_from_slug(classify_failure_reason.error);
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  classified := otlet.failure_reason_from_slug(
    COALESCE(classify_failure_reason.trace_summary, '{}'::jsonb) ->> 'stop_reason'
  );
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  classified := otlet.failure_reason_from_slug(classify_failure_reason.selection_reason);
  IF classified IS NOT NULL THEN
    RETURN classified;
  END IF;

  IF classify_failure_reason.failure_status = 'rejected' THEN
    RETURN 'otlet.failure.v1.decision_rejected';
  END IF;
  IF classify_failure_reason.schema_validation_status = 'failed' THEN
    RETURN 'otlet.failure.v1.output_validation_failed';
  END IF;
  IF classify_failure_reason.runtime_name IS NOT NULL THEN
    RETURN 'otlet.failure.v1.runtime_failed';
  END IF;
  RETURN 'otlet.failure.v1.unclassified';
END;
$$;

ALTER TABLE otlet.jobs
ADD COLUMN failure_reason_code text;

ALTER TABLE otlet.inference_receipts
ADD COLUMN failure_reason_code text;

UPDATE otlet.inference_receipts receipt
SET failure_reason_code = otlet.classify_failure_reason(
  receipt.status,
  receipt.selection_role,
  receipt.selection_reason,
  receipt.schema_validation_status,
  receipt.trace_summary,
  receipt.error,
  receipt.runtime_name
)
WHERE receipt.status IN ('failed', 'rejected', 'canceled');

UPDATE otlet.jobs job
SET failure_reason_code = COALESCE(
  NULLIF(
    otlet.classify_failure_reason(
      job.status,
      NULL,
      NULL,
      NULL,
      '{}'::jsonb,
      job.error,
      NULL
    ),
    'otlet.failure.v1.unclassified'
  ),
  (
    SELECT receipt.failure_reason_code
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = job.id
      AND receipt.failure_reason_code IS NOT NULL
    ORDER BY receipt.attempt_index DESC, receipt.id DESC
    LIMIT 1
  ),
  'otlet.failure.v1.unclassified'
)
WHERE job.status IN ('failed', 'canceled');

ALTER TABLE otlet.jobs
ADD CONSTRAINT jobs_failure_reason_state_check CHECK (
  (status IN ('failed', 'canceled')) = (failure_reason_code IS NOT NULL)
),
ADD CONSTRAINT jobs_failure_reason_fk FOREIGN KEY (failure_reason_code)
  REFERENCES otlet.failure_taxonomy(failure_reason_code);

ALTER TABLE otlet.inference_receipts
ADD CONSTRAINT inference_receipts_failure_reason_state_check CHECK (
  (status IN ('failed', 'rejected', 'canceled')) = (failure_reason_code IS NOT NULL)
),
ADD CONSTRAINT inference_receipts_failure_reason_fk FOREIGN KEY (failure_reason_code)
  REFERENCES otlet.failure_taxonomy(failure_reason_code);

CREATE FUNCTION otlet.assign_receipt_failure_reason() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.failure_reason_code := otlet.classify_failure_reason(
    NEW.status,
    NEW.selection_role,
    NEW.selection_reason,
    NEW.schema_validation_status,
    NEW.trace_summary,
    NEW.error,
    NEW.runtime_name
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER inference_receipts_failure_reason
BEFORE INSERT OR UPDATE OF
  status,
  selection_role,
  selection_reason,
  schema_validation_status,
  trace_summary,
  error,
  runtime_name,
  failure_reason_code
ON otlet.inference_receipts
FOR EACH ROW EXECUTE FUNCTION otlet.assign_receipt_failure_reason();

CREATE FUNCTION otlet.assign_job_failure_reason() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  direct_reason text;
BEGIN
  IF NEW.status NOT IN ('failed', 'canceled') THEN
    NEW.failure_reason_code := NULL;
    RETURN NEW;
  END IF;

  direct_reason := otlet.classify_failure_reason(
    NEW.status,
    NULL,
    NULL,
    NULL,
    '{}'::jsonb,
    NEW.error,
    NULL
  );
  IF direct_reason IS DISTINCT FROM 'otlet.failure.v1.unclassified' THEN
    NEW.failure_reason_code := direct_reason;
    RETURN NEW;
  END IF;

  SELECT receipt.failure_reason_code
  INTO NEW.failure_reason_code
  FROM otlet.inference_receipts receipt
  WHERE receipt.job_id = NEW.id
    AND receipt.failure_reason_code IS NOT NULL
  ORDER BY receipt.attempt_index DESC, receipt.id DESC
  LIMIT 1;

  NEW.failure_reason_code := COALESCE(
    NEW.failure_reason_code,
    'otlet.failure.v1.unclassified'
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_failure_reason
BEFORE INSERT OR UPDATE OF status, error, failure_reason_code
ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.assign_job_failure_reason();

CREATE VIEW otlet.failure_retry_status AS
WITH retry_children AS (
  SELECT child.retry_of_job_id AS job_id, count(*)::bigint AS retry_child_count
  FROM otlet.jobs child
  WHERE child.retry_of_job_id IS NOT NULL
  GROUP BY child.retry_of_job_id
),
job_failures AS (
  SELECT
    'job'::text AS failure_scope,
    job.id AS occurrence_id,
    job.id AS job_id,
    NULL::bigint AS receipt_id,
    job.task_name,
    job.subject_id,
    CASE
      WHEN latest.runtime_name LIKE 'portable:%' THEN 'portable'
      WHEN latest.runtime_name IS NULL THEN 'sql'
      ELSE 'native'
    END AS execution_path,
    job.status AS failure_status,
    latest.selection_role,
    latest.selection_reason,
    job.failure_reason_code,
    taxonomy.taxonomy_version,
    taxonomy.reason_code,
    taxonomy.stage,
    taxonomy.retryability,
    taxonomy.owner_action,
    taxonomy.recommended_retry_mode,
    taxonomy.raw_detail_visibility,
    (job.error IS NOT NULL) AS raw_detail_available,
    (job.application_owner_role_oid IS NOT NULL) AS application_owned,
    (job.application_owner_role_oid IS NOT NULL) AS application_retry_available,
    job.retry_of_job_id,
    job.retry_mode,
    COALESCE(children.retry_child_count, 0) AS retry_child_count,
    job.started_at,
    job.finished_at
  FROM otlet.jobs job
  JOIN otlet.failure_taxonomy taxonomy
    ON taxonomy.failure_reason_code = job.failure_reason_code
  LEFT JOIN retry_children children ON children.job_id = job.id
  LEFT JOIN LATERAL (
    SELECT
      receipt.runtime_name,
      receipt.selection_role,
      receipt.selection_reason
    FROM otlet.inference_receipts receipt
    WHERE receipt.job_id = job.id
    ORDER BY receipt.attempt_index DESC, receipt.id DESC
    LIMIT 1
  ) latest ON true
  WHERE job.status IN ('failed', 'canceled')
),
receipt_failures AS (
  SELECT
    'receipt'::text AS failure_scope,
    receipt.id AS occurrence_id,
    receipt.job_id,
    receipt.id AS receipt_id,
    receipt.task_name,
    receipt.subject_id,
    CASE
      WHEN receipt.runtime_name LIKE 'portable:%' THEN 'portable'
      WHEN receipt.runtime_name IS NULL THEN 'sql'
      ELSE 'native'
    END AS execution_path,
    receipt.status AS failure_status,
    receipt.selection_role,
    receipt.selection_reason,
    receipt.failure_reason_code,
    taxonomy.taxonomy_version,
    taxonomy.reason_code,
    taxonomy.stage,
    taxonomy.retryability,
    taxonomy.owner_action,
    taxonomy.recommended_retry_mode,
    taxonomy.raw_detail_visibility,
    (receipt.error IS NOT NULL) AS raw_detail_available,
    (job.application_owner_role_oid IS NOT NULL) AS application_owned,
    (
      job.application_owner_role_oid IS NOT NULL
      AND job.status IN ('failed', 'canceled')
    ) AS application_retry_available,
    job.retry_of_job_id,
    job.retry_mode,
    COALESCE(children.retry_child_count, 0) AS retry_child_count,
    receipt.started_at,
    receipt.finished_at
  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  JOIN otlet.failure_taxonomy taxonomy
    ON taxonomy.failure_reason_code = receipt.failure_reason_code
  LEFT JOIN retry_children children ON children.job_id = job.id
  WHERE receipt.status IN ('failed', 'rejected', 'canceled')
)
SELECT * FROM job_failures
UNION ALL
SELECT * FROM receipt_failures;

CREATE OR REPLACE VIEW otlet.redaction_policy_status AS
WITH policy AS (
  SELECT sensitive_evidence_mode, sensitive_evidence_retention
  FROM otlet.production_policy
  WHERE name = 'default'
),
observed AS (
  SELECT
    count(*) FILTER (WHERE r.raw_output IS NOT NULL)::bigint AS raw_output_rows,
    count(*) FILTER (
      WHERE r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
    )::bigint AS chosen_text_rows,
    COALESCE(sum(jsonb_array_length(jsonb_path_query_array(
      r.trace_summary,
      '$.detailed_trace.steps[*].token_text'
    ))), 0)::bigint AS token_text_values,
    COALESCE(sum(jsonb_array_length(jsonb_path_query_array(
      r.trace_summary,
      '$.detailed_trace.steps[*].top_alternatives[*].token_text'
    ))), 0)::bigint AS alternative_token_text_values,
    count(*) FILTER (
      WHERE (
        p.sensitive_evidence_mode = 'redacted'
        OR r.finished_at < now() - p.sensitive_evidence_retention
      )
      AND (
        r.raw_output IS NOT NULL
        OR r.trace_summary #>> '{detailed_trace,chosen_text}' IS NOT NULL
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].token_text')
        OR jsonb_path_exists(r.trace_summary, '$.detailed_trace.steps[*].top_alternatives[*].token_text')
      )
    )::bigint AS overdue_sensitive_rows,
    count(*) FILTER (
      WHERE r.trace_summary #> '{evidence_redaction,structured_output}' = 'true'::jsonb
    )::bigint AS structured_output_redacted_receipts,
    count(*) FILTER (
      WHERE r.trace_summary #> '{evidence_redaction,actions}' = 'true'::jsonb
    )::bigint AS action_redacted_receipts
  FROM otlet.inference_receipts r
  CROSS JOIN policy p
),
configured AS (
  SELECT
    count(*) FILTER (
      WHERE jsonb_array_length(COALESCE(t.decision_contract -> 'redact_output_fields', '[]'::jsonb)) > 0
    )::bigint AS structured_output_redaction_tasks,
    count(*) FILTER (
      WHERE jsonb_array_length(COALESCE(t.decision_contract -> 'redact_action_fields', '[]'::jsonb)) > 0
    )::bigint AS action_redaction_tasks
  FROM otlet.tasks t
)
SELECT
  'stored_sensitive_evidence'::text AS policy_name,
  3::integer AS policy_version,
  'hash_only'::text AS assembled_prompt_storage,
  p.sensitive_evidence_mode,
  p.sensitive_evidence_retention,
  (p.sensitive_evidence_mode = 'diagnostic') AS raw_output_allowed_at_write,
  (p.sensitive_evidence_mode = 'diagnostic') AS token_text_allowed_at_write,
  o.raw_output_rows,
  o.chosen_text_rows,
  o.token_text_values,
  o.alternative_token_text_values,
  o.overdue_sensitive_rows,
  c.structured_output_redaction_tasks,
  c.action_redaction_tasks,
  o.structured_output_redacted_receipts,
  o.action_redacted_receipts,
  (o.overdue_sensitive_rows = 0) AS storage_compliant,
  false AS prompts_visible,
  false AS raw_output_visible,
  false AS token_steps_visible,
  false AS source_row_visible,
  ARRAY[
    'prompt',
    'raw_output',
    'token_steps',
    'top_k_alternatives',
    'source_row',
    'trace_summary',
    'job_error',
    'receipt_error'
  ]::text[] AS withheld_fields,
  ARRAY[
    'otlet.audit_receipt_export',
    'otlet.audit_review_export',
    'otlet.audit_review_event_export',
    'otlet.audit_action_execution_export',
    'otlet.audit_eval_label_export',
    'otlet.audit_administrative_change_export',
    'otlet.action_workflow_policy_status',
    'otlet.semantic_dependency_audit',
    'otlet.operational_event_log',
    'otlet.worker_batch_timing_status',
    'otlet.access_policy_status',
    'otlet.failure_retry_status'
  ]::text[] AS export_views,
  'Assembled prompts are hash-only. Audit exports omit job input, raw output, candidate output, token detail, full trace summaries, and raw job and receipt errors. Task configuration and active job input remain database-owner-only.'::text AS notes
FROM policy p
CROSS JOIN observed o
CROSS JOIN configured c;

ALTER FUNCTION otlet.application_job_status(bigint)
RENAME TO application_job_status_previous;

CREATE FUNCTION otlet.application_job_status(requested_job_id bigint)
RETURNS TABLE (
  job_id bigint,
  status text,
  trusted_output jsonb,
  failure_reason_code text,
  failure_stage text,
  failure_retryability text,
  failure_owner_action text,
  recommended_retry_mode text,
  raw_detail_visibility text,
  retry_of_job_id bigint,
  retry_mode text,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  cancel_requested_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT
    job.id,
    job.status,
    output.output,
    job.failure_reason_code,
    taxonomy.stage,
    taxonomy.retryability,
    taxonomy.owner_action,
    taxonomy.recommended_retry_mode,
    taxonomy.raw_detail_visibility,
    job.retry_of_job_id,
    job.retry_mode,
    job.created_at,
    job.started_at,
    job.finished_at,
    job.cancel_requested_at
  FROM otlet.jobs job
  LEFT JOIN otlet.outputs output ON output.job_id = job.id
  LEFT JOIN otlet.failure_taxonomy taxonomy
    ON taxonomy.failure_reason_code = job.failure_reason_code
  WHERE job.id = application_job_status.requested_job_id
    AND job.application_owner_role_oid = (
      SELECT role.oid
      FROM pg_catalog.pg_roles role
      WHERE role.rolname = session_user
    )
$$;

DO $$
DECLARE
  grant_row record;
BEGIN
  FOR grant_row IN
    SELECT role.rolname AS role_name, privilege.is_grantable
    FROM pg_catalog.pg_proc routine
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(
        routine.proacl,
        pg_catalog.acldefault('f', routine.proowner)
      )
    ) privilege
    JOIN pg_catalog.pg_roles role ON role.oid = privilege.grantee
    WHERE routine.oid = 'otlet.application_job_status_previous(bigint)'::regprocedure
      AND privilege.privilege_type = 'EXECUTE'
      AND role.oid <> routine.proowner
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION otlet.application_job_status(bigint) TO %I%s',
      grant_row.role_name,
      CASE WHEN grant_row.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
    );
  END LOOP;
END;
$$;

DROP FUNCTION otlet.application_job_status_previous(bigint);

CREATE OR REPLACE FUNCTION otlet.grant_auditor_access(target_role regrole) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  old_revision_hash text;
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'otlet_access_policy:' || grant_auditor_access.target_role::oid::text,
      0
    )
  );
  old_revision_hash := otlet.access_policy_revision(
    grant_auditor_access.target_role
  );
  SELECT rolname
  INTO role_name
  FROM pg_catalog.pg_roles
  WHERE oid = grant_auditor_access.target_role::oid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'role with oid % does not exist', grant_auditor_access.target_role::oid;
  END IF;

  EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA otlet TO %I', role_name);
  EXECUTE pg_catalog.format(
    'GRANT SELECT ON TABLE '
    'otlet.redaction_policy_status, '
    'otlet.audit_receipt_export, '
    'otlet.audit_review_export, '
    'otlet.audit_review_event_export, '
    'otlet.audit_action_execution_export, '
    'otlet.audit_eval_label_export, '
    'otlet.action_workflow_policy_status, '
    'otlet.semantic_dependency_audit, '
    'otlet.operational_event_log, '
    'otlet.worker_batch_timing_status, '
    'otlet.portable_protocol_status, '
    'otlet.runtime_capability_status, '
    'otlet.portable_worker_status, '
    'otlet.portable_claim_status, '
    'otlet.portable_receipt_status, '
    'otlet.failure_taxonomy, '
    'otlet.failure_retry_status TO %I',
    role_name
  );
  IF pg_catalog.to_regclass('otlet.portable_schema_migrations') IS NULL THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.access_policy_status TO %I',
      role_name
    );
  END IF;
  EXECUTE pg_catalog.format(
    'GRANT EXECUTE ON FUNCTION '
    'otlet.semantic_canonical_jsonb(jsonb), '
    'otlet.portable_canonical_json_text(jsonb), '
    'otlet.portable_text_hash(text), '
    'otlet.portable_json_hash(jsonb), '
    'otlet.linked_runtime_capabilities(), '
    'otlet.identity_hash(text, jsonb), '
    'otlet.identity_text_hash(text, text), '
    'otlet.semantic_source_hash(jsonb), '
    'otlet.semantic_shaped_input(jsonb, jsonb), '
    'otlet.semantic_content_hash(jsonb, jsonb), '
    'otlet.action_execution_role_oid(), '
    'otlet.bounded_action_target_contract(text), '
    'otlet.action_target_contract_hash(text), '
    'otlet.action_target_validation_error(text), '
    'otlet.action_workflow_policy_error(text, text, text, text, text, boolean), '
    'otlet.source_role_descriptor(oid), '
    'otlet.source_relation_descriptor(oid, oid, jsonb), '
    'otlet.source_function_descriptor(oid, oid), '
    'otlet.source_query_binding_descriptor(jsonb, jsonb, jsonb, jsonb), '
    'otlet.source_query_contract_error(jsonb, boolean) TO %I',
    role_name
  );
  PERFORM otlet.finish_access_policy_grant(
    'auditor',
    grant_auditor_access.target_role,
    old_revision_hash
  );
END;
$$;

DO $$
DECLARE
  role_name text;
  portable_install boolean := pg_catalog.to_regclass(
    'otlet.portable_schema_migrations'
  ) IS NOT NULL;
BEGIN
  FOR role_name IN
    SELECT role.rolname
    FROM pg_catalog.pg_roles role
    WHERE role.oid <> (
      SELECT relation.relowner
      FROM pg_catalog.pg_class relation
      WHERE relation.oid = 'otlet.audit_receipt_export'::regclass
    )
      AND (
        SELECT count(DISTINCT relation.oid)
        FROM pg_catalog.unnest(ARRAY[
          'otlet.redaction_policy_status',
          'otlet.access_policy_status',
          'otlet.audit_receipt_export',
          'otlet.audit_review_export',
          'otlet.audit_review_event_export',
          'otlet.audit_action_execution_export',
          'otlet.audit_eval_label_export',
          'otlet.audit_administrative_change_export',
          'otlet.action_workflow_policy_status',
          'otlet.semantic_dependency_audit',
          'otlet.operational_event_log',
          'otlet.worker_batch_timing_status',
          'otlet.portable_protocol_status',
          'otlet.runtime_capability_status',
          'otlet.portable_worker_status',
          'otlet.portable_claim_status',
          'otlet.portable_receipt_status'
        ]::text[]) expected(name)
        JOIN pg_catalog.pg_class relation
          ON relation.oid = pg_catalog.to_regclass(expected.name)
        CROSS JOIN LATERAL pg_catalog.aclexplode(relation.relacl) privilege
        WHERE (expected.name <> 'otlet.access_policy_status' OR NOT portable_install)
          AND privilege.grantee = role.oid
          AND privilege.privilege_type = 'SELECT'
      ) = CASE WHEN portable_install THEN 16 ELSE 17 END
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.failure_taxonomy, otlet.failure_retry_status TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.failure_taxonomy FROM PUBLIC;
REVOKE ALL ON TABLE otlet.failure_retry_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.failure_reason_from_slug(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.classify_failure_reason(text, text, text, text, jsonb, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reject_failure_taxonomy_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.assign_receipt_failure_reason() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.assign_job_failure_reason() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.application_job_status(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_auditor_access(regrole) FROM PUBLIC;
