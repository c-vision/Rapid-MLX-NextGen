#!/usr/bin/env bash
# preview.sh — rebuild and relaunch Rapid CLEANLY so you never preview a
# stale build.
#
# The trap this avoids: `open build/Rapid.app` on an app that's already
# running just activates the existing process — it does NOT load the
# freshly-built binary. So after editing UI you'd rebuild, "open", and
# still see the old window. This script quits the running copy first and
# launches a brand-new instance (`open -n`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> quitting any running Rapid"
osascript -e 'tell application "Rapid" to quit' 2>/dev/null || true
pkill -x Rapid 2>/dev/null || true
# give the old process a moment to release port 8000 / the window
sleep 1

echo "==> building (release)"
"$ROOT/scripts/build.sh"

echo "==> launching the fresh build"
open -n "$ROOT/build/Rapid-MLX Desktop.app"

echo
echo "If you want to also test the first-launch default window size,"
echo "clear the saved window frame first, then re-run this script:"
echo "  defaults delete com.rapidmlx.rapid \"NSWindow Frame Rapid.MainWindow\""
