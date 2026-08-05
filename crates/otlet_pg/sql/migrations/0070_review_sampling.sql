CREATE FUNCTION otlet.review_sampling_rule_error(
  review_sampling jsonb,
  output_schema jsonb,
  decision_contract jsonb
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  class_name text;
  class_rate jsonb;
  answer_field text := COALESCE(
    NULLIF(review_sampling_rule_error.decision_contract ->> 'answer_field', ''),
    'match'
  );
  answer_values text[];
BEGIN
  IF jsonb_typeof(review_sampling_rule_error.review_sampling)
       IS DISTINCT FROM 'object' THEN
    RETURN 'review_sampling must be a JSON object';
  END IF;
  IF review_sampling_rule_error.review_sampling ->> 'format'
       IS DISTINCT FROM 'otlet.review_sampling.v1' THEN
    RETURN 'review_sampling format must be otlet.review_sampling.v1';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_object_keys(review_sampling_rule_error.review_sampling) key
    WHERE key <> ALL(ARRAY[
      'format',
      'task_rate',
      'decision_class_rates',
      'action_free_rate'
    ])
  ) THEN
    RETURN 'review_sampling contains an unsupported field';
  END IF;
  IF NOT review_sampling_rule_error.review_sampling ?| ARRAY[
       'task_rate', 'decision_class_rates', 'action_free_rate'
     ] THEN
    RETURN 'review_sampling requires at least one rate';
  END IF;
  IF COALESCE(
       review_sampling_rule_error.decision_contract -> 'action_types',
       '[]'::jsonb
     ) ? 'none' THEN
    RETURN 'review_sampling reserves none for an action-free expectation';
  END IF;

  IF review_sampling_rule_error.review_sampling ? 'task_rate' THEN
    IF jsonb_typeof(review_sampling_rule_error.review_sampling -> 'task_rate')
         IS DISTINCT FROM 'number' THEN
      RETURN 'review_sampling task_rate must be between 0 and 1';
    END IF;
    IF (review_sampling_rule_error.review_sampling ->> 'task_rate')::numeric
         NOT BETWEEN 0 AND 1 THEN
      RETURN 'review_sampling task_rate must be between 0 and 1';
    END IF;
  END IF;
  IF review_sampling_rule_error.review_sampling ? 'action_free_rate' THEN
    IF jsonb_typeof(
         review_sampling_rule_error.review_sampling -> 'action_free_rate'
       ) IS DISTINCT FROM 'number' THEN
      RETURN 'review_sampling action_free_rate must be between 0 and 1';
    END IF;
    IF (
         review_sampling_rule_error.review_sampling ->> 'action_free_rate'
       )::numeric NOT BETWEEN 0 AND 1 THEN
      RETURN 'review_sampling action_free_rate must be between 0 and 1';
    END IF;
  END IF;

  IF review_sampling_rule_error.review_sampling ? 'decision_class_rates' THEN
    IF jsonb_typeof(
         review_sampling_rule_error.review_sampling -> 'decision_class_rates'
       ) IS DISTINCT FROM 'object'
       OR review_sampling_rule_error.review_sampling -> 'decision_class_rates'
         = '{}'::jsonb THEN
      RETURN 'review_sampling decision_class_rates must be a non-empty object';
    END IF;
    IF (
      SELECT count(*)
      FROM jsonb_object_keys(
        review_sampling_rule_error.review_sampling -> 'decision_class_rates'
      )
    ) > 64 THEN
      RETURN 'review_sampling exceeds 64 decision classes';
    END IF;
    IF COALESCE(
         review_sampling_rule_error.decision_contract ->
           'redact_output_fields',
         '[]'::jsonb
       ) ? answer_field THEN
      RETURN 'review_sampling decision classes cannot use a redacted answer field';
    END IF;
    answer_values := otlet.output_schema_enum_values(
      review_sampling_rule_error.output_schema,
      answer_field
    );
    IF answer_values IS NULL OR cardinality(answer_values) = 0 THEN
      RETURN 'review_sampling decision classes require an enum answer field';
    END IF;
    FOR class_name, class_rate IN
      SELECT key, value
      FROM jsonb_each(
        review_sampling_rule_error.review_sampling -> 'decision_class_rates'
      )
    LOOP
      IF NULLIF(class_name, '') IS NULL OR octet_length(class_name) > 128 THEN
        RETURN 'review_sampling decision class names must contain 1 to 128 bytes';
      END IF;
      IF NOT class_name = ANY(answer_values) THEN
        RETURN format(
          'review_sampling decision class %s is outside the answer enum',
          class_name
        );
      END IF;
      IF jsonb_typeof(class_rate) IS DISTINCT FROM 'number' THEN
        RETURN format(
          'review_sampling decision class rate for %s must be between 0 and 1',
          class_name
        );
      END IF;
      IF (class_rate #>> '{}')::numeric NOT BETWEEN 0 AND 1 THEN
        RETURN format(
          'review_sampling decision class rate for %s must be between 0 and 1',
          class_name
        );
      END IF;
    END LOOP;
  END IF;

  IF COALESCE(
       (review_sampling_rule_error.review_sampling ->> 'task_rate')::numeric,
       0
     ) = 0
     AND COALESCE(
       (
         review_sampling_rule_error.review_sampling ->> 'action_free_rate'
       )::numeric,
       0
     ) = 0
     AND NOT EXISTS (
       SELECT 1
       FROM jsonb_each(COALESCE(
         review_sampling_rule_error.review_sampling -> 'decision_class_rates',
         '{}'::jsonb
       )) rate
       WHERE (rate.value #>> '{}')::numeric > 0
     ) THEN
    RETURN 'review_sampling requires at least one positive rate';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION otlet.validate_workload_acceptance_review_sampling()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  revision_definition jsonb;
  validation_error text;
BEGIN
  IF NEW.definition #> '{population,rule,review_sampling}' IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT revision.definition
  INTO revision_definition
  FROM otlet.workload_revisions revision
  WHERE revision.task_name = NEW.task_name
    AND revision.workload_revision_hash = NEW.candidate_workload_revision_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review sampling candidate revision does not exist';
  END IF;
  validation_error := otlet.review_sampling_rule_error(
    NEW.definition #> '{population,rule,review_sampling}',
    revision_definition #> '{task,output_schema}',
    revision_definition #> '{task,decision_contract}'
  );
  IF validation_error IS NOT NULL THEN
    RAISE EXCEPTION 'otlet workload acceptance contract is invalid: %',
      validation_error;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER workload_acceptance_contracts_c_review_sampling
BEFORE INSERT ON otlet.workload_acceptance_contracts
FOR EACH ROW
EXECUTE FUNCTION otlet.validate_workload_acceptance_review_sampling();

CREATE FUNCTION otlet.review_sampling_choice(
  review_sampling jsonb,
  decision_class text,
  action_free boolean
) RETURNS TABLE (sampling_scope text, sample_rate numeric)
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT choice.sampling_scope, choice.sample_rate
  FROM (VALUES
    (
      1,
      'action_free'::text,
      CASE
        WHEN COALESCE(review_sampling_choice.action_free, false)
          AND review_sampling_choice.review_sampling ? 'action_free_rate'
        THEN (
          review_sampling_choice.review_sampling ->> 'action_free_rate'
        )::numeric
      END
    ),
    (
      2,
      'decision_class'::text,
      CASE
        WHEN review_sampling_choice.decision_class IS NOT NULL
          AND COALESCE(
            review_sampling_choice.review_sampling -> 'decision_class_rates',
            '{}'::jsonb
          ) ? review_sampling_choice.decision_class
        THEN (
          review_sampling_choice.review_sampling #>> ARRAY[
            'decision_class_rates', review_sampling_choice.decision_class
          ]
        )::numeric
      END
    ),
    (
      3,
      'task'::text,
      CASE
        WHEN review_sampling_choice.review_sampling ? 'task_rate'
        THEN (review_sampling_choice.review_sampling ->> 'task_rate')::numeric
      END
    )
  ) choice(precedence, sampling_scope, sample_rate)
  WHERE choice.sample_rate IS NOT NULL
  ORDER BY choice.precedence
  LIMIT 1
$$;

CREATE TABLE otlet.review_samples (
  sample_hash text PRIMARY KEY CHECK (
    sample_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  member_hash text NOT NULL CHECK (
    member_hash ~ '^otlet:v1:sha256:[0-9a-f]{64}$'
  ),
  contract_hash text NOT NULL,
  task_name text NOT NULL,
  workload_revision_hash text NOT NULL,
  job_id bigint NOT NULL UNIQUE REFERENCES otlet.jobs(id),
  output_id bigint NOT NULL UNIQUE REFERENCES otlet.outputs(id),
  receipt_id bigint NOT NULL UNIQUE REFERENCES otlet.inference_receipts(id),
  decision_class text CHECK (
    decision_class IS NULL
    OR (
      NULLIF(decision_class, '') IS NOT NULL
      AND octet_length(decision_class) <= 128
    )
  ),
  action_free boolean NOT NULL,
  sampling_scope text NOT NULL CHECK (
    sampling_scope IN ('task', 'decision_class', 'action_free')
  ),
  sample_rate numeric NOT NULL CHECK (sample_rate > 0 AND sample_rate <= 1),
  sample_bucket bigint NOT NULL CHECK (
    sample_bucket BETWEEN 0 AND 4294967295
  ),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  selected_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (task_name, contract_hash)
    REFERENCES otlet.workload_acceptance_contracts(task_name, contract_hash),
  FOREIGN KEY (task_name, workload_revision_hash)
    REFERENCES otlet.workload_revisions(task_name, workload_revision_hash)
);

CREATE INDEX review_samples_contract_selected_idx
ON otlet.review_samples (contract_hash, selected_at, sample_hash);

CREATE FUNCTION otlet.guard_review_sample_append() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT'
     AND current_setting('otlet.review_sample_append', true) = 'on' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'otlet review samples are append only';
END;
$$;

CREATE FUNCTION otlet.validate_review_sample() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  expected_scope text;
  expected_rate numeric;
  expected_member_hash text;
  expected_bucket bigint;
  expected_definition jsonb;
  answer_field text;
  answer_values text[];
  observed_decision_class text;
  expected_decision_class text;
BEGIN
  SELECT
    contract.definition AS contract_definition,
    contract.created_at AS contract_created_at,
    job.task_name,
    job.workload_revision_hash,
    job.execution_mode,
    job.status AS job_status,
    output.job_id AS output_job_id,
    output.receipt_id AS output_receipt_id,
    output.output AS stored_output,
    receipt.job_id AS receipt_job_id,
    receipt.status AS receipt_status,
    receipt.selection_status,
    receipt.schema_validation_status,
    receipt.output_hash,
    receipt.actions_hash,
    receipt.finished_at,
    revision.definition AS revision_definition,
    NOT EXISTS (
      SELECT 1
      FROM otlet.actions action
      WHERE action.output_id = NEW.output_id
        AND action.receipt_id = NEW.receipt_id
    ) AS action_free
  INTO source
  FROM otlet.workload_acceptance_contracts contract
  JOIN otlet.jobs job ON job.id = NEW.job_id
  JOIN otlet.outputs output ON output.id = NEW.output_id
  JOIN otlet.inference_receipts receipt ON receipt.id = NEW.receipt_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE contract.contract_hash = NEW.contract_hash
    AND contract.task_name = NEW.task_name;
  IF NOT FOUND
     OR source.task_name IS DISTINCT FROM NEW.task_name
     OR source.workload_revision_hash IS DISTINCT FROM
       NEW.workload_revision_hash
     OR source.output_job_id IS DISTINCT FROM NEW.job_id
     OR source.output_receipt_id IS DISTINCT FROM NEW.receipt_id
     OR source.receipt_job_id IS DISTINCT FROM NEW.job_id
     OR source.execution_mode IS DISTINCT FROM 'production'
     OR source.job_status IS DISTINCT FROM 'complete'
     OR source.receipt_status IS DISTINCT FROM 'complete'
     OR source.selection_status IS DISTINCT FROM 'accepted'
     OR source.schema_validation_status IS DISTINCT FROM 'passed'
     OR source.action_free IS DISTINCT FROM NEW.action_free
     OR source.contract_definition ->> 'candidate_workload_revision_hash'
       IS DISTINCT FROM NEW.workload_revision_hash
     OR source.contract_created_at > source.finished_at
     OR source.finished_at < (
       source.contract_definition #>> '{observation_window,starts_at}'
     )::timestamptz
     OR source.finished_at >= (
       source.contract_definition #>> '{observation_window,ends_at}'
     )::timestamptz
     OR EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_contracts successor
       WHERE successor.task_name = NEW.task_name
         AND successor.supersedes_contract_hash = NEW.contract_hash
         AND successor.created_at <= source.finished_at
     )
     OR EXISTS (
       SELECT 1
       FROM otlet.workload_acceptance_contracts other
       WHERE other.task_name = NEW.task_name
         AND other.contract_hash <> NEW.contract_hash
         AND other.candidate_workload_revision_hash =
           NEW.workload_revision_hash
         AND other.created_at <= source.finished_at
         AND source.finished_at >= (
           other.definition #>> '{observation_window,starts_at}'
         )::timestamptz
         AND source.finished_at < (
           other.definition #>> '{observation_window,ends_at}'
         )::timestamptz
         AND other.definition #> '{population,rule,review_sampling}'
           IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM otlet.workload_acceptance_contracts successor
           WHERE successor.task_name = other.task_name
             AND successor.supersedes_contract_hash = other.contract_hash
             AND successor.created_at <= source.finished_at
         )
     ) THEN
    RAISE EXCEPTION 'otlet review sample evidence is inconsistent';
  END IF;

  answer_field := COALESCE(NULLIF(
    source.revision_definition #>> '{task,decision_contract,answer_field}',
    ''
  ), 'match');
  answer_values := otlet.output_schema_enum_values(
    source.revision_definition #> '{task,output_schema}',
    answer_field
  );
  IF answer_values IS NOT NULL
     AND NOT COALESCE(
       source.revision_definition #>
         '{task,decision_contract,redact_output_fields}',
       '[]'::jsonb
     ) ? answer_field THEN
    observed_decision_class := NULLIF(
      source.stored_output ->> answer_field,
      ''
    );
  END IF;

  SELECT choice.sampling_scope, choice.sample_rate
  INTO expected_scope, expected_rate
  FROM otlet.review_sampling_choice(
    source.contract_definition #> '{population,rule,review_sampling}',
    observed_decision_class,
    NEW.action_free
  ) choice;
  expected_decision_class := CASE
    WHEN expected_scope = 'decision_class' THEN observed_decision_class
  END;
  IF NEW.decision_class IS DISTINCT FROM expected_decision_class THEN
    RAISE EXCEPTION 'otlet review sample decision class is invalid';
  END IF;
  expected_member_hash := otlet.identity_hash(
    'review_sampling_member',
    jsonb_build_object(
      'contract_hash', NEW.contract_hash,
      'task_name', NEW.task_name,
      'workload_revision_hash', NEW.workload_revision_hash,
      'receipt_id', NEW.receipt_id,
      'output_hash', source.output_hash,
      'actions_hash', source.actions_hash
    )
  );
  expected_bucket := (
    ('x' || substring(expected_member_hash FROM 17 FOR 8))::bit(32)::bigint
  );
  expected_definition := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.review_sample.v1',
    'member_hash', expected_member_hash,
    'contract_hash', NEW.contract_hash,
    'task_name', NEW.task_name,
    'workload_revision_hash', NEW.workload_revision_hash,
    'job_id', NEW.job_id,
    'output_id', NEW.output_id,
    'receipt_id', NEW.receipt_id,
    'decision_class', NEW.decision_class,
    'action_free', NEW.action_free,
    'sampling_scope', expected_scope,
    'sample_rate', expected_rate,
    'sample_bucket', expected_bucket
  ));
  IF expected_scope IS NULL
     OR expected_rate IS NULL
     OR expected_rate <= 0
     OR expected_bucket::numeric >= expected_rate * 4294967296::numeric
     OR NEW.member_hash IS DISTINCT FROM expected_member_hash
     OR NEW.sampling_scope IS DISTINCT FROM expected_scope
     OR NEW.sample_rate IS DISTINCT FROM expected_rate
     OR NEW.sample_bucket IS DISTINCT FROM expected_bucket
     OR NEW.definition IS DISTINCT FROM expected_definition
     OR NEW.sample_hash IS DISTINCT FROM
       otlet.identity_hash('review_sample', expected_definition) THEN
    RAISE EXCEPTION 'otlet review sample identity is invalid';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER review_samples_a_guard
BEFORE INSERT OR UPDATE OR DELETE ON otlet.review_samples
FOR EACH ROW EXECUTE FUNCTION otlet.guard_review_sample_append();

CREATE TRIGGER review_samples_b_validate
BEFORE INSERT ON otlet.review_samples
FOR EACH ROW EXECUTE FUNCTION otlet.validate_review_sample();

CREATE TRIGGER review_samples_truncate_guard
BEFORE TRUNCATE ON otlet.review_samples
FOR EACH STATEMENT EXECUTE FUNCTION otlet.guard_review_sample_append();

CREATE FUNCTION otlet.record_review_sample(
  output_id bigint,
  output jsonb
) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  review_sampling jsonb;
  answer_field text;
  answer_values text[];
  observed_decision_class text;
  decision_class text;
  action_free boolean;
  sampling_scope text;
  sample_rate numeric;
  member_hash text;
  sample_bucket bigint;
  definition jsonb;
  sample_hash text;
  previous_append text := current_setting('otlet.review_sample_append', true);
BEGIN
  SELECT
    job.id AS job_id,
    job.task_name,
    job.workload_revision_hash,
    job.execution_mode,
    output_row.receipt_id,
    receipt.output_hash,
    receipt.actions_hash,
    receipt.finished_at,
    revision.definition AS revision_definition,
    NULL::text AS contract_hash,
    NULL::jsonb AS contract_definition,
    NULL::bigint AS candidate_count
  INTO source
  FROM otlet.outputs output_row
  JOIN otlet.jobs job ON job.id = output_row.job_id
  JOIN otlet.inference_receipts receipt
    ON receipt.id = output_row.receipt_id
   AND receipt.job_id = job.id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  WHERE output_row.id = record_review_sample.output_id
    AND job.execution_mode = 'production'
    AND job.status = 'complete'
    AND receipt.status = 'complete'
    AND receipt.selection_status = 'accepted'
    AND receipt.schema_validation_status = 'passed';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review sample requires accepted production evidence';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'otlet_workload_acceptance:' || source.task_name,
    0
  ));
  SELECT
    candidate.contract_hash,
    candidate.definition,
    candidate.candidate_count
  INTO source.contract_hash, source.contract_definition, source.candidate_count
  FROM (
    SELECT
      contract.contract_hash,
      contract.definition,
      count(*) OVER () AS candidate_count
    FROM otlet.workload_acceptance_contracts contract
    WHERE contract.task_name = source.task_name
      AND contract.candidate_workload_revision_hash =
        source.workload_revision_hash
      AND contract.created_at <= source.finished_at
      AND source.finished_at >= (
        contract.definition #>> '{observation_window,starts_at}'
      )::timestamptz
      AND source.finished_at < (
        contract.definition #>> '{observation_window,ends_at}'
      )::timestamptz
      AND contract.definition #> '{population,rule,review_sampling}'
        IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.workload_acceptance_contracts successor
        WHERE successor.task_name = contract.task_name
          AND successor.supersedes_contract_hash = contract.contract_hash
          AND successor.created_at <= source.finished_at
      )
    ORDER BY contract.created_at DESC, contract.contract_hash
  ) candidate
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF source.candidate_count IS DISTINCT FROM 1::bigint THEN
    RAISE EXCEPTION 'otlet review sampling contract is ambiguous';
  END IF;

  review_sampling := source.contract_definition #>
    '{population,rule,review_sampling}';
  answer_field := COALESCE(NULLIF(
    source.revision_definition #>> '{task,decision_contract,answer_field}',
    ''
  ), 'match');
  answer_values := otlet.output_schema_enum_values(
    source.revision_definition #> '{task,output_schema}',
    answer_field
  );
  IF COALESCE(
       source.revision_definition #>
         '{task,decision_contract,redact_output_fields}',
       '[]'::jsonb
     ) ? answer_field THEN
    observed_decision_class := NULL;
  ELSE
    observed_decision_class := NULLIF(
      record_review_sample.output ->> answer_field,
      ''
    );
    IF answer_values IS NULL THEN
      observed_decision_class := NULL;
    ELSIF observed_decision_class IS NOT NULL
       AND NOT observed_decision_class = ANY(answer_values) THEN
      RAISE EXCEPTION 'otlet review sample decision class is outside the answer enum';
    END IF;
  END IF;
  action_free := NOT EXISTS (
    SELECT 1
    FROM otlet.actions action
    WHERE action.output_id = record_review_sample.output_id
      AND action.receipt_id = source.receipt_id
  );
  SELECT choice.sampling_scope, choice.sample_rate
  INTO sampling_scope, sample_rate
  FROM otlet.review_sampling_choice(
    review_sampling,
    observed_decision_class,
    action_free
  ) choice;
  IF NOT FOUND OR sample_rate = 0 THEN
    RETURN NULL;
  END IF;
  decision_class := CASE
    WHEN sampling_scope = 'decision_class' THEN observed_decision_class
  END;

  member_hash := otlet.identity_hash(
    'review_sampling_member',
    jsonb_build_object(
      'contract_hash', source.contract_hash,
      'task_name', source.task_name,
      'workload_revision_hash', source.workload_revision_hash,
      'receipt_id', source.receipt_id,
      'output_hash', source.output_hash,
      'actions_hash', source.actions_hash
    )
  );
  sample_bucket := (
    ('x' || substring(member_hash FROM 17 FOR 8))::bit(32)::bigint
  );
  IF sample_bucket::numeric >= sample_rate * 4294967296::numeric THEN
    RETURN NULL;
  END IF;

  definition := jsonb_strip_nulls(jsonb_build_object(
    'format', 'otlet.review_sample.v1',
    'member_hash', member_hash,
    'contract_hash', source.contract_hash,
    'task_name', source.task_name,
    'workload_revision_hash', source.workload_revision_hash,
    'job_id', source.job_id,
    'output_id', record_review_sample.output_id,
    'receipt_id', source.receipt_id,
    'decision_class', decision_class,
    'action_free', action_free,
    'sampling_scope', sampling_scope,
    'sample_rate', sample_rate,
    'sample_bucket', sample_bucket
  ));
  sample_hash := otlet.identity_hash('review_sample', definition);
  PERFORM set_config('otlet.review_sample_append', 'on', true);
  INSERT INTO otlet.review_samples (
    sample_hash,
    member_hash,
    contract_hash,
    task_name,
    workload_revision_hash,
    job_id,
    output_id,
    receipt_id,
    decision_class,
    action_free,
    sampling_scope,
    sample_rate,
    sample_bucket,
    definition
  ) VALUES (
    sample_hash,
    member_hash,
    source.contract_hash,
    source.task_name,
    source.workload_revision_hash,
    source.job_id,
    record_review_sample.output_id,
    source.receipt_id,
    decision_class,
    action_free,
    sampling_scope,
    sample_rate,
    sample_bucket,
    definition
  );
  PERFORM set_config(
    'otlet.review_sample_append',
    COALESCE(previous_append, ''),
    true
  );
  RETURN sample_hash;
END;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.complete_job(bigint,jsonb,text,jsonb,text,text,text,text,timestamptz,jsonb,text,text,text,text,text,text,text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$  END LOOP;

  UPDATE otlet.inference_receipts r$needle$ IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling completion rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$  END LOOP;

  UPDATE otlet.inference_receipts r$needle$,
    $replacement$  END LOOP;

  PERFORM otlet.record_review_sample(saved_output.id, complete_job.output);

  UPDATE otlet.inference_receipts r$replacement$
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
  dry_run_guard text := $guard$        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = status.task_name
            AND member.source_table IS NOT DISTINCT FROM status.source_table
            AND member.subject_id = status.subject_id
        )$guard$;
  live_guard text := $guard$      AND NOT EXISTS (
        SELECT 1
        FROM otlet.eval_labels member
        JOIN otlet.evaluation_cases evaluation_case
          ON evaluation_case.label_id = member.id
        WHERE member.task_name = status.task_name
          AND member.source_table IS NOT DISTINCT FROM status.source_table
          AND member.subject_id = status.subject_id
      )$guard$;
  series_guard text := $guard$        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.evaluation_cases evaluation_case
            ON evaluation_case.label_id = member.id
          WHERE member.task_name = series.task_name
            AND member.source_table IS NOT DISTINCT FROM series.source_table
            AND member.subject_id = series.subject_id
        )$guard$;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.cleanup_eval_label_series(timestamptz,boolean)'::regprocedure
  ) INTO definition;
  IF position(dry_run_guard IN definition) = 0
     OR position(live_guard IN definition) = 0
     OR position(series_guard IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling label retention rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    dry_run_guard,
    dry_run_guard || $guard$
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.review_samples sample
            ON sample.receipt_id = member.receipt_id
          WHERE member.task_name = status.task_name
            AND member.source_table IS NOT DISTINCT FROM status.source_table
            AND member.subject_id = status.subject_id
        )$guard$
  );
  definition := pg_catalog.replace(
    definition,
    live_guard,
    live_guard || $guard$
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.eval_labels member
        JOIN otlet.review_samples sample
          ON sample.receipt_id = member.receipt_id
        WHERE member.task_name = status.task_name
          AND member.source_table IS NOT DISTINCT FROM status.source_table
          AND member.subject_id = status.subject_id
      )$guard$
  );
  EXECUTE pg_catalog.replace(
    definition,
    series_guard,
    series_guard || $guard$
        AND NOT EXISTS (
          SELECT 1
          FROM otlet.eval_labels member
          JOIN otlet.review_samples sample
            ON sample.receipt_id = member.receipt_id
          WHERE member.task_name = series.task_name
            AND member.source_table IS NOT DISTINCT FROM series.source_table
            AND member.subject_id = series.subject_id
        )$guard$
  );
END;
$migration$;

ALTER VIEW otlet.review_queue
RENAME TO review_queue_without_review_samples;

CREATE VIEW otlet.review_queue AS
SELECT queue.*
FROM otlet.review_queue_without_review_samples queue
UNION ALL
SELECT
  'sampled_output'::text,
  'label_sample'::text,
  sample.task_name,
  sample.workload_revision_hash,
  COALESCE(
    revision.definition #>> '{source,watch_name}',
    revision.definition #>> '{source,semantic_index_name}',
    revision.definition #>> '{source,semantic_join_index_name}'
  ),
  job.subject_id,
  job.subject_id,
  NULL::bigint,
  sample.output_id,
  sample.receipt_id,
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
  format(
    '%s review sample at rate %s',
    sample.sampling_scope,
    sample.sample_rate
  ),
  output.output,
  COALESCE(
    job.input #>> '{_otlet_mvcc,table}',
    job.input #>> '{otlet_mvcc,table}',
    revision.definition #>> '{source,source_table}',
    receipt.trace_summary #>> '{mvcc,table}'
  ),
  otlet.semantic_source_hash(job.input),
  otlet.semantic_content_hash(
    job.input,
    revision.definition #> '{task,input_shaping}'
  ),
  COALESCE(
    current_materialization.content_hash,
    otlet.semantic_content_hash(
      job.input,
      revision.definition #> '{task,input_shaping}'
    )
  ),
  (
    COALESCE(current_materialization.stale, false)
    OR (
      current_materialization.content_hash IS NOT NULL
      AND current_materialization.content_hash IS DISTINCT FROM
        otlet.semantic_content_hash(
          job.input,
          revision.definition #> '{task,input_shaping}'
        )
    )
  ),
  sample.selected_at
FROM otlet.review_samples sample
JOIN otlet.jobs job ON job.id = sample.job_id
JOIN otlet.outputs output ON output.id = sample.output_id
JOIN otlet.inference_receipts receipt ON receipt.id = sample.receipt_id
JOIN otlet.workload_revisions revision
  ON revision.task_name = sample.task_name
 AND revision.workload_revision_hash = sample.workload_revision_hash
LEFT JOIN LATERAL (
  SELECT materialization.content_hash, materialization.stale
  FROM otlet.semantic_materializations_effective materialization
  WHERE materialization.task_name = sample.task_name
    AND materialization.subject_id = job.subject_id
    AND materialization.contract_hash = sample.workload_revision_hash
    AND materialization.record_type IS NOT DISTINCT FROM
      revision.definition #>> '{source,record_type}'
  ORDER BY materialization.updated_at DESC, materialization.id DESC
  LIMIT 1
) current_materialization ON true
WHERE NOT EXISTS (
    SELECT 1
    FROM otlet.review_queue_without_review_samples required_review
    WHERE required_review.receipt_id = sample.receipt_id
  )
  AND NOT EXISTS (
    SELECT 1
    FROM otlet.eval_labels label
    WHERE label.receipt_id = sample.receipt_id
      AND label.label_source = 'manual_correction'
      AND label.adjudication_state <> 'rejected'
      AND NOT EXISTS (
        SELECT 1
        FROM otlet.eval_labels successor
        WHERE successor.supersedes_label_id = label.id
      )
  )
ORDER BY created_at, task_name, job_subject_id, queue_kind;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.audit_review_export'::regclass,
    true
  );
  IF position('otlet.review_queue_without_review_samples' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling audit queue rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.audit_review_export AS ' ||
    pg_catalog.replace(
      definition,
      'otlet.review_queue_without_review_samples',
      'otlet.review_queue'
    );
END;
$migration$;

CREATE VIEW otlet.audit_review_sample_export AS
SELECT
  sample.sample_hash,
  sample.member_hash,
  sample.contract_hash,
  sample.task_name,
  sample.workload_revision_hash,
  sample.job_id,
  sample.output_id,
  sample.receipt_id,
  job.subject_id,
  sample.decision_class,
  sample.action_free,
  sample.sampling_scope,
  sample.sample_rate,
  sample.sample_bucket,
  receipt.output_hash,
  receipt.actions_hash,
  sample.selected_at,
  label.label_id,
  label.expected_answer,
  label.expected_confidence,
  label.expected_action_type,
  label.adjudication_state,
  label.label_confidence,
  label.adjudication_reason,
  label.adjudicated_at,
  evaluation_case.case_hash AS evaluation_case_hash,
  evaluation_case.population_kind AS evaluation_population,
  CASE
    WHEN label.label_id IS NULL THEN 'pending_review'
    WHEN label.adjudication_state = 'pending' THEN 'pending_adjudication'
    WHEN label.adjudication_state = 'accepted' THEN 'accepted_label'
    ELSE 'rejected_label'
  END AS review_state
FROM otlet.review_samples sample
JOIN otlet.jobs job ON job.id = sample.job_id
JOIN otlet.inference_receipts receipt ON receipt.id = sample.receipt_id
LEFT JOIN LATERAL (
  SELECT status.*
  FROM otlet.eval_label_status status
  WHERE status.receipt_id = sample.receipt_id
    AND status.label_source = 'manual_correction'
    AND status.current_label
  ORDER BY status.label_revision DESC, status.label_id DESC
  LIMIT 1
) label ON true
LEFT JOIN otlet.evaluation_cases evaluation_case
  ON evaluation_case.label_id = label.label_id;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.redaction_policy_status'::regclass,
    true
  );
  IF position(
    '''otlet.audit_decision_evidence_export''::text' IN definition
  ) = 0 OR position('4 AS policy_version' IN definition) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling redaction registry rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    '''otlet.audit_decision_evidence_export''::text',
    '''otlet.audit_review_sample_export''::text, ' ||
      '''otlet.audit_decision_evidence_export''::text'
  );
  EXECUTE 'CREATE OR REPLACE VIEW otlet.redaction_policy_status AS ' ||
    pg_catalog.replace(definition, '4 AS policy_version', '5 AS policy_version');
END;
$migration$;

REVOKE ALL ON TABLE otlet.review_samples FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue_without_review_samples FROM PUBLIC;
REVOKE ALL ON TABLE otlet.review_queue FROM PUBLIC;
REVOKE ALL ON TABLE otlet.audit_review_sample_export FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_sampling_rule_error(
  jsonb, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
  otlet.validate_workload_acceptance_review_sampling() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.review_sampling_choice(
  jsonb, text, boolean
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.guard_review_sample_append() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.validate_review_sample() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_review_sample(bigint, jsonb)
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.complete_job(
  bigint, jsonb, text, jsonb, text, text, text, text, timestamptz,
  jsonb, text, text, text, text, text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.populate_eval_label_provenance()
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.export_eval_cases(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_evaluation_result(
  bigint, bigint, bigint, jsonb, jsonb
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.record_production_model_qualification(
  text, text, text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION otlet.finish_access_policy_grant(
  text, regrole, text
) FROM PUBLIC;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.populate_eval_label_provenance()'::regprocedure
  ) INTO definition;
  IF position(
    $needle$  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  JOIN otlet.inference_receipts receipt ON receipt.id = action.receipt_id
  WHERE action.id = NEW.action_id
    AND action.output_id IS NOT DISTINCT FROM NEW.output_id
    AND action.receipt_id IS NOT DISTINCT FROM NEW.receipt_id;$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling label provenance rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$  FROM otlet.actions action
  JOIN otlet.jobs job ON job.id = action.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  JOIN otlet.inference_receipts receipt ON receipt.id = action.receipt_id
  WHERE action.id = NEW.action_id
    AND action.output_id IS NOT DISTINCT FROM NEW.output_id
    AND action.receipt_id IS NOT DISTINCT FROM NEW.receipt_id;$needle$,
    $replacement$  FROM otlet.inference_receipts receipt
  JOIN otlet.jobs job ON job.id = receipt.job_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = job.task_name
   AND revision.workload_revision_hash = job.workload_revision_hash
  JOIN otlet.outputs output
    ON output.id = NEW.output_id
   AND output.receipt_id = receipt.id
   AND output.job_id = job.id
  LEFT JOIN otlet.actions action
    ON action.id = NEW.action_id
   AND action.output_id = output.id
   AND action.receipt_id = receipt.id
   AND action.job_id = job.id
  WHERE receipt.id = NEW.receipt_id
    AND (NEW.action_id IS NULL OR action.id IS NOT NULL);$replacement$
  );
END;
$migration$;

CREATE FUNCTION otlet.label_review_sample(
  receipt_id bigint,
  expected_answer text,
  expected_confidence text,
  expected_action_type text,
  review_outcome text,
  reason text
) RETURNS SETOF otlet.eval_labels
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, otlet, pg_temp
AS $$
DECLARE
  source record;
  answer_field text;
  answer_values text[];
  answer_redacted boolean;
  observed_answer text;
  confidence_field text;
  confidence_redacted boolean;
  observed_confidence text;
  existing_label otlet.eval_labels%ROWTYPE;
  saved_label otlet.eval_labels%ROWTYPE;
BEGIN
  IF NULLIF(btrim(label_review_sample.expected_answer), '') IS NULL
     OR octet_length(label_review_sample.expected_answer) > 512
     OR label_review_sample.expected_confidence NOT IN ('high', 'medium', 'low')
     OR NULLIF(btrim(label_review_sample.expected_action_type), '') IS NULL
     OR octet_length(label_review_sample.expected_action_type) > 128
     OR label_review_sample.review_outcome NOT IN ('approve', 'correct')
     OR NULLIF(btrim(label_review_sample.reason), '') IS NULL
     OR octet_length(label_review_sample.reason) > 4096 THEN
    RAISE EXCEPTION 'otlet review sample label is invalid';
  END IF;

  SELECT
    sample.sample_hash,
    sample.action_free,
    sample.output_id,
    sample.receipt_id,
    output.output AS stored_output,
    job.task_name,
    job.workload_revision_hash,
    job.subject_id,
    revision.definition AS revision_definition
  INTO source
  FROM otlet.review_samples sample
  JOIN otlet.inference_receipts receipt ON receipt.id = sample.receipt_id
  JOIN otlet.jobs job ON job.id = sample.job_id
  JOIN otlet.outputs output ON output.id = sample.output_id
  JOIN otlet.workload_revisions revision
    ON revision.task_name = sample.task_name
   AND revision.workload_revision_hash = sample.workload_revision_hash
  WHERE sample.receipt_id = label_review_sample.receipt_id
    AND receipt.job_id = job.id
    AND output.job_id = job.id
    AND output.receipt_id = receipt.id
  FOR UPDATE OF sample;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review sample does not exist';
  END IF;

  SELECT label.*
  INTO existing_label
  FROM otlet.eval_labels label
  WHERE label.receipt_id = source.receipt_id
    AND label.label_source = 'manual_correction'
    AND label.adjudication_state <> 'rejected'
    AND NOT EXISTS (
      SELECT 1
      FROM otlet.eval_labels successor
      WHERE successor.supersedes_label_id = label.id
    )
  ORDER BY label.label_revision DESC, label.id DESC
  LIMIT 1;
  IF FOUND THEN
    IF existing_label.action_id IS NULL
       AND existing_label.output_id = source.output_id
       AND existing_label.expected_answer =
         btrim(label_review_sample.expected_answer)
       AND existing_label.expected_confidence =
         label_review_sample.expected_confidence
       AND existing_label.expected_action_type =
         btrim(label_review_sample.expected_action_type)
       AND existing_label.reason = btrim(label_review_sample.reason) THEN
      IF EXISTS (
        SELECT 1
        FROM otlet.review_events event
        WHERE event.receipt_id = source.receipt_id
          AND event.output_id = source.output_id
          AND event.action_id IS NULL
          AND event.outcome = label_review_sample.review_outcome
          AND event.reason = btrim(label_review_sample.reason)
          AND event.id = (
            SELECT latest.id
            FROM otlet.review_events latest
            WHERE latest.receipt_id = source.receipt_id
              AND latest.output_id = source.output_id
              AND latest.action_id IS NULL
            ORDER BY latest.id DESC
            LIMIT 1
          )
      ) THEN
        RETURN NEXT existing_label;
        RETURN;
      END IF;
      RAISE EXCEPTION 'otlet review sample already has a different outcome';
    END IF;
    RAISE EXCEPTION 'otlet review sample already has a different label';
  END IF;

  PERFORM 1
  FROM otlet.review_queue queue
  WHERE queue.receipt_id = source.receipt_id
    AND queue.queue_kind = 'sampled_output';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'otlet review sample is not eligible for sampled review';
  END IF;

  answer_field := COALESCE(NULLIF(
    source.revision_definition #>> '{task,decision_contract,answer_field}',
    ''
  ), 'match');
  answer_values := otlet.output_schema_enum_values(
    source.revision_definition #> '{task,output_schema}',
    answer_field
  );
  answer_redacted := COALESCE(
    source.revision_definition #>
      '{task,decision_contract,redact_output_fields}',
    '[]'::jsonb
  ) ? answer_field;
  IF NOT answer_redacted THEN
    observed_answer := source.stored_output ->> answer_field;
  END IF;
  IF answer_values IS NOT NULL
     AND NOT btrim(label_review_sample.expected_answer) = ANY(answer_values) THEN
    RAISE EXCEPTION 'otlet review sample expected answer is invalid';
  END IF;
  IF btrim(label_review_sample.expected_action_type) <> 'none'
     AND NOT COALESCE(
       source.revision_definition #> '{task,decision_contract,action_types}',
       '[]'::jsonb
     ) ? btrim(label_review_sample.expected_action_type) THEN
    RAISE EXCEPTION 'otlet review sample expected action type is invalid';
  END IF;
  confidence_field := COALESCE(NULLIF(
    source.revision_definition #>>
      '{task,decision_contract,confidence_field}',
    ''
  ), 'confidence');
  confidence_redacted := COALESCE(
       source.revision_definition #>
         '{task,decision_contract,redact_output_fields}',
       '[]'::jsonb
     ) ? confidence_field;
  IF NOT confidence_redacted THEN
    observed_confidence := source.stored_output ->> confidence_field;
  END IF;
  IF label_review_sample.review_outcome = 'approve'
     AND (
       answer_redacted
       OR confidence_redacted
       OR btrim(label_review_sample.expected_answer) IS DISTINCT FROM
         observed_answer
       OR observed_confidence IS DISTINCT FROM
         label_review_sample.expected_confidence
       OR (
         btrim(label_review_sample.expected_action_type) = 'none'
         AND NOT source.action_free
       )
       OR (
         btrim(label_review_sample.expected_action_type) <> 'none'
         AND (
           (
             SELECT count(*)
             FROM otlet.actions action
             WHERE action.output_id = source.output_id
               AND action.receipt_id = source.receipt_id
           ) <> 1
           OR NOT EXISTS (
             SELECT 1
             FROM otlet.actions action
             WHERE action.output_id = source.output_id
               AND action.receipt_id = source.receipt_id
               AND action.action_type =
                 btrim(label_review_sample.expected_action_type)
               AND action.status <> 'rejected'
               AND action.approval_status <> 'rejected'
               AND action.error IS NULL
           )
         )
       )
     ) THEN
    RAISE EXCEPTION 'otlet approved review sample does not match its evidence';
  END IF;

  INSERT INTO otlet.eval_labels (
    action_id,
    output_id,
    receipt_id,
    subject_id,
    expected_answer,
    expected_confidence,
    expected_action_type,
    label_source,
    reason
  ) VALUES (
    NULL,
    source.output_id,
    source.receipt_id,
    source.subject_id,
    btrim(label_review_sample.expected_answer),
    label_review_sample.expected_confidence,
    btrim(label_review_sample.expected_action_type),
    'manual_correction',
    btrim(label_review_sample.reason)
  )
  RETURNING * INTO saved_label;
  PERFORM otlet.record_review_event(
    label_review_sample.review_outcome,
    NULL,
    source.receipt_id,
    btrim(label_review_sample.reason)
  );
  RETURN NEXT saved_label;
END;
$$;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.eval_label_status'::regclass,
    true
  );
  IF position(
    'LEFT JOIN otlet.jobs job ON job.id = action.job_id' IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling label status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.eval_label_status AS ' ||
    pg_catalog.replace(
      definition,
      'LEFT JOIN otlet.jobs job ON job.id = action.job_id',
      'LEFT JOIN otlet.jobs job ON job.id = (' ||
        'SELECT target.job_id FROM otlet.inference_receipts target ' ||
        'WHERE target.id = label.receipt_id)'
    );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.export_eval_cases(integer)'::regprocedure
  ) INTO definition;
  IF position(
    'LEFT JOIN otlet.jobs job ON job.id = action.job_id' IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling evaluation export rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    'LEFT JOIN otlet.jobs job ON job.id = action.job_id',
    'LEFT JOIN otlet.jobs job ON job.id = (' ||
      'SELECT target.job_id FROM otlet.inference_receipts target ' ||
      'WHERE target.id = label.receipt_id)'
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.record_evaluation_result(bigint,bigint,bigint,jsonb,jsonb)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$  expected_action_present := evaluation_case.expected_action_type = ANY(valid_action_types);$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling evaluation result rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$  expected_action_present := evaluation_case.expected_action_type = ANY(valid_action_types);$needle$,
    $replacement$  expected_action_present := CASE
    WHEN evaluation_case.expected_action_type = 'none'
      AND EXISTS (
        SELECT 1
        FROM otlet.eval_labels label
        JOIN otlet.review_samples sample
          ON sample.receipt_id = label.receipt_id
        WHERE label.id = evaluation_case.label_id
      ) THEN
      cardinality(proposed_action_types) = 0
      AND cardinality(valid_action_types) = 0
    ELSE evaluation_case.expected_action_type = ANY(valid_action_types)
  END;$replacement$
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.record_production_model_qualification(text,text,text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$        OR result.approval_diff -> 'valid_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)
        OR result.approval_diff -> 'proposed_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling qualification rewrite is incomplete';
  END IF;
  EXECUTE pg_catalog.replace(
    definition,
    $needle$        OR result.approval_diff -> 'valid_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)
        OR result.approval_diff -> 'proposed_action_types'
          IS DISTINCT FROM jsonb_build_array(evaluation_case.expected_action_type)$needle$,
    $replacement$        OR result.approval_diff -> 'valid_action_types'
          IS DISTINCT FROM CASE
            WHEN evaluation_case.expected_action_type = 'none'
              AND EXISTS (
                SELECT 1
                FROM otlet.eval_labels label
                JOIN otlet.review_samples sample
                  ON sample.receipt_id = label.receipt_id
                WHERE label.id = evaluation_case.label_id
              ) THEN '[]'::jsonb
            ELSE jsonb_build_array(evaluation_case.expected_action_type)
          END
        OR result.approval_diff -> 'proposed_action_types'
          IS DISTINCT FROM CASE
            WHEN evaluation_case.expected_action_type = 'none'
              AND EXISTS (
                SELECT 1
                FROM otlet.eval_labels label
                JOIN otlet.review_samples sample
                  ON sample.receipt_id = label.receipt_id
                WHERE label.id = evaluation_case.label_id
              ) THEN '[]'::jsonb
            ELSE jsonb_build_array(evaluation_case.expected_action_type)
          END$replacement$
  );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_catalog.pg_get_viewdef(
    'otlet.access_policy_status'::regclass,
    true
  );
  IF position(
    $needle$'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamp with time zone,numeric,text,text)'::regprocedure::oid])$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling access status rewrite is incomplete';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW otlet.access_policy_status AS ' ||
    pg_catalog.replace(
      definition,
      $needle$'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamp with time zone,numeric,text,text)'::regprocedure::oid])$needle$,
      $replacement$'otlet.approve_semantic_correction(bigint,bigint,jsonb,timestamp with time zone,numeric,text,text)'::regprocedure::oid, 'otlet.label_review_sample(bigint,text,text,text,text,text)'::regprocedure::oid])$replacement$
    );
END;
$migration$;

DO $migration$
DECLARE
  definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'otlet.finish_access_policy_grant(text,regrole,text)'::regprocedure
  ) INTO definition;
  IF position(
    $needle$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export TO %I'$needle$ IN definition
  ) = 0 OR position(
    $needle$'otlet.semantic_correction_status_for_task(text) TO %I'$needle$
    IN definition
  ) = 0 OR position(
    $needle$'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text) TO %I'$needle$
    IN definition
  ) = 0 THEN
    RAISE EXCEPTION 'otlet review sampling access grant rewrite is incomplete';
  END IF;
  definition := pg_catalog.replace(
    definition,
    $needle$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export TO %I'$needle$,
    $replacement$'otlet.audit_administrative_change_export, '
      'otlet.audit_semantic_correction_export, '
      'otlet.audit_decision_evidence_export, '
      'otlet.audit_review_sample_export TO %I'$replacement$
  );
  definition := pg_catalog.replace(
    definition,
    $needle$'otlet.semantic_correction_status_for_task(text) TO %I'$needle$,
    $replacement$'otlet.semantic_correction_status_for_task(text), '
      'otlet.pair_constraint_contract_hash(jsonb) TO %I'$replacement$
  );
  EXECUTE pg_catalog.replace(
    definition,
    $needle$'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text) TO %I'$needle$,
    $replacement$'otlet.approve_semantic_correction('
      'bigint,bigint,jsonb,timestamptz,numeric,text,text), '
      'otlet.label_review_sample(bigint,text,text,text,text,text) TO %I'$replacement$
  );
END;
$migration$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name
        FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) IN ('auditor', 'operator')
      AND pg_catalog.has_table_privilege(
        role.oid,
        'otlet.audit_review_export',
        'SELECT'
      )
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT SELECT ON TABLE otlet.audit_review_sample_export TO %I',
      role_name
    );
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION '
      'otlet.pair_constraint_contract_hash(jsonb) TO %I',
      role_name
    );
  END LOOP;

  FOR role_name IN
    SELECT DISTINCT role.rolname
    FROM otlet.administrative_change_events event
    JOIN pg_catalog.pg_roles role
      ON role.rolname = substring(
        event.object_name
        FROM position(':' IN event.object_name) + 1
      )
    WHERE event.object_type = 'access_policy'
      AND split_part(event.object_name, ':', 1) = 'operator'
      AND pg_catalog.has_function_privilege(
        role.oid,
        'otlet.correct_action(bigint,jsonb,text)',
        'EXECUTE'
      )
  LOOP
    EXECUTE pg_catalog.format(
      'GRANT EXECUTE ON FUNCTION ' ||
      'otlet.label_review_sample(bigint,text,text,text,text,text) TO %I',
      role_name
    );
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION otlet.label_review_sample(
  bigint, text, text, text, text, text
) FROM PUBLIC;
