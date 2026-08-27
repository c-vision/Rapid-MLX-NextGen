#!/usr/bin/env bash
#
# Tag the desktop app at the version the engine just released.
#
# The engine and the app ship ONE version number (enforced on every PR by
# scripts/check_version_sync.py), so a release is one event, not two.
# Cutting them separately is what produced the 0.12.5-vs-0.12.6 split that
# reached users: the engine shipped from auto-release.yml, the
# ``rapid-mac-vX.Y.Z`` tag was a manual step somebody had to remember, and
# for four releases nobody did.
#
# Creating ``refs/tags/rapid-mac-v$VERSION`` records the immutable release
# identity. The caller explicitly dispatches .github/workflows/rapid-mac-release.yml
# with the pre-tag producer run and SHA, so that workflow promotes the already
# signed/notarised bytes instead of rebuilding them.
#
# WHY THE API AND NOT ``git push``
# --------------------------------
# The API makes the tag claim atomic and token-independent. Auto-release uses
# its default ``GITHUB_TOKEN`` intentionally: GitHub suppresses the resulting
# push-triggered workflow, then the caller issues one explicit workflow_dispatch
# carrying the exact producer run and source SHA. That avoids a duplicate build
# while preserving standalone PAT/manual tag pushes as a supported rebuild path.
#
# Idempotency is a POST, not a pre-check: ``POST /git/refs`` fails 422 when
# the ref already exists, so the claim is atomic. Only on that failure do we
# read the tag back — peeling annotated tag objects, because
# ``/git/ref/tags/X`` returns the *tag object's* SHA for an annotated tag
# and comparing that raw value to a commit SHA would report "points
# somewhere else" for a tag that is in fact correct (four of this repo's
# rapid-mac tags are annotated). Same tree → done. Different tree → refuse:
# moving a published tag would ship one version's notes against another's
# build.
#
# Required environment:
#   VERSION            X.Y.Z — the version the engine just released
#   RELEASE_SHA        the commit the engine release was cut from
#   ACCEPTED_SHA       the full commit SHA that a candidate build VALIDATED for
#                      this version (the desktop-releasable candidate gate's
#                      accepted source SHA). The tag may only be claimed at this
#                      exact SHA; a RELEASE_SHA that differs from it is refused,
#                      because the tag would claim an app build that was never
#                      validated. This is what stops an RC tag from preceding its
#                      validated artifact commit (#2301).
#   GITHUB_REPOSITORY  owner/repo
#   GH_TOKEN           consumed by ``gh`` (GITHUB_TOKEN in auto-release)
# Optional:
#   GH                 path to the gh binary (tests point this at a mock)
#
# Exit status: 0 tag created or already correct, 1 anything else.

set -euo pipefail

: "${VERSION:?tag_desktop_app.sh: VERSION is required}"
: "${RELEASE_SHA:?tag_desktop_app.sh: RELEASE_SHA is required}"
: "${ACCEPTED_SHA:?tag_desktop_app.sh: ACCEPTED_SHA is required — a desktop tag can only be claimed at the SHA a candidate build validated}"
: "${GITHUB_REPOSITORY:?tag_desktop_app.sh: GITHUB_REPOSITORY is required}"
GH_BIN="${GH:-gh}"

# Both SHAs must be full 40-character commits. Comparing short SHAs would let a
# collision or a truncation mistake read as the same commit, and a human must be
# able to see the exact identity being claimed.
for SHA in "$RELEASE_SHA" "$ACCEPTED_SHA"; do
  [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || {
    echo "::error::tag_desktop_app.sh: '$SHA' is not a full 40-character commit SHA" >&2
    exit 1
  }
done

# Fail closed at the identity boundary BEFORE any POST: this tag can only ever
# be claimed at the SHA that the candidate lane validated. A RELEASE_SHA that
# differs from ACCEPTED_SHA means the version's notes/tag would describe a tree
# whose desktop app was never validated as a signed, notarised, DMG-validated
# candidate — exactly the rc1/tag-before-validation defect (#2301).
if [ "$RELEASE_SHA" != "$ACCEPTED_SHA" ]; then
  echo "::error::refusing to claim a rapid-mac-v${VERSION} tag: this release is cut at $RELEASE_SHA but the validated desktop candidate is $ACCEPTED_SHA. An RC tag must identify the exact commit whose app passed signed build, notarisation and DMG validation; a tag at any other commit may ship a different, unvalidated artifact." >&2
  exit 1
fi

# The tag is built from this string, so a value the tag namespace cannot
# carry has to fail here rather than produce ``rapid-mac-v0.12.7\n``.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/resolve_github_tag.sh
source "$REPO_ROOT/scripts/resolve_github_tag.sh"
if ! python3 "$REPO_ROOT/scripts/release_version.py" validate "$VERSION" >/dev/null; then
  echo "❌ VERSION is '$VERSION', which is not X.Y.Z or X.Y.Z-rcN" >&2
  exit 1
fi

APP_TAG="rapid-mac-v${VERSION}"

# Print the exact identity being claimed BEFORE the irreversible POST, so the
# run log and the environment-approval audit both carry the full commit that a
# candidate build validated — never a branch name or short SHA.
echo "::notice::Claiming $APP_TAG at validated candidate SHA $RELEASE_SHA (accepted: $ACCEPTED_SHA)"
echo "Claiming $APP_TAG at validated candidate SHA $RELEASE_SHA"

if "$GH_BIN" api -X POST "repos/$GITHUB_REPOSITORY/git/refs" \
    -f "ref=refs/tags/$APP_TAG" -f "sha=$RELEASE_SHA" >/dev/null 2>&1; then
  echo "Created $APP_TAG at $RELEASE_SHA; caller must dispatch rapid-mac-release.yml with the exact candidate run"
  exit 0
fi

EXISTING=$(resolve_github_tag_commit "$APP_TAG" 2>/dev/null || true)
if [ -z "$EXISTING" ]; then
  echo "❌ could not create refs/tags/$APP_TAG and could not read it back — refusing to guess." >&2
  echo "   Check the token's contents:write scope, then re-run this workflow." >&2
  exit 1
fi
if [ "$EXISTING" != "$RELEASE_SHA" ]; then
  echo "❌ $APP_TAG already exists at $EXISTING, but the validated candidate (and this release) is $RELEASE_SHA." >&2
  echo "   Refusing to move a published tag: the DMG built from $EXISTING would" >&2
  echo "   ship under $RELEASE_SHA's release notes." >&2
  # A published RC is immutable. The user-visible fix is to supersede it with
  # the next RC on its own validated commit — never to delete or move the tag.
  echo "   To publish a corrected build, cut the NEXT rc (e.g. rapid-mac-v0.13.0-rc2) and validate that exact commit; this tag is not moved or deleted." >&2
  exit 1
fi
echo "$APP_TAG already points at the validated candidate $RELEASE_SHA — nothing to do."
