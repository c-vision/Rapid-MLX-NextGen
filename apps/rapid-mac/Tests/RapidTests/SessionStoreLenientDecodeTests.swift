import Foundation
import Testing
@testable import Rapid

/// Issue #477: one forward-incompatible message / one malformed session
/// must NOT discard the entire visible history. Pre-fix, ``decodeFromDisk``
/// did a single monolithic ``try? decoder.decode(StoreEnvelope.self)``:
/// any throw anywhere collapsed the whole load into ``.corrupt`` and
/// emptied the sidebar. This suite is the Step-0 reproduction turned
/// regression guard — the two seeds below fail on the pre-fix engine
/// (0 surviving sessions) and pass after the lenient-decode + forward-
/// tolerant-enum fix (only the bad element is dropped / degraded).
@MainActor
@Suite("SessionStore lenient element decode (issue #477)")
struct SessionStoreLenientDecodeTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "rapid.tests.lenient-decode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func loadStore(
        with body: Data,
        defaults: UserDefaults
    ) async -> (store: SessionStore, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-lenient-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let tmp = parent.appendingPathComponent("sessions.json")
        try? body.write(to: tmp, options: [.atomic])
        let store = SessionStore(customStoreURL: tmp, customDefaults: defaults)
        await store.awaitInitialLoad()
        return (store, parent)
    }

    private func cleanup(_ parent: URL) {
        try? FileManager.default.removeItem(at: parent)
    }

    /// A syntactically valid message row.
    private func message(id: UUID, role: String, status: String = "complete") -> String {
        """
        {
          "id": "\(id.uuidString)",
          "role": "\(role)",
          "content": "hello",
          "reasoning": "",
          "status": "\(status)",
          "createdAt": "2026-06-26T00:00:00Z"
        }
        """
    }

    /// A syntactically valid session row wrapping the given message JSON.
    private func session(id: UUID, title: String, messages: [String]) -> String {
        """
        {
          "id": "\(id.uuidString)",
          "alias": "qwen3.5-4b",
          "title": "\(title)",
          "isPinned": false,
          "messages": [ \(messages.joined(separator: ",")) ],
          "createdAt": "2026-06-26T00:00:00Z",
          "updatedAt": "2026-06-26T00:00:00Z"
        }
        """
    }

    // MARK: - Step-0 repro (a): forward-incompatible enum value

    @Test("(a) one forward-incompatible message role does NOT wipe the library")
    func forwardIncompatibleRoleKeepsAllSessions() async throws {
        let s0 = UUID(), s1 = UUID(), s2 = UUID()
        // session[1].messages[0] carries a role a NEWER build might add
        // ("function") — the closed pre-fix enum threw on it and lost
        // every session. The forward-tolerant enum maps it to `.unknown`
        // so the row survives (degraded) and all three sessions remain.
        let envelope = Data("""
        {
          "sessions": [
            \(session(id: s0, title: "First", messages: [message(id: UUID(), role: "user")])),
            \(session(id: s1, title: "Second", messages: [message(id: UUID(), role: "function")])),
            \(session(id: s2, title: "Third", messages: [message(id: UUID(), role: "assistant")]))
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        #expect(store.sessions.count == 3,
                "a forward-incompatible role must NOT discard the whole library")
        let ids = Set(store.sessions.map(\.id))
        #expect(ids == [s0, s1, s2])
        // The degraded row is preserved (not dropped) as `.unknown`.
        let second = try #require(store.sessions.first(where: { $0.id == s1 }))
        #expect(second.messages.count == 1)
        #expect(second.messages.first?.role == .unknown)
    }

    @Test("(a') one forward-incompatible message status decodes to .unknown, all sessions survive")
    func forwardIncompatibleStatusKeepsAllSessions() async throws {
        let s0 = UUID(), s1 = UUID()
        let envelope = Data("""
        {
          "sessions": [
            \(session(id: s0, title: "First", messages: [message(id: UUID(), role: "assistant")])),
            \(session(id: s1, title: "Second",
                       messages: [message(id: UUID(), role: "assistant", status: "queued")]))
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        #expect(store.sessions.count == 2)
        let second = try #require(store.sessions.first(where: { $0.id == s1 }))
        #expect(second.messages.first?.status == .unknown)
    }

    // MARK: - Step-0 repro (b): malformed session (missing required field)

    @Test("(b) one malformed session is dropped; the rest survive")
    func malformedSessionDropsOnlyItself() async throws {
        let s0 = UUID(), s1 = UUID(), s2 = UUID()
        // session[1] is missing the required `createdAt` field — the
        // enum-tolerance can't salvage a missing non-enum field, so the
        // element-level decode drops just that session. Pre-fix, the
        // synthesized array decode was all-or-nothing → 0 survivors.
        let envelope = Data("""
        {
          "sessions": [
            \(session(id: s0, title: "First", messages: [message(id: UUID(), role: "user")])),
            {
              "id": "\(s1.uuidString)",
              "alias": "qwen3.5-4b",
              "title": "Malformed",
              "isPinned": false,
              "messages": [],
              "updatedAt": "2026-06-26T00:00:00Z"
            },
            \(session(id: s2, title: "Third", messages: [message(id: UUID(), role: "assistant")]))
          ]
        }
        """.utf8)
        let defaults = makeDefaults()
        let (store, parent) = await loadStore(with: envelope, defaults: defaults)
        defer { cleanup(parent) }

        #expect(store.sessions.count == 2,
                "one malformed session must not lose the other two")
        let ids = Set(store.sessions.map(\.id))
        #expect(ids == [s0, s2])
        #expect(!ids.contains(s1))
    }
}
