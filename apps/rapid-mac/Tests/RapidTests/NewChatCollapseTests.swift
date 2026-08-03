import Foundation
import Testing
@testable import Rapid

/// v0.4.44 contract pins for the "New chat collapses to existing
/// empty session" behaviour. Models ChatGPT Desktop's pattern: ⌘N
/// or "New chat" five times in a row produces at most one empty
/// row, not five.
@MainActor
@Suite("New-chat collapse — v0.4.44")
struct NewChatCollapseTests {
    private func makeStore() -> SessionStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-new-chat-collapse-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Fresh store: first newOrReuseSession creates a new session, reused=false")
    func freshStoreCreates() {
        let store = makeStore()
        let result = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(!result.reused)
        #expect(store.sessions.count == 1)
        #expect(store.activeID == result.id)
    }

    @Test("Two consecutive ⌘N → still ONE session (collapse)")
    func consecutiveNewChatsCollapse() {
        let store = makeStore()
        let a = store.newOrReuseSession(alias: "qwen3.5-4b")
        let b = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(a.id == b.id, "Second New chat must reuse the still-empty first session")
        #expect(b.reused, "reused flag should be true on the second call")
        #expect(store.sessions.count == 1, "Sidebar must not accumulate empty rows")
    }

    @Test("After a user message lands, next ⌘N creates a fresh session")
    func sendUnlocksNewChat() {
        let store = makeStore()
        let first = store.newOrReuseSession(alias: "qwen3.5-4b").id
        store.appendMessage(sessionID: first, ChatMessage(role: .user, content: "Hello"))
        let second = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(second.id != first, "Must create fresh once the previous session has content")
        #expect(!second.reused)
        #expect(store.sessions.count == 2)
    }

    @Test("Pinned empty session does NOT get reused")
    func pinnedSessionsNotReused() {
        // A user who explicitly pinned an empty session has
        // signalled intent for that row to persist. Reusing it
        // would erase the user's "keep this slot open" gesture.
        let store = makeStore()
        let pinned = store.newOrReuseSession(alias: "qwen3.5-4b").id
        store.togglePin(id: pinned)
        let next = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(next.id != pinned, "Pinned empties must not be collapsed into")
        #expect(!next.reused)
    }

    @Test("Renamed empty session does NOT get reused")
    func renamedSessionsNotReused() {
        // Custom title is a stronger signal than "I clicked New
        // chat by accident" — the user named the row before
        // typing anything. Treat the rename as intent to keep
        // the row.
        let store = makeStore()
        let renamed = store.newOrReuseSession(alias: "qwen3.5-4b").id
        store.renameSession(id: renamed, to: "Brainstorm — Q3 strategy")
        let next = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(next.id != renamed, "Renamed empties must not be collapsed into")
    }

    @Test("System-prompt-set empty session does NOT get reused")
    func systemPromptSessionsNotReused() {
        // Setting a system prompt on a fresh row is preparation
        // for a specific conversation — wiping that prep by
        // collapsing the next New chat into it would erase work
        // the user already invested.
        let store = makeStore()
        let prepped = store.newOrReuseSession(alias: "qwen3.5-4b").id
        store.setSystemPrompt(id: prepped, "You are a senior backend engineer.")
        let next = store.newOrReuseSession(alias: "qwen3.5-4b")
        #expect(next.id != prepped, "Prepped empties must not be collapsed into")
    }

    @Test("firstReusableEmptySession returns nil when sidebar has only non-reusable rows")
    func firstReusableNil() {
        let store = makeStore()
        let id = store.newOrReuseSession(alias: "qwen3.5-4b").id
        store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "hi"))
        #expect(store.firstReusableEmptySession() == nil)
    }
}
