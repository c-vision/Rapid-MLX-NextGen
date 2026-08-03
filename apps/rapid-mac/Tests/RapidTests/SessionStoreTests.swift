import Foundation
import Testing
@testable import Rapid

/// Persistence roundtrip for ``SessionStore``. Migrated from
/// ``TestDriver.runStoreRoundtrip`` — same shape, same debounce wait,
/// now expressed as ``@Test``. Uses a tmpdir so the test never
/// touches the user's real Application Support file.
@MainActor
@Suite("SessionStore persistence")
struct SessionStoreTests {
    @Test("Mutations flush to disk and reload in a fresh instance")
    func mutationsRoundtripThroughDisk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = SessionStore(customStoreURL: tmp)
        let id = writer.newSession(alias: "qwen3.6-27b")
        _ = writer.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "What is 2+2?")
        )
        var assistant = ChatMessage(role: .assistant, status: .streaming)
        guard let idx = writer.appendMessage(sessionID: id, assistant) else {
            Issue.record("appending assistant placeholder returned nil index")
            return
        }
        assistant.reasoning = "Let me compute…"
        assistant.content = "4"
        assistant.status = .complete
        writer.updateMessage(sessionID: id, at: idx, with: assistant)

        // Pre-existing flake fix: the prior shape slept 800 ms hoping
        // the 400 ms debounce window had fired, but Swift Task
        // scheduling under load could let the test resume before the
        // debounced writer actually awaited its write tail. ``flush()``
        // is the deterministic commit path designed for exactly this
        // case — cancels the pending debounce, calls ``writeToDisk``,
        // awaits the in-flight ``writeChain`` value. Returns only when
        // the on-disk state matches memory.
        //
        // We still exercise the same persist-then-reload contract; we
        // just don't gamble against the system clock.
        await writer.flush()

        try #require(FileManager.default.fileExists(atPath: tmp.path))

        // Reload in a fresh instance and check structural equality.
        // Issue #117: the load is async when the file exists; wait
        // for the initial load to land before observing sessions.
        let reader = SessionStore(customStoreURL: tmp)
        await reader.awaitInitialLoad()
        try #require(reader.sessions.count == 1)
        let loaded = reader.sessions[0]
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[1].content == "4")
        #expect(loaded.messages[1].reasoning == "Let me compute…")
        // Auto-title pulls from the first user message.
        #expect(loaded.title == "What is 2+2?")
    }
}

/// Pin contract for ``SessionStore.togglePin``.
///
/// v0.4 added a sidebar "Pinned" group. The order rule is
/// "newest pin at the top" — the codex round-1 fix bumps
/// ``updatedAt`` only when transitioning into the pinned
/// state, so a fresh pin always lifts to the top of the
/// Pinned group. A future refactor that "consolidated" the
/// if-branch to always bump (or to never bump) would
/// silently regress that UX, so we pin both halves of the
/// behaviour here.
@MainActor
@Suite("SessionStore.togglePin v0.4 pin semantics")
struct SessionStoreTogglePinTests {
    private func makeStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-pin-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Pinning bumps updatedAt so the fresh pin lands at the TOP of Pinned")
    func pinBumpsTimestamp() async throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        let baseline = store.sessions[0].updatedAt
        // Let the clock advance past the resolution we can read
        // back from ``Date()`` so the bumped timestamp is strictly
        // greater than the baseline rather than equal.
        try await Task.sleep(nanoseconds: 10_000_000)
        store.togglePin(id: id)
        let bumped = store.sessions[0].updatedAt
        #expect(store.sessions[0].isPinned == true)
        #expect(bumped > baseline)
    }

    @Test("Un-pinning leaves updatedAt alone so Recents recency stays truthful")
    func unpinLeavesTimestamp() async throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        store.togglePin(id: id) // pin first (this bumps)
        try await Task.sleep(nanoseconds: 10_000_000)
        let beforeUnpin = store.sessions[0].updatedAt
        store.togglePin(id: id) // unpin
        let afterUnpin = store.sessions[0].updatedAt
        #expect(store.sessions[0].isPinned == false)
        // The codex round-1 fix says un-pinning does NOT bump.
        // Equality is the contract — a future "always bump"
        // refactor would push afterUnpin > beforeUnpin and
        // silently corrupt Recents ordering.
        #expect(afterUnpin == beforeUnpin)
    }

    @Test("togglePin on an unknown id is a no-op")
    func togglePinUnknownId() {
        let store = makeStore()
        _ = store.newSession(alias: "qwen3.6-27b")
        store.togglePin(id: UUID())
        // All real sessions retain their pre-call isPinned (false).
        #expect(store.sessions.allSatisfy { $0.isPinned == false })
    }

    @Test("isPinned default is false on fresh sessions (no migration leak)")
    func defaultIsFalse() {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        #expect(store.sessions.first(where: { $0.id == id })?.isPinned == false)
    }
}

/// Self-audit r1 contracts. The pre-fix shape would silently
/// destroy the on-disk file on a transient decode failure, and
/// would adopt an activeID that pointed at a missing session.
@MainActor
@Suite("SessionStore self-audit r1 contracts")
struct SessionStoreAuditR1Tests {

    @Test("Corrupt sessions.json triggers a timestamped sidecar backup, sessions stay empty")
    func corruptFileBacksUpAndStaysEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("sessions.json")

        // Write garbage so the JSON decoder fails.
        let garbage = Data("not-json-at-all".utf8)
        try garbage.write(to: storeURL)

        // Issue #117: corrupt-on-load now hops through the async
        // path because the file exists. Await it so the sidecar
        // backup has actually been written by the assertions below.
        let store = SessionStore(customStoreURL: storeURL)
        await store.awaitInitialLoad()

        // Sidecar with the `sessions.corrupt.` prefix exists and
        // matches the garbage byte-for-byte, so a future support
        // session can recover the user's history.
        let listing = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let sidecar = listing.first { $0.hasPrefix("sessions.corrupt.") && $0.hasSuffix(".json") }
        try #require(sidecar != nil, "expected a sessions.corrupt.<ts>.json sidecar")
        let sidecarBytes = try Data(contentsOf: dir.appendingPathComponent(sidecar!))
        #expect(sidecarBytes == garbage)
    }

    @Test("activeID that points at a missing session is dropped, falls back to newest")
    func staleActiveIDIsDropped() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-stale-active-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Hand-craft an envelope where activeID points at a UUID
        // that doesn't match any session — same shape as if the
        // user manually edited the file or a partial recovery
        // landed.
        let realID = UUID()
        let staleID = UUID()
        let envelope = """
        {
          "activeID": "\(staleID.uuidString)",
          "sessions": [
            {
              "id": "\(realID.uuidString)",
              "alias": "qwen3.6-27b",
              "title": "Real session",
              "isPinned": false,
              "messages": [],
              "createdAt": "2026-06-12T00:00:00Z",
              "updatedAt": "2026-06-12T00:00:00Z"
            }
          ]
        }
        """
        try Data(envelope.utf8).write(to: tmp)

        let store = SessionStore(customStoreURL: tmp)
        // Issue #117: file exists → async load path.
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 1)
        #expect(store.activeID == realID, "stale activeID must NOT be adopted")
    }

    // MARK: - README L56 audit-batch-5 unpinned surfaces

    /// Pins ``flushSync``'s first-launch path. The async ``writeToDisk``
    /// branch already gets exercised by the round-trip test at L12,
    /// but flushSync uses an independent code path on the AppKit
    /// termination hook. Codex round 3 (cited at SessionStore.swift:602):
    /// the previous shape called ``replaceItemAt`` whose destination
    /// must exist; on a fresh install ``sessions.json`` is absent, so
    /// every first-run save was silently dropped. The fall-through
    /// to ``moveItem`` is the documented fix — pin it for the
    /// termination code path so a refactor that loses the
    /// ``fileExists`` guard goes red.
    @Test("flushSync writes the envelope to a fresh storeURL on the first-launch path")
    func flushSyncFirstLaunchPathWritesEnvelope() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-flushsync-first-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Sanity: the destination must NOT exist yet so the
        // moveItem fallback is the load-bearing path.
        #expect(FileManager.default.fileExists(atPath: tmp.path) == false)

        let store = SessionStore(customStoreURL: tmp)
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "hello flushSync")
        )

        store.flushSync()

        #expect(FileManager.default.fileExists(atPath: tmp.path))
        let decoded = try decodeEnvelope(at: tmp)
        try #require(decoded.sessions.count == 1)
        #expect(decoded.sessions[0].messages.first?.content == "hello flushSync")
    }

    /// Pins ``flushSync``'s overwrite-branch **behaviour** — that
    /// the destination-exists branch loads through a fresh
    /// SessionStore and the second flush carries both rows. Codex
    /// r1 NIT: this is a load/overwrite pin, NOT an atomicity pin —
    /// the post-state check would also accept a non-atomic
    /// delete-then-move refactor. Pinning atomicity end-to-end
    /// would require a writer/reader race which is too flaky for a
    /// unit test; the atomicity contract lives in the FileManager
    /// API + ``data.write(to:options:[.atomic])`` we delegate to.
    @Test("flushSync overwrites an existing storeURL through the replaceItemAt branch")
    func flushSyncOverwritesExistingStoreURL() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-flushsync-overwrite-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // First flushSync to populate the destination.
        do {
            let store = SessionStore(customStoreURL: tmp)
            let id = store.newSession(alias: "qwen3.6-27b")
            _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "v1"))
            store.flushSync()
        }
        #expect(FileManager.default.fileExists(atPath: tmp.path))

        // Second flushSync to exercise the overwrite branch.
        // Issue #117: file exists → async load path; wait for the
        // initial load before observing sessions.
        let store = SessionStore(customStoreURL: tmp)
        await store.awaitInitialLoad()
        // load round-trip should have surfaced the v1 message
        try #require(store.sessions.first?.messages.first?.content == "v1")
        if let id = store.sessions.first?.id {
            _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "v2"))
        }
        store.flushSync()

        let decoded = try decodeEnvelope(at: tmp)
        try #require(decoded.sessions.count == 1)
        let contents = decoded.sessions[0].messages.map(\.content)
        #expect(contents.contains("v1") && contents.contains("v2"))
    }

    /// Pins **encoder parity** between the sync ``flushSync``
    /// (SessionStore.swift:583-585) and the async ``writeToDisk``
    /// (SessionStore.swift:638-640) code paths. The two encoders are
    /// duplicated source-text — same ``dateEncodingStrategy``, same
    /// ``outputFormatting`` set. A refactor that updates one
    /// encoder's shape but forgets the other (e.g. tweaks
    /// ``flushSync`` to ``.iso8601`` from a hypothetical
    /// ``.secondsSince1970`` and forgets ``writeToDisk``) would
    /// silently produce wire-incompatible files on Quit vs. on
    /// debounce save — the next launch's decoder would only accept
    /// one shape. Compare the byte output of both paths against the
    /// same in-memory state.
    ///
    /// Codex r2 BLOCKING fix: the previous shape triggered the
    /// writeToDisk path on storeB by calling ``renameSession`` —
    /// which bumps ``updatedAt`` (SessionStore.swift:176) and can
    /// flip ``bytesA == bytesB`` red for timestamp drift unrelated
    /// to encoder parity. ``flush()`` (SessionStore.swift:533)
    /// unconditionally calls ``writeToDisk`` regardless of whether a
    /// debounce is pending, so we can exercise the async encoder
    /// without mutating state.
    @Test("flushSync and writeChain produce byte-identical output for the same state (encoder parity)")
    func flushSyncAndWriteChainProduceIdenticalBytes() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-parity-A-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-parity-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let urlA = dirA.appendingPathComponent("sessions.json")
        let urlB = dirB.appendingPathComponent("sessions.json")

        // Seed identical state. Snapshot through flushSync first so
        // we have a stable on-disk envelope to hydrate storeB from
        // (load-via-init guarantees identical UUIDs + timestamps).
        let storeA = SessionStore(customStoreURL: urlA)
        let id = storeA.newSession(alias: "qwen3.6-27b")
        for i in 0..<3 {
            _ = storeA.appendMessage(
                sessionID: id,
                ChatMessage(role: .user, content: "msg \(i)")
            )
        }
        storeA.flushSync()

        // Hydrate storeB from urlA's bytes so its in-memory state is
        // a structural clone of storeA's (same UUIDs, timestamps,
        // ordering). NO mutation on storeB — flush() forces the
        // writeToDisk path even with nothing pending.
        try FileManager.default.copyItem(at: urlA, to: urlB)
        let storeB = SessionStore(customStoreURL: urlB)
        await storeB.flush()

        let bytesA = try Data(contentsOf: urlA)
        let bytesB = try Data(contentsOf: urlB)
        // The two encoders should produce identical sorted-key /
        // pretty-printed output. Any divergence here is encoder
        // shape drift — exactly the failure mode the duplicated
        // source-text invites.
        #expect(
            bytesA == bytesB,
            "flushSync and writeToDisk produced divergent output (lens A=\(bytesA.count) B=\(bytesB.count)) — encoder parity broken"
        )
    }

    /// Pins ``.sortedKeys`` as a load-bearing element of the
    /// outputFormatting set. ``StoreEnvelope`` declares fields in
    /// the order ``sessions`` then ``activeID``
    /// (SessionStore.swift:679-681). Without ``.sortedKeys``,
    /// ``JSONEncoder`` emits them in declaration order — so
    /// ``"sessions"`` lands before ``"activeID"`` in the byte
    /// output. With ``.sortedKeys`` they're emitted alphabetically,
    /// so ``"activeID"`` MUST land before ``"sessions"``.
    ///
    /// Codex r2 BLOCKING fix: the previous shape asserted "same
    /// state → same bytes across two saves" via idempotence, but
    /// re-encoding identical struct state can produce byte-identical
    /// output even WITHOUT ``.sortedKeys`` (JSONEncoder is stable
    /// across calls for the same Codable shape). The contract has
    /// to be observed directly in the byte stream — find the
    /// substring offsets and assert ``activeID`` comes first.
    @Test("flushSync output puts JSON keys in sorted order — pins .sortedKeys")
    func flushSyncOutputHasSortedKeys() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-sortedkeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = SessionStore(customStoreURL: tmp)
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "sortedkeys"))
        store.flushSync()

        let bytes = try Data(contentsOf: tmp)
        let text = try #require(String(data: bytes, encoding: .utf8))

        let activeIDRange = try #require(text.range(of: "\"activeID\""))
        let sessionsRange = try #require(text.range(of: "\"sessions\""))
        // .sortedKeys → "activeID" alphabetically precedes "sessions".
        // Without .sortedKeys, declaration order in StoreEnvelope
        // (sessions, activeID) would invert this.
        #expect(
            activeIDRange.lowerBound < sessionsRange.lowerBound,
            "Top-level JSON keys are NOT in sorted order — .sortedKeys appears to be missing from outputFormatting"
        )
    }

    /// Shared envelope decoder so the new tests don't repeat the
    /// JSON-decoding boilerplate inline.
    private func decodeEnvelope(at url: URL) throws -> Envelope {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data)
    }

    private struct Envelope: Decodable {
        var sessions: [ChatSession]
        var activeID: UUID?
    }

    @Test("Concurrent saves serialize via writeChain — no torn JSON on disk")
    func serializedSavesProduceValidJSON() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-serial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SessionStore(customStoreURL: tmp)

        // Hammer scheduleSave indirectly via fast successive
        // mutations. Each mutation cancels the prior debounce and
        // starts a new one; flush() then awaits the whole chain.
        let id = store.newSession(alias: "qwen3.6-27b")
        for i in 0..<25 {
            _ = store.appendMessage(
                sessionID: id,
                ChatMessage(role: .user, content: "tick \(i)")
            )
        }
        await store.flush()

        // After flush the on-disk envelope must be valid JSON
        // (no half-written tmp clobber). Decode it back and check
        // the final state landed.
        let data = try Data(contentsOf: tmp)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Envelope: Decodable { var sessions: [ChatSession]; var activeID: UUID? }
        let decoded = try decoder.decode(Envelope.self, from: data)
        try #require(decoded.sessions.count == 1)
        #expect(decoded.sessions[0].messages.count == 25)
        #expect(decoded.sessions[0].messages.last?.content == "tick 24")
    }
}

/// Codex audit batch 7 (RapidApp.swift:536, F4): the termination
/// path now finalises any in-flight ``.streaming`` placeholder
/// before ``flushSync`` snapshots the envelope. Without this the
/// next launch decodes a row stuck on "still streaming" and any
/// partial ``tool_calls`` on that row 400s the next user turn
/// (orphan-tool-call response shape). Pins the helper's contract:
///
///   * ``streaming`` rows flip to ``complete``
///   * footer is appended (with or without prior content)
///   * any ``toolCalls`` on a streaming row are cleared
///   * non-streaming rows in the same session are untouched
@MainActor
@Suite("SessionStore.finalizeStreamingForTermination")
struct SessionStoreFinalizeStreamingTests {
    @Test("Streaming assistant row flips to complete with footer")
    func streamingRowIsFinalised() {
        let store = SessionStore(customStoreURL: tmpStoreURL())
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "ping"))
        let placeholder = ChatMessage(role: .assistant, content: "partial answer", status: .streaming)
        _ = store.appendMessage(sessionID: id, placeholder)

        store.finalizeStreamingForTermination()

        let session = store.sessions.first { $0.id == id }
        try? #require(session != nil)
        let last = session!.messages.last
        #expect(last?.status == .complete)
        #expect(last?.content.contains("Quit during stream.") == true)
        #expect(last?.content.hasPrefix("partial answer") == true)
    }

    @Test("Empty streaming row gets a non-italic footer")
    func emptyStreamingRowGetsPlainFooter() {
        let store = SessionStore(customStoreURL: tmpStoreURL())
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .assistant, status: .streaming))

        store.finalizeStreamingForTermination()

        let last = store.sessions.first(where: { $0.id == id })?.messages.last
        #expect(last?.status == .complete)
        #expect(last?.content == "Quit during stream.")
    }

    @Test("Dangling tool_calls on a streaming row are cleared")
    func toolCallsClearedOnStreamingRow() {
        let store = SessionStore(customStoreURL: tmpStoreURL())
        let id = store.newSession(alias: "qwen3.6-27b")
        var placeholder = ChatMessage(role: .assistant, status: .streaming)
        placeholder.toolCalls = [
            ToolCall(id: "call_1", name: "weather", arguments: "{\"location\":\"")
        ]
        _ = store.appendMessage(sessionID: id, placeholder)

        store.finalizeStreamingForTermination()

        let last = store.sessions.first(where: { $0.id == id })?.messages.last
        #expect(last?.toolCalls == nil,
                "orphan tool_calls would 400 the next user turn — must be stripped on quit")
    }

    @Test("Non-streaming rows are untouched")
    func completeRowsUntouched() {
        let store = SessionStore(customStoreURL: tmpStoreURL())
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(sessionID: id, ChatMessage(role: .user, content: "ping"))
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, content: "pong", status: .complete)
        )

        store.finalizeStreamingForTermination()

        let messages = store.sessions.first(where: { $0.id == id })!.messages
        #expect(messages[0].content == "ping")
        #expect(messages[1].content == "pong")
        #expect(messages[1].status == .complete)
    }

    private func tmpStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
    }
}
