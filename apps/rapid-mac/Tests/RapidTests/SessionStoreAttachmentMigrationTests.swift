import Foundation
import Testing
@testable import Rapid

/// Issue #22: pin the on-load migration path that rewrites legacy
/// inline ``data:`` image bodies into disk-backed ``sha256:`` refs
/// in ``AttachmentStorage``. This is the critical safety pass — if
/// it's wrong the user's screenshots either silently disappear from
/// chat history or stay base64-inlined and the envelope never
/// shrinks.
@MainActor
@Suite("SessionStore attachment migration (issue #22)")
final class SessionStoreAttachmentMigrationTests {

    /// Per-test temp directories minted via ``tempStoreURL()``.
    /// Drained by ``deinit`` (see issue #294 — same class of leak
    /// as #139's ``TestDefaultsScope``, but for filesystem dirs
    /// under ``NSTemporaryDirectory()`` rather than ``UserDefaults``
    /// plists under ``~/Library/Preferences``). Each entry is the
    /// parent ``rapid-#22-<UUID>`` dir, NOT the inner ``sessions.json``
    /// — removing the parent recursively also reaps the sibling
    /// ``attachments/<hex>`` blob store and any ``legacy-encoder-*.json``
    /// scratch file ``writeLegacyEnvelope`` lands next to it.
    ///
    /// ``nonisolated(unsafe)`` mirrors the ``createdSuiteNames``
    /// pattern in ``TestDefaultsScope``'s consumers — ``deinit``
    /// is always non-isolated and must reach mutable state without
    /// an actor hop. Swift Testing runs each ``@Test`` on a fresh
    /// instance, so there is no cross-test array sharing.
    nonisolated(unsafe) private var createdTempDirs: [URL] = []

    deinit {
        for dir in createdTempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Build a temp ``sessions.json`` path. The matching
    /// ``attachments/`` dir lives as a sibling — that's the
    /// derived-path contract ``SessionStore`` uses to pick its
    /// ``AttachmentStorage`` instance.
    ///
    /// The minted parent directory is tracked in ``createdTempDirs``
    /// so ``deinit`` can recursively unlink it (sessions.json +
    /// attachments/<hex> + any scratch files). See issue #294 for
    /// the 544-straggler reproducer this teardown fixes.
    private func tempStoreURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rapid-#22-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdTempDirs.append(dir)
        return dir.appendingPathComponent("sessions.json")
    }

    /// Build a sessions.json envelope on disk carrying ONE image
    /// attachment with a legacy data: URL body so we can replay the
    /// pre-#22 shape.
    ///
    /// Encodes via real Swift types + the production-shape
    /// ``JSONEncoder`` so the envelope is byte-compatible with
    /// whatever the live ``SessionStore`` writes. Hand-rolled
    /// JSON would drift the moment a new field lands on
    /// ``ChatMessage`` / ``ChatSession``.
    @MainActor
    private func writeLegacyEnvelope(at url: URL, imageBytes: Data) throws {
        let att = Attachment(
            kind: .image,
            filename: "screenshot.png",
            mime: "image/png",
            body: "data:image/png;base64,\(imageBytes.base64EncodedString())",
            sizeBytes: imageBytes.count
        )
        let msg = ChatMessage(
            role: .user,
            content: "what is this?",
            status: .complete,
            attachments: [att]
        )
        let session = ChatSession(
            id: UUID(),
            title: "Legacy session",
            alias: "qwen3-vl-4b",
            messages: [msg],
            createdAt: Date(),
            updatedAt: Date()
        )
        // Encode via a one-off store: pick a fresh tmp directory,
        // construct the store, populate via the public API
        // (``newSession`` + ``appendMessage``), and flush. We
        // can't directly access the private ``StoreEnvelope``
        // shape, but ``flushSync`` produces it byte-identical to
        // production. We then move the file to ``url`` so the
        // test's real target picks it up on its own ``init``.
        _ = session // identity only — we rebuild via the public API
        let scratchURL = url.deletingLastPathComponent()
            .appendingPathComponent("legacy-encoder-\(UUID().uuidString).json")
        let scratchStore = SessionStore(customStoreURL: scratchURL)
        // Fast path: file absent → loadState == .loaded before init returns.
        let id = scratchStore.newSession(alias: "qwen3-vl-4b")
        _ = scratchStore.appendMessage(sessionID: id, msg)
        scratchStore.flushSync()
        try FileManager.default.moveItem(at: scratchURL, to: url)
    }

    @Test("Legacy data: body migrates to sha256: ref on load, blob lands on disk")
    func migrationRewritesBody() async throws {
        let storeURL = tempStoreURL()
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                               0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        try await MainActor.run {
            try writeLegacyEnvelope(at: storeURL, imageBytes: imageBytes)
        }

        let store = await SessionStore(customStoreURL: storeURL)
        await store.awaitInitialLoad()

        let sessions = await store.sessions
        let firstSession = try #require(sessions.first)
        let firstMsg = try #require(firstSession.messages.first)
        let att = try #require(firstMsg.attachments?.first)
        // Body MUST have flipped from data: to sha256:.
        #expect(att.body.hasPrefix(AttachmentBodyPrefix.hashRef),
                "migration must rewrite body to sha256: ref")
        let hash = try #require(AttachmentBodyPrefix.hash(in: att.body))
        // Hash MUST be the SHA-256 of the original bytes.
        #expect(hash == AttachmentStorage.sha256Hex(imageBytes))
        // Blob file MUST exist at attachments/<hex>.
        let storage = await store.attachmentStorage
        let blobURL = storage.url(forHash: hash)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))
        // Disk contents match the input bytes — no encode drift.
        let onDisk = try Data(contentsOf: blobURL)
        #expect(onDisk == imageBytes)
    }

    @Test("Migration runs only once — second load finds nothing legacy and triggers no rewrite")
    func migrationIsIdempotent() async throws {
        let storeURL = tempStoreURL()
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0xCA, 0xFE])
        try await MainActor.run {
            try writeLegacyEnvelope(at: storeURL, imageBytes: imageBytes)
        }

        // First load migrates + saves. The save fires through the
        // debounce (400 ms) so we hand it time to land before the
        // second load reads it back.
        do {
            let store1 = await SessionStore(customStoreURL: storeURL)
            await store1.awaitInitialLoad()
            await store1.flush()
        }

        // Second load reads the migrated envelope; no data: bodies
        // remain, so no migration happens.
        let store2 = await SessionStore(customStoreURL: storeURL)
        await store2.awaitInitialLoad()
        let sessions = await store2.sessions
        let firstSession = try #require(sessions.first)
        let firstMsg = try #require(firstSession.messages.first)
        let att = try #require(firstMsg.attachments?.first)
        // Still sha256: shape — and same hash.
        #expect(att.body.hasPrefix(AttachmentBodyPrefix.hashRef))
        let hash = try #require(AttachmentBodyPrefix.hash(in: att.body))
        #expect(hash == AttachmentStorage.sha256Hex(imageBytes))
    }

    @Test("Loading an envelope built without legacy attachments triggers no migration save")
    func noChurnWithoutLegacyAttachments() async throws {
        let storeURL = tempStoreURL()
        // Seed via the production write path so the envelope decodes
        // cleanly on the next load. The session has a custom title
        // (NOT "New chat") so ``pruneStaleOrphanEmpties`` doesn't
        // sweep it on boot — which would itself trigger a save and
        // contaminate the "no churn" signal.
        try await MainActor.run {
            let seed = SessionStore(customStoreURL: storeURL)
            let id = seed.newSession(alias: "qwen3.5-4b")
            // Promote out of the orphan-empty predicate by adding a
            // real message (matches what a normal user has after
            // their first turn).
            _ = seed.appendMessage(
                sessionID: id,
                ChatMessage(role: .user, content: "hello", status: .complete)
            )
            seed.flushSync()
        }
        let mtimeBefore = (try storeURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)!

        // Sleep so the next write's mtime would be distinguishable
        // from the seed write — sub-second resolution would let a
        // spurious save pass the equality assertion.
        try await Task.sleep(nanoseconds: 50_000_000)

        let store = await SessionStore(customStoreURL: storeURL)
        await store.awaitInitialLoad()
        // Wait past the 400 ms debounce + a small grace so any
        // ``scheduleSave`` queued by the load path would have
        // landed on disk. We deliberately don't call ``flush()`` —
        // that method writes unconditionally and would mask the
        // signal we're trying to test.
        try await Task.sleep(nanoseconds: 600_000_000)
        let mtimeAfter = (try storeURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)!
        #expect(mtimeAfter == mtimeBefore,
                "load of an envelope with no legacy attachments + no in-memory mutations must not rewrite the file")
        _ = store // keep alive past the sleep
    }

    @Test("Wire encoding resolves migrated hash refs back to data URLs")
    func wireResolvesMigratedHashRefs() async throws {
        let storeURL = tempStoreURL()
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0xBA, 0xAD])
        try await MainActor.run {
            try writeLegacyEnvelope(at: storeURL, imageBytes: imageBytes)
        }

        let store = await SessionStore(customStoreURL: storeURL)
        await store.awaitInitialLoad()
        let sessions = await store.sessions
        let firstMsg = try #require(sessions.first?.messages.first)
        let storage = await store.attachmentStorage

        // Build the wire message via the same path ChatStreamClient
        // uses. The resolved image_url must be the data URL we'd
        // have produced pre-#22.
        let wire = Wire.Message(from: firstMsg, storage: storage)
        let encoded = try JSONEncoder().encode(wire)
        let body = try #require(String(data: encoded, encoding: .utf8))
        let expectedDataURL = "data:image/png;base64,\(imageBytes.base64EncodedString())"
        let escaped = expectedDataURL.replacingOccurrences(of: "/", with: "\\/")
        #expect(body.contains("\"url\":\"\(escaped)\""),
                "wire MUST carry the resolved data URL, not the hash ref")
    }
}
