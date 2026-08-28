# SPDX-License-Identifier: Apache-2.0
"""Contracts for lane-scoped full-CI promotion.

These tests intentionally inspect the workflows: a future cleanup must not
restore the expensive behavior where applying ``full-ci`` changed an
engine-only or Desktop-only PR into an all-product run.
"""

import json
import os
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ENGINE_WORKFLOW = ROOT / ".github/workflows/ci.yml"
DESKTOP_WORKFLOW = ROOT / ".github/workflows/rapid-mac-ci.yml"
LABEL_GATE_WORKFLOW = ROOT / ".github/workflows/full-ci-label-gate.yml"
VERSION_WORKFLOW = ROOT / ".github/workflows/version-check.yml"


def _step_run(workflow: Path, job: str, step_name: str) -> str:
    steps = yaml.safe_load(workflow.read_text())["jobs"][job]["steps"]
    (step,) = [candidate for candidate in steps if candidate.get("name") == step_name]
    return str(step["run"])


def _job(workflow: Path, job: str) -> dict[str, object]:
    return yaml.safe_load(workflow.read_text())["jobs"][job]


def _workflow_strings(workflow: Path) -> dict[str, object]:
    """Keep ``on`` as a string instead of YAML 1.1's boolean True."""
    return yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)


def test_engine_full_ci_still_classifies_the_pr_diff():
    run = _step_run(ENGINE_WORKFLOW, "changes", "Classify validation lanes")
    assert 'git diff --no-renames --name-only "$PR_BASE_SHA" "$GITHUB_SHA"' in run
    assert 'full_gate="$FULL_CI"' in run
    assert 'if [ "$FULL_CI" = true ]' not in run


def test_desktop_full_ci_still_classifies_the_pr_diff():
    run = _step_run(DESKTOP_WORKFLOW, "changes", "Classify desktop lane")
    assert 'git diff --no-renames --name-only "$PR_BASE_SHA" "$GITHUB_SHA"' in run
    assert 'echo "full_gate=$FULL_CI"' in run
    assert '|| [ "$FULL_CI" = true ]' not in run


def test_non_engine_change_exits_before_full_ci_requirement():
    run = _step_run(ENGINE_WORKFLOW, "tests", "Check test results")
    classifier_gate = run.index("needs.changes.result")
    common_gate = run.index("needs.lint.result")
    no_lane = run.index('if [ "$expected" != "true" ]')
    engine_gate = run.index("needs.engine-contracts.result")
    promotion = run.index("needs.changes.outputs.full_gate")
    assert classifier_gate < common_gate < no_lane < engine_gate < promotion


def test_non_desktop_change_exits_before_full_ci_requirement():
    run = _step_run(DESKTOP_WORKFLOW, "desktop-tests", "Check desktop results")
    classifier_gate = run.index("needs.changes.result")
    no_lane = run.index('if [ "$DESKTOP_EXPECTED" != true ]')
    promotion = run.index('if [ "${{ github.event_name }}" = pull_request ]')
    assert classifier_gate < no_lane < promotion


def test_unpromoted_product_aggregates_pass_without_publishing_success():
    for workflow, job_name, result_step in (
        (ENGINE_WORKFLOW, "tests", "Check test results"),
        (DESKTOP_WORKFLOW, "desktop-tests", "Check desktop results"),
    ):
        run = _step_run(workflow, job_name, result_step)
        promotion = run.index("full_gate" if job_name == "tests" else "FULL_GATE")
        unpromoted_branch = run[promotion : run.index("fi", promotion) + 2]
        assert "status remains pending" in unpromoted_branch
        assert "exit 0" in unpromoted_branch
        assert "exit 1" not in unpromoted_branch


def test_internal_product_aggregates_own_pending_to_success_transition():
    for workflow, job_name, lane, context in (
        (ENGINE_WORKFLOW, "tests", "engine", "tests"),
        (DESKTOP_WORKFLOW, "desktop-tests", "desktop", "desktop-tests"),
    ):
        steps = _job(workflow, job_name)["steps"]
        pending = next(
            step
            for step in steps
            if step.get("name") == "Start an internal PR merge status pending"
        )
        settle = next(
            step
            for step in steps
            if step.get("name") == "Settle a successful internal full-CI status"
        )

        pending_condition = str(pending["if"])
        assert f"needs.changes.outputs.{lane} == 'true'" in pending_condition
        assert "head.repo.full_name == github.repository" in pending_condition
        assert "full_gate" not in pending_condition
        assert f'context: "{context}"' in pending["run"]
        assert 'state: "pending"' in pending["run"]

        settle_condition = str(settle["if"])
        assert "needs.changes.outputs.full_gate == 'true'" in settle_condition
        assert "head.repo.full_name == github.repository" in settle_condition
        assert f'context: "{context}"' in settle["run"]
        assert 'state: "success"' in settle["run"]

        permissions = _job(workflow, job_name)["permissions"]
        assert permissions == {
            "actions": "read",
            "contents": "read",
            "pull-requests": "read",
            "statuses": "write",
        }


def _execute_internal_settlement(
    tmp_path: Path,
    *,
    workflow: Path,
    job_name: str,
    full_ci: bool,
    latest_run_id: int,
) -> str | None:
    run = _step_run(workflow, job_name, "Settle a successful internal full-CI status")
    mock_bin = tmp_path / "bin"
    mock_bin.mkdir()
    mock_gh = mock_bin / "gh"
    mock_gh.write_text(
        """#!/bin/bash
set -euo pipefail
case "$*" in
  "api repos/test/repo/pulls/7") cat "$MOCK_PR_JSON" ;;
  *"/actions/workflows/"*"/runs?"*) cat "$MOCK_RUNS_JSON" ;;
  *"--method POST"*) cat > "$MOCK_POST" ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 91 ;;
esac
"""
    )
    mock_gh.chmod(0o755)

    head_sha = "a" * 40
    pr_json = tmp_path / "pr.json"
    pr_json.write_text(
        json.dumps(
            {
                "state": "open",
                "base": {"ref": "main"},
                "head": {"sha": head_sha},
                "labels": [{"name": "full-ci"}] if full_ci else [],
            }
        )
    )
    runs_json = tmp_path / "runs.json"
    runs_json.write_text(json.dumps({"workflow_runs": [{"id": latest_run_id}]}))
    post = tmp_path / "post.json"
    env = os.environ | {
        "GH_TOKEN": "test-token",
        "HEAD_SHA": head_sha,
        "MOCK_POST": str(post),
        "MOCK_PR_JSON": str(pr_json),
        "MOCK_RUNS_JSON": str(runs_json),
        "PATH": f"{mock_bin}:{os.environ['PATH']}",
        "PR_NUMBER": "7",
        "REPO": "test/repo",
        "RUN_ID": "100",
        "RUN_URL": "https://example.invalid/run/100",
        "RUNNER_TEMP": str(tmp_path),
    }
    subprocess.run(["bash", "-c", run], check=True, env=env, capture_output=True)
    return post.read_text() if post.exists() else None


def test_internal_settlement_rejects_removed_label_and_superseded_run(tmp_path):
    for index, (workflow, job_name) in enumerate(
        (
            (ENGINE_WORKFLOW, "tests"),
            (DESKTOP_WORKFLOW, "desktop-tests"),
        )
    ):
        removed = tmp_path / f"removed-{index}"
        removed.mkdir()
        assert (
            _execute_internal_settlement(
                removed,
                workflow=workflow,
                job_name=job_name,
                full_ci=False,
                latest_run_id=100,
            )
            is None
        )

        superseded = tmp_path / f"superseded-{index}"
        superseded.mkdir()
        assert (
            _execute_internal_settlement(
                superseded,
                workflow=workflow,
                job_name=job_name,
                full_ci=True,
                latest_run_id=101,
            )
            is None
        )


def test_internal_settlement_accepts_live_label_on_latest_exact_head(tmp_path):
    for index, (workflow, job_name, context) in enumerate(
        (
            (ENGINE_WORKFLOW, "tests", "tests"),
            (DESKTOP_WORKFLOW, "desktop-tests", "desktop-tests"),
        )
    ):
        lane = tmp_path / f"valid-{index}"
        lane.mkdir()
        posted = _execute_internal_settlement(
            lane,
            workflow=workflow,
            job_name=job_name,
            full_ci=True,
            latest_run_id=100,
        )
        assert posted is not None
        payload = json.loads(posted)
        assert payload["state"] == "success"
        assert payload["context"] == context


def test_metadata_gate_is_trusted_fail_closed_and_never_executes_pr_head():
    workflow = _workflow_strings(LABEL_GATE_WORKFLOW)
    triggers = workflow["on"]
    assert "pull_request_target" in triggers
    assert "workflow_dispatch" in triggers
    assert "workflow_run" in triggers
    assert "pull_request" not in triggers
    assert workflow["permissions"] == {
        "contents": "read",
        "pull-requests": "read",
        "statuses": "write",
    }

    job = workflow["jobs"]["publish-required-statuses"]
    steps = job["steps"]
    assert steps[0]["name"] == "Resolve the live PR and fail closed first"
    resolve = steps[0]["run"]
    assert 'gh api "repos/${REPO}/pulls/${PR_NUMBER}"' in resolve
    assert "post_status tests pending" in resolve
    assert "post_status desktop-tests pending" in resolve
    assert "PR_STATE" in resolve and "BASE_REF" in resolve and "HEAD_SHA" in resolve

    checkout = steps[1]
    assert checkout["name"] == "Check out the trusted policy"
    assert checkout["with"]["ref"] == "${{ steps.pr.outputs.base_sha }}"
    workflow_text = LABEL_GATE_WORKFLOW.read_text()
    assert "pull_request.head.sha" not in checkout["with"]["ref"]
    assert "github.event.pull_request.title" not in workflow_text
    assert "github.event.pull_request.body" not in workflow_text

    classify = steps[2]["run"]
    assert "pulls/${PR_NUMBER}/files" in classify
    assert "scripts/classify_ci_changes.py" in classify

    publish = steps[3]["run"]
    assert 'LIVE_HEAD_SHA" != "$HEAD_SHA' in publish
    assert 'LIVE_FULL_CI" != "$FULL_CI' in publish


def test_metadata_gate_settles_only_live_exact_head_successful_full_ci():
    workflow = _workflow_strings(LABEL_GATE_WORKFLOW)
    settle = workflow["jobs"]["settle-completed-gate"]
    assert settle["if"] == "github.event_name == 'workflow_run'"
    run = settle["steps"][0]["run"]
    assert 'LIVE_HEAD_SHA" != "$RUN_SHA' in run
    assert 'FULL_CI" != true' in run
    assert 'JOB_CONCLUSION" != success' in run
    assert '.conclusion != "cancelled"' in run
    assert 'EVIDENCE_RUN_CONCLUSION" != success' in run
    assert "actions/runs/${EVIDENCE_RUN_ID}/jobs" in run
    assert "actions/workflows/${WORKFLOW_FILE}/runs" in run
    assert 'state: "success"' in run
    assert "statuses/${RUN_SHA}" in run


def _execute_metadata_settlement(
    tmp_path: Path, *, runs: list[tuple[int, str]]
) -> tuple[dict[str, str] | None, str]:
    run = _step_run(
        LABEL_GATE_WORKFLOW,
        "settle-completed-gate",
        "Settle an exact-head full-CI status",
    )
    mock_bin = tmp_path / "bin"
    mock_bin.mkdir()
    mock_gh = mock_bin / "gh"
    mock_gh.write_text(
        """#!/bin/bash
set -euo pipefail
case "$*" in
  "api repos/test/repo/pulls/7") cat "$MOCK_PR_JSON" ;;
  *"/actions/workflows/rapid-mac-ci.yml/runs?"*) cat "$MOCK_RUNS_JSON" ;;
  *"/actions/runs/"*"/jobs?"*) cat "$MOCK_JOBS_JSON" ;;
  *"--method POST"*) cat > "$MOCK_POST" ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 91 ;;
esac
"""
    )
    mock_gh.chmod(0o755)

    head_sha = "b" * 40
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"workflow_run": {"pull_requests": [{"number": 7}]}}))
    pr_json = tmp_path / "mock-pr.json"
    pr_json.write_text(
        json.dumps(
            {
                "state": "open",
                "base": {"ref": "main"},
                "head": {"sha": head_sha},
                "labels": [{"name": "full-ci"}],
            }
        )
    )
    runs_json = tmp_path / "runs.json"
    runs_json.write_text(
        json.dumps(
            {
                "workflow_runs": [
                    {
                        "id": run_id,
                        "head_sha": head_sha,
                        "status": "completed",
                        "conclusion": conclusion,
                        "html_url": f"https://example.invalid/run/{run_id}",
                    }
                    for run_id, conclusion in runs
                ]
            }
        )
    )
    jobs_json = tmp_path / "mock-jobs.json"
    jobs_json.write_text(
        json.dumps([{"jobs": [{"name": "desktop-tests", "conclusion": "success"}]}])
    )
    post = tmp_path / "post.json"
    env = os.environ | {
        "GH_TOKEN": "test-token",
        "GITHUB_EVENT_PATH": str(event),
        "MOCK_JOBS_JSON": str(jobs_json),
        "MOCK_POST": str(post),
        "MOCK_PR_JSON": str(pr_json),
        "MOCK_RUNS_JSON": str(runs_json),
        "PATH": f"{mock_bin}:{os.environ['PATH']}",
        "REPO": "test/repo",
        "RUN_NAME": "rapid-mac CI",
        "RUN_SHA": head_sha,
        "RUNNER_TEMP": str(tmp_path),
        "TRIGGER_RUN_ID": str(max(run_id for run_id, _ in runs)),
    }

    completed = subprocess.run(
        ["bash", "-c", run], check=True, env=env, capture_output=True, text=True
    )
    payload = json.loads(post.read_text()) if post.exists() else None
    return payload, completed.stdout + completed.stderr


def test_metadata_gate_uses_success_before_higher_cancelled_duplicate(tmp_path):
    payload, output = _execute_metadata_settlement(
        tmp_path, runs=[(91, "cancelled"), (90, "success")]
    )
    assert payload is not None, output
    assert payload == {
        "state": "success",
        "context": "desktop-tests",
        "description": "Exact-head full-CI merge gate passed",
        "target_url": "https://example.invalid/run/90",
    }


def test_metadata_gate_does_not_mask_newer_failure_with_older_success(tmp_path):
    payload, output = _execute_metadata_settlement(
        tmp_path,
        runs=[(92, "failure"), (91, "cancelled"), (90, "success")],
    )
    assert payload is None
    assert "evidence_run=92 workflow=failure" in output


def test_all_strict_required_workflows_emit_on_merge_group():
    for workflow in (ENGINE_WORKFLOW, DESKTOP_WORKFLOW, VERSION_WORKFLOW):
        triggers = _workflow_strings(workflow)["on"]
        assert triggers["merge_group"]["types"] == ["checks_requested"]

    version = _workflow_strings(VERSION_WORKFLOW)
    guard = version["jobs"]["version-bump-guard"]
    queue_step = next(
        step
        for step in guard["steps"]
        if step.get("name") == "Pass — PR contract already validated before merge queue"
    )
    assert queue_step["if"] == "github.event_name == 'merge_group'"


def test_gui_golden_job_requires_both_desktop_lane_and_full_promotion():
    condition = str(_job(DESKTOP_WORKFLOW, "gui-golden-flows")["if"])
    assert "needs.changes.outputs.desktop == 'true'" in condition
    assert "needs.changes.outputs.full_gate == 'true'" in condition


def test_engine_only_contracts_are_not_universal_pr_guards():
    universal_steps = {
        step.get("name") for step in _job(ENGINE_WORKFLOW, "lint")["steps"]
    }
    engine_steps = {
        step.get("name") for step in _job(ENGINE_WORKFLOW, "engine-contracts")["steps"]
    }
    assert {
        "GitHub Actions SHA pinning",
        "Workflow expression sanity",
        "Model-management architecture SSOT",
        "Run ruff lint",
        "Run ruff format check",
        "Engine ↔ desktop app version sync",
    } <= universal_steps
    assert {
        "CLI ↔ Config fidelity audit",
        "Release-script offline tests",
        "Installer offline tests",
        "Parser microbench",
    } <= engine_steps
    assert not universal_steps & {
        "CLI ↔ Config fidelity audit",
        "Release-script offline tests",
        "Installer offline tests",
        "Parser microbench",
    }


def test_engine_jobs_follow_fail_closed_engine_classification():
    for job_name in ("engine-contracts", "type-check"):
        job = _job(ENGINE_WORKFLOW, job_name)
        assert job["needs"] == "changes"
        assert str(job["if"]) == "needs.changes.outputs.engine == 'true'"

    bound_guard = _job(ENGINE_WORKFLOW, "mlx-bound-guard")
    assert bound_guard["needs"] == "changes"
    condition = str(bound_guard["if"])
    assert "github.event_name == 'pull_request'" in condition
    assert "needs.changes.outputs.engine == 'true'" in condition


def test_type_check_enforces_shrink_only_error_budget():
    type_check = _job(ENGINE_WORKFLOW, "type-check")
    steps = type_check["steps"]
    ratchet = next(
        step
        for step in steps
        if step.get("name") == "Enforce shrink-only mypy error budget"
    )

    assert "continue-on-error" not in ratchet
    assert ratchet["run"] == "python scripts/check_mypy_error_budget.py"
    install = next(step for step in steps if step.get("name") == "Install dependencies")
    assert "pip install --requirement config/mypy-requirements.txt" in install["run"]
    requirements = (ROOT / "config/mypy-requirements.txt").read_text().splitlines()
    pins = [line for line in requirements if line and not line.startswith("#")]
    assert pins
    assert all("==" in pin for pin in pins)
    assert {pin.split("==", maxsplit=1)[0] for pin in pins} >= {
        "mypy",
        "pydantic",
        "pydantic_core",
        "fastapi",
        "starlette",
        "typing_extensions",
    }
    unit_roster = _step_run(
        ENGINE_WORKFLOW, "test-matrix", "Run unit tests (no MLX required)"
    )
    assert "tests/test_check_mypy_error_budget.py" in unit_roster


def test_combined_platform_job_enforces_changed_lines_coverage_without_baseline():
    test_matrix = _job(ENGINE_WORKFLOW, "test-matrix")
    checkout = next(
        step
        for step in test_matrix["steps"]
        if str(step.get("uses", "")).startswith("actions/checkout@")
    )
    assert checkout["with"]["fetch-depth"] == 0

    gate_job = _job(ENGINE_WORKFLOW, "changed-lines-coverage")
    install = next(
        step
        for step in gate_job["steps"]
        if step.get("name") == "Install coverage tools"
    )
    assert '"diff-cover==8.0.3"' in install["run"]

    gate = next(
        step
        for step in gate_job["steps"]
        if step.get("name") == "Combine coverage and enforce changed lines"
    )
    assert gate["env"] == {"PR_BASE_SHA": "${{ github.event.pull_request.base.sha }}"}
    assert "continue-on-error" not in gate
    assert "coverage combine" in gate["run"]
    assert "coverage-data/linux/coverage-linux-3.11.data" in gate["run"]
    assert "coverage-data/apple/coverage-apple.data" in gate["run"]
    assert "coverage.xml" in gate["run"]
    assert '--compare-branch "$PR_BASE_SHA"' in gate["run"]
    assert "--show-uncovered" in gate["run"]
    assert "--fail-under 100" in gate["run"]
    assert "--cov-fail-under" not in gate["run"]
