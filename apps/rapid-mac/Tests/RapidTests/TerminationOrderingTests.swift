import Foundation
import Testing
@testable import Rapid

/// Pins the canonical termination ordering called by
/// ``AppDelegate.applicationWillTerminate``. Audit P1
/// `AppDelegate.swift:651-686` — the in-flight chat stream task
/// must be cancelled BEFORE the session envelope is normalised /
/// flushed and BEFORE the server child is torn down, otherwise:
///
///   * the URLSessionDataTask FIN reaches rapid-mlx after the
///     child has already been SIGTERM'd by `shutdownServer`,
///   * `finalizeStreamingForTermination` races a late-arriving
///     token chunk that could flip a placeholder back to
///     `.streaming` after the normalisation pass.
///
/// Codex r1 NIT on PR #54: the wiring change was three lines and
/// nothing pinned the stop-first invariant against a future
/// reorder. This suite is the pin.
@MainActor
@Suite("AppDelegate termination ordering")
struct TerminationOrderingTests {

    /// The audit P1 invariant in one assertion: stopStream MUST
    /// be the first call, finalizeStreaming MUST run before
    /// flushStore (so the on-disk envelope sees the normalised
    /// placeholders), and the server / downloads teardown comes
    /// last so the SSE FIN propagates while rapid-mlx is still
    /// alive enough to release its decoding slot.
    @Test("runTerminationSequence calls stopStream first, then finalize, flush, server, downloads")
    func sequence_pins_stop_first_then_finalize_flush_teardown() {
        var calls: [String] = []
        AppDelegate.runTerminationSequence(
            stopStream: { calls.append("stop") },
            finalizeStreaming: { calls.append("finalize") },
            flushStore: { calls.append("flush") },
            shutdownServer: { calls.append("server") },
            shutdownDownloads: { calls.append("downloads") }
        )
        #expect(calls == ["stop", "finalize", "flush", "server", "downloads"])
    }

    /// A second, narrower assertion that survives if someone adds
    /// a NEW termination step in the middle — the audit invariant
    /// is "stop first", not "exactly these 5 in this order".
    /// Future-you adds a step → this pin survives; future-you
    /// moves stop after finalize → this pin fires.
    @Test("stopStream is strictly before finalizeStreaming under any future extension")
    func stop_is_strictly_before_finalize() {
        var calls: [String] = []
        AppDelegate.runTerminationSequence(
            stopStream: { calls.append("stop") },
            finalizeStreaming: { calls.append("finalize") },
            flushStore: { _ = calls },
            shutdownServer: { _ = calls },
            shutdownDownloads: { _ = calls }
        )
        let stopIndex = calls.firstIndex(of: "stop")
        let finalizeIndex = calls.firstIndex(of: "finalize")
        #expect(stopIndex != nil)
        #expect(finalizeIndex != nil)
        if let s = stopIndex, let f = finalizeIndex {
            #expect(s < f, "stopStream must run before finalizeStreaming — audit P1 invariant")
        }
    }

    /// Symmetrical pin for the OTHER end of the audit invariant:
    /// stopStream MUST run before shutdownServer so the SSE FIN
    /// reaches rapid-mlx before SIGTERM. Same reasoning as the
    /// finalize pin — if a future refactor moves the server
    /// teardown ahead of the stream cancel, this fires.
    @Test("stopStream is strictly before shutdownServer")
    func stop_is_strictly_before_server_teardown() {
        var calls: [String] = []
        AppDelegate.runTerminationSequence(
            stopStream: { calls.append("stop") },
            finalizeStreaming: { _ = calls },
            flushStore: { _ = calls },
            shutdownServer: { calls.append("server") },
            shutdownDownloads: { _ = calls }
        )
        let stopIndex = calls.firstIndex(of: "stop")
        let serverIndex = calls.firstIndex(of: "server")
        #expect(stopIndex != nil)
        #expect(serverIndex != nil)
        if let s = stopIndex, let v = serverIndex {
            #expect(s < v, "stopStream must run before shutdownServer — audit P1 invariant (FIN before SIGTERM)")
        }
    }

    /// Real-world spot-check: pass live ChatViewModel.stop into the
    /// helper and verify the closure invocation actually delivers
    /// the cancel. If `ChatViewModel.stop()` ever becomes async (or
    /// throws), this test fails to compile / errors at runtime —
    /// the wiring contract on the helper is "synchronous call,
    /// non-throwing".
    @Test("runTerminationSequence accepts a real ChatViewModel.stop without async/throws")
    func sequence_accepts_real_chat_viewmodel_stop() {
        let store = SessionStore(customStoreURL: TerminationOrderingTests.scratchURL())
        let vm = ChatViewModel(store: store)
        var stopFired = false
        AppDelegate.runTerminationSequence(
            stopStream: {
                vm.stop()
                stopFired = true
            },
            finalizeStreaming: {},
            flushStore: {},
            shutdownServer: {},
            shutdownDownloads: {}
        )
        #expect(stopFired,
                "stopStream closure must execute synchronously inside runTerminationSequence")
    }

    private static func scratchURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json", isDirectory: false)
    }
}
