import Foundation
import Testing
@testable import Rapid

/// Contract for reading/writing ``mcp.json``, the launch gate, and the
/// stateless MCP HTTP client's pure helpers. Everything here is injectable
/// (temp ``$HOME``, isolated ``UserDefaults``) so no test touches the real
/// config or the real server.
@Suite("MCP store + launch gate + client helpers")
struct MCPStoreAndClientTests {

    private func tempHome() -> (env: [String: String], home: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcp-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (["HOME": base.path], base)
    }

    // MARK: - Store path resolution

    @Test("configURL resolves under $HOME/.config/rapid-mlx, honouring the override")
    func configURLHonoursHome() {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = MCPConfigStore.configURL(environment: env)
        #expect(url?.path == home.appendingPathComponent(".config/rapid-mlx/mcp.json").path)
    }

    @Test("configURL is nil when HOME is unset or relative")
    func configURLNilWithoutHome() {
        #expect(MCPConfigStore.configURL(environment: [:]) == nil)
        #expect(MCPConfigStore.configURL(environment: ["HOME": "relative/path"]) == nil)
    }

    // MARK: - Store round-trip + perms

    @Test("Absent file loads as an empty config, not an error")
    func loadAbsentIsEmpty() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = try MCPConfigStore.load(environment: env)
        #expect(config.servers.isEmpty)
    }

    @Test("save then load round-trips, and the file is 0600")
    func saveLoadAndPerms() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = MCPConfig(servers: [
            MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"]),
        ])
        let url = try MCPConfigStore.save(config, environment: env)

        let reloaded = try MCPConfigStore.load(environment: env)
        #expect(reloaded == config)

        // Secrets live in this file (engine has no ${VAR} expansion), so it
        // must be owner-only.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test("save creates the parent directory when missing")
    func saveCreatesParentDir() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Nothing exists yet under HOME/.config.
        _ = try MCPConfigStore.save(MCPConfig(), environment: env)
        let dir = home.appendingPathComponent(".config/rapid-mlx", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("load throws (not silently discards) on a corrupt existing file")
    func loadCorruptThrows() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".config/rapid-mlx", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("mcp.json"))
        #expect(throws: (any Error).self) {
            _ = try MCPConfigStore.load(environment: env)
        }
    }

    // MARK: - Launch gate

    private func isolatedDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "mcp-gate-test-\(UUID().uuidString)")!
        return d
    }

    @Test("Gate omits --mcp-config when MCP is disabled (the default)")
    func gateDisabledByDefault() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        // Even with an enabled server on disk, a disabled master toggle wins.
        _ = try MCPConfigStore.save(
            MCPConfig(servers: [MCPServerConfig(name: "fs", transport: .stdio, command: "npx", enabled: true)]),
            environment: env
        )
        #expect(MCPLaunchGate.isEnabled(defaults: defaults) == false)
        #expect(MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env) == nil)
    }

    @Test("Gate omits --mcp-config when enabled but no server is enabled")
    func gateEnabledNoServers() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        _ = try MCPConfigStore.save(
            MCPConfig(servers: [MCPServerConfig(name: "fs", transport: .stdio, command: "npx", enabled: false)]),
            environment: env
        )
        #expect(MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env) == nil)
    }

    @Test("Gate returns the config path when enabled with ≥1 approved enabled server")
    func gateEnabledWithServer() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        let fs = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", enabled: true)
        // A local command must be approved before the gate will launch it —
        // that's the whole point of the consent step in the Connectors UI.
        MCPConsentStore.approve(fs, defaults: defaults)
        _ = try MCPConfigStore.save(MCPConfig(servers: [fs]), environment: env)
        let path = MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env)
        #expect(path == MCPConfigStore.configURL(environment: env)?.path)
    }

    @Test("Gate withholds the flag while an enabled local connector is unapproved")
    func gateWithholdsUnapprovedLocal() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        // Enabled on disk (a past CLI session, a hand-edited file) but the
        // command was never approved here → refuse to launch anything.
        _ = try MCPConfigStore.save(
            MCPConfig(servers: [MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], enabled: true)]),
            environment: env
        )
        #expect(MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env) == nil)
    }

    @Test("Gate withholds if ANY enabled local connector is unapproved, even beside an approved one")
    func gateWithholdsWhenAnyLocalUnapproved() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        let approved = MCPServerConfig(name: "a-fs", transport: .stdio, command: "npx", args: ["-y", "ok"], enabled: true)
        let unapproved = MCPServerConfig(name: "b-db", transport: .stdio, command: "uvx", args: ["db"], enabled: true)
        MCPConsentStore.approve(approved, defaults: defaults)
        _ = try MCPConfigStore.save(MCPConfig(servers: [approved, unapproved]), environment: env)
        // The whole flag is withheld — we don't silently launch a filtered
        // subset. The on-disk file stays the single source of truth.
        #expect(MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env) == nil)
    }

    @Test("Gate launches enabled REMOTE connectors with no approval — nothing execs locally")
    func gateRemoteNeedsNoApproval() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        _ = try MCPConfigStore.save(
            MCPConfig(servers: [MCPServerConfig(name: "remote", transport: .sse, url: "https://mcp.example.com/sse", enabled: true)]),
            environment: env
        )
        let path = MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env)
        #expect(path == MCPConfigStore.configURL(environment: env)?.path)
    }

    @Test("A disabled unapproved local connector doesn't block an approved sibling")
    func gateIgnoresDisabledUnapproved() throws {
        let (env, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: MCPLaunchGate.enabledDefaultsKey)
        let on = MCPServerConfig(name: "a-on", transport: .stdio, command: "npx", args: ["ok"], enabled: true)
        let offUnapproved = MCPServerConfig(name: "b-off", transport: .stdio, command: "uvx", args: ["db"], enabled: false)
        MCPConsentStore.approve(on, defaults: defaults)
        _ = try MCPConfigStore.save(MCPConfig(servers: [on, offUnapproved]), environment: env)
        // Only ENABLED connectors are gated; a disabled one never execs.
        let path = MCPLaunchGate.configPathForLaunch(defaults: defaults, environment: env)
        #expect(path == MCPConfigStore.configURL(environment: env)?.path)
    }

    // MARK: - serveArguments appends --mcp-config only when a path is given

    @Test("serveArguments omits --mcp-config by default, appends it last when set")
    func serveArgumentsMCPFlag() {
        let base = ServerManager.serveArguments(alias: "qwen3-4b", host: "127.0.0.1", port: 8000)
        #expect(!base.contains("--mcp-config"))

        let withMCP = ServerManager.serveArguments(
            alias: "qwen3-4b", host: "127.0.0.1", port: 8000,
            mcpConfigPath: "/home/u/.config/rapid-mlx/mcp.json"
        )
        #expect(withMCP.contains("--mcp-config"))
        // Must trail the argv so --cors-origins' nargs="+" can't swallow it.
        #expect(withMCP.last == "/home/u/.config/rapid-mlx/mcp.json")
        #expect(withMCP[withMCP.count - 2] == "--mcp-config")
    }

    // MARK: - Client helpers

    @Test("parseArguments: empty is a no-arg call, malformed/non-object is invalid")
    func parseArguments() {
        // Empty → a legitimate no-argument call.
        #expect(MCPClient.parseArguments("") == .empty)
        #expect(MCPClient.parseArguments("   ") == .empty)
        // Malformed / non-object → invalid (must NOT be executed as {}).
        #expect(MCPClient.parseArguments("not json") == .invalid)
        #expect(MCPClient.parseArguments("[1,2]") == .invalid)
        #expect(MCPClient.parseArguments("42") == .invalid)
        // A real object is preserved verbatim.
        #expect(MCPClient.parseArguments("{\"location\":\"NYC\"}")
            == .object(.object(["location": .string("NYC")])))
    }

    @Test("flatten: strings pass through, structures become compact JSON")
    func flatten() {
        #expect(MCPClient.flatten(.string("hello")) == "hello")
        #expect(MCPClient.flatten(nil) == "")
        let flat = MCPClient.flatten(.object(["ok": .bool(true)]))
        #expect(flat.contains("\"ok\""))
        #expect(flat.contains("true"))
    }

    @Test("MCPToolInfo maps to an OpenAI tool definition, name verbatim")
    func toolInfoMapsToDefinition() {
        let info = MCPToolInfo(
            name: "filesystem__read_file",
            description: "Read a file",
            server: "filesystem",
            parameters: .object(["type": .string("object")])
        )
        let def = info.toolDefinition
        #expect(def.type == "function")
        #expect(def.function.name == "filesystem__read_file")
        #expect(def.function.description == "Read a file")
    }
}
