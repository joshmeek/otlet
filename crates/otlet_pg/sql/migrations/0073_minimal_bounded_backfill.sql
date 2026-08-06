ALTER TABLE otlet.workload_revision_heads
ALTER COLUMN promoted_at SET DEFAULT clock_timestamp();

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.promote_workload_revision(text,text,text)'::regprocedure
  );
  IF position('promoted_at = now()' IN definition) > 0 THEN
    definition := pg_catalog.replace(
      definition,
      'promoted_at = now()',
      'promoted_at = clock_timestamp()'
    );
  ELSIF position('promoted_at = clock_timestamp()' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet workload promotion timestamp rewrite is incomplete';
  END IF;
  EXECUTE definition;
END;
$migration$;

CREATE TABLE otlet.task_backfills (
  id bigserial PRIMARY KEY,
  task_name text NOT NULL,
  workload_revision_hash text NOT NULL,
  control_state text NOT NULL DEFAULT 'running' CHECK (
    control_state IN ('running', 'paused', 'canceled', 'superseded')
  ),
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
  subject_limit integer NOT NULL CHECK (subject_limit >= 1),
  subject_count integer NOT NULL DEFAULT 0 CHECK (subject_count >= 0),
  subject_manifest_hash text NOT NULL CHECK (
    subject_manifest_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  page_size integer NOT NULL CHECK (page_size BETWEEN 1 AND 64),
  max_jobs_per_minute integer NOT NULL CHECK (max_jobs_per_minute >= 1),
  max_outstanding_jobs integer NOT NULL CHECK (max_outstanding_jobs >= 1),
  state_reason text CHECK (
    state_reason IS NULL OR octet_length(state_reason) BETWEEN 1 AND 4096
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE TABLE otlet.task_backfill_subjects (
  backfill_id bigint NOT NULL REFERENCES otlet.task_backfills(id),
  ordinal integer NOT NULL CHECK (ordinal >= 1),
  subject_id text NOT NULL,
  selected_source_hash text NOT NULL CHECK (
    selected_source_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  disposition text NOT NULL DEFAULT 'pending' CHECK (
    disposition IN (
      'pending',
      'submitted',
      'covered',
      'source_missing',
      'canceled',
      'superseded'
    )
  ),
  submitted_source_hash text CHECK (
    submitted_source_hash IS NULL
    OR submitted_source_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  covered_job_id bigint REFERENCES otlet.jobs(id) ON DELETE SET NULL,
  processed_at timestamptz,
  PRIMARY KEY (backfill_id, ordinal),
  UNIQUE (backfill_id, subject_id),
  CHECK (
    (
      disposition = 'pending'
      AND submitted_source_hash IS NULL
      AND covered_job_id IS NULL
      AND processed_at IS NULL
    ) OR (
      disposition = 'submitted'
      AND submitted_source_hash IS NOT NULL
      AND covered_job_id IS NULL
      AND processed_at IS NOT NULL
    ) OR (
      disposition = 'covered'
      AND submitted_source_hash IS NOT NULL
      AND processed_at IS NOT NULL
    ) OR (
      disposition IN ('source_missing', 'canceled', 'superseded')
      AND submitted_source_hash IS NULL
      AND covered_job_id IS NULL
      AND processed_at IS NOT NULL
    )
  )
);

CREATE INDEX task_backfill_subjects_pending_idx
ON otlet.task_backfill_subjects (backfill_id, ordinal)
WHERE disposition = 'pending';

ALTER TABLE otlet.jobs
ADD COLUMN backfill_id bigint,
ADD COLUMN backfill_ordinal integer,
ADD COLUMN backfill_deferred boolean NOT NULL DEFAULT false,
ADD COLUMN backfill_admitted_at timestamptz,
ADD CONSTRAINT jobs_backfill_lineage_shape CHECK (
  (backfill_id IS NULL) = (backfill_ordinal IS NULL)
  AND (backfill_id IS NULL) = (backfill_admitted_at IS NULL)
  AND (NOT backfill_deferred OR backfill_id IS NOT NULL)
),
ADD CONSTRAINT jobs_backfill_subject_fk FOREIGN KEY (
  backfill_id,
  backfill_ordinal
) REFERENCES otlet.task_backfill_subjects(backfill_id, ordinal);

CREATE UNIQUE INDEX jobs_backfill_subject_idx
ON otlet.jobs (backfill_id, backfill_ordinal)
WHERE backfill_id IS NOT NULL;

CREATE FUNCTION otlet.task_backfill_manifest_hash(requested_backfill_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT otlet.identity_hash(
    'task_backfill_manifest',
    jsonb_build_object(
      'task_name', backfill.task_name,
      'workload_revision_hash', backfill.workload_revision_hash,
      'subjects', COALESCE(subjects.manifest, '[]'::jsonb)
    )
  )
  FROM otlet.task_backfills backfill
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'ordinal', subject.ordinal,
        'subject_id', subject.subject_id,
        'selected_source_hash', subject.selected_source_hash
      )
      ORDER BY subject.ordinal
    ) AS manifest
    FROM otlet.task_backfill_subjects subject
    WHERE subject.backfill_id = backfill.id
  ) subjects ON true
  WHERE backfill.id = task_backfill_manifest_hash.requested_backfill_id;
$$;

CREATE FUNCTION otlet.task_backfill_input_contract(
  requested_task_name text,
  requested_workload_revision_hash text
) RETURNS TABLE (
  input_query text,
  revision_definition jsonb,
  model_name text
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source_kind text;
  semantic_join_index_name text;
BEGIN
  SELECT
    revision.definition,
    revision.definition #>> '{task,input_query}',
    revision.definition #>> '{models,direct,name}',
    revision.definition #>> '{source,kind}',
    revision.definition #>> '{source,semantic_join_index_name}'
  INTO
    task_backfill_input_contract.revision_definition,
    task_backfill_input_contract.input_query,
    task_backfill_input_contract.model_name,
    source_kind,
    semantic_join_index_name
  FROM otlet.tasks task
  JOIN otlet.workload_revision_heads head
    ON head.task_name = task.name
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE task.name = task_backfill_input_contract.requested_task_name
    AND task.lifecycle_state = 'active'
    AND head.active_workload_revision_hash =
      task_backfill_input_contract.requested_workload_revision_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision is not active for task %',
      task_backfill_input_contract.requested_task_name;
  END IF;
  IF task_backfill_input_contract.input_query IS NULL THEN
    RAISE EXCEPTION 'otlet task % has no input_query',
      task_backfill_input_contract.requested_task_name;
  END IF;
  IF source_kind = 'pair' THEN
    task_backfill_input_contract.input_query := format(
      'SELECT subject_id, input FROM otlet.semantic_join_refresh_inputs(%L, %L)',
      semantic_join_index_name,
      task_backfill_input_contract.requested_workload_revision_hash
    );
  END IF;

  PERFORM otlet.require_candidate_query_timeout(
    task_backfill_input_contract.requested_task_name
  );
  RETURN NEXT;
END;
$$;

CREATE FUNCTION otlet.promote_task_backfill_job(requested_job_id bigint)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  job_row otlet.jobs%ROWTYPE;
  changed integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  SELECT job.*
  INTO job_row
  FROM otlet.jobs job
  WHERE job.id = promote_task_backfill_job.requested_job_id
  FOR UPDATE;

  IF NOT FOUND
     OR NOT job_row.backfill_deferred
     OR job_row.status NOT IN ('queued', 'running') THEN
    RETURN false;
  END IF;

  UPDATE otlet.task_backfill_subjects subject
  SET disposition = 'covered',
      covered_job_id = job_row.id,
      processed_at = COALESCE(subject.processed_at, clock_timestamp())
  WHERE subject.backfill_id = job_row.backfill_id
    AND subject.ordinal = job_row.backfill_ordinal
    AND subject.disposition = 'submitted';
  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed <> 1 THEN
    RAISE EXCEPTION 'otlet backfill job % has invalid subject lineage', job_row.id;
  END IF;

  UPDATE otlet.jobs job
  SET backfill_deferred = false
  WHERE job.id = job_row.id;

  RETURN true;
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.validated_task_input_rows(text,integer,text,text,jsonb,boolean)'::regprocedure
  );
  old_fragment := $old$        active.id AS active_job_id,
        active.input AS active_input$old$;
  new_fragment := $new$        active.id AS active_job_id,
        active.input AS active_input,
        active.backfill_deferred AS active_backfill_deferred$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill input-row promotion rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      IF candidate.active_input IS DISTINCT FROM candidate.input THEN
        RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
          candidate.subject_id;
      END IF;$old$;
  new_fragment := $new$      IF candidate.active_input IS DISTINCT FROM candidate.input THEN
        RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
          candidate.subject_id;
      END IF;
      IF candidate.active_backfill_deferred THEN
        PERFORM otlet.promote_task_backfill_job(candidate.active_job_id);
      END IF;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill input-row collision rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  EXECUTE definition;

  definition := pg_catalog.pg_get_functiondef(
    'otlet.admit_task_input(text,text,jsonb,text)'::regprocedure
  );
  old_fragment := $old$  revision_hash text;
  existing_input jsonb;
  input_bytes bigint := octet_length(admit_task_input.input::text);$old$;
  new_fragment := $new$  revision_hash text;
  existing_job_id bigint;
  existing_backfill_deferred boolean;
  existing_input jsonb;
  input_bytes bigint := octet_length(admit_task_input.input::text);$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill admission declaration rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  SELECT active.input
  INTO existing_input
  FROM otlet.jobs active$old$;
  new_fragment := $new$  SELECT active.id, active.backfill_deferred, active.input
  INTO existing_job_id, existing_backfill_deferred, existing_input
  FROM otlet.jobs active$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill admission lookup rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    IF existing_input IS DISTINCT FROM admit_task_input.input THEN
      RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
        admit_task_input.subject_id;
    END IF;
    RETURN false;$old$;
  new_fragment := $new$    IF existing_input IS DISTINCT FROM admit_task_input.input THEN
      RAISE EXCEPTION 'otlet input relation conflicts with active input for subject %',
        admit_task_input.subject_id;
    END IF;
    IF existing_backfill_deferred THEN
      PERFORM otlet.promote_task_backfill_job(existing_job_id);
    END IF;
    RETURN false;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill admission collision rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  EXECUTE definition;
END;
$migration$;

CREATE FUNCTION otlet.create_task_backfill(
  requested_task_name text,
  expected_workload_revision_hash text,
  requested_max_subjects integer,
  requested_page_size integer DEFAULT 64,
  requested_max_jobs_per_minute integer DEFAULT 64,
  requested_max_outstanding_jobs integer DEFAULT 64
) RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  input_contract record;
  active_revision_hash text;
  created_backfill_id bigint;
  candidate_count integer;
BEGIN
  IF create_task_backfill.expected_workload_revision_hash IS NULL THEN
    RAISE EXCEPTION 'otlet backfill expected workload revision is required';
  END IF;
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';
  IF create_task_backfill.requested_max_subjects NOT BETWEEN 1 AND
     policy.max_admission_rows THEN
    RAISE EXCEPTION 'otlet backfill max subjects must be between 1 and %',
      policy.max_admission_rows;
  END IF;
  IF create_task_backfill.requested_page_size NOT BETWEEN 1 AND 64 THEN
    RAISE EXCEPTION 'otlet backfill page size must be between 1 and 64';
  END IF;
  IF policy.max_queued_jobs_per_model < 2
     OR create_task_backfill.requested_max_jobs_per_minute NOT BETWEEN 1 AND
       policy.max_queued_jobs_per_model - 1 THEN
    RAISE EXCEPTION 'otlet backfill jobs per minute must preserve one foreground queue slot';
  END IF;
  IF create_task_backfill.requested_max_outstanding_jobs NOT BETWEEN 1 AND
     policy.max_queued_jobs_per_model - 1 THEN
    RAISE EXCEPTION 'otlet backfill outstanding jobs must preserve one foreground queue slot';
  END IF;

  active_revision_hash := otlet.ensure_active_workload_revision(
    create_task_backfill.requested_task_name
  );
  IF active_revision_hash IS DISTINCT FROM
     create_task_backfill.expected_workload_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed before backfill creation for task %',
      create_task_backfill.requested_task_name;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM otlet.task_backfills existing
    WHERE existing.task_name = create_task_backfill.requested_task_name
      AND existing.workload_revision_hash = active_revision_hash
      AND (
        EXISTS (
          SELECT 1
          FROM otlet.task_backfill_subjects subject
          WHERE subject.backfill_id = existing.id
            AND subject.disposition = 'pending'
        ) OR EXISTS (
          SELECT 1
          FROM otlet.jobs job
          WHERE job.backfill_id = existing.id
            AND job.status IN ('queued', 'running', 'cancel_requested')
        ) OR EXISTS (
          SELECT 1
          FROM otlet.task_backfill_subjects subject
          JOIN otlet.jobs job ON job.id = subject.covered_job_id
          WHERE subject.backfill_id = existing.id
            AND job.status IN ('queued', 'running', 'cancel_requested')
        )
      )
  ) THEN
    RAISE EXCEPTION 'otlet task % already has an unfinished backfill for revision %',
      create_task_backfill.requested_task_name,
      active_revision_hash;
  END IF;
  SELECT *
  INTO STRICT input_contract
  FROM otlet.task_backfill_input_contract(
    create_task_backfill.requested_task_name,
    active_revision_hash
  );

  INSERT INTO otlet.task_backfills (
    task_name,
    workload_revision_hash,
    subject_limit,
    subject_manifest_hash,
    page_size,
    max_jobs_per_minute,
    max_outstanding_jobs
  ) VALUES (
    create_task_backfill.requested_task_name,
    active_revision_hash,
    create_task_backfill.requested_max_subjects,
    otlet.identity_hash(
      'task_backfill_manifest',
      jsonb_build_object(
        'task_name', create_task_backfill.requested_task_name,
        'workload_revision_hash', active_revision_hash,
        'subjects', '[]'::jsonb
      )
    ),
    create_task_backfill.requested_page_size,
    create_task_backfill.requested_max_jobs_per_minute,
    create_task_backfill.requested_max_outstanding_jobs
  )
  RETURNING id INTO created_backfill_id;

  INSERT INTO otlet.task_backfill_subjects (
    backfill_id,
    ordinal,
    subject_id,
    selected_source_hash
  )
  SELECT
    created_backfill_id,
    row_number() OVER (ORDER BY candidate.subject_id COLLATE "C")::integer,
    candidate.subject_id,
    otlet.semantic_source_hash(candidate.input)
  FROM otlet.validated_task_input_rows(
    input_contract.input_query,
    create_task_backfill.requested_max_subjects + 1,
    workload_definition => input_contract.revision_definition
  ) candidate
  ORDER BY candidate.subject_id COLLATE "C";
  GET DIAGNOSTICS candidate_count = ROW_COUNT;

  IF candidate_count > create_task_backfill.requested_max_subjects THEN
    RAISE EXCEPTION 'otlet backfill subject set exceeds requested maximum %',
      create_task_backfill.requested_max_subjects;
  END IF;

  UPDATE otlet.task_backfills backfill
  SET subject_count = candidate_count,
      subject_manifest_hash = otlet.task_backfill_manifest_hash(created_backfill_id),
      updated_at = clock_timestamp()
  WHERE backfill.id = created_backfill_id;

  RETURN created_backfill_id;
END;
$$;

CREATE FUNCTION otlet.task_backfill_admission_has_headroom(
  requested_model_name text,
  requested_input_bytes bigint
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  policy otlet.production_policy%ROWTYPE;
  model_queued_jobs bigint;
  model_queued_bytes bigint;
  total_queued_bytes bigint;
BEGIN
  SELECT * INTO STRICT policy
  FROM otlet.production_policy
  WHERE name = 'default';
  SELECT
    count(*) FILTER (WHERE COALESCE(
      job.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) = task_backfill_admission_has_headroom.requested_model_name),
    COALESCE(sum(octet_length(job.input::text)) FILTER (WHERE COALESCE(
      job.routed_model_name,
      revision.definition #>> '{models,direct,name}'
    ) = task_backfill_admission_has_headroom.requested_model_name), 0),
    COALESCE(sum(octet_length(job.input::text)), 0)
  INTO model_queued_jobs, model_queued_bytes, total_queued_bytes
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

  RETURN task_backfill_admission_has_headroom.requested_input_bytes <=
      policy.max_input_bytes_per_job
    AND model_queued_jobs < GREATEST(
      policy.max_queued_jobs_per_model - 1,
      0
    )
    AND model_queued_bytes +
      task_backfill_admission_has_headroom.requested_input_bytes <= GREATEST(
        policy.max_queued_input_bytes_per_model - LEAST(
          policy.max_input_bytes_per_job,
          policy.max_queued_input_bytes_per_model
        ),
        0
      )
    AND total_queued_bytes +
      task_backfill_admission_has_headroom.requested_input_bytes <= GREATEST(
        policy.max_queued_input_bytes_total - LEAST(
          policy.max_input_bytes_per_job,
          policy.max_queued_input_bytes_total
        ),
        0
      );
END;
$$;

CREATE FUNCTION otlet.close_task_backfill(
  requested_backfill_id bigint,
  requested_terminal_state text,
  requested_reason text
) RETURNS integer
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  backfill_row otlet.task_backfills%ROWTYPE;
  job_row record;
  canceled_jobs integer := 0;
BEGIN
  IF close_task_backfill.requested_terminal_state NOT IN ('canceled', 'superseded') THEN
    RAISE EXCEPTION 'otlet backfill terminal state must be canceled or superseded';
  END IF;
  IF close_task_backfill.requested_reason IS NOT NULL
     AND octet_length(close_task_backfill.requested_reason) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'otlet backfill state reason must be between 1 and 4096 bytes';
  END IF;

  SELECT backfill.*
  INTO backfill_row
  FROM otlet.task_backfills backfill
  WHERE backfill.id = close_task_backfill.requested_backfill_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet backfill % does not exist',
      close_task_backfill.requested_backfill_id;
  END IF;
  IF backfill_row.control_state IN ('canceled', 'superseded') THEN
    RETURN 0;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  UPDATE otlet.task_backfills backfill
  SET control_state = close_task_backfill.requested_terminal_state,
      generation = generation + 1,
      state_reason = close_task_backfill.requested_reason,
      updated_at = clock_timestamp()
  WHERE backfill.id = backfill_row.id;
  UPDATE otlet.task_backfill_subjects subject
  SET disposition = close_task_backfill.requested_terminal_state,
      processed_at = clock_timestamp()
  WHERE subject.backfill_id = backfill_row.id
    AND subject.disposition = 'pending';

  FOR job_row IN
    SELECT job.id
    FROM otlet.jobs job
    WHERE job.backfill_id = backfill_row.id
      AND job.backfill_deferred
      AND job.status IN ('queued', 'running', 'cancel_requested')
    ORDER BY job.id
    FOR UPDATE
  LOOP
    PERFORM 1
    FROM otlet.request_job_cancellation(
      job_row.id,
      COALESCE(
        close_task_backfill.requested_reason,
        'backfill ' || close_task_backfill.requested_terminal_state
      )
    );
    canceled_jobs := canceled_jobs + 1;
  END LOOP;

  RETURN canceled_jobs;
END;
$$;

CREATE FUNCTION otlet.set_task_backfill_state(
  requested_backfill_id bigint,
  requested_state text,
  requested_reason text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  backfill_row otlet.task_backfills%ROWTYPE;
  task_lifecycle_state text;
  task_revision_hash text;
BEGIN
  IF set_task_backfill_state.requested_state NOT IN ('running', 'paused', 'canceled') THEN
    RAISE EXCEPTION 'otlet backfill state must be running, paused, or canceled';
  END IF;
  IF set_task_backfill_state.requested_reason IS NOT NULL
     AND octet_length(set_task_backfill_state.requested_reason) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'otlet backfill state reason must be between 1 and 4096 bytes';
  END IF;

  SELECT backfill.*
  INTO backfill_row
  FROM otlet.task_backfills backfill
  WHERE backfill.id = set_task_backfill_state.requested_backfill_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet backfill % does not exist',
      set_task_backfill_state.requested_backfill_id;
  END IF;

  IF backfill_row.control_state IN ('canceled', 'superseded') THEN
    RETURN backfill_row.control_state;
  END IF;
  IF set_task_backfill_state.requested_state = 'canceled' THEN
    PERFORM otlet.close_task_backfill(
      backfill_row.id,
      'canceled',
      COALESCE(set_task_backfill_state.requested_reason, 'backfill canceled')
    );
    RETURN 'canceled';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'otlet_workload_revision:' || backfill_row.task_name,
      0
    )
  );
  IF set_task_backfill_state.requested_state = 'running' THEN
    SELECT
      task.lifecycle_state,
      CASE task.lifecycle_state
        WHEN 'active' THEN head.active_workload_revision_hash
        ELSE task.lifecycle_revision_hash
      END
    INTO task_lifecycle_state, task_revision_hash
    FROM otlet.tasks task
    LEFT JOIN otlet.workload_revision_heads head ON head.task_name = task.name
    WHERE task.name = backfill_row.task_name;
    IF task_lifecycle_state = 'paused'
       AND task_revision_hash = backfill_row.workload_revision_hash THEN
      RETURN 'task_paused';
    END IF;
    IF task_lifecycle_state IS DISTINCT FROM 'active'
       OR task_revision_hash IS DISTINCT FROM backfill_row.workload_revision_hash THEN
      PERFORM otlet.close_task_backfill(
        backfill_row.id,
        'superseded',
        'backfill workload revision is no longer current'
      );
      RETURN 'superseded';
    END IF;
  END IF;

  UPDATE otlet.task_backfills backfill
  SET control_state = set_task_backfill_state.requested_state,
      generation = CASE
        WHEN control_state IS DISTINCT FROM set_task_backfill_state.requested_state
          THEN generation + 1
        ELSE generation
      END,
      state_reason = set_task_backfill_state.requested_reason,
      updated_at = clock_timestamp()
  WHERE backfill.id = backfill_row.id;
  IF set_task_backfill_state.requested_state = 'running' THEN
    PERFORM otlet.wake_worker();
  END IF;
  RETURN set_task_backfill_state.requested_state;
END;
$$;

CREATE FUNCTION otlet.submit_task_backfill_page(
  requested_backfill_id bigint,
  expected_generation bigint
) RETURNS TABLE (
  submission_state text,
  current_generation bigint,
  processed_subjects integer,
  queued_jobs integer
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  backfill_row otlet.task_backfills%ROWTYPE;
  input_contract record;
  pending record;
  current_input jsonb;
  current_source_hash text;
  active_job otlet.jobs%ROWTYPE;
  admitted boolean;
  recent_jobs integer;
  outstanding_jobs integer;
  page_capacity integer;
  pending_subjects integer;
  task_lifecycle_state text;
  task_revision_hash text;
  page_ordinals integer[] := ARRAY[]::integer[];
  page_subject_ids text[] := ARRAY[]::text[];
  page_inputs jsonb[] := ARRAY[]::jsonb[];
  page_source_hashes text[] := ARRAY[]::text[];
BEGIN
  submit_task_backfill_page.processed_subjects := 0;
  submit_task_backfill_page.queued_jobs := 0;
  SELECT backfill.*
  INTO backfill_row
  FROM otlet.task_backfills backfill
  WHERE backfill.id = submit_task_backfill_page.requested_backfill_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet backfill % does not exist',
      submit_task_backfill_page.requested_backfill_id;
  END IF;
  submit_task_backfill_page.current_generation := backfill_row.generation;

  IF submit_task_backfill_page.expected_generation IS NULL
     OR submit_task_backfill_page.expected_generation IS DISTINCT FROM
       backfill_row.generation THEN
    submit_task_backfill_page.submission_state := 'stale_generation';
    RETURN NEXT;
    RETURN;
  END IF;
  IF backfill_row.control_state <> 'running' THEN
    submit_task_backfill_page.submission_state := backfill_row.control_state;
    RETURN NEXT;
    RETURN;
  END IF;
  IF NOT EXISTS (
       SELECT 1
       FROM otlet.task_backfill_subjects subject
       WHERE subject.backfill_id = backfill_row.id
         AND subject.disposition = 'pending'
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.jobs job
       WHERE job.backfill_id = backfill_row.id
         AND job.status IN ('queued', 'running', 'cancel_requested')
     )
     AND NOT EXISTS (
       SELECT 1
       FROM otlet.task_backfill_subjects subject
       JOIN otlet.jobs job ON job.id = subject.covered_job_id
       WHERE subject.backfill_id = backfill_row.id
         AND job.status IN ('queued', 'running', 'cancel_requested')
     ) THEN
    submit_task_backfill_page.submission_state := 'submission_complete';
    RETURN NEXT;
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'otlet_workload_revision:' || backfill_row.task_name,
      0
    )
  );
  SELECT
    task.lifecycle_state,
    CASE task.lifecycle_state
      WHEN 'active' THEN head.active_workload_revision_hash
      ELSE task.lifecycle_revision_hash
    END
  INTO task_lifecycle_state, task_revision_hash
  FROM otlet.tasks task
  LEFT JOIN otlet.workload_revision_heads head ON head.task_name = task.name
  WHERE task.name = backfill_row.task_name;
  IF task_lifecycle_state = 'paused'
     AND task_revision_hash = backfill_row.workload_revision_hash THEN
    submit_task_backfill_page.submission_state := 'task_paused';
    RETURN NEXT;
    RETURN;
  END IF;
  IF task_lifecycle_state IS DISTINCT FROM 'active'
     OR task_revision_hash IS DISTINCT FROM backfill_row.workload_revision_hash THEN
    PERFORM otlet.close_task_backfill(
      backfill_row.id,
      'superseded',
      'backfill workload revision is no longer current'
    );
    submit_task_backfill_page.submission_state := 'superseded';
    submit_task_backfill_page.current_generation := backfill_row.generation + 1;
    RETURN NEXT;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM otlet.task_backfill_subjects subject
    WHERE subject.backfill_id = backfill_row.id
      AND subject.disposition = 'pending'
  ) THEN
    submit_task_backfill_page.submission_state := 'draining';
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT *
  INTO STRICT input_contract
  FROM otlet.task_backfill_input_contract(
    backfill_row.task_name,
    backfill_row.workload_revision_hash
  );
  IF otlet.semantic_schema_drift_error(input_contract.revision_definition)
     IS NOT NULL THEN
    submit_task_backfill_page.submission_state := 'source_drift';
    RETURN NEXT;
    RETURN;
  END IF;
  IF input_contract.revision_definition #>> '{source,kind}' = 'pair' THEN
    FOR pending IN
      WITH page AS MATERIALIZED (
        SELECT subject.ordinal, subject.subject_id
        FROM otlet.task_backfill_subjects subject
        WHERE subject.backfill_id = backfill_row.id
          AND subject.disposition = 'pending'
        ORDER BY subject.ordinal
        LIMIT backfill_row.page_size
      ), current_inputs AS MATERIALIZED (
        SELECT candidate.subject_id, candidate.input
        FROM otlet.semantic_join_candidate_rows(
          input_contract.revision_definition #>>
            '{source,semantic_join_index_name}',
          backfill_row.workload_revision_hash,
          false
        ) candidate
      )
      SELECT page.ordinal, page.subject_id, current_inputs.input
      FROM page
      LEFT JOIN current_inputs ON current_inputs.subject_id = page.subject_id
      ORDER BY page.ordinal
    LOOP
      page_ordinals := array_append(page_ordinals, pending.ordinal);
      page_subject_ids := array_append(page_subject_ids, pending.subject_id);
      page_inputs := array_append(page_inputs, pending.input);
      page_source_hashes := array_append(
        page_source_hashes,
        CASE WHEN pending.input IS NULL THEN NULL
          ELSE otlet.semantic_source_hash(pending.input)
        END
      );
    END LOOP;
  ELSIF input_contract.revision_definition #>> '{source,kind}' = 'row' THEN
    FOR pending IN
      SELECT subject.ordinal, subject.subject_id
      FROM otlet.task_backfill_subjects subject
      WHERE subject.backfill_id = backfill_row.id
        AND subject.disposition = 'pending'
      ORDER BY subject.ordinal
      LIMIT backfill_row.page_size
    LOOP
      current_input := otlet.current_task_subject_input_snapshot(
        backfill_row.task_name,
        pending.subject_id,
        backfill_row.workload_revision_hash
      );
      page_ordinals := array_append(page_ordinals, pending.ordinal);
      page_subject_ids := array_append(page_subject_ids, pending.subject_id);
      page_inputs := array_append(page_inputs, current_input);
      page_source_hashes := array_append(
        page_source_hashes,
        CASE WHEN current_input IS NULL THEN NULL
          ELSE otlet.semantic_source_hash(current_input)
        END
      );
    END LOOP;
  ELSE
    SELECT
      array_agg(page.ordinal ORDER BY page.ordinal),
      array_agg(page.subject_id ORDER BY page.ordinal)
    INTO page_ordinals, page_subject_ids
    FROM (
      SELECT subject.ordinal, subject.subject_id
      FROM otlet.task_backfill_subjects subject
      WHERE subject.backfill_id = backfill_row.id
        AND subject.disposition = 'pending'
      ORDER BY subject.ordinal
      LIMIT backfill_row.page_size
    ) page;
    FOR pending IN
      WITH current_inputs AS MATERIALIZED (
        SELECT candidate.subject_id, candidate.input
        FROM otlet.validated_task_input_rows(
          format(
            'SELECT source.subject_id, source.input FROM (%s) source '
              || 'WHERE source.subject_id::text = ANY (%L::text[])',
            input_contract.input_query,
            page_subject_ids
          ),
          workload_definition => input_contract.revision_definition
        ) candidate
      )
      SELECT page.ordinal, page.subject_id, current_inputs.input
      FROM unnest(page_ordinals, page_subject_ids) page(ordinal, subject_id)
      LEFT JOIN current_inputs ON current_inputs.subject_id = page.subject_id
      ORDER BY page.ordinal
    LOOP
      page_inputs := array_append(page_inputs, pending.input);
      page_source_hashes := array_append(
        page_source_hashes,
        CASE WHEN pending.input IS NULL THEN NULL
          ELSE otlet.semantic_source_hash(pending.input)
        END
      );
    END LOOP;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('otlet_queue_admission'));
  SELECT
    count(*) FILTER (
      WHERE job.backfill_admitted_at >=
        clock_timestamp() - interval '1 minute'
    ),
    count(*) FILTER (
      WHERE job.backfill_deferred
        AND job.status IN ('queued', 'running', 'cancel_requested')
    )
  INTO recent_jobs, outstanding_jobs
  FROM otlet.jobs job
  WHERE job.backfill_id = backfill_row.id;

  IF recent_jobs >= backfill_row.max_jobs_per_minute THEN
    submit_task_backfill_page.submission_state := 'rate_limited';
    RETURN NEXT;
    RETURN;
  END IF;
  IF outstanding_jobs >= backfill_row.max_outstanding_jobs THEN
    submit_task_backfill_page.submission_state := 'outstanding_limited';
    RETURN NEXT;
    RETURN;
  END IF;
  page_capacity := LEAST(
    backfill_row.page_size,
    backfill_row.max_jobs_per_minute - recent_jobs,
    backfill_row.max_outstanding_jobs - outstanding_jobs
  );

  FOR pending IN
    SELECT
      backfill_row.id AS backfill_id,
      page.ordinal,
      page.subject_id,
      page.current_input,
      page.current_source_hash
    FROM unnest(
      page_ordinals,
      page_subject_ids,
      page_inputs,
      page_source_hashes
    ) AS page(ordinal, subject_id, current_input, current_source_hash)
    ORDER BY page.ordinal
    LIMIT page_capacity
  LOOP
    current_input := pending.current_input;
    current_source_hash := pending.current_source_hash;
    IF current_input IS NULL THEN
      UPDATE otlet.task_backfill_subjects subject
      SET disposition = 'source_missing',
          processed_at = clock_timestamp()
      WHERE subject.backfill_id = pending.backfill_id
        AND subject.ordinal = pending.ordinal
        AND subject.disposition = 'pending';
      submit_task_backfill_page.processed_subjects :=
        submit_task_backfill_page.processed_subjects + 1;
      CONTINUE;
    END IF;

    SELECT job.*
    INTO active_job
    FROM otlet.jobs job
    WHERE job.task_name = backfill_row.task_name
      AND job.workload_revision_hash = backfill_row.workload_revision_hash
      AND job.subject_id = pending.subject_id
      AND job.execution_mode = 'production'
      AND job.status IN ('queued', 'running', 'cancel_requested')
    FOR UPDATE;
    IF FOUND THEN
      IF active_job.input IS DISTINCT FROM current_input THEN
        submit_task_backfill_page.submission_state := 'source_conflict';
        EXIT;
      END IF;
      IF active_job.backfill_id = backfill_row.id THEN
        RAISE EXCEPTION 'otlet backfill subject % has pending owned job %',
          pending.subject_id,
          active_job.id;
      END IF;
      UPDATE otlet.task_backfill_subjects subject
      SET disposition = 'covered',
          submitted_source_hash = current_source_hash,
          covered_job_id = active_job.id,
          processed_at = clock_timestamp()
      WHERE subject.backfill_id = pending.backfill_id
        AND subject.ordinal = pending.ordinal
        AND subject.disposition = 'pending';
      submit_task_backfill_page.processed_subjects :=
        submit_task_backfill_page.processed_subjects + 1;
      CONTINUE;
    END IF;

    IF NOT otlet.task_backfill_admission_has_headroom(
      input_contract.model_name,
      octet_length(current_input::text)
    ) THEN
      submit_task_backfill_page.submission_state := 'foreground_reserved';
      EXIT;
    END IF;
    admitted := otlet.admit_task_input(
      backfill_row.task_name,
      pending.subject_id,
      current_input,
      backfill_row.workload_revision_hash
    );
    IF NOT admitted THEN
      submit_task_backfill_page.submission_state := 'admission_limited';
      EXIT;
    END IF;

    SELECT job.*
    INTO STRICT active_job
    FROM otlet.jobs job
    WHERE job.task_name = backfill_row.task_name
      AND job.workload_revision_hash = backfill_row.workload_revision_hash
      AND job.subject_id = pending.subject_id
      AND job.execution_mode = 'production'
      AND job.status = 'queued'
    FOR UPDATE;
    UPDATE otlet.jobs job
    SET backfill_id = backfill_row.id,
        backfill_ordinal = pending.ordinal,
        backfill_deferred = true,
        backfill_admitted_at = clock_timestamp()
    WHERE job.id = active_job.id;
    UPDATE otlet.task_backfill_subjects subject
    SET disposition = 'submitted',
        submitted_source_hash = current_source_hash,
        processed_at = clock_timestamp()
    WHERE subject.backfill_id = pending.backfill_id
      AND subject.ordinal = pending.ordinal
      AND subject.disposition = 'pending';
    submit_task_backfill_page.processed_subjects :=
      submit_task_backfill_page.processed_subjects + 1;
    submit_task_backfill_page.queued_jobs :=
      submit_task_backfill_page.queued_jobs + 1;
  END LOOP;

  IF submit_task_backfill_page.processed_subjects > 0 THEN
    UPDATE otlet.task_backfills backfill
    SET generation = generation + 1,
        updated_at = clock_timestamp()
    WHERE backfill.id = backfill_row.id
    RETURNING generation INTO submit_task_backfill_page.current_generation;
  END IF;
  IF submit_task_backfill_page.queued_jobs > 0 THEN
    PERFORM otlet.wake_worker();
  END IF;
  SELECT count(*)
  INTO pending_subjects
  FROM otlet.task_backfill_subjects subject
  WHERE subject.backfill_id = backfill_row.id
    AND subject.disposition = 'pending';
  IF submit_task_backfill_page.submission_state IS NULL THEN
    submit_task_backfill_page.submission_state := CASE
      WHEN pending_subjects = 0 THEN 'submission_complete'
      WHEN submit_task_backfill_page.processed_subjects > 0 THEN 'submitted'
      ELSE 'complete'
    END;
  END IF;
  RETURN NEXT;
END;
$$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.seed_watch_time_reconciliation()'::regprocedure
  );
  old_fragment := $old$        AND (
          job.status IN ('queued', 'running', 'cancel_requested')
          OR job.created_at >= freshness.refresh_due_at
        )$old$;
  new_fragment := $new$        AND (
          (
            job.status IN ('queued', 'running', 'cancel_requested')
            AND NOT job.backfill_deferred
          )
          OR (
            job.status NOT IN ('queued', 'running', 'cancel_requested')
            AND job.created_at >= freshness.refresh_due_at
          )
        )$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill time-reconciliation rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  EXECUTE definition;

  definition := pg_catalog.pg_get_functiondef(
    'otlet.reconcile_watch_subject(text,text,boolean)'::regprocedure
  );
  old_fragment := $old$  policy_attempt_limit integer;
BEGIN$old$;
  new_fragment := $new$  policy_attempt_limit integer;
  active_backfill_job_id bigint;
BEGIN$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill reconciliation declaration rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  IF pending.reconciliation_reason = 'time_refresh'
     AND EXISTS (
       SELECT 1
       FROM otlet.jobs job$old$;
  new_fragment := $new$  SELECT min(job.id)
  INTO active_backfill_job_id
  FROM otlet.jobs job
  WHERE job.task_name = watch_row.task_name
    AND job.workload_revision_hash = active_revision_hash
    AND job.subject_id = pending.subject_id
    AND job.execution_mode = 'production'
    AND job.status IN ('queued', 'running')
    AND job.backfill_deferred
    AND otlet.semantic_source_hash(job.input) = current_identity;
  IF active_backfill_job_id IS NOT NULL THEN
    PERFORM otlet.promote_task_backfill_job(active_backfill_job_id);
  END IF;

  IF pending.reconciliation_reason = 'time_refresh'
     AND EXISTS (
       SELECT 1
       FROM otlet.jobs job$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill reconciliation promotion rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$job.status IN ('queued', 'running', 'cancel_requested')$old$;
  new_fragment := $new$(
             job.status IN ('queued', 'running')
             OR (
               job.status = 'cancel_requested'
               AND NOT job.backfill_deferred
             )
           )$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill reconciliation cancellation rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  EXECUTE definition;
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  old_fragment text;
  new_fragment text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.claim_jobs(text,integer,jsonb)'::regprocedure
  );

  old_fragment := $old$    ORDER BY j.created_at, j.id
    FOR UPDATE OF j SKIP LOCKED$old$;
  new_fragment := $new$    ORDER BY
      CASE WHEN j.backfill_deferred THEN 1 ELSE 0 END,
      j.created_at,
      j.id
    FOR UPDATE OF j SKIP LOCKED$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill invalid-input claim order rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      capacity.available_active_job_slots,
      min(CASE WHEN job.status IN ('running', 'cancel_requested') AND (job.leased_until IS NULL OR job.leased_until < now()) THEN 0 ELSE 1 END) AS retry_rank,$old$;
  new_fragment := $new$      capacity.available_active_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,
      min(CASE WHEN job.status IN ('running', 'cancel_requested') AND (job.leased_until IS NULL OR job.leased_until < now()) THEN 0 ELSE 1 END) AS retry_rank,$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill eligible-task rank rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      job.definition #>> '{runtime,lease_ms}',
      capacity.available_active_job_slots
  ),$old$;
  new_fragment := $new$      job.definition #>> '{runtime,lease_ms}',
      capacity.available_active_job_slots,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END
  ),$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill eligible-task grouping rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  selected_task AS (
    SELECT e.*
    FROM eligible_tasks e
    CROSS JOIN policy p
    ORDER BY
      CASE$old$;
  new_fragment := $new$  selected_task AS (
    SELECT e.*
    FROM eligible_tasks e
    CROSS JOIN policy p
    ORDER BY
      e.backfill_rank,
      CASE$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill selected-task rank rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      row_number() OVER (
        ORDER BY
          CASE$old$;
  new_fragment := $new$      row_number() OVER (
        ORDER BY
          e.backfill_rank,
          CASE$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill same-model task rank rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$     AND f.lease_ms = e.lease_ms
    CROSS JOIN policy p$old$;
  new_fragment := $new$     AND f.lease_ms = e.lease_ms
     AND f.backfill_rank = e.backfill_rank
    CROSS JOIN policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill batch-class isolation rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      f.task_rank,
      row_number() OVER (
        PARTITION BY job.task_name
        ORDER BY
          CASE WHEN job.status$old$;
  new_fragment := $new$      f.task_rank,
      CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END AS backfill_rank,
      row_number() OVER (
        PARTITION BY job.task_name
        ORDER BY
          CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END,
          CASE WHEN job.status$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill per-task job rank rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$     AND f.artifact_path IS NOT DISTINCT FROM job.selected_model ->> 'artifact_path'
    CROSS JOIN policy p$old$;
  new_fragment := $new$     AND f.artifact_path IS NOT DISTINCT FROM job.selected_model ->> 'artifact_path'
     AND f.backfill_rank = CASE WHEN job.backfill_deferred THEN 1 ELSE 0 END
    CROSS JOIN policy p$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill ranked-candidate isolation rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      candidate.task_rank,
      candidate.task_job_rank
    FROM otlet.jobs j$old$;
  new_fragment := $new$      candidate.task_rank,
      candidate.task_job_rank,
      candidate.backfill_rank
    FROM otlet.jobs j$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill claimable rank projection rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$    ORDER BY
      candidate.task_job_rank,
      candidate.task_rank
    FOR UPDATE OF j SKIP LOCKED$old$;
  new_fragment := $new$    ORDER BY
      candidate.backfill_rank,
      candidate.task_job_rank,
      candidate.task_rank
    FOR UPDATE OF j SKIP LOCKED$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill final claim order rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$      SELECT LEAST(p.batch_size::bigint, task.available_active_job_slots)
      FROM policy p
      CROSS JOIN selected_task task$old$;
  new_fragment := $new$      SELECT LEAST(
        p.batch_size::bigint,
        task.available_active_job_slots,
        CASE WHEN task.backfill_rank = 1 THEN 1::bigint
          ELSE p.batch_size::bigint
        END
      )
      FROM policy p
      CROSS JOIN selected_task task$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill claim quantum rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);

  old_fragment := $old$  ORDER BY claimable.task_rank, claimable.task_job_rank;$old$;
  new_fragment := $new$  ORDER BY
    claimable.backfill_rank,
    claimable.task_rank,
    claimable.task_job_rank;$new$;
  IF position(old_fragment IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill claimed-row order rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(definition, old_fragment, new_fragment);
  EXECUTE definition;
END;
$migration$;

CREATE VIEW otlet.task_backfill_status AS
WITH subject_counts AS (
  SELECT
    subject.backfill_id,
    count(*)::bigint AS subjects,
    count(*) FILTER (WHERE subject.disposition = 'pending')::bigint
      AS pending_subjects,
    count(*) FILTER (WHERE subject.disposition = 'submitted')::bigint
      AS submitted_subjects,
    count(*) FILTER (WHERE subject.disposition = 'covered')::bigint
      AS covered_subjects,
    count(*) FILTER (WHERE subject.disposition = 'source_missing')::bigint
      AS source_missing_subjects,
    count(*) FILTER (WHERE subject.disposition = 'canceled')::bigint
      AS canceled_subjects,
    count(*) FILTER (WHERE subject.disposition = 'superseded')::bigint
      AS superseded_subjects,
    count(*) FILTER (
      WHERE subject.submitted_source_hash IS DISTINCT FROM
        subject.selected_source_hash
        AND subject.submitted_source_hash IS NOT NULL
    )::bigint AS changed_source_subjects,
    min(subject.ordinal) FILTER (WHERE subject.disposition = 'pending')
      AS next_ordinal
  FROM otlet.task_backfill_subjects subject
  GROUP BY subject.backfill_id
), job_links AS (
  SELECT job.backfill_id, job.id AS job_id
  FROM otlet.jobs job
  WHERE job.backfill_id IS NOT NULL

  UNION

  SELECT subject.backfill_id, subject.covered_job_id
  FROM otlet.task_backfill_subjects subject
  WHERE subject.covered_job_id IS NOT NULL
), job_counts AS (
  SELECT
    link.backfill_id,
    count(*)::bigint AS jobs,
    count(*) FILTER (WHERE job.status = 'queued')::bigint AS queued_jobs,
    count(*) FILTER (WHERE job.status = 'running')::bigint AS running_jobs,
    count(*) FILTER (WHERE job.status = 'cancel_requested')::bigint
      AS cancel_requested_jobs,
    count(*) FILTER (WHERE job.status = 'complete')::bigint AS complete_jobs,
    count(*) FILTER (WHERE job.status = 'failed')::bigint AS failed_jobs,
    count(*) FILTER (WHERE job.status = 'canceled')::bigint AS canceled_jobs,
    count(*) FILTER (
      WHERE job.status IN ('queued', 'running', 'cancel_requested')
    )::bigint AS outstanding_jobs,
    count(*) FILTER (
      WHERE job.backfill_deferred
        AND job.status IN ('queued', 'running', 'cancel_requested')
    )::bigint AS deferred_outstanding_jobs
  FROM job_links link
  JOIN otlet.jobs job ON job.id = link.job_id
  GROUP BY link.backfill_id
), rate_counts AS (
  SELECT
    job.backfill_id,
    count(*) FILTER (
      WHERE job.backfill_admitted_at >=
        statement_timestamp() - interval '1 minute'
    )::bigint AS jobs_in_rate_window
  FROM otlet.jobs job
  WHERE job.backfill_id IS NOT NULL
  GROUP BY job.backfill_id
)
SELECT
  backfill.id AS backfill_id,
  backfill.task_name,
  backfill.workload_revision_hash,
  CASE
    WHEN backfill.control_state IN ('canceled', 'superseded', 'paused')
      THEN backfill.control_state
    WHEN COALESCE(subjects.pending_subjects, 0) = 0
      AND COALESCE(jobs.outstanding_jobs, 0) = 0 THEN 'complete'
    WHEN task.lifecycle_state = 'paused'
      AND task.lifecycle_revision_hash = backfill.workload_revision_hash
      THEN 'task_paused'
    WHEN task.lifecycle_state IS DISTINCT FROM 'active'
      OR head.active_workload_revision_hash IS DISTINCT FROM
      backfill.workload_revision_hash THEN 'revision_changed'
    WHEN COALESCE(subjects.pending_subjects, 0) = 0 THEN 'draining'
    ELSE 'running'
  END AS state,
  backfill.control_state,
  backfill.generation,
  backfill.subject_limit,
  backfill.subject_count,
  backfill.subject_manifest_hash,
  backfill.page_size,
  backfill.max_jobs_per_minute,
  backfill.max_outstanding_jobs,
  COALESCE(subjects.subjects, 0) AS subjects,
  backfill.subject_count - COALESCE(subjects.pending_subjects, 0)
    AS processed_subjects,
  COALESCE(subjects.pending_subjects, 0) AS pending_subjects,
  COALESCE(subjects.submitted_subjects, 0) AS submitted_subjects,
  COALESCE(subjects.covered_subjects, 0) AS covered_subjects,
  COALESCE(subjects.source_missing_subjects, 0) AS source_missing_subjects,
  COALESCE(subjects.canceled_subjects, 0) AS canceled_subjects,
  COALESCE(subjects.superseded_subjects, 0) AS superseded_subjects,
  COALESCE(subjects.changed_source_subjects, 0) AS changed_source_subjects,
  subjects.next_ordinal,
  COALESCE(jobs.jobs, 0) AS jobs,
  COALESCE(jobs.queued_jobs, 0) AS queued_jobs,
  COALESCE(jobs.running_jobs, 0) AS running_jobs,
  COALESCE(jobs.cancel_requested_jobs, 0) AS cancel_requested_jobs,
  COALESCE(jobs.complete_jobs, 0) AS complete_jobs,
  COALESCE(jobs.failed_jobs, 0) AS failed_jobs,
  COALESCE(jobs.canceled_jobs, 0) AS canceled_jobs_count,
  COALESCE(jobs.outstanding_jobs, 0) AS outstanding_jobs,
  COALESCE(jobs.deferred_outstanding_jobs, 0) AS deferred_outstanding_jobs,
  COALESCE(rates.jobs_in_rate_window, 0) AS jobs_in_rate_window,
  GREATEST(
    backfill.max_jobs_per_minute - COALESCE(rates.jobs_in_rate_window, 0),
    0
  ) AS rate_remaining,
  COALESCE(
    CASE task.lifecycle_state
      WHEN 'active' THEN head.active_workload_revision_hash =
        backfill.workload_revision_hash
      WHEN 'paused' THEN task.lifecycle_revision_hash =
        backfill.workload_revision_hash
      ELSE false
    END,
    false
  ) AS revision_current,
  backfill.state_reason,
  backfill.created_at,
  backfill.updated_at
FROM otlet.task_backfills backfill
JOIN otlet.tasks task ON task.name = backfill.task_name
LEFT JOIN otlet.workload_revision_heads head
  ON head.task_name = backfill.task_name
LEFT JOIN subject_counts subjects ON subjects.backfill_id = backfill.id
LEFT JOIN job_counts jobs ON jobs.backfill_id = backfill.id
LEFT JOIN rate_counts rates ON rates.backfill_id = backfill.id;

CREATE FUNCTION otlet.verify_task_backfill_invariants()
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    'task_backfill_manifest_matches'::text,
    'task_backfill'::text,
    backfill.id::text,
    jsonb_build_object(
      'stored_subject_count', backfill.subject_count,
      'actual_subject_count', count(subject.*),
      'stored_manifest_hash', backfill.subject_manifest_hash,
      'actual_manifest_hash', otlet.task_backfill_manifest_hash(backfill.id)
    )
  FROM otlet.task_backfills backfill
  LEFT JOIN otlet.task_backfill_subjects subject
    ON subject.backfill_id = backfill.id
  GROUP BY backfill.id
  HAVING backfill.subject_count IS DISTINCT FROM count(subject.*)
     OR backfill.subject_manifest_hash IS DISTINCT FROM
       otlet.task_backfill_manifest_hash(backfill.id)

  UNION ALL

  SELECT
    'task_backfill_job_matches_subject'::text,
    'job'::text,
    job.id::text,
    jsonb_build_object(
      'backfill_id', job.backfill_id,
      'backfill_ordinal', job.backfill_ordinal,
      'job_task_name', job.task_name,
      'backfill_task_name', backfill.task_name,
      'job_subject_id', job.subject_id,
      'backfill_subject_id', subject.subject_id,
      'job_source_hash', otlet.semantic_source_hash(job.input),
      'submitted_source_hash', subject.submitted_source_hash,
      'disposition', subject.disposition,
      'backfill_deferred', job.backfill_deferred,
      'execution_mode', job.execution_mode
    )
  FROM otlet.jobs job
  JOIN otlet.task_backfills backfill ON backfill.id = job.backfill_id
  JOIN otlet.task_backfill_subjects subject
    ON subject.backfill_id = job.backfill_id
   AND subject.ordinal = job.backfill_ordinal
  WHERE job.backfill_id IS NOT NULL
    AND (
      job.task_name IS DISTINCT FROM backfill.task_name
      OR job.workload_revision_hash IS DISTINCT FROM
        backfill.workload_revision_hash
      OR job.subject_id IS DISTINCT FROM subject.subject_id
      OR otlet.semantic_source_hash(job.input) IS DISTINCT FROM
        subject.submitted_source_hash
      OR NOT (
        (
          job.backfill_deferred
          AND subject.disposition = 'submitted'
          AND subject.covered_job_id IS NULL
        ) OR (
          NOT job.backfill_deferred
          AND subject.disposition = 'covered'
          AND subject.covered_job_id = job.id
        )
      )
      OR job.execution_mode IS DISTINCT FROM 'production'
    )

  UNION ALL

  SELECT
    'task_backfill_covered_job_matches_subject'::text,
    'task_backfill_subject'::text,
    subject.backfill_id::text || ':' || subject.ordinal::text,
    jsonb_build_object(
      'covered_job_id', job.id,
      'job_task_name', job.task_name,
      'backfill_task_name', backfill.task_name,
      'job_workload_revision_hash', job.workload_revision_hash,
      'backfill_workload_revision_hash', backfill.workload_revision_hash,
      'job_subject_id', job.subject_id,
      'backfill_subject_id', subject.subject_id,
      'job_source_hash', otlet.semantic_source_hash(job.input),
      'submitted_source_hash', subject.submitted_source_hash,
      'backfill_deferred', job.backfill_deferred,
      'execution_mode', job.execution_mode
    )
  FROM otlet.task_backfill_subjects subject
  JOIN otlet.task_backfills backfill ON backfill.id = subject.backfill_id
  JOIN otlet.jobs job ON job.id = subject.covered_job_id
  WHERE job.task_name IS DISTINCT FROM backfill.task_name
     OR job.workload_revision_hash IS DISTINCT FROM
       backfill.workload_revision_hash
     OR job.subject_id IS DISTINCT FROM subject.subject_id
     OR otlet.semantic_source_hash(job.input) IS DISTINCT FROM
       subject.submitted_source_hash
     OR job.backfill_deferred
     OR job.execution_mode IS DISTINCT FROM 'production'

  UNION ALL

  SELECT
    'task_revision_has_one_unfinished_backfill'::text,
    'workload_revision'::text,
    backfill.task_name || ':' || backfill.workload_revision_hash,
    jsonb_build_object(
      'backfill_ids', jsonb_agg(backfill.id ORDER BY backfill.id),
      'unfinished_backfills', count(*)
    )
  FROM otlet.task_backfills backfill
  WHERE EXISTS (
      SELECT 1
      FROM otlet.task_backfill_subjects subject
      WHERE subject.backfill_id = backfill.id
        AND subject.disposition = 'pending'
    ) OR EXISTS (
      SELECT 1
      FROM otlet.jobs job
      WHERE job.backfill_id = backfill.id
        AND job.status IN ('queued', 'running', 'cancel_requested')
    ) OR EXISTS (
      SELECT 1
      FROM otlet.task_backfill_subjects subject
      JOIN otlet.jobs job ON job.id = subject.covered_job_id
      WHERE subject.backfill_id = backfill.id
        AND job.status IN ('queued', 'running', 'cancel_requested')
    )
  GROUP BY backfill.task_name, backfill.workload_revision_hash
  HAVING count(*) > 1

  UNION ALL

  SELECT
    'closed_task_backfill_has_no_open_admission'::text,
    'task_backfill'::text,
    backfill.id::text,
    jsonb_build_object(
      'control_state', backfill.control_state,
      'pending_subjects', count(subject.*) FILTER (
        WHERE subject.disposition = 'pending'
      ),
      'queued_jobs', count(job.*) FILTER (
        WHERE job.backfill_deferred AND job.status = 'queued'
      ),
      'running_jobs', count(job.*) FILTER (
        WHERE job.backfill_deferred AND job.status = 'running'
      )
    )
  FROM otlet.task_backfills backfill
  LEFT JOIN otlet.task_backfill_subjects subject
    ON subject.backfill_id = backfill.id
  LEFT JOIN otlet.jobs job ON job.backfill_id = backfill.id
  WHERE backfill.control_state IN ('canceled', 'superseded')
  GROUP BY backfill.id
  HAVING count(subject.*) FILTER (WHERE subject.disposition = 'pending') > 0
      OR count(job.*) FILTER (
        WHERE job.backfill_deferred AND job.status IN ('queued', 'running')
      ) > 0;
$$;

ALTER FUNCTION otlet.verify_invariants(integer)
RENAME TO verify_invariants_before_task_backfill;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_functiondef(
    'otlet.verify_invariants_before_task_backfill(integer)'::regprocedure
  );
  IF position('verify_invariants.sample_limit' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet backfill invariant wrapper rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    'verify_invariants.sample_limit',
    'verify_invariants_before_task_backfill.sample_limit'
  );
  EXECUTE definition;
END;
$migration$;

CREATE FUNCTION otlet.verify_invariants(sample_limit integer DEFAULT NULL)
RETURNS TABLE (
  invariant_name text,
  object_type text,
  object_id text,
  detail jsonb
)
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_invariants_before_task_backfill(
    verify_invariants.sample_limit
  ) invariant;

  RETURN QUERY
  SELECT invariant.*
  FROM otlet.verify_task_backfill_invariants() invariant;
END;
$$;

REVOKE ALL ON TABLE otlet.task_backfills FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_backfill_subjects FROM PUBLIC;
REVOKE ALL ON TABLE otlet.task_backfill_status FROM PUBLIC;
REVOKE ALL ON SEQUENCE otlet.task_backfills_id_seq FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.task_backfill_manifest_hash(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.task_backfill_input_contract(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.promote_task_backfill_job(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.create_task_backfill(text,text,integer,integer,integer,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.task_backfill_admission_has_headroom(text,bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.close_task_backfill(bigint,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.set_task_backfill_state(bigint,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.submit_task_backfill_page(bigint,bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_task_backfill_invariants() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants_before_task_backfill(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.verify_invariants(integer) FROM PUBLIC;
