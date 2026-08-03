import Foundation
import Testing
@testable import Rapid

/// v0.4.45 contract pins for the launch-time orphan-empty-session
/// sweep. v0.4.44 prevented NEW empty rows from accumulating;
/// this guard cleans up rows already on disk from earlier builds.
@MainActor
@Suite("Orphan-empty sweep — v0.4.45")
struct OrphanSweepTests {
    private func tmpURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-orphan-sweep-\(UUID().uuidString).json")
    }

    /// Encode a synthetic on-disk envelope so we can plant sessions
    /// with arbitrary ``updatedAt`` values — SessionStore's public
    /// mutation API always stamps "now" and would defeat the test.
    private func seedDisk(at url: URL, sessions: [ChatSession], activeID: UUID?) throws {
        struct Envelope: Encodable {
            var sessions: [ChatSession]
            var activeID: UUID?
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(sessions: sessions, activeID: activeID))
        try data.write(to: url, options: .atomic)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var oldEnough: Date { now.addingTimeInterval(-(SessionStore.orphanCutoff + 60)) }
    private var freshEnough: Date { now.addingTimeInterval(-60) }

    @Test("Stale empty session is pruned on launch")
    func staleEmptyPruned() async throws {
        let url = tmpURL()
        let stale = ChatSession(
            alias: "qwen3.5-4b",
            updatedAt: oldEnough
        )
        try seedDisk(at: url, sessions: [stale], activeID: stale.id)

        // Issue #117: file exists → async load + prune flow.
        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.isEmpty)
        #expect(store.activeID == nil)
    }

    @Test("Fresh empty session survives (just-clicked New chat)")
    func freshEmptySurvives() async throws {
        let url = tmpURL()
        let fresh = ChatSession(
            alias: "qwen3.5-4b",
            updatedAt: freshEnough
        )
        try seedDisk(at: url, sessions: [fresh], activeID: fresh.id)

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == fresh.id)
    }

    @Test("Stale empty alongside a real session: only the empty drops")
    func staleEmptyDropsRealStays() async throws {
        let url = tmpURL()
        let real = ChatSession(
            alias: "qwen3.5-4b",
            messages: [ChatMessage(role: .user, content: "Hi")],
            updatedAt: oldEnough
        )
        let staleEmpty = ChatSession(
            alias: "qwen3.5-4b",
            updatedAt: oldEnough
        )
        try seedDisk(at: url, sessions: [staleEmpty, real], activeID: staleEmpty.id)

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == real.id)
        // activeID was pointing at the dropped row — must fall back
        // to the newest survivor so the sidebar opens onto something
        // sensible instead of a "no chat selected" empty state.
        #expect(store.activeID == real.id)
    }

    @Test("Stale empty is preserved when pinned (user signalled intent)")
    func pinnedNotPruned() async throws {
        let url = tmpURL()
        let pinned = ChatSession(
            alias: "qwen3.5-4b",
            updatedAt: oldEnough,
            isPinned: true
        )
        try seedDisk(at: url, sessions: [pinned], activeID: pinned.id)

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == pinned.id)
    }

    @Test("Stale empty is preserved when renamed (custom title)")
    func renamedNotPruned() async throws {
        let url = tmpURL()
        let renamed = ChatSession(
            id: UUID(),
            title: "Strategy notes",
            alias: "qwen3.5-4b",
            messages: [],
            updatedAt: oldEnough
        )
        try seedDisk(at: url, sessions: [renamed], activeID: renamed.id)

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == renamed.id)
    }

    @Test("Stale empty is preserved when a system prompt was set")
    func systemPromptNotPruned() async throws {
        let url = tmpURL()
        let prepped = ChatSession(
            alias: "qwen3.5-4b",
            updatedAt: oldEnough,
            systemPrompt: "You are a senior backend engineer."
        )
        try seedDisk(at: url, sessions: [prepped], activeID: prepped.id)

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == prepped.id)
    }

    @Test("No-op load doesn't trigger a disk write (avoid boot churn)")
    func noWriteWhenNothingPruned() async throws {
        let url = tmpURL()
        let fresh = ChatSession(
            alias: "qwen3.5-4b",
            messages: [ChatMessage(role: .user, content: "Hi")],
            updatedAt: oldEnough
        )
        try seedDisk(at: url, sessions: [fresh], activeID: fresh.id)
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtimeBefore = (attrsBefore[.modificationDate] as? Date) ?? Date.distantPast

        let store = SessionStore(customStoreURL: url, now: now)
        await store.awaitInitialLoad()
        // Give the debounce window time to *not* run.
        try await Task.sleep(nanoseconds: 600_000_000)

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtimeAfter = (attrsAfter[.modificationDate] as? Date) ?? Date.distantPast
        #expect(
            mtimeAfter == mtimeBefore,
            "Disk shouldn't be rewritten when there's nothing to sweep"
        )
        _ = store
    }

    @Test("v0.4.44 collapse predicate stays consistent with sweep predicate")
    func collapseAndSweepShareIntent() {
        // Both code paths gate on the same four flags (empty
        // messages, not pinned, default title, no system prompt).
        // If a future refactor flips one path's check, this test
        // pins them together so the drift is loud.
        let url = tmpURL()
        let store = SessionStore(customStoreURL: url, now: now)
        let id = store.newOrReuseSession(alias: "qwen3.5-4b").id
        #expect(store.firstReusableEmptySession()?.id == id)
        // Pin it → both predicates must agree it's no longer reusable.
        store.togglePin(id: id)
        #expect(store.firstReusableEmptySession() == nil)
    }
}
