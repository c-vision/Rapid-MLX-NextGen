#!/usr/bin/env python3
"""Paired AR/MTP capability and throughput gate for the 24 GB Qwen3.8 SKU.

This bench intentionally evaluates the same checkpoint twice, once with plain
autoregressive decoding and once with an external MTP sidecar.  Every item is
paired, so the report can distinguish a real answer flip from ordinary score
noise.  It also records completion hashes: equal hashes are stronger evidence
than equal aggregate accuracy.

The default model/head pair is the proposed 24 GB SKU.  Dataset rows are read
from Hugging Face's datasets-server API in stable source order; no ``datasets``
dependency or local dataset cache is required.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import statistics
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

DEFAULT_MODEL = "rapid-mlx/Qwen3.8-27B-mixed-3.5bpw-MLX"
DEFAULT_HEAD = "mlx-community/Qwen3.8-27B-MTP-4bit"
_DATASETS_SERVER = "https://datasets-server.huggingface.co/rows"
_LETTERS = "ABCDEFGHIJ"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--mtp-sidecar", default=DEFAULT_HEAD)
    parser.add_argument(
        "--task",
        choices=("mmlu-pro", "gsm8k", "humaneval"),
        default="mmlu-pro",
    )
    parser.add_argument("--samples", type=int, default=None)
    parser.add_argument(
        "--indices",
        help="Comma-separated zero-based dataset row indices for targeted reruns",
    )
    parser.add_argument("--draft-block-size", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=None)
    parser.add_argument("--code-timeout", type=float, default=4.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def _task_defaults(task: str) -> tuple[int, int]:
    if task == "mmlu-pro":
        return 500, 24
    if task == "gsm8k":
        return 150, 512
    return 40, 640


def _fetch_rows(dataset: str, config: str, split: str, count: int) -> list[dict]:
    rows: list[dict] = []
    for offset in range(0, count, 100):
        length = min(100, count - offset)
        query = urllib.parse.urlencode(
            {
                "dataset": dataset,
                "config": config,
                "split": split,
                "offset": offset,
                "length": length,
            }
        )
        with urllib.request.urlopen(f"{_DATASETS_SERVER}?{query}") as response:
            payload = json.load(response)
        rows.extend(item["row"] for item in payload["rows"])
    if len(rows) != count:
        raise RuntimeError(
            f"requested {count} rows but datasets-server returned {len(rows)}"
        )
    return rows


def _dataset(task: str, count: int) -> list[dict]:
    if task == "mmlu-pro":
        return _fetch_rows("TIGER-Lab/MMLU-Pro", "default", "test", count)
    if task == "gsm8k":
        return _fetch_rows("openai/gsm8k", "main", "test", count)
    return _fetch_rows(
        "openai/openai_humaneval",
        "openai_humaneval",
        "test",
        count,
    )


def _render_item(task: str, row: dict) -> tuple[str, str]:
    if task == "mmlu-pro":
        options = "\n".join(
            f"{_LETTERS[index]}. {option}"
            for index, option in enumerate(row["options"])
        )
        return (
            "Choose the best answer. Reply with only the letter.\n\n"
            f"{row['question']}\n{options}\nAnswer:",
            row["answer"],
        )
    if task == "gsm8k":
        match = re.search(r"####\s*([-0-9,.]+)", row["answer"])
        if match is None:
            raise ValueError("GSM8K answer has no #### final-answer marker")
        return (
            "Solve this problem. Give a brief calculation and end with FINAL: "
            f"followed by only the numeric answer.\n\n{row['question']}",
            match.group(1).replace(",", ""),
        )
    return (
        "Complete this Python function correctly. Return only one Python code "
        "block containing a complete executable solution, including imports and "
        f"the function definition.\n\n{row['prompt']}",
        row["task_id"],
    )


def _extract_answer(task: str, text: str) -> str | None:
    if task == "mmlu-pro":
        match = re.search(r"(?:^|\b)([A-J])(?:\b|$)", text.strip().upper())
        return match.group(1) if match else None
    if task == "humaneval":
        return None
    matches = re.findall(
        r"FINAL\s*:\s*\$?\s*(-?[\d,]+(?:\.\d+)?)",
        text,
        re.IGNORECASE,
    )
    return matches[-1].replace(",", "") if matches else None


def _chat_prompt(processor: Any, prompt: str, *, thinking: bool) -> str:
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    messages = [{"role": "user", "content": prompt}]
    try:
        return processor.apply_chat_template(
            messages,
            enable_thinking=thinking,
            **kwargs,
        )
    except TypeError:
        return processor.apply_chat_template(messages, **kwargs)


def _extract_python(text: str) -> str:
    blocks = re.findall(r"```(?:python)?\s*(.*?)```", text, re.DOTALL | re.IGNORECASE)
    if blocks:
        return blocks[-1].strip()
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def _run_humaneval_sandbox(
    code: str,
    row: dict[str, Any],
    *,
    timeout: float,
) -> tuple[bool, str]:
    """Run one generated solution in a deny-by-default macOS sandbox."""

    sandbox_exec = shutil.which("sandbox-exec")
    if sandbox_exec is None:
        raise RuntimeError(
            "HumanEval requires macOS sandbox-exec; refusing to execute generated "
            "code directly on the host"
        )
    profile = (
        "(version 1) (deny default) (allow process*) "
        "(allow file-read*) (allow sysctl-read)"
    )
    program = f"{code}\n{row['test']}\ncheck({row['entry_point']})\n"
    try:
        result = subprocess.run(
            [sandbox_exec, "-p", profile, "/usr/bin/python3", "-c", program],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    return result.returncode == 0, result.stderr[-500:]


def _condition_result(
    *,
    mode: str,
    model: Any,
    processor: Any,
    drafter: Any,
    draft_kind: str,
    prompt: str,
    task: str,
    gold: str,
    max_tokens: int,
    draft_block_size: int,
    row: dict[str, Any],
    code_timeout: float,
) -> dict[str, Any]:
    from mlx_vlm import generate

    kwargs: dict[str, Any] = {
        "max_tokens": max_tokens,
        "temperature": 0,
        "verbose": False,
    }
    if mode == "mtp":
        kwargs.update(
            draft_model=drafter,
            draft_kind=draft_kind,
            draft_block_size=draft_block_size,
        )
    result = generate(model, processor, prompt, **kwargs)
    prediction = _extract_answer(task, result.text)
    correct = prediction == gold
    sandbox_error = None
    completion = result.text
    if task == "humaneval":
        completion = _extract_python(result.text)
        correct, sandbox_error = _run_humaneval_sandbox(
            completion,
            row,
            timeout=code_timeout,
        )
    record = {
        "prediction": prediction,
        "correct": correct,
        "generation_tokens": result.generation_tokens,
        "generation_tps": round(result.generation_tps, 3),
        "peak_memory_gb": round(result.peak_memory, 3),
        "finish_reason": result.finish_reason,
        "sha256": hashlib.sha256(completion.encode()).hexdigest(),
    }
    if sandbox_error and not correct:
        record["sandbox_error"] = sandbox_error
    return record


def _summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    flips = Counter(
        (record["ar"]["correct"], record["mtp"]["correct"]) for record in records
    )
    return {
        "samples": len(records),
        "ar_correct": sum(record["ar"]["correct"] for record in records),
        "mtp_correct": sum(record["mtp"]["correct"] for record in records),
        "ar_only_correct": flips[(True, False)],
        "mtp_only_correct": flips[(False, True)],
        "identical_completions": sum(
            record["ar"]["sha256"] == record["mtp"]["sha256"] for record in records
        ),
        "ar_mean_tps": round(
            statistics.mean(record["ar"]["generation_tps"] for record in records),
            3,
        ),
        "mtp_mean_tps": round(
            statistics.mean(record["mtp"]["generation_tps"] for record in records),
            3,
        ),
        "max_peak_memory_gb": max(
            record[mode]["peak_memory_gb"]
            for record in records
            for mode in ("ar", "mtp")
        ),
    }


def main() -> int:
    args = _parse_args()
    default_samples, task_max_tokens = _task_defaults(args.task)
    max_tokens = args.max_tokens or task_max_tokens
    samples = args.samples if args.samples is not None else default_samples
    if samples <= 0:
        raise SystemExit("--samples must be positive")
    if max_tokens <= 0:
        raise SystemExit("--max-tokens must be positive")
    indices = None
    if args.indices:
        try:
            indices = [int(value) for value in args.indices.split(",")]
        except ValueError as exc:
            raise SystemExit("--indices must be comma-separated integers") from exc
        if not indices or min(indices) < 0 or len(indices) != len(set(indices)):
            raise SystemExit("--indices must contain unique non-negative integers")
        samples = len(indices)
    plan = {
        "model": args.model,
        "mtp_sidecar": args.mtp_sidecar,
        "task": args.task,
        "samples": samples,
        "max_tokens": max_tokens,
        "temperature": 0,
        "thinking": args.task == "humaneval",
        "draft_block_size": args.draft_block_size,
        "indices": indices,
    }
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return 0

    from mlx_vlm import load
    from mlx_vlm.speculative.drafters import load_drafter

    if indices is None:
        indexed_rows = list(enumerate(_dataset(args.task, samples)))
    else:
        source_rows = _dataset(args.task, max(indices) + 1)
        indexed_rows = [(index, source_rows[index]) for index in indices]
    model, processor = load(args.model)
    drafter, draft_kind = load_drafter(args.mtp_sidecar, kind="mtp")
    output = args.output
    stream = output.open("w") if output is not None else sys.stdout
    records: list[dict[str, Any]] = []
    try:
        for index, row in indexed_rows:
            raw_prompt, gold = _render_item(args.task, row)
            prompt = _chat_prompt(
                processor,
                raw_prompt,
                thinking=args.task == "humaneval",
            )
            record: dict[str, Any] = {"index": index, "gold": gold}
            if args.task == "mmlu-pro":
                record["category"] = row["category"]
            for mode in ("ar", "mtp"):
                record[mode] = _condition_result(
                    mode=mode,
                    model=model,
                    processor=processor,
                    drafter=drafter,
                    draft_kind=draft_kind,
                    prompt=prompt,
                    task=args.task,
                    gold=gold,
                    max_tokens=max_tokens,
                    draft_block_size=args.draft_block_size,
                    row=row,
                    code_timeout=args.code_timeout,
                )
            records.append(record)
            print(json.dumps(record, sort_keys=True), file=stream, flush=True)
            if (index + 1) % 10 == 0:
                print(f"completed {index + 1}/{samples}", file=sys.stderr)
    finally:
        if output is not None:
            stream.close()

    print(json.dumps({"plan": plan, "summary": _summarize(records)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
