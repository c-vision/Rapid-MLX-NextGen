import Foundation
import Testing
@testable import Rapid

/// Contract for ``ChatViewModel.regenerateLast``. The semantics that
/// matter: trims everything after the last user turn (inclusive of any
/// assistant tail) before resubmitting. Anything weaker leaves
/// stale assistant content in the transcript or, worse, regenerates
/// from a stale user prompt.
@MainActor
@Suite("ChatViewModel.regenerateLast trims and resends")
struct RegenerateTests {
    private func makeStore() -> SessionStore {
        // Per-test temp file so concurrent runs don't clobber each other.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Drops only the assistant tail, leaves prior user turns intact")
    func dropsAssistantTail() {
        let store = makeStore()
        let id = store.newSession(alias: "fake-alias")
        store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "first"))
        store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "reply 1", status: .complete))
        store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "follow-up"))
        store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "reply 2", status: .complete))

        // Use a stub client so we don't try to POST during the test.
        let vm = ChatViewModel(store: store, client: ChatStreamClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        vm.regenerateLast(alias: "fake-alias")

        // After regenerate: the second assistant ("reply 2") should be gone
        // and a fresh user turn for "follow-up" should be appended again
        // (the existing send() path re-appends the user message). We assert
        // by checking the user-prompt suffix lines up.
        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        let userTurns = messages.filter { $0.role == .user }.map { $0.content }
        #expect(userTurns == ["first", "follow-up"])
        // The pre-existing "reply 1" assistant message must survive — only
        // the tail assistant turn gets dropped.
        let assistantTurns = messages.filter { $0.role == .assistant }
        #expect(assistantTurns.first?.content == "reply 1")
        // The post-regenerate assistant placeholder is .streaming (the
        // stream will fail because we point at a dead port, but the
        // bookkeeping should be correct).
        #expect(assistantTurns.last?.status == .streaming)
    }

    @Test("No-op when there are no user turns yet")
    func noUserTurnsIsNoop() {
        let store = makeStore()
        _ = store.newSession(alias: "fake-alias")
        // System or empty session — no user turns. regenerateLast should
        // bail without throwing or appending placeholders.
        let vm = ChatViewModel(store: store, client: ChatStreamClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        vm.regenerateLast(alias: "fake-alias")
        let count = store.sessions.first?.messages.count ?? 0
        #expect(count == 0)
    }

    @Test("Retries a .failed assistant tail — drops the failure, re-sends the user prompt (v0.4.6 Retry button)")
    func retriesFailedAssistantTail() {
        let store = makeStore()
        let id = store.newSession(alias: "fake-alias")
        store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "what's the weather?"))
        // Simulates the v0.4.5 mid-chat-crash outcome: partial content,
        // then status flipped to .failed by the streamTruncated catch
        // path in ChatViewModel.runOneStream.
        var failed = ChatMessage(role: .assistant, content: "It's curr", status: .failed)
        failed.errorMessage = "rapid-mlx closed the stream mid-response (likely a crash)."
        store.appendMessage(sessionID: id, failed)

        let vm = ChatViewModel(store: store, client: ChatStreamClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        vm.regenerateLast(alias: "fake-alias")

        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        // The .failed assistant turn must be gone — leaving stale red
        // bubbles around after a Retry would be confusing UX.
        #expect(!messages.contains(where: { $0.status == .failed }))
        // The original user prompt must still be exactly once in the
        // transcript (regenerateLast re-appends it via send()).
        let userTurns = messages.filter { $0.role == .user }.map { $0.content }
        #expect(userTurns == ["what's the weather?"])
        // A fresh .streaming placeholder should be in flight.
        #expect(messages.last?.role == .assistant)
        #expect(messages.last?.status == .streaming)
    }

    @Test("No-op while streaming — Stop is the exit path, not Regenerate")
    func noopWhileStreaming() {
        let store = makeStore()
        let id = store.newSession(alias: "fake-alias")
        store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "ping"))
        store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "pong", status: .streaming))

        // Spin up a vm and force isStreaming=true the same way runStream
        // would. We do this via send() to a dead port, which sets the
        // flag, then assert regenerate is a no-op until the inflight task
        // settles. We don't await the failure here — just observe the
        // synchronous skip.
        let vm = ChatViewModel(store: store, client: ChatStreamClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        vm.send("ping", alias: "fake-alias")
        let pre = store.sessions.first(where: { $0.id == id })?.messages.count ?? 0
        vm.regenerateLast(alias: "fake-alias")
        let post = store.sessions.first(where: { $0.id == id })?.messages.count ?? 0
        #expect(pre == post)
    }
}
