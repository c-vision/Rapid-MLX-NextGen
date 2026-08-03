import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// PoppedConversationView pins to a specific session UUID and renders
/// its transcript independently of ``SessionStore.activeID``. The
/// shape contract: title + user/assistant messages render, missing
/// UUIDs surface an "unavailable" state, and the "Reply in Main
/// Window" affordance is present whenever the session resolves.
@MainActor
@Suite("PoppedConversationView shape")
struct PoppedConversationViewTests {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-popped-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: url)
    }

    @Test("Renders the session title and the Reply CTA when the UUID resolves")
    func rendersTitleAndCTA() throws {
        let store = makeStore()
        let id = store.newSession(alias: "fixture-1b-4bit")
        store.renameSession(id: id, to: "Aurora drawings")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "draw me an aurora"),
            ChatMessage(role: .assistant, content: "Here you go."),
        ])
        let sut = PoppedConversationView(sessionID: id, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Aurora drawings")
        }
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Reply in Main Window")
        }
    }

    @Test("Missing UUID falls back to the unavailable state")
    func missingUUIDFallback() throws {
        let store = makeStore()
        let sut = PoppedConversationView(sessionID: nil, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Conversation not available")
        }
    }

    @Test("Deleted UUID still shows the unavailable state, not a crash")
    func deletedUUIDFallback() throws {
        let store = makeStore()
        let stale = UUID()
        let sut = PoppedConversationView(sessionID: stale, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Conversation not available")
        }
    }

    /// Audit P1: prior to this fix a popped window pinned to a now-
    /// deleted session showed "not available" with no obvious way to
    /// close — the user had to remember ⌘W or the Window menu. The
    /// unavailable state now ships an explicit Close Window button.
    @Test("Unavailable state surfaces a Close Window action")
    func unavailableStateHasCloseAction() throws {
        let store = makeStore()
        let sut = PoppedConversationView(sessionID: UUID(), store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(button: "Close Window")
        }
    }

    @Test("Unavailable state Close action is present for nil sessionID too")
    func unavailableStateCloseForNilUUID() throws {
        let store = makeStore()
        let sut = PoppedConversationView(sessionID: nil, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(button: "Close Window")
        }
    }

    @Test("System and tool messages are filtered out of the popped transcript")
    func filtersSystemAndTool() throws {
        let store = makeStore()
        let id = store.newSession(alias: "fixture-1b-4bit")
        store.renameSession(id: id, to: "Filtered view")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .system, content: "internal-system-prompt-token"),
            ChatMessage(role: .user, content: "user-question-token"),
            ChatMessage(role: .assistant, content: "assistant-answer-token"),
            ChatMessage(role: .tool, content: "internal-tool-payload-token", toolCallID: "abc"),
        ])
        let sut = PoppedConversationView(sessionID: id, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "user-question-token")
        }
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "assistant-answer-token")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "internal-system-prompt-token")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "internal-tool-payload-token")
        }
    }

    @Test("Header surfaces the alias next to the title")
    func aliasInHeader() throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.renameSession(id: id, to: "Chat with alias")
        let sut = PoppedConversationView(sessionID: id, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "qwen3.5-4b-4bit")
        }
    }

    @Test("Popped view stays pinned to its UUID even after activeID switches")
    func pinnedDespiteActiveIDChange() throws {
        // The core design contract: popping a chat out is a snapshot
        // of "show me THIS conversation" — switching activeID in the
        // main window must not redirect what the popped window shows.
        // Without this test a future refactor (e.g. read from
        // ``activeSession`` instead of looking up by sessionID) would
        // silently regress the pin without any other test catching it.
        let store = makeStore()
        let pinnedID = store.newSession(alias: "fixture-1b-4bit")
        store.renameSession(id: pinnedID, to: "PINNED CHAT TITLE")
        let otherID = store.newSession(alias: "fixture-other-4bit")
        store.renameSession(id: otherID, to: "OTHER CHAT TITLE")

        store.activeID = otherID
        #expect(store.activeID == otherID)

        let sut = PoppedConversationView(sessionID: pinnedID, store: store)
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "PINNED CHAT TITLE")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "OTHER CHAT TITLE")
        }
    }

    @Test("Hybrid reasoning_content is surfaced under the disclosure header")
    func reasoningContentRendered() throws {
        // v0.5.14 NIT #1 contract: Qwen 3.5 / 3.6 hybrid models put
        // chain-of-thought into ``reasoning_content``. The main
        // ChatView surfaces it; the popped surface must too, else the
        // popped window looks like a truncated copy.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.renameSession(id: id, to: "Hybrid mirror")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "Final answer body.",
                reasoning: "thinking-trace-marker-zzx"
            ),
        ])
        let sut = PoppedConversationView(sessionID: id, store: store)

        // Label cycles "Thinking…" while streaming → "Reasoning"
        // once complete; this fixture is .complete so the label
        // reads "Reasoning", matching ChatView.swift:1838.
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Reasoning")
        }
    }

    @Test("Streaming hybrid messages label the reasoning disclosure 'Thinking…'")
    func reasoningLabelWhileStreaming() throws {
        // Cycles to match main ChatView so the popped window reads
        // identically while a hybrid model is mid-trace.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.renameSession(id: id, to: "Mid-thought")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "",
                reasoning: "still-thinking-trace",
                status: .streaming
            ),
        ])
        let sut = PoppedConversationView(sessionID: id, store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Thinking…")
        }
    }

    @Test("Streaming placeholders with empty content don't flash the (empty) caption")
    func streamingPlaceholderHidesEmptyCaption() throws {
        // v0.5.14 NIT #2 contract: an in-flight ``.streaming``
        // assistant row carries empty content for one frame before
        // tokens arrive. Without the status gate the popped window
        // flashes "(empty)" every time the user pops a chat mid-stream.
        let store = makeStore()
        let id = store.newSession(alias: "fixture-1b-4bit")
        store.renameSession(id: id, to: "Mid-stream pop")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "Question while we wait."),
            ChatMessage(role: .assistant, content: "", status: .streaming),
        ])
        let sut = PoppedConversationView(sessionID: id, store: store)

        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "(empty)")
        }
    }
}
