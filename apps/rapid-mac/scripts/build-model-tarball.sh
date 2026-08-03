#!/usr/bin/env bash
# build-model-tarball.sh — package a Quickstart model snapshot
# (HuggingFace Hub layout) into a deterministic, downloadable tarball
# for the bootstrapper architecture (see .claude/loop/bootstrapper-plan.md
# P3 slice β).
#
# The bootstrapper DMG (slice α — built by build-bootstrapper-dmg.sh)
# ships ~5-8 MB. On first launch the bootstrapper SwiftUI module
# downloads the sidecar tarball (P1) + this Quickstart model tarball
# in parallel, verifies SHA256, extracts, then transitions straight
# into ChatView. Slice β only produces this tarball as a GHA workflow
# artifact — no R2 push, no release asset, no client wiring. Slice γ
# adds the latest.json fields; slice δ adds telemetry; slice ε is the
# cutover.
#
# Output:
#   build/quickstart-<alias>-<version>.tar.gz
#   build/quickstart-<alias>-<version>.manifest.json
#
# Where <alias> defaults to "bonsai-1.7b-2bit" and <version> is the
# desktop CFBundleShortVersionString (mirrors sidecar tarball naming).
# A version pin (vs the HF snapshot SHA) is used so the bootstrapper
# can request the same artifact set the desktop release was QA'd
# against — bumping the bundled model is an intentional release action
# (the same rule build.sh's BUNDLED_MODEL_REPO follows).
#
# Determinism:
#   Mirrors scripts/build-sidecar-tarball.sh exactly — Python's
#   tarfile + gzip(mtime=0) with sorted entries, pinned uid/gid/uname/
#   gname, USTAR format, single SOURCE_DATE_EPOCH. Repeated runs over
#   the same snapshot tree produce byte-identical archives (same
#   SHA-256) which is the load-bearing invariant for slice γ's
#   latest.json content-hash and slice ε's R2 dedup.
#
# Source resolution (in order — first match wins):
#   1. If --snapshot-dir is passed, use it.
#   2. .app's bundled snapshot at Contents/Resources/models/hf-cache/
#      hub/models--<owner>--<name>/snapshots/<sha>/ (the canonical
#      build.sh BUNDLE_MODEL=1 staging path — works when invoked
#      against a freshly-built .app that bundled the model).
#   3. User's HF cache at ~/.cache/huggingface/hub/
#      models--<owner>--<name>/snapshots/<sha>/ (works locally on a
#      developer's Mac that has already pulled the model OR in CI
#      after a workflow-scoped huggingface_hub.snapshot_download).
#
# IMPORTANT: this script READS from the user's HF cache when (3)
# applies. It NEVER writes to the cache and NEVER mutates symlinks
# inside it. The script copies file content out (via tar's
# stream-read) rather than touching the original tree, so a parallel
# `huggingface_hub` snapshot_download in the same cache cannot race
# with us.
#
# Size sanity:
#   Fails if output > 1 GB (catches packaging the wrong model —
#   bonsai-1.7b-2bit compressed lands ~490 MB; the 2-bit-packed
#   safetensors barely gzips, so a larger bonsai (4B ~1.1 GB) trips
#   this and forces an intentional gate retune) or < 50 MB (catches
#   empty / truncated archive — the safetensors blob alone is ~490 MB).
#
# File-shape sanity:
#   Asserts every entry in EXPECTED_FILES (config.json + tokenizer
#   pair + model weights index + .safetensors blob) is present in the
#   snapshot before packing. A future model swap edits only the
#   EXPECTED_FILES constant + the default alias + repo at the top of
#   the script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"

# --- defaults (model swap = edit these four constants) ----------------
DEFAULT_ALIAS="bonsai-1.7b-2bit"
DEFAULT_REPO="prism-ml/Ternary-Bonsai-1.7B-mlx-2bit"

# Files the bootstrapper / sidecar require to load this model. The
# .gitattributes / README.md from the HF snapshot are intentionally
# excluded — they're packaged but not part of the load contract. The
# list below is the minimum set that must EXIST in the source
# snapshot; the tarball includes whatever else is present in the
# snapshot dir lexicographically. A missing entry here triggers a
# hard fail with the missing filename listed — much friendlier than
# a runtime "tokenizer.json not found" 30 s into first launch.
# NOTE: bonsai-1.7b-2bit ships NO ``special_tokens_map.json`` (the
# 0.6B starter did) and DOES ship a standalone ``chat_template.jinja``
# that carries the tool-call / think template — required for the
# .known tool-calling surface. Asserting both keeps the swap honest.
EXPECTED_FILES=(
  "config.json"
  "tokenizer.json"
  "tokenizer_config.json"
  "chat_template.jinja"
  "model.safetensors"
  "model.safetensors.index.json"
)

# Compressed-size gates (bytes). Lower bound catches an empty /
# truncated archive (safetensors alone is ~490 MB pre-compression, so
# anything < 50 MB cannot possibly be a valid bonsai-1.7b-2bit
# package). Upper bound catches a wrong-model swap (a 7B model would
# easily blow past 1 GB compressed). Both gates can be tuned for a
# future model via the env vars; defaults are sized for the current
# Quickstart pick.
MODEL_TARBALL_MAX_MB="${MODEL_TARBALL_MAX_MB:-1024}"
MODEL_TARBALL_MIN_MB="${MODEL_TARBALL_MIN_MB:-50}"
# Sanity cap: an absurd env override (e.g. user typo MAX_MB=99999999)
# would overflow when multiplied by 1 MiB. Mirror slice α's defence:
# disallow > 1 TiB.
MAX_GATE_CEILING_MB=1048576  # 1 TiB
for gate_name in MODEL_TARBALL_MAX_MB MODEL_TARBALL_MIN_MB; do
  gate_val="${!gate_name}"
  if [[ ! "$gate_val" =~ ^[0-9]+$ ]]; then
    echo "::error::$gate_name must be a non-negative integer (got '$gate_val')" >&2
    exit 1
  fi
  if (( gate_val > MAX_GATE_CEILING_MB )); then
    echo "::error::$gate_name ($gate_val) exceeds sanity ceiling ($MAX_GATE_CEILING_MB MB / 1 TiB)" >&2
    exit 1
  fi
done

# --- argv parsing -----------------------------------------------------
ALIAS="$DEFAULT_ALIAS"
REPO="$DEFAULT_REPO"
APP=""
SNAPSHOT_DIR=""
APP_VERSION_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage: $0 [--app PATH] [--snapshot-dir PATH] [--alias NAME] [--repo OWNER/NAME] [--version X.Y.Z]

Options:
  --app PATH            Path to Rapid-MLX Desktop.app (default: build/Rapid-MLX Desktop.app).
                        Used to read CFBundleShortVersionString for tarball naming AND
                        as a fallback snapshot source (BUNDLE_MODEL=1 builds).
  --snapshot-dir PATH   Explicit path to an HF Hub snapshot directory
                        (.../snapshots/<sha>/). Overrides the .app + user-cache
                        search.
  --alias NAME          Model alias for output filenames + manifest (default:
                        $DEFAULT_ALIAS). Should match the rapid-mlx aliases.json key.
  --repo OWNER/NAME     HuggingFace repo ID (default: $DEFAULT_REPO). Used to derive
                        the cache dir name (models--<owner>--<name>) when probing
                        the user's HF cache.
  --version X.Y.Z       Override the desktop version stamp (default: read from
                        the .app's Info.plist). Useful for CI dry-runs against an
                        unbuilt .app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)            APP="$2"; shift 2 ;;
    --snapshot-dir)   SNAPSHOT_DIR="$2"; shift 2 ;;
    --alias)          ALIAS="$2"; shift 2 ;;
    --repo)           REPO="$2"; shift 2 ;;
    --version)        APP_VERSION_OVERRIDE="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "::error::Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# Hardening: alias goes straight into the output filename + manifest +
# (eventually) the R2 bucket key. Reject anything that isn't lowercase
# alnum/dot/dash so a malformed flag can't slip a path separator or
# whitespace through. Matches the rapid-mlx aliases.json key grammar.
if [[ ! "$ALIAS" =~ ^[a-z0-9.-]+$ ]]; then
  echo "::error::Alias '$ALIAS' has disallowed characters (must match ^[a-z0-9.-]+\$)" >&2
  exit 1
fi
# Repo ID — HuggingFace allows owner/name with alnum, dot, dash,
# underscore. The transformed cache-dir name is what we care about
# for path safety; constrain the input to the HF grammar.
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::Repo '$REPO' does not match HF owner/name grammar" >&2
  exit 1
fi

# HF Hub on-disk dir name: each / in the repo becomes -- (double dash).
# Matches build.sh's derivation and BundledModel.swift's
# bundledCacheDirName so all three agree on the path.
REPO_DIRNAME="models--$(echo "$REPO" | sed 's|/|--|g')"

# --- resolve APP_VERSION ---------------------------------------------
APP_VERSION=""
if [[ -n "$APP_VERSION_OVERRIDE" ]]; then
  APP_VERSION="$APP_VERSION_OVERRIDE"
else
  APP_PATH="${APP:-$BUILD/Rapid-MLX Desktop.app}"
  INFO_PLIST="$APP_PATH/Contents/Info.plist"
  if [[ ! -f "$INFO_PLIST" ]]; then
    echo "::error::Info.plist not found at $INFO_PLIST" >&2
    echo "Pass --app /path/to/Rapid-MLX Desktop.app or --version X.Y.Z" >&2
    exit 1
  fi
  if ! APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)"; then
    echo "::error::CFBundleShortVersionString missing or unreadable in $INFO_PLIST" >&2
    exit 1
  fi
fi
# Same SemVer regex as build-sidecar-tarball.sh — defence against a
# malformed Info.plist or a malicious --version slipping a path
# separator into the output filename / manifest / R2 key.
if [[ -z "$APP_VERSION" ]] || [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::Desktop version '$APP_VERSION' is not a SemVer-shaped string" >&2
  exit 1
fi

# --- resolve SNAPSHOT_DIR --------------------------------------------
# Source priority documented at the top of the file.
if [[ -z "$SNAPSHOT_DIR" ]]; then
  # 2. .app's bundled snapshot (BUNDLE_MODEL=1 staging path).
  APP_PATH="${APP:-$BUILD/Rapid-MLX Desktop.app}"
  BUNDLED_HUB="$APP_PATH/Contents/Resources/models/hf-cache/hub/$REPO_DIRNAME/snapshots"
  if [[ -d "$BUNDLED_HUB" ]]; then
    # HF Hub stores exactly one snapshot per ref; pick the first
    # (lexicographic) snapshot dir. If a future build ships multiple,
    # the picker would need refining — but `snapshot_download` for a
    # single repo writes a single snapshot dir, so this is safe today.
    SNAPSHOT_DIR="$(find "$BUNDLED_HUB" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | head -n1)"
    if [[ -n "$SNAPSHOT_DIR" ]]; then
      echo "==> resolved snapshot from .app bundle: $SNAPSHOT_DIR"
    fi
  fi
fi
if [[ -z "$SNAPSHOT_DIR" ]]; then
  # 3. User's HF cache. Mirrors huggingface_hub's resolution rules
  #    (HF_HUB_CACHE / HF_HOME / XDG_CACHE_HOME / HOME). Kept lean —
  #    only the precedence steps we need at CI / dev time.
  USER_HUB=""
  if [[ -n "${HF_HUB_CACHE:-}" ]]; then
    USER_HUB="$HF_HUB_CACHE"
  elif [[ -n "${HF_HOME:-}" ]]; then
    USER_HUB="$HF_HOME/hub"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    USER_HUB="$XDG_CACHE_HOME/huggingface/hub"
  elif [[ -n "${HOME:-}" ]]; then
    USER_HUB="$HOME/.cache/huggingface/hub"
  fi
  if [[ -n "$USER_HUB" ]] && [[ -d "$USER_HUB/$REPO_DIRNAME/snapshots" ]]; then
    SNAPSHOT_DIR="$(find "$USER_HUB/$REPO_DIRNAME/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | head -n1)"
    if [[ -n "$SNAPSHOT_DIR" ]]; then
      echo "==> resolved snapshot from HF cache: $SNAPSHOT_DIR"
    fi
  fi
fi
if [[ -z "$SNAPSHOT_DIR" ]] || [[ ! -d "$SNAPSHOT_DIR" ]]; then
  echo "::error::Could not locate snapshot directory for $REPO" >&2
  echo "" >&2
  echo "Tried:" >&2
  echo "  1. --snapshot-dir flag (not passed)" >&2
  echo "  2. .app's Contents/Resources/models/hf-cache/hub/$REPO_DIRNAME/snapshots/" >&2
  echo "  3. user HF cache at \$HF_HUB_CACHE / \$HF_HOME/hub / \$XDG_CACHE_HOME/huggingface/hub / \$HOME/.cache/huggingface/hub" >&2
  echo "" >&2
  echo "Prime the cache via:" >&2
  echo "  HF_HUB_DISABLE_XET=1 python3 -c \"from huggingface_hub import snapshot_download; snapshot_download('$REPO')\"" >&2
  exit 1
fi

# Resolve symlinks so the absolute path in the manifest is stable. HF
# snapshot files are themselves symlinks into ../../blobs/ — tarfile
# follows them automatically (dereference=True is the default for
# regular files via gettarinfo on file paths, but we still want a
# concrete snapshot dir so listing + walk are deterministic).
SNAPSHOT_DIR="$(cd "$SNAPSHOT_DIR" && pwd -P)"

# --- file-shape gate -------------------------------------------------
# Check every expected file exists (following symlinks — HF stores
# blobs at ../../blobs/<sha> and snapshots contain symlinks). Surface
# all missing files at once for fast iteration on a future model swap.
MISSING=()
for f in "${EXPECTED_FILES[@]}"; do
  # -e follows symlinks (intentional — we care that the path resolves
  # to a real blob, not that there's a dangling link). The lock files
  # under .rapid-mlx-mirror/ have a "name.lock" shape so they don't
  # collide with any EXPECTED_FILES entry.
  if [[ ! -e "$SNAPSHOT_DIR/$f" ]]; then
    MISSING+=("$f")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::Snapshot at $SNAPSHOT_DIR is missing required files:" >&2
  for m in "${MISSING[@]}"; do
    echo "::error::  - $m" >&2
  done
  echo "" >&2
  echo "Snapshot listing:" >&2
  ls -la "$SNAPSHOT_DIR" >&2
  exit 1
fi

# --- content-stable epoch -------------------------------------------
# Codex r3 MAJOR: the sidecar-tarball pattern of "fall back to the git
# commit time" silently broke slice γ's content-hash / R2 dedup
# contract for THIS script. The model tarball is packaged once per
# release tag, and the same model snapshot packaged on two different
# desktop release commits MUST produce the same SHA256 (otherwise
# slice γ's per-release "is this model already uploaded to R2" probe
# always misses and we pay bandwidth + storage for re-uploading
# identical bytes on every desktop release).
#
# Resolution chain:
#   1. Honour an explicit SOURCE_DATE_EPOCH override (OSS reproducible
#      -builds convention — a CI step that wants to pin its own epoch
#      keeps that ability).
#   2. Otherwise, derive the epoch from a content-IDENTITY hash of
#      the snapshot — a SHA256 of (sorted relpath, file size) tuples
#      for every entry, truncated to 32 bits and tar-safe-clamped to
#      [978307200, 2147483647] (2001-01-01 .. 2038-01-19, well clear
#      of the year-2038 USTAR mtime limit AND well clear of the 1970
#      epoch which some extractors treat as "no mtime").
#
#      Note this is a content-IDENTITY hash, not a full content hash:
#      we hash (relpath, size) tuples rather than the bytes themselves
#      because the bytes go directly into the tar payload anyway —
#      any per-byte change shifts the tar SHA256 regardless of the
#      mtime field. Using (relpath, size) makes the epoch derivation
#      O(file count) rather than O(total bytes) — important when the
#      snapshot is 330 MB of safetensors and we don't want to read
#      every blob twice (once for the epoch hash, once for the
#      tarfile.addfile() body). Same identity tuple → same epoch →
#      same tar header bytes; combined with the unchanged blob
#      content, that gives same final tarball SHA. A new HF snapshot
#      (upstream re-upload) almost always changes file sizes /
#      adds-removes files → flips the epoch → flips the SHA.
#      Even in the degenerate case where two distinct HF snapshots
#      had identical (relpath, size) tuples but different bytes, the
#      tar payload bytes themselves would still differ → tarball SHA
#      still differs. Slice γ's content-hash invariant holds.
#
# We do NOT fall back to git commit time the way build-sidecar-
# tarball.sh does. The sidecar tarball is a per-release artifact
# whose CONTENT changes per release anyway (rapid-mlx submodule
# version, Python deps); a per-release epoch is fine for it. The
# model tarball is the opposite: the content is stable across
# desktop releases for as long as the upstream HF snapshot doesn't
# change.
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(python3 - "$SNAPSHOT_DIR" <<'PY'
import hashlib, os, sys
snapshot_dir = sys.argv[1]
h = hashlib.sha256()
entries = []
for root, dirs, files in os.walk(snapshot_dir, followlinks=False):
    dirs.sort()
    for f in sorted(files):
        entries.append(os.path.join(root, f))
entries.sort()
for path in entries:
    rel = os.path.relpath(path, snapshot_dir)
    resolved = os.path.realpath(path)
    try:
        size = os.path.getsize(resolved)
    except OSError:
        size = 0
    h.update(rel.encode("utf-8"))
    h.update(b"|")
    h.update(str(size).encode("ascii"))
    h.update(b"\n")
digest = h.hexdigest()
# Take the top 8 hex chars (32 bits), clamp into the safe range.
raw = int(digest[:8], 16)  # 0 .. 2**32 - 1
LO = 978307200    # 2001-01-01T00:00:00Z
HI = 2147483647   # 2038-01-19T03:14:07Z (max signed 32-bit time_t)
span = HI - LO
epoch = LO + (raw % span)
print(epoch)
PY
)"
  if [[ -z "$SOURCE_DATE_EPOCH" ]] || [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "::error::Failed to derive content-stable epoch from $SNAPSHOT_DIR" >&2
    exit 1
  fi
fi
STABLE_DATE="$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

# --- output paths ----------------------------------------------------
TARBALL_NAME="quickstart-${ALIAS}-${APP_VERSION}.tar.gz"
MANIFEST_NAME="quickstart-${ALIAS}-${APP_VERSION}.manifest.json"
TARBALL="$BUILD/$TARBALL_NAME"
MANIFEST="$BUILD/$MANIFEST_NAME"

mkdir -p "$BUILD"

echo "Packaging Quickstart model snapshot:"
echo "  alias:             $ALIAS"
echo "  repo:              $REPO"
echo "  snapshot dir:      $SNAPSHOT_DIR"
echo "  desktop version:   $APP_VERSION"
echo "  pinned epoch:      $SOURCE_DATE_EPOCH ($STABLE_DATE)"
echo "  output tarball:    $TARBALL"

# --- pack via Python tarfile (same machinery as sidecar tarball) ----
# Why not bsdtar: same reasons as build-sidecar-tarball.sh (no portable
# mtime override, pax exthdr syntax unsupported, ownership flags don't
# compose). Python's tarfile gives us the full deterministic story in
# ~30 lines and zero external deps beyond the stdlib.
#
# What we do:
#   - Walk the snapshot dir lexicographically.
#   - Follow symlinks: HF stores actual blobs under ../../blobs/<sha>
#     and the snapshot dir contains symlinks. We package the resolved
#     file content (NOT the symlink) so the tarball extracts to a
#     self-contained snapshot tree without needing blobs/ alongside.
#   - Pin mtime / uid / gid / uname / gname on every entry.
#   - USTAR format (no pax exthdrs, simpler bytes).
#   - gzip wrapper with mtime=0 so the gzip header is content-only.
#   - Stream (mode="w|") to keep memory bounded for the 326 MB blob.
#
# arcname convention: entries are packed FLAT — each arcname is the
# snapshot-relative path (config.json, tokenizer.json, ...) with NO
# top-level "<alias>/" wrapper directory and NO leading root-dir
# entry. #416: the previous "<alias>/" wrapper double-nested on the
# install side. ModelInstaller.stage extracts the tarball into a
# per-alias staging dir and commit atomically renames THAT dir onto
#   <installRoot>/<alias>/
# so a tarball whose own top level was already "<alias>/" landed at
#   <installRoot>/<alias>/<alias>/{config.json, ...}
# Packing flat makes the install leaf exactly
#   <installRoot>/bonsai-1.7b-2bit/{config.json, tokenizer.json, ...}
# — a single level, which is what
# QuickstartModel.resolveFlatModelDir's preferred branch expects.
# Still independent of the HF snapshot SHA so reproducible across
# upstream HF re-uploads. (Retiring the "<alias>/" prefix changes the
# tarball SHA256 — safe: it's a fresh per-release content-addressed
# artifact with no stored back-compat SHA.)
python3 - "$SNAPSHOT_DIR" "$TARBALL" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import os
import sys
import tarfile

snapshot_dir = sys.argv[1]
out_path = sys.argv[2]
epoch = int(sys.argv[3])

# Walk lexicographically — deterministic order independent of FS layout.
# followlinks=False so we don't recurse into the blobs/ directory via
# any symlinked subdirectory (HF snapshots don't have nested symlinked
# dirs, but defence-in-depth in case a future HF layout change does).
entries = []
for root, dirs, files in os.walk(snapshot_dir, followlinks=False):
    dirs.sort()
    for d in dirs:
        entries.append(os.path.join(root, d))
    for f in sorted(files):
        entries.append(os.path.join(root, f))
entries.sort()

def normalise(ti):
    ti.mtime = epoch
    ti.uid = 0
    ti.gid = 0
    ti.uname = ""
    ti.gname = ""
    # File-mode normalisation. Codex r1 MAJOR: gettarinfo() captures
    # st_mode from the on-disk file, which differs across HF caches —
    # a `chmod 600 blob` on the user's machine vs a freshly downloaded
    # blob (0644) drifts the tarball SHA256 even with all other
    # metadata pinned. For the content-hash contract slice γ depends
    # on, modes must be pinned too:
    #   - directories:    0755 (drwxr-xr-x)
    #   - regular files:  0644 (-rw-r--r--)
    #   - symlinks / others: leave the type-bits alone, tarfile
    #     handles them per format spec; only the permission bits
    #     of regular files leak host state in practice.
    # Verified via codex r1's symlink fixture: pre-fix `chmod 600`
    # → SHA drift; post-fix → byte-identical.
    if ti.isdir():
        ti.mode = 0o755
    elif ti.isfile():
        ti.mode = 0o644
    return ti

# Two-stage: tarfile streams into a gzip writer with mtime=0 so even
# the gzip header is content-only.
#
# Codex r2 MAJOR: ``gzip.GzipFile(out_path, ...)`` derives the gzip
# FNAME header from os.path.basename(out_path) — which, for this
# script, is ``quickstart-bonsai-1.7b-2bit-X.Y.Z.tar`` (note: gzip
# strips the trailing ``.gz``). So identical tar payloads packaged
# at different desktop versions produce different SHA256s simply
# because the version stamp is baked into the gzip header. That
# breaks slice γ's content-hash / R2 dedup invariant. The fix: open
# the output file ourselves and pass ``filename=""`` so the FNAME
# field is omitted entirely. Verified with the same fixture as the
# mode-normalisation test: pre-fix --version 1.2.3 vs 4.5.6 SHA
# drifted; post-fix both SHAs match.
with open(out_path, "wb") as raw_out:
    with gzip.GzipFile(
        filename="",
        mode="wb",
        fileobj=raw_out,
        compresslevel=9,
        mtime=0,
    ) as gz:
        with tarfile.open(fileobj=gz, mode="w|", format=tarfile.USTAR_FORMAT) as tar:
            # #416: pack FLAT — no top-level "<alias>/" root entry. The
            # install side (ModelInstaller.stage -> commit) already wraps
            # the extracted tree in a per-alias directory via the atomic
            # rename onto <installRoot>/<alias>/; emitting a leading
            # "<alias>/" here would double-nest to
            # <installRoot>/<alias>/<alias>/.
            for path in entries:
                arcname = os.path.relpath(path, snapshot_dir)
                # IMPORTANT: dereference symlinks. HF snapshot files are
                # symlinks into blobs/<sha>; we want the BLOB CONTENT in
                # the tarball, not a dangling link. ``os.path.realpath``
                # resolves the symlink, and ``gettarinfo`` on the resolved
                # path returns a TarInfo describing the regular file. Pin
                # the arcname back to the snapshot-relative path so the
                # archive's structure is the snapshot dir, not the blobs
                # dir.
                resolved = os.path.realpath(path)
                ti = tar.gettarinfo(resolved, arcname=arcname)
                if ti is None:
                    continue
                # gettarinfo on a directory entry recurses via the parent
                # os.walk above — skip the dirs themselves in the second
                # loop (they were already added as directory TarInfos).
                if ti.isdir():
                    # Replace with a directory TarInfo whose arcname is the
                    # snapshot-relative dir path. Use the source path (NOT
                    # the resolved one) so the archive structure matches
                    # what we walked.
                    ti = tar.gettarinfo(path, arcname=arcname)
                    normalise(ti)
                    tar.addfile(ti)
                    continue
                normalise(ti)
                if ti.isfile():
                    with open(resolved, "rb") as f:
                        tar.addfile(ti, f)
                else:
                    # Hard links / FIFOs / devices — body-less. HF
                    # snapshots don't ship these but defence-in-depth.
                    tar.addfile(ti)
PY

if [[ ! -s "$TARBALL" ]]; then
  echo "::error::tarfile output empty: $TARBALL" >&2
  exit 1
fi

# --- size gates ------------------------------------------------------
SIZE_BYTES="$(stat -f '%z' "$TARBALL")"
SIZE_MB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.1f", b/1024/1024 }')"
MIN_BYTES=$(( MODEL_TARBALL_MIN_MB * 1048576 ))
MAX_BYTES=$(( MODEL_TARBALL_MAX_MB * 1048576 ))

# Byte-precise comparison (NOT du -sm — du rounds whole-MiB blocks
# UP, so a 100 KB tarball can report `1` and silently pass a `>= 1 MB`
# floor). Same lesson as slice α PR #404 codex r1.
if [[ "$SIZE_BYTES" -lt "$MIN_BYTES" ]]; then
  echo "::error::Tarball $TARBALL is ${SIZE_MB} MB (${SIZE_BYTES} bytes), below the ${MODEL_TARBALL_MIN_MB} MB floor (${MIN_BYTES} bytes)." >&2
  echo "::error::Almost certainly an empty/truncated archive — bonsai-1.7b-2bit's safetensors blob alone is ~490 MB." >&2
  exit 1
fi
if [[ "$SIZE_BYTES" -gt "$MAX_BYTES" ]]; then
  echo "::error::Tarball $TARBALL is ${SIZE_MB} MB (${SIZE_BYTES} bytes), exceeds the ${MODEL_TARBALL_MAX_MB} MB ceiling (${MAX_BYTES} bytes)." >&2
  echo "::error::Almost certainly the wrong model — bump MODEL_TARBALL_MAX_MB only after explicit review of the EXPECTED_FILES constant." >&2
  exit 1
fi

SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

# Uncompressed size + file count: walk the tarball once to compute the
# values the manifest exposes. Cheap relative to the gzip work above.
read -r UNCOMPRESSED_BYTES FILE_COUNT < <(python3 - "$TARBALL" <<'PY'
import sys, tarfile
total = 0
count = 0
with tarfile.open(sys.argv[1], "r:gz") as tar:
    for ti in tar:
        if ti.isfile():
            total += ti.size
            count += 1
print(total, count)
PY
)

# --- manifest --------------------------------------------------------
# JSON via Python so any version string / repo name with quotes or
# control chars is escaped safely. Schema mirrors the sidecar manifest
# (schema_version + artifact + named fields + sha + size) so slice γ
# can consume both with the same Codable struct.
python3 - \
    "$MANIFEST" \
    "$ALIAS" \
    "$REPO" \
    "$APP_VERSION" \
    "$TARBALL_NAME" \
    "$SHA" \
    "$SIZE_BYTES" \
    "$UNCOMPRESSED_BYTES" \
    "$FILE_COUNT" \
    "$SOURCE_DATE_EPOCH" \
    "$STABLE_DATE" \
<<'PY'
import json, sys
(out_path, alias, repo, desktop_version, tarball_name, sha,
 tarball_size, uncompressed_size, file_count, epoch, built_at) = sys.argv[1:12]
with open(out_path, "w") as f:
    json.dump({
        "schema_version": 1,
        "artifact": "quickstart-model",
        "model_alias": alias,
        "hf_path": repo,
        "desktop_version": desktop_version,
        "tarball_filename": tarball_name,
        "tarball_sha256": sha,
        "tarball_size": int(tarball_size),
        "uncompressed_size": int(uncompressed_size),
        "file_count": int(file_count),
        "created_at_epoch": int(epoch),
        "created_at_utc": built_at,
    }, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo ""
echo "Quickstart model tarball:"
echo "  path:                $TARBALL"
echo "  size (compressed):   ${SIZE_MB} MB (${SIZE_BYTES} bytes)"
echo "  size (uncompressed): ${UNCOMPRESSED_BYTES} bytes"
echo "  file count:          ${FILE_COUNT}"
echo "  sha256:              ${SHA}"
echo "  manifest:            $MANIFEST"

# --- CI integration --------------------------------------------------
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "tarball_path=${TARBALL}"
    echo "tarball_name=${TARBALL_NAME}"
    echo "tarball_sha256=${SHA}"
    echo "tarball_size_bytes=${SIZE_BYTES}"
    echo "uncompressed_size_bytes=${UNCOMPRESSED_BYTES}"
    echo "file_count=${FILE_COUNT}"
    echo "manifest_path=${MANIFEST}"
    echo "model_alias=${ALIAS}"
    echo "desktop_version=${APP_VERSION}"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Quickstart model tarball"
    echo ""
    echo "| field | value |"
    echo "|-------|-------|"
    echo "| model_alias | \`${ALIAS}\` |"
    echo "| hf_path | \`${REPO}\` |"
    echo "| desktop_version | \`${APP_VERSION}\` |"
    echo "| tarball | \`${TARBALL_NAME}\` |"
    echo "| compressed | ${SIZE_MB} MB |"
    echo "| uncompressed | ${UNCOMPRESSED_BYTES} bytes |"
    echo "| file_count | ${FILE_COUNT} |"
    echo "| sha256 | \`${SHA}\` |"
    echo "| epoch (UTC) | ${STABLE_DATE} |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
