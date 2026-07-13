# Entity Resolution Walkthrough

Use this SQL walkthrough to expand the entity-resolution path from `docs/otlet-worked-example.md`. Start with `./scripts/otlet-setup.sh`, then paste each section into the `psql` session described there

Run the sections in order before adapting them. Each section names the state it creates and the output to inspect. Follow-up checks live in [runtime-and-traces.md](runtime-and-traces.md), [semantic-watches.md](semantic-watches.md), and [production-contract.md](production-contract.md)

The setup and inspection sections run as the extension owner. A delegated reviewer reads `otlet.audit_review_export` and receives `otlet.grant_operator_access(...)` before using the action review functions. Raw `otlet.review_queue`, task configuration, receipts, and trace state remain owner-only

Receipts keep prompt and raw-output hashes under the default storage policy. Accepted output and rejected structured candidates remain available without persisting the assembled prompt or raw model text

## Step 1 - Register The Models

```sql
CREATE EXTENSION IF NOT EXISTS otlet;

SELECT otlet.register_model(
  'qwen3_1_7b',
  :'cheap_model_artifact'
);

SELECT otlet.register_model(
  'qwen35_4b',
  :'strong_model_artifact'
);
```

The Otlet background worker runs `linked_inproc` inference. It loads a local GGUF through in-process llama.cpp and keeps the model resident across jobs. Postgres exposes the queue, source row identity, output validation, receipts, traces, and runtime state through SQL

## Step 2 - Create The Source Tables

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

## Step 3 - Clear Old Demo State

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

Delete prior demo state to make the example rerunnable. Production flows retain their history

## Step 4 - Create The Task

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

Decision-rule presets are immutable. Edit behavior by creating a new preset name, not by rewriting the shipped preset row:

```sql
DO $$
BEGIN
  UPDATE otlet.decision_rule_presets
  SET decision_contract = decision_contract || '{"demo_edit":true}'::jsonb
  WHERE name = 'row_triage_decision_v1';
  RAISE EXCEPTION 'expected preset update to be rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'otlet decision rule preset row_triage_decision_v1 is immutable%' THEN
      RAISE;
    END IF;
END;
$$;

SELECT 'preset_immutability_contract=raised' AS preset_immutability_contract;
```

Representative output:

```text
preset_immutability_contract=raised
```

If the model returns malformed JSON, missing fields, unknown fields, or values outside the enum, Otlet marks the job failed and keeps the raw evidence. Otlet stores no trusted output or records

## Step 5 - Enqueue The Jobs

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

The transaction creates durable database work, and the resident worker claims it

The queue keeps model work out of the client request. SQL shows each job at any status: queued, running, complete, failed, or canceled

## Step 6 - Watch The Worker

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

Wait a moment and run the query again while jobs remain active

Representative output:

```text
+------+------------------------+------------------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------+
|  id  |       task_name        |       subject_id       |  status  | attempts |          created_at           |          started_at           |          finished_at          | error |
+------+------------------------+------------------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------+
| 2104 | entity_resolution_demo | vendor-1001:vendor-313 | complete |        1 | 2026-07-07 14:01:06.063557+00 | 2026-07-07 14:01:06.075946+00 | 2026-07-07 14:02:39.745305+00 |       |
| 2105 | entity_resolution_demo | vendor-1001:vendor-314 | complete |        1 | 2026-07-07 14:01:06.063557+00 | 2026-07-07 14:01:06.075946+00 | 2026-07-07 14:03:23.793005+00 |       |
| 2106 | entity_resolution_demo | vendor-1001:vendor-42  | complete |        1 | 2026-07-07 14:01:06.063557+00 | 2026-07-07 14:01:06.075946+00 | 2026-07-07 14:04:10.308073+00 |       |
| 2107 | entity_resolution_demo | vendor-1001:vendor-77  | complete |        1 | 2026-07-07 14:01:06.063557+00 | 2026-07-07 14:01:06.075946+00 | 2026-07-07 14:04:50.716933+00 |       |
+------+------------------------+------------------------+----------+----------+-------------------------------+-------------------------------+-------------------------------+-------+
(4 rows)
```

The worker coordinates through database tables. It claims jobs from `otlet.jobs`, writes outputs to Otlet tables, and records worker events in `otlet.worker_events`

## Step 7 - Read The Model Output

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
+------------------------+------------------+------------+-------------------------------------------------------------+
|       subject_id       |      match       | confidence |                           reason                            |
+------------------------+------------------+------------+-------------------------------------------------------------+
| vendor-1001:vendor-313 | different_entity | high       | Conflicting stable identifiers found.                       |
| vendor-1001:vendor-314 | different_entity | high       | 4 conflicting stable identifiers found                      |
| vendor-1001:vendor-42  | same_entity      | high       | Same remittance account and tax ID match                    |
| vendor-1001:vendor-77  | different_entity | high       | Conflicting stable identifiers indicate different entities. |
+------------------------+------------------+------------+-------------------------------------------------------------+
(4 rows)
```

`otlet.runs` gives SQL access to accepted jobs, outputs, and receipts

Otlet stores each result as database state

Direct entity-resolution tasks ask the model for one typed action. Otlet stores actions when they attach to an accepted, schema-valid output receipt

## Step 8 - Inspect Typed Actions

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

## Step 9 - Review The Queue

`otlet.review_queue` gathers actions that need attention, abstention outputs, and review flags with receipt and source-freshness context:

```sql
SELECT queue_kind, next_operator_step, task_name, watch_name, subject_id, action_id, receipt_id, source_stale
FROM otlet.review_queue
WHERE task_name IN ('entity_resolution_demo', 'demo_entity_resolution_idx_task')
ORDER BY created_at, task_name
LIMIT 5;
```

Representative output:

```text
    queue_kind    | next_operator_step |            task_name            |         watch_name         | subject_id | action_id | receipt_id | source_stale
------------------+--------------------+---------------------------------+----------------------------+------------+-----------+------------+--------------
 pending_approval | approve            | demo_entity_resolution_idx_task | demo_entity_resolution_idx | vendor-42  |        35 |         85 | f
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

The eval export includes the correction:

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

Eval label confidence uses `low`, `medium`, or `high`. Record calibration notes in `reason` or task-specific fields rather than expanding `expected_confidence`

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

Semantic materializations store two row identities. `source_hash` is MVCC-coupled provenance for the exact row version that produced a job. `content_hash` is the model-input identity used for freshness, excluding Otlet's MVCC envelope so benign row churn can revalidate without rerunning the model

Input shaping fields are top-level in the task input. Row watches wrap source rows under `row`, so `evidence_fields` does not traverse `row.evidence`; project evidence to a top-level object in the input or pair candidate query. Pair watches treat the candidate query as the shaping declaration, with `strip_keys` available for top-level volatile fields

## Step 10 - Learn The Action Boundary

Otlet uses a fixed, typed action vocabulary. The built-in action catalog says which actions need approval and which ones can create Otlet-owned records:

```sql
SELECT action_type, requires_approval, creates_record, applyable
FROM otlet.action_type_schemas
ORDER BY action_type;

SELECT otlet.action_validation_error(
  '{"type":"update_source_table","table":"public.anything"}'::jsonb
) AS rejected_action_error;
```

Representative output:

```text
   action_type   | requires_approval | creates_record | applyable
-----------------+-------------------+----------------+-----------
 create_record   | f                 | t              | t
 merge_candidate | t                 | f              | f
 new_entity      | f                 | f              | f
 note            | f                 | t              | t
 review_flag     | f                 | f              | f
 update_row      | t                 | f              | t
(6 rows)

 rejected_action_error
-----------------------
 unsupported action type
(1 row)
```

Otlet enforces write authority through the action catalog. The model can request an action; Otlet decides which action types can become database state. Otlet stores unsupported actions as rejected evidence when they arrive with an accepted output. `otlet.action_status` shows approval, dry-run, and apply state

Otlet exposes one source-table write action: `update_row`. The extension owner registers one ordinary table, its sole primary key, and the columns Otlet may update:

```sql
SELECT otlet.register_action_target(
  'review_items',
  'app.review_items'::regclass,
  'id',
  ARRAY['review_state', 'review_reason']::name[]
);
```

The model-authored action contains data, not SQL:

```json
{
  "type": "update_row",
  "body": {
    "target": "review_items",
    "identity": "item-42",
    "changes": {
      "review_state": "approved",
      "review_reason": "matched source evidence"
    }
  }
}
```

The identity must equal the job subject, the target must equal the modeled source table, and the target registration must list each changed key. Version one supports one ordinary table, one single-column primary key, one row, and at most 16 changed columns. It rejects raw SQL, predicates, expressions, joins, generated columns, identity columns, partitions, foreign tables, views, temporary tables, Otlet tables, and RLS targets

Review the typed result before approval, then apply it:

```sql
SELECT dry_run_status FROM otlet.dry_run_action(:action_id);
SELECT approval_status FROM otlet.approve_action(:action_id, 'reviewed source evidence');
SELECT apply_status FROM otlet.apply_action(:action_id);
SELECT apply_status FROM otlet.apply_action(:action_id);
```

The first apply updates one row and stores before/after hashes. The second returns `replayed`, writes no row, and links to the original receipt. If the source row, target registration, schema, or privileges changed after dry run, apply fails closed. `correct_action` still means reject plus eval label; a corrected executable write is a new proposal with a new dry run and approval
