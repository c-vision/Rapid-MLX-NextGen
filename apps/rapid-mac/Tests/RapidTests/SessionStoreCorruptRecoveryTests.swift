import Foundation
import Testing
@testable import Rapid

/// Issue #450: pin the corruption-recovery contract so a future
/// "let's simplify the load path" refactor doesn't silently lose
/// the user-facing banner signal. Three invariants:
///
///   1. Every distinct corruption shape (truncated JSON, syntactically
///      invalid bytes, wrong root-object type) triggers the sidecar
///      write AND populates ``lastLoadError`` so the UI banner fires.
///   2. ``dismissLoadError()`` persists the dismissed backup's
///      timestamp to UserDefaults; the next launch reading the SAME
///      sidecar must NOT re-fire the banner.
///   3. A NEWER corruption sidecar (later timestamp) DOES re-fire
///      the banner even after a prior dismissal — the dismissal
///      contract is per-backup, not "never warn again".
@MainActor
@Suite("SessionStore corrupt-load recovery banner (issue #450)")
struct SessionStoreCorruptRecoveryTests {

    /// Per-test UserDefaults suite so the dismissal flag doesn't
    /// leak between tests AND the test never touches the real
    /// process-wide `standard` defaults. Uniquely named per
    /// invocation via UUID.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "rapid.tests.corrupt-recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Helper to seed a corrupt envelope on disk and observe what
    /// the load path produces. Returns the store so the caller
    /// can inspect ``lastLoadError`` and also the parent directory
    /// so the caller can enumerate sidecars.
    ///
    /// Each call gets a UUID-scoped SUBDIRECTORY of the system
    /// temp dir — without this isolation, two parallel-running
    /// tests share the same parent and their cleanup steps race
    /// (one test's enumerated-and-deleted ``sessions.corrupt.*``
    /// wipes another test's still-being-read sidecar). Caller is
    /// expected to remove the subdirectory in a ``defer``.
    private func loadStore(
        with body: Data,
        defaults: UserDefaults
    ) async -> (store: SessionStore, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-corrupt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let tmp = parent.appendingPathComponent("sessions.json")
        try? body.write(to: tmp, options: [.atomic])
        let store = SessionStore(customStoreURL: tmp, customDefaults: defaults)
        await store.awaitInitialLoad()
        return (store, parent)
    }

    /// Centralised cleanup: blow away the per-test temp subdir so
    /// tests don't accumulate cruft in /var/folders.
    private func cleanup(_ parent: URL) {
        try? FileManager.default.removeItem(at: parent)
    }

    @Test("Truncated JSON → backup created AND lastLoadError populated")
    func truncatedJSONTriggersBanner() async throws {
        let truncated = Data("""
        {
          "activeID": "00000000-0000-0000-0000-000000000001",
          "sessions": [
            { "id": "00000000-0000
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: truncated, defaults: defaults)
        defer { cleanup(parent) }

        // Sidebar would otherwise show the empty state — verify
        // the bytes WERE recovered to a sidecar even though
        // ``sessions`` is empty.
        #expect(store.sessions.isEmpty)
        try #require(store.lastLoadError != nil,
                     "truncated JSON must populate lastLoadError so the banner fires")
        let err = store.lastLoadError!
        #expect(err.timestamp > 0)
        #expect(err.backupURL.lastPathComponent.hasPrefix("sessions.corrupt."))
        #expect(err.backupURL.lastPathComponent.hasSuffix(".json"))
        let sidecarBytes = try Data(contentsOf: err.backupURL)
        #expect(sidecarBytes == truncated,
                "the sidecar must preserve the raw corrupt bytes verbatim")
    }

    @Test("Syntactically-invalid JSON (random text) → backup AND banner")
    func invalidJSONTriggersBanner() async throws {
        // Not even close to JSON — a binary garble shape that a
        // disk corruption / partial-write of a different file
        // could plausibly drop onto sessions.json.
        let garble = Data([0x80, 0x81, 0x82, 0x00, 0xff, 0xfe, 0x01])
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: garble, defaults: defaults)
        defer { cleanup(parent) }
        try #require(store.lastLoadError != nil,
                     "garble bytes must populate lastLoadError")
        #expect(store.sessions.isEmpty)
        let sidecarBytes = try Data(contentsOf: store.lastLoadError!.backupURL)
        #expect(sidecarBytes == garble)
    }

    @Test("Wrong root type (JSON array instead of object) → backup AND banner")
    func wrongRootTypeTriggersBanner() async throws {
        // Valid JSON but the wrong shape — the decoder will fail
        // because StoreEnvelope expects an object with sessions /
        // activeID keys, not a bare array.
        let arrayRoot = Data("""
        [
          { "wrong": "shape" }
        ]
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: arrayRoot, defaults: defaults)
        defer { cleanup(parent) }
        try #require(store.lastLoadError != nil,
                     "valid-JSON-but-wrong-shape must populate lastLoadError")
        #expect(store.sessions.isEmpty)
    }

    @Test("Healthy envelope → lastLoadError stays nil (banner suppressed)")
    func healthyEnvelopeDoesNotTriggerBanner() async throws {
        let id = UUID()
        let envelope = Data("""
        {
          "activeID": "\(id.uuidString)",
          "sessions": [
            {
              "id": "\(id.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "Clean",
              "isPinned": false,
              "messages": [],
              "createdAt": "2026-06-26T00:00:00Z",
              "updatedAt": "2026-06-26T00:00:00Z"
            }
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.lastLoadError == nil,
                "a clean load must NOT populate lastLoadError")
        #expect(store.sessions.count == 1)
    }

    @Test("dismissLoadError persists content digest; same corrupt bytes do NOT re-fire on next launch")
    func dismissalSuppressesSameCorruptBytesOnRelaunch() async throws {
        let body = Data("definitely not json".utf8)
        let defaults = makeDefaults()

        // First launch: corruption fires the banner.
        let (firstStore, parent) = await loadStore(with: body, defaults: defaults)
        defer { cleanup(parent) }
        try #require(firstStore.lastLoadError != nil)
        let dismissedDigest = firstStore.lastLoadError!.contentDigest
        let dismissedTimestamp = firstStore.lastLoadError!.timestamp
        firstStore.dismissLoadError()
        #expect(firstStore.lastLoadError == nil,
                "dismissLoadError must clear the in-memory notice")
        #expect(defaults.string(forKey: SessionStore.lastDismissedCorruptionDigestKey)
                == dismissedDigest,
                "dismissal must persist the content digest to UserDefaults")
        // Codex r1 MAJOR fix: dismissal also writes legacy timestamp
        // for backward-compat with downgrade paths.
        #expect(defaults.integer(forKey: SessionStore.lastDismissedCorruptionKey)
                == dismissedTimestamp,
                "dismissal must also persist the legacy timestamp for backward-compat")

        // Simulate a "relaunch" where the canonical sessions.json
        // is still the SAME corrupt bytes (the recovery path does
        // not auto-heal the source file). Previously this re-fired
        // the banner because the new sidecar timestamp beat the
        // dismissed timestamp; the digest-keyed gate keeps the
        // same payload suppressed.
        let storeURL = parent.appendingPathComponent("sessions.json")
        try body.write(to: storeURL, options: [.atomic])
        let relaunched = SessionStore(customStoreURL: storeURL,
                                      customDefaults: defaults)
        await relaunched.awaitInitialLoad()
        #expect(relaunched.lastLoadError == nil,
                "same corrupt bytes after dismissal must stay suppressed across relaunches")
    }

    @Test("Different corrupt bytes re-fire banner even after a prior dismissal")
    func differentCorruptBytesReFireAfterPriorDismissal() async throws {
        let defaults = makeDefaults()
        // Pre-dismiss a previous corruption.
        let firstBody = Data("garble round 1".utf8)
        let (firstStore, parent) = await loadStore(with: firstBody, defaults: defaults)
        defer { cleanup(parent) }
        try #require(firstStore.lastLoadError != nil)
        firstStore.dismissLoadError()

        // Re-load with DIFFERENT corrupt bytes — should re-fire.
        let secondBody = Data("garble round 2 (different)".utf8)
        let storeURL = parent.appendingPathComponent("sessions.json")
        try secondBody.write(to: storeURL, options: [.atomic])
        let relaunched = SessionStore(customStoreURL: storeURL,
                                      customDefaults: defaults)
        await relaunched.awaitInitialLoad()
        try #require(relaunched.lastLoadError != nil,
                     "new corrupt bytes (different digest) must re-fire the banner")
    }

    @Test("Legacy timestamp dismissal (older builds) still suppresses on first re-launch")
    func legacyTimestampDismissalSuppressesOnUpgrade() async throws {
        let defaults = makeDefaults()
        // Pre-seed ONLY the legacy timestamp key with Int.max,
        // simulating a dismissal from an older build that didn't
        // know about the digest key. The new build should still
        // honour the legacy gate.
        defaults.set(Int.max, forKey: SessionStore.lastDismissedCorruptionKey)

        let body = Data("not json".utf8)
        let (store, parent) = await loadStore(with: body, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.lastLoadError == nil,
                "legacy timestamp dismissal at Int.max must suppress the banner on upgrade")
    }
}
