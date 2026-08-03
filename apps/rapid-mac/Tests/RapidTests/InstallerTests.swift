import Foundation
import Testing
@testable import Rapid

@Suite("Installer — DMG install state machine")
@MainActor
struct InstallerTests {
    // MARK: - Builder

    /// Build an Installer wired with cooperative mocks that record
    /// the call order. Sub-tests override only the closures whose
    /// behaviour they want to control.
    private func buildInstaller(
        downloaderResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/mock.dmg")),
        mounterResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/mock-mount")),
        appFinderResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/mock-mount/Rapid.app")),
        codesignResult: Result<Void, Error> = .success(()),
        stagedCopyResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/staged.app")),
        helperSpawnResult: Result<Void, Error> = .success(()),
        progressSequence: [Double] = [0.25, 0.50, 0.75, 1.0]
    ) -> (Installer, CallRecorder) {
        let recorder = CallRecorder()
        let installer = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, progress in
                recorder.record(.download)
                for p in progressSequence {
                    await MainActor.run { progress(p) }
                }
                return try downloaderResult.get()
            },
            mounter: { _ in
                recorder.record(.mount)
                return try mounterResult.get()
            },
            appFinder: { _ in
                recorder.record(.findApp)
                return try appFinderResult.get()
            },
            codesignVerifier: { _ in
                recorder.record(.verify)
                _ = try codesignResult.get()
            },
            stagedCopier: { _, _ in
                recorder.record(.stageCopy)
                return try stagedCopyResult.get()
            },
            unmounter: { _ in
                recorder.record(.unmount)
            },
            helperSpawner: { _, _, _ in
                recorder.record(.spawnHelper)
                _ = try helperSpawnResult.get()
            },
            terminator: {
                recorder.record(.terminate)
            }
        )
        return (installer, recorder)
    }

    // MARK: - Happy path

    @Test("Happy path runs all stages in order and terminates last")
    func happyPathRunsAllStages() async {
        let (installer, recorder) = buildInstaller()
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        #expect(recorder.events == [
            .download,
            .mount,
            .findApp,
            .verify,
            .stageCopy,
            .unmount,
            .spawnHelper,
            .terminate,
        ])
        // Stage ends at ``.relaunching`` because we replaced the
        // terminator with a no-op recorder — production NSApp.terminate
        // would tear down the process here, so the stage never has a
        // chance to roll past it. That's the contract: the final
        // observable state is ``.relaunching``, never ``.idle`` after
        // a successful install.
        if case .relaunching = installer.stage {
            // ok
        } else {
            Issue.record("expected .relaunching, got \(installer.stage)")
        }
    }

    @Test("Download progress updates the stage's fractional progress")
    func downloadProgressUpdatesStage() async {
        // Deterministic synchronisation: the downloader signals
        // ``progressFired`` AFTER it has propagated progress(0.5) to
        // the installer; the test waits on that signal before
        // reading stage. Earlier impl used ``Task.sleep(50ms)`` and
        // flaked under full-suite contention because MainActor hops
        // weren't guaranteed to settle within the sleep window.
        let progressFired = AsyncStream<Void>.makeStream()
        let progressGate = AsyncStream<Double>.makeStream()
        let (installer, _) = buildInstaller(
            downloaderResult: .success(URL(fileURLWithPath: "/tmp/x.dmg")),
            progressSequence: []
        )
        let mocked = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, progress in
                await MainActor.run { progress(0.5) }
                progressFired.continuation.yield(())
                for await fraction in progressGate.stream {
                    await MainActor.run { progress(fraction) }
                    if fraction >= 1.0 { break }
                }
                return URL(fileURLWithPath: "/tmp/x.dmg")
            },
            mounter: { _ in URL(fileURLWithPath: "/tmp/mock-mount") },
            appFinder: { _ in URL(fileURLWithPath: "/tmp/mock-mount/Rapid.app") },
            codesignVerifier: { _ in },
            stagedCopier: { _, _ in URL(fileURLWithPath: "/tmp/staged.app") },
            unmounter: { _ in },
            helperSpawner: { _, _, _ in },
            terminator: { }
        )
        let installTask = Task { await mocked.install(from: URL(string: "https://example.com/Rapid.dmg")!) }
        // Wait until the downloader has signalled it propagated 0.5.
        var iter = progressFired.stream.makeAsyncIterator()
        _ = await iter.next()
        if case .downloading(let p) = mocked.stage {
            #expect(p == 0.5)
        } else {
            Issue.record("expected .downloading(0.5), got \(mocked.stage)")
        }
        // Drive to completion and join.
        progressGate.continuation.yield(1.0)
        progressGate.continuation.finish()
        progressFired.continuation.finish()
        await installTask.value
        _ = installer  // silence unused
    }

    @Test("Progress > 1.0 is clamped so the UI doesn't render past 100%")
    func progressIsClamped() async {
        let progressFired = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Double>.makeStream()
        let bad = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, progress in
                await MainActor.run { progress(42.0) }
                progressFired.continuation.yield(())
                for await _ in gate.stream { break }
                return URL(fileURLWithPath: "/tmp/x.dmg")
            },
            mounter: { _ in URL(fileURLWithPath: "/tmp/m") },
            appFinder: { _ in URL(fileURLWithPath: "/tmp/m/Rapid.app") },
            codesignVerifier: { _ in },
            stagedCopier: { _, _ in URL(fileURLWithPath: "/tmp/s.app") },
            unmounter: { _ in },
            helperSpawner: { _, _, _ in },
            terminator: { }
        )
        let task = Task { await bad.install(from: URL(string: "https://example.com/Rapid.dmg")!) }
        var iter = progressFired.stream.makeAsyncIterator()
        _ = await iter.next()
        if case .downloading(let p) = bad.stage {
            #expect(p == 1.0)  // clamped, not 42.0
        } else {
            Issue.record("expected clamped .downloading, got \(bad.stage)")
        }
        gate.continuation.yield(1.0)
        gate.continuation.finish()
        progressFired.continuation.finish()
        await task.value
    }

    // MARK: - Failure paths

    @Test("Download failure surfaces .failed and never touches mount")
    func downloadFailureStopsAtMount() async {
        let (installer, recorder) = buildInstaller(
            downloaderResult: .failure(InstallerError.downloadFailed("offline"))
        )
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        if case .failed(let msg) = installer.stage {
            #expect(msg.contains("Download failed"))
        } else {
            Issue.record("expected .failed, got \(installer.stage)")
        }
        #expect(recorder.events == [.download])
    }

    @Test("Mount failure surfaces .failed and never calls unmount")
    func mountFailureSkipsUnmount() async {
        let (installer, recorder) = buildInstaller(
            mounterResult: .failure(InstallerError.mountFailed("hdiutil exit 1"))
        )
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        if case .failed(let msg) = installer.stage {
            #expect(msg.contains("hdiutil"))
        } else {
            Issue.record("expected .failed, got \(installer.stage)")
        }
        #expect(!recorder.events.contains(.unmount))
        #expect(!recorder.events.contains(.spawnHelper))
        #expect(!recorder.events.contains(.terminate))
    }

    @Test("Codesign failure ALWAYS unmounts the volume")
    func codesignFailureUnmounts() async {
        // Regression guard for the defer-unmount contract — without
        // the explicit catch-then-unmount block, a thrown
        // codesignVerifier would leave the volume mounted until
        // reboot. The recorder pins the ordering.
        let (installer, recorder) = buildInstaller(
            codesignResult: .failure(InstallerError.codesignFailed("bundle corrupt"))
        )
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        if case .failed(let msg) = installer.stage {
            #expect(msg.contains("signature verification"))
        } else {
            Issue.record("expected .failed, got \(installer.stage)")
        }
        // Must contain unmount; must NOT contain spawn/terminate.
        #expect(recorder.events.contains(.unmount))
        #expect(!recorder.events.contains(.spawnHelper))
        #expect(!recorder.events.contains(.terminate))
    }

    @Test("Helper spawn failure surfaces .failed and skips terminate")
    func helperSpawnFailureSkipsTerminate() async {
        let (installer, recorder) = buildInstaller(
            helperSpawnResult: .failure(InstallerError.helperSpawnFailed("perm denied"))
        )
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        if case .failed = installer.stage {
            // ok
        } else {
            Issue.record("expected .failed, got \(installer.stage)")
        }
        // The terminator MUST NOT have fired — we don't want to
        // tear down the user's running app if we couldn't put a
        // replacement in motion.
        #expect(!recorder.events.contains(.terminate))
    }

    // MARK: - Concurrency guard

    @Test("Stage flips to .downloading BEFORE any await — closes TOCTOU re-entry")
    func stageFlipsBeforeFirstAwait() async {
        // Codex r2 #1: r1's pre-download cleanup used
        // ``await Task.detached(...).value`` which kept ``stage ==
        // .idle`` for the duration of the cleanup. A second click
        // during that window passed ``guard !isRunning`` and ran a
        // parallel pipeline. Fix: ``stage = .downloading(progress: 0)``
        // must be the FIRST write after the guard, before any
        // suspend point. This test pins that ordering.
        let pause = AsyncStream<Void>.makeStream()
        let installer = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, _ in
                // Suspend forever so we can inspect stage mid-flight.
                for await _ in pause.stream { break }
                return URL(fileURLWithPath: "/tmp/x.dmg")
            },
            mounter: { _ in URL(fileURLWithPath: "/tmp/m") },
            appFinder: { _ in URL(fileURLWithPath: "/tmp/m/Rapid.app") },
            codesignVerifier: { _ in },
            stagedCopier: { _, _ in URL(fileURLWithPath: "/tmp/s.app") },
            unmounter: { _ in },
            helperSpawner: { _, _, _ in },
            terminator: { }
        )
        // Kick the install. install() is @MainActor; before it
        // suspends on the downloader closure, it MUST set
        // stage = .downloading(0). We're already on @MainActor so
        // by the time we get to read stage after the Task launch,
        // the synchronous prefix has run.
        let task = Task { await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!) }
        // Yield once so the install Task gets to run its sync prefix.
        await Task.yield()
        #expect(installer.isRunning)
        if case .downloading = installer.stage {
            // ok
        } else {
            Issue.record("expected .downloading after sync prefix, got \(installer.stage)")
        }
        pause.continuation.yield(())
        pause.continuation.finish()
        await task.value
    }

    @Test("Overlapping install calls coalesce — second invocation is a no-op")
    func overlappingInstallsCoalesce() async {
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstGate = AsyncStream<Void>.makeStream()
        let recorder = CallRecorder()
        let custom = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, progress in
                await MainActor.run { progress(0.5) }
                firstStarted.continuation.yield(())
                for await _ in firstGate.stream { break }
                return URL(fileURLWithPath: "/tmp/x.dmg")
            },
            mounter: { _ in URL(fileURLWithPath: "/tmp/m") },
            appFinder: { _ in URL(fileURLWithPath: "/tmp/m/Rapid.app") },
            codesignVerifier: { _ in },
            stagedCopier: { _, _ in URL(fileURLWithPath: "/tmp/s.app") },
            unmounter: { _ in },
            helperSpawner: { _, _, _ in
                recorder.record(.spawnHelper)
            },
            terminator: {
                recorder.record(.terminate)
            }
        )
        let firstTask = Task { await custom.install(from: URL(string: "https://example.com/Rapid.dmg")!) }
        // Wait for the first install to reach the downloader before
        // firing the second.
        var iter = firstStarted.stream.makeAsyncIterator()
        _ = await iter.next()
        // Second install should be a no-op because ``isRunning`` is
        // true.
        await custom.install(from: URL(string: "https://example.com/Other.dmg")!)
        // Drain the first to completion.
        firstGate.continuation.yield(())
        firstGate.continuation.finish()
        firstStarted.continuation.finish()
        await firstTask.value
        // Only the first install should have driven the pipeline —
        // both download and helper spawn fire exactly once.
        #expect(recorder.events.filter { $0 == .spawnHelper }.count == 1)
        #expect(recorder.events.filter { $0 == .terminate }.count == 1)
    }

    // MARK: - Reset

    @Test("reset() returns to .idle only from a terminal state")
    func resetOnlyFromTerminal() async {
        let (installer, _) = buildInstaller(
            downloaderResult: .failure(InstallerError.downloadFailed("offline"))
        )
        await installer.install(from: URL(string: "https://example.com/Rapid.dmg")!)
        if case .failed = installer.stage {
            // ok
        } else {
            Issue.record("setup: expected .failed")
            return
        }
        installer.reset()
        #expect(installer.stage == .idle)
    }

    @Test("reset() is a no-op while a stage is in flight")
    func resetIsNoopWhileRunning() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let inflight = Installer(
            installedAppURL: URL(fileURLWithPath: "/Applications/Rapid.app"),
            downloader: { _, progress in
                await MainActor.run { progress(0.5) }
                started.continuation.yield(())
                for await _ in gate.stream { break }
                return URL(fileURLWithPath: "/tmp/x.dmg")
            },
            mounter: { _ in URL(fileURLWithPath: "/tmp/m") },
            appFinder: { _ in URL(fileURLWithPath: "/tmp/m/Rapid.app") },
            codesignVerifier: { _ in },
            stagedCopier: { _, _ in URL(fileURLWithPath: "/tmp/s.app") },
            unmounter: { _ in },
            helperSpawner: { _, _, _ in },
            terminator: { }
        )
        let task = Task { await inflight.install(from: URL(string: "https://example.com/Rapid.dmg")!) }
        var iter = started.stream.makeAsyncIterator()
        _ = await iter.next()
        // Confirm we ARE running.
        #expect(inflight.isRunning)
        inflight.reset()
        // Stage must not have rolled to .idle — that would be the
        // bug.
        if case .idle = inflight.stage {
            Issue.record("reset() rolled .idle from a running stage; expected no-op")
        }
        gate.continuation.yield(())
        gate.continuation.finish()
        started.continuation.finish()
        await task.value
    }
}

// MARK: - hdiutil plist parser

@Suite("Installer.parseHdiutilMountPoint")
struct InstallerPlistParserTests {
    @Test("Parses the first <string> after <key>mount-point</key>")
    func parsesFirstMountPoint() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>system-entities</key>
          <array>
            <dict>
              <key>content-hint</key>
              <string>Apple_HFS</string>
              <key>mount-point</key>
              <string>/private/tmp/dmg.AbCdEf</string>
              <key>dev-entry</key>
              <string>/dev/disk4s1</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        #expect(
            Installer.parseHdiutilMountPoint(plistXML: plist)
                == "/private/tmp/dmg.AbCdEf"
        )
    }

    @Test("Returns nil when there is no mount-point key")
    func returnsNilOnMissing() {
        let plist = "<plist><dict></dict></plist>"
        #expect(Installer.parseHdiutilMountPoint(plistXML: plist) == nil)
    }

    @Test("Returns nil when the value is empty (degraded mount)")
    func returnsNilOnEmpty() {
        let plist = """
        <key>mount-point</key>
        <string></string>
        """
        #expect(Installer.parseHdiutilMountPoint(plistXML: plist) == nil)
    }

    @Test("Picks the FIRST non-empty mount-point when multiple partitions exist")
    func picksFirstWhenMultiple() {
        // A multi-partition DMG produces several system-entities;
        // the parser scans all and picks the first non-empty value.
        let plist = """
        <key>mount-point</key>
        <string>/private/tmp/dmg.First</string>
        <key>mount-point</key>
        <string>/private/tmp/dmg.Second</string>
        """
        #expect(
            Installer.parseHdiutilMountPoint(plistXML: plist)
                == "/private/tmp/dmg.First"
        )
    }

    @Test("Skips empty mount-points and picks the first non-empty one")
    func skipsEmptyAndPicksNextNonEmpty() {
        // Codex r1 #10: a DMG with a leading Apple_partition_scheme
        // entity may emit an EMPTY mount-point before the HFS+/APFS
        // partition's real one. Old parser returned nil here; new
        // parser walks past the empty and returns the real mount.
        let plist = """
        <key>mount-point</key>
        <string></string>
        <key>mount-point</key>
        <string>/private/tmp/dmg.RealMount</string>
        """
        #expect(
            Installer.parseHdiutilMountPoint(plistXML: plist)
                == "/private/tmp/dmg.RealMount"
        )
    }

    @Test("PropertyListSerialization path walks system-entities array")
    func plistPathWalksEntities() {
        // Realistic hdiutil-shaped multi-entity payload where the
        // first entity (Apple_partition_scheme) lacks a mount-point
        // entirely; the parser must descend into the array and find
        // the HFS partition's mount-point in the next entity. This
        // is the canonical macOS Sonoma output shape.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>system-entities</key>
          <array>
            <dict>
              <key>content-hint</key>
              <string>Apple_partition_scheme</string>
            </dict>
            <dict>
              <key>content-hint</key>
              <string>Apple_partition_map</string>
            </dict>
            <dict>
              <key>content-hint</key>
              <string>Apple_HFS</string>
              <key>mount-point</key>
              <string>/private/tmp/dmg.XYZ</string>
              <key>dev-entry</key>
              <string>/dev/disk4s1</string>
            </dict>
          </array>
        </dict>
        </plist>
        """
        #expect(
            Installer.parseHdiutilMountPoint(plistXML: plist)
                == "/private/tmp/dmg.XYZ"
        )
    }
}

// MARK: - Staging + cleanup

@Suite("Installer.stagingURL + cleanupStaleArtifacts")
struct InstallerStagingTests {
    @Test("stagingURL is a sibling of installed bundle with .rapid-staged- prefix")
    func stagingIsSibling() {
        let installed = URL(fileURLWithPath: "/Applications/Rapid.app")
        let staged = Installer.stagingURL(near: installed)
        #expect(staged.deletingLastPathComponent().path == "/Applications")
        #expect(staged.lastPathComponent.hasPrefix(".rapid-staged-"))
        #expect(staged.lastPathComponent.hasSuffix(".app"))
    }

    @Test("stagingURL produces a fresh path on each call")
    func stagingIsUnique() {
        let installed = URL(fileURLWithPath: "/Applications/Rapid.app")
        let a = Installer.stagingURL(near: installed)
        let b = Installer.stagingURL(near: installed)
        #expect(a != b)
    }

    @Test("cleanupStaleArtifacts removes stale staged bundles + backup anchors")
    func cleanupRemovesStaleSiblings() throws {
        // Build a tmpdir, plant a "Rapid.app" + a stale staged
        // sibling + a stale backup anchor, run cleanup, verify only
        // the live bundle survives. Use ``now`` 1 hour in the
        // future so every plant counts as ``stale`` regardless of
        // when the test runs.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let installed = tmp.appendingPathComponent("Rapid.app")
        let staleStaged = tmp.appendingPathComponent(".rapid-staged-old.app")
        let staleBackup = tmp.appendingPathComponent("Rapid.app.old-1234")
        let unrelated = tmp.appendingPathComponent("OtherApp.app")
        for url in [installed, staleStaged, staleBackup, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Inject "now = 1h in the future" so every plant is stale
        // relative to the 60s threshold.
        let future = Date(timeIntervalSinceNow: 3600)
        Installer.cleanupStaleArtifacts(near: installed, now: future)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        #expect(after.contains("Rapid.app"))     // live bundle survives (not prefixed)
        #expect(after.contains("OtherApp.app"))  // unrelated app survives
        #expect(!after.contains(".rapid-staged-old.app"))
        #expect(!after.contains("Rapid.app.old-1234"))
    }

    @Test("cleanupStaleArtifacts does NOT delete fresh files (mtime guard)")
    func cleanupSkipsFreshFiles() throws {
        // Codex r2 #1/#6: cleanup runs fire-and-forget from
        // ``install()`` and could race the fresh DMG download. The
        // mtime guard must keep recently-created files (within the
        // freshness window) safe. Plant a "fresh" staged bundle
        // with default ``now`` (real wall clock) and verify it
        // survives cleanup.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-cleanup-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let installed = tmp.appendingPathComponent("Rapid.app")
        let freshStaged = tmp.appendingPathComponent(".rapid-staged-INFLIGHT.app")
        for url in [installed, freshStaged] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Use real wall-clock ``now`` — the freshStaged was just
        // created, so its mtime is < 60s old and the cleanup must
        // skip it.
        Installer.cleanupStaleArtifacts(near: installed)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        #expect(after.contains(".rapid-staged-INFLIGHT.app"))
    }
}

// MARK: - Relaunch helper script invariants

@Suite("Installer.relaunchHelperScript")
struct InstallerHelperScriptTests {
    @Test("Has a bash shebang so /bin/bash can exec it directly")
    func hasBashShebang() {
        #expect(Installer.relaunchHelperScript.hasPrefix("#!/bin/bash"))
    }

    @Test("Reads parent PID + staged + installed from positional args")
    func usesPositionalArgs() {
        let s = Installer.relaunchHelperScript
        #expect(s.contains("PARENT_PID=\"${1:-}\""))
        #expect(s.contains("STAGED=\"${2:-}\""))
        #expect(s.contains("INSTALLED=\"${3:-}\""))
    }

    @Test("Aborts on missing args BEFORE touching the filesystem")
    func abortsOnMissingArgs() {
        // The arg guard must be ahead of the rename to avoid an
        // empty STAGED accidentally moving into root.
        let s = Installer.relaunchHelperScript
        guard let guardIdx = s.range(of: "missing args; abort"),
              let renameIdx = s.range(of: "rename installed → backup failed") else {
            Issue.record("script missing arg-guard or rename failure log line")
            return
        }
        #expect(guardIdx.lowerBound < renameIdx.lowerBound)
    }

    @Test("Waits for parent PID to exit before swapping")
    func waitsForParentExit() {
        let s = Installer.relaunchHelperScript
        // Polls every 200ms (0.2s) for up to 30 seconds (150 iters).
        #expect(s.contains("sleep 0.2"))
        #expect(s.contains("i -lt 150"))
        #expect(s.contains("kill -0"))
    }

    @Test("Has a rollback path that restores the backup on rename failure")
    func rollsBackOnRenameFailure() {
        let s = Installer.relaunchHelperScript
        #expect(s.contains("rolling back"))
        #expect(s.contains("mv \"${BACKUP}\" \"${INSTALLED}\""))
    }

    @Test("Removes the partial installed dir BEFORE rollback rename")
    func removesPartialBeforeRollback() {
        // Codex r1 #3: ``mv`` refuses to overwrite a non-empty dir
        // on same-volume renames, so a half-finished install leaves
        // the rollback rename silently failing without an explicit
        // ``rm -rf`` first. The script must emit the rm in the
        // rollback path AND the rm must precede the mv-from-backup.
        let s = Installer.relaunchHelperScript
        guard let rmRange = s.range(of: "rm -rf \"${INSTALLED}\""),
              let rollbackMvRange = s.range(of: "mv \"${BACKUP}\" \"${INSTALLED}\"") else {
            Issue.record("script missing rm-before-rollback or rollback mv")
            return
        }
        #expect(rmRange.lowerBound < rollbackMvRange.lowerBound)
    }

    @Test("Strips trailing slash from INSTALLED + STAGED for path stability")
    func stripsTrailingSlash() {
        // Codex r1 #1: BACKUP="${INSTALLED}.old-$$" must be a
        // sibling, never a hidden child of a slash-suffixed path.
        let s = Installer.relaunchHelperScript
        #expect(s.contains("INSTALLED=\"${INSTALLED%/}\""))
        #expect(s.contains("STAGED=\"${STAGED%/}\""))
    }

    @Test("Defends against unset HOME so set -u doesn't abort before logging")
    func defendsAgainstUnsetHOME() {
        // Codex r1 #4: launchd-spawned children may inherit an env
        // without HOME; without the defensive default, `set -u`
        // aborts on LOG_DIR=... before logging is wired and the
        // user sees the app quit with zero diagnostic.
        let s = Installer.relaunchHelperScript
        #expect(s.contains("HOME=\"${HOME:-/Users/$(id -un)}\""))
    }

    @Test("Strips com.apple.quarantine xattr so Gatekeeper doesn't block relaunch")
    func stripsQuarantine() {
        // DMG-mounted bundles inherit ``com.apple.quarantine``; left
        // on, Gatekeeper will refuse to launch the swapped-in app
        // and the user gets a "Rapid.app can't be opened" dialog.
        let s = Installer.relaunchHelperScript
        #expect(s.contains("xattr -dr com.apple.quarantine"))
    }

    @Test("Logs to ~/Library/Logs/Rapid/installer.log so post-mortem is possible")
    func logsToLibraryLogs() {
        let s = Installer.relaunchHelperScript
        #expect(s.contains("Library/Logs/Rapid"))
        #expect(s.contains("installer.log"))
    }

    @Test("Uses `open` (not `osascript launch`) to relaunch")
    func usesOpenForRelaunch() {
        // ``open`` re-attaches the new bundle to Launch Services so
        // a) the new version's Info.plist is consulted, and b) the
        // user sees the new Dock badge immediately. ``osascript -e
        // 'tell application "Rapid" to activate'`` would re-launch
        // the OLD code from Launch Services cache on some macOS
        // versions.
        let s = Installer.relaunchHelperScript
        #expect(s.contains("open \"${INSTALLED}\""))
    }
}

// MARK: - URL allowlist (codex audit r1 Installer.swift:319)

/// Pin the download-URL allowlist contract so a future refactor
/// can't silently re-introduce the bypass.
@Suite("Installer.runDownload — URL allowlist")
struct InstallerURLAllowlistTests {
    private static let dummyProgress: @MainActor @Sendable (Double) -> Void = { _ in }

    @Test("rejects non-HTTPS URLs even when the host is allowlisted")
    func rejectsNonHTTPS() async {
        let url = URL(string: "http://github.com/machinefi/rapid-desktop/releases/download/v0/x.dmg")!
        await #expect(throws: InstallerError.self) {
            try await Installer.runDownload(url: url, progress: Self.dummyProgress)
        }
    }

    @Test("rejects URLs that embed userinfo (credentials)")
    func rejectsUserinfo() async {
        let url = URL(string: "https://attacker:pw@github.com/machinefi/rapid-desktop/releases/download/v0/x.dmg")!
        await #expect(throws: InstallerError.self) {
            try await Installer.runDownload(url: url, progress: Self.dummyProgress)
        }
    }

    @Test("rejects URLs whose host is not on the download allowlist")
    func rejectsForeignHost() async {
        let url = URL(string: "https://attacker.example.com/Rapid-update.dmg")!
        await #expect(throws: InstallerError.self) {
            try await Installer.runDownload(url: url, progress: Self.dummyProgress)
        }
    }

    @Test("allowlist contains the GitHub Releases CDN hosts we actually redirect to")
    func allowlistContainsCDN() {
        // GitHub Releases asset URLs (github.com) 302 to one of the
        // two signed-CDN hosts below. Both need to be in the set or
        // the install fails halfway through a working download.
        #expect(updateDownloadHostAllowlist.contains("github.com"))
        #expect(updateDownloadHostAllowlist.contains("objects.githubusercontent.com"))
        #expect(updateDownloadHostAllowlist.contains("release-assets.githubusercontent.com"))
    }
}

// MARK: - Recorder helpers

private enum InstallerEvent: Equatable, Sendable {
    case download, mount, findApp, verify, stageCopy, unmount, spawnHelper, terminate
}

/// Lock-backed event log so the various injected closures (some
/// ``@MainActor``, some ``@Sendable`` running on a cooperative
/// thread pool) can append in real wall-clock order without the
/// asserts racing a still-pending ``Task { @MainActor }`` append.
/// Previous attempt used a posted main-actor Task; that lost the
/// ``.terminate`` event because the install() return raced the
/// scheduled append.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [InstallerEvent] = []

    init() {}

    func record(_ event: InstallerEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }

    var events: [InstallerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}
