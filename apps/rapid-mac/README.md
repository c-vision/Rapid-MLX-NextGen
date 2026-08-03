# rapid-desktop

Native SwiftUI Mac client for [rapid-mlx](https://github.com/raullenchai/Rapid-MLX).
Local-first inference with a ChatGPT-Desktop / Ollama feel — Apple Silicon,
your weights, your prompts, your data.

## Status

v0.5.16 (current). The SwiftUI surface is the only shipped client.
The Tauri v0.1.13 build is archived on branch
[`archive/tauri-v0.1`](https://github.com/machinefi/rapid-desktop/tree/archive/tauri-v0.1).

Closed-source — see [LICENSE](LICENSE). Free for personal AND commercial use
inside a company, team, or organization (no separate license required).

## Install

```bash
brew tap machinefi/tap
brew install --cask rapid-desktop
```

Or download the latest signed + notarised `.dmg` directly from
[GitHub Releases](https://github.com/machinefi/rapid-desktop/releases/latest).
The Homebrew Cask manifest lives at
[`Casks/rapid-desktop.rb`](Casks/rapid-desktop.rb) — see
[`Casks/README.md`](Casks/README.md) for the publish flow.

## Build from source

```bash
bash scripts/build.sh
open "build/Rapid-MLX Desktop.app"
```

Requires Xcode 16 / Swift 6.0 (macOS 14+). Production releases are signed +
notarised via `.github/workflows/release.yml`.

To enable in-app Sentry Feedback in a local app bundle, provide the public
project DSN while building:

```bash
SENTRY_DSN='https://98bf167a934acfa87a2a45f048b57991@o512435.ingest.us.sentry.io/4511811466428416' bash scripts/build.sh
```

`swift run` reads the same environment variable at runtime. Release builds
inject it from the `SENTRY_DSN` GitHub Actions secret into the app's
`Info.plist`.

## Features

### Chat
- SSE streaming with hybrid `thinking` / `content` split for
  Qwen 3.5 / 3.6 + GLM 4.7 + DeepSeek V4.
- Tool-calling end-to-end (calculator, datetime, weather, filesystem,
  web_search). User-visible permission prompts; Keychain-stored API keys.
- Markdown + code-block syntax highlighting, copy-as-markdown,
  copy code block, copy plain.
- Bidi / control-character sanitisation on every transcript + pasteboard
  surface (audit batch 11).

### Sessions
- Sidebar with pin, rename, fork (branching), delete, multi-select,
  export to `.md`.
- Cmd+1..9 quick switch, ChatGPT-style date grouping, in-session search.
- Atomic JSON persistence with serialised concurrent-write chain
  (audit batch 5).

### Server lifecycle
- Auto-spawn `rapid-mlx serve`, surfaces Downloading / Preparing /
  WarmingUp phases distinctly so users don't think a slow model load
  is a crash.
- Loopback-only readiness probe — `ServerManager` polls
  `http://127.0.0.1:<port>/healthz` on the same loopback the spawned
  child binds to. No auth gate today; per-launch token + Bearer
  enforcement on `/v1/chat/completions` is tracked under
  [issue #17](https://github.com/machinefi/rapid-desktop/issues/17)
  (cross-repo, needs a coordinated `rapid-mlx` CLI change).
- Background `rapid-mlx pull` downloads — fetch a new model while another
  keeps serving.

### Quick Ask
- ⌥+Space global floating panel (Alfred / Raycast / ChatGPT-Desktop
  pattern), user-rebindable.
- Carbon `RegisterEventHotKey` with explicit `EventHotKeyID` verification
  (audit batch 7).

### Model picker
- Cached vs. all aliases, green-dot for downloaded, per-alias size +
  memory hint, recent-aliases shortcut.
- Bounded-deletion contract: canonical-path + hard-prefix check before
  `removeItem`; no rm-rf-on-edge-case (audit batch 10).

### Attachments
- Image (multimodal models) + text-file (any model).
- MIME-sniff gate so a renamed `.html` can't ride into the multimodal
  payload as `data:image/...` (audit batch 12).

### Sampling
- Temperature, top_p, top_k, repetition_penalty knobs.
- Per-model presets driven by `rapid-mlx`'s recommended_sampling.
- Out-of-range / NaN clamping on both load and write (audit batch 12).

### Self-update
- Polls `https://rapidmlx.com/api/desktop-update?v=<app-version>` on
  launch and every 6 hours — a CF Worker returning the same release
  manifest as the R2 object, which also counts the poll as an aggregate
  active-install signal. The **only** data sent is the app version;
  the Worker keeps aggregate version/country counts and never stores
  the IP. Opt out with `RAPIDMLX_NO_UPDATE_CHECK=1` or `DO_NOT_TRACK=1`
  (skips the request entirely). See [PRIVACY.md](PRIVACY.md).
- Host-allowlist on every "Update available" CTA so a compromised
  manifest can't redirect the DMG download to phishing (audit batch 2).
- Sparkle migration on the roadmap ([#16](https://github.com/machinefi/rapid-desktop/issues/16)).

### Telemetry (opt-in)
- Explicit first-run choice; telemetry stays off until accepted and remains
  toggleable in Settings → Privacy.
- Desktop `session_start` + `error` and embedded-engine
  `session_start` / `session_end` / sampled `request` / `error` events go to
  `telemetry.rapidmlx.com` (Cloudflare Worker → R2) under one shared anonymous
  client ID, so the app and sidecar do not double-count an install.
- PII-redacted paths (`/Users/<name>/` scrubbed), 256 KB body cap,
  redirect-free ephemeral URLSession, no-cookie, 4xx classified as
  permanent (no retry-forever) (audit batch 8).
- See [PRIVACY.md](PRIVACY.md) for the field list, reset behavior, and raw-data
  retention.

### Crash reporting
- `NSException` + signal handlers write per-launch markers to
  `~/Library/Application Support/Rapid/crash-markers/` (0600 perms).
- Next launch flushes them as `error` events; permanent 4xx response
  retires the marker, transient 5xx + network errors keep it for retry.

### Feedback
- Help and menu-bar entries open a native macOS feedback form for bug reports
  and feature requests.
- User-submitted text, optional email, and standard Sentry app/device context
  are sent through Sentry. This context includes app, macOS, hardware, memory,
  processor, power/thermal, locale, and time-zone details. Chat content and
  attachments are never included.
- Sentry's automatic crash, performance, session, metric, and breadcrumb
  collection is disabled; the existing first-party crash pipeline remains the
  only automatic diagnostics path.

## Smoke test

```bash
bash scripts/smoke.sh
```

`swift test` (~720 cases — DownloadProgress, UpdateChecker,
SessionStore, ChatStreamClient SSE, sandbox + canonical-path contracts,
audit-batch contracts, snapshot tests) + chat lifecycle against a fake
`rapid-mlx`, end-to-end in under 15 s.

## Release-smoke gate

```bash
bash scripts/release-smoke.sh
```

Catches v0.5.9-class ship-blockers (SPM `Bundle.module` accessor crashing
inside the wrapped `.app` on first SwiftUI body read). Mandatory before
tagging a release. Verifies every PNG declared in `Package.swift`
resolves via `Bundle.main.url(forResource:)` against the assembled
bundle, then `open`s the app, waits 15 s, and asserts a substantial
layer-0 window owned by the launched PID actually rendered via
`CGWindowListCopyWindowInfo`. Exit codes: 0 pass, 1 scene never
rendered, 2 resource verification failed pre-launch.

## Architecture

```
RapidApp (SwiftUI Scene root)
├── ContentView                  — server state gating + chat surface
│   ├── SessionsSidebar          — NavigationSplitView left pane
│   ├── ModelPickerBar           — header alias picker + status badge
│   └── ChatView                 — assistant / user bubbles + compose bar
├── QuickAskPanel                — ⌥+Space NSPanel host
├── Settings                     — sidebar tabs (NavigationSplitView,
│                                        not the system Settings strip):
│                                        Tools / Web Search / Sampling /
│                                        Appearance / Quick Ask /
│                                        Keyboard / Privacy / rapid-mlx
└── MenuBarExtra                 — tray icon + update CTA + Quit
```

State holders are `@Observable` classes injected via SwiftUI `environment`:
`ServerManager`, `SessionStore`, `ChatViewModel`, `DownloadManager`,
`SandboxManager`, `UpdateChecker`, `Installer`, `CLIVersionChecker`,
`SamplingConfig`, `AppearanceConfig`, `OnboardingState`, `SettingsRouter`,
`WebSearchConfig`, `QuickAskController`, `QuickAskConfig`, `LaunchAtLogin`.
`BuiltinToolRegistry` is a plain `final class` (NOT `@Observable`) — only
its `sandbox` child is injected. `DownloadProgress` is `@Observable` but
owned by `DownloadManager` rather than injected directly into the env.

## Releasing

Pushing a `v*` tag triggers `.github/workflows/release.yml`:

1. Imports the `Developer ID Application` certificate into a temp keychain
2. `bash scripts/build.sh` → `build/Rapid-MLX Desktop.app`
3. `codesign --options runtime --timestamp` with hardened runtime
4. `scripts/dmg.sh` → `rapid-mlx-desktop.dmg`
5. `xcrun notarytool submit` via App Store Connect API key
6. `xcrun stapler staple` on both `.app` and `.dmg`
7. Attaches `rapid-mlx-desktop.dmg` to the GitHub Release (the R2 mirror
   step in `release.yml` additionally publishes the legacy alias `Rapid.dmg` so pre-v0.5.22 inbound links continue to resolve)

Required repo secrets:
`MACOS_DEVID_CERT_P12_BASE64`, `MACOS_DEVID_CERT_PASSWORD`,
`APPLE_TEAM_ID`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`,
`AC_API_KEY_P8_BASE64`.

`workflow_dispatch` does the same build but uploads as a workflow
artifact (no release) for dry-runs.

## Security

Reporting a vulnerability: see [SECURITY.md](SECURITY.md).

## License

Closed-source — see [LICENSE](LICENSE).
Third-party components: [THIRD_PARTY.md](THIRD_PARTY.md).
