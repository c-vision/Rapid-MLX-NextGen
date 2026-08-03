import Foundation
import Testing
@testable import Rapid

/// Contract for ``MCPConsentStore`` — the record of which local (stdio)
/// connector commands the user has explicitly allowed to run. Everything is
/// pumped through an isolated ``UserDefaults`` so no test touches the real
/// approval set.
@Suite("MCP consent store")
struct MCPConsentStoreTests {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "mcp-consent-test-\(UUID().uuidString)")!
    }

    @Test("A remote connector needs no approval — nothing execs locally")
    func remoteNeverGated() {
        let d = isolatedDefaults()
        let remote = MCPServerConfig(name: "r", transport: .sse, url: "https://x/sse", enabled: true)
        #expect(MCPConsentStore.commandFingerprint(remote) == nil)
        #expect(MCPConsentStore.isLaunchApproved(remote, defaults: d))
    }

    @Test("A command-less stdio draft has no fingerprint and doesn't block")
    func commandlessDraftNotGated() {
        let d = isolatedDefaults()
        let blank = MCPServerConfig(name: "s", transport: .stdio, command: nil)
        let empty = MCPServerConfig(name: "s", transport: .stdio, command: "   ")
        #expect(MCPConsentStore.commandFingerprint(blank) == nil)
        #expect(MCPConsentStore.commandFingerprint(empty) == nil)
        #expect(MCPConsentStore.isLaunchApproved(blank, defaults: d))
        #expect(MCPConsentStore.isLaunchApproved(empty, defaults: d))
    }

    @Test("A local command is unapproved until explicitly approved")
    func localGatedUntilApproved() {
        let d = isolatedDefaults()
        let s = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], enabled: true)
        #expect(!MCPConsentStore.isLaunchApproved(s, defaults: d))
        MCPConsentStore.approve(s, defaults: d)
        #expect(MCPConsentStore.isLaunchApproved(s, defaults: d))
    }

    @Test("Approval is keyed to command + args, not name — editing the command revokes it")
    func approvalKeyedToCommandNotName() {
        let d = isolatedDefaults()
        let original = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "server", "/tmp"], enabled: true)
        MCPConsentStore.approve(original, defaults: d)
        #expect(MCPConsentStore.isLaunchApproved(original, defaults: d))

        // Same NAME, but the args changed from /tmp to / — a materially
        // different command. Approval must NOT carry over.
        let edited = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "server", "/"], enabled: true)
        #expect(!MCPConsentStore.isLaunchApproved(edited, defaults: d))
    }

    @Test("Editing an env value revokes approval — a rogue NODE_OPTIONS needs new consent")
    func approvalKeyedToEnvValue() {
        let d = isolatedDefaults()
        let original = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], env: ["API_KEY": "abc"], enabled: true)
        MCPConsentStore.approve(original, defaults: d)
        #expect(MCPConsentStore.isLaunchApproved(original, defaults: d))

        // Same command + args, but env now injects an execution-changing var.
        let tampered = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], env: ["API_KEY": "abc", "NODE_OPTIONS": "--require /tmp/evil.js"], enabled: true)
        #expect(!MCPConsentStore.isLaunchApproved(tampered, defaults: d))
    }

    @Test("Length-prefixed encoding is injective even with embedded separators")
    func injectiveWithEmbeddedSeparators() {
        // Netstring length-prefixing means no field content can forge a
        // boundary. `["a\0b","c"]` and `["a","b\0c"]` (which a naive
        // NUL-delimited scheme would collide) map to distinct material.
        let a = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["a\u{0}b", "c"], enabled: true)
        let b = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["a", "b\u{0}c"], enabled: true)
        #expect(MCPConsentStore.commandFingerprint(a) != MCPConsentStore.commandFingerprint(b))
        // A ':' in a value (the netstring separator) also can't forge a field.
        let c = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["3:abc"], enabled: true)
        let d = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["", "abc"], enabled: true)
        #expect(MCPConsentStore.commandFingerprint(c) != MCPConsentStore.commandFingerprint(d))
    }

    @Test("Env order doesn't matter — same pairs in any order share one fingerprint")
    func envOrderInsensitive() {
        let a = MCPServerConfig(name: "s", transport: .stdio, command: "c", env: ["B": "2", "A": "1"], enabled: true)
        let b = MCPServerConfig(name: "s", transport: .stdio, command: "c", env: ["A": "1", "B": "2"], enabled: true)
        #expect(MCPConsentStore.commandFingerprint(a) == MCPConsentStore.commandFingerprint(b))
    }

    @Test("Fingerprint is a hash, not the raw command — no secret env value leaks into the store")
    func fingerprintIsOpaqueHash() {
        let secret = "super-secret-api-key-value"
        let s = MCPServerConfig(name: "s", transport: .stdio, command: "npx", env: ["API_KEY": secret], enabled: true)
        let fp = MCPConsentStore.commandFingerprint(s)
        #expect(fp != nil)
        // SHA-256 hex is 64 chars and must not contain the plaintext secret.
        #expect(fp?.count == 64)
        #expect(fp?.contains(secret) == false)
        #expect(fp?.contains("npx") == false)
    }

    @Test("Approval survives a rename — same command under a new name stays approved")
    func approvalSurvivesRename() {
        let d = isolatedDefaults()
        let original = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], enabled: true)
        MCPConsentStore.approve(original, defaults: d)
        let renamed = MCPServerConfig(name: "files", transport: .stdio, command: "npx", args: ["-y", "x"], enabled: true)
        #expect(MCPConsentStore.isLaunchApproved(renamed, defaults: d))
    }

    @Test("NUL join keeps [\"a b\"] and [\"a\",\"b\"] from colliding")
    func argSplitDoesNotCollide() {
        let joined = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["a b"], enabled: true)
        let split = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["a", "b"], enabled: true)
        #expect(MCPConsentStore.commandFingerprint(joined) != MCPConsentStore.commandFingerprint(split))
    }

    @Test("Fingerprint is injective across arg count: [] vs [\"\"] vs [\"\",\"\"] all differ")
    func argCountIsInjective() {
        let none = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: [], enabled: true)
        let oneEmpty = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: [""], enabled: true)
        let twoEmpty = MCPServerConfig(name: "s", transport: .stdio, command: "c", args: ["", ""], enabled: true)
        let a = MCPConsentStore.commandFingerprint(none)
        let b = MCPConsentStore.commandFingerprint(oneEmpty)
        let c = MCPConsentStore.commandFingerprint(twoEmpty)
        #expect(a != b)
        #expect(b != c)
        #expect(a != c)
        // And approving the empty-arg form must NOT authorize the [""] form.
        let d = isolatedDefaults()
        MCPConsentStore.approve(none, defaults: d)
        #expect(MCPConsentStore.isLaunchApproved(none, defaults: d))
        #expect(!MCPConsentStore.isLaunchApproved(oneEmpty, defaults: d))
    }

    @Test("Approving is idempotent — the set doesn't grow on re-approval")
    func approveIsIdempotent() {
        let d = isolatedDefaults()
        let s = MCPServerConfig(name: "fs", transport: .stdio, command: "npx", args: ["-y", "x"], enabled: true)
        MCPConsentStore.approve(s, defaults: d)
        MCPConsentStore.approve(s, defaults: d)
        #expect(MCPConsentStore.approvedSet(d).count == 1)
    }
}
