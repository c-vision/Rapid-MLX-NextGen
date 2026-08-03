import Testing
import Foundation
@testable import Rapid

/// Coverage for ``ServerManager.runRuntimeHealthLoop`` — the runtime
/// /healthz monitor that flips state to ``.crashed`` after N
/// consecutive probe failures. Uses the ``probe:`` closure seam +
/// short ``interval:`` so tests pin the contract in milliseconds
/// without spinning up a real HTTP server.
@MainActor
@Suite("RuntimeHealthMonitor")
struct RuntimeHealthMonitorTests {
    /// Tiny mutable counter that the probe closure increments. Lets
    /// each test inspect how many times the loop probed before the
    /// terminal transition.
    final class ProbeCounter: @unchecked Sendable {
        var count = 0
    }

    @Test("3 consecutive failures → state flips to .crashed with the right alias + message")
    func three_consecutive_failures_crashes() async {
        let mgr = ServerManager(testingState: .ready(alias: "qwen3.5-4b"))
        let stub = ProcessGroupChild.testStub()
        mgr._testInstallChild(stub)
        let counter = ProbeCounter()

        await mgr.runRuntimeHealthLoop(
            process: stub,
            alias: "qwen3.5-4b",
            interval: 0.005,
            threshold: 3,
            probe: { counter.count += 1; return false }
        )

        if case .crashed(let a, let msg) = mgr.state {
            #expect(a == "qwen3.5-4b", "alias is preserved on the .crashed transition")
            #expect(msg.lowercased().contains("stopped responding"), "message explains the model went unresponsive, without engine jargon")
        } else {
            Issue.record("expected .crashed, got \(mgr.state)")
        }
        #expect(counter.count == 3, "exactly threshold probes before terminal transition")
    }

    @Test("alternating fail/succeed never reaches the threshold")
    func alternating_pass_fail_never_crashes() async {
        let mgr = ServerManager(testingState: .ready(alias: "x"))
        let stub = ProcessGroupChild.testStub()
        mgr._testInstallChild(stub)
        let counter = ProbeCounter()
        let cancelAt = 8

        // Cancel after a fixed number of probes so the loop exits.
        let task = Task { @MainActor in
            await mgr.runRuntimeHealthLoop(
                process: stub,
                alias: "x",
                interval: 0.005,
                threshold: 3,
                probe: {
                    counter.count += 1
                    if counter.count >= cancelAt {
                        // Cancel via the same path production uses.
                        mgr._testClearChild()  // triggers self.child !== process bail
                    }
                    return counter.count % 2 == 0  // pass on even, fail on odd
                }
            )
        }
        _ = await task.value

        #expect(mgr.state == .ready(alias: "x"), "state never drifted from .ready")
        #expect(counter.count >= cancelAt, "loop probed past the would-be threshold")
    }

    @Test("Task cancellation BEFORE first probe → no state mutation")
    func cancellation_before_probe_no_op() async {
        let mgr = ServerManager(testingState: .ready(alias: "x"))
        let stub = ProcessGroupChild.testStub()
        mgr._testInstallChild(stub)
        let counter = ProbeCounter()

        let task = Task { @MainActor in
            await mgr.runRuntimeHealthLoop(
                process: stub,
                alias: "x",
                interval: 10.0,  // intentionally long; cancel fires first
                threshold: 1,
                probe: { counter.count += 1; return false }
            )
        }
        // Cancel immediately so the sleep at the top of the loop
        // throws CancellationError and the loop bails.
        task.cancel()
        _ = await task.value

        #expect(counter.count == 0, "probe never ran")
        #expect(mgr.state == .ready(alias: "x"), "state stayed .ready")
    }

    @Test("Replace-start mid-loop → original loop bails without state mutation (codex r1 #1)")
    func replace_start_mid_loop_bails() async {
        let mgr = ServerManager(testingState: .ready(alias: "x"))
        let originalStub = ProcessGroupChild.testStub()
        let newStub = ProcessGroupChild.testStub()
        mgr._testInstallChild(originalStub)
        let counter = ProbeCounter()

        // Probe failure on call 2 swaps in a new child — the loop
        // must observe `self.child !== originalStub` and bail
        // without incrementing failures past 1.
        await mgr.runRuntimeHealthLoop(
            process: originalStub,
            alias: "x",
            interval: 0.005,
            threshold: 5,
            probe: {
                counter.count += 1
                if counter.count == 2 {
                    mgr._testInstallChild(newStub)
                }
                return false
            }
        )

        #expect(mgr.state == .ready(alias: "x"), "state preserved — new launch's monitor owns the transition")
        #expect(counter.count == 2, "loop bailed after the post-probe identity check on call 2")
    }

    @Test("State drift away from .ready before probe → loop bails (codex r1 #1)")
    func state_drift_before_probe_bails() async {
        let mgr = ServerManager(testingState: .ready(alias: "x"))
        let stub = ProcessGroupChild.testStub()
        mgr._testInstallChild(stub)
        let counter = ProbeCounter()

        await mgr.runRuntimeHealthLoop(
            process: stub,
            alias: "x",
            interval: 0.005,
            threshold: 5,
            probe: {
                counter.count += 1
                if counter.count == 1 {
                    // Simulate a manual stop landing between probes.
                    mgr._testSetState(.stopped)
                }
                return false
            }
        )

        // Loop must NOT have flipped to .crashed — .stopped wins.
        if case .crashed = mgr.state {
            Issue.record("loop incorrectly flipped to .crashed past .stopped")
        }
        #expect(mgr.state == .stopped, "state stayed .stopped — the manual stop wins")
        #expect(counter.count <= 2, "loop bailed promptly after observing drift")
    }
}
