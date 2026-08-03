import Foundation
import Testing
@testable import Rapid

/// Issue #476: a crash / SIGKILL / force-quit mid-stream persists an
/// assistant row as ``.streaming`` (the debounced save fired before the
/// graceful ``finalizeStreamingForTermination`` could run). On the next
/// launch that stale row must be normalized to a terminal state, otherwise
/// it renders a perpetual "Thinking…" spinner, pins ``streamingCount`` > 0
/// forever (widening the debounce window for every future save), and
/// replays orphan ``tool_calls`` that 400 the next turn.
///
/// This suite pins the load-time normalization: stale ``.streaming`` rows
/// become ``.complete`` with cleared ``toolCalls`` and an interruption
/// footer; non-streaming rows pass through untouched.
@MainActor
@Suite("SessionStore stale-streaming normalization (issue #476)")
struct SessionStoreStaleStreamingTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "rapid.tests.stale-streaming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func loadStore(
        with body: Data,
        defaults: UserDefaults
    ) async -> (store: SessionStore, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-stale-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent("sessions.json")
        try? body.write(to: tmp, options: [.atomic])
        let store = SessionStore(customStoreURL: tmp, customDefaults: defaults)
        await store.awaitInitialLoad()
        return (store, parent)
    }

    private func cleanup(_ parent: URL) {
        try? FileManager.default.removeItem(at: parent)
    }

    /// An assistant message, optionally in ``.streaming`` status, optionally
    /// carrying a partial tool call, with a fixed non-empty body.
    private func assistant(
        id: UUID = UUID(),
        status: String,
        content: String = "partial answer",
        toolCall: Bool = false
    ) -> String {
        let toolCallsJSON = toolCall
            ? """
            , "toolCalls": [ { "id": "call_1", "type": "function",
              "function": { "name": "web_search", "arguments": "{}" } } ]
            """
            : ""
        return """
        {
          "id": "\(id.uuidString)", "role": "assistant", "content": "\(content)",
          "reasoning": "", "status": "\(status)",
          "createdAt": "2026-06-30T00:00:00Z"\(toolCallsJSON)
        }
        """
    }

    private func userMessage(id: UUID = UUID()) -> String {
        """
        {
          "id": "\(id.uuidString)", "role": "user", "content": "hi",
          "reasoning": "", "status": "complete", "createdAt": "2026-06-30T00:00:00Z"
        }
        """
    }

    private func session(id: UUID, title: String, messages: [String]) -> String {
        """
        {
          "id": "\(id.uuidString)", "alias": "qwen3.5-4b", "title": "\(title)",
          "isPinned": false, "messages": [ \(messages.joined(separator: ",")) ],
          "createdAt": "2026-06-30T00:00:00Z", "updatedAt": "2026-06-30T00:00:00Z"
        }
        """
    }

    @Test("A stale .streaming row loads as .complete (no perpetual Thinking spinner)")
    func staleStreamingRowNormalizedToComplete() async throws {
        let s0 = UUID()
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Crashed",
              messages: [userMessage(), assistant(status: "streaming")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        let last = try #require(store.sessions.first?.messages.last)
        #expect(last.status == .complete, "stale streaming row must not stay .streaming")
        #expect(store.streamingMessageCount == 0, "no live stream after a fresh load")
        #expect(last.content.contains("interrupted"),
                "an interruption footer signals why the reply stopped")
    }

    @Test("Normalization clears partial tool_calls (session stays continuable)")
    func staleStreamingToolCallsCleared() async throws {
        let s0 = UUID()
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Crashed mid-tool",
              messages: [userMessage(), assistant(status: "streaming", toolCall: true)])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        let last = try #require(store.sessions.first?.messages.last)
        #expect(last.status == .complete)
        #expect(last.toolCalls == nil,
                "orphan tool_calls must be cleared or the next turn 400s")
    }

    @Test("Non-streaming rows are untouched by normalization")
    func completeRowsPassThroughUnchanged() async throws {
        let s0 = UUID()
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Clean",
              messages: [userMessage(), assistant(status: "complete", content: "done")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        let last = try #require(store.sessions.first?.messages.last)
        #expect(last.status == .complete)
        #expect(last.content == "done", "a completed row's content must not be mutated")
        #expect(store.streamingMessageCount == 0)
    }

    @Test("The healed row survives a re-save + relaunch (no re-wedge)")
    func normalizedRowPersistsAcrossRelaunch() async throws {
        let s0 = UUID()
        let envelope = Data("""
        { "sessions": [ \(session(id: s0, title: "Crashed",
              messages: [userMessage(), assistant(status: "streaming")])) ] }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }
        // Flush the healed state, then relaunch and confirm the row is still
        // terminal (the canonical file no longer carries a .streaming row).
        await store.flush()
        let storeURL = parent.appendingPathComponent("sessions.json")
        let relaunched = SessionStore(customStoreURL: storeURL, customDefaults: defaults)
        await relaunched.awaitInitialLoad()
        #expect(relaunched.sessions.first?.messages.last?.status == .complete)
        #expect(relaunched.streamingMessageCount == 0)
    }

    @Test("Restoring a backup that carries a stale .streaming row normalizes it too (no re-wedge via restore path)")
    func restoredBackupStreamingRowNormalized() async throws {
        // Start from a full break so the load leaves a backup + empty live.
        let corrupt = Data("not json".utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: corrupt, defaults: defaults)
        defer { cleanup(parent) }
        let backup = try #require(store.availableSessionBackups().first,
                                  "the corrupt load should have left a backup")

        // Point the backup at an envelope whose last row is a stale
        // .streaming assistant (the crash-mid-stream artifact #476 targets),
        // then restore it. `restoreSessionBackup` decodes straight off disk
        // (no normalization there), so the fix must live in the adopt path.
        let s0 = UUID()
        let staleBackup = Data("""
        { "sessions": [ \(session(id: s0, title: "Restored crash",
              messages: [userMessage(), assistant(status: "streaming", toolCall: true)])) ] }
        """.utf8)
        try staleBackup.write(to: backup.url, options: [.atomic])

        try await store.restoreSessionBackup(backup)

        let last = try #require(store.sessions.first?.messages.last)
        #expect(last.status == .complete, "restore must not adopt a stale .streaming row verbatim")
        #expect(last.toolCalls == nil, "orphan tool_calls must be cleared on the restore path too")
        #expect(store.streamingMessageCount == 0, "restore must not pin the streaming counter > 0")
    }
}
