import Foundation
import Testing
@testable import Rapid

/// Coverage for the per-tool-call approval gate (`MCPToolApprovalStore`).
@Suite("MCP tool-call approval")
@MainActor
struct MCPToolApprovalStoreTests {

    /// A fresh, isolated UserDefaults so tests never touch the real domain
    /// or each other. (mirrors the pattern other stores' tests use.)
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "MCPToolApprovalStoreTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("default mode is ask; unknown tool suspends until answered")
    func asksByDefault() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        #expect(store.mode == .ask)
        let task = Task { await store.requestApproval(toolName: "fs__read", connectorName: "fs", argumentsPreview: "{}") }
        // Let the request register the pending prompt.
        while store.pendingRequest == nil { await Task.yield() }
        #expect(store.pendingRequest?.toolName == "fs__read")
        store.answer(.allowOnce)
        let decision = await task.value
        #expect(decision == .allowOnce)
        #expect(store.pendingRequest == nil)
        // allowOnce does NOT persist a whitelist entry.
        #expect(store.alwaysAllowed.isEmpty)
    }

    @Test("auto-approve-all returns allowOnce without prompting")
    func yoloBypassesPrompt() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        store.mode = .autoApproveAll
        let decision = await store.requestApproval(toolName: "x__y", connectorName: "x", argumentsPreview: "{}")
        #expect(decision == .allowOnce)
        #expect(store.pendingRequest == nil)   // never prompted
    }

    @Test("always-allow is remembered and skips future prompts, across instances")
    func alwaysAllowPersists() async {
        let defaults = freshDefaults()
        let store = MCPToolApprovalStore(defaults: defaults)
        let task = Task { await store.requestApproval(toolName: "db__query", connectorName: "db", argumentsPreview: "{}") }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.alwaysAllow)
        #expect(await task.value == .alwaysAllow)
        #expect(store.alwaysAllowed.contains("db__query"))
        // Same tool now auto-approves without a prompt.
        let again = await store.requestApproval(toolName: "db__query", connectorName: "db", argumentsPreview: "{}")
        #expect(again == .allowOnce)
        #expect(store.pendingRequest == nil)
        // A NEW store on the same defaults still remembers it.
        let reborn = MCPToolApprovalStore(defaults: defaults)
        #expect(reborn.alwaysAllowed.contains("db__query"))
    }

    @Test("mode persists across instances")
    func modePersists() {
        let defaults = freshDefaults()
        let store = MCPToolApprovalStore(defaults: defaults)
        store.mode = .autoApproveAll
        let reborn = MCPToolApprovalStore(defaults: defaults)
        #expect(reborn.mode == .autoApproveAll)
    }

    @Test("deny returns deny and remembers nothing")
    func denyIsClean() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        let task = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: "{}") }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.deny)
        #expect(await task.value == .deny)
        #expect(store.alwaysAllowed.isEmpty)
        #expect(store.pendingRequest == nil)
    }

    @Test("a second request while one is pending is denied, not hung")
    func reentrantRequestDenied() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        let first = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: "{}") }
        while store.pendingRequest == nil { await Task.yield() }
        let second = await store.requestApproval(toolName: "c__d", connectorName: "c", argumentsPreview: "{}")
        #expect(second == .deny)               // re-entrant guard
        store.answer(.allowOnce)               // release the first
        #expect(await first.value == .allowOnce)
    }

    @Test("cancelling the awaiting task denies and clears the pending slot")
    func cancellationDenies() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        let task = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: "{}") }
        while store.pendingRequest == nil { await Task.yield() }
        task.cancel()
        #expect(await task.value == .deny)
        // Slot cleared so a later request doesn't hit the re-entrant guard.
        while store.pendingRequest != nil { await Task.yield() }
        #expect(store.pendingRequest == nil)
    }

    @Test("resetAlwaysAllowed clears the whitelist")
    func resetClearsWhitelist() async {
        let defaults = freshDefaults()
        let store = MCPToolApprovalStore(defaults: defaults)
        let task = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: "{}") }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.alwaysAllow)
        _ = await task.value
        #expect(!store.alwaysAllowed.isEmpty)
        store.resetAlwaysAllowed()
        #expect(store.alwaysAllowed.isEmpty)
        #expect(MCPToolApprovalStore(defaults: defaults).alwaysAllowed.isEmpty)
    }

    @Test("connectorName parses the namespaced prefix; bare name yields nil")
    func connectorNameParsing() {
        #expect(MCPToolApprovalStore.connectorName(from: "fs__read_file") == "fs")
        #expect(MCPToolApprovalStore.connectorName(from: "read_file") == nil)
        #expect(MCPToolApprovalStore.connectorName(from: "__leading") == nil)
    }

    @Test("argument preview is single-lined and length-capped")
    func previewFlattensAndCaps() async {
        let store = MCPToolApprovalStore(defaults: freshDefaults())
        let messy = "{\n  \"path\": \"" + String(repeating: "x", count: 500) + "\"\n}"
        let task = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: messy) }
        while store.pendingRequest == nil { await Task.yield() }
        let preview = store.pendingRequest?.argumentsPreview ?? ""
        #expect(!preview.contains("\n"))
        #expect(preview.count <= 201)          // 200 + ellipsis
        #expect(preview.hasSuffix("…"))        // content was truncated
        store.answer(.deny)
        _ = await task.value
    }

    /// Boundary cases for the preview cap (codex r2): content at exactly the
    /// cap keeps every character with NO ellipsis; one char over gets capped
    /// + ellipsis; a whitespace-padded payload still shows its real content
    /// (leading whitespace is skipped before the 200-char budget is spent, so
    /// it never collapses to a lone "…").
    @Test("preview cap boundaries: exact cap, cap+1, and whitespace-prefixed")
    func previewCapBoundaries() async {
        func preview(of raw: String, _ label: String) async -> String {
            let store = MCPToolApprovalStore(defaults: freshDefaults(label))
            let task = Task { await store.requestApproval(toolName: "a__b", connectorName: "a", argumentsPreview: raw) }
            while store.pendingRequest == nil { await Task.yield() }
            let p = store.pendingRequest?.argumentsPreview ?? ""
            store.answer(.deny)
            _ = await task.value
            return p
        }

        let exact = String(repeating: "y", count: 200)
        let atCap = await preview(of: exact, "exact")
        #expect(atCap == exact)                 // no ellipsis at exactly cap
        #expect(!atCap.hasSuffix("…"))

        let over = String(repeating: "z", count: 201)
        let capped = await preview(of: over, "over")
        #expect(capped.count == 201)            // 200 visible + ellipsis
        #expect(capped.hasSuffix("…"))
        #expect(capped.dropLast() == String(repeating: "z", count: 200))

        // 50 leading spaces then real content well under the cap: the content
        // survives intact, no ellipsis, no leading space.
        let padded = String(repeating: " ", count: 50) + "{\"k\":\"v\"}"
        let unpadded = await preview(of: padded, "padded")
        #expect(unpadded == "{\"k\":\"v\"}")
    }
}
