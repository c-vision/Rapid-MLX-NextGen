import Foundation
import Testing
@testable import Rapid

/// Contract for the Quick Ask launcher controller introduced in
/// v0.5.0. The controller owns:
///   - panel visibility (toggle / show / hide)
///   - the server-state gate that decides whether opening Quick Ask
///     makes sense (no point opening a chat surface when the binary
///     isn't even installed)
///   - the bridge into ``SessionStore`` for spawning a fresh session
///     per launcher invocation
///
/// We can't drive the SwiftUI panel here (no run loop, no NSWindow),
/// but the value-level state — ``isVisible``, ``sessionID``,
/// ``canOpen(serverState:)`` — is the contract every UI surface
/// depends on, so we pin those.
@MainActor
@Suite("QuickAskController — v0.5.0 launcher")
struct QuickAskControllerTests {

    // MARK: - Setup helpers

    private func makeController(
        defaultAlias: String = "qwen3.6-27b",
        serverState: ServerState = .ready(alias: "qwen3.6-27b")
    ) -> (QuickAskController, SessionStore, ChatViewModel, ServerManager) {
        // Each test gets its own tmp-backed SessionStore so writes
        // don't leak into the real user-defaults file.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quick-ask-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: tmp)
        let chat = ChatViewModel(store: store)
        let server = ServerManager(
            testingState: serverState,
            binaryPath: URL(fileURLWithPath: "/dev/null")
        )
        let controller = QuickAskController(
            store: store,
            chat: chat,
            server: server,
            defaultAlias: defaultAlias
        )
        return (controller, store, chat, server)
    }

    // MARK: - Initial state

    @Test("Controller starts hidden with no bound session")
    func initialState() {
        let (controller, _, _, _) = makeController()
        #expect(controller.isVisible == false)
        #expect(controller.sessionID == nil)
        #expect(controller.preferredAlias == "qwen3.6-27b")
    }

    // MARK: - canOpen() decision matrix

    @Test(".ready allows Quick Ask to open")
    func canOpenReady() {
        let (controller, _, _, _) = makeController()
        #expect(controller.canOpen(serverState: .ready(alias: "x")) == true)
    }

    @Test(".starting allows Quick Ask to open (panel renders warming-up state)")
    func canOpenStarting() {
        let (controller, _, _, _) = makeController()
        #expect(controller.canOpen(serverState: .starting(alias: "x")) == true)
    }

    @Test(".idle blocks Quick Ask — user needs main window to start server")
    func canOpenIdleBlocked() {
        let (controller, _, _, _) = makeController()
        #expect(controller.canOpen(serverState: .idle) == false)
    }

    @Test(".missing blocks Quick Ask — no binary to talk to")
    func canOpenMissingBlocked() {
        let (controller, _, _, _) = makeController()
        #expect(controller.canOpen(serverState: .missing) == false)
    }

    @Test(".stopped blocks Quick Ask — user explicitly stopped server")
    func canOpenStoppedBlocked() {
        let (controller, _, _, _) = makeController()
        #expect(controller.canOpen(serverState: .stopped) == false)
    }

    @Test(".crashed blocks Quick Ask — user needs main window to inspect logs")
    func canOpenCrashedBlocked() {
        let (controller, _, _, _) = makeController()
        let crashed = ServerState.crashed(alias: "x", message: "boom")
        #expect(controller.canOpen(serverState: crashed) == false)
    }

    // MARK: - show / hide / toggle

    @Test("show() flips isVisible to true")
    func showFlipsVisible() {
        let (controller, _, _, _) = makeController()
        controller.show()
        #expect(controller.isVisible == true)
    }

    @Test("hide() flips isVisible back to false")
    func hideFlipsHidden() {
        let (controller, _, _, _) = makeController()
        controller.show()
        controller.hide()
        #expect(controller.isVisible == false)
    }

    @Test("toggle() while hidden opens; toggle() while visible closes")
    func toggleAlternates() {
        let (controller, _, _, _) = makeController()
        #expect(controller.isVisible == false)
        controller.toggle()
        #expect(controller.isVisible == true)
        controller.toggle()
        #expect(controller.isVisible == false)
    }

    @Test("toggle() in .ready state opens the panel")
    func toggleReadyOpens() {
        let (controller, _, _, _) = makeController(serverState: .ready(alias: "x"))
        controller.toggle()
        #expect(controller.isVisible == true)
    }

    @Test("toggle() in .idle state does NOT open the panel — server gate")
    func toggleIdleBlocked() {
        let (controller, _, _, _) = makeController(serverState: .idle)
        controller.toggle()
        #expect(controller.isVisible == false)
    }

    // MARK: - preferredAlias resolution

    @Test("show() resolves preferredAlias to active session's alias when present")
    func showResolvesActiveAlias() {
        let (controller, store, _, _) = makeController(defaultAlias: "fallback-alias")
        // Seed the store with an active session bound to a specific
        // alias. show() should refresh ``preferredAlias`` to match.
        _ = store.newSession(alias: "qwen3.5-35b")
        controller.show()
        #expect(controller.preferredAlias == "qwen3.5-35b")
    }

    @Test("show() with no sessions keeps the default alias")
    func showKeepsDefaultWhenNoSessions() {
        let (controller, _, _, _) = makeController(defaultAlias: "fallback-alias")
        controller.show()
        #expect(controller.preferredAlias == "fallback-alias")
    }

    // MARK: - submit() session lifecycle

    @Test("submit() with empty text is a no-op and returns nil")
    func submitEmptyIsNoOp() {
        let (controller, store, _, _) = makeController()
        let before = store.sessions.count
        let result = controller.submit("   ")
        #expect(result == nil)
        #expect(controller.sessionID == nil)
        #expect(store.sessions.count == before)
    }

    @Test("submit() with non-empty text creates a new session bound to preferredAlias")
    func submitCreatesSession() {
        let (controller, store, _, _) = makeController(defaultAlias: "qwen3.5-4b")
        let id = controller.submit("hello")
        #expect(id != nil)
        #expect(controller.sessionID == id)
        let session = store.sessions.first(where: { $0.id == id })
        #expect(session != nil)
        #expect(session?.alias == "qwen3.5-4b")
    }

    @Test("Repeated submit() invocations each spawn a fresh session")
    func submitAlwaysNewSession() {
        // Quick Ask explicitly does NOT re-use a session across
        // hotkey invocations — that would silently graft the user's
        // chat onto whatever the main window had selected.
        let (controller, store, _, _) = makeController()
        let first = controller.submit("first prompt")
        let second = controller.submit("second prompt")
        #expect(first != second)
        #expect(store.sessions.count == 2)
    }

    // MARK: - dispatch() — slash commands (v0.5.0)

    @Test("dispatch(.newSession) clears the bound sessionID — next submit() spawns fresh")
    func dispatchNewSessionClearsSession() {
        let (controller, _, _, _) = makeController()
        _ = controller.submit("first")
        #expect(controller.sessionID != nil)
        let effect = controller.dispatch(.newSession)
        #expect(effect == .none)
        #expect(controller.sessionID == nil)
    }

    @Test("dispatch(.switchModel(alias:)) updates preferredAlias verbatim")
    func dispatchSwitchModelUpdatesAlias() {
        let (controller, _, _, _) = makeController(defaultAlias: "qwen3.6-27b")
        let effect = controller.dispatch(.switchModel(alias: "qwen3.5-4b-8bit"))
        #expect(effect == .none)
        #expect(controller.preferredAlias == "qwen3.5-4b-8bit")
    }

    @Test("dispatch(.help) returns showShortcuts — controller does not own the sheet")
    func dispatchHelpRequestsOverlay() {
        let (controller, _, _, _) = makeController()
        let effect = controller.dispatch(.help)
        #expect(effect == .showShortcuts)
    }

    @Test("dispatch(.close) hides the panel and reports dismissed")
    func dispatchCloseHidesPanel() {
        let (controller, _, _, _) = makeController()
        controller.show()
        #expect(controller.isVisible == true)
        let effect = controller.dispatch(.close)
        #expect(effect == .dismissed)
        #expect(controller.isVisible == false)
    }
}
