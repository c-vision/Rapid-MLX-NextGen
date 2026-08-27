import Foundation

/// Configuration for the Desktop test-suite hang watchdog.
///
/// The whole purpose of this component is to convert a hung `swift test`
/// run — which today can stall a train for the full job timeout (20 minutes,
/// once 45) with no usable diagnostic — into a fast, readable failure with a
/// sampled stack artifact. Two complementary mechanisms exist:
///
///  * Swift Testing's per-suite `.timeLimit(.minutes(2))` trait (added to the
///    specific hang-prone suites, `TestTimeouts.hangProne`) fails the suite
///    quickly and names the suite.
///  * This watchdog is the *whole-run* backstop: it enforces a per-run
///    deadline on the `swift test` process and, on expiry, samples the hung
///    process's stacks so we know WHERE it hung even when no per-suite limit
///    was in place.
public struct WatchdogConfig: Sendable {
    /// Deadline for the wrapped run, measured from when the watchdog starts
    /// watching. This is the whole-run backstop, not the per-suite 2-minute
    /// limit — it must sit above the healthy serialized `swift test` duration
    /// so a healthy run is never expired.
    public var deadline: Duration
    /// Seconds for each `/usr/bin/sample` capture. 1 is plenty to get a stack.
    public var sampleDurationSeconds: Int
    /// Directory the sample + system-state artifact is written into.
    public var artifactDir: URL
    /// Path prefix for the artifact basename.
    public var artifactName: String

    public init(
        deadline: Duration = .seconds(300),
        sampleDurationSeconds: Int = 1,
        artifactDir: URL = URL(fileURLWithPath: "/tmp/desktop-hang-artifacts"),
        artifactName: String = "desktop-hang"
    ) {
        self.deadline = deadline
        self.sampleDurationSeconds = sampleDurationSeconds
        self.artifactDir = artifactDir
        self.artifactName = artifactName
    }
}

/// A process-survival test + the hooks that let a unit test fake the world.
///
/// Everything that touches the real host (wall clock, whether a PID is still
/// alive, launching `/usr/bin/sample` and the system-state probes) is
/// injected here as a closure, so the decision logic in ``HangWatchdog`` is
/// pure and unit-testable without any real process, clock, or sampler.
public struct WatchdogSeams: Sendable {
    /// Returns the current wall-clock instant. Injected clock seam.
    public var now: @Sendable () -> Date
    /// True while the wrapped process is still alive. Injected process seam.
    public var wrappedProcessIsAlive: @Sendable () -> Bool
    /// Perform the stack + system-state capture for the (hung) process and
    /// write it into the artifact at `artifactURL`. Injected sample seam.
    public var capture: @Sendable (pid_t, URL) throws -> Void

    public static let live = WatchdogSeams(
        now: { Date() },
        wrappedProcessIsAlive: { fatalError("live seam used without a PID; use makeLive(pid:)") },
        capture: { pid, url in try SampleInvocation.capture(pid: pid, artifactURL: url) }
    )

    /// Build the live seams pinned to a specific wrapped PID.
    public static func makeLive(pid: pid_t, config: WatchdogConfig) -> WatchdogSeams {
        WatchdogSeams(
            now: { Date() },
            wrappedProcessIsAlive: { ProcessAlive.isAlive(pid: pid) },
            capture: { capturedPID, url in
                try SampleInvocation.capture(
                    pid: capturedPID,
                    config: config,
                    artifactURL: url
                )
            }
        )
    }
}

/// Outcome of a watchdog watch.
public enum WatchdogResult: Equatable, Sendable {
    /// The wrapped process exited before the deadline elapsed.
    case completed
    /// The deadline elapsed while the wrapped process was still running; a
    /// sample artifact was captured and (optionally) the run was killed.
    case hung(artifactURL: URL, reason: String)
}

/// The hang watchdog: pure decision logic over injected seams.
///
/// `run` watches a wrapped process (identified only through the injected
/// `wrappedProcessIsAlive` seam) until either it exits (returns
/// ``WatchdogResult/completed``) or the deadline passes while it is still
/// alive (returns ``WatchdogResult/hung`` after capturing the sample).
///
/// The deadline math and the artifact-path construction are pure and unit
/// tested with a fake clock and fake process; the real capture is delegated
/// to ``SampleInvocation``.
public struct HangWatchdog {
    public let config: WatchdogConfig
    public let seams: WatchdogSeams

    public init(config: WatchdogConfig = WatchdogConfig(), seams: WatchdogSeams) {
        self.config = config
        self.seams = seams
    }

    /// The artifact URL for a given PID and clock instant (pure; testable).
    public func artifactURL(pid: pid_t, at date: Date) -> URL {
        let stamp = String(Int64(date.timeIntervalSince1970))
        let name = "\(config.artifactName)-\(pid)-\(stamp).txt"
        return config.artifactDir.appendingPathComponent(name)
    }

    /// Whether the deadline has elapsed given a start offset and the current
    /// wall clock (pure; testable).
    public func isExpired(startedAt start: Date, now nowDate: Date) -> Bool {
        nowDate.timeIntervalSince(start) >= config.deadline.toSeconds
    }

    /// Watch the wrapped process until it exits or the deadline is exceeded.
    ///
    /// - Parameter pid: the wrapped PID, used for the artifact name + capture.
    /// - Returns: ``WatchdogResult/completed`` if the process exited before
    ///   the deadline, else ``WatchdogResult/hung`` with the captured artifact.
    public func run(watchedPID pid: pid_t) -> WatchdogResult {
        let start = seams.now()
        let pollInterval: TimeInterval = 0.25

        while true {
            if !seams.wrappedProcessIsAlive() {
                return .completed
            }
            if isExpired(startedAt: start, now: seams.now()) {
                let url = artifactURL(pid: pid, at: seams.now())
                do {
                    try seams.capture(pid, url)
                } catch {
                    return .hung(
                        artifactURL: url,
                        reason: "deadline (\(config.deadline.toSeconds)s) exceeded; sample capture failed: \(error)"
                    )
                }
                return .hung(
                    artifactURL: url,
                    reason: "deadline (\(config.deadline.toSeconds)s) exceeded; see sample artifact \(url.path)"
                )
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}

// MARK: - Duration helpers

extension Duration {
    /// Whole seconds represented by this duration (truncated).
    fileprivate var toSeconds: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
