import csv


def read_tsv(path):
    if not path.exists() or path.stat().st_size == 0:
        return []
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    for row in rows:
        if "single_run_verdict" not in row and "verdict" in row:
            row["single_run_verdict"] = row["verdict"]
        if "verdict" not in row and "single_run_verdict" in row:
            row["verdict"] = row["single_run_verdict"]
    return rows


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


def plural(count, singular, plural_form=None):
    return singular if count == 1 else (plural_form or f"{singular}s")


def compact_count(value):
    value = float(value)
    return str(int(value)) if value.is_integer() else f"{value:.1f}"


def clean_lines(lines):
    cleaned = []
    previous_blank = False
    for line in lines:
        blank = line == ""
        if blank and previous_blank:
            continue
        cleaned.append(line)
        previous_blank = blank
    return cleaned


def cell(value):
    return " ".join(("" if value is None else str(value)).replace("|", "\\|").split())


def table(headers, rows):
    numeric = {
        "rank",
        "runs",
        "repeat_count",
        "otlet_fit",
        "overall_fit",
        "production_score",
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
        "overall_fit_jobs_s_gb",
        "quality_per_active_b",
        "contract",
        "entity",
        "abstain",
        "dirty",
        "triage",
        "triage_abstain",
        "numeric",
        "extraction",
        "policy",
        "user_suite",
        "actions",
        "diag_actions",
        "diag_triage",
        "diag_numeric",
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
        "hallucinated_action",
        "stale_leaks",
        "source_mutated",
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
    }
    separator = [("---:" if header in numeric else "---") for header in headers]
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(separator) + " |"]
    for row in rows:
        out.append("| " + " | ".join(cell(row.get(h, "")) for h in headers) + " |")
    return "\n".join(out)
