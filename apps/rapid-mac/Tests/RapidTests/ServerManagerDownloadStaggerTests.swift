import Foundation
import Testing
@testable import Rapid

/// rapid-desktop issue #253 — the desktop GUI could spawn
/// ``rapid-mlx pull <alias>`` (via ``DownloadManager``) and
/// ``rapid-mlx serve <alias>`` (via ``ServerManager``) concurrently
/// for the same alias. With Rapid-MLX 0.7.27+ both subprocesses run
/// their own mirror code, double-writing the HF cache (snapshot dir +
/// orphan blob) and burning 2× disk + 2× bandwidth + 272 s extra on
/// the cold start the user is waiting on.
///
/// The fix wires ``ServerManager`` to ``DownloadManager`` and gates
/// ``start(alias:)`` on ``awaitDownloadSettlement`` so the serve spawn
/// staggers behind any in-flight background pull for the same alias.
/// These tests pin both halves of that contract.
@MainActor
@Suite("ServerManager — #253 stagger behind in-flight DownloadManager pull")
struct ServerManagerDownloadStaggerTests {
    private let alias = "qwen3.6-27b-4bit"

    private func waitUntil(
        deadline: Date,
        predicate: () -> Bool
    ) async -> Bool {
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return predicate()
    }

    @Test("awaitDownloadSettlement returns immediately when no job exists")
    func settlementNoOpsWithoutJob() async {
        let downloads = DownloadManager()
        let t0 = Date()
        await downloads.awaitDownloadSettlement(alias: alias)
        let elapsed = Date().timeIntervalSince(t0)
        // Must not even hit the 250 ms polling cadence.
        #expect(elapsed < 0.25)
    }

    @Test("awaitDownloadSettlement returns immediately when job already finished")
    func settlementNoOpsAfterTerminalStatus() async {
        let downloads = DownloadManager()
        _ = downloads._testingSeedJob(alias: alias)
        downloads._testingFinish(alias: alias, status: 0, reason: .exit)
        let t0 = Date()
        await downloads.awaitDownloadSettlement(alias: alias)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 0.25)
    }

    @Test("awaitDownloadSettlement suspends while running, returns after .completed")
    func settlementSuspendsWhileRunning() async {
        let downloads = DownloadManager()
        _ = downloads._testingSeedJob(alias: alias)
        #expect(downloads.isDownloading(alias))

        async let waiter: Void = downloads.awaitDownloadSettlement(alias: alias)

        // Give the waiter a couple of polling cycles before settling.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(downloads.isDownloading(alias))

        downloads._testingFinish(alias: alias, status: 0, reason: .exit)
        let settled = await waitUntil(deadline: Date().addingTimeInterval(2)) {
            !downloads.isDownloading(alias)
        }
        #expect(settled)
        await waiter
    }

    @Test("awaitDownloadSettlement also unblocks on .cancelled")
    func settlementUnblocksOnCancel() async {
        let downloads = DownloadManager()
        _ = downloads._testingSeedJob(alias: alias)
        async let waiter: Void = downloads.awaitDownloadSettlement(alias: alias)
        try? await Task.sleep(nanoseconds: 350_000_000)
        downloads._testingFinish(
            alias: alias,
            status: 9,
            reason: .uncaughtSignal,
            wasCancelling: true
        )
        await waiter
        #expect(!downloads.isDownloading(alias))
    }

    @Test("attached DownloadManager is held weakly — release post-attach drops the ref")
    func attachedDownloadsHeldWeakly() {
        let server = ServerManager(
            testingState: .idle,
            binaryPath: URL(fileURLWithPath: "/opt/homebrew/bin/rapid-mlx")
        )
        weak var weakDownloads: DownloadManager?
        do {
            let downloads = DownloadManager()
            weakDownloads = downloads
            server.attachDownloads(downloads)
            #expect(weakDownloads != nil)
        }
        // The DownloadManager's only strong reference went out of
        // scope; ServerManager's weak handle must not pin it alive.
        // Pinning would tie the manager's lifetime to the
        // ServerManager singleton, which outlives any reasonable
        // teardown harness and breaks ARC-based test cleanup.
        #expect(weakDownloads == nil)
    }

    @Test("awaitDownloadSettlement returns promptly on Task cancellation (no busy-loop)")
    func settlementHonorsTaskCancellation() async {
        // codex r1 BLOCKING: the previous shape used
        // ``try? await Task.sleep(...)`` which swallows
        // ``CancellationError`` and re-enters the ``while
        // isDownloading`` check immediately. On cancellation the loop
        // becomes a tight MainActor busy-poll that freezes the UI
        // until the pull settles. The fix returns out of the loop on
        // cancellation so the start ``Task`` can unwind cleanly.
        let downloads = DownloadManager()
        _ = downloads._testingSeedJob(alias: alias)
        #expect(downloads.isDownloading(alias))

        let waiter = Task { @MainActor in
            await downloads.awaitDownloadSettlement(alias: alias)
        }
        // Give the waiter at least one polling cycle before cancelling.
        try? await Task.sleep(nanoseconds: 350_000_000)
        let t0 = Date()
        waiter.cancel()
        await waiter.value
        let elapsed = Date().timeIntervalSince(t0)
        // The real signal is that ``isDownloading`` is STILL true
        // after the wait returns — we exited via cancellation rather
        // than via settlement. ``elapsed`` should be small (~zero)
        // because ``Task.sleep`` throws immediately on cancel.
        #expect(elapsed < 0.5)
        #expect(downloads.isDownloading(alias))
    }
}
