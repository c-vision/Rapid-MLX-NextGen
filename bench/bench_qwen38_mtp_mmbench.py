#!/usr/bin/env python3
"""Paired AR/MTP MMBench gate for the compact Qwen3.8-27B SKU."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import tempfile
import time
from pathlib import Path
from typing import Any


def _args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--mtp-sidecar", required=True)
    parser.add_argument("--samples", type=int, default=300)
    parser.add_argument("--max-tokens", type=int, default=64)
    parser.add_argument("--draft-block-size", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def _answer(text: str) -> str | None:
    tail = text.split("</think>")[-1]
    match = re.search(r"\b([A-D])\b", tail)
    return match.group(1) if match else None


def _summary(records: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for mode in ("ar", "mtp"):
        rows = [row for row in records if row["mode"] == mode]
        result[mode] = {
            "correct": sum(bool(row["correct"]) for row in rows),
            "total": len(rows),
            "accuracy": sum(bool(row["correct"]) for row in rows) / len(rows),
            "mean_tps": sum(float(row["generation_tps"]) for row in rows) / len(rows),
        }
    paired = {mode: {} for mode in ("ar", "mtp")}
    for row in records:
        paired[row["mode"]][row["index"]] = row
    common = sorted(set(paired["ar"]) & set(paired["mtp"]))
    result["paired"] = {
        "common_correct": sum(
            paired["ar"][i]["correct"] and paired["mtp"][i]["correct"] for i in common
        ),
        "mtp_only_correct": sum(
            not paired["ar"][i]["correct"] and paired["mtp"][i]["correct"]
            for i in common
        ),
        "ar_only_correct": sum(
            paired["ar"][i]["correct"] and not paired["mtp"][i]["correct"]
            for i in common
        ),
        "identical_outputs": sum(
            paired["ar"][i]["sha256"] == paired["mtp"][i]["sha256"] for i in common
        ),
    }
    result["speedup"] = result["mtp"]["mean_tps"] / result["ar"]["mean_tps"]
    return result


def main() -> int:
    args = _args()
    if args.samples <= 0 or args.max_tokens <= 0:
        raise SystemExit("--samples and --max-tokens must be positive")

    from datasets import load_dataset
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.speculative.drafters import load_drafter

    dataset = load_dataset("lmms-lab/MMBench_EN", split="dev")
    indices = list(range(len(dataset)))
    random.Random(42).shuffle(indices)
    indices = indices[: args.samples]
    model, processor = load(args.model)
    drafter, draft_kind = load_drafter(args.mtp_sidecar, kind="mtp")
    records: list[dict[str, Any]] = []
    args.output.parent.mkdir(parents=True, exist_ok=True)

    with (
        tempfile.TemporaryDirectory(prefix="rapid-mtp-mmbench-") as temp_dir,
        args.output.open("w") as stream,
    ):
        for ordinal, index in enumerate(indices):
            row = dataset[index]
            options = {key: row[key] for key in "ABCD" if row.get(key)}
            hint = (row.get("hint") or "").strip()
            prompt = (
                ((f"Hint: {hint}\n") if hint else "")
                + row["question"]
                + "\n"
                + "\n".join(f"{key}. {value}" for key, value in options.items())
                + "\n\nAnswer with the single option letter only."
            )
            image_path = Path(temp_dir) / f"{index}.png"
            row["image"].convert("RGB").save(image_path)
            messages = [
                {
                    "role": "user",
                    "content": [
                        {"type": "image"},
                        {"type": "text", "text": prompt},
                    ],
                }
            ]
            formatted = apply_chat_template(
                processor,
                model.config,
                messages,
                num_images=1,
                enable_thinking=False,
            )
            modes = ("ar", "mtp") if ordinal % 2 == 0 else ("mtp", "ar")
            for mode in modes:
                kwargs: dict[str, Any] = {
                    "image": [str(image_path)],
                    "max_tokens": args.max_tokens,
                    "temperature": 0,
                    "verbose": False,
                }
                if mode == "mtp":
                    kwargs.update(
                        draft_model=drafter,
                        draft_kind=draft_kind,
                        draft_block_size=args.draft_block_size,
                    )
                started = time.perf_counter()
                output = generate(model, processor, formatted, **kwargs)
                elapsed = time.perf_counter() - started
                text = output.text if hasattr(output, "text") else str(output)
                generated = int(getattr(output, "generation_tokens", 0) or 0)
                record = {
                    "index": index,
                    "mode": mode,
                    "gold": row["answer"],
                    "prediction": _answer(text),
                    "correct": _answer(text) == row["answer"],
                    "generation_tokens": generated,
                    "generation_tps": generated / elapsed if elapsed else 0.0,
                    "elapsed_s": elapsed,
                    "sha256": hashlib.sha256(text.encode()).hexdigest(),
                }
                records.append(record)
                stream.write(json.dumps(record) + "\n")
                stream.flush()
            if (ordinal + 1) % 10 == 0:
                print(json.dumps({"completed": ordinal + 1, **_summary(records)}))

    summary = _summary(records)
    args.output.with_suffix(".summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
