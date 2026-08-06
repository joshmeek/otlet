CREATE FUNCTION otlet.workload_enablement_preflight(
  requested_task_name text,
  expected_workload_revision_hash text,
  requested_enablement_kind text,
  requested_max_subjects integer DEFAULT NULL,
  requested_page_size integer DEFAULT 64,
  requested_max_jobs_per_minute integer DEFAULT 64,
  requested_max_outstanding_jobs integer DEFAULT 64
) RETURNS TABLE (
  task_name text,
  workload_revision_hash text,
  enablement_kind text,
  source_kind text,
  candidate_plan jsonb,
  candidate_plan_status text,
  candidate_plan_error text,
  candidate_plan_cost numeric,
  candidate_plan_rows bigint,
  estimated_candidates bigint,
  candidate_plan_width_bytes bigint,
  latest_observed_candidate_rows bigint,
  active_same_revision_jobs bigint,
  estimated_jobs bigint,
  input_observations bigint,
  estimated_input_bytes_per_job bigint,
  estimated_largest_input_bytes bigint,
  estimated_total_input_bytes numeric,
  estimated_peak_queue_input_bytes numeric,
  runtime_observations bigint,
  runtime_sample_scope text,
  model_ms_p25 bigint,
  model_ms_p50 bigint,
  model_ms_p75 bigint,
  service_ms_p25 bigint,
  service_ms_p50 bigint,
  service_ms_p75 bigint,
  estimated_model_ms_p50 numeric,
  estimated_catch_up_ms_p25 numeric,
  estimated_catch_up_ms_p50 numeric,
  estimated_catch_up_ms_p75 numeric,
  within_current_policy boolean,
  policy_blockers text[],
  capacity jsonb,
  uncertainty_level text,
  uncertainty_reasons text[],
  checked_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
ROWS 1
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  plan_result record;
  policy otlet.production_policy%ROWTYPE;
  task_capacity otlet.task_queue_capacity%ROWTYPE;
  model_capacity otlet.model_queue_status%ROWTYPE;
  revision_definition jsonb;
  input_query text;
  direct_model_name text;
  route_models text[];
  contract_error text;
  input_bytes_per_job numeric;
  observed_largest_input bigint;
  semantic_candidates bigint;
  semantic_inflight bigint;
  peak_queue_jobs bigint;
  available_queue_slots bigint;
  available_task_queue_input_bytes bigint;
  available_model_queue_input_bytes bigint;
  available_total_queue_input_bytes bigint;
  model_backlog_jobs bigint;
  rate_floor_ms numeric := 0;
BEGIN
  workload_enablement_preflight.checked_at := clock_timestamp();
  workload_enablement_preflight.task_name :=
    workload_enablement_preflight.requested_task_name;
  workload_enablement_preflight.workload_revision_hash :=
    workload_enablement_preflight.expected_workload_revision_hash;
  workload_enablement_preflight.enablement_kind :=
    workload_enablement_preflight.requested_enablement_kind;

  IF workload_enablement_preflight.expected_workload_revision_hash IS NULL THEN
    RAISE EXCEPTION 'otlet workload enablement preflight requires an expected workload revision';
  END IF;
  IF workload_enablement_preflight.requested_enablement_kind IS NULL
     OR workload_enablement_preflight.requested_enablement_kind NOT IN (
    'watch', 'backfill'
  ) THEN
    RAISE EXCEPTION 'otlet workload enablement kind must be watch or backfill';
  END IF;

  SELECT production.* INTO STRICT policy
  FROM otlet.production_policy production
  WHERE production.name = 'default';

  SELECT
    revision.definition,
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{models,direct,name}'
  INTO revision_definition, input_query, direct_model_name
  FROM otlet.tasks task
  JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE task.name = workload_enablement_preflight.requested_task_name
    AND task.lifecycle_state = 'active'
    AND head.active_workload_revision_hash =
      workload_enablement_preflight.expected_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision is not active for task %',
      workload_enablement_preflight.requested_task_name;
  END IF;
  IF input_query IS NULL THEN
    RAISE EXCEPTION 'otlet workload preflight requires a task input query';
  END IF;

  IF workload_enablement_preflight.requested_enablement_kind = 'watch'
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.watches watch
       WHERE watch.task_name = workload_enablement_preflight.requested_task_name
     ) THEN
    RAISE EXCEPTION 'otlet watch enablement requires a watch task';
  END IF;
  IF workload_enablement_preflight.requested_enablement_kind = 'backfill' THEN
    IF workload_enablement_preflight.requested_max_subjects IS NULL
       OR workload_enablement_preflight.requested_max_subjects NOT BETWEEN 1 AND
         policy.max_admission_rows THEN
      RAISE EXCEPTION 'otlet preflight max subjects must be between 1 and %',
        policy.max_admission_rows;
    END IF;
    IF workload_enablement_preflight.requested_page_size IS NULL
       OR workload_enablement_preflight.requested_page_size NOT BETWEEN 1 AND 64 THEN
      RAISE EXCEPTION 'otlet preflight page size must be between 1 and 64';
    END IF;
    IF policy.max_queued_jobs_per_model < 2
       OR workload_enablement_preflight.requested_max_jobs_per_minute IS NULL
       OR workload_enablement_preflight.requested_max_jobs_per_minute NOT BETWEEN
         1 AND policy.max_queued_jobs_per_model - 1 THEN
      RAISE EXCEPTION 'otlet preflight jobs per minute must preserve one foreground queue slot';
    END IF;
    IF workload_enablement_preflight.requested_max_outstanding_jobs IS NULL
       OR workload_enablement_preflight.requested_max_outstanding_jobs NOT BETWEEN
         1 AND policy.max_queued_jobs_per_model - 1 THEN
      RAISE EXCEPTION 'otlet preflight outstanding jobs must preserve one foreground queue slot';
    END IF;
  ELSIF workload_enablement_preflight.requested_max_subjects IS NOT NULL THEN
    RAISE EXCEPTION 'otlet preflight max subjects applies only to backfill';
  END IF;

  workload_enablement_preflight.source_kind := COALESCE(
    revision_definition #>> '{source,kind}',
    'generic'
  );

  PERFORM otlet.lock_source_query_contract_relations(
    revision_definition #> '{source,query_contract}'
  );
  contract_error := otlet.source_query_contract_error(
    revision_definition #> '{source,query_contract}',
    true
  );
  IF contract_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload is suspended: %', contract_error;
  END IF;
  contract_error := otlet.semantic_schema_drift_error(revision_definition);
  IF contract_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload is suspended: %', contract_error;
  END IF;
  SELECT * INTO STRICT plan_result
  FROM otlet.preflight_candidate_query(
    CASE workload_enablement_preflight.source_kind
      WHEN 'pair' THEN revision_definition #>> '{source,candidate_query}'
      ELSE input_query
    END,
    false,
    false,
    revision_definition #> '{source,query_contract}'
  );

  workload_enablement_preflight.candidate_plan := plan_result.candidate_plan;
  workload_enablement_preflight.candidate_plan_status :=
    plan_result.candidate_preflight_status;
  workload_enablement_preflight.candidate_plan_error :=
    plan_result.candidate_preflight_error;
  workload_enablement_preflight.candidate_plan_cost := plan_result.candidate_plan_cost;
  workload_enablement_preflight.candidate_plan_rows := LEAST(
    GREATEST(
      CEIL(COALESCE(
        (plan_result.candidate_plan #>> '{0,Plan,Plan Rows}')::numeric,
        0
      )),
      0
    ),
    9223372036854775807
  )::bigint;
  workload_enablement_preflight.candidate_plan_width_bytes := LEAST(
    GREATEST(
      CEIL(COALESCE(
        (plan_result.candidate_plan #>> '{0,Plan,Plan Width}')::numeric,
        0
      )),
      0
    ),
    9223372036854775807
  )::bigint;

  SELECT count(*)::bigint
  INTO workload_enablement_preflight.active_same_revision_jobs
  FROM otlet.jobs job
  WHERE job.task_name = workload_enablement_preflight.requested_task_name
    AND job.workload_revision_hash =
      workload_enablement_preflight.expected_workload_revision_hash
    AND job.execution_mode = 'production'
    AND job.status IN ('queued', 'running', 'cancel_requested');

  IF workload_enablement_preflight.source_kind = 'row' THEN
    SELECT
      plan.stale_subjects + plan.missing_subjects,
      plan.inflight_subjects
    INTO semantic_candidates, semantic_inflight
    FROM otlet.semantic_index_plan(
      revision_definition #>> '{source,semantic_index_name}',
      false,
      workload_enablement_preflight.expected_workload_revision_hash
    ) plan;
  ELSIF workload_enablement_preflight.source_kind = 'pair'
        AND workload_enablement_preflight.candidate_plan_status = 'ready' THEN
    SELECT
      GREATEST(
        plan.stale_subjects,
        workload_enablement_preflight.candidate_plan_rows - plan.fresh_subjects,
        0
      ),
      plan.inflight_subjects
    INTO semantic_candidates, semantic_inflight
    FROM otlet.semantic_join_index_plan(
      revision_definition #>> '{source,semantic_join_index_name}',
      false,
      workload_enablement_preflight.expected_workload_revision_hash
    ) plan;
  END IF;
  workload_enablement_preflight.estimated_candidates := COALESCE(
    semantic_candidates,
    workload_enablement_preflight.candidate_plan_rows
  );
  workload_enablement_preflight.estimated_jobs := GREATEST(
    workload_enablement_preflight.estimated_candidates - COALESCE(
      semantic_inflight,
      workload_enablement_preflight.active_same_revision_jobs
    ),
    0
  );

  WITH recent AS (
    SELECT
      observation.candidate_rows,
      observation.candidate_bytes,
      observation.largest_input_bytes,
      observation.created_at,
      observation.observation_hash
    FROM otlet.task_candidate_observations observation
    WHERE observation.task_name = workload_enablement_preflight.requested_task_name
      AND observation.workload_revision_hash =
        workload_enablement_preflight.expected_workload_revision_hash
      AND observation.rejection_reason IS DISTINCT FROM 'row_cap'
      AND observation.candidate_rows > 0
    ORDER BY observation.created_at DESC, observation.observation_hash DESC
    LIMIT 16
  )
  SELECT
    count(*)::bigint,
    (array_agg(candidate_rows ORDER BY created_at DESC, observation_hash DESC))[1],
    sum(candidate_bytes)::numeric / NULLIF(sum(candidate_rows), 0),
    max(largest_input_bytes)
  INTO
    workload_enablement_preflight.input_observations,
    workload_enablement_preflight.latest_observed_candidate_rows,
    input_bytes_per_job,
    observed_largest_input
  FROM recent;
  workload_enablement_preflight.estimated_input_bytes_per_job := GREATEST(
    CEIL(COALESCE(
      input_bytes_per_job,
      workload_enablement_preflight.candidate_plan_width_bytes::numeric
    )),
    0
  )::bigint;
  workload_enablement_preflight.estimated_largest_input_bytes := COALESCE(
    observed_largest_input,
    workload_enablement_preflight.estimated_input_bytes_per_job
  );
  workload_enablement_preflight.estimated_total_input_bytes :=
    workload_enablement_preflight.estimated_jobs::numeric
      * workload_enablement_preflight.estimated_input_bytes_per_job;

  SELECT COALESCE(array_agg(DISTINCT model_name ORDER BY model_name), ARRAY[]::text[])
  INTO route_models
  FROM (
    SELECT model.value ->> 'name' AS model_name
    FROM jsonb_each(COALESCE(revision_definition -> 'models', '{}'::jsonb)) model
    WHERE jsonb_typeof(model.value) = 'object'
      AND NULLIF(model.value ->> 'name', '') IS NOT NULL
  ) models;

  WITH classified AS (
    SELECT
      CASE
        WHEN job.task_name = workload_enablement_preflight.requested_task_name
         AND job.workload_revision_hash =
           workload_enablement_preflight.expected_workload_revision_hash
          THEN 1
        WHEN job.task_name = workload_enablement_preflight.requested_task_name
          THEN 2
        ELSE 3
      END AS priority,
      timing.prompt_decode_ms + timing.generate_ms AS model_ms,
      timing.accounted_worker_ms,
      job.finished_at,
      job.id
    FROM otlet.runtime_stage_timing_status timing
    JOIN otlet.jobs job ON job.id = timing.job_id
    WHERE job.status = 'complete'
      AND NOT timing.inference_cache_hit
      AND timing.accounted_worker_ms > 0
      AND timing.prompt_decode_ms + timing.generate_ms > 0
      AND (
        (
          job.task_name = workload_enablement_preflight.requested_task_name
          AND job.workload_revision_hash =
            workload_enablement_preflight.expected_workload_revision_hash
        )
        OR timing.model_names && route_models
      )
  ), eligible AS (
    SELECT
      classified.priority,
      classified.model_ms,
      classified.accounted_worker_ms,
      row_number() OVER (
        PARTITION BY classified.priority
        ORDER BY classified.finished_at DESC, classified.id DESC
      ) AS sample_rank
    FROM classified
  ), summaries AS (
    SELECT
      priority,
      count(*)::bigint AS observations,
      percentile_disc(0.25) WITHIN GROUP (
        ORDER BY model_ms
      ) AS model_p25,
      percentile_disc(0.5) WITHIN GROUP (
        ORDER BY model_ms
      ) AS model_p50,
      percentile_disc(0.75) WITHIN GROUP (
        ORDER BY model_ms
      ) AS model_p75,
      percentile_disc(0.25) WITHIN GROUP (
        ORDER BY accounted_worker_ms
      ) AS service_p25,
      percentile_disc(0.5) WITHIN GROUP (
        ORDER BY accounted_worker_ms
      ) AS service_p50,
      percentile_disc(0.75) WITHIN GROUP (
        ORDER BY accounted_worker_ms
      ) AS service_p75
    FROM eligible
    WHERE sample_rank <= 101
    GROUP BY priority
  )
  SELECT
    summaries.observations,
    CASE summaries.priority
      WHEN 1 THEN 'active_revision'
      WHEN 2 THEN 'task_route_history'
      ELSE 'route_model_history'
    END,
    summaries.model_p25,
    summaries.model_p50,
    summaries.model_p75,
    summaries.service_p25,
    summaries.service_p50,
    summaries.service_p75
  INTO
    workload_enablement_preflight.runtime_observations,
    workload_enablement_preflight.runtime_sample_scope,
    workload_enablement_preflight.model_ms_p25,
    workload_enablement_preflight.model_ms_p50,
    workload_enablement_preflight.model_ms_p75,
    workload_enablement_preflight.service_ms_p25,
    workload_enablement_preflight.service_ms_p50,
    workload_enablement_preflight.service_ms_p75
  FROM summaries
  ORDER BY summaries.priority
  LIMIT 1;

  IF workload_enablement_preflight.runtime_observations IS NULL THEN
    workload_enablement_preflight.runtime_observations := 0;
    workload_enablement_preflight.model_ms_p25 :=
      (revision_definition #>> '{runtime,effective_max_attempt_ms}')::bigint;
    workload_enablement_preflight.model_ms_p50 :=
      workload_enablement_preflight.model_ms_p25;
    workload_enablement_preflight.model_ms_p75 :=
      workload_enablement_preflight.model_ms_p25;
    workload_enablement_preflight.service_ms_p25 :=
      workload_enablement_preflight.model_ms_p25;
    workload_enablement_preflight.service_ms_p50 :=
      workload_enablement_preflight.model_ms_p25;
    workload_enablement_preflight.service_ms_p75 :=
      workload_enablement_preflight.model_ms_p25;
    workload_enablement_preflight.runtime_sample_scope := 'attempt_deadline_fallback';
  END IF;

  workload_enablement_preflight.estimated_model_ms_p50 :=
    workload_enablement_preflight.estimated_jobs::numeric
      * workload_enablement_preflight.model_ms_p50;
  SELECT * INTO STRICT model_capacity
  FROM otlet.model_queue_status queue
  WHERE queue.model_name = direct_model_name;
  SELECT * INTO STRICT task_capacity
  FROM otlet.task_queue_capacity queue
  WHERE queue.task_name = workload_enablement_preflight.requested_task_name;

  SELECT count(*)::bigint
  INTO model_backlog_jobs
  FROM otlet.jobs job
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = job.task_name
  WHERE (
      job.status IN ('running', 'cancel_requested')
      OR (
        job.status = 'queued'
        AND CASE job.execution_mode
          WHEN 'evaluation' THEN true
          ELSE job.workload_revision_hash = head.active_workload_revision_hash
        END
      )
    )
    AND COALESCE(
      job.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) = ANY(route_models);
  peak_queue_jobs := CASE workload_enablement_preflight.requested_enablement_kind
    WHEN 'backfill' THEN LEAST(
      workload_enablement_preflight.estimated_jobs,
      workload_enablement_preflight.requested_max_outstanding_jobs::bigint
    )
    ELSE workload_enablement_preflight.estimated_jobs
  END;
  workload_enablement_preflight.estimated_peak_queue_input_bytes :=
    peak_queue_jobs::numeric
      * workload_enablement_preflight.estimated_input_bytes_per_job;
  available_queue_slots := GREATEST(
    model_capacity.available_queue_slots
      - CASE workload_enablement_preflight.requested_enablement_kind
          WHEN 'backfill' THEN 1
          ELSE 0
        END,
    0
  );
  available_task_queue_input_bytes := GREATEST(
    task_capacity.available_queued_input_bytes
      - CASE workload_enablement_preflight.requested_enablement_kind
          WHEN 'backfill' THEN LEAST(
            policy.max_input_bytes_per_job,
            policy.max_queued_input_bytes_per_task
          )
          ELSE 0
        END,
    0
  );
  available_model_queue_input_bytes := GREATEST(
    model_capacity.available_model_queue_input_bytes
      - CASE workload_enablement_preflight.requested_enablement_kind
          WHEN 'backfill' THEN LEAST(
            policy.max_input_bytes_per_job,
            policy.max_queued_input_bytes_per_model
          )
          ELSE 0
        END,
    0
  );
  available_total_queue_input_bytes := GREATEST(
    model_capacity.available_total_queue_input_bytes
      - CASE workload_enablement_preflight.requested_enablement_kind
          WHEN 'backfill' THEN LEAST(
            policy.max_input_bytes_per_job,
            policy.max_queued_input_bytes_total
          )
          ELSE 0
        END,
    0
  );

  IF workload_enablement_preflight.requested_enablement_kind = 'backfill'
     AND workload_enablement_preflight.estimated_jobs > 0 THEN
    rate_floor_ms := FLOOR(
      (workload_enablement_preflight.estimated_jobs - 1)::numeric
        / workload_enablement_preflight.requested_max_jobs_per_minute
    ) * 60000;
  END IF;
  workload_enablement_preflight.estimated_catch_up_ms_p25 := GREATEST(
    (
      model_backlog_jobs + workload_enablement_preflight.estimated_jobs
    )::numeric * workload_enablement_preflight.service_ms_p25,
    CASE WHEN workload_enablement_preflight.estimated_jobs > 0
      THEN rate_floor_ms + workload_enablement_preflight.service_ms_p25
      ELSE 0
    END
  );
  workload_enablement_preflight.estimated_catch_up_ms_p50 := GREATEST(
    (
      model_backlog_jobs + workload_enablement_preflight.estimated_jobs
    )::numeric * workload_enablement_preflight.service_ms_p50,
    CASE WHEN workload_enablement_preflight.estimated_jobs > 0
      THEN rate_floor_ms + workload_enablement_preflight.service_ms_p50
      ELSE 0
    END
  );
  workload_enablement_preflight.estimated_catch_up_ms_p75 := GREATEST(
    (
      model_backlog_jobs + workload_enablement_preflight.estimated_jobs
    )::numeric * workload_enablement_preflight.service_ms_p75,
    CASE WHEN workload_enablement_preflight.estimated_jobs > 0
      THEN rate_floor_ms + workload_enablement_preflight.service_ms_p75
      ELSE 0
    END
  );

  workload_enablement_preflight.policy_blockers := ARRAY[]::text[];
  IF workload_enablement_preflight.candidate_plan_status <> 'ready' THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'candidate_plan_not_ready'
    );
  END IF;
  IF workload_enablement_preflight.source_kind = 'pair'
     AND workload_enablement_preflight.candidate_plan_rows >
       (revision_definition #>> '{source,max_candidate_rows}')::bigint THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_candidates_exceed_watch_max_candidate_rows'
    );
  END IF;
  IF workload_enablement_preflight.requested_enablement_kind = 'backfill' THEN
    IF workload_enablement_preflight.estimated_candidates >
       workload_enablement_preflight.requested_max_subjects THEN
      workload_enablement_preflight.policy_blockers := array_append(
        workload_enablement_preflight.policy_blockers,
        'estimated_candidates_exceed_requested_max_subjects'
      );
    END IF;
    IF EXISTS (
      SELECT 1
      FROM otlet.task_backfill_status backfill
      WHERE backfill.task_name = workload_enablement_preflight.requested_task_name
        AND backfill.workload_revision_hash =
          workload_enablement_preflight.expected_workload_revision_hash
        AND (backfill.pending_subjects > 0 OR backfill.outstanding_jobs > 0)
    ) THEN
      workload_enablement_preflight.policy_blockers := array_append(
        workload_enablement_preflight.policy_blockers,
        'unfinished_backfill_exists'
      );
    END IF;
  ELSIF workload_enablement_preflight.source_kind <> 'pair'
        AND workload_enablement_preflight.estimated_candidates >
          policy.max_admission_rows THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_candidates_exceed_admission_rows'
    );
  END IF;
  IF peak_queue_jobs > available_queue_slots THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_jobs_exceed_model_queue_slots'
    );
  END IF;
  IF workload_enablement_preflight.estimated_largest_input_bytes >
     policy.max_input_bytes_per_job THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_input_exceeds_per_job_bytes'
    );
  END IF;
  IF task_capacity.queue_age_exceeded THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'task_queue_age_exceeded'
    );
  END IF;
  IF workload_enablement_preflight.estimated_peak_queue_input_bytes >
     available_task_queue_input_bytes THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_queue_bytes_exceed_task_headroom'
    );
  END IF;
  IF workload_enablement_preflight.estimated_peak_queue_input_bytes >
     available_model_queue_input_bytes THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_queue_bytes_exceed_model_headroom'
    );
  END IF;
  IF workload_enablement_preflight.estimated_peak_queue_input_bytes >
     available_total_queue_input_bytes THEN
    workload_enablement_preflight.policy_blockers := array_append(
      workload_enablement_preflight.policy_blockers,
      'estimated_queue_bytes_exceed_total_headroom'
    );
  END IF;
  workload_enablement_preflight.within_current_policy :=
    cardinality(workload_enablement_preflight.policy_blockers) = 0;
  workload_enablement_preflight.capacity := jsonb_build_object(
    'model_queue_jobs', model_capacity.queued_jobs,
    'model_running_jobs', model_capacity.running_jobs,
    'model_cancel_requested_jobs', model_capacity.cancel_requested_jobs,
    'model_backlog_jobs', model_backlog_jobs,
    'estimated_peak_queue_jobs', peak_queue_jobs,
    'available_model_queue_slots', model_capacity.available_queue_slots,
    'effective_available_model_queue_slots', available_queue_slots,
    'available_task_queue_input_bytes', task_capacity.available_queued_input_bytes,
    'effective_available_task_queue_input_bytes',
      available_task_queue_input_bytes,
    'available_model_queue_input_bytes',
      model_capacity.available_model_queue_input_bytes,
    'effective_available_model_queue_input_bytes',
      available_model_queue_input_bytes,
    'available_total_queue_input_bytes',
      model_capacity.available_total_queue_input_bytes,
    'effective_available_total_queue_input_bytes',
      available_total_queue_input_bytes,
    'max_input_bytes_per_job', policy.max_input_bytes_per_job,
    'max_admission_rows', policy.max_admission_rows,
    'requested_max_subjects',
      workload_enablement_preflight.requested_max_subjects,
    'requested_page_size',
      workload_enablement_preflight.requested_page_size,
    'requested_max_jobs_per_minute',
      workload_enablement_preflight.requested_max_jobs_per_minute,
    'requested_max_outstanding_jobs',
      workload_enablement_preflight.requested_max_outstanding_jobs
  );

  workload_enablement_preflight.uncertainty_reasons := ARRAY[
    'planner_cardinality_estimate',
    'source_query_rebinding_not_executed',
    'stage_accounted_service_excludes_unmeasured_worker_overhead',
    'serial_catch_up_excludes_worker_parallelism'
  ]::text[];
  IF workload_enablement_preflight.input_observations = 0 THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'input_bytes_from_plan_width'
    );
  END IF;
  IF workload_enablement_preflight.source_kind = 'pair' THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'pair_candidate_membership_not_executed'
    );
  END IF;
  IF workload_enablement_preflight.source_kind IN ('row', 'pair') THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'semantic_state_counts_estimated'
    );
  END IF;
  IF workload_enablement_preflight.active_same_revision_jobs > 0 THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'active_overlap_estimated_by_count'
    );
  END IF;
  IF workload_enablement_preflight.runtime_sample_scope = 'attempt_deadline_fallback' THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'runtime_history_missing'
    );
  ELSIF workload_enablement_preflight.runtime_sample_scope <> 'active_revision' THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'runtime_history_not_revision_specific'
    );
  END IF;
  IF workload_enablement_preflight.runtime_observations < 21 THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'runtime_sample_below_21'
    );
  END IF;
  IF workload_enablement_preflight.requested_enablement_kind = 'backfill' THEN
    workload_enablement_preflight.uncertainty_reasons := array_append(
      workload_enablement_preflight.uncertainty_reasons,
      'manual_backfill_page_delay_excluded'
    );
  END IF;
  workload_enablement_preflight.uncertainty_level := CASE
    WHEN workload_enablement_preflight.runtime_sample_scope = 'active_revision'
      AND workload_enablement_preflight.runtime_observations >= 21
      AND workload_enablement_preflight.input_observations > 0
      AND workload_enablement_preflight.source_kind = 'generic'
      THEN 'low'
    WHEN workload_enablement_preflight.runtime_sample_scope = 'active_revision'
      AND workload_enablement_preflight.input_observations > 0
      THEN 'medium'
    ELSE 'high'
  END;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION otlet.workload_enablement_preflight(
  text, text, text, integer, integer, integer, integer
) IS 'Read-only estimate for one active watch refresh or bounded backfill';

REVOKE ALL ON FUNCTION otlet.workload_enablement_preflight(
  text, text, text, integer, integer, integer, integer
) FROM PUBLIC;
