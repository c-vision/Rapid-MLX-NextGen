import Foundation
import Testing
@testable import Rapid

/// Two thin polish surfaces tested here:
///   * ``SessionStore.renameSession`` — quietly ignores blanks and
///     trims whitespace; we want a regression test before the
///     sidebar's inline rename starts shipping blank titles.
///   * ``ChatViewModel.editUserMessage`` — truncates the transcript
///     at the edit point and re-streams. Wraps the same
///     ``replaceMessages`` plumbing ``regenerateLast`` uses, so a
///     regression in one is a regression in both.
@Suite("Session rename + user-turn edit")
@MainActor
struct RenameEditTests {
    /// Spin up a temp-dir-backed store so the tests don't trample
    /// the user's real ~/Library/Application Support/Rapid file.
    private func makeStore() -> SessionStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-rename-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.json")
        return SessionStore(customStoreURL: url)
    }

    @Test("renameSession replaces the title, trimming whitespace")
    func renameTrims() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        store.renameSession(id: id, to: "  Project plan  ")
        #expect(store.sessions.first(where: { $0.id == id })?.title == "Project plan")
    }

    @Test("renameSession ignores a blank title (no-op)")
    func renameRejectsBlank() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        // Auto-derived title for an empty session is "New chat".
        let before = store.sessions.first(where: { $0.id == id })?.title
        store.renameSession(id: id, to: "   ")
        #expect(store.sessions.first(where: { $0.id == id })?.title == before)
    }

    @Test("renameSession on an unknown id is a no-op")
    func renameUnknownIDNoOp() {
        let store = makeStore()
        let real = store.newSession(alias: "qwen3.5-4b")
        store.renameSession(id: UUID(), to: "Phantom")
        // Real session untouched.
        #expect(store.sessions.first(where: { $0.id == real })?.title == "New chat")
    }

    @Test("editUserMessage truncates the transcript at the edited turn")
    func editTruncates() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let u1 = ChatMessage(role: .user, content: "First", status: .complete)
        let a1 = ChatMessage(role: .assistant, content: "First reply", status: .complete)
        let u2 = ChatMessage(role: .user, content: "Second", status: .complete)
        let a2 = ChatMessage(role: .assistant, content: "Second reply", status: .complete)
        _ = store.appendMessage(sessionID: id, u1)
        _ = store.appendMessage(sessionID: id, a1)
        _ = store.appendMessage(sessionID: id, u2)
        _ = store.appendMessage(sessionID: id, a2)

        // Tools are EmptyToolRegistry — viewmodel.send will fire a
        // network request to 127.0.0.1:8000 (which the test
        // environment doesn't serve), but our assertion is on the
        // synchronous truncation step that runs *before* send dispatches.
        // We don't await the stream task; we just snapshot the messages
        // array right after the truncation lands.
        let viewModel = ChatViewModel(store: store)
        viewModel.editUserMessage(id: u1.id, newContent: "Edited first", alias: "qwen3.5-4b")

        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        // After truncation: just the edited user turn + (newly opened)
        // streaming assistant placeholder. The original u2 / a2 /
        // a1 are gone.
        #expect(messages.count == 2)
        #expect(messages[0].content == "Edited first")
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        // Tear down the inflight stream task so the test exits cleanly.
        viewModel.stop()
    }

    @Test("Editing the first turn refreshes its auto-derived session title")
    func editRefreshesAutoTitle() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let first = ChatMessage(role: .user, content: "Original request")
        _ = store.appendMessage(sessionID: id, first)
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "Original reply")
        )

        let viewModel = ChatViewModel(store: store)
        let accepted = viewModel.editUserMessage(
            id: first.id,
            newContent: "Updated request",
            alias: "qwen3.5-4b"
        )

        #expect(accepted)
        #expect(store.sessions.first(where: { $0.id == id })?.title == "Updated request")
        viewModel.stop()
    }

    @Test("Editing the first turn preserves a manually renamed session title")
    func editPreservesCustomTitle() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let first = ChatMessage(role: .user, content: "Original request")
        _ = store.appendMessage(sessionID: id, first)
        store.renameSession(id: id, to: "Release planning")

        let viewModel = ChatViewModel(store: store)
        _ = viewModel.editUserMessage(
            id: first.id,
            newContent: "Updated request",
            alias: "qwen3.5-4b"
        )

        #expect(store.sessions.first(where: { $0.id == id })?.title == "Release planning")
        viewModel.stop()
    }

    /// Upstream #579 pinned attachment preservation INSIDE
    /// ``editUserMessage`` (the VM re-read the original row's
    /// attachments). The 2026-07 rewind redesign deliberately moved
    /// attachment custody to the composer: ``beginEditRewind`` stages
    /// the original attachments there, the user may add/remove some,
    /// and Send passes the composer's set back in. So the VM contract
    /// is now "sends exactly what the composer hands over" — carried
    /// attachments AND removal are both legal, and each gets a pin.
    @Test("Editing with composer-staged attachments sends exactly those")
    func editPreservesAttachments() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let attachment = Attachment(
            kind: .textFile,
            filename: "notes.txt",
            mime: "text/plain",
            body: "context",
            sizeBytes: 7
        )
        let user = ChatMessage(
            role: .user,
            content: "Summarize this",
            attachments: [attachment]
        )
        _ = store.appendMessage(sessionID: id, user)
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "Summary"))

        let viewModel = ChatViewModel(store: store)
        _ = viewModel.editUserMessage(
            id: user.id,
            newContent: "Extract the decisions",
            attachments: [attachment],
            alias: "qwen3.5-4b"
        )

        let edited = store.sessions.first(where: { $0.id == id })?.messages.first
        #expect(edited?.content == "Extract the decisions")
        #expect(edited?.attachments == [attachment])
        viewModel.stop()
    }

    @Test("Editing may drop the original attachments — removal in the composer is legal")
    func editMayRemoveAttachments() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let attachment = Attachment(
            kind: .textFile,
            filename: "notes.txt",
            mime: "text/plain",
            body: "context",
            sizeBytes: 7
        )
        let user = ChatMessage(
            role: .user,
            content: "Summarize this",
            attachments: [attachment]
        )
        _ = store.appendMessage(sessionID: id, user)
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "Summary"))

        let viewModel = ChatViewModel(store: store)
        _ = viewModel.editUserMessage(
            id: user.id,
            newContent: "Answer without the file this time",
            attachments: [],
            alias: "qwen3.5-4b"
        )

        let edited = store.sessions.first(where: { $0.id == id })?.messages.first
        #expect(edited?.content == "Answer without the file this time")
        #expect(edited?.attachments == nil || edited?.attachments?.isEmpty == true)
        viewModel.stop()
    }

    @Test("Editing is rejected without truncation while another response is streaming")
    func editRejectedWhileStreaming() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let first = ChatMessage(role: .user, content: "Keep this request")
        _ = store.appendMessage(sessionID: id, first)
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "Keep this reply"))

        let viewModel = ChatViewModel(store: store)
        viewModel.send("A newer request", alias: "qwen3.5-4b")
        let before = store.sessions.first(where: { $0.id == id })?.messages

        let accepted = viewModel.editUserMessage(
            id: first.id,
            newContent: "This must not replace history yet",
            alias: "qwen3.5-4b"
        )

        #expect(!accepted)
        #expect(store.sessions.first(where: { $0.id == id })?.messages == before)
        viewModel.stop()
    }

    @Test("editUserMessage rejects empty input (no truncation)")
    func editRejectsBlank() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "Keep me", status: .complete))
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "And me", status: .complete))
        let firstUserID = store.sessions.first(where: { $0.id == id })!.messages[0].id

        let viewModel = ChatViewModel(store: store)
        let accepted = viewModel.editUserMessage(
            id: firstUserID,
            newContent: "   ",
            alias: "qwen3.5-4b"
        )

        // Transcript untouched.
        #expect(!accepted)
        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[0].content == "Keep me")
    }

    @Test("editUserMessage on an assistant id is a no-op")
    func editAssistantRowRejected() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "u1", status: .complete))
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "a1", status: .complete))
        let assistantID = store.sessions.first(where: { $0.id == id })!.messages[1].id

        let viewModel = ChatViewModel(store: store)
        viewModel.editUserMessage(id: assistantID, newContent: "won't fly", alias: "qwen3.5-4b")

        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        #expect(messages.count == 2)
        #expect(messages[1].content == "a1")
    }

    // MARK: - 2026-07 rewind redesign

    @Test("editUserMessage sends the COMPOSER's attachments, not the original message's")
    func editUsesComposerAttachments() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let originalAtt = Attachment(
            kind: .textFile, filename: "old.txt", mime: "text/plain",
            body: "old contents", sizeBytes: 12
        )
        let u1 = ChatMessage(
            role: .user, content: "Look at this", status: .complete,
            attachments: [originalAtt]
        )
        _ = store.appendMessage(sessionID: id, u1)
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, content: "ok", status: .complete))

        // The user removed the original attachment in the composer and
        // attached a different file before resending.
        let replacementAtt = Attachment(
            kind: .textFile, filename: "new.txt", mime: "text/plain",
            body: "new contents", sizeBytes: 12
        )
        let viewModel = ChatViewModel(store: store)
        viewModel.editUserMessage(
            id: u1.id, newContent: "Look at this instead",
            attachments: [replacementAtt], alias: "qwen3.5-4b"
        )

        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        #expect(messages.first?.attachments?.map(\.filename) == ["new.txt"])
        // And an edit that strips attachments entirely must strip them.
        let viewModel2 = ChatViewModel(store: store)
        let newFirstID = messages.first!.id
        viewModel2.editUserMessage(
            id: newFirstID, newContent: "no attachment now",
            attachments: [], alias: "qwen3.5-4b"
        )
        let after = store.sessions.first(where: { $0.id == id })?.messages ?? []
        #expect(after.first?.attachments == nil)
    }

    @Test("editUserMessage allows an attachment-only edit, mirroring send")
    func editAllowsAttachmentOnly() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b")
        let u1 = ChatMessage(role: .user, content: "with prose", status: .complete)
        _ = store.appendMessage(sessionID: id, u1)

        let att = Attachment(
            kind: .textFile, filename: "doc.txt", mime: "text/plain",
            body: "contents", sizeBytes: 8
        )
        let viewModel = ChatViewModel(store: store)
        viewModel.editUserMessage(id: u1.id, newContent: "  ", attachments: [att], alias: "qwen3.5-4b")

        let messages = store.sessions.first(where: { $0.id == id })?.messages ?? []
        // The composer accepts attachment-only sends, so the edit path
        // must too — otherwise Send silently eats a legal state.
        #expect(messages.first?.attachments?.map(\.filename) == ["doc.txt"])
    }

    @Test("visibleMessages hides the edited turn and everything after it — and only that")
    func visibleMessagesRewind() {
        let u1 = ChatMessage(role: .user, content: "u1", status: .complete)
        let a1 = ChatMessage(role: .assistant, content: "a1", status: .complete)
        let u2 = ChatMessage(role: .user, content: "u2", status: .complete)
        let a2 = ChatMessage(role: .assistant, content: "a2", status: .complete)
        let all = [u1, a1, u2, a2]

        // Rewind staged on u2: u1 + a1 stay visible.
        #expect(ChatView.visibleMessages(all, editRewindID: u2.id).map(\.content) == ["u1", "a1"])
        // Rewind on the FIRST turn: transcript preview is empty.
        #expect(ChatView.visibleMessages(all, editRewindID: u1.id).isEmpty)
        // No rewind staged: everything renders.
        #expect(ChatView.visibleMessages(all, editRewindID: nil).count == 4)
        // Orphaned id (message deleted elsewhere mid-edit): render the
        // full list rather than hiding arbitrary turns on a stale id.
        #expect(ChatView.visibleMessages(all, editRewindID: UUID()).count == 4)
    }
}
