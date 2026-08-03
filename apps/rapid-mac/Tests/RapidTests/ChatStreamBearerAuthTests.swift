import Foundation
import Testing
@testable import Rapid

/// Issue #17 desktop-half: the per-launch bearer secret must reach
/// every chat request as ``Authorization: Bearer <secret>``. Without
/// it, any local process that knows the loopback port could drive
/// inference against our server and consume GPU.
///
/// We intercept the outgoing ``URLRequest`` via a custom
/// ``URLProtocol`` and assert on the header the live ``send()`` shape
/// produces. The streaming body itself is replied with a minimal
/// terminating chunk so the chat client returns cleanly instead of
/// hanging on the 200 response.
/// ``.serialized`` because ``AuthHeaderRecorderProtocol.lastAuthorization``
/// is a process-wide singleton URLProtocol state. Parallel tests
/// would race on writes and see each other's headers in their
/// assertions.
@Suite("ChatStreamClient — bearer auth (issue #17)", .serialized)
struct ChatStreamBearerAuthTests {

    private func makeClient(bearer: String?, recorder: AuthHeaderRecorderProtocol.Type) -> ChatStreamClient {
        recorder.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [recorder] + (cfg.protocolClasses ?? [])
        let session = URLSession(configuration: cfg)
        return ChatStreamClient(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            session: session
        )
    }

    private func sampleRequest() -> ChatStreamClient.Request {
        ChatStreamClient.Request(
            alias: "qwen3.5-4b",
            messages: [ChatMessage(role: .user, content: "hi")]
        )
    }

    @Test("bearer non-nil → Authorization: Bearer <token> on the outgoing request")
    @MainActor
    func bearerSetSendsHeader() async throws {
        let client = makeClient(bearer: "deadbeef", recorder: AuthHeaderRecorderProtocol.self)
        do {
            try await client.send(sampleRequest(), bearerToken: "deadbeef") { _ in }
        } catch {
            // The recorder returns an empty 200 stream which the
            // chat parser may surface as no-content; either way the
            // header has already been captured pre-network.
        }
        let header = AuthHeaderRecorderProtocol.lastAuthorization
        #expect(header == "Bearer deadbeef",
                "expected 'Bearer deadbeef', got \(header ?? "(nil)")")
    }

    @Test("bearer nil → no Authorization header (back-compat with test rigs)")
    @MainActor
    func bearerNilOmitsHeader() async throws {
        let client = makeClient(bearer: nil, recorder: AuthHeaderRecorderProtocol.self)
        do {
            try await client.send(sampleRequest(), bearerToken: nil) { _ in }
        } catch { /* ignore — header capture is pre-network */ }
        #expect(AuthHeaderRecorderProtocol.lastAuthorization == nil,
                "nil bearer must NOT inject a header (got \(AuthHeaderRecorderProtocol.lastAuthorization ?? "nil"))")
    }

    @Test("bearer empty string → no Authorization header (avoids 'Bearer ' bare-prefix on the wire)")
    @MainActor
    func bearerEmptyOmitsHeader() async throws {
        let client = makeClient(bearer: "", recorder: AuthHeaderRecorderProtocol.self)
        do {
            try await client.send(sampleRequest(), bearerToken: "") { _ in }
        } catch { /* ignore */ }
        #expect(AuthHeaderRecorderProtocol.lastAuthorization == nil,
                "empty bearer must NOT inject a header; rapid-mlx treats empty as anonymous and we'd 401 ourselves")
    }
}

/// URLProtocol that captures the outgoing request's Authorization
/// header (for assertion) and replies with an empty 200 stream so
/// the chat client returns instead of hanging.
final class AuthHeaderRecorderProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var lastAuthorization: String?

    static func reset() {
        lastAuthorization = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Send a single SSE [DONE] marker so the bytes(for:) stream
        // completes promptly instead of hanging on the 200 response
        // with no body events.
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
