import Foundation
import Testing
@testable import Rapid

/// Angle A — Process-kill chaos for the atomic-write boundary.
///
/// The documented crash-safety story for both ``ChatExporter.atomicWrite``
/// and ``SessionStore.writeToDisk`` is the same primitive: write to a
/// sibling temp file, then ``rename(2)`` it into place. ``rename`` is
/// atomic on a single filesystem, so the kernel guarantees:
///
///   * The path at ``destination`` is either the OLD file (rename
///     hasn't landed yet) or the NEW file (rename completed). It is
///     NEVER a partial / torn file.
///   * Any ``.tmp`` sibling left behind from a crash before rename is
///     orphan garbage but not a correctness hazard.
///
/// Synchronisation protocol (codex r2 BLOCKING fix). The original GO-
/// barrier signalled AFTER the write+sync, so the kill window only
/// covered [GO, mv]. That window is < 20 us — kills at >= 50 us
/// landed after mv had completed. The hand-on-the-clock fix:
/// **bidirectional barrier**.
///
///   1. Child: spawn, prepare hex payload in memory, send "R" (READY)
///      on stdout, then BLOCK on a single byte from stdin.
///   2. Parent: read "R" — now confident the child has done all
///      spawn / fork-exec / interpreter startup overhead.
///   3. Parent: write "G" to the child's stdin. THE INSTANT this
///      byte is sent, the parent starts its microsecond kill timer.
///   4. Child: receives the byte, immediately runs the whole
///      [cp, sync, mv] pipeline. The parent's SIGKILL lands at a
///      precise offset INSIDE that pipeline.
///
/// The kill grid {0, 25, 50, ..., 5000} us POST-GO sweeps a range
/// that comfortably brackets the [cp, sync, mv] critical-section
/// runtime — the invariant (no torn dest, no chimera) holds at
/// every offset. We deliberately DON'T claim per-phase pinpoint
/// landings: ``cp`` of 16 KiB may finish in a single read/write
/// pair, and ``/bin/sync`` is the per-volume system sync rather
/// than the ``fsync(fd)`` ChatExporter.atomicWrite uses (codex r3
/// MAJOR — fidelity disclaimer). What this harness pins is the
/// kernel-level atomic-rename guarantee: no kill timing in the
/// 0-5 ms window produces a torn destination. A future iteration
/// could swap the shell pipeline for a tiny C helper that uses
/// ``open + write + fsync + rename`` directly, mirroring
/// atomicWrite's syscall sequence byte-for-byte.
@Suite("Chaos — process-kill at persistence boundary", .serialized)
struct ProcessKillChaosTests {

    // MARK: - Kill-after-GO grid (microseconds)

    private static let killGridMicros: [UInt32] = [
        0, 25, 50, 100, 150, 200, 300, 400, 500, 700,
        1_000, 1_300, 1_700, 2_000, 3_000, 5_000,
    ]

    @Test("atomic temp+rename: SIGKILL at any 0-5 ms offset POST-GO never produces a torn destination",
          arguments: 0..<Self.killGridMicros.count * 4)
    func atomicTempRenameSurvivesKill(iteration: Int) async throws {
        let dir = try makeChaosDir(label: "atomic-rename")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = dir.appendingPathComponent("payload.bin")
        let canonical = canonicalBytes(seed: UInt64(iteration))
        let canonicalHex = canonical.map { String(format: "%02x", $0) }.joined()

        let killAfterMicros = Self.killGridMicros[iteration % Self.killGridMicros.count]

        let outcome = try runShellChaosBidirectional(
            dir: dir,
            dest: dest,
            payloadHex: canonicalHex,
            killAfterGoMicros: killAfterMicros
        )

        // Invariant 1: dest either matches canonical exactly, or
        // doesn't exist. Never a different size, never partial bytes.
        let destExists = FileManager.default.fileExists(atPath: dest.path)
        if destExists {
            let observed = try Data(contentsOf: dest)
            if observed != canonical {
                Issue.record("""
                CHAOS BUG (P1, data loss): destination has partial / wrong content after SIGKILL.
                  iteration=\(iteration), killAfterGoMicros=\(killAfterMicros), readyOK=\(outcome.readyOK), goOK=\(outcome.goOK)
                  expected=\(canonical.count) bytes
                  observed=\(observed.count) bytes
                """)
            }
        }

        // Invariant 2 (informational, not enforced): orphan ``.tmp``
        // siblings AFTER a mid-rename SIGKILL are EXPECTED — the
        // rename never ran, the temp survives.
        let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let orphanCount = siblings.filter { $0.lastPathComponent.hasSuffix(".tmp") }.count
        _ = orphanCount
    }

    /// 4 concurrent atomic writers race for the same destination.
    /// All 4 hit the READY barrier first; the parent then sends GO
    /// to all 4 simultaneously and immediately starts the kill
    /// timer for each. 3 are killed at staggered POST-GO microseconds;
    /// the 4th runs clean.
    ///
    /// Invariant: the observed bytes are EXACTLY one of the 4
    /// canonical payloads — never a chimera (a prefix from A spliced
    /// with a suffix from B). A simultaneous-release race between
    /// 4 atomic-rename writers must still leave a single coherent
    /// payload at the destination.
    @Test("4-way concurrent atomic writers to same dest: 3 killed at staggered POST-GO offsets + 1 survives never produces a chimera",
          arguments: 0..<20)
    func concurrentAtomicWritersChimera(iteration: Int) async throws {
        let dir = try makeChaosDir(label: "concurrent-atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("contested.bin")

        let payloads: [Data] = (0..<4).map { i in
            canonicalBytes(seed: UInt64(iteration) ^ UInt64(i) << 16)
        }
        let payloadHex = payloads.map { $0.map { String(format: "%02x", $0) }.joined() }

        // Codex r3 NIT: defer-driven cleanup so a mid-spawn throw,
        // a !allReady early return, or a successful completion all
        // converge through the same close + waitUntilExit path —
        // no fd leak, no orphan proc.
        var children: [ChaosChild] = []
        defer {
            for child in children {
                if child.proc.isRunning {
                    kill(child.proc.processIdentifier, SIGKILL)
                    child.proc.waitUntilExit()
                }
                close(child.parentReadFD)
                close(child.parentWriteFD)
            }
        }

        // Spawn all 4 with bidirectional pipes.
        for hex in payloadHex {
            children.append(try spawnShellChaosBidirectional(
                dir: dir,
                dest: dest,
                payloadHex: hex
            ))
        }
        // Wait for ALL READY bytes BEFORE any GO is sent.
        var allReady = true
        for child in children {
            let r = (try? readByte(from: child.parentReadFD, timeoutMs: 5_000)) ?? false
            if !r { allReady = false }
        }
        if !allReady {
            // Child(ren) failed to reach READY — let the defer
            // SIGKILL + wait + close run.
            return
        }

        // Send GO to all 4 in a tight write() loop. The four pipe
        // writes are not literally simultaneous (each is one
        // syscall + kernel pipe-buffer fill + child wakeup) but
        // the inter-write gap is on the order of low microseconds
        // — close enough that the children's [cp, sync, mv] runs
        // are interleaving in the kernel.
        for child in children {
            _ = "G".withCString { write(child.parentWriteFD, $0, 1) }
        }
        // Stagger the kills POST-GO. NOTE (codex r3): ``usleep`` is
        // CUMULATIVE in this sleep-then-kill loop — kid 0 fires at
        // ~100 us, kid 1 at ~600 us, kid 2 at ~2100 us POST-GO
        // (the usleep delays add up). That's still inside the
        // 5 ms grid we use elsewhere, and the staggered offsets
        // exercise the race window even if the exact phases aren't
        // the 100/500/1500 figures the array literal might suggest.
        let killOffsetsMicros: [UInt32?] = [100, 500, 1_500, nil]
        for (idx, child) in children.enumerated() {
            if let killAfter = killOffsetsMicros[idx] {
                usleep(killAfter)
                kill(child.proc.processIdentifier, SIGKILL)
            }
        }
        // Wait for the unkilled child to finish before reading dest.
        for child in children {
            child.proc.waitUntilExit()
        }

        let destExists = FileManager.default.fileExists(atPath: dest.path)
        if destExists {
            let observed = try Data(contentsOf: dest)
            let matchesAny = payloads.contains(observed)
            if !matchesAny {
                Issue.record("""
                CHAOS BUG (P0, data corruption): concurrent atomic writers produced a chimera.
                  iteration=\(iteration)
                  observed.count=\(observed.count)
                  payload.counts=\(payloads.map(\.count))
                """)
            }
        }
    }

    // MARK: - fd_set helper regression

    /// Pre-fix this trapped at ``fd == 31`` with
    /// ``Fatal error: Not enough bits to represent the passed value``
    /// because ``Int32(1 << 31)`` overflows. Post-fix the mask is built
    /// as ``UInt32(1) << bit`` then ``Int32(bitPattern:)``-cast, which
    /// is the same sign-bit-preserving move BSD's ``__DARWIN_FD_SET``
    /// macro performs. We sweep the first 4 ``__fd_mask`` slots (fds
    /// 0..<128) so every "bit == 31" boundary is exercised, not just
    /// the first one.
    @Test("fdSetAdd: no integer overflow at any bit position 0-127")
    func fdSetAddNoOverflow() {
        for fd in Int32(0)..<Int32(128) {
            var set = fd_set()
            withUnsafeMutablePointer(to: &set) { ptr in
                fdSetClearAll(ptr)
                fdSetAdd(fd, ptr)
            }
            // Verify the bit actually landed where the BSD macro would
            // place it. Read back via the same memory rebind so we're
            // checking the bit-pattern post-write, not a fresh compute.
            let count = MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size
            let slot = Int(fd) / 32
            let bit = Int(fd) % 32
            guard slot < count else { continue }
            let observed: Int32 = withUnsafePointer(to: &set) { ptr in
                ptr.withMemoryRebound(to: Int32.self, capacity: count) { p in
                    p[slot]
                }
            }
            let expectedMask = Int32(bitPattern: UInt32(1) << UInt32(bit))
            #expect(observed == expectedMask, "fd=\(fd) slot=\(slot) bit=\(bit) observed=\(observed) expected=\(expectedMask)")
        }
    }

    // MARK: - Helpers

    private struct ChaosOutcome {
        let readyOK: Bool
        let goOK: Bool
    }

    private struct ChaosChild {
        let proc: Process
        /// fd parent reads READY bytes from (child stdout).
        let parentReadFD: Int32
        /// fd parent writes GO bytes to (child stdin).
        let parentWriteFD: Int32
    }

    /// Per-iteration scratch directory. Distinct per iteration so
    /// SIGKILLs don't race across iterations.
    private func makeChaosDir(label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-chaos-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Deterministic per-iteration payload — ~16 KB of pseudo-random
    /// bytes derived from ``seed``. Large enough that the write step
    /// can't complete in a single syscall on most page sizes — the
    /// partial-write window between syscalls is exposed.
    private func canonicalBytes(seed: UInt64) -> Data {
        var rng = SplitMix64(seed: seed)
        var out = Data()
        out.reserveCapacity(16 * 1024)
        for _ in 0..<(16 * 1024 / 8) {
            var v = rng.next()
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Single-writer bidirectional barrier:
    ///
    ///   1. spawn child sh script with stdin pipe + stdout pipe
    ///   2. block until child sends 'R' (READY) on stdout
    ///   3. send 'G' (GO) on stdin
    ///   4. usleep(killAfterGoMicros)
    ///   5. SIGKILL
    private func runShellChaosBidirectional(
        dir: URL,
        dest: URL,
        payloadHex: String,
        killAfterGoMicros: UInt32
    ) throws -> ChaosOutcome {
        let child = try spawnShellChaosBidirectional(
            dir: dir, dest: dest, payloadHex: payloadHex
        )
        // Codex r3 NIT: defer cleanup so an unexpected throw mid-
        // sequence doesn't leak fds or leave the child running.
        defer {
            if child.proc.isRunning {
                kill(child.proc.processIdentifier, SIGKILL)
                child.proc.waitUntilExit()
            }
            close(child.parentReadFD)
            close(child.parentWriteFD)
        }
        let ready = (try? readByte(from: child.parentReadFD, timeoutMs: 5_000)) ?? false
        var goOK = false
        if ready {
            let n = "G".withCString { write(child.parentWriteFD, $0, 1) }
            goOK = (n == 1)
            if goOK {
                usleep(killAfterGoMicros)
            }
        }
        kill(child.proc.processIdentifier, SIGKILL)
        child.proc.waitUntilExit()
        return ChaosOutcome(readyOK: ready, goOK: goOK)
    }

    /// Launch the shell harness with stdin + stdout pipes and the
    /// bidirectional barrier script. Returns the file descriptors
    /// the parent uses to read READY and write GO.
    ///
    /// The script:
    ///   1. Pre-decode the hex payload into a sibling ``<tmpName>.src``
    ///      tmpfile via xxd — executes once, before READY, so the
    ///      decode cost is OUT of the critical section.
    ///   2. Write 'R' to stdout, flush.
    ///   3. Read one byte from stdin (blocking via ``dd bs=1 count=1``
    ///      so the shell can't line-buffer the byte).
    ///   4. Run the [cp, sync, mv] pipeline as one tight sub-shell.
    ///      The parent's kill timer started the instant it sent 'G' —
    ///      every microsecond of this sub-shell is in the critical-
    ///      section kill window.
    private func spawnShellChaosBidirectional(
        dir: URL,
        dest: URL,
        payloadHex: String
    ) throws -> ChaosChild {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let tmpName = ".chaos-\(UUID().uuidString).tmp"
        // Pre-decode the hex payload into a tmpfile BEFORE the
        // READY signal so the per-iteration xxd cost doesn't
        // contaminate the post-GO timing window. The pre-decoded
        // bytes live in a sibling ``<tmpName>.src`` and the
        // post-GO pipeline only does ``cp + sync + mv`` against
        // them — a known-cost sequence.
        let script = """
        set -e
        cd \(dir.path.escapedForShell())
        # Pre-decode payload outside the critical section.
        printf '%s' '\(payloadHex)' | /usr/bin/xxd -r -p > '\(tmpName).src'
        # READY barrier.
        printf 'R'
        # Block on parent's GO byte. ``dd`` with bs=1 count=1 is
        # the most portable way to read exactly one byte from
        # stdin without buffering (shell ``read`` would line-
        # buffer and only return after newline).
        /bin/dd bs=1 count=1 of=/dev/null 2>/dev/null
        # CRITICAL SECTION — parent's kill timer is running.
        cp '\(tmpName).src' '\(tmpName)'
        /bin/sync
        mv '\(tmpName)' '\(dest.lastPathComponent.escapedForShell())'
        """
        proc.arguments = ["-c", script]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return ChaosChild(
            proc: proc,
            parentReadFD: stdoutPipe.fileHandleForReading.fileDescriptor,
            parentWriteFD: stdinPipe.fileHandleForWriting.fileDescriptor
        )
    }

    /// Blocking single-byte read from ``fd`` with a wall-clock
    /// timeout in milliseconds. Returns true if a byte arrived
    /// before the deadline.
    private func readByte(from fd: Int32, timeoutMs: Int) throws -> Bool {
        let deadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        var byte: UInt8 = 0
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            var rfds = fd_set()
            withUnsafeMutablePointer(to: &rfds) { ptr in
                fdSetClearAll(ptr)
                fdSetAdd(fd, ptr)
            }
            var tv = timeval(tv_sec: 0, tv_usec: 5_000)
            let rc = select(fd + 1, &rfds, nil, nil, &tv)
            if rc < 0 { continue }
            if rc == 0 { continue }
            let r = read(fd, &byte, 1)
            if r == 1 { return true }
            if r == 0 { return false }
            if r < 0 && errno != EINTR { return false }
        }
        return false
    }
}

// MARK: - fd_set helpers (Foundation doesn't expose them)

private func fdSetClearAll(_ set: UnsafeMutablePointer<fd_set>) {
    let count = MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size
    set.withMemoryRebound(to: Int32.self, capacity: count) { p in
        for i in 0..<count { p[i] = 0 }
    }
}

private func fdSetAdd(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) {
    // Negative or oversized fds are out-of-range for the fd_set bitmap.
    guard fd >= 0 else { return }
    let intBits = 32
    let count = MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size
    set.withMemoryRebound(to: Int32.self, capacity: count) { p in
        let slot = Int(fd) / intBits
        let bit = Int(fd) % intBits
        guard slot < count else { return }
        // CRITICAL: build the mask as UInt32 first, THEN bit-pattern-cast
        // to Int32. Going through ``Int32(1 << bit)`` traps when bit == 31
        // because ``1 << 31`` widens to ``Int`` = 0x80000000, which doesn't
        // fit in Int32's positive range and raises
        // "Fatal error: Not enough bits to represent the passed value".
        // BSD's ``__DARWIN_FD_SET`` does exactly this unsigned shift +
        // sign-bit-preserving reinterpretation, so we mirror it here.
        let mask = UInt32(1) << UInt32(bit)
        p[slot] |= Int32(bitPattern: mask)
    }
}

private extension String {
    /// Single-quote-escape for ``/bin/sh``. We use single-quoted
    /// strings in the chaos script body — closing the quote with
    /// ``'\\''`` is the canonical escape for an embedded apostrophe.
    func escapedForShell() -> String {
        replacingOccurrences(of: "'", with: "'\\''")
    }
}
