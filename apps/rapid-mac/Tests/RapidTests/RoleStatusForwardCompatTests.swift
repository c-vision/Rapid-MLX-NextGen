import Foundation
import Testing
@testable import Rapid

/// Issue #477: ``ChatMessage.Role`` and ``ChatMessage.Status`` are now
/// forward-tolerant closed enums. An unrecognised raw value (a role/status
/// a NEWER build added, decoded on an older one) degrades to ``.unknown``
/// instead of throwing — which is what previously collapsed the whole
/// library load. This suite pins the degrade + the encode round-trip so a
/// future "tighten the enum" refactor can't silently re-introduce the
/// all-or-nothing failure.
@Suite("Role/Status forward-compatibility (issue #477)")
struct RoleStatusForwardCompatTests {

    private func decoder() -> JSONDecoder { JSONDecoder() }
    private func encoder() -> JSONEncoder { JSONEncoder() }

    // MARK: - Role

    @Test("Unknown role string decodes to .unknown (no throw)")
    func unknownRoleDecodes() throws {
        let raw = Data("\"function\"".utf8)
        let role = try decoder().decode(ChatMessage.Role.self, from: raw)
        #expect(role == .unknown)
    }

    @Test("Every known role still decodes to its own case")
    func knownRolesDecode() throws {
        let cases: [(String, ChatMessage.Role)] = [
            ("user", .user), ("assistant", .assistant),
            ("system", .system), ("tool", .tool),
        ]
        for (raw, expected) in cases {
            let decoded = try decoder().decode(ChatMessage.Role.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded == expected)
        }
    }

    @Test("Role.unknown encodes to the stable 'unknown' sentinel and round-trips")
    func roleUnknownRoundTrips() throws {
        let encoded = try encoder().encode(ChatMessage.Role.unknown)
        #expect(String(data: encoded, encoding: .utf8) == "\"unknown\"")
        let back = try decoder().decode(ChatMessage.Role.self, from: encoded)
        #expect(back == .unknown)
    }

    // MARK: - Status

    @Test("Unknown status string decodes to .unknown (no throw)")
    func unknownStatusDecodes() throws {
        let raw = Data("\"queued\"".utf8)
        let status = try decoder().decode(ChatMessage.Status.self, from: raw)
        #expect(status == .unknown)
    }

    @Test("Every known status still decodes to its own case")
    func knownStatusesDecode() throws {
        let cases: [(String, ChatMessage.Status)] = [
            ("complete", .complete), ("streaming", .streaming), ("failed", .failed),
        ]
        for (raw, expected) in cases {
            let decoded = try decoder().decode(ChatMessage.Status.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded == expected)
        }
    }

    @Test("Status.unknown encodes to the stable 'unknown' sentinel and round-trips")
    func statusUnknownRoundTrips() throws {
        let encoded = try encoder().encode(ChatMessage.Status.unknown)
        #expect(String(data: encoded, encoding: .utf8) == "\"unknown\"")
        let back = try decoder().decode(ChatMessage.Status.self, from: encoded)
        #expect(back == .unknown)
    }

    // MARK: - Message-level: a whole ChatMessage with an unknown role/status

    @Test("A ChatMessage carrying an unknown role+status decodes cleanly")
    func messageWithUnknownRoleAndStatusDecodes() throws {
        let d = decoder()
        d.dateDecodingStrategy = .iso8601
        let json = Data("""
        {
          "id": "\(UUID().uuidString)",
          "role": "function",
          "content": "tool output",
          "reasoning": "",
          "status": "queued",
          "createdAt": "2026-06-26T00:00:00Z"
        }
        """.utf8)
        let msg = try d.decode(ChatMessage.self, from: json)
        #expect(msg.role == .unknown)
        #expect(msg.status == .unknown)
        #expect(msg.content == "tool output")
    }

    // MARK: - Wire filter: an unknown-role row must never reach the body

    @Test("filterUnknownRolesForWire drops .unknown rows, keeps the rest")
    @MainActor
    func wireFilterDropsUnknownRoles() {
        let msgs: [ChatMessage] = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .unknown, content: "degraded"),
            ChatMessage(role: .assistant, content: "hello"),
        ]
        let filtered = ChatViewModel.filterUnknownRolesForWire(msgs)
        #expect(filtered.count == 2)
        #expect(!filtered.contains { $0.role == .unknown })
        #expect(filtered.map(\.role) == [.user, .assistant])
    }
}
