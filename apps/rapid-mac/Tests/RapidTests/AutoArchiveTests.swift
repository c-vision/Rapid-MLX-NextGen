import Foundation
import Testing
@testable import Rapid

/// Contract for ``SessionStore.shouldAutoArchive`` — the pure
/// predicate behind the Sidebar's Archived section. Lifted out of
/// the view so the rules can be pinned without booting SwiftUI.
///
/// The contract has three gates: non-empty, not pinned, older than
/// the cutoff. Each gate has its own test below so a refactor that
/// loosens one slips a single failure rather than smearing the cause.
@MainActor
@Suite("SessionStore.shouldAutoArchive — Tier 1 #F auto-archive")
struct AutoArchiveTests {

    private func sessionUpdated(_ daysAgo: Int) -> ChatSession {
        var s = ChatSession(alias: "qwen3.6-27b")
        s.messages = [ChatMessage(role: .user, content: "hello")]
        s.updatedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        return s
    }

    @Test("Session older than the cutoff is archived")
    func staleSessionArchives() {
        let s = sessionUpdated(60)
        #expect(SessionStore.shouldAutoArchive(s, now: Date()) == true)
    }

    @Test("Session inside the cutoff stays in Recents")
    func freshSessionDoesNotArchive() {
        let s = sessionUpdated(5)
        #expect(SessionStore.shouldAutoArchive(s, now: Date()) == false)
    }

    @Test("Empty sessions never archive — orphan sweep handles those")
    func emptySessionDoesNotArchive() {
        var s = ChatSession(alias: "qwen3.6-27b")
        s.updatedAt = Date().addingTimeInterval(-365 * 86_400)
        s.messages = []
        #expect(SessionStore.shouldAutoArchive(s, now: Date()) == false)
    }

    @Test("Pinned sessions never archive regardless of age")
    func pinnedSessionDoesNotArchive() {
        var s = sessionUpdated(365)
        s.isPinned = true
        #expect(SessionStore.shouldAutoArchive(s, now: Date()) == false)
    }

    @Test("Boundary: exactly at the cutoff is still recent (strict <)")
    func atBoundaryStaysRecent() {
        let cutoff = SessionStore.defaultArchiveCutoffDays
        let now = Date()
        var s = ChatSession(alias: "qwen3.6-27b")
        s.messages = [ChatMessage(role: .user, content: "hi")]
        s.updatedAt = now.addingTimeInterval(-Double(cutoff) * 86_400)
        // Predicate uses strict <, so equality counts as recent.
        // Boundary on this strict side is the user-friendly choice:
        // "30 days old" still appears in Recents; "30 days + a
        // tick" is the first frame it archives.
        #expect(SessionStore.shouldAutoArchive(s, now: now, cutoffDays: cutoff) == false)
    }

    @Test("Custom cutoff overrides the default")
    func cutoffDaysIsHonoured() {
        let s = sessionUpdated(10)
        // Default 30 → recent; pass a tighter 7-day cutoff → archived.
        #expect(SessionStore.shouldAutoArchive(s, now: Date(), cutoffDays: 30) == false)
        #expect(SessionStore.shouldAutoArchive(s, now: Date(), cutoffDays: 7) == true)
    }

}
// NOTE: an integration test that loads back-dated sessions into a
// real SessionStore and asserts `orderedForNavigation` skips the
// archived ones is intentionally omitted — SessionStore.sessions is
// `private(set)` so the test would need a test-only back-dating
// hook. The single-line predicate use in `orderedForNavigation`
// (`!Self.shouldAutoArchive($0, now: Date())`) is small enough that
// the pure-predicate tests above cover the contract; bridging via a
// dedicated mutator would dilute the SessionStore API for marginal
// confidence.
