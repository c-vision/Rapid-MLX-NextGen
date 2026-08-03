import Foundation
import Testing
@testable import Rapid

/// Contract for the MCP config model + its serialisation to / from the
/// engine's ``mcp.json`` schema (``vllm_mlx/mcp/config.py``). The wire shape
/// is load-bearing: the desktop writes this file and the bundled engine reads
/// it, so a drift here silently breaks tool loading.
@Suite("MCP config model + wire schema")
struct MCPConfigTests {

    // MARK: - Round-trip to the engine's { servers: { name: {…} } } shape

    @Test("Encodes servers as a name-keyed map, not an array")
    func encodesServersAsMap() throws {
        let config = MCPConfig(servers: [
            MCPServerConfig(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                env: [:],
                enabled: true,
                timeout: 30
            )
        ])
        let data = try JSONEncoder().encode(config)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = try #require(obj?["servers"] as? [String: Any])
        // Keyed by name; the name is NOT a field on the value.
        let fs = try #require(servers["filesystem"] as? [String: Any])
        #expect(fs["command"] as? String == "npx")
        #expect(fs["transport"] as? String == "stdio")
        #expect(fs["name"] == nil, "name must be the map key, not a field")
        #expect(obj?["max_tool_calls"] as? Int == 10)
        #expect(obj?["default_timeout"] as? Double == 30)
    }

    @Test("Decodes the engine's example config, folding the key into name")
    func decodesEngineExample() throws {
        // Verbatim shape from vllm_mlx/mcp/config.py::create_example_config.
        let json = """
        {
          "servers": {
            "filesystem": {
              "transport": "stdio",
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
              "enabled": true,
              "timeout": 30
            },
            "web-search": {
              "transport": "sse",
              "url": "http://localhost:3001/sse",
              "enabled": true,
              "timeout": 60
            }
          },
          "max_tool_calls": 10,
          "default_timeout": 30.0
        }
        """
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
        #expect(config.servers.count == 2)
        // Sorted by name: filesystem before web-search.
        let fs = config.servers[0]
        #expect(fs.name == "filesystem")
        #expect(fs.transport == .stdio)
        #expect(fs.command == "npx")
        #expect(fs.args.count == 3)
        let web = config.servers[1]
        #expect(web.name == "web-search")
        #expect(web.transport == .sse)
        #expect(web.url == "http://localhost:3001/sse")
        #expect(web.timeout == 60)
    }

    @Test("Full round-trip preserves every field")
    func roundTripPreservesFields() throws {
        let original = MCPConfig(
            servers: [
                MCPServerConfig(name: "a", transport: .stdio, command: "uvx",
                                args: ["mcp-server-sqlite", "--db-path", "data.db"],
                                env: ["API_KEY": "secret"], enabled: false, timeout: 45),
                MCPServerConfig(name: "b", transport: .sse, url: "https://example.com/mcp",
                                enabled: true, timeout: 10),
            ],
            maxToolCalls: 7,
            defaultTimeout: 20,
            allowedHighRiskTools: ["a__execute"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("stdio encode omits url; sse encode omits command/args/env")
    func encodeOmitsIrrelevantTransportFields() throws {
        let config = MCPConfig(servers: [
            MCPServerConfig(name: "s", transport: .sse, command: "should-not-appear",
                            args: ["x"], env: ["K": "V"], url: "https://h/mcp"),
        ])
        let data = try JSONEncoder().encode(config)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["servers"] as? [String: Any]
        let s = try #require(servers?["s"] as? [String: Any])
        #expect(s["url"] as? String == "https://h/mcp")
        #expect(s["command"] == nil, "sse server must not emit a command")
        #expect(s["args"] == nil)
        #expect(s["env"] == nil)
    }

    // MARK: - Validation (mirrors engine __post_init__)

    @Test("stdio server without a command is invalid")
    func stdioNeedsCommand() {
        let s = MCPServerConfig(name: "x", transport: .stdio, command: nil)
        #expect(s.validationError != nil)
    }

    @Test("sse server without a url is invalid; bad scheme rejected")
    func sseNeedsURL() {
        #expect(MCPServerConfig(name: "x", transport: .sse, url: nil).validationError != nil)
        #expect(MCPServerConfig(name: "x", transport: .sse, url: "localhost:3001").validationError != nil)
        #expect(MCPServerConfig(name: "x", transport: .sse, url: "https://h/mcp").validationError == nil)
    }

    @Test("empty name is invalid regardless of transport")
    func nameRequired() {
        #expect(MCPServerConfig(name: "  ", transport: .stdio, command: "npx").validationError != nil)
    }

    @Test("A valid stdio server passes validation")
    func validStdioPasses() {
        let s = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"])
        #expect(s.validationError == nil)
    }

    // MARK: - Consent-screen command line (MCP spec: show exact command)

    @Test("displayCommandLine shows the full untruncated command + args")
    func displayCommandLineExact() {
        let s = MCPServerConfig(name: "fs", transport: .stdio, command: "npx",
                                args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        // These tokens are all shell-safe, so they render bare.
        #expect(s.displayCommandLine == "npx -y @modelcontextprotocol/server-filesystem /tmp")
        // sse servers have no command line.
        #expect(MCPServerConfig(name: "r", transport: .sse, url: "https://h").displayCommandLine == nil)
    }

    @Test("displayCommandLine quotes tokens with spaces / empties so boundaries are exact")
    func displayCommandLineQuotesAmbiguousTokens() {
        // Without quoting, ["a b"] and ["a","b"] would render identically and
        // an empty argument would vanish — the consent screen must be exact.
        let s = MCPServerConfig(name: "x", transport: .stdio, command: "python",
                                args: ["/path with space/s.py", "", "--flag=v"])
        #expect(s.displayCommandLine == "python '/path with space/s.py' '' --flag=v")
        // Embedded single quote is escaped the '\'' way.
        #expect(MCPServerConfig.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test("command position is quoted for reserved words / assignments; args stay bare")
    func displayCommandLineQuotesCommandPosition() {
        // A reserved word in command position must be quoted so it reads as a
        // program, not shell grammar.
        let r = MCPServerConfig(name: "x", transport: .stdio, command: "time", args: ["x"])
        #expect(r.displayCommandLine == "'time' x")
        // A command that looks like an assignment must be quoted.
        let a = MCPServerConfig(name: "x", transport: .stdio, command: "FOO=bar", args: [])
        #expect(a.displayCommandLine == "'FOO=bar'")
        // But an ARG that contains '=' (the common --flag=value) stays bare.
        let flag = MCPServerConfig(name: "x", transport: .stdio, command: "npx", args: ["--k=v"])
        #expect(flag.displayCommandLine == "npx --k=v")
    }

    // MARK: - enabledServers

    @Test("enabledServers filters out disabled entries")
    func enabledServersFilters() {
        let config = MCPConfig(servers: [
            MCPServerConfig(name: "on", transport: .stdio, command: "a", enabled: true),
            MCPServerConfig(name: "off", transport: .stdio, command: "b", enabled: false),
        ])
        #expect(config.enabledServers.map(\.name) == ["on"])
    }
}
