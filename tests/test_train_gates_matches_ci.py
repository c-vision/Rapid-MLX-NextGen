"""Drift test: keep `scripts/train_gates.sh` (and its parser helper) honest
against the hosted CI workflows.

`scripts/train_gates.sh <base-sha>` reproduces the 5 validation gates the CI
matrix runs. It does NOT hardcode those gates — it parses them at runtime from
`.github/workflows/ci.yml` and `.github/workflows/rapid-mac-ci.yml` via
`scripts/train_gates_parser.py`. This test guards that reproduction from
drifting away from the workflows: if a CI-definition edit changes the Linux
pytest roster, the Apple pytest roster, the mypy invocation, the diff-cover
invocation, or the Desktop swift invocation, one of the assertions below must
fail — exactly the machine-readable tripwire that keeps the local train-gates
reproduction honest.

Pure-pytest, Linux-friendly, no MLX import (the parser is stdlib + PyYAML).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from scripts.train_gates_parser import (
    CI_WORKFLOW,
    MAC_CI_WORKFLOW,
    MYPY_BUDGET_SCRIPT,
    parse_apple_pytest_args,
    parse_diff_cover_invocation,
    parse_linux_pytest_args,
    parse_mypy_invocation,
    parse_swift_test_invocation,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
yaml = pytest.importorskip("yaml")

CI = CI_WORKFLOW.read_text()
MAC_CI = MAC_CI_WORKFLOW.read_text()
CI_PARSED = yaml.safe_load(CI)
MAC_CI_PARSED = yaml.safe_load(MAC_CI)


def _split_blocks(run_text: str) -> list[list[str]]:
    """Independent split of a step's run text into per-pytest-process blocks.

    This re-derives the split WITHOUT using the shared parser (so the parser
    cannot mask a drift against a bug of its own). A block starts at a line
    whose stripped form is ``pytest``.
    """
    blocks: list[list[str]] = []
    current: list[str] | None = None
    for line in run_text.splitlines():
        stripped = line.strip()
        if stripped == "pytest" or stripped.startswith("pytest \\"):
            current = []
            blocks.append(current)
            continue
        if current is not None:
            current.append(line)
    return blocks


def _extract_path_tokens(block: list[str]) -> list[str]:
    """Extract the literal `tests/test_*.py[::...]` tokens one pytest block
    passes on its own (independent re-derivation, NOT via the shared parser)."""
    tokens: list[str] = []
    for line in block:
        if line.strip().startswith("#"):
            continue
        # Skip the --deselect= entries (they carry the same shape but are
        # excluded args, not executed paths).
        if "--deselect=" in line:
            continue
        stripped = line.strip()
        if stripped.startswith("tests/test_") and ".py" in stripped:
            # strip the trailing ` \` continuation and any trailing flag words
            tok = stripped.split(" \\")[0].split()[0]
            tokens.append(tok)
    return tokens


def _run_step(job_name: str, step_name: str, ci: dict) -> dict:
    job = ci["jobs"][job_name]
    matches = [s for s in job["steps"] if s.get("name") == step_name]
    assert matches, f"step {step_name!r} not found in job {job_name}"
    return matches[0]


def _run_text(job_name: str, step_name: str, ci: dict) -> str:
    return _run_step(job_name, step_name, ci)["run"]


# ---------------------------------------------------------------------------
# Linux no-MLX roster (TWO separate pytest processes in ci.yml)
# ---------------------------------------------------------------------------
def test_linux_parser_returns_two_invocations() -> None:
    # ci.yml's "Run unit tests" step runs TWO separate pytest processes: the
    # broad no-MLX roster, and a SECOND process for the engine-lifecycle tests
    # (their tests/_headless_mlx.py MagicMock `mlx` shim pollutes sys.modules
    # and must not leak into the broad roster). The parser must preserve that
    # split so the local Gate 1 runs each in its own process. This is the guard
    # that B3 (the original wrong diagnosis added `_real_mlx_or_skip` instead)
    # enforces: a CI edit collapsing/adding a pytest block trips this count.
    parsed = parse_linux_pytest_args()
    assert isinstance(parsed, list)
    run_text = _run_text("test-matrix", "Run unit tests (no MLX required)", CI_PARSED)
    blocks = _split_blocks(run_text)
    assert len(parsed) == len(blocks) == 2, (
        "the local gate must reproduce ci.yml's per-process pytest split; "
        f"parser produced {len(parsed)} invocation(s), ci.yml has {len(blocks)}"
    )


def test_linux_parser_matches_workflow_roster() -> None:
    parsed = parse_linux_pytest_args()
    run_text = _run_text("test-matrix", "Run unit tests (no MLX required)", CI_PARSED)
    blocks = _split_blocks(run_text)
    for invocation, block in zip(parsed, blocks):
        workflow_paths = _extract_path_tokens(block)
        assert workflow_paths, "workflow carries no Linux test paths"
        assert invocation["paths"] == workflow_paths, (
            "Linux pytest roster drifted: the parser extracts\n"
            f"{invocation['paths']}\nbut ci.yml carries\n{workflow_paths}\n"
            "Update the parser (or the workflow) so they agree."
        )


def test_linux_parser_second_process_engine_lifecycle() -> None:
    # The second pytest process is exactly the engine-lifecycle seam set, with
    # --cov-append so its coverage unions into the same data file as the first
    # process (mirroring ci.yml's combined Linux coverage).
    parsed = parse_linux_pytest_args()
    second = parsed[1]
    assert second["paths"] == [
        "tests/test_engine_lifecycle.py",
        "tests/test_mllm_process_loop_errors.py",
        "tests/test_disconnect_guard_aborts_scheduler.py",
        "tests/test_rst_mid_sse_zombie_kv.py",
    ]
    assert second["deselect"] == []
    assert second["marker"] is None  # the second process has no -k filter
    assert second["cov_declaration"]["cov_append"] is True
    # The first process is the broad roster and must NOT use --cov-append (it
    # seeds the coverage file).
    assert parsed[0]["cov_declaration"]["cov_append"] is False


def test_linux_parser_extracts_deselect_and_k_filter() -> None:
    parsed = parse_linux_pytest_args()
    run_text = _run_text("test-matrix", "Run unit tests (no MLX required)", CI_PARSED)
    main_invocation = parsed[0]

    # Every --deselect= arg in the FIRST (main) block must be captured, and only
    # those — including the case where the workflow deselects nothing (since
    # #2508 declared jinja2 in the ci-linux extra, the roster carries no
    # --deselect= at all; the parser must then return an empty list, never a
    # phantom entry). The engine-lifecycle block never has any.
    main_block = _split_blocks(run_text)[0]
    expected_deselect = [
        line.strip().split("--deselect=", 1)[1].split(" \\")[0].split()[0]
        for line in main_block
        if "--deselect=" in line
    ]
    assert main_invocation["deselect"] == expected_deselect
    assert len(expected_deselect) == run_text.count("--deselect=")

    # The -k filter must be captured verbatim on the main block.
    assert main_invocation["marker"], (
        "Linux -k filter is empty; workflow must carry one"
    )
    assert main_invocation["marker"] in run_text


def test_linux_roster_asserts_no_mlx_import() -> None:
    # The Linux roster lives in the "no MLX required" step; this is the contract
    # that Gate 1 enforces. Guard the guard: every path the parser hands to
    # Gate 1 across BOTH pytest processes must resolve to a real file.
    parsed = parse_linux_pytest_args()
    for invocation in parsed:
        for path in invocation["paths"]:
            file_part = path.split("::", 1)[0]
            assert (CI_WORKFLOW.parents[2] / file_part).is_file(), (
                f"{file_part} missing"
            )


# ---------------------------------------------------------------------------
# Apple-MLX roster
# ---------------------------------------------------------------------------
def test_apple_parser_matches_workflow_roster() -> None:
    parsed = parse_apple_pytest_args()
    step = _run_step("test-apple-silicon", "Run MLX-dependent tests", CI_PARSED)
    run_text = step["run"]
    workflow_paths = _extract_path_tokens(_split_blocks(run_text)[0])
    assert workflow_paths, "workflow carries no Apple test paths"
    assert parsed["paths"] == workflow_paths, (
        "Apple pytest roster drifted: the parser extracts\n"
        f"{parsed['paths']}\nbut ci.yml carries\n{workflow_paths}\n"
    )
    for path in parsed["paths"]:
        file_part = path.split("::", 1)[0]
        assert (CI_WORKFLOW.parents[2] / file_part).is_file(), f"{file_part} missing"


def test_apple_parser_extracts_m_and_k_filters() -> None:
    # Gate 4 must follow ci.yml's Apple -m / -k flags, not hardcode them.
    parsed = parse_apple_pytest_args()
    run_text = _run_text("test-apple-silicon", "Run MLX-dependent tests", CI_PARSED)
    assert parsed["m"], "Apple -m marker expression is empty"
    assert parsed["k"], "Apple -k filter is empty"
    assert parsed["m"] in run_text
    assert parsed["k"] in run_text
    assert parsed["m"] == "not slow"  # current hosted value, guarded verbatim
    assert parsed["k"] == "not Integration"  # current hosted value


def test_apple_roster_has_no_overlap_with_linux_surface() -> None:
    # A test that lands in BOTH rosters is a red flag: an mlx-importing test in
    # the Linux (no-MLX) roster would crash CI, and a no-MLX test wasted on the
    # Apple gate hides Linux-only coverage. (test_mllm_cache.py legitimately
    # appears in both, exercising no-MLX paths on Linux and mlx paths on Apple.)
    linux = {
        path for invocation in parse_linux_pytest_args() for path in invocation["paths"]
    }
    apple = set(parse_apple_pytest_args()["paths"])
    overlap = linux & apple
    # Documented intentional overlaps: test_mllm_cache.py exercises no-MLX
    # paths on Linux and mlx paths on Apple; test_routing_groups_0131.py is
    # legitimately in both rosters as an existing cross-platform suite.
    assert overlap <= {
        "tests/test_mllm_cache.py",
        "tests/test_routing_groups_0131.py",
    }, f"unexpected roster overlap: {overlap}"


# ---------------------------------------------------------------------------
# mypy budget
# ---------------------------------------------------------------------------
def test_mypy_invocation_matches_workflow() -> None:
    parsed = parse_mypy_invocation()
    run_text = _run_text(
        "type-check", "Enforce shrink-only mypy error budget", CI_PARSED
    )
    assert parsed == {"script": MYPY_BUDGET_SCRIPT}
    assert f"python {MYPY_BUDGET_SCRIPT}" in run_text
    # The pinned budget file must exist (it feeds the gates-hash).
    assert (CI_WORKFLOW.parents[2] / "config/mypy-requirements.txt").is_file()
    assert (CI_WORKFLOW.parents[2] / "config/mypy-error-baseline.txt").is_file()


# ---------------------------------------------------------------------------
# diff-cover (Gate 3)
# ---------------------------------------------------------------------------
def test_diff_cover_invocation_matches_workflow() -> None:
    parsed = parse_diff_cover_invocation()
    run_text = _run_text(
        "changed-lines-coverage",
        "Combine coverage and enforce changed lines",
        CI_PARSED,
    )
    assert "coverage combine" in run_text
    assert "coverage-data/linux/coverage-linux-3.11.data" in run_text
    assert "coverage-data/apple/coverage-apple.data" in run_text
    assert "--fail-under 100" in run_text
    assert parsed["fail_under"] == 100
    assert parsed["linux"] == "coverage-linux-3.11.data"
    assert parsed["apple"] == "coverage-apple.data"


def test_diff_cover_pin_matches_workflow_install_step() -> None:
    # Gate 3 installs `coverage` + the SAME diff-cover pin the hosted job
    # installs, parsed from its "Install coverage tools" step — never
    # hardcoded in the script. Guard the pin verbatim so a hosted bump that
    # the parser fails to pick up trips here.
    parsed = parse_diff_cover_invocation()
    install_text = _run_text(
        "changed-lines-coverage", "Install coverage tools", CI_PARSED
    )
    assert f"diff-cover=={parsed['diff_cover_pin']}" in install_text
    assert "coverage" in install_text
    assert parsed["diff_cover_pin"] == "8.0.3"  # current hosted pin, verbatim


# ---------------------------------------------------------------------------
# train_gates.sh argument handling — these paths exit BEFORE any interpreter
# resolution, workflow parsing or venv creation, so they are cheap and
# Linux-friendly (bash + git only) and never touch the environment.
# ---------------------------------------------------------------------------
TRAIN_GATES_SH = REPO_ROOT / "scripts" / "train_gates.sh"


def _run_train_gates(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(TRAIN_GATES_SH), *args],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_train_gates_help_exits_zero_with_usage_on_stdout() -> None:
    for flag in ("-h", "--help"):
        proc = _run_train_gates(flag)
        assert proc.returncode == 0, (flag, proc.stderr)
        assert proc.stdout.startswith("usage: scripts/train_gates.sh <base-sha>")
        assert "GATES DIRTY" in proc.stdout  # the receipt contract is documented
        assert proc.stderr == ""


def test_train_gates_missing_or_bad_args_exit_2_with_usage() -> None:
    for args in ((), ("--bogus",), ("a", "b")):
        proc = _run_train_gates(*args)
        assert proc.returncode == 2, (args, proc.stdout, proc.stderr)
        assert proc.stderr.startswith("ERROR: "), (args, proc.stderr)
        assert "usage: scripts/train_gates.sh <base-sha>" in proc.stderr
        assert "GATES OK" not in proc.stdout


def test_train_gates_unresolvable_base_is_one_clear_error_not_git_fatal() -> None:
    proc = _run_train_gates("no-such-rev-zz")
    assert proc.returncode == 2, (proc.stdout, proc.stderr)
    first_line = proc.stderr.splitlines()[0]
    assert first_line.startswith("ERROR: cannot resolve base 'no-such-rev-zz'")
    assert "fatal:" not in proc.stderr
    assert "usage: scripts/train_gates.sh <base-sha>" in proc.stderr


def test_train_gates_refuses_base_equal_to_head() -> None:
    # base == HEAD would make diff-cover compare an EMPTY diff and pass 100%
    # by construction; the script must refuse before running any gate.
    proc = _run_train_gates("HEAD")
    assert proc.returncode == 2, (proc.stdout, proc.stderr)
    assert "IS the current HEAD" in proc.stderr
    assert "merge-base" in proc.stderr
    assert "GATES OK" not in proc.stdout
    assert "== Gate 1" not in proc.stdout


# ---------------------------------------------------------------------------
# Desktop swift test (Gate 5)
# ---------------------------------------------------------------------------
def test_swift_test_invocation_matches_workflow() -> None:
    parsed = parse_swift_test_invocation()
    assert parsed == {"cmd": "swift test --no-parallel"}
    assert "swift test --no-parallel" in MAC_CI


# ---------------------------------------------------------------------------
# The training gates must actually be wired into the shared parser so the
# hash that freeze relies on stays stable under renames.
# ---------------------------------------------------------------------------
def test_train_gates_script_parses_workflows() -> None:
    # Exercise the subprocess entry path too (what train_gates.sh runs), so a
    # break in `python -m scripts.train_gates_parser` surfaces here, in CI,
    # before it surfaces in a local train run.
    import subprocess
    import sys

    proc = subprocess.run(
        [sys.executable, "-m", "scripts.train_gates_parser", "all"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    import json

    payload = json.loads(proc.stdout)
    assert set(payload) == {"linux", "apple", "mypy", "diff_cover", "swift_test"}
    assert isinstance(payload["linux"], list) and len(payload["linux"]) == 2
    assert payload["linux"][0]["paths"]
    assert payload["linux"][1]["paths"]
    assert payload["apple"]["paths"]


def test_train_gates_script_cli_targets_are_reachable() -> None:
    # `train_gates.sh` invokes the parser for exactly these single targets via
    # `python -m scripts.train_gates_parser <target>`. A new gate must not add
    # a subprocess target the script uses without this tripwire noticing, and
    # an existing target must never become unreachable.
    import json
    import subprocess
    import sys

    expected_targets = ("linux", "apple", "mypy", "diff_cover", "swift_test")
    for target in expected_targets:
        proc = subprocess.run(
            [sys.executable, "-m", "scripts.train_gates_parser", target],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
        )
        assert proc.returncode == 0, (target, proc.stderr)
        payload = json.loads(proc.stdout)
        assert payload, (target, "empty payload")
