import Foundation

/// Test-only fixture writer that retries a few times on the transient
/// ``EBADF`` ("Bad file descriptor") that the heavy blob-writing
/// suites hit when they run concurrently with the full ~2800-test
/// parallel pool (issue #530).
///
/// It is *contention*, not a hard FD ceiling — ``ulimit -n`` is
/// 1048576, yet a multi-MB fixture create/write transiently returns
/// EBADF while hundreds of sibling tests churn file descriptors. A
/// short backoff clears it. Product code never uses this; it exists
/// only so multi-MB test fixtures write reliably under load.
enum FixtureIO {
    /// Write ``data`` to ``url``, retrying on a transient EBADF.
    ///
    /// The failure surfaces as either a bare ``NSPOSIXErrorDomain``
    /// code 9 or an ``NSCocoaErrorDomain`` 512 (``fileWriteUnknown``)
    /// wrapping an underlying POSIX 9 — we retry on both shapes and
    /// re-throw anything else immediately (a real ENOSPC / EACCES
    /// must still fail the test).
    static func write(_ data: Data, to url: URL, attempts: Int = 4) throws {
        precondition(attempts >= 1, "attempts must be >= 1")
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try data.write(to: url)
                return
            } catch let error where isTransientEBADF(error) {
                lastError = error
                if attempt < attempts - 1 {
                    // 10 / 20 / 30 ms — the contention window is
                    // short-lived FD churn from sibling suites.
                    Thread.sleep(forTimeInterval: 0.01 * Double(attempt + 1))
                }
            }
        }
        // Exhausted retries on a genuinely persistent EBADF — surface
        // it so the failure is visible rather than silently swallowed.
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// True iff ``error`` is the transient EBADF this helper retries.
    private static func isTransientEBADF(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EBADF) {
            return true
        }
        if ns.domain == NSCocoaErrorDomain,
           let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EBADF) {
            return true
        }
        return false
    }
}
