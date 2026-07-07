from report_io import clean_lines, read_tsv, table
from report_scoring import (
    aggregate_summaries,
    first_blocker,
    model_base_map,
    num,
    score_label,
    with_base_key,
)


def case_rate(cases, model_key, predicate):
    rows = [row for row in cases if row.get("model_key") == model_key]
    if not rows:
        return 0.0
    return sum(1 for row in rows if predicate(row)) / len(rows)


def compare_runs(baseline_dir, candidate_dir):
    baseline_models = read_tsv(baseline_dir / "models.tsv")
    candidate_models = read_tsv(candidate_dir / "models.tsv")
    baseline_by_base = model_base_map(baseline_models)
    candidate_by_base = model_base_map(candidate_models)
    baseline_cases = read_tsv(baseline_dir / "case_results.tsv")
    candidate_cases = read_tsv(candidate_dir / "case_results.tsv")
    baseline_summaries = aggregate_summaries(read_tsv(baseline_dir / "model_summary.tsv"), baseline_models)
    candidate_summaries = aggregate_summaries(read_tsv(candidate_dir / "model_summary.tsv"), candidate_models)

    for row in baseline_cases:
        with_base_key(row, baseline_by_base)
    for row in candidate_cases:
        with_base_key(row, candidate_by_base)

    baseline_by_model = {row.get("model_key", ""): row for row in baseline_summaries}
    candidate_by_model = {row.get("model_key", ""): row for row in candidate_summaries}
    model_keys = sorted(set(baseline_by_model) | set(candidate_by_model))
    rows = []
    for model_key in model_keys:
        before = baseline_by_model.get(model_key, {})
        after = candidate_by_model.get(model_key, {})
        before_cases = [row for row in baseline_cases if row.get("model_key") == model_key]
        after_cases = [row for row in candidate_cases if row.get("model_key") == model_key]
        rows.append(
            {
                "model": model_key,
                "cases_before": len(before_cases),
                "cases_after": len(after_cases),
                "overall_before": score_label(before.get("overall_fit")),
                "overall_after": score_label(after.get("overall_fit")),
                "overall_delta": score_label(num(after.get("overall_fit")) - num(before.get("overall_fit"))),
                "schema_delta": score_label(num(after.get("schema_valid_rate")) - num(before.get("schema_valid_rate"))),
                "parse_fail_delta": score_label(
                    case_rate(candidate_cases, model_key, lambda row: "invalid model JSON" in row.get("error", ""))
                    - case_rate(baseline_cases, model_key, lambda row: "invalid model JSON" in row.get("error", ""))
                ),
                "false_merge_delta": score_label(num(after.get("abstention_false_merge_rate")) - num(before.get("abstention_false_merge_rate"))),
                "confidence_delta": score_label(num(after.get("confidence_score")) - num(before.get("confidence_score"))),
                "halluc_action_delta": score_label(
                    num(after.get("hallucinated_trusted_action_rate")) - num(before.get("hallucinated_trusted_action_rate"))
                ),
                "trusted_action_delta": score_label(num(after.get("typed_action_score")) - num(before.get("typed_action_score"))),
                "semantic_delta": score_label(
                    num(after.get("semantic_materialization_score")) - num(before.get("semantic_materialization_score"))
                ),
                "row_watch_delta": score_label(num(after.get("row_watch_score")) - num(before.get("row_watch_score"))),
                "p95_ms_delta": score_label(num(after.get("p95_generate_ms")) - num(before.get("p95_generate_ms"))),
                "rss_gb_delta": score_label(num(after.get("resident_gb")) - num(before.get("resident_gb"))),
                "blocker_before": first_blocker(before),
                "blocker_after": first_blocker(after),
            }
        )

    out = candidate_dir / "comparison.md"
    lines = [
        "# Otlet Benchmark Comparison",
        "",
        f"- Baseline: `{baseline_dir}`",
        f"- Candidate: `{candidate_dir}`",
        "- Basis: exported benchmark TSVs; no case rows are dropped by the comparison",
        "- Good deltas are positive for schema, confidence, trusted action, semantic, row-watch, and overall fit",
        "- Good deltas are negative for parse failures, false merges, hallucinated actions, p95 latency, and resident RSS",
        "",
        table(
            [
                "model",
                "cases_before",
                "cases_after",
                "overall_before",
                "overall_after",
                "overall_delta",
                "schema_delta",
                "parse_fail_delta",
                "false_merge_delta",
                "confidence_delta",
                "halluc_action_delta",
                "trusted_action_delta",
                "semantic_delta",
                "row_watch_delta",
                "p95_ms_delta",
                "rss_gb_delta",
                "blocker_before",
                "blocker_after",
            ],
            rows,
        ),
        "",
    ]
    out.write_text("\n".join(clean_lines(lines)), encoding="utf-8")
    print(out)
