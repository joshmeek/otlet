CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  index_row record;
  join_row record;
  current_contract_hash text;
  bounded_sample_limit integer := NULLIF(GREATEST(COALESCE(sample_limit, 0), 0), 0);
  sample_clause text := '';
  sample_detail jsonb := '{}'::jsonb;
BEGIN
  IF bounded_sample_limit IS NOT NULL THEN
    sample_clause := format('ORDER BY subject_id LIMIT %s', bounded_sample_limit);
    sample_detail := jsonb_build_object(
      'scan_mode',
      'sampled',
      'sample_limit',
      bounded_sample_limit
    );
  END IF;

  RETURN QUERY
  SELECT
    'one_accepted_output_per_job'::text,
    'job'::text,
    o.job_id::text,
    jsonb_build_object('output_count', count(*))
  FROM otlet.outputs o
  GROUP BY o.job_id
  HAVING count(*) > 1;

  RETURN QUERY
  SELECT
    'every_output_has_accepted_receipt'::text,
    'output'::text,
    o.id::text,
    jsonb_build_object(
      'job_id', o.job_id,
      'receipt_id', o.receipt_id,
      'receipt_status', r.status,
      'selection_status', r.selection_status,
      'schema_validation_status', r.schema_validation_status,
      'receipt_job_id', r.job_id,
      'job_status', j.status
    )
  FROM otlet.outputs o
  LEFT JOIN otlet.inference_receipts r ON r.id = o.receipt_id
  LEFT JOIN otlet.jobs j ON j.id = o.job_id
  WHERE r.id IS NULL
     OR r.job_id IS DISTINCT FROM o.job_id
     OR r.status IS DISTINCT FROM 'complete'
     OR r.selection_status IS DISTINCT FROM 'accepted'
     OR r.schema_validation_status IS DISTINCT FROM 'passed'
     OR j.status IS DISTINCT FROM 'complete';

  RETURN QUERY
  SELECT
    'no_action_without_receipt_lineage'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'job_id', a.job_id,
      'output_id', a.output_id,
      'receipt_id', a.receipt_id,
      'receipt_job_id', r.job_id,
      'output_job_id', o.job_id,
      'output_receipt_id', o.receipt_id
    )
  FROM otlet.actions a
  LEFT JOIN otlet.inference_receipts r ON r.id = a.receipt_id
  LEFT JOIN otlet.outputs o ON o.id = a.output_id
  WHERE a.receipt_id IS NULL
     OR r.id IS NULL
     OR r.job_id IS DISTINCT FROM a.job_id
     OR a.output_id IS NULL
     OR o.id IS NULL
     OR o.job_id IS DISTINCT FROM a.job_id
     OR o.receipt_id IS DISTINCT FROM a.receipt_id;

  RETURN QUERY
  SELECT
    'queued_jobs_within_model_cap'::text,
    'model'::text,
    q.model_name::text,
    jsonb_build_object(
      'queued_jobs',
      q.queued_jobs,
      'max_queued_jobs_per_model',
      q.max_queued_jobs_per_model
    )
  FROM (
    SELECT
      m.name AS model_name,
      count(j.id)::bigint AS queued_jobs,
      p.max_queued_jobs_per_model
    FROM otlet.production_policy p
    JOIN otlet.models m ON true
    LEFT JOIN otlet.tasks t ON t.model_name = m.name
    LEFT JOIN otlet.jobs j ON j.task_name = t.name AND j.status = 'queued'
    GROUP BY m.name, p.max_queued_jobs_per_model
  ) q
  WHERE q.queued_jobs > q.max_queued_jobs_per_model;

  RETURN QUERY
  SELECT
    'queued_input_bytes_within_model_cap'::text,
    'model'::text,
    q.model_name,
    jsonb_build_object(
      'queued_input_bytes', q.queued_input_bytes,
      'max_queued_input_bytes_per_model', q.max_queued_input_bytes_per_model
    )
  FROM (
    SELECT
      m.name AS model_name,
      COALESCE(sum(octet_length(j.input::text)), 0)::bigint AS queued_input_bytes,
      p.max_queued_input_bytes_per_model
    FROM otlet.production_policy p
    CROSS JOIN otlet.models m
    LEFT JOIN otlet.tasks t ON t.model_name = m.name
    LEFT JOIN otlet.jobs j ON j.task_name = t.name AND j.status = 'queued'
    GROUP BY m.name, p.max_queued_input_bytes_per_model
  ) q
  WHERE q.queued_input_bytes > q.max_queued_input_bytes_per_model;

  RETURN QUERY
  SELECT
    'total_queued_input_bytes_within_cap'::text,
    'queue'::text,
    p.name,
    jsonb_build_object(
      'queued_input_bytes', q.queued_input_bytes,
      'max_queued_input_bytes_total', p.max_queued_input_bytes_total
    )
  FROM otlet.production_policy p
  CROSS JOIN LATERAL (
    SELECT COALESCE(sum(octet_length(j.input::text)), 0)::bigint AS queued_input_bytes
    FROM otlet.jobs j
    WHERE j.status = 'queued'
  ) q
  WHERE q.queued_input_bytes > p.max_queued_input_bytes_total;

  RETURN QUERY
  SELECT
    'queued_input_within_per_job_cap'::text,
    'job'::text,
    j.id::text,
    jsonb_build_object(
      'input_bytes', octet_length(j.input::text),
      'max_input_bytes_per_job', p.max_input_bytes_per_job
    )
  FROM otlet.jobs j
  CROSS JOIN otlet.production_policy p
  WHERE j.status = 'queued'
    AND octet_length(j.input::text) > p.max_input_bytes_per_job;

  RETURN QUERY
  SELECT
    'no_applied_action_without_approval'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'action_type', a.action_type,
      'status', a.status,
      'approval_status', a.approval_status,
      'apply_status', a.apply_status
    )
  FROM otlet.actions a
  WHERE a.apply_status IN ('applied', 'replayed')
    AND a.approval_status IS DISTINCT FROM 'approved';

  RETURN QUERY
  SELECT
    'workflow_actions_match_task_allowlist'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'task_name', j.task_name,
      'action_type', a.action_type,
      'status', a.status
    )
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  JOIN otlet.tasks t ON t.name = j.task_name
  WHERE a.authority_origin = 'workflow'
    AND a.status <> 'rejected'
    AND NOT COALESCE(t.decision_contract -> 'action_types', '[]'::jsonb) ? a.action_type;

  RETURN QUERY
  SELECT
    'accepted_updates_match_workflow_authority'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'task_name', j.task_name,
      'target_name', a.target_name,
      'subject_namespace', a.subject_namespace,
      'authority_error', otlet.action_workflow_policy_error(
        j.task_name,
        a.action_type,
        a.authority_policy_hash,
        a.target_name,
        a.subject_namespace,
        false
      )
    )
  FROM otlet.actions a
  JOIN otlet.jobs j ON j.id = a.job_id
  WHERE a.action_type = 'update_row'
    AND a.status <> 'rejected'
    AND (
      a.authority_origin <> 'workflow'
      OR otlet.action_workflow_policy_error(
        j.task_name,
        a.action_type,
        a.authority_policy_hash,
        a.target_name,
        a.subject_namespace,
        false
      ) IS NOT NULL
    );

  RETURN QUERY
  SELECT
    'applied_updates_have_mutation_authority'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'authority_origin', a.authority_origin,
      'authority_mode', a.authority_mode,
      'evaluation_status', a.evaluation_status,
      'target_name', a.target_name,
      'payload_target', a.payload #>> '{body,target}'
    )
  FROM otlet.actions a
  WHERE a.action_type = 'update_row'
    AND a.apply_status IN ('applied', 'replayed')
    AND (
      a.authority_origin <> 'workflow'
      OR a.authority_mode <> 'bounded_mutation'
      OR a.evaluation_status <> 'evaluated'
      OR a.authority_policy_hash !~ '^[0-9a-f]{32}$'
      OR a.target_name IS NULL
      OR a.subject_namespace IS NULL
      OR a.payload #>> '{body,target}' IS DISTINCT FROM a.target_name
      OR a.dry_run_status <> 'passed'
      OR a.approval_status <> 'approved'
    );

  RETURN QUERY
  SELECT
    'applied_updates_have_execution_receipts'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'status', a.status,
      'apply_status', a.apply_status,
      'idempotency_key_present', a.idempotency_key IS NOT NULL
    )
  FROM otlet.actions a
  WHERE a.action_type = 'update_row'
    AND a.status = 'applied'
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.action_execution_receipts er
      WHERE er.action_id = a.id
        AND er.mode = 'apply'
        AND er.status IN ('applied', 'replayed')
    );

  RETURN QUERY
  SELECT
    'successful_execution_receipts_have_applied_actions'::text,
    'action_execution_receipt'::text,
    er.id::text,
    jsonb_build_object(
      'action_id', er.action_id,
      'receipt_status', er.status,
      'action_status', a.status
    )
  FROM otlet.action_execution_receipts er
  LEFT JOIN otlet.actions a ON a.id = er.action_id
  WHERE er.mode = 'apply'
    AND er.status IN ('applied', 'replayed')
    AND (a.id IS NULL OR a.status IS DISTINCT FROM 'applied');

  RETURN QUERY
  SELECT
    'update_actions_have_bounded_identity'::text,
    'action'::text,
    a.id::text,
    jsonb_build_object(
      'source_table_present', a.source_table IS NOT NULL,
      'subject_id_present', a.subject_id IS NOT NULL,
      'idempotency_key_present', a.idempotency_key IS NOT NULL,
      'target_present', NULLIF(a.payload #>> '{body,target}', '') IS NOT NULL
    )
  FROM otlet.actions a
  WHERE a.action_type = 'update_row'
    AND a.status <> 'rejected'
    AND (
      a.source_table IS NULL
      OR a.subject_id IS NULL
      OR a.idempotency_key IS NULL
      OR NULLIF(a.payload #>> '{body,target}', '') IS NULL
    );

  RETURN QUERY
  SELECT
    'no_expired_running_jobs'::text,
    'job'::text,
    j.id::text,
    jsonb_build_object(
      'status', j.status,
      'leased_until', j.leased_until,
      'attempts', j.attempts
    )
  FROM otlet.jobs j
  WHERE j.status IN ('running', 'cancel_requested')
    AND (j.leased_until IS NULL OR j.leased_until < now());

  RETURN QUERY
  SELECT
    'active_jobs_have_claim_tokens'::text,
    'job'::text,
    j.id::text,
    jsonb_build_object('status', j.status, 'attempts', j.attempts)
  FROM otlet.jobs j
  WHERE j.status IN ('running', 'cancel_requested')
    AND j.claim_token IS NULL;

  RETURN QUERY
  SELECT
    'complete_receipts_are_schema_validated'::text,
    'receipt'::text,
    r.id::text,
    jsonb_build_object(
      'job_id', r.job_id,
      'status', r.status,
      'schema_validation_status', r.schema_validation_status
    )
  FROM otlet.inference_receipts r
  WHERE r.status = 'complete'
    AND r.schema_validation_status IS DISTINCT FROM 'passed';

  RETURN QUERY
  SELECT
    'complete_receipts_have_portable_identities'::text,
    'receipt'::text,
    r.id::text,
    jsonb_build_object(
      'job_id', r.job_id,
      'task_identity_hash', r.task_identity_hash,
      'source_identity_hash', r.source_identity_hash,
      'model_identity_hash', r.model_identity_hash,
      'runtime_options_hash', r.runtime_options_hash,
      'prompt_hash', r.prompt_hash,
      'input_hash', r.input_hash,
      'output_schema_hash', r.output_schema_hash,
      'output_hash', r.output_hash,
      'actions_hash', r.actions_hash,
      'validation_version', r.trace_summary #>> '{portable_validation,version}'
    )
  FROM otlet.inference_receipts r
  WHERE r.status = 'complete'
    AND (
      r.task_identity_hash IS NULL
      OR r.source_identity_hash IS NULL
      OR r.model_identity_hash IS NULL
      OR r.runtime_options_hash IS NULL
      OR r.prompt_hash IS NULL
      OR r.input_hash IS NULL
      OR r.output_schema_hash IS NULL
      OR r.output_hash IS NULL
      OR r.actions_hash IS NULL
      OR r.trace_summary #>> '{portable_validation,version}'
        IS DISTINCT FROM 'otlet_portable_validation_v1'
    );

  RETURN QUERY
  SELECT
    'portable_live_claims_match_jobs'::text,
    'portable_claim'::text,
    c.id::text,
    jsonb_build_object(
      'job_id', c.job_id,
      'worker_id', c.worker_id,
      'claim_status', c.status,
      'job_status', j.status
    )
  FROM otlet.portable_claims c
  JOIN otlet.jobs j ON j.id = c.job_id
  WHERE c.status IN ('claimed', 'renewed')
    AND (
      j.status NOT IN ('running', 'cancel_requested')
      OR j.claim_token IS NULL
      OR c.claim_token_hash IS DISTINCT FROM otlet.portable_text_hash(j.claim_token)
    );

  RETURN QUERY
  SELECT
    'portable_terminal_claims_match_jobs'::text,
    'portable_claim'::text,
    c.id::text,
    jsonb_build_object(
      'job_id', c.job_id,
      'worker_id', c.worker_id,
      'claim_status', c.status,
      'job_status', j.status
    )
  FROM otlet.portable_claims c
  JOIN otlet.jobs j ON j.id = c.job_id
  WHERE c.status IN ('complete', 'failed', 'canceled')
    AND c.status IS DISTINCT FROM j.status;

  RETURN QUERY
  SELECT
    'portable_receipts_match_claims'::text,
    'receipt'::text,
    r.id::text,
    jsonb_build_object(
      'claim_id', c.id,
      'claim_job_id', c.job_id,
      'receipt_job_id', r.job_id,
      'runtime_name', r.runtime_name,
      'runtime_endpoint', r.runtime_endpoint
    )
  FROM otlet.portable_receipt_links l
  JOIN otlet.portable_claims c ON c.id = l.claim_id
  JOIN otlet.inference_receipts r ON r.id = l.receipt_id
  WHERE r.job_id IS DISTINCT FROM c.job_id
     OR r.runtime_name NOT LIKE 'portable:%'
     OR r.runtime_endpoint IS DISTINCT FROM 'postgres_rpc';

  RETURN QUERY
  SELECT
    'enabled_portable_workers_have_database_roles'::text,
    'portable_worker'::text,
    w.worker_id,
    jsonb_build_object('database_role_oid', w.database_role_oid)
  FROM otlet.portable_workers w
  WHERE w.enabled
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_roles r
      WHERE r.oid = w.database_role_oid
    );

  RETURN QUERY
  SELECT
    'sensitive_storage_matches_policy'::text,
    'redaction_policy'::text,
    s.policy_name,
    jsonb_build_object(
      'sensitive_evidence_mode', s.sensitive_evidence_mode,
      'raw_output_rows', s.raw_output_rows,
      'chosen_text_rows', s.chosen_text_rows,
      'token_text_values', s.token_text_values,
      'alternative_token_text_values', s.alternative_token_text_values,
      'overdue_sensitive_rows', s.overdue_sensitive_rows
    )
  FROM otlet.redaction_policy_status s
  WHERE NOT s.storage_compliant;

  RETURN QUERY
  SELECT
    'destination_state_matches_latest_acknowledgement'::text,
    'destination_export'::text,
    export.id::text,
    jsonb_build_object(
      'destination', export.destination,
      'export_state', export.state,
      'acknowledgement_state', latest.acknowledgement_state
    )
  FROM otlet.destination_exports export
  JOIN LATERAL (
    SELECT acknowledgement.acknowledgement_state
    FROM otlet.destination_acknowledgements acknowledgement
    WHERE acknowledgement.destination_export_id = export.id
    ORDER BY acknowledgement.id DESC
    LIMIT 1
  ) latest ON true
  WHERE export.state IS DISTINCT FROM latest.acknowledgement_state;

  RETURN QUERY
  SELECT
    'destination_replays_link_to_applied_acknowledgements'::text,
    'destination_acknowledgement'::text,
    replay.id::text,
    jsonb_build_object(
      'destination_export_id', replay.destination_export_id,
      'acknowledgement_id', replay.acknowledgement_id,
      'replay_of_acknowledgement_id', replay.replay_of_acknowledgement_id,
      'destination_execution_receipt_id', replay.destination_execution_receipt_id
    )
  FROM otlet.destination_acknowledgements replay
  LEFT JOIN otlet.destination_acknowledgements source
    ON source.destination_export_id = replay.destination_export_id
   AND source.acknowledgement_id = replay.replay_of_acknowledgement_id
  WHERE replay.replay_decision = 'duplicate_replay'
    AND (
      source.id IS NULL
      OR source.acknowledgement_state <> 'applied'
      OR source.destination_execution_receipt_id
        IS DISTINCT FROM replay.destination_execution_receipt_id
    );

  RETURN QUERY
  SELECT
    'materializations_have_source_hashes'::text,
    'materialization'::text,
    sm.id::text,
    jsonb_build_object(
      'task_name', sm.task_name,
      'subject_id', sm.subject_id,
      'stale', sm.stale
    )
  FROM otlet.semantic_materializations sm
  WHERE sm.source_hash IS NULL;

  RETURN QUERY
  SELECT
    'no_runtime_slot_errors'::text,
    'runtime'::text,
    rs.model_name::text,
    jsonb_build_object(
      'runtime_status', rs.runtime_status,
      'slot_state', rs.slot_state
    )
  FROM otlet.runtime_status rs
  WHERE rs.runtime_status = 'error'
     OR rs.slot_state = 'error';

  FOR index_row IN
    SELECT
      si.name,
      si.task_name,
      si.source_table,
      si.subject_column,
      si.input_columns,
      si.record_type,
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    FROM otlet.semantic_indexes si
    JOIN otlet.tasks t ON t.name = si.task_name
  LOOP
    current_contract_hash := otlet.task_contract_hash(
      index_row.instruction,
      index_row.output_schema,
      index_row.model_name,
      index_row.runtime_options,
      index_row.input_shaping,
      index_row.decision_contract
    );

    BEGIN
      RETURN QUERY EXECUTE format(
        $sql$
          WITH source_inputs AS (
            SELECT
              (src.%1$I)::text AS subject_id,
              jsonb_build_object(
                '_otlet_mvcc', jsonb_build_object(
                  'table', %2$L,
                  'subject_id', (src.%1$I)::text,
                  'ctid', src.ctid::text,
                  'xmin', src.xmin::text
                ),
                'table', %2$L,
                'row', otlet.semantic_project_row(to_jsonb(src), %6$L::text[])
              ) AS input
            FROM %3$s AS src
          ),
          current_inputs AS (
            SELECT *
            FROM source_inputs
            %11$s
          ),
          current_hashes AS (
            SELECT DISTINCT ON (subject_id)
              subject_id,
              otlet.semantic_content_hash(input, %9$L::jsonb) AS content_hash
            FROM current_inputs
            ORDER BY subject_id, input::text
          )
          SELECT
            'fresh_materialization_content_hash_matches_source'::text,
            'semantic_materialization'::text,
            sm.id::text,
            jsonb_build_object(
              'semantic_index', %8$L,
              'task_name', sm.task_name,
              'record_type', sm.record_type,
              'source_table', sm.source_table,
              'subject_id', sm.subject_id,
              'stored_content_hash', sm.content_hash,
              'current_content_hash', ch.content_hash,
              'stored_contract_hash', sm.contract_hash,
              'current_contract_hash', %7$L
            ) || %10$L::jsonb
          FROM otlet.semantic_materializations sm
          LEFT JOIN current_hashes ch ON ch.subject_id = sm.subject_id
          WHERE sm.task_name = %4$L
            AND sm.record_type = %5$L
            AND sm.source_table = %2$L
            AND sm.stale = false
            AND (
              ch.subject_id IS NULL
              OR sm.content_hash IS DISTINCT FROM ch.content_hash
              OR sm.contract_hash IS DISTINCT FROM %7$L
            )
        $sql$,
        index_row.subject_column,
        index_row.source_table,
        index_row.source_table,
        index_row.task_name,
        index_row.record_type,
        index_row.input_columns,
        current_contract_hash,
        index_row.name,
        index_row.input_shaping,
        sample_detail,
        sample_clause
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY
      SELECT
        'fresh_materialization_source_query_runs'::text,
        'semantic_index'::text,
        index_row.name::text,
        jsonb_build_object(
          'task_name', index_row.task_name,
          'source_table', index_row.source_table,
          'error', SQLERRM
        ) || sample_detail;
    END;
  END LOOP;

  FOR join_row IN
    SELECT
      sji.name,
      sji.task_name,
      sji.candidate_query,
      sji.record_type,
      sji.max_candidate_rows,
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    FROM otlet.semantic_join_indexes sji
    JOIN otlet.tasks t ON t.name = sji.task_name
  LOOP
    current_contract_hash := otlet.task_contract_hash(
      join_row.instruction,
      join_row.output_schema,
      join_row.model_name,
      join_row.runtime_options,
      join_row.input_shaping,
      join_row.decision_contract
    );

    BEGIN
      RETURN QUERY EXECUTE format(
        $sql$
          WITH source_inputs AS (
            SELECT subject_id, input
            FROM (
              SELECT subject_id::text AS subject_id, input::jsonb AS input
              FROM (%1$s) otlet_join_candidate
              ORDER BY subject_id
              LIMIT %2$s
            ) otlet_join_input
          ),
          current_inputs AS (
            SELECT *
            FROM source_inputs
            %10$s
          ),
          current_hashes AS (
            SELECT DISTINCT ON (subject_id)
              subject_id,
              otlet.semantic_content_hash(input, %8$L::jsonb) AS content_hash
            FROM current_inputs
            ORDER BY subject_id, input::text
          )
          SELECT
            'fresh_materialization_content_hash_matches_source'::text,
            'semantic_materialization'::text,
            sm.id::text,
            jsonb_build_object(
              'semantic_join_index', %6$L,
              'task_name', sm.task_name,
              'record_type', sm.record_type,
              'source_table', sm.source_table,
              'subject_id', sm.subject_id,
              'stored_content_hash', sm.content_hash,
              'current_content_hash', ch.content_hash,
              'stored_contract_hash', sm.contract_hash,
              'current_contract_hash', %5$L
            ) || %9$L::jsonb
          FROM otlet.semantic_materializations sm
          LEFT JOIN current_hashes ch ON ch.subject_id = sm.subject_id
          WHERE sm.task_name = %3$L
            AND sm.record_type = %4$L
            AND sm.source_table = %7$L
            AND sm.stale = false
            AND (
              ch.subject_id IS NULL
              OR sm.content_hash IS DISTINCT FROM ch.content_hash
              OR sm.contract_hash IS DISTINCT FROM %5$L
            )
        $sql$,
        join_row.candidate_query,
        join_row.max_candidate_rows,
        join_row.task_name,
        join_row.record_type,
        current_contract_hash,
        join_row.name,
        'otlet.semantic_join:' || join_row.name,
        join_row.input_shaping,
        sample_detail,
        sample_clause
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY
      SELECT
        'fresh_materialization_source_query_runs'::text,
        'semantic_join_index'::text,
        join_row.name::text,
        jsonb_build_object(
          'task_name', join_row.task_name,
          'error', SQLERRM
        ) || sample_detail;
    END;
  END LOOP;
END;
$$;
