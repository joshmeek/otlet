#!/usr/bin/env python3
import csv
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


FIELDS = [
    "model_key",
    "hf_repo",
    "filename",
    "metadata_status",
    "checked_at",
    "hf_last_modified",
    "hf_downloads",
    "hf_likes",
    "hf_license",
    "artifact_bytes_hint",
    "gguf_file_count",
    "split_file_count",
    "gated",
    "error",
]


def curl_json(url):
    proc = subprocess.run(
        ["curl", "-fsSL", "--max-time", "30", url],
        check=False,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"curl exited {proc.returncode}")
    return json.loads(proc.stdout)


def license_from(data):
    card = data.get("cardData")
    if isinstance(card, dict) and card.get("license"):
        return str(card["license"])
    for tag in data.get("tags") or []:
        if isinstance(tag, str) and tag.startswith("license:"):
            return tag.split(":", 1)[1]
    return ""


def split_count(filename, ggufs):
    if "-00001-of-" not in filename:
        return 0
    prefix = filename.split("-00001-of-", 1)[0]
    return sum(1 for name in ggufs if name.startswith(prefix))


def metadata(row, checked_at):
    filename = row["filename"]
    out = {field: "" for field in FIELDS}
    out.update(
        {
            "model_key": row["model_key"],
            "hf_repo": row["hf_repo"],
            "filename": filename,
            "checked_at": checked_at,
        }
    )
    try:
        data = curl_json(f"https://huggingface.co/api/models/{row['hf_repo']}?blobs=true")
        siblings = data.get("siblings") or []
        ggufs = [s.get("rfilename", "") for s in siblings if s.get("rfilename", "").lower().endswith(".gguf")]
        exact = next((s for s in siblings if s.get("rfilename") == filename), None) if filename else None
        out.update(
            {
                "metadata_status": "ok" if exact or not filename else "missing_file",
                "hf_last_modified": data.get("lastModified", ""),
                "hf_downloads": data.get("downloads", ""),
                "hf_likes": data.get("likes", ""),
                "hf_license": license_from(data),
                "artifact_bytes_hint": exact.get("size", "") if exact else "",
                "gguf_file_count": len(ggufs),
                "split_file_count": split_count(filename, ggufs),
                "gated": str(bool(data.get("gated"))).lower(),
            }
        )
    except Exception as exc:
        out["metadata_status"] = "error"
        out["error"] = str(exc).replace("\n", " ")[:240]
    return out


def main():
    root = Path(__file__).resolve().parent
    models_path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "models.tsv"
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "report" / "latest" / "models_metadata.tsv"
    checked_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    with models_path.open(newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            print(f"metadata model={row['model_key']} repo={row['hf_repo']}", file=sys.stderr, flush=True)
            writer.writerow(metadata(row, checked_at))

    print(out_path)


if __name__ == "__main__":
    main()
