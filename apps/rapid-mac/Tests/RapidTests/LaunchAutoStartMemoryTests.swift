import Foundation
import Testing

@testable import Rapid

@Suite("Launch auto-start memory guard")
struct LaunchAutoStartMemoryTests {
    @MainActor
    @Test("unsafe launch resume defers silently, explicit Start still warns")
    func launchResumeDoesNotPresentUnsolicitedWarning() async {
        let server = ServerManager(
            testingState: .idle,
            binaryPath: URL(fileURLWithPath: "/usr/bin/true")
        )
        server.memorySnapshotProvider = {
            MemoryProbe.Snapshot(
                totalBytes: 16 * 1_073_741_824,
                usedBytes: 15 * 1_073_741_824
            )
        }

        let alias = "qwen3-235b-4bit"
        await server.start(alias: alias, isLaunchAutoStart: true)

        #expect(server.state == .idle)
        #expect(server.pendingMemoryWarning == nil)
        #expect(server.servingAlias == nil)

        await server.start(alias: alias)

        #expect(server.pendingMemoryWarning?.alias == alias)
        #expect(server.pendingMemoryWarning?.severity == .unsafe)
        #expect(server.servingAlias == nil)
    }
}
