import Foundation
import Testing
@testable import Rapid

/// Coverage for ``CommandApprovalStore`` — the per-invocation approval gate
/// behind ``run_command``. Focuses on the two contracts a user relies on:
/// (1) in the default ``ask`` mode a command suspends until they answer, and
/// (2) the ``autoApproveAll`` "yolo" mode short-circuits without a prompt and
/// persists across launches.
@MainActor
@Suite("CommandApprovalStore")
struct CommandApprovalStoreTests {

    private func freshStore() -> (CommandApprovalStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "rapid.test.cmdapproval.\(UUID().uuidString)")!
        return (CommandApprovalStore(defaults: suite), suite)
    }

    @Test("Default mode is ask")
    func defaultModeIsAsk() {
        let (store, _) = freshStore()
        #expect(store.mode == .ask)
    }

    @Test("Ask mode suspends until answered, then returns the decision")
    func askSuspendsThenResolves() async {
        let (store, _) = freshStore()
        let task = Task { @MainActor in
            await store.requestApproval(command: "ls", workingDirectory: "/tmp")
        }
        while store.pendingRequest == nil { await Task.yield() }
        #expect(store.pendingRequest?.command == "ls")
        #expect(store.pendingRequest?.fullCommand == "ls")
        #expect(store.pendingRequest?.workingDirectory == "/tmp")
        store.answer(.allowOnce)
        let decision = await task.value
        #expect(decision == .allowOnce)
        #expect(store.pendingRequest == nil)
    }

    @Test("The full command is retained untruncated for the approval sheet")
    func fullCommandRetained() async {
        let (store, _) = freshStore()
        // A long command whose destructive tail sits well past the preview cap.
        let long = String(repeating: "echo a; ", count: 100) + "rm -rf important"
        let task = Task { @MainActor in
            await store.requestApproval(command: long, workingDirectory: "/tmp")
        }
        while store.pendingRequest == nil { await Task.yield() }
        // The one-line preview is capped, but the sheet gets every byte so the
        // tail can't be hidden from the user.
        #expect(store.pendingRequest?.fullCommand == long)
        #expect((store.pendingRequest?.command.count ?? .max) < long.count)
        store.answer(.deny)
        _ = await task.value
    }

    @Test("A deny answer resolves to .deny")
    func denyResolves() async {
        let (store, _) = freshStore()
        let task = Task { @MainActor in
            await store.requestApproval(command: "rm -rf /", workingDirectory: "/tmp")
        }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.deny)
        #expect(await task.value == .deny)
    }

    @Test("Auto-approve returns allowOnce without ever prompting")
    func autoApproveSkipsPrompt() async {
        let (store, _) = freshStore()
        store.mode = .autoApproveAll
        let decision = await store.requestApproval(command: "make build", workingDirectory: "/tmp")
        #expect(decision == .allowOnce)
        #expect(store.pendingRequest == nil, "yolo mode must not surface a dialog")
    }

    @Test("Mode is persisted to the backing defaults")
    func modePersists() {
        let suite = UserDefaults(suiteName: "rapid.test.cmdapproval.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        let a = CommandApprovalStore(defaults: suite)
        a.mode = .autoApproveAll
        // A second store reading the same suite sees the persisted choice.
        let b = CommandApprovalStore(defaults: suite)
        #expect(b.mode == .autoApproveAll)
    }

    @Test("A second concurrent request is denied rather than hanging")
    func reentrantRequestDenied() async {
        let (store, _) = freshStore()
        let first = Task { @MainActor in
            await store.requestApproval(command: "first", workingDirectory: "/tmp")
        }
        while store.pendingRequest == nil { await Task.yield() }
        // A second request while one is pending must fail fast.
        let second = await store.requestApproval(command: "second", workingDirectory: "/tmp")
        #expect(second == .deny)
        store.answer(.allowOnce)
        _ = await first.value
    }

    // MARK: - previewLine

    @Test("previewLine flattens interior whitespace and trims edges")
    func previewFlattens() {
        // Each interior whitespace char maps to a single space; leading and
        // trailing whitespace is trimmed.
        let out = CommandApprovalStore.previewLine("  echo\thello world  ")
        #expect(out == "echo hello world")
    }

    @Test("previewLine caps overlong commands with an ellipsis")
    func previewCaps() {
        let long = String(repeating: "a", count: 500)
        let out = CommandApprovalStore.previewLine(long, cap: 10)
        #expect(out == "aaaaaaaaaa…")
    }

    // MARK: - displaySafe

    @Test("displaySafe renders bidi + zero-width scalars as visible escapes")
    func displaySafeEscapesSpoofing() {
        // A right-to-left override (U+202E) can visually reorder a command so a
        // real `rm` hides after a `#`. It must surface as a visible escape.
        let spoof = "echo hi \u{202E}# rm -rf ~"
        let safe = CommandApprovalStore.displaySafe(spoof)
        #expect(!safe.unicodeScalars.contains("\u{202E}"))
        #expect(safe.contains("\\u{202E}"))
        // A zero-width space is likewise made visible.
        #expect(CommandApprovalStore.displaySafe("a\u{200B}b").contains("\\u{200B}"))
        // Ordinary text (incl. tabs / newlines) is preserved verbatim.
        #expect(CommandApprovalStore.displaySafe("ls -la\n\tgrep x") == "ls -la\n\tgrep x")
    }
}
