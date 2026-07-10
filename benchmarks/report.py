#!/usr/bin/env python3
import sys
from pathlib import Path

from report_charts import (
    write_bar,
    write_overall,
    write_param_fit,
    write_pareto,
    write_score_audit,
    write_scorecard,
)
from report_io import clean_lines, compact_count, plural, read_kv, read_tsv, short, table
from report_scoring import (
    add_missing_model_rows,
    aggregate_summaries,
    benchmark_confidence,
    case_failure_mode,
    current_report_rows,
    display_verdict,
    finalize_gate_failures,
    finalize_report_status,
    first_blocker,
    gate_failures,
    gate_status,
    metric_present,
    model_base_map,
    num,
    production_score,
    ranked,
    readiness,
    score_audit_rows,
    score_label,
    with_base_key,
)


SMALL_ARTIFACT_GB = 2.0


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: report.py RUN_DIR")
    run_dir = Path(sys.argv[1])
    models = read_tsv(run_dir / "models.tsv")
    model_metadata = {row.get("model_key", ""): row for row in read_tsv(run_dir / "models_metadata.tsv")}
    cases = read_tsv(run_dir / "case_results.tsv")
    raw_summaries = read_tsv(run_dir / "model_summary.tsv")
    base_by_model = model_base_map(models)
    for row in cases:
        with_base_key(row, base_by_model)
    summaries = add_missing_model_rows(aggregate_summaries(raw_summaries, models), models)
    report_summaries = finalize_report_status(
        finalize_gate_failures(current_report_rows(summaries))
    )
    report_model_keys = {row.get("model_key", "") for row in report_summaries}
    report_cases = [row for row in cases if row.get("base_model_key") in report_model_keys]
    cases_by_model = {}
    for row in report_cases:
        cases_by_model.setdefault(row.get("base_model_key", ""), []).append(row)
    meta = read_kv(run_dir / "metadata.tsv")
    cleanup = read_kv(run_dir / "cleanup.tsv")
    for row in summaries:
        resident_gb = num(row.get("resident_gb"))
        active_params_b = num(row.get("active_params_b"))
        correct_jobs_per_second_per_gb = num(row.get("correct_jobs_per_second_per_gb"), None)
        if correct_jobs_per_second_per_gb is None and resident_gb > 0:
            correct_jobs_per_second_per_gb = (
                num(row.get("quality_score")) * num(row.get("jobs_per_second")) / resident_gb
            )
        if correct_jobs_per_second_per_gb is None:
            row["correct_jobs_per_second_per_gb"] = ""
        else:
            row["correct_jobs_per_second_per_gb"] = correct_jobs_per_second_per_gb
        if resident_gb > 0:
            row["overall_fit_jobs_per_second_per_gb"] = (
                num(row.get("otlet_fit_score")) * num(row.get("jobs_per_second")) / resident_gb
            )
        else:
            row["overall_fit_jobs_per_second_per_gb"] = ""
        if active_params_b > 0:
            row["quality_per_active_b"] = num(row.get("quality_score")) / active_params_b
        else:
            row["quality_per_active_b"] = ""

    runnable_summaries = [row for row in report_summaries if row.get("run_status") == "complete"]
    scored_summaries = [row for row in runnable_summaries if row.get("score_status") == "scored"]
    out_of_running = [row for row in report_summaries if row.get("run_status") != "complete"]
    pareto = run_dir / "pareto.svg"
    params = run_dir / "params.svg"
    latency = run_dir / "latency.svg"
    ttft = run_dir / "ttft.svg"
    prompt_decode = run_dir / "prompt_decode.svg"
    efficiency = run_dir / "efficiency.svg"
    overall = run_dir / "overall.svg"
    scorecard = run_dir / "scorecard.tsv"
    score_audit = run_dir / "score_audit.tsv"
    write_overall(overall, scored_summaries)
    write_pareto(pareto, runnable_summaries)
    write_param_fit(params, runnable_summaries)
    write_bar(latency, runnable_summaries, "p95_generate_ms", "p95 generation latency ms, higher is slower")
    write_bar(ttft, runnable_summaries, "p95_ttft_ms", "p95 TTFT ms, higher is slower")
    write_bar(prompt_decode, runnable_summaries, "p95_prompt_decode_ms", "p95 prompt decode ms, higher is slower")
    write_bar(efficiency, runnable_summaries, "correct_jobs_per_second_per_gb", "correct jobs/sec per resident GB")
    write_scorecard(scorecard, report_summaries)
    write_score_audit(score_audit, report_summaries)
    ranked_summaries = sorted(
        scored_summaries,
        key=lambda row: (num(row.get("trusted_fit_score")), num(row.get("quality_score"))),
        reverse=True,
    )
    default_model_keys = [
        row.get("model_key", "") for row in ranked_summaries if row.get("include_by_default") == "true"
    ] or ([ranked_summaries[0].get("model_key", "")] if ranked_summaries else [])
    comparison_model_keys = [row.get("model_key", "") for row in ranked_summaries]
    recommended_command = (
        f"OTLET_BENCH_LIMIT_MODELS={','.join(default_model_keys)} "
        "OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh"
        if default_model_keys
        else "OTLET_BENCH_LIMIT_MODELS=qwen35_4b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh"
    )
    diagnostic_ranked_summaries = sorted(
        runnable_summaries,
        key=lambda row: (num(row.get("quality_score")), num(row.get("diagnostic_quality_score"))),
        reverse=True,
    )

    report = run_dir / "otlet-model-benchmark.md"
    summary_rows = []
    for rank, row in enumerate(ranked_summaries, start=1):
        summary_rows.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "repeat_count": row.get("repeat_count", ""),
                "verdict": display_verdict(row),
                "readiness": readiness(row),
                "production_score": f"{production_score(row):.3f}",
                "otlet_fit": score_label(row.get("trusted_fit_score")),
                "overall_fit": score_label(row.get("trusted_fit_score")),
                "diagnostic_fit": score_label(row.get("diagnostic_fit_score")),
                "fit_min": score_label(row.get("trusted_fit_min")),
                "fit_max": score_label(row.get("trusted_fit_max")),
                "fit_sd": score_label(row.get("trusted_fit_sd")),
                "trusted_quality": f'{num(row.get("quality_score")):.3f}',
                "schema": f'{num(row.get("schema_valid_rate")):.3f}',
                "diag_decision": f'{num(row.get("diagnostic_entity_accuracy")):.3f}',
                "trusted_decision": f'{num(row.get("entity_accuracy")):.3f}',
                "confidence": f'{num(row.get("confidence_score")):.3f}' if row.get("confidence_score") not in (None, "") else "",
                "diag_confidence": f'{num(row.get("diagnostic_confidence_accuracy")):.3f}' if row.get("diagnostic_confidence_accuracy") not in (None, "") else "",
                "row_watch": f'{num(row.get("row_watch_score")):.3f}',
                "params_b": f'{num(row.get("declared_params_b")):.2f}' if row.get("declared_params_b") else "",
                "active_b": f'{num(row.get("active_params_b")):.2f}' if row.get("active_params_b") else "",
                "p95_ms": f'{num(row.get("p95_generate_ms")):.0f}',
                "ttft_ms": f'{num(row.get("p95_ttft_ms")):.0f}',
                "prompt_ms": f'{num(row.get("p95_prompt_decode_ms")):.0f}',
                "tok_s": f'{num(row.get("mean_tokens_per_second")):.2f}',
                "steady_tok_s": f'{num(row.get("mean_steady_tokens_per_second")):.2f}',
                "rss_gb": f'{num(row.get("resident_gb")):.3f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.3f}',
                "correct_jobs_s_gb": f'{num(row.get("correct_jobs_per_second_per_gb")):.3f}',
                "overall_fit_jobs_s_gb": f'{num(row.get("overall_fit_jobs_per_second_per_gb")):.3f}',
                "quality_per_active_b": f'{num(row.get("quality_per_active_b")):.3f}',
                "resource_fit": f'{num(row.get("resource_fit")):.3f}',
            }
        )

    model_rows = []
    seen_models = set()
    for row in models:
        base = row.get("base_model_key") or row.get("model_key", "")
        if base not in report_model_keys:
            continue
        if base in seen_models:
            continue
        seen_models.add(base)
        model_rows.append(
            {
                "model": base,
                "family": row.get("family", ""),
                "tier": row.get("tier", ""),
                "quant": row.get("quant", ""),
                "params_b": row.get("declared_params_b", ""),
                "active_b": row.get("active_params_b", ""),
                "ctx": row.get("context_tokens", ""),
                "updated": (model_metadata.get(base, {}).get("hf_last_modified", "") or "")[:10],
                "downloads": model_metadata.get(base, {}).get("hf_downloads", ""),
                "likes": model_metadata.get(base, {}).get("hf_likes", ""),
                "hint_gb": (
                    f'{num(model_metadata.get(base, {}).get("artifact_bytes_hint")) / 1000000000.0:.3f}'
                    if model_metadata.get(base, {}).get("artifact_bytes_hint")
                    else ""
                ),
                "artifact": short(row.get("filename") or row.get("artifact_path"), 46),
                "license": row.get("license_note", ""),
                "source": row.get("source_url", ""),
            }
        )

    track_rows = []
    for row in diagnostic_ranked_summaries:
        track_rows.append(
            {
                "model": row.get("model_key", ""),
                "contract": f'{num(row.get("contract_score")):.3f}',
                "entity": f'{num(row.get("entity_resolution_score")):.3f}',
                "abstain": f'{num(row.get("abstention_score")):.3f}',
                "dirty": f'{num(row.get("dirty_data_score")):.3f}',
                "triage": f'{num(row.get("triage_score")):.3f}' if metric_present(row, "triage_score") else "",
                "triage_abstain": f'{num(row.get("triage_abstention_score")):.3f}' if metric_present(row, "triage_abstention_score") else "",
                "numeric": f'{num(row.get("numeric_evidence_score")):.3f}' if metric_present(row, "numeric_evidence_score") else "",
                "extraction": f'{num(row.get("extraction_score")):.3f}' if metric_present(row, "extraction_score") else "",
                "policy": f'{num(row.get("policy_check_score")):.3f}' if metric_present(row, "policy_check_score") else "",
                "user_suite": f'{num(row.get("user_suite_score")):.3f}' if metric_present(row, "user_suite_score") else "",
                "row_watch": f'{num(row.get("row_watch_score")):.3f}',
                "actions": f'{num(row.get("typed_action_score")):.3f}',
                "confidence": f'{num(row.get("confidence_score")):.3f}' if row.get("confidence_score") not in (None, "") else "",
                "diag_triage": f'{num(row.get("diagnostic_triage_accuracy")):.3f}' if metric_present(row, "diagnostic_triage_accuracy") else "",
                "diag_numeric": f'{num(row.get("diagnostic_numeric_accuracy")):.3f}' if metric_present(row, "diagnostic_numeric_accuracy") else "",
                "diag_actions": f'{num(row.get("diagnostic_action_accuracy")):.3f}',
                "diag_confidence": f'{num(row.get("diagnostic_confidence_accuracy")):.3f}' if row.get("diagnostic_confidence_accuracy") not in (None, "") else "",
                "semantic": f'{num(row.get("semantic_materialization_score")):.3f}',
            }
        )

    gate_rows = []
    blocker_counts = {}
    for row in diagnostic_ranked_summaries:
        failures = gate_failures(row)
        for failure in failures:
            blocker_counts[failure] = blocker_counts.get(failure, 0) + 1
        gate_rows.append(
            {
                "model": row.get("model_key", ""),
                "runs": row.get("repeat_count", ""),
                "verdict": display_verdict(row),
                "gate": "pass" if not failures else "fail",
                "failed_gate": short("; ".join(failures), 80),
                "schema": f'{num(row.get("schema_valid_rate")):.3f}',
                "contract": f'{num(row.get("contract_score")):.3f}',
                "entity": f'{num(row.get("entity_accuracy")):.3f}',
                "abstain": f'{num(row.get("abstention_score")):.3f}',
                "triage": f'{num(row.get("triage_score")):.3f}' if metric_present(row, "triage_score") else "",
                "extraction": f'{num(row.get("extraction_score")):.3f}' if metric_present(row, "extraction_score") else "",
                "policy": f'{num(row.get("policy_check_score")):.3f}' if metric_present(row, "policy_check_score") else "",
                "actions": f'{num(row.get("typed_action_score")):.3f}',
                "confidence": f'{num(row.get("confidence_score")):.3f}' if row.get("confidence_score") not in (None, "") else "",
                "semantic": f'{num(row.get("semantic_materialization_score")):.3f}',
            }
        )

    blocker_rows = [
        {"failed_gate": gate, "models": count}
        for gate, count in sorted(blocker_counts.items(), key=lambda item: (-item[1], item[0]))
    ]
    failure_mode_rows = []
    failure_mode_detail_rows = []
    failure_modes = [
        "invalid_json",
        "bad_output_envelope",
        "schema_invalid",
        "schema_missing",
        "false_merge",
        "wrong_match",
        "wrong_confidence",
        "wrong_action",
        "passed",
    ]
    for row in diagnostic_ranked_summaries:
        model_key = row.get("model_key", "")
        counts = {}
        for case in cases_by_model.get(model_key, ()):
            mode = case_failure_mode(case)
            counts[mode] = counts.get(mode, 0) + 1
        non_passed = {mode: count for mode, count in counts.items() if mode != "passed"}
        if not counts:
            continue
        top_mode, top_count = max(non_passed.items(), key=lambda item: item[1], default=("passed", 0))
        failure_mode_rows.append(
            {
                "model": model_key,
                "top_failure": top_mode,
                "count": top_count,
                "passed_cases": counts.get("passed", 0),
            }
        )
        detail = {"model": model_key}
        for mode in failure_modes:
            detail[mode] = counts.get(mode, 0)
        failure_mode_detail_rows.append(detail)
    out_of_running_rows = []
    for row in out_of_running:
        out_of_running_rows.append(
            {
                "model": row.get("model_key", ""),
                "status": row.get("run_status", ""),
                "reason": short(row.get("unsupported_reason") or first_blocker(row), 100),
                "tier": row.get("tier", ""),
                "artifact_gb": f'{num(row.get("artifact_gb")):.3f}' if row.get("artifact_gb") else "",
            }
        )

    readiness_rows = []
    for rank, row in enumerate(diagnostic_ranked_summaries, start=1):
        readiness_rows.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "readiness": readiness(row),
                "production_score": f"{production_score(row):.3f}",
                "overall_fit": score_label(row.get("trusted_fit_score")),
                "first_blocker": first_blocker(row),
                "gate": gate_status(row),
            }
        )

    audit_rows = [
        {
            "rank": row["rank"],
            "model": row["model"],
            "role": row["role"],
            "score_status": row["score_status"],
            "production_gate": row["production_gate"],
            "overall_fit": row["overall_fit"],
            "trusted_quality": score_label(row["trusted_quality"]),
            "resource_fit": score_label(row["resource_fit"]),
            "score_reason": row["score_reason"],
            "first_blocker": row["first_blocker"],
        }
        for row in score_audit_rows(report_summaries)
    ]

    failure_rows = []
    seen_failure_models = set()
    for summary in diagnostic_ranked_summaries:
        model_key = summary.get("model_key", "")
        for row in cases_by_model.get(model_key, ()):
            failed = (
                row.get("schema_valid") != "t"
                or row.get("match_correct") != "t"
                or row.get("confidence_correct") != "t"
                or row.get("action_correct") != "t"
            )
            if not failed or model_key in seen_failure_models:
                continue
            failure_rows.append(
                {
                    "model": row.get("base_model_key", ""),
                    "case": row.get("case_id", ""),
                    "expected": row.get("expected_match", ""),
                    "trusted": row.get("actual_match", ""),
                    "expected_conf": row.get("expected_confidence_floor", ""),
                    "trusted_conf": row.get("actual_confidence", ""),
                    "raw_conf": row.get("raw_confidence", ""),
                    "raw": row.get("raw_match", ""),
                    "action": row.get("actual_action_type", ""),
                    "raw_action": row.get("raw_action_type", ""),
                    "receipt": row.get("receipt_id", ""),
                    "hash": short(row.get("raw_output_hash", ""), 12),
                    "reason": short(row.get("reason") or row.get("error"), 54),
                }
            )
            seen_failure_models.add(model_key)
            break

    gate_passes = [row for row in ranked_summaries if gate_status(row) == "pass"]
    best_fit = gate_passes[0] if gate_passes else ranked_summaries[0] if ranked_summaries else {}
    best_trusted = max(report_summaries, key=lambda row: num(row.get("quality_score")), default={})
    best_triage = max(
        [row for row in scored_summaries if metric_present(row, "triage_score")],
        key=lambda row: num(row.get("triage_score")),
        default={},
    )
    best_row_watch = max(report_summaries, key=lambda row: num(row.get("row_watch_score")), default={})
    if num(best_row_watch.get("row_watch_score")) <= 0:
        best_row_watch = {}
    small_rows = [row for row in scored_summaries if 0 < num(row.get("artifact_gb")) <= SMALL_ARTIFACT_GB]
    best_small = max(small_rows, key=lambda row: num(row.get("trusted_fit_score")), default={})
    small_candidate_rows = []
    for rank, row in enumerate(sorted(small_rows, key=lambda r: num(r.get("trusted_fit_score")), reverse=True), start=1):
        small_candidate_rows.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "overall_fit": score_label(row.get("trusted_fit_score")),
                "trusted_quality": f'{num(row.get("quality_score")):.3f}',
                "resource_fit": f'{num(row.get("resource_fit")):.3f}',
                "schema": f'{num(row.get("schema_valid_rate")):.3f}',
                "p95_ms": f'{num(row.get("p95_generate_ms")):.0f}',
                "ttft_ms": f'{num(row.get("p95_ttft_ms")):.0f}',
                "rss_gb": f'{num(row.get("resident_gb")):.3f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.3f}',
            }
        )
    best_hard_case = max(
        report_summaries,
        key=lambda row: (
            num(row.get("entity_resolution_score")),
            num(row.get("contract_score")),
            num(row.get("quality_score")),
            num(row.get("trusted_fit_score")),
        ),
        default={},
    )
    run_ids = sorted({row.get("run_id", "") for row in report_summaries if row.get("run_id")})
    if run_ids and not (meta.get("run_id") or meta.get("source_run_ids")):
        meta["source_run_ids"] = ",".join(run_ids)
    repeat_counts = [num(row.get("repeat_count")) for row in report_summaries]
    min_repeats = min(repeat_counts) if repeat_counts else 0
    max_repeats = max(repeat_counts) if repeat_counts else 0
    report_raw_summaries = [row for row in raw_summaries if row.get("model_key", "") in report_model_keys]
    cases_per_model_run = (len(report_cases) / len(report_raw_summaries)) if report_raw_summaries else 0
    confidence, confidence_reason, confidence_next = benchmark_confidence(
        report_summaries, report_raw_summaries, len(report_cases), run_ids
    )
    min_direct_schema_rate = num(meta.get("min_direct_schema_rate"), None)
    if len(run_ids) > 1:
        timing_limit = "- Merged evidence compares quality gates; timing and RSS compare best after one same-run sweep"
    elif min_repeats >= 3:
        timing_limit = f"- Same-run evidence has repeat counts {min_repeats:.0f}-{max_repeats:.0f}"
    else:
        timing_limit = "- One same-run sweep proves direction; use OTLET_BENCH_RUNS=3 before treating stability as proven"
    if cases_per_model_run >= 100:
        coverage_limit = f"- Direct gold coverage is frontier-sized at {compact_count(cases_per_model_run)} cases per model run"
    else:
        coverage_limit = (
            f"- Direct gold coverage remains smoke-sized at {compact_count(cases_per_model_run)} cases per model run; "
            "the frontier target is 100+ cases per model"
        )

    findings = []
    findings.append(f"- Benchmark confidence: `{confidence}`")
    excluded_model_count = len(summaries) - len(report_summaries)
    if excluded_model_count:
        findings.append(
            f"- {excluded_model_count} non-default model {plural(excluded_model_count, 'row')} stayed out of current rankings; explicit runs can still inspect raw TSV evidence"
        )
    direct_gate_skips = []
    repeated_summaries = [row for row in ranked_summaries if num(row.get("repeat_count")) >= 3]
    if repeated_summaries:
        repeated = repeated_summaries[0]
        findings.append(
            f'- `{repeated.get("model_key")}` has same-run repeat proof with '
            f'{num(repeated.get("repeat_count")):.0f} runs; ranking uses its worst overall-fit repeat '
            f'({score_label(repeated.get("trusted_fit_score"))})'
        )
    if runnable_summaries and not scored_summaries:
        findings.append("- This run predates required confidence-target scoring and has no current overall fit scores")
    if min_direct_schema_rate is not None:
        direct_gate_skips = [
            row
            for row in scored_summaries
            if num(row.get("schema_valid_rate")) < min_direct_schema_rate
            and num(row.get("semantic_materialization_score")) == 0
            and num(row.get("row_watch_score")) == 0
        ]
        if direct_gate_skips:
            direct_gate_label = "model" if len(direct_gate_skips) == 1 else "models"
            findings.append(
                f"- {len(direct_gate_skips)} scored {direct_gate_label} skipped semantic and row-watch phases because direct schema-valid rate was below {min_direct_schema_rate:.2f}"
            )
    if not gate_passes:
        findings.append("- No tested model clears every production gate in this run")
    elif best_fit:
        findings.append(
            f'- `{best_fit.get("model_key")}` is the best production-gated model by production score '
            f'({score_label(best_fit.get("trusted_fit_score"))})'
        )
    if best_trusted:
        findings.append(
            f'- `{best_trusted.get("model_key")}` has the best `trusted_quality` '
            f'({num(best_trusted.get("quality_score")):.3f})'
        )
    if best_hard_case:
        findings.append(
            f'- `{best_hard_case.get("model_key")}` has the best hard entity-resolution track score '
            f'({num(best_hard_case.get("entity_resolution_score")):.3f})'
        )
    if best_triage and num(best_triage.get("triage_score")) > 0:
        findings.append(
            f'- `{best_triage.get("model_key")}` has the best triage phase score '
            f'({num(best_triage.get("triage_score")):.3f})'
        )
    if best_row_watch:
        findings.append(
            f'- `{best_row_watch.get("model_key")}` has the best row-watch score '
            f'({num(best_row_watch.get("row_watch_score")):.3f})'
        )
    if best_small:
        findings.append(
            f'- `{best_small.get("model_key")}` is the best <=2.0 GB artifact candidate '
            f'({num(best_small.get("artifact_gb")):.3f} GB artifact, {score_label(best_small.get("trusted_fit_score"))} overall fit)'
        )
    default_limit = (
        f'- `{best_fit.get("model_key")}` passed the production gate with at least 3 same-run repeats'
        if gate_passes and best_fit
        else "- No model passed the production gate, so the report does not recommend a default model"
    )

    def winner_row(workload, row, metric, caveat):
        if not row:
            return {"workload": workload, "model": "", "metric": "", "gate": "", "caveat": caveat}
        return {
            "workload": workload,
            "model": row.get("model_key", ""),
            "metric": metric,
            "gate": gate_status(row),
            "caveat": caveat,
        }

    eligible_rows = [row for row in scored_summaries if gate_status(row) == "pass"]
    default_row = ranked(eligible_rows)[0] if eligible_rows else {}
    efficiency_row = max(
        scored_summaries,
        key=lambda row: num(row.get("correct_jobs_per_second_per_gb")),
        default={},
    )
    score_caveat = (
        "legacy diagnostic; current score missing required metrics"
        if runnable_summaries and not scored_summaries
        else "not a default model unless gate passes"
    )

    def workload_caveat(row):
        if row and gate_status(row) == "pass":
            return "production gate passed"
        return score_caveat

    workload_rows = [
        winner_row(
            "default Otlet model",
            default_row,
            score_label(default_row.get("trusted_fit_score")) if default_row else "",
            "none passed production gates" if not default_row else "production gate passed",
        ),
        winner_row(
            "hard entity resolution",
            best_hard_case,
            f'{num(best_hard_case.get("entity_resolution_score")):.3f}',
            workload_caveat(best_hard_case),
        ),
        winner_row(
            "row watching",
            best_row_watch,
            f'{num(best_row_watch.get("row_watch_score")):.3f}',
            workload_caveat(best_row_watch) if best_row_watch else "not proven; direct schema gate skipped row-watch phase",
        ),
        winner_row(
            "triage",
            best_triage,
            f'{num(best_triage.get("triage_score")):.3f}',
            workload_caveat(best_triage) if best_triage else "not scored in this run",
        ),
        winner_row(
            "<=2.0 GB artifact",
            best_small,
            score_label(best_small.get("trusted_fit_score")),
            "small-fit pick, still gate-aware" if best_small else "no current overall-fit row",
        ),
        winner_row(
            "correct jobs/sec/GB",
            efficiency_row,
            f'{num(efficiency_row.get("correct_jobs_per_second_per_gb")):.3f}',
            "compare timing after one same-run sweep" if efficiency_row else "no current overall-fit row",
        ),
    ]

    lines = [
        "# Otlet Model-Fit Benchmark Report",
        "",
        "This benchmark scores current local GGUF models as Otlet workers inside Postgres. Each case provides the evidence in source rows. The score measures strict JSON, trusted actions, row watching, receipts, semantic materialization, stale safety, EXPLAIN visibility, TTFT, decode throughput, memory, and artifact size",
        "",
        "`production_score` is zero until a model passes every production gate with at least 3 same-run repeats. `overall_fit` is the broad Otlet research score: trusted output quality with a soft resource adjustment for artifact GB, resident RSS, p95 latency, and active params. `diagnostic_fit` is separate and can read compact fields from rejected attempts. Invalid JSON never becomes trusted Otlet state",
        "",
        "The public report uses the current comparable scored set: default-included models plus current-family models with nonzero trusted fit. For the same family and size class, keep only the newest version in regular reports, such as Qwen3.5 4B over Qwen3 4B. Zero-score, unscored, superseded, and manual-only rows stay out of the public ranking",
        "",
        "## Findings",
        "",
        *findings,
        "",
        "A runnable model gets an overall fit score and a role. The report keeps load failures, manifest blocks, and run-limit skips out of the ranking instead of assigning fake zeros",
        "",
        "Verdicts are role-aware. A model can be useful for triage, row watching, hard-case comparison, or diagnostic prompt work while still failing the production gate",
        "",
        "## Current Limits",
        "",
        default_limit,
        timing_limit,
        coverage_limit,
        "- Candidate rankings are useful for deciding what to rerun or improve, not for shipping a model automatically",
        "",
        "## Run Integrity",
        "",
        table(
            ["key", "value"],
            [
                {"key": "benchmark_confidence", "value": confidence},
                {"key": "confidence_reason", "value": confidence_reason},
                {"key": "next_confidence_step", "value": confidence_next},
                {"key": "model_rows", "value": len(report_summaries)},
                {"key": "non_default_rows_excluded", "value": excluded_model_count},
                {"key": "raw_model_run_rows", "value": len(report_raw_summaries)},
                {"key": "case_rows", "value": len(report_cases)},
                {
                    "key": "scored_cases_per_model_run",
                    "value": compact_count(cases_per_model_run),
                },
                {"key": "repeat_count_range", "value": f"{min_repeats:.0f}-{max_repeats:.0f}"},
                {"key": "source_run_ids", "value": ", ".join(run_ids)},
                {
                    "key": "same_run_comparison",
                    "value": "yes" if len(run_ids) <= 1 else "no; latency/RSS compare best after one full rerun",
                },
                {"key": "score_basis", "value": "trusted accepted output first; resource fit is a soft adjustment"},
            ],
        ),
        "",
        "## Score Contract",
        "",
        "A model must pass the production gate with at least 3 same-run repeats before it can be called a default Otlet model. The gate requires no worker crash, no source-table mutation, no stale leak, schema >= 0.95, contract >= 0.95, exact confidence target accuracy >= 0.95, entity >= 0.80, triage >= 0.80, extraction >= 0.80, policy >= 0.80, zero false merges, hallucinated trusted actions <= 0.01, semantic materialization >= 0.95, and repeat_count >= 3",
        "",
        "`overall_fit = trusted_quality * (0.75 + 0.25 * resource_fit)` for a single run. `production_score = overall_fit` only when the production gate and repeat proof pass; otherwise it is 0.000. `trusted_quality` includes contract, entity-resolution, abstention, dirty-data, triage, numeric-evidence, extraction, policy-check, user-suite, row-watch, typed-action, semantic-materialization, and confidence scores. `resource_fit` weights artifact GB 40%, resident RSS 30%, p95 latency 20%, and active params 10%. The targets are <=2.0 GB artifact, <=2.5 GB resident RSS, <=20s p95 generation, and <=3B active params. A model over a target is discounted by target/value instead of zeroed out. Repeated models rank by their worst overall-fit repeat; the scorecard shows mean, min, max, and standard deviation. `diagnostic_fit` uses the same soft resource adjustment but starts from diagnostic fields",
        "",
        "## Score Audit",
        "",
        "This table explains the headline fit score without requiring a reader to reverse-engineer the TSVs. A scored zero means the model ran and produced no useful trusted or diagnostic Otlet signal. Out-of-running means the model did not produce a comparable result",
        "",
        table(["rank", "model", "role", "score_status", "production_gate", "overall_fit", "trusted_quality", "resource_fit", "score_reason", "first_blocker"], audit_rows),
        "",
        "## Overall Fit Chart",
        "",
        f"![Overall Otlet fit]({overall.name})",
        "",
        "## Workload Winners",
        "",
        table(["workload", "model", "metric", "gate", "caveat"], workload_rows),
        "",
        "## Production Readiness",
        "",
        "The repeat-aware default-model gate sets `production_score` to zero for non-passing models, even when `overall_fit` or a workload role is useful",
        "",
        table(["rank", "model", "readiness", "production_score", "overall_fit", "gate", "first_blocker"], readiness_rows),
        "",
        "## <=2.0 GB Artifact Candidates",
        "",
        "The Otlet-small track includes models whose measured artifact in the run is at or below 2.0 GB",
        "",
        table(["rank", "model", "overall_fit", "trusted_quality", "resource_fit", "schema", "p95_ms", "ttft_ms", "rss_gb", "artifact_gb"], small_candidate_rows)
        if small_candidate_rows
        else "The run measured no <=2.0 GB artifact candidates",
        "",
        "## Blocker Summary",
        "",
        table(["failed_gate", "models"], blocker_rows),
        "",
        "## First Failure Modes",
        "",
        table(["model", "top_failure", "count", "passed_cases"], failure_mode_rows)
        if failure_mode_rows
        else "The report has no scored case failures",
        "",
        "## Failure Mode Breakdown",
        "",
        table(["model", *failure_modes], failure_mode_detail_rows)
        if failure_mode_detail_rows
        else "The report has no scored case failures",
        "",
        "## Gate Summary",
        "",
        table(["model", "runs", "verdict", "gate", "failed_gate", "schema", "contract", "confidence", "entity", "abstain", "triage", "extraction", "policy", "actions", "semantic"], gate_rows),
        "",
        "## Out Of Running",
        "",
        table(["model", "status", "reason", "tier", "artifact_gb"], out_of_running_rows)
        if out_of_running_rows
        else "No selected models were out of running",
        "",
        "## Overall Fit Ranking",
        "",
        "The report ranks models by `overall_fit`, not default readiness. Use this table to choose what to improve or rerun. The production readiness table above decides whether a model is safe to call a default Otlet model",
        "",
        table(
            [
                "rank",
                "model",
                "repeat_count",
                "verdict",
                "readiness",
                "production_score",
                "overall_fit",
                "diagnostic_fit",
                "fit_min",
                "fit_max",
                "fit_sd",
                "trusted_quality",
                "schema",
                "diag_decision",
                "trusted_decision",
                "confidence",
                "diag_confidence",
                "row_watch",
                "params_b",
                "active_b",
                "p95_ms",
                "ttft_ms",
                "prompt_ms",
                "tok_s",
                "steady_tok_s",
                "rss_gb",
                "artifact_gb",
                "correct_jobs_s_gb",
                "overall_fit_jobs_s_gb",
                "quality_per_active_b",
                "resource_fit",
            ],
            summary_rows,
        )
        if summary_rows
        else "The run exported no current overall-score rows because required scoring metrics are missing",
        "",
        "## Track Breakdown",
        "",
        table(["model", "contract", "entity", "abstain", "dirty", "triage", "triage_abstain", "numeric", "extraction", "policy", "user_suite", "row_watch", "actions", "confidence", "diag_triage", "diag_numeric", "diag_actions", "diag_confidence", "semantic"], track_rows),
        "",
        "## Selected Failure Examples",
        "",
        "One representative failed case per model is shown here. The full case table has every scored case",
        "",
        table(["model", "case", "expected", "trusted", "expected_conf", "trusted_conf", "raw_conf", "raw", "action", "raw_action", "receipt", "hash", "reason"], failure_rows)
        if failure_rows
        else "The run exported no failing cases",
        "",
        "## Charts",
        "",
        f"- Overall fit chart: `{overall.name}`",
        f"- Pareto: `{pareto.name}`",
        f"- Params: `{params.name}`",
        f"- Latency: `{latency.name}`",
        f"- TTFT: `{ttft.name}`",
        f"- Prompt decode: `{prompt_decode.name}`",
        f"- Efficiency: `{efficiency.name}`",
        f"- Score audit TSV: `{score_audit.name}`",
        f"- Scorecard TSV: `{scorecard.name}`",
        "",
        "## Cleanup",
        "",
        table(["key", "value"], [{"key": k, "value": v} for k, v in sorted(cleanup.items())]),
        "",
        "## Run Metadata",
        "",
        table(["key", "value"], [{"key": k, "value": v} for k, v in sorted(meta.items()) if k != "reproduction_command"]),
        "",
        "## Ranked Models",
        "",
        table(
            [
                "model",
                "family",
                "tier",
                "quant",
                "params_b",
                "active_b",
                "ctx",
                "updated",
                "downloads",
                "likes",
                "hint_gb",
                "artifact",
                "license",
                "source",
            ],
            model_rows,
        ),
        "",
        "## Reproduce",
        "",
        "```sh",
        recommended_command,
        "```",
        "",
    ]
    report.write_text("\n".join(clean_lines(lines)), encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
