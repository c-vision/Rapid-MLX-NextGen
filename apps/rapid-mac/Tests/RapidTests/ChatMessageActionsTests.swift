import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Chat message actions")
struct ChatMessageActionsTests {
    private func isolatedStoreURL() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-chat-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (root, root.appendingPathComponent("conversations.json"))
    }

    @Test("Editing an older user message drops the later turns and resends the edit")
    func editOlderUserMessageRewindsConversation() {
        let viewModel = ChatViewModel(persistsConversations: false)
        let firstUser = ChatMessage(role: .user, content: "original question")
        let firstAssistant = ChatMessage(role: .assistant, content: "first answer")
        let secondUser = ChatMessage(role: .user, content: "follow-up")
        let secondAssistant = ChatMessage(role: .assistant, content: "second answer")
        viewModel.devSeedMessages([firstUser, firstAssistant, secondUser, secondAssistant])

        let edited = viewModel.editUserMessage(
            id: firstUser.id,
            newContent: "  revised question  ",
            alias: "test-model"
        )
        defer { viewModel.stopAndPersist() }

        #expect(edited)
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].role == .user)
        #expect(viewModel.messages[0].content == "revised question")
        #expect(viewModel.messages[1].role == .assistant)
        #expect(viewModel.messages[1].status == .streaming)
        #expect(!viewModel.messages.contains(where: { $0.id == secondUser.id }))
        #expect(!viewModel.messages.contains(where: { $0.id == secondAssistant.id }))
    }

    @Test("Retrying an older assistant response replays its preceding user turn")
    func retryOlderAssistantRewindsToItsUserMessage() {
        let viewModel = ChatViewModel(persistsConversations: false)
        let firstUser = ChatMessage(role: .user, content: "first question")
        let firstAssistant = ChatMessage(role: .assistant, content: "first answer")
        let secondUser = ChatMessage(role: .user, content: "second question")
        let secondAssistant = ChatMessage(role: .assistant, content: "second answer")
        viewModel.devSeedMessages([firstUser, firstAssistant, secondUser, secondAssistant])

        let retried = viewModel.retryAssistantMessage(
            id: firstAssistant.id,
            alias: "test-model"
        )
        defer { viewModel.stopAndPersist() }

        #expect(retried)
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].role == .user)
        #expect(viewModel.messages[0].content == "first question")
        #expect(viewModel.messages[1].role == .assistant)
        #expect(viewModel.messages[1].status == .streaming)
        #expect(!viewModel.messages.contains(where: { $0.id == secondUser.id }))
        #expect(!viewModel.messages.contains(where: { $0.id == secondAssistant.id }))
    }

    @Test("Retrying an older response replays in place, without spawning a sidebar entry")
    func retryOlderAssistantStaysOnTheSameConversation() throws {
        let store = try isolatedStoreURL()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let viewModel = ChatViewModel(conversationStoreURL: store.file)
        let firstUser = ChatMessage(role: .user, content: "first question")
        let firstAssistant = ChatMessage(role: .assistant, content: "first answer")
        let secondUser = ChatMessage(role: .user, content: "second question")
        let secondAssistant = ChatMessage(role: .assistant, content: "second answer")
        viewModel.devSeedMessages([firstUser, firstAssistant, secondUser, secondAssistant])
        let originalID = viewModel.activeConversationID

        let retried = viewModel.retryAssistantMessage(
            id: firstAssistant.id,
            alias: "test-model"
        )
        #expect(retried)
        #expect(viewModel.activeConversationID == originalID)
        viewModel.stopAndPersist()
        ConversationStore.flush()

        // Exactly one row on disk: the retry rewrote the conversation it was
        // fired from rather than forking a duplicate-titled branch beside it.
        let reloaded = ChatViewModel(conversationStoreURL: store.file)
        #expect(reloaded.conversations.count == 1)
        #expect(reloaded.conversations.first?.id == originalID)
    }

    @Test("Editing an older message replays in place, without spawning a sidebar entry")
    func editOlderUserStaysOnTheSameConversation() throws {
        let store = try isolatedStoreURL()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let viewModel = ChatViewModel(conversationStoreURL: store.file)
        let firstUser = ChatMessage(role: .user, content: "first question")
        let firstAssistant = ChatMessage(role: .assistant, content: "first answer")
        let secondUser = ChatMessage(role: .user, content: "second question")
        let secondAssistant = ChatMessage(role: .assistant, content: "second answer")
        viewModel.devSeedMessages([firstUser, firstAssistant, secondUser, secondAssistant])
        let originalID = viewModel.activeConversationID

        let edited = viewModel.editUserMessage(
            id: firstUser.id,
            newContent: "edited question",
            alias: "test-model"
        )
        #expect(edited)
        #expect(viewModel.activeConversationID == originalID)
        viewModel.stopAndPersist()
        ConversationStore.flush()

        let reloaded = ChatViewModel(conversationStoreURL: store.file)
        #expect(reloaded.conversations.count == 1)
        #expect(reloaded.conversations.first?.id == originalID)
    }
}
