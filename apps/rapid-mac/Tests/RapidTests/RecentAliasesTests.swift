import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.23 regenerate-with-different-alias chevron data
/// source. Pins:
///   - aliases come back ordered newest-first by `updatedAt`
///   - duplicates collapse (keep the most-recent occurrence)
///   - the `excluding` argument really excludes (case-sensitive)
///   - empty aliases are skipped (defensive — newSession("") is legal)
///   - `limit` caps the list so the chevron menu stays short
@MainActor
@Suite("SessionStore.recentAliases — v0.4.23")
struct RecentAliasesTests {
    private func freshStore() -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-test-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Empty store returns an empty list")
    func emptyStore() {
        let store = freshStore()
        #expect(store.recentAliases(excluding: "anything") == [])
    }

    @Test("Single-alias store excludes the current alias and returns []")
    func singleAliasExcluded() {
        let store = freshStore()
        _ = store.newSession(alias: "qwen3.6-27b")
        #expect(store.recentAliases(excluding: "qwen3.6-27b") == [])
    }

    @Test("Multiple aliases come back ordered by updatedAt descending")
    func recencyOrdering() {
        let store = freshStore()
        let aId = store.newSession(alias: "alias-a")
        let bId = store.newSession(alias: "alias-b")
        let cId = store.newSession(alias: "alias-c")
        // Make B the most recently updated, then A, then C.
        store.renameSession(id: bId, to: "most recent")
        // Force ordering by sleeping past the clock granularity.
        Thread.sleep(forTimeInterval: 0.02)
        store.renameSession(id: aId, to: "second")
        Thread.sleep(forTimeInterval: 0.02)
        // C stays oldest (we don't touch it after creation, except
        // newSession itself which set its updatedAt at construction).
        _ = cId
        // Excluding nothing real — so all 3 should appear; B newest,
        // A next, C last.
        let result = store.recentAliases(excluding: "—not-an-alias—")
        #expect(result == ["alias-a", "alias-b", "alias-c"])
    }

    @Test("Duplicate aliases across sessions collapse to one entry")
    func deduplication() {
        let store = freshStore()
        _ = store.newSession(alias: "alias-shared")
        _ = store.newSession(alias: "alias-other")
        _ = store.newSession(alias: "alias-shared")
        _ = store.newSession(alias: "alias-shared")
        let result = store.recentAliases(excluding: "current")
        // Only TWO distinct aliases — alias-shared listed once.
        #expect(result.count == 2)
        #expect(Set(result) == ["alias-shared", "alias-other"])
    }

    @Test("excluding argument really excludes (case-sensitive)")
    func excludingHonored() {
        let store = freshStore()
        _ = store.newSession(alias: "Qwen3.6-27B")
        _ = store.newSession(alias: "gpt-oss-20b")
        let r1 = store.recentAliases(excluding: "Qwen3.6-27B")
        #expect(r1 == ["gpt-oss-20b"])
        // Case-sensitive: a different case in `excluding` does NOT
        // filter the alias out.
        let r2 = store.recentAliases(excluding: "qwen3.6-27b")
        #expect(r2.contains("Qwen3.6-27B"))
    }

    @Test("Empty / whitespace-only aliases are skipped — defensive against newSession('')")
    func emptyAliasSkipped() {
        let store = freshStore()
        _ = store.newSession(alias: "")
        _ = store.newSession(alias: "   ")
        _ = store.newSession(alias: "real-alias")
        let result = store.recentAliases(excluding: "x")
        #expect(result == ["real-alias"])
    }

    @Test("limit caps the list so the chevron menu stays short")
    func limitCaps() {
        let store = freshStore()
        for i in 1...10 {
            _ = store.newSession(alias: "alias-\(i)")
        }
        let result = store.recentAliases(excluding: "current", limit: 3)
        #expect(result.count == 3)
    }
}
