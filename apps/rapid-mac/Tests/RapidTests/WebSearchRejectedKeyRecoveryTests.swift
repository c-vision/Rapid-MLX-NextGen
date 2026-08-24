import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Rejected web-search key recovery")
final class WebSearchRejectedKeyRecoveryTests {
    private var suiteNames: [String] = []
    deinit { TestDefaultsScope.cleanup(suiteNames: suiteNames) }

    private func freshDefaults() -> UserDefaults {
        let name = TestDefaultsScope.mintSuiteName(prefix: "rapid-search-recovery-")
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCall(id: String = "search_1") -> ToolCall {
        ToolCall(
            id: id,
            name: "web_search",
            arguments: #"{"query":"what is the news today?"}"#
        )
    }

    private static func rejectedResult() -> ToolCallResult {
        ToolCallResult(
            toolCallID: "",
            content: "provider rejected the credential",
            isError: true,
            failureKind: .webSearchKeyRejected
        )
    }

    @Test("First search removes a rejected optional key and replays once keyless")
    func firstSearchRecoversKeyless() async {
        let keychain = InMemoryKeychain()
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)
        #expect(config.setAPIKey("keen_rejected_secret", for: .keenable))

        var observedKeys: [String?] = []
        let registry = BuiltinToolRegistry(webSearch: config) { arguments, provider, key in
            observedKeys.append(key)
            #expect(arguments == #"{"query":"what is the news today?"}"#)
            #expect(provider == .keenable)
            if key != nil { return Self.rejectedResult() }
            return ToolCallResult(
                toolCallID: "",
                content: "Web search via Keenable: keyless result",
                isError: false
            )
        }

        let result = await registry.run(makeCall())

        #expect(!result.isError)
        #expect(result.toolCallID == "search_1")
        #expect(observedKeys.count == 2)
        #expect(observedKeys[0] == "keen_rejected_secret")
        #expect(observedKeys[1] == nil)
        #expect(config.apiKey(for: .keenable) == nil)
        #expect(result.content.contains("keyless mode"))
        #expect(!result.content.contains("keen_rejected_secret"))
    }

    @Test("A first-chat web search completes with recovered evidence, not a failed tool row")
    func firstChatSearchRecoversInPlace() async throws {
        FirstChatSearchProtocol.reset()
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_first_chat_stale", for: .keenable))

        var observedKeys: [String?] = []
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            observedKeys.append(key)
            if key != nil { return Self.rejectedResult() }
            return ToolCallResult(
                toolCallID: "",
                content: "Web search via Keenable (keyless): current headline"
            )
        }
        let model = ChatViewModel(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://first-chat-search")!,
                session: FirstChatSearchProtocol.session()
            ),
            tools: registry,
            persistsConversations: false
        )

        model.send("What is the news today?", alias: "test-model")
        for _ in 0..<300 where model.isStreaming {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isStreaming)
        #expect(model.messages.last?.content == "Here is today's answer from current search evidence.")
        #expect(model.messages.last?.status == .complete)
        #expect(model.messages.filter { $0.role == .tool }.count == 1)
        let toolRow = try #require(model.messages.first { $0.role == .tool })
        #expect(toolRow.status == .complete)
        #expect(toolRow.failureKind == nil)
        #expect(toolRow.content.contains("keyless"))
        #expect(!toolRow.content.contains("keen_first_chat_stale"))
        #expect(observedKeys.count == 2)
        #expect(observedKeys[0] == "keen_first_chat_stale")
        #expect(observedKeys[1] == nil)
        #expect(FirstChatSearchProtocol.requestBodies.count == 2)
    }

    @Test("Later searches stay keyless and never resend the rejected credential")
    func repeatedSearchDoesNotReuseRejectedKey() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_stale", for: .keenable))

        var observedKeys: [String?] = []
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            observedKeys.append(key)
            if key != nil { return Self.rejectedResult() }
            return ToolCallResult(toolCallID: "", content: "keyless result")
        }

        let first = await registry.run(makeCall(id: "first"))
        let second = await registry.run(makeCall(id: "second"))

        #expect(!first.isError)
        #expect(!second.isError)
        #expect(observedKeys.count == 3)
        #expect(observedKeys[0] == "keen_stale")
        #expect(observedKeys[1] == nil)
        #expect(observedKeys[2] == nil)
    }

    @Test("A replacement key saved while the request is in flight is preserved")
    func concurrentReplacementWinsOverStaleRejection() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_old_rejected", for: .keenable))

        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            attempts += 1
            #expect(key == "keen_old_rejected")
            // Simulate Settings saving a replacement while the first network
            // request is suspended. Its eventual rejection belongs only to
            // the credential captured when that request began.
            #expect(config.setAPIKey("keen_new_valid", for: .keenable))
            await Task.yield()
            return Self.rejectedResult()
        }

        let result = await registry.run(makeCall())

        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .keenable) == "keen_new_valid")
    }

    @Test("A same-value replacement is a new credential revision and is preserved")
    func sameValueReplacementWinsOverStaleRejection() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_aba", for: .keenable))
        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
            attempts += 1
            #expect(config.setAPIKey("keen_intermediate", for: .keenable))
            #expect(config.setAPIKey("keen_aba", for: .keenable))
            return Self.rejectedResult()
        }

        let result = await registry.run(makeCall())

        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .keenable) == "keen_aba")
    }

    @Test("A manual clear during the request is not narrated as automatic recovery")
    func manualClearDoesNotShareAutomaticRecovery() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_user_clears", for: .keenable))
        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
            attempts += 1
            #expect(config.setAPIKey(nil, for: .keenable))
            return Self.rejectedResult()
        }

        let result = await registry.run(makeCall())

        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .keenable) == nil)
        #expect(!result.content.contains("Rapid removed"))
    }

    @Test("Overlapping rejections both share the transition to keyless mode")
    func overlappingRejectionsBothRecover() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_shared_stale", for: .keenable))
        let keyedBarrier = TestBarrier(participants: 2)
        var observedKeys: [String?] = []
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            observedKeys.append(key)
            if key != nil {
                await keyedBarrier.arriveAndWait()
                return Self.rejectedResult()
            }
            return ToolCallResult(toolCallID: "", content: "keyless result")
        }

        async let first = registry.run(makeCall(id: "overlap_1"))
        async let second = registry.run(makeCall(id: "overlap_2"))
        let results = await [first, second]

        #expect(results.allSatisfy { !$0.isError })
        #expect(observedKeys.compactMap { $0 }.count == 2)
        #expect(observedKeys.filter { $0 == nil }.count == 2)
        #expect(config.apiKey(for: .keenable) == nil)
    }

    @Test("Cancellation after rejection does not clear the key or start recovery")
    func cancellationStopsRecovery() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_keep_on_cancel", for: .keenable))

        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
            attempts += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.rejectedResult()
        }

        let result = await Task { await registry.run(makeCall()) }.value

        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .keenable) == "keen_keep_on_cancel")
    }

    @Test("Cancellation racing with key removal makes one bounded replay attempt")
    func cancellationDuringPersistentTransitionAttemptsReplay() async {
        let keychain = CancellationOnDeleteKeychain()
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)
        #expect(config.setAPIKey("keen_rejected_during_delete", for: .keenable))

        var observedKeys: [String?] = []
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            observedKeys.append(key)
            if key != nil { return Self.rejectedResult() }
            #expect(Task.isCancelled)
            return ToolCallResult(
                toolCallID: "",
                content: "keyless replay cancelled",
                isError: true,
                failureKind: .toolFailed
            )
        }

        let result = await Task { await registry.run(makeCall()) }.value

        #expect(result.isError)
        #expect(result.failureKind == .toolFailed)
        #expect(result.failureKind != .webSearchKeyRejected)
        #expect(observedKeys.count == 2)
        #expect(observedKeys[0] == "keen_rejected_during_delete")
        #expect(observedKeys[1] == nil)
        #expect(config.apiKey(for: .keenable) == nil)
    }

    @Test("A replacement saved during replay makes no false future-state claim")
    func replacementDuringReplayKeepsAuditNoteTruthful() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(config.setAPIKey("keen_rejected_before_replay", for: .keenable))
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, key in
            if key != nil { return Self.rejectedResult() }
            await Task.yield()
            #expect(config.setAPIKey("keen_replacement_during_replay", for: .keenable))
            return ToolCallResult(toolCallID: "", content: "keyless result")
        }

        let result = await registry.run(makeCall())

        #expect(!result.isError)
        #expect(result.content.contains("retried this search"))
        #expect(!result.content.contains("Future searches"))
        #expect(config.apiKey(for: .keenable) == "keen_replacement_during_replay")
    }

    @Test("A failed Keychain delete keeps the original failure and does not replay")
    func persistenceFailureDoesNotPretendToRecover() async {
        let keychain = DeleteFailingKeychain()
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)
        #expect(config.setAPIKey("keen_cannot_delete", for: .keenable))

        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
            attempts += 1
            return Self.rejectedResult()
        }

        let result = await registry.run(makeCall())

        #expect(result.isError)
        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .keenable) == "keen_cannot_delete")
    }

    @Test("Quota, rate-limit, network, and query failures never enter credential recovery")
    func unrelatedFailuresAreNotRetried() async {
        for kind in [
            FailureDiagnosis.Kind.webSearchKeyQuotaExceeded,
            .webSearchKeyRateLimited,
            .webSearchOffline,
            .webSearchUnavailable,
            .toolFailed,
        ] {
            let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
            #expect(config.setAPIKey("keen_still_valid", for: .keenable))
            var attempts = 0
            let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
                attempts += 1
                return ToolCallResult(
                    toolCallID: "",
                    content: "typed failure",
                    isError: true,
                    failureKind: kind
                )
            }

            let result = await registry.run(makeCall())

            #expect(result.failureKind == kind)
            #expect(attempts == 1)
            #expect(config.apiKey(for: .keenable) == "keen_still_valid")
        }
    }

    @Test("A provider without the recovery capability never clears or replays")
    func ineligibleProviderDoesNotRecover() async {
        let config = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        config.provider = .parallel
        #expect(config.setAPIKey("parallel_rejected", for: .parallel))
        var attempts = 0
        let registry = BuiltinToolRegistry(webSearch: config) { _, _, _ in
            attempts += 1
            return Self.rejectedResult()
        }

        let result = await registry.run(makeCall())

        #expect(result.failureKind == .webSearchKeyRejected)
        #expect(attempts == 1)
        #expect(config.apiKey(for: .parallel) == "parallel_rejected")
    }
}

private actor TestBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        remaining = participants
    }

    func arriveAndWait() async {
        remaining -= 1
        if remaining == 0 {
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class DeleteFailingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func read(account: String) -> String? {
        lock.withLock { storage[account] }
    }

    func write(account: String, secret: String) -> Bool {
        lock.withLock { storage[account] = secret }
        return true
    }

    func delete(account: String) -> Bool { false }
}

private final class CancellationOnDeleteKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func read(account: String) -> String? {
        lock.withLock { storage[account] }
    }

    func write(account: String, secret: String) -> Bool {
        lock.withLock { storage[account] = secret }
        return true
    }

    func delete(account: String) -> Bool {
        _ = lock.withLock { storage.removeValue(forKey: account) }
        withUnsafeCurrentTask { $0?.cancel() }
        return true
    }
}

private final class FirstChatSearchProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestBodies: [Data] = []

    static func reset() {
        requestBodies = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstChatSearchProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestBodies.append(readBody(from: request))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let stream: String
        if Self.requestBodies.count == 1 {
            stream = #"""
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"search_1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"what is the news today?\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """#
        } else {
            stream = """
            data: {"choices":[{"delta":{"content":"Here is today's answer from current search evidence."},"finish_reason":"stop"}]}

            data: [DONE]

            """
        }
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody(from request: URLRequest) -> Data {
        guard let input = request.httpBodyStream else { return request.httpBody ?? Data() }
        input.open()
        defer { input.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
