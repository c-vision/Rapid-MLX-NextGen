# Release notes — curated highlights

A `git log` dump is a record, not release notes. It tells a reader *what
commits happened*; it never tells them *what changed and why they should care*.
A bash step in CI cannot write that, and we are not putting an LLM in the
release path — so the prose has to be captured by a human **while the work is
being done**, and merely assembled at release time. That is what this directory
is.

## How it works

`.github/workflows/auto-release.yml` → `scripts/build_release_notes.sh` looks
for **`docs/release-notes/v<X.Y.Z>.md`** *in the commit being tagged*.

- **File present** → its contents are the top of the GitHub Release body,
  verbatim, and the auto-generated commit list is appended below it inside a
  collapsed `<details><summary>All changes</summary>`.
- **File absent or empty** → the release publishes exactly as it always has: a
  flat commit list, no `<details>`.

**A release is never blocked on prose.** Forgetting to write highlights costs
you nice notes, never a release.

The machinery around the prose is unchanged either way: the
`## What's new in vX.Y.Z` heading, the ⚠️ emergency-release banner when the
Tier-1 agent gate was bypassed, the `## Community contributors` section, and the
trailing `Install:` line are all still generated.

## Writing them

1. **While you work**, append to `unreleased.md`. It is a scratch file; no PR is
   required to touch it and there is no schema to satisfy.
2. **In the version-bump PR** (the one that sets `version` in `pyproject.toml`
   and whose subject is `chore: bump version to X.Y.Z`), rename it:

   ```bash
   git mv docs/release-notes/unreleased.md docs/release-notes/vX.Y.Z.md
   ```

   Reread it as a whole, cut what turned out not to matter, and add the framing
   paragraph. Then recreate an empty `unreleased.md` from the template at the
   bottom of this file.

That rename is the entire "roll into an archive and reset" step, and it happens
in the PR that already exists for every release. Nothing in CI writes to the
repository — the workflow only ever *reads* the release commit, so it needs no
push permission on `main` and cannot race a concurrent merge.

Naming the file after its version also makes stale prose structurally
impossible: `v0.11.9.md` can only ever be published as v0.11.9. A forgotten
reset cannot cause last release's highlights to ship again.

The files accumulate here, so this directory doubles as a browsable, in-repo
changelog.

## What good looks like

Model these on how a reader decides whether to upgrade.

- **A short framing paragraph.** What is this release *about*? One or two
  sentences. No single PR knows this; only a human looking at the whole range
  does.
- **A `## Highlights` section.** A handful of bolded, named items — not one per
  PR, one per *thing a user would notice*. Each gets a paragraph explaining what
  changed and why it matters, with the PR link inline. Three good ones beat
  fifteen restated commit subjects.
- **Tables wherever there are numbers.** A context sweep (1K…128K) of
  prefill/decode tok/s; a feature-on/off table with a Change % column. Numbers
  are the reason anyone believes the paragraph above them.
- **Negative results, stated plainly.** This is not optional politeness, it is
  what makes the positive numbers credible. If a feature wins on code and loses
  on prose, say so and say what the engine does about it — "prose lands at
  32–57% acceptance and does not consistently gain, so the adaptive controller
  parks speculation there". A reader who finds one honest caveat will trust
  every other number on the page; a reader who finds none will trust nothing.
  Write the caveat in the same breath as the win, in the same paragraph or as a
  row in the same table.
- **Anything genuinely breaking, first**, before the wins.

## Template

Copy this into a fresh `unreleased.md` after each release.

```markdown
<!-- Scratch space for the next release's notes. Rename to vX.Y.Z.md in the
     version-bump PR. See README.md in this directory. -->

<!-- One or two sentences: what is this release about? -->

## Highlights

**<Named thing>** — what changed, and why a user should care. Include the
numbers if there are numbers, and the caveat if there is a caveat. ([#1234](https://github.com/raullenchai/Rapid-MLX/pull/1234))

| Context | Prefill tok/s | Decode tok/s |
| ------: | ------------: | -----------: |
|      1K |               |              |
|    128K |               |              |

| Workload | Off | On | Change | Acceptance |
| -------- | --: | -: | -----: | ---------: |
| Code     |     |    |        |            |
| Prose    |     |    |        |            |
```
