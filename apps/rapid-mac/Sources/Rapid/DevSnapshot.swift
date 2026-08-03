import SwiftUI
import AppKit

/// DEV-ONLY visual snapshot harness.
///
/// When the `RAPID_DEV_SNAPSHOT_DIR` environment variable is set, this
/// renders the real SwiftUI screens to PNG via `ImageRenderer` and then
/// quits. It needs **no Screen-Recording permission** and works over
/// SSH / headless — `ImageRenderer` rasterises the actual view hierarchy
/// in-process, so it is the reliable way to eyeball the UI when
/// `screencapture` can only see the wallpaper.
///
/// Entirely gated on the env var: absent it, `runIfRequested` returns
/// immediately and nothing here runs in normal use. No product behaviour
/// change, no version bump.
enum DevSnapshot {
    @MainActor
    static func runIfRequested(
        server: ServerManager,
        downloads: DownloadManager,
        chat: ChatViewModel,
        updater: UpdateChecker,
        sampling: SamplingConfig,
        appearance: AppearanceConfig,
        settingsRouter: SettingsRouter,
        installTracker: InstallTracker,
        quickstart: QuickstartCoordinator,
        dockPromptStore: DockVisibilityPromptStore
    ) async {
        guard let dir = ProcessInfo.processInfo.environment["RAPID_DEV_SNAPSHOT_DIR"],
              !dir.isEmpty else { return }

        // Let @State init, first layout, and any cheap sync work settle.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        // Erase to AnyView so the long environment chain stays cheap to
        // type-check and the render call is monomorphic.
        func contentView(width: CGFloat, height: CGFloat) -> AnyView {
            AnyView(
                ContentView()
                    .tint(RapidTheme.brand)
                    .environment(server)
                    .environment(downloads)
                    .environment(chat)
                    .environment(updater)
                    .environment(sampling)
                    .environment(appearance)
                    .environment(settingsRouter)
                    .environment(installTracker)
                    .environment(quickstart)
                    .environment(dockPromptStore)
                    .frame(width: width, height: height)
            )
        }

        // Scenario 1: the app as launched (idle / first-run, depending on
        // whether HF_HUB_CACHE points at a populated cache).
        render(contentView(width: 900, height: 640), to: "\(dir)/content-idle.png")
        render(contentView(width: 640, height: 560), to: "\(dir)/content-min.png")

        // Scenario 2: a populated chat transcript, so we can eyeball the
        // streaming bubble / markdown render path that an empty transcript
        // never exercises.
        chat.devSeedMessages([
            ChatMessage(role: .user, content: "What can you help me with?"),
            ChatMessage(
                role: .assistant,
                content: """
                I run entirely on your Mac — no data leaves the machine. \
                I can answer questions, help with **code**, and explain \
                things. Here's a quick example:

                ```swift
                let greeting = "Hello from Rapid-MLX"
                print(greeting)
                ```

                Ask me anything.
                """,
                status: .complete,
                stats: MessageStats(
                    elapsedSeconds: 0.69,
                    charCount: 232,
                    promptTokens: 12,
                    completionTokens: 58
                )
            ),
        ])
        // Let the transcript layout settle before capturing.
        try? await Task.sleep(nanoseconds: 500_000_000)
        render(contentView(width: 900, height: 640), to: "\(dir)/content-chat.png")

        // Chat transcript bubbles, rendered without the ScrollView so the
        // seeded messages are actually visible.
        render(
            AnyView(
                ChatView(viewModel: chat, server: server,
                         alias: .constant("bonsai-1.7b-2bit"), serverReady: true)
                    .transcriptRows
                    .frame(width: 900)
                    .background(RapidTheme.canvas)
                    .tint(RapidTheme.brand)
            ),
            to: "\(dir)/chat-bubbles.png"
        )

        // Scenario 3: the "Connect your tools" sheet (pure SwiftUI, so it
        // renders faithfully — unlike the NSViewRepresentable composer).
        render(
            AnyView(
                ConnectToolsView(
                    host: "127.0.0.1", port: 8000,
                    bearer: "rapid-sk-demo1234567890abcdef",
                    alias: "bonsai-1.7b-2bit", onClose: {}
                ).cardContent
                    .frame(width: 460)
                    .background(RapidTheme.canvas)
                    .tint(RapidTheme.brand)
            ),
            to: "\(dir)/connect-tools.png"
        )

        // Scenario 4: the "Speed on this Mac" benchmark card, result state.
        let benchRunner = BenchmarkRunner()
        benchRunner.devSeed(phase: .done(BenchmarkResult(
            alias: "bonsai-1.7b-2bit", chip: "Apple M3 Ultra",
            throughputTPS: 836, tokensPerSecond: 781
        )))
        render(
            AnyView(
                BenchmarkView(
                    binary: nil, alias: "bonsai-1.7b-2bit",
                    hardware: MacHardware.detect(), onClose: {}, runner: benchRunner
                ).content
                    .frame(width: 440)
                    .padding(20)
                    .background(RapidTheme.canvas)
                    .tint(RapidTheme.brand)
            ),
            to: "\(dir)/benchmark-result.png"
        )

        // Scenario 5: the telemetry consent sheet (the privacy "gate").
        render(
            AnyView(
                TelemetryConsentView(onDecision: { _ in })
                    .frame(width: 460)
                    .background(RapidTheme.canvas)
                    .tint(RapidTheme.brand)
            ),
            to: "\(dir)/consent.png"
        )

        log("wrote PNGs to \(dir)")

        // LIVE mode: when RAPID_DEV_SERVE_ALIAS is set, actually start the
        // sidecar (resolved by ServerLocator — the bundled engine unless
        // RAPID_BIN overrides it), send one chat turn, and snapshot the
        // REAL streamed output — the runtime path static renders can't
        // reach. Then the normal terminate exercises clean teardown.
        if let liveAlias = ProcessInfo.processInfo.environment["RAPID_DEV_SERVE_ALIAS"],
           !liveAlias.isEmpty {
            await runLiveChat(
                alias: liveAlias, server: server, chat: chat,
                downloads: downloads, quickstart: quickstart, dir: dir
            )
        }

        // One-shot: quit so the dogfood harness gets a clean exit.
        NSApp.terminate(nil)
    }

    @MainActor
    private static func runLiveChat(
        alias: String, server: ServerManager, chat: ChatViewModel,
        downloads: DownloadManager, quickstart: QuickstartCoordinator, dir: String
    ) async {
        log("live: starting sidecar for \(alias)…")
        await server.start(alias: alias)
        guard case .ready = server.state else {
            log("live: server did not reach ready (state=\(server.state)) — skipping")
            return
        }
        log("live: ready on port \(server.activePort); sending a chat turn")
        chat.send("Say hello and name one thing you can help with, in one sentence.",
                  alias: alias)
        // Wait for the stream to finish (cap ~90s).
        for _ in 0..<180 {
            if !chat.isStreaming { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let msg = chat.messages.last(where: { $0.role == .assistant }) {
            log("live: streaming=\(chat.isStreaming) status=\(msg.status) "
                + "content=\(msg.content.count)ch reasoning=\(msg.reasoning.count)ch "
                + "err=\(msg.errorMessage ?? "-")")
            log("live: content='\(msg.content.prefix(160))'")
            if !msg.reasoning.isEmpty {
                log("live: reasoning='\(msg.reasoning.prefix(160))'")
            }
        } else {
            log("live: no assistant message (isStreaming=\(chat.isStreaming), lastError=\(chat.lastError ?? "-"))")
        }
        render(
            liveContentView(
                server: server, chat: chat,
                downloads: downloads, quickstart: quickstart
            ),
            to: "\(dir)/content-chat-live.png"
        )
        log("live: wrote content-chat-live.png; stopping sidecar")
        await server.stop()
    }

    @MainActor
    private static func liveContentView(
        server: ServerManager, chat: ChatViewModel,
        downloads: DownloadManager, quickstart: QuickstartCoordinator
    ) -> AnyView {
        // ChatView reads DownloadManager + QuickstartCoordinator from the
        // environment (the Ollama-layout composer/quickstart affordances);
        // inject both or ImageRenderer traps with "No Observable object of
        // type DownloadManager found". The real app supplies them from
        // RapidApp's scene — this render path must mirror that.
        AnyView(
            ChatView(
                viewModel: chat,
                server: server,
                alias: .constant(server.servingAlias ?? ""),
                serverReady: true
            )
            .environment(downloads)
            .environment(quickstart)
            .frame(width: 900, height: 640)
            .tint(RapidTheme.brand)
            .background(RapidTheme.canvas)
        )
    }

    @MainActor
    private static func render(_ view: AnyView, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            log("FAILED to render \(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            log("FAILED to write \(path): \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[dev-snapshot] \(message)\n".utf8))
    }
}
