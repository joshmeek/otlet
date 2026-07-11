import statistics

from report_io import num


def ranked(rows):
    return sorted(
        rows,
        key=lambda row: (num(row.get("otlet_fit_score")), num(row.get("quality_score"))),
        reverse=True,
    )


def truthy(value):
    return str(value).lower() in ("t", "true", "1", "yes")


def add_otlet_fit(row):
    out_of_running = row.get("run_status") not in (None, "", "complete")
    missing_required_metric = row.get("confidence_score") in (None, "")
    trusted_fit = 0.0 if out_of_running or missing_required_metric else num(row.get("overall_fit"))
    diagnostic_fit = 0.0 if out_of_running else num(row.get("diagnostic_fit"))
    row["trusted_quality"] = 0.0 if out_of_running or missing_required_metric else num(row.get("trusted_quality", row.get("quality_score")))
    row["resource_fit"] = num(row.get("resource_fit"))
    row["trusted_fit_score"] = trusted_fit
    row["overall_fit"] = trusted_fit
    row["diagnostic_fit_score"] = diagnostic_fit
    row["diagnostic_fit"] = diagnostic_fit
    row["otlet_fit_score"] = trusted_fit
    if out_of_running:
        row["score_status"] = "out_of_running"
    elif missing_required_metric:
        row["score_status"] = "needs_current_scoring_run"
    else:
        row["score_status"] = "scored"


def gate_failures(row):
    if "_final_gate_failures" in row:
        return row["_final_gate_failures"]
    failures = list(row.get("_gate_failures") or [])
    if not failures:
        if row.get("run_status") and row.get("run_status") != "complete":
            return [row.get("unsupported_reason") or "run not complete"]
        if num(row.get("worker_crash_count")) > 0:
            failures.append("worker crash")
        if truthy(row.get("source_table_mutated")):
            failures.append("source table mutated")
        if num(row.get("stale_leak_count")) > 0:
            failures.append("stale result leaked")
        if num(row.get("schema_valid_rate")) < 0.95:
            failures.append("schema < 0.95")
        if num(row.get("contract_score")) < 0.95:
            failures.append("contract < 0.95")
        if row.get("confidence_score") in (None, ""):
            failures.append("confidence not measured")
        elif num(row.get("confidence_score")) < 0.95:
            failures.append("confidence < 0.95")
        if num(row.get("entity_accuracy")) < 0.80:
            failures.append("entity < 0.80")
        if metric_present(row, "triage_score") and num(row.get("triage_score")) < 0.80:
            failures.append("triage < 0.80")
        if metric_present(row, "extraction_score") and num(row.get("extraction_score")) < 0.80:
            failures.append("extraction < 0.80")
        if metric_present(row, "policy_check_score") and num(row.get("policy_check_score")) < 0.80:
            failures.append("policy < 0.80")
        if num(row.get("abstention_false_merge_rate")) > 0:
            failures.append("false merge")
        if num(row.get("hallucinated_trusted_action_rate")) > 0.01:
            failures.append("hallucinated action")
        if num(row.get("semantic_materialization_score")) < 0.95:
            failures.append("semantic < 0.95")
    if row.get("run_status") == "complete" and metric_present(row, "repeat_count") and not repeat_proven(row):
        failures.append("repeat_count < 3")
    return failures


def display_verdict(row):
    if "_final_display_verdict" in row:
        return row["_final_display_verdict"]
    if row.get("run_status") and row.get("run_status") != "complete":
        return "not_supported"
    failures = gate_failures(row)
    if failures == ["repeat_count < 3"] and num(row.get("quality_score")) >= 0.90:
        return "eligible_candidate"
    if not failures and num(row.get("quality_score")) >= 0.90:
        return "default_candidate"
    if not failures:
        return "eligible_candidate"
    if num(row.get("worker_crash_count")) > 0 or truthy(row.get("source_table_mutated")) or num(row.get("stale_leak_count")) > 0:
        return "unsafe_rejected"
    if (
        failures == ["hallucinated action"]
        and num(row.get("schema_valid_rate")) >= 0.95
        and num(row.get("contract_score")) >= 0.95
        and num(row.get("entity_resolution_score")) >= 0.80
    ):
        return "hard_case_candidate_needs_action_fix"
    if (
        num(row.get("triage_score")) >= 0.70
        and num(row.get("schema_valid_rate")) >= 0.50
        and num(row.get("confidence_score")) >= 0.50
        and num(row.get("abstention_false_merge_rate")) == 0
        and num(row.get("hallucinated_trusted_action_rate")) <= 0.01
    ):
        return "triage_candidate"
    if (
        num(row.get("schema_valid_rate")) >= 0.95
        and num(row.get("contract_score")) >= 0.95
        and num(row.get("row_watch_score")) >= 0.80
    ):
        return "row_watch_candidate_limited"
    if num(row.get("row_watch_score")) >= 0.70 and num(row.get("semantic_materialization_score")) >= 0.50:
        return "row_watch_candidate"
    if (
        num(row.get("entity_resolution_score")) >= 0.50
        and num(row.get("schema_valid_rate")) >= 0.50
        and num(row.get("abstention_false_merge_rate")) == 0
    ):
        return "hard_case_candidate"
    if (
        num(row.get("schema_valid_rate")) >= 0.25
        or num(row.get("semantic_materialization_score")) >= 0.25
        or num(row.get("row_watch_score")) >= 0.25
    ):
        return "partial_candidate"
    if num(row.get("diagnostic_quality_score")) >= 0.20:
        return "diagnostic_only"
    if num(row.get("schema_valid_rate")) > 0:
        return "contract_blocked"
    return "unusable"


def gate_status(row):
    if "_final_gate_status" in row:
        return row["_final_gate_status"]
    return "pass" if not gate_failures(row) else "fail"


def production_score(row):
    if "_final_production_score" in row:
        return row["_final_production_score"]
    return num(row.get("trusted_fit_score")) if gate_status(row) == "pass" else 0.0


def readiness(row):
    if "_final_readiness" in row:
        return row["_final_readiness"]
    if row.get("run_status") and row.get("run_status") != "complete":
        return "not_supported"
    failures = gate_failures(row)
    if failures == ["repeat_count < 3"] and num(row.get("quality_score")) >= 0.90:
        return "needs_repeat_proof"
    if not failures and num(row.get("quality_score")) >= 0.90:
        return "default_ready"
    if not failures:
        return "eligible_candidate"
    verdict = display_verdict(row)
    if verdict in (
        "triage_candidate",
        "hard_case_candidate",
        "hard_case_candidate_needs_action_fix",
        "row_watch_candidate",
        "row_watch_candidate_limited",
        "partial_candidate",
    ):
        return "workload_candidate"
    if verdict == "diagnostic_only":
        return "diagnostic_only"
    if verdict == "unusable":
        return "unusable"
    if num(row.get("schema_valid_rate")) < 0.25 or num(row.get("contract_score")) < 0.25:
        return "contract_blocked"
    return "research_only"


def finalize_report_status(rows):
    for row in rows:
        row["_final_gate_failures"] = gate_failures(row)
        row["_final_gate_status"] = gate_status(row)
        row["_final_display_verdict"] = display_verdict(row)
        row["_final_readiness"] = readiness(row)
        row["_final_production_score"] = production_score(row)
    return rows


def first_blocker(row):
    failures = gate_failures(row)
    return failures[0] if failures else ""


def case_failure_mode(row):
    if row.get("schema_valid") != "t":
        error = row.get("error", "")
        if "invalid model JSON" in error:
            return "invalid_json"
        if '"match" is a required property' in error:
            return "bad_output_envelope"
        if "schema validation failed" in error:
            return "schema_invalid"
        return "schema_missing"
    if row.get("false_merge") == "t":
        return "false_merge"
    if row.get("match_correct") != "t":
        return "wrong_match"
    if row.get("confidence_correct") != "t":
        return "wrong_confidence"
    if row.get("action_correct") != "t":
        return "wrong_action"
    return "passed"


def benchmark_confidence(summaries, raw_summaries, case_count, run_ids):
    complete_raw_summaries = [row for row in raw_summaries if row.get("run_status") == "complete"]
    complete_summaries = [row for row in summaries if row.get("run_status") == "complete"]
    if not summaries or not raw_summaries:
        return (
            "no_result",
            "Benchmark exported no rows",
            "Run at least the Qwen smoke benchmark",
        )
    if not complete_raw_summaries:
        return (
            "no_scored_models",
            "Benchmark exported no complete model runs",
            "Run at least one supported model",
        )
    cases_per_run = case_count / len(complete_raw_summaries)
    repeats = [num(row.get("repeat_count")) for row in complete_summaries]
    min_repeats = min(repeats) if repeats else 0
    same_run = len(run_ids) <= 1
    gate_passes = sum(1 for row in complete_summaries if gate_status(row) == "pass")
    if cases_per_run >= 100 and min_repeats >= 3 and same_run and gate_passes:
        return (
            "frontier_confident",
            "Repeated same-run suite with frontier-size case coverage and at least one production-gated model",
            "Use workload-specific winners and Pareto metrics",
        )
    if cases_per_run >= 40 and min_repeats >= 3 and same_run:
        return (
            "stable_research",
            "Repeated same-run suite with useful diagnostic coverage",
            "Keep 100+ cases per model for the full frontier report",
        )
    if min_repeats >= 3 and same_run:
        return (
            "stable_smoke",
            "Repeated same-run smoke with stable scoring but limited case coverage",
            "Expand gold cases before making broad claims",
        )
    if same_run:
        return (
            "provisional_single_run",
            "Single-run result; useful for direction, not stability",
            "Rerun with OTLET_BENCH_RUNS=3",
        )
    return (
        "merged_provisional",
        "Merged runs; quality gates are comparable, but timing and RSS need one same-run sweep",
        "Run the same selected model set in one OTLET_BENCH_RUNS=3 publish run",
    )


def mean(values):
    return statistics.fmean(values) if values else 0.0


def stdev(values):
    return statistics.stdev(values) if len(values) >= 2 else 0.0


def model_base_map(models):
    out = {}
    for row in models:
        model_key = row.get("model_key", "")
        if model_key:
            out[model_key] = row.get("base_model_key") or model_key
    return out


def with_base_key(row, base_by_model):
    row["base_model_key"] = base_by_model.get(row.get("model_key", ""), row.get("model_key", ""))
    return row


def aggregate_summaries(rows, models):
    base_by_model = model_base_map(models)
    model_by_base = {}
    for row in models:
        base = row.get("base_model_key") or row.get("model_key", "")
        if base and base not in model_by_base:
            model_by_base[base] = row
    groups = {}
    for row in rows:
        add_otlet_fit(row)
        with_base_key(row, base_by_model)
        groups.setdefault(row["base_model_key"], []).append(row)

    mean_fields = [
        "declared_params_b",
        "active_params_b",
        "context_tokens",
        "schema_valid_rate",
        "entity_accuracy",
        "abstention_false_merge_rate",
        "hallucinated_trusted_action_rate",
        "p50_generate_ms",
        "p50_ttft_ms",
        "p50_prompt_decode_ms",
        "mean_tokens_per_second",
        "mean_steady_tokens_per_second",
        "jobs_per_second",
        "correct_jobs_per_second_per_gb",
        "quality_per_artifact_gb",
        "contract_score",
        "entity_resolution_score",
        "abstention_score",
        "dirty_data_score",
        "triage_score",
        "triage_abstention_score",
        "numeric_evidence_score",
        "extraction_score",
        "policy_check_score",
        "user_suite_score",
        "row_watch_score",
        "typed_action_score",
        "semantic_materialization_score",
        "confidence_score",
        "diagnostic_entity_accuracy",
        "diagnostic_triage_accuracy",
        "diagnostic_numeric_accuracy",
        "diagnostic_action_accuracy",
        "diagnostic_confidence_accuracy",
        "diagnostic_quality_score",
        "quality_score",
    ]
    max_fields = [
        "artifact_bytes",
        "artifact_gb",
        "resident_gb",
        "p95_generate_ms",
        "p95_ttft_ms",
        "p95_prompt_decode_ms",
        "stale_leak_count",
        "worker_crash_count",
    ]

    out = []
    for base, group in groups.items():
        aggregate = group[0].copy()
        aggregate.update({k: v for k, v in model_by_base.get(base, {}).items() if v not in (None, "")})
        aggregate["model_key"] = base
        aggregate["base_model_key"] = base
        aggregate["model_name"] = base
        aggregate["run_id"] = ",".join(sorted({row.get("run_id", "") for row in group if row.get("run_id")}))
        aggregate["repeat_count"] = len(group)
        aggregate["total_cases"] = sum(num(row.get("total_cases")) for row in group)
        aggregate["source_table_mutated"] = "t" if any(truthy(row.get("source_table_mutated")) for row in group) else "f"
        aggregate["external_artifact"] = "t" if all(truthy(row.get("external_artifact")) for row in group) else "f"
        aggregate["run_status"] = "complete" if all(row.get("run_status") == "complete" for row in group) else "mixed"
        aggregate["unsupported_reason"] = "; ".join(
            sorted({row.get("unsupported_reason", "") for row in group if row.get("unsupported_reason")})
        )

        for field in mean_fields:
            values = [
                value
                for row in group
                if (value := num(row.get(field), None)) is not None
            ]
            aggregate[field] = mean(values) if values else ""
        for field in max_fields:
            values = [
                value
                for row in group
                if (value := num(row.get(field), None)) is not None
            ]
            aggregate[field] = max(values) if values else 0.0

        repeat_failures = []
        for row in group:
            repeat_failures.extend(gate_failures(row))
        aggregate["_gate_failures"] = sorted(set(repeat_failures))

        add_otlet_fit(aggregate)
        trusted_scores = [num(row.get("trusted_fit_score")) for row in group]
        diagnostic_scores = [num(row.get("diagnostic_fit_score")) for row in group]
        aggregate["trusted_fit_mean"] = mean(trusted_scores)
        aggregate["trusted_fit_min"] = min(trusted_scores) if trusted_scores else 0.0
        aggregate["trusted_fit_max"] = max(trusted_scores) if trusted_scores else 0.0
        aggregate["trusted_fit_sd"] = stdev(trusted_scores)
        aggregate["diagnostic_fit_mean"] = mean(diagnostic_scores)
        aggregate["diagnostic_fit_min"] = min(diagnostic_scores) if diagnostic_scores else 0.0
        aggregate["diagnostic_fit_max"] = max(diagnostic_scores) if diagnostic_scores else 0.0
        aggregate["diagnostic_fit_sd"] = stdev(diagnostic_scores)
        aggregate["trusted_fit_score"] = aggregate["trusted_fit_min"]
        aggregate["diagnostic_fit_score"] = aggregate["diagnostic_fit_min"]
        aggregate["otlet_fit_score"] = aggregate["trusted_fit_score"]
        aggregate["overall_fit"] = aggregate["trusted_fit_score"]
        aggregate["diagnostic_fit"] = aggregate["diagnostic_fit_score"]
        aggregate["stability_status"] = "stable_proof" if len(group) >= 3 else "single_run" if len(group) == 1 else "limited_repeats"
        out.append(aggregate)

    return out


def add_missing_model_rows(summaries, models):
    seen = {row.get("model_key", "") for row in summaries}
    out = list(summaries)
    for row in models:
        model_key = row.get("base_model_key") or row.get("model_key", "")
        if not model_key or model_key in seen:
            continue
        missing = row.copy()
        missing["model_key"] = model_key
        missing["base_model_key"] = model_key
        missing["model_name"] = model_key
        missing["run_id"] = ""
        missing["repeat_count"] = 0
        missing["run_status"] = "not_scored"
        missing["unsupported_reason"] = "selected model has no model_summary row"
        missing["score_status"] = "out_of_running"
        missing["stability_status"] = "not_run"
        missing["source_table_mutated"] = "f"
        missing["external_artifact"] = row.get("external_artifact", "f")
        for field in (
            "total_cases",
            "schema_valid_rate",
            "entity_accuracy",
            "abstention_false_merge_rate",
            "hallucinated_trusted_action_rate",
            "stale_leak_count",
            "worker_crash_count",
            "artifact_gb",
            "resident_gb",
            "p50_generate_ms",
            "p95_generate_ms",
            "p50_ttft_ms",
            "p95_ttft_ms",
            "p50_prompt_decode_ms",
            "p95_prompt_decode_ms",
            "mean_tokens_per_second",
            "mean_steady_tokens_per_second",
            "jobs_per_second",
            "correct_jobs_per_second_per_gb",
            "quality_per_artifact_gb",
            "contract_score",
            "entity_resolution_score",
            "abstention_score",
            "dirty_data_score",
            "triage_score",
            "triage_abstention_score",
            "numeric_evidence_score",
            "extraction_score",
            "policy_check_score",
            "user_suite_score",
            "row_watch_score",
            "typed_action_score",
            "semantic_materialization_score",
            "diagnostic_entity_accuracy",
            "diagnostic_triage_accuracy",
            "diagnostic_numeric_accuracy",
            "diagnostic_action_accuracy",
            "diagnostic_confidence_accuracy",
            "diagnostic_quality_score",
            "quality_score",
        ):
            missing.setdefault(field, 0.0)
        missing["confidence_score"] = ""
        add_otlet_fit(missing)
        out.append(missing)
        seen.add(model_key)
    return out


def current_report_rows(rows):
    return [
        row
        for row in rows
        if row.get("tier") == "core"
        and (row.get("include_by_default") == "true" or num(row.get("trusted_fit_score")) > 0)
        and display_verdict(row) != "unusable"
    ]


def score_label(value):
    value = num(value)
    if value == 0:
        return "0.000"
    if abs(value) < 0.001:
        return f"{value:.6f}"
    return f"{value:.3f}"

def metric_present(row, key):
    return row.get(key) not in (None, "")

def repeat_proven(row):
    return num(row.get("repeat_count")) >= 3

def score_reason(row):
    status = row.get("score_status", "")
    if status == "out_of_running":
        return f'out of running: {row.get("unsupported_reason") or first_blocker(row)}'
    if status == "needs_current_scoring_run":
        return "missing current scoring metrics"
    verdict = display_verdict(row)
    if num(row.get("trusted_fit_score")) == 0:
        if num(row.get("quality_score")) == 0:
            if verdict == "diagnostic_only":
                return "diagnostic signal only; no trusted accepted output"
            return "ran but created no useful Otlet signal"
        if num(row.get("resource_fit")) == 0:
            return "trusted work scored but no measured resource fit"
    return "trusted_quality with soft resource adjustment"

def score_audit_rows(rows):
    out = []
    for rank, row in enumerate(ranked(rows), start=1):
        scored = row.get("score_status") == "scored"
        out.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "role": display_verdict(row),
                "score_status": row.get("score_status", ""),
                "production_gate": gate_status(row),
                "readiness": readiness(row),
                "overall_fit": score_label(row.get("trusted_fit_score")) if scored else "",
                "production_score": f"{production_score(row):.6f}" if scored else "",
                "trusted_quality": f'{num(row.get("quality_score")):.6f}' if scored else "",
                "resource_fit": f'{num(row.get("resource_fit")):.6f}' if scored else "",
                "score_reason": score_reason(row),
                "first_blocker": first_blocker(row),
                "schema": f'{num(row.get("schema_valid_rate")):.6f}',
                "contract": f'{num(row.get("contract_score")):.6f}',
                "entity": f'{num(row.get("entity_accuracy")):.6f}',
                "confidence": f'{num(row.get("confidence_score")):.6f}' if row.get("confidence_score") not in (None, "") else "",
                "triage": f'{num(row.get("triage_score")):.6f}' if metric_present(row, "triage_score") else "",
                "row_watch": f'{num(row.get("row_watch_score")):.6f}',
                "semantic": f'{num(row.get("semantic_materialization_score")):.6f}',
                "false_merge": f'{num(row.get("abstention_false_merge_rate")):.6f}',
                "hallucinated_action": f'{num(row.get("hallucinated_trusted_action_rate")):.6f}',
                "stale_leaks": f'{num(row.get("stale_leak_count")):.0f}',
                "source_mutated": "1" if truthy(row.get("source_table_mutated")) else "0",
                "p95_ms": f'{num(row.get("p95_generate_ms")):.3f}',
                "ttft_ms": f'{num(row.get("p95_ttft_ms")):.3f}',
                "rss_gb": f'{num(row.get("resident_gb")):.6f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.6f}',
            }
        )
    return out
