import Foundation
import Testing
@testable import Rapid

/// Issue #17 desktop-half + codex r1 P3: ``activeBearer`` must NOT
/// linger in any state where ``child == nil``. Otherwise a follow-up
/// chat attempt (or a diagnostic read) would send a stale secret to
/// whatever process later binds ``activePort``.
///
/// Note: we can't easily drive the real spawn-throws path from a
/// unit test (it would require mocking ``ProcessGroupChild.spawn``,
/// which lives inside ``ServerManager``). Instead we drive the
/// "binary missing → state=.missing without ever spawning" path,
/// which exercises the same invariant: any non-.ready / non-.starting
/// terminal state must have a nil bearer.
@MainActor
@Suite("ServerManager.activeBearer lifecycle (issue #17)")
struct ServerManagerBearerLifecycleTests {

    @Test("fresh ServerManager has nil activeBearer")
    func freshManagerHasNilBearer() {
        let mgr = ServerManager(testingState: .idle)
        #expect(mgr.activeBearer == nil)
    }

    @Test("start() with no binary keeps activeBearer nil (.missing path)")
    func startWithoutBinaryKeepsBearerNil() async {
        // No binaryPath → start() flips state to .missing before any
        // RNG / spawn work. Codex r1 P3 invariant: the bearer must
        // stay nil through every NON-ready terminal state.
        let mgr = ServerManager(testingState: .idle, binaryPath: nil)
        await mgr.start(alias: "qwen3.5-4b")
        #expect(mgr.activeBearer == nil,
                "no-binary path must not publish a bearer; got \(mgr.activeBearer ?? "nil")")
        guard case .missing = mgr.state else {
            Issue.record("expected .missing, got \(mgr.state)")
            return
        }
    }

    @Test("start() with an invalid alias keeps activeBearer nil (.crashed validation path)")
    func startWithInvalidAliasKeepsBearerNil() async {
        // Alias contains a space → fails Self.isValidAlias → state
        // goes .crashed before bearer generation. Same invariant.
        let dummyBinary = URL(fileURLWithPath: "/nonexistent/rapid-mlx")
        let mgr = ServerManager(testingState: .idle, binaryPath: dummyBinary)
        await mgr.start(alias: "bad alias")
        #expect(mgr.activeBearer == nil,
                "invalid-alias path must not publish a bearer; got \(mgr.activeBearer ?? "nil")")
        guard case .crashed = mgr.state else {
            Issue.record("expected .crashed from invalid alias, got \(mgr.state)")
            return
        }
    }
}
