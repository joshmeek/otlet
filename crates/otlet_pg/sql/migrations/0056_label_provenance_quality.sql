ALTER TABLE otlet.eval_labels
ADD COLUMN task_name text NOT NULL REFERENCES otlet.tasks(name),
ADD COLUMN workload_revision_hash text NOT NULL,
ADD COLUMN content_hash text NOT NULL,
ADD CONSTRAINT eval_labels_content_hash_check CHECK (
  content_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
),
ADD COLUMN label_revision bigint NOT NULL,
ADD CONSTRAINT eval_labels_label_revision_check CHECK (label_revision > 0),
ADD COLUMN authenticated_role_oid oid NOT NULL,
ADD COLUMN authenticated_role_name text NOT NULL,
ADD CONSTRAINT eval_labels_authenticated_role_name_check CHECK (
  NULLIF(btrim(authenticated_role_name), '') IS NOT NULL
),
ADD COLUMN active_role_oid oid NOT NULL,
ADD COLUMN active_role_name text NOT NULL,
ADD CONSTRAINT eval_labels_active_role_name_check CHECK (
  NULLIF(btrim(active_role_name), '') IS NOT NULL
),
ADD COLUMN adjudication_state text NOT NULL DEFAULT 'pending',
ADD CONSTRAINT eval_labels_adjudication_state_check CHECK (
  adjudication_state IN ('pending', 'accepted', 'rejected')
),
ADD COLUMN label_confidence numeric,
ADD COLUMN supersedes_label_id bigint,
ADD CONSTRAINT eval_labels_supersedes_label_check CHECK (
  supersedes_label_id IS NULL OR supersedes_label_id > 0
),
ADD COLUMN adjudication_reason text,
ADD CONSTRAINT eval_labels_adjudication_reason_check CHECK (
  adjudication_reason IS NULL OR (
    NULLIF(btrim(adjudication_reason), '') IS NOT NULL
    AND octet_length(adjudication_reason) <= 4096
  )
),
ADD COLUMN adjudicated_authenticated_role_oid oid,
ADD COLUMN adjudicated_authenticated_role_name text,
ADD COLUMN adjudicated_active_role_oid oid,
ADD COLUMN adjudicated_active_role_name text,
ADD COLUMN adjudicated_at timestamptz,
ADD CONSTRAINT eval_labels_workload_revision_fkey
  FOREIGN KEY (task_name, workload_revision_hash)
  REFERENCES otlet.workload_revisions(task_name, workload_revision_hash),
ADD CONSTRAINT eval_labels_adjudication_fields_check CHECK (
  (adjudication_state = 'pending'
    AND label_confidence IS NULL
    AND supersedes_label_id IS NULL
    AND adjudication_reason IS NULL
    AND adjudicated_authenticated_role_oid IS NULL
    AND adjudicated_authenticated_role_name IS NULL
    AND adjudicated_active_role_oid IS NULL
    AND adjudicated_active_role_name IS NULL
    AND adjudicated_at IS NULL)
  OR
  (adjudication_state IN ('accepted', 'rejected')
    AND label_confidence IS NOT NULL
    AND label_confidence <> 'NaN'::numeric
    AND label_confidence BETWEEN 0 AND 1
    AND adjudication_reason IS NOT NULL
    AND adjudicated_authenticated_role_oid IS NOT NULL
    AND NULLIF(btrim(adjudicated_authenticated_role_name), '') IS NOT NULL
    AND adjudicated_active_role_oid IS NOT NULL
    AND NULLIF(btrim(adjudicated_active_role_name), '') IS NOT NULL
    AND adjudicated_at IS NOT NULL)
),
ADD CONSTRAINT eval_labels_rejected_supersession_check CHECK (
  adjudication_state = 'accepted' OR supersedes_label_id IS NULL
),
ADD CONSTRAINT eval_labels_supersedes_self_check
  CHECK (supersedes_label_id IS DISTINCT FROM id),
ADD CONSTRAINT eval_labels_supersedes_label_fkey
  FOREIGN KEY (supersedes_label_id) REFERENCES otlet.eval_labels(id);

ALTER TABLE otlet.eval_labels
ALTER COLUMN created_at SET DEFAULT clock_timestamp();

ALTER TABLE otlet.eval_labels
ALTER COLUMN source_hash SET NOT NULL;

CREATE TABLE otlet.eval_label_series_revisions (
  task_name text NOT NULL REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  source_table text,
  subject_id text NOT NULL,
  last_revision bigint NOT NULL CHECK (last_revision > 0),
  CONSTRAINT eval_label_series_revisions_key
    UNIQUE NULLS NOT DISTINCT (task_name, source_table, subject_id)
);

CREATE UNIQUE INDEX eval_labels_series_revision_idx
ON otlet.eval_labels (
  task_name,
  source_table,
  subject_id,
  label_revision
) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX eval_labels_supersedes_idx
ON otlet.eval_labels (supersedes_label_id)
WHERE supersedes_label_id IS NOT NULL;

CREATE INDEX eval_labels_quality_idx
ON otlet.eval_labels (
  task_name,
  workload_revision_hash,
  source_table,
  subject_id,
  source_hash
);

CREATE FUNCTION otlet.current_task_subject_input_snapshot(
  task_name text,
  subject_id text,
  workload_revision_hash text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  revision_definition jsonb;
  resolved_revision_hash text;
  source_kind text;
  current_input_query text;
  current_input jsonb;
  input_columns text[];
BEGIN
  IF current_task_subject_input_snapshot.workload_revision_hash IS NULL THEN
    SELECT head.active_workload_revision_hash, revision.definition
    INTO resolved_revision_hash, revision_definition
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    WHERE head.task_name = current_task_subject_input_snapshot.task_name;
  ELSE
    SELECT revision.workload_revision_hash, revision.definition
    INTO resolved_revision_hash, revision_definition
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = current_task_subject_input_snapshot.task_name
      AND revision.workload_revision_hash =
        current_task_subject_input_snapshot.workload_revision_hash;
  END IF;

  IF revision_definition IS NULL THEN
    RETURN NULL;
  END IF;

  source_kind := revision_definition #>> '{source,kind}';
  IF source_kind = 'pair' THEN
    RETURN otlet.task_subject_input(
      format(
        'SELECT subject_id, input FROM otlet.semantic_join_candidate_rows(%L, %L, false)',
        revision_definition #>> '{source,semantic_join_index_name}',
        resolved_revision_hash
      ),
      current_task_subject_input_snapshot.subject_id
    );
  END IF;

  PERFORM otlet.require_workload_source_contract(
    current_task_subject_input_snapshot.task_name,
    resolved_revision_hash,
    false
  );
  IF otlet.semantic_schema_drift_error(revision_definition) IS NOT NULL THEN
    RETURN NULL;
  END IF;

  IF source_kind = 'row' THEN
    SELECT array_agg(field_name)
    INTO input_columns
    FROM jsonb_array_elements_text(
      COALESCE(revision_definition #> '{source,input_columns}', '[]'::jsonb)
    ) field(field_name);
    current_input_query := format(
      $query$
        SELECT
          (source.%1$I)::text AS subject_id,
          jsonb_build_object(
            '_otlet_mvcc', jsonb_build_object(
              'table', %2$L,
              'subject_id', (source.%1$I)::text,
              'ctid', source.ctid::text,
              'xmin', source.xmin::text
            ),
            'table', %2$L,
            'row', otlet.semantic_project_row(to_jsonb(source), %4$L::text[])
          ) AS input
        FROM %3$s AS source
        WHERE (source.%1$I)::text = %5$L
      $query$,
      (revision_definition #>> '{source,subject_column}')::name,
      revision_definition #>> '{source,source_table}',
      revision_definition #>> '{source,source_table}',
      input_columns,
      current_task_subject_input_snapshot.subject_id
    );
  ELSE
    current_input_query := revision_definition #>> '{task,input_query}';
  END IF;

  IF NULLIF(current_input_query, '') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT candidate.input
  INTO current_input
  FROM otlet.validated_task_input_rows(
    current_input_query,
    workload_definition => revision_definition,
    validate_contract => false
  ) candidate
  WHERE candidate.subject_id = current_task_subject_input_snapshot.subject_id;
  RETURN current_input;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.current_task_subject_content_hash(
  task_name text,
  subject_id text,
  workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  current_input jsonb;
  input_shaping jsonb;
BEGIN
  current_input := otlet.current_task_subject_input_snapshot(
    current_task_subject_content_hash.task_name,
    current_task_subject_content_hash.subject_id,
    current_task_subject_content_hash.workload_revision_hash
  );
  IF current_input IS NULL THEN
    RETURN NULL;
  END IF;
  IF current_task_subject_content_hash.workload_revision_hash IS NULL THEN
    SELECT task.input_shaping
    INTO input_shaping
    FROM otlet.tasks task
    WHERE task.name = current_task_subject_content_hash.task_name;
  ELSE
    SELECT revision.definition #> '{task,input_shaping}'
    INTO input_shaping
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = current_task_subject_content_hash.task_name
      AND revision.workload_revision_hash =
        current_task_subject_content_hash.workload_revision_hash;
  END IF;
  RETURN otlet.semantic_content_hash(current_input, input_shaping);
END;
$$;

CREATE FUNCTION otlet.current_task_subject_source_hash(
  task_name text,
  subject_id text,
  workload_revision_hash text DEFAULT NULL
) RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
  SELECT otlet.semantic_source_hash(
    otlet.current_task_subject_input_snapshot($1, $2, $3)
  );
$$;

CREATE FUNCTION otlet.eval_label_current_source_hash(label_id bigint) RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target record;
BEGIN
  SELECT label.task_name, label.subject_id, label.workload_revision_hash
  INTO target
  FROM otlet.eval_labels label
  WHERE label.id = eval_label_current_source_hash.label_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  BEGIN
    RETURN otlet.current_task_subject_source_hash(
      target.task_name,
      target.subject_id,
      target.workload_revision_hash
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

CREATE FUNCTION otlet.populate_eval_label_provenance() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  evidence record;
  role_setting text := current_setting('role', true);
BEGIN
  SELECT
    job.task_name,
    job.workload_revision_hash,
    job.subject_id,
    otlet.semantic_content_hash(
      job.input,
      revision.definition #> '{task,input_shaping}'
    ) AS content_hash,
    CASE
      WHEN revision.definition #>> '{source,kind}' = 'pair'
        OR COALESCE(
          job.input -> '_otlet_mvcc',
          job.input -> 'otlet_mvcc'
        ) ?& ARRAY['left_id', 'right_id']
      THEN NULL
      ELSE COALESCE(
        job.input #>> '{_otlet_mvcc,table}',
        job.input #>> '{otlet_mvcc,table}',
        revision.definition #>> '{source,source_table}',
        receipt.trace_summary #>> '{mvcc,table}'
      )
    END AS source_table,
    otlet.semantic_source_hash(job.input) AS source_hash
  INTO evidence
  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  JOIN otlet.inference_receipts receipt ON receipt.id = action.receipt_id
  WHERE action.id = NEW.action_id
    AND action.output_id IS NOT DISTINCT FROM NEW.output_id
    AND action.receipt_id IS NOT DISTINCT FROM NEW.receipt_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation label provenance is invalid';
  END IF;

  NEW.task_name := evidence.task_name;
  NEW.workload_revision_hash := evidence.workload_revision_hash;
  NEW.subject_id := evidence.subject_id;
  NEW.source_table := evidence.source_table;
  NEW.source_hash := evidence.source_hash;
  NEW.content_hash := evidence.content_hash;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    concat_ws(':',
      'otlet_eval_label',
      evidence.task_name,
      COALESCE(evidence.source_table, ''),
      evidence.subject_id
    ),
    0
  ));
  INSERT INTO otlet.eval_label_series_revisions (
    task_name,
    source_table,
    subject_id,
    last_revision
  ) VALUES (
    evidence.task_name,
    evidence.source_table,
    evidence.subject_id,
    1
  )
  ON CONFLICT ON CONSTRAINT eval_label_series_revisions_key DO UPDATE
  SET last_revision = otlet.eval_label_series_revisions.last_revision + 1
  RETURNING last_revision INTO NEW.label_revision;
  NEW.authenticated_role_oid := session_user::regrole::oid;
  NEW.authenticated_role_name := session_user;
  IF role_setting IS NULL OR role_setting = 'none' THEN
    NEW.active_role_oid := NEW.authenticated_role_oid;
    NEW.active_role_name := NEW.authenticated_role_name;
  ELSE
    SELECT role.oid, role.rolname
    INTO NEW.active_role_oid, NEW.active_role_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = role_setting::regrole::oid;
  END IF;
  NEW.adjudication_state := 'pending';
  NEW.label_confidence := NULL;
  NEW.supersedes_label_id := NULL;
  NEW.adjudication_reason := NULL;
  NEW.adjudicated_authenticated_role_oid := NULL;
  NEW.adjudicated_authenticated_role_name := NULL;
  NEW.adjudicated_active_role_oid := NULL;
  NEW.adjudicated_active_role_name := NULL;
  NEW.adjudicated_at := NULL;
  NEW.created_at := clock_timestamp();
  RETURN NEW;
END;
$$;

CREATE TRIGGER eval_labels_b_provenance
BEFORE INSERT ON otlet.eval_labels
FOR EACH ROW EXECUTE FUNCTION otlet.populate_eval_label_provenance();

CREATE FUNCTION otlet.guard_eval_label_adjudication() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF current_setting('otlet.eval_label_adjudication', true) IS DISTINCT FROM 'on'
     OR OLD.adjudication_state <> 'pending'
     OR NEW.adjudication_state NOT IN ('accepted', 'rejected')
     OR (to_jsonb(NEW) - ARRAY[
       'adjudication_state',
       'label_confidence',
       'supersedes_label_id',
       'adjudication_reason',
       'adjudicated_authenticated_role_oid',
       'adjudicated_authenticated_role_name',
       'adjudicated_active_role_oid',
       'adjudicated_active_role_name',
       'adjudicated_at'
     ]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[
       'adjudication_state',
       'label_confidence',
       'supersedes_label_id',
       'adjudication_reason',
       'adjudicated_authenticated_role_oid',
       'adjudicated_authenticated_role_name',
       'adjudicated_active_role_oid',
       'adjudicated_active_role_name',
       'adjudicated_at'
     ]) THEN
    RAISE EXCEPTION 'otlet evaluation label provenance is immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER eval_labels_c_adjudication
BEFORE UPDATE ON otlet.eval_labels
FOR EACH ROW EXECUTE FUNCTION otlet.guard_eval_label_adjudication();

CREATE FUNCTION otlet.lock_eval_label_series(label_ids bigint[]) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  series record;
BEGIN
  FOR series IN
    SELECT DISTINCT
      label.task_name,
      label.source_table,
      label.subject_id
    FROM otlet.eval_labels label
    WHERE label.id = ANY(COALESCE(lock_eval_label_series.label_ids, ARRAY[]::bigint[]))
    ORDER BY label.task_name, label.source_table NULLS FIRST, label.subject_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      concat_ws(':',
        'otlet_eval_label',
        series.task_name,
        COALESCE(series.source_table, ''),
        series.subject_id
      ),
      0
    ));
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.guard_eval_label_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  cleanup_mode text := current_setting('otlet.eval_label_cleanup', true);
BEGIN
  IF cleanup_mode = 'skip' THEN
    RETURN NULL;
  END IF;
  IF cleanup_mode IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'otlet evaluation label history is cleanup-managed';
  END IF;
  RETURN OLD;
END;
$$;

CREATE TRIGGER eval_labels_d_delete_guard
BEFORE DELETE ON otlet.eval_labels
FOR EACH ROW EXECUTE FUNCTION otlet.guard_eval_label_delete();

CREATE TRIGGER eval_labels_truncate_guard
BEFORE TRUNCATE ON otlet.eval_labels
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_eval_label_delete();

CREATE FUNCTION otlet.cleanup_eval_label_series(
  cutoff timestamptz,
  requested_dry_run boolean DEFAULT true
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  series record;
  affected bigint := 0;
  deleted bigint;
  previous_cleanup text := current_setting('otlet.eval_label_cleanup', true);
BEGIN
  IF cleanup_eval_label_series.cutoff IS NULL THEN
    RAISE EXCEPTION 'otlet evaluation label cleanup cutoff is required';
  END IF;
  IF NOT COALESCE(cleanup_eval_label_series.requested_dry_run, true)
     AND current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'otlet evaluation label cleanup requires read committed isolation';
  END IF;
  IF COALESCE(cleanup_eval_label_series.requested_dry_run, true) THEN
    WITH series_status AS (
      SELECT
        label.task_name,
        label.source_table,
        label.subject_id,
        max(COALESCE(label.adjudicated_at, label.created_at)) AS last_event_at
      FROM otlet.eval_labels label
      GROUP BY label.task_name, label.source_table, label.subject_id
    ), deletable AS (
      SELECT status.*
      FROM series_status status
      WHERE status.last_event_at < cleanup_eval_label_series.cutoff
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = status.task_name
            AND member.source_table IS NOT DISTINCT FROM status.source_table
            AND member.subject_id = status.subject_id
        )
    )
    SELECT count(*)
    INTO affected
    FROM otlet.eval_labels label
    JOIN deletable
      ON deletable.task_name = label.task_name
     AND deletable.source_table IS NOT DISTINCT FROM label.source_table
     AND deletable.subject_id = label.subject_id;
    RETURN affected;
  END IF;

  PERFORM set_config('otlet.eval_label_cleanup', 'on', true);
  FOR series IN
    WITH series_status AS (
      SELECT
        label.task_name,
        label.source_table,
        label.subject_id,
        max(COALESCE(label.adjudicated_at, label.created_at)) AS last_event_at
      FROM otlet.eval_labels label
      GROUP BY label.task_name, label.source_table, label.subject_id
    )
    SELECT status.*
    FROM series_status status
    WHERE status.last_event_at < cleanup_eval_label_series.cutoff
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.eval_labels member
        JOIN otlet.evaluation_cases evaluation_case
          ON evaluation_case.label_id = member.id
        WHERE member.task_name = status.task_name
          AND member.source_table IS NOT DISTINCT FROM status.source_table
          AND member.subject_id = status.subject_id
      )
    ORDER BY status.task_name, status.source_table NULLS FIRST, status.subject_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      concat_ws(':',
        'otlet_eval_label',
        series.task_name,
        COALESCE(series.source_table, ''),
        series.subject_id
      ),
      0
    ));
    IF EXISTS (
      SELECT 1
      FROM otlet.eval_labels label
      WHERE label.task_name = series.task_name
        AND label.source_table IS NOT DISTINCT FROM series.source_table
        AND label.subject_id = series.subject_id
      HAVING max(COALESCE(label.adjudicated_at, label.created_at)) <
          cleanup_eval_label_series.cutoff
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = series.task_name
            AND member.source_table IS NOT DISTINCT FROM series.source_table
            AND member.subject_id = series.subject_id
        )
    ) THEN
      DELETE FROM otlet.eval_labels label
      WHERE label.task_name = series.task_name
        AND label.source_table IS NOT DISTINCT FROM series.source_table
        AND label.subject_id = series.subject_id;
      GET DIAGNOSTICS deleted = ROW_COUNT;
      affected := affected + deleted;
    END IF;
  END LOOP;
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
  RETURN affected;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
  RAISE;
END;
$$;

ALTER FUNCTION otlet.cleanup_policy_state(boolean)
RENAME TO cleanup_policy_state_without_label_quality;

DO $$
DECLARE
  function_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'otlet.cleanup_policy_state_without_label_quality(boolean)'::regprocedure
  )
  INTO function_definition;
  EXECUTE replace(
    function_definition,
    'cleanup_policy_state.requested_dry_run',
    'cleanup_policy_state_without_label_quality.requested_dry_run'
  );
END;
$$;

CREATE FUNCTION otlet.cleanup_policy_state(
  requested_dry_run boolean DEFAULT true
) RETURNS TABLE (
  worker_events bigint,
  token_trace_rows bigint,
  token_alternative_rows bigint,
  eval_labels bigint,
  delete_stale_materializations bigint,
  sensitive_raw_outputs bigint,
  sensitive_chosen_texts bigint,
  sensitive_token_texts bigint,
  sensitive_alternative_token_texts bigint,
  failed_canceled_jobs bigint,
  dry_run boolean
)
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  eval_retention interval;
  label_count bigint;
  previous_cleanup text := current_setting('otlet.eval_label_cleanup', true);
BEGIN
  SELECT policy.eval_label_retention
  INTO eval_retention
  FROM otlet.production_policy policy
  WHERE policy.name = 'default';
  label_count := otlet.cleanup_eval_label_series(
    now() - eval_retention,
    cleanup_policy_state.requested_dry_run
  );
  PERFORM set_config('otlet.eval_label_cleanup', 'skip', true);
  RETURN QUERY
  SELECT
    state.worker_events,
    state.token_trace_rows,
    state.token_alternative_rows,
    label_count,
    state.delete_stale_materializations,
    state.sensitive_raw_outputs,
    state.sensitive_chosen_texts,
    state.sensitive_token_texts,
    state.sensitive_alternative_token_texts,
    state.failed_canceled_jobs,
    state.dry_run
  FROM otlet.cleanup_policy_state_without_label_quality(
    cleanup_policy_state.requested_dry_run
  ) state;
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config(
    'otlet.eval_label_cleanup',
    COALESCE(previous_cleanup, ''),
    true
  );
  RAISE;
END;
$$;

CREATE FUNCTION otlet.adjudicate_eval_label(
  label_id bigint,
  outcome text,
  label_confidence numeric,
  reason text,
  supersedes_label_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  target otlet.eval_labels%ROWTYPE;
  predecessor otlet.eval_labels%ROWTYPE;
  role_setting text := current_setting('role', true);
  active_oid oid;
  active_name text;
  previous_adjudication text :=
    current_setting('otlet.eval_label_adjudication', true);
BEGIN
  IF adjudicate_eval_label.outcome NOT IN ('accepted', 'rejected')
     OR adjudicate_eval_label.label_confidence IS NULL
     OR adjudicate_eval_label.label_confidence = 'NaN'::numeric
     OR adjudicate_eval_label.label_confidence < 0
     OR adjudicate_eval_label.label_confidence > 1
     OR NULLIF(btrim(adjudicate_eval_label.reason), '') IS NULL
     OR octet_length(adjudicate_eval_label.reason) > 4096
     OR (
       adjudicate_eval_label.outcome = 'rejected'
       AND adjudicate_eval_label.supersedes_label_id IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'otlet evaluation label adjudication is invalid';
  END IF;

  PERFORM otlet.lock_eval_label_series(ARRAY[adjudicate_eval_label.label_id]);
  SELECT * INTO target
  FROM otlet.eval_labels label
  WHERE label.id = adjudicate_eval_label.label_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation label does not exist';
  END IF;
  IF target.adjudication_state <> 'pending' THEN
    IF target.adjudication_state = adjudicate_eval_label.outcome
       AND target.label_confidence = adjudicate_eval_label.label_confidence
       AND target.adjudication_reason = btrim(adjudicate_eval_label.reason)
       AND target.supersedes_label_id IS NOT DISTINCT FROM
         adjudicate_eval_label.supersedes_label_id THEN
      RETURN target.id;
    END IF;
    RAISE EXCEPTION 'otlet evaluation label adjudication conflicts with the stored decision';
  END IF;

  IF adjudicate_eval_label.supersedes_label_id IS NOT NULL THEN
    SELECT * INTO predecessor
    FROM otlet.eval_labels label
    WHERE label.id = adjudicate_eval_label.supersedes_label_id;
    IF NOT FOUND
       OR predecessor.id = target.id
       OR predecessor.task_name <> target.task_name
       OR predecessor.source_table IS DISTINCT FROM target.source_table
       OR predecessor.subject_id <> target.subject_id
       OR predecessor.adjudication_state <> 'accepted'
       OR predecessor.label_revision >= target.label_revision
       OR EXISTS (
         SELECT 1
         FROM otlet.eval_labels successor
         WHERE successor.supersedes_label_id = predecessor.id
       ) THEN
      RAISE EXCEPTION 'otlet evaluation label predecessor is invalid';
    END IF;
  END IF;

  IF role_setting IS NULL OR role_setting = 'none' THEN
    active_oid := session_user::regrole::oid;
    active_name := session_user;
  ELSE
    SELECT role.oid, role.rolname
    INTO active_oid, active_name
    FROM pg_catalog.pg_roles role
    WHERE role.oid = role_setting::regrole::oid;
  END IF;
  PERFORM set_config('otlet.eval_label_adjudication', 'on', true);
  UPDATE otlet.eval_labels label
  SET adjudication_state = adjudicate_eval_label.outcome,
      label_confidence = adjudicate_eval_label.label_confidence,
      supersedes_label_id = adjudicate_eval_label.supersedes_label_id,
      adjudication_reason = btrim(adjudicate_eval_label.reason),
      adjudicated_authenticated_role_oid = session_user::regrole::oid,
      adjudicated_authenticated_role_name = session_user,
      adjudicated_active_role_oid = active_oid,
      adjudicated_active_role_name = active_name,
      adjudicated_at = clock_timestamp()
  WHERE label.id = target.id;
  PERFORM set_config(
    'otlet.eval_label_adjudication',
    COALESCE(previous_adjudication, ''),
    true
  );
  RETURN target.id;
END;
$$;

CREATE VIEW otlet.eval_label_quality_status AS
WITH base AS MATERIALIZED (
  SELECT
    label.*,
    successor.id AS superseded_by_label_id
  FROM otlet.eval_labels label
  LEFT JOIN otlet.eval_labels successor
    ON successor.supersedes_label_id = label.id
), classified AS (
  SELECT
    label.*,
    label.superseded_by_label_id IS NULL AS current_label,
    label.superseded_by_label_id IS NULL
      AND label.adjudication_state <> 'rejected'
      AND EXISTS (
        SELECT 1
        FROM base other
        WHERE other.id <> label.id
          AND other.superseded_by_label_id IS NULL
          AND other.adjudication_state <> 'rejected'
          AND other.task_name = label.task_name
          AND other.workload_revision_hash = label.workload_revision_hash
          AND other.source_table IS NOT DISTINCT FROM label.source_table
          AND other.subject_id = label.subject_id
          AND other.source_hash = label.source_hash
          AND ROW(
            other.expected_answer,
            other.expected_confidence,
            other.expected_action_type
          ) IS DISTINCT FROM ROW(
            label.expected_answer,
            label.expected_confidence,
            label.expected_action_type
          )
      ) AS contradictory
  FROM base label
), freshness AS (
  SELECT
    label.*,
    current.current_source_hash,
    current.current_source_hash IS NOT NULL
      AND current.current_source_hash = label.source_hash AS source_revision_current
  FROM classified label
  CROSS JOIN LATERAL (
    SELECT otlet.eval_label_current_source_hash(label.id) AS current_source_hash
  ) current
)
SELECT
  label.id AS label_id,
  label.task_name,
  label.workload_revision_hash,
  label.label_revision,
  label.action_id,
  label.output_id,
  label.receipt_id,
  label.source_table,
  label.subject_id,
  label.source_hash,
  label.current_source_hash,
  label.content_hash,
  label.expected_answer,
  label.expected_confidence,
  label.expected_action_type,
  label.label_source,
  label.reason,
  label.authenticated_role_name AS authored_by,
  label.active_role_name AS authored_as,
  label.adjudication_state,
  label.label_confidence,
  label.supersedes_label_id,
  label.superseded_by_label_id,
  label.adjudicated_authenticated_role_name AS adjudicated_by,
  label.adjudicated_active_role_name AS adjudicated_as,
  label.adjudication_reason,
  label.adjudicated_at,
  label.current_label,
  label.source_revision_current,
  label.contradictory,
  label.adjudication_state = 'accepted'
    AND label.current_label
    AND label.source_revision_current
    AND NOT label.contradictory AS qualification_eligible,
  CASE
    WHEN NOT label.current_label THEN 'superseded'
    WHEN label.adjudication_state = 'pending' THEN 'pending_adjudication'
    WHEN label.adjudication_state = 'rejected' THEN 'rejected'
    WHEN NOT label.source_revision_current THEN 'stale_source_revision'
    WHEN label.contradictory THEN 'contradictory'
    ELSE NULL
  END AS exclusion_reason,
  label.created_at
FROM freshness label;

DROP INDEX otlet.evaluation_cases_lineage_idx;

CREATE INDEX evaluation_cases_lineage_idx
ON otlet.evaluation_cases (lineage_hash, created_at DESC, case_hash);

CREATE OR REPLACE FUNCTION otlet.register_evaluation_case(
  label_id bigint,
  population_kind text,
  approval_reason text
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  shaped_input jsonb;
  shaped_input_hash text;
  computed_lineage_hash text;
  definition jsonb;
  case_hash text;
  existing_case record;
  previous_append text := current_setting('otlet.evaluation_append', true);
BEGIN
  IF COALESCE(register_evaluation_case.population_kind, '') NOT IN (
    'tuning', 'calibration', 'shadow', 'qualification'
  ) THEN
    RAISE EXCEPTION 'otlet evaluation population must be tuning, calibration, shadow, or qualification';
  END IF;
  IF NULLIF(btrim(register_evaluation_case.approval_reason), '') IS NULL
     OR octet_length(register_evaluation_case.approval_reason) > 4096 THEN
    RAISE EXCEPTION 'otlet evaluation snapshot approval reason is required and bounded';
  END IF;

  PERFORM otlet.lock_eval_label_series(ARRAY[register_evaluation_case.label_id]);
  SELECT
    label.id AS label_id,
    job.task_name,
    job.workload_revision_hash,
    job.subject_id,
    job.input,
    revision.definition #> '{task,input_shaping}' AS input_shaping,
    label.source_table,
    label.source_hash,
    label.expected_answer,
    label.expected_confidence,
    label.expected_action_type,
    label.label_source
  INTO source
  FROM otlet.eval_labels label
  JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id
  JOIN otlet.jobs job ON job.id = receipt.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE label.id = register_evaluation_case.label_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet evaluation label has no replayable workload evidence';
  END IF;
  IF register_evaluation_case.population_kind = 'qualification' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.eval_label_quality_status quality
      WHERE quality.label_id = source.label_id
        AND quality.qualification_eligible
    ) THEN
      RAISE EXCEPTION 'otlet qualification evaluation label is not eligible';
    END IF;
  END IF;
  IF NOT otlet.source_fields_are_allowed(source.input, source.input_shaping) THEN
    RAISE EXCEPTION 'otlet evaluation source field allowlist is invalid';
  END IF;

  shaped_input := otlet.semantic_shaped_input(source.input, source.input_shaping);
  IF jsonb_typeof(shaped_input) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'otlet evaluation shaped snapshot must be a JSON object';
  END IF;
  shaped_input_hash := otlet.identity_hash('evaluation_shaped_snapshot', shaped_input);
  computed_lineage_hash := otlet.identity_hash(
    'evaluation_case_lineage',
    jsonb_strip_nulls(jsonb_build_object(
      'task_name', source.task_name,
      'subject_id', source.subject_id,
      'source_table', source.source_table,
      'source_hash', source.source_hash,
      'shaped_input_hash', shaped_input_hash
    ))
  );
  definition := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.evaluation.case.v2',
    'source_mode', 'approved_shaped_snapshot',
    'task_name', source.task_name,
    'workload_revision_hash', source.workload_revision_hash,
    'label_id', source.label_id,
    'subject_id', source.subject_id,
    'source_table', source.source_table,
    'source_hash', source.source_hash,
    'shaped_input_hash', shaped_input_hash,
    'lineage_hash', computed_lineage_hash,
    'population_kind', register_evaluation_case.population_kind,
    'expected_answer', source.expected_answer,
    'expected_confidence', source.expected_confidence,
    'expected_action_type', source.expected_action_type,
    'label_source', source.label_source
  ));
  case_hash := otlet.identity_hash('evaluation_case', definition);

  PERFORM pg_advisory_xact_lock(
    hashtextextended('otlet_evaluation_case_lineage:' || computed_lineage_hash, 0)
  );
  SELECT existing.case_hash, existing.population_kind, existing.lineage_hash
  INTO existing_case
  FROM otlet.evaluation_cases existing
  WHERE existing.label_id = source.label_id;
  IF FOUND THEN
    IF existing_case.case_hash IS DISTINCT FROM case_hash THEN
      RAISE EXCEPTION 'otlet evaluation label already has a different case identity';
    END IF;
    RETURN existing_case.case_hash;
  END IF;

  SELECT
    existing.case_hash,
    existing.population_kind,
    existing.lineage_hash,
    existing.label_id
  INTO existing_case
  FROM otlet.evaluation_cases existing
  JOIN otlet.eval_labels existing_label ON existing_label.id = existing.label_id
  WHERE existing.lineage_hash = computed_lineage_hash
  ORDER BY existing_label.label_revision DESC
  LIMIT 1;
  IF FOUND THEN
    IF existing_case.population_kind IS DISTINCT FROM
         register_evaluation_case.population_kind
       OR NOT EXISTS (
         WITH RECURSIVE lineage AS (
           SELECT replacement.id, replacement.supersedes_label_id
           FROM otlet.eval_labels replacement
           WHERE replacement.id = source.label_id
             AND replacement.adjudication_state = 'accepted'
           UNION ALL
           SELECT predecessor.id, predecessor.supersedes_label_id
           FROM otlet.eval_labels predecessor
           JOIN lineage child ON predecessor.id = child.supersedes_label_id
         )
         SELECT 1
         FROM lineage
         WHERE lineage.id = existing_case.label_id
       ) THEN
      RAISE EXCEPTION 'otlet evaluation snapshot lineage is already registered as %',
        existing_case.population_kind;
    END IF;
  END IF;

  PERFORM set_config('otlet.evaluation_append', 'on', true);
  INSERT INTO otlet.evaluation_cases (
    case_hash,
    task_name,
    workload_revision_hash,
    label_id,
    subject_id,
    source_table,
    source_hash,
    shaped_input,
    shaped_input_hash,
    population_kind,
    lineage_hash,
    expected_answer,
    expected_confidence,
    expected_action_type,
    label_source,
    definition,
    approval_reason,
    authenticated_role_oid,
    authenticated_role_name,
    active_role_oid,
    active_role_name
  ) VALUES (
    case_hash,
    source.task_name,
    source.workload_revision_hash,
    source.label_id,
    source.subject_id,
    source.source_table,
    source.source_hash,
    shaped_input,
    shaped_input_hash,
    register_evaluation_case.population_kind,
    computed_lineage_hash,
    source.expected_answer,
    source.expected_confidence,
    source.expected_action_type,
    source.label_source,
    definition,
    btrim(register_evaluation_case.approval_reason),
    session_user::regrole::oid,
    session_user,
    current_user::regrole::oid,
    current_user
  );
  PERFORM set_config('otlet.evaluation_append', COALESCE(previous_append, ''), true);
  RETURN case_hash;
END;
$$;

CREATE FUNCTION otlet.validate_evaluation_case_label_quality() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  PERFORM otlet.lock_eval_label_series(ARRAY[NEW.label_id]);
  IF NEW.population_kind = 'qualification' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM otlet.eval_label_quality_status quality
      WHERE quality.label_id = NEW.label_id
        AND quality.qualification_eligible
    ) THEN
      RAISE EXCEPTION 'otlet qualification evaluation label is not eligible';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_cases_c_label_quality
BEFORE INSERT ON otlet.evaluation_cases
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_case_label_quality();

CREATE FUNCTION otlet.validate_evaluation_run_label_quality() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  label_ids bigint[];
BEGIN
  SELECT array_agg(DISTINCT evaluation_case.label_id ORDER BY evaluation_case.label_id)
  INTO label_ids
  FROM otlet.evaluation_cases evaluation_case
  WHERE evaluation_case.case_hash = ANY(NEW.case_hashes)
    AND evaluation_case.population_kind = 'qualification';
  IF cardinality(label_ids) > 0 THEN
    PERFORM otlet.lock_eval_label_series(label_ids);
    IF EXISTS (
      SELECT 1
      FROM unnest(label_ids) candidate(label_id)
      LEFT JOIN otlet.eval_label_quality_status quality
        ON quality.label_id = candidate.label_id
      WHERE quality.qualification_eligible IS DISTINCT FROM true
    ) THEN
      RAISE EXCEPTION 'otlet qualification evaluation run contains an ineligible label';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER evaluation_runs_e_label_quality
BEFORE INSERT ON otlet.evaluation_runs
FOR EACH ROW EXECUTE FUNCTION otlet.validate_evaluation_run_label_quality();

CREATE FUNCTION otlet.validate_promotion_label_quality() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  label_ids bigint[];
BEGIN
  IF NEW.event_kind <> 'promotion_decision'
     OR NEW.definition #>> '{payload,outcome}' <> 'promote' THEN
    RETURN NEW;
  END IF;
  SELECT array_agg(DISTINCT evaluation_case.label_id ORDER BY evaluation_case.label_id)
  INTO label_ids
  FROM jsonb_array_elements_text(COALESCE(
    NEW.definition #> '{payload,qualification_run_hashes}',
    '[]'::jsonb
  )) run_hash(value)
  JOIN otlet.evaluation_runs run ON run.run_hash = run_hash.value
  JOIN otlet.evaluation_cases evaluation_case
    ON evaluation_case.case_hash = ANY(run.case_hashes);
  PERFORM otlet.lock_eval_label_series(label_ids);
  IF EXISTS (
    SELECT 1
    FROM unnest(COALESCE(label_ids, ARRAY[]::bigint[])) candidate(label_id)
    LEFT JOIN otlet.eval_label_quality_status quality
      ON quality.label_id = candidate.label_id
    WHERE quality.qualification_eligible IS DISTINCT FROM true
  ) THEN
    RAISE EXCEPTION 'otlet workload promotion references an ineligible evaluation label';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_events_c_label_quality
BEFORE INSERT ON otlet.workload_acceptance_events
FOR EACH ROW EXECUTE FUNCTION otlet.validate_promotion_label_quality();

CREATE OR REPLACE VIEW otlet.eval_label_status AS
WITH base AS MATERIALIZED (
  SELECT label.*, successor.id AS superseded_by_label_id
  FROM otlet.eval_labels label
  LEFT JOIN otlet.eval_labels successor
    ON successor.supersedes_label_id = label.id
), classified AS (
  SELECT
    label.*,
    label.superseded_by_label_id IS NULL AS current_label,
    label.superseded_by_label_id IS NULL
      AND label.adjudication_state <> 'rejected'
      AND EXISTS (
        SELECT 1
        FROM base other
        WHERE other.id <> label.id
          AND other.superseded_by_label_id IS NULL
          AND other.adjudication_state <> 'rejected'
          AND other.task_name = label.task_name
          AND other.workload_revision_hash = label.workload_revision_hash
          AND other.source_table IS NOT DISTINCT FROM label.source_table
          AND other.subject_id = label.subject_id
          AND other.source_hash = label.source_hash
          AND ROW(
            other.expected_answer,
            other.expected_confidence,
            other.expected_action_type
          ) IS DISTINCT FROM ROW(
            label.expected_answer,
            label.expected_confidence,
            label.expected_action_type
          )
      ) AS contradictory
  FROM base label
)
SELECT
  label.id AS label_id,
  label.action_id,
  label.output_id,
  label.receipt_id,
  label.source_table,
  label.subject_id,
  label.source_hash,
  label.expected_answer,
  label.expected_confidence,
  label.expected_action_type,
  label.label_source,
  label.reason,
  action.action_type AS observed_action_type,
  action.status AS action_status,
  action.approval_status,
  output.output ->> COALESCE(
    NULLIF(revision.definition #>> '{task,decision_contract,answer_field}', ''),
    'match'
  ) AS observed_answer,
  output.output ->> COALESCE(
    NULLIF(revision.definition #>> '{task,decision_contract,confidence_field}', ''),
    'confidence'
  ) AS observed_confidence,
  receipt.model_name,
  receipt.selection_role,
  receipt.selection_status,
  label.created_at,
  label.task_name,
  label.workload_revision_hash,
  label.content_hash,
  label.label_revision,
  label.authenticated_role_name AS authored_by,
  label.active_role_name AS authored_as,
  label.adjudication_state,
  label.label_confidence,
  label.supersedes_label_id,
  label.superseded_by_label_id,
  label.adjudicated_authenticated_role_name AS adjudicated_by,
  label.adjudicated_active_role_name AS adjudicated_as,
  label.adjudication_reason,
  label.adjudicated_at,
  NULL::text AS current_source_hash,
  label.current_label,
  NULL::boolean AS source_revision_current,
  label.contradictory,
  false AS qualification_eligible,
  CASE
    WHEN NOT label.current_label THEN 'superseded'
    WHEN label.adjudication_state = 'pending' THEN 'pending_adjudication'
    WHEN label.adjudication_state = 'rejected' THEN 'rejected'
    WHEN label.contradictory THEN 'contradictory'
    ELSE 'owner_freshness_check_required'
  END AS exclusion_reason
FROM classified label
LEFT JOIN otlet.actions action ON action.id = label.action_id
LEFT JOIN otlet.jobs job ON job.id = action.job_id
LEFT JOIN otlet.workload_revisions revision
  ON revision.task_name = job.task_name
 AND revision.workload_revision_hash = job.workload_revision_hash
LEFT JOIN otlet.outputs output ON output.id = label.output_id
LEFT JOIN otlet.inference_receipts receipt ON receipt.id = label.receipt_id;

CREATE OR REPLACE VIEW otlet.audit_eval_label_export AS
SELECT
  label.label_id,
  label.action_id,
  label.output_id,
  label.receipt_id,
  label.source_table,
  label.subject_id,
  label.source_hash,
  label.expected_answer,
  label.expected_confidence,
  label.expected_action_type,
  label.label_source,
  label.reason,
  label.observed_action_type,
  label.action_status,
  label.approval_status,
  label.observed_answer,
  label.observed_confidence,
  label.model_name,
  label.selection_role,
  label.selection_status,
  label.created_at,
  label.task_name,
  label.workload_revision_hash,
  label.content_hash,
  label.label_revision,
  label.authored_by,
  label.authored_as,
  label.adjudication_state,
  label.label_confidence,
  label.supersedes_label_id,
  label.superseded_by_label_id,
  label.adjudicated_by,
  label.adjudicated_as,
  label.adjudication_reason,
  label.adjudicated_at,
  label.current_source_hash,
  label.current_label,
  label.source_revision_current,
  label.contradictory,
  label.qualification_eligible,
  label.exclusion_reason
FROM otlet.eval_label_status label;

CREATE OR REPLACE VIEW otlet.evaluation_case_status AS
SELECT
  evaluation_case.case_hash,
  evaluation_case.task_name,
  evaluation_case.workload_revision_hash AS source_workload_revision_hash,
  evaluation_case.label_id,
  evaluation_case.subject_id,
  evaluation_case.source_table,
  evaluation_case.source_hash,
  evaluation_case.shaped_input_hash,
  'approved_shaped_snapshot'::text AS source_mode,
  evaluation_case.expected_answer,
  evaluation_case.expected_confidence,
  evaluation_case.expected_action_type,
  evaluation_case.label_source,
  evaluation_case.approval_reason,
  evaluation_case.authenticated_role_name AS approved_by,
  evaluation_case.active_role_name AS approved_as,
  evaluation_case.created_at,
  evaluation_case.population_kind,
  evaluation_case.lineage_hash,
  quality.label_revision,
  quality.label_confidence,
  quality.adjudication_state AS label_adjudication_state,
  quality.current_label AS label_current,
  quality.source_revision_current AS label_source_revision_current,
  quality.contradictory AS label_contradictory,
  quality.qualification_eligible AS label_qualification_eligible,
  quality.exclusion_reason AS label_exclusion_reason
FROM otlet.evaluation_cases evaluation_case
JOIN otlet.eval_label_quality_status quality
  ON quality.label_id = evaluation_case.label_id;

REVOKE EXECUTE ON FUNCTION otlet.current_task_subject_input_snapshot(
  text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.current_task_subject_content_hash(
  text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.current_task_subject_source_hash(
  text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.eval_label_current_source_hash(bigint)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.populate_eval_label_provenance() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_eval_label_adjudication() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.lock_eval_label_series(bigint[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_eval_label_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.cleanup_eval_label_series(
  timestamptz, boolean
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.cleanup_policy_state_without_label_quality(
  boolean
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.cleanup_policy_state(boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.adjudicate_eval_label(
  bigint, text, numeric, text, bigint
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_case_label_quality()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_evaluation_run_label_quality()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_promotion_label_quality() FROM PUBLIC;
REVOKE ALL ON TABLE otlet.eval_label_series_revisions FROM PUBLIC;
REVOKE ALL ON TABLE otlet.eval_label_quality_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.eval_label_status FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_eval_label_export FROM PUBLIC;
REVOKE ALL ON TABLE otlet.evaluation_case_status FROM PUBLIC;
