import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Preset session snapshots")
struct PresetSessionTests {
    private func store() -> SessionStore {
        SessionStore(customStoreURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-preset-session-\(UUID().uuidString).json"))
    }

    private func preset() -> ChatPreset {
        ChatPreset(
            id: "builtin.test",
            origin: .builtIn,
            name: "Test Coder",
            icon: "terminal",
            systemPrompt: "Be precise.",
            modelAlias: "model-b",
            sampling: SamplingOverrides(temperature: 0.25, maxTokens: 768),
            enabledToolNames: ["calculator"],
            knowledgeBaseIDs: ["kb.one"]
        )
    }

    @Test("Legacy ChatSession JSON defaults all preset fields safely")
    func legacyDecode() throws {
        let data = Data("""
        {
          "id":"11111111-1111-1111-1111-111111111111",
          "title":"Old",
          "alias":"model-a",
          "messages":[],
          "createdAt":770000000,
          "updatedAt":770000000,
          "isPinned":false
        }
        """.utf8)
        let session = try JSONDecoder().decode(ChatSession.self, from: data)
        #expect(session.appliedPreset == nil)
        #expect(session.samplingOverrides == nil)
        #expect(session.enabledToolNames == nil)
        #expect(session.knowledgeBaseIDs.isEmpty)
    }

    @Test("New session copies every preset value")
    func newSessionSnapshot() throws {
        let store = store()
        let id = store.newSession(alias: "model-a", preset: preset())
        let session = try #require(store.sessions.first(where: { $0.id == id }))
        #expect(session.alias == "model-b")
        #expect(session.systemPrompt == "Be precise.")
        #expect(session.appliedPreset?.name == "Test Coder")
        #expect(session.samplingOverrides?.temperature == 0.25)
        #expect(session.enabledToolNames == ["calculator"])
        #expect(session.knowledgeBaseIDs == ["kb.one"])
    }

    @Test("Preset can reuse a plain empty row but configured rows are protected")
    func reuseRules() throws {
        let store = store()
        let blank = store.newOrReuseSession(alias: "model-a")
        let applied = store.newOrReuseSession(alias: "model-a", preset: preset())
        #expect(applied.id == blank.id)
        #expect(applied.reused)
        #expect(store.firstReusableEmptySession() == nil)

        let next = store.newOrReuseSession(alias: "model-a")
        #expect(next.id != applied.id)
    }

    @Test("A model-less preset refreshes a reused blank row to the current model")
    func reusedAliasFallback() throws {
        let store = store()
        let blank = store.newSession(alias: "model-old")
        let modelLess = ChatPreset.user(
            name: "Current Model",
            systemPrompt: "Use the current model."
        )

        let applied = store.newOrReuseSession(alias: "model-current", preset: modelLess)
        let session = try #require(store.sessions.first(where: { $0.id == blank }))
        #expect(applied.id == blank)
        #expect(session.alias == "model-current")
    }

    @Test("Manual configuration removes provenance but preserves the new value")
    func manualCustomization() throws {
        let store = store()
        let id = store.newSession(alias: "model-a", preset: preset())
        store.setSystemPrompt(id: id, "Custom prompt")
        var session = try #require(store.sessions.first(where: { $0.id == id }))
        #expect(session.appliedPreset == nil)
        #expect(session.systemPrompt == "Custom prompt")

        store.applyPreset(id: id, preset())
        store.setEnabledToolNames(id: id, [])
        session = try #require(store.sessions.first(where: { $0.id == id }))
        #expect(session.appliedPreset == nil)
        #expect(session.enabledToolNames == [])

        store.applyPreset(id: id, preset())
        store.setAlias("model-c", for: id)
        session = try #require(store.sessions.first(where: { $0.id == id }))
        #expect(session.appliedPreset == nil)
        #expect(session.alias == "model-c")
    }

    @Test("Fork inherits the complete applied configuration snapshot")
    func forkSnapshot() throws {
        let store = store()
        let parentID = store.newSession(alias: "model-a", preset: preset())
        let message = ChatMessage(role: .user, content: "Hello")
        store.appendMessage(sessionID: parentID, message)
        let branchID = try #require(store.fork(sessionID: parentID, throughMessageID: message.id))
        let branch = try #require(store.sessions.first(where: { $0.id == branchID }))
        #expect(branch.appliedPreset?.id == "builtin.test")
        #expect(branch.samplingOverrides == preset().sampling)
        #expect(branch.enabledToolNames == ["calculator"])
        #expect(branch.knowledgeBaseIDs == ["kb.one"])
    }

    @Test("Session tools can narrow but never bypass a global disable")
    func toolIntersection() {
        let store = store()
        let suite = "rapid-preset-tools-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "rapid.tools.enabled.calculator")
        let registry = PresetToolRegistry()
        let vm = ChatViewModel(store: store, tools: registry, toolDefaults: defaults)
        let session = ChatSession(
            alias: "model-a",
            enabledToolNames: ["calculator", "read_file"]
        )
        #expect(vm.enabledDefinitions(for: session).map { $0.function.name } == ["read_file"])
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Forced tool is dropped when a preset excludes it")
    func forcedToolAvailability() {
        let definitions = [CalculatorTool.definition]
        #expect(ChatViewModel.availableForcedTool("calculator", definitions: definitions) == "calculator")
        #expect(ChatViewModel.availableForcedTool("web_search", definitions: definitions) == nil)
        #expect(ChatViewModel.availableForcedTool(nil, definitions: definitions) == nil)
    }

    @Test("Sampling overrides resolve per request and clamp invalid values")
    func samplingResolution() {
        let suite = "rapid-preset-sampling-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let sampling = SamplingConfig(defaults: defaults)
        let resolved = sampling.resolved(
            overrides: SamplingOverrides(
                temperature: 99,
                topP: 0,
                maxTokens: 1,
                repetitionPenalty: 9,
                enableThinking: true
            ),
            toolsEnabled: false
        )
        #expect(resolved.temperature == SamplingConfig.temperatureRange.upperBound)
        #expect(resolved.topP == SamplingConfig.topPRange.lowerBound)
        #expect(resolved.maxTokens == SamplingConfig.maxTokensRange.lowerBound)
        #expect(resolved.repetitionPenalty == SamplingConfig.repetitionPenaltyRange.upperBound)
        #expect(resolved.enableThinking)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class PresetToolRegistry: ToolRegistry {
    let definitions: [ToolDefinition] = [
        CalculatorTool.definition,
        FilesystemToolDefinitions.readFile,
    ]

    func run(_ call: ToolCall) async -> ToolCallResult {
        ToolCallResult(toolCallID: call.id, content: "unused")
    }
}
