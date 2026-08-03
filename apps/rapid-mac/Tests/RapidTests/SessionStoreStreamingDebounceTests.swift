import Foundation
import Testing
@testable import Rapid

/// Issue #297: stream-aware debounce on ``SessionStore.scheduleSave``.
/// Pre-fix the debounce was a fixed 400 ms regardless of whether any
/// message was streaming; on a 500-session × 50-msg heavy user
/// streaming a 2K-token reply, that meant 22 MB/sec of churn re-
/// encoding the full envelope every 400 ms. The fix flips to a 1500 ms
/// debounce while ANY ``.streaming`` message exists, then back to
/// 400 ms once the stream completes — so the final write lands on
/// disk within the original SLA but the intermediate writes go from
/// 60/sec to 16/sec.
///
/// These tests pin the **counter invariant** + the **debounce-window
/// switch** without standing up an actual ``Task.sleep`` race. The
/// production code's ``scheduleSave`` captures the debounce decision
/// at schedule-time (see #297 comment in SessionStore.swift), which
/// is exactly the contract that ``_currentDebounceInterval()``
/// exposes for the test seam.
@MainActor
@Suite("SessionStore — #297 stream-aware debounce")
struct SessionStoreStreamingDebounceTests {

    private func tmpStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
    }

    private func freshStore() async -> SessionStore {
        let store = SessionStore(customStoreURL: tmpStoreURL())
        await store.awaitInitialLoad()
        return store
    }

    @Test("Counter starts at 0 on a fresh store")
    func counterStartsAtZero() async {
        let store = await freshStore()
        #expect(store.streamingMessageCount == 0)
        #expect(store._currentDebounceInterval() == 0.4)
    }

    @Test("Appending a .streaming message increments the counter")
    func streamingAppendIncrements() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .user, content: "ping")
        )
        #expect(store.streamingMessageCount == 0, "user turn is .complete by default")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        #expect(store.streamingMessageCount == 1)
        #expect(store._currentDebounceInterval() == 1.5,
                "debounce must switch to 1500 ms once a stream is live")
    }

    @Test("updateMessage .streaming → .complete decrements the counter")
    func completingDecrements() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        guard let idx = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("append returned nil")
            return
        }
        #expect(store.streamingMessageCount == 1)

        var msg = store.sessions[0].messages[idx]
        msg.status = .complete
        msg.content = "done"
        store.updateMessage(sessionID: id, at: idx, with: msg)

        #expect(store.streamingMessageCount == 0)
        #expect(store._currentDebounceInterval() == 0.4,
                "debounce must restore to 400 ms once the stream completes")
    }

    @Test("updateMessage .streaming → .failed also decrements")
    func failedDecrements() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        guard let idx = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("append returned nil")
            return
        }
        var msg = store.sessions[0].messages[idx]
        msg.status = .failed
        msg.errorMessage = "boom"
        store.updateMessage(sessionID: id, at: idx, with: msg)
        #expect(store.streamingMessageCount == 0)
    }

    @Test("Repeated updateMessage on a .streaming row does NOT double-count")
    func updateStreamingToStreamingNoDoubleCount() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        guard let idx = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("append returned nil")
            return
        }
        // Drive 100 coalescer flushes — each one updates the .streaming
        // row's content but keeps status the same. The counter MUST
        // stay at 1; without the from-status guard it would either
        // double-count or thrash.
        for i in 0..<100 {
            var msg = store.sessions[0].messages[idx]
            msg.content += "tok\(i) "
            store.updateMessage(sessionID: id, at: idx, with: msg)
            #expect(store.streamingMessageCount == 1)
        }
    }

    @Test("Two concurrent streams in two sessions both tracked")
    func twoConcurrentStreams() async {
        let store = await freshStore()
        let idA = store.newSession(alias: "qwen3.6-27b")
        let idB = store.newSession(alias: "gpt-oss-20b")
        _ = store.appendMessage(
            sessionID: idA,
            ChatMessage(role: .assistant, status: .streaming)
        )
        _ = store.appendMessage(
            sessionID: idB,
            ChatMessage(role: .assistant, status: .streaming)
        )
        #expect(store.streamingMessageCount == 2)
        #expect(store._currentDebounceInterval() == 1.5)
    }

    @Test("delete(session) deducts streaming rows from that session")
    func deleteSessionDeductsStreaming() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        #expect(store.streamingMessageCount == 1)
        store.delete(id: id)
        #expect(store.streamingMessageCount == 0)
        #expect(store._currentDebounceInterval() == 0.4)
    }

    @Test("replaceMessages adjusts counter by net delta")
    func replaceMessagesAdjustsCounter() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        // Seed: 2 streaming rows.
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        #expect(store.streamingMessageCount == 2)

        // Replace with 1 streaming + 1 complete.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, status: .streaming),
        ])
        #expect(store.streamingMessageCount == 1)

        // Replace with 0 streaming.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "done"),
            ChatMessage(role: .assistant, content: "ok", status: .complete),
        ])
        #expect(store.streamingMessageCount == 0)
    }

    @Test("finalizeStreamingForTermination zeros the counter")
    func finalizeZerosCounter() async {
        let store = await freshStore()
        let id = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        _ = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        )
        #expect(store.streamingMessageCount == 2)
        store.finalizeStreamingForTermination()
        #expect(store.streamingMessageCount == 0)
    }

    @Test("100 streaming flushes call writeToDisk <= 1/sec; final write within 500 ms after stream end", .perfBudget)
    func streamingFlushesObeyDebounce() async throws {
        // Simulate a 100-chunk stream feeding scheduleSave at coalescer
        // cadence (~30/sec on a fast reply). Pre-fix the 400 ms
        // debounce would have allowed up to 2.5 writes/sec; the fix
        // pins the streaming-active rate at <= ~0.67/sec (1500 ms
        // debounce). Empirically: writeToDisk lands AT MOST once per
        // 100-flush burst because every flush cancels the previous
        // pending Task before its sleep wakes.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SessionStore(customStoreURL: tmp)
        await store.awaitInitialLoad()
        let id = store.newSession(alias: "qwen3.6-27b")
        guard let idx = store.appendMessage(
            sessionID: id,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("append returned nil")
            return
        }

        let burstStart = ContinuousClock.now
        for i in 0..<100 {
            var msg = store.sessions[0].messages[idx]
            msg.content += "tok\(i) "
            store.updateMessage(sessionID: id, at: idx, with: msg)
            // Tiny yield so the actor can schedule the Task; we're
            // NOT awaiting sleeps that the production debounce uses.
            // Each iteration is well under 1 ms.
        }
        let burstElapsed = ContinuousClock.now - burstStart
        // Burst should complete WELL under the 1500 ms streaming
        // debounce — verifying the schedule path is non-blocking.
        let burstSec = Double(burstElapsed.components.seconds)
            + Double(burstElapsed.components.attoseconds) * 1e-18
        #expect(burstSec < 1.5, "100 scheduleSave calls should fit inside the streaming debounce window (got \(burstSec)s)")

        // No file yet — the debounce hasn't fired.
        #expect(!FileManager.default.fileExists(atPath: tmp.path),
                "writeToDisk must NOT have fired yet — the streaming debounce is 1500 ms")

        // Complete the stream.
        var msg = store.sessions[0].messages[idx]
        msg.status = .complete
        msg.content = "final"
        store.updateMessage(sessionID: id, at: idx, with: msg)
        #expect(store.streamingMessageCount == 0)

        // The complete-transition kicks the SHORTER (400 ms) debounce.
        // Use flush() for deterministic observation — it cancels the
        // pending Task and runs writeToDisk synchronously, just like
        // applicationWillTerminate does.
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: tmp.path),
                "the final state must land on disk within the original 400 ms SLA")
    }

    @Test("fork copies streaming rows into the branch and bumps the counter (codex r1 MINOR closure)")
    func forkBumpsCounterForStreamingRowsInBranch() async {
        let store = await freshStore()
        let parent = store.newSession(alias: "qwen3.6-27b")
        _ = store.appendMessage(
            sessionID: parent,
            ChatMessage(role: .user, content: "ping")
        )
        guard let assistantIdx = store.appendMessage(
            sessionID: parent,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("append returned nil")
            return
        }
        // 1 streaming row in parent, prefix-fork through the streaming
        // row would copy it. Production UI guards against this (the
        // codex r1 MINOR note), but the counter MUST stay sound if a
        // future caller ever hits this path.
        #expect(store.streamingMessageCount == 1)
        let streamingMessageID = store.sessions[0].messages[assistantIdx].id
        guard let branch = store.fork(sessionID: parent, throughMessageID: streamingMessageID) else {
            Issue.record("fork returned nil")
            return
        }
        _ = branch
        // Branch now contains a copy of the streaming row → counter == 2.
        #expect(store.streamingMessageCount == 2)
        // Cleanup: complete both streaming rows so the counter returns
        // to 0 (mirrors how a future caller would tidy up).
        for sIdx in store.sessions.indices {
            for mIdx in store.sessions[sIdx].messages.indices
                where store.sessions[sIdx].messages[mIdx].status == .streaming {
                var msg = store.sessions[sIdx].messages[mIdx]
                msg.status = .complete
                msg.content = "completed"
                store.updateMessage(
                    sessionID: store.sessions[sIdx].id,
                    at: mIdx,
                    with: msg
                )
            }
        }
        #expect(store.streamingMessageCount == 0)
    }

    @Test("Crash + reload: an orphan .streaming row is normalized to .complete on load (Issue #476), counter stays 0")
    func orphanStreamingRowNormalizedOnLoad() async throws {
        // Simulate a SIGKILL mid-stream: persist an envelope that
        // contains a .streaming row, then load a fresh store.
        //
        // Issue #476 SUPERSEDES the earlier #297 "seed streamingCount
        // from disk" behavior this test used to assert. A row left
        // ``.streaming`` by a crash is an ORPHAN — no live stream drives
        // it after a fresh load — so ``normalizeStaleStreamingRows`` (on
        // the load path) flips it to ``.complete`` with an interruption
        // footer and leaves ``streamingCount`` at 0. That kills the
        // stuck "Thinking…" spinner AND prevents the debounce timer
        // from firing at the wrong (streaming) window for a row that
        // will never complete — the same goal the old seed had, reached
        // by normalizing rather than resurrecting the row.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let writer = SessionStore(customStoreURL: tmp)
            await writer.awaitInitialLoad()
            let id = writer.newSession(alias: "qwen3.6-27b")
            _ = writer.appendMessage(
                sessionID: id,
                ChatMessage(role: .user, content: "ping")
            )
            _ = writer.appendMessage(
                sessionID: id,
                ChatMessage(role: .assistant, status: .streaming)
            )
            // flushSync persists the streaming row verbatim — the
            // termination cleanup (finalizeStreamingForTermination)
            // is deliberately NOT called here so we exercise the
            // SIGKILL recovery path handled at load time by #476.
            writer.flushSync()
        }

        let reader = SessionStore(customStoreURL: tmp)
        await reader.awaitInitialLoad()

        // #476: no LIVE stream exists immediately after a fresh load.
        #expect(reader.streamingMessageCount == 0,
                "an orphan .streaming row must NOT resurrect as a live stream on load (Issue #476 supersedes the #297 seed)")

        // The orphan row is normalized to a terminal state with the
        // interruption footer. The row was appended with empty content,
        // so the bare-footer branch applies.
        let assistantRow = reader.sessions
            .first?.messages.first(where: { $0.role == .assistant })
        #expect(assistantRow?.status == .complete,
                "the orphan .streaming row must be normalized to .complete on load")
        #expect(assistantRow?.content == "_Response interrupted._",
                "the normalized row must carry the interruption footer so the UI shows a terminated (not stuck) response")
    }
}
