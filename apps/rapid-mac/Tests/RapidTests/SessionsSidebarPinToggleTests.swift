import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// Issue #314 regression net: rapid Pin/Unpin alternation used to
/// collapse the PINNED row to a ~2 px sliver because the row's
/// SwiftUI identity migrated across two ``Section`` boundaries
/// (Recents → Pinned and back) with overlapping implicit move
/// transitions racing the List's row-height invalidation.
///
/// The fix is structural and lives at ``SessionsSidebar``'s
/// ``ForEach`` row:
///
///   1. `.id(session.id)` — explicit identity so SwiftUI tracks
///      the row as the SAME node across Section migrations rather
///      than fade-out-here + fade-in-there.
///   2. `.animation(nil, value: session.isPinned)` — short-circuits
///      the implicit move transition so the membership flip lands
///      synchronously and no transition can be in flight when the
///      next toggle arrives.
///
/// We can't drive an AppKit run-loop from XCTest to reproduce the
/// 2 px sliver itself, but we CAN pin the two invariants the fix
/// rests on:
///
///   - the row keeps stable identity (its session UUID) across
///     ``togglePin`` calls (the data-layer contract the
///     SwiftUI fix presupposes), and
///   - rapid alternation leaves the underlying session in a
///     consistent state (no torn ``isPinned`` flag, no orphaned
///     row in the wrong section's filtered list).
///
/// Both checks pin the data-layer assumptions the SwiftUI fix
/// rests on. The modifier chain itself (`.id` + `.animation(nil)`)
/// remains a review/manual-regression surface — ViewInspector
/// cannot reliably introspect List/Section row modifiers on
/// macOS, so removing the modifiers would not necessarily trip
/// this suite. A future refactor that drops them needs a manual
/// rapid-toggle repro pass against the live app.
@MainActor
@Suite("SessionsSidebar pin-toggle regression (#314)")
struct SessionsSidebarPinToggleTests {
    private func makeStore() -> (SessionStore, UUID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-pintoggle-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: url)
        let id = store.newSession(alias: "fake-alias")
        return (store, id)
    }

    /// The data-layer contract the SwiftUI fix presupposes: a
    /// session's ``id`` is stable across ``togglePin`` calls. If
    /// this ever regresses the `.id(session.id)` modifier becomes
    /// a no-op and #314 returns.
    @Test("Session ID is stable across togglePin")
    func sessionIDStableAcrossTogglePin() {
        let (store, id) = makeStore()
        let original = store.sessions.first { $0.id == id }
        #expect(original != nil)
        store.togglePin(id: id)
        store.togglePin(id: id)
        store.togglePin(id: id)
        let after = store.sessions.first { $0.id == id }
        #expect(after?.id == id)
    }

    /// 5 toggles (4 back-and-forth alternations) matches the
    /// repro from the issue: "Pin → Unpin → Pin → Unpin → Pin in
    /// <2 s." After the burst the session must be in exactly one
    /// section's filter output, not both and not neither.
    @Test("Rapid Pin/Unpin alternation leaves session in exactly one section")
    func rapidAlternationConvergesToSingleSection() {
        let (store, id) = makeStore()
        // Start unpinned → 5 toggles (4 alternations) → final
        // state is pinned. Matches the issue's repro sequence.
        for _ in 0..<5 {
            store.togglePin(id: id)
        }
        let session = store.sessions.first { $0.id == id }
        #expect(session?.isPinned == true)

        // The two Section filters used by the sidebar must agree:
        // the session is in Pinned, NOT in Recents. A double-
        // membership would indicate a torn ``isPinned`` read; a
        // zero-membership would indicate the session got dropped
        // by one of the racing filter passes. Either return path
        // would re-open #314 from the data layer.
        let pinnedHits = store.sessions
            .filter { $0.isPinned }
            .filter { $0.id == id }
            .count
        let recentsHits = store.sessions
            .filter { !$0.isPinned && !SessionStore.shouldAutoArchive($0, now: Date()) }
            .filter { $0.id == id }
            .count
        #expect(pinnedHits == 1)
        #expect(recentsHits == 0)
    }

    /// Sanity: even-count toggles return to the original
    /// (unpinned) state. The fix doesn't change ``togglePin``
    /// semantics; we pin them so a future engine refactor can't
    /// silently introduce a one-way pin trap that would mask the
    /// row-height bug behind a different symptom.
    @Test("Even-count alternation returns to original unpinned state")
    func evenCountReturnsToUnpinned() {
        let (store, id) = makeStore()
        for _ in 0..<6 {
            store.togglePin(id: id)
        }
        let session = store.sessions.first { $0.id == id }
        #expect(session?.isPinned == false)
    }

    /// The view-layer guard: the row carries an explicit
    /// `.id(session.id)` modifier inside the section's ForEach.
    /// ViewInspector can't reach into a SwiftUI List body cleanly
    /// on macOS, so we assert the sidebar renders without throwing
    /// when sessions are present AND when one has been pinned —
    /// the smoke check that the modifier compiles into the row
    /// path. The structural assertion (id stability + animation
    /// short-circuit) is the source-code review surface; this
    /// test pins that the view still renders both branches so a
    /// future modifier swap doesn't crash the sidebar.
    @Test("Sidebar renders with both pinned and unpinned sessions")
    func sidebarRendersWithMixedPinState() throws {
        let (store, id) = makeStore()
        store.togglePin(id: id)
        _ = store.newSession(alias: "fake-alias-2")
        let sut = SessionsSidebar(store: store, defaultAlias: "")
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Pinned")
        }
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Recents")
        }
    }
}
