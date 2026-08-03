import Foundation
import Testing
@testable import Rapid

/// Pins the audit P1 contract for ``ChatStreamClient.openBytesWithRetry``.
/// A pre-stream URLError from a retryable code class should be
/// invisibly retried once; a non-retryable code or a second
/// failure should propagate to the caller unchanged.
///
/// Why pre-stream only: once the SSE byte loop has started, the
/// assistant placeholder may already hold partial content and the
/// server-side completion is mid-decode. Replaying the POST would
/// double-charge the user (and confuse the model). The retry
/// helper deliberately only wraps the `session.bytes(for:)`
/// dispatch, not the SSE loop downstream.
/// Serialised because the FlakyRetryProtocol shares a static
/// attempt counter across instances. Swift Testing's default
/// parallel execution races on that counter.
@Suite("ChatStreamClient pre-stream transient retry", .serialized)
struct ChatStreamTransientRetryTests {

    /// First call surfaces a retryable URLError, second call
    /// succeeds with 200. The helper MUST return the second
    /// response — the user never sees the blip.
    @Test("Retries once on cannotConnectToHost and returns the second response")
    func retries_on_cannot_connect_then_succeeds() async throws {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 1
        FlakyRetryProtocol.errorCode = .cannotConnectToHost
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        let (_, response) = try await ChatStreamClient.openBytesWithRetry(
            session: session,
            request: req,
            retryDelay: .milliseconds(1) // keep wall-clock tiny
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(FlakyRetryProtocol.attemptCount == 2,
                "Helper must have made exactly 2 attempts (1 fail + 1 retry)")
    }

    /// Same shape but using `.networkConnectionLost` — the
    /// classic WiFi-blip code class — to prove the retry set
    /// covers all three documented codes.
    @Test("Retries on networkConnectionLost")
    func retries_on_network_connection_lost() async throws {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 1
        FlakyRetryProtocol.errorCode = .networkConnectionLost
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        let (_, response) = try await ChatStreamClient.openBytesWithRetry(
            session: session,
            request: req,
            retryDelay: .milliseconds(1)
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(FlakyRetryProtocol.attemptCount == 2)
    }

    @Test("Retries on dnsLookupFailed")
    func retries_on_dns_lookup_failed() async throws {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 1
        FlakyRetryProtocol.errorCode = .dnsLookupFailed
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        let (_, _) = try await ChatStreamClient.openBytesWithRetry(
            session: session,
            request: req,
            retryDelay: .milliseconds(1)
        )
        #expect(FlakyRetryProtocol.attemptCount == 2)
    }

    /// Audit safeguard: bound the retry budget to ONE. A persistent
    /// failure must NOT loop indefinitely; the second URLError
    /// propagates to the caller.
    @Test("Two consecutive retryable failures propagate the second error (bounded retry)")
    func two_failures_propagate() async {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 2 // both attempts fail
        FlakyRetryProtocol.errorCode = .cannotConnectToHost
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        do {
            _ = try await ChatStreamClient.openBytesWithRetry(
                session: session,
                request: req,
                retryDelay: .milliseconds(1)
            )
            Issue.record("Expected the second failure to propagate, got success")
        } catch let e as URLError {
            #expect(e.code == .cannotConnectToHost)
            #expect(FlakyRetryProtocol.attemptCount == 2,
                    "Bounded — helper must give up after 2 total attempts")
        } catch {
            Issue.record("Expected URLError, got \(type(of: error))")
        }
    }

    /// `.timedOut` is explicitly NOT in `retryableURLErrorCodes`
    /// because the 600 s request timeout means a true timeout is
    /// a genuinely hung server, not a blip. Pin that the helper
    /// surfaces this immediately without paying a retry delay.
    @Test("Non-retryable URLError code propagates without retry")
    func timeout_not_retried() async {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 1
        FlakyRetryProtocol.errorCode = .timedOut
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        do {
            _ = try await ChatStreamClient.openBytesWithRetry(
                session: session,
                request: req,
                retryDelay: .seconds(60) // would be obvious if hit
            )
            Issue.record("Expected URLError to propagate without retry")
        } catch let e as URLError {
            #expect(e.code == .timedOut)
            #expect(FlakyRetryProtocol.attemptCount == 1,
                    "Non-retryable code must NOT trigger a retry — got \(FlakyRetryProtocol.attemptCount) attempts")
        } catch {
            Issue.record("Expected URLError, got \(type(of: error))")
        }
    }

    /// `.cancelled` represents a user-initiated Stop. Never retry
    /// — the user clicked Stop on purpose.
    @Test("Cancelled is never retried")
    func cancelled_not_retried() async {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 1
        FlakyRetryProtocol.errorCode = .cancelled
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        do {
            _ = try await ChatStreamClient.openBytesWithRetry(
                session: session,
                request: req,
                retryDelay: .seconds(60)
            )
            Issue.record("Expected cancelled to propagate without retry")
        } catch let e as URLError {
            #expect(e.code == .cancelled)
            #expect(FlakyRetryProtocol.attemptCount == 1)
        } catch {
            Issue.record("Expected URLError, got \(type(of: error))")
        }
    }

    /// First-try-success path — helper must NOT introduce delay
    /// on the happy path. Attempt count is 1, no sleep.
    @Test("First-try success returns immediately with attemptCount == 1")
    func happy_path_no_retry() async throws {
        FlakyRetryProtocol.reset()
        FlakyRetryProtocol.failuresBeforeSuccess = 0
        let session = FlakyRetryProtocol.session()

        let req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!)
        let (_, response) = try await ChatStreamClient.openBytesWithRetry(
            session: session,
            request: req,
            retryDelay: .seconds(60) // would be obvious if hit
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(FlakyRetryProtocol.attemptCount == 1)
    }

    /// Pin the documented retry-code set so a future contributor
    /// who adds `.timedOut` (the audit explicitly rejects this)
    /// has to update both the helper AND this test, surfacing
    /// the policy decision.
    @Test("Retryable code set is the documented three")
    func retryable_codes_pinned() {
        #expect(ChatStreamClient.retryableURLErrorCodes == [
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
        ])
    }
}

/// URLProtocol that fails the first `failuresBeforeSuccess`
/// attempts with a configurable `URLError.Code`, then succeeds
/// with an empty 200 response. Static state shared across
/// instances because URLSession constructs a fresh protocol
/// per request — we need a counter that survives reuse.
final class FlakyRetryProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var attemptCount: Int = 0
    nonisolated(unsafe) static var failuresBeforeSuccess: Int = 0
    nonisolated(unsafe) static var errorCode: URLError.Code = .cannotConnectToHost

    static func reset() {
        attemptCount = 0
        failuresBeforeSuccess = 0
        errorCode = .cannotConnectToHost
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlakyRetryProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attemptCount += 1
        if Self.attemptCount <= Self.failuresBeforeSuccess {
            client?.urlProtocol(self, didFailWithError: URLError(Self.errorCode))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
