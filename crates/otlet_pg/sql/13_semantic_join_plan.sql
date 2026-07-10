CREATE FUNCTION otlet.semantic_join_index_current_rows(
  index_name text,
  fresh_only boolean DEFAULT true
) RETURNS TABLE (
  subject_id text,
  body jsonb,
  stale boolean,
  source_hash text,
  freshness_basis text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  fresh_sql text := CASE WHEN COALESCE(fresh_only, true) THEN 'true' ELSE 'false' END;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_current_rows.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_current_rows.index_name;
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
        SELECT subject_id, input
        FROM (
          SELECT subject_id::text AS subject_id, input::jsonb AS input
          FROM (%1$s) otlet_join_candidate
          ORDER BY subject_id
          LIMIT %2$s
        ) otlet_join_input
      ),
      current_inputs AS (
        SELECT
          subject_id,
          input,
          md5(input::text) AS source_hash,
          otlet.semantic_content_hash(input, %7$L::jsonb) AS content_hash
        FROM raw_inputs
      ),
      latest AS (
        SELECT DISTINCT ON (sm.subject_id)
          sm.subject_id,
          sm.body,
          sm.stale,
          sm.source_hash,
          sm.content_hash,
          sm.contract_hash,
          sm.stale_reason,
          sm.freshness_basis,
          sm.updated_at,
          sm.id
        FROM current_inputs ci
        JOIN otlet.semantic_materializations sm
          ON sm.subject_id = ci.subject_id
        WHERE sm.task_name = %3$L
          AND sm.record_type = %4$L
        ORDER BY
          sm.subject_id,
          (
            sm.content_hash IS NOT DISTINCT FROM ci.content_hash
            AND sm.contract_hash IS NOT DISTINCT FROM %5$L
          ) DESC,
          sm.updated_at DESC,
          sm.id DESC
      )
      SELECT
        latest.subject_id,
        latest.body,
        status.is_stale AS stale,
        latest.source_hash,
        CASE
          WHEN status.freshness_basis = 'content_hash_match' THEN COALESCE(latest.freshness_basis, status.freshness_basis)
          ELSE status.freshness_basis
        END AS freshness_basis,
        latest.updated_at
      FROM current_inputs ci
      JOIN latest ON latest.subject_id = ci.subject_id
      CROSS JOIN LATERAL otlet.semantic_freshness_status(
        latest.content_hash,
        latest.contract_hash,
        latest.stale,
        latest.stale_reason,
        latest.source_hash,
        ci.content_hash,
        %5$L,
        ci.source_hash
      ) status
      WHERE (
        NOT %6$s
        OR status.is_fresh
      )
      ORDER BY latest.subject_id
    $sql$,
    index_row.candidate_query,
    index_row.max_candidate_rows,
    index_row.task_name,
    index_row.record_type,
    current_contract_hash,
    fresh_sql,
    current_input_shaping
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches(
  index_name text,
  subject_id text,
  expected jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
  current_input jsonb;
  current_source_hash text;
  current_content_hash text;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_matches.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_matches.index_name;
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  EXECUTE format(
    $sql$
      SELECT input
      FROM (
        SELECT subject_id::text AS subject_id, input::jsonb AS input
        FROM (%s) otlet_join_candidate
      ) otlet_join_input
      WHERE subject_id = $1
      LIMIT 1
    $sql$,
    index_row.candidate_query
  )
  INTO current_input
  USING semantic_join_matches.subject_id;

  IF current_input IS NULL THEN
    RETURN false;
  END IF;

  current_source_hash := md5(current_input::text);
  current_content_hash := otlet.semantic_content_hash(current_input, current_input_shaping);

  RETURN EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.body,
        sm.source_hash,
        sm.content_hash,
        sm.contract_hash,
        sm.stale,
        sm.stale_reason,
        sm.freshness_basis,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = index_row.task_name
        AND sm.record_type = index_row.record_type
        AND sm.subject_id = semantic_join_matches.subject_id
      ORDER BY
        sm.subject_id,
        (
          sm.content_hash IS NOT DISTINCT FROM current_content_hash
          AND sm.contract_hash IS NOT DISTINCT FROM current_contract_hash
        ) DESC,
        sm.updated_at DESC,
        sm.id DESC
    ) latest
    CROSS JOIN LATERAL otlet.semantic_freshness_status(
      latest.content_hash,
      latest.contract_hash,
      latest.stale,
      latest.stale_reason,
      latest.source_hash,
      current_content_hash,
      current_contract_hash,
      current_source_hash
    ) status
    WHERE status.is_fresh
      AND latest.body @> semantic_join_matches.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_join_matches_auto(
  index_name text,
  subject_id text,
  expected jsonb
) RETURNS boolean
LANGUAGE plpgsql
STABLE
STRICT
COST 1000
AS $$
BEGIN
  RETURN otlet.semantic_join_matches(
    semantic_join_matches_auto.index_name,
    semantic_join_matches_auto.subject_id,
    semantic_join_matches_auto.expected
  );
END;
$$;

CREATE FUNCTION otlet.semantic_plan_from_counts(
  p_name text,
  p_task_name text,
  p_record_type text,
  p_model_name text,
  p_source_relation text,
  p_lookup_path text,
  p_empty_reason text,
  p_fresh_reason text,
  p_fail_closed_reason text,
  p_partial_refresh_reason text,
  p_full_refresh_path text,
  p_full_refresh_reason text,
  p_total_subjects bigint,
  p_fresh_subjects bigint,
  p_stale_subjects bigint,
  p_missing_subjects bigint,
  p_stale_reasons jsonb DEFAULT '{}'::jsonb,
  p_count_basis text DEFAULT 'exact'
) RETURNS TABLE (
  selected_path text,
  reason text,
  effective_stale_policy text,
  name text,
  task_name text,
  record_type text,
  model_name text,
  runtime_name text,
  source_relation text,
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  inflight_subjects bigint,
  lookup_subjects bigint,
  wait_subjects bigint,
  queue_subjects bigint,
  infer_now_subjects bigint,
  fail_closed_subjects bigint,
  freshness numeric,
  model_ms numeric,
  model_cost_source text,
  cache_hit_ms numeric,
  lookup_ms numeric,
  queue_ms numeric,
  infer_now_ms numeric,
  path_cost numeric,
  worker_queue_depth bigint,
  available_queue_slots bigint,
  stale_reasons jsonb,
  count_basis text,
  checked_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_total_subjects bigint := COALESCE(p_total_subjects, 0);
  v_fresh_subjects bigint := COALESCE(p_fresh_subjects, 0);
  v_stale_subjects bigint := COALESCE(p_stale_subjects, 0);
  v_missing_subjects bigint := COALESCE(p_missing_subjects, 0);
  v_refresh_subjects bigint := 0;
  v_inflight_subjects bigint := 0;
  v_worker_queue_depth bigint := 0;
  v_available_queue_slots bigint := 0;
  v_wait_subjects bigint := 0;
  v_queue_subjects bigint := 0;
  v_infer_now_subjects bigint := 0;
  v_fail_closed_subjects bigint := 0;
  v_remaining_refresh_subjects bigint := 0;
  v_model_ms numeric := 2500;
  v_model_cost_source text := 'static_fallback';
  v_lookup_ms numeric := 1;
  v_queue_ms numeric := 1;
  v_infer_now_ms numeric := 0;
  v_path_cost numeric := 1;
  v_stale_policy text := 'lookup_only_fail_closed';
  v_auto_wait_ms integer := 10000;
  v_auto_infer_ms integer := 15000;
  v_auto_max_rows integer := 1;
  v_selected_path text;
  v_reason text;
  v_runtime_name text := 'linked_inproc';
  v_stale_reasons jsonb := COALESCE(p_stale_reasons, '{}'::jsonb);
BEGIN
  v_refresh_subjects := v_stale_subjects + v_missing_subjects;

  SELECT
    count(DISTINCT j.subject_id) FILTER (
      WHERE j.task_name = p_task_name
    )::bigint,
    count(j.id)::bigint,
    COALESCE(otlet.available_model_queue_slots(p_model_name), 0)::bigint
  INTO v_inflight_subjects, v_worker_queue_depth, v_available_queue_slots
  FROM otlet.tasks t
  LEFT JOIN otlet.jobs j
    ON j.task_name = t.name
   AND j.status IN ('queued', 'running', 'cancel_requested')
  WHERE t.model_name = p_model_name;

  SELECT
    COALESCE(receipt_cost.task_generate_ms, slot_cost.last_generate_ms, receipt_cost.model_generate_ms, 2500)::numeric,
    CASE
      WHEN receipt_cost.task_generate_ms IS NOT NULL THEN 'task_receipt'
      WHEN slot_cost.last_generate_ms IS NOT NULL THEN 'runtime_slot'
      WHEN receipt_cost.model_generate_ms IS NOT NULL THEN 'model_receipt'
      ELSE 'static_fallback'
    END
  INTO v_model_ms, v_model_cost_source
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (
    SELECT
      (
        SELECT r.generate_ms::numeric
        FROM otlet.inference_receipts r
        WHERE r.task_name = p_task_name
          AND r.model_name = p_model_name
          AND r.status = 'complete'
          AND r.schema_validation_status = 'passed'
          AND COALESCE(r.generate_ms, 0) > 0
        ORDER BY r.finished_at DESC
        LIMIT 1
      ) AS task_generate_ms,
      (
        SELECT r.generate_ms::numeric
        FROM otlet.inference_receipts r
        WHERE r.model_name = p_model_name
          AND r.status = 'complete'
          AND r.schema_validation_status = 'passed'
          AND COALESCE(r.generate_ms, 0) > 0
        ORDER BY r.finished_at DESC
        LIMIT 1
      ) AS model_generate_ms
  ) receipt_cost ON true
  LEFT JOIN LATERAL (
    SELECT rs.last_generate_ms::numeric AS last_generate_ms
    FROM otlet.runtime_slots rs
    WHERE rs.model_name = p_model_name
      AND COALESCE(rs.last_generate_ms, 0) > 0
    ORDER BY rs.last_used_at DESC NULLS LAST
    LIMIT 1
  ) slot_cost ON true;

  SELECT
    COALESCE(policy.stale_policy, 'lookup_only_fail_closed'),
    COALESCE(policy.semantic_auto_wait_ms, 10000),
    COALESCE(policy.semantic_auto_infer_ms, 15000),
    COALESCE(policy.semantic_auto_max_rows, 1)
  INTO v_stale_policy, v_auto_wait_ms, v_auto_infer_ms, v_auto_max_rows
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';

  IF COALESCE(v_auto_infer_ms, 0) > 0 AND COALESCE(v_auto_max_rows, 0) > 0 THEN
    v_infer_now_subjects := LEAST(v_refresh_subjects, v_auto_max_rows::bigint);
  END IF;

  IF COALESCE(v_auto_wait_ms, 0) > 0 THEN
    v_wait_subjects := COALESCE(v_inflight_subjects, 0);
  END IF;

  v_remaining_refresh_subjects := GREATEST(v_refresh_subjects - v_infer_now_subjects, 0);

  IF v_stale_policy = 'refresh_then_fail_closed' THEN
    v_queue_subjects := LEAST(v_remaining_refresh_subjects, COALESCE(v_available_queue_slots, 0));
  END IF;

  v_fail_closed_subjects := GREATEST(
    v_refresh_subjects + COALESCE(v_inflight_subjects, 0) - v_wait_subjects - v_infer_now_subjects - v_queue_subjects,
    0
  );

  IF v_total_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_empty_reason;
  ELSIF v_infer_now_subjects > 0 THEN
    v_selected_path := 'bounded_infer_now';
    v_reason := format(
      'auto semantic policy: fresh=%s wait=%s infer=%s queue=%s fail_closed=%s',
      v_fresh_subjects,
      v_wait_subjects,
      v_infer_now_subjects,
      v_queue_subjects,
      v_fail_closed_subjects
    );
  ELSIF v_wait_subjects > 0 THEN
    v_selected_path := 'wait_for_refresh';
    v_reason := 'refresh already active';
  ELSIF v_refresh_subjects = 0 THEN
    v_selected_path := p_lookup_path;
    v_reason := p_fresh_reason;
  ELSIF v_stale_policy = 'lookup_only_fail_closed' THEN
    v_selected_path := 'lookup_fail_closed';
    v_reason := p_fail_closed_reason;
  ELSIF v_queue_subjects > 0 AND v_refresh_subjects < v_total_subjects THEN
    v_selected_path := 'queue_refresh';
    v_reason := p_partial_refresh_reason;
  ELSIF v_queue_subjects > 0 THEN
    v_selected_path := p_full_refresh_path;
    v_reason := p_full_refresh_reason;
  ELSE
    v_selected_path := 'lookup_fail_closed';
    v_reason := p_fail_closed_reason;
  END IF;

  v_lookup_ms := round(1 + (v_fresh_subjects::numeric * 0.05), 2);
  v_queue_ms := round(v_lookup_ms + (v_refresh_subjects::numeric * COALESCE(v_model_ms, 2500)), 2);
  v_infer_now_ms := round(v_infer_now_subjects::numeric * COALESCE(v_model_ms, 2500), 2);
  v_path_cost := CASE v_selected_path
    WHEN p_lookup_path THEN v_lookup_ms
    WHEN 'lookup_fail_closed' THEN v_lookup_ms
    WHEN 'wait_for_refresh' THEN round(v_lookup_ms + (v_wait_subjects::numeric * 0.50), 2)
    WHEN 'bounded_infer_now' THEN round(v_lookup_ms + v_infer_now_ms, 2)
    ELSE v_queue_ms
  END;

  RETURN QUERY SELECT
    v_selected_path,
    v_reason,
    v_stale_policy,
    p_name,
    p_task_name,
    p_record_type,
    p_model_name,
    COALESCE(v_runtime_name, 'linked_inproc'),
    p_source_relation,
    v_total_subjects,
    v_fresh_subjects,
    v_stale_subjects,
    v_missing_subjects,
    COALESCE(v_inflight_subjects, 0),
    v_fresh_subjects,
    v_wait_subjects,
    v_queue_subjects,
    v_infer_now_subjects,
    v_fail_closed_subjects,
    CASE WHEN v_total_subjects = 0 THEN 1::numeric ELSE round(v_fresh_subjects::numeric / v_total_subjects, 4) END,
    round(COALESCE(v_model_ms, 2500), 2),
    COALESCE(v_model_cost_source, 'static_fallback'),
    0.05::numeric,
    v_lookup_ms,
    v_queue_ms,
    v_infer_now_ms,
    v_path_cost,
    COALESCE(v_worker_queue_depth, 0),
    COALESCE(v_available_queue_slots, 0),
    v_stale_reasons,
    COALESCE(NULLIF(p_count_basis, ''), 'exact'),
    clock_timestamp();
END;
$$;

CREATE FUNCTION otlet.semantic_join_index_plan(
  index_name text,
  exact boolean DEFAULT false
) RETURNS TABLE (
  selected_path text,
  reason text,
  effective_stale_policy text,
  name text,
  task_name text,
  record_type text,
  model_name text,
  runtime_name text,
  source_relation text,
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  inflight_subjects bigint,
  lookup_subjects bigint,
  wait_subjects bigint,
  queue_subjects bigint,
  infer_now_subjects bigint,
  fail_closed_subjects bigint,
  freshness numeric,
  model_ms numeric,
  model_cost_source text,
  cache_hit_ms numeric,
  lookup_ms numeric,
  queue_ms numeric,
  infer_now_ms numeric,
  path_cost numeric,
  worker_queue_depth bigint,
  available_queue_slots bigint,
  stale_reasons jsonb,
  count_basis text,
  checked_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  index_row otlet.semantic_join_indexes%ROWTYPE;
  v_total_subjects bigint := 0;
  v_fresh_subjects bigint := 0;
  v_stale_subjects bigint := 0;
  v_missing_subjects bigint := 0;
  v_stale_reasons jsonb := '{}'::jsonb;
  v_count_basis text := CASE WHEN exact THEN 'exact' ELSE 'estimated' END;
  current_contract_hash text;
  current_input_shaping jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO index_row
  FROM otlet.semantic_join_indexes sji
  WHERE sji.name = semantic_join_index_plan.index_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', semantic_join_index_plan.index_name;
  END IF;

  SELECT
    otlet.task_contract_hash(
      t.instruction,
      t.output_schema,
      t.model_name,
      t.runtime_options,
      t.input_shaping,
      t.decision_contract
    ),
    t.input_shaping
  INTO current_contract_hash, current_input_shaping
  FROM otlet.tasks t
  WHERE t.name = index_row.task_name;

  IF exact THEN
    EXECUTE format(
      $sql$
        WITH raw_inputs AS (
          SELECT subject_id, input
          FROM (
            SELECT subject_id::text AS subject_id, input::jsonb AS input
            FROM (%1$s) otlet_join_candidate
            ORDER BY subject_id
            LIMIT %2$s
          ) otlet_join_input
        ),
        current_inputs AS (
          SELECT
            subject_id,
            input,
            md5(input::text) AS source_hash,
            otlet.semantic_content_hash(input, %6$L::jsonb) AS content_hash
          FROM raw_inputs
        ),
        latest AS (
          SELECT DISTINCT ON (sm.subject_id)
            sm.subject_id,
            sm.stale,
            sm.source_hash,
            sm.content_hash,
            sm.contract_hash,
            sm.stale_reason,
            sm.updated_at,
            sm.id
          FROM current_inputs ci
          JOIN otlet.semantic_materializations sm
            ON sm.subject_id = ci.subject_id
          WHERE sm.task_name = %3$L
            AND sm.record_type = %4$L
          ORDER BY
            sm.subject_id,
            (
              sm.content_hash IS NOT DISTINCT FROM ci.content_hash
              AND sm.contract_hash IS NOT DISTINCT FROM %5$L
            ) DESC,
            sm.updated_at DESC,
            sm.id DESC
        ),
        classified AS (
          SELECT
            ci.subject_id,
            l.subject_id IS NOT NULL AS has_materialization,
            COALESCE(status.is_fresh, false) AS source_fresh,
            (l.subject_id IS NOT NULL AND COALESCE(status.is_stale, true)) AS source_stale,
            COALESCE(status.stale_reason, 'content_revalidation_pending') AS stale_reason
          FROM current_inputs ci
          LEFT JOIN latest l USING (subject_id)
          LEFT JOIN LATERAL otlet.semantic_freshness_status(
            l.content_hash,
            l.contract_hash,
            l.stale,
            l.stale_reason,
            l.source_hash,
            ci.content_hash,
            %5$L,
            ci.source_hash
          ) status ON l.subject_id IS NOT NULL
        )
        SELECT
          count(*)::bigint,
          count(*) FILTER (WHERE has_materialization AND source_fresh)::bigint,
          count(*) FILTER (WHERE source_stale)::bigint,
          count(*) FILTER (WHERE NOT has_materialization)::bigint,
          COALESCE(
            (
              SELECT jsonb_object_agg(reason, reason_count ORDER BY reason)
              FROM (
                SELECT stale_reason AS reason, count(*) AS reason_count
                FROM classified
                WHERE source_stale
                GROUP BY stale_reason
              ) reasons
            ),
            '{}'::jsonb
          )
        FROM classified
      $sql$,
      index_row.candidate_query,
      index_row.max_candidate_rows,
      index_row.task_name,
      index_row.record_type,
      current_contract_hash,
      current_input_shaping
    )
    INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects, v_stale_reasons;
  ELSE
    WITH latest AS (
      SELECT DISTINCT ON (sm.subject_id)
        sm.subject_id,
        sm.stale,
        sm.source_hash,
        sm.content_hash,
        sm.contract_hash,
        sm.stale_reason,
        sm.updated_at,
        sm.id
      FROM otlet.semantic_materializations sm
      WHERE sm.task_name = index_row.task_name
        AND sm.record_type = index_row.record_type
      ORDER BY
        sm.subject_id,
        (
          NOT sm.stale
          AND sm.contract_hash IS NOT DISTINCT FROM current_contract_hash
        ) DESC,
        sm.updated_at DESC,
        sm.id DESC
    ),
    classified AS (
      SELECT
        subject_id,
        status.is_fresh,
        status.is_stale,
        COALESCE(status.stale_reason, 'content_revalidation_pending') AS stale_reason
      FROM latest
      CROSS JOIN LATERAL otlet.semantic_freshness_status(
        content_hash,
        contract_hash,
        stale,
        stale_reason,
        source_hash,
        content_hash,
        current_contract_hash,
        source_hash
      ) status
    ),
    materialized AS (
      SELECT
        count(*)::bigint AS materialized_subjects,
        count(*) FILTER (WHERE is_fresh)::bigint AS fresh_subjects,
        count(*) FILTER (WHERE is_stale)::bigint AS stale_subjects,
        COALESCE(
          (
            SELECT jsonb_object_agg(reason_rows.reason, reason_rows.reason_count ORDER BY reason_rows.reason)
            FROM (
              SELECT stale_reason AS reason, count(*) AS reason_count
              FROM classified
              WHERE is_stale
              GROUP BY stale_reason
            ) reason_rows
          ),
          '{}'::jsonb
        ) AS stale_reasons
      FROM classified
    )
    SELECT
      CASE
        WHEN m.materialized_subjects > 0 THEN m.materialized_subjects
        ELSE COALESCE(index_row.max_candidate_rows, 0)::bigint
      END,
      m.fresh_subjects,
      m.stale_subjects,
      GREATEST(
        (
          CASE
            WHEN m.materialized_subjects > 0 THEN m.materialized_subjects
            ELSE COALESCE(index_row.max_candidate_rows, 0)::bigint
          END
        ) - m.fresh_subjects - m.stale_subjects,
        0
      ),
      m.stale_reasons
    INTO v_total_subjects, v_fresh_subjects, v_stale_subjects, v_missing_subjects, v_stale_reasons
    FROM materialized m;
  END IF;

  RETURN QUERY
  SELECT *
  FROM otlet.semantic_plan_from_counts(
    index_row.name,
    index_row.task_name,
    index_row.record_type,
    index_row.model_name,
    'semantic_join:' || index_row.name,
    'semantic_join_lookup',
    'empty candidate set',
    'semantic join index fully fresh',
    'policy returns fresh pair lookup rows only',
    'partial pair refresh queued before lookup',
    'fresh_pair_inference',
    'fresh pair inference has no reusable semantic coverage',
    v_total_subjects,
    v_fresh_subjects,
    v_stale_subjects,
    v_missing_subjects,
    v_stale_reasons,
    v_count_basis
  );
END;
$$;
