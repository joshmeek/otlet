# Otlet Worked Example

Use this as a learning file, not a test harness. The format follows Chen, Retnowati, Chan, and Kalyuga's worked-example research on [solution steps and knowledge transfer](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762): show the solved step first, keep each step's state visible, reduce search work for novices, then ask the learner to transfer the pattern to a nearby Otlet surface

The example teaches one high-interactivity Otlet task: entity resolution. You keep vendor rows in ordinary Postgres tables, select hard candidate pairs in SQL, enqueue durable model work, let the resident worker try a cheap local model and escalate hard rows to a stronger local model, validate `same_entity` / `different_entity` / `unclear`, record typed actions, and keep receipts

Output blocks below come from a real Docker-backed run on July 7, 2026 with `./scripts/otlet-setup.sh` and `./scripts/otlet-demo.sh`. Job IDs, receipt IDs, timestamps, token counts, timings, and token rates vary by machine and cache state

## Worked-Example Shape

Read the steps in order once before changing anything:

1. Start a local Otlet runtime
2. Inspect the source pairs
3. Create the task and queue four jobs
4. Read the accepted model outputs
5. Inspect cheap-to-strong model selection
6. Inspect typed actions and review state
7. Transfer the pattern to semantic joins, stale rows, traces, and production checks

The first six steps are retention checks: they teach the entity-resolution solution path. Step seven is the transfer check: the same contracts reappear in watches, CustomScan refresh, traces, and production status

## Step 1 - Start Local Otlet

Run the setup script:

```sh
./scripts/otlet-setup.sh
```

Observed setup output:

```text
postgres_url=postgres://postgres:postgres@127.0.0.1:55432/postgres
worker_count=1
cheap_model_artifact=/var/lib/postgresql/otlet-models/Qwen3-1.7B-Q8_0.gguf
strong_model_artifact=/var/lib/postgresql/otlet-models/Qwen3.5-4B-Q4_K_M.gguf
```

Open `psql` with both local model artifact paths:

```sh
docker exec -it otlet-postgres sh -lc '
  cheap_model_artifact="$(find /var/lib/postgresql -name Qwen3-1.7B-Q8_0.gguf -print -quit)"
  strong_model_artifact="$(find /var/lib/postgresql -name Qwen3.5-4B-Q4_K_M.gguf -print -quit)"
  psql -U postgres -d postgres \
    -v cheap_model_artifact="$cheap_model_artifact" \
    -v strong_model_artifact="$strong_model_artifact"
'
```

This is the solved starting state: Postgres is running, the Otlet worker exists, and both local GGUF artifacts are visible inside the container

## Step 2 - Inspect The Source Pairs

The source rows stay in `public`. Otlet receives only compact pair-shaped input:

```sql
SELECT p.pair_id, r.legal_name AS right_name,
       left(v.input->'candidate_evidence'->>'shared_stable_identifiers', 34) AS shared,
       left(v.input->'candidate_evidence'->>'conflicting_stable_identifiers', 42) AS conflicts
FROM public.otlet_demo_vendor_pair p
JOIN public.otlet_demo_vendor_entity r ON r.id = p.right_id
JOIN public.otlet_demo_vendor_pair_input v ON v.subject_id = p.pair_id
ORDER BY p.pair_id;
```

Observed output:

```text
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
|        pair_id         |          right_name           |               shared               |                 conflicts                  |
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
| vendor-1001:vendor-313 | North Star Medical Logistics  | []                                 | ["medical logistics versus freight vendor" |
| vendor-1001:vendor-314 | Northstar Freight Canada Inc. | []                                 | ["different country and Canadian legal ent |
| vendor-1001:vendor-42  | N-Star Freight Services       | ["same remittance account ending 8 | []                                         |
| vendor-1001:vendor-77  | Clearwater Medical Supplies   | []                                 | ["different industry and city", "no shared |
+------------------------+-------------------------------+------------------------------------+--------------------------------------------+
(4 rows)
```

The solved idea: SQL narrows the work to four candidate pairs before the model sees anything

## Step 3 - Queue Durable Model Work

The long SQL in [entity-resolution-walkthrough.md](entity-resolution-walkthrough.md) registers `qwen3_1_7b`, registers `qwen35_4b`, creates `entity_resolution_demo`, installs cheap-to-strong selection, and queues the four jobs:

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
```

Observed contract output:

```text
entity_resolution_contract=4|same_entity|different_entity|4|4
```

Read that as:

- 4 completed entity-resolution jobs
- `vendor-1001:vendor-42` resolved as `same_entity`
- `vendor-1001:vendor-77` resolved as `different_entity`
- 4 receipts attached to accepted outputs
- 4 accepted outputs passed schema validation

## Step 4 - Read The Solved Outputs

```sql
SELECT subject_id,
       output->>'match' AS match,
       output->>'confidence' AS confidence,
       output->>'reason' AS reason
FROM otlet.runs
WHERE task_name = 'entity_resolution_demo'
  AND output_id IS NOT NULL
ORDER BY subject_id;
```

Observed output:

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

The solved idea: `otlet.runs` is the learning surface for accepted outputs. You do not scrape model text from logs

## Step 5 - Inspect Model Selection

```sql
SELECT subject_id, attempt_index, selection_role, selection_status,
       model_name, output->>'match' AS match, output->>'confidence' AS confidence
FROM otlet.model_selection_attempts
WHERE task_name = 'entity_resolution_demo'
ORDER BY subject_id, attempt_index;
```

Observed output:

```text
+------------------------+---------------+----------------+------------------+------------+------------------+------------+
|       subject_id       | attempt_index | selection_role | selection_status | model_name |      match       | confidence |
+------------------------+---------------+----------------+------------------+------------+------------------+------------+
| vendor-1001:vendor-313 |             1 | cheap          | rejected         | qwen3_1_7b |                  |            |
| vendor-1001:vendor-313 |             2 | strong         | accepted         | qwen35_4b  | different_entity | high       |
| vendor-1001:vendor-314 |             1 | cheap          | rejected         | qwen3_1_7b |                  |            |
| vendor-1001:vendor-314 |             2 | strong         | accepted         | qwen35_4b  | different_entity | high       |
| vendor-1001:vendor-42  |             1 | cheap          | rejected         | qwen3_1_7b |                  |            |
| vendor-1001:vendor-42  |             2 | strong         | accepted         | qwen35_4b  | same_entity      | high       |
| vendor-1001:vendor-77  |             1 | cheap          | rejected         | qwen3_1_7b |                  |            |
| vendor-1001:vendor-77  |             2 | strong         | accepted         | qwen35_4b  | different_entity | high       |
+------------------------+---------------+----------------+------------------+------------+------------------+------------+
(8 rows)
```

The solved idea: a rejected cheap attempt is still evidence. The accepted strong attempt becomes trusted output

## Step 6 - Inspect Typed Actions

The model cannot mutate source tables. It can propose typed actions. Otlet validates the action vocabulary and review state:

```text
action_schema_contract=merge_candidate|new_entity|note|review_flag
action_type_contract=merge_candidate|new_entity
action_status_contract=4|4|4|0
failed_attempt_action_contract=0
```

The full demo then approves and dry-runs the merge candidate, rejects one `new_entity` action to exercise review state, and proves source rows did not change:

```text
action_approve_contract=approved|approved|demo approval reason
action_dry_run_contract=approved|approved|passed
action_apply_contract=approved|approved|not_applicable|action type has no apply path
action_reject_contract=rejected|rejected
source_write_contract=5|fa7672627cd7ab2a22aba2d9d7035815|5|fa7672627cd7ab2a22aba2d9d7035815
```

The solved idea: Otlet stores trusted actions, but the application still owns merge authority

## Step 7 - Transfer The Pattern

After the direct task works, transfer the same idea to semantic joins, stale rows, receipts, and production checks:

```text
semantic_join_auto_records=4|4
semantic_join_auto_materialized=4
semantic_join_lookup_contract=4|1|3
semantic_join_match_contract=true|true
semantic_join_stale_contract=4|0|fresh_after_lookup=0|receipts=8|8
receipt_trace_contract=8|8|8|8
inference_visibility_status=true|true|true|true|true
runtime_status_contract=ready|ready|35.71|true|true|true|none|linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run
planner_1m_contract=estimated|1000000|4.404|true
docker_crash_log_scan=ok
```

The transfer idea: the direct task, semantic join, CustomScan refresh, trace views, and production policy all expose the same database-owned proof chain: source row identity, job, receipt, output, action, materialization, freshness, and status

## Detailed Walkthroughs

Use these files when you want to run the solved steps by hand:

- [Entity resolution walkthrough](entity-resolution-walkthrough.md)
- [Runtime and traces](runtime-and-traces.md)
- [Semantic watches](semantic-watches.md)
- [Production contract](production-contract.md)

Use `./scripts/otlet-demo.sh` as the compact regression proof. Use this Markdown to learn the path before changing it
