import Foundation
import Testing
@testable import Rapid

/// Contract tests for the ⌘[/⌘] sidebar navigation added in
/// ``SessionStore.selectPreviousSession`` / ``selectNextSession``.
/// All assertions operate on the synchronous SessionStore APIs —
/// no SwiftUI boot — so the keyboard-navigation behaviour is locked
/// independently of ChatView's carrier wiring.
@MainActor
@Suite("SessionStore ⌘[/⌘] navigation")
struct SessionNavigationTests {

    // MARK: - Helpers

    /// Build an isolated store on a tmpfile so the test never
    /// touches the user's real session file.
    private func freshStore() -> (SessionStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-nav-\(UUID().uuidString).json")
        return (SessionStore(customStoreURL: tmp), tmp)
    }

    // MARK: - orderedForNavigation

    @Test("orderedForNavigation puts pinned first, then recents — both newest-first")
    func orderRespectsPinAndRecency() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = store.newSession(alias: "qwen3.6-27b")
        let b = store.newSession(alias: "qwen3.6-27b")
        let c = store.newSession(alias: "qwen3.6-27b")
        // Pin the middle one — it should jump ahead of both
        // recents in the navigation order.
        store.togglePin(id: b)

        let ordered = store.orderedForNavigation
        try? #require(ordered.count == 3)
        #expect(ordered.first == b, "pinned session leads the order")
        // Of the two recents, the more recently created (c) comes
        // first because c was inserted at index 0 of `sessions`
        // and its updatedAt is the newest.
        #expect(ordered[1] == c)
        #expect(ordered[2] == a)
    }

    @Test("orderedForNavigation is empty when there are no sessions")
    func emptyStoreYieldsEmptyOrder() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(store.orderedForNavigation.isEmpty)
    }

    // MARK: - selectPreviousSession

    @Test("⌘[ moves activeID up one row in display order")
    func previousMovesUp() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = store.newSession(alias: "qwen3.6-27b")
        let b = store.newSession(alias: "qwen3.6-27b")
        let c = store.newSession(alias: "qwen3.6-27b")
        // Order: [c, b, a]. Start on `a` (the bottom).
        store.activeID = a

        let moved = store.selectPreviousSession()
        #expect(moved == b)
        #expect(store.activeID == b)

        let movedAgain = store.selectPreviousSession()
        #expect(movedAgain == c)
        #expect(store.activeID == c)
    }

    @Test("⌘[ at the top is a no-op (no wrap)")
    func previousAtTopIsNoop() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = store.newSession(alias: "qwen3.6-27b")
        let b = store.newSession(alias: "qwen3.6-27b")
        // Order: [b, a]. Active is already at the top (b).
        store.activeID = b

        let moved = store.selectPreviousSession()
        #expect(moved == nil)
        #expect(store.activeID == b, "active does not wrap to bottom")
    }

    // MARK: - selectNextSession

    @Test("⌘] moves activeID down one row in display order")
    func nextMovesDown() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = store.newSession(alias: "qwen3.6-27b")
        let b = store.newSession(alias: "qwen3.6-27b")
        let c = store.newSession(alias: "qwen3.6-27b")
        // Order: [c, b, a]. Start on `c` (the top).
        store.activeID = c

        let moved = store.selectNextSession()
        #expect(moved == b)
        #expect(store.activeID == b)

        let movedAgain = store.selectNextSession()
        #expect(movedAgain == a)
        #expect(store.activeID == a)
    }

    @Test("⌘] at the bottom is a no-op (no wrap)")
    func nextAtBottomIsNoop() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = store.newSession(alias: "qwen3.6-27b")
        let b = store.newSession(alias: "qwen3.6-27b")
        // Order: [b, a]. Active is already at the bottom (a).
        store.activeID = a

        let moved = store.selectNextSession()
        #expect(moved == nil)
        #expect(store.activeID == a, "active does not wrap to top")
    }

    // MARK: - Degenerate inputs

    @Test("Both nav APIs no-op when activeID is nil")
    func nilActiveYieldsNoop() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = store.newSession(alias: "qwen3.6-27b")
        store.activeID = nil

        #expect(store.selectPreviousSession() == nil)
        #expect(store.selectNextSession() == nil)
        #expect(store.activeID == nil)
    }

    @Test("Both nav APIs no-op with a single session")
    func singleSessionStays() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let only = store.newSession(alias: "qwen3.6-27b")

        #expect(store.selectPreviousSession() == nil)
        #expect(store.activeID == only)
        #expect(store.selectNextSession() == nil)
        #expect(store.activeID == only)
    }

    @Test("⌘[ from a pinned session steps to the next pinned, not into recents")
    func navStaysWithinPinnedGroupWhenItExists() {
        let (store, tmp) = freshStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p1 = store.newSession(alias: "qwen3.6-27b")
        let p2 = store.newSession(alias: "qwen3.6-27b")
        let r1 = store.newSession(alias: "qwen3.6-27b")
        store.togglePin(id: p1)
        store.togglePin(id: p2)
        // Order: pinned [p2, p1] then recents [r1]. Active on r1.
        store.activeID = r1
        // ⌘[ from r1 → p1 (last pinned).
        #expect(store.selectPreviousSession() == p1)
        // ⌘[ again → p2 (top pinned).
        #expect(store.selectPreviousSession() == p2)
        // ⌘[ again at top → nil.
        #expect(store.selectPreviousSession() == nil)
    }
}
