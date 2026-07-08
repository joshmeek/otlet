# Otlet Benchmarks

The benchmark harness measures how well a local GGUF model behaves as an Otlet worker over compact Postgres row evidence. It is not a general knowledge benchmark

Start with the normal Otlet proof path:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

Run the fast probe before spending time on a full benchmark. It uses the real Otlet worker on five row-shaped JSON cases and reports viability, pass count, schema passes, token rate, steady decode rate, p95 generation time, p95 TTFT, and p95 prompt decode time:

```sh
OTLET_PROBE_LIMIT_MODELS=ministral3_3b,qwen35_4b,qwen3_1_7b ./benchmarks/quick_probe.sh
```

Set `OTLET_PROBE_DOWNLOAD=1` when you want the probe to fetch a missing GGUF. Downloads go under `/var/lib/postgresql/otlet-probe-models` and the script removes them on exit unless `OTLET_PROBE_KEEP_MODELS=1`

Find current Hugging Face GGUF candidates before adding a model row:

```sh
python3 benchmarks/find_candidates.py
```

Sweep CPU thread counts through the same probe:

```sh
OTLET_SWEEP_MODELS=qwen3_1_7b,qwen35_4b OTLET_SWEEP_THREADS=1,2,4,6,8,12 ./benchmarks/thread_sweep.sh
```

The probe accepts `OTLET_PROBE_LLAMA_THREADS=<n>`, `OTLET_PROBE_LLAMA_BATCH_THREADS=<n>`, and `OTLET_PROBE_RUNTIME_OPTIONS='{"max_tokens":64}'` for one run. The setup path accepts deployment-level llama.cpp knobs before `./scripts/otlet-setup.sh`:

| knob | scope | default |
| --- | --- | --- |
| `OTLET_LLAMA_THREADS` | decode threads | visible cores capped at `6` |
| `OTLET_LLAMA_BATCH_THREADS` | prompt-decode thread pool | same as decode threads |
| `OTLET_LLAMA_BATCH_TOKENS` | logical prompt batch tokens | `512` |
| `OTLET_LLAMA_UBATCH_TOKENS` | physical prompt ubatch tokens | `512` |
| `OTLET_LLAMA_MMAP` | model mmap toggle | llama.cpp default |
| `OTLET_LLAMA_MLOCK` | lock model pages in memory | llama.cpp default |
| `OTLET_LLAMA_FLASH_ATTN` | `auto`, `on`, or `off` flash attention | llama.cpp default |
| `OTLET_LLAMA_NO_PERF` | skip llama.cpp perf counters | `true` |
| `OTLET_LLAMA_KV_TYPE` | set both KV cache types: `f16`, `q8_0`, `q4_0` | llama.cpp default |
| `OTLET_LLAMA_KV_TYPE_K` | set K cache type only | llama.cpp default |
| `OTLET_LLAMA_KV_TYPE_V` | set V cache type only | llama.cpp default |
| `OMP_PROC_BIND`, `OMP_PLACES`, `GOMP_CPU_AFFINITY` | OpenMP CPU placement | unset |

Treat those as host-specific controls. Re-run `./scripts/otlet-setup.sh` after changing startup knobs so the worker process starts with the new environment

Run the default-included benchmark model:

```sh
OTLET_BENCH_LIMIT_MODELS=qwen35_4b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a single named model when debugging a candidate:

```sh
OTLET_BENCH_LIMIT_MODELS=phi4_mini OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run the current scored comparison set after a prompt, schema, scoring, or runtime change:

```sh
OTLET_BENCH_LIMIT_MODELS=ministral3_3b,qwen35_4b,gemma4_e2b,glm_edge_4b,gemma4_e4b,phi4_mini OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Keep routine model search under 4B active parameters and about 4 GB of local artifact size. Qwen3.5 4B stays the stable default until a smaller model passes the fast probe and the full benchmark. MiniStral, Gemma, GLM Edge, Phi mini, and SmolLM stay in comparison lanes

Recent quick-probe findings:

| model | viable | mean tok/s | result |
| --- | --- | ---: | --- |
| `qwen35_4b` | yes | `34.15` | passed all five row-shaped cases with the 6-thread CPU default |
| `qwen3_1_7b` | no | `68.79` | fast cheap model, failed three correctness cases |
| `ministral3_3b` | no | `10.48` | failed markdown-fence, adversarial row-text, and numeric-threshold cases |
| `phi4_mini` | no | `10.69` | schema-valid, failed adversarial row-text and numeric-threshold cases |
| `smollm3_3b` | no | `8.71` | schema-valid, failed adversarial row-text and numeric-threshold cases |
| `glm_edge_4b` | no | `6.68` | produced fenced JSON and failed the same hard decisions |

Thread sweep on the current Docker CPU showed the best stable setting at 6 threads:

| model | threads | viable | mean tok/s |
| --- | ---: | --- | ---: |
| `qwen35_4b` | `4` | yes | `24.67` |
| `qwen35_4b` | `6` | yes | `28.03` |
| `qwen35_4b` | `8` | yes | `26.65` |
| `qwen35_4b` | `12` | yes | `5.37` |
| `qwen3_1_7b` | `6` | no | `71.91` |
| `qwen3_1_7b` | `12` | no | `10.63` |

Recent CPU tuning sweep on `qwen35_4b` kept the old default at `41.89 tok/s` as the before sample. The control-only build stayed neutral at `41.44 tok/s`; every default change below either failed correctness or lost throughput:

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
| KV cache type | `q8_0` | yes | `30.22` | slower; possible memory-only lever |
| KV cache type | `q4_0` | no | `25.16` | failed one decision |
| OpenMP placement | `PROC_BIND=spread`, `PLACES=cores` | no | `9.95` | timed out one smoke case |

Run the default-included set after a harness improvement when you want the shortest publishable check:

```sh
models="$(awk -F '\t' 'NR > 1 && $9 == "true" {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run manual candidates when you have a reason to spend the time. Rows marked `candidate`, `diagnostic`, `historical`, or `heavy` stay outside the default run:

```sh
models="$(awk -F '\t' 'NR > 1 && ($6 == "candidate" || $6 == "diagnostic") {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=6 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a one-model default smoke without publishing a local report:

```sh
OTLET_BENCH_LIMIT_MODELS=qwen35_4b OTLET_BENCH_RUNS=1 ./benchmarks/run.sh
```

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

Raw run artifacts stay under ignored `benchmarks/runs/<timestamp>-<run_id>/`

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

## Benchmark Scope

The suite measures Otlet fit. Each case puts evidence in database rows and asks the model to behave like a Postgres-resident worker over compact row JSON

The score covers:

- schema-valid trusted output
- explicit production gates and repeat proof before any default-model claim
- non-ER triage decisions across flag, pass, abstain, and adversarial row-text cases
- numeric-evidence decisions across threshold pass, threshold breach, incomplete evidence, and adversarial row-text cases
- extraction and policy-check phases with production gates
- entity-resolution decisions across duplicates, hard negatives, sparse rows, dirty rows, and abstention cases
- exact confidence targets, so overconfident or underconfident outputs do not get silent credit
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
