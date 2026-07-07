# Otlet Benchmarks

The benchmark harness measures how well a local GGUF model behaves as an Otlet worker over compact Postgres row evidence. It is not a general knowledge benchmark

Start with the normal Otlet proof path:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

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
OTLET_BENCH_LIMIT_MODELS=qwen35_4b,ministral3_3b,gemma4_e2b,glm_edge_4b,gemma4_e4b,phi4_mini OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run the default-included set when the harness has materially improved and you want the shortest publishable check:

```sh
models="$(awk -F '\t' 'NR > 1 && $9 == "true" {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run manual candidates only when you have a reason to spend the time. Rows marked `candidate`, `diagnostic`, `historical`, or `heavy` stay outside the default run:

```sh
models="$(awk -F '\t' 'NR > 1 && ($6 == "candidate" || $6 == "diagnostic") {print $1}' benchmarks/models.tsv | paste -sd, -)"
OTLET_BENCH_LIMIT_MODELS="$models" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=6 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh
```

Run a one-model Qwen smoke without publishing a local report:

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
