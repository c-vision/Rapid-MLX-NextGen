import Foundation
import Testing
@testable import RapidDesktopTestWatchdog

/// Unit tests for the hang-watchdog decision logic, driven entirely through
/// injected seams (fake clock, fake process-survival, fake sample capture) so
/// no real `/usr/bin/sample`, process, or wall clock is touched.
@Suite("HangWatchdog — deadline math + seams")
struct WatchdogDecisionTests {

    // MARK: - Deadline math (pure)

    @Test("isExpired is false before the deadline")
    func notExpiredBeforeDeadline() {
        let cfg = WatchdogConfig(deadline: .seconds(120))
        let wd = HangWatchdog(config: cfg, seams: .fake(now: { Date(timeIntervalSince1970: 100) }))
        let start = Date(timeIntervalSince1970: 0)
        // 60s elapsed < 120s deadline.
        #expect(wd.isExpired(startedAt: start, now: Date(timeIntervalSince1970: 60)) == false)
    }

    @Test("isExpired is true at and past the deadline")
    func expiredAtAndPastDeadline() {
        let cfg = WatchdogConfig(deadline: .seconds(120))
        let wd = HangWatchdog(config: cfg, seams: .fake(now: { Date() }))
        let start = Date(timeIntervalSince1970: 0)
        #expect(wd.isExpired(startedAt: start, now: Date(timeIntervalSince1970: 120)) == true)
        #expect(wd.isExpired(startedAt: start, now: Date(timeIntervalSince1970: 300)) == true)
    }

    // MARK: - Artifact path (pure)

    @Test("artifact URL embeds pid, name prefix, timestamp and .txt suffix")
    func artifactPathShape() {
        let cfg = WatchdogConfig(
            artifactDir: URL(fileURLWithPath: "/tmp/hang", isDirectory: true),
            artifactName: "desktop-hang"
        )
        let wd = HangWatchdog(config: cfg, seams: .fake(now: { Date(timeIntervalSince1970: 12345) }))
        let url = wd.artifactURL(pid: 4242, at: Date(timeIntervalSince1970: 12345))
        #expect(url.path == "/tmp/hang/desktop-hang-4242-12345.txt")
    }

    // MARK: - run() outcomes via fake seams

    @Test("run returns completed when the wrapped process exits before deadline")
    func completesWhenProcessExitsFirst() {
        let cfg = WatchdogConfig(deadline: .seconds(60))
        let wd = HangWatchdog(
            config: cfg,
            seams: .fake(
                now: { Date() },
                wrappedAlive: { false },   // already gone
                capture: { pid, url in
                    Issue.record("capture must not run when the process is already gone")
                }
            )
        )
        #expect(wd.run(watchedPID: 100) == .completed)
    }

    @Test("run returns hung + writes artifact when the process outlives the deadline")
    func hangsAndCapturesOnDeadline() {
        let cfg = WatchdogConfig(deadline: .seconds(2), artifactDir: URL(fileURLWithPath: "/tmp/x"))
        let captured = Locked<(pid: pid_t, url: URL)?>(nil)
        let calls = Locked(0)
        let wd = HangWatchdog(
            config: cfg,
            seams: WatchdogSeams(
                now: {
                    let n = calls.withLock { c -> Int in
                        c += 1
                        return c
                    }
                    // First call is the start instant (t=0); every later poll
                    // is t=60s, already past the 2s deadline, while the process
                    // stays alive — so the watchdog must expire and capture.
                    return Date(timeIntervalSince1970: n == 1 ? 0 : 60)
                },
                wrappedProcessIsAlive: { true },
                capture: { pid, url in captured.withLock { $0 = (pid, url) } }
            )
        )
        let result = wd.run(watchedPID: 77)
        guard case .hung(let url, let reason) = result else {
            Issue.record("expected .hung, got \(result)")
            return
        }
        let got = captured.value
        #expect(got?.pid == 77)
        #expect(url == got?.url)
        #expect(url.path == "/tmp/x/desktop-hang-77-60.txt")
        #expect(reason.contains("deadline"))
    }
}

extension WatchdogSeams {
    /// Convenience fake-seams constructor for tests.
    static func fake(
        now: @escaping @Sendable () -> Date = { Date() },
        wrappedAlive: @escaping @Sendable () -> Bool = { true },
        capture: @escaping @Sendable (pid_t, URL) throws -> Void = { _, _ in }
    ) -> WatchdogSeams {
        WatchdogSeams(now: now, wrappedProcessIsAlive: wrappedAlive, capture: capture)
    }
}
