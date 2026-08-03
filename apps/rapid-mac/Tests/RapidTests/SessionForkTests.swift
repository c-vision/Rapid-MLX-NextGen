import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.20 conversation fork. Pins:
///   - fork through a user turn keeps that turn AND everything before it
///   - alias + systemPrompt are inherited
///   - branch title carries a "(branch)" suffix
///   - branch starts unpinned even if parent is pinned
///   - branch becomes the active session
///   - message IDs in the branch are fresh (no SwiftUI id collisions)
///   - unknown sessionID / messageID is a no-op
@MainActor
@Suite("SessionStore.fork — v0.4.20 conversation branching")
struct SessionForkTests {
    private func freshStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    /// Build a parent session with 4 turns (user/asst/user/asst). The
    /// returned tuple gives us the session ID and the IDs of the
    /// individual messages so tests can fork through any of them.
    private func parentWithTurns(in store: SessionStore) -> (UUID, [UUID]) {
        let pid = store.newSession(alias: "qwen3.6-27b")
        store.setSystemPrompt(id: pid, "You are a curt reviewer.")
        let u1 = ChatMessage(role: .user, content: "First user")
        let a1 = ChatMessage(role: .assistant, content: "First reply", status: .complete)
        let u2 = ChatMessage(role: .user, content: "Second user")
        let a2 = ChatMessage(role: .assistant, content: "Second reply", status: .complete)
        store.appendMessage(sessionID: pid, u1)
        store.appendMessage(sessionID: pid, a1)
        store.appendMessage(sessionID: pid, u2)
        store.appendMessage(sessionID: pid, a2)
        return (pid, [u1.id, a1.id, u2.id, a2.id])
    }

    @Test("Forking through a mid-conversation user turn keeps that turn and the prefix")
    func keepsThroughSelected() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[2])!  // second user
        let branch = store.sessions.first(where: { $0.id == branchID })!
        // 3 messages: u1, a1, u2 — the second assistant reply is dropped.
        #expect(branch.messages.count == 3)
        #expect(branch.messages.map { $0.content } == ["First user", "First reply", "Second user"])
    }

    @Test("Branch inherits the parent's alias and system prompt")
    func inheritsAliasAndSystemPrompt() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[0])!
        let branch = store.sessions.first(where: { $0.id == branchID })!
        #expect(branch.alias == "qwen3.6-27b")
        #expect(branch.systemPrompt == "You are a curt reviewer.")
    }

    @Test("Branch title carries a '(branch)' suffix derived from the parent title")
    func titleHasBranchSuffix() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        store.renameSession(id: pid, to: "Pittsburgh weather")
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[0])!
        let branch = store.sessions.first(where: { $0.id == branchID })!
        #expect(branch.title == "Pittsburgh weather (branch)")
    }

    @Test("New-chat-titled parent still produces a labelled branch title")
    func newChatParentTitleFallback() {
        let store = freshStore()
        let pid = store.newSession(alias: "fake-alias")
        let m = ChatMessage(role: .user, content: "x")
        store.appendMessage(sessionID: pid, m)
        // The first-turn auto-rename uses the content; force it back.
        store.renameSession(id: pid, to: "New chat")
        let branchID = store.fork(sessionID: pid, throughMessageID: m.id)!
        let branch = store.sessions.first(where: { $0.id == branchID })!
        #expect(branch.title == "New chat (branch)")
    }

    @Test("Branch becomes the active session — UI flips immediately on fork")
    func branchBecomesActive() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[2])!
        #expect(store.activeID == branchID)
        #expect(store.activeID != pid)
    }

    @Test("Branch starts unpinned even if the parent was pinned")
    func branchIsNotPinned() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        store.togglePin(id: pid)  // parent now pinned
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[0])!
        let branch = store.sessions.first(where: { $0.id == branchID })!
        #expect(branch.isPinned == false)
    }

    @Test("Branch messages have fresh UUIDs — no SwiftUI id-collision hazard")
    func freshMessageIDs() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        let branchID = store.fork(sessionID: pid, throughMessageID: ids[2])!
        let branch = store.sessions.first(where: { $0.id == branchID })!
        let parent = store.sessions.first(where: { $0.id == pid })!
        let branchIDs = Set(branch.messages.map { $0.id })
        let parentIDs = Set(parent.messages.map { $0.id })
        #expect(branchIDs.isDisjoint(with: parentIDs))
    }

    @Test("Parent session is unchanged — fork is a pure read of the source")
    func parentUntouched() {
        let store = freshStore()
        let (pid, ids) = parentWithTurns(in: store)
        let parentBefore = store.sessions.first(where: { $0.id == pid })!
        _ = store.fork(sessionID: pid, throughMessageID: ids[1])
        let parentAfter = store.sessions.first(where: { $0.id == pid })!
        #expect(parentBefore.messages.count == parentAfter.messages.count)
        #expect(parentBefore.messages.map { $0.id } == parentAfter.messages.map { $0.id })
        #expect(parentBefore.title == parentAfter.title)
    }

    @Test("Unknown sessionID is a silent no-op — returns nil, doesn't insert a row")
    func unknownSessionNoOp() {
        let store = freshStore()
        let (_, ids) = parentWithTurns(in: store)
        let countBefore = store.sessions.count
        let result = store.fork(sessionID: UUID(), throughMessageID: ids[0])
        #expect(result == nil)
        #expect(store.sessions.count == countBefore)
    }

    @Test("Unknown messageID is a silent no-op — returns nil, doesn't insert a row")
    func unknownMessageNoOp() {
        let store = freshStore()
        let (pid, _) = parentWithTurns(in: store)
        let countBefore = store.sessions.count
        let result = store.fork(sessionID: pid, throughMessageID: UUID())
        #expect(result == nil)
        #expect(store.sessions.count == countBefore)
    }
}
