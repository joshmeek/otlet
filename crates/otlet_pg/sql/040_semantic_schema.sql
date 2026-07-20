CREATE TABLE otlet.semantic_materializations (
  id bigserial PRIMARY KEY,
  record_id bigint NOT NULL UNIQUE REFERENCES otlet.records(id),
  record_type text NOT NULL,
  source_table text,
  subject_id text,
  source_dependencies jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(source_dependencies) = 'array'),
  task_name text NOT NULL,
  model_name text NOT NULL,
  body jsonb NOT NULL,
  stale boolean NOT NULL DEFAULT false,
  source_hash text,
  content_hash text,
  contract_hash text,
  stale_reason text CHECK (stale_reason IN (
    'source_update',
    'source_delete',
    'candidate_removed',
    'candidate_changed',
    'contract_changed',
    'schema_drift',
    'manual',
    'content_revalidation_pending'
  )),
  freshness_basis text CHECK (freshness_basis IN (
    'content_hash_match',
    'mvcc_match',
    'revalidated_after_benign_update'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX semantic_materializations_lookup_idx
ON otlet.semantic_materializations (task_name, record_type, stale, subject_id);

CREATE INDEX semantic_materializations_subject_latest_idx
ON otlet.semantic_materializations (task_name, record_type, subject_id, updated_at DESC, id DESC);

CREATE INDEX semantic_materializations_source_delete_idx
ON otlet.semantic_materializations (updated_at, id)
WHERE stale AND stale_reason = 'source_delete';

CREATE INDEX semantic_materializations_source_idx
ON otlet.semantic_materializations (source_table, subject_id, task_name, record_type, stale);

CREATE INDEX semantic_materializations_dependencies_idx
ON otlet.semantic_materializations USING gin (source_dependencies jsonb_path_ops);

CREATE TABLE otlet.semantic_indexes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name),
  source_table text NOT NULL,
  subject_column text NOT NULL,
  input_columns text[],
  record_type text NOT NULL,
  model_name text NOT NULL REFERENCES otlet.models(name),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_refresh_at timestamptz,
  last_lookup_at timestamptz
);

CREATE TABLE otlet.semantic_join_indexes (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name),
  candidate_query text NOT NULL,
  record_type text NOT NULL,
  model_name text NOT NULL REFERENCES otlet.models(name),
  max_candidate_rows integer NOT NULL DEFAULT 1000 CHECK (max_candidate_rows BETWEEN 1 AND 100000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_refresh_at timestamptz,
  last_lookup_at timestamptz,
  last_materialized_at timestamptz
);

CREATE TABLE otlet.watches (
  name text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_-]*$'),
  kind text NOT NULL CHECK (kind IN ('row', 'pair')),
  task_name text NOT NULL UNIQUE REFERENCES otlet.tasks(name) ON DELETE CASCADE,
  semantic_index_name text UNIQUE REFERENCES otlet.semantic_indexes(name) ON DELETE SET NULL,
  semantic_join_index_name text UNIQUE REFERENCES otlet.semantic_join_indexes(name) ON DELETE SET NULL,
  source_table text,
  subject_column text,
  input_columns text[],
  pair_sources jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(pair_sources) = 'array'),
  candidate_query text,
  output_schema jsonb NOT NULL CHECK (jsonb_typeof(output_schema) = 'object'),
  action_types text[] NOT NULL DEFAULT '{}'::text[],
  stale_policy text NOT NULL DEFAULT 'refresh_then_fail_closed' CHECK (stale_policy IN (
    'lookup_only_fail_closed',
    'refresh_then_fail_closed'
  )),
  selection_policy jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(selection_policy) = 'object'),
  trigger_policy jsonb NOT NULL DEFAULT '{"on_change":"mark_stale"}'::jsonb CHECK (jsonb_typeof(trigger_policy) = 'object'),
  input_shaping jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(input_shaping) = 'object'),
  decision_contract jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(decision_contract) = 'object'),
  model_name text NOT NULL REFERENCES otlet.models(name),
  record_type text NOT NULL,
  runtime_options jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(runtime_options) = 'object'),
  max_candidate_rows integer NOT NULL DEFAULT 1000 CHECK (max_candidate_rows BETWEEN 1 AND 100000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (kind = 'row' AND semantic_index_name IS NOT NULL AND semantic_join_index_name IS NULL AND source_table IS NOT NULL AND subject_column IS NOT NULL AND pair_sources = '[]'::jsonb AND candidate_query IS NULL)
    OR
    (kind = 'pair' AND semantic_index_name IS NULL AND semantic_join_index_name IS NOT NULL AND source_table IS NULL AND subject_column IS NULL AND candidate_query IS NOT NULL)
  )
);
