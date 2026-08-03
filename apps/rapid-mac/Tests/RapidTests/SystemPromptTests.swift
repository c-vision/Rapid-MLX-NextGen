import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.17 per-session system prompt. Pins:
///   - schema-compat: pre-v0.4.17 envelopes decode with systemPrompt=nil
///   - setSystemPrompt trims whitespace and treats blank as clear
///   - mutator does NOT bump updatedAt (system-prompt edits aren't
///     conversation activity — see SessionStore.setSystemPrompt doc)
///   - round-trip through JSON encode → decode survives non-nil
@MainActor
@Suite("ChatSession + SessionStore — per-session system prompt (v0.4.17)")
struct SystemPromptTests {
    private func freshStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("ChatSession defaults systemPrompt to nil on construction")
    func defaultNil() {
        let s = ChatSession(alias: "fake-alias")
        #expect(s.systemPrompt == nil)
    }

    @Test("Pre-v0.4.17 envelopes (no systemPrompt key) decode with systemPrompt=nil")
    func legacyDecode() throws {
        // Hand-rolled JSON in the v0.4.16 schema shape — no systemPrompt key.
        let legacyJSON = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "title": "Pre-upgrade chat",
            "alias": "qwen3.5-4b",
            "messages": [],
            "createdAt": 770000000.0,
            "updatedAt": 770000000.0,
            "isPinned": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatSession.self, from: legacyJSON)
        #expect(decoded.systemPrompt == nil)
        #expect(decoded.title == "Pre-upgrade chat")
    }

    @Test("setSystemPrompt with non-empty value persists trimmed")
    func setNonEmpty() {
        let store = freshStore()
        let id = store.newSession(alias: "fake-alias")
        store.setSystemPrompt(id: id, "  You are a precise reviewer.  ")
        let session = store.sessions.first(where: { $0.id == id })!
        #expect(session.systemPrompt == "You are a precise reviewer.")
    }

    @Test("setSystemPrompt with blank / whitespace clears to nil")
    func clearOnBlank() {
        let store = freshStore()
        let id = store.newSession(alias: "fake-alias")
        store.setSystemPrompt(id: id, "Real prompt")
        store.setSystemPrompt(id: id, "")
        #expect(store.sessions.first(where: { $0.id == id })?.systemPrompt == nil)

        store.setSystemPrompt(id: id, "Set again")
        store.setSystemPrompt(id: id, "   \n  ")
        #expect(store.sessions.first(where: { $0.id == id })?.systemPrompt == nil)

        store.setSystemPrompt(id: id, "Once more")
        store.setSystemPrompt(id: id, nil)
        #expect(store.sessions.first(where: { $0.id == id })?.systemPrompt == nil)
    }

    @Test("setSystemPrompt does NOT bump updatedAt — config change, not chat activity")
    func doesNotBumpUpdatedAt() {
        let store = freshStore()
        let id = store.newSession(alias: "fake-alias")
        let before = store.sessions.first(where: { $0.id == id })!.updatedAt
        // Give the system clock at least a tick of resolution so a
        // would-be bump would be observable.
        Thread.sleep(forTimeInterval: 0.02)
        store.setSystemPrompt(id: id, "Should not bump recency")
        let after = store.sessions.first(where: { $0.id == id })!.updatedAt
        #expect(before == after)
    }

    @Test("JSON round-trip preserves a populated systemPrompt")
    func roundTrip() throws {
        let session = ChatSession(
            title: "x",
            alias: "fake-alias",
            systemPrompt: "Respond only in bullet points."
        )
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(ChatSession.self, from: data)
        #expect(back.systemPrompt == "Respond only in bullet points.")
    }
}
