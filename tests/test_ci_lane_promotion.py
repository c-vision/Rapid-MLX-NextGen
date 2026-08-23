# SPDX-License-Identifier: Apache-2.0
"""Contracts for lane-scoped full-CI promotion.

These tests intentionally inspect the workflows: a future cleanup must not
restore the expensive behavior where applying ``full-ci`` changed an
engine-only or Desktop-only PR into an all-product run.
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ENGINE_WORKFLOW = ROOT / ".github/workflows/ci.yml"
DESKTOP_WORKFLOW = ROOT / ".github/workflows/rapid-mac-ci.yml"


def _step_run(workflow: Path, job: str, step_name: str) -> str:
    steps = yaml.safe_load(workflow.read_text())["jobs"][job]["steps"]
    (step,) = [candidate for candidate in steps if candidate.get("name") == step_name]
    return str(step["run"])


def _job(workflow: Path, job: str) -> dict[str, object]:
    return yaml.safe_load(workflow.read_text())["jobs"][job]


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
    common_gate = run.index("needs.lint.result")
    no_lane = run.index('if [ "$expected" != "true" ]')
    promotion = run.index("needs.changes.outputs.full_gate")
    assert common_gate < no_lane < promotion


def test_non_desktop_change_exits_before_full_ci_requirement():
    run = _step_run(DESKTOP_WORKFLOW, "desktop-tests", "Check desktop results")
    no_lane = run.index('if [ "$DESKTOP_EXPECTED" != true ]')
    promotion = run.index('if [ "${{ github.event_name }}" = pull_request ]')
    assert no_lane < promotion


def test_gui_golden_job_requires_both_desktop_lane_and_full_promotion():
    condition = str(_job(DESKTOP_WORKFLOW, "gui-golden-flows")["if"])
    assert "needs.changes.outputs.desktop == 'true'" in condition
    assert "needs.changes.outputs.full_gate == 'true'" in condition
