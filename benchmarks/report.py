#!/usr/bin/env python3
import csv
import html
import math
import sys
from pathlib import Path


SMALL_ARTIFACT_GB = 2.0
RESIDENT_TARGET_GB = 2.5
P95_TARGET_MS = 20000.0
ACTIVE_PARAMS_TARGET_B = 3.0


def read_tsv(path):
    if not path.exists() or path.stat().st_size == 0:
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def read_kv(path):
    rows = read_tsv(path)
    return {row.get("key", ""): row.get("value", "") for row in rows}


def num(value, default=0.0):
    try:
        if value in (None, ""):
            return default
        return float(value)
    except ValueError:
        return default


def short(value, n=80):
    value = "" if value is None else str(value)
    value = " ".join(value.replace("|", "\\|").split())
    return value if len(value) <= n else value[: n - 1] + "..."


def cell(value):
    return " ".join(("" if value is None else str(value)).replace("|", "\\|").split())


def table(headers, rows):
    numeric = {
        "rank",
        "runs",
        "repeat_count",
        "otlet_fit",
        "overall_score",
        "production_score",
        "candidate_fit",
        "diagnostic_fit",
        "fit_min",
        "fit_max",
        "fit_sd",
        "trusted_gate",
        "schema",
        "diag_decision",
        "trusted_decision",
        "confidence",
        "diag_confidence",
        "row_watch",
        "params_b",
        "active_b",
        "downloads",
        "likes",
        "hint_gb",
        "p95_ms",
        "tok_s",
        "rss_gb",
        "artifact_gb",
        "resource_fit",
        "artifact_fit",
        "resident_fit",
        "latency_fit",
        "active_param_fit",
        "correct_jobs_s_gb",
        "candidate_fit_jobs_s_gb",
        "quality_per_active_b",
        "contract",
        "entity",
        "abstain",
        "dirty",
        "actions",
        "diag_actions",
        "semantic",
        "count",
        "passed_cases",
        "invalid_json",
        "bad_output_envelope",
        "schema_invalid",
        "schema_missing",
        "false_merge",
        "wrong_match",
        "wrong_confidence",
        "wrong_action",
        "passed",
        "false_merge",
        "hallucinated_action",
        "stale_leaks",
        "source_mutated",
    }
    separator = [("---:" if header in numeric else "---") for header in headers]
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(separator) + " |"]
    for row in rows:
        out.append("| " + " | ".join(cell(row.get(h, "")) for h in headers) + " |")
    return "\n".join(out)


def ranked(rows):
    return sorted(
        rows,
        key=lambda row: (num(row.get("trusted_fit_score")), num(row.get("quality_score"))),
        reverse=True,
    )


def truthy(value):
    return str(value).lower() in ("t", "true", "1", "yes")


def resource_component(row, key, target):
    value = row.get(key)
    if value in (None, ""):
        return 0.0
    value = num(value)
    if value <= 0:
        return 0.0
    return max(0.0, min(1.0, 1.0 - value / target))


def add_otlet_fit(row):
    artifact_fit = resource_component(row, "artifact_gb", SMALL_ARTIFACT_GB)
    resident_fit = resource_component(row, "resident_gb", RESIDENT_TARGET_GB)
    latency_fit = resource_component(row, "p95_generate_ms", P95_TARGET_MS)
    active_fit = resource_component(row, "active_params_b", ACTIVE_PARAMS_TARGET_B)
    resource_fit = 0.40 * artifact_fit + 0.30 * resident_fit + 0.20 * latency_fit + 0.10 * active_fit
    out_of_running = row.get("run_status") not in (None, "", "complete")
    missing_required_metric = row.get("confidence_score") in (None, "")
    trusted_quality = 0.0 if out_of_running or missing_required_metric else num(row.get("quality_score"))
    row["artifact_fit"] = artifact_fit
    row["resident_fit"] = resident_fit
    row["latency_fit"] = latency_fit
    row["active_param_fit"] = active_fit
    row["resource_fit"] = resource_fit
    row["trusted_fit_score"] = trusted_quality * resource_fit
    row["diagnostic_fit_score"] = num(row.get("diagnostic_quality_score")) * resource_fit
    row["otlet_fit_score"] = row["trusted_fit_score"]
    if out_of_running:
        row["score_status"] = "out_of_running"
    elif missing_required_metric:
        row["score_status"] = "needs_current_scoring_run"
    else:
        row["score_status"] = "scored"


def gate_failures(row):
    if row.get("_gate_failures"):
        return row["_gate_failures"]
    failures = []
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
    if num(row.get("abstention_false_merge_rate")) > 0:
        failures.append("false merge")
    if num(row.get("hallucinated_trusted_action_rate")) > 0.01:
        failures.append("hallucinated action")
    if num(row.get("semantic_materialization_score")) < 0.95:
        failures.append("semantic < 0.95")
    return failures


def display_verdict(row):
    if row.get("run_status") and row.get("run_status") != "complete":
        return "not_supported"
    failures = gate_failures(row)
    if not failures and num(row.get("quality_score")) >= 0.90:
        return "default_candidate"
    if not failures:
        return "eligible_candidate"
    if (
        failures == ["hallucinated action"]
        and num(row.get("schema_valid_rate")) >= 0.95
        and num(row.get("contract_score")) >= 0.95
        and num(row.get("entity_resolution_score")) >= 0.80
    ):
        return "hard_case_candidate_needs_action_fix"
    if (
        num(row.get("schema_valid_rate")) >= 0.95
        and num(row.get("contract_score")) >= 0.95
        and num(row.get("row_watch_score")) >= 0.80
    ):
        return "row_watch_candidate_limited"
    return "too_unreliable"


def gate_status(row):
    return "pass" if not gate_failures(row) else "fail"


def production_score(row):
    return num(row.get("trusted_fit_score")) if gate_status(row) == "pass" else 0.0


def readiness(row):
    if row.get("run_status") and row.get("run_status") != "complete":
        return "not_supported"
    failures = gate_failures(row)
    if not failures and num(row.get("quality_score")) >= 0.90:
        return "default_ready"
    if not failures:
        return "eligible_candidate"
    if display_verdict(row) in ("hard_case_candidate_needs_action_fix", "row_watch_candidate_limited"):
        return "workload_candidate"
    if num(row.get("schema_valid_rate")) < 0.50 or num(row.get("contract_score")) < 0.50:
        return "contract_blocked"
    return "research_only"


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
    values = [v for v in values if v != "" and v is not None]
    return sum(values) / len(values) if values else 0.0


def stdev(values):
    values = [v for v in values if v != "" and v is not None]
    if len(values) < 2:
        return 0.0
    avg = mean(values)
    return math.sqrt(sum((v - avg) ** 2 for v in values) / (len(values) - 1))


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
        "mean_tokens_per_second",
        "jobs_per_second",
        "correct_jobs_per_second_per_gb",
        "quality_per_artifact_gb",
        "contract_score",
        "entity_resolution_score",
        "abstention_score",
        "dirty_data_score",
        "row_watch_score",
        "typed_action_score",
        "semantic_materialization_score",
        "confidence_score",
        "diagnostic_entity_accuracy",
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
        "stale_leak_count",
        "worker_crash_count",
    ]

    out = []
    for base, group in groups.items():
        aggregate = group[0].copy()
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
            values = [num(row.get(field), None) for row in group]
            values = [value for value in values if value is not None]
            aggregate[field] = mean(values) if values else ""
        for field in max_fields:
            values = [num(row.get(field), None) for row in group]
            values = [value for value in values if value is not None]
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
            "mean_tokens_per_second",
            "jobs_per_second",
            "correct_jobs_per_second_per_gb",
            "quality_per_artifact_gb",
            "contract_score",
            "entity_resolution_score",
            "abstention_score",
            "dirty_data_score",
            "row_watch_score",
            "typed_action_score",
            "semantic_materialization_score",
            "diagnostic_entity_accuracy",
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


def svg_shell(width, height, body):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<rect width="100%" height="100%" fill="#ffffff"/>
<style>
text {{ font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; fill: #20242a; }}
.axis {{ stroke: #4b5563; stroke-width: 1; }}
.grid {{ stroke: #e5e7eb; stroke-width: 1; }}
.bar {{ fill: #2563eb; }}
.point {{ fill: #dc2626; stroke: #7f1d1d; stroke-width: 1; opacity: 0.85; }}
</style>
{body}
</svg>
"""


def text_width(value):
    return max(1, len(str(value))) * 7


def nice_max(value):
    value = max(0.0, float(value))
    if value == 0:
        return 1.0
    magnitude = 10 ** math.floor(math.log10(value))
    for step in (1, 2, 5, 10):
        candidate = step * magnitude
        if candidate >= value:
            return candidate
    return 10 * magnitude


def tick_label(value):
    value = float(value)
    if value == 0:
        return "0"
    if abs(value) >= 100:
        return f"{value:.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}".rstrip("0").rstrip(".")
    if abs(value) >= 1:
        return f"{value:.2f}".rstrip("0").rstrip(".")
    return f"{value:.3f}".rstrip("0").rstrip(".")


def score_label(value):
    value = num(value)
    if value == 0:
        return "0.000"
    if abs(value) < 0.001:
        return f"{value:.6f}"
    return f"{value:.3f}"


def write_empty_chart(path, title):
    path.write_text(
        svg_shell(720, 360, f'<text x="24" y="42">{html.escape(title)}: no rows</text>\n'),
        encoding="utf-8",
    )


def write_scatter(path, rows, x_key, y_key, title, x_label, y_label):
    if not rows:
        write_empty_chart(path, title)
        return
    rows = ranked(rows)
    width = 920
    left, right, top = 72, 48, 42
    plot_w, plot_h = width - left - right, 500
    legend_top = top + plot_h + 72
    legend_rows = math.ceil(len(rows) / 2)
    height = max(width, legend_top + 24 + legend_rows * 19)
    legend_x_left = left
    legend_x_right = left + 430
    max_x = nice_max(max(num(r.get(x_key)) for r in rows) or 1.0)
    max_y = 1.0 if y_key.endswith("score") else nice_max(max(num(r.get(y_key)) for r in rows) or 1.0)
    max_artifact = max(num(r.get("artifact_gb")) for r in rows) or 1.0
    parts = [
        f'<text x="24" y="24">{html.escape(title)}</text>',
        f'<line class="axis" x1="{left}" y1="{top + plot_h}" x2="{left + plot_w}" y2="{top + plot_h}"/>',
        f'<line class="axis" x1="{left}" y1="{top}" x2="{left}" y2="{top + plot_h}"/>',
        f'<text x="{left}" y="{top + plot_h + 42}">{html.escape(x_label)}</text>',
        f'<text x="18" y="{top + 12}">{html.escape(y_label)}</text>',
        f'<text x="{left}" y="{legend_top}">rank model score</text>',
    ]
    for i in range(5):
        x = left + plot_w * i / 4
        y = top + plot_h * i / 4
        x_value = max_x * i / 4
        y_value = max_y * (1 - i / 4)
        y_label_text = tick_label(y_value)
        parts.append(f'<line class="grid" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{top + plot_h}"/>')
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.1f}" x2="{left + plot_w}" y2="{y:.1f}"/>')
        parts.append(f'<text text-anchor="middle" x="{x:.1f}" y="{top + plot_h + 18:.1f}">{tick_label(x_value)}</text>')
        parts.append(
            f'<text text-anchor="end" x="{left - 8}" y="{y + 4:.1f}">{html.escape(y_label_text)}</text>'
        )
    for i, row in enumerate(rows, start=1):
        x = left + (num(row.get(x_key)) / max_x) * plot_w
        y = top + plot_h - (num(row.get(y_key)) / max_y) * plot_h
        radius = 5 + 10 * math.sqrt(num(row.get("artifact_gb")) / max_artifact)
        parts.append(f'<circle class="point" cx="{x:.1f}" cy="{y:.1f}" r="{radius:.1f}"/>')
        parts.append(
            f'<text style="fill:#ffffff" text-anchor="middle" x="{x:.1f}" y="{y + 4:.1f}">{i}</text>'
        )
        legend_index = i - 1
        legend_x = legend_x_left if legend_index < legend_rows else legend_x_right
        legend_y = legend_top + 24 + (legend_index % legend_rows) * 19
        label = f'{i}. {row.get("model_key", "model")} {num(row.get(y_key)):.3f}'
        parts.append(f'<text x="{legend_x}" y="{legend_y}">{html.escape(label)}</text>')
    path.write_text(svg_shell(width, height, "\n".join(parts)), encoding="utf-8")


def write_pareto(path, rows):
    write_scatter(
        path,
        rows,
        "resident_gb",
        "trusted_fit_score",
        "Pareto: resident GB vs overall score",
        "resident GB",
        "overall score",
    )


def write_bar(path, rows, value_key, title):
    if not rows:
        write_empty_chart(path, title)
        return
    rows = sorted(rows, key=lambda r: num(r.get(value_key)), reverse=True)
    longest = max(text_width(r.get("model_key", "model")) for r in rows)
    width = 1040
    row_h = 44
    height = max(width, 100 + row_h * len(rows))
    left, right, top = max(220, longest + 36), 136, 62
    max_value = nice_max(max(num(r.get(value_key)) for r in rows) or 1.0)
    bar_w = width - left - right
    bottom_y = top + row_h * len(rows) + 10
    parts = [
        f'<text x="24" y="26">{html.escape(title)}</text>',
        f'<line class="axis" x1="{left}" y1="{bottom_y}" x2="{left + bar_w}" y2="{bottom_y}"/>',
    ]
    for i in range(5):
        x = left + bar_w * i / 4
        value = max_value * i / 4
        parts.append(f'<line class="grid" x1="{x:.1f}" y1="{top - 8}" x2="{x:.1f}" y2="{bottom_y}"/>')
        parts.append(f'<text text-anchor="middle" x="{x:.1f}" y="{bottom_y + 18}">{tick_label(value)}</text>')
    for i, row in enumerate(rows):
        y = top + i * row_h
        value = num(row.get(value_key))
        w = (value / max_value) * bar_w
        value_label = tick_label(value)
        value_x = min(left + w + 6, width - text_width(value_label) - 20)
        parts.append(f'<text x="24" y="{y + 18}">{html.escape(row.get("model_key", "model"))}</text>')
        parts.append(f'<rect class="bar" x="{left}" y="{y}" width="{w:.1f}" height="20" rx="2"/>')
        parts.append(f'<text x="{value_x:.1f}" y="{y + 15}">{value_label}</text>')
    path.write_text(svg_shell(width, height, "\n".join(parts)), encoding="utf-8")


def write_param_fit(path, rows):
    rows = [row for row in rows if num(row.get("active_params_b")) > 0]
    if not rows:
        write_empty_chart(path, "Params")
        return
    write_scatter(
        path,
        rows,
        "active_params_b",
        "trusted_fit_score",
        "Active params vs overall score",
        "active params B",
        "overall score",
    )


def write_overall(path, rows):
    write_bar(path, rows, "trusted_fit_score", "Overall Otlet score, higher is better")


def write_scorecard(path, rows):
    fields = [
        "model_key",
        "repeat_count",
        "stability",
        "verdict",
        "gate_status",
        "gate_failures",
        "score_status",
        "readiness",
        "production_score",
        "candidate_fit",
        "trusted_fit",
        "trusted_fit_mean",
        "trusted_fit_min",
        "trusted_fit_max",
        "trusted_fit_sd",
        "diagnostic_fit",
        "trusted_gate",
        "diagnostic_quality",
        "resource_fit",
        "artifact_fit",
        "resident_fit",
        "latency_fit",
        "active_param_fit",
        "correct_jobs_s_gb",
        "candidate_fit_jobs_s_gb",
        "quality_per_active_b",
        "schema",
        "entity",
        "contract",
        "abstain",
        "dirty",
        "row_watch",
        "actions",
        "confidence",
        "diag_confidence",
        "semantic",
        "p95_ms",
        "tok_s",
        "rss_gb",
        "artifact_gb",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in ranked(rows):
            scored = row.get("score_status") == "scored"
            score = lambda key: f'{num(row.get(key)):.6f}' if scored else ""
            writer.writerow(
                {
                    "model_key": row.get("model_key", ""),
                    "repeat_count": row.get("repeat_count", ""),
                    "stability": row.get("stability_status", ""),
                    "verdict": display_verdict(row),
                    "gate_status": gate_status(row),
                    "gate_failures": "; ".join(gate_failures(row)),
                    "score_status": row.get("score_status", ""),
                    "readiness": readiness(row),
                    "production_score": f"{production_score(row):.6f}" if scored else "",
                    "candidate_fit": score("trusted_fit_score"),
                    "trusted_fit": score("trusted_fit_score"),
                    "trusted_fit_mean": score("trusted_fit_mean"),
                    "trusted_fit_min": score("trusted_fit_min"),
                    "trusted_fit_max": score("trusted_fit_max"),
                    "trusted_fit_sd": score("trusted_fit_sd"),
                    "diagnostic_fit": score("diagnostic_fit_score"),
                    "trusted_gate": f'{num(row.get("quality_score")):.6f}',
                    "diagnostic_quality": f'{num(row.get("diagnostic_quality_score")):.6f}',
                    "resource_fit": f'{num(row.get("resource_fit")):.6f}',
                    "artifact_fit": f'{num(row.get("artifact_fit")):.6f}',
                    "resident_fit": f'{num(row.get("resident_fit")):.6f}',
                    "latency_fit": f'{num(row.get("latency_fit")):.6f}',
                    "active_param_fit": f'{num(row.get("active_param_fit")):.6f}',
                    "correct_jobs_s_gb": f'{num(row.get("correct_jobs_per_second_per_gb")):.6f}',
                    "candidate_fit_jobs_s_gb": f'{num(row.get("candidate_fit_jobs_per_second_per_gb")):.6f}',
                    "quality_per_active_b": f'{num(row.get("quality_per_active_b")):.6f}',
                    "schema": f'{num(row.get("schema_valid_rate")):.6f}',
                    "entity": f'{num(row.get("entity_accuracy")):.6f}',
                    "contract": f'{num(row.get("contract_score")):.6f}',
                    "abstain": f'{num(row.get("abstention_score")):.6f}',
                    "dirty": f'{num(row.get("dirty_data_score")):.6f}',
                    "row_watch": f'{num(row.get("row_watch_score")):.6f}',
                    "actions": f'{num(row.get("typed_action_score")):.6f}',
                    "confidence": f'{num(row.get("confidence_score")):.6f}' if row.get("confidence_score") not in (None, "") else "",
                    "diag_confidence": f'{num(row.get("diagnostic_confidence_accuracy")):.6f}' if row.get("diagnostic_confidence_accuracy") not in (None, "") else "",
                    "semantic": f'{num(row.get("semantic_materialization_score")):.6f}',
                    "p95_ms": f'{num(row.get("p95_generate_ms")):.3f}',
                    "tok_s": f'{num(row.get("mean_tokens_per_second")):.6f}',
                    "rss_gb": f'{num(row.get("resident_gb")):.6f}',
                    "artifact_gb": f'{num(row.get("artifact_gb")):.6f}',
                }
            )


def score_reason(row):
    status = row.get("score_status", "")
    if status == "out_of_running":
        return f'out of running: {row.get("unsupported_reason") or first_blocker(row)}'
    if status == "needs_current_scoring_run":
        return "missing current scoring metrics"
    if num(row.get("trusted_fit_score")) == 0:
        if num(row.get("quality_score")) == 0:
            return "ran but created no trusted Otlet quality"
        if num(row.get("resource_fit")) == 0:
            return "trusted work scored but resource fit is zero"
    return "trusted_gate * resource_fit"


def score_audit_rows(rows):
    out = []
    for rank, row in enumerate(ranked(rows), start=1):
        scored = row.get("score_status") == "scored"
        out.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "score_status": row.get("score_status", ""),
                "production_gate": gate_status(row),
                "readiness": readiness(row),
                "overall_score": score_label(row.get("trusted_fit_score")) if scored else "",
                "production_score": f"{production_score(row):.6f}" if scored else "",
                "trusted_gate": f'{num(row.get("quality_score")):.6f}' if scored else "",
                "resource_fit": f'{num(row.get("resource_fit")):.6f}' if scored else "",
                "score_reason": score_reason(row),
                "first_blocker": first_blocker(row),
                "schema": f'{num(row.get("schema_valid_rate")):.6f}',
                "contract": f'{num(row.get("contract_score")):.6f}',
                "entity": f'{num(row.get("entity_accuracy")):.6f}',
                "confidence": f'{num(row.get("confidence_score")):.6f}' if row.get("confidence_score") not in (None, "") else "",
                "row_watch": f'{num(row.get("row_watch_score")):.6f}',
                "semantic": f'{num(row.get("semantic_materialization_score")):.6f}',
                "false_merge": f'{num(row.get("abstention_false_merge_rate")):.6f}',
                "hallucinated_action": f'{num(row.get("hallucinated_trusted_action_rate")):.6f}',
                "stale_leaks": f'{num(row.get("stale_leak_count")):.0f}',
                "source_mutated": "1" if truthy(row.get("source_table_mutated")) else "0",
                "p95_ms": f'{num(row.get("p95_generate_ms")):.3f}',
                "rss_gb": f'{num(row.get("resident_gb")):.6f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.6f}',
            }
        )
    return out


def write_score_audit(path, rows):
    fields = [
        "rank",
        "model",
        "score_status",
        "production_gate",
        "readiness",
        "overall_score",
        "production_score",
        "trusted_gate",
        "resource_fit",
        "score_reason",
        "first_blocker",
        "schema",
        "contract",
        "entity",
        "confidence",
        "row_watch",
        "semantic",
        "false_merge",
        "hallucinated_action",
        "stale_leaks",
        "source_mutated",
        "p95_ms",
        "rss_gb",
        "artifact_gb",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(score_audit_rows(rows))


def write_index_readme(run_dir, context):
    expected = Path(__file__).resolve().parent / "report" / "latest"
    if run_dir.resolve() != expected:
        return

    readme = expected.parents[1] / "README.md"
    scored = ranked(context["scored_summaries"])
    summary_rows = context["summary_rows"]
    workload_rows = context["workload_rows"]
    readiness_rows = context["readiness_rows"]
    failure_mode_rows = context["failure_mode_rows"]
    out_of_running_rows = context.get("out_of_running_rows", [])
    confidence = context["confidence"]
    confidence_next = context["confidence_next"]
    cases_per_model_run = context["cases_per_model_run"]
    direct_gate_skip_count = context.get("direct_gate_skip_count", 0)
    min_direct_schema_rate = context.get("min_direct_schema_rate")
    model_count = len(context["summaries"])
    stable_models = [row for row in scored if num(row.get("repeat_count")) >= 3]
    single_run_count = sum(1 for row in scored if num(row.get("repeat_count")) == 1)
    single_run_label = "model is" if single_run_count == 1 else "models are"
    direct_gate_label = "model" if direct_gate_skip_count == 1 else "models"
    source_run_ids = context["meta"].get("source_run_ids", "")
    run_id = context["meta"].get("run_id") or source_run_ids or ""
    merged_report = "," in source_run_ids
    latest_kind = (
        "this is a merged current scored report"
        if scored and merged_report
        else
        "this is a current scored run"
        if scored
        else "this is now treated as a legacy diagnostic run because it predates required confidence-target scoring"
    )
    score_rows = []
    for rank, row in enumerate(scored, start=1):
        score_rows.append(
            {
                "rank": rank,
                "model": row.get("model_key", ""),
                "overall_score": score_label(row.get("trusted_fit_score")),
                "trusted_gate": f'{num(row.get("quality_score")):.3f}',
                "diagnostic_fit": score_label(row.get("diagnostic_fit_score")),
                "resource_fit": f'{num(row.get("resource_fit")):.3f}',
                "first_blocker": first_blocker(row),
            }
        )

    lines = [
        "# Otlet Benchmarks",
        "",
        "## Overall Score",
        "",
        "Read this ranking first. `overall_score` is `candidate_fit`: trusted Otlet work times resource fit. A zero means the model ran but produced no trusted state",
        "",
        table(["rank", "model", "overall_score", "trusted_gate", "diagnostic_fit", "resource_fit", "first_blocker"], score_rows)
        if score_rows
        else table(
            ["status", "value"],
            [
                {"status": "current scored models", "value": 0},
                {"status": "blocker", "value": "latest broad run predates confidence-target scoring"},
                {"status": "next proof", "value": "rerun selected models with the current 112-case fixture"},
            ],
        ),
        "",
        "## Latest Result",
        "",
        f"Run `{run_id}`: {latest_kind}. It covers {model_count} selected model rows through the benchmark harness. The runner writes generated report artifacts under ignored `benchmarks/report/latest`",
        "",
        f"Benchmark confidence: `{confidence}`. Next proof: {confidence_next}",
        "",
        (
            f"`{stable_models[0].get('model_key')}` has same-run repeat proof with {num(stable_models[0].get('repeat_count')):.0f} runs; repeated models rank by their worst candidate-fit repeat. The other {single_run_count} scored {single_run_label} single-run broad comparison rows"
            if stable_models
            else "All scored models are currently single-run rows; rerun key candidates with `OTLET_BENCH_RUNS=3` before treating stability as proven"
        ),
        "",
        "A model that completes a current-format run gets an overall score. The harness marks load failures, timeouts, manifest blocks, and missing summaries as out of running instead of assigning a fake zero",
        "",
        "The TSVs store `overall_score` as `candidate_fit`: trusted Otlet work multiplied by resource fit for artifact size, resident RSS, p95 latency, and active params. Fast invalid output gets an overall score of zero because it creates no trusted Otlet state. `production_score` stays zero until a model passes every production gate",
        "",
        f"Current coverage is {cases_per_model_run:.1f} direct gold cases per model run. The current fixture target is 112 deterministic pair cases per model plus row-watch and semantic checks",
        "",
        f"The runner skipped semantic and row-watch phases for {direct_gate_skip_count} scored {direct_gate_label} because direct schema-valid rate was below {min_direct_schema_rate:.2f}"
        if direct_gate_skip_count and min_direct_schema_rate is not None
        else "",
        "",
        "## Workload Picks",
        "",
        table(["workload", "model", "metric", "gate", "caveat"], workload_rows),
        "",
        "## Production Readiness",
        "",
        "The default-model gate keeps failed models out of production rank. Failed models keep diagnostic evidence, but their production score is zero",
        "",
        table(["rank", "model", "readiness", "production_score", "candidate_fit", "gate", "first_blocker"], readiness_rows),
        "",
        "## First Failure Modes",
        "",
        table(["model", "top_failure", "count", "passed_cases"], failure_mode_rows[:5])
        if failure_mode_rows
        else "The report has no scored case failures",
        "",
        "## Overall Score Ranking",
        "",
        table(
            ["rank", "model", "runs", "readiness", "overall_score", "trusted_gate", "schema", "p95_ms", "rss_gb", "artifact_gb"],
            [
                {
                    "rank": row["rank"],
                    "model": row["model"],
                    "runs": row["repeat_count"],
                    "readiness": row["readiness"],
                    "overall_score": row["candidate_fit"],
                    "trusted_gate": row["trusted_gate"],
                    "schema": row["schema"],
                    "p95_ms": row["p95_ms"],
                    "rss_gb": row["rss_gb"],
                    "artifact_gb": row["artifact_gb"],
                }
                for row in summary_rows
            ],
        )
        if summary_rows
        else "This legacy run has no current overall-score rows. Use the gate and track breakdown in the full report to pick rerun targets",
        "",
        "## Out Of Running",
        "",
        table(["model", "status", "reason", "tier", "artifact_gb"], out_of_running_rows)
        if out_of_running_rows
        else "No selected models were out of running",
        "",
        "## Drilldown Charts",
        "",
        "The headline chart ranks overall score. The charts below explain whether that score is quality-limited, memory-limited, latency-limited, or parameter-limited. Treat latency and throughput as useful only after checking `trusted_gate`; instant invalid output is not useful work",
        "",
        "Running the benchmark writes local SVG charts under ignored `benchmarks/report/latest`: overall score, resident memory versus score, active parameters versus score, p95 latency, and trusted throughput per resident GB",
        "",
        "## Report Files",
        "",
        "- Full report: `report/latest/otlet-model-benchmark.md`",
        "- Overall score chart: `report/latest/overall.svg`",
        "- Score audit TSV: `report/latest/score_audit.tsv`",
        "- Gate scorecard TSV: `report/latest/scorecard.tsv`",
        "- Model summary TSV: `report/latest/model_summary.tsv`",
        "- Case result TSV: `report/latest/case_results.tsv`",
        "- Cleanup proof: `report/latest/cleanup.tsv`",
        "- Planner proof: `report/latest/explain.txt`",
        "",
        "## Benchmark Scope",
        "",
        "The suite measures Otlet fit, not background model knowledge. Each case puts the evidence in database rows and asks the model to behave like a Postgres-resident worker over compact row JSON",
        "",
        "The score covers:",
        "",
        "- schema-valid trusted output",
        "- explicit production gates before any default-model claim",
        "- entity-resolution decisions across duplicates, hard negatives, sparse rows, dirty rows, and abstention cases",
        "- exact confidence targets, so overconfident or underconfident outputs do not get silent credit",
        "- typed actions with no source-table writes",
        "- row-watch classification",
        "- semantic materialization and stale-result safety",
        "- receipt, trace, source-hash, FDW, and CustomScan visibility",
        "- p95 latency, tokens/sec, resident RSS, artifact size, active params, and fit per resident GB",
        "",
        "## Rerun",
        "",
        "Start from the normal Otlet proof path:",
        "",
        "```sh",
        "./scripts/otlet-setup.sh",
        "./scripts/otlet-demo.sh",
        "```",
        "",
        "Run one model and write a local report:",
        "",
        "```sh",
        "OTLET_BENCH_LIMIT_MODELS=ministral3_3b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh",
        "```",
        "",
        "Run a subset and write a local report:",
        "",
        "```sh",
        "OTLET_BENCH_LIMIT_MODELS=ministral3_3b,glm_edge_4b,smollm3_3b OTLET_BENCH_RUNS=1 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh",
        "```",
        "",
        "Run the small-model set around the 2 GB artifact target and refresh the report:",
        "",
        "```sh",
        "models=\"$(awk -F '\\t' 'NR > 1 && $6 == \"core\" && $10 <= 2.0 {print $1}' benchmarks/models.tsv | paste -sd, -)\"",
        "OTLET_BENCH_LIMIT_MODELS=\"$models\" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=2.0 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh",
        "```",
        "",
        "The benchmark default timeout is two hours per task phase because the current fixture loads 112 row-pair cases per model and larger local models can cross one hour before semantic refresh starts",
        "",
        "Run every core model in the manifest and write a local report:",
        "",
        "```sh",
        "models=\"$(awk -F '\\t' 'NR > 1 && $6 == \"core\" {print $1}' benchmarks/models.tsv | paste -sd, -)\"",
        "OTLET_BENCH_LIMIT_MODELS=\"$models\" OTLET_BENCH_RUNS=1 OTLET_BENCH_MAX_ARTIFACT_GB=6 OTLET_BENCH_PUBLISH_REPORT=1 ./benchmarks/run.sh",
        "```",
        "",
        "Run the Qwen smoke without writing a local report:",
        "",
        "```sh",
        "OTLET_BENCH_LIMIT_MODELS=linked_qwen_0_6b,linked_qwen_1_7b OTLET_BENCH_RUNS=1 ./benchmarks/run.sh",
        "```",
        "",
        "Refresh model manifest metadata:",
        "",
        "```sh",
        "python3 benchmarks/refresh-metadata.py",
        "```",
        "",
        "`OTLET_BENCH_PUBLISH_REPORT=1` updates local generated Markdown, SVG, TSV, cleanup, and EXPLAIN files under ignored `benchmarks/report/latest/`",
        "",
        "Raw runs stay under ignored `benchmarks/runs/<timestamp>-<run_id>/`. Keep a raw run while debugging; commit benchmark code and README updates, not generated run artifacts",
        "",
        "Raw run artifacts update after each completed model. `report/latest` updates only when the runner reaches normal completion with `OTLET_BENCH_PUBLISH_REPORT=1`",
        "",
    ]
    readme.write_text("\n".join(lines), encoding="utf-8")


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
            row["candidate_fit_jobs_per_second_per_gb"] = (
                num(row.get("otlet_fit_score")) * num(row.get("jobs_per_second")) / resident_gb
            )
        else:
            row["candidate_fit_jobs_per_second_per_gb"] = ""
        if active_params_b > 0:
            row["quality_per_active_b"] = num(row.get("quality_score")) / active_params_b
        else:
            row["quality_per_active_b"] = ""

    runnable_summaries = [row for row in summaries if row.get("run_status") == "complete"]
    scored_summaries = [row for row in runnable_summaries if row.get("score_status") == "scored"]
    out_of_running = [row for row in summaries if row.get("run_status") != "complete"]
    pareto = run_dir / "pareto.svg"
    params = run_dir / "params.svg"
    latency = run_dir / "latency.svg"
    efficiency = run_dir / "efficiency.svg"
    overall = run_dir / "overall.svg"
    scorecard = run_dir / "scorecard.tsv"
    score_audit = run_dir / "score_audit.tsv"
    write_overall(overall, scored_summaries)
    write_pareto(pareto, runnable_summaries)
    write_param_fit(params, runnable_summaries)
    write_bar(latency, runnable_summaries, "p95_generate_ms", "p95 generation latency ms, higher is slower")
    write_bar(efficiency, runnable_summaries, "correct_jobs_per_second_per_gb", "correct jobs/sec per resident GB")
    write_scorecard(scorecard, summaries)
    write_score_audit(score_audit, summaries)
    ranked_summaries = sorted(
        scored_summaries,
        key=lambda row: (num(row.get("trusted_fit_score")), num(row.get("quality_score"))),
        reverse=True,
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
                "candidate_fit": score_label(row.get("trusted_fit_score")),
                "diagnostic_fit": score_label(row.get("diagnostic_fit_score")),
                "fit_min": score_label(row.get("trusted_fit_min")),
                "fit_max": score_label(row.get("trusted_fit_max")),
                "fit_sd": score_label(row.get("trusted_fit_sd")),
                "trusted_gate": f'{num(row.get("quality_score")):.3f}',
                "schema": f'{num(row.get("schema_valid_rate")):.3f}',
                "diag_decision": f'{num(row.get("diagnostic_entity_accuracy")):.3f}',
                "trusted_decision": f'{num(row.get("entity_accuracy")):.3f}',
                "confidence": f'{num(row.get("confidence_score")):.3f}' if row.get("confidence_score") not in (None, "") else "",
                "diag_confidence": f'{num(row.get("diagnostic_confidence_accuracy")):.3f}' if row.get("diagnostic_confidence_accuracy") not in (None, "") else "",
                "row_watch": f'{num(row.get("row_watch_score")):.3f}',
                "params_b": f'{num(row.get("declared_params_b")):.2f}' if row.get("declared_params_b") else "",
                "active_b": f'{num(row.get("active_params_b")):.2f}' if row.get("active_params_b") else "",
                "p95_ms": f'{num(row.get("p95_generate_ms")):.0f}',
                "tok_s": f'{num(row.get("mean_tokens_per_second")):.2f}',
                "rss_gb": f'{num(row.get("resident_gb")):.3f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.3f}',
                "correct_jobs_s_gb": f'{num(row.get("correct_jobs_per_second_per_gb")):.3f}',
                "candidate_fit_jobs_s_gb": f'{num(row.get("candidate_fit_jobs_per_second_per_gb")):.3f}',
                "quality_per_active_b": f'{num(row.get("quality_per_active_b")):.3f}',
                "resource_fit": f'{num(row.get("resource_fit")):.3f}',
            }
        )

    model_rows = []
    seen_models = set()
    for row in models:
        base = row.get("base_model_key") or row.get("model_key", "")
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
                "row_watch": f'{num(row.get("row_watch_score")):.3f}',
                "actions": f'{num(row.get("typed_action_score")):.3f}',
                "confidence": f'{num(row.get("confidence_score")):.3f}' if row.get("confidence_score") not in (None, "") else "",
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
        for case in cases:
            if case.get("base_model_key") != model_key:
                continue
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
                "candidate_fit": score_label(row.get("trusted_fit_score")),
                "first_blocker": first_blocker(row),
                "gate": gate_status(row),
            }
        )

    audit_rows = [
        {
            "rank": row["rank"],
            "model": row["model"],
            "score_status": row["score_status"],
            "production_gate": row["production_gate"],
            "overall_score": row["overall_score"],
            "trusted_gate": score_label(row["trusted_gate"]),
            "resource_fit": score_label(row["resource_fit"]),
            "score_reason": row["score_reason"],
            "first_blocker": row["first_blocker"],
        }
        for row in score_audit_rows(summaries)
    ]

    failure_rows = []
    seen_failure_models = set()
    for summary in diagnostic_ranked_summaries:
        model_key = summary.get("model_key", "")
        for row in cases:
            failed = (
                row.get("schema_valid") != "t"
                or row.get("match_correct") != "t"
                or row.get("confidence_correct") != "t"
                or row.get("action_correct") != "t"
            )
            if not failed or row.get("base_model_key") != model_key or model_key in seen_failure_models:
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
    best_trusted = max(summaries, key=lambda row: num(row.get("quality_score")), default={})
    best_row_watch = max(summaries, key=lambda row: num(row.get("row_watch_score")), default={})
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
                "candidate_fit": score_label(row.get("trusted_fit_score")),
                "trusted_gate": f'{num(row.get("quality_score")):.3f}',
                "resource_fit": f'{num(row.get("resource_fit")):.3f}',
                "schema": f'{num(row.get("schema_valid_rate")):.3f}',
                "p95_ms": f'{num(row.get("p95_generate_ms")):.0f}',
                "rss_gb": f'{num(row.get("resident_gb")):.3f}',
                "artifact_gb": f'{num(row.get("artifact_gb")):.3f}',
            }
        )
    best_hard_case = max(
        summaries,
        key=lambda row: (
            num(row.get("entity_resolution_score")),
            num(row.get("contract_score")),
            num(row.get("quality_score")),
            num(row.get("trusted_fit_score")),
        ),
        default={},
    )
    qwen06 = next((row for row in diagnostic_ranked_summaries if row.get("model_key") == "linked_qwen_0_6b"), {})
    qwen17 = next((row for row in diagnostic_ranked_summaries if row.get("model_key") == "linked_qwen_1_7b"), {})
    rank_by_key = {row.get("model_key"): i for i, row in enumerate(diagnostic_ranked_summaries, start=1)}
    run_ids = sorted({row.get("run_id", "") for row in summaries if row.get("run_id")})
    repeat_counts = [num(row.get("repeat_count")) for row in summaries]
    min_repeats = min(repeat_counts) if repeat_counts else 0
    max_repeats = max(repeat_counts) if repeat_counts else 0
    cases_per_model_run = (len(cases) / len(raw_summaries)) if raw_summaries else 0
    confidence, confidence_reason, confidence_next = benchmark_confidence(
        summaries, raw_summaries, len(cases), run_ids
    )
    min_direct_schema_rate = num(meta.get("min_direct_schema_rate"), None)
    if len(run_ids) > 1:
        timing_limit = "- Merged evidence compares quality gates; timing and RSS compare best after one same-run sweep"
    elif min_repeats >= 3:
        timing_limit = f"- Same-run evidence has repeat counts {min_repeats:.0f}-{max_repeats:.0f}"
    else:
        timing_limit = "- One same-run sweep proves direction; use OTLET_BENCH_RUNS=3 before treating stability as proven"
    if cases_per_model_run >= 100:
        coverage_limit = f"- Direct gold coverage is frontier-sized at {cases_per_model_run:.1f} cases per model run"
    else:
        coverage_limit = (
            f"- Direct gold coverage remains smoke-sized at {cases_per_model_run:.1f} cases per model run; "
            "the frontier target is 100+ cases per model"
        )

    findings = []
    findings.append(f"- Benchmark confidence: `{confidence}`")
    repeated_summaries = [row for row in ranked_summaries if num(row.get("repeat_count")) >= 3]
    if repeated_summaries:
        repeated = repeated_summaries[0]
        findings.append(
            f'- `{repeated.get("model_key")}` has same-run repeat proof with '
            f'{num(repeated.get("repeat_count")):.0f} runs; ranking uses its worst candidate-fit repeat '
            f'({score_label(repeated.get("trusted_fit_score"))})'
        )
    if runnable_summaries and not scored_summaries:
        findings.append("- This run predates required confidence-target scoring and has no current overall scores")
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
            f'- `{best_trusted.get("model_key")}` has the best `trusted_gate` '
            f'({num(best_trusted.get("quality_score")):.3f})'
        )
    if best_hard_case:
        findings.append(
            f'- `{best_hard_case.get("model_key")}` has the best hard entity-resolution track score '
            f'({num(best_hard_case.get("entity_resolution_score")):.3f})'
        )
    if best_row_watch:
        findings.append(
            f'- `{best_row_watch.get("model_key")}` has the best row-watch score '
            f'({num(best_row_watch.get("row_watch_score")):.3f})'
        )
    if best_small:
        findings.append(
            f'- `{best_small.get("model_key")}` is the best <=2.0 GB artifact candidate '
            f'({num(best_small.get("artifact_gb")):.3f} GB artifact, {score_label(best_small.get("trusted_fit_score"))} candidate fit)'
        )
    if qwen06 and qwen17:
        findings.append(
            f'- The Qwen demo baselines rank {rank_by_key.get("linked_qwen_1_7b")} '
            f'and {rank_by_key.get("linked_qwen_0_6b")} on this harder suite'
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
            score_caveat,
        ),
        winner_row(
            "row watching",
            best_row_watch,
            f'{num(best_row_watch.get("row_watch_score")):.3f}',
            score_caveat if best_row_watch else "not proven; direct schema gate skipped row-watch phase",
        ),
        winner_row(
            "<=2.0 GB artifact",
            best_small,
            score_label(best_small.get("trusted_fit_score")),
            "small-fit pick, still gate-aware" if best_small else "no current candidate-fit row",
        ),
        winner_row(
            "correct jobs/sec/GB",
            efficiency_row,
            f'{num(efficiency_row.get("correct_jobs_per_second_per_gb")):.3f}',
            "compare timing after one same-run sweep" if efficiency_row else "no current candidate-fit row",
        ),
    ]

    lines = [
        "# Otlet Model-Fit Benchmark Report",
        "",
        "This benchmark scores local GGUF models as Otlet workers inside Postgres. Each case provides the evidence in source rows. The score measures strict JSON, trusted actions, row watching, receipts, semantic materialization, stale safety, EXPLAIN visibility, latency, memory, and artifact size",
        "",
        "`production_score` is zero until a model passes every production gate. `candidate_fit` is the research score for models that still fail gates: schema-valid accepted outputs, exact confidence targets, trusted actions, semantic state, and stale safety, multiplied by resource fit for artifact GB, resident RSS, p95 latency, and active params. `diagnostic_fit` is separate and can read compact fields from rejected attempts. Invalid JSON never becomes trusted Otlet state or headline score",
        "",
        "## Findings",
        "",
        *findings,
        "",
        "A runnable model gets an overall score. The report keeps load failures, manifest blocks, and run-limit skips out of the ranking instead of assigning fake zeros",
        "",
        "Verdicts are gate-aware. A model can be useful for a workload and still fail the production gate. Treat `too_unreliable` as a hard warning, not a near miss",
        "",
        "## Current Limits",
        "",
        "- No model passed the production gate, so the report does not recommend a default model",
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
                {"key": "model_rows", "value": len(summaries)},
                {"key": "raw_model_run_rows", "value": len(raw_summaries)},
                {"key": "case_rows", "value": len(cases)},
                {
                    "key": "direct_gold_cases_per_model_run",
                    "value": f"{cases_per_model_run:.1f}",
                },
                {"key": "repeat_count_range", "value": f"{min_repeats:.0f}-{max_repeats:.0f}"},
                {"key": "source_run_ids", "value": ", ".join(run_ids)},
                {
                    "key": "same_run_comparison",
                    "value": "yes" if len(run_ids) <= 1 else "no; latency/RSS compare best after one full rerun",
                },
                {"key": "score_basis", "value": "trusted accepted output first; repeated runs rank by worst candidate fit"},
            ],
        ),
        "",
        "## Score Contract",
        "",
        "A model must pass the production gate before it can be called a default Otlet model. The gate requires no worker crash, no source-table mutation, no stale leak, schema >= 0.95, contract >= 0.95, exact confidence target accuracy >= 0.95, entity >= 0.80, zero false merges, hallucinated trusted actions <= 0.01, and semantic materialization >= 0.95",
        "",
        "`candidate_fit = trusted_gate * resource_fit` for a single run. `production_score = candidate_fit` only when the production gate passes; otherwise it is 0.000. `resource_fit` weights artifact GB 40%, resident RSS 30%, p95 latency 20%, and active params 10%. The targets are <=2.0 GB artifact, <=2.5 GB resident RSS, <=20s p95 generation, and <=3B active params. A model at or above a target gets no credit for that resource component. Repeated models rank by their worst candidate-fit repeat; the scorecard shows mean, min, max, and standard deviation. `diagnostic_fit` uses the same resource fit but starts from diagnostic fields, so use it for research instead of trusted-state ranking",
        "",
        "## Score Audit",
        "",
        "This table explains the headline score without requiring a reader to reverse-engineer the TSVs. A scored zero means the model ran and failed to create trusted Otlet work. Out-of-running means the model did not produce a comparable result",
        "",
        table(["rank", "model", "score_status", "production_gate", "overall_score", "trusted_gate", "resource_fit", "score_reason", "first_blocker"], audit_rows),
        "",
        "## Overall Score Chart",
        "",
        f"![Overall Otlet score]({overall.name})",
        "",
        "## Workload Winners",
        "",
        table(["workload", "model", "metric", "gate", "caveat"], workload_rows),
        "",
        "## Production Readiness",
        "",
        "The default-model gate sets `production_score` to zero for failed models, even when `candidate_fit` is high",
        "",
        table(["rank", "model", "readiness", "production_score", "candidate_fit", "gate", "first_blocker"], readiness_rows),
        "",
        "## <=2.0 GB Artifact Candidates",
        "",
        "The Otlet-small track includes models whose measured artifact in the run is at or below 2.0 GB",
        "",
        table(["rank", "model", "candidate_fit", "trusted_gate", "resource_fit", "schema", "p95_ms", "rss_gb", "artifact_gb"], small_candidate_rows)
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
        table(["model", "runs", "verdict", "gate", "failed_gate", "schema", "contract", "confidence", "entity", "abstain", "actions", "semantic"], gate_rows),
        "",
        "## Out Of Running",
        "",
        table(["model", "status", "reason", "tier", "artifact_gb"], out_of_running_rows)
        if out_of_running_rows
        else "No selected models were out of running",
        "",
        "## Candidate Fit Ranking",
        "",
        "The report ranks models by `candidate_fit`, not default readiness. Use this table to choose what to improve or rerun. The production readiness table above decides whether a model is safe to call a default Otlet model",
        "",
        table(
            [
                "rank",
                "model",
                "repeat_count",
                "verdict",
                "readiness",
                "production_score",
                "candidate_fit",
                "diagnostic_fit",
                "fit_min",
                "fit_max",
                "fit_sd",
                "trusted_gate",
                "schema",
                "diag_decision",
                "trusted_decision",
                "confidence",
                "diag_confidence",
                "row_watch",
                "params_b",
                "active_b",
                "p95_ms",
                "tok_s",
                "rss_gb",
                "artifact_gb",
                "correct_jobs_s_gb",
                "candidate_fit_jobs_s_gb",
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
        table(["model", "contract", "entity", "abstain", "dirty", "row_watch", "actions", "confidence", "diag_actions", "diag_confidence", "semantic"], track_rows),
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
        f"- Overall score: `{overall.name}`",
        f"- Pareto: `{pareto.name}`",
        f"- Params: `{params.name}`",
        f"- Latency: `{latency.name}`",
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
        table(["key", "value"], [{"key": k, "value": v} for k, v in sorted(meta.items())]),
        "",
        "## Candidate Models",
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
        meta.get("reproduction_command", "OTLET_BENCH_LIMIT_MODELS=linked_qwen_0_6b,linked_qwen_1_7b OTLET_BENCH_RUNS=1 ./benchmarks/run.sh"),
        "```",
        "",
    ]
    report.write_text("\n".join(lines), encoding="utf-8")
    write_index_readme(
        run_dir,
        {
            "scored_summaries": scored_summaries,
            "summary_rows": summary_rows,
            "workload_rows": workload_rows,
            "readiness_rows": readiness_rows,
            "failure_mode_rows": failure_mode_rows,
            "out_of_running_rows": out_of_running_rows,
            "confidence": confidence,
            "confidence_next": confidence_next,
            "cases_per_model_run": cases_per_model_run,
            "summaries": summaries,
            "meta": meta,
            "direct_gate_skip_count": len(direct_gate_skips),
            "min_direct_schema_rate": min_direct_schema_rate,
        },
    )
    print(report)


if __name__ == "__main__":
    main()
