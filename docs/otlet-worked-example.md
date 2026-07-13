# Otlet Worked Example

Use this learning file as a worked example, following the structure from [this study](https://www.tandfonline.com/doi/full/10.1080/01443410.2023.2273762)

Follow one Docker-backed Otlet entity-resolution loop: leave vendor rows in Postgres tables, select hard candidate pairs in SQL, enqueue durable model work, let the resident worker try a cheap local model and escalate hard rows to a stronger local model, validate `same_entity` / `different_entity` / `unclear`, record typed actions, and preserve receipts

The output blocks come from a Docker-backed run on July 13, 2026 with `./scripts/otlet-setup.sh` and `./scripts/otlet-demo.sh`. Job IDs, receipt IDs, hashes, timestamps, token counts, timings, and token rates are representative and vary by machine and cache state

This walkthrough runs as the extension owner because it registers models and tasks, reads raw attempt state, and administers watches. Production auditors use the redacted `otlet.audit_*` views. Reviewers receive `otlet.grant_operator_access(...)` before calling approval, correction, dry-run, or apply functions. See [production-contract.md](production-contract.md) for the exact grants

The default storage policy keeps assembled prompts in worker memory and removes raw model text and token text before receipt insertion. The examples inspect hashes, structured output, and numeric trace state

## Example Path

Run these steps in order:

1. Start a local Otlet runtime
2. Inspect the source pairs
3. Create the task and queue four jobs
4. Read the accepted model outputs
5. Inspect cheap-to-strong model selection
6. Inspect typed actions and review state
7. Check semantic joins, stale rows, traces, and production status

Steps 1-6 teach the direct task. Step 7 applies its contract to watches, CustomScan refresh, traces, and production status

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

Postgres now runs the Otlet worker with both local GGUF artifacts visible inside the container

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

SQL narrows the work to four candidate pairs before the model sees anything

## Step 3 - Queue Durable Model Work

The long SQL in [entity-resolution-walkthrough.md](entity-resolution-walkthrough.md) registers `qwen3_1_7b`, registers `qwen35_4b`, creates `entity_resolution_demo`, installs cheap-to-strong selection, and queues the four jobs:

```sql
SELECT otlet.run_task('entity_resolution_demo') AS queued_jobs;
```

Observed contract output:

```text
entity_resolution_contract=4|same_entity|different_entity|4|4
```

The contract fields report:

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

`otlet.runs` exposes accepted outputs through SQL

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

A rejected cheap attempt is still evidence. The accepted strong attempt becomes trusted output

## Step 6 - Inspect Typed Actions

The entity-resolution table stays unchanged. The model proposes typed actions, and Otlet validates the action vocabulary and review state:

```text
action_schema_contract=merge_candidate|new_entity|note|review_flag|update_row
action_type_contract=merge_candidate|new_entity
action_status_contract=4|4|4|0
failed_attempt_action_contract=0
```

The demo then approves and dry-runs the merge candidate, rejects one `new_entity` action to exercise review state, and proves source rows did not change:

```text
action_approve_contract=approved|approved|demo approval reason
action_dry_run_contract=approved|approved|passed
action_apply_contract=approved|approved|not_applicable|action type has no apply path
action_reject_contract=rejected|rejected
source_write_contract=5|fa7672627cd7ab2a22aba2d9d7035815|5|fa7672627cd7ab2a22aba2d9d7035815
```

Otlet stores trusted actions. The application still owns merge authority

The demo also registers a separate five-row table for the bounded `update_row` path. It proves accepted and rejected proposals, type-safe dry run, identical idempotency keys, operator apply, concurrent replay, stale source rejection, disabled-target rejection, protected-column preservation, and hashed receipts:

```text
bounded_proposal_contract=5|3|1|1|1|2|1
bounded_dry_run_contract=4|1|4|1
bounded_queue_contract=4|1
bounded_execution_contract=approved|bounded apply|1|DO_NOT_TOUCH_SENTINEL|pending||0|DO_NOT_TOUCH_SENTINEL|1|2|2|0
permission_contract=public=0/0/0|auditor=8/3|operator=8/9|definer=8/8|positive=7|denied=48
```

Only `row-1` changes through Otlet. Its allowed state, reason, and priority columns change once; its protected sentinel remains. `row-3` stays unchanged. The two replay receipts affect zero rows, and the two rejected apply attempts affect zero rows

## Step 7 - Check Semantic And Production Paths

After the direct task works, check semantic joins, portable watch definitions, stale rows, receipts, and production status:

```text
semantic_join_auto_records=4|4
semantic_join_auto_materialized=4
semantic_join_lookup_contract=4|1|3
semantic_join_match_contract=true|true
watch_replace_contract=true|true|true|true|true|true|true|true|true|true
watch_round_trip_contract=true|true|true|true|true
watch_import_failure_contract=9|true
candidate_removed_contract=0|true|candidate_removed|0|0|false|
candidate_changed_contract=1|true|candidate_changed|0
semantic_join_stale_contract=4|0|fresh_after_lookup=0|receipts=8|8
receipt_trace_contract=8|8|8|8
inference_visibility_status=true|true|true|true|true
direct_ask_runtime_fingerprint_contract=otlet_runtime_fingerprint_v1|true|true|Q4_K_M|otlet_raw_json_worker_v1|94a220cd6|512|8217751552
preload_admission_contract=failed|model_load_admission_rejected|rejected|true|true|true|true|0|true|true|true|true
runtime_status_contract=ready|ready|40.97|true|true|true|none|linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1
planner_1m_contract=estimated|1000000|4.305|true
performance_ratio_contract=40|50|1.250|16550|413.750
materialization_failure_status_contract=true|true
invariant_contract=0
docker_crash_log_scan=ok
```

Check these fields in each path: source row identity, job, receipt, output, action, materialization, freshness, and status

The candidate contracts show that removal and identical restoration queue no work. Changed candidate content queues one refresh and stays outside fresh lookup until that work completes. The pre-load contract shows that an explicit memory budget can reject a replacement model before tensor allocation while preserving the current resident model and worker

## Detailed Walkthroughs

Run the detailed paths by hand with these files:

- [Entity resolution walkthrough](entity-resolution-walkthrough.md)
- [Runtime and traces](runtime-and-traces.md)
- [Semantic watches](semantic-watches.md)
- [Production contract](production-contract.md)

Use this Markdown to learn the path, then run `./scripts/otlet-demo.sh` as the compact regression proof
