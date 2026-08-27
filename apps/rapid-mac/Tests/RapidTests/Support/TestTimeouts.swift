import Foundation
import Testing

/// Shared time-limit traits for hang-prone Desktop test suites (#2488).
///
/// A suite that spawns a real engine process, or that waits on RAM/clock and
/// could stall the serialised `swift test --no-parallel` pool, should declare
/// it by adding the shared trait constant to its `@Suite` attribute — one line
/// per suite:
///
/// ```swift
/// @Suite("...", .timeLimit(.minutes(2)))
/// ```
/// becomes:
/// ```swift
/// @Suite("...", TestTimeouts.hangProne)
/// ```
///
/// This is deliberately a *suite-level* limit (Swift Testing's `.timeLimit`
/// is recursive over a suite's contained tests), so a single stuck `@Test`
/// trips the whole suite at 2 minutes instead of stalling the serialised run
/// until the CI job timeout. The complementary whole-run backstop lives in
/// `scripts/desktop-test-timeout.sh`.
///
/// Only `.minutes(_:)` (integer) is available on the installed toolchain —
/// `.seconds`/`.milliseconds` are marked unavailable — so 2 minutes is the
/// finest granularity the trait allows.
enum TestTimeouts {
    /// 2-minute time limit applied to hang-prone suites.
    static let hangProne: any SuiteTrait = .timeLimit(.minutes(2))
}
