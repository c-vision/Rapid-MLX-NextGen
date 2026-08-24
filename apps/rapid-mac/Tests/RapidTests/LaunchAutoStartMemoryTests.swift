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

    @MainActor
    @Test("parked warning re-samples the injected probe in both directions")
    func parkedWarningRefreshesFromInjectedProbe() async throws {
        let gib = UInt64(1_073_741_824)
        let snapshots = LockedMemorySnapshots(
            .init(totalBytes: 32 * gib, usedBytes: 30 * gib)
        )
        let server = ServerManager(
            testingState: .idle,
            binaryPath: URL(fileURLWithPath: "/usr/bin/true")
        )
        server.memorySnapshotProvider = { snapshots.current }

        await server.start(alias: "qwen3.5-9b-4bit")
        let originalID = try #require(server.pendingMemoryWarning?.id)
        #expect(server.pendingMemoryWarning?.severity == .unsafe)

        snapshots.current = .init(totalBytes: 32 * gib, usedBytes: 16 * gib)
        let becameTight = await server.refreshPendingMemoryWarning()
        #expect(becameTight?.old == .unsafe)
        #expect(becameTight?.new == .tight)
        #expect(server.pendingMemoryWarning?.confirmTitle == "Load model")

        snapshots.current = .init(totalBytes: 32 * gib, usedBytes: 2 * gib)
        let becameSafe = await server.refreshPendingMemoryWarning()
        #expect(becameSafe?.old == .tight)
        #expect(becameSafe?.new == .safe)
        #expect(server.pendingMemoryWarning?.id == originalID)
        #expect(server.pendingMemoryWarning?.confirmTitle == "Load model")

        snapshots.current = .init(totalBytes: 32 * gib, usedBytes: 30 * gib)
        let becameUnsafe = await server.refreshPendingMemoryWarning()
        #expect(becameUnsafe?.old == .safe)
        #expect(becameUnsafe?.new == .unsafe)
        #expect(server.pendingMemoryWarning?.id == originalID)
    }

    @MainActor
    @Test("a newly-safe Load action rechecks memory at activation")
    func safeActionDoesNotBecomeAStaleBypass() async throws {
        let gib = UInt64(1_073_741_824)
        let snapshots = LockedMemorySnapshots(
            .init(totalBytes: 32 * gib, usedBytes: 30 * gib)
        )
        let server = ServerManager(
            testingState: .idle,
            binaryPath: URL(fileURLWithPath: "/usr/bin/true")
        )
        server.memorySnapshotProvider = { snapshots.current }

        await server.start(alias: "qwen3.5-9b-4bit")
        let originalID = try #require(server.pendingMemoryWarning?.id)
        snapshots.current = .init(totalBytes: 32 * gib, usedBytes: 2 * gib)
        _ = await server.refreshPendingMemoryWarning()
        let safeWarning = try #require(server.pendingMemoryWarning)
        #expect(safeWarning.severity == .safe)

        // Pressure returns after the last visible sample but before the user
        // clicks. The ordinary Load action must not carry a stale waiver.
        snapshots.current = .init(totalBytes: 32 * gib, usedBytes: 30 * gib)
        server.confirmPendingMemoryLoad(safeWarning)
        for _ in 0 ..< 100 where server.pendingMemoryWarning == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rechecked = try #require(server.pendingMemoryWarning)
        #expect(rechecked.severity == .unsafe)
        #expect(rechecked.id != originalID)
    }
}

private final class LockedMemorySnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MemoryProbe.Snapshot

    init(_ value: MemoryProbe.Snapshot) {
        self.value = value
    }

    var current: MemoryProbe.Snapshot {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
