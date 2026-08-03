#!/usr/bin/env bash
# Post-build validation for build/rapid-mlx-desktop.dmg.
#
# Closes audit P1 `release.yml:106–110` — "DMG bg image / icon
# positions / Applications symlink not validated post-build." We
# don't ship a custom bg or icon layout (plain DMG by design), but
# the Applications drop-target symlink IS load-bearing UX — without
# it the user opens the DMG and has nowhere obvious to drag the
# app bundle onto. A regression that silently drops the symlink
# (or staging path change) is exactly the kind of thing that
# doesn't surface until a user complains. Validate at build time.
#
# Steps:
#   1. Attach the DMG read-only at a temp mount point.
#   2. Assert exactly one *.app exists at the root with a parseable
#      Info.plist + the expected ``com.rapidmlx.rapid`` bundle id.
#      Strict default (#164): only ``Rapid-MLX Desktop.app`` passes.
#      Pass ``--allow-legacy`` or set
#      ``RAPID_VALIDATE_DMG_ALLOW_LEGACY=1`` to also accept the
#      pre-v0.5.22 ``Rapid.app`` name (used when re-validating a
#      legacy build artifact locally).
#   3. Assert the Applications symlink exists and points at /Applications.
#   4. Always detach on exit (trap), even on assertion failure.
#
# Usage:
#   scripts/validate-dmg.sh                                # uses build/rapid-mlx-desktop.dmg
#   scripts/validate-dmg.sh /path/to/some.dmg
#   scripts/validate-dmg.sh --allow-legacy                 # uses default DMG, accepts legacy
#   scripts/validate-dmg.sh /path/to/some.dmg --allow-legacy
#   RAPID_VALIDATE_DMG_ALLOW_LEGACY=1 scripts/validate-dmg.sh
#
# Exit code 0 ⇒ DMG looks shippable. Non-zero ⇒ release blocked.

set -euo pipefail

# Parse args: --allow-legacy can appear in any position.
ALLOW_LEGACY="${RAPID_VALIDATE_DMG_ALLOW_LEGACY:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG=""
for arg in "$@"; do
    case "$arg" in
        --allow-legacy) ALLOW_LEGACY=1 ;;
        --*) echo "validate-dmg: unknown option $arg" >&2; exit 1 ;;
        *) [[ -z "$DMG" ]] && DMG="$arg" || { echo "validate-dmg: too many positional args" >&2; exit 1; } ;;
    esac
done
DMG="${DMG:-$ROOT/build/rapid-mlx-desktop.dmg}"

if [[ ! -f "$DMG" ]]; then
    echo "validate-dmg: DMG not found at $DMG" >&2
    exit 1
fi

MOUNT="$(mktemp -d -t rapid-dmg-validate-XXXXXX)"
ATTACHED=0

cleanup() {
    if [[ "$ATTACHED" -eq 1 ]]; then
        hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true
    fi
    rm -rf "$MOUNT"
}
trap cleanup EXIT

echo "==> attaching $DMG at $MOUNT"
hdiutil attach "$DMG" \
    -mountpoint "$MOUNT" \
    -nobrowse \
    -readonly \
    -quiet
ATTACHED=1

fail() {
    echo "validate-dmg: FAIL — $*" >&2
    exit 1
}

# 1. Exactly one *.app at the root (rules out a typoed bundle name
# that would still pass a hard-coded check).
#
# Default (strict, what CI uses): only the v0.5.22 canonical name
# "Rapid-MLX Desktop.app" passes — a silent regression that
# resurrects the old "Rapid.app" name fails the workflow instead
# of slipping through. The ``--allow-legacy`` opt-in (parsed
# above) re-admits the legacy name for local re-validation of
# older artifacts.
APPS=()
while IFS= read -r entry; do
    [[ -n "$entry" ]] && APPS+=("$entry")
done < <(find "$MOUNT" -maxdepth 1 -type d -name "*.app" -not -name ".*" -print)

[[ "${#APPS[@]}" -ge 1 ]] || fail "no *.app at root of DMG (found: $(ls -1 "$MOUNT"))"
[[ "${#APPS[@]}" -eq 1 ]] || fail "expected exactly one *.app at root, found ${#APPS[@]}: ${APPS[*]}"
APP="${APPS[0]}"
APP_NAME="$(basename "$APP")"
case "$APP_NAME" in
    "Rapid-MLX Desktop.app")
        echo "==> bundle: $APP_NAME"
        ;;
    "Rapid.app")
        if [[ "$ALLOW_LEGACY" == "1" ]]; then
            echo "==> bundle: $APP_NAME (legacy name accepted via RAPID_VALIDATE_DMG_ALLOW_LEGACY=1)"
        else
            fail "legacy bundle name 'Rapid.app' found (expected 'Rapid-MLX Desktop.app'). Re-run with RAPID_VALIDATE_DMG_ALLOW_LEGACY=1 to accept legacy artifacts."
        fi
        ;;
    *)
        fail "unexpected bundle name '$APP_NAME' (expected 'Rapid-MLX Desktop.app')"
        ;;
esac

# 2. Info.plist parses + has the bundle id we expect.
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "Info.plist missing inside $APP_NAME"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null || true)"
[[ -n "$BUNDLE_ID" ]] || fail "could not read CFBundleIdentifier from Info.plist"
echo "==> bundle id: $BUNDLE_ID"
[[ "$BUNDLE_ID" == "com.rapidmlx.rapid" ]] || fail "unexpected bundle id '$BUNDLE_ID' (expected 'com.rapidmlx.rapid')"

# 3. Applications symlink at the root, pointing at /Applications.
APPS_LINK="$MOUNT/Applications"
[[ -L "$APPS_LINK" ]] || fail "Applications drop-target symlink missing at DMG root"
TARGET="$(readlink "$APPS_LINK")"
[[ "$TARGET" == "/Applications" ]] || fail "Applications symlink points at '$TARGET', expected '/Applications'"
echo "==> Applications -> $TARGET"

echo "==> validate-dmg: OK"
