CREATE FUNCTION otlet.entity_graph_conflict_status_for_task(
  target_task_name text
) RETURNS TABLE (
  conflict_hash text,
  conflict_status text,
  task_name text,
  active_workload_revision_hash text,
  relevant_contract_hash text,
  cannot_fact_hash text,
  subject_id text,
  left_id text,
  right_id text,
  review_event_id bigint,
  reviewer_identity text,
  reviewer_role text,
  review_reason text,
  source_hash text,
  content_hash text,
  current_source_hash text,
  current_content_hash text,
  active_fact_count bigint,
  active_must_link_count bigint,
  active_cannot_link_count bigint,
  active_vertex_count bigint,
  estimated_state_count numeric,
  estimated_edge_visit_count numeric,
  created_at timestamptz
)
LANGUAGE sql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
WITH RECURSIVE active_facts AS MATERIALIZED (
  SELECT
    fact.fact_hash,
    fact.task_name,
    fact.subject_id,
    fact.left_id,
    fact.right_id,
    fact.relation,
    fact.relevant_contract_hash,
    fact.source_hash,
    fact.content_hash,
    fact.review_event_id,
    fact.reviewer_identity,
    fact.reviewer_role,
    review.reason AS review_reason,
    head.active_workload_revision_hash,
    active.relevant_contract_hash AS active_relevant_contract_hash,
    active.current_source_hash,
    active.current_content_hash,
    fact.created_at
  FROM (
    SELECT scoped.*
    FROM otlet.pair_constraint_facts scoped
    WHERE scoped.task_name = $1
  ) fact
  JOIN otlet.tasks task ON task.name = fact.task_name
  JOIN otlet.workload_revision_heads head
    ON head.task_name = fact.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash =
     head.active_workload_revision_hash
  LEFT JOIN LATERAL (
    SELECT otlet.pair_constraint_current_input(
      fact.task_name,
      fact.subject_id,
      head.active_workload_revision_hash
    ) AS input
  ) current_input ON true
  LEFT JOIN LATERAL (
    SELECT
      otlet.pair_constraint_contract_hash(revision.definition)
        AS relevant_contract_hash,
      CASE WHEN current_input.input IS NULL THEN NULL
        ELSE otlet.semantic_source_hash(current_input.input)
      END AS current_source_hash,
      CASE WHEN current_input.input IS NULL THEN NULL
        ELSE otlet.semantic_content_hash(
          current_input.input,
          revision.definition #> '{task,input_shaping}'
        )
      END AS current_content_hash
  ) active ON true
  JOIN otlet.review_events review ON review.id = fact.review_event_id
  WHERE fact.task_name = $1
    AND task.lifecycle_state = 'active'
    AND active.relevant_contract_hash = fact.relevant_contract_hash
    AND active.current_source_hash = fact.source_hash
    AND active.current_content_hash = fact.content_hash
), vertices AS (
  SELECT fact.left_id AS entity_id
  FROM active_facts fact
  UNION
  SELECT fact.right_id AS entity_id
  FROM active_facts fact
), fact_counts AS (
  SELECT
    $1 AS task_name,
    min(fact.active_workload_revision_hash) AS active_workload_revision_hash,
    min(fact.active_relevant_contract_hash) AS relevant_contract_hash,
    count(*) AS active_fact_count,
    count(*) FILTER (WHERE fact.relation = 'must_link')
      AS active_must_link_count,
    count(*) FILTER (WHERE fact.relation = 'cannot_link')
      AS active_cannot_link_count,
    max(fact.created_at) AS latest_fact_at
  FROM active_facts fact
  HAVING count(*) > 0
), counts AS (
  SELECT
    fact_counts.*,
    (
      SELECT count(*)
      FROM vertices
    ) AS active_vertex_count,
    fact_counts.active_cannot_link_count::numeric * (
      SELECT count(*)
      FROM vertices
    )::numeric AS estimated_state_count,
    fact_counts.active_cannot_link_count::numeric
      * fact_counts.active_must_link_count::numeric
      * 2::numeric AS estimated_edge_visit_count
  FROM fact_counts
), bounded_counts AS (
  SELECT
    counts.*,
    -- ponytail: Per-task recursive cap; persist graph state only after measured need
    counts.active_fact_count <= 4096
      AND counts.active_vertex_count <= 4096
      AND counts.estimated_state_count <= 1000000
      AND counts.estimated_edge_visit_count <= 1000000 AS within_limits
  FROM counts
), must_edges AS (
  SELECT fact.left_id AS from_id, fact.right_id AS to_id
  FROM active_facts fact
  CROSS JOIN bounded_counts bounded
  WHERE fact.relation = 'must_link'
    AND bounded.within_limits
  UNION
  SELECT fact.right_id AS from_id, fact.left_id AS to_id
  FROM active_facts fact
  CROSS JOIN bounded_counts bounded
  WHERE fact.relation = 'must_link'
    AND bounded.within_limits
), cannot_facts AS (
  SELECT fact.*
  FROM active_facts fact
  CROSS JOIN bounded_counts bounded
  WHERE fact.relation = 'cannot_link'
    AND bounded.within_limits
), reach (cannot_fact_hash, entity_id) AS (
  SELECT fact.fact_hash, fact.left_id
  FROM cannot_facts fact
  UNION
  SELECT reach.cannot_fact_hash, edge.to_id
  FROM reach
  JOIN must_edges edge
    ON edge.from_id = reach.entity_id
), conflicts AS (
  SELECT fact.*
  FROM cannot_facts fact
  WHERE EXISTS (
    SELECT 1
    FROM reach
    WHERE reach.cannot_fact_hash = fact.fact_hash
      AND reach.entity_id = fact.right_id
  )
)
SELECT
  otlet.identity_hash(
    'entity_graph_conflict',
    jsonb_build_object(
      'task_name', conflict.task_name,
      'cannot_fact_hash', conflict.fact_hash
    )
  ) AS conflict_hash,
  'conflict'::text AS conflict_status,
  conflict.task_name,
  conflict.active_workload_revision_hash,
  conflict.relevant_contract_hash,
  conflict.fact_hash AS cannot_fact_hash,
  conflict.subject_id,
  conflict.left_id,
  conflict.right_id,
  conflict.review_event_id,
  conflict.reviewer_identity,
  conflict.reviewer_role,
  conflict.review_reason,
  conflict.source_hash,
  conflict.content_hash,
  conflict.current_source_hash,
  conflict.current_content_hash,
  counts.active_fact_count,
  counts.active_must_link_count,
  counts.active_cannot_link_count,
  counts.active_vertex_count,
  counts.estimated_state_count,
  counts.estimated_edge_visit_count,
  conflict.created_at
FROM conflicts conflict
JOIN counts ON counts.task_name = conflict.task_name
UNION ALL
SELECT
  otlet.identity_hash(
    'entity_graph_analysis_limit',
    jsonb_build_object(
      'task_name', counts.task_name,
      'relevant_contract_hash', counts.relevant_contract_hash,
      'active_fact_count', counts.active_fact_count,
      'active_vertex_count', counts.active_vertex_count
    )
  ),
  'analysis_limit_exceeded'::text,
  counts.task_name,
  counts.active_workload_revision_hash,
  counts.relevant_contract_hash,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  counts.active_fact_count,
  counts.active_must_link_count,
  counts.active_cannot_link_count,
  counts.active_vertex_count,
  counts.estimated_state_count,
  counts.estimated_edge_visit_count,
  counts.latest_fact_at
FROM bounded_counts counts
WHERE counts.active_cannot_link_count > 0
  AND NOT counts.within_limits;
$$;

CREATE VIEW otlet.entity_graph_conflict_status AS
SELECT conflict.*
FROM (
  SELECT DISTINCT fact.task_name
  FROM otlet.pair_constraint_facts fact
) task
CROSS JOIN LATERAL otlet.entity_graph_conflict_status_for_task(
  task.task_name
) conflict;

CREATE FUNCTION otlet.lock_entity_graph_task(task_name text) RETURNS void
LANGUAGE sql
VOLATILE
STRICT
AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'otlet_entity_graph:' || $1,
    0
  ));
$$;

CREATE FUNCTION otlet.lock_entity_graph_fact_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  PERFORM otlet.lock_entity_graph_task(NEW.task_name);
  RETURN NEW;
END;
$$;

CREATE TRIGGER pair_constraint_facts_entity_graph_lock
BEFORE INSERT ON otlet.pair_constraint_facts
FOR EACH ROW EXECUTE FUNCTION otlet.lock_entity_graph_fact_write();

CREATE FUNCTION otlet.require_entity_graph_clear(
  task_name text,
  operation text
) RETURNS void
LANGUAGE plpgsql
VOLATILE
STRICT
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  blocker record;
BEGIN
  PERFORM otlet.lock_entity_graph_task(require_entity_graph_clear.task_name);
  SELECT status.conflict_hash, status.conflict_status
  INTO blocker
  FROM otlet.entity_graph_conflict_status_for_task(
    require_entity_graph_clear.task_name
  ) status
  ORDER BY status.conflict_status, status.conflict_hash
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'otlet entity graph blocker prevents % for task %',
      require_entity_graph_clear.operation,
      require_entity_graph_clear.task_name
      USING DETAIL = format(
        '%s: %s',
        blocker.conflict_status,
        blocker.conflict_hash
      );
  END IF;
END;
$$;

CREATE FUNCTION otlet.guard_entity_graph_action_approval() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  graph_task_name text;
BEGIN
  SELECT job.task_name
  INTO graph_task_name
  FROM otlet.jobs job
  WHERE job.id = NEW.job_id;
  PERFORM otlet.require_entity_graph_clear(
    graph_task_name,
    'recommendation approval'
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER actions_entity_graph_approval
BEFORE UPDATE OF status, approval_status ON otlet.actions
FOR EACH ROW
WHEN (
  NEW.action_type IN ('merge_candidate', 'new_entity')
  AND NEW.status = 'approved'
  AND NEW.approval_status = 'approved'
  AND (
    OLD.status <> 'approved'
    OR OLD.approval_status <> 'approved'
  )
)
EXECUTE FUNCTION otlet.guard_entity_graph_action_approval();

CREATE FUNCTION otlet.guard_entity_graph_promotion() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     OR NEW.active_workload_revision_hash IS DISTINCT FROM
       OLD.active_workload_revision_hash THEN
    PERFORM otlet.require_entity_graph_clear(
      NEW.task_name,
      'workload promotion'
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_entity_graph
AFTER INSERT OR UPDATE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.guard_entity_graph_promotion();

CREATE OR REPLACE FUNCTION otlet.export_eval_cases(
  max_rows integer DEFAULT 1000
)
RETURNS TABLE (
  label_id bigint,
  fixture_source text,
  case_kind text,
  manual_gold boolean,
  source_table text,
  subject_id text,
  source_hash text,
  expected_answer text,
  expected_confidence text,
  expected_action_type text,
  label_source text,
  reason text,
  action_id bigint,
  output_id bigint,
  receipt_id bigint,
  created_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  exported record;
  selected_task text;
  selected_tasks text[] := ARRAY[]::text[];
BEGIN
  FOR exported IN
    SELECT
      label.task_name AS graph_task_name,
      label.id AS label_id,
      'otlet_eval_labels_generated'::text AS fixture_source,
      CASE
        WHEN label.label_source = 'manual_correction' THEN 'gold'
        WHEN declared.action_answer IS NOT NULL
          AND label.expected_answer <> declared.action_answer
          THEN 'false_trusted'
        WHEN label.expected_answer = ANY(contract.abstain_values)
          THEN 'abstention'
        WHEN label.expected_answer = contract.primary_answer THEN 'positive'
        WHEN contract.primary_answer IS NOT NULL THEN 'hard_negative'
        ELSE 'gold'
      END AS case_kind,
      label.label_source = 'manual_correction' AS manual_gold,
      label.source_table,
      label.subject_id,
      label.source_hash,
      label.expected_answer,
      label.expected_confidence,
      label.expected_action_type,
      label.label_source,
      label.reason,
      label.action_id,
      label.output_id,
      label.receipt_id,
      label.created_at
    FROM otlet.eval_labels label
    LEFT JOIN otlet.actions action ON action.id = label.action_id
    LEFT JOIN otlet.jobs job ON job.id = action.job_id
    LEFT JOIN otlet.workload_revisions revision
      ON revision.workload_revision_hash = job.workload_revision_hash
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          NULLIF(
            revision.definition #>>
              '{task,decision_contract,answer_field}',
            ''
          ),
          'match'
        ) AS answer_field,
        COALESCE(
          (
            SELECT array_agg(value)
            FROM jsonb_array_elements_text(COALESCE(
              revision.definition #>
                '{task,decision_contract,abstain_values}',
              '[]'::jsonb
            )) AS abstain(value)
          ),
          ARRAY[]::text[]
        ) AS abstain_values,
        (
          SELECT value
          FROM unnest(otlet.output_schema_enum_values(
            revision.definition #> '{task,output_schema}',
            COALESCE(
              NULLIF(
                revision.definition #>>
                  '{task,decision_contract,answer_field}',
                ''
              ),
              'match'
            )
          )) WITH ORDINALITY AS answer(value, ord)
          WHERE NOT value = ANY(COALESCE(
            (
              SELECT array_agg(abstain_value)
              FROM jsonb_array_elements_text(COALESCE(
                revision.definition #>
                  '{task,decision_contract,abstain_values}',
                '[]'::jsonb
              )) AS abstain(abstain_value)
            ),
            ARRAY[]::text[]
          ))
          ORDER BY ord
          LIMIT 1
        ) AS primary_answer
    ) contract ON true
    LEFT JOIN LATERAL (
      SELECT otlet.action_declared_answer(
        COALESCE(NULLIF(label.expected_action_type, ''), action.action_type),
        contract.answer_field
      ) AS action_answer
    ) declared ON true
    ORDER BY label.created_at DESC, label.id DESC
    LIMIT GREATEST(0, LEAST(COALESCE(
      export_eval_cases.max_rows,
      1000
    ), 100000))
  LOOP
    label_id := exported.label_id;
    fixture_source := exported.fixture_source;
    case_kind := exported.case_kind;
    manual_gold := exported.manual_gold;
    source_table := exported.source_table;
    subject_id := exported.subject_id;
    source_hash := exported.source_hash;
    expected_answer := exported.expected_answer;
    expected_confidence := exported.expected_confidence;
    expected_action_type := exported.expected_action_type;
    label_source := exported.label_source;
    reason := exported.reason;
    action_id := exported.action_id;
    output_id := exported.output_id;
    receipt_id := exported.receipt_id;
    created_at := exported.created_at;
    RETURN NEXT;

    IF exported.graph_task_name IS NOT NULL
       AND NOT exported.graph_task_name = ANY(selected_tasks) THEN
      selected_tasks := array_append(
        selected_tasks,
        exported.graph_task_name
      );
    END IF;
  END LOOP;

  FOR selected_task IN
    SELECT selected.task_name
    FROM unnest(selected_tasks) selected(task_name)
    ORDER BY selected.task_name COLLATE "C"
  LOOP
    PERFORM otlet.require_entity_graph_clear(
      selected_task,
      'evaluation export'
    );
  END LOOP;
END;
$$;

ALTER VIEW otlet.review_queue
RENAME TO review_queue_without_entity_graph_conflicts;

CREATE VIEW otlet.review_queue AS
SELECT queue.*
FROM otlet.review_queue_without_entity_graph_conflicts queue
UNION ALL
SELECT
  'entity_graph_conflict'::text,
  'review_graph_conflict'::text,
  conflict.task_name,
  conflict.active_workload_revision_hash,
  COALESCE(
    revision.definition #>> '{source,watch_name}',
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{source,semantic_join_index_name}'
  ),
  conflict.subject_id,
  conflict.subject_id,
  NULL::bigint,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::text,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::bigint,
  NULL::text,
  NULL::text,
  NULL::text,
  concat_ws(': ', conflict.conflict_status, conflict.conflict_hash),
  jsonb_strip_nulls(jsonb_build_object(
    'conflict_hash', conflict.conflict_hash,
    'conflict_status', conflict.conflict_status,
    'cannot_fact_hash', conflict.cannot_fact_hash,
    'left_id', conflict.left_id,
    'right_id', conflict.right_id,
    'review_event_id', conflict.review_event_id,
    'reviewer_identity', conflict.reviewer_identity,
    'reviewer_role', conflict.reviewer_role,
    'active_fact_count', conflict.active_fact_count,
    'active_must_link_count', conflict.active_must_link_count,
    'active_cannot_link_count', conflict.active_cannot_link_count,
    'active_vertex_count', conflict.active_vertex_count
  )),
  NULL::text,
  conflict.source_hash,
  conflict.content_hash,
  conflict.current_content_hash,
  false,
  conflict.created_at
FROM otlet.entity_graph_conflict_status conflict
LEFT JOIN otlet.workload_revisions revision
  ON revision.task_name = conflict.task_name
 AND revision.workload_revision_hash = conflict.active_workload_revision_hash
ORDER BY created_at, task_name, job_subject_id, queue_kind;

CREATE OR REPLACE VIEW otlet.audit_review_export AS
SELECT
  q.queue_kind,
  q.next_operator_step,
  q.task_name,
  q.workload_revision_hash,
  q.watch_name,
  q.job_subject_id,
  q.subject_id,
  q.action_id,
  q.output_id,
  q.receipt_id,
  q.action_type,
  a.authority_origin,
  a.authority_mode,
  a.evaluation_status,
  a.authority_policy_hash,
  a.subject_namespace,
  a.target_name,
  q.action_status,
  q.approval_status,
  q.dry_run_status,
  q.apply_status,
  otlet.identity_text_hash(
    'audit_idempotency_key',
    q.idempotency_key
  ) AS idempotency_key_hash,
  q.execution_receipt_id,
  q.execution_mode,
  q.execution_status,
  q.execution_affected_rows,
  q.execution_before_hash,
  q.execution_result_hash,
  q.execution_error,
  q.review_reason,
  q.source_table,
  q.source_hash,
  q.content_hash,
  q.current_content_hash,
  q.source_stale,
  q.created_at,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'conflict_hash'
  END AS entity_graph_conflict_hash,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'conflict_status'
  END AS entity_graph_conflict_status,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'cannot_fact_hash'
  END AS entity_graph_cannot_fact_hash,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'left_id'
  END AS entity_graph_left_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'right_id'
  END AS entity_graph_right_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN (q.output ->> 'review_event_id')::bigint
  END AS entity_graph_review_event_id,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'reviewer_identity'
  END AS entity_graph_reviewer_identity,
  CASE WHEN q.queue_kind = 'entity_graph_conflict'
    THEN q.output ->> 'reviewer_role'
  END AS entity_graph_reviewer_role
FROM otlet.review_queue q
LEFT JOIN otlet.actions a ON a.id = q.action_id;

CREATE OR REPLACE FUNCTION otlet.finish_access_policy_grant(
  policy_name text,
  target_role regrole,
  old_revision_hash text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  role_name text;
  new_revision_hash text;
BEGIN
  SELECT role.rolname
  INTO role_name
  FROM pg_catalog.pg_roles role
  WHERE role.oid = finish_access_policy_grant.target_role::oid;

  IF finish_access_policy_grant.policy_name IN ('auditor', 'operator') THEN
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE '
      'otlet.audit_administrative_change_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text) TO %I',
      role_name
    );
  END IF;
  new_revision_hash := otlet.access_policy_revision(
    finish_access_policy_grant.target_role
  );
  PERFORM otlet.append_administrative_change(
    'access_policy',
    finish_access_policy_grant.policy_name || ':' || role_name,
    'grant',
    finish_access_policy_grant.old_revision_hash,
    new_revision_hash
  );
END;
$$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT role.rolname
    FROM pg_catalog.pg_class relation
    CROSS JOIN LATERAL pg_catalog.aclexplode(relation.relacl) privilege
    JOIN pg_catalog.pg_roles role ON role.oid = privilege.grantee
    WHERE relation.oid = 'otlet.audit_review_export'::regclass
      AND privilege.privilege_type = 'SELECT'
      AND role.oid <> relation.relowner
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.entity_graph_conflict_status_for_task(text) TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE ALL ON TABLE otlet.entity_graph_conflict_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue_without_entity_graph_conflicts
  FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  otlet.entity_graph_conflict_status_for_task(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lock_entity_graph_task(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lock_entity_graph_fact_write() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.require_entity_graph_clear(text,text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_entity_graph_action_approval()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_entity_graph_promotion() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.export_eval_cases(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.grant_auditor_access(regrole) FROM PUBLIC;
