import Foundation
import Testing
@testable import Rapid

/// Contract for the per-session FS permission gate. Get any of these
/// wrong and the chat surface either (a) prompts on every single
/// tool call (annoying) or (b) silently grants too much (dangerous).
@MainActor
@Suite("SandboxManager grants")
struct SandboxManagerTests {
    @Test("Granting a folder covers nested files without re-prompting")
    func folderGrantCoversDescendants() async {
        let mgr = SandboxManager(initialGrants: [
            URL(fileURLWithPath: "/Users/test/Documents")
        ])
        #expect(mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Documents/notes.txt")))
        #expect(mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Documents/sub/deep.txt")))
    }

    @Test("Folder grant does NOT cover siblings whose name is a prefix")
    func folderGrantDoesNotPrefixLeak() async {
        // ``/Users/test/Doc`` MUST NOT be covered by a grant to
        // ``/Users/test/Documents``. Without the trailing-slash
        // guard, ``hasPrefix`` would mis-match.
        let mgr = SandboxManager(initialGrants: [
            URL(fileURLWithPath: "/Users/test/Documents")
        ])
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/DocumentsBackup/whatever.txt")))
    }

    @Test("Once grant covers only the exact path")
    func onceGrantIsExact() async {
        let mgr = SandboxManager(initialGrants: [
            URL(fileURLWithPath: "/Users/test/Notes/secret.md")
        ])
        #expect(mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Notes/secret.md")))
        // Sibling file in the same dir is NOT covered.
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Notes/other.md")))
    }

    @Test("Allow-once decision grants the requested path on resume")
    func allowOnceRecordsGrant() async {
        let mgr = SandboxManager()
        let path = URL(fileURLWithPath: "/Users/test/foo.txt")
        // Drive the request + answer concurrently because requestAccess suspends.
        async let decision = mgr.requestAccess(to: path, toolName: "read_file")
        // Yield enough to let the request settle into pending state.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowOnce)
        let d = await decision
        #expect(d == .allowOnce)
        #expect(mgr.isAllowed(path))
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/bar.txt")))
    }

    @Test("Allow-once on a directory does NOT recursively grant descendants")
    func allowOnceOnDirectoryIsExact() async {
        // Regression for a v0.3 review finding: ``.allowOnce`` used
        // to insert the path into ``allowedRoots`` which is
        // prefix-matched. If the user answered "Allow once" on a
        // ``list_directory`` request for ``~/Documents``, every
        // descendant got recursive coverage — contrary to the
        // sheet's "once" copy. The fix routes one-shot grants
        // through a separate exact-equality set.
        let mgr = SandboxManager()
        let dir = URL(fileURLWithPath: "/Users/test/Documents")
        async let decision = mgr.requestAccess(to: dir, toolName: "list_directory")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowOnce)
        _ = await decision
        // The directory itself is allowed (so a repeated identical
        // call doesn't re-prompt).
        #expect(mgr.isAllowed(dir))
        // But descendants are NOT covered — that's the bug.
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Documents/secret.txt")))
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Documents/sub/leaf.swift")))
    }

    @Test("Allow-folder decision grants the parent directory")
    func allowFolderGrantsParent() async {
        let mgr = SandboxManager()
        let path = URL(fileURLWithPath: "/Users/test/Project/main.swift")
        async let decision = mgr.requestAccess(to: path, toolName: "read_file")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await decision
        // Sibling in the same parent is now covered.
        #expect(mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Project/util.swift")))
        // Sibling-of-parent is NOT covered.
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/OtherProject/main.swift")))
    }

    @Test("A write-folder grant's physical root is frozen against a later symlink swap")
    func writeGrantPhysicalRootFrozenAgainstSymlinkSwap() async throws {
        // sandboxWritableRoots() feeds run_command's Seatbelt writable subpaths.
        // It must return the physical path FROZEN at grant time — never
        // re-resolve it — or a command writable in a granted PARENT could
        // replace the approved dir with a symlink to an unapproved target and
        // float the write grant onto it (codex r11 BLOCKING; same class of flaw
        // isAllowed avoids for read/write grants).
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "rapid-sbx-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }

        let approved = base + "/approved"   // what the user grants
        let evil = base + "/evil"           // an unapproved dir a swap points at
        try fm.createDirectory(atPath: approved, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: evil, withIntermediateDirectories: true)
        let approvedPhysical = real(approved)
        let evilPhysical = real(evil)

        let mgr = SandboxManager()
        async let decision = mgr.requestAccess(
            to: URL(fileURLWithPath: approved + "/file.txt"),
            toolName: "write_file", access: .write)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await decision

        #expect(mgr.sandboxWritableRoots() == [approvedPhysical],
                "the write grant should freeze the approved dir's physical path")

        // Attacker swaps the approved dir for a symlink to the unapproved dir.
        try fm.removeItem(atPath: approved)
        try fm.createSymbolicLink(atPath: approved, withDestinationPath: evil)

        let roots = mgr.sandboxWritableRoots()
        #expect(roots == [approvedPhysical],
                "a use-time re-resolve floated the grant onto the swapped target")
        #expect(!roots.contains(evilPhysical),
                "the writable root must never point at the unapproved swap target")
    }

    @Test("A write-folder grant is frozen against a symlink swap DURING the approval prompt")
    func writeGrantFrozenAgainstSwapDuringPrompt() async throws {
        // TOCTOU across the approval window (codex r12 BLOCKING): the user is
        // shown "grant write to <link>"; while the dialog is up, an attacker
        // retargets <link> from the approved dir to an unapproved one. The
        // grant MUST land on what the user saw (frozen at request time), not
        // the swapped target. PendingRequest snapshots the resolved path when
        // the prompt is raised; answer() must consume that snapshot.
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "rapid-sbx-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }

        let approved = base + "/approved"      // what <link> points at when shown
        let evil = base + "/evil"              // where the attacker retargets it
        try fm.createDirectory(atPath: approved, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: evil, withIntermediateDirectories: true)
        let link = base + "/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: approved)
        let approvedPhysical = real(approved)
        let evilPhysical = real(evil)

        let mgr = SandboxManager()
        async let decision = mgr.requestAccess(
            to: URL(fileURLWithPath: link + "/file.txt"),
            toolName: "write_file", access: .write)

        // Wait until the request is actually pending (snapshot frozen), THEN
        // swap the symlink out from under it before answering.
        var spins = 0
        while mgr.pendingRequest == nil && spins < 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(mgr.pendingRequest != nil, "request never became pending")
        try fm.removeItem(atPath: link)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: evil)

        mgr.answer(.allowFolder)
        _ = await decision

        let roots = mgr.sandboxWritableRoots()
        #expect(roots == [approvedPhysical],
                "the grant floated onto the target swapped in during the prompt")
        #expect(!roots.contains(evilPhysical),
                "the writable root must be what the user was shown, not the swap")
    }

    // MARK: - Blanket auto-approve (Settings → Permissions)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "rapid.test.sandbox.\(UUID().uuidString)")!
    }

    @Test("autoApproveRead makes isAllowed(.read) true so the post-approval recheck passes")
    func autoApproveReadSatisfiesIsAllowedRecheck() {
        // Regression: the filesystem tools re-check isAllowed right before they
        // open a path (TOCTOU guard). Auto-approve must satisfy that recheck,
        // not only the initial requestAccess, or every auto-approved read fails
        // with "path target changed after approval."
        let mgr = SandboxManager(defaults: freshDefaults())
        let path = URL(fileURLWithPath: "/Users/test/anything/file.txt")
        #expect(!mgr.isAllowed(path, access: .read))
        mgr.autoApproveRead = true
        #expect(mgr.isAllowed(path, access: .read))
        // Read switch alone must NOT satisfy a write recheck.
        #expect(!mgr.isAllowed(path, access: .write))
    }

    @Test("autoApproveWrite satisfies both the write recheck and (transitively) reads")
    func autoApproveWriteSatisfiesIsAllowedRechecks() {
        let mgr = SandboxManager(defaults: freshDefaults())
        let path = URL(fileURLWithPath: "/Users/test/anything/file.txt")
        mgr.autoApproveWrite = true
        #expect(mgr.isAllowed(path, access: .write))
        // Being allowed to overwrite implies being allowed to read.
        #expect(mgr.isAllowed(path, access: .read))
    }

    @Test("autoApproveRead grants a read without ever prompting")
    func autoApproveReadSkipsPrompt() async {
        let mgr = SandboxManager(defaults: freshDefaults())
        mgr.autoApproveRead = true
        let decision = await mgr.requestAccess(
            to: URL(fileURLWithPath: "/Users/test/anything/file.txt"),
            toolName: "read_file")
        #expect(decision == .allowOnce)
        #expect(mgr.pendingRequest == nil, "auto-approve must not surface a dialog")
    }

    @Test("autoApproveRead records NO grant — turning it off restores asking")
    func autoApproveReadLeavesNoResidue() async {
        let mgr = SandboxManager(defaults: freshDefaults())
        let path = URL(fileURLWithPath: "/Users/test/anything/file.txt")
        mgr.autoApproveRead = true
        _ = await mgr.requestAccess(to: path, toolName: "read_file")
        // Flip the switch back off: the earlier auto-approved read must not
        // have left a lingering grant.
        mgr.autoApproveRead = false
        #expect(!mgr.isAllowed(path), "auto-approve must not persist a per-path grant")
    }

    @Test("autoApproveRead does NOT authorise a write — axes are separate")
    func autoApproveReadNeverAuthorisesWrite() async {
        let mgr = SandboxManager(defaults: freshDefaults())
        mgr.autoApproveRead = true
        // A write with only the READ switch on must still fall through to the
        // prompt machinery, not auto-allow.
        async let decision = mgr.requestAccess(
            to: URL(fileURLWithPath: "/Users/test/anything/file.txt"),
            toolName: "write_file", access: .write)
        var spins = 0
        while mgr.pendingRequest == nil && spins < 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(mgr.pendingRequest != nil, "write must prompt when only read is auto-approved")
        mgr.answer(.deny)
        #expect(await decision == .deny)
    }

    @Test("autoApproveWrite grants a write without prompting")
    func autoApproveWriteSkipsPrompt() async {
        let mgr = SandboxManager(defaults: freshDefaults())
        mgr.autoApproveWrite = true
        let decision = await mgr.requestAccess(
            to: URL(fileURLWithPath: "/Users/test/anything/file.txt"),
            toolName: "write_file", access: .write)
        #expect(decision == .allowOnce)
        #expect(mgr.pendingRequest == nil)
    }

    @Test("Both auto-approve flags persist to the backing defaults")
    func autoApproveFlagsPersist() {
        let suite = freshDefaults()
        defer { suite.removePersistentDomain(forName: suite.description) }
        let a = SandboxManager(defaults: suite)
        a.autoApproveRead = true
        a.autoApproveWrite = true
        // A fresh manager over the same defaults reads the choice back.
        let b = SandboxManager(defaults: suite)
        #expect(b.autoApproveRead)
        #expect(b.autoApproveWrite)
    }

    /// End-to-end guard for the exact regression codex caught: an auto-approved
    /// call records NO grant, and every filesystem tool re-checks ``isAllowed``
    /// right before it touches the path. If auto-approve didn't satisfy that
    /// recheck, the tool would fail with "path target changed after approval"
    /// even though the user turned the switch on. Drive the REAL tool functions
    /// (real filesystem + real sandboxed command) to prove they actually run.
    @Test("Auto-approve lets the real write/read/run tools execute (no grant)")
    func autoApproveDrivesRealToolExecution() async {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-sbx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("out.txt")

        let d = freshDefaults()
        let sandbox = SandboxManager(defaults: d)
        sandbox.autoApproveRead = true
        sandbox.autoApproveWrite = true

        let w = await FilesystemTools.writeFile(
            arguments: #"{"path":"\#(target.path)","content":"sbx-payload"}"#, sandbox: sandbox)
        #expect(!w.isError, "auto-approved write must execute: \(w.content)")
        #expect((try? String(contentsOf: target, encoding: .utf8)) == "sbx-payload")

        let r = await FilesystemTools.readFile(
            arguments: #"{"path":"\#(target.path)"}"#, sandbox: sandbox)
        #expect(!r.isError && r.content.contains("sbx-payload"), "auto-approved read must execute: \(r.content)")

        let cmd = CommandApprovalStore(defaults: d)
        cmd.mode = .autoApproveAll
        let c = await RunCommandTool.run(
            arguments: #"{"command":"echo sbx_stdout_marker"}"#, approval: cmd, sandbox: sandbox)
        #expect(!c.isError && c.content.contains("sbx_stdout_marker"), "auto-approved command must execute: \(c.content)")
    }

    // MARK: - #534: dialog shows the resolved target, not the lexical path

    @Test("Prompt surfaces the symlink-resolved destination, not the benign lexical path")
    func promptShowsResolvedDestinationThroughSymlink() async throws {
        // A user asked to read ``<base>/link/file.txt`` where ``link`` is a
        // pre-existing symlink to ``<base>/real``. The grant is recorded
        // against the RESOLVED path (``<base>/real/file.txt``); the dialog
        // MUST show that resolved target — not the lexical ``link`` path —
        // so an intermediate symlink can't display a benign path while the
        // grant lands on the external directory it points at (issue #534).
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "rapid-sbx-534-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let realDir = base + "/real"
        try fm.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        let link = base + "/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: realDir)
        let resolvedFile = real(realDir) + "/file.txt"

        let mgr = SandboxManager()
        async let decision = mgr.requestAccess(
            to: URL(fileURLWithPath: link + "/file.txt"),
            toolName: "read_file")
        var spins = 0
        while mgr.pendingRequest == nil && spins < 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        let req = try #require(mgr.pendingRequest, "request never became pending")

        #expect(req.isSymlinkRedirected, "an intermediate symlink must be flagged as redirected")
        // The resolved target — what the dialog shows and what a grant
        // actually lands on — is the physical file, NOT the lexical link
        // path. (``canonical`` itself stays lexical here: resolvingSymlinks
        // can't resolve the intermediate `link` when the leaf `file.txt`
        // doesn't exist yet, which is exactly why resolvedTargetPath routes
        // through the parent's realpath instead — issue #534.)
        #expect(req.resolvedTargetPath == resolvedFile)
        // The user-facing phrase names the resolved destination …
        #expect(req.grantedPathPhrase.contains(resolvedFile),
                "dialog must show the resolved destination: \(req.grantedPathPhrase)")
        // … and preserves the lexical path the model asked for so the
        // redirection is visible rather than silently swapped.
        #expect(req.grantedPathPhrase.contains(link + "/file.txt"),
                "dialog must also show the lexical request: \(req.grantedPathPhrase)")

        mgr.answer(.deny)
        _ = await decision
    }

    @Test("A non-symlinked path shows its plain path with no redirection note")
    func promptPlainPathNotFlaggedAsRedirected() async throws {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "rapid-sbx-534b-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        // Resolve the base once so the canonical form matches what the
        // request computes (NSTemporaryDirectory itself can sit under a
        // /var → /private/var symlink; comparing against the resolved base
        // isolates THIS test from that OS-level link).
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        let realBase = base.withCString { realpath($0, &buf) } != nil
            ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : base
        let target = realBase + "/plain.txt"

        let mgr = SandboxManager()
        async let decision = mgr.requestAccess(
            to: URL(fileURLWithPath: target), toolName: "read_file")
        var spins = 0
        while mgr.pendingRequest == nil && spins < 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        let req = try #require(mgr.pendingRequest)
        #expect(!req.isSymlinkRedirected, "a plain path must not be flagged as redirected")
        #expect(req.grantedPathPhrase == target, "plain path shows verbatim, no note")
        mgr.answer(.deny)
        _ = await decision
    }

    // MARK: - #535: grants are scoped to the active conversation

    @Test("resetSessionGrants drops read + write grants so a later chat re-prompts")
    func resetSessionGrantsClearsPerPathGrants() async {
        let mgr = SandboxManager()
        // Chat A grants a read folder and a write folder.
        let readPath = URL(fileURLWithPath: "/Users/test/ReadProj/a.txt")
        async let d1 = mgr.requestAccess(to: readPath, toolName: "read_file")
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await d1

        let writePath = URL(fileURLWithPath: "/Users/test/WriteProj/b.txt")
        async let d2 = mgr.requestAccess(to: writePath, toolName: "write_file", access: .write)
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await d2

        #expect(mgr.isAllowed(readPath, access: .read))
        #expect(mgr.isAllowed(writePath, access: .write))

        // Switching chats resets the per-path grants.
        mgr.resetSessionGrants()

        #expect(!mgr.isAllowed(readPath, access: .read), "read grant must not survive a session change")
        #expect(!mgr.isAllowed(writePath, access: .write), "write grant must not survive a session change")
        #expect(!mgr.isAllowed(writePath, access: .read), "the write grant's implied read must also clear")
    }

    @Test("resetSessionGrants clears one-shot grants and the Seatbelt writable roots")
    func resetSessionGrantsClearsOneShotAndWritableRoots() async throws {
        // The Seatbelt writable root is the realpath of the granted folder,
        // so the write-folder grant must land on a directory that actually
        // exists on disk (physicalFolder is nil otherwise). Use a real temp
        // dir for it; the one-shot read can stay a synthetic path.
        let fm = FileManager.default
        let realDir = NSTemporaryDirectory() + "rapid-sbx-535-\(UUID().uuidString)"
        try fm.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: realDir) }

        let mgr = SandboxManager()
        let once = URL(fileURLWithPath: "/Users/test/once.txt")
        async let d1 = mgr.requestAccess(to: once, toolName: "read_file")
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowOnce)
        _ = await d1
        #expect(mgr.isAllowed(once))

        let writeFolder = URL(fileURLWithPath: realDir + "/c.txt")
        async let d2 = mgr.requestAccess(to: writeFolder, toolName: "write_file", access: .write)
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await d2
        #expect(!mgr.sandboxWritableRoots().isEmpty, "write-folder grant should freeze a Seatbelt writable root")

        mgr.resetSessionGrants()
        #expect(!mgr.isAllowed(once), "one-shot grant must clear on reset")
        #expect(mgr.sandboxWritableRoots().isEmpty, "Seatbelt writable roots must clear on reset")
    }

    @Test("resetSessionGrants preserves the seeded trust roots but drops user grants")
    func resetSessionGrantsPreservesSeed() async {
        // autoApprove stays OFF here so ``isAllowed`` actually consults the
        // grant sets — with a blanket switch on it short-circuits and the
        // seed-vs-grant distinction would be untestable.
        let seeded = URL(fileURLWithPath: "/Users/test/Seeded")
        let mgr = SandboxManager(initialGrants: [seeded], defaults: freshDefaults())

        // A user-approved grant on TOP of the seed.
        let extra = URL(fileURLWithPath: "/Users/test/Extra/x.txt")
        async let d = mgr.requestAccess(to: extra, toolName: "read_file")
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowFolder)
        _ = await d
        #expect(mgr.isAllowed(extra))

        mgr.resetSessionGrants()

        // The seed the host handed the manager survives …
        #expect(mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Seeded/deep.txt")),
                "seeded trust root must survive a session reset")
        // … but the user's per-session grant does not.
        #expect(!mgr.isAllowed(extra), "a user-approved grant must not survive a session reset")
    }

    @Test("resetSessionGrants leaves the persisted auto-approve switches untouched")
    func resetSessionGrantsPreservesAutoApprove() {
        let mgr = SandboxManager(defaults: freshDefaults())
        mgr.autoApproveRead = true
        mgr.autoApproveWrite = true
        mgr.resetSessionGrants()
        // The blanket switches are an explicit Settings choice meant to
        // outlive any single conversation — reset must not clear them.
        #expect(mgr.autoApproveRead)
        #expect(mgr.autoApproveWrite)
    }

    @Test("A request left pending across a session reset is denied, not carried into the next chat")
    func resetSessionGrantsDeniesInFlightRequest() async {
        // Codex r1 BLOCKING: chat A raises an approval dialog, the user
        // switches to chat B (reset) WITHOUT answering, then answers the old
        // dialog. Before the fix, that late answer recorded a grant into the
        // now-current SandboxManager, silently re-granting what #535 cleared.
        // The reset must deny + resume the in-flight request so neither the
        // suspended tool nor a late answer can create a grant for chat B.
        let mgr = SandboxManager()
        let target = URL(fileURLWithPath: "/Users/test/Pending/p.txt")
        async let decision = mgr.requestAccess(to: target, toolName: "write_file", access: .write)
        var spins = 0
        while mgr.pendingRequest == nil && spins < 200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(mgr.pendingRequest != nil, "request never became pending")

        // The user switches chats mid-approval.
        mgr.resetSessionGrants()

        // The suspended tool observes a denial …
        let d = await decision
        #expect(d == .deny, "an abandoned pending request must resume as .deny")
        // … the globally-presented dialog is gone …
        #expect(mgr.pendingRequest == nil, "reset must clear the pending request")
        // … and a late answer records nothing into the new chat.
        mgr.answer(.allowFolder)
        #expect(!mgr.isAllowed(target, access: .write),
                "answering a reset-cleared request must not grant anything")
    }
}
