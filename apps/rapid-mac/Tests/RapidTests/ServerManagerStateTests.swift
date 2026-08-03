import Darwin
import Foundation
import Testing
@testable import Rapid

/// State-transition contract for ``ServerManager``. We only test the
/// transitions that are pure (no subprocess, no I/O) — anything that
/// would spawn a real ``rapid-mlx`` belongs in the TestDriver chat
/// smoke against the fake.
@MainActor
@Suite("ServerManager state transitions")
struct ServerManagerStateTests {
    private func waitUntil(
        deadline: Date,
        predicate: () -> Bool
    ) async -> Bool {
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    @Test("ProcessGroupChild spawns the child as its own process-group leader")
    func processGroupSpawnCreatesGroupLeader() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let child = try ProcessGroupChild.spawn(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            standardInput: .nullDevice,
            standardOutput: stdout,
            standardError: stderr
        )
        defer {
            if child.isProcessGroupAlive {
                child.signalProcessGroup(SIGKILL)
            }
        }

        #expect(child.processIdentifier > 0)
        #expect(getpgid(child.processIdentifier) == child.processIdentifier)

        child.signalProcessGroup(SIGTERM)
        let exited = await waitUntil(deadline: Date().addingTimeInterval(3)) {
            !child.isProcessGroupAlive
        }
        #expect(exited)
    }

    @Test("dismissTerminalState: .crashed with a binary path → .idle")
    func dismissCrashedWithBinary() {
        let mgr = ServerManager(
            testingState: .crashed(alias: "fake-alias", message: "boom"),
            binaryPath: URL(fileURLWithPath: "/opt/homebrew/bin/rapid-mlx")
        )
        mgr.dismissTerminalState()
        guard case .idle = mgr.state else {
            Issue.record("expected .idle, got \(mgr.state)")
            return
        }
    }

    @Test("dismissTerminalState: .stopped with a binary path → .idle")
    func dismissStoppedWithBinary() {
        let mgr = ServerManager(
            testingState: .stopped,
            binaryPath: URL(fileURLWithPath: "/opt/homebrew/bin/rapid-mlx")
        )
        mgr.dismissTerminalState()
        guard case .idle = mgr.state else {
            Issue.record("expected .idle, got \(mgr.state)")
            return
        }
    }

    @Test("dismissTerminalState: .crashed without a binary path → .missing (not .idle)")
    func dismissCrashedNoBinary() {
        // Edge case: rapid-mlx was uninstalled mid-session, then it
        // crashed. We should NOT pretend it's now installable — the
        // first-run overlay's recheck button is the right path back.
        let mgr = ServerManager(
            testingState: .crashed(alias: "fake-alias", message: "boom"),
            binaryPath: nil
        )
        mgr.dismissTerminalState()
        guard case .missing = mgr.state else {
            Issue.record("expected .missing, got \(mgr.state)")
            return
        }
    }

    @Test("dismissTerminalState: idempotent on .ready (live state)")
    func dismissNoopOnReady() {
        // Calling dismiss while the server is live must NOT
        // surreptitiously tear down state — that would diverge the
        // SwiftUI view from the actual child process.
        let mgr = ServerManager(
            testingState: .ready(alias: "fake-alias"),
            binaryPath: URL(fileURLWithPath: "/opt/homebrew/bin/rapid-mlx")
        )
        mgr.dismissTerminalState()
        guard case .ready = mgr.state else {
            Issue.record("dismiss should be a no-op on .ready, got \(mgr.state)")
            return
        }
    }

    @Test("dismissTerminalState: idempotent on .starting")
    func dismissNoopOnStarting() {
        let mgr = ServerManager(
            testingState: .starting(alias: "fake-alias"),
            binaryPath: URL(fileURLWithPath: "/opt/homebrew/bin/rapid-mlx")
        )
        mgr.dismissTerminalState()
        guard case .starting = mgr.state else {
            Issue.record("dismiss should be a no-op on .starting, got \(mgr.state)")
            return
        }
    }

    // MARK: - Alias validation (codex audit r1 ServerManager.swift:308)

    @Test("isValidAlias accepts canonical aliases.json shapes")
    func isValidAliasHappyPath() {
        #expect(ServerManager.isValidAlias("qwen3.5-4b-4bit"))
        #expect(ServerManager.isValidAlias("qwen3.6-35b-a3b-mxfp4"))
        #expect(ServerManager.isValidAlias("deepseek-v4-flash-8bit"))
        #expect(ServerManager.isValidAlias("diffusion-gemma-26b-4bit"))
    }

    @Test("isValidAlias rejects leading dash (CLI flag injection)")
    func isValidAliasRejectsLeadingDash() {
        #expect(!ServerManager.isValidAlias("-config"))
        #expect(!ServerManager.isValidAlias("--host"))
        #expect(!ServerManager.isValidAlias("-"))
    }

    @Test("isValidAlias rejects control characters and whitespace")
    func isValidAliasRejectsControlChars() {
        #expect(!ServerManager.isValidAlias("qwen3.5-4b\n--host=evil"))
        #expect(!ServerManager.isValidAlias("qwen3.5-4b\u{1B}[31mred"))
        #expect(!ServerManager.isValidAlias("qwen3.5 4b"))
        #expect(!ServerManager.isValidAlias("\u{7F}"))
    }

    @Test("isValidAlias rejects shell metacharacters")
    func isValidAliasRejectsShellMeta() {
        #expect(!ServerManager.isValidAlias("alias;rm -rf"))
        #expect(!ServerManager.isValidAlias("alias|cat"))
        #expect(!ServerManager.isValidAlias("alias`id`"))
        #expect(!ServerManager.isValidAlias("alias$(id)"))
        #expect(!ServerManager.isValidAlias("alias&background"))
    }

    @Test("isValidAlias rejects empty and over-long")
    func isValidAliasBounds() {
        #expect(!ServerManager.isValidAlias(""))
        #expect(!ServerManager.isValidAlias(String(repeating: "a", count: 129)))
        #expect(ServerManager.isValidAlias(String(repeating: "a", count: 128)))
    }

    @Test("isValidAlias accepts hf-path-shaped values")
    func isValidAliasHFPath() {
        #expect(ServerManager.isValidAlias("mlx-community/Qwen3.5-4B-MLX-4bit"))
        #expect(ServerManager.isValidAlias("prism-ml/bonsai-image-ternary-4B-mlx-2bit"))
    }
}
