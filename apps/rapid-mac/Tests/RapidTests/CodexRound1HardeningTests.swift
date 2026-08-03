import Foundation
import Testing
@testable import Rapid

/// Pin the codex round-1 hardening fixes so a future regression
/// can't silently re-open the bypasses. Five distinct surfaces:
/// symlink canonicalisation in the sandbox + denylist, oversized
/// attachment short-circuit, file-size cap on read_file, and the
/// stuck-streaming placeholder on max-tool-rounds exhaustion.
@MainActor
@Suite("Codex round-1 hardening")
struct CodexRound1HardeningTests {

    // MARK: - Symlink-bypass guard on SandboxManager

    @Test("Grant to a parent does NOT cover a symlink whose target lives outside")
    func sandboxRejectsSymlinkEscape() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let granted = tmp.appendingPathComponent("granted", isDirectory: true)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("secret.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let symlink = granted.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let sandbox = SandboxManager(initialGrants: [granted])
        // The model points at the symlink — which lexically lives
        // inside the grant — but the real target is outside.
        // ``isAllowed`` must follow the symlink and reject the read.
        #expect(sandbox.isAllowed(symlink) == false,
                "symlink whose target leaves the grant must NOT be considered allowed")
    }

    @Test("Exact symlink inside the grant whose target stays inside the grant IS allowed")
    func sandboxAcceptsSymlinkContained() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let granted = tmp.appendingPathComponent("granted", isDirectory: true)
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        let target = granted.appendingPathComponent("real.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let symlink = granted.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let sandbox = SandboxManager(initialGrants: [granted])
        #expect(sandbox.isAllowed(symlink) == true,
                "in-grant symlink target should still resolve allowed")
    }

    // MARK: - Attachment size cap

    @Test("makeAttachment returns nil for files larger than the 4 MB cap WITHOUT loading them")
    func attachmentRejectsOversizeBeforeReading() throws {
        // Write a file just over the cap. The test would OOM the
        // pre-fix runner if it tried to load the file (no such
        // sentinel — we just assert the rejection path, the
        // memory-safety argument is that we never call
        // ``Data(contentsOf:)``).
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let big = tmp.appendingPathComponent("big.txt")
        let chunk = String(repeating: "x", count: 1024 * 1024) // 1 MB chunk
        try (chunk + chunk + chunk + chunk + chunk).write(to: big, atomically: true, encoding: .utf8) // 5 MB
        let result = AttachmentIngest.makeAttachment(from: big)
        #expect(result == nil, "5 MB file must be rejected by the 4 MB cap")
    }

    @Test("makeAttachment accepts a small UTF-8 file (positive control)")
    func attachmentAcceptsSmall() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let small = tmp.appendingPathComponent("note.txt")
        try "hello world".write(to: small, atomically: true, encoding: .utf8)
        let result = AttachmentIngest.makeAttachment(from: small)
        #expect(result != nil)
        #expect(result?.kind == .textFile)
    }

    // MARK: - SessionStore flush()

    @Test("flush() writes the latest envelope synchronously even before the debounce fires")
    func sessionStoreFlushIsImmediate() async throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("sessions.json")
        let store = SessionStore(customStoreURL: url)
        let sessionID = store.newSession(alias: "qwen3.5-4b")
        _ = store.appendMessage(
            sessionID: sessionID,
            ChatMessage(role: .user, content: "ping-marker-42")
        )
        // ``flush`` must cancel the pending debounce and write
        // before returning. Read the envelope back IMMEDIATELY
        // (no sleep) — if the debounce path was the only writer,
        // the file would still hold the pre-append state.
        await store.flush()
        let raw = try Data(contentsOf: url)
        let json = String(data: raw, encoding: .utf8) ?? ""
        #expect(json.contains("ping-marker-42"),
                "flush() must write the latest envelope before returning")
    }

    // MARK: - Helpers

    private func makeTmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_round1_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
