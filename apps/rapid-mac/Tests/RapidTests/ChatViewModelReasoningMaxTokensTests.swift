import Foundation
import Testing
@testable import Rapid

/// Cycle-3 codex r2 MINOR — pin the integration between
/// ``SamplingConfig.effectiveMaxTokens(toolsEnabled:)`` and the
/// ``ChatStreamClient.Request`` that ``ChatViewModel.send`` ships
/// on the wire. The SamplingConfig-level tests in
/// ``ServerModelProfileTests`` pin the function's return value; this
/// suite pins that ``ChatViewModel`` actually CALLS it (rather than
/// passing the raw ``s.maxTokens`` slider value). A future refactor
/// that swaps ``effectiveMaxTokens(toolsEnabled:)`` back to
/// ``s.maxTokens`` would slip past the SamplingConfig tests; this
/// suite is the one that catches it.
///
/// Uses URLProtocol body capture (the same pattern as
/// ``ChatStreamRequestBodyTests`` / ``CapabilityChipToolBiasTests``)
/// so we observe the actual JSON ChatViewModel.send → ChatStreamClient
/// transmits, not just an intermediate Swift struct.
@MainActor
@Suite("ChatViewModel uses effectiveMaxTokens — reasoning floor reaches the wire", .serialized)
struct ChatViewModelReasoningMaxTokensTests {
    private func makeStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    private func freshDefaults() -> UserDefaults {
        let name = TestDefaultsScope.mintSuiteName(prefix: "rapid-vm-c3-test-")
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Wait for the captured body or the inflight task to settle.
    /// Polls because ``inflight`` is private on ChatViewModel — the
    /// observable side effect is the URLProtocol capture firing,
    /// which lands within milliseconds of ``send`` enqueueing the
    /// request.
    private func waitForCapture(timeoutNs: UInt64 = 15_000_000_000) async {
        // Generous ceiling (15 s): the capture fires within milliseconds
        // when the machine is idle, but under the ~2800-test parallel
        // pool the async send → URLProtocol round-trip can stall past a
        // tight 5 s budget and flake ("no request body captured"). A
        // passing test still returns the instant lastRequestBody lands;
        // only a genuinely stuck send pays the headroom.
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if MaxTokensCaptureProtocol.lastRequestBody != nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
    }

    /// Fresh SamplingConfig + reasoning profile → ChatViewModel.send
    /// with no tools → wire ``max_tokens`` ≥ reasoningChatFloor.
    /// Today the chat floor is 2,048 and the baseline is 4,096, so
    /// the on-the-wire value is 4,096 — the assertion uses ``>=`` so
    /// a future floor raise doesn't churn this test.
    @Test("send() to a reasoning alias with no tools ships max_tokens ≥ reasoningChatFloor")
    func chatPathHonoursChatFloor() async throws {
        MaxTokensCaptureProtocol.reset()
        let sampling = SamplingConfig(defaults: freshDefaults())
        let profile = ServerModelProfile(
            id: "vibethinker-3b-8bit",
            recommendedSampling: nil,
            isHybrid: false,
            isMoe: false,
            toolCallParser: "hermes",
            reasoningParser: "vibethinker",
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)
        #expect(sampling.activeReasoningParser == "vibethinker")

        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: MaxTokensCaptureProtocol.session()
        )
        let store = makeStore()
        _ = store.newSession(alias: "vibethinker-3b-8bit")
        let vm = ChatViewModel(store: store, client: client, sampling: sampling)
        vm.send("test prompt", alias: "vibethinker-3b-8bit")
        await waitForCapture()

        guard let body = MaxTokensCaptureProtocol.lastRequestBody else {
            Issue.record("no request body captured — ChatStreamClient.send didn't fire")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard let maxTokens = parsed["max_tokens"] as? Int else {
            Issue.record("max_tokens missing or non-int — got \(String(describing: parsed["max_tokens"]))")
            return
        }
        #expect(maxTokens >= SamplingConfig.reasoningChatFloor,
                "wire max_tokens (\(maxTokens)) below the chat floor (\(SamplingConfig.reasoningChatFloor)) — ChatViewModel.send is bypassing effectiveMaxTokens(toolsEnabled:)")
    }

    /// Same setup but with tools attached → wire ``max_tokens`` ≥
    /// reasoningToolsFloor. This is the cycle-2 fuzz-correctness P1
    /// scenario: a reasoning alias with the calculator tool on
    /// "27 + 45" returns ``finish_reason = length`` at max_tokens =
    /// 512 (the original cycle-2 repro burned 1,697 reasoning tokens
    /// before the first tool_call). The wire-level pin here guarantees
    /// the floor reaches the server.
    ///
    /// NOTE (2026-07): the tools-on path only engages when tools
    /// actually reach the wire — ``ChatViewModel`` computes
    /// ``effectiveMaxTokens(toolsEnabled: !definitions.isEmpty)``. Since
    /// the 2026-07-09 sweep demoted ``vibethinker-`` to
    /// ``ToolUseCapability.brokenPrefixes`` (tools stripped at the
    /// wire → ``definitions`` empty → chat floor, not tools floor), a
    /// broken alias would silently exercise the CHAT path and defeat
    /// the ``parsed["tools"] != nil`` guard below. This test therefore
    /// uses ``qwen3-8b-4bit`` — a ``.known`` reasoning-capable alias
    /// whose tools DO reach the wire — so the tools floor is genuinely
    /// exercised. The chat-floor counterpart above still pins the
    /// (broken-safe) reasoning alias for its own scenario.
    @Test("send() to a reasoning alias WITH tools ships max_tokens ≥ reasoningToolsFloor")
    func toolPathHonoursToolsFloor() async throws {
        MaxTokensCaptureProtocol.reset()
        let sampling = SamplingConfig(defaults: freshDefaults())
        let profile = ServerModelProfile(
            id: "qwen3-8b-4bit",
            recommendedSampling: nil,
            isHybrid: false,
            isMoe: false,
            toolCallParser: "hermes",
            reasoningParser: "qwen3",
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)

        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: MaxTokensCaptureProtocol.session()
        )
        let store = makeStore()
        _ = store.newSession(alias: "qwen3-8b-4bit")
        let vm = ChatViewModel(
            store: store,
            client: client,
            tools: SingleCalculatorRegistry(),
            sampling: sampling
        )
        vm.send("What is 27 + 45?", alias: "qwen3-8b-4bit")
        await waitForCapture()

        guard let body = MaxTokensCaptureProtocol.lastRequestBody else {
            Issue.record("no request body captured")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard let maxTokens = parsed["max_tokens"] as? Int else {
            Issue.record("max_tokens missing")
            return
        }
        // The tools-on floor is the key bump for cycle-2 P1.
        #expect(maxTokens >= SamplingConfig.reasoningToolsFloor,
                "wire max_tokens (\(maxTokens)) below the tools floor (\(SamplingConfig.reasoningToolsFloor)) — ChatViewModel is shipping the raw slider value instead of effectiveMaxTokens(toolsEnabled: true)")
        // Also confirm the tools really were attached — otherwise the
        // bump would trigger via the chat path (a false green).
        #expect(parsed["tools"] != nil,
                "request body must carry tools to validate the tools-on path")
    }

    /// User explicitly dragged the slider to a value below the floor —
    /// cycle-3 contract says respect the user. Pin that ChatViewModel
    /// ships the user's value verbatim even on a reasoning alias with
    /// tools attached.
    @Test("send() respects an explicit max_tokens = 512 user override on a reasoning alias")
    func userOverrideReachesTheWire() async throws {
        MaxTokensCaptureProtocol.reset()
        let sampling = SamplingConfig(defaults: freshDefaults())
        // User drags slider WAY below the chat floor.
        sampling.maxTokens = 512
        let profile = ServerModelProfile(
            id: "vibethinker-3b-8bit",
            recommendedSampling: nil,
            isHybrid: false,
            isMoe: false,
            toolCallParser: "hermes",
            reasoningParser: "vibethinker",
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)
        #expect(sampling.maxTokens == 512, "applyServerProfile must not silently re-write the user's choice")

        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: MaxTokensCaptureProtocol.session()
        )
        let store = makeStore()
        _ = store.newSession(alias: "vibethinker-3b-8bit")
        let vm = ChatViewModel(
            store: store,
            client: client,
            tools: SingleCalculatorRegistry(),
            sampling: sampling
        )
        vm.send("What is 27 + 45?", alias: "vibethinker-3b-8bit")
        await waitForCapture()

        guard let body = MaxTokensCaptureProtocol.lastRequestBody else {
            Issue.record("no request body captured")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard let maxTokens = parsed["max_tokens"] as? Int else {
            Issue.record("max_tokens missing")
            return
        }
        #expect(maxTokens == 512,
                "wire max_tokens must equal the user's explicit 512 choice — ChatViewModel must NOT silently lift")
    }

    /// Non-reasoning alias path — confirms the cycle-3 change doesn't
    /// perturb the existing default behaviour. With a hermes3-8b-4bit
    /// shape (no reasoning_parser), ChatViewModel must ship the
    /// untouched ``s.maxTokens`` value (4,096 at first launch).
    @Test("send() to a non-reasoning alias ships the raw slider value (no auto-bump)")
    func nonReasoningPathUnchanged() async throws {
        MaxTokensCaptureProtocol.reset()
        let sampling = SamplingConfig(defaults: freshDefaults())
        let profile = ServerModelProfile(
            id: "hermes3-8b-4bit",
            recommendedSampling: nil,
            isHybrid: false,
            isMoe: false,
            toolCallParser: "hermes",
            reasoningParser: nil,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)
        #expect(sampling.activeReasoningParser == nil)

        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: MaxTokensCaptureProtocol.session()
        )
        let store = makeStore()
        _ = store.newSession(alias: "hermes3-8b-4bit")
        let vm = ChatViewModel(
            store: store,
            client: client,
            tools: SingleCalculatorRegistry(),
            sampling: sampling
        )
        vm.send("hello", alias: "hermes3-8b-4bit")
        await waitForCapture()

        guard let body = MaxTokensCaptureProtocol.lastRequestBody else {
            Issue.record("no request body captured")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let maxTokens = parsed["max_tokens"] as? Int
        #expect(maxTokens == SamplingConfig.maxTokensDefault,
                "non-reasoning alias must ship the v0.4.12 4,096 default unchanged (got \(String(describing: maxTokens)))")
    }
}

/// URLProtocol that captures the outgoing JSON request body and
/// responds with a minimal complete SSE stream so
/// ``ChatStreamClient.send`` returns cleanly. Modelled on
/// ``ForcedToolProtocol`` from ``CapabilityChipToolBiasTests``;
/// dedicated class so we don't race the shared static state.
final class MaxTokensCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody: Data?

    static func reset() { lastRequestBody = nil }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MaxTokensCaptureProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let n = buf.withUnsafeMutableBufferPointer { ptr in
                    stream.read(ptr.baseAddress!, maxLength: bufSize)
                }
                if n > 0 { data.append(buf, count: n) }
                if n <= 0 { break }
            }
            stream.close()
            MaxTokensCaptureProtocol.lastRequestBody = data
        } else {
            MaxTokensCaptureProtocol.lastRequestBody = request.httpBody
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n
        data: [DONE]\n
        """.data(using: .utf8)!
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Single-tool registry returning a fake calculator definition.
/// Used by the tools-on tests to make ``definitions.isEmpty == false``
/// in ChatViewModel.runToolLoop without pulling in BuiltinToolRegistry
/// (which would also surface every shipping tool and inflate the
/// captured body).
@MainActor
private final class SingleCalculatorRegistry: ToolRegistry {
    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "calculator",
                description: "Evaluate an arithmetic expression.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "expression": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("expression")]),
                ])
            )
        ]
    }

    func run(_ call: ToolCall) async -> ToolCallResult {
        ToolCallResult(toolCallID: call.id, content: "72")
    }
}
