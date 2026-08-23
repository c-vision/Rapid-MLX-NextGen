# Path-aware PR gates and merge queue

Rapid-MLX uses two validation levels so concurrent pull requests do not each
pay the full release-grade macOS cost.

## PR gate

`scripts/classify_ci_changes.py` assigns changed paths to the engine and desktop
lanes. The policy fails closed: an empty diff, workflow change, or unknown
product area selects all applicable lanes.

- Engine changes run the Linux test matrix, the Apple Silicon test suite, and
  one representative L1 model (`qwen3.5-4b-4bit`).
- Desktop changes run the Swift build/test and the inexpensive GUI harness
  contracts. They do not run engine model smokes.
- Documentation-only changes run the common lightweight checks and stable
  aggregate jobs, without allocating a macOS runner.

The required checks are the stable aggregate jobs `tests` and `desktop-tests`.
They must not be renamed or hidden behind workflow-level path filters without a
matching branch-protection migration. `tests` includes lint, type-check job
health, the MLX dependency-bound guard on pull requests, and all selected engine
test lanes; `desktop-tests` includes every selected Desktop lane.

## Merge gate

Adding the `full-ci` label upgrades the lanes selected by the pull request's
actual diff. Apply it only when the PR is ready to merge; removing it returns
subsequent commits to the path-aware PR gate.

- Engine changes expand to the full five-model L1 matrix.
- Desktop changes expand to the complete GUI golden-flow job.
- Cross-cutting or unknown changes expand both lanes.
- Documentation-only changes require neither product lane and do not need the
  label.

The label never changes lane classification. This prevents an engine-only PR
from allocating the full Desktop gate, or a Desktop-only PR from allocating
the full model gate. The selected product aggregate intentionally remains
non-successful until the label is present, so branch protection cannot bypass
its merge gate.

The workflows also subscribe to GitHub's `merge_group` event. After the
repository becomes eligible for GitHub merge queues, every queue candidate will
automatically receive the same full coverage against its synthetic candidate
commit. This validates the combined state that will actually reach `main`,
rather than repeatedly validating each PR against an obsolete base.

Pushes to `main` retain the full engine coverage as a post-merge signal.

## Repository configuration

GitHub currently offers merge queues only to public repositories owned by an
organization, or private repositories owned by an Enterprise Cloud
organization. Rapid-MLX is a public repository owned by a personal account, so
the queue cannot be enabled until ownership moves to an organization.

After that eligibility change, and after the workflows containing
`merge_group` support are present on `main`:

1. Require `tests` and `desktop-tests` for `main`.
2. Require branches to be up to date through the merge queue, rather than
   asking authors or agents to rebase every open PR after each merge.
3. Use squash as the merge method and start with a small queue batch. Increase
   batching only after observing queue latency and failure isolation.

Do not enable the queue before the workflow trigger reaches `main`: otherwise
GitHub creates a merge-group commit whose required checks never start.

## Rollback

Disable the merge queue first, restore `full-ci` label-based merging, and leave
the `merge_group` triggers in place. The triggers are harmless while the queue
is disabled. If path classification is suspect, make its policy select both
lanes for every PR; this restores the previous validation coverage without
renaming required checks.
