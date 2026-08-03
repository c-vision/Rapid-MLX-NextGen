#!/usr/bin/env bash
# dogfood-isolate.sh — produce a CFPreferences-isolated copy of a built .app
# for dogfood / first-launch UX testing.
#
# ROOT CAUSE THIS SOLVES
# ----------------------
# macOS `cfprefsd` keys preferences on **bundle identifier**, NOT on $HOME.
# Setting `HOME=/tmp/persona1-maya/home` (which the legacy dogfood harness
# did) does NOT isolate CFPreferences: a test launch of the .app with the
# stock `com.rapidmlx.rapid` bundle-id will:
#   1. **Read** from the user's prod plist
#      (`~/Library/Preferences/com.rapidmlx.rapid.plist`), inheriting
#      `quickstart.v1.done=1`, `onboarding.v1.seen=1`, etc., short-circuiting
#      every first-launch / onboarding assertion the harness tries to make.
#   2. **Write** test-run keys (e.g. `rapid.install.lastSeenVersion`) BACK
#      into the user's prod plist, silently corrupting prod state.
#
# Every "fresh-install" dogfood report produced with the old harness is
# therefore actually a returning-user run in disguise, and prod plist was
# mutated as a side effect. This helper fixes that by rewriting the bundle
# identifier on a *copy* of the .app to a unique, throwaway value
# (`com.rapidmlx.rapid.dogfood-<8hex>`). cfprefsd then treats it as a brand
# new app — empty plist, zero leakage into prod.
#
# Test-harness only. No product behaviour changes; no version bump.
#
# Usage:
#   ./scripts/dogfood-isolate.sh <source.app> <target-dir>
#
# Example:
#   APP=$(./scripts/dogfood-isolate.sh "build/Rapid-MLX Desktop.app" /tmp/persona2-alex)
#   open -n "$APP"
#   # ... run test ...
#   pkill -f "$APP"                       # path-qualified — NEVER bare 'pkill -f Rapid'
#   defaults delete "com.rapidmlx.rapid.dogfood-<id>"   # isolated bundle only

set -euo pipefail

print_help() {
    cat <<'EOF'
dogfood-isolate.sh — CFPreferences-isolated copy of a built .app

USAGE:
    dogfood-isolate.sh <source.app> <target-dir>
    dogfood-isolate.sh --help

ARGUMENTS:
    <source.app>   Path to a built .app bundle (e.g. build/Rapid-MLX Desktop.app)
    <target-dir>   Directory to place the isolated copy into. Created if missing.
                   If the target already contains a copy of the .app, it is
                   removed first (idempotent re-runs are safe).

OUTPUT:
    Progress and diagnostics are written to STDERR.
    The absolute path to the isolated .app is written to STDOUT, so callers
    can capture it:

        APP=$(./scripts/dogfood-isolate.sh build/Rapid.app /tmp/harness)

WHAT IT DOES:
    1. Copy <source.app> into <target-dir>/<source-basename>.
    2. Rewrite CFBundleIdentifier in the COPY's Info.plist from
       com.rapidmlx.rapid -> com.rapidmlx.rapid.dogfood-<8hex>.
    3. Strip the existing code signature (codesign --remove-signature).
    4. Re-sign ad-hoc (codesign --sign - --deep --force).

WHY:
    cfprefsd keys preferences on bundle identifier, not $HOME. Rewriting
    the bundle-id is the only way to fully isolate plist state between a
    dogfood test launch and the user's installed prod app.

NEVER:
    * Touch ~/Library/Preferences/com.rapidmlx.rapid.plist (prod plist).
    * Modify /Applications/Rapid-MLX Desktop.app (prod app).
    * Run `pkill -f Rapid` against the isolated copy — always
      `pkill -f "<absolute path to isolated .app>"`.
EOF
}

log() {
    # Progress / diagnostics go to STDERR so STDOUT stays clean for the
    # final path (which callers capture with $(...)).
    printf '[dogfood-isolate] %s\n' "$*" >&2
}

die() {
    printf '[dogfood-isolate] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    print_help
    exit 0
fi

if [[ $# -ne 2 ]]; then
    print_help >&2
    die "expected 2 arguments, got $#"
fi

SOURCE_APP="$1"
TARGET_DIR="$2"

# --- validate source ---------------------------------------------------------
if [[ ! -e "$SOURCE_APP" ]]; then
    die "source .app does not exist: $SOURCE_APP"
fi
if [[ ! -d "$SOURCE_APP" ]]; then
    die "source path is not a directory (.app bundles are directories): $SOURCE_APP"
fi
if [[ ! -f "$SOURCE_APP/Contents/Info.plist" ]]; then
    die "source is missing Contents/Info.plist (not a valid .app bundle): $SOURCE_APP"
fi

# Resolve absolute, symlink-resolved paths so STDOUT is unambiguous and
# the same-path safety check below cannot be bypassed by a symlink at
# EITHER end (target dir OR the final source component itself —
# e.g. /tmp/Rapid.app symlinked at /Applications/Rapid-MLX Desktop.app).
# `cd "$SOURCE_APP" && pwd -P` works because an .app bundle is a
# directory; this is the portable way to do `readlink -f` on macOS
# without depending on GNU coreutils.
SOURCE_ABS=$(cd "$SOURCE_APP" && pwd -P)
APP_BASENAME=$(basename "$SOURCE_ABS")

# --- safety layer 2 (pre-mkdir): raw-input system-prefix check ---------------
# Check the literal TARGET_DIR string BEFORE mkdir / pwd -P so we never
# even create directories inside a system prefix. The post-mkdir
# resolution below still re-checks the canonical path to catch
# symlinked-parent cases.
GUARD_PREFIXES=(/Applications /System /Library /usr /bin /sbin /opt)
for guard_prefix in "${GUARD_PREFIXES[@]}"; do
    if [[ "$TARGET_DIR" == "$guard_prefix"* ]]; then
        die "refusing to operate: <target-dir> '$TARGET_DIR' is under '$guard_prefix'. This helper writes throwaway test bundles; pick a scratch location (e.g. /tmp/persona2-alex)."
    fi
done

mkdir -p "$TARGET_DIR"
TARGET_ABS=$(cd "$TARGET_DIR" && pwd -P)
TARGET_APP="$TARGET_ABS/$APP_BASENAME"

# --- safety layer 1: refuse to overwrite the source -------------------------
# Without this guard, invocations like
#   ./scripts/dogfood-isolate.sh "/Applications/Rapid-MLX Desktop.app" /Applications
# would resolve TARGET_APP to the same path as SOURCE_ABS; the
# idempotency delete below would then `rm -rf` the prod app before the
# copy step runs. Both SOURCE_ABS and TARGET_ABS are fully
# symlink-resolved via `pwd -P`, so this check cannot be sidestepped by
# a symlinked target dir, a symlinked source bundle, or
# `/tmp` vs `/private/tmp`.
if [[ "$TARGET_APP" == "$SOURCE_ABS" ]]; then
    die "refusing to operate: target path equals source path ($TARGET_APP). Pick a different <target-dir> (e.g. /tmp/persona2-alex) — this helper is for THROWAWAY test copies, not in-place rewrites of installed/built apps."
fi

# --- safety layer 2 (post-resolve): symlinked-parent landed under system ----
# E.g. <target-dir>=/tmp/foo where /tmp/foo is a symlink to /Applications.
# The raw-input check above wouldn't catch that, but pwd -P resolves it
# and we re-check here.
for guard_prefix in "${GUARD_PREFIXES[@]}"; do
    if [[ "$TARGET_ABS" == "$guard_prefix"* ]]; then
        die "refusing to operate: <target-dir> resolves under '$guard_prefix' ($TARGET_ABS). This helper writes throwaway test bundles; pick a scratch location (e.g. /tmp/persona2-alex)."
    fi
done

# --- safety layer 3: refuse to delete an un-isolated prod bundle -------------
# If something is already sitting at TARGET_APP, sanity-check its
# CFBundleIdentifier before `rm -rf`. The expected case is a previous
# dogfood copy (id ends with `.dogfood-<hex>`); anything still carrying
# the stock prod id (`com.rapidmlx.rapid`) is a sign we're about to
# clobber the user's real install located outside /Applications (e.g.
# someone copied it into ~/Desktop) and must abort.
if [[ -e "$TARGET_APP" ]]; then
    if [[ -f "$TARGET_APP/Contents/Info.plist" ]]; then
        existing_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$existing_id" == "com.rapidmlx.rapid" ]]; then
            die "refusing to remove $TARGET_APP — its CFBundleIdentifier is the prod id 'com.rapidmlx.rapid'. This looks like a real install, not a previous dogfood copy. Pick a different <target-dir>."
        fi
    fi
    log "removing existing copy at $TARGET_APP"
    rm -rf "$TARGET_APP"
fi

# --- 1. copy ------------------------------------------------------------------
log "copying $SOURCE_ABS -> $TARGET_APP"
# `cp -R` preserves bundle structure; we deliberately do NOT preserve the
# existing signature seal because step 3 strips it anyway.
cp -R "$SOURCE_ABS" "$TARGET_APP"

# --- 2. rewrite CFBundleIdentifier -------------------------------------------
PLIST="$TARGET_APP/Contents/Info.plist"
ORIGINAL_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST" 2>/dev/null || true)
if [[ -z "$ORIGINAL_ID" ]]; then
    die "could not read CFBundleIdentifier from $PLIST"
fi
log "original CFBundleIdentifier: $ORIGINAL_ID"

if ! command -v uuidgen >/dev/null 2>&1; then
    die "uuidgen not found; required to mint a unique bundle suffix"
fi
SUFFIX=$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | cut -c1-8)
if [[ ${#SUFFIX} -ne 8 ]]; then
    die "failed to mint 8-char suffix (got '$SUFFIX')"
fi
NEW_ID="${ORIGINAL_ID}.dogfood-${SUFFIX}"

log "rewriting CFBundleIdentifier -> $NEW_ID"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_ID" "$PLIST"

# Sanity-check the rewrite stuck.
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
if [[ "$ACTUAL_ID" != "$NEW_ID" ]]; then
    die "CFBundleIdentifier rewrite verification failed: expected '$NEW_ID', got '$ACTUAL_ID'"
fi

# --- 3. strip existing signature ---------------------------------------------
# Stripping is required because the original seal covered the old bundle-id
# embedded in Info.plist; re-signing without a strip leaves a stale signature
# that codesign will reject.
log "stripping existing code signature"
codesign --remove-signature "$TARGET_APP" >/dev/null 2>&1 || {
    # `--remove-signature` returns non-zero when there's nothing to remove
    # (e.g. an unsigned dev build). That's fine — log + continue.
    log "  (no existing signature, or remove-signature returned non-zero; continuing)"
}

# --- 4. ad-hoc re-sign --------------------------------------------------------
# Ad-hoc signing (`--sign -`) is enough for local LaunchServices to accept the
# bundle and for cfprefsd to treat it as a distinct identity. Notarisation /
# hardened runtime are intentionally NOT applied — this is a throwaway test
# bundle.
log "ad-hoc re-signing (--deep --force)"
codesign --sign - --deep --force "$TARGET_APP" >/dev/null 2>&1 || \
    die "codesign --sign - --deep --force failed for $TARGET_APP"

# Verify the new signature is intact end-to-end.
if ! codesign --verify --deep --strict "$TARGET_APP" >/dev/null 2>&1; then
    die "codesign --verify --deep --strict failed for $TARGET_APP"
fi
log "signature verified"

# --- done --------------------------------------------------------------------
log "isolated .app ready: $TARGET_APP"
log "  new bundle-id: $NEW_ID"
log "  cleanup later: defaults delete '$NEW_ID'"
log "  shutdown:      pkill -f '$TARGET_APP'    # path-qualified, do NOT use bare 'pkill -f Rapid'"

# STDOUT: just the path, for $(./scripts/dogfood-isolate.sh ...) capture.
printf '%s\n' "$TARGET_APP"
