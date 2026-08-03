import Foundation
import Testing
@testable import Rapid

/// Contract for ``MessageSearch`` — v0.4.30 Cmd+F in-session find.
/// The matching logic, caption formatting, and cursor-step semantics
/// are pure functions so the UI behaviour is fully pinnable without
/// standing up a ``ChatView`` host.
@Suite("MessageSearch — v0.4.30 Cmd+F find contract")
struct MessageSearchTests {
    private func msg(_ role: ChatMessage.Role, _ content: String, reasoning: String = "") -> ChatMessage {
        var m = ChatMessage(role: role, content: content, status: .complete)
        m.reasoning = reasoning
        return m
    }

    // MARK: - matches(in:query:)

    @Test("Empty query returns no matches (don't light up every row)")
    func emptyQueryNoMatches() {
        let messages = [msg(.user, "anything"), msg(.assistant, "anything else")]
        #expect(MessageSearch.matches(in: messages, query: "").isEmpty)
    }

    @Test("Whitespace-only query is treated as empty")
    func whitespaceQueryNoMatches() {
        let messages = [msg(.user, "anything")]
        #expect(MessageSearch.matches(in: messages, query: "   ").isEmpty)
        #expect(MessageSearch.matches(in: messages, query: "\t\n").isEmpty)
    }

    @Test("Case-insensitive substring match")
    func caseInsensitive() {
        let messages = [
            msg(.user, "What is GitHub?"),
            msg(.assistant, "GitHub is a code-hosting platform.")
        ]
        let ids = MessageSearch.matches(in: messages, query: "github")
        #expect(ids == [messages[0].id, messages[1].id])
    }

    @Test("Diacritic-insensitive substring match")
    func diacriticInsensitive() {
        let messages = [
            msg(.user, "Café notes"),
            msg(.assistant, "Résumé summary")
        ]
        #expect(MessageSearch.matches(in: messages, query: "cafe") == [messages[0].id])
        #expect(MessageSearch.matches(in: messages, query: "resume") == [messages[1].id])
    }

    @Test("Matches in transcript order — order preserved across mixed roles")
    func orderPreserved() {
        let m1 = msg(.user, "tell me about hash maps")
        let m2 = msg(.assistant, "non-matching middle")
        let m3 = msg(.user, "follow up on HASH MAPS")
        let m4 = msg(.assistant, "Hash maps are O(1) on average.")
        let ids = MessageSearch.matches(in: [m1, m2, m3, m4], query: "hash")
        #expect(ids == [m1.id, m3.id, m4.id])
    }

    @Test("Reasoning trace is searched (so Qwen hybrid users can find intermediate steps)")
    func reasoningIsSearched() {
        let m = msg(.assistant, "The answer is 42.", reasoning: "Let me compute: 6 × 7 = 42.")
        let ids = MessageSearch.matches(in: [m], query: "compute")
        #expect(ids == [m.id])
    }

    @Test("Query spanning content/reasoning boundary does NOT match (space separator stops cross-field hits)")
    func crossBoundaryNoMatch() {
        // "foo" in content + "bar" in reasoning concatenated as
        // "foo bar" — a query for "foobar" must not hit.
        let m = msg(.assistant, "foo", reasoning: "bar")
        #expect(MessageSearch.matches(in: [m], query: "foobar").isEmpty)
    }

    @Test("Non-matching messages are skipped — count reflects only true matches")
    func nonMatchingSkipped() {
        let m1 = msg(.user, "hello")
        let m2 = msg(.assistant, "world")
        let m3 = msg(.user, "hello again")
        let ids = MessageSearch.matches(in: [m1, m2, m3], query: "hello")
        #expect(ids == [m1.id, m3.id])
    }

    // MARK: - caption(matchCount:currentIndex:)

    @Test("Zero matches caption — 'Not found'")
    func zeroMatchesCaption() {
        #expect(MessageSearch.caption(matchCount: 0, currentIndex: 0) == "Not found")
    }

    @Test("Standard 'N of M' formatting — 1-indexed for humans")
    func standardCaption() {
        #expect(MessageSearch.caption(matchCount: 17, currentIndex: 0) == "1 of 17")
        #expect(MessageSearch.caption(matchCount: 17, currentIndex: 5) == "6 of 17")
        #expect(MessageSearch.caption(matchCount: 17, currentIndex: 16) == "17 of 17")
    }

    @Test("Out-of-range index clamps defensively (don't crash if UI lags by a tick)")
    func clampedCaption() {
        // currentIndex past matchCount-1: clamp to last
        #expect(MessageSearch.caption(matchCount: 3, currentIndex: 99) == "3 of 3")
        // negative currentIndex: clamp to first
        #expect(MessageSearch.caption(matchCount: 3, currentIndex: -2) == "1 of 3")
    }

    // MARK: - step(currentIndex:matchCount:delta:)

    @Test("Stepping forward advances by 1")
    func stepForward() {
        #expect(MessageSearch.step(currentIndex: 0, matchCount: 5, delta: 1) == 1)
        #expect(MessageSearch.step(currentIndex: 3, matchCount: 5, delta: 1) == 4)
    }

    @Test("Stepping forward at the last match wraps to 0 (Safari behaviour)")
    func stepForwardWraps() {
        #expect(MessageSearch.step(currentIndex: 4, matchCount: 5, delta: 1) == 0)
    }

    @Test("Stepping backward from 0 wraps to the last match")
    func stepBackwardWraps() {
        #expect(MessageSearch.step(currentIndex: 0, matchCount: 5, delta: -1) == 4)
    }

    @Test("Zero matches — step returns 0 (defensive; UI should disable the buttons anyway)")
    func stepZeroMatches() {
        #expect(MessageSearch.step(currentIndex: 7, matchCount: 0, delta: 1) == 0)
        #expect(MessageSearch.step(currentIndex: 7, matchCount: 0, delta: -1) == 0)
    }

    @Test("Multi-step delta works (jumping by 2 / -3 wraps correctly)")
    func multiStepDelta() {
        // delta=+3 from 4 with matchCount=5: (4+3)%5 = 2
        #expect(MessageSearch.step(currentIndex: 4, matchCount: 5, delta: 3) == 2)
        // delta=-3 from 1 with matchCount=5: (1-3+5)%5 = 3
        #expect(MessageSearch.step(currentIndex: 1, matchCount: 5, delta: -3) == 3)
    }
}
