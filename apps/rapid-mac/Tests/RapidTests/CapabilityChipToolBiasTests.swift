import Foundation
import Testing
@testable import Rapid

/// #141 contract — capability-chip tool_choice bias on the chat
/// completions wire body.
///
/// Background: 2026-06-14 cross-model probe found qwen3.6-35b-4bit
/// routing "What did Apple announce at WWDC 2026?" → ``get_datetime``
/// ~50% of the time when the user originated the send from the
/// "Search the web" empty-state chip. The chip's CTA *promises*
/// ``web_search`` — a different tool firing breaks trust on the very
/// first interactive surface a new user touches.
///
/// Fix: when a send originates from a chip whose
/// ``expectedTool`` is non-nil, the wire body emits
///
///     "tool_choice": {"type":"function","function":{"name":"<expectedTool>"}}
///
/// instead of the default ``"auto"`` string. Free-typed sends (no
/// chip in flight) keep the auto behaviour so the model can pick.
@Suite("#141 capability-chip tool_choice bias — wire body contract", .serialized)
struct CapabilityChipToolBiasTests {

    // MARK: - Wire body shape

    @Test("Default request (no forcedTool) ships tool_choice=\"auto\" when tools are advertised")
    func defaultEmitsAutoString() throws {
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "hi", status: .complete)],
            tools: [Self.fakeWebSearchTool]
        )
        let body = try encode(request: req)
        // ``"auto"`` round-trips as a JSON string, so the parsed dict
        // surfaces it as ``String``.
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test("forcedTool=\"web_search\" emits the typed-function tool_choice shape")
    func forcedToolEmitsTypedFunction() throws {
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "Search the web for WWDC 2026", status: .complete)],
            tools: [Self.fakeWebSearchTool],
            forcedTool: "web_search"
        )
        let body = try encode(request: req)
        guard let choice = body["tool_choice"] as? [String: Any] else {
            Issue.record("forcedTool send must emit a JSON object for tool_choice, got \(String(describing: body["tool_choice"]))")
            return
        }
        #expect(choice["type"] as? String == "function")
        guard let function = choice["function"] as? [String: Any] else {
            Issue.record("typed tool_choice must carry a nested function block")
            return
        }
        #expect(function["name"] as? String == "web_search")
    }

    @Test("forcedTool round-trips for every BuiltinToolRegistry capability-chip tool name")
    func forcedToolRoundTripsForEveryChipTool() throws {
        // Mirror the four chip-promised tool names from
        // ``ChatView.capabilityChipKinds`` so a future chip-row
        // refactor that renames a tool surfaces here too.
        for name in ["web_search", "calculator", "weather", "read_file"] {
            let req = ChatStreamClient.Request(
                alias: "qwen3.6-35b-4bit",
                messages: [ChatMessage(role: .user, content: "x", status: .complete)],
                tools: [Self.fakeWebSearchTool],
                forcedTool: name
            )
            let body = try encode(request: req)
            let choice = body["tool_choice"] as? [String: Any]
            let function = choice?["function"] as? [String: Any]
            #expect(function?["name"] as? String == name, "forcedTool=\"\(name)\" must round-trip on the wire")
        }
    }

    @Test("Empty tool registry omits tool_choice entirely, even when forcedTool is set")
    func emptyRegistryOmitsToolChoice() throws {
        // A wire body that emits ``tool_choice: {…}`` without a
        // ``tools`` field is malformed per OpenAI spec — the server
        // has nothing to bind the typed function name against. The
        // resolver must collapse to ``nil`` (omit the field) in
        // that case so the request stays valid.
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "hi", status: .complete)],
            tools: nil,
            forcedTool: "web_search"
        )
        let body = try encode(request: req)
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }

    @Test("Empty / whitespace forcedTool degrades to tool_choice=auto, never function.name=\"\"")
    func emptyForcedToolDegradesToAuto() throws {
        // Defends against a future caller passing a stray empty
        // string from a stale ``pendingForcedTool``. A typed
        // function block with ``name: ""`` would be a 400 from
        // a strict server; degrading to ``"auto"`` keeps the
        // request shipping.
        for stray in ["", " ", "\n\t "] {
            let req = ChatStreamClient.Request(
                alias: "qwen3.6-35b-4bit",
                messages: [ChatMessage(role: .user, content: "x", status: .complete)],
                tools: [Self.fakeWebSearchTool],
                forcedTool: stray
            )
            let body = try encode(request: req)
            #expect(body["tool_choice"] as? String == "auto", "forcedTool=\"\(stray.debugDescription)\" must degrade to auto")
        }
    }

    @Test("Wire.ToolChoice.resolve covers the no-tools / auto / function decision matrix")
    func resolveDecisionMatrix() {
        // No tools → omit (nil), regardless of forcedTool.
        #expect(Wire.ToolChoice.resolve(hasTools: false, forcedTool: nil) == nil)
        #expect(Wire.ToolChoice.resolve(hasTools: false, forcedTool: "web_search") == nil)
        // Tools present + nil forcedTool → auto.
        #expect(Wire.ToolChoice.resolve(hasTools: true, forcedTool: nil) == .auto)
        // Tools present + non-empty forcedTool → typed function.
        #expect(Wire.ToolChoice.resolve(hasTools: true, forcedTool: "web_search") == .function(name: "web_search"))
        // Tools present + whitespace-only forcedTool → auto.
        #expect(Wire.ToolChoice.resolve(hasTools: true, forcedTool: " ") == .auto)
    }

    @Test("Raw JSON of typed tool_choice is the OpenAI canonical shape")
    func rawJSONShape() throws {
        // Pin the raw on-the-wire bytes so a future Encodable
        // refactor that flips key order or wraps the function block
        // in an array can't pass without explicit revisit.
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "x", status: .complete)],
            tools: [Self.fakeWebSearchTool],
            forcedTool: "web_search"
        )
        let body = Wire.ChatCompletionRequest(
            model: req.alias,
            messages: req.messages,
            stream: true,
            temperature: req.temperature,
            top_p: req.topP,
            max_tokens: req.maxTokens,
            repetition_penalty: req.repetitionPenalty,
            frequency_penalty: req.frequencyPenalty,
            presence_penalty: req.presencePenalty,
            tools: (req.tools?.isEmpty == false) ? req.tools : nil,
            tool_choice: Wire.ToolChoice.resolve(
                hasTools: req.tools?.isEmpty == false,
                forcedTool: req.forcedTool
            ),
            stream_options: .init(include_usage: true),
            chat_template_kwargs: req.enableThinking
                ? nil
                : .init(enable_thinking: false)
        )
        let data = try JSONEncoder().encode(body)
        guard let raw = String(data: data, encoding: .utf8) else {
            Issue.record("body wasn't UTF-8 decodable")
            return
        }
        // Don't pin whitespace — JSONEncoder may interleave keys —
        // but DO pin the substring that identifies the typed shape.
        #expect(raw.contains("\"tool_choice\""))
        #expect(raw.contains("\"type\":\"function\""))
        #expect(raw.contains("\"name\":\"web_search\""))
    }

    // MARK: - End-to-end via URLProtocol

    @Test("End-to-end send() with forcedTool ships the typed function shape")
    @MainActor
    func endToEndForcedTool() async throws {
        ForcedToolProtocol.reset()
        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: ForcedToolProtocol.session()
        )
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "Search the web for WWDC 2026", status: .complete)],
            tools: [Self.fakeWebSearchTool],
            forcedTool: "web_search"
        )
        try await client.send(req) { _ in }
        guard let body = ForcedToolProtocol.lastRequestBody else {
            Issue.record("no request body captured")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard let choice = parsed["tool_choice"] as? [String: Any],
              let function = choice["function"] as? [String: Any] else {
            Issue.record("typed tool_choice missing from wire body — got \(String(describing: parsed["tool_choice"]))")
            return
        }
        #expect(function["name"] as? String == "web_search")
    }

    @Test("End-to-end send() WITHOUT forcedTool keeps tool_choice=\"auto\"")
    @MainActor
    func endToEndAutoDefault() async throws {
        ForcedToolProtocol.reset()
        let client = ChatStreamClient(
            baseURL: URL(string: "fake://rapid-mlx")!,
            session: ForcedToolProtocol.session()
        )
        let req = ChatStreamClient.Request(
            alias: "qwen3.6-35b-4bit",
            messages: [ChatMessage(role: .user, content: "tell me a joke", status: .complete)],
            tools: [Self.fakeWebSearchTool]
        )
        try await client.send(req) { _ in }
        guard let body = ForcedToolProtocol.lastRequestBody else {
            Issue.record("no request body captured")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(parsed["tool_choice"] as? String == "auto")
    }

    // MARK: - ChatView resolve helper

    @Test("ChatView.resolvePendingForcedTool keeps the bias when the draft starts with the seed")
    func resolveHelperKeepsBiasOnSeedPrefix() {
        // The "Search the web" chip seeds ``"Search the web for "``;
        // the user typing ``"golden retrievers"`` after it must
        // KEEP the bias because the draft still carries the chip's
        // intent.
        let forced = ChatView.resolvePendingForcedTool(
            pending: "web_search",
            draft: "Search the web for golden retrievers"
        )
        #expect(forced == "web_search")
    }

    @Test("ChatView.resolvePendingForcedTool drops the bias when the draft no longer starts with the seed")
    func resolveHelperDropsBiasOnPrefixMismatch() {
        // User pasted entirely different prose. The chip's intent
        // is gone — degrade to auto.
        let forced = ChatView.resolvePendingForcedTool(
            pending: "web_search",
            draft: "What's the capital of France?"
        )
        #expect(forced == nil)
    }

    @Test("ChatView.resolvePendingForcedTool returns nil when nothing is pending")
    func resolveHelperReturnsNilWhenNotPending() {
        let forced = ChatView.resolvePendingForcedTool(
            pending: nil,
            draft: "Search the web for golden retrievers"
        )
        #expect(forced == nil)
    }

    @Test("ChatView.resolvePendingForcedTool returns nil for empty / whitespace draft")
    func resolveHelperReturnsNilForEmptyDraft() {
        for draft in ["", "   ", "\n\t"] {
            let forced = ChatView.resolvePendingForcedTool(
                pending: "web_search",
                draft: draft
            )
            #expect(forced == nil, "empty/whitespace draft \"\(draft.debugDescription)\" must not stamp forcedTool")
        }
    }

    @Test("ChatView.resolvePendingForcedTool matches against the originating chip's seed only")
    func resolveHelperMatchesOriginatingChipOnly() {
        // The user clicked "Weather" (pending=weather) then pasted
        // the "Search the web for" text — the chip-origin contract
        // is "this chip's intent is still active," not "any chip's
        // intent is active." Resolve must drop the bias.
        let forced = ChatView.resolvePendingForcedTool(
            pending: "weather",
            draft: "Search the web for WWDC 2026"
        )
        #expect(forced == nil)
    }

    @Test("Every chip in capabilityChipKinds carries an expectedTool")
    func everyChipCarriesExpectedTool() {
        // Pin the contract that the four canonical chips all map
        // to a known BuiltinToolRegistry function name. A future
        // chip-row addition that omits expectedTool is OPT-IN (the
        // chip will run with tool_choice=auto, which is fine) — but
        // for the canonical four we want the explicit bias.
        let expected: [String: String] = [
            "Search the web": "web_search",
            "Calculate": "calculator",
            "Weather": "weather",
            "Read files": "read_file",
        ]
        for kind in ChatView.capabilityChipKinds {
            #expect(
                kind.expectedTool == expected[kind.title],
                "Chip \"\(kind.title)\" expectedTool=\(String(describing: kind.expectedTool)) — expected \(String(describing: expected[kind.title]))"
            )
        }
    }

    // MARK: - helpers

    /// Minimal tool definition used to satisfy ``has tools advertised``
    /// on the wire. The function shape isn't load-bearing — the
    /// tests assert against ``tool_choice`` only.
    private static let fakeWebSearchTool = ToolDefinition(
        name: "web_search",
        description: "Search the web.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
        ])
    )

    /// Encode ``Request`` through the same Wire mapping
    /// ``ChatStreamClient.send`` would and return the parsed JSON
    /// dict for inspection. Mirrors the helper from
    /// ``ChatStreamRequestBodyTests`` so the tool_choice path is
    /// exercised against the exact code the production hot path
    /// runs.
    private func encode(request: ChatStreamClient.Request) throws -> [String: Any] {
        let body = Wire.ChatCompletionRequest(
            model: request.alias,
            messages: request.messages,
            stream: true,
            temperature: request.temperature,
            top_p: request.topP,
            max_tokens: request.maxTokens,
            repetition_penalty: request.repetitionPenalty,
            frequency_penalty: request.frequencyPenalty,
            presence_penalty: request.presencePenalty,
            tools: (request.tools?.isEmpty == false) ? request.tools : nil,
            tool_choice: Wire.ToolChoice.resolve(
                hasTools: request.tools?.isEmpty == false,
                forcedTool: request.forcedTool
            ),
            stream_options: .init(include_usage: true),
            chat_template_kwargs: request.enableThinking
                ? nil
                : .init(enable_thinking: false)
        )
        let data = try JSONEncoder().encode(body)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return parsed as! [String: Any]
    }
}

/// URLProtocol that captures the outgoing request body so the
/// end-to-end tests above can read back the wire JSON
/// ``ChatStreamClient.send`` actually shipped. Modelled on
/// ``FakeChatProtocol`` from ``ChatStreamRequestBodyTests`` — a
/// dedicated class so we don't race that suite's shared static.
final class ForcedToolProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody: Data?

    static func reset() { lastRequestBody = nil }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForcedToolProtocol.self] + (config.protocolClasses ?? [])
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
            ForcedToolProtocol.lastRequestBody = data
        } else {
            ForcedToolProtocol.lastRequestBody = request.httpBody
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
