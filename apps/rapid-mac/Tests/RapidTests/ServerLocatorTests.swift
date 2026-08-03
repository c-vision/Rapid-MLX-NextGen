import Foundation
import Testing
@testable import Rapid

/// `ServerLocator` resolves the absolute path of the rapid-mlx CLI
/// that this desktop release owns. v0.8.10 cutover collapsed the
/// priority chain from 6 slots to 3: RAPID_BIN, runtime-override,
/// bundled. The legacy PATH / brew / pipx / uv fallback was removed
/// so a user-installed sibling rapid-mlx can no longer silently shadow
/// the release-pipeline-shipped sidecar (which would break the
/// "Rapid · up to date" claim and let arbitrary versions answer
/// spawn requests).
///
/// These tests pin the priority order, the missing-install contract
/// (all three slots empty → ``find()`` returns ``nil``), the slot-
/// classifier (used by the About panel for the binary-origin label),
/// and the existing path-normalization contract.
@Suite("ServerLocator path normalization")
struct ServerLocatorNormalizationTests {
    @Test("Path candidates must be absolute")
    func relativePathCandidateRejected() {
        #expect(ServerLocator._testingNormalizedPath("bin/rapid-mlx", allowRelative: false) == nil)
    }

    @Test("Explicit RAPID_BIN-style override may be relative but resolves absolute")
    func relativeOverrideResolvesAbsolute() throws {
        let resolved = try #require(ServerLocator._testingNormalizedPath("scripts/fake-rapid-mlx.sh", allowRelative: true))
        #expect(resolved.hasPrefix("/"))
        #expect(resolved.hasSuffix("/scripts/fake-rapid-mlx.sh"))
    }

    @Test("Absolute candidates are standardized")
    func absoluteCandidateStandardized() {
        #expect(ServerLocator._testingNormalizedPath("/tmp/../tmp/rapid-mlx", allowRelative: false) == "/tmp/rapid-mlx")
    }
}

/// Fixture builder that stands up a tmp directory tree mimicking the
/// three live slots so a single `find(...)` call exercises the real
/// priority chain. Each test plants only the slots it cares about and
/// leaves the rest empty — the locator must pick the highest-priority
/// non-empty slot. The v0.8.10-cutover tests additionally plant the
/// legacy PATH / brew / pipx locations to assert they are ignored.
private struct LocatorFixture {
    let root: URL
    let bundleResource: URL
    let appSupport: URL
    let pathDir: URL
    let homeDir: URL
    var environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-locator-\(UUID().uuidString)")
        bundleResource = root.appendingPathComponent("bundle/Contents/Resources")
        appSupport = root.appendingPathComponent("appsupport")
        pathDir = root.appendingPathComponent("path")
        homeDir = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bundleResource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        environment = [
            "PATH": pathDir.path,
            "HOME": homeDir.path,
        ]
    }

    func plantExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("ServerLocator priority chain")
struct ServerLocatorPriorityTests {
    @Test("RAPID_BIN beats every other slot, even when bundle + override both exist")
    func rapidBinWins() throws {
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let rapidBin = f.root.appendingPathComponent("custom-bin/rapid-mlx")
        let override = f.appSupport.appendingPathComponent("runtime-override/rapid-mlx/bin/rapid-mlx")
        let bundled = f.bundleResource.appendingPathComponent("rapid-mlx/bin/rapid-mlx")
        try f.plantExecutable(at: rapidBin)
        try f.plantExecutable(at: override)
        try f.plantExecutable(at: bundled)
        f.environment["RAPID_BIN"] = rapidBin.path

        let resolved = try #require(
            ServerLocator.find(
                environment: f.environment,
                bundleResourceURL: f.bundleResource,
                applicationSupportURL: f.appSupport
            )
        )
        #expect(resolved.standardizedFileURL.path == rapidBin.standardizedFileURL.path)
    }

    @Test("runtime-override beats bundled when RAPID_BIN is unset")
    func overrideBeatsBundled() throws {
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let override = f.appSupport.appendingPathComponent("runtime-override/rapid-mlx/bin/rapid-mlx")
        let bundled = f.bundleResource.appendingPathComponent("rapid-mlx/bin/rapid-mlx")
        try f.plantExecutable(at: override)
        try f.plantExecutable(at: bundled)

        let resolved = try #require(
            ServerLocator.find(
                environment: f.environment,
                bundleResourceURL: f.bundleResource,
                applicationSupportURL: f.appSupport
            )
        )
        #expect(resolved.standardizedFileURL.path == override.standardizedFileURL.path)
    }

    @Test("bundled wins when only bundled is populated (slim DMG fallback)")
    func bundledResolvesWhenOnlyBundled() throws {
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let bundled = f.bundleResource.appendingPathComponent("rapid-mlx/bin/rapid-mlx")
        try f.plantExecutable(at: bundled)

        let resolved = try #require(
            ServerLocator.find(
                environment: f.environment,
                bundleResourceURL: f.bundleResource,
                applicationSupportURL: f.appSupport
            )
        )
        #expect(resolved.standardizedFileURL.path == bundled.standardizedFileURL.path)
    }

    @Test("v0.8.10 cutover: a sibling rapid-mlx on PATH is ignored")
    func pathInstallIsIgnored() throws {
        // Pre-v0.8.10 the locator walked PATH and the fixed brew /
        // pipx slots as a Phase 1 fallback. After ε.2 the slim
        // bootstrapper DMG ships without a bundled sidecar and the
        // ``BootstrapCoordinator`` is the only supported install
        // path; honouring a stray ``/opt/homebrew/bin/rapid-mlx``
        // (left over from a tap or a pip install) would silently
        // shadow whatever the desktop release pipeline shipped, and
        // the "Rapid · up to date" claim would describe a different
        // binary than the one actually answering spawn requests.
        //
        // This test pins the new contract: with override + bundle
        // empty, a binary planted on ``PATH`` MUST NOT resolve.
        // The dev host's real ``/opt/homebrew/bin/rapid-mlx`` is
        // irrelevant to this assertion because the locator no
        // longer touches PATH at all.
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let pathBin = f.pathDir.appendingPathComponent("rapid-mlx")
        try f.plantExecutable(at: pathBin)
        // NO override, NO bundle — locator must return nil.

        let resolved = ServerLocator.find(
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(resolved == nil)
    }

    @Test("v0.8.10 cutover: planted fixed-fallback paths are ignored")
    func fixedFallbackPathsIgnored() throws {
        // Companion to ``pathInstallIsIgnored`` — exercises the
        // specific Phase 1 hard-coded slots ``/opt/homebrew/bin``,
        // ``/usr/local/bin``, ``~/.local/bin``. The locator no
        // longer probes any of these. We can't plant binaries at
        // ``/opt/homebrew`` from a test, but we CAN prove the
        // locator returns nil when the only candidate it COULD
        // have walked is ``$HOME/.local/bin``, which the fixture
        // controls fully. Same wins as ``pathInstallIsIgnored``;
        // separates the failure mode for triage if a future refactor
        // re-introduces only one of the legacy slots.
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let pipxShim = f.homeDir.appendingPathComponent(".local/bin/rapid-mlx")
        try f.plantExecutable(at: pipxShim)
        f.environment["PATH"] = ""  // scrub PATH so only fixed slots could match

        let resolved = ServerLocator.find(
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(resolved == nil)
    }

    @Test("Regression #430: a binary at the pre-fix flat path (runtime-override/bin/rapid-mlx) does NOT resolve")
    func flatRuntimeOverridePathIsRejected() throws {
        // Pre-fix the locator looked at
        // ``runtime-override/bin/rapid-mlx`` (no ``rapid-mlx/`` wrapper),
        // which had been latent-wrong since PR #36. The bootstrap
        // install pipeline produces a tree shaped
        // ``runtime-override/rapid-mlx/bin/rapid-mlx`` (the
        // ``rapid-mlx/`` wrapper is the top-level arcname in the
        // sidecar tarball, preserved through tarball → extract →
        // publish), so the locator should ONLY accept the wrapped
        // shape. v0.8.12 was the first release where the slim DMG
        // actually went live on latest.json, exposing the latent
        // mismatch (every fresh slim-DMG user landed on the
        // "Setup didn't finish" overlay with no recovery path).
        //
        // This test locks the fix direction by planting a binary at
        // the OLD wrong path and asserting ``find()`` returns nil —
        // so any future refactor that silently re-introduces the flat
        // shape fails closed instead of shipping a regressed v0.8.13+.
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let flatOverride = f.appSupport.appendingPathComponent("runtime-override/bin/rapid-mlx")
        try f.plantExecutable(at: flatOverride)
        // NO wrapped-path executable, NO bundled — flat MUST NOT match.

        let resolved = ServerLocator.find(
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(resolved == nil)
    }

    @Test("Regression #430: bootstrap-shaped tree at runtime-override/rapid-mlx/bin/rapid-mlx resolves")
    func wrappedRuntimeOverridePathResolves() throws {
        // Companion to ``flatRuntimeOverridePathIsRejected``: prove
        // the wrapped layout the install pipeline actually produces
        // is the layout the locator accepts. Together the two tests
        // pin BOTH directions of the fix — flat rejected AND wrapped
        // accepted — so a single-line edit that breaks either side
        // is caught by exactly one assertion.
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let wrappedOverride = f.appSupport
            .appendingPathComponent("runtime-override/rapid-mlx/bin/rapid-mlx")
        try f.plantExecutable(at: wrappedOverride)
        // Also write the top-level VERSION marker the bootstrap
        // installer leaves at runtime-override/ to mirror real on-disk
        // shape — locator MUST NOT regress to treating the wrapper
        // dir as the binary basename just because a sibling file
        // exists at the same level.
        let versionMarker = f.appSupport.appendingPathComponent("runtime-override/VERSION")
        try Data("0.8.18".utf8).write(to: versionMarker)

        let resolved = try #require(
            ServerLocator.find(
                environment: f.environment,
                bundleResourceURL: f.bundleResource,
                applicationSupportURL: f.appSupport
            )
        )
        #expect(resolved.standardizedFileURL.path == wrappedOverride.standardizedFileURL.path)

        // Classify must agree — the classifier path string and the
        // find() path string both use the same constant; this catches
        // the "fixed one, forgot the other" regression mode.
        let source = ServerLocator.classify(
            resolved: resolved,
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(source == .runtimeOverride)
    }

    @Test("All three slots empty returns nil — bootstrapper-relaunch contract")
    func allSlotsEmptyReturnsNil() throws {
        // The whole-app contract that callers rely on post-ε.2:
        // when nothing resolves, surface the missing-install UX so
        // ``BootstrapCoordinator`` can re-run, instead of silently
        // executing whatever sibling rapid-mlx the host happens to
        // have. The previous shape of this test (formerly
        // ``allCustomSlotsEmptyClassifiesFallback``) was forced to
        // accept either a host-Cask fallback OR nil because the
        // locator walked the host. Now we can assert nil directly.
        var f = try LocatorFixture()
        defer { f.cleanup() }
        f.environment["PATH"] = ""  // scrub PATH; not consulted post-v0.8.10, asserted for belt-and-braces

        let resolved = ServerLocator.find(
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(resolved == nil)
    }
}

@Suite("ServerLocator slot classifier")
struct ServerLocatorClassifierTests {
    @Test("Classifies the resolved path back to its slot of origin")
    func classifyMatchesPriorityChainSlot() throws {
        var f = try LocatorFixture()
        defer { f.cleanup() }
        let bundled = f.bundleResource.appendingPathComponent("rapid-mlx/bin/rapid-mlx")
        let override = f.appSupport.appendingPathComponent("runtime-override/rapid-mlx/bin/rapid-mlx")
        try f.plantExecutable(at: bundled)
        try f.plantExecutable(at: override)

        let resolved = try #require(
            ServerLocator.find(
                environment: f.environment,
                bundleResourceURL: f.bundleResource,
                applicationSupportURL: f.appSupport
            )
        )
        // override beats bundled in the chain, so classify must agree.
        let source = ServerLocator.classify(
            resolved: resolved,
            environment: f.environment,
            bundleResourceURL: f.bundleResource,
            applicationSupportURL: f.appSupport
        )
        #expect(source == .runtimeOverride)
    }

    @Test("A path matching none of the three live slots returns .unknown")
    func unknownPath() {
        // Post-v0.8.10 the only recognized slots are RAPID_BIN /
        // runtime-override / bundled. An empty env keeps RAPID_BIN
        // unset, so a stray absolute path must fall through to
        // ``.unknown`` — no brew / pipx / uv / PATH guessing remains.
        #expect(
            ServerLocator.classify(
                resolved: URL(fileURLWithPath: "/some/random/spot/rapid-mlx"),
                environment: [:],
                bundleResourceURL: nil,
                applicationSupportURL: nil
            ) == .unknown
        )
    }
}
