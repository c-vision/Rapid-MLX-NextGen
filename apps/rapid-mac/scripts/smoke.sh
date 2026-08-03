#!/usr/bin/env bash
# smoke.sh — fast (sub-2s) end-to-end smoke for Rapid.app.
#
# Runs the Swift Testing unit suite + the chat lifecycle directive
# against the fake rapid-mlx, so a code change can be verified
# without standing up a real model.
#
# What it covers:
#   * swift test (14 cases — DownloadProgress, UpdateChecker,
#     SessionStore roundtrip)
#   * ServerManager spawn / health-poll / state transitions
#     (.idle → .starting → .ready → .stopped)
#   * ChatStreamClient SSE decode (reasoning + content lanes,
#     finish_reason routing, clean [DONE])
#
# What it does NOT cover:
#   * Real model inference (use ``RAPID_BIN=/opt/homebrew/bin/rapid-mlx``
#     or unset RAPID_BIN for that)
#   * SwiftUI view tree (Step 2 — ViewInspector)
#   * Visual fidelity (Step 3 — snapshot testing)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift test"
swift test

echo
echo "==> chat lifecycle vs fake rapid-mlx"
# Build first so we time the smoke, not the compile.
swift build >/dev/null
start_ts="$(date +%s)"
RAPID_BIN="$ROOT/scripts/fake-rapid-mlx.sh" \
    RAPID_TEST_DRIVER='chat:fake-alias:hi there' \
    .build/debug/Rapid >/tmp/rapid-smoke.log 2>&1
end_ts="$(date +%s)"

if ! grep -q "post-stop state=stopped" /tmp/rapid-smoke.log; then
    echo "FAIL — chat smoke did not reach stopped state"
    tail -20 /tmp/rapid-smoke.log
    exit 1
fi
if ! grep -q "finished reason=stop" /tmp/rapid-smoke.log; then
    echo "FAIL — chat smoke did not reach finish_reason=stop"
    tail -20 /tmp/rapid-smoke.log
    exit 1
fi
content_chars="$(grep -E '^test_driver: total_content_chars=' /tmp/rapid-smoke.log | tail -1 | cut -d= -f2)"
reasoning_chars="$(grep -E '^test_driver: total_reasoning_chars=' /tmp/rapid-smoke.log | tail -1 | cut -d= -f2)"
echo "OK content=${content_chars}ch reasoning=${reasoning_chars}ch wall=$((end_ts - start_ts))s"
