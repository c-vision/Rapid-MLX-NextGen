import Foundation
import Testing
@testable import Rapid

/// Issue #117: pin the async ``loadFromDisk`` contract so a future
/// "let's just inline the decode again" refactor goes red.
///
/// Three invariants:
///   1. The fast path (file absent) lands ``.loaded`` BEFORE init
///      returns — no test churn for the common case.
///   2. The slow path (file present) is ``.loading`` after init,
///      flips to ``.loaded`` once the off-main decode applies.
///   3. ``scheduleSave`` and ``flushSync`` MUST drop their writes
///      during the ``.loading`` window, otherwise an early
///      ``.onAppear`` ``newSession`` would persist an empty
///      envelope on top of a heavy user's real history before the
///      load completes. Tested below by pre-seeding a file, then
///      calling ``flushSync`` BEFORE awaiting the load — the
///      pre-existing on-disk envelope must survive.
@MainActor
@Suite("SessionStore async loadFromDisk (issue #117)")
struct SessionStoreLoadStateTests {

    /// Poll the on-disk store until it holds ``expected`` sessions, then
    /// return the decoded ``sessions`` array (or the last-read array on
    /// timeout, so the caller's assertions still produce a useful diff).
    ///
    /// The post-merge persistence is a DEBOUNCED ``scheduleSave`` — it
    /// commits asynchronously. Sleeping a fixed interval (the old
    /// 600 ms) flakes under the ~1000-test parallel pool: a loaded box
    /// can miss the window and read the file mid-write / pre-write.
    /// Polling converges the moment the save lands and tolerates a
    /// slow box up to the (generous) timeout.
    private func waitForPersistedSessions(
        at url: URL,
        expected: Int,
        timeoutNs: UInt64 = 5_000_000_000
    ) async -> [[String: Any]] {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        var last: [[String: Any]] = []
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let bytes = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: bytes),
               let json = obj as? [String: Any],
               let sessions = json["sessions"] as? [[String: Any]] {
                last = sessions
                if sessions.count == expected { return sessions }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
        }
        return last
    }

    @Test("Fast path: file absent → loadState is .loaded the moment init returns")
    func absentFileIsSynchronouslyLoaded() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-loadstate-fast-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Sanity: file must NOT exist so the fast path fires.
        #expect(FileManager.default.fileExists(atPath: tmp.path) == false)

        let store = SessionStore(customStoreURL: tmp)
        // The .onAppear seed gate in ContentView reads loadState
        // synchronously. The fast path MUST land .loaded by the
        // time init returns — otherwise every fresh install would
        // see a spinner for a single render frame.
        #expect(store.loadState == .loaded)
        #expect(store.sessions.isEmpty)
    }

    @Test("Slow path: file present → loadState .loading at init, .loaded after awaitInitialLoad")
    func presentFileIsAsynchronouslyLoaded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-loadstate-slow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed a real on-disk envelope so the async path fires.
        let realID = UUID()
        let envelope = """
        {
          "activeID": "\(realID.uuidString)",
          "sessions": [
            {
              "id": "\(realID.uuidString)",
              "alias": "qwen3.5-4b",
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
        // Init returns BEFORE the off-main decode applies. The
        // observable state is "loading + empty sessions" so the
        // sidebar renders a spinner instead of "no chats yet".
        #expect(store.loadState == .loading)
        #expect(store.sessions.isEmpty)

        await store.awaitInitialLoad()

        #expect(store.loadState == .loaded)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == realID)
    }

    @Test("During .loading: flushSync drops the write so the on-disk envelope is preserved")
    func flushSyncDuringLoadingDoesNotClobberDisk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-loadstate-flushsync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed two real sessions so we can detect a destructive
        // empty-envelope write — count would drop to 0.
        let id1 = UUID()
        let id2 = UUID()
        let envelope = """
        {
          "activeID": "\(id1.uuidString)",
          "sessions": [
            {
              "id": "\(id1.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "First",
              "isPinned": false,
              "messages": [],
              "createdAt": "2026-06-12T00:00:00Z",
              "updatedAt": "2026-06-12T00:00:00Z"
            },
            {
              "id": "\(id2.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "Second",
              "isPinned": false,
              "messages": [],
              "createdAt": "2026-06-12T00:00:00Z",
              "updatedAt": "2026-06-12T00:00:00Z"
            }
          ]
        }
        """
        try Data(envelope.utf8).write(to: tmp)
        let bytesBefore = try Data(contentsOf: tmp)

        let store = SessionStore(customStoreURL: tmp)
        // Critical: we're calling flushSync BEFORE awaitInitialLoad.
        // The load-state guard MUST drop the write, otherwise we'd
        // snapshot an empty `sessions` array on top of the user's
        // real envelope and irrecoverably destroy two sessions.
        #expect(store.loadState == .loading)
        store.flushSync()
        let bytesAfter = try Data(contentsOf: tmp)
        #expect(bytesAfter == bytesBefore,
                "flushSync during .loading must NOT rewrite the on-disk envelope")

        // After awaiting, the load completes and both sessions are present.
        await store.awaitInitialLoad()
        #expect(store.sessions.count == 2)
    }

    @Test("Codex r1 P2 + r2 BLOCKING: in-memory mutations + their MESSAGES survive the merge AND get persisted")
    func mutationsDuringLoadingSurviveTheLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-loadstate-merge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed two real sessions so the load applies non-trivial state.
        let diskID1 = UUID()
        let diskID2 = UUID()
        let envelope = """
        {
          "activeID": "\(diskID1.uuidString)",
          "sessions": [
            {
              "id": "\(diskID1.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "On-disk first",
              "isPinned": false,
              "messages": [],
              "createdAt": "2026-06-12T00:00:00Z",
              "updatedAt": "2026-06-12T00:00:00Z"
            },
            {
              "id": "\(diskID2.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "On-disk second",
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
        // Simulate Cmd+N AND a send happening during the loading
        // window — same shape as ContentView's pre-fix ``.onAppear``
        // followed by the compose bar's first send. Codex r2 P3
        // NIT: pinning the message survival, not just the row, so
        // a future refactor that resets ``messages`` on merge fails
        // here.
        #expect(store.loadState == .loading)
        let userPicked = store.newSession(alias: "qwen3.5-4b")
        let userMsg = ChatMessage(
            role: .user,
            content: "Pre-load message that must survive the merge",
            status: .complete
        )
        let appendIdx = store.appendMessage(sessionID: userPicked, userMsg)
        #expect(appendIdx == 0, "append happens in memory even during .loading")
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].messages.count == 1)
        #expect(store.activeID == userPicked, "newSession picks the new chat as active")

        await store.awaitInitialLoad()

        // Row survival: user's session prepended, on-disk both
        // present, count = 3.
        #expect(store.sessions.count == 3,
                "merge must preserve the user's New chat (1) + on-disk (2)")
        #expect(store.sessions[0].id == userPicked)
        #expect(store.sessions.contains(where: { $0.id == diskID1 }))
        #expect(store.sessions.contains(where: { $0.id == diskID2 }))

        // Message survival: the pre-load chat's content is still
        // there. Pre-r2 the merge MIGHT have kept the row ID but
        // reset messages; this assertion would catch that.
        #expect(store.sessions[0].messages.count == 1,
                "the user's pre-load message must survive the merge")
        #expect(store.sessions[0].messages.first?.content
                == "Pre-load message that must survive the merge")

        // Active ID precedence: user-picked beats envelope's value.
        #expect(store.activeID == userPicked,
                "user-picked activeID must NOT be overwritten by the loaded envelope's value")

        // Codex r2 BLOCKING: the merge made the row visible — but
        // every scheduleSave during the loading window was dropped
        // by the load-state guard, so without an explicit save
        // call after the merge the row + message would live only
        // in memory until the next mutation. A force-quit between
        // the merge and the next mutation would lose them. The fix
        // is an explicit ``scheduleSave()`` at the end of the
        // slow-path apply when ``hadInMemoryMutations`` was true.
        // Wait past the debounce window so the save commits, then
        // verify the merged state is on disk.
        // StoreEnvelope is private to SessionStore — peek at the raw
        // JSON to count sessions and pull the user's row by ID. Poll
        // for the debounced post-merge save rather than sleeping a
        // fixed interval (see ``waitForPersistedSessions``).
        let savedSessions = await waitForPersistedSessions(at: tmp, expected: 3)
        #expect(savedSessions.count == 3,
                "merged state MUST hit disk — codex r2 BLOCKING data-loss window")
        let savedUserRow = savedSessions.first(where: {
            ($0["id"] as? String) == userPicked.uuidString
        })
        try #require(savedUserRow != nil,
                     "the user's pre-load row must be persisted")
        let savedMessages = savedUserRow?["messages"] as? [[String: Any]] ?? []
        #expect(savedMessages.first?["content"] as? String
                == "Pre-load message that must survive the merge",
                "the user's pre-load message must be persisted (not just visible)")
    }

    @Test("During .loading: scheduleSave (via newSession) is gated; the destructive replace can't happen")
    func newSessionDuringLoadingDoesNotClobberDiskBeforeMerge() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-loadstate-newsession-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed a real session so we can detect a destructive write
        // that would have replaced it with the in-memory empty array.
        let realID = UUID()
        let envelope = """
        {
          "activeID": "\(realID.uuidString)",
          "sessions": [
            {
              "id": "\(realID.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "Real",
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
        #expect(store.loadState == .loading)
        let newID = store.newSession(alias: "qwen3.5-4b")
        #expect(store.sessions.count == 1, "mutation lands in memory")

        // After awaiting the load, the merge prepends the new row
        // and the codex r2 BLOCKING fix schedules a save. The save
        // hits disk on the standard debounce. Verify the persisted
        // state has BOTH rows (not the pre-fix empty replace).
        await store.awaitInitialLoad()
        // Poll for the debounced post-merge save rather than sleeping a
        // fixed interval (see ``waitForPersistedSessions``).
        let savedSessions = await waitForPersistedSessions(at: tmp, expected: 2)
        #expect(savedSessions.count == 2,
                "destructive replace would have left 0 or 1 — merge persists BOTH rows")
        let savedIDs = Set(savedSessions.compactMap { $0["id"] as? String })
        #expect(savedIDs.contains(realID.uuidString),
                "the on-disk session must survive (pre-#117 would have lost it)")
        #expect(savedIDs.contains(newID.uuidString),
                "the user's pre-load session must survive (codex r2 BLOCKING)")
    }
}
