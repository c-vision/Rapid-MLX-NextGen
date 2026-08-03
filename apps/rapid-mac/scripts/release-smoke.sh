#!/usr/bin/env bash
# release-smoke.sh — production release-smoke gate for Rapid.app.
#
# Catches the v0.5.9-class ship-blocker (SPM Bundle.module accessor
# fatalError on first SwiftUI body read inside the wrapped .app).
# See memory/gotcha_spm_bundle_module_app_wrapper.md.
#
# Three stages:
#   1. verify-app-resources.swift — every PNG declared in Package.swift's
#      resources: block must resolve via Bundle.main.url(forResource:)
#      against the assembled bundle. Pre-launch static check.
#   2. open + sustained-life poll — v0.5.9 took >4s of SwiftUI layout
#      before the sidebar tried to read Bundle.module and aborted; the
#      old `sleep 4` smoke missed it. We wait 15s.
#   3. Scene-rendered assertion — CGWindowListCopyWindowInfo must report
#      at least one substantial (>= 200x200) layer-0 window owned by the
#      launched PID. A crashing app dies before its WindowGroup body
#      runs, so no window ever appears.
#
# Exit codes:
#   0 — pass (process alive AND scene rendered)
#   1 — SwiftUI scene never rendered (crash or stuck on splash)
#   2 — resource verification failed pre-launch

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "release-smoke: macOS only (uname=$(uname -s))" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Rapid-MLX Desktop.app"
EXEC="$APP/Contents/MacOS/Rapid"
SHOT="/tmp/rapid-release-smoke.png"

cleanup() {
    if pgrep -f "$EXEC" >/dev/null 2>&1; then
        pkill -f "$EXEC" || true
        sleep 1
        pkill -9 -f "$EXEC" 2>/dev/null || true
    fi
    rm -f "$SHOT"
}
trap cleanup EXIT

# --- Stage 0: ensure the .app exists ----------------------------------------
if [[ ! -d "$APP" ]]; then
    echo "==> build/\"Rapid-MLX Desktop.app\" missing — running scripts/build.sh"
    if ! bash "$ROOT/scripts/build.sh"; then
        echo "release-smoke: scripts/build.sh failed; cannot smoke" >&2
        exit 2
    fi
fi
if [[ ! -x "$EXEC" ]]; then
    echo "release-smoke: $EXEC missing or not executable" >&2
    exit 2
fi

# --- Stage 1: pre-launch resource verification ------------------------------
echo "==> verify-app-resources.swift"
if ! swift "$ROOT/scripts/verify-app-resources.swift" "$APP"; then
    echo "release-smoke: resource verification failed (Bundle.main.url misses)" >&2
    exit 2
fi

# --- Stage 2: launch via LaunchServices, sustained-life poll -----------------
# Kill any stale instance first so we know the PID we're about to read is ours.
if pgrep -f "$EXEC" >/dev/null 2>&1; then
    pkill -f "$EXEC" || true
    sleep 1
fi

echo "==> open $APP"
open "$APP"

# 15 s, not 4 s — v0.5.9 abort fires only after the sidebar lays out and
# reads Bundle.module; that took ~6-8 s on quiet hardware in the post-mortem.
WAIT_SECONDS=15
echo "==> waiting ${WAIT_SECONDS}s for SwiftUI scene to render"
for ((i=1; i<=WAIT_SECONDS; i++)); do
    sleep 1
    if ! pgrep -f "$EXEC" >/dev/null 2>&1; then
        echo "release-smoke: Rapid process died after ${i}s (v0.5.9-class crash signature)" >&2
        exit 1
    fi
done

PID="$(pgrep -f "$EXEC" | head -1 || true)"
if [[ -z "$PID" ]]; then
    echo "release-smoke: no live Rapid pid after ${WAIT_SECONDS}s" >&2
    exit 1
fi
echo "==> Rapid alive at pid=$PID"

# --- Stage 3: scene-rendered assertion via CGWindowList ---------------------
# Inline Swift so we don't need a separate file. CGWindowListCopyWindowInfo
# does NOT require Accessibility or Screen Recording permission — it's the
# same API the Dock and Mission Control use.
WINDOW_INFO="$(swift - "$PID" <<'SWIFT' 2>&1 || true
import Foundation
import CoreGraphics

guard CommandLine.arguments.count >= 2, let target = Int32(CommandLine.arguments[1]) else {
    print("ERR usage")
    exit(2)
}
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("ERR cgwindowlist nil")
    exit(1)
}
var best: (wid: Int, w: Double, h: Double)? = nil
for info in arr {
    guard (info[kCGWindowOwnerPID as String] as? Int32) == target else { continue }
    guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let wid = info[kCGWindowNumber as String] as? Int ?? -1
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let w = bounds["Width"] as? Double ?? 0
    let h = bounds["Height"] as? Double ?? 0
    if best == nil || (w * h) > (best!.w * best!.h) {
        best = (wid, w, h)
    }
}
if let b = best {
    print("OK wid=\(b.wid) size=\(Int(b.w))x\(Int(b.h))")
} else {
    print("NONE")
}
SWIFT
)"

echo "==> window probe: $WINDOW_INFO"

if [[ "$WINDOW_INFO" != OK* ]]; then
    echo "release-smoke: no layer-0 window owned by pid=$PID (SwiftUI Scene never rendered)" >&2
    exit 1
fi

# Parse "OK wid=NNN size=WxH" and gate on substantial dimensions.
WID="$(echo "$WINDOW_INFO" | sed -nE 's/.*wid=([0-9]+).*/\1/p')"
W="$(echo "$WINDOW_INFO" | sed -nE 's/.*size=([0-9]+)x[0-9]+.*/\1/p')"
H="$(echo "$WINDOW_INFO" | sed -nE 's/.*size=[0-9]+x([0-9]+).*/\1/p')"
if [[ -z "$WID" || -z "$W" || -z "$H" ]]; then
    echo "release-smoke: could not parse window probe output: $WINDOW_INFO" >&2
    exit 1
fi
# 200x200 floor rules out the early-render hidden splash that v0.5.9 briefly
# painted before the sidebar fatalError'd. Rapid's default main window is
# 1200x820 (see RapidApp.swift WindowGroup defaultSize — widened from 900x612
# in PR #86 to give 13" MacBook Air M1 displays ~56 pt of headroom under the
# menu bar without clipping the bottom bar).
if (( W < 200 || H < 200 )); then
    echo "release-smoke: window too small (${W}x${H}) — scene may have stalled before layout" >&2
    exit 1
fi

# --- Stage 3b (best-effort): screencapture by window id ---------------------
# Requires Screen Recording permission. Don't fail the gate if denied —
# the window-enumeration assertion above is already sufficient proof.
SHOT_NOTE=""
if screencapture -l"$WID" -x "$SHOT" >/dev/null 2>&1 && [[ -s "$SHOT" ]]; then
    SIZE="$(stat -f%z "$SHOT" 2>/dev/null || echo 0)"
    if (( SIZE > 20480 )); then
        SHOT_NOTE=" capture=${SIZE}B"
    else
        SHOT_NOTE=" capture=${SIZE}B(suspiciously-small)"
    fi
else
    SHOT_NOTE=" capture=skipped(no-screen-recording-perm)"
fi

echo
echo "release-smoke: PASS pid=$PID wid=$WID window=${W}x${H} waited=${WAIT_SECONDS}s${SHOT_NOTE}"
exit 0
