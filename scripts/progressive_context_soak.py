#!/usr/bin/env python3
"""Grow one OpenAI Responses conversation like a long-running Codex session.

Unlike a synthetic single-shot long prompt, this sends the full conversation on
every turn while adding only a small suffix. A healthy prefix cache should make
prefill work proportional to the suffix, not to the total context.

Example:
  .venv/bin/python scripts/progressive_context_soak.py \
    --url http://127.0.0.1:8000/v1 --model deepseek-v4-flash-0731 \
    --stages 32000,64000,128000,200000,300000 --compact
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from dataclasses import asdict, dataclass

import httpx


@dataclass
class TurnResult:
    target_tokens: int
    prompt_tokens: int
    completion_tokens: int
    ttft_seconds: float
    elapsed_seconds: float
    output_chars: int
    repetition_period: int | None


def repetition_period(
    text: str, *, repeats: int = 3, max_period: int = 512
) -> int | None:
    """Return a repeated tail period, matching the failure Codex reconnects on."""
    if not text:
        return None
    limit = min(max_period, len(text) // repeats)
    for period in range(1, limit + 1):
        tail = text[-period:]
        if text.endswith(tail * repeats):
            return period
    return None


def padding_for_tokens(needed: int) -> str:
    # A leading-space common word is one token in the DeepSeek tokenizer. The
    # usage feedback loop corrects any tokenizer-specific error on later turns.
    return " context" * max(0, needed)


def _extract_usage(event: dict) -> tuple[int, int] | None:
    response = event.get("response") or event
    usage = response.get("usage") if isinstance(response, dict) else None
    if not isinstance(usage, dict):
        return None
    prompt = usage.get("input_tokens", usage.get("prompt_tokens", 0))
    completion = usage.get("output_tokens", usage.get("completion_tokens", 0))
    return int(prompt or 0), int(completion or 0)


def run_turn(
    client: httpx.Client,
    *,
    url: str,
    model: str,
    items: list[dict],
    max_output_tokens: int,
    timeout: float,
) -> tuple[TurnResult, str]:
    payload = {
        "model": model,
        "input": items,
        "stream": True,
        "max_output_tokens": max_output_tokens,
        "reasoning": {"effort": "medium"},
    }
    start = time.perf_counter()
    first_token_at = None
    output_parts: list[str] = []
    usage = (0, 0)
    completed = False
    with client.stream(
        "POST", f"{url}/responses", json=payload, timeout=timeout
    ) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            event = json.loads(line[6:])
            event_type = event.get("type")
            if event_type in {"response.failed", "error"}:
                raise RuntimeError(f"response stream failed: {event!r}")
            if event_type == "response.completed":
                completed = True
            delta = event.get("delta")
            if isinstance(delta, str) and delta:
                if first_token_at is None:
                    first_token_at = time.perf_counter()
                output_parts.append(delta)
            found_usage = _extract_usage(event)
            if found_usage is not None:
                usage = found_usage
    if not completed:
        raise RuntimeError("response stream ended without response.completed")
    if usage[0] <= 0:
        raise RuntimeError(f"response completed without valid input usage: {usage!r}")
    end = time.perf_counter()
    text = "".join(output_parts)
    return (
        TurnResult(
            target_tokens=0,
            prompt_tokens=usage[0],
            completion_tokens=usage[1],
            ttft_seconds=(first_token_at or end) - start,
            elapsed_seconds=end - start,
            output_chars=len(text),
            repetition_period=repetition_period(text),
        ),
        text,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000/v1")
    parser.add_argument("--model", default="deepseek-v4-flash-0731")
    parser.add_argument("--stages", default="32000,64000,128000,200000,300000")
    parser.add_argument("--max-output-tokens", type=int, default=64)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--compact", action="store_true")
    parser.add_argument("--json-out")
    args = parser.parse_args()

    stages = [int(x) for x in args.stages.split(",") if x.strip()]
    if (
        not stages
        or stages[0] <= 0
        or any(current <= previous for previous, current in zip(stages, stages[1:]))
    ):
        parser.error("--stages must be positive, ascending comma-separated integers")

    items: list[dict] = [
        {
            "role": "user",
            "content": "We are maintaining Rapid-MLX. Preserve all prior context and reply only with a short progress checkpoint.",
        }
    ]
    results: list[TurnResult] = []
    observed_prompt_tokens = 0

    with httpx.Client() as client:
        for target in stages:
            # The first estimate is deliberately conservative. After each turn,
            # server-reported usage closes the loop for the next target.
            needed = max(1, target - observed_prompt_tokens)
            items.append(
                {
                    "role": "user",
                    "content": "Append-only project evidence:\n"
                    + padding_for_tokens(needed),
                }
            )
            result, output = run_turn(
                client,
                url=args.url,
                model=args.model,
                items=items,
                max_output_tokens=args.max_output_tokens,
                timeout=args.timeout,
            )
            result.target_tokens = target
            results.append(result)
            observed_prompt_tokens = result.prompt_tokens
            items.append({"role": "assistant", "content": output or "checkpoint"})
            print(json.dumps(asdict(result), sort_keys=True), flush=True)
            if result.repetition_period is not None:
                raise RuntimeError(
                    f"exact repetition loop at target {target}: "
                    f"period={result.repetition_period}"
                )

        if args.compact:
            # Simulate Codex compaction: replace the old branch with a concise
            # summary, then verify the server remains healthy and memory/cache
            # policy can age out the abandoned long branch.
            items = [
                {
                    "role": "user",
                    "content": (
                        "Compacted project state: Rapid-MLX long-context soak "
                        f"reached {observed_prompt_tokens} tokens successfully. "
                        "Continue from this summary and answer with OK."
                    ),
                }
            ]
            compact_result, compact_output = run_turn(
                client,
                url=args.url,
                model=args.model,
                items=items,
                max_output_tokens=16,
                timeout=args.timeout,
            )
            compact_result.target_tokens = 0
            results.append(compact_result)
            print(json.dumps({"compact": asdict(compact_result)}, sort_keys=True))
            normalized = compact_output.strip().rstrip(".! ").casefold()
            if normalized != "ok":
                raise RuntimeError(
                    f"compact/resume returned unexpected output: {compact_output!r}"
                )

    report = {
        "results": [asdict(r) for r in results],
        "max_prompt_tokens": max(r.prompt_tokens for r in results),
        "median_ttft_seconds": statistics.median(r.ttft_seconds for r in results),
        "passed": all(r.repetition_period is None for r in results),
    }
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
