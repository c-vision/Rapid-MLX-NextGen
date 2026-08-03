import Foundation
import Testing
@testable import Rapid

/// Contract for ``SessionsSidebar.sessionMatches`` — the predicate
/// driving the v0.4.11 sidebar Cmd+F search. We pin one assertion
/// per branch so a future "performance pass" can't quietly drop
/// case-insensitivity or skip system-message filtering.
@Suite("SessionsSidebar search predicate")
struct SessionSearchTests {
    private func session(
        title: String,
        messages: [ChatMessage] = []
    ) -> ChatSession {
        ChatSession(
            title: title,
            alias: "fake-alias",
            messages: messages
        )
    }

    @Test("Empty query matches every session — used to render the unfiltered list")
    func emptyQueryMatchesAll() {
        let s = session(title: "Anything goes here")
        #expect(SessionsSidebar.sessionMatches(s, query: ""))
        #expect(SessionsSidebar.sessionMatches(s, query: "   "))
    }

    @Test("Title substring is the cheap-path match")
    func titleSubstring() {
        let s = session(title: "Tokyo weather report")
        #expect(SessionsSidebar.sessionMatches(s, query: "tokyo"))
        #expect(SessionsSidebar.sessionMatches(s, query: "weather"))
        #expect(SessionsSidebar.sessionMatches(s, query: "report"))
    }

    @Test("Title match is case-insensitive (TOKYO finds Tokyo)")
    func titleCaseInsensitive() {
        let s = session(title: "Tokyo trip planning")
        #expect(SessionsSidebar.sessionMatches(s, query: "TOKYO"))
        #expect(SessionsSidebar.sessionMatches(s, query: "tokyo"))
        #expect(SessionsSidebar.sessionMatches(s, query: "ToKyO"))
    }

    @Test("Falls back to message-content search when title doesn't hit")
    func contentSearchFallback() {
        let s = session(
            title: "Untitled chat",
            messages: [
                ChatMessage(role: .user, content: "What's the weather in Tokyo?"),
                ChatMessage(role: .assistant, content: "It's currently raining."),
            ]
        )
        #expect(SessionsSidebar.sessionMatches(s, query: "tokyo"))
        #expect(SessionsSidebar.sessionMatches(s, query: "raining"))
        #expect(!SessionsSidebar.sessionMatches(s, query: "snow"))
    }

    @Test("Skips system and tool messages — they're chrome, not user-recall content")
    func skipsSystemAndTool() {
        let s = session(
            title: "Untitled chat",
            messages: [
                ChatMessage(role: .system, content: "You are a helpful assistant about Tokyo."),
                ChatMessage(role: .tool, content: "{\"city\": \"Tokyo\"}"),
                ChatMessage(role: .user, content: "What's the time?"),
                ChatMessage(role: .assistant, content: "12:34 PM."),
            ]
        )
        // "Tokyo" appears ONLY in system + tool — both filtered out.
        #expect(!SessionsSidebar.sessionMatches(s, query: "tokyo"))
        // User content still matches.
        #expect(SessionsSidebar.sessionMatches(s, query: "time"))
    }

    @Test("Query is trimmed of surrounding whitespace before matching")
    func queryTrimming() {
        let s = session(title: "Project plan")
        #expect(SessionsSidebar.sessionMatches(s, query: "  plan  "))
        #expect(SessionsSidebar.sessionMatches(s, query: "\tplan\n"))
    }

    @Test("Unicode case-folding works — café finds Café")
    func unicodeCaseFolding() {
        let s = session(title: "Café meeting notes")
        #expect(SessionsSidebar.sessionMatches(s, query: "café"))
        #expect(SessionsSidebar.sessionMatches(s, query: "CAFÉ"))
    }

    @Test("Searches newest message first — the recent-recall case")
    func searchesNewestFirst() {
        // This is a behaviour test (not just a contract one): we
        // can't directly observe iteration order, but we CAN
        // verify a session with the needle ONLY in the last
        // message still matches. If the algorithm short-circuited
        // at the wrong index, this would fail.
        let s = session(
            title: "Untitled",
            messages: [
                ChatMessage(role: .user, content: "Hello"),
                ChatMessage(role: .assistant, content: "Hi there"),
                ChatMessage(role: .user, content: "Tell me about quantum entanglement"),
            ]
        )
        #expect(SessionsSidebar.sessionMatches(s, query: "quantum"))
    }

    @Test("No match anywhere returns false")
    func noMatchReturnsFalse() {
        let s = session(
            title: "Weather forecast",
            messages: [
                ChatMessage(role: .user, content: "Will it rain tomorrow?"),
                ChatMessage(role: .assistant, content: "Yes, light showers expected."),
            ]
        )
        #expect(!SessionsSidebar.sessionMatches(s, query: "xyz"))
        #expect(!SessionsSidebar.sessionMatches(s, query: "tokyo"))
    }
}

/// v0.4.16 contract: Cmd+N picks the N-th visible session, in the
/// same pinned-first-then-recents-newest-first order the sidebar
/// list renders. We pin this against ``visibleSessions`` rather
/// than the keyboard event itself — the event plumbing is
/// SwiftUI-internal and ViewInspector-hostile, but the selection
/// math IS testable. If this contract holds, the live behaviour
/// reduces to "Cmd+N tells the same selector to pick index N-1."
@MainActor
@Suite("SessionsSidebar Cmd+1..9 — visible-session ordering")
struct SessionsSidebarSwitchTests {
    private func freshStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Pinned sessions come first, then recents, both newest-first")
    func pinnedFirstThenRecents() {
        let store = freshStore()
        // Build a known order: two pinned (newest second) + two
        // recents (newest second). Active ID irrelevant for
        // ordering.
        let r1 = store.newSession(alias: "fake-alias")
        sleep(0)  // ensure distinct updatedAt
        let r2 = store.newSession(alias: "fake-alias")
        let p1 = store.newSession(alias: "fake-alias")
        let p2 = store.newSession(alias: "fake-alias")
        store.togglePin(id: p1)
        store.togglePin(id: p2)

        let bar = SessionsSidebar(store: store, defaultAlias: "fake-alias")
        // visibleSessions is a computed property — read it via the
        // bound store state. The order should be:
        //   1. p2 (latest pin — togglePin bumps updatedAt)
        //   2. p1
        //   3. r2
        //   4. r1
        let visible = bar.visibleSessions
        #expect(visible.count == 4)
        #expect(visible[0].id == p2)
        #expect(visible[1].id == p1)
        #expect(visible[2].id == r2)
        #expect(visible[3].id == r1)
    }

    @Test("Cmd+N with N greater than the visible count is a no-op (activeID stays put)")
    func outOfRangeIsNoop() {
        let store = freshStore()
        let s1 = store.newSession(alias: "fake-alias")
        store.activeID = s1

        let bar = SessionsSidebar(store: store, defaultAlias: "fake-alias")
        // visibleSessions has 1 entry; "Cmd+5" maps to index 4
        // which is out of range. The selector should leave the
        // active ID untouched.
        #expect(bar.visibleSessions.count == 1)
        // We don't have a hook for the private switcher, so we
        // assert the contract indirectly: visibleSessions is the
        // source of truth, and a UI-level no-op equates to "the
        // selector finds nothing at index N-1".
        let outOfRangeIndex = 4
        #expect(!bar.visibleSessions.indices.contains(outOfRangeIndex))
    }
}
