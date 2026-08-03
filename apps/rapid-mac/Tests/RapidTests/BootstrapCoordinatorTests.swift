import CryptoKit
import Foundation
import Testing
@testable import Rapid

/// URLProtocol stub dedicated to ``BootstrapCoordinatorTests``.
/// Mirrors ``StubInstallerProtocol`` but lives in its own class so
/// the two suites can run in parallel without racing on static state
/// (``BootstrapInstallerTests`` already learnt this lesson the hard
/// way; see the comment on ``StubInstallerProtocol``).
final class StubCoordinatorProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = .init()

    static func reset(body: Data) {
        Self.body = body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = Self.body
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { /* no-op */ }
}

/// Drives ``BootstrapCoordinator`` end-to-end with in-memory test
/// doubles so the suite never touches the network and uses a sandbox
/// temp directory for every filesystem mutation.
///
/// Coverage matrix (state-machine corners we care about):
///
///   1. detect — bundled-only present → `.installed(.bundled)`
///      (the backward-compat path for existing v0.8.x users)
///   2. detect — runtime-override present → `.installed(.bootstrapInstalled)`
///   3. detect — both absent → kicks install pipeline
///   4. install — happy path → `.installed(.bootstrapInstalled)`
///      with VERSION marker on disk
///   5. install — manifest fetch error → `.failed(.manifestFetchFailed)`
///   6. install — extractor error → `.failed(.extractFailed)`
///   7. cancel mid-install → `.failed(.cancelled)`
///   8. retry after failure → re-runs and reaches `.installed`
///   9. detect — corrupt VERSION file → falls through to bundled
///      (the "VERSION shouldn't loop install forever" invariant)
///  10. detect — expectedVersion mismatch → falls through to bundled
///  11. start() is reentrancy-guarded — second call no-ops
///  12. manifest validate — rejects non-https / non-allowlist hosts
@Suite("BootstrapCoordinator", .serialized)
@MainActor
struct BootstrapCoordinatorTests {

    // MARK: - Doubles

    private final class StubExtractor: SidecarExtractor.TarExtractor, @unchecked Sendable {
        let layout: [(relativePath: String, body: Data, isMachO: Bool)]
        let writeQuarantine: Bool
        init(
            layout: [(String, Data, Bool)],
            writeQuarantine: Bool = false
        ) {
            self.layout = layout.map { ($0.0, $0.1, $0.2) }
            self.writeQuarantine = writeQuarantine
        }
        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            let fm = FileManager.default
            for entry in layout {
                let dest = destinationDirectory.appendingPathComponent(entry.relativePath)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.body.write(to: dest)
            }
        }
    }

    private struct PassMachOVerifier: SidecarExtractor.MachOVerifier {
        func verify(url: URL) async throws { /* always pass */ }
    }

    /// Mach-O magic bytes that the SidecarExtractor's magic-detect
    /// expects. `0xFEEDFACF` is 64-bit native — same value used by
    /// the slice-4 tests.
    private static func machOBytes() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00])
    }

    private static func tempDir(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boot-coord-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeVersion(_ v: String, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? v.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Build a coordinator wired entirely to in-memory doubles.
    private static func makeCoordinator(
        runtimeDir: URL,
        bundledMarker: URL?,
        manifest: BootstrapManifest? = nil,
        manifestError: Error? = nil,
        extractorLayout: [(String, Data, Bool)] = [
            // #430: model the on-disk shape the real
            // ``scripts/build-sidecar-tarball.sh`` produces — the
            // tarball's top-level arcname is ``rapid-mlx/`` and that
            // wrapper is preserved through extract + atomic publish.
            // Pre-fix, the stub put ``bin/rapid-mlx`` directly under
            // ``runtime-override/`` (which the install pipeline NEVER
            // actually produces) and the ServerLocator runtime-override
            // candidate was off-by-one in the same direction — so both
            // the prod code and the test scaffolding agreed on a
            // layout that simply does not exist on disk. The wrapped
            // shape below pins the test fixtures to reality so a
            // future drift caught by this stub is also caught by
            // ``ServerLocator.find()``.
            ("VERSION", Data("0.0.0-from-tarball".utf8), false),
            ("rapid-mlx/bin/rapid-mlx", machOBytes(), true),
        ],
        expectedVersion: String? = nil,
        installerOverride: BootstrapInstaller? = nil
    ) -> (BootstrapCoordinator, URL) {
        let work = tempDir("work")
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let resolvedManifest = manifest ?? BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        // Installer with a stub URLProtocol bound to the tarball
        // bytes — same recipe BootstrapInstallerTests uses.
        let installer = installerOverride ?? makeStubInstaller(body: tarball)
        let extractor = SidecarExtractor(
            tarExtractor: StubExtractor(layout: extractorLayout),
            machOVerifier: PassMachOVerifier()
        )
        let fetcher: BootstrapCoordinator.ManifestFetcher = {
            if let err = manifestError { throw err }
            return resolvedManifest
        }
        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: runtimeDir,
            bundledMarker: bundledMarker,
            workDirectory: work,
            manifestFetcher: fetcher,
            installer: installer,
            extractor: extractor,
            expectedVersion: expectedVersion
        )
        return (BootstrapCoordinator(configuration: config), work)
    }

    private static func makeStubInstaller(body: Data) -> BootstrapInstaller {
        StubCoordinatorProtocol.reset(body: body)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubCoordinatorProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        return BootstrapInstaller(downloader: downloader)
    }

    /// Spin a tight wait until ``coordinator.state`` reaches one of
    /// the terminal states (`.installed`, `.failed`). We use a real
    /// poll rather than a Combine subscription because the test
    /// doubles complete in milliseconds and the polling overhead is
    /// dominated by `Task.yield()`.
    private static func awaitTerminal(
        _ coordinator: BootstrapCoordinator,
        timeoutSeconds: Double = 10
    ) async -> BootstrapCoordinator.State {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch coordinator.state {
            case .installed, .failed:
                return coordinator.state
            default:
                try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            }
        }
        return coordinator.state
    }

    // MARK: - Detection

    @Test("detect: bundled marker present → .installed(.bundled)")
    func detectBundledOnly() async {
        let runtime = Self.tempDir("rt-bundled")
        let bundleRoot = Self.tempDir("bundle-bundled")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifestError: TestError.shouldNotFetch
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")),
                "expected bundled-detection to short-circuit; saw \(final)")
    }

    /// Issue #435 pin: a bundled-sidecar marker on disk MUST be
    /// detected synchronously inside ``init(configuration:)`` — BEFORE
    /// ``start()`` runs — so SwiftUI's first body evaluation in
    /// ``BootstrapGateView`` lands directly on the ``.installed`` case
    /// and mounts ``ContentView()`` from the very first frame. The
    /// previous shape started in ``.checking`` and only flipped to
    /// ``.installed`` once ``start()``'s async detect Task settled,
    /// which raced macOS ``NavigationSplitView``'s first layout pass
    /// (Group case transition from a 420×360 SplashView to a
    /// 880×560-minimum ContentView left NSSplitView with stale
    /// geometry → blank sidebar + blank detail with only backgrounds
    /// + status footer visible, self-recovers on quit + relaunch).
    ///
    /// If a future change reverts the eager init or moves the detect
    /// back into the async pipeline, this assertion fails before
    /// anyone exercises the SwiftUI tree.
    @Test("init #435: bundled marker → state == .installed(.bundled) BEFORE start() runs")
    func eagerInitBundledDetect() async {
        let runtime = Self.tempDir("rt-eager")
        let bundleRoot = Self.tempDir("bundle-eager")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.18", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        // ``manifestError`` set to ``shouldNotFetch`` so the test
        // fails loudly if the (now-skipped) async pipeline ever runs
        // for the eager-detected case.
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifestError: TestError.shouldNotFetch
        )
        defer { try? FileManager.default.removeItem(at: work) }

        // The whole point of this test: state is .installed BEFORE
        // start() is called. The previous shape would have been
        // .checking here.
        #expect(coord.state == .installed(.bundled(version: "0.8.18")),
                "expected eager init-time bundled detect to land .installed; saw \(coord.state)")
    }

    /// Issue #435 companion pin: when ``bundledMarker`` is ``nil``
    /// (the slim-DMG bootstrapper path before first install), init
    /// MUST leave the state at ``.checking`` so the async pipeline
    /// can still run. Skipping the eager detect for slim-DMG users is
    /// load-bearing — they need the full ``runDetectAndInstall``
    /// pipeline to fetch, verify, extract, and publish the sidecar.
    @Test("init #435: no bundled marker → state stays .checking (slim-DMG path unchanged)")
    func eagerInitSlimDmgUntouched() {
        let runtime = Self.tempDir("rt-eager-slim")
        defer { try? FileManager.default.removeItem(at: runtime) }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil
        )
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(coord.state == .checking,
                "slim-DMG path: init MUST NOT prematurely flip state away from .checking; saw \(coord.state)")
    }

    /// Codex r1 MAJOR (#435): the eager init MUST defer to the async
    /// pipeline when a runtime-override marker exists on disk. Without
    /// this guard a mixed-install user (runtime-override 0.8.14 +
    /// bundled 0.8.18 + manifest sidecar 0.8.18) would see the
    /// coordinator publish ``.installed(.bundled(0.8.18))`` while
    /// ``ServerLocator`` would actually run the runtime-override
    /// 0.8.14 binary — and ``start()``'s ``.installed`` short-circuit
    /// would then skip the stale-runtime reinstall path entirely.
    /// Pinning the contract here keeps a future change that "just
    /// drops" the runtime-override fileExists guard from regressing
    /// the priority order.
    ///
    /// We assert init-time state directly (no ``start()``) so the test
    /// fails on the regression even if the post-``start()`` install
    /// pipeline later patches things up.
    @Test("init #435: runtime-override marker present → init does NOT eagerly install bundled (priority preserved)")
    func eagerInitDefersToRuntimeOverride() {
        let runtime = Self.tempDir("rt-eager-mixed")
        // Plant a runtime-override marker — value doesn't matter for
        // this assertion; the eager guard checks ``fileExists`` only.
        Self.writeVersion("0.8.14", at: runtime.appendingPathComponent("VERSION"))
        let bundleRoot = Self.tempDir("bundle-eager-mixed")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.18", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker
        )
        defer { try? FileManager.default.removeItem(at: work) }

        // INIT-TIME state — start() has not run. The eager init guard
        // must have suppressed bundled detection because
        // ``runtime-override/VERSION`` exists on disk; the async
        // pipeline ``runDetectAndInstall`` is the only place that's
        // allowed to weigh runtime-override priority + stale-marker
        // re-validation against the manifest.
        #expect(coord.state == .checking,
                "runtime-override marker MUST defer eager init to the async pipeline; saw \(coord.state)")
    }

    /// Codex r1 MAJOR companion (#435): end-to-end version of the
    /// mixed-install case — after ``start()``, the coordinator MUST
    /// land on the runtime-override branch (with manifest re-validation
    /// triggering a reinstall when the on-disk marker is stale). This
    /// catches the bypass class of regressions where init
    /// short-circuits to ``.installed(.bundled)`` and ``start()``'s
    /// ``.installed`` guard skips the async pipeline outright.
    @Test("init #435 end-to-end: stale runtime-override + bundled + manifest reinstall → lands at .bootstrapInstalled (not .bundled)")
    func eagerInitStaleRuntimePlusBundledRespectsManifestReinstall() async {
        let runtime = Self.tempDir("rt-e2e-stale-mixed")
        Self.writeVersion("0.8.14", at: runtime.appendingPathComponent("VERSION"))
        let bundleRoot = Self.tempDir("bundle-e2e-stale-mixed")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.18", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
            try? FileManager.default.removeItem(
                at: runtime
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtime.lastPathComponent + ".bootstrap-scratch")
            )
        }
        // Manifest's sidecar 0.8.18 is "today" — same as bundled, but
        // newer than the on-disk runtime marker. The async pipeline
        // must run install (runtime path), NOT short-circuit to
        // bundled, so the runtime-override slot lands at 0.8.18 and
        // ``ServerLocator`` (which prefers runtime-override) executes
        // the fresh sidecar.
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.8.5",
            sidecarVersion: "0.8.18",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifest: manifest
        )
        defer { try? FileManager.default.removeItem(at: work) }

        // Init must NOT eagerly flip to .installed(.bundled) — the
        // sibling test pins this; this test catches the start()
        // short-circuit half of the same regression.
        #expect(coord.state == .checking)

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "mixed-install with stale runtime + newer bundled MUST reinstall via runtime path, not short-circuit to .bundled; saw \(final)")
    }

    /// Issue #435 companion pin: a bundled marker that fails the
    /// version-parse contract (binary garbage, oversized file, empty,
    /// non-numeric segments) MUST NOT flip the initial state. We
    /// fall through to ``.checking`` so ``start()``'s async
    /// ``detectInstalled`` can decide the next step (most likely
    /// "install pipeline" since neither marker is valid).
    @Test("init #435: corrupt bundled marker → state stays .checking, no false-positive .installed")
    func eagerInitCorruptBundledIgnored() {
        let runtime = Self.tempDir("rt-eager-corrupt")
        let bundleRoot = Self.tempDir("bundle-eager-corrupt")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        // Non-version garbage — the same shape the existing
        // ``detectCorruptVersionFallsBackToBundled`` test exercises
        // against the runtime-override slot.
        try? FileManager.default.createDirectory(
            at: bundledMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "not-a-real-version".data(using: .utf8)?.write(to: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker
        )
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(coord.state == .checking,
                "corrupt bundled marker must NOT eagerly flip state; saw \(coord.state)")
    }

    @Test("detect: runtime-override marker + manifest fetch fails → accept marker (offline fallback, #400)")
    func detectRuntimeOverrideOnly() async {
        let runtime = Self.tempDir("rt-bootstrap")
        Self.writeVersion("v0.9.0", at: runtime.appendingPathComponent("VERSION"))
        defer { try? FileManager.default.removeItem(at: runtime) }

        // Codex r1 BLOCKING (#400) fix: when a bootstrap marker is
        // present, detect now re-validates against the manifest. If
        // the manifest fetch fails (offline, DNS, CDN — modelled
        // here by ``manifestError``), the coordinator accepts the
        // existing marker rather than refusing to launch.
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifestError: TestError.deliberate
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        // "v0.9.0" gets normalised to "0.9.0" by readMarker — pin the
        // post-strip shape so a future change to the trim rule fails
        // loudly.
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected bootstrap-installed detection; saw \(final)")
    }

    /// Codex r1 MAJOR: a hostile runtime-override VERSION that's
    /// orders of magnitude larger than the 256-byte cap must NOT be
    /// loaded into memory in full. We pin the cap-enforcement behaviour
    /// here by writing a 1 MiB junk marker — the readMarker path must
    /// (a) refuse the file and (b) not allocate 1 MiB to do it.
    /// FileHandle.read(upToCount:) caps the read; if a regression
    /// switched it back to Data(contentsOf:) this test still passes
    /// the "rejected" check but the underlying allocation safety is
    /// lost (caught by code review, not asserted here — we'd need
    /// memory instrumentation we don't ship).
    @Test("detect: oversized VERSION at runtime-override is rejected")
    func detectOversizedVersionIsRejected() async {
        let runtime = Self.tempDir("rt-huge")
        // 1 MiB of zeros — comfortably beyond the cap.
        let huge = Data(repeating: 0, count: 1024 * 1024)
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try? huge.write(to: runtime.appendingPathComponent("VERSION"))
        let bundleRoot = Self.tempDir("bundle-huge")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifestError: TestError.shouldNotFetch
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")),
                "oversized VERSION should fall through to bundled; saw \(final)")
    }

    @Test("detect: corrupt VERSION at runtime-override falls back to bundled")
    func detectCorruptVersionFallsBackToBundled() async {
        let runtime = Self.tempDir("rt-corrupt")
        // Write a marker that doesn't parse as a version (contains
        // a non-digit segment). This is the "shouldn't loop install
        // forever" invariant — a corrupt marker doesn't pin the
        // coordinator into the install path when a known-good bundled
        // sidecar is right there.
        try? "not-a-real-version".data(using: .utf8)?
            .write(to: runtime.appendingPathComponent("VERSION"))
        let bundleRoot = Self.tempDir("bundle-corrupt")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifestError: TestError.shouldNotFetch
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")),
                "corrupt runtime-override VERSION should fall through to bundled; saw \(final)")
    }

    @Test("detect: expectedVersion mismatch with bootstrap marker falls back to bundled")
    func detectExpectedVersionMismatchFallsBackToBundled() async {
        let runtime = Self.tempDir("rt-mismatch")
        Self.writeVersion("0.7.0", at: runtime.appendingPathComponent("VERSION"))
        let bundleRoot = Self.tempDir("bundle-mismatch")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifestError: TestError.shouldNotFetch,
            expectedVersion: "0.9.0"
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")),
                "expectedVersion mismatch should fall through to bundled; saw \(final)")
    }

    // MARK: - Install pipeline

    @Test("install happy path (legacy manifest) → marker == manifest.version (backward-compat fallback)")
    func installHappyPath() async {
        let runtime = Self.tempDir("rt-install")
        defer {
            try? FileManager.default.removeItem(at: runtime)
            // Also clean up the scratch sibling if one was orphaned
            // (shouldn't happen on the happy path but defensive).
            try? FileManager.default.removeItem(
                at: runtime
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtime.lastPathComponent + ".bootstrap-scratch")
            )
        }

        // Default manifest in ``makeCoordinator`` has NO
        // ``sidecar_version`` — this is the backward-compat path
        // (older latest.json that hasn't gained the field yet).
        // ``effectiveSidecarVersion`` falls back to ``version`` so
        // the marker is the desktop version (today's behaviour
        // unchanged for legacy manifests).
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected fresh install to succeed; saw \(final)")
        // VERSION marker should be on disk at the bootstrapper-install
        // destination, carrying the MANIFEST's effective sidecar
        // version (not whatever the tarball shipped at VERSION).
        // Codex r1 BLOCKING regression pin: the default extractor
        // layout in `makeCoordinator` ships `VERSION =
        // 0.0.0-from-tarball`; if the coordinator stopped scrubbing
        // the scratch marker before publish we'd see that string
        // here instead of the manifest's effective sidecar version.
        let marker = runtime.appendingPathComponent("VERSION")
        let written = try? String(contentsOf: marker, encoding: .utf8)
        #expect(written == "0.9.0",
                "marker should reflect manifest's effective sidecar version (here == manifest.version because sidecar_version is absent); saw \(written ?? "nil")")
        // Splash bar should sit at 100% after install.
        #expect(coord.splash.progress == 1.0)
        // Scratch sibling must be gone — either renamed onto
        // destination or cleaned up on failure. Codex r1 BLOCKING
        // crash-window pin.
        let scratch = runtime
            .deletingLastPathComponent()
            .appendingPathComponent(runtime.lastPathComponent + ".bootstrap-scratch")
        #expect(!FileManager.default.fileExists(atPath: scratch.path),
                "scratch dir must be removed after successful publish (rename or cleanup)")
    }

    /// Codex r1 BLOCKING regression pin. Models the "extractor wrote
    /// a stale tarball VERSION; coordinator must overwrite + publish
    /// atomically" invariant. The tarball ships `VERSION =
    /// 0.7.0-stale` AND the manifest declares version `0.9.0`. After
    /// install, the disk marker must reflect the manifest (not the
    /// tarball). A regression that re-introduced "publish to
    /// destination then write marker" sequencing would let the
    /// tarball value survive on a synthetic crash between rename +
    /// write — caught here by asserting the on-disk byte string
    /// directly.
    @Test("install: tarball VERSION is scrubbed before atomic publish")
    func installScrubsTarballVersion() async {
        let runtime = Self.tempDir("rt-scrub")
        defer { try? FileManager.default.removeItem(at: runtime) }
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            extractorLayout: [
                ("VERSION", Data("0.7.0-stale".utf8), false),
                // #430: match the real ``scripts/build-sidecar-tarball.sh``
                // arcname (top-level ``rapid-mlx/``) so the test exercises
                // the same on-disk shape ServerLocator's runtime-override
                // slot resolves against. Pre-fix this test planted
                // ``bin/rapid-mlx`` directly under runtime — a shape the
                // production install pipeline never produces.
                ("rapid-mlx/bin/rapid-mlx", Self.machOBytes(), true),
            ]
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        _ = await Self.awaitTerminal(coord)
        let written = try? String(
            contentsOf: runtime.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        #expect(written == "0.9.0",
                "tarball VERSION must be scrubbed before publish; saw \(written ?? "nil")")
        // The bin file from the tarball should have made it through.
        // #430: the binary lives under the ``rapid-mlx/`` wrapper that
        // the real ``scripts/build-sidecar-tarball.sh`` arcname puts
        // at the top level — preserved through extract + publish.
        #expect(
            FileManager.default.fileExists(atPath: runtime.appendingPathComponent("rapid-mlx/bin/rapid-mlx").path),
            "non-marker tarball contents must be preserved across the scratch→destination rename"
        )
    }

    /// Issue #400 — when the manifest carries an explicit
    /// ``sidecar_version`` (the rapid-mlx package version, distinct
    /// from the desktop release version), the runtime-override
    /// VERSION marker MUST record the sidecar version. This makes the
    /// marker semantic identical to the bundled tree's
    /// ``Contents/Resources/rapid-mlx/VERSION`` (which also holds the
    /// sidecar version) and unblocks future sidecar-only bumps from
    /// re-triggering install when the desktop version is unchanged.
    @Test("install: marker records sidecar_version when present (#400)")
    func installMarkerRecordsSidecarVersion() async {
        let runtime = Self.tempDir("rt-svers")
        defer { try? FileManager.default.removeItem(at: runtime) }

        // Manifest declares desktop version 0.8.5 BUT sidecar
        // package version 0.8.18 — the same shape v0.8.5's
        // bootstrapper Agent A observed in dogfood.
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.8.5",
            sidecarVersion: "0.8.18",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifest: manifest
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        // SidecarLocation must reflect the SIDECAR package version,
        // not the desktop release version.
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "state should expose sidecar_version; saw \(final)")
        let written = try? String(
            contentsOf: runtime.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        #expect(written == "0.8.18",
                "marker must record sidecar_version (#400), not manifest.version; saw \(written ?? "nil")")
    }

    /// Issue #400 — ``expectedVersion`` is interpreted as the
    /// sidecar (rapid-mlx) package version (matching what the marker
    /// holds), NOT the desktop release version. Combined with the
    /// codex r2 offline-fallback semantic, this also confirms that
    /// when the manifest can't be fetched (modelled here by
    /// ``manifestError``) the coordinator accepts the existing
    /// matched marker and lands on bootstrapInstalled — the user
    /// gets a working launch rather than a refused start.
    @Test("detect: expectedVersion pins the sidecar version + offline-fallback accepts marker (#400)")
    func detectExpectedVersionMatchesSidecarSemantic() async {
        let runtime = Self.tempDir("rt-pin-sidecar")
        // A previous install left a marker with the sidecar version
        // 0.8.18. Pin to that value via expectedVersion; detect must
        // accept it as a match.
        Self.writeVersion("0.8.18", at: runtime.appendingPathComponent("VERSION"))
        defer { try? FileManager.default.removeItem(at: runtime) }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifestError: TestError.deliberate,
            expectedVersion: "0.8.18"
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "expectedVersion pinning the sidecar version must accept a matching marker (offline fallback path); saw \(final)")
    }

    /// Codex r1 BLOCKING (#400) — stale runtime-override re-install
    /// path. Without this re-validation, a future sidecar-only bump
    /// could never re-trigger install in production (the marker
    /// would compare equal to itself and the coordinator would
    /// short-circuit forever). Pins the new detect-step behaviour:
    /// when the manifest's effective sidecar version differs from
    /// the on-disk marker, the coordinator falls through to install
    /// (NO second manifest fetch — the manifest already in hand is
    /// re-used).
    @Test("detect: bootstrap marker stale vs manifest sidecar_version → re-install (#400)")
    func detectStaleBootstrapMarkerTriggersReinstall() async {
        let runtime = Self.tempDir("rt-stale")
        // Previous install left a marker for sidecar 0.8.14.
        Self.writeVersion("0.8.14", at: runtime.appendingPathComponent("VERSION"))
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(
                at: runtime
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtime.lastPathComponent + ".bootstrap-scratch")
            )
        }
        // Today's manifest declares sidecar_version 0.8.18.
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.8.5",
            sidecarVersion: "0.8.18",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifest: manifest
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        // Final state must be the NEW (0.8.18) install, not the
        // stale (0.8.14) marker.
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "stale bootstrap marker must re-install to manifest sidecar_version; saw \(final)")
        // The on-disk marker must reflect the new value.
        let written = try? String(
            contentsOf: runtime.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        #expect(written == "0.8.18",
                "on-disk marker must reflect post-reinstall version; saw \(written ?? "nil")")
    }

    /// Codex r3 BLOCKING (#400) — validation bypass guard. The
    /// stale-marker re-install path fetches the manifest via a
    /// caller-supplied closure that may NOT have run
    /// ``BootstrapCoordinator.validate(_:)`` (only the production
    /// ``defaultManifestFetcher`` does). Pin that
    /// ``refreshedSidecarTarget()`` validates inline so a malformed
    /// or hostile manifest can never reach the install pipeline
    /// through this path. Failure semantic: validation failure is
    /// treated the same as offline (accept the existing marker;
    /// next detect cycle retries).
    @Test("detect: malformed manifest from a custom fetcher cannot bypass validate (codex r3 #400)")
    func detectMalformedManifestDoesNotBypassValidate() async {
        let runtime = Self.tempDir("rt-malformed")
        Self.writeVersion("0.8.14", at: runtime.appendingPathComponent("VERSION"))
        defer { try? FileManager.default.removeItem(at: runtime) }

        // Construct a manifest with a clearly invalid sidecar_url
        // (http, not https) — the fresh path's validator would
        // reject this. The re-install path MUST reject it too.
        let hostile = BootstrapManifest(
            schemaVersion: 1,
            version: "0.8.5",
            sidecarVersion: "0.8.99",
            sidecarURL: URL(string: "http://evil.example.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifest: hostile
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        // Must NOT install / replace the marker. The pre-existing
        // sidecar (0.8.14) stays.
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.14")),
                "malformed manifest must not bypass validate; the existing marker is preserved as offline-fallback; saw \(final)")
        let written = try? String(
            contentsOf: runtime.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        #expect(written == "0.8.14",
                "on-disk marker must not be overwritten by an unvalidated manifest; saw \(written ?? "nil")")
    }

    /// Codex r1 BLOCKING (#400) — up-to-date short-circuit. When the
    /// manifest's effective sidecar version matches the on-disk
    /// marker, detect accepts without re-installing. Same on-disk
    /// marker survives the round-trip.
    @Test("detect: bootstrap marker == manifest sidecar_version → accept (no reinstall, #400)")
    func detectFreshBootstrapMarkerSkipsReinstall() async {
        let runtime = Self.tempDir("rt-fresh")
        Self.writeVersion("0.8.18", at: runtime.appendingPathComponent("VERSION"))
        defer { try? FileManager.default.removeItem(at: runtime) }

        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.8.5",
            sidecarVersion: "0.8.18",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifest: manifest
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "fresh bootstrap marker matching manifest sidecar_version must short-circuit; saw \(final)")
    }

    /// Backward-compat regression pin (#400): an OLDER ``latest.json``
    /// that hasn't yet gained ``sidecar_version`` must still install
    /// correctly. The marker falls back to ``manifest.version`` so
    /// existing deployments don't break when an old client meets a
    /// new server (or vice-versa).
    @Test("install: legacy manifest without sidecar_version falls back to manifest.version (#400)")
    func installFallsBackWhenSidecarVersionMissing() async {
        let runtime = Self.tempDir("rt-legacy")
        defer { try? FileManager.default.removeItem(at: runtime) }

        // Default makeCoordinator manifest has nil sidecarVersion.
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        _ = await Self.awaitTerminal(coord)
        let written = try? String(
            contentsOf: runtime.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        #expect(written == "0.9.0",
                "legacy manifest must fall back to manifest.version (no regression); saw \(written ?? "nil")")
    }

    @Test("install: manifest fetch failure → .failed(.manifestFetchFailed)")
    func installManifestFailure() async {
        let runtime = Self.tempDir("rt-fetch-fail")
        defer { try? FileManager.default.removeItem(at: runtime) }

        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: nil,
            manifestError: TestError.deliberate
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        if case .failed(.manifestFetchFailed) = final {
            // ok
        } else {
            Issue.record("expected manifestFetchFailed; saw \(final)")
        }
    }

    @Test("install: extractor failure → .failed(.extractFailed)")
    func installExtractorFailure() async {
        let runtime = Self.tempDir("rt-extract-fail")
        defer { try? FileManager.default.removeItem(at: runtime) }

        // A layout with ZERO Mach-O files passes the magic-byte gate
        // (extractor only inspects regular files) but the slice-4
        // extractor doesn't fail on that — what we really need is a
        // bytes-level injection. Replace the tar extractor with a
        // stub that throws on `extract(...)`.
        final class FailingTar: SidecarExtractor.TarExtractor, @unchecked Sendable {
            func extract(tarballURL: URL, destinationDirectory: URL) async throws {
                throw SidecarExtractor.ExtractError.tarFailed(message: "stub failure")
            }
        }
        let extractor = SidecarExtractor(
            tarExtractor: FailingTar(),
            machOVerifier: PassMachOVerifier()
        )
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        StubCoordinatorProtocol.reset(body: tarball)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubCoordinatorProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        let installer = BootstrapInstaller(downloader: downloader)
        let work = Self.tempDir("work-extract-fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: runtime,
            bundledMarker: nil,
            workDirectory: work,
            manifestFetcher: { manifest },
            installer: installer,
            extractor: extractor,
            expectedVersion: nil
        )
        let coord = BootstrapCoordinator(configuration: config)

        coord.start()
        let final = await Self.awaitTerminal(coord)
        if case .failed(.extractFailed(let msg)) = final {
            #expect(msg.contains("stub failure"))
        } else {
            Issue.record("expected extractFailed; saw \(final)")
        }
    }

    @Test("cancel mid-install → .failed(.cancelled)")
    func cancelMidInstall() async {
        let runtime = Self.tempDir("rt-cancel")
        defer { try? FileManager.default.removeItem(at: runtime) }

        // Block the manifest fetcher until we explicitly let it
        // through so the test has a deterministic window in which
        // to call cancel(). We use a continuation that's released
        // by the test driver after invoking cancel() — but cancel()
        // should already have set the task's cancellation flag, so
        // the fetcher's `try Task.checkCancellation()` throws as soon
        // as the fetcher gets cpu time.
        actor Gate {
            private var open: Bool = false
            func waitOpen() async {
                while !open {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            func openNow() { open = true }
        }
        let gate = Gate()
        let fetcher: BootstrapCoordinator.ManifestFetcher = {
            await gate.waitOpen()
            try Task.checkCancellation()
            return BootstrapManifest(
                schemaVersion: 1,
                version: "0.9.0",
                sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
                sidecarSHA256: String(repeating: "a", count: 64),
                sidecarSize: 1
            )
        }
        let installer = Self.makeStubInstaller(body: Data())
        let extractor = SidecarExtractor(
            tarExtractor: StubExtractor(layout: []),
            machOVerifier: PassMachOVerifier()
        )
        let work = Self.tempDir("work-cancel")
        defer { try? FileManager.default.removeItem(at: work) }
        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: runtime,
            bundledMarker: nil,
            workDirectory: work,
            manifestFetcher: fetcher,
            installer: installer,
            extractor: extractor,
            expectedVersion: nil
        )
        let coord = BootstrapCoordinator(configuration: config)

        coord.start()
        // Wait briefly for the coordinator to transition into the
        // installing phase, then cancel BEFORE we open the gate.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        coord.cancel()
        // Release the fetcher's await so it can observe the
        // cancellation flag and throw.
        await gate.openNow()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .failed(.cancelled),
                "expected cancellation to settle as .failed(.cancelled); saw \(final)")
    }

    @Test("retry after failure → re-runs and reaches .installed")
    func retryAfterFailure() async {
        let runtime = Self.tempDir("rt-retry")
        defer { try? FileManager.default.removeItem(at: runtime) }

        // First fetch fails; second succeeds. Counter is held on a
        // class so the closure captures by reference.
        final class Counter: @unchecked Sendable {
            var attempt = 0
            let lock = NSLock()
            func increment() -> Int {
                lock.lock(); defer { lock.unlock() }
                attempt += 1
                return attempt
            }
        }
        let counter = Counter()
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let fetcher: BootstrapCoordinator.ManifestFetcher = {
            if counter.increment() == 1 {
                throw TestError.deliberate
            }
            return BootstrapManifest(
                schemaVersion: 1,
                version: "0.9.0",
                sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
                sidecarSHA256: hash,
                sidecarSize: UInt64(tarball.count)
            )
        }
        let installer = Self.makeStubInstaller(body: tarball)
        let extractor = SidecarExtractor(
            tarExtractor: StubExtractor(layout: [
                ("VERSION", Data("from-tar".utf8), false),
                ("rapid-mlx/bin/rapid-mlx", Self.machOBytes(), true),
            ]),
            machOVerifier: PassMachOVerifier()
        )
        let work = Self.tempDir("work-retry")
        defer { try? FileManager.default.removeItem(at: work) }
        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: runtime,
            bundledMarker: nil,
            workDirectory: work,
            manifestFetcher: fetcher,
            installer: installer,
            extractor: extractor,
            expectedVersion: nil
        )
        let coord = BootstrapCoordinator(configuration: config)

        coord.start()
        let firstSettle = await Self.awaitTerminal(coord)
        if case .failed(.manifestFetchFailed) = firstSettle {
            // ok
        } else {
            Issue.record("first attempt should have failed; saw \(firstSettle)")
            return
        }
        coord.retry()
        let second = await Self.awaitTerminal(coord)
        #expect(second == BootstrapCoordinator.State.installed(.bootstrapInstalled(version: "0.9.0")),
                "retry should reach installed; saw \(second)")
    }

    @Test("start() reentrancy — second call no-ops")
    func startReentrancyIsGuarded() async {
        let runtime = Self.tempDir("rt-reentry")
        let bundleRoot = Self.tempDir("bundle-reentry")
        let bundledMarker = bundleRoot.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: bundleRoot)
        }
        final class Counter: @unchecked Sendable {
            var calls = 0
            let lock = NSLock()
            func bump() {
                lock.lock(); defer { lock.unlock() }
                calls += 1
            }
            func snapshot() -> Int {
                lock.lock(); defer { lock.unlock() }
                return calls
            }
        }
        let counter = Counter()
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        let (coord, work) = Self.makeCoordinator(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            manifest: manifest
        )
        defer { try? FileManager.default.removeItem(at: work) }
        // Override the manifest fetcher to a counter so we can assert
        // no fetch happens (detect short-circuits).
        // We don't bother — `manifestError: shouldNotFetch` would
        // hard-fail the detect-only path. Instead, call start() 5
        // times back-to-back and assert the state lands at bundled
        // exactly once with no exception thrown.
        for _ in 0..<5 { coord.start() }
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")))
        _ = counter.snapshot() // silence unused warning
    }

    // MARK: - Manifest validation

    @Test("manifest validation rejects non-HTTPS sidecar_url")
    func manifestRejectsHttp() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "http://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("manifest validation rejects sidecar_url outside allowlist")
    func manifestRejectsBadHost() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://evil.example.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("manifest validation rejects malformed SHA256")
    func manifestRejectsBadHash() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: "not-a-hash",
            sidecarSize: 1
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("manifest validation rejects schema_version != 1")
    func manifestRejectsBadSchema() {
        let manifest = BootstrapManifest(
            schemaVersion: 2,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("manifest validation rejects non-positive size")
    func manifestRejectsZeroSize() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 0
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    /// Codex r1 MINOR: cap upper bound too. A compromised manifest
    /// must not be able to force the client into a tens-of-GB
    /// download.
    @Test("manifest validation rejects size above max")
    func manifestRejectsHugeSize() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: BootstrapCoordinator.sidecarMaxBytes + 1
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    /// Codex r1 MAJOR: manifest.version flows into the local tarball
    /// filename AND the runtime VERSION marker. A non-version-shaped
    /// value would (a) let a hostile manifest inject `..` segments,
    /// and (b) write a marker the next launch's readMarker rejects
    /// — looping the install forever on a no-bundled-fallback DMG.
    @Test("manifest validation rejects non-version-shaped version")
    func manifestRejectsBadVersionShape() {
        let badShapes = [
            "",                     // empty
            "abc",                  // not numeric
            "0.evil",               // mixed
            "1..2",                 // double dot
            "../traversal",         // path traversal attempt
            "0.9.0/extra",          // slash
            "0.9.0\n0.9.1",         // newline injection
            String(repeating: "1", count: 300), // oversized
        ]
        for raw in badShapes {
            let manifest = BootstrapManifest(
                schemaVersion: 1,
                version: raw,
                sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
                sidecarSHA256: String(repeating: "a", count: 64),
                sidecarSize: 1
            )
            #expect(throws: BootstrapCoordinator.ManifestError.self) {
                try BootstrapCoordinator.validate(manifest)
            }
        }
    }

    @Test("manifest validation accepts canonical version grammar")
    func manifestAcceptsValidVersions() {
        let good = ["0.9.0", "v0.9.0", "1", "1.2", "1.2.3.4.5", "0.0.0"]
        for raw in good {
            let manifest = BootstrapManifest(
                schemaVersion: 1,
                version: raw,
                sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
                sidecarSHA256: String(repeating: "a", count: 64),
                sidecarSize: 1
            )
            #expect(throws: Never.self) {
                try BootstrapCoordinator.validate(manifest)
            }
        }
    }

    /// Issue #400 — ``sidecar_version`` flows into the on-disk
    /// VERSION marker (via ``effectiveSidecarVersion``). Enforce
    /// the same grammar the marker reader enforces so a hostile
    /// manifest can't inject a marker the next launch would reject
    /// — that would loop install forever on a no-bundled-fallback
    /// DMG (same failure mode the original ``version`` grammar
    /// guards against).
    @Test("manifest validation rejects non-version-shaped sidecar_version (#400)")
    func manifestRejectsBadSidecarVersionShape() {
        let badShapes = [
            "abc", "0.evil", "1..2", "../traversal", "0.9.0/extra",
            "0.9.0\n0.9.1", String(repeating: "1", count: 300),
        ]
        for raw in badShapes {
            let manifest = BootstrapManifest(
                schemaVersion: 1,
                version: "0.9.0",
                sidecarVersion: raw,
                sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
                sidecarSHA256: String(repeating: "a", count: 64),
                sidecarSize: 1
            )
            #expect(throws: BootstrapCoordinator.ManifestError.self) {
                try BootstrapCoordinator.validate(manifest)
            }
        }
    }

    /// Issue #400 — nil ``sidecar_version`` is the legacy
    /// (pre-#400) shape and MUST validate as the additive-field
    /// contract requires.
    @Test("manifest validation accepts nil sidecar_version (legacy manifest, #400)")
    func manifestAcceptsNilSidecarVersion() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarVersion: nil,
            sidecarURL: URL(string: "https://dl.rapidmlx.com/x.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1
        )
        #expect(throws: Never.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    /// Issue #400 — decoder must accept a manifest carrying a
    /// ``sidecar_version`` field (the new shape released alongside
    /// this fix). Pin the Codable contract so a future rename of
    /// the JSON key fails loudly.
    @Test("manifest decoder reads sidecar_version JSON key (#400)")
    func manifestDecoderReadsSidecarVersion() throws {
        let json = """
        {
          "schema_version": 1,
          "version": "0.8.5",
          "sidecar_version": "0.8.18",
          "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz",
          "sidecar_sha256": "\(String(repeating: "a", count: 64))",
          "sidecar_size": 1
        }
        """
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "0.8.5")
        #expect(manifest.sidecarVersion == "0.8.18")
        #expect(manifest.effectiveSidecarVersion == "0.8.18")
    }

    /// Issue #400 — decoder must tolerate a manifest WITHOUT
    /// ``sidecar_version`` (older latest.json on R2 today). The
    /// effective sidecar version falls back to ``version`` so
    /// installed users don't regress when an old server meets a
    /// new client (or vice-versa).
    @Test("manifest decoder tolerates missing sidecar_version (legacy, #400)")
    func manifestDecoderToleratesMissingSidecarVersion() throws {
        let json = """
        {
          "schema_version": 1,
          "version": "0.8.5",
          "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz",
          "sidecar_sha256": "\(String(repeating: "a", count: 64))",
          "sidecar_size": 1
        }
        """
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: Data(json.utf8))
        #expect(manifest.sidecarVersion == nil)
        #expect(manifest.effectiveSidecarVersion == "0.8.5")
    }

    // MARK: - Progress translation

    @Test("installer-phase progress is monotonic across phases")
    func progressMonotonic() {
        let m = SplashViewModel()
        BootstrapCoordinator.applyInstallerPhase(
            .downloading, fraction: 0.0,
            totalBytes: 100_000_000, splash: m
        )
        let p0 = m.progress
        BootstrapCoordinator.applyInstallerPhase(
            .downloading, fraction: 1.0,
            totalBytes: 100_000_000, splash: m
        )
        let p1 = m.progress
        BootstrapCoordinator.applyInstallerPhase(
            .verifying, fraction: 1.0,
            totalBytes: 100_000_000, splash: m
        )
        let p2 = m.progress
        BootstrapCoordinator.applyInstallerPhase(
            .installing, fraction: 1.0,
            totalBytes: 100_000_000, splash: m
        )
        let p3 = m.progress
        BootstrapCoordinator.applyExtractorPhase(
            .extracting, fraction: 1.0, splash: m
        )
        let p4 = m.progress
        BootstrapCoordinator.applyExtractorPhase(
            .strippingQuarantine, fraction: 1.0, splash: m
        )
        let p5 = m.progress
        BootstrapCoordinator.applyExtractorPhase(
            .verifyingSignatures, fraction: 1.0, splash: m
        )
        let p6 = m.progress

        #expect(p0 < p1, "downloading 0 → 1 must advance the bar")
        #expect(p1 < p2, "downloading → verifying must advance the bar")
        #expect(p2 < p3, "verifying → installing must advance the bar")
        #expect(p3 < p4, "installing → extracting must advance the bar")
        #expect(p4 < p5, "extracting → stripping must advance the bar")
        #expect(p5 < p6, "stripping → verifying-signatures must advance the bar")
        #expect(p6 <= 1.0 && p6 >= 0.95, "final extractor phase should land near 100%, saw \(p6)")
    }

    @Test("progress callbacks do not mutate splash.cancellable")
    func progressCallbacksLeaveCancellableAlone() {
        // Codex r1 MAJOR: cancellable lifecycle is owned by the
        // coordinator's runDetectAndInstall, not by the
        // out-of-order progress callbacks. Pin that contract.
        let m = SplashViewModel()
        m.cancellable = true
        BootstrapCoordinator.applyExtractorPhase(
            .verifyingSignatures, fraction: 1.0, splash: m
        )
        #expect(m.cancellable == true)
        m.cancellable = false
        BootstrapCoordinator.applyExtractorPhase(
            .extracting, fraction: 0.5, splash: m
        )
        #expect(m.cancellable == false)
        BootstrapCoordinator.applyInstallerPhase(
            .verifying, fraction: 0.5, totalBytes: 100, splash: m
        )
        #expect(m.cancellable == false,
                "installer-phase callbacks must not flip the gate either")
    }

    // MARK: - InstallFailure translation

    @Test("installer InstallError variants map to user-facing failures")
    func installerErrorTranslation() {
        let diskInfo = BootstrapInstaller.DiskFailureInfo(
            operation: .publish,
            path: "/tmp/x",
            domain: "NSCocoaErrorDomain",
            code: 4,
            message: "permission denied"
        )
        let mapped = BootstrapCoordinator.translate(.diskFailed(diskInfo))
        if case .diskFailed(let m, let p) = mapped {
            #expect(m == "permission denied")
            #expect(p == "/tmp/x")
        } else {
            Issue.record("expected diskFailed; saw \(mapped)")
        }

        let v = BootstrapCoordinator.translate(.verifyFailed(expected: "abc", actual: "def"))
        if case .verifyMismatch(let e, let a) = v {
            #expect(e == "abc")
            #expect(a == "def")
        } else {
            Issue.record("expected verifyMismatch; saw \(v)")
        }
    }

    // MARK: - Failure-message contract

    @Test("InstallFailure.userMessage never empty")
    func failureMessagesNonEmpty() {
        let cases: [BootstrapCoordinator.InstallFailure] = [
            .manifestFetchFailed(message: "x"),
            .verifyMismatch(expected: "a", actual: "b"),
            .extractFailed(message: "y"),
            .diskFailed(message: "z", path: "/p"),
            .cancelled,
        ]
        for c in cases {
            #expect(!c.userMessage.isEmpty)
        }
    }

    // MARK: - Issue #401: first-install session archive wire-up

    /// Build a coordinator with the issue-#401 session-archive paths
    /// wired up. Mirrors ``makeCoordinator`` but tacks on the two
    /// extra Configuration fields the production path uses
    /// (``historyMarkerURL`` + ``sessionsFileURL``). Returns the
    /// coordinator AND the two URLs so each test can prepare /
    /// inspect the disk state.
    private static func makeCoordinatorWithSessionArchive(
        runtimeDir: URL,
        bundledMarker: URL?,
        historyMarker: URL,
        sessionsFile: URL
    ) -> (BootstrapCoordinator, URL) {
        let work = tempDir("work-401")
        let tarball = Data(repeating: 0x42, count: 64)
        let hash = SHA256Verifier.hexString(SHA256.hash(data: tarball))
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz")!,
            sidecarSHA256: hash,
            sidecarSize: UInt64(tarball.count)
        )
        let installer = makeStubInstaller(body: tarball)
        let extractor = SidecarExtractor(
            tarExtractor: StubExtractor(layout: [
                ("VERSION", Data("0.0.0-from-tarball".utf8), false),
                ("rapid-mlx/bin/rapid-mlx", machOBytes(), true),
            ]),
            machOVerifier: PassMachOVerifier()
        )
        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: runtimeDir,
            bundledMarker: bundledMarker,
            workDirectory: work,
            manifestFetcher: { manifest },
            installer: installer,
            extractor: extractor,
            expectedVersion: nil,
            historyMarkerURL: historyMarker,
            sessionsFileURL: sessionsFile
        )
        return (BootstrapCoordinator(configuration: config), work)
    }

    /// Genuinely-first install: no runtime-override, no bundled
    /// marker, no history marker. Helper MUST archive
    /// ``sessions.json`` to a sibling backup and write the history
    /// marker so the next reinstall doesn't trigger again.
    @Test("issue #401: genuinely first install archives sessions.json + writes history")
    func issue401FirstInstallArchivesSessions() async throws {
        let appSupport = Self.tempDir("app-support-first")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        // Seed a recognisable sessions.json.
        let payload = #"{"sessions":[{"id":"abc"}]}"#
        try Data(payload.utf8).write(to: sessions, options: .atomic)

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected install to land .installed; saw \(final)")
        // Original sessions.json must be gone (renamed).
        #expect(!FileManager.default.fileExists(atPath: sessions.path),
                "first-install archive must remove sessions.json from original path")
        // A sibling backup must exist with the original payload.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("sessions.")
                && $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.count == 1,
                "expected exactly one backup file, saw \(backups.map(\.lastPathComponent))")
        if let backup = backups.first {
            let recovered = try String(contentsOf: backup, encoding: .utf8)
            #expect(recovered == payload,
                    "backup must carry the original sessions.json bytes")
        }
        // History marker must exist so the NEXT install doesn't
        // re-trigger the archive.
        #expect(FileManager.default.fileExists(atPath: history.path),
                "history marker must be written after a successful first install")
    }

    /// Bundled-sidecar v0.8.x user. Detect short-circuits to
    /// ``.installed(.bundled)``; the install branch never runs; the
    /// archive helper never fires. Pin: sessions.json is untouched
    /// AND (codex r2 MAJOR backfill) the history marker IS written
    /// so a future P3 reinstall-after-delete doesn't misclassify.
    @Test("issue #401: bundled-sidecar path leaves sessions.json untouched + backfills marker")
    func issue401BundledPathPreservesSessions() async throws {
        let appSupport = Self.tempDir("app-support-bundled")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        let payload = #"{"sessions":[{"id":"keep-me"}]}"#
        try Data(payload.utf8).write(to: sessions, options: .atomic)
        // Plant a bundled marker so detect picks it up.
        let bundle = Self.tempDir("bundle-401-bundled")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let bundledMarker = bundle.appendingPathComponent("rapid-mlx/VERSION")
        Self.writeVersion("0.8.4", at: bundledMarker)

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bundled(version: "0.8.4")),
                "expected bundled detection; saw \(final)")
        // Sessions.json untouched, no backups.
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "bundled path must leave sessions.json on disk")
        let recovered = try String(contentsOf: sessions, encoding: .utf8)
        #expect(recovered == payload, "sessions.json bytes must be untouched")
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty,
                "bundled-detect path must NOT create any backup files")
        // Codex r2 MAJOR: history marker IS backfilled on the detect
        // path so the user's NEXT reinstall-after-delete (against a
        // future bundled-less DMG) sees the marker and preserves
        // their history. Previously this assertion read
        // "marker must NOT be written" — that was the migration gap
        // codex caught.
        #expect(FileManager.default.fileExists(atPath: history.path),
                "bundled-detect path must backfill the history marker (codex r2 migration gap)")
    }

    /// User who ran bootstrapper once (so history marker exists),
    /// deleted ``runtime-override/``, and re-launched. The predicate
    /// must read the history marker and preserve sessions.json.
    @Test("issue #401: reinstall after deleting runtime-override preserves sessions.json")
    func issue401ReinstallPreservesSessions() async throws {
        let appSupport = Self.tempDir("app-support-reinstall")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        let payload = #"{"sessions":[{"id":"my-real-chat"}]}"#
        try Data(payload.utf8).write(to: sessions, options: .atomic)
        // Plant a history marker — signals "bootstrapper has run
        // here before". User intentionally rm-rf'd runtime-override
        // to force a re-install (e.g. corrupt sidecar recovery).
        try Data("first_install=2026-06-01T00:00:00Z\n".utf8)
            .write(to: history, options: .atomic)

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected install to succeed; saw \(final)")
        // Sessions.json must be UNTOUCHED — this user has been using
        // the app and just wants to refresh the sidecar.
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "reinstall must preserve sessions.json")
        let recovered = try String(contentsOf: sessions, encoding: .utf8)
        #expect(recovered == payload,
                "sessions.json bytes must be untouched on reinstall")
        // No new backup file should appear.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty,
                "reinstall must NOT create any backup files")
        // History marker MUST still be there (and may be rewritten
        // — we don't pin contents, only presence).
        #expect(FileManager.default.fileExists(atPath: history.path),
                "history marker must persist across reinstalls")
    }

    /// Genuinely-first install where ``sessions.json`` does not
    /// exist (true brand-new Mac). The helper returns ``.notPresent``
    /// and we still write the history marker so the next launch
    /// short-circuits.
    @Test("issue #401: first install with no prior sessions.json still writes history marker")
    func issue401FirstInstallNoSessionsFileStillMarksHistory() async {
        let appSupport = Self.tempDir("app-support-clean")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        // sessions.json deliberately NOT created.

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected fresh install to succeed; saw \(final)")
        // No spurious sessions.json created.
        #expect(!FileManager.default.fileExists(atPath: sessions.path),
                "no sessions.json should appear on a brand-new install")
        // No backups created either.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty, "no backup files should be created when there's nothing to back up")
        // History marker still landed.
        #expect(FileManager.default.fileExists(atPath: history.path),
                "history marker must always be written after a successful install")
    }

    /// Codex r1 MAJOR: end-to-end regression for the actual reported
    /// bug. The prior 4 wire-up tests confirm the disk state is
    /// correct AFTER the coordinator's archive runs — but the user-
    /// visible bug from the dogfood report is "ChatView opens with a
    /// previous user's prompt restored". The thing actually doing
    /// the restoring is ``SessionStore.init`` reading
    /// ``sessions.json`` from the SAME ``appSupport`` directory the
    /// bootstrapper just operated on. This test models the exact
    /// flow: bootstrap completes successfully on a genuinely-first
    /// install with a stale envelope on disk, then we instantiate a
    /// fresh ``SessionStore`` against that directory and assert the
    /// store sees ZERO sessions (== ChatView opens empty, not with
    /// the stale prompt).
    ///
    /// Without the issue #401 fix this test fails: SessionStore
    /// reads the un-archived sessions.json and restores the prior
    /// chat — exactly what dogfood Agent A reported on 2026-06-24.
    @Test("issue #401 end-to-end: post-first-install SessionStore opens empty for ChatView")
    func issue401EndToEndChatViewIsEmptyAfterFirstInstall() async throws {
        let appSupport = Self.tempDir("app-support-e2e")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        // Seed a recognisable stale envelope at the exact path
        // SessionStore reads from. The shape mimics the production
        // ``StoreEnvelope`` Codable schema so the load path actually
        // decodes it (a malformed payload would short-circuit to
        // ``.corrupt`` and trivially pass — that would NOT prove the
        // fix). Codex r4 MAJOR: ``ChatMessage.init(from:)`` decodes
        // ``reasoning`` via ``decode(String.self)`` (not
        // ``decodeIfPresent``), so the field MUST be present —
        // omitting it would silently drive the envelope down the
        // ``.corrupt`` path and the assertions below would pass
        // for the wrong reason. The "write a 500 word essay"
        // content mirrors the dogfood report verbatim.
        let stalePayload = """
        {
          "activeID" : "11111111-1111-1111-1111-111111111111",
          "sessions" : [
            {
              "alias" : "qwen3.5-4b",
              "createdAt" : "2026-06-23T10:00:00Z",
              "id" : "11111111-1111-1111-1111-111111111111",
              "isPinned" : false,
              "messages" : [
                {
                  "content" : "write a detailed 500 word essay",
                  "createdAt" : "2026-06-23T10:00:01Z",
                  "id" : "22222222-2222-2222-2222-222222222222",
                  "reasoning" : "",
                  "role" : "user",
                  "status" : "complete"
                }
              ],
              "title" : "Essay help",
              "updatedAt" : "2026-06-23T10:00:01Z"
            }
          ]
        }
        """
        try Data(stalePayload.utf8).write(to: sessions, options: .atomic)

        // Codex r4 MAJOR sanity gate: confirm the fixture actually
        // decodes via the production ``SessionStore`` BEFORE we
        // hand it to the coordinator. If the schema drifts in a
        // future change and our payload silently flips to the
        // ``.corrupt`` path, the empty-after-install assertions
        // below would pass for the wrong reason — making the
        // regression test vacuous (the exact failure mode codex
        // caught). This gate fails loudly if the fixture stops
        // representing a "valid stale envelope".
        do {
            let preCheck = SessionStore(customStoreURL: sessions)
            await preCheck.awaitInitialLoad()
            #expect(preCheck.sessions.count == 1,
                    "fixture sanity: stale envelope must decode to 1 session pre-coordinator; saw \(preCheck.sessions.count)")
            #expect(preCheck.sessions.first?.messages.first?.content == "write a detailed 500 word essay",
                    "fixture sanity: stale envelope must carry the dogfood prompt verbatim")
        }

        // Run the bootstrap coordinator against this app-support
        // tree. Genuinely-first install (no markers).
        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected install to succeed; saw \(final)")

        // Now stand up the production ``SessionStore`` against the
        // archived sessions.json path. The store's ``init`` runs the
        // same on-disk read the real ChatView triggers at app start;
        // ``awaitInitialLoad`` blocks until the async decode lands.
        // With the issue #401 fix, sessions.json is GONE (renamed to
        // a sibling backup) so the store sees the fast-path
        // "no file → loaded with empty sessions" branch.
        let store = SessionStore(customStoreURL: sessions)
        await store.awaitInitialLoad()

        // The user-visible assertion: ChatView opens with a fresh
        // empty state (no stale row in the sidebar, no stale prompt
        // recalled in the compose editor). This is the EXACT symptom
        // the dogfood report describes.
        #expect(store.sessions.isEmpty,
                "post-first-install SessionStore must be empty; saw \(store.sessions.count) stale sessions")
        #expect(store.activeID == nil,
                "post-first-install SessionStore must have no active session; saw \(String(describing: store.activeID))")

        // And the forensic backup must carry the stale bytes so the
        // user can recover if they actually wanted that history.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("sessions.")
                && $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.count == 1,
                "exactly one forensic backup must exist; saw \(backups.map(\.lastPathComponent))")
        if let backup = backups.first {
            let recovered = try String(contentsOf: backup, encoding: .utf8)
            #expect(recovered.contains("write a detailed 500 word essay"),
                    "forensic backup must carry the stale prompt verbatim")
        }
    }

    /// Codex r2 MAJOR pin: backfill the history marker on the
    /// detect short-circuit path so pre-#401 users (existing
    /// runtime-override OR bundled-sidecar) get the marker too. The
    /// migration gap this closes: a v0.8.x user who later deletes
    /// the bundled tree and re-launches against a future P3
    /// bootstrapper DMG would otherwise have NO history marker, and
    /// the predicate would misclassify as "genuinely first install"
    /// and archive their real history.
    ///
    /// We MUST NOT archive sessions.json on this path — the user
    /// has a valid install and we just detected it; their history is
    /// theirs to keep. We only write the marker so the NEXT
    /// reinstall-after-delete can resolve correctly.
    @Test("issue #401 codex r2: backfill history marker on detect short-circuit")
    func issue401BackfillHistoryMarkerOnDetect() async throws {
        let appSupport = Self.tempDir("app-support-backfill")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")

        // Seed an existing runtime-override marker — this user is
        // already installed via a pre-#401 bootstrap run.
        Self.writeVersion("v0.9.0", at: runtime.appendingPathComponent("VERSION"))
        // Real history sitting in sessions.json the user does NOT
        // want destroyed.
        let payload = #"{"sessions":[{"id":"keep-me"}]}"#
        try Data(payload.utf8).write(to: sessions, options: .atomic)
        // Marker deliberately absent — simulating pre-#401 state.
        #expect(!FileManager.default.fileExists(atPath: history.path),
                "precondition: history marker must be absent before the test")

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "detect path must short-circuit to installed; saw \(final)")
        // Backfill landed: marker now exists on disk.
        #expect(FileManager.default.fileExists(atPath: history.path),
                "history marker must be backfilled on detect short-circuit")
        // sessions.json UNTOUCHED — the detect path must NEVER
        // archive the user's history (they already have a valid
        // install).
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "sessions.json must be preserved on detect short-circuit")
        let recovered = try String(contentsOf: sessions, encoding: .utf8)
        #expect(recovered == payload,
                "sessions.json bytes must be untouched on detect path")
        // No backup files — same invariant as the bundled path test.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty,
                "detect short-circuit must NOT create any backup files")
    }

    /// Codex r5 MAJOR — documented residual-risk acceptance test.
    ///
    /// Scenario:
    ///   1. First install runs.
    ///   2. ``maybeWriteHistoryMarker()`` fails to land the marker
    ///      (read-only mount / sandbox flip / ENOSPC — observed in
    ///      support tickets, all rare).
    ///   3. Per codex r1 MAJOR ordering, the archive is SKIPPED so the
    ///      user's existing ``sessions.json`` (which on this hypothetical
    ///      machine carries a previous tenant's stale chat) is preserved
    ///      verbatim. The user therefore sees the same stale-frame
    ///      first-impression #401 set out to fix — but it's the FAIL-
    ///      CLOSED outcome (no data loss) and the install pipeline
    ///      itself succeeded.
    ///   4. User continues to use the app and builds REAL chat history
    ///      on top of the unmoved envelope.
    ///   5. User deletes ``runtime-override/`` for any reason (corrupt
    ///      sidecar recovery, disk cleanup) and re-launches.
    ///   6. The predicate now sees: no runtime-override marker, no
    ///      bundled marker, no ``.bootstrap-history`` — and classifies
    ///      this as a genuinely-first install. ``sessions.json`` gets
    ///      archived → user's real chats are renamed to
    ///      ``sessions.<stamp>.bak.json``. Recoverable via the backup,
    ///      but the active envelope is wiped.
    ///
    /// Decision: ACCEPT the residual risk. The compound probability of
    /// (a) marker write failure on a fresh ``Application Support``
    /// directory the install pipeline JUST successfully wrote ``runtime-
    /// override/`` into, AND (b) the user later building real history,
    /// AND (c) the user then intentionally deleting their sidecar tree,
    /// is several orders of magnitude lower than the routine bug #401
    /// itself solves. The archive is recoverable (we rename rather than
    /// rm) and every subsequent detect short-circuit re-attempts the
    /// marker write (per the codex r2 backfill path), so the window
    /// closes on every successful launch with a working filesystem.
    ///
    /// The two alternative fixes considered + rejected:
    ///
    ///   * **Sniff ``sessions.json`` content as a secondary discriminator.**
    ///     Defeats the original bug entirely — the dogfood report describes
    ///     a previous tenant's "write a 500 word essay" prompt in
    ///     ``sessions.json``, which IS real content, so any content-based
    ///     predicate that refuses to archive on "non-empty sessions" would
    ///     leave the entire reported bug unfixed.
    ///
    ///   * **Fail-the-install on marker-write failure.** Marker write
    ///     failures are usually transient (ENOSPC clears once the user
    ///     frees space; permission flips clear after Settings dialogs);
    ///     refusing to launch the app — which has a complete, verified,
    ///     atomically-published sidecar — over a 4 KB metadata write is
    ///     worse UX than the residual-risk scenario itself, and turns a
    ///     P3 forensic concern into a P0 launch failure.
    ///
    /// This test pins the documented behaviour so any future change that
    /// alters the trade-off will surface immediately. If a follow-up PR
    /// closes the residual risk (e.g. by writing a marker to a different
    /// durable surface that survives ``runtime-override`` deletion), this
    /// test should be updated to assert the new behaviour rather than
    /// silently flipped.
    @Test("issue #401 codex r5: documented residual-risk — fail-closed semantic on cascaded marker failure")
    func issue401DocumentedResidualRiskOnMarkerFailure() async throws {
        let appSupport = Self.tempDir("app-support-residual-risk-pin")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")

        // ── Reconstruct the residual-risk steady state ────────────
        //
        // After all the cascaded failures above, the user is now
        // sitting at: real history in ``sessions.json``, NO
        // ``runtime-override/`` (they deleted it), NO history marker
        // (write failed at step 2 of the cascade). About to launch
        // afresh.
        let realHistoryPayload = #"""
        {
          "sessions" : [
            {
              "id" : "real-history-built-after-marker-failure",
              "messages" : [
                {
                  "content" : "real prompt the user typed after the first install",
                  "role" : "user"
                }
              ]
            }
          ]
        }
        """#
        try Data(realHistoryPayload.utf8).write(to: sessions, options: .atomic)
        #expect(!FileManager.default.fileExists(atPath: history.path),
                "precondition: history marker absent (step 2 of cascade)")
        #expect(!FileManager.default.fileExists(atPath: runtime.appendingPathComponent("VERSION").path),
                "precondition: runtime-override deleted (step 5 of cascade)")

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "install must still succeed even on the residual-risk path; saw \(final)")

        // ── DOCUMENTED OUTCOME ─────────────────────────────────────
        //
        // The predicate classifies this as genuinely-first install
        // (per the cascade above) and archives the user's REAL
        // history. The archive is recoverable — original bytes land
        // in ``sessions.<stamp>.bak.json``.
        //
        // This is the residual risk the PR body documents. If you're
        // here because this test failed, a recent change likely
        // closed the residual risk — update the assertions to pin
        // the new (better) behaviour, and remove this acceptance
        // documentation from the PR body / commit messages.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("sessions.")
                && $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.count == 1,
                "exactly one backup must be created on the residual-risk path (the archive is recoverable, not destructive); saw \(backups.map { $0.lastPathComponent })")
        if let backup = backups.first {
            let recovered = try String(contentsOf: backup, encoding: .utf8)
            #expect(recovered == realHistoryPayload,
                    "backup must carry the user's real history verbatim — recoverable via Finder / Time Machine")
        }
    }

    /// Codex r6 MAJOR — corrupt ``runtime-override/VERSION`` is still
    /// evidence of a prior install for archive-predicate purposes.
    ///
    /// Asymmetry-on-purpose: ``detectInstalled`` REJECTS a corrupt
    /// marker (returns nil → install pipeline re-runs) so the user
    /// gets a fresh, valid sidecar. But the archive predicate has a
    /// different job: it must NOT archive sessions.json whenever
    /// there's ANY evidence of prior bootstrap activity on this
    /// machine. A 7-byte truncated marker that fails the digits-only
    /// grammar check is still very strong evidence that someone has
    /// run the bootstrapper here before — and their sessions.json
    /// (probably real chat history) must survive the repair install.
    ///
    /// Before codex r6 fix: ``computeIsGenuinelyFirstInstall`` used
    /// ``readMarker``-based ``hasNonEmptyMarker``, which would say
    /// "no valid marker found" for a truncated VERSION and
    /// misclassify this repair install as genuinely-first → archive
    /// the user's real history.
    ///
    /// After fix: ``fileExists`` on the marker path returns true for
    /// the 7-byte file → predicate returns false → archive skipped
    /// → sessions.json untouched. Install pipeline still runs (because
    /// detect rejects the corrupt marker for grammar reasons) and
    /// replaces the corrupt tree with a fresh one.
    @Test("issue #401 codex r6: corrupt runtime-override/VERSION preserves sessions during repair reinstall")
    func issue401CorruptRuntimeMarkerPreservesSessions() async throws {
        let appSupport = Self.tempDir("app-support-corrupt-runtime-marker")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")

        // Plant a CORRUPT runtime marker (binary garbage that fails
        // the digits-only grammar in readMarker). The directory
        // itself is present + the file is present — evidence of
        // prior install — but the contents are not parseable.
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data([0x00, 0xFF, 0xAB, 0xCD, 0x12, 0x34, 0x56])
        try corruptBytes.write(
            to: runtime.appendingPathComponent("VERSION"),
            options: .atomic
        )
        // Real history sitting in sessions.json the user does NOT
        // want destroyed during the repair reinstall.
        let realPayload = #"{"sessions":[{"id":"real-history","messages":[{"role":"user","content":"keep me"}]}]}"#
        try Data(realPayload.utf8).write(to: sessions, options: .atomic)
        // No history marker — pre-#401 install.
        #expect(!FileManager.default.fileExists(atPath: history.path),
                "precondition: history marker must be absent (pre-#401 install)")

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        // Install must succeed (detect rejected the corrupt marker
        // and re-ran the install pipeline).
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected install to succeed after corrupt-marker rejection; saw \(final)")
        // sessions.json must be UNTOUCHED — the corrupt marker was
        // evidence of prior bootstrap activity, so the predicate
        // correctly refused to archive.
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "sessions.json must be preserved across repair reinstall")
        let recovered = try String(contentsOf: sessions, encoding: .utf8)
        #expect(recovered == realPayload,
                "sessions.json bytes must be untouched when runtime marker exists (even if corrupt)")
        // No backup files — same invariant as the reinstall path test.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("sessions.")
                && $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty,
                "repair-reinstall path must NOT archive sessions.json; saw \(backups.map { $0.lastPathComponent })")
    }

    /// Codex r6 MAJOR companion — same asymmetry for the bundled
    /// marker. A corrupt ``Contents/Resources/rapid-mlx/VERSION``
    /// (rare but possible — partial DMG install, signed-resource
    /// tampering) must still suppress the archive. ``detectInstalled``
    /// might reject the bundled marker for grammar reasons and run
    /// the install pipeline, but the predicate must read "prior
    /// install detected" and preserve the user's history.
    @Test("issue #401 codex r6: corrupt bundled VERSION preserves sessions during repair install")
    func issue401CorruptBundledMarkerPreservesSessions() async throws {
        let appSupport = Self.tempDir("app-support-corrupt-bundled")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")
        // Bundled marker lives inside a separate tree the test owns.
        let bundleRoot = Self.tempDir("bundle-corrupt")
        defer { try? FileManager.default.removeItem(at: bundleRoot) }
        let bundledMarker = bundleRoot
            .appendingPathComponent("rapid-mlx/VERSION")
        try FileManager.default.createDirectory(
            at: bundledMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: bundledMarker, options: .atomic)
        let realPayload = #"{"sessions":[{"id":"x","messages":[{"role":"user","content":"y"}]}]}"#
        try Data(realPayload.utf8).write(to: sessions, options: .atomic)

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: bundledMarker,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        _ = await Self.awaitTerminal(coord)
        // Whatever the final state, sessions.json must survive.
        // (The detect path may or may not fall through to install
        // depending on the corrupt-marker fallback; the predicate
        // invariant is independent of that detail.)
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "sessions.json must survive even when bundled marker is corrupt")
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )) ?? []
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("sessions.")
                && $0.lastPathComponent.hasSuffix(".bak.json")
        }
        #expect(backups.isEmpty,
                "corrupt bundled marker still suppresses archive; saw \(backups.map { $0.lastPathComponent })")
    }

    /// Codex r5 MINOR — preserve the original ``first_install``
    /// timestamp across detect/install backfills.
    ///
    /// Pin: a pre-existing ``.bootstrap-history`` marker (e.g. written
    /// by a prior bootstrap on this machine) must NOT be rewritten
    /// with a "now" timestamp on every subsequent launch / detect
    /// short-circuit. The marker's purpose is forensic — knowing WHEN
    /// the user first bootstrapped is the only thing the body
    /// communicates — and overwriting it silently erases that history.
    @Test("issue #401 codex r5: existing history marker is NOT rewritten on detect backfill")
    func issue401HistoryMarkerNotRewrittenOnBackfill() async throws {
        let appSupport = Self.tempDir("app-support-marker-preserve")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let runtime = appSupport.appendingPathComponent("runtime-override")
        let history = appSupport.appendingPathComponent(".bootstrap-history")
        let sessions = appSupport.appendingPathComponent("sessions.json")

        Self.writeVersion("v0.9.0", at: runtime.appendingPathComponent("VERSION"))
        // Plant a pre-existing marker with a known historic timestamp
        // — the body the user / support might one day grep for.
        let originalBody = "first_install=2024-01-15T00:00:00Z\n"
        try Data(originalBody.utf8).write(to: history, options: .atomic)
        // sessions.json present + non-empty so the install still
        // takes a normal-looking path (detect short-circuit fires
        // because the runtime marker is present).
        try Data(#"{"sessions":[]}"#.utf8).write(to: sessions, options: .atomic)

        let (coord, work) = Self.makeCoordinatorWithSessionArchive(
            runtimeDir: runtime,
            bundledMarker: nil,
            historyMarker: history,
            sessionsFile: sessions
        )
        defer { try? FileManager.default.removeItem(at: work) }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "expected detect short-circuit to succeed; saw \(final)")
        // The marker MUST still carry the ORIGINAL timestamp body.
        // Without the codex r5 MINOR fix, this would now read
        // "first_install=<today>" and the original first-install date
        // would be silently lost.
        let recoveredBody = try String(contentsOf: history, encoding: .utf8)
        #expect(recoveredBody == originalBody,
                "history marker body must be preserved verbatim across detect backfills; saw \(recoveredBody)")
    }
}

private enum TestError: Error {
    case deliberate
    case shouldNotFetch
}
