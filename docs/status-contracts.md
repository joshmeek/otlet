# Otlet status contracts

Otlet keeps live runtime, planner, cache, trace, and semantic state in SQL views. Static design ledgers live here so SQL views do not pretend documentation is live database state

Use this doc when you maintain Otlet internals or need to understand why a status view exposes a certain field. It is not the first user guide. Start with the README and worked example if you want to run Otlet

The tables below describe two things:

- which Postgres extension surface Otlet uses for model-access behavior such as planning, scanning, explaining, cancellation, freshness, and receipts
- which resource limits Otlet enforces for infer-now requests, resident cache entries, cache bytes, and detailed token traces

The SQL views show current database state. This file records stable design choices and policy names that should not be hardcoded into live views as fake runtime data

## Model-access callback map

| Area | Callback idea | Current Otlet surface | Decision |
| --- | --- | --- | --- |
| path creation | model path create | `set_rel_pathlist_hook` CustomPath | extension path wins |
| costing | model cost estimate | `semantic_index_plan` and CustomPath costs | extension path wins |
| begin scan | begin model scan | `BeginCustomScan` and `BeginForeignScan` | extension path wins |
| execute scan | execute model scan | `ExecCustomScan` and `IterateForeignScan` | extension path wins |
| rescan | rescan model scan | `ReScanCustomScan` and `ReScanForeignScan` | extension path wins |
| end scan | end model scan | `EndCustomScan` and `EndForeignScan` | extension path wins |
| explain | explain model scan | `ExplainCustomScan` and `ExplainForeignScan` | extension path wins |
| receipts | model receipt sink | `otlet.inference_receipts` | extension path wins |
| materialization | model materialization sink | `otlet.semantic_materializations` | extension path wins |
| resource owner | model resource owner | resident worker linked cache | extension path wins |
| memory accounting | model memory accounting | `otlet.runtime_status` worker memory fields | extension path wins |
| cancellation | model cancel callback | cancel jobs plus linked runtime token checks | extension path wins |
| freshness | model snapshot freshness check | MVCC source hash and stale policy | extension path wins |
| EPQ recheck | recheck model access tuple | volatile SQL filter and rowmark fallback | extension fallback is acceptable |
| parallel DSM estimate | estimate model access DSM | serial leader-owned resident worker | defer until parallel model access wins |
| parallel DSM init | initialize model access DSM | serial leader-owned resident worker | defer until parallel model access wins |
| parallel worker init | initialize model access worker | serial leader-owned resident worker | defer until parallel model access wins |
| parallel worker shutdown | shutdown model access worker | serial leader-owned resident worker | defer until parallel model access wins |
| parallel counters | merge model access counters | leader EXPLAIN counters only | defer until parallel model access wins |
| strategy dispatch | model strategy dispatch | typed semantic operators without model opclasses | do not fake opclass or AMOP rows |

## Worker resource policies

| Resource | Cap source | Live SQL field | Breach behavior |
| --- | --- | --- | --- |
| infer-now slots | worker shared memory | `runtime_status.infer_now_slot_count`, `runtime_status.infer_now_queue_depth` | busy queue returns zero and increments busy rejections |
| infer-now task name bytes | worker shared memory | `runtime_status.infer_now_task_cap_bytes`, `runtime_status.infer_now_task_bytes` | SQL error before queue insert |
| infer-now subject id bytes | worker shared memory | `runtime_status.infer_now_subject_cap_bytes`, `runtime_status.infer_now_subject_bytes` | SQL error before queue insert |
| infer-now input JSON bytes | worker shared memory | `runtime_status.infer_now_input_cap_bytes`, `runtime_status.infer_now_input_bytes` | SQL error before queue insert |
| infer-now error bytes | worker shared memory | `runtime_status.infer_now_error_cap_bytes`, `runtime_status.infer_now_error_bytes` | worker error text is truncated to cap |
| infer-now wait milliseconds | requester wait loop | `runtime_status.infer_now_max_wait_ms`, `runtime_status.infer_now_last_elapsed_ms` | timeout cancels running job or releases unstarted slot |
| resident inference cache entries | resident worker memory | `runtime_status.inference_cache_max_entries`, `runtime_status.inference_cache_entries` | bounded LRU eviction |
| resident inference cache bytes | resident worker memory | `runtime_status.inference_cache_max_bytes`, `runtime_status.inference_cache_bytes` | bounded LRU eviction |
| generation trace tokens | receipt trace JSONB | `inference_visibility_status.max_detailed_trace_tokens` | runtime options reject values above cap |
| generation trace alternatives | receipt trace JSONB | `inference_visibility_status.max_detailed_trace_top_k` | runtime options reject values above cap |
