import argparse
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "scripts" / "deepseek_engine_ab.py"
SPEC = importlib.util.spec_from_file_location("deepseek_engine_ab", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def test_extract_response_collects_text_and_calls():
    answer, calls = MODULE.extract_response(
        {
            "output": [
                {"type": "reasoning", "content": []},
                {
                    "type": "function_call",
                    "name": "exec_command",
                    "arguments": '{"cmd":"rg foo a.py b.py"}',
                },
                {
                    "type": "message",
                    "content": [{"type": "output_text", "text": "done"}],
                },
            ]
        }
    )
    assert answer == "done"
    assert len(calls) == 1


def test_score_bounded_inspection_requires_one_call_with_both_paths():
    case = MODULE.CASES[0]
    call = {
        "name": "exec_command",
        "arguments": json.dumps(
            {
                "cmd": "cat scripts/release_check_m3_random.py "
                "tests/test_release_check_random.py"
            }
        ),
    }
    assert MODULE.score(case, "", [call]) == (True, None)
    passed, failure = MODULE.score(case, "", [call, call])
    assert not passed
    assert "one exec_command" in failure


def test_score_bounded_inspection_rejects_non_reading_path_mentions():
    case = MODULE.CASES[0]
    for command in (
        "echo scripts/release_check_m3_random.py tests/test_release_check_random.py",
        "cat placeholder.py # scripts/release_check_m3_random.py "
        "tests/test_release_check_random.py",
        "cat scripts/release_check_m3_random.py "
        "tests/test_release_check_random.py > /tmp/copied",
        "sed -i '' -e 's/x/y/' scripts/release_check_m3_random.py "
        "tests/test_release_check_random.py",
    ):
        call = {
            "name": "exec_command",
            "arguments": json.dumps({"cmd": command}),
        }
        assert not MODULE.score(case, "", [call])[0]
    malformed = {
        "name": "exec_command",
        "arguments": json.dumps(
            {
                "cmd": "cat scripts/release_check_m3_random.py "
                "tests/test_release_check_random.py",
                "extra": "not allowed",
            }
        ),
    }
    assert not MODULE.score(case, "", [malformed])[0]


def test_score_review_is_exact():
    case = MODULE.CASES[1]
    assert MODULE.score(case, "A", []) == (True, None)
    assert MODULE.score(case, "Candidate A", [])[0] is False


def test_score_recovery_requires_exact_contract():
    case = MODULE.CASES[2]
    assert MODULE.score(case, "ADD", [])[0]
    for answer in (
        "Do not add g12_eligible to the schema.",
        "Delete g12_eligible from the schema.",
        "Exclude g12_eligible from the schema.",
    ):
        assert not MODULE.score(case, answer, [])[0]


def test_run_trial_reports_incomplete_status():
    case = MODULE.CASES[1]
    response = type(
        "Response",
        (),
        {
            "raise_for_status": lambda self: None,
            "json": lambda self: {
                "status": "incomplete",
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": "A"}],
                    }
                ],
            },
        },
    )()
    client = type("Client", (), {"post": lambda self, *args, **kwargs: response})()
    trial = MODULE.run_trial(client, "local", "http://test/v1", "model", case, 1)
    assert not trial.passed
    assert trial.failure == "endpoint status was 'incomplete', not 'completed'"


def test_run_trial_records_transport_failure():
    class BrokenClient:
        def post(self, *args, **kwargs):
            raise RuntimeError("endpoint unavailable")

    trial = MODULE.run_trial(
        BrokenClient(), "local", "http://test/v1", "model", MODULE.CASES[0], 1
    )
    assert not trial.passed
    assert trial.status == "error"
    assert trial.failure == "RuntimeError: endpoint unavailable"


def test_run_trial_records_malformed_usage():
    response = type(
        "Response",
        (),
        {
            "raise_for_status": lambda self: None,
            "json": lambda self: {
                "status": "completed",
                "output": [],
                "usage": {"input_tokens": "not-a-number"},
            },
        },
    )()
    client = type("Client", (), {"post": lambda self, *args, **kwargs: response})()
    trial = MODULE.run_trial(
        client, "local", "http://test/v1", "model", MODULE.CASES[0], 1
    )
    assert trial.status == "error"
    assert trial.input_tokens == 0
    assert trial.failure.startswith("ValueError:")


def test_duplicate_endpoint_names_are_rejected():
    try:
        MODULE.reject_duplicate_endpoint_names(
            [("local", "http://one", None), ("local", "http://two", None)]
        )
    except ValueError as exc:
        assert "duplicate endpoint" in str(exc)
    else:
        raise AssertionError("expected duplicate endpoints to fail")


def test_parse_endpoint_uses_environment_variable_name():
    assert MODULE.parse_endpoint("cloud=https://example.test/v1,CLOUD_KEY") == (
        "cloud",
        "https://example.test/v1",
        "CLOUD_KEY",
    )


def test_parse_endpoint_rejects_literal_credential_suffix():
    try:
        MODULE.parse_endpoint("cloud=https://example.test/v1,not-a-valid-env-name")
    except argparse.ArgumentTypeError as exc:
        assert "environment-variable name" in str(exc)
        assert "not-a-valid" not in str(exc)
    else:
        raise AssertionError("expected literal credential suffix to fail")
    try:
        MODULE.parse_endpoint("cloud=http://example.test/v1,CLOUD_KEY")
    except argparse.ArgumentTypeError as exc:
        assert "HTTPS" in str(exc)
    else:
        raise AssertionError("expected plaintext credential endpoint to fail")
    for unsafe in (
        "https://user:secret@example.test/v1",
        "https://example.test/v1?api_key=secret",
        "https://example.test/v1#secret",
    ):
        try:
            MODULE.parse_endpoint(f"cloud={unsafe}")
        except argparse.ArgumentTypeError as exc:
            assert "must not contain" in str(exc)
        else:
            raise AssertionError("expected credential-bearing URL to fail")


def test_summary_excludes_error_latency_from_median():
    completed = MODULE.Trial(
        "local", "case", 1, True, "completed", 10.0, 1, 1, 0, 0, "NO"
    )
    failed = MODULE.Trial(
        "local", "case", 2, False, "error", 0.01, 0, 0, 0, 0, "", "timeout"
    )
    summary = MODULE.summarize([completed, failed])["local"]
    assert summary["median_latency_seconds"] == 10.0
    assert summary["median_output_tokens"] == 1
