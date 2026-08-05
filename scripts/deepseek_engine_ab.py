#!/usr/bin/env python3
"""Compare DeepSeek-compatible Responses endpoints on engineering tasks.

The suite deliberately uses small, independently scoreable cases before an
expensive Codex soak.  Endpoint credentials are read from environment
variables and are never included in the JSON report.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

EXEC_TOOL = {
    "type": "function",
    "name": "exec_command",
    "description": "Run a shell command in the repository.",
    "parameters": {
        "type": "object",
        "properties": {"cmd": {"type": "string"}},
        "required": ["cmd"],
        "additionalProperties": False,
    },
}


@dataclass(frozen=True)
class Case:
    name: str
    prompt: str
    expected: str
    tools: tuple[dict[str, Any], ...] = ()


CASES = (
    Case(
        name="bounded_inspection",
        prompt=(
            "Inspect scripts/release_check_m3_random.py and "
            "tests/test_release_check_random.py. Make exactly one "
            "exec_command tool call using exactly: cat "
            "scripts/release_check_m3_random.py tests/test_release_check_random.py"
        ),
        expected="one_exec_call_reads_both",
        tools=(EXEC_TOOL,),
    ),
    Case(
        name="backward_compatibility_review",
        prompt=(
            "Review this compatibility requirement: profiles without "
            "g12_eligible remain eligible, while an explicit false opts out. "
            "Candidate A is `profile.get('g12_eligible', True) is not False`. "
            "Candidate B is `bool(profile.get('g12_eligible', False))`. Which "
            "candidate satisfies the requirement? Reply with one letter: A or B."
        ),
        expected="exact_a",
    ),
    Case(
        name="schema_recovery",
        prompt=(
            "AliasProfile is a deprecated alias of ModelProfile. A regression "
            "says: g12_eligible is rejected because it is absent from the "
            "allowed profile-key schema. Should the next change add or remove "
            "g12_eligible from that schema? Reply with one word: ADD or REMOVE."
        ),
        expected="exact_add",
    ),
)


@dataclass
class Trial:
    endpoint: str
    case: str
    repetition: int
    passed: bool
    status: str
    latency_seconds: float
    input_tokens: int
    output_tokens: int
    reasoning_tokens: int
    tool_calls: int
    answer: str
    failure: str | None = None


def extract_response(data: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    text: list[str] = []
    calls: list[dict[str, Any]] = []
    for item in data.get("output", []):
        if item.get("type") == "function_call":
            calls.append(item)
        for content in item.get("content") or []:
            if content.get("type") == "output_text" and content.get("text"):
                text.append(content["text"])
    return "\n".join(text).strip(), calls


def score(
    case: Case, answer: str, calls: list[dict[str, Any]]
) -> tuple[bool, str | None]:
    if case.expected == "exact_a":
        return (
            answer == "A",
            None if answer == "A" else "not exact A",
        )
    if case.expected == "exact_add":
        passed = answer == "ADD"
        return (
            passed,
            None if passed else "not exact ADD",
        )
    if case.expected == "one_exec_call_reads_both":
        if len(calls) != 1 or calls[0].get("name") != "exec_command":
            return False, f"expected one exec_command, got {len(calls)} tool calls"
        try:
            arguments = json.loads(calls[0].get("arguments") or "{}")
        except json.JSONDecodeError:
            return False, "invalid tool arguments JSON"
        if not isinstance(arguments, dict) or set(arguments) != {"cmd"}:
            return False, "tool arguments must contain only the cmd field"
        command = arguments["cmd"]
        if not isinstance(command, str):
            return False, "tool cmd must be a string"
        expected = (
            "cat scripts/release_check_m3_random.py tests/test_release_check_random.py"
        )
        passed = command.strip() == expected
        return (
            passed,
            None if passed else "tool command did not read both requested files",
        )
    raise ValueError(f"unknown expectation: {case.expected}")


def run_trial(
    client: httpx.Client,
    endpoint_name: str,
    url: str,
    model: str,
    case: Case,
    repetition: int,
) -> Trial:
    payload: dict[str, Any] = {
        "model": model,
        "input": case.prompt,
        "max_output_tokens": 1024,
        "reasoning": {"effort": "medium"},
    }
    if case.tools:
        payload["tools"] = list(case.tools)
    started = time.perf_counter()
    try:
        response = client.post(f"{url.rstrip('/')}/responses", json=payload)
        response.raise_for_status()
        data = response.json()
        answer, calls = extract_response(data)
        passed, failure = score(case, answer, calls)
        status = str(data.get("status"))
        if status != "completed":
            status_failure = f"endpoint status was {status!r}, not 'completed'"
            failure = f"{status_failure}; {failure}" if failure else status_failure
        usage = data.get("usage") or {}
        details = usage.get("output_tokens_details") or {}
        input_tokens = int(usage.get("input_tokens") or 0)
        output_tokens = int(usage.get("output_tokens") or 0)
        reasoning_tokens = int(details.get("reasoning_tokens") or 0)
    except Exception as exc:
        answer, calls = "", []
        passed = False
        status = "error"
        input_tokens = output_tokens = reasoning_tokens = 0
        failure = f"{type(exc).__name__}: {exc}"
    elapsed = time.perf_counter() - started
    return Trial(
        endpoint=endpoint_name,
        case=case.name,
        repetition=repetition,
        passed=passed and status == "completed",
        status=status,
        latency_seconds=round(elapsed, 3),
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        reasoning_tokens=reasoning_tokens,
        tool_calls=len(calls),
        answer=answer,
        failure=failure,
    )


def parse_endpoint(value: str) -> tuple[str, str, str | None]:
    """Parse NAME=URL[,ENV_VAR] without ever accepting a literal secret."""
    try:
        name, target = value.split("=", 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("endpoint must be NAME=URL[,ENV_VAR]") from exc
    url, separator, env_var = target.rpartition(",")
    if not separator:
        url, env_var = target, None
    if not name or not url:
        raise argparse.ArgumentTypeError("endpoint name and URL are required")
    if env_var is not None and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", env_var):
        raise argparse.ArgumentTypeError(
            "credential suffix must be an environment-variable name"
        )
    parsed_url = urlparse(url)
    if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
        raise argparse.ArgumentTypeError("endpoint URL must be HTTP(S)")
    if env_var is not None and parsed_url.scheme != "https":
        raise argparse.ArgumentTypeError("credentialed endpoints must use HTTPS")
    if (
        parsed_url.username
        or parsed_url.password
        or parsed_url.query
        or parsed_url.fragment
    ):
        raise argparse.ArgumentTypeError(
            "endpoint URL must not contain userinfo, query parameters, or fragments"
        )
    return name, url, env_var


def reject_duplicate_endpoint_names(
    endpoints: list[tuple[str, str, str | None]],
) -> None:
    names = [name for name, _, _ in endpoints]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ValueError(f"duplicate endpoint name(s): {', '.join(duplicates)}")


def summarize(trials: list[Trial]) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for endpoint in sorted({trial.endpoint for trial in trials}):
        selected = [trial for trial in trials if trial.endpoint == endpoint]
        completed = [trial for trial in selected if trial.status == "completed"]
        summary[endpoint] = {
            "passed": sum(trial.passed for trial in selected),
            "trials": len(selected),
            "pass_rate": sum(trial.passed for trial in selected) / len(selected),
            "median_latency_seconds": (
                statistics.median(trial.latency_seconds for trial in completed)
                if completed
                else None
            ),
            "median_output_tokens": (
                statistics.median(trial.output_tokens for trial in completed)
                if completed
                else None
            ),
        }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--endpoint",
        action="append",
        required=True,
        type=parse_endpoint,
        metavar="NAME=URL[,ENV_VAR]",
    )
    parser.add_argument("--model", default="deepseek-v4-flash")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    try:
        reject_duplicate_endpoint_names(args.endpoint)
    except ValueError as exc:
        parser.error(str(exc))

    trials: list[Trial] = []
    for name, url, env_var in args.endpoint:
        headers = {}
        if env_var:
            token = os.environ.get(env_var)
            if not token:
                parser.error("credential environment variable is not set")
            headers["Authorization"] = f"Bearer {token}"
        with httpx.Client(headers=headers, timeout=args.timeout) as client:
            for case in CASES:
                for repetition in range(1, args.repetitions + 1):
                    trial = run_trial(client, name, url, args.model, case, repetition)
                    trials.append(trial)
                    print(json.dumps(asdict(trial), ensure_ascii=False), flush=True)

    report = {
        "trials": [asdict(trial) for trial in trials],
        "summary": summarize(trials),
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps(report, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    print(json.dumps({"summary": report["summary"]}, ensure_ascii=False))
    return 0 if all(trial.passed for trial in trials) else 1


if __name__ == "__main__":
    raise SystemExit(main())
