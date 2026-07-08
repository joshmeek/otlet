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


def numeric_column(values):
    seen = False
    for value in values:
        if value == "":
            continue
        try:
            float(value)
        except ValueError:
            return False
        seen = True
    return seen


def table(headers, rows):
    rendered = [[cell(row.get(header, "")) for header in headers] for row in rows]
    separator = [
        "---:" if numeric_column(row[i] for row in rendered) else "---"
        for i, _ in enumerate(headers)
    ]
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(separator) + " |"]
    for row in rendered:
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)
