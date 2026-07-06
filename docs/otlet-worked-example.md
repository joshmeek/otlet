# Otlet Worked Example

Use this as a learning file, not a test harness. The format follows _worked example_ research from [this study](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762#abstract)

You start with the smallest real Otlet loop for entity resolution: keep vendor rows in ordinary Postgres tables, select hard candidate pairs in SQL, enqueue durable model work, let the resident worker try a cheap local model and escalate hard rows to a stronger local model, validate `same_entity` / `different_entity` / `unclear`, record typed action proposals, and keep the audit trail

The example data uses vendors where string normalization fails. One pair is a rebrand with a shared remittance account and acquisition note. One pair has no shared identifiers and belongs in a separate entity. Two pairs carry weak name/address/brand signals that force harder model work. Otlet judges the pairs without mutating source tables

## Otlet In One Loop

```text
source candidate pair
  -> otlet.jobs row
  -> resident Postgres worker
  -> cheap local Qwen3 1.7B through llama.cpp
  -> stronger local Qwen3.5 4B when policy escalates
  -> JSON and action validation
  -> otlet.outputs
  -> otlet.actions
  -> otlet.records
  -> otlet.semantic_materializations
  -> otlet.inference_receipts
```

Otlet keeps Postgres as the system of record

Source tables stay under application control. Otlet sends the model bounded pair-shaped input and accepts structured JSON. Otlet validates output and typed actions before storage. Semantic refresh jobs create Otlet-owned `create_record` actions, records, and materialized semantic rows from validated output so downstream SQL can read fresh state

For one-off row questions, use `otlet.ask(...)`. It inlines the prompt, row JSON, output schema, and model name, then returns trusted output with `job_id` and `receipt_id`. Otlet writes the internal task, job, receipt, trace, and output rows. Named tasks below are for repeatable watches, queues, semantic refresh, and model selection

## Start From A Running Local Otlet

Build and start the local Postgres container first:

```sh
./scripts/otlet-setup.sh
```

Open `psql` with both local Qwen artifact paths available as variables:

```sh
docker exec -it otlet-postgres sh -lc '
  cheap_model_artifact="$(find /var/lib/postgresql -name Qwen3-1.7B-Q8_0.gguf -print -quit)"
  strong_model_artifact="$(find /var/lib/postgresql -name Qwen3.5-4B-Q4_K_M.gguf -print -quit)"
  psql -U postgres -d postgres \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v strong_model_artifact="$strong_model_artifact"
'
```

Paste the rest of the file into that `psql` session section by section

Output blocks show representative output from real local runs. Job IDs, receipt IDs, timestamps, costs, timings, memory samples, and token rates vary by machine and model cache state

## Register The Runtime And Models

```sql
CREATE EXTENSION IF NOT EXISTS otlet;

SELECT otlet.register_runtime('linked_inproc', 'linked');

SELECT otlet.register_model(
  'qwen3_1_7b',
  :'cheap_model_artifact',
  'linked_inproc'
);

SELECT otlet.register_model(
  'qwen35_4b',
  :'strong_model_artifact',
  'linked_inproc'
);
```

`linked_inproc` means the Otlet background worker inside Postgres owns inference

The worker loads a local GGUF through in-process llama.cpp and keeps the model resident across jobs

Postgres can query the queue, source row identity, output validation, receipts, traces, and runtime state

## Create The Source Tables

```sql
DROP TABLE IF EXISTS public.otlet_demo_vendor_pair;
DROP TABLE IF EXISTS public.otlet_demo_vendor_entity;

CREATE TABLE public.otlet_demo_vendor_entity (
  id text PRIMARY KEY,
  legal_name text NOT NULL,
  website text,
  address text,
  notes text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.otlet_demo_vendor_pair (
  pair_id text PRIMARY KEY,
  left_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id),
  right_id text NOT NULL REFERENCES public.otlet_demo_vendor_entity(id)
);

INSERT INTO public.otlet_demo_vendor_entity (id, legal_name, website, address, notes)
VALUES
  ('vendor-1001', 'Northstar Logistics LLC', 'northstar-logistics.example', '41 W Lake St, Chicago, IL', 'legacy freight vendor from the 2021 import; tax id 36-9918821; remittance account ending 8821; AP contact ops@northstar-logistics.example'),
  ('vendor-42', 'N-Star Freight Services', 'nstar-freight.example', '41 West Lake Street, Suite 900, Chicago', 'same remittance account ending 8821 and same tax id 36-9918821; internal note says Northstar rebranded after acquisition'),
  ('vendor-77', 'Clearwater Medical Supplies', 'clearwatermed.example', '500 Hospital Way, Phoenix, AZ', 'hospital supply distributor; no shared tax id, domain, payment account, AP contact, remittance account, city, or industry with the freight vendor'),
  ('vendor-313', 'North Star Medical Logistics', 'northstarmedlog.example', '41 West Lake Street, Chicago, IL', 'medical logistics broker; same building and similar name, but verified separate legal entity; different tax id 92-4403130; different remittance account ending 1199; different domain, payment account, AP contact, and no acquisition note'),
  ('vendor-314', 'Northstar Freight Canada Inc.', 'northstar-canada.example', '88 King St W, Toronto, ON', 'Canadian freight carrier with similar brand; different country, tax id CA-771314, bank account ending 4410, AP contact, and no shared remittance account or acquisition note in the ledger');

INSERT INTO public.otlet_demo_vendor_pair (pair_id, left_id, right_id)
VALUES
  ('vendor-1001:vendor-42', 'vendor-1001', 'vendor-42'),
  ('vendor-1001:vendor-77', 'vendor-1001', 'vendor-77'),
  ('vendor-1001:vendor-313', 'vendor-1001', 'vendor-313'),
  ('vendor-1001:vendor-314', 'vendor-1001', 'vendor-314');
```

Your application owns these tables

SQL selects candidate pairs first, then Otlet judges those pairs. Merge vendors later through an explicit application workflow outside this model pass

## Clear Old Demo State

```sql
DELETE FROM otlet.worker_events e
USING otlet.jobs j
WHERE e.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.semantic_materializations sm
USING otlet.records r, otlet.actions a, otlet.jobs j
WHERE sm.record_id = r.id
  AND r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.records r
USING otlet.actions a, otlet.jobs j
WHERE r.action_id = a.id
  AND a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.actions a
USING otlet.jobs j
WHERE a.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.outputs o
USING otlet.jobs j
WHERE o.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.inference_receipts r
USING otlet.jobs j
WHERE r.job_id = j.id
  AND j.task_name = 'entity_resolution_demo';

DELETE FROM otlet.jobs
WHERE task_name = 'entity_resolution_demo';

DELETE FROM otlet.tasks
WHERE name = 'entity_resolution_demo';
```

The product flow does not need this cleanup

It only makes the example rerunnable

## Create The Task

```sql
SELECT name, model_name
FROM otlet.create_task(
  'entity_resolution_demo',
  $$
    SELECT
      p.pair_id AS subject_id,
      jsonb_build_object(
        '_otlet_mvcc', jsonb_build_object(
          'table', 'public.otlet_demo_vendor_entity',
          'subject_id', p.pair_id,
          'left_id', p.left_id,
          'right_id', p.right_id,
          'left_ctid', l.ctid::text,
          'left_xmin', l.xmin::text,
          'right_ctid', r.ctid::text,
          'right_xmin', r.xmin::text
        ),
        'candidate_evidence', evidence.candidate_evidence,
        'evidence_counts', jsonb_build_object(
          'shared_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'shared_stable_identifiers'),
          'conflicting_stable_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'conflicting_stable_identifiers'),
          'weak_matching_signals', jsonb_array_length(evidence.candidate_evidence -> 'weak_matching_signals'),
          'missing_or_unknown_identifiers', jsonb_array_length(evidence.candidate_evidence -> 'missing_or_unknown_identifiers'),
          'row_quality_warnings', jsonb_array_length(evidence.candidate_evidence -> 'row_quality_warnings')
        ),
        'action_ids', jsonb_build_object('left_id', p.left_id, 'right_id', p.right_id)
      ) AS input
    FROM public.otlet_demo_vendor_pair p
    JOIN public.otlet_demo_vendor_entity l ON l.id = p.left_id
    JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
    CROSS JOIN LATERAL (
      SELECT CASE p.pair_id
        WHEN 'vendor-1001:vendor-42' THEN jsonb_build_object(
          'shared_stable_identifiers', jsonb_build_array(
            'same remittance account ending 8821',
            'same tax id 36-9918821',
            'Northstar rebrand after acquisition'
          ),
          'conflicting_stable_identifiers', '[]'::jsonb,
          'weak_matching_signals', jsonb_build_array('similar address'),
          'missing_or_unknown_identifiers', '[]'::jsonb,
          'row_quality_warnings', '[]'::jsonb
        )
        WHEN 'vendor-1001:vendor-77' THEN jsonb_build_object(
          'shared_stable_identifiers', '[]'::jsonb,
          'conflicting_stable_identifiers', jsonb_build_array(
            'different industry and city',
            'no shared tax id, domain, payment account, AP contact, or remittance account'
          ),
          'weak_matching_signals', '[]'::jsonb,
          'missing_or_unknown_identifiers', '[]'::jsonb,
          'row_quality_warnings', '[]'::jsonb
        )
        WHEN 'vendor-1001:vendor-313' THEN jsonb_build_object(
          'shared_stable_identifiers', '[]'::jsonb,
          'conflicting_stable_identifiers', jsonb_build_array(
            'medical logistics versus freight vendor',
            'different tax id 92-4403130',
            'different remittance account ending 1199',
            'different domain, payment account, AP contact, and no acquisition note'
          ),
          'weak_matching_signals', jsonb_build_array('same office building', 'similar North Star name'),
          'missing_or_unknown_identifiers', '[]'::jsonb,
          'row_quality_warnings', '[]'::jsonb
        )
        WHEN 'vendor-1001:vendor-314' THEN jsonb_build_object(
          'shared_stable_identifiers', '[]'::jsonb,
          'conflicting_stable_identifiers', jsonb_build_array(
            'different country and Canadian legal entity',
            'different tax id CA-771314',
            'different bank account ending 4410, AP contact, and no shared remittance account',
            'no acquisition or rebrand note connecting the records'
          ),
          'weak_matching_signals', jsonb_build_array('similar Northstar freight brand'),
          'missing_or_unknown_identifiers', '[]'::jsonb,
          'row_quality_warnings', '[]'::jsonb
        )
        ELSE jsonb_build_object(
          'shared_stable_identifiers', '[]'::jsonb,
          'conflicting_stable_identifiers', '[]'::jsonb,
          'weak_matching_signals', '[]'::jsonb,
          'missing_or_unknown_identifiers', jsonb_build_array('no decisive identity evidence'),
          'row_quality_warnings', '[]'::jsonb
        )
      END AS candidate_evidence
    ) evidence
    ORDER BY p.pair_id
  $$,
  'Return one JSON object only. Top-level keys must be output and actions. Never use ellipses or placeholder values. Use input.evidence_counts for the decision and input.candidate_evidence only for the short reason. input.action_ids are row IDs for action bodies, not identity evidence. confidence must be low, medium, or high, never unclear. Rule 1: if conflicting_stable_identifiers > 0, output different_entity with confidence high. Rule 2: else if shared_stable_identifiers > 0, output same_entity with confidence high. Rule 3: else output unclear with confidence medium. Never output different_entity when conflicting_stable_identifiers = 0. Never output same_entity when shared_stable_identifiers = 0. weak_matching_signals, missing_or_unknown_identifiers, and row_quality_warnings only explain unclear. Action type must be exactly merge_candidate, new_entity, or review_flag; never same_entity, different_entity, or unclear. same_entity uses merge_candidate body left_id, right_id, confidence, reason. different_entity uses new_entity body entity_id, reason, and entity_id must equal input.action_ids.right_id. unclear uses review_flag body left_id, right_id, severity, reason. Use input.action_ids.left_id and input.action_ids.right_id. Do not include an evidence field in actions. Keep output.reason and action body reason under 18 words. Quote every key and string. No markdown.',
  '{
    "type": "object",
    "required": ["match", "confidence", "reason"],
    "additionalProperties": false,
    "properties": {
      "match": {"enum": ["same_entity", "different_entity", "unclear"]},
      "confidence": {"enum": ["low", "medium", "high"]},
      "reason": {"type": "string", "maxLength": 240}
    }
  }'::jsonb,
  'qwen3_1_7b',
  '{
    "max_tokens": 256,
    "reasoning": "off",
    "inference_cache": true,
    "generation_trace": true,
    "generation_trace_max_tokens": 16,
    "generation_trace_top_k": 3
  }'::jsonb
);

SELECT task_name, cheap_model_name, strong_model_name
FROM otlet.set_model_selection_policy(
  'entity_resolution_demo',
  'qwen3_1_7b',
  'qwen35_4b'
);
```

Representative output:

```text
          name          |    model_name
------------------------+------------------
 entity_resolution_demo | qwen3_1_7b
(1 row)

       task_name        | cheap_model_name | strong_model_name
------------------------+------------------+-------------------
 entity_resolution_demo | qwen3_1_7b | qwen35_4b
(1 row)
```

`create_task` registers the model contract and input query

The task has seven parts:

- `task_name` gives the queue and receipt trail a stable name
- `input_query` converts SQL-selected candidate pairs into `subject_id` and compact `input`
- `instruction` is the model contract for this task
- `output_schema` is the JSON schema Otlet enforces before storing output
- `model_name` chooses the cheap registered local model
- `model_selection_policies` chooses the stronger registered local model for escalation
- `runtime_options` bound generation, tracing, and cache behavior

The schema separates model judgment from database state Otlet stores

If the model returns malformed JSON, missing fields, unknown fields, or values outside the enum, Otlet marks the job failed and keeps the raw evidence. Otlet stores no trusted output or records

## Enqueue The Jobs

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
```

Representative output:

```text
 queued_jobs
-------------
           4
(1 row)
```

`run_task` executes the task input query and inserts one row into `otlet.jobs` per pair

The user transaction creates durable database work. The resident worker claims it

The queue keeps model work out of the client request. SQL shows each job at any status: queued, running, complete, failed, or canceled

## Watch The Worker

```sql
SELECT
  id,
  task_name,
  subject_id,
  status,
  attempts,
  created_at,
  started_at,
  finished_at,
  error
FROM otlet.jobs
WHERE task_name = 'entity_resolution_demo'
ORDER BY id;
```

If it is still running, wait a moment and run the query again

Representative output:

```text
 id |       task_name        |      subject_id       |  status  | attempts |          created_at           |          started_at           |          finished_at          | error
----+------------------------+-----------------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------
  1 | entity_resolution_demo | vendor-1001:vendor-313 | complete |        1 | 2026-06-26 15:30:50.122119+00 | 2026-06-26 15:30:50.126401+00 | 2026-06-26 15:31:02.446731+00 |
  2 | entity_resolution_demo | vendor-1001:vendor-314 | complete |        1 | 2026-06-26 15:30:50.122119+00 | 2026-06-26 15:30:50.126401+00 | 2026-06-26 15:31:04.009343+00 |
  3 | entity_resolution_demo | vendor-1001:vendor-42  | complete |        1 | 2026-06-26 15:30:50.122119+00 | 2026-06-26 15:30:50.126401+00 | 2026-06-26 15:31:04.826055+00 |
  4 | entity_resolution_demo | vendor-1001:vendor-77  | complete |        1 | 2026-06-26 15:30:50.122119+00 | 2026-06-26 15:30:50.126401+00 | 2026-06-26 15:31:05.731144+00 |
(4 rows)
```

The worker coordinates through normal database state. It claims jobs from `otlet.jobs`, writes outputs to Otlet tables, and records worker events in `otlet.worker_events`

## Read The Model Output

```sql
SELECT
  r.subject_id,
  r.output ->> 'match' AS match,
  r.output ->> 'confidence' AS confidence,
  r.output ->> 'reason' AS reason
FROM otlet.runs r
WHERE r.task_name = 'entity_resolution_demo'
ORDER BY r.subject_id;
```

Representative output:

```text
      subject_id       |      match       | confidence |                    reason
-----------------------+------------------+------------+----------------------------------------------
 vendor-1001:vendor-313 | different_entity | high       | no shared identifiers
 vendor-1001:vendor-314 | different_entity | high       | no shared identifiers
 vendor-1001:vendor-42  | same_entity      | high       | shared remittance or rebrand
 vendor-1001:vendor-77  | different_entity | high       | no shared identifiers
(4 rows)
```

`otlet.runs` is a convenience view over jobs, outputs, and receipts

Otlet stores the result as database state. You do not have to scrape a terminal response

Direct entity-resolution tasks ask the model for one typed action. Otlet stores actions only when they attach to an accepted, schema-valid output receipt

## Inspect Typed Actions

```sql
SELECT
  action_type,
  status,
  approval_status,
  dry_run_status,
  apply_status,
  count(*) AS actions
FROM otlet.action_status
WHERE task_name = 'entity_resolution_demo'
GROUP BY action_type, status, approval_status, dry_run_status, apply_status
ORDER BY action_type;
```

Representative output:

```text
   action_type   |  status  | approval_status | dry_run_status |  apply_status  | actions
-----------------+----------+-----------------+----------------+----------------+---------
 merge_candidate | proposed | required        | not_run        | not_applicable |       1
 new_entity      | proposed | not_required    | not_run        | not_applicable |       3
(2 rows)
```

`merge_candidate` records evidence for a later merge workflow. It requires approval and has no source-table apply path. `new_entity` says the right-side row belongs in a separate entity

Failed or rejected model attempts do not create trusted actions:

```sql
SELECT count(*) AS failed_attempt_actions
FROM otlet.action_status a
JOIN otlet.inference_receipts r ON r.id = a.receipt_id
WHERE a.task_name = 'entity_resolution_demo'
  AND r.selection_status <> 'accepted';
```

Representative output:

```text
 failed_attempt_actions
------------------------
                      0
(1 row)
```

## Review The Queue

`otlet.review_queue` gathers actions that need attention, abstention outputs, and review flags with receipt and source-freshness context:

```sql
SELECT queue_kind, task_name, watch_name, subject_id, action_id, receipt_id, source_stale
FROM otlet.review_queue
WHERE task_name IN ('entity_resolution_demo', 'demo_entity_resolution_idx_task')
ORDER BY created_at, task_name
LIMIT 5;
```

Representative output:

```text
    queue_kind    |            task_name            |         watch_name         | subject_id | action_id | receipt_id | source_stale
------------------+---------------------------------+----------------------------+------------+-----------+------------+--------------
 pending_approval | demo_entity_resolution_idx_task | demo_entity_resolution_idx | vendor-42  |        35 |         85 | f
(1 row)
```

Manual correction is one atomic call: reject the action and write a gold `manual_correction` eval label. This example rolls back so the later approval flow can still run:

```sql
BEGIN;

WITH target AS (
  SELECT
    q.action_id,
    q.action_type,
    q.output ->> COALESCE(NULLIF(t.decision_contract ->> 'answer_field', ''), 'match') AS expected_answer,
    COALESCE(q.output ->> 'confidence', 'high') AS expected_confidence
  FROM otlet.review_queue q
  JOIN otlet.tasks t ON t.name = q.task_name
  WHERE q.action_id IS NOT NULL
    AND q.task_name IN ('entity_resolution_demo', 'demo_entity_resolution_idx_task')
  ORDER BY q.created_at, q.task_name
  LIMIT 1
), correction AS (
  SELECT l.*
  FROM target t,
  LATERAL otlet.correct_action(
    t.action_id,
    jsonb_build_object(
      'expected_answer', t.expected_answer,
      'expected_confidence', t.expected_confidence,
      'expected_action_type', t.action_type
    ),
    'worked example correction'
  ) l
)
SELECT action_id, expected_answer, expected_confidence, expected_action_type, label_source
FROM correction;

ROLLBACK;
```

Representative output:

```text
 action_id | expected_answer | expected_confidence | expected_action_type |   label_source
-----------+-----------------+---------------------+----------------------+-------------------
        35 | same_entity     | high                | merge_candidate      | manual_correction
(1 row)
```

The same correction is immediately available as local eval data:

```sql
SELECT action_id, case_kind, expected_answer, expected_action_type, manual_gold
FROM otlet.export_eval_cases(5)
WHERE label_source = 'manual_correction'
ORDER BY created_at DESC
LIMIT 1;
```

Representative output:

```text
 action_id | case_kind | expected_answer | expected_action_type | manual_gold
-----------+-----------+-----------------+----------------------+-------------
        35 | gold      | same_entity     | merge_candidate      | t
(1 row)
```

Eval label confidence is intentionally the same small vocabulary used by model outputs: `low`, `medium`, or `high`. Keep calibration notes in `reason` or task-specific fields rather than expanding `expected_confidence`

Approve, dry-run, and apply one merge proposal:

```sql
WITH target AS (
  SELECT min(action_id) AS action_id
  FROM otlet.action_status
  WHERE task_name = 'entity_resolution_demo'
    AND action_type = 'merge_candidate'
), approved AS (
  SELECT 'approve' AS step, a.*
  FROM target t, LATERAL otlet.approve_action(t.action_id) a
), dry_run AS (
  SELECT 'dry_run' AS step, a.*
  FROM approved p, LATERAL otlet.dry_run_action(p.id) a
), applied AS (
  SELECT 'apply' AS step, a.*
  FROM dry_run d, LATERAL otlet.apply_action(d.id) a
)
SELECT step, status, approval_status, dry_run_status, apply_status
FROM approved
UNION ALL
SELECT step, status, approval_status, dry_run_status, apply_status
FROM dry_run
UNION ALL
SELECT step, status, approval_status, dry_run_status, apply_status
FROM applied;
```

Representative output:

```text
  step   |  status  | approval_status | dry_run_status |  apply_status
---------+----------+-----------------+----------------+----------------
 approve | approved | approved        | not_run        | not_applicable
 dry_run | approved | approved        | passed         | not_applicable
 apply   | approved | approved        | passed         | not_applicable
(3 rows)
```

Semantic refresh jobs create typed `create_record` actions, `otlet.records` rows, and semantic materializations after schema validation passes

Semantic materializations keep two row identities. `source_hash` is MVCC-coupled provenance for the exact row version that produced a job. `content_hash` is the model-input identity used for freshness, excluding Otlet's MVCC envelope so benign row churn can revalidate without rerunning the model

Input shaping fields are top-level in the task input. Row watches wrap source rows under `row`, so `evidence_fields` does not traverse `row.evidence`; project evidence to a top-level object in the input or pair candidate query. Pair watches treat the candidate query as the shaping declaration, with `strip_keys` available for top-level volatile fields

## Inspect Model Selection Attempts

```sql
SELECT
  subject_id,
  attempt_index,
  selection_role,
  selection_status,
  model_name,
  output ->> 'match' AS match,
  output ->> 'confidence' AS confidence
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index;
```

Representative output from the demo run:

```text
      subject_id       | attempt_index | selection_role | selection_status |    model_name    |      match       | confidence
-----------------------+---------------+----------------+------------------+------------------+------------------+------------
 vendor-1001:vendor-313 |             1 | cheap          | failed           | qwen3_1_7b |                  |
 vendor-1001:vendor-313 |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
 vendor-1001:vendor-314 |             1 | cheap          | failed           | qwen3_1_7b |                  |
 vendor-1001:vendor-314 |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
 vendor-1001:vendor-42  |             1 | cheap          | failed           | qwen3_1_7b |                  |
 vendor-1001:vendor-42  |             2 | strong         | accepted         | qwen35_4b        | same_entity      | high
 vendor-1001:vendor-77  |             1 | cheap          | failed           | qwen3_1_7b |                  |
 vendor-1001:vendor-77  |             2 | strong         | accepted         | qwen35_4b        | different_entity | high
(8 rows)
```

The cheap model fails the stricter output/action envelope in this run. Failed attempts stay visible as receipts, every row escalates to `qwen35_4b`, and Otlet materializes only the accepted output for each job

## Read The Receipt

```sql
SELECT 'receipt_attempt_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE selection_role = 'cheap')::text || '|' ||
       count(*) FILTER (WHERE selection_role = 'strong')::text || '|' ||
       count(*) FILTER (WHERE status = 'failed')::text AS receipt_attempt_contract
FROM otlet.inference_receipt_trace_status
WHERE task_name = 'entity_resolution_demo';
```

Representative output:

```text
receipt_attempt_contract=8|4|4|4
```

A receipt records evidence for one model run. A selected job can have multiple receipts for the same candidate pair

It links the model, artifact, runtime options, prompt hash, input hash, output schema hash, raw output hash, validation status, timing, token counts, memory summary, and trace summary

Otlet stores receipts when jobs fail because failures produce evidence too

## Inspect Runtime Residency

```sql
SELECT 'runtime_residency_contract=' ||
       runtime_status || '|' ||
       slot_state || '|' ||
       model_residency_policy || '|' ||
       (context_window_tokens > 0)::text || '|' ||
       (inference_cache_entries <= inference_cache_max_entries)::text AS runtime_residency_contract
FROM otlet.runtime_status
WHERE runtime_name = 'linked_inproc';
```

Representative output:

```text
runtime_residency_contract=ready|ready|resident_worker_loaded_model_context|true|true
```

Otlet exposes model residency here

The worker keeps the local model/context warm across jobs. SQL can see the slot state, memory sample, context window, cache entries, cache bounds, and the last cache reason

SQL shows whether the model loaded, is busy, failed, cached, or went over budget

The inference-output cache stores schema-valid raw model output before selection trust is applied. Accepted abstentions and rejected-but-valid attempts may reuse cached bytes, while invalid JSON/schema failures are never cached. The receipt still records accepted/rejected/failed status, and the cache key basis stays content hash + contract hash + model fingerprint

```sql
SELECT task_name,
       cache_enabled_receipts,
       inference_cache_hits,
       inference_cache_hit_rate,
       inference_cache_key_bases
FROM otlet.task_inference_cache_status
WHERE task_name = 'entity_resolution_demo';
```

## Inspect Token Traces

The task enabled bounded generation tracing:

```json
{
  "generation_trace": true,
  "generation_trace_max_tokens": 16,
  "generation_trace_top_k": 3
}
```

Otlet stores a bounded trace summary on the receipt instead of an unbounded prompt or logits blob

Check the bounded token trace:

```sql
SELECT 'token_trace_contract=' ||
       (SELECT count(*)::text FROM otlet.inference_receipt_token_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT count(*)::text FROM otlet.inference_receipt_token_alternative_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT (max(step) <= 16)::text FROM otlet.inference_receipt_token_trace WHERE task_name = 'entity_resolution_demo') || '|' ||
       (SELECT (max(alternative_rank) <= 3)::text FROM otlet.inference_receipt_token_alternative_trace WHERE task_name = 'entity_resolution_demo') AS token_trace_contract;
```

Representative output:

```text
token_trace_contract=112|336|true|true
```

Trace data records:

- Prompt tokens used by the row
- Model tokens generated
- Generation stop reason
- Probability availability from llama.cpp logits
- Receipt, row identity, input hash, and schema hash attached to the trace
- Resident model cache and inference-output cache use

Otlet bounds tracing so prompt, token, and logits storage does not turn observability into a data retention problem

## Check The Whole Chain

```sql
SELECT
  (SELECT count(*) FROM otlet.outputs o JOIN otlet.jobs j ON j.id = o.job_id WHERE j.task_name = 'entity_resolution_demo') AS outputs,
  (SELECT count(*) FROM otlet.actions a JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'entity_resolution_demo') AS actions,
  (SELECT count(*) FROM otlet.records r JOIN otlet.actions a ON a.id = r.action_id JOIN otlet.jobs j ON j.id = a.job_id WHERE j.task_name = 'entity_resolution_demo') AS records,
  (SELECT count(*) FROM otlet.inference_receipts r WHERE r.task_name = 'entity_resolution_demo') AS receipts;
```

Representative output:

```text
 outputs | actions | records | receipts
---------+---------+---------+----------
       4 |       4 |       0 |        7
(1 row)
```

That count covers the direct task shape:

```text
four source candidate pairs
four jobs
four accepted outputs
four typed action proposals
seven model-attempt receipts
bounded trace state
SQL-visible runtime state
```

## Bad Output

If the model returns invalid JSON or a value outside the schema, Otlet fails closed

Check these rows:

- `otlet.jobs.status = 'failed'`
- `otlet.jobs.error` contains the validation or parse failure
- `otlet.jobs.raw_output` keeps raw model text for inspection
- `otlet.outputs` has no validated row
- `otlet.actions` has no trusted row from a failed model attempt
- `otlet.records` has no row
- an error receipt preserves the model/runtime evidence when available

The task schema and action rules decide whether model output can become database truth. If output passes and a proposed action fails, Otlet keeps the rejected action as evidence and creates no record

## Semantic Indexes

The direct task path gives you the shortest way to learn Otlet

Semantic indexes add repeated lookup over source rows, stale-row tracking, refresh decisions, native FDW reads, and source-row CustomScan predicates

Use a direct task when:

- you want to review or transform a known batch of rows
- you want to inspect jobs, outputs, actions, records, receipts, and traces directly
- you are still designing the model contract

Use a semantic index when:

- you want model-derived state to be reusable in normal queries
- source rows change and stale results must fail closed
- lookup can skip rows whose source hash is fresh
- you want executor-visible semantic access through FDW or CustomScan paths

The direct task path teaches the Otlet contract. The semantic path adds query ergonomics and freshness policy

## Map The Otlet Schema

The direct task path gives you the smallest loop. The rest of Otlet uses the same tables

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
                19
(1 row)
```

The base tables split into a few jobs:

- `runtimes`, `models`, and `runtime_slots` describe the local model runtime
- `tasks`, `model_selection_policies`, and `jobs` describe durable work and cheap-first escalation policy
- `outputs`, `action_type_schemas`, `actions`, `records`, `inference_receipts`, and `worker_events` describe what happened
- `production_policy` defines queue admission, leases, invalid output handling, stale-result behavior, and cleanup windows
- `watches`, `semantic_indexes`, and `semantic_materializations` make row-derived model state queryable
- `watches` and `semantic_join_indexes` do the same for pairwise candidate rows

Use `otlet.runs` for application reads. Use trace and status views for debugging, proof, and learning

## Create A Retry Task

The next examples reuse this task to show terminal failure evidence and safe requeueing

```sql
DROP TABLE IF EXISTS public.learning_retry_source;

CREATE TABLE public.learning_retry_source (
  id bigint PRIMARY KEY,
  note text NOT NULL
);

INSERT INTO public.learning_retry_source
VALUES (1, 'Retry me after a terminal failure');

SELECT name, input_query IS NOT NULL AS has_input_query, model_name
FROM otlet.create_task(
  'learning_retry_task',
  $$
    SELECT id::text AS subject_id, to_jsonb(learning_retry_source)::jsonb AS input
    FROM public.learning_retry_source
  $$,
  'Return exactly this JSON object: {"output":{"status":"ok"},"actions":[]}',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'qwen3_1_7b',
  '{"max_tokens":64,"reasoning":"off"}'::jsonb
);
```

Representative output:

```text
        name         | has_input_query |    model_name
---------------------+-----------------+------------------
 learning_retry_task | t               | qwen3_1_7b
(1 row)
```

## Cancel Queued Work

Cancellation changes job lifecycle state

Use a queued job that the worker has not claimed yet:

```sql
SELECT name, model_name
FROM otlet.create_task(
  'learning_cancel_task',
  NULL::text,
  'Lifecycle task used to show queued cancellation',
  '{"type":"object","required":["status"],"additionalProperties":false,"properties":{"status":{"enum":["ok"]}}}'::jsonb,
  'qwen3_1_7b',
  '{}'::jsonb
);

INSERT INTO otlet.jobs (task_name, subject_id, input)
VALUES ('learning_cancel_task', 'cancel-1', '{"kind":"manual queued job"}'::jsonb)
RETURNING id, task_name, subject_id, status, attempts;

SELECT id, task_name, subject_id, status, error
FROM otlet.cancel_job(
  (SELECT id FROM otlet.jobs WHERE task_name = 'learning_cancel_task' AND subject_id = 'cancel-1'),
  'learning example cancellation'
);

SELECT j.id, j.status, j.error, r.status AS receipt_status, r.error AS receipt_error
FROM otlet.jobs j
LEFT JOIN otlet.inference_receipts r ON r.job_id = j.id
WHERE j.task_name = 'learning_cancel_task'
ORDER BY j.id;
```

Representative output:

```text
         name         |    model_name
----------------------+------------------
 learning_cancel_task | qwen3_1_7b
(1 row)

 id |      task_name       | subject_id | status | attempts
----+----------------------+------------+--------+----------
  9 | learning_cancel_task | cancel-1   | queued |        0
(1 row)

 id |      task_name       | subject_id |  status  |             error
----+----------------------+------------+----------+-------------------------------
  9 | learning_cancel_task | cancel-1   | canceled | learning example cancellation
(1 row)

 id |  status  |             error             | receipt_status |         receipt_error
----+----------+-------------------------------+----------------+-------------------------------
  9 | canceled | learning example cancellation | canceled       | learning example cancellation
(1 row)
```

Canceled work still gets a receipt. A canceled model run still leaves evidence

## Understand Retry And Failed-Run Evidence

Otlet leaves failed jobs visible. A failed job is terminal, so you can queue the same task and subject again

The partial unique index only blocks duplicate active work:

```sql
CREATE UNIQUE INDEX jobs_active_subject_idx
ON otlet.jobs (task_name, subject_id)
WHERE status IN ('queued', 'running', 'cancel_requested');
```

This run creates one synthetic failed job, then lets `run_task` enqueue a second job for the same subject

The worker claims the second job and rejects the output against the strict JSON contract:

```sql
SELECT id, subject_id, status, attempts, error, raw_output IS NOT NULL AS has_raw_output
FROM otlet.jobs
WHERE task_name = 'learning_retry_task'
ORDER BY id;

SELECT id AS receipt_id, job_id, task_name, subject_id, status, schema_validation_status, error
FROM otlet.inference_receipts
WHERE task_name = 'learning_retry_task'
ORDER BY id;
```

Representative output:

```text
 id | subject_id | status | attempts |                                                                                                                                           error                                                                                                                                            | has_raw_output
----+------------+--------+----------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+----------------
 11 | 1          | failed |        1 | learning example synthetic failure                                                                                                                                                                                                                                                         | t
 12 | 1          | failed |        1 | invalid model JSON: The input is a single row of data. The output must be a JSON object with "output" and "actions" keys, and "actions" must be an array. The output must not have any markdown. The output must not have any prose. The output must not have any other keys than "output" | t
(2 rows)

 receipt_id | job_id |      task_name      | subject_id | status | schema_validation_status |                                                                                                                                           error
------------+--------+---------------------+------------+--------+--------------------------+--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
         11 |     11 | learning_retry_task | 1          | failed |                          | learning example synthetic failure
         12 |     12 | learning_retry_task | 1          | failed |                          | invalid model JSON: The input is a single row of data. The output must be a JSON object with "output" and "actions" keys, and "actions" must be an array. The output must not have any markdown. The output must not have any prose. The output must not have any other keys than "output"
(2 rows)
```

Failure keeps the raw output, stores the error, and records the attempt in a receipt

## Check Worker Events And Receipt Statuses

Events show worker behavior. Receipts show model behavior

```sql
SELECT event_type, count(*)
FROM otlet.worker_events e
JOIN otlet.jobs j ON j.id = e.job_id
WHERE j.task_name LIKE 'learning_%'
GROUP BY event_type
ORDER BY event_type;

SELECT task_name, status, count(*)
FROM otlet.inference_receipts
WHERE task_name LIKE 'learning_%'
GROUP BY task_name, status
ORDER BY task_name, status;
```

Representative output:

```text
 event_type   | count
---------------+-------
 job_canceled  |     1
 job_failed    |     2
 job_started   |     1
(3 rows)

      task_name       |  status  | count
----------------------+----------+-------
 learning_cancel_task | canceled |     1
 learning_retry_task  | failed   |     2
(2 rows)
```

Use events for worker behavior and receipts for model behavior

## Learn The Action Boundary

Otlet keeps the action vocabulary fixed and typed. The built-in action catalog says which actions need approval and which ones can create Otlet-owned records:

```sql
SELECT action_type, requires_approval, creates_record
FROM otlet.action_type_schemas
ORDER BY action_type;

SELECT otlet.action_validation_error(
  '{"type":"update_source_table","table":"public.anything"}'::jsonb
) AS rejected_action_error;
```

Representative output:

```text
   action_type   | requires_approval | creates_record
-----------------+-------------------+----------------
 create_record   | f                 | t
 merge_candidate | t                 | f
 new_entity      | f                 | f
 note            | f                 | t
 review_flag     | f                 | f
(5 rows)

 rejected_action_error
-----------------------
 unsupported action type
(1 row)
```

Otlet controls write authority here. The model can ask for an action, but Otlet decides which action types can become database state. Otlet stores unsupported actions as rejected evidence when they arrive with an accepted output. `otlet.action_status` shows approval, dry-run, and apply state

## Materialize Records Into Semantic State

Actions and records form one layer. Semantic materializations make those records reusable from queries

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

The trigger does not rerun the model. It marks the previous derived fact stale so reads can fail closed or request refresh

Plain `mark_stale` row watches treat INSERT as missing semantic state rather than stale semantic state. Exact planning shows the new row as unresolved until refresh or infer-now:

```sql
SELECT missing_subjects, queue_subjects, count_basis
FROM otlet.semantic_index_plan('demo_semantic_vendor_idx', true);
```

Use `{"on_change":"mark_stale_and_enqueue"}` when inserts should enqueue immediately

## Build A Row Watch

A row watch wraps a source table with an Otlet task, materialized records, stale tracking, trigger policy, and a native FDW table

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

## Read Through FDW

`create_watch` also creates an underlying native foreign table for row watches

The FDW table holds materialized semantic state:

```sql
SELECT 'semantic_fdw_rows_contract=' ||
       count(*)::text || '|' ||
       count(*) FILTER (WHERE body @> '{"status":"needs_review"}'::jsonb)::text || '|' ||
       count(*) FILTER (WHERE stale)::text AS semantic_fdw_rows_contract
FROM otlet.demo_semantic_vendor_idx_native;
```

Representative output:

```text
semantic_fdw_rows_contract=3|3|0
```

Use the FDW table for semantic rows. Use `semantic_index_current_rows` when you want the same state without a foreign table

## Inspect The Native FDW Plan

The native table uses `otlet_semantic_fdw`

```sql
EXPLAIN (ANALYZE, VERBOSE, COSTS, SUMMARY OFF, TIMING OFF)
SELECT *
FROM otlet.demo_semantic_vendor_idx_native
WHERE subject_id = '2';
```

Representative output excerpt:

```text
Foreign Scan on otlet.demo_semantic_vendor_idx_native
  Otlet Node: Semantic Foreign Scan
  Selected Path: semantic_lookup
  Stale Reasons: {}
  Count Basis: estimated
  Model Cost Source: runtime_slot
  Queue Subjects: 0
  Path Cost: 1.05
  Freshness: 1.00
  Pushed Subject Id: 2
```

The FDW runs inside Postgres as a native access path over Otlet-owned semantic materializations

## EXPLAIN Field Vocabulary

The SQL plan row, FDW EXPLAIN, and CustomScan EXPLAIN use the same terms for the planner contract

| Concept | SQL plan row | FDW EXPLAIN | CustomScan EXPLAIN | Notes |
| --- | --- | --- | --- | --- |
| Chosen path | `selected_path` | `Selected Path` | `Planner Selected Path` | CustomScan prefixes planner-owned decisions |
| Reason | `reason` | `Reason` | `Planner Reason` | Human-readable reason for the chosen path |
| Count basis | `count_basis` | `Count Basis` | `Count Basis` | `exact` means source rows were counted; `estimated` means planner estimates were used |
| Model cost basis | `model_cost_source` | `Model Cost Source` | `Model Cost Source` | Usually `task_receipt`, `runtime_slot`, `model_receipt`, or `static_fallback` |
| Stale reasons | `stale_reasons` | `Stale Reasons` | `Planner Stale Reasons` | JSON count by stale reason where stale subjects are counted |
| Infer-now prediction | `infer_now_subjects`, `fail_closed_subjects` | `Infer Now Subjects`, `Fail Closed Subjects` | `Planner Infer Now Subjects`, `Planner Fail Closed Subjects` | CustomScan also reports actual executor counters |
| Freshness basis | `semantic_index_current_rows.freshness_basis` | `freshness_basis` output column | `Preloaded Freshness Basis` | Surface-specific because it describes materialized row freshness, not only path choice |

Captured row-plan excerpt:

```text
selected_path | semantic_lookup
stale_reasons | {}
model_cost_source | task_receipt
count_basis | exact
```

Captured FDW EXPLAIN excerpt:

```text
Selected Path: semantic_lookup
Stale Reasons: {}
Count Basis: estimated
Model Cost Source: runtime_slot
Freshness: 1.00
```

Captured CustomScan EXPLAIN excerpt:

```text
Planner Selected Path: semantic_lookup
Planner Stale Reasons: {}
Count Basis: exact
Model Cost Source: task_receipt
Preloaded Fresh Subjects: 3
Preloaded Freshness Basis: {"mvcc_match": 3}
```

## Use CustomScan For Source-Row Predicates

Otlet can own a semantic predicate against the source table through a CustomScan

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
  Semantic Index: demo_semantic_vendor_idx
  Planner Selected Path: semantic_lookup
  Count Basis: exact
  Model Cost Source: task_receipt
  Planner Stale Reasons: {}
  Preloaded Fresh Subjects: 3
  Preloaded Freshness Basis: {"mvcc_match": 3}
  Actual Fresh Subjects: 3
```

The child scan reads the source table. Otlet strips the semantic predicate from the child plan and evaluates it against preloaded semantic state

## Fail Closed On Stale Rows

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

Fail closed means stale facts do not match because old model output looked right

## Let CustomScan Refresh A Stale Row With Infer-Now

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

Receipts carry executor provenance because the same model task can run from the worker queue or from CustomScan infer-now

## Build A Pair Watch

Row watches are source-table-oriented. Pair watches are candidate-query-oriented

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

Wait for the worker the same way the semantic index section does, or run `./scripts/otlet-demo.sh` for the compact proof. Then inspect the automatic materialization:

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

`pair_sources` installs the same stale trigger used by row indexes. Updates to declared source rows mark matching pair materializations through `_otlet_mvcc` dependencies, and `drop_watch` removes the trigger when no row index or pair watch still needs it

Now inspect the join index:

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

A semantic join index uses the same contract: jobs, outputs, actions, records, materializations, receipts

## Query A Semantic Join Predicate

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

## Inspect Trace Visibility Across The System

The trace visibility view reports links from receipts to outputs, actions, token steps, top-k alternatives, provenance, stale policy, and CustomScan infer-now

```sql
SELECT 'inference_visibility_status=' ||
       (receipt_count > 0)::text || '|' ||
       (token_steps > 0)::text || '|' ||
       (top_k_alternatives > 0)::text || '|' ||
       (max_detailed_trace_tokens <= 16)::text || '|' ||
       (max_detailed_trace_top_k <= 3)::text AS inference_visibility_contract
FROM otlet.inference_visibility_status;
```

Representative output:

```text
inference_visibility_status=true|true|true|true|true
```

Those booleans prove receipts, token steps, top-k alternatives, bounded trace tokens, and top-k width were present

## Inspect Runtime Status After Advanced Runs

Runtime status shows the resident model slot, cache bounds, memory samples, and last run metrics

```sql
SELECT runtime_status || '|' ||
       slot_state || '|' ||
       COALESCE(tokens_per_second::text, '') || '|' ||
       (COALESCE(inference_cache_entries, 0) <= COALESCE(inference_cache_max_entries, 0))::text || '|' ||
       COALESCE(worker_memory_sample_policy, '') AS runtime_contract
FROM otlet.runtime_status
WHERE runtime_name = 'linked_inproc'
  AND model_name = 'qwen3_1_7b'
LIMIT 1;
```

Representative output from the demo run:

```text
runtime_status_contract=ready|ready|60.34|true|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
```

The value reports a ready runtime, a ready model slot, bounded cache entries, and Linux process-status memory sampling after a worker run

## Inspect Production Policy

The production policy row and status views are ordinary SQL state under `otlet`: `production_policy_status`, `production_status`, `model_queue_status`, `worker_throughput_status`, and `cleanup_policy_state(true)`

Representative output from the demo contract:

```text
production_policy_contract=default|refresh_then_fail_closed|3|8
production_status_contract=true|true|true|true
model_queue_status_contract=queue_accepting|0|0
throughput_status_contract=queue_accepting|0|0|4|4|0
cleanup_policy_dry_run=0|0|0|0|0|0|true
```

## Know The Remaining Production Boundaries

Otlet installs internal production policy, bounded queues, leases, sweeps, validation evidence, action approval state, status views, and cleanup dry-run/apply functions. Your application owns tenant access, app roles, and who may approve or apply actions

Check row-level security:

```sql
SELECT 'rls_contract=' ||
       count(*)::text || '|' ||
       (count(*) FILTER (WHERE relrowsecurity))::text
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'otlet'
  AND c.relkind = 'r';

SELECT 'installed_policies=' || count(*)::text
FROM pg_policies
WHERE schemaname = 'otlet';
```

Representative output:

```text
rls_contract=19|0
installed_policies=0
```

Check default grants visible through `information_schema`:

```sql
SELECT 'grant_contract=' ||
       string_agg(privilege_type || ':' || n::text, '|' ORDER BY privilege_type)
FROM (
  SELECT privilege_type, count(*) AS n
  FROM information_schema.role_table_grants
  WHERE table_schema = 'otlet'
  GROUP BY privilege_type
) grants;
```

Representative output:

```text
grant_contract=DELETE:44|INSERT:44|REFERENCES:44|SELECT:44|TRIGGER:44|TRUNCATE:44|UPDATE:44
```

Your application owns these production boundaries:

- create app roles that expose only the views and functions you want
- add RLS or schema isolation if multiple tenants share the database
- schedule `otlet.cleanup_policy_state(false)` if your deployment wants periodic worker-event, trace, stale materialization, and rejected raw-output pruning
- expose `otlet.approve_action`, `otlet.reject_action`, `otlet.dry_run_action`, and `otlet.apply_action` only to roles that can operate actions
- allow only the action types your application can safely interpret

## Run The Full Demo Contract

The repo includes a script that exercises the entity-resolution path used in this learning file:

```sh
./scripts/otlet-demo.sh
```

Representative contract output from the demo run:

```text
direct_ask_contract=review_payment|2|2
entity_resolution_contract=4|same_entity|different_entity|4|4
model_selection_status_contract=true|true|true|4|3
action_type_contract=merge_candidate|new_entity
source_write_contract=5|...|5|...
semantic_join_auto_materialized=4
receipt_trace_contract=8|8|8|8
```

Use that script as the compact regression proof. Use this Markdown to learn the same system
