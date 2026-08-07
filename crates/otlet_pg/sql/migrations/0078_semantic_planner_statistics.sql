CREATE TABLE otlet.semantic_planner_statistics (
  task_name text NOT NULL,
  workload_revision_hash text NOT NULL,
  total_subjects bigint NOT NULL CHECK (total_subjects >= 0),
  fresh_subjects bigint NOT NULL CHECK (fresh_subjects >= 0),
  stale_subjects bigint NOT NULL CHECK (stale_subjects >= 0),
  missing_subjects bigint NOT NULL CHECK (missing_subjects >= 0),
  stale_reasons jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
    jsonb_typeof(stale_reasons) = 'object'
  ),
  count_basis text NOT NULL CHECK (count_basis IN (
    'maintained',
    'maintained_upper_bound',
    'maintained_invalid'
  )),
  valid_until timestamptz,
  refreshed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  invalidated_at timestamptz,
  invalidation_reason text,
  statistics_version bigint NOT NULL DEFAULT 1 CHECK (statistics_version > 0),
  PRIMARY KEY (task_name, workload_revision_hash),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
    ON DELETE CASCADE,
  CHECK (fresh_subjects + stale_subjects + missing_subjects = total_subjects),
  CHECK (
    (count_basis = 'maintained_invalid'
      AND invalidated_at IS NOT NULL
      AND NULLIF(invalidation_reason, '') IS NOT NULL)
    OR
    (count_basis <> 'maintained_invalid'
      AND invalidated_at IS NULL
      AND invalidation_reason IS NULL)
  )
);

CREATE FUNCTION otlet.recompute_semantic_planner_statistics(
  requested_task_name text,
  expected_workload_revision_hash text,
  requested_total_subjects bigint DEFAULT NULL,
  requested_count_basis text DEFAULT NULL
) RETURNS otlet.semantic_planner_statistics
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  current_row otlet.semantic_planner_statistics%ROWTYPE;
  saved otlet.semantic_planner_statistics%ROWTYPE;
  materialized_subjects bigint := 0;
  fresh_subjects bigint := 0;
  stale_subjects bigint := 0;
  stale_reasons jsonb := '{}'::jsonb;
  total_subjects bigint;
  count_basis text;
  valid_until timestamptz;
  revision_definition jsonb;
BEGIN
  IF requested_count_basis IS NOT NULL
     AND requested_count_basis NOT IN (
       'maintained', 'maintained_upper_bound', 'maintained_invalid'
     ) THEN
    RAISE EXCEPTION 'otlet semantic planner count basis is invalid';
  END IF;
  IF requested_total_subjects IS NOT NULL AND requested_total_subjects < 0 THEN
    RAISE EXCEPTION 'otlet semantic planner total subjects cannot be negative';
  END IF;
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = recompute_semantic_planner_statistics.requested_task_name
    AND revision.workload_revision_hash =
      recompute_semantic_planner_statistics.expected_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet workload revision does not exist for semantic statistics';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_semantic_statistics:' || requested_task_name || ':' ||
      expected_workload_revision_hash,
    0
  ));
  SELECT statistics.*
  INTO current_row
  FROM otlet.semantic_planner_statistics statistics
  WHERE statistics.task_name = requested_task_name
    AND statistics.workload_revision_hash = expected_workload_revision_hash
  FOR UPDATE;

  WITH latest AS (
    SELECT DISTINCT ON (materialization.subject_id)
      materialization.subject_id,
      materialization.stale,
      materialization.stale_reason,
      stored.stale_reason AS stored_stale_reason,
      materialization.updated_at,
      materialization.id
    FROM otlet.semantic_materializations_effective materialization
    JOIN otlet.semantic_materializations stored
      ON stored.id = materialization.id
    WHERE materialization.task_name = requested_task_name
      AND materialization.contract_hash = expected_workload_revision_hash
      AND materialization.subject_id IS NOT NULL
    ORDER BY
      materialization.subject_id,
      materialization.updated_at DESC,
      materialization.id DESC
  ), classified AS (
    SELECT *
    FROM latest
    WHERE stored_stale_reason IS NULL
       OR stored_stale_reason NOT IN ('source_delete', 'candidate_removed')
  )
  SELECT
    count(*)::bigint,
    count(*) FILTER (WHERE NOT stale)::bigint,
    count(*) FILTER (WHERE stale)::bigint,
    COALESCE((
      SELECT jsonb_object_agg(reason, reason_count ORDER BY reason)
      FROM (
        SELECT stale_reason AS reason, count(*) AS reason_count
        FROM classified
        WHERE stale
        GROUP BY stale_reason
      ) reasons
    ), '{}'::jsonb)
  INTO materialized_subjects, fresh_subjects, stale_subjects, stale_reasons
  FROM classified;

  total_subjects := CASE
    WHEN requested_total_subjects IS NOT NULL THEN requested_total_subjects
    ELSE COALESCE(current_row.total_subjects, materialized_subjects)
  END;
  IF fresh_subjects + stale_subjects > total_subjects THEN
    fresh_subjects := 0;
    stale_subjects := total_subjects;
    stale_reasons := CASE WHEN total_subjects > 0
      THEN jsonb_build_object('source_set_reduced', total_subjects)
      ELSE '{}'::jsonb
    END;
  END IF;
  count_basis := COALESCE(
    requested_count_basis,
    current_row.count_basis,
    'maintained'
  );
  SELECT min(deadline)
  INTO valid_until
  FROM (
    SELECT freshness.expires_at AS deadline
    FROM otlet.watch_time_freshness freshness
    WHERE freshness.task_name = requested_task_name
      AND freshness.workload_revision_hash = expected_workload_revision_hash
      AND freshness.expires_at > statement_timestamp()
    UNION ALL
    SELECT correction.expires_at
    FROM otlet.semantic_correction_overrides correction
    WHERE correction.task_name = requested_task_name
      AND correction.record_type =
        revision_definition #>> '{source,record_type}'
      AND correction.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision_definition)
      AND correction.expires_at > statement_timestamp()
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.semantic_correction_overrides successor
        WHERE successor.supersedes_correction_hash = correction.correction_hash
      )
  ) deadlines;

  INSERT INTO otlet.semantic_planner_statistics (
    task_name,
    workload_revision_hash,
    total_subjects,
    fresh_subjects,
    stale_subjects,
    missing_subjects,
    stale_reasons,
    count_basis,
    valid_until,
    refreshed_at,
    invalidated_at,
    invalidation_reason
  ) VALUES (
    requested_task_name,
    expected_workload_revision_hash,
    total_subjects,
    fresh_subjects,
    stale_subjects,
    total_subjects - fresh_subjects - stale_subjects,
    stale_reasons,
    count_basis,
    valid_until,
    clock_timestamp(),
    CASE WHEN count_basis = 'maintained_invalid'
      THEN COALESCE(current_row.invalidated_at, clock_timestamp())
      ELSE NULL
    END,
    CASE WHEN count_basis = 'maintained_invalid'
      THEN COALESCE(current_row.invalidation_reason, 'statistics_invalid')
      ELSE NULL
    END
  )
  ON CONFLICT (task_name, workload_revision_hash) DO UPDATE
  SET total_subjects = EXCLUDED.total_subjects,
      fresh_subjects = EXCLUDED.fresh_subjects,
      stale_subjects = EXCLUDED.stale_subjects,
      missing_subjects = EXCLUDED.missing_subjects,
      stale_reasons = EXCLUDED.stale_reasons,
      count_basis = EXCLUDED.count_basis,
      valid_until = EXCLUDED.valid_until,
      refreshed_at = EXCLUDED.refreshed_at,
      invalidated_at = EXCLUDED.invalidated_at,
      invalidation_reason = EXCLUDED.invalidation_reason,
      statistics_version =
        otlet.semantic_planner_statistics.statistics_version + 1
  RETURNING * INTO saved;
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.invalidate_semantic_planner_statistics(
  requested_task_name text,
  expected_workload_revision_hash text,
  requested_reason text
) RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  changed bigint;
BEGIN
  IF NULLIF(requested_reason, '') IS NULL THEN
    RAISE EXCEPTION 'otlet semantic planner invalidation reason is required';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_semantic_statistics:' || requested_task_name || ':' ||
      expected_workload_revision_hash,
    0
  ));
  UPDATE otlet.semantic_planner_statistics statistics
  SET count_basis = 'maintained_invalid',
      invalidated_at = COALESCE(statistics.invalidated_at, clock_timestamp()),
      invalidation_reason = requested_reason,
      statistics_version = statistics.statistics_version + 1
  WHERE statistics.task_name = requested_task_name
    AND statistics.workload_revision_hash = expected_workload_revision_hash
    AND (
      statistics.count_basis <> 'maintained_invalid'
      OR statistics.invalidation_reason IS DISTINCT FROM requested_reason
    );
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed > 0;
END;
$$;

CREATE OR REPLACE FUNCTION otlet.mark_semantic_stale_trigger() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  subject_id text;
  old_subject_id text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    subject_id := to_jsonb(NEW) ->> TG_ARGV[0];
    old_subject_id := to_jsonb(OLD) ->> TG_ARGV[0];
    IF old_subject_id IS DISTINCT FROM subject_id
       AND old_subject_id IS NOT NULL THEN
      PERFORM otlet.mark_semantic_stale(
        format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
        old_subject_id,
        'source_delete'
      );
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    subject_id := to_jsonb(OLD) ->> TG_ARGV[0];
  ELSE
    subject_id := to_jsonb(NEW) ->> TG_ARGV[0];
  END IF;

  PERFORM otlet.mark_semantic_stale(
    format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
    subject_id,
    CASE WHEN TG_OP = 'DELETE' THEN 'source_delete' ELSE 'source_update' END
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION otlet.semantic_planner_source_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  active_revision_hash text;
  source_kind text;
  revision_definition jsonb;
  source_subject_column text;
  changed_subject_id text;
  current_total bigint;
  row_delta bigint := 0;
  changed_rows bigint := 0;
BEGIN
  SELECT
    head.active_workload_revision_hash,
    revision.definition #>> '{source,kind}',
    revision.definition
  INTO active_revision_hash, source_kind, revision_definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = TG_ARGV[0];
  IF NOT FOUND OR source_kind NOT IN ('row', 'pair') THEN
    RETURN NULL;
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT count(*)::bigint INTO changed_rows FROM new_rows;
  ELSIF TG_OP = 'UPDATE' THEN
    SELECT count(*)::bigint INTO changed_rows FROM new_rows;
  ELSIF TG_OP = 'DELETE' THEN
    SELECT count(*)::bigint INTO changed_rows FROM old_rows;
  ELSE
    changed_rows := 1;
  END IF;
  IF changed_rows = 0 THEN
    RETURN NULL;
  END IF;

  IF source_kind = 'row' THEN
    source_subject_column :=
      revision_definition #>> '{source,subject_column}';
  ELSE
    SELECT COALESCE(
      NULLIF(pair_source.value ->> 'subject_column', ''),
      'id'
    )
    INTO source_subject_column
    FROM jsonb_array_elements(COALESCE(
      revision_definition #> '{source,pair_sources}', '[]'::jsonb
    )) pair_source(value)
    WHERE to_regclass(pair_source.value ->> 'table') = TG_RELID
    LIMIT 1;
  END IF;
  IF TG_OP = 'INSERT' AND source_subject_column IS NOT NULL THEN
    FOR changed_subject_id IN
      SELECT DISTINCT to_jsonb(changed_row) ->> source_subject_column
      FROM new_rows changed_row
      WHERE to_jsonb(changed_row) ->> source_subject_column IS NOT NULL
      ORDER BY 1
    LOOP
      PERFORM otlet.mark_semantic_stale(
        format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
        changed_subject_id,
        'source_update'
      );
    END LOOP;
  END IF;

  IF source_kind = 'pair' THEN
    PERFORM otlet.invalidate_semantic_planner_statistics(
      TG_ARGV[0], active_revision_hash, CASE WHEN TG_OP = 'TRUNCATE'
        THEN 'pair_source_truncate'
        ELSE 'pair_source_change'
      END
    );
    RETURN NULL;
  END IF;

  IF TG_OP = 'TRUNCATE' THEN
    PERFORM otlet.mark_semantic_stale(
      format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME),
      NULL,
      'source_delete'
    );
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_semantic_statistics:' || TG_ARGV[0] || ':' ||
      active_revision_hash,
    0
  ));

  SELECT statistics.total_subjects
  INTO current_total
  FROM otlet.semantic_planner_statistics statistics
  WHERE statistics.task_name = TG_ARGV[0]
    AND statistics.workload_revision_hash = active_revision_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' THEN
    row_delta := changed_rows;
  ELSIF TG_OP = 'DELETE' THEN
    row_delta := -changed_rows;
  END IF;
  PERFORM otlet.recompute_semantic_planner_statistics(
    TG_ARGV[0],
    active_revision_hash,
    CASE WHEN TG_OP = 'TRUNCATE'
      THEN 0
      ELSE GREATEST(current_total + row_delta, 0)
    END,
    'maintained'
  );
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.drop_semantic_planner_source_triggers(
  requested_task_name text,
  definition jsonb
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source_relation regclass;
  trigger_prefix text := 'otlet_stats_' || substr(md5(requested_task_name), 1, 16);
BEGIN
  FOR source_relation IN
    SELECT DISTINCT to_regclass(source_table) AS relation_oid
    FROM (
      SELECT definition #>> '{source,source_table}' AS source_table
      WHERE definition #>> '{source,kind}' = 'row'
      UNION ALL
      SELECT value ->> 'table'
      FROM jsonb_array_elements(COALESCE(
        definition #> '{source,pair_sources}', '[]'::jsonb
      )) pair_source(value)
      WHERE definition #>> '{source,kind}' = 'pair'
    ) sources
    WHERE to_regclass(source_table) IS NOT NULL
    ORDER BY relation_oid
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
      trigger_prefix || '_i', source_relation);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
      trigger_prefix || '_u', source_relation);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
      trigger_prefix || '_d', source_relation);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
      trigger_prefix || '_t', source_relation);
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.install_semantic_planner_source_triggers(
  requested_task_name text,
  definition jsonb
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source_relation regclass;
  trigger_prefix text := 'otlet_stats_' || substr(md5(requested_task_name), 1, 16);
BEGIN
  PERFORM otlet.drop_semantic_planner_source_triggers(
    requested_task_name, definition
  );
  FOR source_relation IN
    SELECT DISTINCT to_regclass(source_table) AS relation_oid
    FROM (
      SELECT definition #>> '{source,source_table}' AS source_table
      WHERE definition #>> '{source,kind}' = 'row'
      UNION ALL
      SELECT value ->> 'table'
      FROM jsonb_array_elements(COALESCE(
        definition #> '{source,pair_sources}', '[]'::jsonb
      )) pair_source(value)
      WHERE definition #>> '{source,kind}' = 'pair'
    ) sources
    WHERE to_regclass(source_table) IS NOT NULL
    ORDER BY relation_oid
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I AFTER INSERT ON %s REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION otlet.semantic_planner_source_change(%L)',
      trigger_prefix || '_i', source_relation, requested_task_name
    );
    EXECUTE format(
      'CREATE TRIGGER %I AFTER UPDATE ON %s REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION otlet.semantic_planner_source_change(%L)',
      trigger_prefix || '_u', source_relation, requested_task_name
    );
    EXECUTE format(
      'CREATE TRIGGER %I AFTER DELETE ON %s REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION otlet.semantic_planner_source_change(%L)',
      trigger_prefix || '_d', source_relation, requested_task_name
    );
    EXECUTE format(
      'CREATE TRIGGER %I AFTER TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION otlet.semantic_planner_source_change(%L)',
      trigger_prefix || '_t', source_relation, requested_task_name
    );
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.reset_semantic_planner_statistics(
  requested_task_name text,
  expected_workload_revision_hash text
) RETURNS otlet.semantic_planner_statistics
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  definition jsonb;
  source_kind text;
  source_table text;
  total_subjects bigint;
  count_basis text;
  saved otlet.semantic_planner_statistics%ROWTYPE;
BEGIN
  SELECT revision.definition
  INTO definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = requested_task_name
    AND head.active_workload_revision_hash = expected_workload_revision_hash
  FOR UPDATE OF head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic statistics require the active workload revision';
  END IF;
  source_kind := definition #>> '{source,kind}';
  IF source_kind NOT IN ('row', 'pair') THEN
    RAISE EXCEPTION 'otlet semantic statistics require a row or pair workload';
  END IF;

  PERFORM otlet.lock_task_source_relations(requested_task_name);
  IF source_kind = 'row' THEN
    source_table := definition #>> '{source,source_table}';
    EXECUTE format('SELECT count(*)::bigint FROM %s', source_table)
    INTO total_subjects;
    count_basis := 'maintained';
  ELSE
    total_subjects := (definition #>> '{source,max_candidate_rows}')::bigint;
    count_basis := 'maintained_upper_bound';
  END IF;
  saved := otlet.recompute_semantic_planner_statistics(
    requested_task_name,
    expected_workload_revision_hash,
    total_subjects,
    count_basis
  );
  PERFORM otlet.install_semantic_planner_source_triggers(
    requested_task_name, definition
  );
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.maintain_semantic_planner_statistics(
  requested_task_name text,
  expected_workload_revision_hash text
) RETURNS otlet.semantic_planner_statistics
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  definition jsonb;
  source_kind text;
  index_name text;
  total_subjects bigint;
  saved otlet.semantic_planner_statistics%ROWTYPE;
BEGIN
  SELECT revision.definition
  INTO definition
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = requested_task_name
    AND head.active_workload_revision_hash = expected_workload_revision_hash
  FOR UPDATE OF head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic statistics maintenance conflict for task %',
      requested_task_name;
  END IF;
  source_kind := definition #>> '{source,kind}';
  PERFORM otlet.lock_task_source_relations(requested_task_name);
  IF source_kind = 'row' THEN
    EXECUTE format(
      'SELECT count(*)::bigint FROM %s',
      definition #>> '{source,source_table}'
    ) INTO total_subjects;
  ELSIF source_kind = 'pair' THEN
    index_name := definition #>> '{source,semantic_join_index_name}';
    SELECT count(*)::bigint
    INTO total_subjects
    FROM otlet.semantic_join_candidate_rows(
      index_name, expected_workload_revision_hash, false
    );
  ELSE
    RAISE EXCEPTION 'otlet semantic statistics require a row or pair workload';
  END IF;
  saved := otlet.recompute_semantic_planner_statistics(
    requested_task_name,
    expected_workload_revision_hash,
    total_subjects,
    'maintained'
  );
  PERFORM otlet.install_semantic_planner_source_triggers(
    requested_task_name, definition
  );
  RETURN saved;
END;
$$;

CREATE FUNCTION otlet.semantic_planner_head_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  old_definition jsonb;
  new_definition jsonb;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    SELECT revision.definition
    INTO old_definition
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = OLD.task_name
      AND revision.workload_revision_hash = OLD.active_workload_revision_hash;
    IF old_definition #>> '{source,kind}' IN ('row', 'pair') THEN
      PERFORM otlet.drop_semantic_planner_source_triggers(
        OLD.task_name, old_definition
      );
    END IF;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT revision.definition
    INTO new_definition
    FROM otlet.workload_revisions revision
    WHERE revision.task_name = NEW.task_name
      AND revision.workload_revision_hash = NEW.active_workload_revision_hash;
    IF new_definition #>> '{source,kind}' IN ('row', 'pair') THEN
      PERFORM otlet.reset_semantic_planner_statistics(
        NEW.task_name, NEW.active_workload_revision_hash
      );
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_revision_heads_zz_semantic_planner_statistics
AFTER INSERT OR UPDATE OR DELETE ON otlet.workload_revision_heads
FOR EACH ROW EXECUTE FUNCTION otlet.semantic_planner_head_change();

CREATE FUNCTION otlet.recompute_changed_semantic_planner_statistics() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  changed record;
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' THEN
    FOR changed IN
      SELECT DISTINCT task_name, contract_hash AS workload_revision_hash
      FROM new_materializations
      ORDER BY task_name, workload_revision_hash
    LOOP
      IF EXISTS (
        SELECT 1 FROM otlet.semantic_planner_statistics statistics
        WHERE statistics.task_name = changed.task_name
          AND statistics.workload_revision_hash = changed.workload_revision_hash
      ) THEN
        PERFORM otlet.recompute_semantic_planner_statistics(
          changed.task_name, changed.workload_revision_hash
        );
      END IF;
    END LOOP;
  ELSIF TG_OP = 'DELETE' THEN
    FOR changed IN
      SELECT DISTINCT task_name, contract_hash AS workload_revision_hash
      FROM old_materializations
      ORDER BY task_name, workload_revision_hash
    LOOP
      IF EXISTS (
        SELECT 1 FROM otlet.semantic_planner_statistics statistics
        WHERE statistics.task_name = changed.task_name
          AND statistics.workload_revision_hash = changed.workload_revision_hash
      ) THEN
        PERFORM otlet.recompute_semantic_planner_statistics(
          changed.task_name, changed.workload_revision_hash
        );
      END IF;
    END LOOP;
  ELSE
    FOR changed IN
      SELECT DISTINCT task_name, contract_hash AS workload_revision_hash
      FROM (
        SELECT task_name, contract_hash FROM old_materializations
        UNION ALL
        SELECT task_name, contract_hash FROM new_materializations
      ) revisions
      ORDER BY task_name, workload_revision_hash
    LOOP
      IF EXISTS (
        SELECT 1 FROM otlet.semantic_planner_statistics statistics
        WHERE statistics.task_name = changed.task_name
          AND statistics.workload_revision_hash = changed.workload_revision_hash
      ) THEN
        PERFORM otlet.recompute_semantic_planner_statistics(
          changed.task_name, changed.workload_revision_hash
        );
      END IF;
    END LOOP;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER semantic_materializations_planner_statistics_insert
AFTER INSERT ON otlet.semantic_materializations
REFERENCING NEW TABLE AS new_materializations
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_changed_semantic_planner_statistics();

CREATE TRIGGER semantic_materializations_planner_statistics_update
AFTER UPDATE ON otlet.semantic_materializations
REFERENCING OLD TABLE AS old_materializations NEW TABLE AS new_materializations
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_changed_semantic_planner_statistics();

CREATE TRIGGER semantic_materializations_planner_statistics_delete
AFTER DELETE ON otlet.semantic_materializations
REFERENCING OLD TABLE AS old_materializations
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_changed_semantic_planner_statistics();

CREATE FUNCTION otlet.recompute_corrected_semantic_planner_statistics() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  changed record;
BEGIN
  FOR changed IN
    WITH affected_corrections AS (
      SELECT
        correction.task_name,
        correction.record_type,
        correction.relevant_contract_hash
      FROM new_corrections correction
      UNION
      SELECT
        predecessor.task_name,
        predecessor.record_type,
        predecessor.relevant_contract_hash
      FROM new_corrections correction
      JOIN otlet.semantic_correction_overrides predecessor
        ON predecessor.correction_hash = correction.supersedes_correction_hash
    )
    SELECT DISTINCT statistics.task_name, statistics.workload_revision_hash
    FROM affected_corrections correction
    JOIN otlet.semantic_planner_statistics statistics
      ON statistics.task_name = correction.task_name
    JOIN otlet.workload_revisions revision
      ON revision.task_name = statistics.task_name
     AND revision.workload_revision_hash = statistics.workload_revision_hash
    WHERE correction.record_type =
        revision.definition #>> '{source,record_type}'
      AND correction.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision.definition)
    ORDER BY statistics.task_name, statistics.workload_revision_hash
  LOOP
    PERFORM otlet.recompute_semantic_planner_statistics(
      changed.task_name, changed.workload_revision_hash
    );
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE TRIGGER semantic_corrections_planner_statistics
AFTER INSERT ON otlet.semantic_correction_overrides
REFERENCING NEW TABLE AS new_corrections
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_corrected_semantic_planner_statistics();

CREATE FUNCTION otlet.recompute_constrained_semantic_planner_statistics()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  changed record;
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NULL;
  END IF;
  FOR changed IN
    SELECT DISTINCT
      statistics.task_name,
      statistics.workload_revision_hash
    FROM new_pair_constraint_facts fact
    JOIN otlet.semantic_planner_statistics statistics
      ON statistics.task_name = fact.task_name
    JOIN otlet.workload_revisions revision
      ON revision.task_name = statistics.task_name
     AND revision.workload_revision_hash = statistics.workload_revision_hash
    WHERE fact.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision.definition)
    ORDER BY statistics.task_name, statistics.workload_revision_hash
  LOOP
    PERFORM otlet.recompute_semantic_planner_statistics(
      changed.task_name, changed.workload_revision_hash
    );
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE TRIGGER pair_constraint_facts_planner_statistics
AFTER INSERT ON otlet.pair_constraint_facts
REFERENCING NEW TABLE AS new_pair_constraint_facts
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_constrained_semantic_planner_statistics();

CREATE FUNCTION otlet.recompute_reviewed_semantic_planner_statistics()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  changed record;
BEGIN
  FOR changed IN
    SELECT DISTINCT
      statistics.task_name,
      statistics.workload_revision_hash
    FROM new_review_events review
    JOIN otlet.pair_constraint_facts fact
      ON fact.review_event_id = review.id
    JOIN otlet.semantic_planner_statistics statistics
      ON statistics.task_name = fact.task_name
    JOIN otlet.workload_revisions revision
      ON revision.task_name = statistics.task_name
     AND revision.workload_revision_hash = statistics.workload_revision_hash
    WHERE fact.relevant_contract_hash =
        otlet.pair_constraint_contract_hash(revision.definition)
    ORDER BY statistics.task_name, statistics.workload_revision_hash
  LOOP
    PERFORM otlet.recompute_semantic_planner_statistics(
      changed.task_name, changed.workload_revision_hash
    );
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE TRIGGER review_events_zz_semantic_planner_statistics
AFTER INSERT ON otlet.review_events
REFERENCING NEW TABLE AS new_review_events
FOR EACH STATEMENT
EXECUTE FUNCTION otlet.recompute_reviewed_semantic_planner_statistics();

CREATE FUNCTION otlet.semantic_planner_counts(
  requested_task_name text,
  expected_workload_revision_hash text,
  fallback_total_subjects bigint
) RETURNS TABLE (
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  stale_reasons jsonb,
  count_basis text
)
LANGUAGE plpgsql
STABLE
ROWS 1
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  statistics otlet.semantic_planner_statistics%ROWTYPE;
BEGIN
  SELECT current.*
  INTO statistics
  FROM otlet.semantic_planner_statistics current
  WHERE current.task_name = requested_task_name
    AND current.workload_revision_hash = expected_workload_revision_hash;
  IF NOT FOUND THEN
    total_subjects := GREATEST(COALESCE(fallback_total_subjects, 0), 0);
    fresh_subjects := 0;
    stale_subjects := 0;
    missing_subjects := total_subjects;
    stale_reasons := '{}'::jsonb;
    count_basis := 'maintained_missing';
  ELSIF statistics.count_basis = 'maintained_invalid' THEN
    total_subjects := GREATEST(
      statistics.total_subjects,
      COALESCE(fallback_total_subjects, 0)
    );
    fresh_subjects := 0;
    stale_subjects := 0;
    missing_subjects := total_subjects;
    stale_reasons := '{}'::jsonb;
    count_basis := 'maintained_invalid';
  ELSIF statistics.valid_until IS NOT NULL
        AND statistics.valid_until <= statement_timestamp() THEN
    total_subjects := statistics.total_subjects;
    fresh_subjects := 0;
    stale_subjects := statistics.fresh_subjects + statistics.stale_subjects;
    missing_subjects := statistics.missing_subjects;
    stale_reasons := statistics.stale_reasons || CASE
      WHEN statistics.fresh_subjects > 0 THEN jsonb_build_object(
        'time_expired',
        COALESCE(
          (statistics.stale_reasons ->> 'time_expired')::bigint,
          0
        ) + statistics.fresh_subjects
      )
      ELSE '{}'::jsonb
    END;
    count_basis := 'maintained_expired';
  ELSE
    total_subjects := statistics.total_subjects;
    fresh_subjects := statistics.fresh_subjects;
    stale_subjects := statistics.stale_subjects;
    missing_subjects := statistics.missing_subjects;
    stale_reasons := statistics.stale_reasons;
    count_basis := statistics.count_basis;
  END IF;
  RETURN NEXT;
END;
$$;

CREATE VIEW otlet.semantic_planner_statistics_status AS
SELECT
  statistics.task_name,
  statistics.workload_revision_hash,
  revision.definition #>> '{source,kind}' AS source_kind,
  COALESCE(
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{source,semantic_join_index_name}'
  ) AS index_name,
  counts.total_subjects,
  counts.fresh_subjects,
  counts.stale_subjects,
  counts.missing_subjects,
  counts.stale_reasons,
  counts.count_basis,
  statistics.valid_until,
  statistics.refreshed_at,
  statistics.invalidated_at,
  statistics.invalidation_reason,
  statistics.statistics_version
FROM otlet.semantic_planner_statistics statistics
JOIN otlet.workload_revision_heads head
  ON head.task_name = statistics.task_name
 AND head.active_workload_revision_hash = statistics.workload_revision_hash
JOIN otlet.workload_revisions revision
  ON revision.task_name = statistics.task_name
 AND revision.workload_revision_hash = statistics.workload_revision_hash
CROSS JOIN LATERAL otlet.semantic_planner_counts(
  statistics.task_name,
  statistics.workload_revision_hash,
  statistics.total_subjects
) counts;

CREATE FUNCTION otlet.semantic_row_exact_counts(
  definition jsonb,
  workload_revision_hash text
) RETURNS TABLE (
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  stale_reasons jsonb
)
LANGUAGE plpgsql
VOLATILE
ROWS 1
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  input_columns text[] := ARRAY(
    SELECT value
    FROM jsonb_array_elements_text(COALESCE(
      definition #> '{source,input_columns}', '[]'::jsonb
    )) value
  );
BEGIN
  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
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
            'row', otlet.semantic_project_row(to_jsonb(source), %6$L::text[])
          ) AS input
        FROM %3$s source
      ), current_inputs AS (
        SELECT
          subject_id,
          otlet.semantic_source_hash(input) AS source_hash,
          otlet.semantic_content_hash(input, %7$L::jsonb) AS content_hash
        FROM raw_inputs
      ), latest AS (
        SELECT DISTINCT ON (materialization.subject_id)
          materialization.subject_id,
          materialization.stale,
          materialization.source_hash,
          materialization.content_hash,
          materialization.contract_hash,
          materialization.stale_reason,
          materialization.updated_at,
          materialization.id
        FROM current_inputs input
        JOIN otlet.semantic_materializations_effective materialization
          ON materialization.subject_id = input.subject_id
        WHERE materialization.task_name = %4$L
          AND materialization.record_type = %5$L
          AND materialization.contract_hash = %8$L
        ORDER BY
          materialization.subject_id,
          (
            materialization.content_hash IS NOT DISTINCT FROM input.content_hash
            AND materialization.contract_hash IS NOT DISTINCT FROM %8$L
          ) DESC,
          materialization.updated_at DESC,
          materialization.id DESC
      ), classified AS (
        SELECT
          input.subject_id,
          latest.subject_id IS NOT NULL AS has_materialization,
          COALESCE(status.is_fresh, false) AS is_fresh,
          latest.subject_id IS NOT NULL
            AND COALESCE(status.is_stale, true) AS is_stale,
          COALESCE(
            status.stale_reason, 'content_revalidation_pending'
          ) AS stale_reason
        FROM current_inputs input
        LEFT JOIN latest USING (subject_id)
        LEFT JOIN LATERAL otlet.semantic_freshness_status(
          latest.content_hash,
          latest.contract_hash,
          latest.stale,
          latest.stale_reason,
          latest.source_hash,
          input.content_hash,
          %8$L,
          input.source_hash
        ) status ON latest.subject_id IS NOT NULL
      )
      SELECT
        count(*)::bigint,
        count(*) FILTER (WHERE is_fresh)::bigint,
        count(*) FILTER (WHERE is_stale)::bigint,
        count(*) FILTER (WHERE NOT has_materialization)::bigint,
        COALESCE((
          SELECT jsonb_object_agg(reason, reason_count ORDER BY reason)
          FROM (
            SELECT stale_reason AS reason, count(*) AS reason_count
            FROM classified
            WHERE is_stale
            GROUP BY stale_reason
          ) reasons
        ), '{}'::jsonb)
      FROM classified
    $sql$,
    definition #>> '{source,subject_column}',
    definition #>> '{source,source_table}',
    definition #>> '{source,source_table}',
    definition #>> '{task,name}',
    definition #>> '{source,record_type}',
    input_columns,
    definition #> '{task,input_shaping}',
    workload_revision_hash
  );
END;
$$;

CREATE FUNCTION otlet.semantic_pair_exact_counts(
  definition jsonb,
  workload_revision_hash text
) RETURNS TABLE (
  total_subjects bigint,
  fresh_subjects bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  stale_reasons jsonb
)
LANGUAGE plpgsql
VOLATILE
ROWS 1
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  RETURN QUERY EXECUTE format(
    $sql$
      WITH raw_inputs AS (
        SELECT subject_id, input
        FROM otlet.semantic_join_candidate_rows(%1$L, %4$L, false)
      ), current_inputs AS (
        SELECT
          subject_id,
          otlet.semantic_source_hash(input) AS source_hash,
          otlet.semantic_content_hash(input, %5$L::jsonb) AS content_hash
        FROM raw_inputs
      ), latest AS (
        SELECT DISTINCT ON (materialization.subject_id)
          materialization.subject_id,
          materialization.stale,
          materialization.source_hash,
          materialization.content_hash,
          materialization.contract_hash,
          materialization.stale_reason,
          materialization.updated_at,
          materialization.id
        FROM current_inputs input
        JOIN otlet.semantic_materializations_effective materialization
          ON materialization.subject_id = input.subject_id
        WHERE materialization.task_name = %2$L
          AND materialization.record_type = %3$L
          AND materialization.contract_hash = %4$L
        ORDER BY
          materialization.subject_id,
          (
            materialization.content_hash IS NOT DISTINCT FROM input.content_hash
            AND materialization.contract_hash IS NOT DISTINCT FROM %4$L
          ) DESC,
          materialization.updated_at DESC,
          materialization.id DESC
      ), classified AS (
        SELECT
          input.subject_id,
          latest.subject_id IS NOT NULL AS has_materialization,
          COALESCE(status.is_fresh, false) AS is_fresh,
          latest.subject_id IS NOT NULL
            AND COALESCE(status.is_stale, true) AS is_stale,
          COALESCE(
            status.stale_reason, 'content_revalidation_pending'
          ) AS stale_reason
        FROM current_inputs input
        LEFT JOIN latest USING (subject_id)
        LEFT JOIN LATERAL otlet.semantic_freshness_status(
          latest.content_hash,
          latest.contract_hash,
          latest.stale,
          latest.stale_reason,
          latest.source_hash,
          input.content_hash,
          %4$L,
          input.source_hash
        ) status ON latest.subject_id IS NOT NULL
      )
      SELECT
        count(*)::bigint,
        count(*) FILTER (WHERE is_fresh)::bigint,
        count(*) FILTER (WHERE is_stale)::bigint,
        count(*) FILTER (WHERE NOT has_materialization)::bigint,
        COALESCE((
          SELECT jsonb_object_agg(reason, reason_count ORDER BY reason)
          FROM (
            SELECT stale_reason AS reason, count(*) AS reason_count
            FROM classified
            WHERE is_stale
            GROUP BY stale_reason
          ) reasons
        ), '{}'::jsonb)
      FROM classified
    $sql$,
    definition #>> '{source,semantic_join_index_name}',
    definition #>> '{task,name}',
    definition #>> '{source,record_type}',
    workload_revision_hash,
    definition #> '{task,input_shaping}'
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.semantic_index_plan(
  index_name text,
  exact boolean DEFAULT false,
  expected_workload_revision_hash text DEFAULT NULL
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
VOLATILE
ROWS 1
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  definition jsonb;
  current_revision_hash text;
  current_task_name text;
  current_record_type text;
  current_model_name text;
  current_source_table text;
  schema_drift_error text;
  counts record;
  source_estimate bigint := 0;
  resolved_count_basis text;
BEGIN
  SELECT
    revision.definition,
    head.active_workload_revision_hash,
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,record_type}',
    revision.definition #>> '{models,direct,name}',
    revision.definition #>> '{source,source_table}'
  INTO
    definition,
    current_revision_hash,
    current_task_name,
    current_record_type,
    current_model_name,
    current_source_table
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = index_name
    AND revision.definition #>> '{source,kind}' = 'row';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', index_name;
  END IF;
  IF expected_workload_revision_hash IS NOT NULL
     AND expected_workload_revision_hash IS DISTINCT FROM current_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic plan for index %',
      index_name;
  END IF;
  PERFORM otlet.require_workload_source_contract(
    current_task_name, current_revision_hash, false
  );
  schema_drift_error := otlet.semantic_schema_drift_error(definition);

  IF exact AND schema_drift_error IS NULL THEN
    SELECT * INTO counts
    FROM otlet.semantic_row_exact_counts(definition, current_revision_hash);
    resolved_count_basis := 'exact';
  ELSIF exact THEN
    EXECUTE format('SELECT count(*)::bigint FROM %s', current_source_table)
    INTO source_estimate;
    SELECT
      source_estimate AS total_subjects,
      0::bigint AS fresh_subjects,
      source_estimate AS stale_subjects,
      0::bigint AS missing_subjects,
      jsonb_build_object('schema_drift', source_estimate) AS stale_reasons
    INTO counts;
    resolved_count_basis := 'exact';
  ELSE
    SELECT GREATEST(COALESCE(relation.reltuples, 0), 0)::bigint
    INTO source_estimate
    FROM pg_class relation
    WHERE relation.oid = current_source_table::regclass;
    SELECT * INTO counts
    FROM otlet.semantic_planner_counts(
      current_task_name, current_revision_hash, source_estimate
    );
    resolved_count_basis := counts.count_basis;
    IF schema_drift_error IS NOT NULL THEN
      counts.fresh_subjects := 0;
      counts.stale_subjects := counts.total_subjects;
      counts.missing_subjects := 0;
      counts.stale_reasons := jsonb_build_object(
        'schema_drift', counts.total_subjects
      );
    END IF;
  END IF;

  RETURN QUERY
  SELECT *
  FROM otlet.semantic_plan_from_counts(
    index_name,
    current_task_name,
    current_record_type,
    current_model_name,
    current_source_table,
    'semantic_lookup',
    'empty source',
    'semantic index fully fresh',
    CASE WHEN schema_drift_error IS NULL
      THEN 'policy returns fresh lookup rows only'
      ELSE 'fail closed: ' || schema_drift_error
    END,
    'partial refresh queued before lookup',
    'fresh_inference_scan',
    'fresh inference has no reusable semantic coverage',
    counts.total_subjects,
    counts.fresh_subjects,
    counts.stale_subjects,
    counts.missing_subjects,
    counts.stale_reasons,
    resolved_count_basis,
    schema_drift_error IS NOT NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.semantic_join_index_plan(
  index_name text,
  exact boolean DEFAULT false,
  expected_workload_revision_hash text DEFAULT NULL
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
VOLATILE
ROWS 1
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  definition jsonb;
  current_revision_hash text;
  current_task_name text;
  current_record_type text;
  current_model_name text;
  max_candidate_rows bigint;
  counts record;
  resolved_count_basis text;
BEGIN
  SELECT
    revision.definition,
    head.active_workload_revision_hash,
    revision.definition #>> '{task,name}',
    revision.definition #>> '{source,record_type}',
    revision.definition #>> '{models,direct,name}',
    (revision.definition #>> '{source,max_candidate_rows}')::bigint
  INTO
    definition,
    current_revision_hash,
    current_task_name,
    current_record_type,
    current_model_name,
    max_candidate_rows
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = index_name
    AND revision.definition #>> '{source,kind}' = 'pair';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', index_name;
  END IF;
  IF expected_workload_revision_hash IS NOT NULL
     AND expected_workload_revision_hash IS DISTINCT FROM current_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during semantic join plan for index %',
      index_name;
  END IF;
  PERFORM otlet.require_workload_source_contract(
    current_task_name, current_revision_hash, false
  );

  IF exact THEN
    SELECT * INTO counts
    FROM otlet.semantic_pair_exact_counts(definition, current_revision_hash);
    resolved_count_basis := 'exact';
  ELSE
    SELECT * INTO counts
    FROM otlet.semantic_planner_counts(
      current_task_name, current_revision_hash, max_candidate_rows
    );
    resolved_count_basis := counts.count_basis;
  END IF;

  RETURN QUERY
  SELECT *
  FROM otlet.semantic_plan_from_counts(
    index_name,
    current_task_name,
    current_record_type,
    current_model_name,
    'semantic_join:' || index_name,
    'semantic_join_lookup',
    'empty candidate set',
    'semantic join index fully fresh',
    'policy returns fresh pair lookup rows only',
    'partial pair refresh queued before lookup',
    'fresh_pair_inference',
    'fresh pair inference has no reusable semantic coverage',
    counts.total_subjects,
    counts.fresh_subjects,
    counts.stale_subjects,
    counts.missing_subjects,
    counts.stale_reasons,
    resolved_count_basis
  );
END;
$$;

CREATE OR REPLACE FUNCTION otlet.refresh_semantic_join_index(
  index_name text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  current_task_name text;
  current_revision_hash text;
  queued bigint;
BEGIN
  SELECT
    revision.definition #>> '{task,name}'
  INTO current_task_name
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_join_index_name}' = index_name
    AND revision.definition #>> '{source,kind}' = 'pair';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % does not exist', index_name;
  END IF;

  current_revision_hash :=
    otlet.ensure_active_workload_revision(current_task_name);
  PERFORM 1
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE head.task_name = current_task_name
    AND head.active_workload_revision_hash = current_revision_hash
    AND revision.definition #>> '{source,semantic_join_index_name}' = index_name
    AND revision.definition #>> '{source,kind}' = 'pair'
  FOR UPDATE OF head;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic join index % changed during refresh', index_name;
  END IF;

  SELECT otlet.run_task_with_origin(current_task_name, 'pair_watch') INTO queued;
  PERFORM otlet.maintain_semantic_planner_statistics(
    current_task_name, current_revision_hash
  );
  RETURN queued;
END;
$$;

CREATE FUNCTION otlet.semantic_predicate_counts(
  index_name text,
  expected jsonb,
  expected_workload_revision_hash text DEFAULT NULL
) RETURNS TABLE (
  index_kind text,
  task_name text,
  workload_revision_hash text,
  total_subjects bigint,
  fresh_matches bigint,
  fresh_non_matches bigint,
  stale_subjects bigint,
  missing_subjects bigint,
  inflight_subjects bigint,
  count_basis text,
  checked_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
ROWS 1
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  resolved_revision_hash text;
BEGIN
  IF expected IS NULL THEN
    RAISE EXCEPTION 'otlet semantic predicate diagnostics require expected json';
  END IF;
  semantic_predicate_counts.checked_at := statement_timestamp();
  SELECT head.task_name, head.active_workload_revision_hash, 'row'
  INTO
    semantic_predicate_counts.task_name,
    resolved_revision_hash,
    semantic_predicate_counts.index_kind
  FROM otlet.workload_revision_heads head
  JOIN otlet.workload_revisions revision
    ON revision.task_name = head.task_name
   AND revision.workload_revision_hash = head.active_workload_revision_hash
  WHERE revision.definition #>> '{source,semantic_index_name}' = index_name
    AND revision.definition #>> '{source,kind}' = 'row';
  IF NOT FOUND THEN
    SELECT head.task_name, head.active_workload_revision_hash, 'pair'
    INTO
      semantic_predicate_counts.task_name,
      resolved_revision_hash,
      semantic_predicate_counts.index_kind
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    WHERE revision.definition #>> '{source,semantic_join_index_name}' = index_name
      AND revision.definition #>> '{source,kind}' = 'pair';
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet semantic index % does not exist', index_name;
  END IF;
  IF expected_workload_revision_hash IS NOT NULL
     AND expected_workload_revision_hash IS DISTINCT FROM resolved_revision_hash THEN
    RAISE EXCEPTION 'otlet workload revision changed during predicate diagnostics';
  END IF;
  semantic_predicate_counts.workload_revision_hash := resolved_revision_hash;
  semantic_predicate_counts.count_basis := 'exact_predicate_diagnostic';

  IF semantic_predicate_counts.index_kind = 'row' THEN
    WITH plan AS MATERIALIZED (
      SELECT *
      FROM otlet.semantic_index_plan(index_name, true, resolved_revision_hash)
    ), current_rows AS MATERIALIZED (
      SELECT *
      FROM otlet.semantic_index_current_rows(
        index_name, false, resolved_revision_hash
      )
    )
    SELECT
      plan.total_subjects,
      count(*) FILTER (
        WHERE NOT current_rows.stale AND current_rows.body @> expected
      )::bigint,
      count(*) FILTER (
        WHERE NOT current_rows.stale AND NOT (current_rows.body @> expected)
      )::bigint,
      plan.stale_subjects,
      plan.missing_subjects,
      plan.inflight_subjects
    INTO
      semantic_predicate_counts.total_subjects,
      semantic_predicate_counts.fresh_matches,
      semantic_predicate_counts.fresh_non_matches,
      semantic_predicate_counts.stale_subjects,
      semantic_predicate_counts.missing_subjects,
      semantic_predicate_counts.inflight_subjects
    FROM plan
    LEFT JOIN current_rows ON true
    GROUP BY
      plan.total_subjects,
      plan.stale_subjects,
      plan.missing_subjects,
      plan.inflight_subjects;
  ELSE
    WITH plan AS MATERIALIZED (
      SELECT *
      FROM otlet.semantic_join_index_plan(index_name, true, resolved_revision_hash)
    ), current_rows AS MATERIALIZED (
      SELECT *
      FROM otlet.semantic_join_index_current_rows(
        index_name, false, resolved_revision_hash
      )
    )
    SELECT
      plan.total_subjects,
      count(*) FILTER (
        WHERE NOT current_rows.stale AND current_rows.body @> expected
      )::bigint,
      count(*) FILTER (
        WHERE NOT current_rows.stale AND NOT (current_rows.body @> expected)
      )::bigint,
      plan.stale_subjects,
      plan.missing_subjects,
      plan.inflight_subjects
    INTO
      semantic_predicate_counts.total_subjects,
      semantic_predicate_counts.fresh_matches,
      semantic_predicate_counts.fresh_non_matches,
      semantic_predicate_counts.stale_subjects,
      semantic_predicate_counts.missing_subjects,
      semantic_predicate_counts.inflight_subjects
    FROM plan
    LEFT JOIN current_rows ON true
    GROUP BY
      plan.total_subjects,
      plan.stale_subjects,
      plan.missing_subjects,
      plan.inflight_subjects;
  END IF;
  RETURN NEXT;
END;
$$;

DO $$
DECLARE
  active record;
BEGIN
  FOR active IN
    SELECT head.task_name, head.active_workload_revision_hash
    FROM otlet.workload_revision_heads head
    JOIN otlet.workload_revisions revision
      ON revision.task_name = head.task_name
     AND revision.workload_revision_hash = head.active_workload_revision_hash
    JOIN otlet.tasks task ON task.name = head.task_name
    WHERE revision.definition #>> '{source,kind}' IN ('row', 'pair')
      AND task.lifecycle_state = 'active'
    ORDER BY head.task_name
  LOOP
    PERFORM otlet.reset_semantic_planner_statistics(
      active.task_name, active.active_workload_revision_hash
    );
  END LOOP;
END;
$$;

COMMENT ON TABLE otlet.semantic_planner_statistics IS
  'Revision-pinned generic semantic counts maintained outside planning';
COMMENT ON FUNCTION otlet.maintain_semantic_planner_statistics(text, text) IS
  'Refresh exact generic semantic counts outside planning';
COMMENT ON FUNCTION otlet.semantic_predicate_counts(text, jsonb, text) IS
  'Read-only exact predicate diagnostics that are never used for planning';

REVOKE ALL ON TABLE otlet.semantic_planner_statistics FROM PUBLIC;
REVOKE ALL ON TABLE otlet.semantic_planner_statistics_status FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.recompute_semantic_planner_statistics(
  text, text, bigint, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.invalidate_semantic_planner_statistics(
  text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.mark_semantic_stale_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_planner_source_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.drop_semantic_planner_source_triggers(
  text, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.install_semantic_planner_source_triggers(
  text, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.reset_semantic_planner_statistics(
  text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.maintain_semantic_planner_statistics(
  text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_planner_head_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.recompute_changed_semantic_planner_statistics()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.recompute_corrected_semantic_planner_statistics()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.recompute_constrained_semantic_planner_statistics()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.recompute_reviewed_semantic_planner_statistics()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_planner_counts(text, text, bigint)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_row_exact_counts(jsonb, text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_pair_exact_counts(jsonb, text)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.semantic_predicate_counts(text, jsonb, text)
  FROM PUBLIC;
