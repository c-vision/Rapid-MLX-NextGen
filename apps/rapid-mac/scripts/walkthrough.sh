#!/usr/bin/env bash
# scripts/walkthrough.sh — drive the F1-F10 release walkthrough via
# AppleScript AXIdentifier lookups. Built to replace the cliclick-by-
# coordinate flow that lost contact with SwiftUI gesture recognizers
# (typing + keyboard shortcuts work via cliclick; mouse clicks land at
# the right pixel but don't trigger button onClick handlers).
#
# Prereq: the running build must be from a tree that wires the
# matching `.accessibilityIdentifier(...)` modifiers on each control.
# `feat/walkthrough-a11y-identifiers` is the seed PR that introduced
# the three identifiers used below; subsequent walkthrough additions
# extend the list incrementally.
#
# Usage:
#   scripts/walkthrough.sh                  # quit + relaunch + run
#   scripts/walkthrough.sh --no-relaunch    # assume app already up
#
# Screencaps land under /tmp/rapid-walkthrough-<UTC>/.
set -euo pipefail

APP="Rapid-MLX"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="/tmp/rapid-walkthrough-${STAMP}"
mkdir -p "$OUT"
echo "==> screencaps + logs → $OUT"

if [[ "${1:-}" != "--no-relaunch" ]]; then
    osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
    sleep 3
    open -a "$APP"
    sleep 6
fi

osascript -e "tell application \"$APP\" to activate"
sleep 1

# --- F1: launch + first window present ---
echo "==> F1 launch"
screencapture -x "$OUT/F1_launch.png"

# --- F5: click primary Start/Download&start button via AXIdentifier ---
echo "==> F5 ModelPickerBar.PrimaryButton click"
osascript <<'OSA' 2>&1 | tee "$OUT/F5_click.log"
tell application "System Events"
    tell process "Rapid-MLX"
        try
            -- Use the AXIdentifier attribute to find the primary
            -- start/stop button regardless of which state-label it
            -- currently renders (Download & start / Start / Stop).
            set primary to (first button of window 1 whose value of attribute "AXIdentifier" is "ModelPickerBar.PrimaryButton")
            click primary
            return "clicked: " & (description of primary)
        on error errmsg number errnum
            return "FAIL (" & errnum & "): " & errmsg
        end try
    end tell
end tell
OSA
sleep 6
screencapture -x "$OUT/F5_after_click.png"

# --- F2: sidebar New chat ---
echo "==> F2 Sidebar.NewChat click"
osascript <<'OSA' 2>&1 | tee "$OUT/F2_newchat.log"
tell application "System Events"
    tell process "Rapid-MLX"
        try
            set newChat to (first button of window 1 whose value of attribute "AXIdentifier" is "Sidebar.NewChat")
            click newChat
            return "clicked: " & (description of newChat)
        on error errmsg number errnum
            return "FAIL (" & errnum & "): " & errmsg
        end try
    end tell
end tell
OSA
sleep 2
screencapture -x "$OUT/F2_after_newchat.png"

# --- F3: type + send via SendOrStopButton ---
echo "==> F3 type message + click ChatView.SendOrStopButton"
osascript <<'OSA'
tell application "Rapid-MLX" to activate
delay 0.5
tell application "System Events"
    keystroke "What is 7 plus 5? Answer in one word."
end tell
OSA
sleep 1
osascript <<'OSA' 2>&1 | tee "$OUT/F3_send.log"
tell application "System Events"
    tell process "Rapid-MLX"
        try
            set sendBtn to (first button of window 1 whose value of attribute "AXIdentifier" is "ChatView.SendOrStopButton")
            click sendBtn
            return "clicked: " & (description of sendBtn)
        on error errmsg number errnum
            return "FAIL (" & errnum & "): " & errmsg
        end try
    end tell
end tell
OSA
sleep 10
screencapture -x "$OUT/F3_after_send.png"

# --- F4: settings ---
echo "==> F4 settings via Cmd+,"
osascript <<'OSA'
tell application "System Events"
    keystroke "," using command down
end tell
OSA
sleep 2
screencapture -x "$OUT/F4_settings.png"
osascript <<'OSA'
tell application "System Events"
    keystroke "w" using command down
end tell
OSA

# --- F8: bottom-bar version pill (visual check only) ---
echo "==> F8 footer version pill — visual"
screencapture -x "$OUT/F8_footer.png"

# --- F7: quit lifecycle ---
echo "==> F7 quit"
osascript -e "tell application \"$APP\" to quit"
sleep 4
if pgrep -fl "Rapid-MLX Desktop|/Rapid$" >/dev/null 2>&1; then
    echo "FAIL: app still running after quit"
    exit 1
fi
echo "==> quit clean"

echo "==> walkthrough done. Screencaps at $OUT"
ls "$OUT"
