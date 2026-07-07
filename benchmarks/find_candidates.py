#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.parse
import urllib.request


DEFAULT_QUERIES = [
    "Ministral-3-3B-Instruct GGUF",
    "Qwen3.5 4B GGUF",
    "Gemma 4B instruct GGUF",
    "GLM Edge 4B GGUF",
    "Phi-4-mini-instruct GGUF",
    "SmolLM3 3B GGUF",
    "Kimi 4B GGUF",
]


def api_models(query, limit):
    url = (
        "https://huggingface.co/api/models?"
        + urllib.parse.urlencode(
            {"search": query, "limit": str(limit), "sort": "downloads", "direction": "-1"}
        )
    )
    with urllib.request.urlopen(url, timeout=20) as response:
        return json.load(response)


def tag_value(tags, prefix):
    for tag in tags:
        if tag.startswith(prefix):
            return tag[len(prefix) :]
    return ""


def main():
    parser = argparse.ArgumentParser(
        description="List current Hugging Face GGUF candidates for Otlet model probes"
    )
    parser.add_argument("queries", nargs="*", default=DEFAULT_QUERIES)
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()

    print("query\tmodel_id\tdownloads\tlikes\tlicense\tbase_model")
    for query in args.queries:
        for model in api_models(query, args.limit):
            tags = model.get("tags") or []
            if "gguf" not in tags:
                continue
            print(
                "\t".join(
                    [
                        query,
                        model.get("modelId", ""),
                        str(model.get("downloads", "")),
                        str(model.get("likes", "")),
                        tag_value(tags, "license:"),
                        tag_value(tags, "base_model:"),
                    ]
                )
            )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"find_candidates failed: {exc}", file=sys.stderr)
        sys.exit(1)
