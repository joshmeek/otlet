# Otlet Benchmarks

The benchmark harness measures local GGUF models as Otlet workers over compact Postgres row evidence. It does not measure general knowledge

Run the Otlet proof path first:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

Run the fast probe before spending time on a full benchmark. It uses the resident Otlet worker on five row-shaped JSON cases and reports viability, pass count, schema passes, token rate, steady decode rate, p95 generation time, p95 TTFT, p95 prompt decode time, and effective llama.cpp decode/batch thread counts:

```sh
OTLET_PROBE_LIMIT_MODELS=ministral3_3b,qwen35_4b,qwen3_1_7b ./benchmarks/quick_probe.sh
```

Set `OTLET_PROBE_DOWNLOAD=1` when you want the probe to fetch a missing GGUF. Downloads go under `/var/lib/postgresql/otlet-probe-models` and the script removes them on exit unless `OTLET_PROBE_KEEP_MODELS=1`

## Current Model Decision

The raw `/no_think` prompt and Q4_K_M artifact remain the defaults. A fresh three-sample control after one warmup passed `5/5` correctness and schema cases with median `27.74` mean tok/s, `27.28` steady tok/s, `3158 ms` p95 generation, `1012 ms` p95 TTFT, and `997 ms` p95 prompt decode

Disposable binaries built from the same commit tested the current prompt, the same prompt without `/no_think`, and the GGUF's embedded one-user chat template. The embedded template renders the same byte boundary as the smallest explicit Qwen ChatML wrapper, so those two labels shared one runtime probe

| prompt | correctness | schema | result |
| --- | ---: | ---: | --- |
| raw with `/no_think` | `5/5` | `5/5` | keep |
| raw without `/no_think` | `4/5` | `4/5` | reject |
| embedded GGUF template / explicit ChatML | `0/5` | `0/5` | reject |

The same-base quantization probe pinned `unsloth/Qwen3.5-4B-GGUF` at `e87f176479d0855a907a41277aca2f8ee7a09523`. Q4_K_M passed `5/5` at `26.13/25.69` mean/steady tok/s. Q5_K_M used 14.8 percent more artifact and runtime-model bytes, loaded in `9841 ms` instead of `5589 ms`, ran at `17.43/17.12` tok/s, and returned `flag` on the adversarial row-text case instead of the evidence-derived `pass`. Q5 stopped at the fast gate, so it did not consume a 447-job full run

These are Otlet SQL-path results for this fixture and host, not general model rankings. Re-run the probe after changing the base model, prompt, runtime, or hardware

## Quick-Probe Controls

Find current Hugging Face GGUF candidates before adding a model row:

```sh
python3 benchmarks/find_candidates.py
```

Sweep CPU thread counts through that probe:

```sh
for threads in 1 2 4 6 8 12; do
  OTLET_PROBE_LIMIT_MODELS=qwen3_1_7b,qwen35_4b \
    OTLET_PROBE_LLAMA_THREADS="$threads" \
    ./benchmarks/quick_probe.sh |
    awk -v threads="$threads" 'NR == 1 && threads == 1 { print "threads\t" $0 } NR > 1 { print threads "\t" $0 }'
done
```

On the measured host, concurrent infer-now callers fill the bounded shared-memory queue. The default resident worker serializes llama.cpp generation

The probe accepts `OTLET_PROBE_LLAMA_THREADS=<n>`, `OTLET_PROBE_LLAMA_BATCH_THREADS=<n>`, and `OTLET_PROBE_RUNTIME_OPTIONS='{"max_tokens":64}'` for one run. The setup path accepts deployment-level llama.cpp knobs before `./scripts/otlet-setup.sh`:

| knob | scope | default |
| --- | --- | --- |
| `OTLET_WORKER_COUNT` | resident Postgres workers | `1`, capped at `4`, research control |
| `OTLET_LLAMA_THREADS` | decode threads | visible cores capped at `6` |
| `OTLET_LLAMA_BATCH_THREADS` | prompt-decode thread pool | decode-thread value |
| `OTLET_LLAMA_BATCH_TOKENS` | logical prompt batch tokens | `512` |
| `OTLET_LLAMA_UBATCH_TOKENS` | physical prompt ubatch tokens | `512` |
| `OTLET_LLAMA_MMAP` | model mmap toggle | llama.cpp default |
| `OTLET_LLAMA_MLOCK` | lock model pages in memory | llama.cpp default |
| `OTLET_LLAMA_FLASH_ATTN` | `auto`, `on`, or `off` flash attention | llama.cpp default |
| `OTLET_LLAMA_NO_PERF` | skip llama.cpp perf counters | `true` |
| `OTLET_LLAMA_KV_TYPE` | set both KV cache types: `f16`, `q8_0`, `q4_0` | llama.cpp default |
| `OTLET_LLAMA_KV_TYPE_K` | set K cache type independently | llama.cpp default |
| `OTLET_LLAMA_KV_TYPE_V` | set V cache type independently | llama.cpp default |
| `OMP_PROC_BIND`, `OMP_PLACES`, `GOMP_CPU_AFFINITY` | OpenMP CPU placement | unset |

Host hardware determines these controls. Re-run `./scripts/otlet-setup.sh` after changing startup knobs so the worker process starts with the new environment

Use `OTLET_WORKER_COUNT=1` unless a local probe shows a wall-clock win and acceptable RSS. A qwen35_4b infer-now probe on the current Docker CPU measured four warm concurrent callers like this:

| setup | wall time | shape | result |
| --- | ---: | --- | --- |
| `1` worker, `6` threads | `11.22s` | serialized jobs | best wall time, about `25-30 tok/s` |
| `2` workers, `6` threads each | `13.02s` | two overlapping jobs | slower from CPU oversubscription |
| `2` workers, `3` threads each | `11.51s` | two overlapping jobs | near baseline, with about double resident model memory |

The two-worker probes produced overlapping llama.cpp generation from separate Postgres workers and increased wall time or memory on qwen35_4b. Treat worker count as a research control until Otlet has per-worker RSS totals, model-specific admission caps, queue fairness proof, and database responsiveness checks

## Measured Runtime Decisions

### Resident-model queue preference

A bounded warm-model scheduler was rejected at commit `0f4081a6`. The candidate identified the resident model from the latest worker-lifetime `model_swap` event and allowed one warm-model claim before returning to strict task-cursor order. The existing retry rank, per-task FIFO order, active-job cap, lease handling, and `SKIP LOCKED` claim stayed in place

The paired A/B workload alternated four tasks across qwen3_1_7b and qwen35_4b, queued two 64-token cache-disabled jobs per task, and claimed one job at a time. All 48 jobs across six runs completed with schema-valid output. Both variants used one resident worker and six decode and batch threads on the same 12-core ARM64 host. The model fingerprint hashes were `7a1b434a2888535d` and `e66bad85956d6d75`; the runtime fingerprint hashes were `ad374ff9a8f1a02c` and `e5797a21096dfddf`

| pair | variant | model loads | load time | wall time | maximum queue wait |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | task cursor | 6 | 35.940s | 66.059s | 64.631s |
| 1 | warm preference | 5 | 44.690s | 105.258s | 88.564s |
| 2 | task cursor | 6 | 41.677s | 80.385s | 78.841s |
| 2 | warm preference | 5 | 27.506s | 48.115s | 40.468s |
| 3 | task cursor | 6 | 34.155s | 62.892s | 61.235s |
| 3 | warm preference | 5 | 34.583s | 86.740s | 75.488s |

The candidate median reduced model loads from six to five and load time from 35.940s to 34.583s. Median wall time regressed from 66.059s to 86.740s, and median maximum queue wait regressed from 64.631s to 75.488s. The candidate also passed focused task-turn, continuous-arrival starvation, lease, cancellation, and concurrent-claim checks, but failed the wall-time and queue-wait retention gate. No scheduler code was retained

### Same-model cross-task claims

The task-cursor scheduler at `962dcc49` opened one claim per task even when several one-row tasks used the same model. A five-run model-free fixture compared 1, 4, and 16 direct qwen35 tasks with `worker_claim_batch_size = 8` on PostgreSQL 18.4. No model was loaded or executed

| tasks | task-cursor claims | cross-task claims | task-cursor jobs/claim | cross-task jobs/claim | task-cursor drain | cross-task drain |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 | 1 | 1 | 0.370ms | 0.265ms |
| 4 | 4 | 1 | 1 | 4 | 0.690ms | 0.435ms |
| 16 | 16 | 2 | 1 | 8 | 3.264ms | 0.877ms |

The retained claim fills each batch by task round, advances the cursor to the last claimed task, and groups only tasks with the same base model, artifact, and cheap/strong policy models. Two simultaneous claimers took eight unique jobs each from a 16-task queue. Expired running jobs, cancel-requested jobs, per-task FIFO order, model-policy separation, queue caps, and the full demo stayed valid. Batch events now include every claimed task in `task_names`

### Bounded fallback window

Increasing the claim batch from 8 to 16 was tested as the smallest way to coalesce adjacent cheap-to-strong work without adding another worker queue. The candidate used only the existing claim, lease, cancellation, and in-batch fallback paths

A rotated three-pair workload queued 16 cache-disabled policy jobs. Every cheap attempt failed schema validation and every strong attempt completed with schema-valid output, forcing the maximum fallback load. Both variants used one resident worker and the same qwen3_1_7b and qwen35_4b runtime fingerprints

| pair | claim batch | model loads | load time | wall time | maximum queue wait |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 8 | 4 | 24.937s | 61.425s | 33.538s |
| 1 | 16 | 2 | 14.409s | 44.213s | 0.660s |
| 2 | 8 | 4 | 39.388s | 79.972s | 38.623s |
| 2 | 16 | 2 | 14.677s | 45.432s | 4.191s |
| 3 | 16 | 2 | 27.397s | 81.591s | 4.005s |
| 3 | 8 | 4 | 96.194s | 153.976s | 80.366s |

The median moved from four to two loads, 39.388s to 14.677s of load time, and 79.972s to 45.432s wall time. The larger claim still failed the cancellation gate. In a 16-job direct workload, the last job stayed queued under batch 8 and canceled in 0.000s. Batch 16 claimed it immediately, so cancellation remained requested for 17.213s while the worker processed the preceding jobs. Otlet keeps the default at 8 and adds no cross-batch deferred state

### Single-context batching

The current linked llama.cpp API can isolate multiple sequence IDs, KV positions, samplers, JSON stopping, and cancellation in one context. The smallest Otlet prototype still failed the combined throughput and memory gate:

| probe | wall time | peak worker RSS | result |
| --- | ---: | ---: | --- |
| 4 sequential jobs | `22.308s` | `5.695 GB` | control |
| 4 batched jobs | `24.176s` | higher | reject: slower |
| 8 sequential jobs, paired control | `28.338s` | `5.919 GB` | control |
| 8 batched jobs, 512-token buffer | `20.574s` | `6.605 GB` | reject: about 686 MB more RSS |
| 8 batched jobs, 128-token buffer | `35.002s` | `6.266 GB` | reject: slower and still larger |

All retained comparisons used one worker, six threads, the same qwen35 task and prompt identity, cache disabled, and `8/8` correct schema-valid outputs. One-client `SELECT 1` latency during the fastest batch was no worse than sequential load. Dropping the resident sequential context reduced the extra peak to about 290 MB, but bounded buffers then lost the wall-time win. Otlet keeps the sequential decoder and reruns this experiment after the linked runtime, model, or memory envelope changes

Requester timeout is a separate correctness contract. The resident worker persists the existing shared-memory abort through `otlet.cancel_job` during prompt/decode probes and at the output-acceptance boundary. The demo requires a canceled receipt, zero outputs, zero actions, and one healthy worker after the caller transaction raises

### Multi-model residency

The worker runs cheap attempts for a claimed policy batch before its strong fallbacks. Both four-row entity-resolution demo batches recorded two model swaps. A forced synchronous alternating workload paid a load on each call: cheap/strong/cheap/strong took `54.277s`, and the reverse order took `45.746s`. Cheap loads were `5.172-5.753s`; strong loads were `6.172-9.035s`. All eight outputs passed their schemas

A two-entry cache does not fit this runtime. Cold worker RSS was `27.2 MB`; the lowest post-run cheap and strong RSS samples were `4.345 GB` and `5.623 GB`. Their additive projection, subtracting the cold worker once, is `9.941 GB` against `8.218 GB` of memory. That is `1.723 GB` over physical memory before reserving headroom for Postgres. We retained no cache prototype

One-client `SELECT 1` load during the alternating probe completed `1,072,092` transactions with zero failures at `45us` p50, `132us` p95, and `38.448ms` max. The installed GGUFs have no expert or MTP heads, and the installed model set has no compatible draft model. The pinned crate exposes MTP bindings, but its smallest real caller fails to link on unresolved `common_speculative_*` symbols. Otlet keeps one resident context and treats multi-residency, speculative decoding, and expert streaming as new experiments after the memory envelope or installed artifacts change

### Persisted inference cache

Otlet keeps the process-local inference-output cache. The fresh demo produced 13 cache-enabled attempts, one hit, 12 misses, a three-entry and 880-byte high-water mark, and zero evictions. A later research sequence reached 13 entries and 2,941 bytes without eviction. The 512-entry cap would use about 116 KiB at that observed average, far below the 8 MiB byte cap

One stable qwen35 row measured a `9.452s` enabled miss, a `0.503s` exact hit, a `3.189s` cache-disabled warm run, and a `15.310s` miss after restart. These four runs produced the same schema-valid raw-output and runtime-contract hashes. A second cold miss under one-client `SELECT 1` load completed while 444,899 database transactions ran with zero failures at `47us` p50 and `100us` p95

No installed workload records eviction followed by a repeated-identity miss, and the 447-job full benchmark disables inference caching to measure live generation. A durable cache would persist exact raw envelopes despite the default hash-only evidence policy and duplicate trusted state already kept in outputs and semantic materializations. Otlet adds no disk cache

### Cache-hit completion path

The earlier `0.503s` exact-hit result included a 500 ms shell polling interval. Runtime-stage timing on commit `f57dea7d` found no corresponding completion cost. Ten direct qwen35 exact hits measured `3ms` requester p50 and `10.05ms` p95. Ten supported queued `run_task` hits measured `11.5ms` end-to-end p50 and `25.7ms` p95, including `5ms` median queue wait and `7.5ms` median worker time. Exact hits for row-watch and pair-watch tasks completed in `16ms` and `6ms`, including semantic materialization

A real worker restart cleared the cache. The next identical request missed in `13.857s`, including `6.311s` model load, `262ms` context creation, `5.679s` prompt decode, and `1.474s` generation; the following exact hit took `8ms`. Disabling the cache kept the generation path and reported `disabled` instead of a hit

Cache insertion remains after raw-envelope parsing, action parsing, and schema validation. Hits repeat those checks and require the full content, contract, runtime-output, and model identity before accepting cached bytes. Successful completion already writes the job, receipt, output, actions, runtime slot, and event in one SQL transition. Removing validation or merging fault-isolated metrics and materialization work would weaken the contract to optimize noise, so Otlet retains the existing path

### Worker lifecycle transaction fusion

An accepted attempt previously used three transactions after model execution: runtime metrics, job completion, and semantic materialization. Otlet now keeps best-effort metrics independent and runs completion plus materialization in one transaction. Materialization has its own guarded subtransaction, so its failure rolls back semantic writes without erasing the completed job, receipt, output, actions, runtime slot, or completion event

Fifty qwen35 exact hits measured `4ms` requester p50 and `5ms` p95 before fusion, then `3ms` p50 and `4ms` p95 after fusion. Median worker time fell from `3ms` to `2ms`. The accepted-success boundary fell from three transactions to two without moving lease renewal, cancellation, failed-attempt, or metrics recovery boundaries

Failure injection on semantic record insertion left the job complete with one receipt, one output, a `semantic_materialization_failed` event, one healthy worker, and a successful later materialization retry. Failure injection inside `complete_job` previously restarted the worker and left a running lease. The guarded path instead produced one terminal failed job, one failed receipt, zero outputs, one healthy worker, and no crash finding. The full demo and five-case qwen35 probe passed after the change

### Optional startup model preload

`production_policy.preload_model_name` optionally loads one registered local GGUF and its context when the resident worker starts. The default is `NULL`. Preload uses the same model construction, artifact fingerprint, runtime options, RSS budget, system-memory, cgroup, and llama.cpp projection checks as a request. It creates no job or receipt. Success populates `runtime_status` and emits `model_preload_succeeded`; failure emits `model_preload_failed` once for that worker start and leaves the worker available

Three same-host qwen35 restart pairs measured cold first requests at `10.131s`, `10.434s`, and `9.799s`. Preloaded first requests took `5.041s`, `5.545s`, and `5.795s`. Median first-request latency fell from `10.131s` to `5.545s`, or 45.3 percent. The measured preload used `4.994s` model load and `106ms` context construction, held `5.772 GB` worker RSS instead of the `15 MB` cold worker, and removed model load and context time from the first receipt

One-client read latency averaged `0.053ms` during preload with 225,800 transactions and zero failures, compared with `0.051ms` and zero failures while the worker stayed cold. Missing registration, invalid GGUF, unreadable GGUF, and a one-byte RSS budget each produced one failure event, one stable worker PID, and no retry loop. Keep the option unset unless predictable first-request latency is worth resident memory before demand

### Cross-batch task-contract cache

The resident worker keeps the 16 most recently used exact task contracts across claim batches. A hit reuses parsed runtime options, contract hashes, status JSON, rendered schema, and the static prompt prefix without retaining source input, shaped prompts, raw output, or evidence. Instruction, schema, runtime options, input shaping, decision contract, configured model, artifact path, or artifact hash changes force a miss. A worker restart clears the cache

A release-mode fixture repeated a 100-field schema and 4,000-byte instruction 20,000 times. Clearing the task cache for each simulated one-job batch took `220.824ms`, or `11.041us` per preparation. The bounded cross-batch cache took `63.806ms`, or `3.190us` per preparation, a 71.1 percent reduction. Exact hits perform no new task-contract or prompt-prefix heap construction. The five-case qwen35 probe and full demo passed with prompt identity, contract invalidation, permissions, zero invariant findings, and a clean crash scan

### Static prompt-prefix token reuse

Saved prompt-prefix states already retain the exact prefix token vector. The linked runtime now reuses that vector after matching the resident model, exact prefix hash, and exact prefix bytes instead of tokenizing the static prefix again. It still tokenizes the full prompt and still checks that the cached prefix tokens are its exact leading token sequence before restoring state. Prefix tokens share the existing four-entry, 512 MiB prefix-state lifetime and byte accounting; there is no second token cache

Back-to-back baseline and candidate runs used 30 cache-disabled qwen35 requests per shape. For a 307-token prompt with 298 reusable prefix tokens, tokenization moved from `5ms` p50 and `14.1ms` p95 to `4ms` and `13.1ms`. For a 707-token prompt with 698 reusable prefix tokens, it moved from `7ms` and `13.55ms` to `5ms` and `12.55ms`. All 60 candidate outputs passed schema validation with one prompt hash per shape. A qwen35-to-qwen3 swap saved a new one-entry prefix state with zero reused tokens, proving model changes cannot reuse the previous model's tokens. The five-case qwen35 probe and full demo passed with zero invariant or crash findings

Run the default-included benchmark model:

```sh
OTLET_BENCH_LIMIT_MODELS=qwen35_4b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a single named model when debugging a candidate:

```sh
OTLET_BENCH_LIMIT_MODELS=phi4_mini OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run the current scored comparison set after an output-affecting prompt, schema, decoding, model, or scoring change:

```sh
OTLET_BENCH_LIMIT_MODELS=ministral3_3b,qwen35_4b,gemma4_e2b,glm_edge_4b,gemma4_e4b,phi4_mini OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

## Validation Rings

Use the smallest ring that covers the changed contract:

| Change | Required proof | Full benchmark |
| --- | --- | --- |
| Docs, pure views, model-free planner or SQL logic | Static checks plus focused SQL | No |
| Decode speed, threads, batch, context, load, memory, or other runtime-only behavior | Five-case quick probe; use repeated interleaved same-host A/B when results move | If the result is ambiguous or regresses |
| Cache, queue, cancellation, admission, residency, receipt, status, or EXPLAIN behavior | Fresh setup, full demo, focused SQL, invariants, permissions, crash scan, and quick probe when performance can move | If output can change or focused evidence is inconclusive |
| Prompt, template, quantization, model, decoding, schema acceptance, output selection, or published scores | Comparable quick probe followed by the full suite | Yes |
| Final integrated runtime state | Complete validation ring | Yes |

A full qwen35 run executes 447 sequential model jobs: 112 direct pair jobs, 110 general reliability jobs, 112 semantic-join jobs, and 113 row-watch jobs. The July 13, 2026 `b1783967979` run took 48 minutes 20 seconds at `0.1542 jobs/s`. Its 340 scored cases reached `0.9882` schema validity, `0.9664` trusted quality, `1.0000` entity accuracy, zero false merges, zero stale leaks, and zero worker crashes. It did not pass the production gate: extraction scored `0.7667`, the hallucinated trusted-action rate was `0.3324`, and the run had one repeat. Join replay covers watch-owned worker and materialization behavior; row watch uses a distinct prompt and schema

Limit routine model search to 4B active parameters and about 4 GB of local artifact size. Qwen3.5 4B stays the stable default until a smaller model passes the fast probe and the full benchmark. MiniStral, Gemma, GLM Edge, Phi mini, and SmolLM stay in comparison lanes

Recent quick-probe findings:

| model | viable | mean tok/s | result |
| --- | --- | ---: | --- |
| `qwen35_4b` | yes | `40.90` | passed all five row-shaped cases with the 6-thread CPU default |
| `qwen3_1_7b` | no | `68.79` | fast cheap model, failed three correctness cases |
| `ministral3_3b` | no | `10.48` | failed markdown-fence, adversarial row-text, and numeric-threshold cases |
| `phi4_mini` | no | `10.69` | schema-valid, failed adversarial row-text and numeric-threshold cases |
| `smollm3_3b` | no | `8.71` | schema-valid, failed adversarial row-text and numeric-threshold cases |
| `glm_edge_4b` | no | `6.68` | produced fenced JSON and failed the listed hard decisions |

An interleaved three-sample A/B after runtime fingerprinting measured a `40.90 tok/s` feature median and `41.18 tok/s` unchanged-code median. All six probes passed 5/5; feature p95 generation was `2218 ms` versus `2354 ms` for the control

Thread sweep on the current Docker CPU showed the best stable qwen35 setting at 6 threads:

| model | threads | viable | mean tok/s |
| --- | ---: | --- | ---: |
| `qwen35_4b` | `1` | no | `7.90` |
| `qwen35_4b` | `2` | yes | `16.91` |
| `qwen35_4b` | `4` | yes | `29.35` |
| `qwen35_4b` | `6` | yes | `38.51` |
| `qwen35_4b` | `8` | yes | `37.28` |
| `qwen35_4b` | `12` | yes | `6.68` |
| `qwen3_1_7b` | `6` | no | `71.91` |
| `qwen3_1_7b` | `12` | no | `10.63` |

Recent CPU tuning sweep on `qwen35_4b` kept the old default at `41.89 tok/s` as the before sample. The control build stayed neutral at `41.44 tok/s`; each tested default change failed correctness or lost throughput:

| control | tested setting | viable | mean tok/s | result |
| --- | --- | --- | ---: | --- |
| decode threads | `6` | yes | `37.76` | still best in sweep; `8`, `10`, and `12` were slower |
| batch threads | `12` | yes | `41.21` | repeated A/B was neutral versus default `41.31` |
| logical batch | `2048` | yes | `39.80` | slower than `512` |
| physical ubatch | `2048/256` | yes | `33.66` | slower |
| mmap | `false` | yes | `25.78` | slower |
| mlock | `true` | yes | `24.09` | slower |
| flash attention | `on` | yes | `31.48` | slower on CPU |
| perf counters | `OTLET_LLAMA_NO_PERF=false` | yes | `28.33` | slower |
| KV cache type | `q8_0` | yes | `30.22` | slower; possible memory lever |
| KV cache type | `q4_0` | no | `25.16` | failed one decision |
| OpenMP placement | `PROC_BIND=spread`, `PLACES=cores` | no | `9.95` | timed out one smoke case |

The host and SQL probes kept the six-thread, F16, unset-placement defaults. The ARM64 host exposes 12 physical and 12 logical CPUs with one hardware thread per core, no NUMA node interface, no container power counter, and no usable unprivileged host energy counter. Linked llama.cpp has native CPU and OpenMP enabled, BLAS disabled, and no linked BLAS library. `PROC_BIND=close PLACES=cores` stalled the first probe case for more than 107 seconds

The first rotated F16/Q8 KV A/B block showed a Q8 lead, then the medians converged to 37.46 versus 37.31 mean tok/s while both stayed 5/5. Q4 repeated at 4/5 by obeying adversarial row text. F16 remains the default and neither candidate earned a full run. A one-client `pgbench` `SELECT 1` probe measured 38 microseconds p50 and 46 microseconds p95 while idle, 40 and 69 microseconds during cold load plus five judgments, and 39 and 87 microseconds while four infer-now callers filled the bounded queue. All database transactions and judgments completed without swap, faults, PSI events, timeouts, or crashes

Interleaved prompt-prefix probe on `qwen35_4b` now keeps multiple task prefixes in the resident worker. The A/B/A probe used two different inline tasks. Before the bounded multi-prefix cache, the second A decoded the full 424-token prompt again at about `6.7s` prompt decode. After the change, the second A restored 386 prefix tokens, decoded 38 tail tokens, and prompt decode was `1.143s`. The resident worker kept two prefix states using about `130.6 MiB`

Run the default-included set after a harness improvement when you want the shortest publishable check:

```sh
models="$(awk -F '\t' 'NR > 1 && $9 == "true" {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run manual candidates for targeted research. Rows marked `candidate`, `diagnostic`, `historical`, or `heavy` stay outside the default run:

```sh
models="$(awk -F '\t' 'NR > 1 && ($6 == "candidate" || $6 == "diagnostic") {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=6 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a one-model default smoke without publishing a local report:

```sh
OTLET_BENCH_LIMIT_MODELS=qwen35_4b OTLET_BENCH_RUNS=1 ./benchmarks/run.sh
```

The harness requires the database to start in `redacted` sensitive-evidence mode. It enables `diagnostic` mode for scoring rejected or malformed attempts, writes hashes and derived scores to artifacts, then restores `redacted` mode and runs cleanup. Reports omit assembled prompts, raw model output, and token text

## Report Output

`OTLET_BENCH_PUBLISH_REPORT=1` writes the latest report under ignored `benchmarks/report/latest/`

Key files:

- `benchmarks/report/latest/otlet-model-benchmark.md`
- `benchmarks/report/latest/overall.svg`
- `benchmarks/report/latest/pareto.svg`
- `benchmarks/report/latest/params.svg`
- `benchmarks/report/latest/latency.svg`
- `benchmarks/report/latest/ttft.svg`
- `benchmarks/report/latest/prompt_decode.svg`
- `benchmarks/report/latest/efficiency.svg`
- `benchmarks/report/latest/scorecard.tsv`
- `benchmarks/report/latest/model_summary.tsv`
- `benchmarks/report/latest/case_results.tsv`
- `benchmarks/report/latest/explain.txt`

Run artifacts stay under ignored `benchmarks/runs/<timestamp>-<run_id>/`

Commit benchmark code and this static README. Do not commit generated run reports or chart snapshots

## Score Fields

Score fields are `0.000` to `1.000`

| name | meaning |
| --- | --- |
| `overall_fit` | trusted Otlet quality with a soft resource adjustment; higher is better |
| `trusted_quality` | schema-valid accepted output quality before resource adjustment |
| `diagnostic_fit` | partial signal from rejected or invalid attempts; outside trusted state |
| `resource_fit` | soft score for artifact size, resident RSS, latency, and active params |
| `first_blocker` | first production gate that kept a model from default readiness |
| `default_candidate` | passed the production gate with at least 3 same-run repeats |
| `triage_candidate` | trusted output exists, but the model is not default-ready |
| `row_watch_candidate` | watch-style row judgment works, but the model is not default-ready |
| `workload_candidate` | production-readiness label for a non-default model |

The generated report includes ranking tables, workload picks, production readiness, first failure modes, out-of-running rows, chart links, model metadata, and rerun commands

Each run metadata file also records the runtime fingerprint documents, full fingerprint hashes, and output-contract hashes observed on its receipts. These values bind performance and quality results to the artifact, prompt template, linked llama.cpp revision, effective context settings, CPU placement, and host capacity

## Benchmark Scope

The suite measures Otlet fit. Each case puts evidence in database rows and asks the model to behave like a Postgres-resident worker over compact row JSON

The score covers:

- schema-valid trusted output
- explicit production gates and repeat proof before any default-model claim
- non-ER triage decisions across flag, pass, abstain, and adversarial row-text cases
- numeric-evidence decisions across threshold pass, threshold breach, incomplete evidence, and adversarial row-text cases
- extraction and policy-check phases with production gates
- entity-resolution decisions across duplicates, hard negatives, sparse rows, dirty rows, and abstention cases
- exact confidence targets that reject overconfident or underconfident outputs
- typed actions with no source-table writes
- row-watch classification as per-row case results
- semantic materialization and stale-result safety
- receipt, trace, source-hash, current-row SQL, and CustomScan visibility
- p95 latency, tokens/sec, resident RSS, artifact size, active params, and fit per resident GB

## Model Metadata

Refresh model manifest metadata into the ignored latest report directory:

```sh
python3 benchmarks/refresh-metadata.py
```

Pass `OTLET_BENCH_MODELS_METADATA=/path/to/models_metadata.tsv` to use an explicit metadata file during a run

The benchmark default timeout is two hours per task phase because the fixture loads many row-pair cases per model and larger local models can cross one hour before semantic refresh starts
