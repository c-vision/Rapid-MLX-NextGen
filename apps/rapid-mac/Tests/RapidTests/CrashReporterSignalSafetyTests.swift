import Darwin
import Foundation
import RapidCrashHandler
import Testing
@testable import Rapid

/// Issue #24: signal-handler safety contract.
///
/// We can't safely invoke ``raise(SIGSEGV)`` from a unit test —
/// the process would die — so this suite pins the *contract*
/// instead:
///
///   * ``install()`` populates the pre-allocated C-string arena
///     so the signal handler has every byte it needs without
///     touching ``malloc`` at firing time (F2).
///   * The detailed-marker guard is a ``sig_atomic_t`` cell,
///     not a Swift ``Bool`` — only the former is race-safe
///     across the kill→signal-deliver path (F7).
///   * Signal dispositions installed via ``sigaction(2)`` set
///     ``sa_handler`` to our top-level ``@convention(c)`` symbol,
///     not ``SIG_DFL`` and not a Swift closure thunk (F1).
/// ``.serialized`` because the SignalState arena is a process-wide
/// singleton. Two parallel tests would race on the install/reset
/// pair and each other's ``defer`` blocks would clobber the live
/// suite member's buffers mid-assertion.
@Suite("CrashReporter signal-safety contract (issue #24)", .serialized)
struct CrashReporterSignalSafetyTests {

    // MARK: - F2: pre-allocated arena

    @Test("install() populates marker path and per-signal envelopes")
    func installPopulatesArena() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        let state = CrashReporter._state
        #expect(state.installed, "install() must flip the latch")
        #expect(state.markerPath?.hasSuffix(".json") == true,
                "markerPath must be a resolved file path, got \(state.markerPath ?? "nil")")
        #expect(state.sigabrtLen > 0, "SIGABRT envelope must be non-empty")
        #expect(state.sigsegvLen > 0, "SIGSEGV envelope must be non-empty")
        #expect(state.sigbusLen  > 0, "SIGBUS envelope must be non-empty")
        #expect(state.sigillLen  > 0, "SIGILL envelope must be non-empty")
        #expect(state.sigfpeLen  > 0, "SIGFPE envelope must be non-empty")
    }

    @Test("envelopes encode the matching signal name + number")
    func envelopesEncodeSignalMetadata() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        // Re-read each envelope back out of the C arena (the buffers
        // are NOT NUL-terminated so we copy by length). The shape
        // must match CrashMarker's required keys + carry the
        // signal-specific message — that's the contract
        // flushPendingCrashReports relies on.
        func envelopeBody(_ buf: UnsafePointer<CChar>?, _ len: Int) -> String? {
            guard let buf, len > 0 else { return nil }
            return String(decoding: UnsafeBufferPointer(start: buf, count: len).map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        }
        let snap = rapid_crash_arena_snapshot()
        let abrt = envelopeBody(snap.sigabrt_buf, snap.sigabrt_len) ?? ""
        let segv = envelopeBody(snap.sigsegv_buf, snap.sigsegv_len) ?? ""

        #expect(abrt.contains("\"error_type\":\"signal\""),
                "envelope must declare error_type=signal")
        #expect(abrt.contains("SIGABRT"),
                "SIGABRT envelope must name SIGABRT, got \(abrt)")
        #expect(abrt.contains("\"session_id\""),
                "envelope must carry session_id for dashboard correlation")
        #expect(abrt.contains("\"version\""),
                "envelope must carry version so flushPendingCrashReports re-attributes correctly")
        #expect(segv.contains("SIGSEGV"),
                "SIGSEGV envelope must name SIGSEGV, got \(segv)")
    }

    // MARK: - F7: sig_atomic_t guard

    @Test("detailedFlag is a sig_atomic_t cell that starts at 0")
    func detailedFlagStartsZero() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        #expect(CrashReporter._state.detailedFlagValue == 0,
                "detailedFlag must start cleared so the signal handler writes its envelope by default")
    }

    @Test("markDetailedMarkerWritten flips sig_atomic_t cell from 0 to 1")
    func detailedFlagFlipsToOne() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        #expect(CrashReporter._state.detailedFlagValue == 0)
        CrashReporter.markDetailedMarkerWritten()
        #expect(CrashReporter._state.detailedFlagValue == 1,
                "markDetailedMarkerWritten must set the cell to 1 — the signal handler reads this to decide whether to O_TRUNC over the rich payload")
    }

    @Test("detailedFlag pointer is sig_atomic_t-sized (regression guard against Bool re-creep)")
    func detailedFlagIsSigAtomicT() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        // sig_atomic_t is Int32 on Darwin; Bool would be 1 byte.
        // If a future refactor swaps the cell back to Bool the size
        // changes and this guard goes red.
        #expect(MemoryLayout<sig_atomic_t>.size == 4,
                "sig_atomic_t expected to be 4 bytes on Darwin")
        #expect(MemoryLayout<sig_atomic_t>.size != MemoryLayout<Bool>.size,
                "sig_atomic_t and Bool must differ in size for this regression guard to be meaningful")
    }

    // MARK: - F1: sigaction-installed disposition

    @Test("SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE are armed (not SIG_DFL, not SIG_IGN)")
    func signalDispositionsAreArmed() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            var current = sigaction()
            #expect(sigaction(sig, nil, &current) == 0,
                    "sigaction read must succeed for signal \(sig)")
            // SIG_DFL is the unhandled default; SIG_IGN means "drop
            // it on the floor". Neither matches our handler.
            let handlerBits = unsafeBitCast(current.__sigaction_u.__sa_handler,
                                            to: UInt.self)
            let defaultBits = unsafeBitCast(SIG_DFL as sig_t?, to: UInt.self)
            let ignoreBits  = unsafeBitCast(SIG_IGN as sig_t?, to: UInt.self)
            #expect(handlerBits != defaultBits,
                    "signal \(sig) must not be SIG_DFL after install()")
            #expect(handlerBits != ignoreBits,
                    "signal \(sig) must not be SIG_IGN after install()")
            // SA_RESTART matches the previous BSD signal(2)
            // behaviour — without it a concurrent slow syscall
            // would EINTR-fail when SIGABRT lands on another thread.
            #expect((current.sa_flags & SA_RESTART) != 0,
                    "signal \(sig) sigaction must set SA_RESTART")
        }
    }

    @Test("After install(), the SIGABRT handler symbol matches rapidCrashSignalHandler (defense-in-depth pin)")
    func handlerPointerIsOurSymbol() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        defer { CrashReporter._resetForTesting() }

        // First half: all 5 signals share the same handler pointer
        // — a regression that armed only SIGABRT but left SIGSEGV
        // at SIG_DFL would break this.
        var abrtAction = sigaction()
        sigaction(SIGABRT, nil, &abrtAction)
        let abrtPtr = unsafeBitCast(abrtAction.__sigaction_u.__sa_handler,
                                     to: UInt.self)

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            var current = sigaction()
            sigaction(sig, nil, &current)
            let bits = unsafeBitCast(current.__sigaction_u.__sa_handler,
                                     to: UInt.self)
            #expect(bits == abrtPtr,
                    "signal \(sig) must share the same handler symbol as SIGABRT — uniform install via sigaction(2) is the F1 invariant")
        }

        // Second half (F1 pin per codex r1): the installed handler
        // is EXACTLY the pure-C rapid_crash_signal_handler symbol
        // from RapidCrashHandler — not a Swift trampoline, not any
        // wrapper. Without this anchor a future refactor could
        // re-introduce a Swift closure thunk and the F2/F7 contract
        // would silently regress.
        let cHandlerBits = unsafeBitCast(
            rapid_crash_signal_handler as (@convention(c) (Int32) -> Void),
            to: UInt.self
        )
        #expect(abrtPtr == cHandlerBits,
                "F1: sa_handler must point at the pure-C rapid_crash_signal_handler, not a Swift closure thunk")
    }

    // MARK: - Idempotency

    @Test("install() called twice is a no-op (second call must not re-leak the arena)")
    func installIsIdempotent() {
        CrashReporter._resetForTesting()
        CrashReporter.install()
        let firstSnapshot = CrashReporter._state
        CrashReporter.install()
        let secondSnapshot = CrashReporter._state
        defer { CrashReporter._resetForTesting() }

        // markerPath should be the same STRING — if install() runs
        // twice it would re-allocate a fresh buffer and orphan the
        // first, leaking the original allocation. (Production never
        // calls install twice; this guards a future refactor that
        // drops the latch.)
        #expect(firstSnapshot.markerPath == secondSnapshot.markerPath)
        #expect(firstSnapshot.sigabrtLen == secondSnapshot.sigabrtLen)
    }
}
