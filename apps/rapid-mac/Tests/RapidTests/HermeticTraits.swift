import Foundation
import Testing

/// Opt-in gates for tests that can't be hermetic across machines.
///
/// This package has no CI job pinned to a fixed OS/hardware that runs
/// `swift test` (only the `release` workflow builds the app). So two
/// families of tests can't pass deterministically on an arbitrary
/// developer box, and — left enabled by default — they make a plain
/// `swift test` red for reasons unrelated to any code change:
///
///   * **Pixel snapshots.** `assertSnapshot` compares an `NSHostingView`
///     render against a PNG baseline committed under `__Snapshots__/`.
///     SwiftUI/AppKit rendering (font hinting, subpixel, gradients)
///     differs across macOS versions and displays, so a baseline
///     recorded on one host diffs on another.
///   * **Wall-clock perf budgets.** Elapsed-time ceilings are a
///     function of machine speed and, more sharply, of contention in
///     the ~1000-test `@MainActor` parallel pool — a loaded box blows a
///     2 s budget that an idle one clears in ~20 ms.
///
/// Rather than delete the coverage, both are gated behind an explicit
/// env opt-in. A normal `swift test` skips them (green everywhere); the
/// checks remain available on demand and on a machine that owns the
/// baselines.
extension Trait where Self == ConditionTrait {

    /// Pixel-snapshot tests. Baselines are host/OS-specific. Opt in with
    /// `RAPID_UI_SNAPSHOT_TESTS=1`; rebaseline with `SNAPSHOT_RECORD=1`.
    static var uiSnapshot: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["RAPID_UI_SNAPSHOT_TESTS"] == "1",
            "pixel snapshots are host/OS-specific; set RAPID_UI_SNAPSHOT_TESTS=1 to run (SNAPSHOT_RECORD=1 to rebaseline)"
        )
    }

    /// Wall-clock perf-budget tests. Elapsed ceilings are machine- and
    /// load-dependent and flake under the parallel test pool. Opt in with
    /// `RAPID_PERF_TESTS=1`.
    static var perfBudget: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["RAPID_PERF_TESTS"] == "1",
            "wall-clock perf budgets are machine/load-dependent; set RAPID_PERF_TESTS=1 to run"
        )
    }
}
