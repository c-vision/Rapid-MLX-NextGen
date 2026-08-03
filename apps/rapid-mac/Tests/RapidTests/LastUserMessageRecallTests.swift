import Foundation
import Testing
@testable import Rapid

/// Contract tests for ``SessionStore.lastUserMessageInActiveSession``
/// — the resolver behind Up-arrow-in-empty-compose recall (Tier 1
/// Claude / Raycast convention). Keeps the resolver pure and unit-
/// testable; the AppKit-side wiring (``ComposeTextEditor.doCommandBy``
/// + ``moveUp:``) only forwards to it.
@MainActor
@Suite("SessionStore.lastUserMessageInActiveSession")
struct LastUserMessageRecallTests {

    private func freshStore() -> (SessionStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-recall-\(UUID().uuidString).json")
        return (SessionStore(customStoreURL: tmp), tmp)
    }

    @Test("Returns nil when no session is active")
    func nilWhenNoActiveSession() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = store.newSession(alias: "qwen3.6-27b")
        store.activeID = nil
        #expect(store.lastUserMessageInActiveSession == nil)
    }

    @Test("Returns nil when active session has no user turns")
    func nilWhenNoUserTurns() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "Hello! How can I help?")
        )
        #expect(store.lastUserMessageInActiveSession == nil)
    }

    @Test("Returns the most recent user message content")
    func returnsLatestUserMessage() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "first prompt")
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "first answer")
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "second prompt")
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "second answer")
        )
        #expect(store.lastUserMessageInActiveSession == "second prompt")
    }

    @Test("Skips assistant turns to find the prior user message")
    func skipsAssistantTurns() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "prompt")
        )
        // Multiple assistant turns simulating regenerate + tool
        // responses. The recall should still surface "prompt".
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "draft 1")
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "draft 2")
        )
        #expect(store.lastUserMessageInActiveSession == "prompt")
    }

    @Test("Treats an empty-content user turn (attachment-only) as nil")
    func emptyContentUserTurnIsNil() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let id = store.newSession(alias: "qwen3.6-27b")
        // Attachment-only send: content is the empty string. Seeding
        // the compose with "" is no improvement over leaving it
        // empty, so the resolver should treat this as nothing-to-
        // recall.
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "")
        )
        #expect(store.lastUserMessageInActiveSession == nil)
    }

    @Test("Multi-line user prompts come back verbatim including newlines")
    func multilinePromptPreserved() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let id = store.newSession(alias: "qwen3.6-27b")
        let multi = "Line one\nLine two\nLine three"
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: multi)
        )
        #expect(store.lastUserMessageInActiveSession == multi)
    }

    @Test("Recall reflects the currently active session, not a sibling")
    func recallFollowsActiveID() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: a,
            ChatMessage(role: .user, content: "from A")
        )
        let b = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: b,
            ChatMessage(role: .user, content: "from B")
        )
        // Newest session b is active by construction.
        #expect(store.lastUserMessageInActiveSession == "from B")
        // Flip active to a and re-check.
        store.activeID = a
        #expect(store.lastUserMessageInActiveSession == "from A")
    }
}
