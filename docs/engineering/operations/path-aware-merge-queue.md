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
- Documentation-only changes run universal repository guards and stable
  aggregate jobs, without allocating an engine, type-check, MLX-bound, model,
  or macOS runner. Universal guards retain workflow-expression, immutable
  Action-pin, and architecture-SSOT checks.

Engine classification includes the serving packages and their tests, scripts,
examples, evaluations, benchmark inputs/results, regression harness, and
engine-only type-check configuration. These paths must not allocate Desktop or
GUI runners merely because they live outside the primary Python package.

Engine-only contracts are admitted by the same fail-closed classifier as the
engine test lanes. They include CLI/config fidelity, release and installer
offline tests, and the parser microbenchmark. Desktop-only and
documentation-only changes do not pay for those engine-specific dependencies
and commands. Whole-repository Ruff and engine/Desktop version synchronization
remain universal because Desktop support code includes Python and either side
of the shared version contract may change.

The strict required checks are the stable aggregate jobs `tests`,
`desktop-tests`, and `version-bump-guard`. They must not be renamed or hidden
behind workflow-level path filters without a matching branch-protection
migration. `tests` includes lint, type-check job health, the MLX
dependency-bound guard on pull requests, and all selected engine test lanes;
`desktop-tests` includes every selected Desktop lane. `version-bump-guard`
runs for every pull request, passing quickly when the version is unchanged.

### Type-error budget

Engine changes run a shrink-only mypy debt ratchet. The checked-in
`config/mypy-error-baseline.txt` records the current error count for each dirty
file under the fully pinned Python 3.11 environment in
`config/mypy-requirements.txt`. A new dirty file or an increase in any file's
count blocks `tests`. When fixes reduce a count or clean a file completely, CI
also blocks until the baseline is tightened with:

```bash
python scripts/check_mypy_error_budget.py --update
```

`--update` refuses growth and new dirty files, so it cannot be used as a casual
bypass. The budget intentionally does not claim semantic identity for individual
diagnostics: replacing one error with another while a dirty file's total stays
flat is outside this first ratchet. This keeps the gate deterministic despite
moving line numbers and messages while preventing debt from spreading or
growing. As dirty files are repaired and removed from the baseline, they can
never become dirty again without failing CI.

### Changed-lines coverage

Engine pull requests enforce 100% coverage for executable lines newly added or
modified under `vllm_mlx/`. The Python 3.11 Linux unit-test leg already produces
`coverage.xml`; `diff-cover` compares that report with the pull request's
immutable base SHA and blocks the stable `tests` aggregate when a measurable
changed line was not exercised. Comments, blank lines, deletions, tests, docs,
and unchanged production lines do not enter the score.

This is a new-debt ratchet, not a whole-repository percentage target. Existing
uncovered code remains grandfathered until a pull request changes its executable
lines, so ordinary feature and bug-fix work is not required to repair unrelated
historical coverage debt. A production change that cannot run on the Linux lane
must expose its behavior through a Linux-testable boundary or extend the coverage
gate to consume trustworthy evidence from the relevant required lane; lowering
the threshold is not the normal escape hatch.

## Merge gate

Adding the `full-ci` label upgrades the lanes selected by the pull request's
actual diff. Apply it only when the PR is ready to merge; removing it returns
subsequent commits to the path-aware PR gate.

- Engine changes expand to the full five-model L1 matrix.
- Desktop changes build the release GUI once, then run every journey group
  mapped to the changed controls and product sources in
  `Tests/GUIGoldenFlows/journeys.yaml`.
- Cross-cutting or unknown changes expand both lanes.
- Documentation-only changes require neither product lane and do not need the
  label.

GUI routing expands a changed source to its complete journey group, so sibling
flows around the same user workflow remain covered. It fails closed: empty or
invalid diffs, new unmapped Desktop paths, shared UI components, packaging
inputs, the harness, its manifest, and the CI workflow select every PR journey.
Broad mixed-responsibility directories such as `Sources/Rapid/UI/` never grant
narrow ownership to a new file; that requires an explicit file or cohesive
domain-directory mapping in the manifest.
Each named workflow step remains visible but an unselected journey exits before
preflight, app launch, or artifact creation. The final verdict requires exactly
the number of result records selected by the classifier, so a selected journey
cannot silently disappear.

The label never changes lane classification. This prevents an engine-only PR
from allocating the full Desktop gate, or a Desktop-only PR from allocating
the full model gate.

### Pending, not failing, before promotion

An unpromoted product PR is a waiting release candidate, not a test failure.
The aggregate Action check therefore passes after its inexpensive PR checks,
while `.github/workflows/full-ci-label-gate.yml` publishes a same-name pending
commit status for each selected product lane. GitHub requires both a check run
and a commit status when they share a required name, so the pending status keeps
the merge blocked without showing a false red failure.

The status transition is fail closed:

1. A trusted `pull_request_target` workflow reads the live PR and immediately
   posts pending `tests` and `desktop-tests` statuses before classification.
2. It checks out only the base revision of the policy and classifies filenames
   obtained from the GitHub API. It never checks out or executes the PR head.
3. An unselected lane becomes successful immediately. A selected lane remains
   pending both before and after the `full-ci` label is applied.
4. Only a successful exact-head full-CI aggregate may replace that selected
   lane's pending status with success. The aggregate job settles same-repository
   PRs directly; a trusted `workflow_run` completion hook settles fork PRs.
5. A stale SHA, removed label, superseded exact-head run, failed/cancelled
   workflow, missing aggregate job, classifier failure, or metadata mismatch
   leaves the status pending.

Do not replace this with a job-level `if` condition. GitHub reports a skipped
job as successful, which would allow a required skipped context to bypass the
promotion gate. Do not publish success when the label is observed: doing so
would briefly reuse old exact-SHA check evidence during label churn.

All three required workflows subscribe to GitHub's `merge_group` event. Every
queue candidate will therefore receive `tests`, `desktop-tests`, and
`version-bump-guard` on its synthetic candidate commit. Product workflows run
full combined-tree coverage for merge groups. The version guard emits its
stable context because the individual PR contract was already validated before
queue entry. This validates the state that will actually reach `main`, rather
than repeatedly validating each PR against an obsolete base.

Pushes to `main` retain the full engine coverage as a post-merge signal.

### Desktop GUI artifact provenance

The full Desktop gate builds one release-configured app with
`SKIP_SIDECAR=1`, packages it, and uploads it under an artifact name containing
the exact candidate SHA. Selected manifest journey groups run as independent
matrix shards and reuse that artifact; GUI jobs do not rebuild the app. Before
extraction, they verify a versioned manifest that binds the SHA, build mode,
sidecar mode, archive filename, and SHA-256 digest; after extraction they
verify the macOS code-signing seal. Missing, stale, malformed, or modified
artifacts fail closed.

The classifier emits the matrix from the same journey SSOT used for routing.
Each selected flow appears in exactly one group shard. Matrix fail-fast is
disabled so one failure cannot cancel evidence from sibling groups, while the
stable `desktop-tests` facade remains red unless every selected shard passes.
Hosted-runner isolation gives every shard a separate HOME, defaults database,
ports, app processes, and result directory. Failure artifact names include the
group so concurrent uploads cannot overwrite one another.

This artifact is test-only and retained for one day. It is not signed for
distribution, notarized, published, or eligible for release promotion. Release
workflows continue to build their own Developer-ID-signed artifact with the
bundled sidecar and release credentials.

## Repository configuration

GitHub currently offers merge queues only to public repositories owned by an
organization, or private repositories owned by an Enterprise Cloud
organization. Rapid-MLX is a public repository owned by a personal account, so
the queue cannot be enabled until ownership moves to an organization.

The current `main` protection is strict and requires three GitHub Actions
contexts from app id `15368`: `tests`, `desktop-tests`, and
`version-bump-guard`. There are no repository rulesets. Keep that protection
unchanged until the owner enables a queue.

After ownership moves to an eligible organization and these workflows are on
the default branch, the owner should enable **Require merge queue** in the
existing non-wildcard `main` branch-protection rule and configure:

- merge queue required and squash as the allowed merge method;
- required status checks `tests`, `desktop-tests`, and `version-bump-guard`;
- the existing strict status-check policy retained; the queue candidate
  provides the up-to-date combined tree without repeated author rebases;
- build concurrency `1` initially;
- merge only non-failing entries enabled;
- status-check timeout `60 minutes`;
- minimum and maximum merge group size `1`, with a `0` minute minimum wait.

After five consecutive green merge groups, increase maximum group size to `3`
and use a `5` minute wait to amortize busy integration trains. Keep concurrency
at `1` until failure attribution and runner capacity are demonstrated at that
batch size.

Before changing `main`, rehearse on a scratch target branch in an eligible
organization-owned repository:

1. Create the scratch branch from the intended `main` SHA and temporarily add
   that branch to all three workflows' event filters in the sandbox only.
2. Apply the exact required contexts and queue settings above to the scratch
   branch.
3. Queue one documentation-only PR and one harmless cross-cutting workflow PR.
   Confirm all three contexts appear on both synthetic merge-group SHAs, and
   confirm the cross-cutting PR runs both product lanes.
4. Queue two PRs concurrently. Confirm strict protection groups or restacks
   them without direct pushes, and that deliberately failing the second PR
   removes only its group.
5. Remove the sandbox changes and record run URLs before applying the settings
   to `main`.

A hosted scratch rehearsal cannot be performed in the current personal-account
repository because GitHub does not expose merge queues there. Local event
fixtures and workflow contract tests verify the `merge_group` wiring now; the
organization-owned scratch rehearsal above remains a hard prerequisite to the
owner's production configuration change.

Do not enable the queue before every required workflow trigger reaches `main`:
otherwise GitHub creates a merge-group commit whose required check remains
`Expected` forever. Treat an indefinitely expected
`version-bump-guard` as a trigger defect and stop; never bypass the required
context.

## Rollback

Disable the merge queue first, restore `full-ci` label-based merging, and leave
the `merge_group` triggers in place. The triggers are harmless while the queue
is disabled. If path classification is suspect, make its policy select both
lanes for every PR; this restores the previous validation coverage without
renaming required checks. For GUI routing specifically, removing the
`GUI_FLOWS` job environment or making `scripts/select_gui_flows.py` return the
full manifest roster restores the previous all-journey behavior.
If GUI matrix execution is suspect, remove the matrix strategy, restore
`GUI_FLOWS` and `EXPECTED_FLOW_COUNT` to the classifier's whole-selection
outputs, and remove group suffixes from evidence artifact names. This restores
one serial consumer without changing which journeys are selected.
If GUI artifact reuse is suspect, restore the build step inside
`gui-golden-flows` and remove `gui-app-build` from its dependencies. This costs
additional macOS build time but preserves the same release-shaped UI coverage.
If the mypy budget gate is operationally broken, restore the prior advisory
direct mypy command with `continue-on-error: true` while repairing the script.
Do not increase counts or add files to the baseline merely to make a PR green.
If changed-lines coverage is operationally broken, remove only the
`Enforce changed-lines coverage` step while repairing its checkout or tooling;
keep the existing advisory measurement and coverage XML upload as diagnostic
evidence. Do not lower `--fail-under` or exclude changed production lines merely
to make a pull request green.
