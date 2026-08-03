import Darwin
import Foundation

// MARK: - Crash-safe FileHandle reads
//
// `FileHandle`'s legacy read APIs — `readDataToEndOfFile()`,
// `availableData`, `readData(ofLength:)` — raise an Objective-C
// `NSFileHandleOperationException` ("Bad file descriptor") when the
// underlying descriptor has gone bad (EBADF). That exception is NOT
// catchable from Swift (`do/catch` and `try?` don't see it), so it
// propagates to `libc++abi` and `SIGABRT`s the entire process.
//
// This bites us specifically on subprocess pipes: when a child (`ps`,
// `lsof`, `codesign`, the rapid-mlx downloader, …) is reaped and its
// pipe descriptor is closed while a readability handler / termination
// handler / background reader is mid-read, the read races the close and
// hits EBADF. Under the parallel test pool this was observed aborting a
// full `swift test` run mid-suite; in production the same race could
// take down the app on a server start / download.
//
// The throwing replacements added in macOS 10.15.4 (`readToEnd()`,
// `read(upToCount:)`) surface the identical failure as a *catchable*
// Swift `Error`. The helpers below wrap them so a bad descriptor
// degrades to empty `Data` — every call site here already treats empty
// as a benign "no more bytes" / "nothing to parse" signal.
extension FileHandle {
    /// Drain to EOF, returning empty `Data` instead of crashing on a bad
    /// descriptor. Crash-safe replacement for `readDataToEndOfFile()`.
    func readToEndSafely() -> Data {
        (try? readToEnd()) ?? Data()
    }

    /// Read up to `count` bytes, returning empty `Data` instead of
    /// crashing on a bad descriptor. Crash-safe replacement for
    /// `readData(ofLength:)`.
    ///
    /// IMPORTANT — blocking, fill-to-count semantics. Foundation
    /// implements `read(upToCount:)` as a fill-to-count read
    /// (`_NSReadFromFileDescriptorWithProgress`): on a *blocking*
    /// descriptor it blocks until `count` bytes have arrived OR the
    /// write end signals EOF. It does NOT return early with whatever is
    /// currently buffered (verified — a `read(upToCount: 64 KiB)` on a
    /// pipe holding 5 bytes with the write end still open blocks
    /// forever). Use this only where EOF is guaranteed to arrive:
    ///  - a regular file (EOF at end-of-file), or
    ///  - a pipe whose only writer is a child that exits (EOF on exit).
    ///
    /// Do NOT use this to drain a still-open pipe incrementally — e.g. a
    /// `readabilityHandler` streaming a long-lived child's stdout/stderr:
    /// it would stall until 64 KiB accumulates instead of delivering
    /// each line, freezing progress/log tails. Use a ``PipeDrainer``
    /// (raw, non-blocking, FD-lifetime-safe) there instead.
    func readSafely(upToCount count: Int) -> Data {
        (try? read(upToCount: count)) ?? Data()
    }
}

/// Chunk size for crash-safe pipe drains — matches the typical macOS
/// pipe buffer, so one drain inside a readability handler consumes what
/// `availableData` would have.
let safePipeChunkBytes = 64 * 1024

/// Outcome of a single ``PipeDrainer/drain(cap:)``: the bytes read plus
/// whether the read end reached genuine EOF (the writer(s) closed). A
/// caller that tears its handler down on drain (e.g. the SidecarExtractor
/// stderr collector) must key that on ``atEOF`` — NOT on empty data — so a
/// transient `EAGAIN`/`EINTR` (nothing buffered right now, but the child is
/// still alive) can't prematurely stop draining.
struct DrainResult: Equatable {
    let data: Data
    let atEOF: Bool
}

/// Non-blocking, crash-safe drainer for a pipe's read end.
///
/// Owns the read ``FileHandle`` STRONGLY. That ownership is load-bearing:
/// a bare captured `Int32` does not keep the descriptor alive, so a
/// readability/termination handler that runs after the pipe is released
/// could `fcntl`/`read` a descriptor number that the OS already recycled
/// to an unrelated file — toggling flags on, or reading bytes from, a
/// stranger. Holding the handle keeps THIS descriptor valid for the
/// drainer's whole lifetime; every handler and the termination tail for a
/// pipe capture the SAME drainer, so the FD can't be reclaimed while any
/// of them might still fire.
///
/// The descriptor is put in `O_NONBLOCK` mode ONCE, at construction, and
/// left there — there is no per-drain flag toggle. That is what makes
/// concurrent drains of the same pipe (the stderr readability handler and
/// the termination tail can overlap on different queues) safe: with no
/// toggle, one drain can't restore blocking mode underneath another and
/// strand it in a blocking `read(2)`. Raw `read(2)` on an `O_NONBLOCK`
/// descriptor returns buffered bytes or `EAGAIN` and never waits — whereas
/// `FileHandle.read(upToCount:)` wrongly returns empty on `O_NONBLOCK`
/// (a Foundation quirk; verified) and `availableData` raises an
/// uncatchable NSException on a bad FD, which is why this uses neither.
///
/// `@unchecked Sendable`: all stored state is immutable after `init`
/// (`let`), `errno` is thread-local, and concurrent `read(2)` on one FD is
/// safe at the syscall layer (each read consumes a disjoint slice), so the
/// closures that capture a drainer across queues need no external lock.
final class PipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let fd: Int32
    private let ready: Bool

    /// Capture a pipe's read handle. Construct this while the handle is
    /// guaranteed live (right after `Pipe()`, before any close) — reading
    /// `fileDescriptor` off an already-closed handle raises the uncatchable
    /// NSException this whole file exists to avoid.
    init(_ handle: FileHandle) {
        self.handle = handle
        let descriptor = handle.fileDescriptor
        self.fd = descriptor
        guard descriptor >= 0 else { self.ready = false; return }
        let flags = fcntl(descriptor, F_GETFL)
        self.ready = flags != -1 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
    }

    /// Drain up to `cap` currently-buffered bytes without blocking.
    ///
    /// `atEOF` is true only when a `read(2)` returned `0` (all writers
    /// closed) or the descriptor is genuinely gone (`EBADF`). `EAGAIN`
    /// (nothing buffered right now) is NOT EOF. `EINTR` is retried.
    func drain(cap: Int = safePipeChunkBytes) -> DrainResult {
        guard ready, cap > 0 else { return DrainResult(data: Data(), atEOF: false) }
        var out = Data()
        var atEOF = false
        let chunk = min(cap, safePipeChunkBytes)
        var buffer = [UInt8](repeating: 0, count: chunk)
        while out.count < cap {
            let want = min(chunk, cap - out.count)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
                continue
            }
            if n == 0 {
                atEOF = true          // all writers closed
                break
            }
            // n == -1 — snapshot errno before anything can clobber it.
            let err = errno
            if err == EINTR { continue }                        // retry
            if err == EAGAIN || err == EWOULDBLOCK { break }     // no data now
            // Only a genuinely gone descriptor (EBADF) is EOF; the caller
            // detaches its handler on `atEOF`. Any other unexpected error
            // (EIO, EINVAL, …) stops this drain WITHOUT signalling EOF, so
            // a transient failure can't prematurely detach a live handler —
            // the next readable event simply re-drains (contract: atEOF is
            // EOF-or-EBADF only).
            if err == EBADF { atEOF = true }
            break
        }
        return DrainResult(data: out, atEOF: atEOF)
    }
}
