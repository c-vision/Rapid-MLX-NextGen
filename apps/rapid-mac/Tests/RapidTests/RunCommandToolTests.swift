import Foundation
import Testing
@testable import Rapid

/// Coverage for ``run_command`` — the sandboxed shell tool. These exercise
/// the security-critical contract end-to-end where possible (real
/// `sandbox-exec`) and unit-test the profile / env construction where a
/// live run would be flaky (network egress) or intrusive (reading the
/// user's real `~/.ssh`).
///
/// The e2e "write outside the workspace is denied" test is the load-bearing
/// proof that the Seatbelt profile is actually applied by the kernel — if
/// that passes, an unconfined run is impossible.
@MainActor
@Suite("run_command tool")
struct RunCommandToolTests {

    // MARK: - helpers

    /// JSON-encode a tool-arguments dictionary (proper escaping for
    /// commands that contain quotes / redirects / newlines).
    private func argsJSON(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the tool's JSON success payload back into a dictionary.
    private func payload(_ result: ToolCallResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// A store pre-set to auto-approve so exec-focused tests don't have to
    /// drive the approval dialog. Uses a throwaway defaults suite.
    private func autoApproveStore() -> CommandApprovalStore {
        let suite = UserDefaults(suiteName: "rapid.test.runcmd.\(UUID().uuidString)")!
        let store = CommandApprovalStore(defaults: suite)
        store.mode = .autoApproveAll
        return store
    }

    /// The substring the profile emits for a `(literal "…")` deny of `path` —
    /// the rename guard's exact-match form ("the dir itself, never its
    /// contents"). (Assumes `path` has no `"`/`\`, true for these test homes.)
    private func literalRule(_ path: String) -> String { "(literal \"\(path)\")" }

    // MARK: - argument validation

    @Test("Empty command is rejected before anything runs")
    func emptyCommandRejected() async {
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "   "]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(result.isError)
        #expect(result.content.contains("empty"))
    }

    @Test("Unparseable arguments return an error, not a crash")
    func badArgsRejected() async {
        let result = await RunCommandTool.run(
            arguments: "not json",
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(result.isError)
    }

    @Test("A working_directory that doesn't exist is rejected")
    func missingWorkingDirRejected() async {
        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": "echo hi",
                "working_directory": "/nope/does/not/exist/\(UUID().uuidString)"
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(result.isError)
        #expect(result.content.contains("working_directory"))
    }

    @Test("An oversized command is rejected before it reaches the sandbox")
    func oversizedCommandRejected() async {
        // The command + inline Seatbelt profile travel as sandbox-exec argv,
        // bounded by ARG_MAX; a command past the cap is refused up front (and
        // is a red flag, not a real shell invocation).
        let huge = "echo " + String(repeating: "a", count: RunCommandTool.maxCommandBytes + 1)
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": huge]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(result.isError)
        #expect(result.content.contains("too long"))
    }

    // MARK: - approval gate

    @Test("A denied command never executes")
    func deniedCommandDoesNotRun() async {
        let suite = UserDefaults(suiteName: "rapid.test.runcmd.\(UUID().uuidString)")!
        let store = CommandApprovalStore(defaults: suite) // default .ask

        // A sentinel file the command would create if it ever ran.
        let sentinel = NSTemporaryDirectory() + "rapid-denied-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: sentinel) }

        let runTask = Task { @MainActor in
            await RunCommandTool.run(
                arguments: argsJSON(["command": "touch \(sentinel)"]),
                approval: store,
                sandbox: SandboxManager()
            )
        }
        // Wait for the prompt to appear, then deny.
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.deny)

        let result = await runTask.value
        #expect(result.isError)
        #expect(result.content.contains("declined"))
        // A denied command is never launched, so there is no exec payload at
        // all — no `exit_code`, `stdout`, or `sandboxed` field. (The sentinel
        // alone is weak: it lives outside the sandbox workspace, so Seatbelt
        // would block the `touch` even if a bug DID launch the command. This
        // asserts the command never reached the sandbox in the first place.)
        #expect(payload(result)["exit_code"] == nil, "a declined command must not execute")
        #expect(payload(result)["sandboxed"] == nil)
        #expect(!FileManager.default.fileExists(atPath: sentinel),
                "denied command must not have side effects")
    }

    @Test("Allow-once runs the command and reports its output + exit code")
    func allowOnceRuns() async {
        let suite = UserDefaults(suiteName: "rapid.test.runcmd.\(UUID().uuidString)")!
        let store = CommandApprovalStore(defaults: suite)

        let runTask = Task { @MainActor in
            await RunCommandTool.run(
                arguments: argsJSON(["command": "echo hello-run-command"]),
                approval: store,
                sandbox: SandboxManager()
            )
        }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.allowOnce)

        let result = await runTask.value
        #expect(!result.isError)
        let p = payload(result)
        #expect((p["exit_code"] as? Int) == 0)
        #expect((p["stdout"] as? String)?.contains("hello-run-command") == true)
        #expect((p["sandboxed"] as? Bool) == true)
    }

    // MARK: - exit-code propagation

    @Test("A non-zero exit code is reported")
    func nonZeroExitReported() async {
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "exit 7"]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        #expect((payload(result)["exit_code"] as? Int) == 7)
    }

    // MARK: - Seatbelt enforcement (e2e)

    @Test("Writing outside the workspace is denied by the sandbox")
    func writeOutsideWorkspaceDenied() async {
        // A sibling dir of the (internal) scratch workspace — NOT a granted
        // writable root, so a write into it must be blocked by Seatbelt.
        let outsideDir = NSTemporaryDirectory() + "rapid-outside-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }
        let target = outsideDir + "/should-not-exist.txt"

        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "echo x > \(target)"]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError) // the tool ran; the write inside it failed
        let p = payload(result)
        #expect((p["exit_code"] as? Int) != 0, "sandboxed write should fail")
        #expect(!FileManager.default.fileExists(atPath: target),
                "Seatbelt must block the out-of-workspace write")
    }

    @Test("Writing inside the workspace succeeds")
    func writeInsideWorkspaceSucceeds() async {
        // TMPDIR is set to the writable scratch workspace, so a write there
        // round-trips. Proven inside the one command (we don't get the
        // workspace path back out — it's cleaned up on return).
        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": "echo inside-ok > \"$TMPDIR/probe.txt\" && cat \"$TMPDIR/probe.txt\""
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let p = payload(result)
        #expect((p["exit_code"] as? Int) == 0)
        #expect((p["stdout"] as? String)?.contains("inside-ok") == true)
    }

    // MARK: - timeout

    @Test("A command that overruns its timeout is killed")
    func timeoutKills() async {
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "sleep 10", "timeout_seconds": 1]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let p = payload(result)
        #expect((p["timed_out"] as? Bool) == true)
        #expect((p["note"] as? String)?.contains("terminated") == true)
    }

    // MARK: - cancellation

    @Test("Cancelling the task stops the run instead of waiting out the timeout")
    func cancellationStopsRun() async {
        let store = autoApproveStore()
        let started = Date()
        let runTask = Task { @MainActor in
            await RunCommandTool.run(
                // Would otherwise run for the full (clamped) timeout.
                arguments: argsJSON(["command": "sleep 30", "timeout_seconds": 30]),
                approval: store,
                sandbox: SandboxManager()
            )
        }
        // Give it a moment to launch, then Stop.
        try? await Task.sleep(nanoseconds: 400_000_000)
        runTask.cancel()
        let result = await runTask.value
        // Returned promptly (well under the 30s timeout) with a cancel error.
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.isError)
        #expect(result.content.contains("cancel"))
    }

    // MARK: - process-group containment

    @Test("A backgrounded child is reaped when the command returns (no leak, no hang)")
    func backgroundedChildIsReaped() async {
        // The command backgrounds a long sleep (renamed so we can find it) and
        // exits immediately. Without reliable process-group containment the
        // sleep would outlive the call — and, holding the stdout pipe, could
        // wedge the drain forever. It must be gone shortly after we return.
        let marker = "rapidbgtest-\(UUID().uuidString)"
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                     arguments: ["-f", marker]) }
        let started = Date()
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "( exec -a \(marker) sleep 120 ) & exit 0"]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        // Returned promptly — no 120s hang on the inherited pipe.
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!result.isError)

        // Give the post-exit group sweep a beat, then confirm nothing survives.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let survivors = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = survivors
        try? pgrep.run()
        pgrep.waitUntilExit()
        let out = String(decoding: survivors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out.isEmpty, "backgrounded child survived the run: \(out)")
    }

    // MARK: - process-group escape (direct child is contained)

    @Test("A direct child that escapes its process group is still killed on timeout")
    func groupEscapeIsContainedE2E() async {
        // The direct child is its OWN group's leader, so it can't `setsid` (that
        // is EPERM for a group leader). It CAN, however, `setpgid(0, getppid())`
        // to hop into the supervisor's group, leaving the child group `$GC` that
        // `kill(-$GC)` targets. Seatbelt does not mediate setpgid, so the group
        // kill alone would miss it. But teardown ALSO signals the direct child by
        // PID (`kill($kid)`): the supervisor owns `$kid` (unreaped, so no pid
        // reuse) and a parent can always SIGKILL its own child regardless of the
        // group it moved to. So the escapee is CONTAINED, not merely bounded —
        // this is the codex r16 MAJOR-1 fix. Removing the direct-pid kill would
        // let the marker survive the group sweep, so asserting it is GONE
        // afterward precisely guards that fix (and, per the r16 NIT, proves the
        // escaping path actually executed rather than a trivially-fast child).
        let marker = "rapidgrpescape-\(UUID().uuidString)"
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                     arguments: ["-f", marker]) }
        // bash execs perl → perl hops to the supervisor's group (escaping $GC) →
        // execs a renamed long sleep. All execs reuse the direct child's pid, so
        // the marker sleep IS `$kid` and the direct-pid kill reaches it.
        let cmd = "exec /usr/bin/perl -e 'use POSIX; POSIX::setpgid(0, getppid()); "
            + "exec(qq{/bin/bash}, qq{-c}, qq{exec -a \(marker) sleep 60})'"
        let started = Date()
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": cmd, "timeout_seconds": 1]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        // Returned promptly — NOT hung for the 60s sleep. (1s timeout + teardown
        // TERM/0.3s/KILL + reap + drain ≈ a few seconds; bounded at 20s.)
        #expect(Date().timeIntervalSince(started) < 20,
                "the tool hung on a group-escaping child instead of killing it")
        #expect(!result.isError)

        // The escapee left `$GC`, so only the direct-pid kill can have reaped it.
        // run() returns AFTER the supervisor reaps `$kid`, so the marker must be
        // gone. Give a brief grace, then confirm nothing survives. A regression
        // that dropped `kill($kid)` would leave this sleep alive for ~60s.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let survivors = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = survivors
        try? pgrep.run()
        pgrep.waitUntilExit()
        let out = String(decoding: survivors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out.isEmpty, "group-escaping child survived teardown: \(out)")
    }

    @Test("A group-escaping child that self-stops is killed, not orphaned and resumed")
    func selfStopEscapeIsContainedE2E() async {
        // SIGCHLD fires on a child STOP as well as an exit, so a self-`SIGSTOP`
        // child wakes the supervisor's wait WITHOUT a teardown (no control-pipe
        // EOF). If the child-terminated branch only swept the group, this child —
        // having escaped into the supervisor's group and ignoring SIGHUP — would
        // be left un-killed; once the supervisor exits, the kernel orphans its
        // stopped group and delivers SIGCONT, resuming an uncontrolled command
        // (codex r17 MAJOR). The fix SIGKILLs `$kid` directly in that branch too
        // (SIGKILL terminates a stopped process before it can resume). So the
        // marker command after the STOP must NEVER run.
        let marker = "rapidstopescape-\(UUID().uuidString)"
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                     arguments: ["-f", marker]) }
        // Escape the group, ignore SIGHUP, self-stop; only a kernel SIGCONT after
        // orphaning would reach the `exec` — which must not happen.
        let cmd = "exec /usr/bin/perl -e '"
            + "use POSIX; POSIX::setpgid(0, getppid()); $SIG{HUP} = qq{IGNORE}; "
            + "kill(qq{STOP}, $$); "
            + "exec(qq{/bin/bash}, qq{-c}, qq{exec -a \(marker) sleep 60})'"
        let started = Date()
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": cmd]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        // The supervisor SIGKILLs the stopped child and reaps it — returns
        // promptly, well under the 30s default timeout.
        #expect(Date().timeIntervalSince(started) < 20,
                "the tool hung on a self-stopped escaping child")
        #expect(!result.isError)

        // The child was killed WHILE stopped, so it never reached the marker
        // `exec`. A regression that dropped the direct kill would let the kernel
        // resume it, and the marker sleep would be alive here.
        try? await Task.sleep(nanoseconds: 900_000_000)
        let survivors = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = survivors
        try? pgrep.run()
        pgrep.waitUntilExit()
        let out = String(decoding: survivors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out.isEmpty, "self-stopped escaping child was resumed after teardown: \(out)")
    }

    // MARK: - output cap

    @Test("Oversized stdout is truncated and flagged")
    func outputCapTruncates() async {
        let result = await RunCommandTool.run(
            arguments: argsJSON(["command": "yes a | head -c 200000"]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let p = payload(result)
        #expect((p["stdout_truncated"] as? Bool) == true)
        let out = (p["stdout"] as? String) ?? ""
        #expect(out.utf8.count <= RunCommandTool.outputByteCap + 8,
                "captured stdout must be capped near \(RunCommandTool.outputByteCap) bytes")
    }

    // MARK: - environment scrub (unit)

    @Test("Scrubbed environment is a minimal allowlist, not the app's env")
    func scrubbedEnvIsAllowlist() {
        // A secret the app might hold must not survive into the child.
        setenv("RAPID_TEST_LEAKED_SECRET", "super-secret", 1)
        defer { unsetenv("RAPID_TEST_LEAKED_SECRET") }

        let ws = "/private/tmp/rapid-ws-probe"
        let env = RunCommandTool.scrubbedEnvironment(workspace: ws)

        #expect(env["RAPID_TEST_LEAKED_SECRET"] == nil, "secret leaked into sandbox env")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["TMPDIR"] == ws)
        #expect(env["HOME"] == NSHomeDirectory())
        let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "TERM", "USER", "LOGNAME"]
        #expect(Set(env.keys).isSubset(of: allowed),
                "unexpected env keys: \(Set(env.keys).subtracting(allowed))")
    }

    // MARK: - Seatbelt profile (unit)

    @Test("A case-variant of a credential path is denied by the kernel")
    func caseVariantCredentialReadDeniedE2E() throws {
        // macOS ships APFS case-INSENSITIVE, so `~/.SSH/id_rsa` is the SAME
        // inode as `~/.ssh/…`. Seatbelt's `subpath` deny matches the physical
        // path case-insensitively on such a volume, so BOTH spellings must be
        // refused. (On a case-sensitive volume `.SSH` is a genuinely different,
        // non-secret path — so the variant assertions there are skipped, not
        // vacuously "passed": the exact-case denial is still checked.)
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "rapid-home-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        let secret = "TOPSECRET-\(UUID().uuidString)"
        try secret.write(toFile: home + "/.ssh/id_rsa", atomically: true, encoding: .utf8)
        // A readable control file proves the sandbox permits ordinary reads
        // (so a denial below is the rule firing, not a blanket read failure).
        try "public-ok".write(toFile: home + "/readme.txt", atomically: true, encoding: .utf8)

        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let resolvedHome = real(home)
        let profile = RunCommandTool.seatbeltProfile(writableRoots: [], home: resolvedHome)

        func sandboxedCat(_ path: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, "/bin/cat", path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        // Control: an ordinary file in the same home reads fine.
        #expect(sandboxedCat(resolvedHome + "/readme.txt").contains("public-ok"),
                "the sandbox must still permit ordinary reads")
        // Exact-case credential read is denied.
        #expect(!sandboxedCat(resolvedHome + "/.ssh/id_rsa").contains(secret),
                "the credential store read must be denied")
        // Only assert the case-variant when it actually resolves to the same
        // secret file (i.e. this is a case-insensitive volume) — otherwise the
        // "denial" would be a vacuous file-not-found, proving nothing.
        if fm.fileExists(atPath: resolvedHome + "/.SSH/id_rsa") {
            #expect(!sandboxedCat(resolvedHome + "/.SSH/id_rsa").contains(secret),
                    "a case-variant of the credential path must not bypass the deny")
            #expect(!sandboxedCat(resolvedHome + "/.Ssh/id_rsa").contains(secret))
        }
    }

    @Test("Profile is deny-default and re-opens only what a local command needs")
    func profileIsDenyDefault() {
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/private/var/folders/xx/ws"], home: "/Users/tester")
        // The base policy MUST be deny-default — (allow default) would leave
        // Mach/XPC/LaunchServices/Apple-Events open so `open https://…` could
        // broker a network fetch outside the sandbox.
        #expect(profile.contains("(deny default)"))
        #expect(!profile.contains("(allow default)"),
                "allow-default leaves the network-broker escape open")
        // Re-opened essentials for build/test/inspect commands.
        #expect(profile.contains("(allow process-exec*)"))
        #expect(profile.contains("(allow file-read*)"))
        // Hard no-network boundary (redundant under deny-default, kept explicit).
        #expect(profile.contains("(deny network*)"))
        // sysctl is allowed (uname/getconf/the linker need it) but the
        // process-arg selectors that leak a parent's ENVIRONMENT are denied —
        // otherwise a command could read Rapid's env via kern.procargs2 and
        // recover the API keys the env scrub withheld.
        #expect(profile.contains("(allow sysctl-read)"))
        #expect(profile.contains("kern.procargs2"))
        #expect(profile.contains("(deny sysctl-read"))
    }

    @Test("Profile denies terminal/console/PTY devices both directions (no fake-prompt exfil)")
    func profileDeniesTerminalDevices() {
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/private/var/folders/xx/ws"], home: "/Users/tester")
        // A command with a controlling tty (Rapid launched from a shell) could
        // write a fake `Password:` to /dev/tty and read the reply back, past the
        // /dev/null stdin severance. tty/pty/console must be denied for BOTH
        // read and write with EXPLICIT `file-read*` / `file-write*` operations
        // (a `file*` deny does NOT override the global `(allow file-read*)`), and
        // /dev/tty must NOT sit in the device write-allow.
        #expect(profile.contains("(deny file-read*"))
        #expect(profile.contains("(deny file-write*"))
        // The tty/pty/console filters appear under BOTH deny operations.
        for filter in ["(regex \"^/dev/tty\")", "(regex \"^/dev/pty\")",
                       "(literal \"/dev/ptmx\")", "(literal \"/dev/console\")"] {
            // once under file-read*, once under file-write*
            let occurrences = profile.components(separatedBy: filter).count - 1
            #expect(occurrences >= 2, "\(filter) must be denied for both read and write")
        }
        #expect(!profile.contains("    (literal \"/dev/tty\")"),
                "/dev/tty must not be in the device write-allow list")
        // The innocuous device writes scripts need remain allowed.
        #expect(profile.contains("(literal \"/dev/null\")"))
        #expect(profile.contains("(literal \"/dev/stderr\")"))
    }

    @Test("A tty device (/dev/ptmx) read-open is denied by the real profile, end-to-end")
    func ttyDeviceReadDeniedE2E() async {
        // /dev/tty itself needs a controlling terminal to open, which a test
        // process lacks — but /dev/ptmx is denied by the SAME rule and opens
        // unconditionally, so it's the load-bearing proof that the kernel
        // applies the read deny. Opening it for read (`: < …`) returns at once
        // (a plain read of it would block on the master, hence no `cat`).
        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": ": < /dev/ptmx && echo OPENED || echo DENIED", "timeout_seconds": 20
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let out = (payload(result)["stdout"] as? String) ?? ""
        #expect(out.contains("DENIED"), "reading a PTY device must be denied by the sandbox")
        #expect(!out.contains("OPENED"))
    }

    @Test("Profile denies reading credential stores, re-denies persistence + prefs writes")
    func profileShape() {
        let home = "/Users/tester"
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/private/var/folders/xx/ws"], home: home)

        // The granted workspace is writable.
        #expect(profile.contains("(allow file-write*"))
        #expect(profile.contains("/private/var/folders/xx/ws"))
        // Credential stores + token configs are read-denied. Each protected
        // path appears only inside its deny rule, so a plain `contains` proves
        // it is in the deny set. (Seatbelt matches these case-insensitively on
        // APFS — a `~/.SSH` variant can't bypass; proven in
        // ``caseVariantCredentialReadDeniedE2E``.)
        #expect(profile.contains("(deny file-read*"))
        #expect(profile.contains("\(home)/.ssh"))
        #expect(profile.contains("\(home)/.aws"))
        #expect(profile.contains("\(home)/.gnupg"))
        #expect(profile.contains("\(home)/.git-credentials"))
        #expect(profile.contains("\(home)/.config/gh"))
        #expect(profile.contains("\(home)/.azure"))
        #expect(profile.contains("\(home)/Library/Keychains"))
        // Rapid's OWN secret store (MCP server env API keys live in
        // ~/.config/rapid-mlx/mcp.json) — reads are otherwise open, so this
        // deny is what stops an approved `cat` from handing it to the model.
        #expect(profile.contains("\(home)/.config/rapid-mlx"))
        // Hugging Face access tokens (this app uses the HF cache) + ~/.gitconfig
        // (can carry `http.*.extraHeader` creds) are read-denied too.
        #expect(profile.contains("\(home)/.huggingface"))
        #expect(profile.contains("\(home)/.cache/huggingface/token"))
        #expect(profile.contains("\(home)/.gitconfig"))
        // Cargo registry auth tokens (the specific files, not all of ~/.cargo —
        // a build must still read ~/.cargo/config.toml + the registry cache).
        #expect(profile.contains("\(home)/.cargo/credentials.toml"))
        #expect(profile.contains("\(home)/.cargo/credentials"))
        // Per-app sandbox containers hold private app data (some stash tokens
        // outside the Keychain); a build never reads them, so they are
        // read-denied wholesale.
        #expect(profile.contains("\(home)/Library/Containers"))
        #expect(profile.contains("\(home)/Library/Group Containers"))
        // Persistence / code-exec configs are write-denied even under a
        // broad grant (the trailing deny wins — last match).
        #expect(profile.contains("\(home)/.zshrc"))
        // Logout scripts run on shell exit — also a persistence vector.
        #expect(profile.contains("\(home)/.zlogout"))
        #expect(profile.contains("\(home)/.bash_logout"))
        // The WHOLE of ~/Library is write-denied (it holds a broad code-exec
        // plugin surface + the preference plists — a direct plist write could
        // flip Rapid's own auto-approve). The subtree deny covers LaunchAgents,
        // Preferences, Services/*.workflow, … without enumerating each.
        #expect(profile.contains("(subpath \"\(home)/Library\")"))
    }

    @Test("A symlinked credential dir is denied at both its lexical and resolved path")
    func profileFollowsCredentialSymlinks() throws {
        // Dotfile managers commonly make ~/.ssh a symlink into a repo. Seatbelt
        // matches PHYSICAL paths, so a deny keyed only on the lexical ~/.ssh
        // would miss — the read resolves to the target, which the broad
        // (allow file-read*) still permits. The profile must deny BOTH.
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "rapid-home-\(UUID().uuidString)"
        let secretRepo = NSTemporaryDirectory() + "rapid-dotfiles-\(UUID().uuidString)/ssh"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: secretRepo, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: home)
            try? fm.removeItem(atPath: (secretRepo as NSString).deletingLastPathComponent)
        }
        // ~/.ssh -> …/dotfiles/ssh (the real credential store).
        try fm.createSymbolicLink(atPath: home + "/.ssh", withDestinationPath: secretRepo)

        // Resolve both sides the way the profile does (realpath), since the
        // temp dir itself may be under a symlink (/var -> /private/var).
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let resolvedHome = real(home)
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: [], home: resolvedHome)

        // The lexical node under home…
        #expect(profile.contains("\(resolvedHome)/.ssh"))
        // …AND the symlink's resolved target are both denied.
        #expect(profile.contains(real(secretRepo)),
                "a symlinked ~/.ssh must also deny its realpath target")
    }

    @Test("Rename-relocation guard is root-aware: empty for a narrow grant")
    func relocationGuardEmptyForNarrowGrant() {
        // A specific project-folder grant contains no secret's ancestor, so no
        // relocation is possible and the guard adds nothing (no over-restriction
        // in the common case).
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/Users/tester/code/proj"], home: "/Users/tester")
        #expect(!profile.contains("(deny file-write-unlink"),
                "a narrow grant needs no rename guard")
    }

    @Test("Rename-relocation guard locks the ancestor chain under a broad home grant")
    func relocationGuardUnderHomeGrant() {
        // Denying WRITE to ~/.config/rapid-mlx doesn't stop `mv ~/.config ~/.x`
        // (a write to ~, which a broad home grant permits) relocating the secret
        // to a physical path the deny rules never mention. Under a ~ grant the
        // guard must deny UNLINK of the ancestor chain so the subtree can't be
        // moved.
        let home = "/Users/tester"
        let profile = RunCommandTool.seatbeltProfile(writableRoots: [home], home: home)
        #expect(profile.contains("(deny file-write-unlink"))
        // Unprotected parents of nested secrets (exact-match `literal`).
        #expect(profile.contains(literalRule("\(home)/.config")))
        // ~/Library is itself a protected SUBTREE, so its own rename is already
        // blocked by the file-write* subtree deny — it needn't (and doesn't)
        // appear in the relocation guard, which only lists UNPROTECTED ancestors.
        #expect(profile.contains("(subpath \"\(home)/Library\")"))
        // Multi-level: the browser cookie store sits three deep, so its
        // unprotected intermediate ~/Library/Application Support is guarded.
        #expect(profile.contains(literalRule("\(home)/Library/Application Support")))
        // $HOME itself is guarded once it's inside a writable root (belt: harmless
        // when only ~ is granted, load-bearing once a parent grant makes ~
        // renamable — see the /Users case).
        #expect(profile.contains(literalRule(home)))
    }

    @Test("Rename-relocation guard fires even for a whole-disk (/) grant")
    func relocationGuardUnderRootGrant() {
        // A `/` grant contains everything; the naive `w + "/"` prefix test
        // becomes "//" and never matches, which would emit NO guard while still
        // allowing `(subpath "/")` writes — so `mv ~/.config ~/.x` would leak.
        // The whole-disk case must be special-cased.
        let home = "/Users/alice"
        let profile = RunCommandTool.seatbeltProfile(writableRoots: ["/"], home: home)
        #expect(profile.contains("(deny file-write-unlink"))
        #expect(profile.contains(literalRule(home)))
        #expect(profile.contains(literalRule("\(home)/.config")))
        // ~/Library's own rename is blocked by the file-write* subtree deny.
        #expect(profile.contains("(subpath \"\(home)/Library\")"))
    }

    @Test("Rename-relocation guard covers $HOME when a parent like /Users is granted")
    func relocationGuardUnderUsersGrant() {
        // A recursive /Users grant makes `mv /Users/alice /Users/x` possible,
        // relocating EVERY protected inode. The guard must deny unlink of
        // /Users/alice (=$HOME) — reachable only because the guard is bounded by
        // the writable root, not hard-stopped at $HOME.
        let home = "/Users/alice"
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/Users"], home: home)
        #expect(profile.contains("(deny file-write-unlink"))
        #expect(profile.contains(literalRule(home)),
                "$HOME must be unlink-guarded when its parent is a writable root")
    }

    @Test("Rename guard covers the symlink TARGET chain of a symlinked ancestor")
    func relocationGuardCoversSymlinkTargetChain() throws {
        // ~/.config -> ~/dotfiles/config with a ~ grant. Guarding only the
        // lexical ~/.config misses `mv ~/dotfiles ~/.x`, which relocates the
        // PHYSICAL secret. The guard must walk the physical variant too and lock
        // ~/dotfiles.
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "rapid-home-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home + "/dotfiles/config/rapid-mlx",
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        try fm.createSymbolicLink(atPath: home + "/.config",
                                  withDestinationPath: home + "/dotfiles/config")

        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let resolvedHome = real(home)
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: [resolvedHome], home: resolvedHome)
        // The physical target's parent (~/dotfiles) must be unlink-guarded.
        #expect(profile.contains(literalRule("\(resolvedHome)/dotfiles")),
                "the symlink target chain must be rename-guarded, not just the lexical path")
    }

    @Test("A protected leaf under a symlinked ancestor is denied at its physical target")
    func profileFollowsSymlinkedAncestorOfMissingLeaf() throws {
        // The nastier symlink case: ~/.config is a symlink into a dotfiles repo
        // and the protected leaf ~/.config/gh does NOT exist yet. A plain
        // realpath(~/.config/gh) fails, so a naive deny would be lexical-only —
        // and `mkdir -p ~/.config/gh` (writing the physical …/dotfiles/config/gh)
        // would slip past a broad home write grant. The profile must deny the
        // reconstructed physical target too.
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "rapid-home-\(UUID().uuidString)"
        let dotfilesConfig = NSTemporaryDirectory() + "rapid-dotfiles-\(UUID().uuidString)/config"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dotfilesConfig, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: home)
            try? fm.removeItem(atPath: (dotfilesConfig as NSString).deletingLastPathComponent)
        }
        // ~/.config -> …/dotfiles/config, but ~/.config/gh is never created.
        try fm.createSymbolicLink(atPath: home + "/.config", withDestinationPath: dotfilesConfig)

        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let resolvedHome = real(home)
        let profile = RunCommandTool.seatbeltProfile(writableRoots: [], home: resolvedHome)

        // The physical target of the still-nonexistent ~/.config/gh must appear
        // in the deny set (peeled to the symlinked ancestor + re-attached leaf).
        let physicalGH = real(dotfilesConfig) + "/gh"
        #expect(profile.contains(physicalGH),
                "a protected leaf under a symlinked parent must deny its physical target")
    }

    @Test("run_command's persist deny mirrors write_file's code-exec surface")
    func profileMirrorsWriteFileExecSurface() {
        // Anti-drift: every home-relative code-exec/persistence path write_file
        // blocks must ALSO be denied by run_command's Seatbelt profile, or the
        // shell tool becomes a bypass for the file tools. Both consume the same
        // shared constant, so this asserts the profile actually emits each.
        let home = "/Users/tester"
        let profile = RunCommandTool.seatbeltProfile(writableRoots: [home], home: home)
        for rel in FilesystemTools.homeRelativeExecPersistencePaths {
            #expect(profile.contains("(subpath \"\(home)/\(rel)\")"),
                    "code-exec path \(rel) is blocked by write_file but not run_command")
        }
        // The `.git` path-component deny (repo hooks / config are executed by
        // Git) — a plain regex, matched case-insensitively by Seatbelt on APFS.
        #expect(profile.contains("(regex \"/\\.git(/|$)\")"))
        // ...and the conventional `core.hooksPath` dirs, equally auto-executed.
        #expect(profile.contains("(regex \"/\\.husky(/|$)\")"))
        #expect(profile.contains("(regex \"/\\.githooks(/|$)\")"))
    }

    @Test("Planting a .git hook is blocked even inside the writable workspace")
    func gitHookWriteBlocked() async {
        // $TMPDIR is the writable scratch workspace. Even there, creating a
        // `.git` component (which Git would later execute from) must be refused —
        // otherwise run_command is a persistence primitive the file tools block.
        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": "mkdir -p \"$TMPDIR/repo/.git/hooks\" "
                    + "&& echo evil > \"$TMPDIR/repo/.git/hooks/pre-commit\" "
                    + "&& echo WROTE || echo BLOCKED"
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let out = (payload(result)["stdout"] as? String) ?? ""
        #expect(!out.contains("WROTE"), "planting a .git hook must be blocked by the sandbox")
        #expect(out.contains("BLOCKED"))
    }

    @Test("Planting a core.hooksPath hook (.husky / .githooks) is blocked in the workspace")
    func gitHooksPathDirsWriteBlockedE2E() async {
        // Git can be pointed at an alternate hooks dir via `core.hooksPath`;
        // Husky (`.husky/`) and the common `.githooks/` are the conventional
        // choices, auto-run on the next git command. Blocking `.git` alone
        // would let the model plant one of these instead, so the profile denies
        // those directory names too — verified end-to-end inside the writable
        // workspace where an ordinary write DOES succeed.
        for dir in [".husky", ".githooks"] {
            let result = await RunCommandTool.run(
                arguments: argsJSON([
                    "command": "mkdir -p \"$TMPDIR/repo/\(dir)\" "
                        + "&& echo evil > \"$TMPDIR/repo/\(dir)/pre-commit\" "
                        + "&& echo WROTE || echo BLOCKED"
                ]),
                approval: autoApproveStore(),
                sandbox: SandboxManager()
            )
            #expect(!result.isError)
            let out = (payload(result)["stdout"] as? String) ?? ""
            #expect(!out.contains("WROTE"), "planting a \(dir) hook must be blocked by the sandbox")
            #expect(out.contains("BLOCKED"))
        }
    }

    @Test("Planting a logout script is blocked even under a broad home grant")
    func logoutScriptWriteBlockedE2E() throws {
        // A logout script (~/.zlogout, ~/.bash_logout) runs when a login shell
        // exits — a persistence + code-exec vector. Under a broad home write
        // grant the profile's trailing persistence deny must still refuse it,
        // even though the home is otherwise writable. Driven straight through
        // sandbox-exec so the home can be a throwaway dir (the tool itself uses
        // the real $HOME).
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "rapid-home-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        let resolvedHome = real(home)
        // The throwaway home lives under /private/var/folders, which the trailing
        // absolute-deny list refuses. Production re-allows the tool's real writable
        // base the same way — pass it as the scratch workspace so an ordinary write
        // lands while the LATER persistence deny still wins for logout scripts.
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: [resolvedHome], home: resolvedHome,
            scratchWorkspace: resolvedHome)

        func shWrite(_ path: String) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, "/bin/sh", "-c", "echo evil > '\(path)'"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            return fm.fileExists(atPath: path)
        }
        #expect(!shWrite(resolvedHome + "/.zlogout"), "~/.zlogout write must be blocked")
        #expect(!shWrite(resolvedHome + "/.bash_logout"), "~/.bash_logout write must be blocked")
        // Control: an ordinary file in the granted home DOES write.
        #expect(shWrite(resolvedHome + "/notes.txt"), "an ordinary home write must still succeed")
    }

    @Test("A whole-disk (/) grant still cannot write the absolute protected roots")
    func rootGrantCannotWriteAbsoluteBlockedRootsE2E() throws {
        // A folder grant for `/` (obtainable via allow-folder on any path) must
        // NOT bypass write_file's absolute protected-path policy: /usr, /Library,
        // /opt, /private/var, … stay read-only even under `(allow file-write*
        // (subpath "/"))` (codex r14 MAJOR). Proven with a real USER-WRITABLE
        // path under a blocked root — a temp dir under /private/var/folders — so
        // the denial is attributable to the sandbox, not to POSIX perms (a
        // /usr/local/bin write would fail for a non-root user regardless).
        let fm = FileManager.default
        func real(_ p: String) -> String {
            var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
            return p.withCString { realpath($0, &buf) } != nil
                ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : p
        }
        // A path under a blocked root that this user CAN write when unsandboxed.
        let underVar = NSTemporaryDirectory() + "rapid-blocked-\(UUID().uuidString)"
        try fm.createDirectory(atPath: underVar, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: underVar) }
        let resolvedBlocked = real(underVar)
        // The tool's own scratch workspace — also under /private/var — is the
        // ONE re-allowed exception; a granted path that merely happens to sit
        // under a blocked root is NOT.
        let ws = NSTemporaryDirectory() + "rapid-ws-\(UUID().uuidString)"
        try fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: ws) }
        let resolvedWs = real(ws)
        // Only meaningful if the temp area really is under a blocked root.
        try #require(resolvedBlocked.hasPrefix("/private/var/"))
        try #require(resolvedWs.hasPrefix("/private/var/"))

        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/"], home: real(NSHomeDirectory()),
            scratchWorkspace: resolvedWs)

        func shWrite(_ path: String) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, "/bin/sh", "-c", "echo evil > '\(path)'"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            return fm.fileExists(atPath: path)
        }
        // Under the `/` grant, a write to the blocked-root path is refused …
        #expect(!shWrite(resolvedBlocked + "/pwned.txt"),
                "a / grant must not write a /private/var path (absolute deny wins)")
        // … while the tool's own re-allowed scratch workspace still writes.
        #expect(shWrite(resolvedWs + "/ok.txt"),
                "the scratch workspace must stay writable under the / grant")
    }

    @Test("The command's stdin IS /dev/null, not the app's inherited descriptor")
    func stdinIsSevered() async {
        // Have the CHILD identify its own stdin: `/dev/fd/0 -ef /dev/null` is
        // true only when fd 0 is the null device. This positively proves the
        // tool set standardInput = nullDevice (a "reads empty / returns
        // promptly" check is vacuous — an empty inherited pipe also EOFs), and
        // it does so WITHOUT mutating this process's own fd 0, so it can't race
        // parallel tests (codex r12 NIT).
        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": "test /dev/fd/0 -ef /dev/null && echo NULLSTDIN || echo OTHERSTDIN",
                "timeout_seconds": 20
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let p = payload(result)
        #expect((p["timed_out"] as? Bool) != true)
        let out = (p["stdout"] as? String) ?? ""
        #expect(out.contains("NULLSTDIN"), "child stdin is not /dev/null — it was inherited")
        #expect(!out.contains("OTHERSTDIN"))
    }

    @Test("An inherited HIGH fd (5000) is severed, not just fd 0")
    func highFdIsSevered() async throws {
        // The shim closes EVERY inherited fd >=3 by enumerating /dev/fd, not a
        // bounded range, so a secret on a high descriptor can't be siphoned via
        // `cat <&5000`. Plant fd 5000 in this process pointing at a marker file
        // (dup2 clears close-on-exec so Foundation inherits it), run
        // `cat <&5000`, and assert the marker never reaches the child. fd 5000
        // is unique to this test, so unlike fd 0 there is no cross-test race.
        let fm = FileManager.default
        let markerPath = NSTemporaryDirectory() + "rapid-hf-\(UUID().uuidString).txt"
        let marker = "HIGH_FD_SECRET_5000"
        try (marker + "\n").write(toFile: markerPath, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: markerPath) }

        let fd = open(markerPath, O_RDONLY)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd); close(5000) } }
        #expect(dup2(fd, 5000) >= 0)   // fd 5000 → the marker file, no CLOEXEC

        let result = await RunCommandTool.run(
            arguments: argsJSON([
                "command": "cat <&5000 2>&1 || true", "timeout_seconds": 20
            ]),
            approval: autoApproveStore(),
            sandbox: SandboxManager()
        )
        #expect(!result.isError)
        let out = (payload(result)["stdout"] as? String) ?? ""
        #expect(!out.contains(marker),
                "a secret on inherited fd 5000 leaked — the close-all did not reach it")
    }

    @Test("Returned content is bounded even when output is control-byte heavy")
    func escapedBudgetClampBoundsContent() {
        // The raw 64 KiB capture cap does not bound the RETURNED tool content:
        // a control byte escapes to `\u00XX` (6 bytes) and invalid UTF-8 decodes
        // to U+FFFD, so an adversarial stream could inflate ~6×. The escaped
        // budget clamp must cut on a scalar boundary so the escaped form fits.
        let controls = String(repeating: "\u{01}", count: 1000)   // each →  (6B)
        let (clamped, truncated) = RunCommandTool.clampToEscapedBudget(controls, budget: 600)
        #expect(truncated)
        #expect(clamped.unicodeScalars.count == 100, "600 / 6 bytes-per-control = 100 scalars")
        // The clamped string's own escaped size stays within budget.
        let escaped = clamped.unicodeScalars.reduce(0) { $0 + ($1.value < 0x20 ? 6 : String($1).utf8.count) }
        #expect(escaped <= 600)
        // A short clean string passes through untouched (no false truncation).
        let (clean, cut) = RunCommandTool.clampToEscapedBudget("hello world", budget: 600)
        #expect(!cut && clean == "hello world")

        // Forward slash escapes to `\/` (2 bytes) under JSONSerialization, so it
        // must count as 2 — a path-heavy stream would otherwise slip ~2× past.
        let slashes = String(repeating: "/", count: 500)
        let (sClamped, sTrunc) = RunCommandTool.clampToEscapedBudget(slashes, budget: 200)
        #expect(sTrunc)
        #expect(sClamped.unicodeScalars.count == 100, "200 / 2 bytes-per-slash = 100")
        // U+2028 and an astral scalar are emitted RAW (not \u-escaped), so they
        // cost their UTF-8 width — never truncated below what fits.
        let (uc, ucCut) = RunCommandTool.clampToEscapedBudget("\u{2028}\u{1F600}", budget: 600)
        #expect(!ucCut && uc == "\u{2028}\u{1F600}")
    }

    @Test("Profile quotes paths so a crafted root can't break out of the sexp")
    func profileQuotesPaths() {
        // A root containing a quote/backslash would, unescaped, terminate the
        // (subpath "...") string early. The tool filters such roots out before
        // calling this, but the quoter must still escape defensively.
        let profile = RunCommandTool.seatbeltProfile(
            writableRoots: ["/tmp/a\"b\\c"], home: "/Users/tester")
        // Assert the crafted root's OWN dangerous characters are escaped — both
        // the embedded quote and backslash — so it can't terminate the sexp
        // string early. A generic "contains a backslash" check would pass
        // vacuously on the profile's ordinary regex escapes (e.g. `\.`), so we
        // pin the exact escaped rendering of this specific root.
        #expect(profile.contains("/tmp/a\\\"b\\\\c"),
                "the crafted root's quote and backslash must both be escaped in place")
    }
}
