import Foundation
import Testing
@testable import Rapid

/// Contract for ``ChatViewModel.streamingSessionID`` — drives the
/// per-row "generating" dot in ``SessionsSidebar``. The two
/// guarantees that matter for the sidebar to render correctly:
///
///   1. Fresh viewmodel reports nil (the sidebar should show no
///      dot before any send).
///   2. ``send`` populates it with the receiving session's ID at the
///      same moment ``isStreaming`` flips to true (sidebar updates
///      atomically with the chat surface).
///
/// We pin the receive-side here only; the defer in ``runToolLoop`` is
/// the single clear-side and is exercised by existing regenerate /
/// session-store tests via the same code path.
@MainActor
@Suite("ChatViewModel.streamingSessionID — sidebar indicator")
struct StreamingSessionIDTests {

    private func makeStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-stream-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    private func makeVM(store: SessionStore) -> ChatViewModel {
        ChatViewModel(
            store: store,
            client: ChatStreamClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        )
    }

    @Test("Fresh viewmodel reports nil streamingSessionID")
    func freshVMIsNil() {
        let store = makeStore()
        let vm = makeVM(store: store)
        #expect(vm.streamingSessionID == nil)
        #expect(vm.isStreaming == false)
    }

    @Test("send() populates streamingSessionID with the receiving session")
    func sendPopulates() {
        let store = makeStore()
        let id = store.newSession(alias: "fake-alias")
        let vm = makeVM(store: store)

        vm.send("hello", alias: "fake-alias")

        // Set synchronously before the Task suspension point so the
        // sidebar's next render frame sees the new value, not a
        // half-set state.
        #expect(vm.streamingSessionID == id)
        #expect(vm.isStreaming == true)
    }

    @Test("send() into an empty store creates a session and points at it")
    func sendWithoutSessionCreatesAndPoints() {
        let store = makeStore()
        let vm = makeVM(store: store)
        #expect(store.activeID == nil)

        vm.send("hello", alias: "fake-alias")

        // ``send`` spawns a new session when there's no active one.
        // streamingSessionID must follow the new id, not stay nil.
        let newID = try? #require(store.activeID)
        #expect(vm.streamingSessionID == newID)
    }

    @Test("Second send (while not streaming) flips streamingSessionID to the new target")
    func sendUpdatesAcrossSessions() async {
        let store = makeStore()
        let a = store.newSession(alias: "fake-alias")
        let vm = makeVM(store: store)

        vm.send("first", alias: "fake-alias")
        #expect(vm.streamingSessionID == a)

        // Wait for the connect failure to drain through the runToolLoop
        // defer so isStreaming flips back to false. The poll mirrors
        // the pattern existing async tests use against the dead-port
        // client (port 1).
        for _ in 0..<30 {
            if !vm.isStreaming { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? #require(!vm.isStreaming)
        #expect(vm.streamingSessionID == nil, "defer clears alongside isStreaming")

        let b = store.newSession(alias: "fake-alias")
        vm.send("second", alias: "fake-alias")
        #expect(vm.streamingSessionID == b)
    }
}
