import Foundation
import Testing
@testable import Rapid

/// Contract for the Connectors editor's pure logic — draft assembly and
/// the Add/Save gate. These are the load-bearing bits: draft assembly is
/// what the consent screen renders (so it must equal what saves), and the
/// gate is what stops a colliding or structurally-invalid connector from
/// reaching the engine's name-keyed ``mcp.json`` map.
@Suite("MCP connectors editor logic")
struct MCPConnectorsPanelTests {

    // MARK: - Draft assembly (consent == what saves)

    @Test("Local draft drops empty args and blank-key env; keeps order")
    func assemblesLocalDraft() {
        let draft = MCPServerEditorSheet.assembleDraft(
            name: "  filesystem  ",
            transport: .stdio,
            command: "  npx  ",
            argTexts: ["-y", "", "@modelcontextprotocol/server-filesystem", "/tmp"],
            envPairs: [("API_KEY", "secret"), ("  ", "orphan"), ("EMPTY_OK", "")],
            url: "ignored-for-stdio",
            enabled: true,
            timeout: 30
        )
        #expect(draft.name == "filesystem")
        #expect(draft.command == "npx")
        // The empty middle token is dropped so the consent line matches
        // exactly what runs. (Collection == is hoisted to a Bool so the
        // #expect diagnostic capture stays simple.)
        let argsMatch = draft.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        #expect(argsMatch)
        // Blank-key env pair dropped; empty *value* preserved.
        let envMatch = draft.env == ["API_KEY": "secret", "EMPTY_OK": ""]
        #expect(envMatch)
        // A Local server never carries a URL even if the field had text.
        #expect(draft.url == nil)
        // The consent line is exactly what will run.
        #expect(draft.displayCommandLine == "npx -y @modelcontextprotocol/server-filesystem /tmp")
    }

    @Test("Remote draft drops command/args/env; keeps only the URL")
    func assemblesRemoteDraft() {
        let draft = MCPServerEditorSheet.assembleDraft(
            name: "web",
            transport: .sse,
            command: "should-not-survive",
            argTexts: ["x", "y"],
            envPairs: [("K", "V")],
            url: "  https://example.com/mcp  ",
            enabled: false,
            timeout: 45
        )
        #expect(draft.transport == .sse)
        #expect(draft.url == "https://example.com/mcp")
        #expect(draft.command == nil)
        #expect(draft.args.isEmpty)
        #expect(draft.env.isEmpty)
        #expect(draft.enabled == false)
        #expect(draft.timeout == 45)
        // sse has no command line to show on the consent screen.
        #expect(draft.displayCommandLine == nil)
    }

    // MARK: - Add/Save gate

    @Test("A valid Local connector is saveable")
    func validLocalPasses() {
        let draft = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"])
        #expect(MCPServerEditorSheet.blockingReason(draft: draft, mode: .add, existingNames: []) == nil)
    }

    @Test("Structural validation errors surface verbatim")
    func structuralErrorsSurface() {
        // No command → the model's own validationError wins.
        let noCmd = MCPServerConfig(name: "x", transport: .stdio, command: nil)
        #expect(MCPServerEditorSheet.blockingReason(draft: noCmd, mode: .add, existingNames: []) != nil)
        // Bad SSE scheme.
        let badURL = MCPServerConfig(name: "x", transport: .sse, url: "localhost:3001")
        #expect(MCPServerEditorSheet.blockingReason(draft: badURL, mode: .add, existingNames: []) != nil)
    }

    @Test("Adding a name that already exists (any case) is blocked")
    func duplicateNameBlockedOnAdd() {
        let draft = MCPServerConfig(name: "FileSystem", transport: .stdio, command: "npx")
        let reason = MCPServerEditorSheet.blockingReason(
            draft: draft, mode: .add, existingNames: ["filesystem"]
        )
        #expect(reason != nil)
        #expect(reason?.contains("already exists") == true)
    }

    @Test("Editing a connector without renaming it is not a self-collision")
    func editSameNameAllowed() {
        let draft = MCPServerConfig(name: "filesystem", transport: .stdio, command: "npx")
        // existingNames includes the row being edited; the mode excludes it.
        let reason = MCPServerEditorSheet.blockingReason(
            draft: draft,
            mode: .edit(originalName: "filesystem"),
            existingNames: ["filesystem", "web"]
        )
        #expect(reason == nil)
    }

    @Test("Renaming a connector onto another existing name is blocked")
    func editRenameOntoSiblingBlocked() {
        let draft = MCPServerConfig(name: "web", transport: .stdio, command: "npx")
        let reason = MCPServerEditorSheet.blockingReason(
            draft: draft,
            mode: .edit(originalName: "filesystem"),
            existingNames: ["filesystem", "web"]
        )
        #expect(reason != nil)
    }

    // MARK: - Case-collision load guard

    @Test("A case-only-duplicate name in the loaded config is detected")
    func caseCollisionDetected() {
        let config = MCPConfig(servers: [
            MCPServerConfig(name: "fs", transport: .stdio, command: "npx"),
            MCPServerConfig(name: "FS", transport: .stdio, command: "uvx"),
        ])
        // Returns the colliding (second) name so the panel can name it in the
        // lock message. Which one is reported doesn't matter; that one is.
        #expect(SettingsConnectorsPanel.caseInsensitiveDuplicateName(in: config) == "FS")
    }

    @Test("Distinct names (ignoring case) are not flagged as a collision")
    func noFalseCollision() {
        let config = MCPConfig(servers: [
            MCPServerConfig(name: "fs", transport: .stdio, command: "npx"),
            MCPServerConfig(name: "web", transport: .sse, url: "https://x/sse"),
        ])
        #expect(SettingsConnectorsPanel.caseInsensitiveDuplicateName(in: config) == nil)
    }
}

/// Contract for the ``ServerManager`` MCP status passthrough used by the
/// Connectors panel. With no attached registry (headless test seam) it
/// must return an empty list and never crash — the panel renders that as
/// "no live connectors".
@Suite("ServerManager MCP status passthrough")
@MainActor
struct ServerManagerMCPStatusTests {

    @Test("mcpServerStatuses is empty when no registry is attached")
    func statusesEmptyWithoutRegistry() async {
        let manager = ServerManager(testingState: .idle)
        let statuses = await manager.mcpServerStatuses()
        #expect(statuses.isEmpty)
    }

    @Test("refreshMCPTools is a no-op (no crash) without a registry")
    func refreshToolsNoOpWithoutRegistry() async {
        let manager = ServerManager(testingState: .idle)
        await manager.refreshMCPTools()
        // Reaching here without a trap is the assertion.
        #expect(Bool(true))
    }
}
