import Foundation
import Testing
@testable import Rapid

/// Contract for ``CommandPalette.filter`` — the pure ranking layer
/// behind the ⌘K palette (Tier 1 #H, MVP scope: session-jump only).
/// All assertions hit the pure type so the contract is locked
/// independently of CommandPaletteView's SwiftUI wiring.
@MainActor
@Suite("CommandPalette session-jump matcher")
struct CommandPaletteTests {

    private func session(
        title: String,
        userTurn: String? = nil,
        assistantTurn: String? = nil,
        pinned: Bool = false,
        updatedDaysAgo: Double = 0
    ) -> ChatSession {
        var s = ChatSession(title: title, alias: "qwen3.6-27b")
        if let t = userTurn {
            s.messages.append(ChatMessage(role: .user, content: t))
        }
        if let a = assistantTurn {
            s.messages.append(ChatMessage(role: .assistant, content: a))
        }
        s.isPinned = pinned
        s.updatedAt = Date().addingTimeInterval(-updatedDaysAgo * 86_400)
        return s
    }

    @Test("Empty query returns the most-recently-updated sessions, capped at maxResults")
    func emptyQueryReturnsRecency() {
        let now = Date()
        var sessions: [ChatSession] = []
        // Build 12 sessions, each one day older than the last. The
        // palette should return the top 8 (CommandPalette.maxResults)
        // sorted newest-first.
        for i in 0..<12 {
            var s = ChatSession(title: "Chat \(i)", alias: "qwen3.6-27b")
            s.messages = [ChatMessage(role: .user, content: "n=\(i)")]
            s.updatedAt = now.addingTimeInterval(-Double(i) * 86_400)
            sessions.append(s)
        }
        let result = CommandPalette.filter(query: "", sessions: sessions)
        #expect(result.count == CommandPalette.maxResults)
        // Newest first → "Chat 0" leads, "Chat 7" closes the visible
        // window (Chat 8..11 fall off).
        #expect(result.first?.title == "Chat 0")
        #expect(result.last?.title == "Chat 7")
    }

    @Test("Whitespace-only query behaves like empty")
    func whitespaceQueryIsEmpty() {
        let s = session(title: "Brainstorm", userTurn: "ideas")
        let result = CommandPalette.filter(query: "   ", sessions: [s])
        #expect(result.count == 1)
    }

    @Test("Title prefix match ranks above substring match")
    func titlePrefixBeatsSubstring() {
        let a = session(title: "Cooking notes")
        let b = session(title: "Notes on cooking")
        // Both contain "notes"; only `b` has it as a prefix.
        let result = CommandPalette.filter(query: "notes", sessions: [a, b])
        #expect(result.count == 2)
        #expect(result.first?.title == "Notes on cooking")
        #expect(result.last?.title == "Cooking notes")
    }

    @Test("Title substring match beats body match")
    func titleBeatsBody() {
        let a = session(title: "Unrelated", userTurn: "pasta recipe details")
        let b = session(title: "Pasta thoughts")
        let result = CommandPalette.filter(query: "pasta", sessions: [a, b])
        #expect(result.first?.title == "Pasta thoughts")
        #expect(result.last?.title == "Unrelated")
    }

    @Test("Sessions with no hit are filtered out entirely")
    func missesDropOut() {
        let a = session(title: "Foo", userTurn: "alpha")
        let b = session(title: "Bar", userTurn: "beta")
        let result = CommandPalette.filter(query: "zzz", sessions: [a, b])
        #expect(result.isEmpty)
    }

    @Test("Match is case-insensitive on both sides")
    func caseInsensitive() {
        let s = session(title: "TOKYO trip")
        let lowered = CommandPalette.filter(query: "tokyo", sessions: [s])
        #expect(lowered.count == 1)
        let upper = CommandPalette.filter(query: "TOKYO", sessions: [s])
        #expect(upper.count == 1)
        let mixed = CommandPalette.filter(query: "ToKyO", sessions: [s])
        #expect(mixed.count == 1)
    }

    @Test("Match is diacritic-insensitive without lowercasing whole transcripts")
    func diacriticInsensitive() {
        let title = session(title: "Café planning")
        let body = session(title: "Unrelated", userTurn: "Résumé review notes")

        #expect(CommandPalette.filter(query: "cafe", sessions: [title]).count == 1)
        #expect(CommandPalette.filter(query: "resume", sessions: [body]).count == 1)
    }

    @Test("Same-score ties break by recency (newer first)")
    func tiesBreakByRecency() {
        let stale = session(title: "Tokyo notes", updatedDaysAgo: 30)
        let fresh = session(title: "Tokyo notes", updatedDaysAgo: 1)
        let result = CommandPalette.filter(query: "tokyo", sessions: [stale, fresh])
        // Both score 100 (prefix match); fresh wins on recency.
        #expect(result.first?.updatedAt == fresh.updatedAt)
    }

    @Test("Result count is capped at maxResults even when many match")
    func capHonoured() {
        // Build 20 sessions whose titles all contain the needle.
        let many: [ChatSession] = (0..<20).map { i in
            session(title: "alpha chat \(i)", updatedDaysAgo: Double(i))
        }
        let result = CommandPalette.filter(query: "alpha", sessions: many)
        #expect(result.count == CommandPalette.maxResults)
    }

    @Test("Body content match is found via message reverse-iteration")
    func bodyMatchFound() {
        let s = session(
            title: "Trip planning",
            userTurn: "I need flights to Tokyo next week"
        )
        let result = CommandPalette.filter(query: "tokyo", sessions: [s])
        #expect(result.count == 1)
    }

    @Test("clampedIndex wraps top-to-bottom and bottom-to-top")
    func clampedIndexWraps() {
        #expect(CommandPalette.clampedIndex(-1, count: 5) == 4)
        #expect(CommandPalette.clampedIndex(5, count: 5) == 0)
        #expect(CommandPalette.clampedIndex(7, count: 5) == 2)
        #expect(CommandPalette.clampedIndex(0, count: 0) == 0)
    }
}
