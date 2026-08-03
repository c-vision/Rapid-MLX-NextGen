import Foundation
import Testing
@testable import Rapid

/// Issue #118 — pin the read-only gauge that drives Settings →
/// Storage. Two halves:
///
///   1. ``StorageInfoBuilder.snapshot`` produces the right counts
///      and byte totals for a known on-disk state. We seed a
///      temp ``SessionStore``, write a known envelope, and assert
///      both the in-memory counts and the on-disk byte readings
///      line up.
///   2. ``StorageArchivalPolicy`` round-trips through UserDefaults
///      under the namespaced key and decodes legacy/corrupt values
///      to ``.never`` instead of trapping.
@MainActor
@Suite("StorageInfo + StorageArchivalPolicy — issue #118 gauge contract")
final class StorageInfoTests {
    /// See ``TestDefaultsScope`` + issue #139 — RAII teardown for
    /// the ``UserDefaults(suiteName:)`` plists this suite mints.
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults() -> UserDefaults {
        let name = TestDefaultsScope.mintSuiteName(prefix: "rapid-storage-test-")
        createdSuiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func tmpStore() async -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-storage-test-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: url)
        await store.awaitInitialLoad()
        return store
    }

    // MARK: - StorageInfoBuilder.snapshot

    @Test("Empty store: zero sessions, zero messages, nil sessions.json bytes (file not yet flushed)")
    func emptyStore() async throws {
        let store = await tmpStore()
        let info = StorageInfoBuilder.snapshot(from: store)
        #expect(info.sessionCount == 0)
        #expect(info.messageCount == 0)
        // sessions.json hasn't been written yet — the file doesn't
        // exist, so we report nil rather than 0 to distinguish
        // "couldn't read" from "really empty."
        #expect(info.sessionsFileBytes == nil)
    }

    @Test("After seeding sessions + flushing to disk, sessionsFileBytes is non-nil and positive")
    func sizedAfterFlush() async throws {
        let store = await tmpStore()
        _ = store.newSession(alias: "fake-1")
        _ = store.newSession(alias: "fake-2")
        // Force the debounce-save chain to settle so the file lands.
        // ``flushSync`` is sync + main-actor; the test is
        // ``@MainActor`` so a bare call is fine. It also awaits the
        // active write chain via an inline atomic write.
        store.flushSync()
        let info = StorageInfoBuilder.snapshot(from: store)
        #expect(info.sessionCount == 2)
        let bytes = try #require(info.sessionsFileBytes)
        #expect(bytes > 0)
    }

    @Test("messageCount totals across every session, not just the active one")
    func messageCountSum() async throws {
        let store = await tmpStore()
        let s1 = store.newSession(alias: "a")
        let s2 = store.newSession(alias: "b")
        // 2 messages in s1, 3 in s2 — the public API on SessionStore
        // is ``appendMessage(sessionID:_:)`` taking a fully-formed
        // ``ChatMessage``; there's no role-shorthand helper.
        store.appendMessage(sessionID: s1, ChatMessage(role: .user, content: "u1"))
        store.appendMessage(sessionID: s1, ChatMessage(role: .user, content: "u2"))
        store.appendMessage(sessionID: s2, ChatMessage(role: .user, content: "v1"))
        store.appendMessage(sessionID: s2, ChatMessage(role: .user, content: "v2"))
        store.appendMessage(sessionID: s2, ChatMessage(role: .user, content: "v3"))
        let info = StorageInfoBuilder.snapshot(from: store)
        #expect(info.messageCount == 5)
    }

    @Test("storageRoot is the parent directory of sessionsFileURL (so Reveal in Finder lands the user in the right folder)")
    func storageRootParent() async throws {
        let store = await tmpStore()
        let info = StorageInfoBuilder.snapshot(from: store)
        // Test envelope path is a UUID-suffixed file in the tmp dir,
        // not literally ``sessions.json`` — so compare on parent
        // dir + last-component round-trip rather than hard-coding
        // the production filename.
        #expect(info.storageRoot == store.sessionsFileURL.deletingLastPathComponent())
        #expect(
            info.storageRoot.appendingPathComponent(store.sessionsFileURL.lastPathComponent)
                == store.sessionsFileURL
        )
    }

    @Test("totalDiskBytes is nil when either slot is unreadable (don't show a partial total that reads as real)")
    func partialTotalsAreNil() {
        let info = StorageInfo(
            sessionCount: 1,
            messageCount: 1,
            sessionsFileBytes: 100,
            attachmentsBytes: nil,
            storageRoot: URL(fileURLWithPath: "/tmp")
        )
        #expect(info.totalDiskBytes == nil)
    }

    @Test("totalDiskBytes sums both slots when both are known")
    func totalSums() {
        let info = StorageInfo(
            sessionCount: 1,
            messageCount: 1,
            sessionsFileBytes: 100,
            attachmentsBytes: 200,
            storageRoot: URL(fileURLWithPath: "/tmp")
        )
        #expect(info.totalDiskBytes == 300)
    }

    // MARK: - StorageInfoBuilder.fileSize / directorySize

    @Test("fileSize returns nil for a missing file")
    func fileSizeMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-storage-test-missing-\(UUID().uuidString).bin")
        #expect(StorageInfoBuilder.fileSize(at: url) == nil)
    }

    @Test("fileSize returns the actual byte count for a file we just wrote")
    func fileSizeKnown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-storage-test-bytes-\(UUID().uuidString).bin")
        let payload = Data(repeating: 0xAB, count: 1234)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StorageInfoBuilder.fileSize(at: url) == 1234)
    }

    @Test("directorySize returns nil for a missing directory")
    func directorySizeMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-storage-test-missing-dir-\(UUID().uuidString)")
        #expect(StorageInfoBuilder.directorySize(at: url) == nil)
    }

    @Test("directorySize sums every regular file recursively (covers a future sharded-blob layout)")
    func directorySizeRecursive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("rapid-storage-test-dir-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("top.bin"))
        try Data(repeating: 0, count: 200).write(to: root.appendingPathComponent("a/middle.bin"))
        try Data(repeating: 0, count: 50).write(to: nested.appendingPathComponent("leaf.bin"))

        #expect(StorageInfoBuilder.directorySize(at: root) == 350)
    }

    // MARK: - StorageArchivalPolicy

    @Test("Default policy on a fresh defaults store is .never")
    func archivalDefault() {
        let d = freshDefaults()
        #expect(StorageArchivalPolicy.current(in: d) == .never)
    }

    @Test("Policy round-trips through UserDefaults")
    func archivalRoundTrip() {
        let d = freshDefaults()
        StorageArchivalPolicy.set(.ninetyDays, in: d)
        #expect(StorageArchivalPolicy.current(in: d) == .ninetyDays)
    }

    @Test("Corrupt persisted value falls back to .never (don't crash on a hand-edited plist)")
    func archivalCorruptFallsBack() {
        let d = freshDefaults()
        d.set("garbage-not-a-policy", forKey: StorageArchivalPolicy.userDefaultsKey)
        #expect(StorageArchivalPolicy.current(in: d) == .never)
    }

    @Test("inactivityWindow is nil for .never (caller short-circuits) and seconds elsewhere")
    func inactivityWindowSeconds() {
        // ``inactivityWindow`` returns ``TimeInterval`` (Double); the
        // RHS must be Double too — Swift's ``==`` between ``Double?``
        // and an Int literal would type-check at compile time but
        // the integer literal still gets bridged through ``Optional``
        // in a way that fails ``#expect``'s structural equality. Use
        // explicit Double literals throughout.
        #expect(StorageArchivalPolicy.never.inactivityWindow == nil)
        #expect(StorageArchivalPolicy.thirtyDays.inactivityWindow == 30.0 * 24.0 * 3600.0)
        #expect(StorageArchivalPolicy.ninetyDays.inactivityWindow == 90.0 * 24.0 * 3600.0)
        #expect(StorageArchivalPolicy.oneEightyDays.inactivityWindow == 180.0 * 24.0 * 3600.0)
        #expect(StorageArchivalPolicy.oneYear.inactivityWindow == 365.0 * 24.0 * 3600.0)
    }

    @Test("displayLabel is non-empty for every case (covers Picker rendering)")
    func displayLabelsPresent() {
        for policy in StorageArchivalPolicy.allCases {
            #expect(!policy.displayLabel.isEmpty)
        }
    }
}
