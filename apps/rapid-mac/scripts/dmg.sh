#!/usr/bin/env bash
# dmg.sh — wrap build/"Rapid-MLX Desktop.app" into a draggable
# rapid-mlx-desktop.dmg (legacy alias Rapid.dmg published alongside
# in CI — see release.yml R2 upload step).
#
# We deliberately use Apple's built-in `hdiutil` (and don't pull in
# `create-dmg` from Homebrew) so a contributor can build a release on a
# clean machine without `brew install`. The trade-off is no custom
# background image or icon layout — Finder's default view is fine for
# v1; we can drop in a `.DS_Store` template later.
#
# Layout inside the volume:
#   Rapid-MLX Desktop.app  ← the SwiftUI executable bundle
#   Applications  ───────┐ ← symlink so the user drags the app onto it
#                        └→ /Applications
#
# The DMG is codesigned with the same identity as the .app
# (CODESIGN_IDENTITY env var; ad-hoc "-" by default). For a real
# release the caller signs with a Developer ID identity and then runs
# scripts/notarize.sh to notarise + staple the DMG — that is what makes
# it install with zero Gatekeeper warnings, even offline.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Rapid-MLX Desktop.app"
DMG="$BUILD/rapid-mlx-desktop.dmg"
STAGING="$BUILD/dmg-staging"
VOL_NAME="Rapid-MLX Desktop"

if [[ ! -d "$APP" ]]; then
    echo "==> Rapid-MLX Desktop.app missing — running build.sh first"
    bash "$ROOT/scripts/build.sh"
fi

echo "==> staging $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# `cp -R` follows the SwiftUI .app bundle structure correctly; -p
# preserves the executable bit so the embedded Mach-O launches.
cp -R "$APP" "$STAGING/Rapid-MLX Desktop.app"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
# UDZO = zlib-compressed read-only. Smallest distribution size, good
# enough decompression speed on modern Macs (the .app is mostly
# already-compressed Swift runtime bytes).
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -fs HFS+ \
    -format UDZO \
    "$DMG" \
    >/dev/null

SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc codesign $DMG"
else
    echo "==> Developer ID codesign $DMG ($SIGN_IDENTITY)"
fi
codesign --force --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify "$DMG"

echo "==> hdiutil verify (CRC + structure)"
hdiutil verify "$DMG" >/dev/null

# Tidy up — staging is reproducible; only the .dmg is the artifact.
rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "rapid-mlx-desktop.dmg ready at: $DMG ($SIZE)"
echo "Test mount with:   open '$DMG'"
