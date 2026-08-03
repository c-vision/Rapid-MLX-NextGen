import Foundation
import Testing
@testable import Rapid

/// Issue #477: a PARTIAL recovery (root decoded, N elements dropped) is a
/// distinct outcome from a FULL document break (#450). It applies the
/// survivors to the sidebar, still sidecars the ORIGINAL bytes, and raises
/// the softer partial notice carrying the recovered / dropped counts so
/// the shrinkage is never silent. This suite pins that three-way split and
/// the ``.unknown``-status non-wedge.
@MainActor
@Suite("SessionStore partial-recovery notice (issue #477)")
struct SessionStorePartialRecoveryTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "rapid.tests.partial-recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func loadStore(
        with body: Data,
        defaults: UserDefaults
    ) async -> (store: SessionStore, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-partial-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent("sessions.json")
        try? body.write(to: tmp, options: [.atomic])
        let store = SessionStore(customStoreURL: tmp, customDefaults: defaults)
        await store.awaitInitialLoad()
        return (store, parent)
    }

    private func cleanup(_ parent: URL) {
        try? FileManager.default.removeItem(at: parent)
    }

    private func message(id: UUID, role: String, status: String = "complete") -> String {
        """
        {
          "id": "\(id.uuidString)", "role": "\(role)", "content": "hi",
          "reasoning": "", "status": "\(status)", "createdAt": "2026-06-26T00:00:00Z"
        }
        """
    }

    private func session(id: UUID, title: String, messages: [String]) -> String {
        """
        {
          "id": "\(id.uuidString)", "alias": "qwen3.5-4b", "title": "\(title)",
          "isPinned": false, "messages": [ \(messages.joined(separator: ",")) ],
          "createdAt": "2026-06-26T00:00:00Z", "updatedAt": "2026-06-26T00:00:00Z"
        }
        """
    }

    @Test("Partial drop applies survivors, sidecars original bytes, raises .partial notice")
    func partialDropRaisesPartialNotice() async throws {
        let s0 = UUID(), s1 = UUID(), s2 = UUID()
        // session[1] is malformed (missing required createdAt) → dropped.
        let envelope = Data("""
        {
          "sessions": [
            \(session(id: s0, title: "First", messages: [message(id: UUID(), role: "user")])),
            { "id": "\(s1.uuidString)", "alias": "qwen3.5-4b", "title": "Bad",
              "isPinned": false, "messages": [], "updatedAt": "2026-06-26T00:00:00Z" },
            \(session(id: s2, title: "Third", messages: [message(id: UUID(), role: "assistant")]))
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        // Survivors applied (NOT wiped).
        #expect(store.sessions.count == 2)
        #expect(Set(store.sessions.map(\.id)) == [s0, s2])

        // Partial notice raised, distinct from a full break.
        let err = try #require(store.lastLoadError,
                               "a partial drop must raise a recovery notice")
        #expect(err.kind == .partial(recoveredChats: 2, droppedElements: 1))

        // Original bytes preserved verbatim in the backup.
        let sidecarBytes = try Data(contentsOf: err.backupURL)
        #expect(sidecarBytes == envelope)
        #expect(err.backupURL.lastPathComponent.hasPrefix("sessions.corrupt."))

        // The backup shows up in the Settings Recover-from-backup list.
        // Compare by filename: contentsOfDirectory and appendingPathComponent
        // can differ on /var vs /private/var symlink normalisation.
        #expect(store.availableSessionBackups().contains {
            $0.url.lastPathComponent == err.backupURL.lastPathComponent
        })
    }

    @Test("Dropped MESSAGES (not whole session) also raise the partial notice with the right count")
    func droppedMessagesRaisePartialNotice() async throws {
        let s0 = UUID()
        // One session; its second message is malformed (missing content)
        // so it drops, but the session and its first message survive.
        let goodMsg = message(id: UUID(), role: "user")
        let badMsg = """
        { "id": "\(UUID().uuidString)", "role": "assistant",
          "reasoning": "", "status": "complete", "createdAt": "2026-06-26T00:00:00Z" }
        """
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Solo", messages: [goodMsg, badMsg])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.messages.count == 1)
        let err = try #require(store.lastLoadError)
        #expect(err.kind == .partial(recoveredChats: 1, droppedElements: 1))
    }

    @Test("Full document break stays .full (distinct from partial)")
    func fullBreakStaysFull() async throws {
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: Data("not json at all".utf8), defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.sessions.isEmpty)
        let err = try #require(store.lastLoadError)
        #expect(err.kind == .full)
    }

    @Test("Clean envelope raises no notice at all")
    func cleanEnvelopeNoNotice() async throws {
        let s0 = UUID()
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Clean", messages: [message(id: UUID(), role: "user")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.sessions.count == 1)
        #expect(store.lastLoadError == nil)
    }

    @Test("restoreSessionBackup swaps a backup in as live history and keeps the swap reversible")
    func restoreSwapsBackupInReversibly() async throws {
        let s0 = UUID()
        // Full break so the live file is empty and a backup exists.
        let corrupt = Data("not json".utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: corrupt, defaults: defaults)
        defer { cleanup(parent) }
        let backups = store.availableSessionBackups()
        let backup = try #require(backups.first, "the corrupt load should have left a backup")

        // Point the backup at a KNOWN-GOOD envelope so we can assert the
        // swap took (the corrupt load backed up the garbage bytes; here we
        // overwrite the backup file with a clean envelope to restore).
        let clean = Data("""
        { "sessions": [ \(session(id: s0, title: "Recovered", messages: [message(id: UUID(), role: "user")])) ] }
        """.utf8)
        try clean.write(to: backup.url, options: [.atomic])

        try await store.restoreSessionBackup(backup)

        // The live file now holds the clean bytes.
        let live = parent.appendingPathComponent("sessions.json")
        let liveBytes = try Data(contentsOf: live)
        #expect(liveBytes == clean)

        // Codex BLOCKING fix: the restore HOT-LOADS into memory, so the
        // sidebar shows the recovered session immediately AND a later
        // quit-flush writes the restored content (not stale state).
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == s0)
        #expect(store.sessions.first?.title == "Recovered")
        // The stale load-failure notice is cleared by the restore.
        #expect(store.lastLoadError == nil)

        // The swap is reversible: the previous live (garbage) was preserved
        // as a fresh backup, so the list still has an entry to fall back to.
        #expect(!store.availableSessionBackups().isEmpty)
    }

    @Test("restoreSessionBackup refuses an unreadable backup WITHOUT touching live history")
    func restoreRefusesUnreadableBackupLeavesLiveIntact() async throws {
        let s0 = UUID()
        // Start from a healthy live store.
        let clean = Data("""
        { "sessions": [ \(session(id: s0, title: "Keep me", messages: [message(id: UUID(), role: "user")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: clean, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.sessions.count == 1)

        // Hand-craft an unreadable backup file in the store dir.
        let badBackupURL = parent.appendingPathComponent("sessions.corrupt.999.json")
        try Data("total garbage not json".utf8).write(to: badBackupURL, options: [.atomic])
        let badBackup = try #require(
            store.availableSessionBackups().first { $0.url.lastPathComponent == "sessions.corrupt.999.json" }
        )

        // Restore must throw and NOT destroy the live history.
        await #expect(throws: SessionRestoreError.unreadableBackup) {
            try await store.restoreSessionBackup(badBackup)
        }
        // Live file + in-memory sessions untouched.
        let live = parent.appendingPathComponent("sessions.json")
        #expect(try Data(contentsOf: live) == clean)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.title == "Keep me")
    }

    @Test("restoreSessionBackup refuses while a reply is streaming (leaves live intact)")
    func restoreRefusesWhileStreaming() async throws {
        let s0 = UUID()
        // Post-#476, a persisted ``.streaming`` row is a STALE crash
        // artifact that load normalizes away — it is NOT a live stream. A
        // genuine in-flight reply is an in-memory row, so load a clean
        // store and induce one via the mutation path.
        let clean = Data("""
        { "sessions": [ \(session(id: s0, title: "Live", messages: [message(id: UUID(), role: "user")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: clean, defaults: defaults)
        defer { cleanup(parent) }
        store.appendMessage(sessionID: s0, ChatMessage(role: .assistant, status: .streaming))
        #expect(store.streamingMessageCount == 1)

        // A valid backup exists on disk.
        let backupURL = parent.appendingPathComponent("sessions.corrupt.111.json")
        let backupBytes = Data("""
        { "sessions": [ \(session(id: UUID(), title: "Other", messages: [message(id: UUID(), role: "user")])) ] }
        """.utf8)
        try backupBytes.write(to: backupURL, options: [.atomic])
        let backup = try #require(
            store.availableSessionBackups().first { $0.url.lastPathComponent == "sessions.corrupt.111.json" }
        )

        await #expect(throws: SessionRestoreError.streamingInProgress) {
            try await store.restoreSessionBackup(backup)
        }
        // Live history untouched; still the streaming session.
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == s0)
    }

    @Test("Partial recovery persists the healed survivor envelope (next launch decodes clean)")
    func partialRecoveryHealsCanonicalFile() async throws {
        let s0 = UUID(), s1 = UUID()
        // session[1] malformed → partial recovery of session[0].
        let envelope = Data("""
        {
          "sessions": [
            \(session(id: s0, title: "Good", messages: [message(id: UUID(), role: "user")])),
            { "id": "\(s1.uuidString)", "alias": "qwen3.5-4b", "title": "Bad",
              "isPinned": false, "messages": [], "updatedAt": "2026-06-26T00:00:00Z" }
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.sessions.count == 1)

        // Flush the scheduled save so the canonical file is rewritten to
        // the survivors, then relaunch and confirm a CLEAN decode (no
        // partial notice) — the damaged original no longer re-decodes.
        await store.flush()
        let storeURL = parent.appendingPathComponent("sessions.json")
        let relaunched = SessionStore(customStoreURL: storeURL, customDefaults: defaults)
        await relaunched.awaitInitialLoad()
        #expect(relaunched.sessions.count == 1)
        #expect(relaunched.sessions.first?.id == s0)
        #expect(relaunched.lastLoadError == nil,
                "healed canonical file must decode clean on the next launch")
    }

    @Test(".unknown status must NOT seed the streaming counter (no typing-dot wedge)")
    func unknownStatusDoesNotSeedStreamingCount() async throws {
        let s0 = UUID()
        // A message with a forward-incompatible status decodes to
        // .unknown; it must be treated like .complete, not .streaming.
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Restored",
              messages: [message(id: UUID(), role: "assistant", status: "queued")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.messages.first?.status == .unknown)
        #expect(store.streamingMessageCount == 0,
                "an .unknown status must seed like .complete, never .streaming")
    }
}
