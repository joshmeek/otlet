import csv
import html
import math

from report_io import num
from report_scoring import (
    display_verdict,
    gate_failures,
    gate_status,
    metric_present,
    production_score,
    ranked,
    readiness,
    score_audit_rows,
)


def svg_shell(width, height, body):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<rect x="0" y="0" width="{width}" height="{height}" fill="#ffffff"/>
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
    left, right, top = 72, 48, 56
    plot_w, plot_h = width - left - right, 360
    legend_top = top + plot_h + 66
    legend_rows = math.ceil(len(rows) / 2)
    height = legend_top + 34 + legend_rows * 19
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
        f'<text x="{left}" y="{top - 12}">{html.escape(y_label)}</text>',
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
        "Pareto: resident GB vs overall fit",
        "resident GB",
        "overall fit",
    )


def write_bar(path, rows, value_key, title):
    if not rows:
        write_empty_chart(path, title)
        return
    rows = sorted(rows, key=lambda r: num(r.get(value_key)), reverse=True)
    longest = max(text_width(r.get("model_key", "model")) for r in rows)
    width = 1040
    row_h = 44
    height = 110 + row_h * len(rows)
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
        "Active params vs overall fit",
        "active params B",
        "overall fit",
    )


def write_overall(path, rows):
    write_bar(path, rows, "trusted_fit_score", "Overall Otlet fit, higher is better")


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
        "overall_fit",
        "trusted_fit",
        "trusted_fit_mean",
        "trusted_fit_min",
        "trusted_fit_max",
        "trusted_fit_sd",
        "diagnostic_fit",
        "trusted_quality",
        "diagnostic_quality",
        "resource_fit",
        "artifact_fit",
        "resident_fit",
        "latency_fit",
        "active_param_fit",
        "correct_jobs_s_gb",
        "overall_fit_jobs_s_gb",
        "quality_per_active_b",
        "schema",
        "entity",
        "contract",
        "abstain",
        "dirty",
        "triage",
        "triage_abstain",
        "numeric",
        "extraction",
        "policy",
        "user_suite",
        "row_watch",
        "actions",
        "confidence",
        "diag_triage",
        "diag_numeric",
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
                    "overall_fit": score("trusted_fit_score"),
                    "trusted_fit": score("trusted_fit_score"),
                    "trusted_fit_mean": score("trusted_fit_mean"),
                    "trusted_fit_min": score("trusted_fit_min"),
                    "trusted_fit_max": score("trusted_fit_max"),
                    "trusted_fit_sd": score("trusted_fit_sd"),
                    "diagnostic_fit": score("diagnostic_fit_score"),
                    "trusted_quality": f'{num(row.get("quality_score")):.6f}',
                    "diagnostic_quality": f'{num(row.get("diagnostic_quality_score")):.6f}',
                    "resource_fit": f'{num(row.get("resource_fit")):.6f}',
                    "artifact_fit": f'{num(row.get("artifact_fit")):.6f}',
                    "resident_fit": f'{num(row.get("resident_fit")):.6f}',
                    "latency_fit": f'{num(row.get("latency_fit")):.6f}',
                    "active_param_fit": f'{num(row.get("active_param_fit")):.6f}',
                    "correct_jobs_s_gb": f'{num(row.get("correct_jobs_per_second_per_gb")):.6f}',
                    "overall_fit_jobs_s_gb": f'{num(row.get("overall_fit_jobs_per_second_per_gb")):.6f}',
                    "quality_per_active_b": f'{num(row.get("quality_per_active_b")):.6f}',
                    "schema": f'{num(row.get("schema_valid_rate")):.6f}',
                    "entity": f'{num(row.get("entity_accuracy")):.6f}',
                    "contract": f'{num(row.get("contract_score")):.6f}',
                    "abstain": f'{num(row.get("abstention_score")):.6f}',
                    "dirty": f'{num(row.get("dirty_data_score")):.6f}',
                    "triage": f'{num(row.get("triage_score")):.6f}' if metric_present(row, "triage_score") else "",
                    "triage_abstain": f'{num(row.get("triage_abstention_score")):.6f}' if metric_present(row, "triage_abstention_score") else "",
                    "numeric": f'{num(row.get("numeric_evidence_score")):.6f}' if metric_present(row, "numeric_evidence_score") else "",
                    "extraction": f'{num(row.get("extraction_score")):.6f}' if metric_present(row, "extraction_score") else "",
                    "policy": f'{num(row.get("policy_check_score")):.6f}' if metric_present(row, "policy_check_score") else "",
                    "user_suite": f'{num(row.get("user_suite_score")):.6f}' if metric_present(row, "user_suite_score") else "",
                    "row_watch": f'{num(row.get("row_watch_score")):.6f}',
                    "actions": f'{num(row.get("typed_action_score")):.6f}',
                    "confidence": f'{num(row.get("confidence_score")):.6f}' if row.get("confidence_score") not in (None, "") else "",
                    "diag_triage": f'{num(row.get("diagnostic_triage_accuracy")):.6f}' if metric_present(row, "diagnostic_triage_accuracy") else "",
                    "diag_numeric": f'{num(row.get("diagnostic_numeric_accuracy")):.6f}' if metric_present(row, "diagnostic_numeric_accuracy") else "",
                    "diag_confidence": f'{num(row.get("diagnostic_confidence_accuracy")):.6f}' if row.get("diagnostic_confidence_accuracy") not in (None, "") else "",
                    "semantic": f'{num(row.get("semantic_materialization_score")):.6f}',
                    "p95_ms": f'{num(row.get("p95_generate_ms")):.3f}',
                    "tok_s": f'{num(row.get("mean_tokens_per_second")):.6f}',
                    "rss_gb": f'{num(row.get("resident_gb")):.6f}',
                    "artifact_gb": f'{num(row.get("artifact_gb")):.6f}',
                }
            )


def write_score_audit(path, rows):
    fields = [
        "rank",
        "model",
        "role",
        "score_status",
        "production_gate",
        "readiness",
        "overall_fit",
        "production_score",
        "trusted_quality",
        "resource_fit",
        "score_reason",
        "first_blocker",
        "schema",
        "contract",
        "entity",
        "confidence",
        "triage",
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
