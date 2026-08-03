import Foundation
import Testing
@testable import Rapid

/// Contract for the Ollama / LM Studio "global model binding" shape
/// landed in v0.5.1.
///
/// **The bug it closes:** in v0.5.0 each ``ChatSession`` carried its own
/// pinned alias, and ``ChatViewModel.send`` would overwrite that pin
/// with whatever the model picker currently showed. Combined with the
/// picker / spawn race during a model switch, that surfaced as the
/// user typing into a chat while the request landed on a DIFFERENT
/// model — or, worse, the server 404'ing because the request said one
/// alias and the resident model said another (see PR for screenshot).
///
/// **The shape we want:** there is a single "currently loaded" model,
/// owned by ``ServerManager``. Every outgoing chat request uses that
/// alias regardless of session metadata. ``ChatSession.alias`` becomes
/// historical "first sent to X" metadata, not an enforced pin.
@MainActor
@Suite("Global model binding (Ollama / LM Studio shape)")
struct GlobalModelBindingTests {
    @Test("ServerManager.servingAlias reflects .ready(alias:) only")
    func servingAliasOnlyOnReady() {
        // The chat loop reads ``servingAlias`` to decide the
        // ``model:`` field on the wire. Any state other than
        // ``.ready`` must surface ``nil`` so the loop falls back to
        // the caller's hint instead of pretending an alias is live.
        let ready = ServerManager(testingState: .ready(alias: "qwen3.6-27b-4bit"))
        #expect(ready.servingAlias == "qwen3.6-27b-4bit")

        let starting = ServerManager(testingState: .starting(alias: "qwen3.6-27b-4bit"))
        #expect(starting.servingAlias == nil)

        let idle = ServerManager(testingState: .idle)
        #expect(idle.servingAlias == nil)

        let crashed = ServerManager(testingState: .crashed(alias: "qwen3.6-27b-4bit", message: "OOM"))
        #expect(crashed.servingAlias == nil)

        let stopped = ServerManager(testingState: .stopped)
        #expect(stopped.servingAlias == nil)

        let missing = ServerManager(testingState: .missing)
        #expect(missing.servingAlias == nil)
    }

    @Test("send() preserves the session's historical alias instead of overwriting it with the picker's value")
    func sendDoesNotOverwriteSessionAlias() async {
        // Seed a session that was first opened against
        // ``qwen3.5-4b-4bit`` (the v0.5.0 stale-pin scenario from
        // the bug report). The user then switches the picker to
        // ``qwopus-9b-4bit`` and types into the OLD chat. The pre-
        // v0.5.1 code path called ``setAlias(picker, …)`` inside
        // ``send`` and rewrote the historical alias — losing the
        // breadcrumb of which model first answered.
        let store = SessionStore(customStoreURL: tempPersistenceURL())
        let originalAlias = "qwen3.5-4b-4bit"
        let sid = store.newSession(alias: originalAlias)
        store.activeID = sid

        let server = ServerManager(testingState: .ready(alias: "qwopus-9b-4bit"))
        let vm = ChatViewModel(store: store, server: server)

        // Fire ``send`` with the picker's NEW alias. The request
        // never reaches a network because no rapid-mlx is running —
        // we only care about the synchronous bookkeeping: did the
        // store's alias survive? (The streaming task will fail
        // immediately on the real socket; that's fine.)
        vm.send("hello", alias: "qwopus-9b-4bit")

        // The historical alias must stay pinned to what created
        // the session, not the picker value. UI surfaces this as
        // the "first sent to X" caption in the sidebar.
        let session = store.sessions.first(where: { $0.id == sid })
        #expect(session?.alias == originalAlias)

        // Clean up the inflight stream so the test doesn't leak a
        // Task into the next case.
        vm.stop()
    }

    /// Drop a throwaway persistence URL under the OS temp dir. Each
    /// test gets its own UUID-suffixed path so SessionStore writes
    /// can't bleed across cases.
    private func tempPersistenceURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("rapid-global-binding-\(UUID().uuidString).json")
    }
}
