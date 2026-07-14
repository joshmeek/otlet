# Semantic Watches

Use this guide to extend the direct entity-resolution walkthrough into reusable semantic state through jobs, receipts, outputs, actions, materializations, and freshness checks

The vendor-pair demo covers the end-to-end path. Smaller learning tables isolate each transfer pattern

This administrative walkthrough runs as the extension owner because it creates watches, reads raw status and receipt views, and changes source fixtures. Auditors use the redacted exports; action reviewers receive the operator capability described in [production-contract.md](production-contract.md)

Watch jobs keep active source input owner-only. Derived receipts follow the same redacted storage policy as direct jobs: hashes and numeric traces remain, while assembled prompts, raw model text, and token text stay out of production storage

## Step 1 - Choose Direct Task Or Semantic Index

The direct task path gives you the shortest way to learn Otlet

Semantic indexes add repeated lookup over source rows, stale-row tracking, refresh decisions, current-row SQL reads, and source-row CustomScan predicates

Use a direct task when:

- you want to review or transform a known batch of rows
- you want to inspect jobs, outputs, actions, records, receipts, and traces from SQL
- you are still designing the model contract

Use a semantic index when:

- you want model-derived state to be reusable in normal queries
- source rows change and stale results must fail closed
- lookup can skip rows whose source hash is fresh
- you want reusable semantic rows and executor-visible CustomScan predicates

The direct task teaches the Otlet contract. Semantic indexes add query ergonomics and freshness policy

## Step 2 - Map The Otlet Schema

The direct task uses the smallest loop. Other Otlet surfaces use these tables

Use the catalog to see the durable state Otlet owns:

```sql
SELECT count(*) AS otlet_base_tables
FROM information_schema.tables
WHERE table_schema = 'otlet'
  AND table_type = 'BASE TABLE';
```

Representative output:

```text
 otlet_base_tables
-------------------
                20
(1 row)
```

Group the base tables by role:

- `models` and `runtime_slots` describe the local resident model runtime
- `tasks`, `model_selection_policies`, and `jobs` describe durable work and cheap-first escalation policy
- `outputs`, `action_type_schemas`, `actions`, `records`, `inference_receipts`, and `worker_events` store results and execution evidence
- `production_policy` defines queue admission, leases, invalid output handling, stale-result behavior, and cleanup windows
- `watches`, `semantic_indexes`, and `semantic_materializations` make row-derived model state queryable
- `watches` and `semantic_join_indexes` store pairwise candidate definitions

Use `otlet.runs` for application reads. Use trace and status views for debugging, proof, and learning

## Step 3 - Materialize Records Into Semantic State

Otlet stores actions and records first, then exposes records to queries through semantic materializations

This sequence materializes an entity-pair record, watches source changes, and marks the record stale through an update trigger:

```sql
SELECT record_type, subject_id, body, stale, source_table
FROM otlet.semantic_materializations
WHERE record_type = 'entity_hypothesis'
ORDER BY id;

SELECT otlet.materialize_semantic_index('demo_semantic_vendor_idx') AS refreshed_materializations;

SELECT otlet.watch_semantic_stale('public.otlet_entity_vendor'::regclass, 'id') AS stale_trigger_name;

UPDATE public.otlet_entity_vendor
SET city = 'Austin Learning'
WHERE id = 1;

SELECT count(*) AS stale_materializations
FROM otlet.semantic_materializations
WHERE record_type = 'entity_hypothesis'
  AND stale;
```

Representative output:

```text
    record_type    | subject_id |                                          body                                           | stale |        source_table
-------------------+------------+-----------------------------------------------------------------------------------------+-------+----------------------------
 entity_hypothesis | 1:2        | {"match": "yes", "reason": "same normalized name, phone, and city", "confidence": 0.95} | t     | public.otlet_entity_vendor
(1 row)

 refreshed_materializations
----------------------------
                          1
(1 row)

      stale_trigger_name
------------------------------
 otlet_stale_f2ddcf358c8f1d1f
(1 row)

UPDATE 1

 stale_materializations
------------------------
                      1
(1 row)
```

The trigger marks the previous derived fact stale and leaves model reruns to refresh policy. A source delete records `source_delete` in `otlet.semantic_dependency_audit`

Plain `mark_stale` row watches treat INSERT as missing semantic state rather than stale semantic state. Exact planning shows the new row as unresolved until refresh or infer-now:

```sql
SELECT missing_subjects, queue_subjects, count_basis
FROM otlet.semantic_index_plan('demo_semantic_vendor_idx', true);
```

Use `{"on_change":"mark_stale_and_enqueue"}` when inserts need immediate enqueue

## Step 4 - Build A Row Watch

A row watch wraps a source table with an Otlet task, materialized records, stale tracking, trigger policy, and current-row SQL reads

The creation shape is:

```sql
SELECT otlet.create_watch(
  'demo_semantic_vendor_idx',
  'row',
  'Otlet demo row watch. Return exactly this JSON object for every input row: {"output":{"status":"needs_review","needs_review":true,"issues":["demo semantic index"]},"actions":[{"type":"create_record","record_type":"demo_semantic_fact","subject_id":"db-owned","body":{"status":"needs_review","needs_review":true,"semantic":"indexed row"}}]}',
  '{
    "type": "object",
    "required": ["status", "needs_review", "issues"],
    "additionalProperties": false,
    "properties": {
      "status": {"enum": ["needs_review"]},
      "needs_review": {"type": "boolean"},
      "issues": {"type": "array", "items": {"type": "string"}}
    }
  }'::jsonb,
  'qwen3_1_7b',
  'public.otlet_demo_semantic_vendor'::regclass,
  'id',
  NULL,
  'demo_semantic_fact',
  '{"max_tokens":256,"reasoning":"off","inference_cache":true,"generation_trace":true,"generation_trace_max_tokens":12,"generation_trace_top_k":3}'::jsonb,
  '{}'::jsonb,
  '{"on_change":"mark_stale"}'::jsonb,
  ARRAY['create_record']
);

SELECT otlet.refresh_semantic_index('demo_semantic_vendor_idx') AS queued;

DO $$
DECLARE
  active_jobs bigint;
  complete_jobs bigint;
  failed_jobs bigint;
BEGIN
  FOR i IN 1..180 LOOP
    SELECT
      count(*) FILTER (WHERE status IN ('queued','running','cancel_requested')),
      count(*) FILTER (WHERE status = 'complete'),
      count(*) FILTER (WHERE status IN ('failed','canceled'))
    INTO active_jobs, complete_jobs, failed_jobs
    FROM otlet.jobs
    WHERE task_name = 'demo_semantic_vendor_idx_task';

    IF failed_jobs > 0 THEN
      RAISE EXCEPTION 'semantic index refresh failed';
    END IF;

    IF complete_jobs >= 3 AND active_jobs = 0 THEN
      RETURN;
    END IF;

    PERFORM pg_sleep(1);
  END LOOP;

  RAISE EXCEPTION 'timed out waiting for semantic index refresh';
END $$;

SELECT otlet.materialize_semantic_index('demo_semantic_vendor_idx') AS materialized;
```

Compact output from the demo run:

```text
semantic_index_refresh_queued=3
semantic_index_materialized=3
```

Once materialized, the index has planner-visible status:

```sql
SELECT 'semantic_index_status_contract=' ||
       name || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       inflight_subjects::text || '|' ||
       effective_stale_policy AS semantic_index_status_contract
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT 'semantic_index_plan_contract=' ||
       selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text || '|' ||
       freshness::text AS semantic_index_plan_contract
FROM otlet.semantic_index_plan('demo_semantic_vendor_idx');
```

Representative output:

```text
semantic_index_status_contract=demo_semantic_vendor_idx|3|0|0|refresh_then_fail_closed
semantic_index_plan_contract=semantic_lookup|3|3|0|0|1.0000
```

`semantic_index_plan` shows whether Otlet can reuse materialized state, refresh, wait, or run fresh inference

## Step 5 - Read Current Semantic Rows

`semantic_index_current_rows` returns materialized semantic state without adding another public access path:

```sql
SELECT 'semantic_current_rows_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"status":"needs_review"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE stale)::text AS semantic_current_rows_contract
FROM otlet.semantic_index_current_rows('demo_semantic_vendor_idx', true);
```

Representative output:

```text
semantic_current_rows_contract=3|3|0
```

Filter the current-row function when you need one subject:

```sql
SELECT *
FROM otlet.semantic_index_current_rows('demo_semantic_vendor_idx', true)
WHERE subject_id = '2';
```

## Step 6 - Read EXPLAIN Field Vocabulary

The SQL plan row and CustomScan EXPLAIN share planner terms

| Concept | SQL plan row | CustomScan EXPLAIN | Parity |
| --- | --- | --- | --- |
| Chosen path | `selected_path` | `Planner Selected Path` | Shared vocabulary; CustomScan prefixes planner-owned decisions |
| Reason | `reason` | `Planner Reason` | Equivalent meaning |
| Count basis | `count_basis` | `Count Basis` | SQL plan rows describe index state; CustomScan source-row predicates use exact or child-plan counts |
| Model cost basis | `model_cost_source` | `Model Cost Source` | Ordered basis: task receipt, runtime slot, model receipt, static fallback |
| Stale reasons | `stale_reasons` | `Planner Stale Reasons` | Shared JSON shape for stale subject counts |
| Infer-now prediction | `infer_now_subjects`, `fail_closed_subjects` | `Planner Infer Now Subjects`, `Planner Fail Closed Subjects` | CustomScan also reports actual executor counters |
| Freshness basis | `semantic_index_current_rows.freshness_basis` | `Preloaded Fresh Subjects / Basis`, `Emitted Freshness Basis` | Current-row SQL reports row freshness; CustomScan reports aggregate executor evidence |
| Child plan attachment | (none) | `Child Plan Attached` | Counter; `1` once begin-scan attaches the Postgres child plan |
| Source tuple path | (none) | `Source Tuple Provider` | Matches executor context; row scans report `child_plan_execprocnode`, joins report `child_subquery_join_execprocnode` |
| Predicate owner | (none) | `Semantic Predicate Owner` | Fixed owner: `otlet_customscan_executor` |
| Runtime identity | `inference_receipt_trace_status.runtime_fingerprint_hash` | `Infer Now Runtime Fingerprint Hash` | Same infer-now receipt fingerprint |
| Warm-job SQL finish | `inference_receipt_trace_status.finish_sql_ms` | `Infer Now Trace Finish Sql Ms` | Optional; stamped inside `complete_job` / `fail_job` |
| Warm-job materialize | `inference_receipt_trace_status.materialize_ms` | `Infer Now Trace Materialize Ms` | Optional; stamped inside `materialize_completed_semantic_job` |

Captured row-plan excerpt:

```text
selected_path | semantic_lookup
stale_reasons | {}
model_cost_source | task_receipt
count_basis | exact
```

Captured CustomScan EXPLAIN excerpt:

```text
Child Plan Attached: 1
Semantic Predicate Owner: otlet_customscan_executor
Source Tuple Provider: child_plan_execprocnode
Planner Selected Path: semantic_lookup
Planner Stale Reasons: {}
Count Basis: exact
Model Cost Source: task_receipt
Preloaded Fresh Subjects / Basis: 3 {"mvcc_match": 3}
Emitted Freshness Basis: {"mvcc_match": 3}
```

## Step 7 - Use CustomScan For Source-Row Predicates

Use a CustomScan to evaluate an Otlet semantic predicate against the source table

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v
  Otlet Node: Semantic Source CustomScan
  Child Semantic Filter: stripped_before_child_plan
  Child Plan Attached: 1
  Semantic Predicate Owner: otlet_customscan_executor
  Source Tuple Provider: child_plan_execprocnode
  Semantic Index: demo_semantic_vendor_idx
  Planner Selected Path: semantic_lookup
  Count Basis: exact
  Model Cost Source: task_receipt
  Planner Stale Reasons: {}
  Preloaded Fresh Subjects / Basis: 3 {"mvcc_match": 3}
  Emitted Freshness Basis: {"mvcc_match": 3}
  Actual Fresh Subjects: 3
```

The child scan reads the source table. Otlet strips the semantic predicate from the child plan and evaluates it against preloaded semantic state

CustomScan uses statement preload semantics. Row-marked queries such as `FOR UPDATE` stay on the standard Postgres plan because Otlet blocks the CustomScan planner path when queries include rowmarks; Postgres still owns locking and row recheck behavior. For non-rowmark CustomScan, stale triggers and the next statement pick up concurrent source changes instead of a per-tuple recheck inside that scan

## Step 8 - Fail Closed On Stale Rows

Changing a source row makes its materialized semantic state stale

```sql
UPDATE public.otlet_demo_semantic_vendor
SET email = 'learning-stale@example.test', updated_at = clock_timestamp()
WHERE id = 2;

SELECT 'semantic_stale_status_contract=' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       inflight_subjects::text AS semantic_stale_status_contract
FROM otlet.semantic_index_status
WHERE name = 'demo_semantic_vendor_idx';

SELECT count(*) AS fail_closed_rows
FROM public.otlet_demo_semantic_vendor v
WHERE v.id = 2
  AND otlet.semantic_matches('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output:

```text
UPDATE 1

semantic_stale_status_contract=2|1|0

 fail_closed_rows
------------------
                0
(1 row)
```

Fail-closed reads exclude stale facts even when old model output matched

## Step 9 - Let CustomScan Refresh A Stale Row With Infer-Now

`semantic_matches_auto` lets a source-table query use policy-owned bounded infer-now for stale or missing rows

The wait, infer, and max-row budget comes from `otlet.production_policy_status`:

```sql
SELECT 'semantic_auto_policy_contract=' ||
       semantic_auto_wait_ms::text || '|' ||
       semantic_auto_infer_ms::text || '|' ||
       semantic_auto_max_rows::text AS semantic_auto_policy_contract
FROM otlet.production_policy_status;
```

Representative output:

```text
semantic_auto_policy_contract=10000|15000|1
```

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT id
FROM public.otlet_demo_semantic_vendor v
WHERE otlet.semantic_matches_auto('demo_semantic_vendor_idx', v.id::text, '{"status":"needs_review"}'::jsonb);
```

Representative output excerpt:

```text
Custom Scan (Otlet Semantic Source CustomScan) on public.otlet_demo_semantic_vendor v
  Otlet Node: Semantic Source CustomScan
  Child Plan Attached: 1
  Semantic Predicate Owner: otlet_customscan_executor
  Source Tuple Provider: child_plan_execprocnode
  Semantic Index: demo_semantic_vendor_idx
  Refresh Policy: auto_lookup_wait_infer_refresh_fail_closed
  Infer Now Timeout Ms: 15000
  Infer Now Max Rows: 1
  Planner Selected Path: bounded_infer_now
  Count Basis: exact
  Model Cost Source: task_receipt
  Planner Infer Now Subjects: 1
  Planner Fail Closed Subjects: 0
  Preloaded Stale Subjects: 1
  Actual Infer Resolved Rows: 1
  Infer Now Receipts: 1
  Infer Now Trace Receipt Id: 42
  Infer Now Runtime Fingerprint Hash: e5797a21096dfddf
```

The executor refreshed the stale row with a bounded infer-now budget and a receipt

Inspect that receipt:

```sql
SELECT executor_origin || '|' ||
       semantic_index_name || '|' ||
       status || '|' ||
       (prompt_tokens > 0)::text || '|' ||
       (generated_tokens >= 0)::text AS receipt_contract
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'demo_semantic_vendor_idx_task'
  AND subject_id = '2'
ORDER BY receipt_id DESC
LIMIT 1;
```

Representative output:

```text
                    receipt_contract
---------------------------------------------------------
 customscan_infer_now|demo_semantic_vendor_idx|complete|t|t
(1 row)
```

Receipts carry executor provenance because one model task can run from the worker queue or from CustomScan infer-now

## Step 10 - Build A Pair Watch

Row watches follow source tables. Pair watches follow candidate queries

The candidate query supplies `subject_id` and `input` for candidate pairs:

```sql
SELECT otlet.drop_watch('learning_entity_pair_idx');

DROP TABLE IF EXISTS public.learning_entity;

CREATE TABLE public.learning_entity (
  id bigint PRIMARY KEY,
  name text NOT NULL,
  phone text NOT NULL,
  city text NOT NULL
);

INSERT INTO public.learning_entity VALUES
  (1, 'Acme Logistics LLC', '512-555-0100', 'Austin'),
  (2, 'ACME Logistics', '512-555-0100', 'Austin');

SELECT 'semantic_join_create_contract=' ||
       name || '|' ||
       task_name || '|' ||
       record_type || '|' ||
       max_candidate_rows::text
FROM otlet.create_watch(
  watch_name => 'learning_entity_pair_idx',
  kind => 'pair',
  instruction => 'The two input entities are the same company. Return exactly this JSON object: {"output":{"match":"yes","confidence":0.95,"needs_review":false},"actions":[]}',
  output_schema => '{"type":"object","required":["match","confidence","needs_review"],"additionalProperties":false,"properties":{"match":{"enum":["yes"]},"confidence":{"type":"number"},"needs_review":{"type":"boolean"}}}'::jsonb,
  model_name => 'qwen3_1_7b',
  candidate_query => $$
    SELECT
      a.id::text || ':' || b.id::text AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.learning_entity',
          'subject_id', a.id::text,
          'right_id', b.id::text
        ),
        'left', to_jsonb(a),
        'right', to_jsonb(b)
      ) AS input
    FROM public.learning_entity a
    JOIN public.learning_entity b ON a.id < b.id
  $$,
  record_type => 'learning_entity_pair',
  runtime_options => '{"max_tokens":160,"reasoning":"off"}'::jsonb,
  trigger_policy => '{"on_change":"mark_stale"}'::jsonb,
  max_candidate_rows => 10,
  pair_sources => '[{"table":"public.learning_entity","subject_column":"id"}]'::jsonb
);

SELECT 'semantic_join_refresh_queued=' ||
       otlet.refresh_semantic_join_index('learning_entity_pair_idx')::text;
```

Use the semantic-index wait loop, or run `./scripts/otlet-demo.sh` for the compact proof. Then inspect the automatic materialization:

```sql
SELECT 'semantic_join_auto_materialized=' ||
       count(*)::text AS semantic_join_auto_materialized
FROM otlet.semantic_materializations
WHERE task_name = 'learning_entity_pair_idx_task'
  AND record_type = 'learning_entity_pair'
  AND stale = false;
```

Representative output:

```text
semantic_join_create_contract=learning_entity_pair_idx|learning_entity_pair_idx_task|learning_entity_pair|10
semantic_join_refresh_queued=1
semantic_join_auto_materialized=1
```

`pair_sources` installs the row-index stale trigger. Updates to declared source rows mark matching pair materializations through `_otlet_mvcc` dependencies, and `drop_watch` removes the trigger when no row index or pair watch still needs it

Pair refresh reconciles the bounded candidate query. A removed subject gets `candidate_removed`; a subject with changed shaped content gets `candidate_changed`. Removed candidates queue no work. New and changed candidates continue through the existing queue. If the same candidate content returns, Otlet clears the candidate-drift state and reuses its materialization

```sql
SELECT subject_id, stale, stale_reason, source_dependencies
FROM otlet.semantic_dependency_audit
WHERE task_name = 'learning_entity_pair_idx_task'
ORDER BY subject_id;
```

Inspect the join index:

```sql
SELECT 'semantic_join_status_contract=' ||
       selected_path || '|' ||
       total_subjects::text || '|' ||
       fresh_subjects::text || '|' ||
       stale_subjects::text || '|' ||
       missing_subjects::text AS semantic_join_status_contract
FROM otlet.semantic_join_index_plan('learning_entity_pair_idx');

SELECT 'semantic_join_lookup_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"match":"yes"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE stale)::text AS semantic_join_lookup_contract
FROM otlet.semantic_join_index_current_rows('learning_entity_pair_idx', true);
```

Representative output:

```text
semantic_join_status_contract=semantic_join_lookup|1|1|0|0
semantic_join_lookup_contract=1|1|0
```

A semantic join index stores jobs, outputs, actions, records, materializations, and receipts

## Step 11 - Query A Semantic Join Predicate

```sql
SELECT 'semantic_join_match_contract=' ||
       bool_and(otlet.semantic_join_matches('learning_entity_pair_idx', subject_id, '{"match":"yes"}'::jsonb))::text AS semantic_join_match_contract
FROM otlet.semantic_join_index_current_rows('learning_entity_pair_idx', true);
```

Representative output:

```text
semantic_join_match_contract=true
```

Use explicit JSON predicates for row and join semantic filters

## Step 12 - Move A Watch Definition

The extension owner can export a row or pair watch as configuration-only JSONB:

```sql
SELECT jsonb_pretty(otlet.export_watch('learning_entity_pair_idx'));
```

`otlet.watch.v1` uses the same fields as `otlet.create_watch(...)`. The shortened values below show the key and type contract; export keeps the full instruction, schema, and candidate query

```json
{
  "format": "otlet.watch.v1",
  "name": "learning_entity_pair_idx",
  "kind": "pair",
  "instruction": "Compare one candidate pair",
  "output_schema": {},
  "model_name": "qwen3_1_7b",
  "table_name": null,
  "subject_column": null,
  "candidate_query": "SELECT subject_id, input FROM public.learning_entity_pair_input",
  "record_type": "learning_entity_pair",
  "runtime_options": {},
  "selection_policy": {},
  "trigger_policy": {"on_change": "mark_stale"},
  "action_types": [],
  "stale_policy": "refresh_then_fail_closed",
  "input_shaping": {},
  "decision_contract": {},
  "max_candidate_rows": 10,
  "input_columns": null,
  "pair_sources": [
    {"table": "public.learning_entity", "subject_column": "id"}
  ]
}
```

The document contains watch configuration and owner-authored candidate SQL. It excludes model paths, source rows, jobs, outputs, actions, receipts, labels, traces, materializations, trigger names, timestamps, and counters

Import requires the referenced model, tables, and columns to exist. The function rejects an existing watch unless the owner requests replacement:

```sql
SELECT otlet.export_watch('learning_entity_pair_idx') AS watch_definition \gset

SELECT otlet.drop_watch('learning_entity_pair_idx');

SELECT name, kind
FROM otlet.import_watch(:'watch_definition'::jsonb);

SELECT name, kind
FROM otlet.import_watch(
  :'watch_definition'::jsonb,
  replace_existing => true
);
```

Import validates `otlet.watch.v1`, resolves database dependencies, and calls `otlet.create_watch(...)`. A failed import rolls back its statement and leaves an existing watch unchanged

The Docker demo proves replacement, drop/import round trip, lookup preservation, trigger preservation, and nine rejected documents:

```text
watch_replace_contract=true|true|true|true|true|true|true|true|true|true
watch_round_trip_contract=true|true|true|true|true
watch_import_failure_contract=9|true
```
