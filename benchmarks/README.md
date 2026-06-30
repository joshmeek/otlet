# Otlet Benchmarks

## Overall Score

Read this ranking first. `overall_score` is `candidate_fit`: trusted Otlet work times resource fit. A zero means the model ran but produced no trusted state

| rank | model | overall_score | trusted_gate | diagnostic_fit | resource_fit | first_blocker |
| ---: | --- | ---: | ---: | ---: | ---: | --- |
| 1 | qwen3_4b | 0.068 | 0.776 | 0.068 | 0.085 | confidence < 0.95 |
| 2 | linked_qwen_1_7b | 0.028 | 0.182 | 0.055 | 0.156 | confidence < 0.95 |
| 3 | linked_qwen_0_6b | 0.000439 | 0.001 | 0.141 | 0.614 | confidence < 0.95 |
| 4 | gemma3_270m | 0.000 | 0.000 | 0.094 | 0.787 | confidence < 0.95 |
| 5 | granite4_1b | 0.000 | 0.000 | 0.077 | 0.642 | confidence < 0.95 |
| 6 | lfm25_12b_instruct | 0.000 | 0.000 | 0.150 | 0.671 | confidence < 0.95 |
| 7 | lfm25_230m | 0.000 | 0.000 | 0.104 | 0.859 | confidence < 0.95 |
| 8 | lfm25_350m | 0.000 | 0.000 | 0.100 | 0.836 | confidence < 0.95 |
| 9 | minicpm4_05b | 0.000 | 0.000 | 0.091 | 0.762 | confidence < 0.95 |

## Latest Result

Run `b1782789097,b1782813851`: this is a merged current scored report. It covers 9 selected model rows through the benchmark harness. The runner writes generated report artifacts under ignored `benchmarks/report/latest`

Benchmark confidence: `merged_provisional`. Next proof: Run the same selected model set in one OTLET_BENCH_RUNS=3 publish run

`qwen3_4b` has same-run repeat proof with 3 runs; repeated models rank by their worst candidate-fit repeat. The other 8 scored models are single-run broad comparison rows

A model that completes a current-format run gets an overall score. The harness marks load failures, timeouts, manifest blocks, and missing summaries as out of running instead of assigning a fake zero

The TSVs store `overall_score` as `candidate_fit`: trusted Otlet work multiplied by resource fit for artifact size, resident RSS, p95 latency, and active params. Fast invalid output gets an overall score of zero because it creates no trusted Otlet state. `production_score` stays zero until a model passes every production gate

Current coverage is 112.0 direct gold cases per model run. The current fixture target is 112 deterministic pair cases per model plus row-watch and semantic checks

The runner skipped semantic and row-watch phases for 8 scored models because direct schema-valid rate was below 0.50

## Workload Picks

| workload | model | metric | gate | caveat |
| --- | --- | --- | --- | --- |
| default Otlet model |  |  |  | none passed production gates |
| hard entity resolution | qwen3_4b | 0.874 | fail | not a default model unless gate passes |
| row watching | qwen3_4b | 0.522 | fail | not a default model unless gate passes |
| <=2.0 GB artifact | linked_qwen_1_7b | 0.028 | fail | small-fit pick, still gate-aware |
| correct jobs/sec/GB | qwen3_4b | 0.008 | fail | compare timing after one same-run sweep |

## Production Readiness

The default-model gate keeps failed models out of production rank. Failed models keep diagnostic evidence, but their production score is zero

| rank | model | readiness | production_score | candidate_fit | gate | first_blocker |
| ---: | --- | --- | ---: | ---: | --- | --- |
| 1 | qwen3_4b | research_only | 0.000 | 0.068 | fail | confidence < 0.95 |
| 2 | linked_qwen_1_7b | contract_blocked | 0.000 | 0.028 | fail | confidence < 0.95 |
| 3 | linked_qwen_0_6b | contract_blocked | 0.000 | 0.000439 | fail | confidence < 0.95 |
| 4 | lfm25_12b_instruct | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |
| 5 | lfm25_230m | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |
| 6 | gemma3_270m | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |
| 7 | granite4_1b | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |
| 8 | lfm25_350m | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |
| 9 | minicpm4_05b | contract_blocked | 0.000 | 0.000 | fail | confidence < 0.95 |

## First Failure Modes

| model | top_failure | count | passed_cases |
| --- | --- | ---: | ---: |
| qwen3_4b | false_merge | 63 | 260 |
| linked_qwen_1_7b | invalid_json | 85 | 20 |
| linked_qwen_0_6b | invalid_json | 73 | 0 |
| lfm25_12b_instruct | schema_invalid | 57 | 0 |
| lfm25_230m | invalid_json | 112 | 0 |

## Overall Score Ranking

| rank | model | runs | readiness | overall_score | trusted_gate | schema | p95_ms | rss_gb | artifact_gb |
| ---: | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | qwen3_4b | 3 | research_only | 0.068 | 0.776 | 0.979 | 11527 | 3.357 | 2.497 |
| 2 | linked_qwen_1_7b | 1 | contract_blocked | 0.028 | 0.182 | 0.241 | 11998 | 2.518 | 1.834 |
| 3 | linked_qwen_0_6b | 1 | contract_blocked | 0.000439 | 0.001 | 0.080 | 8202 | 1.298 | 0.639 |
| 4 | gemma3_270m | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 7823 | 0.560 | 0.292 |
| 5 | granite4_1b | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 5 | 1.206 | 0.901 |
| 6 | lfm25_12b_instruct | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 2117 | 1.011 | 0.731 |
| 7 | lfm25_230m | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 2593 | 0.485 | 0.247 |
| 8 | lfm25_350m | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 33 | 0.631 | 0.379 |
| 9 | minicpm4_05b | 1 | contract_blocked | 0.000 | 0.000 | 0.000 | 4215 | 0.718 | 0.463 |

## Out Of Running

No selected models were out of running

## Drilldown Charts

The headline chart ranks overall score. The charts below explain whether that score is quality-limited, memory-limited, latency-limited, or parameter-limited. Treat latency and throughput as useful only after checking `trusted_gate`; instant invalid output is not useful work

Running the benchmark writes local SVG charts under ignored `benchmarks/report/latest`: overall score, resident memory versus score, active parameters versus score, p95 latency, and trusted throughput per resident GB

## Report Files

- Full report: `report/latest/otlet-model-benchmark.md`
- Overall score chart: `report/latest/overall.svg`
- Score audit TSV: `report/latest/score_audit.tsv`
- Gate scorecard TSV: `report/latest/scorecard.tsv`
- Model summary TSV: `report/latest/model_summary.tsv`
- Case result TSV: `report/latest/case_results.tsv`
- Cleanup proof: `report/latest/cleanup.tsv`
- Planner proof: `report/latest/explain.txt`

## Benchmark Scope

The suite measures Otlet fit, not background model knowledge. Each case puts the evidence in database rows and asks the model to behave like a Postgres-resident worker over compact row JSON

The score covers:

- schema-valid trusted output
- explicit production gates before any default-model claim
- entity-resolution decisions across duplicates, hard negatives, sparse rows, dirty rows, and abstention cases
- exact confidence targets, so overconfident or underconfident outputs do not get silent credit
- typed actions with no source-table writes
- row-watch classification
- semantic materialization and stale-result safety
- receipt, trace, source-hash, FDW, and CustomScan visibility
- p95 latency, tokens/sec, resident RSS, artifact size, active params, and fit per resident GB

## Rerun

Start from the normal Otlet proof path:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

Run one model and write a local report:

```sh
OTLET_BENCH_LIMIT_MODELS=ministral3_3b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a subset and write a local report:

```sh
OTLET_BENCH_LIMIT_MODELS=ministral3_3b,glm_edge_4b,smollm3_3b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run the small-model set around the 2 GB artifact target and refresh the report:

```sh
models="$(awk -F '\t' 'NR > 1 && $6 == "core" && $10 <= 2.0 {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=2.0 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

The benchmark default timeout is two hours per task phase because the current fixture loads 112 row-pair cases per model and larger local models can cross one hour before semantic refresh starts

Run every core model in the manifest and write a local report:

```sh
models="$(awk -F '\t' 'NR > 1 && $6 == "core" {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=6 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run the Qwen smoke without writing a local report:

```sh
OTLET_BENCH_LIMIT_MODELS=linked_qwen_0_6b,linked_qwen_1_7b OTLET_BENCH_RUNS=1 ./benchmarks/run.sh
```

Refresh model manifest metadata:

```sh
python3 benchmarks/refresh-metadata.py
```

`OTLET_BENCH_PUBLISH_REPORT=1` updates local generated Markdown, SVG, TSV, cleanup, and EXPLAIN files under ignored `benchmarks/report/latest/`

Raw runs stay under ignored `benchmarks/runs/<timestamp>-<run_id>/`. Keep a raw run while debugging; commit benchmark code and README updates, not generated run artifacts

Raw run artifacts update after each completed model. `report/latest` updates only when the runner reaches normal completion with `OTLET_BENCH_PUBLISH_REPORT=1`
