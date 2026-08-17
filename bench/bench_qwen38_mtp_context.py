#!/usr/bin/env python3
"""Measure paired AR/MTP decode and memory at a controlled prompt length."""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
from typing import Any


def _args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--mtp-sidecar", required=True)
    parser.add_argument("--prompt-tokens", type=int, default=4096)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--draft-block-size", type=int, default=3)
    parser.add_argument(
        "--memory-limit-gb",
        type=float,
        help="Optional MLX allocator limit, applied before model load",
    )
    return parser.parse_args()


def _encode(processor: Any, text: str) -> list[int]:
    tokenizer = getattr(processor, "tokenizer", processor)
    encoded = tokenizer.encode(text)
    return encoded.tolist() if hasattr(encoded, "tolist") else list(encoded)


def _render(processor: Any, content: str) -> str:
    messages = [{"role": "user", "content": content}]
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    try:
        return processor.apply_chat_template(messages, enable_thinking=False, **kwargs)
    except TypeError:
        return processor.apply_chat_template(messages, **kwargs)


def _controlled_prompt(processor: Any, target: int) -> tuple[str, int]:
    lines = [
        f"Record {index:05d}: project cobalt has checkpoint {index % 97}; "
        f"owner team-{index % 13}; status verified."
        for index in range(target)
    ]
    request = (
        "\nUsing the records above, explain a reliable validation strategy in "
        "detail. Do not enumerate every record."
    )
    low, high = 1, len(lines)
    best = _render(processor, lines[0] + request)
    best_count = len(_encode(processor, best))
    while low <= high:
        middle = (low + high) // 2
        rendered = _render(processor, "\n".join(lines[:middle]) + request)
        count = len(_encode(processor, rendered))
        if count <= target:
            best, best_count = rendered, count
            low = middle + 1
        else:
            high = middle - 1
    if best_count < int(target * 0.98):
        raise RuntimeError(
            f"could only construct {best_count} tokens for target {target}"
        )
    return best, best_count


def main() -> int:
    args = _args()
    if min(args.prompt_tokens, args.max_tokens, args.repeats) <= 0:
        raise SystemExit("token counts and repeats must be positive")

    import mlx.core as mx
    from mlx_vlm import generate, load
    from mlx_vlm.speculative.drafters import load_drafter

    if args.memory_limit_gb is not None:
        if args.memory_limit_gb <= 0:
            raise SystemExit("--memory-limit-gb must be positive")
        mx.set_memory_limit(int(args.memory_limit_gb * 1e9))
    model, processor = load(args.model)
    drafter, draft_kind = load_drafter(args.mtp_sidecar, kind="mtp")
    mx.eval(model.parameters(), drafter.parameters())
    mx.clear_cache()
    prompt, actual_prompt_tokens = _controlled_prompt(processor, args.prompt_tokens)
    records = []
    for repetition in range(args.repeats):
        for mode in ("ar", "mtp"):
            mx.clear_cache()
            mx.reset_peak_memory()
            active_before_gb = mx.get_active_memory() / 1e9
            kwargs = {
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
            result = generate(model, processor, prompt, **kwargs)
            records.append(
                {
                    "repetition": repetition,
                    "mode": mode,
                    "prompt_tokens": actual_prompt_tokens,
                    "generation_tokens": result.generation_tokens,
                    "generation_tps": result.generation_tps,
                    "peak_memory_gb": mx.get_peak_memory() / 1e9,
                    "active_before_gb": active_before_gb,
                    "active_after_gb": mx.get_active_memory() / 1e9,
                    "finish_reason": result.finish_reason,
                    "sha256": hashlib.sha256(result.text.encode()).hexdigest(),
                }
            )
    summary = {}
    for mode in ("ar", "mtp"):
        rows = [row for row in records if row["mode"] == mode]
        summary[mode] = {
            "mean_tps": statistics.mean(row["generation_tps"] for row in rows),
            "max_peak_memory_gb": max(row["peak_memory_gb"] for row in rows),
        }
    summary["speedup"] = summary["mtp"]["mean_tps"] / summary["ar"]["mean_tps"]
    summary["identical_pairs"] = sum(
        records[index]["sha256"] == records[index + 1]["sha256"]
        for index in range(0, len(records), 2)
    )
    print(json.dumps({"records": records, "summary": summary}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
