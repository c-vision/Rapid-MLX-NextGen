import Foundation
import Testing
@testable import Rapid

/// URLProtocol stub that serves a fixed `Data` body and inspects the
/// `Range` header on each request. Static state is shared across
/// instances because URLSession constructs a fresh protocol per
/// request and we need to assert the second-attempt resume sent the
/// correct offset.
final class StubDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = .init()
    nonisolated(unsafe) static var observedRangeHeaders: [String?] = []
    /// When > 0, the first `truncateFirstNRequests` requests serve
    /// only half the available payload (relative to whatever the
    /// Range offset asked for) and end cleanly. Triggers the
    /// receiver's size check, but the bytes that did arrive are
    /// durable on disk — that's exactly the resume guarantee the
    /// test covers. Mid-stream `didFailWithError` was tried first
    /// and proved flaky: URLProtocol → URLSession races the load
    /// callback against the error callback and the data sometimes
    /// vanishes without reaching the delegate.
    nonisolated(unsafe) static var truncateFirstNRequests: Int = 0
    /// When true, server pretends not to honour Range and sends a
    /// full 200 response with the entire body even when Range is set.
    nonisolated(unsafe) static var refuseRange: Bool = false
    /// When > 0, the first N requests synthesise a `didFailWithError`
    /// after delivering `failAfterBytes` bytes — simulates a Wi-Fi
    /// drop mid-stream. The bytes delivered before the failure ARE
    /// durable (the production guarantee the resume contract relies
    /// on), so the next retry can use them as the resume offset.
    nonisolated(unsafe) static var failFirstNRequests: Int = 0
    nonisolated(unsafe) static var failAfterBytes: Int = 0
    /// When non-nil, server returns a 206 but omits Content-Range or
    /// sends a wrong one. Used to verify the downloader rejects the
    /// response instead of writing bytes at the wrong offset.
    nonisolated(unsafe) static var badContentRangeHeader: String? = nil
    nonisolated(unsafe) static var useBadContentRangeOnNextRequest: Bool = false
    /// When > 0, after delivering the first chunk the stub sleeps
    /// for this long before sending more. Lets a cancellation test
    /// observe an in-flight task deterministically.
    nonisolated(unsafe) static var stallSecondsAfterFirstChunk: Double = 0
    /// Flipped by `stopLoading()` so the stall loop can exit early
    /// when URLSession is asked to cancel the data task.
    nonisolated(unsafe) static var stallCancelled: Bool = false

    static func reset(body: Data) {
        Self.body = body
        Self.observedRangeHeaders = []
        Self.truncateFirstNRequests = 0
        Self.refuseRange = false
        Self.failFirstNRequests = 0
        Self.failAfterBytes = 0
        Self.badContentRangeHeader = nil
        Self.useBadContentRangeOnNextRequest = false
        Self.stallSecondsAfterFirstChunk = 0
        Self.stallCancelled = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.observedRangeHeaders.append(range)

        let attemptIndex = Self.observedRangeHeaders.count - 1
        let shouldTruncate = attemptIndex < Self.truncateFirstNRequests
        let shouldFail = attemptIndex < Self.failFirstNRequests

        var offset: Int64 = 0
        if let r = range, !Self.refuseRange,
           let prefix = r.split(separator: "=").last,
           let firstByte = prefix.split(separator: "-").first,
           let parsed = Int64(firstByte) {
            offset = parsed
        }

        let status = (range != nil && !Self.refuseRange) ? 206 : 200
        var headers: [String: String] = [:]
        if status == 206 {
            if Self.useBadContentRangeOnNextRequest, let h = Self.badContentRangeHeader {
                headers["Content-Range"] = h
                Self.useBadContentRangeOnNextRequest = false
            } else {
                let end = max(offset, Int64(Self.body.count) - 1)
                headers["Content-Range"] = "bytes \(offset)-\(end)/\(Self.body.count)"
            }
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if offset < Int64(Self.body.count) {
            let payload = Self.body.subdata(in: Int(offset)..<Self.body.count)
            if Self.stallSecondsAfterFirstChunk > 0 {
                // Deliver a small first chunk, then sleep. Lets the
                // cancellation test fire `task.cancel()` while the
                // load is genuinely in flight.
                let head = payload.prefix(min(payload.count, 4 * 1024))
                client?.urlProtocol(self, didLoad: head)
                // Poll for cancellation up to the stall duration so
                // stopLoading() (which sets stalled-cancel flag) can
                // interrupt cleanly.
                Self.stallCancelled = false
                let deadline = Date().addingTimeInterval(Self.stallSecondsAfterFirstChunk)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                    if Self.stallCancelled { break }
                }
                let err = NSError(domain: NSURLErrorDomain,
                                  code: NSURLErrorCancelled,
                                  userInfo: nil)
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            if shouldFail {
                // Deliver `failAfterBytes` then synthesise a
                // network failure. Mirrors a Wi-Fi disconnect after
                // a partial chunk has hit disk. The small sleep
                // between didLoad + didFailWithError gives the
                // URLSession delegate queue time to actually invoke
                // `urlSession(_:dataTask:didReceive:)` before the
                // error tears the load down — without it URLSession
                // may drop the buffered data, exactly the failure
                // mode the production code is designed to survive
                // but the stub would mask.
                let cutoff = min(payload.count, max(1, Self.failAfterBytes))
                if cutoff > 0 {
                    client?.urlProtocol(self, didLoad: payload.prefix(cutoff))
                }
                Thread.sleep(forTimeInterval: 0.05)
                let err = NSError(domain: NSURLErrorDomain,
                                  code: NSURLErrorNetworkConnectionLost,
                                  userInfo: nil)
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            if shouldTruncate {
                // Server delivers half its remaining bytes, then
                // closes cleanly. Receiver sees fewer bytes than
                // `expectedBytes` → SizeMismatch error. The bytes
                // that DID arrive are durable, so the retry can
                // resume from `offset + cutoff`.
                let cutoff = max(1, payload.count / 2)
                client?.urlProtocol(self, didLoad: payload.prefix(cutoff))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.stallCancelled = true
    }
}

/// Tests share `StubDownloadProtocol`'s static state (URLSession
/// constructs a fresh protocol per request, so the counter has to be
/// type-level). `.serialized` keeps the 5 cases from racing on it.
@Suite("ResumableDownloader", .serialized)
struct ResumableDownloaderTests {
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubDownloadProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static func makeBody(byteCount: Int) -> Data {
        var d = Data(capacity: byteCount)
        for i in 0..<byteCount { d.append(UInt8(i % 256)) }
        return d
    }

    @Test("happy path — single request, atomic rename, partial cleaned")
    func happyPath() async throws {
        let body = Self.makeBody(byteCount: 200 * 1024)  // 200 KB → multiple buffer flushes
        StubDownloadProtocol.reset(body: body)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-happy-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let result = try await downloader.download(
            from: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            to: tmp,
            expectedBytes: UInt64(body.count)
        )

        #expect(result == tmp)
        let written = try Data(contentsOf: tmp)
        #expect(written == body, "atomic rename should produce byte-identical file")
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathExtension("partial").path),
                "the .partial file should be gone after the rename")
        #expect(StubDownloadProtocol.observedRangeHeaders == [nil],
                "first attempt with no prior .partial must not send a Range header")
    }

    @Test("retry after truncated transfer resumes from byte offset")
    func resumeAfterFailure() async throws {
        let body = Self.makeBody(byteCount: 200 * 1024)
        StubDownloadProtocol.reset(body: body)
        StubDownloadProtocol.truncateFirstNRequests = 1

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-resume-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        let partialURL = tmp.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let url = URL(string: "https://example.invalid/sidecar.tar.gz")!

        // First attempt fails mid-stream — partial should be on disk.
        await #expect(throws: (any Error).self) {
            _ = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }
        let partialSize = (try? FileManager.default
            .attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(partialSize > 0, "first attempt must leave bytes on disk so the retry can resume")
        #expect(partialSize < Int64(body.count), "first attempt closed mid-stream, not at EOF")

        // Second attempt resumes from the partial.
        let result = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        #expect(result == tmp)
        let written = try Data(contentsOf: tmp)
        #expect(written == body, "resumed bytes + new bytes should reconstruct the full body")

        let secondRange = StubDownloadProtocol.observedRangeHeaders[1]
        #expect(secondRange?.hasPrefix("bytes=") == true,
                "retry must send Range header with the partial-file byte offset")
    }

    @Test("server refusing Range (200 to Range request) restarts from zero")
    func serverRefusesRangeRestarts() async throws {
        let body = Self.makeBody(byteCount: 200 * 1024)
        StubDownloadProtocol.reset(body: body)
        StubDownloadProtocol.truncateFirstNRequests = 1

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-refuse-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        let partialURL = tmp.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let url = URL(string: "https://example.invalid/sidecar.tar.gz")!
        await #expect(throws: (any Error).self) {
            _ = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }

        // Flip the server: it now ignores Range and sends a full 200.
        // The downloader must discard the partial and end up with
        // exactly `body` bytes (not body.size + partialSize).
        StubDownloadProtocol.refuseRange = true
        let result = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        let written = try Data(contentsOf: result)
        #expect(written.count == body.count,
                "Range-refusing server must not concatenate fresh body onto a stale partial")
        #expect(written == body)
    }

    @Test("size mismatch surfaces as SizeMismatch error")
    func sizeMismatch() async throws {
        let body = Self.makeBody(byteCount: 100 * 1024)
        StubDownloadProtocol.reset(body: body)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-mismatch-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        await #expect(throws: ResumableDownloader.DownloadError.self) {
            _ = try await downloader.download(
                from: URL(string: "https://example.invalid/sidecar.tar.gz")!,
                to: tmp,
                expectedBytes: UInt64(body.count + 1)  // wrong on purpose
            )
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.path),
                "the destination must not exist when the size check fails")
    }

    @Test("invalid expectedBytes rejected before any network call")
    func invalidExpectedBytes() async throws {
        let downloader = ResumableDownloader(session: Self.makeSession())
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-invalid-\(UUID().uuidString)")
        await #expect(throws: ResumableDownloader.DownloadError.invalidExpectedBytes) {
            _ = try await downloader.download(
                from: URL(string: "https://example.invalid/sidecar.tar.gz")!,
                to: tmp,
                expectedBytes: 0
            )
        }
    }

    /// The production resume contract — Wi-Fi drop after some bytes
    /// hit disk, then a clean retry with the right Range header.
    /// This is the path the truncate-only tests CAN'T cover, because
    /// truncate finishes the load cleanly and surfaces SizeMismatch
    /// instead of the URLSession failure path the bootstrapper hits
    /// in the wild.
    @Test("network failure mid-stream leaves resumable partial on disk")
    func networkFailureResumesCleanly() async throws {
        let body = Self.makeBody(byteCount: 200 * 1024)
        StubDownloadProtocol.reset(body: body)
        StubDownloadProtocol.failFirstNRequests = 1
        StubDownloadProtocol.failAfterBytes = 80 * 1024  // ~40% in

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-netfail-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        let partialURL = tmp.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let url = URL(string: "https://example.invalid/sidecar.tar.gz")!

        // First attempt: real didFailWithError, surfaces as transport.
        await #expect(throws: ResumableDownloader.DownloadError.self) {
            _ = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }
        let partialSize = (try? FileManager.default
            .attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(partialSize >= Int64(80 * 1024 - 1024),
                "bytes delivered before didFailWithError must be durable on disk")
        #expect(partialSize < Int64(body.count))

        // Second attempt resumes; observed Range header reflects the disk state.
        let result = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        let written = try Data(contentsOf: result)
        #expect(written == body, "resumed transfer must reconstruct the body byte-for-byte")
        let secondRange = StubDownloadProtocol.observedRangeHeaders[1]
        #expect(secondRange?.hasPrefix("bytes=") == true)
    }

    /// CDN bug: server returns 206 but ships bytes from offset 0,
    /// claiming a Content-Range that doesn't match what we asked.
    /// The downloader must refuse to write or the .partial gets
    /// silently corrupted with bytes-at-the-wrong-offset.
    @Test("206 with mismatched Content-Range is rejected")
    func mismatchedContentRangeRejected() async throws {
        let body = Self.makeBody(byteCount: 200 * 1024)
        StubDownloadProtocol.reset(body: body)
        StubDownloadProtocol.truncateFirstNRequests = 1

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-badcr-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        let partialURL = tmp.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let url = URL(string: "https://example.invalid/sidecar.tar.gz")!
        // Seed a partial so the retry has to send a Range header.
        await #expect(throws: (any Error).self) {
            _ = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }

        // Stub the next response: claim 206 but advertise start=0.
        StubDownloadProtocol.badContentRangeHeader = "bytes 0-100/\(body.count)"
        StubDownloadProtocol.useBadContentRangeOnNextRequest = true

        await #expect(throws: ResumableDownloader.DownloadError.self) {
            _ = try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }
        // The .partial from the first attempt is still on disk;
        // critical invariant is that we did NOT install a corrupt
        // file at `tmp`.
        #expect(!FileManager.default.fileExists(atPath: tmp.path),
                "destination must remain absent when Content-Range is wrong")
    }

    /// `Task.cancel()` while a download is in flight must surface as
    /// `CancellationError`, not `.transport(...)` — the UI layer
    /// branches on this to distinguish user intent from a real
    /// failure. The .partial stays on disk for the next retry.
    ///
    /// Deterministic: the stub delivers headers + a 4 KB head chunk,
    /// then stalls until `stopLoading()` flips `stallCancelled`. We
    /// cancel after a short wait so the task is guaranteed to be
    /// in-flight when the cancel signal lands, which yields the
    /// production NSURLErrorCancelled path → `CancellationError`.
    @Test("Task.cancel during in-flight download surfaces as CancellationError")
    func cancellationSurfacesAsCancellationError() async throws {
        let body = Self.makeBody(byteCount: 4 * 1024 * 1024)
        StubDownloadProtocol.reset(body: body)
        StubDownloadProtocol.stallSecondsAfterFirstChunk = 5.0

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdl-cancel-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmp)
        let partialURL = tmp.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: partialURL)
        }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let url = URL(string: "https://example.invalid/sidecar.tar.gz")!

        let downloadTask = Task {
            try await downloader.download(from: url, to: tmp, expectedBytes: UInt64(body.count))
        }
        // Let the stub deliver the first chunk and enter its stall
        // loop, then cancel — guarantees the task is genuinely in
        // flight when cancellation lands.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
        downloadTask.cancel()

        do {
            _ = try await downloadTask.value
            Issue.record("cancelled download must throw")
        } catch is CancellationError {
            // expected — production path
        } catch {
            Issue.record("expected CancellationError, got: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.path),
                "cancellation must not leave an installed file")
    }
}
