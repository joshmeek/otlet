ALTER TABLE otlet.production_policy
ADD COLUMN max_active_jobs_per_task integer NOT NULL DEFAULT 8,
ADD COLUMN max_queued_input_bytes_per_task bigint,
ADD COLUMN max_queue_age interval NOT NULL DEFAULT interval '1 day';

UPDATE otlet.production_policy
SET max_queued_input_bytes_per_task = LEAST(
  67108864,
  max_queued_input_bytes_total
);

ALTER TABLE otlet.production_policy
ALTER COLUMN max_queued_input_bytes_per_task SET DEFAULT 67108864,
ALTER COLUMN max_queued_input_bytes_per_task SET NOT NULL,
ADD CONSTRAINT production_policy_task_active_jobs_bound CHECK (
  max_active_jobs_per_task BETWEEN 1 AND 1024
),
ADD CONSTRAINT production_policy_task_queue_bytes_bound CHECK (
  max_queued_input_bytes_per_task BETWEEN 1 AND 1073741824
),
ADD CONSTRAINT production_policy_task_queue_bytes_global_bound CHECK (
  max_queued_input_bytes_per_task <= max_queued_input_bytes_total
),
ADD CONSTRAINT production_policy_task_queue_age_bound CHECK (
  max_queue_age BETWEEN interval '1 second' AND interval '30 days'
);

ALTER TABLE otlet.jobs
ADD COLUMN job_origin text NOT NULL DEFAULT 'task_run',
ADD CONSTRAINT jobs_job_origin_check CHECK (job_origin IN (
  'direct_ask',
  'task_run',
  'row_watch',
  'pair_watch',
  'catch_up',
  'backfill',
  'customscan'
));

UPDATE otlet.jobs job
SET job_origin = CASE
  WHEN job.backfill_id IS NOT NULL THEN 'backfill'
  WHEN job.task_name LIKE 'ask_v1_%' THEN 'direct_ask'
  ELSE 'task_run'
END;

ALTER TABLE otlet.task_candidate_observations
DROP CONSTRAINT task_candidate_observations_rejection_reason_check,
ADD CONSTRAINT task_candidate_observations_rejection_reason_check CHECK (
  rejection_reason IN (
    'row_cap',
    'queue_depth_cap',
    'input_byte_cap',
    'task_queue_age_cap',
    'task_queued_input_byte_cap',
    'model_queued_input_byte_cap',
    'total_queued_input_byte_cap'
  )
);

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_functiondef(
    'otlet.record_task_candidate_observation('
      'text,text,bigint,bigint,bigint,boolean,text)'::regprocedure
  );
  old_fragment := $old$         'input_byte_cap',
         'model_queued_input_byte_cap',$old$;
  new_fragment := $new$         'input_byte_cap',
         'task_queue_age_cap',
         'task_queued_input_byte_cap',
         'model_queued_input_byte_cap',$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task candidate rejection rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);
END;
$migration$;

CREATE INDEX jobs_task_queued_created_idx
ON otlet.jobs (task_name, created_at, id)
WHERE status = 'queued';

CREATE VIEW otlet.task_queue_capacity AS
WITH queued AS (
  SELECT
    job.task_name,
    count(*)::bigint AS queued_jobs,
    COALESCE(sum(octet_length(job.input::text)), 0)::bigint
      AS queued_input_bytes,
    min(job.created_at) AS oldest_queued_at
  FROM otlet.jobs job
  LEFT JOIN otlet.workload_revision_heads head
    ON head.task_name = job.task_name
  WHERE job.status = 'queued'
    AND CASE job.execution_mode
      WHEN 'evaluation' THEN true
      ELSE head.active_workload_revision_hash = job.workload_revision_hash
    END
  GROUP BY job.task_name
)
SELECT
  task.name AS task_name,
  policy.max_queued_input_bytes_per_task,
  policy.max_queue_age,
  COALESCE(queued.queued_jobs, 0)::bigint AS queued_jobs,
  COALESCE(queued.queued_input_bytes, 0)::bigint AS queued_input_bytes,
  GREATEST(
    policy.max_queued_input_bytes_per_task
      - COALESCE(queued.queued_input_bytes, 0),
    0
  )::bigint AS available_queued_input_bytes,
  queued.oldest_queued_at,
  CASE WHEN queued.oldest_queued_at IS NULL THEN NULL
    ELSE GREATEST(
      statement_timestamp() - queued.oldest_queued_at,
      interval '0 seconds'
    )
  END AS oldest_queue_age,
  COALESCE(
    queued.oldest_queued_at + policy.max_queue_age
      <= statement_timestamp(),
    false
  ) AS queue_age_exceeded,
  COALESCE(
    queued.queued_input_bytes >= policy.max_queued_input_bytes_per_task,
    false
  ) AS queue_bytes_exhausted
FROM otlet.tasks task
CROSS JOIN otlet.production_policy policy
LEFT JOIN queued ON queued.task_name = task.name
WHERE policy.name = 'default';

CREATE VIEW otlet.task_claim_capacity AS
WITH active AS (
  SELECT job.task_name, count(*)::bigint AS active_claimed_jobs
  FROM otlet.jobs job
  WHERE job.status IN ('running', 'cancel_requested')
    AND job.leased_until >= statement_timestamp()
  GROUP BY job.task_name
)
SELECT
  task.name AS task_name,
  policy.max_active_jobs_per_task,
  COALESCE(active.active_claimed_jobs, 0)::bigint AS active_claimed_jobs,
  GREATEST(
    policy.max_active_jobs_per_task::bigint
      - COALESCE(active.active_claimed_jobs, 0),
    0
  )::bigint AS available_active_job_slots
FROM otlet.tasks task
CROSS JOIN otlet.production_policy policy
LEFT JOIN active ON active.task_name = task.name
WHERE policy.name = 'default';

CREATE VIEW otlet.task_queue_status AS
WITH origin_queue AS (
  SELECT
    job.task_name,
    job.job_origin,
    count(*)::bigint AS queued_jobs,
    COALESCE(sum(octet_length(job.input::text)), 0)::bigint
      AS queued_input_bytes,
    min(job.created_at) AS oldest_queued_at
  FROM otlet.jobs job
  LEFT JOIN otlet.workload_revision_heads head
    ON head.task_name = job.task_name
  WHERE job.status = 'queued'
    AND CASE job.execution_mode
      WHEN 'evaluation' THEN true
      ELSE head.active_workload_revision_hash = job.workload_revision_hash
    END
  GROUP BY job.task_name, job.job_origin
)
SELECT
  origin.task_name,
  origin.job_origin,
  origin.queued_jobs,
  origin.queued_input_bytes,
  origin.oldest_queued_at,
  GREATEST(
    statement_timestamp() - origin.oldest_queued_at,
    interval '0 seconds'
  ) AS oldest_queue_age,
  capacity.queued_jobs AS task_queued_jobs,
  capacity.queued_input_bytes AS task_queued_input_bytes,
  capacity.max_queued_input_bytes_per_task,
  capacity.available_queued_input_bytes,
  capacity.max_queue_age,
  origin.oldest_queued_at + capacity.max_queue_age
    <= statement_timestamp() AS origin_queue_age_exceeded,
  capacity.queue_age_exceeded AS task_queue_age_exceeded,
  capacity.queue_bytes_exhausted
FROM origin_queue origin
JOIN otlet.task_queue_capacity capacity
  ON capacity.task_name = origin.task_name;

CREATE VIEW otlet.task_resource_status AS
WITH origin_active AS (
  SELECT
    job.task_name,
    job.job_origin,
    count(*)::bigint AS active_claimed_jobs
  FROM otlet.jobs job
  WHERE job.status IN ('running', 'cancel_requested')
    AND job.leased_until >= statement_timestamp()
  GROUP BY job.task_name, job.job_origin
)
SELECT
  origin.task_name,
  origin.job_origin,
  origin.active_claimed_jobs,
  capacity.active_claimed_jobs AS task_active_claimed_jobs,
  capacity.max_active_jobs_per_task,
  capacity.available_active_job_slots,
  capacity.available_active_job_slots = 0 AS task_concurrency_exhausted
FROM origin_active origin
JOIN otlet.task_claim_capacity capacity
  ON capacity.task_name = origin.task_name;

CREATE FUNCTION otlet.guard_job_origin_and_budget() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  queue_capacity otlet.task_queue_capacity%ROWTYPE;
  claim_capacity otlet.task_claim_capacity%ROWTYPE;
  new_input_bytes bigint;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.job_origin IS DISTINCT FROM OLD.job_origin THEN
      RAISE EXCEPTION 'otlet job origin is immutable';
    END IF;
    RETURN NEW;
  END IF;

  NEW.job_origin := COALESCE(NEW.job_origin, 'task_run');
  IF NEW.job_origin NOT IN (
    'direct_ask',
    'task_run',
    'row_watch',
    'pair_watch',
    'catch_up',
    'backfill',
    'customscan'
  ) THEN
    RAISE EXCEPTION 'otlet job origin % is unsupported', NEW.job_origin;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  IF NEW.status = 'queued'
     AND (
       NEW.execution_mode = 'evaluation'
       OR EXISTS (
         SELECT 1
         FROM otlet.workload_revision_heads head
         WHERE head.task_name = NEW.task_name
           AND head.active_workload_revision_hash = NEW.workload_revision_hash
       )
     ) THEN
    SELECT *
    INTO STRICT queue_capacity
    FROM otlet.task_queue_capacity capacity
    WHERE capacity.task_name = NEW.task_name;
    new_input_bytes := octet_length(NEW.input::text);
    IF queue_capacity.queue_age_exceeded THEN
      RAISE EXCEPTION 'otlet task queue age cap exceeded for task %', NEW.task_name;
    END IF;
    IF queue_capacity.queued_input_bytes + new_input_bytes
       > queue_capacity.max_queued_input_bytes_per_task THEN
      RAISE EXCEPTION 'otlet task queued input byte cap exceeded for task %',
        NEW.task_name;
    END IF;
  ELSIF NEW.status IN ('running', 'cancel_requested')
        AND NEW.leased_until >= statement_timestamp() THEN
    SELECT *
    INTO STRICT claim_capacity
    FROM otlet.task_claim_capacity capacity
    WHERE capacity.task_name = NEW.task_name;
    IF claim_capacity.available_active_job_slots <= 0 THEN
      RAISE EXCEPTION 'otlet task active job cap exceeded for task %', NEW.task_name;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER jobs_job_origin_and_budget
BEFORE INSERT OR UPDATE OF job_origin ON otlet.jobs
FOR EACH ROW EXECUTE FUNCTION otlet.guard_job_origin_and_budget();

CREATE FUNCTION otlet.admit_task_input_with_origin(
  task_name text,
  subject_id text,
  input jsonb,
  workload_revision_hash text,
  job_origin text
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  task_model_name text;
  revision_hash text;
  existing_job_id bigint;
  existing_backfill_deferred boolean;
  existing_input jsonb;
  input_bytes bigint := octet_length(admit_task_input_with_origin.input::text);
  policy otlet.production_policy%ROWTYPE;
  task_queue otlet.task_queue_capacity%ROWTYPE;
  queued_jobs bigint;
  model_queued_bytes bigint;
  total_queued_bytes bigint;
  rejection_reason text;
  rejection_limit bigint;
BEGIN
  IF admit_task_input_with_origin.subject_id IS NULL THEN
    RAISE EXCEPTION 'otlet input relation produced null subject_id';
  END IF;
  IF admit_task_input_with_origin.input IS NULL THEN
    RAISE EXCEPTION 'otlet input relation produced null input';
  END IF;

  IF admit_task_input_with_origin.job_origin NOT IN (
    'direct_ask', 'task_run', 'row_watch', 'pair_watch',
    'catch_up', 'backfill', 'customscan'
  ) THEN
    RAISE EXCEPTION 'otlet job origin % is unsupported',
      admit_task_input_with_origin.job_origin;
  END IF;

  revision_hash := otlet.ensure_active_workload_revision(
    admit_task_input_with_origin.task_name
  );
  IF admit_task_input_with_origin.workload_revision_hash IS NOT NULL
     AND admit_task_input_with_origin.workload_revision_hash
       IS DISTINCT FROM revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision is not active for task %',
      admit_task_input_with_origin.task_name;
  END IF;
  SELECT revision.definition #>> '{models,direct,name}'
  INTO task_model_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = admit_task_input_with_origin.task_name
    AND revision.workload_revision_hash = revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not belong to task %',
      admit_task_input_with_origin.task_name;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));

  SELECT active.id, active.backfill_deferred, active.input
  INTO existing_job_id, existing_backfill_deferred, existing_input
  FROM otlet.jobs active
  WHERE active.task_name = admit_task_input_with_origin.task_name
    AND active.workload_revision_hash = revision_hash
    AND active.subject_id = admit_task_input_with_origin.subject_id
    AND active.execution_mode = 'production'
    AND active.status IN ('queued', 'running', 'cancel_requested')
  FOR UPDATE;
  IF FOUND THEN
    IF existing_input IS DISTINCT FROM admit_task_input_with_origin.input THEN
      RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
        admit_task_input_with_origin.subject_id;
    END IF;
    IF existing_backfill_deferred THEN
      PERFORM otlet.promote_task_backfill_job(existing_job_id);
    END IF;
    RETURN false;
  END IF;

  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';
  SELECT * INTO STRICT task_queue
  FROM otlet.task_queue_capacity capacity
  WHERE capacity.task_name = admit_task_input_with_origin.task_name;

  SELECT
    count(*) FILTER (WHERE COALESCE(
      job.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) = task_model_name),
    COALESCE(sum(octet_length(job.input::text)) FILTER (
      WHERE COALESCE(
        job.routed_model_name,
        revision.definition #>> '{models,direct,name}'
      ) = task_model_name
    ), 0),
    COALESCE(sum(octet_length(job.input::text)), 0)
  INTO queued_jobs, model_queued_bytes, total_queued_bytes
  FROM otlet.jobs job
  LEFT JOIN otlet.workload_revision_heads head
    ON head.task_name = job.task_name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE job.status = 'queued'
    AND CASE job.execution_mode
      WHEN 'evaluation' THEN true
      ELSE head.active_workload_revision_hash = job.workload_revision_hash
    END;

  IF input_bytes > policy.max_input_bytes_per_job THEN
    rejection_reason := 'input_byte_cap';
    rejection_limit := policy.max_input_bytes_per_job;
  ELSIF queued_jobs >= policy.max_queued_jobs_per_model THEN
    rejection_reason := 'queue_depth_cap';
    rejection_limit := policy.max_queued_jobs_per_model;
  ELSIF task_queue.queue_age_exceeded THEN
    rejection_reason := 'task_queue_age_cap';
    rejection_limit := NULL;
  ELSIF task_queue.queued_input_bytes + input_bytes
        > task_queue.max_queued_input_bytes_per_task THEN
    rejection_reason := 'task_queued_input_byte_cap';
    rejection_limit := task_queue.max_queued_input_bytes_per_task;
  ELSIF model_queued_bytes + input_bytes
        > policy.max_queued_input_bytes_per_model THEN
    rejection_reason := 'model_queued_input_byte_cap';
    rejection_limit := policy.max_queued_input_bytes_per_model;
  ELSIF total_queued_bytes + input_bytes
        > policy.max_queued_input_bytes_total THEN
    rejection_reason := 'total_queued_input_byte_cap';
    rejection_limit := policy.max_queued_input_bytes_total;
  END IF;

  IF rejection_reason IS NOT NULL THEN
    PERFORM otlet.record_queue_admission_suppressed(
      admit_task_input_with_origin.task_name,
      task_model_name,
      admit_task_input_with_origin.subject_id,
      queued_jobs,
      GREATEST(policy.max_queued_jobs_per_model - queued_jobs, 0)::integer,
      rejection_reason,
      input_bytes,
      rejection_limit,
      revision_hash
    );
    RETURN false;
  END IF;

  INSERT INTO otlet.jobs (
    task_name,
    workload_revision_hash,
    subject_id,
    input,
    job_origin
  )
  VALUES (
    admit_task_input_with_origin.task_name,
    revision_hash,
    admit_task_input_with_origin.subject_id,
    admit_task_input_with_origin.input,
    admit_task_input_with_origin.job_origin
  );
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.admit_task_input(
  task_name text,
  subject_id text,
  input jsonb,
  workload_revision_hash text DEFAULT NULL
) RETURNS boolean
LANGUAGE sql
AS $$
  SELECT otlet.admit_task_input_with_origin(
    task_name,
    subject_id,
    input,
    workload_revision_hash,
    'task_run'
  );
$$;

CREATE FUNCTION otlet.run_task_subject_with_origin(
  task_name text,
  subject_id text,
  expected_workload_revision_hash text,
  job_origin text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  revision_hash text;
  revision_definition jsonb;
  source_kind text;
  semantic_join_index_name text;
  pending_input jsonb;
  queued boolean;
BEGIN
  IF run_task_subject_with_origin.job_origin NOT IN (
    'task_run', 'customscan'
  ) THEN
    RAISE EXCEPTION 'otlet subject job origin % is unsupported',
      run_task_subject_with_origin.job_origin;
  END IF;

  revision_hash := otlet.ensure_active_workload_revision(
    run_task_subject_with_origin.task_name
  );
  IF run_task_subject_with_origin.expected_workload_revision_hash IS NOT NULL
     AND run_task_subject_with_origin.expected_workload_revision_hash
       IS DISTINCT FROM revision_hash THEN
    RAISE EXCEPTION
      'otlet workload revision changed during subject admission for task %',
      run_task_subject_with_origin.task_name;
  END IF;
  SELECT
    revision.definition,
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{source,kind}',
    revision.definition #>> '{source,semantic_join_index_name}'
  INTO revision_definition, query, source_kind, semantic_join_index_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = run_task_subject_with_origin.task_name
    AND revision.workload_revision_hash = revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist',
      run_task_subject_with_origin.task_name;
  END IF;
  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query',
      run_task_subject_with_origin.task_name;
  END IF;
  IF source_kind = 'pair' THEN
    query := format(
      'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L, %L)',
      semantic_join_index_name,
      revision_hash
    );
  END IF;

  PERFORM otlet.require_candidate_query_timeout(
    run_task_subject_with_origin.task_name
  );
  pending_input := otlet.task_subject_input(
    query,
    run_task_subject_with_origin.subject_id,
    revision_definition
  );
  IF pending_input IS NULL THEN
    RETURN 0;
  END IF;

  queued := otlet.admit_task_input_with_origin(
    run_task_subject_with_origin.task_name,
    run_task_subject_with_origin.subject_id,
    pending_input,
    revision_hash,
    run_task_subject_with_origin.job_origin
  );
  IF queued THEN
    PERFORM otlet.resolve_watch_input_reconciliation(
      run_task_subject_with_origin.task_name,
      revision_hash,
      run_task_subject_with_origin.subject_id,
      pending_input
    );
    PERFORM otlet.wake_worker();
  ELSE
    PERFORM otlet.record_watch_input_reconciliation(
      run_task_subject_with_origin.task_name,
      revision_hash,
      run_task_subject_with_origin.subject_id,
      pending_input
    );
  END IF;
  RETURN queued::integer;
END;
$$;

CREATE FUNCTION otlet.run_task_subjects_with_origin(
  task_name text,
  subject_ids text[],
  expected_workload_revision_hash text,
  job_origin text
) RETURNS TABLE (subject_id text, queued boolean)
LANGUAGE plpgsql
AS $$
BEGIN
  IF cardinality(run_task_subjects_with_origin.subject_ids) > 64 THEN
    RAISE EXCEPTION 'otlet.run_task_subjects accepts at most 64 subjects';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(
      run_task_subjects_with_origin.subject_ids,
      ARRAY[]::text[]
    )) requested(subject_id)
    WHERE requested.subject_id IS NULL
  ) THEN
    RAISE EXCEPTION 'otlet input relation produced null subject_id';
  END IF;
  IF cardinality(COALESCE(
       run_task_subjects_with_origin.subject_ids,
       ARRAY[]::text[]
     )) IS DISTINCT FROM (
    SELECT count(DISTINCT requested.subject_id)
    FROM unnest(COALESCE(
      run_task_subjects_with_origin.subject_ids,
      ARRAY[]::text[]
    )) requested(subject_id)
  ) THEN
    RAISE EXCEPTION 'otlet input relation produced duplicate requested subject_id';
  END IF;

  RETURN QUERY
  SELECT requested.subject_id,
         otlet.run_task_subject_with_origin(
           run_task_subjects_with_origin.task_name,
           requested.subject_id,
           run_task_subjects_with_origin.expected_workload_revision_hash,
           run_task_subjects_with_origin.job_origin
         ) > 0
  FROM unnest(COALESCE(
    run_task_subjects_with_origin.subject_ids,
    ARRAY[]::text[]
  )) WITH ORDINALITY AS requested(subject_id, ordinal)
  ORDER BY requested.ordinal;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.run_task_subject(
  task_name text,
  subject_id text,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS bigint
LANGUAGE sql
AS $$
  SELECT otlet.run_task_subject_with_origin(
    task_name,
    subject_id,
    expected_workload_revision_hash,
    'task_run'
  );
$$;

CREATE OR REPLACE FUNCTION otlet.run_task_subjects(
  task_name text,
  subject_ids text[],
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE (subject_id text, queued boolean)
LANGUAGE sql
AS $$
  SELECT *
  FROM otlet.run_task_subjects_with_origin(
    task_name,
    subject_ids,
    expected_workload_revision_hash,
    'task_run'
  );
$$;

CREATE FUNCTION otlet.run_task_with_origin(
  task_name text,
  job_origin text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  query text;
  task_model_name text;
  revision_hash text;
  revision_definition jsonb;
  source_kind text;
  semantic_join_index_name text;
  queue_slots integer;
  queued bigint := 0;
  candidate_rows bigint;
  candidate_bytes bigint;
  largest_input_bytes bigint;
  rejection_reason text;
  rejection_limit bigint;
  reconciled_rows bigint;
BEGIN
  IF run_task_with_origin.job_origin NOT IN (
    'task_run', 'row_watch', 'pair_watch'
  ) THEN
    RAISE EXCEPTION 'otlet bulk job origin % is unsupported',
      run_task_with_origin.job_origin;
  END IF;

  revision_hash := otlet.ensure_active_workload_revision(
    run_task_with_origin.task_name
  );
  SELECT
    revision.definition,
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{models,direct,name}',
    revision.definition #>> '{source,kind}',
    revision.definition #>> '{source,semantic_join_index_name}'
  INTO revision_definition, query, task_model_name, source_kind,
       semantic_join_index_name
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = run_task_with_origin.task_name
    AND revision.workload_revision_hash = revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet task % does not exist', task_name;
  END IF;
  IF query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query', task_name;
  END IF;
  IF source_kind = 'pair' THEN
    query := format(
      'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L, %L)',
      semantic_join_index_name,
      revision_hash
    );
  END IF;

  PERFORM otlet.require_candidate_query_timeout(run_task_with_origin.task_name);
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  EXECUTE format(
    'WITH policy AS (
       SELECT * FROM otlet.production_policy p WHERE p.name = ''default''
     ),
     task_queue AS (
       SELECT * FROM otlet.task_queue_capacity q WHERE q.task_name = %3$L
     ),
     queue_state AS (
       SELECT
         count(*) FILTER (
           WHERE COALESCE(
             j.routed_model_name,
             queued_revisions.definition #>> ''{models,direct,name}''
           ) = %1$L
         )::bigint AS model_queued_jobs,
         COALESCE(sum(octet_length(j.input::text)) FILTER (
           WHERE COALESCE(
             j.routed_model_name,
             queued_revisions.definition #>> ''{models,direct,name}''
           ) = %1$L
         ), 0)::bigint AS model_queued_bytes,
         COALESCE(sum(octet_length(j.input::text)), 0)::bigint
           AS total_queued_bytes
       FROM otlet.jobs j
       LEFT JOIN otlet.workload_revision_heads queued_heads
         ON queued_heads.task_name = j.task_name
       JOIN otlet.workload_revisions queued_revisions
         ON queued_revisions.task_name = j.task_name
        AND queued_revisions.workload_revision_hash = j.workload_revision_hash
       WHERE j.status = ''queued''
         AND CASE j.execution_mode
           WHEN ''evaluation'' THEN true
           ELSE queued_heads.active_workload_revision_hash = j.workload_revision_hash
         END
     ),
     bounded_input AS MATERIALIZED (
       SELECT
         otlet_input.subject_id,
         otlet_input.input,
         octet_length(otlet_input.input::text)::bigint AS input_bytes
       FROM otlet.validated_task_input_rows(
         %2$L,
         (SELECT max_admission_rows + 1 FROM policy),
         %3$L,
         %4$L,
         %5$L::jsonb
       ) otlet_input
     ),
     candidate_state AS (
       SELECT
         count(*)::bigint AS candidate_rows,
         COALESCE(sum(input_bytes), 0)::bigint AS candidate_bytes,
         COALESCE(max(input_bytes), 0)::bigint AS largest_input_bytes
       FROM bounded_input
     ),
     decision AS (
       SELECT
         GREATEST(
           p.max_queued_jobs_per_model - q.model_queued_jobs,
           0
         )::integer AS queue_slots,
         c.*,
         CASE
           WHEN c.candidate_rows > p.max_admission_rows THEN ''row_cap''
           WHEN c.candidate_rows > GREATEST(
             p.max_queued_jobs_per_model - q.model_queued_jobs,
             0
           ) THEN ''queue_depth_cap''
           WHEN c.largest_input_bytes > p.max_input_bytes_per_job
             THEN ''input_byte_cap''
           WHEN t.queue_age_exceeded THEN ''task_queue_age_cap''
           WHEN t.queued_input_bytes + c.candidate_bytes
                > t.max_queued_input_bytes_per_task
             THEN ''task_queued_input_byte_cap''
           WHEN q.model_queued_bytes + c.candidate_bytes
                > p.max_queued_input_bytes_per_model
             THEN ''model_queued_input_byte_cap''
           WHEN q.total_queued_bytes + c.candidate_bytes
                > p.max_queued_input_bytes_total
             THEN ''total_queued_input_byte_cap''
         END AS rejection_reason,
         CASE
           WHEN c.candidate_rows > p.max_admission_rows
             THEN p.max_admission_rows::bigint
           WHEN c.candidate_rows > GREATEST(
             p.max_queued_jobs_per_model - q.model_queued_jobs,
             0
           ) THEN GREATEST(
             p.max_queued_jobs_per_model - q.model_queued_jobs,
             0
           )::bigint
           WHEN c.largest_input_bytes > p.max_input_bytes_per_job
             THEN p.max_input_bytes_per_job
           WHEN t.queue_age_exceeded THEN NULL::bigint
           WHEN t.queued_input_bytes + c.candidate_bytes
                > t.max_queued_input_bytes_per_task
             THEN t.max_queued_input_bytes_per_task
           WHEN q.model_queued_bytes + c.candidate_bytes
                > p.max_queued_input_bytes_per_model
             THEN p.max_queued_input_bytes_per_model
           WHEN q.total_queued_bytes + c.candidate_bytes
                > p.max_queued_input_bytes_total
             THEN p.max_queued_input_bytes_total
         END AS rejection_limit
       FROM policy p
       CROSS JOIN task_queue t
       CROSS JOIN queue_state q
       CROSS JOIN candidate_state c
     ),
     inserted AS (
       INSERT INTO otlet.jobs (
         task_name,
         workload_revision_hash,
         subject_id,
         input,
         job_origin
       )
       SELECT %3$L, %4$L, pending.subject_id, pending.input, %6$L
       FROM bounded_input pending
       CROSS JOIN decision d
       WHERE d.rejection_reason IS NULL
       ORDER BY pending.subject_id COLLATE "C"
       RETURNING 1
     ),
     recorded_reconciliation AS MATERIALIZED (
       SELECT otlet.record_watch_input_reconciliation(
         %3$L, %4$L, pending.subject_id, pending.input
       ) AS generation
       FROM bounded_input pending
       CROSS JOIN decision d
       WHERE d.rejection_reason IS NOT NULL
         AND d.rejection_reason <> ''row_cap''
     ),
     resolved_reconciliation AS MATERIALIZED (
       SELECT otlet.resolve_watch_input_reconciliation(
         %3$L, %4$L, pending.subject_id, pending.input
       ) AS removed
       FROM bounded_input pending
       CROSS JOIN decision d
       WHERE d.rejection_reason IS NULL
     )
     SELECT
       (SELECT count(*) FROM inserted),
       candidate_rows,
       candidate_bytes,
       largest_input_bytes,
       queue_slots,
       rejection_reason,
       rejection_limit,
       (SELECT count(*) FROM recorded_reconciliation)
         + (SELECT count(*) FROM resolved_reconciliation)
     FROM decision',
    task_model_name,
    query,
    task_name,
    revision_hash,
    revision_definition,
    job_origin
  )
  INTO queued, candidate_rows, candidate_bytes, largest_input_bytes, queue_slots,
       rejection_reason, rejection_limit, reconciled_rows;

  IF rejection_reason IS NOT NULL THEN
    PERFORM otlet.record_task_candidate_observation(
      run_task_with_origin.task_name,
      revision_hash,
      candidate_rows,
      candidate_bytes,
      largest_input_bytes,
      false,
      rejection_reason
    );
    PERFORM otlet.record_queue_admission_suppressed(
      run_task_with_origin.task_name,
      task_model_name,
      suppressed_queued_jobs => candidate_rows,
      suppressed_queue_slots => queue_slots,
      suppressed_reason => rejection_reason,
      suppressed_input_bytes => CASE
        WHEN rejection_reason = 'input_byte_cap' THEN largest_input_bytes
        ELSE candidate_bytes
      END,
      suppressed_limit_bytes => rejection_limit,
      suppressed_workload_revision_hash => revision_hash
    );
    RETURN 0;
  END IF;
  IF queued <> candidate_rows THEN
    RAISE EXCEPTION 'otlet queue admission changed concurrently; no jobs were committed';
  END IF;
  PERFORM otlet.record_task_candidate_observation(
    run_task_with_origin.task_name,
    revision_hash,
    candidate_rows,
    candidate_bytes,
    largest_input_bytes,
    true,
    NULL
  );
  IF queued > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;
  RETURN queued;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.run_task(task_name text) RETURNS bigint
LANGUAGE sql
AS $$
  SELECT otlet.run_task_with_origin(task_name, 'task_run');
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_functiondef(
    'otlet.claim_jobs(text,integer,jsonb)'::regprocedure
  );
  old_fragment := $old$      capacity.available_active_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,$old$;
  new_fragment := $new$      capacity.available_active_job_slots,
      task_capacity.available_active_job_slots AS available_task_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity claim projection rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    JOIN otlet.model_claim_capacity capacity
      ON capacity.model_name = job.selected_model ->> 'name'
    WHERE ($old$;
  new_fragment := $new$    JOIN otlet.model_claim_capacity capacity
      ON capacity.model_name = job.selected_model ->> 'name'
    JOIN otlet.task_claim_capacity task_capacity
      ON task_capacity.task_name = job.task_name
    WHERE ($new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity claim join rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      AND capacity.available_active_job_slots > 0
      AND ($old$;
  new_fragment := $new$      AND capacity.available_active_job_slots > 0
      AND task_capacity.available_active_job_slots > 0
      AND ($new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity eligibility rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      capacity.available_active_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END
  ),$old$;
  new_fragment := $new$      capacity.available_active_job_slots,
      task_capacity.available_active_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END
  ),$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity claim grouping rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      f.task_rank,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,$old$;
  new_fragment := $new$      f.task_rank,
      f.available_task_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity candidate projection rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      AND EXISTS (
        SELECT 1
        FROM guarded_tasks task$old$;
  new_fragment := $new$      AND candidate.task_job_rank <= candidate.available_task_job_slots
      AND EXISTS (
        SELECT 1
        FROM guarded_tasks task$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet task-capacity candidate gate rewrite is incomplete';
  END IF;
  definition := replace(definition, old_fragment, new_fragment);
  EXECUTE definition;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_functiondef(
    'otlet.enqueue_ask(text,text,jsonb,jsonb,jsonb)'::regprocedure
  );
  old_fragment := $old$  IF NOT otlet.admit_task_input(direct_task_name, direct_subject_id, actual_input) THEN$old$;
  new_fragment := $new$  IF NOT otlet.admit_task_input_with_origin(
    direct_task_name,
    direct_subject_id,
    actual_input,
    NULL,
    'direct_ask'
  ) THEN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet direct-ask origin rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  definition := pg_get_functiondef(
    'otlet.refresh_semantic_index(text)'::regprocedure
  );
  old_fragment := 'SELECT otlet.run_task(task_name) INTO queued;';
  new_fragment := $$SELECT otlet.run_task_with_origin(task_name, 'row_watch') INTO queued;$$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet row-watch origin rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  definition := pg_get_functiondef(
    'otlet.refresh_semantic_join_index(text)'::regprocedure
  );
  new_fragment := $$SELECT otlet.run_task_with_origin(task_name, 'pair_watch') INTO queued;$$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet pair-watch origin rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  definition := pg_get_functiondef(
    'otlet.reconcile_watch_subject(text,text,boolean)'::regprocedure
  );
  old_fragment := $old$    queued := otlet.admit_task_input(
      watch_row.task_name,
      pending.subject_id,
      pending_input,
      active_revision_hash
    );$old$;
  new_fragment := $new$    queued := otlet.admit_task_input_with_origin(
      watch_row.task_name,
      pending.subject_id,
      pending_input,
      active_revision_hash,
      'catch_up'
    );$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet catch-up origin rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  definition := pg_get_functiondef(
    'otlet.submit_task_backfill_page(bigint,bigint)'::regprocedure
  );
  old_fragment := $old$    admitted := otlet.admit_task_input(
      backfill_row.task_name,
      pending.subject_id,
      current_input,
      backfill_row.workload_revision_hash
    );$old$;
  new_fragment := $new$    admitted := otlet.admit_task_input_with_origin(
      backfill_row.task_name,
      pending.subject_id,
      current_input,
      backfill_row.workload_revision_hash,
      'backfill'
    );$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill origin rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_get_viewdef('otlet.production_policy_status'::regclass, true);
  old_fragment := $old$    failed_job_retention
   FROM otlet.production_policy p$old$;
  new_fragment := $new$    failed_job_retention,
    max_active_jobs_per_task,
    max_queued_input_bytes_per_task,
    max_queue_age
   FROM otlet.production_policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet production-policy status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.production_policy_status AS '
    || replace(definition, old_fragment, new_fragment);

  definition := pg_get_viewdef('otlet.runs'::regclass, true);
  old_fragment := $old$    accepted.finished_at AS receipt_finished_at
   FROM otlet.jobs j$old$;
  new_fragment := $new$    accepted.finished_at AS receipt_finished_at,
    j.job_origin
   FROM otlet.jobs j$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet run origin status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.runs AS '
    || replace(definition, old_fragment, new_fragment);

  definition := pg_get_viewdef(
    'otlet.inference_receipt_trace_status'::regclass,
    true
  );
  old_fragment := $old$    r.finished_at AS receipt_finished_at
   FROM otlet.inference_receipts r$old$;
  new_fragment := $new$    r.finished_at AS receipt_finished_at,
    job.job_origin
   FROM otlet.inference_receipts r$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet receipt origin status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.inference_receipt_trace_status AS '
    || replace(definition, old_fragment, new_fragment);

  definition := pg_get_viewdef('otlet.portable_receipt_status'::regclass, true);
  old_fragment := $old$    l.linked_at
   FROM otlet.portable_receipt_links l
     JOIN otlet.portable_claims c ON c.id = l.claim_id
     JOIN otlet.inference_receipts r ON r.id = l.receipt_id$old$;
  new_fragment := $new$    l.linked_at,
    job.job_origin
   FROM otlet.portable_receipt_links l
     JOIN otlet.portable_claims c ON c.id = l.claim_id
     JOIN otlet.inference_receipts r ON r.id = l.receipt_id
     JOIN otlet.jobs job ON job.id = c.job_id$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet portable receipt origin status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.portable_receipt_status AS '
    || replace(definition, old_fragment, new_fragment);

  definition := pg_get_viewdef('otlet.audit_receipt_export'::regclass, true);
  old_fragment := $old$    s.receipt_finished_at
   FROM otlet.inference_receipt_trace_status s$old$;
  new_fragment := $new$    s.receipt_finished_at,
    s.job_origin
   FROM otlet.inference_receipt_trace_status s$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet audit receipt origin rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.audit_receipt_export AS '
    || replace(definition, old_fragment, new_fragment);
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
  granted_role text;
BEGIN
  definition := pg_get_functiondef(
    'otlet.grant_auditor_access(regrole)'::regprocedure
  );
  old_fragment := $old$    'otlet.failure_taxonomy, '
    'otlet.failure_retry_status TO %I',$old$;
  new_fragment := $new$    'otlet.failure_taxonomy, '
    'otlet.failure_retry_status, '
    'otlet.task_queue_status, '
    'otlet.task_resource_status TO %I',$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet auditor workload status grant rewrite is incomplete';
  END IF;
  EXECUTE replace(definition, old_fragment, new_fragment);

  FOR granted_role IN
    SELECT role.rolname
    FROM pg_roles role
    JOIN LATERAL aclexplode(
      (SELECT relation.relacl
       FROM pg_class relation
       WHERE relation.oid = 'otlet.failure_retry_status'::regclass)
    ) privilege ON privilege.grantee = role.oid
    WHERE privilege.privilege_type = 'SELECT'
  LOOP
    EXECUTE format(
      'GRANT SELECT ON TABLE otlet.task_queue_status, '
        || 'otlet.task_resource_status TO %I',
      granted_role
    );
  END LOOP;
END;
$migration$;

REVOKE ALL ON TABLE otlet.task_queue_capacity FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_claim_capacity FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_queue_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_resource_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_job_origin_and_budget() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.admit_task_input_with_origin(
  text, text, jsonb, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.run_task_with_origin(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.run_task_subject_with_origin(
  text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.run_task_subjects_with_origin(
  text, text[], text, text
) FROM PUBLIC;
