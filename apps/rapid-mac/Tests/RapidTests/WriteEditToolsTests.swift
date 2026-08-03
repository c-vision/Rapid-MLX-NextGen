import Foundation
import Testing
@testable import Rapid

/// Coverage for the two action tools that MUTATE the filesystem —
/// ``write_file`` and ``edit_file`` — plus the WRITE-intent split in
/// ``SandboxManager`` that keeps a read grant from silently
/// authorising a write.
///
/// These drive the real ``SandboxManager`` continuation gate (the
/// tool suspends on a prompt; the test answers it) and touch a real
/// throwaway temp directory so the atomic temp+rename path, symlink
/// refusal, and blocklist all exercise production code.
@MainActor
@Suite("write_file / edit_file tools")
struct WriteEditToolsTests {

    // MARK: - harness

    /// A unique empty temp directory; removed at the end of the test.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-writeedit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run a tool op that is EXPECTED to raise a sandbox prompt, wait
    /// for the prompt to appear, then answer it with `decision`.
    @discardableResult
    private func approving(
        _ sandbox: SandboxManager,
        with decision: SandboxManager.Decision,
        _ op: @escaping @Sendable () async -> ToolCallResult
    ) async -> ToolCallResult {
        async let result = op()
        var spins = 0
        while sandbox.pendingRequest == nil && spins < 500 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
            spins += 1
        }
        sandbox.answer(decision)   // no-op if the op returned early without prompting
        return await result
    }

    private func json(_ result: ToolCallResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - write_file

    @Test("write_file creates a new file after an allow-once approval")
    func writeCreatesFile() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("note.txt")
        let args = #"{"path": "\#(target.path)", "content": "hello world"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }

        #expect(!result.isError)
        #expect(json(result)["created"] as? Bool == true)
        let onDisk = try String(contentsOf: target, encoding: .utf8)
        #expect(onDisk == "hello world")
    }

    @Test("write_file overwrites an existing file (created=false)")
    func writeOverwrites() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("note.txt")
        try "old contents".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "content": "new"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }

        #expect(!result.isError)
        #expect(json(result)["created"] as? Bool == false)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test("write_file denied writes nothing")
    func writeDeniedIsNoOp() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("note.txt")
        let args = #"{"path": "\#(target.path)", "content": "x"}"#

        let result = await approving(sandbox, with: .deny) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }

        #expect(result.isError)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("write_file rejects a relative path without prompting")
    func writeRejectsRelativePath() async {
        let sandbox = SandboxManager()
        let result = await FilesystemTools.writeFile(
            arguments: #"{"path": "note.txt", "content": "x"}"#, sandbox: sandbox)
        #expect(result.isError)
        #expect(sandbox.pendingRequest == nil)   // never reached the gate
    }

    @Test("write_file refuses OS + user-Library locations without prompting")
    func writeBlocklist() async {
        let sandbox = SandboxManager()
        for path in ["/System/x.txt", "/usr/bin/x", "\(NSHomeDirectory())/Library/Preferences/x.plist"] {
            let result = await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(path)", "content": "x"}"#, sandbox: sandbox)
            #expect(result.isError, "\(path) should be write-blocked")
            #expect(sandbox.pendingRequest == nil)
        }
    }

    @Test("write_file errors when the parent folder is missing")
    func writeParentMissing() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("does-not-exist/deep.txt")
        let args = #"{"path": "\#(target.path)", "content": "x"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }
        #expect(result.isError)
        #expect(result.content.contains("parent folder does not exist"))
    }

    @Test("write_file rejects content over the byte cap without prompting")
    func writeOverCap() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let big = String(repeating: "a", count: FilesystemTools.writeByteCap + 1)
        let target = dir.appendingPathComponent("big.txt")
        let result = await FilesystemTools.writeFile(
            arguments: #"{"path": "\#(target.path)", "content": "\#(big)"}"#, sandbox: sandbox)
        #expect(result.isError)
        #expect(sandbox.pendingRequest == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("write_file refuses to write THROUGH a symlink")
    func writeRefusesSymlink() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.txt")
        try "orig".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(link.path)", "content": "pwned"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }

        #expect(result.isError)
        #expect(result.content.contains("symlink"))
        // The link's real target is untouched.
        #expect(try String(contentsOf: real, encoding: .utf8) == "orig")
    }

    @Test("a READ grant does NOT authorise a write — write still prompts")
    func readGrantDoesNotCoverWrite() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-seed a READ grant for the whole dir.
        let sandbox = SandboxManager(initialGrants: [dir])
        let target = dir.appendingPathComponent("note.txt")
        #expect(sandbox.isAllowed(target, access: .read))    // read is covered
        #expect(!sandbox.isAllowed(target, access: .write))  // write is NOT

        // So write_file must raise a fresh prompt despite the read grant.
        let args = #"{"path": "\#(target.path)", "content": "x"}"#
        var prompted = false
        async let result = FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        var spins = 0
        while sandbox.pendingRequest == nil && spins < 500 {
            await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000); spins += 1
        }
        if sandbox.pendingRequest != nil { prompted = true; sandbox.answer(.allowOnce) }
        let r = await result
        #expect(prompted)
        #expect(!r.isError)
    }

    @Test("allow-folder WRITE grant skips the prompt for a sibling write")
    func writeFolderGrantCoversSiblings() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let a = dir.appendingPathComponent("a.txt")
        _ = await approving(sandbox, with: .allowFolder) {
            await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(a.path)", "content": "A"}"#, sandbox: sandbox)
        }
        // Second write to a sibling: no prompt should appear.
        let b = dir.appendingPathComponent("b.txt")
        let result = await FilesystemTools.writeFile(
            arguments: #"{"path": "\#(b.path)", "content": "B"}"#, sandbox: sandbox)
        #expect(!result.isError)
        #expect(sandbox.pendingRequest == nil)   // covered by the folder grant
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
    }

    // MARK: - edit_file

    @Test("edit_file replaces a unique string")
    func editUnique() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("greet.txt")
        try "hello world".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "world", "new_string": "there"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }

        #expect(!result.isError)
        #expect(json(result)["replacements"] as? Int == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello there")
    }

    @Test("edit_file errors when old_string is not found (file untouched)")
    func editNotFound() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("greet.txt")
        try "hello world".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "zzz", "new_string": "q"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }

        #expect(result.isError)
        #expect(result.content.contains("not found"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello world")
    }

    @Test("edit_file rejects an ambiguous match unless replace_all")
    func editAmbiguous() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("multi.txt")
        try "a a a".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "a", "new_string": "b"}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }

        #expect(result.isError)
        #expect(result.content.contains("more than once"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "a a a")
    }

    @Test("edit_file with replace_all replaces every occurrence")
    func editReplaceAll() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("multi.txt")
        try "a a a".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "a", "new_string": "b", "replace_all": true}"#

        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }

        #expect(!result.isError)
        #expect(json(result)["replacements"] as? Int == 3)
        #expect(try String(contentsOf: target, encoding: .utf8) == "b b b")
    }

    @Test("edit_file rejects empty old_string without prompting")
    func editEmptyOldString() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("x.txt")
        let args = #"{"path": "\#(target.path)", "old_string": "", "new_string": "y"}"#
        let result = await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        #expect(result.isError)
        #expect(sandbox.pendingRequest == nil)
    }

    @Test("edit_file rejects a no-op (old == new) without prompting")
    func editIdentical() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("x.txt")
        let args = #"{"path": "\#(target.path)", "old_string": "a", "new_string": "a"}"#
        let result = await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        #expect(result.isError)
        #expect(sandbox.pendingRequest == nil)
    }

    @Test("edit_file errors on a missing file (after approval)")
    func editMissingFile() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("ghost.txt")
        let args = #"{"path": "\#(target.path)", "old_string": "a", "new_string": "b"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }
        #expect(result.isError)
    }

    // MARK: - hardening (codex round 1)

    @Test("write_file refuses a non-regular target (FIFO)")
    func writeRefusesNonRegular() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(fifo.path)", "content": "x"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        }
        #expect(result.isError)
        #expect(result.content.contains("regular file"))
    }

    @Test("write_file refuses credential stores + /etc without prompting")
    func writeBlocksCredentialDirs() async {
        let sandbox = SandboxManager()
        let home = NSHomeDirectory()
        let blocked = [
            "\(home)/.ssh/authorized_keys",
            "\(home)/.ssh/config",
            "\(home)/.aws/credentials",
            "\(home)/.gnupg/secring.gpg",
            "\(home)/.config/gcloud/credentials.db",
            "\(home)/.netrc",
            "/etc/hosts",
        ]
        for path in blocked {
            let result = await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(path)", "content": "x"}"#, sandbox: sandbox)
            #expect(result.isError, "\(path) must be write-blocked")
            #expect(sandbox.pendingRequest == nil, "\(path) must not even prompt")
        }
    }

    @Test("write_file blocks shell-RC, login-item + dev-tool config files (code-exec/persistence)")
    func writeBlocksShellStartupFiles() async {
        let sandbox = SandboxManager()
        let home = NSHomeDirectory()
        for path in ["\(home)/.zshrc", "\(home)/.bash_profile", "\(home)/.zprofile",
                     "\(home)/Library/LaunchAgents/x.plist", "\(home)/.config/fish/config.fish",
                     "\(home)/.gitconfig", "\(home)/.config/git/config",
                     "\(home)/.config/nvim/init.lua", "\(home)/.vimrc",
                     "\(home)/.emacs.d/init.el"] {
            let result = await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(path)", "content": "x"}"#, sandbox: sandbox)
            #expect(result.isError, "\(path) must be write-blocked")
        }
    }

    @Test("write_file creates fresh files private (0600), not world-readable")
    func writeFreshFileIsPrivate() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sandbox = SandboxManager()
        let target = dir.appendingPathComponent("secret.env")
        _ = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(target.path)", "content": "TOKEN=abc"}"#, sandbox: sandbox)
        }
        let mode = (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600, "a freshly written file must not be world-readable")
    }

    @Test("write_file refuses any path with a .git component (hooks/config exec surface)")
    func writeBlocksGitInternals() async {
        let sandbox = SandboxManager()
        let home = NSHomeDirectory()
        for path in ["\(home)/proj/.git/config", "\(home)/proj/.git/hooks/pre-commit",
                     "\(home)/proj/sub/.git", "\(home)/proj/.GIT/hooks/post-checkout"] {
            let result = await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(path)", "content": "x"}"#, sandbox: sandbox)
            #expect(result.isError, "\(path) must be write-blocked")
        }
        // …but .gitignore / .gitattributes (distinct names) are NOT blocked.
        #expect(!FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "\(home)/proj/.gitignore")))
        #expect(!FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "\(home)/proj/.gitattributes")))
    }

    @Test("write_file rejects an embedded NUL (C-string truncation attack)")
    func writeRejectsEmbeddedNUL() async {
        let sandbox = SandboxManager()
        let home = NSHomeDirectory()
        // "~/.zshrc .txt" must NOT slip past the blocklist and land
        // on ~/.zshrc via C-string truncation. It should be refused
        // outright, with no prompt.
        let evil = "\(home)/.zshrc\u{0000}.txt"
        let args = #"{"path": "\#(evil)", "content": "x"}"#
        let result = await FilesystemTools.writeFile(arguments: args, sandbox: sandbox)
        #expect(result.isError)
        #expect(sandbox.pendingRequest == nil)
    }

    @Test("write_file blocks user-level executable + editor-extension roots")
    func writeBlocksUserExecRoots() {
        let home = NSHomeDirectory()
        for p in ["\(home)/Applications/Foo.app/Contents/MacOS/Foo",
                  "\(home)/.vscode/extensions/evil/extension.js",
                  "\(home)/.cursor/extensions/evil/extension.js"] {
            #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: p)), "\(p) must be write-blocked")
        }
    }

    @Test("edit_file treats an overlapping pattern as ambiguous (not unique)")
    func editOverlappingIsAmbiguous() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("ov.txt")
        try "ababa".write(to: target, atomically: true, encoding: .utf8)
        let sandbox = SandboxManager()
        // "aba" overlaps twice in "ababa" — must be rejected as ambiguous.
        let args = #"{"path": "\#(target.path)", "old_string": "aba", "new_string": "X"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }
        #expect(result.isError)
        #expect(result.content.contains("more than once"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "ababa")
    }

    @Test("edit_file preserves the target's extended attributes (e.g. quarantine)")
    func editPreservesXattrs() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("doc.txt")
        try "hello world".write(to: target, atomically: true, encoding: .utf8)
        // Stamp a custom xattr on the original.
        let xattrName = "com.rapid.test.flag"
        let xattrValue = Data("keep-me".utf8)
        let setResult = target.path.withCString { pathC in
            xattrValue.withUnsafeBytes { buf in
                setxattr(pathC, xattrName, buf.baseAddress, buf.count, 0, 0)
            }
        }
        #expect(setResult == 0, "precondition: could set the xattr")

        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "world", "new_string": "there"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }
        #expect(!result.isError)
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello there")
        // The xattr must survive the atomic temp+rename.
        let size = target.path.withCString { getxattr($0, xattrName, nil, 0, 0, 0) }
        #expect(size == xattrValue.count, "xattr must be preserved across the edit")
    }

    @Test("write blocklist is case-insensitive (default APFS folds case)")
    func writeBlocklistCaseInsensitive() {
        let home = NSHomeDirectory()
        // Mixed-case spellings of blocked paths resolve to the same file
        // on the default case-insensitive boot volume and must be blocked.
        #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "\(home)/.ZSHRC")))
        #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "\(home)/lIBRARY/Preferences/x.plist")))
        #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "/ETC/hosts")))
        #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: "\(home)/.SSH/authorized_keys")))
    }

    @Test("safeReplaceFile refuses a drifted edit (content changed since read)")
    func editContentDriftRefused() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("drift.txt")
        try "current on disk".write(to: target, atomically: true, encoding: .utf8)
        // Simulate an edit computed against a STALE snapshot: the on-disk
        // bytes no longer match what `expecting` claims we read.
        do {
            _ = try FilesystemTools.safeReplaceFile(
                target: target, expecting: "an older snapshot", newContent: Data("new".utf8))
            Issue.record("expected safeReplaceFile to refuse a drifted edit")
        } catch let e as FilesystemTools.WriteError {
            guard case .contentChanged = e else {
                Issue.record("wrong error for drift: \(e)"); return
            }
        }
        // The file is left exactly as it was.
        #expect(try String(contentsOf: target, encoding: .utf8) == "current on disk")
    }

    @Test("a folder write-grant does NOT survive the granted folder being swapped to a symlink")
    func writeGrantVoidedBySymlinkSwap() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("approved/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // A real file the attacker wants the model to reach after the swap.
        try "OUT-OF-GRANT".write(
            to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let sandbox = SandboxManager()
        // Approve the whole `sub` folder for writing.
        _ = await approving(sandbox, with: .allowFolder) {
            await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(sub.appendingPathComponent("note.txt").path)", "content": "one"}"#,
                sandbox: sandbox)
        }
        // The just-written file in the granted folder is covered...
        #expect(sandbox.isAllowed(sub.appendingPathComponent("note.txt"), access: .write))
        // ...but after `sub` is swapped to a symlink pointing OUTSIDE the
        // grant, the redirected (now-existing) file is not authorised — the
        // grant was frozen to the original physical folder, not the symlink.
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        #expect(!sandbox.isAllowed(sub.appendingPathComponent("secret.txt"), access: .write))
    }

    @Test("a folder write-grant does NOT float when an ANCESTOR is retargeted")
    func writeGrantFrozenAgainstAncestorSwap() async throws {
        // codex r7 BLOCKING regression guard. The stored grant root must be
        // frozen at grant time and NEVER re-resolved: retargeting an
        // INTERMEDIATE ancestor of the root (`parent` → `evil`) makes the
        // live path resolve into an unapproved directory. If isAllowed
        // re-resolved the stored root it would float onto `evil/proj` too
        // (root and target then agree), authorising a write/read the user
        // never approved — and the physical-parent re-auth can't catch it
        // because both sides point at the attacker's directory. Uses an
        // EXISTING target so resolvingSymlinksInPath is well-defined.
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("parent/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let evilProj = dir.appendingPathComponent("evil/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: evilProj, withIntermediateDirectories: true)
        try "SECRET".write(
            to: evilProj.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)

        let sandbox = SandboxManager()
        // Approve the `parent/proj` folder for writing.
        _ = await approving(sandbox, with: .allowFolder) {
            await FilesystemTools.writeFile(
                arguments: #"{"path": "\#(proj.appendingPathComponent("note.txt").path)", "content": "one"}"#,
                sandbox: sandbox)
        }
        #expect(sandbox.isAllowed(proj.appendingPathComponent("note.txt"), access: .write))
        // Retarget the ANCESTOR `parent` → `evil`, so `parent/proj/target.txt`
        // now resolves to the unapproved `evil/proj/target.txt`.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("parent"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("parent"), withDestinationURL: dir.appendingPathComponent("evil"))
        #expect(!sandbox.isAllowed(proj.appendingPathComponent("target.txt"), access: .write))
    }

    @Test("safeReplaceFile with a matching snapshot commits the edit")
    func editContentMatchCommits() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("ok.txt")
        try "before".write(to: target, atomically: true, encoding: .utf8)
        let existed = try FilesystemTools.safeReplaceFile(
            target: target, expecting: "before", newContent: Data("after".utf8))
        #expect(existed)
        #expect(try String(contentsOf: target, encoding: .utf8) == "after")
    }

    @Test("write blocklist covers auto-executed config + PATH executable roots")
    func writeBlocksConfigAndPathRoots() {
        let home = NSHomeDirectory()
        for p in ["\(home)/bin/git",
                  "\(home)/.local/bin/python",
                  "\(home)/.tmux.conf",
                  "\(home)/.tmux/plugins/evil/evil.tmux",
                  "\(home)/.oh-my-zsh/custom/evil.zsh",
                  "\(home)/.config/wezterm/wezterm.lua",
                  "\(home)/.config/alacritty/alacritty.toml",
                  "\(home)/.config/kitty/kitty.conf",
                  "\(home)/.hammerspoon/init.lua",
                  "\(home)/.yabairc",
                  "\(home)/.skhdrc",
                  "\(home)/.chunkwmrc",
                  "\(home)/.config/yabai/yabairc",
                  "\(home)/.config/skhd/skhdrc"] {
            #expect(FilesystemTools.isWriteBlocked(URL(fileURLWithPath: p)), "\(p) must be write-blocked")
        }
    }

    // MARK: - edit_file pre-image reader (fd-relative, no read-through)

    @Test("safeReadLeaf reads a regular file fd-relative from its physical parent")
    func safeReadLeafReadsRegular() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("data.txt")
        try "payload".write(to: f, atomically: true, encoding: .utf8)
        let data = try FilesystemTools.safeReadLeaf(
            physicalParent: FilesystemTools.physicalParentPath(of: f)!, leaf: "data.txt", cap: 1 << 20)
        #expect(String(data: data, encoding: .utf8) == "payload")
    }

    @Test("safeReadLeaf refuses a symlink leaf — never reads its target")
    func safeReadLeafRefusesSymlinkLeaf() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("secret.txt")
        try "top secret".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        do {
            _ = try FilesystemTools.safeReadLeaf(
                physicalParent: FilesystemTools.physicalParentPath(of: link)!, leaf: "link.txt", cap: 1 << 20)
            Issue.record("expected safeReadLeaf to refuse a symlink leaf")
        } catch let e as FilesystemTools.WriteError {
            guard case .targetIsSymlink = e else { Issue.record("wrong error: \(e)"); return }
        }
    }

    @Test("safeReadLeaf refuses an intermediate-component symlink swap — closes edit_file's read oracle")
    func safeReadLeafRefusesIntermediateSwap() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "in-grant".write(to: sub.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "OUT-OF-GRANT SECRET".write(
            to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // The fully-physical parent the caller authorized, captured BEFORE the
        // swap. After `sub` becomes a symlink to `outside`, a lexical read
        // would follow it and leak the out-of-grant file through edit_file's
        // found / occurrence-count report; the fd-relative reader must refuse.
        let physParent = FilesystemTools.physicalParentPath(of: sub.appendingPathComponent("f.txt"))!
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        do {
            _ = try FilesystemTools.safeReadLeaf(physicalParent: physParent, leaf: "f.txt", cap: 1 << 20)
            Issue.record("expected safeReadLeaf to refuse an intermediate symlink swap")
        } catch let e as FilesystemTools.WriteError {
            guard case .pathChanged = e else { Issue.record("wrong error: \(e)"); return }
        }
    }

    @Test("edit_file on a missing file points the model at write_file")
    func editMissingFileMessage() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("nope.txt")
        let sandbox = SandboxManager()
        let args = #"{"path": "\#(target.path)", "old_string": "a", "new_string": "b"}"#
        let result = await approving(sandbox, with: .allowOnce) {
            await FilesystemTools.editFile(arguments: args, sandbox: sandbox)
        }
        #expect(result.isError)
        #expect(result.content.contains("does not exist"))
    }

    // MARK: - SandboxManager write-intent split

    @Test("a WRITE grant implies read; a read grant never implies write")
    func writeImpliesReadNotViceVersa() async {
        // Write folder grant → both read and write covered.
        let writeMgr = SandboxManager()
        let file = URL(fileURLWithPath: "/Users/test/Proj/main.swift")
        async let d = writeMgr.requestAccess(to: file, toolName: "write_file", access: .write)
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        writeMgr.answer(.allowFolder)
        _ = await d
        let sibling = URL(fileURLWithPath: "/Users/test/Proj/util.swift")
        #expect(writeMgr.isAllowed(sibling, access: .write))
        #expect(writeMgr.isAllowed(sibling, access: .read))   // write implies read

        // Read-only grant → write NOT covered.
        let readMgr = SandboxManager(initialGrants: [URL(fileURLWithPath: "/Users/test/Proj")])
        #expect(readMgr.isAllowed(file, access: .read))
        #expect(!readMgr.isAllowed(file, access: .write))
    }

    @Test("allow-once WRITE grant is exact + write-scoped")
    func writeOnceGrantExact() async {
        let mgr = SandboxManager()
        let file = URL(fileURLWithPath: "/Users/test/Notes/todo.md")
        async let d = mgr.requestAccess(to: file, toolName: "write_file", access: .write)
        await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000)
        mgr.answer(.allowOnce)
        _ = await d
        #expect(mgr.isAllowed(file, access: .write))
        #expect(mgr.isAllowed(file, access: .read))
        // Sibling is not covered for write.
        #expect(!mgr.isAllowed(URL(fileURLWithPath: "/Users/test/Notes/other.md"), access: .write))
    }
}
