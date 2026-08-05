#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Decode-throughput perf-regression gate — measures generation speed against a
REAL running ``rapid-mlx serve`` and (optionally) fails when it drops below a
reviewed floor.

This is the perf half of the release gate that the Tier-1 agent smoke
(``tests/integrations/agent_smoke.sh``) runs on the SAME warm serve it already
booted for the agentic checks — so there is no second model load. Like
``evals/coherence_gate.py`` it requires a server to already be listening (it does
**not** boot one) and reads ``$RAPID_MLX_BASE_URL`` by default.

Why a long, fixed generation
----------------------------
A hybrid MoE model's tokens/sec on a SHORT response is dominated by prefill and
kernel-warmup noise (#284), so a short-prompt measurement is not a reliable
regression signal. This gate uses a short prompt and a LONG generation
(``--max-tokens``, default 512) so decode dominates the wall clock; on a fixed
workload at temperature 0 the end-to-end tokens/sec is a stable proxy for decode
throughput. A small warmup request precedes the measured one so a cold
long-context kernel does not skew the number.

Baseline is a reviewed human decision, never automatic
------------------------------------------------------
This gate NEVER invents a baseline. With no floor it runs ADVISORY: it prints the
measured tokens/sec and exits 0, so the first Studio run yields the number to
review. Enforcement turns on only when a floor is supplied, most-specific first:
``--min-tps`` > ``$RAPID_MLX_PERF_MIN_TPS`` > the committed per-alias floor in
``--floors-file`` (``harness/perf_floors.json``). Set the reviewed number to
~85% of the observed warm rate to absorb run-to-run variance.

Usage
-----
    # advisory (prints tokens/sec, always exits 0):
    python evals/perf_gate.py --base-url http://127.0.0.1:8000/v1

    # enforcing via a one-off override:
    RAPID_MLX_PERF_MIN_TPS=19.5 python evals/perf_gate.py

    # enforcing via the committed reviewed floor for a served alias
    # (how release-check-m3's G8b gate calls it):
    python evals/perf_gate.py --alias qwen3.5-9b-4bit \
        --floors-file harness/perf_floors.json

Exit codes:
    0 — measured tokens/sec >= floor, OR advisory mode (no floor set)
    1 — a floor was set and the measured tokens/sec fell below it (regression)
    2 — no server reachable, or the response lacked usable token accounting
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

import httpx

_DEFAULT_BASE_URL = os.environ.get("RAPID_MLX_BASE_URL", "http://127.0.0.1:8000/v1")

# Short prompt, long deterministic generation — decode dominates the wall clock.
_DEFAULT_PROMPT = (
    "Write a thorough technical explanation of how a modern CPU memory cache "
    "works. Cover the L1/L2/L3 hierarchy, cache lines, associativity, write-back "
    "vs write-through, and eviction policies such as LRU. Be detailed and precise."
)


# Smallest decode sample this gate will judge. Below this the tokens/sec
# figure is dominated by scheduling noise rather than steady-state decode.
_MIN_DECODE_TOKENS = 64


class InvalidServerResponseError(RuntimeError):
    """The server replied, but without usable token accounting."""


def _env_float(name: str) -> float | None:
    """Parse a float env var. Unset/blank -> None (advisory). Garbage raises,
    because an operator who set the variable meant to enforce something."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        raise SystemExit(
            f"ERROR: {name}={raw!r} is not a number; refusing to guess a floor."
        )


class FloorsFileError(RuntimeError):
    """A committed floors file could not be read or is malformed."""


def _load_floor_from_file(path: str, alias: str) -> float | None:
    """Look up the reviewed decode-tok/s floor for ``alias`` in a committed
    floors file (``harness/perf_floors.json``).

    Shape::

        {"schema": 1, "floors": {"qwen3.5-9b-4bit": 29.5, ...}}

    Returns the floor for ``alias`` if present, else ``None`` (advisory — the
    alias simply has no reviewed floor yet). Anything else about the COMMITTED
    config being wrong raises ``FloorsFileError`` so the caller fails loudly
    rather than silently dropping enforcement — this includes an unreadable
    file, invalid JSON, a non-object top level, an unsupported/absent
    ``schema``, an absent or non-object ``floors``, and a present floor whose
    value is not a finite number ``> 0`` (a committed ``0`` / negative / NaN /
    ``Infinity`` floor cannot enforce anything, so it is a config error, not a
    "no floor"). Only a MISSING alias — not a broken file — is the advisory
    ``None`` path.
    """
    if not alias:
        # No alias to look up — a floors file is useless without one. Treat as
        # "no file floor" rather than erroring, so callers can always pass the
        # file and let the alias decide whether it matters. main() separately
        # rejects a --floors-file supplied with no --alias and no other floor.
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise FloorsFileError(f"cannot read floors file {path!r}: {exc}") from exc
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise FloorsFileError(f"floors file {path!r} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise FloorsFileError(f"floors file {path!r} must be a JSON object")
    # A committed config with the wrong/absent schema is malformed, not empty:
    # a future breaking format change must fail loudly here, never be read as
    # "no floors" (which would silently disable enforcement for every alias).
    # Strict identity check: ``schema`` must be the INTEGER 1. ``!= 1`` alone
    # would accept ``true`` (bool is an int subclass, ``True == 1``) and
    # ``1.0`` (``1.0 == 1``) — both malformed JSON that must not pass.
    schema = data.get("schema")
    if type(schema) is not int or schema != 1:
        raise FloorsFileError(
            f"floors file {path!r}: unsupported schema {schema!r} (expected integer 1)"
        )
    # ``floors`` must be PRESENT — a missing key is a broken file, not an empty
    # registry. An empty ``{}`` object IS valid (the seeded state: advisory for
    # every alias); a missing key is not.
    if "floors" not in data:
        raise FloorsFileError(f"floors file {path!r}: missing required 'floors' object")
    floors = data["floors"]
    if not isinstance(floors, dict):
        raise FloorsFileError(f"floors file {path!r}: 'floors' must be an object")
    if alias not in floors:
        return None
    value = floors[alias]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        # ``bool`` is an ``int`` subclass — reject True/False explicitly so a
        # stray ``true`` isn't read as the floor 1.0.
        raise FloorsFileError(
            f"floors file {path!r}: floor for {alias!r} must be a number, got {value!r}"
        )
    value = float(value)
    # Range-check the committed value HERE so a bogus 0 / negative / NaN /
    # Infinity fails as a config error naming the file + alias, rather than
    # slipping through to main()'s generic "resolved floor cannot enforce"
    # guard (which still backstops CLI / env floors).
    if not math.isfinite(value) or value <= 0:
        raise FloorsFileError(
            f"floors file {path!r}: floor for {alias!r} must be a finite number "
            f"> 0, got {value!r}"
        )
    return value


def resolve_floor(
    *,
    cli_min_tps: float | None,
    env_min_tps: float | None,
    floors_file: str | None,
    alias: str | None,
) -> float | None:
    """Resolve the effective decode-tok/s floor from all sources, most-specific
    first: an explicit ``--min-tps`` beats ``RAPID_MLX_PERF_MIN_TPS`` beats the
    committed ``floors_file[alias]``; if none supplies one, the gate runs
    advisory (``None``).

    An operator override (CLI/env) intentionally wins over the committed file so
    a one-off run can tighten or relax the reviewed floor without editing repo
    config. Validation of the winning value is left to :func:`main`.
    """
    if cli_min_tps is not None:
        return cli_min_tps
    if env_min_tps is not None:
        return env_min_tps
    if floors_file is not None:
        return _load_floor_from_file(floors_file, alias or "")
    return None


def _server_reachable(base_url: str) -> bool:
    try:
        r = httpx.get(f"{base_url.rstrip('/')}/models", timeout=5.0)
        return r.status_code == 200
    except Exception:
        return False


class MeasurementError(RuntimeError):
    """The run completed but produced no usable perf sample."""


def _measure_decode(
    base_url: str, prompt: str, *, max_tokens: int, timeout: float
) -> tuple[int, float, float]:
    """Stream one completion and separate prefill from decode.

    Returns ``(decoded_tokens, ttft_seconds, decode_seconds)``.

    Dividing total request latency by token count — which this gate used to
    do — charges prefill and time-to-first-token against decode, so a long
    prompt makes a healthy model look slow (512 tokens with 10s TTFT + 20s
    decode reports 17 tok/s for a model actually decoding at 25.6). vLLM and
    SGLang both report TTFT and output-token throughput as separate numbers
    for exactly this reason; measure decode the same way, from the first
    streamed token to the last.

    Token COUNT comes from ``usage.completion_tokens`` via
    ``stream_options.include_usage``, not from counting SSE frames: one delta
    is not one token (the detokenizer can batch several, and a frame can
    carry no text at all), so frame-counting silently understates throughput.
    """
    body = {
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        # Authoritative token accounting — see the docstring.
        "stream_options": {"include_usage": True},
        # Match the gauntlet's --no-thinking boot: measure answer-token decode,
        # not thinking-mode expansion.
        "enable_thinking": False,
    }
    start = time.monotonic()
    # httpx's timeout is per-READ (inactivity), not a total deadline: a stream
    # that trickles one frame every timeout-minus-epsilon seconds never trips
    # it and can outlive the whole CI job budget. Bound the wall clock too.
    deadline = start + timeout
    first_tok_at: float | None = None
    last_tok_at = start
    deltas = 0
    usage_tokens: int | None = None
    finish_reason: str | None = None

    with httpx.stream(
        "POST", f"{base_url.rstrip('/')}/chat/completions", json=body, timeout=timeout
    ) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if time.monotonic() > deadline:
                raise MeasurementError(
                    f"stream exceeded the {timeout:.0f}s budget "
                    f"(decoded {deltas} frames so far)"
                )
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                chunk = json.loads(payload)
            except ValueError as exc:
                # A frame we cannot parse means the stream is not what we think
                # it is. Swallowing it would let a truncated run be judged as a
                # complete one.
                raise MeasurementError(
                    f"malformed SSE frame: {payload[:120]!r}"
                ) from exc
            # Mid-stream error frames are how the server reports a generation
            # that died partway. Counting the tokens that arrived before it
            # would score an incomplete run as a healthy one.
            if isinstance(chunk, dict) and chunk.get("error"):
                raise MeasurementError(
                    f"server reported an error mid-stream: {chunk['error']}"
                )
            if usage := (chunk.get("usage") if isinstance(chunk, dict) else None):
                if (ct := usage.get("completion_tokens")) is not None:
                    usage_tokens = int(ct)
            choices = chunk.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            if choice.get("delta", {}).get("content"):
                now = time.monotonic()
                if first_tok_at is None:
                    first_tok_at = now
                last_tok_at = now
                deltas += 1
            if choice.get("finish_reason"):
                finish_reason = choice["finish_reason"]

    if first_tok_at is None or deltas == 0:
        raise MeasurementError("server streamed no content tokens")

    # A stream that never reported why it stopped did not demonstrably finish;
    # judging its throughput would score a truncated generation as a healthy one.
    if finish_reason is None:
        raise MeasurementError(
            "stream ended without a terminal finish_reason — generation did not "
            "demonstrably complete"
        )

    tokens = usage_tokens if usage_tokens is not None else deltas
    if usage_tokens is None:
        print(
            "  NOTE: server sent no usage.completion_tokens; falling back to "
            "counting SSE deltas, which can understate throughput.",
            file=sys.stderr,
        )

    # A gate that accepts any sample size is not a gate: `max_tokens` is only
    # a CEILING, so a model that stops after 8 tokens would report a number
    # computed over 0.2s of noise and sail past any floor. Require enough
    # decode to be meaningful.
    if tokens < _MIN_DECODE_TOKENS:
        raise MeasurementError(
            f"only {tokens} tokens decoded (finish_reason={finish_reason!r}); "
            f"need >= {_MIN_DECODE_TOKENS} for a meaningful throughput sample"
        )

    ttft = first_tok_at - start
    decode_seconds = last_tok_at - first_tok_at
    if decode_seconds <= 0:
        raise MeasurementError("all tokens arrived in one batch — cannot time decode")
    return tokens, ttft, decode_seconds


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--base-url",
        default=_DEFAULT_BASE_URL,
        help="OpenAI-compatible base URL (default: $RAPID_MLX_BASE_URL or "
        "http://127.0.0.1:8000/v1)",
    )
    ap.add_argument(
        "--min-tps",
        type=float,
        default=None,
        help="reviewed decode tokens/sec floor; below it the gate fails. "
        "An explicit value here overrides both $RAPID_MLX_PERF_MIN_TPS and the "
        "--floors-file entry. Default: resolve from env / floors file, else "
        "advisory-only.",
    )
    ap.add_argument(
        "--floors-file",
        default=None,
        help="path to a committed reviewed-floors JSON "
        '(harness/perf_floors.json): {"floors": {"<alias>": <tok/s>}}. '
        "When --alias has an entry the gate ENFORCES that floor; when it "
        "doesn't, the gate runs advisory. Lower precedence than --min-tps and "
        "$RAPID_MLX_PERF_MIN_TPS.",
    )
    ap.add_argument(
        "--alias",
        default=None,
        help="the served model alias, used to look up its reviewed floor in "
        "--floors-file.",
    )
    ap.add_argument(
        "--max-tokens",
        type=int,
        default=512,
        help="generation length for the measured request (default: 512)",
    )
    ap.add_argument(
        "--timeout",
        type=float,
        default=300.0,
        help="total budget for the measured request (s). Bounds wall-clock "
        "time, not just read inactivity (default: 300)",
    )
    args = ap.parse_args()

    # Honor CLI-over-env precedence for BOTH the value and its errors: an
    # explicit --min-tps makes $RAPID_MLX_PERF_MIN_TPS irrelevant, so don't
    # even parse it (``_env_float`` SystemExits on a malformed value — parsing
    # it unconditionally would abort a run whose CLI floor is perfectly valid).
    env_min_tps = _env_float("RAPID_MLX_PERF_MIN_TPS") if args.min_tps is None else None

    # A --floors-file with no --alias resolves to advisory (nothing to look
    # up), which silently defeats the gate the caller clearly meant to arm.
    # Reject it — UNLESS a higher-precedence CLI/env floor is active, in which
    # case the file is moot and the run is legitimately enforcing anyway.
    if (
        args.floors_file is not None
        and not (args.alias or "").strip()
        and args.min_tps is None
        and env_min_tps is None
    ):
        print(
            "ERROR: --floors-file was given without --alias and no "
            "--min-tps / $RAPID_MLX_PERF_MIN_TPS floor is set, so no floor "
            "could be looked up and the gate would silently run advisory. "
            "Pass --alias <served model> to enforce its committed floor.",
            file=sys.stderr,
        )
        return 2

    # Resolve the effective floor from all sources (CLI > env > floors file).
    # A broken COMMITTED floors file is an operator error that must fail loudly
    # rather than silently dropping enforcement — the whole point of wiring
    # this gate is that a regression can't slip through unnoticed.
    try:
        min_tps = resolve_floor(
            cli_min_tps=args.min_tps,
            env_min_tps=env_min_tps,
            floors_file=args.floors_file,
            alias=args.alias,
        )
    except FloorsFileError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    args.min_tps = min_tps

    # A floor of NaN silently disables enforcement: every `tps < nan` is False,
    # so a 1 tok/s model would PASS. Same for inf (always fails) and <= 0
    # (meaningless). A malformed floor means the operator INTENDED to enforce
    # and the value is broken — refuse rather than quietly run advisory. This
    # guards the resolved floor regardless of which source supplied it.
    if args.min_tps is not None and not (
        math.isfinite(args.min_tps) and args.min_tps > 0
    ):
        print(
            f"ERROR: resolved perf floor is {args.min_tps!r} "
            "(--min-tps / $RAPID_MLX_PERF_MIN_TPS / --floors-file); "
            "expected a finite number > 0. Refusing to run with a floor that "
            "cannot enforce anything.",
            file=sys.stderr,
        )
        return 2

    base_url = args.base_url
    print("=" * 60)
    print("  perf-regression gate (decode throughput)")
    print(f"  base_url: {base_url}")
    floor_str = (
        f"{args.min_tps:.2f} tok/s" if args.min_tps is not None else "(advisory)"
    )
    print(f"  floor: {floor_str}   max_tokens: {args.max_tokens}")
    print("=" * 60)

    # The caller's contract is "non-zero blocks the release", so whether a
    # measurement FAILURE blocks depends on the mode. With a reviewed floor we
    # fail closed: unable to verify == not verified. In advisory mode there is
    # nothing to enforce, so an unreachable server or a flaky request must not
    # take the release down over a number nobody is checking yet.
    advisory = args.min_tps is None

    def _unmeasurable(msg: str) -> int:
        print(f"ERROR: perf measurement failed: {msg}", file=sys.stderr)
        if advisory:
            print(
                "  ADVISORY: no floor set — not blocking the release on a "
                "measurement this gate is not yet enforcing."
            )
            return 0
        print(
            "  A floor is set, so an unverifiable measurement blocks: "
            "cannot confirm the model did not regress.",
            file=sys.stderr,
        )
        return 2

    if not _server_reachable(base_url):
        return _unmeasurable(
            f"no rapid-mlx server reachable at {base_url} "
            "(start one with: rapid-mlx serve <model> --port 8000)"
        )

    try:
        # Warm the decode path so the measured run is not skewed by a
        # first-touch kernel compile (the agent smoke already exercised the
        # serve, so this is usually a no-op).
        _measure_decode(base_url, "Say ready.", max_tokens=8, timeout=args.timeout)
    except Exception:  # noqa: BLE001 — warm-up result is deliberately ignored
        pass

    try:
        tokens, ttft, decode_seconds = _measure_decode(
            base_url, _DEFAULT_PROMPT, max_tokens=args.max_tokens, timeout=args.timeout
        )
    except (httpx.HTTPError, InvalidServerResponseError, MeasurementError) as exc:
        return _unmeasurable(str(exc))

    tps = tokens / decode_seconds
    print(
        f"  measured: {tokens} tokens, TTFT {ttft:.2f}s, "
        f"decode {decode_seconds:.2f}s -> {tps:.2f} tok/s (decode only)"
    )
    print("=" * 60)

    if advisory:
        print(
            "  ADVISORY: no floor set (RAPID_MLX_PERF_MIN_TPS unset) — record this "
            "number, review it, then set the floor to enforce."
        )
        return 0

    if tps < args.min_tps:
        print(
            f"PERF GATE FAILED — {tps:.2f} tok/s is below the reviewed floor of "
            f"{args.min_tps:.2f} tok/s. The served model regressed; do NOT release.",
            file=sys.stderr,
        )
        return 1

    print(f"  PASS: {tps:.2f} tok/s >= floor {args.min_tps:.2f} tok/s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
