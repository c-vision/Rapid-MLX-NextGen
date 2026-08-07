# AX-first GUI golden flows

`scripts/gui-golden-flows.sh` runs the five release journeys against a built
Rapid-MLX Desktop app without loading a real model:

1. fresh install, consent, onboarding, and steady-state shell;
2. Settings mutation and persistence across an app relaunch;
3. basic chat, persisted conversation row, and restored transcript;
4. a deliberately slow stream and semantic **Stop generating** action;
5. model start, a one-shot sidecar crash, automatic respawn, and ready state.

Every journey gets a unique bundle identifier and throwaway `HOME` through
`dogfood-isolate.sh`. The fake sidecar emits deterministic SSE and JSONL
lifecycle evidence, so the suite does not download a model or put meaningful
pressure on unified memory.

## Run

Build the current checkout, then run all flows:

```bash
cd apps/rapid-mac
SKIP_SIDECAR=1 BUNDLE_MODEL=0 ./scripts/build.sh
./scripts/gui-golden-flows.sh
```

Run one journey or retain its isolated persona for diagnosis:

```bash
./scripts/gui-golden-flows.sh --flow slow-stream-stop
./scripts/gui-golden-flows.sh --flow chat-restore --keep
```

Set `RAPID_GUI_SOURCE_APP` to test a release candidate bundle and
`RAPID_GUI_GOLDEN_OUT` to choose the artifact directory. Each run records AX
trees, actions, fake-sidecar events, logs, and a top-level `result.json`.

## Why this is not coordinate automation

The checked-in `rapid-ax.swift` helper talks directly to macOS Accessibility.
It finds controls by stable `AXIdentifier`, performs `AXPress`, sets native text
values, and serializes roles/descriptions/values for assertions. Peekaboo is
kept for permission checks, window discovery, menu interaction, and screenshots.
The only coordinate fallback is the documented first-run SwiftUI consent-sheet
fallback, derived from AX bounds, for older accessibility stacks.

This makes normal actions independent of window position, resolution, theme,
and most layout changes. It also avoids Peekaboo snapshot publication failures
seen while the ready-state UI is updating. The app does not need to own the
foreground for ordinary AX actions; menu operations and screenshots may briefly
activate it, so release CI should still use a dedicated logged-in macOS session.

## Adding a flow

Prefer a stable `.accessibilityIdentifier(...)` in product code, then assert
observable user state rather than sleeps or pixels. Keep model behavior behind
the fake sidecar unless the purpose of the flow is real inference quality. A
real-model dogfood pass remains a separate, explicitly memory-budgeted release
stage.
