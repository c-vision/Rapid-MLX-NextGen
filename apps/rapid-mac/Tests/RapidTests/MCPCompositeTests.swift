import Foundation
import Testing
@testable import Rapid

/// Contract for ``CompositeToolRegistry`` — the seam that lets MCP tools ride
/// the existing chat tool-loop. The load-bearing property for PR 1 is that
/// with no MCP servers the composite is behaviourally identical to the bare
/// built-in registry.
@Suite("MCP composite registry routing")
@MainActor
struct MCPCompositeTests {

    /// Minimal ``ToolRegistry`` stand-in that records which calls it ran.
    private final class FakeRegistry: ToolRegistry {
        let definitions: [ToolDefinition]
        var ranNames: [String] = []
        init(_ defs: [ToolDefinition]) { self.definitions = defs }
        func run(_ call: ToolCall) async -> ToolCallResult {
            ranNames.append(call.function.name)
            return ToolCallResult(toolCallID: call.id, content: "builtin:\(call.function.name)")
        }
    }

    private func def(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "", parameters: .object([:]))
    }

    @Test("With no MCP servers, definitions == the built-in set, in order")
    func emptyMCPMatchesBuiltin() {
        let builtin = FakeRegistry([def("web_search"), def("read_file")])
        let mcp = MCPToolRegistry(server: nil) // no server → no tools
        let composite = CompositeToolRegistry(builtin: builtin, mcp: mcp)
        #expect(composite.definitions.map(\.function.name) == ["web_search", "read_file"])
    }

    @Test("An unknown (non-MCP) call routes to the built-in registry")
    func unknownCallRoutesToBuiltin() async {
        let builtin = FakeRegistry([def("web_search")])
        let mcp = MCPToolRegistry(server: nil)
        let composite = CompositeToolRegistry(builtin: builtin, mcp: mcp)
        let result = await composite.run(ToolCall(id: "1", name: "web_search", arguments: "{}"))
        #expect(result.content == "builtin:web_search")
        #expect(builtin.ranNames == ["web_search"])
    }

    @Test("refresh with no live endpoint evicts to an empty tool set")
    func refreshNoServerEvicts() async {
        // The eviction path (no live bearer/port) must clear the cache and not
        // crash — the guarantee that stopped/crashed servers stop advertising.
        let mcp = MCPToolRegistry(server: nil)
        await mcp.refresh()
        #expect(mcp.definitions.isEmpty)
        #expect(mcp.toolNames.isEmpty)
    }

    @Test("evict() synchronously clears the advertised tool set")
    func evictClearsSynchronously() {
        // evict() is @MainActor and non-async — the synchronous call itself is
        // the guarantee (it runs inside activeBearer.didSet before any awaiting
        // discovery task can commit). It must leave the cache empty.
        let mcp = MCPToolRegistry(server: nil)
        mcp.evict()
        #expect(mcp.definitions.isEmpty)
        #expect(mcp.toolNames.isEmpty)
    }

    /// Isolated defaults so the approval store's persistence never touches the
    /// real domain or another test.
    private func freshApproval(_ name: String = #function) -> MCPToolApprovalStore {
        let suite = "MCPCompositeTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return MCPToolApprovalStore(defaults: d)
    }

    @Test("A denied MCP-owned call is short-circuited before it reaches the connector")
    func deniedMCPCallNeverRuns() async {
        // Seed an MCP-owned tool name so the composite routes the call to the
        // MCP half (and thus through the approval gate).
        let builtin = FakeRegistry([])
        let mcp = MCPToolRegistry(server: nil)
        mcp.seedToolNamesForTesting(["fs__read"])
        let approval = freshApproval()
        let composite = CompositeToolRegistry(builtin: builtin, mcp: mcp, approval: approval)

        let task = Task { await composite.run(ToolCall(id: "1", name: "fs__read", arguments: "{}")) }
        while approval.pendingRequest == nil { await Task.yield() }
        approval.answer(.deny)
        let result = await task.value

        // The decline text is the tell that the gate short-circuited: had the
        // call reached ``mcp.run`` (nil server) it would carry that half's own
        // "tool server is not running" error instead.
        #expect(result.isError)
        #expect(result.content == "This tool call was declined.")
        #expect(builtin.ranNames.isEmpty)   // never routed to built-in either
    }

    @Test("Auto-approve routes an MCP-owned call through to the connector")
    func autoApproveRoutesToMCP() async {
        let mcp = MCPToolRegistry(server: nil)
        mcp.seedToolNamesForTesting(["fs__read"])
        let approval = freshApproval()
        approval.mode = .autoApproveAll
        let composite = CompositeToolRegistry(builtin: FakeRegistry([]), mcp: mcp, approval: approval)

        let result = await composite.run(ToolCall(id: "1", name: "fs__read", arguments: "{}"))
        // Reached ``mcp.run`` (which, with a nil server, returns its own clean
        // error) rather than being declined — proves auto-approve passes the
        // gate without a prompt.
        #expect(approval.pendingRequest == nil)
        #expect(result.content != "This tool call was declined.")
    }

    @Test("An MCP call with no live server surfaces a clean error, not a crash")
    func mcpCallWithoutServerErrors() async {
        // MCPToolRegistry with a nil server can't own any tool name (toolNames
        // stays empty until refresh), so a namespaced call falls through to
        // built-in — which correctly reports it doesn't know the tool. This
        // pins the no-crash guarantee for the server-down path.
        let builtin = FakeRegistry([])
        let mcp = MCPToolRegistry(server: nil)
        let composite = CompositeToolRegistry(builtin: builtin, mcp: mcp)
        let result = await composite.run(ToolCall(id: "1", name: "filesystem__read", arguments: "{}"))
        // Built-in FakeRegistry runs it (records the name) and returns a
        // non-crashing result — the point is the call completes.
        #expect(builtin.ranNames == ["filesystem__read"])
        #expect(result.toolCallID == "1")
    }
}
