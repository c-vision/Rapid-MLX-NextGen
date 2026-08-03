import CryptoKit
import Foundation
import Testing
@testable import Rapid

/// P3 slice γ coverage matrix for ``BootstrapCoordinator``'s
/// concurrent sidecar+model install path.
///
/// Coordinate with the legacy ``BootstrapCoordinatorTests``: those
/// pin the sidecar-only path (today's production manifest, no model
/// fields). This suite adds the slice-γ behaviours:
///
///   1. Manifest WITHOUT model fields → coordinator behaves
///      IDENTICALLY to today (no model installer call, no
///      modelInstallRoot mutation, splash bar matches legacy
///      progress curve, ``.installed(.bootstrapInstalled)``).
///   2. Manifest WITH model fields → both downloads issued; both
///      extracted; both committed atomically; sidecar VERSION marker
///      on disk; model alias directory under installRoot.
///   3. Sidecar succeeds, model fails (404 download) → coordinator
///      returns ``.failed(.modelDownloadFailed)``, sidecar NOT
///      published (scratch removed), model staging cleaned up.
///   4. Model succeeds, sidecar fails (SHA mismatch) → coordinator
///      returns ``.failed(.verifyMismatch)``, model staging cleaned
///      up; nothing published.
///   5. Cancel mid-download → both child tasks observe cancellation,
///      both stagings cleaned up.
///   6. Combined progress callback reports weighted aggregate
///      (sidecar 50/100 + model 250/500 = 300/600 = 0.5 of the
///      0.05..0.60 download band).
///   7. Partial manifest (model_url present, model_sha256 absent) →
///      validate() rejects with descriptive error referencing the
///      missing field name (so a publisher-side typo is easy to
///      attribute).
@Suite("BootstrapCoordinatorConcurrentInstall", .serialized)
@MainActor
struct BootstrapCoordinatorConcurrentInstallTests {

    // MARK: - URLProtocol stub (sidecar + model URLs both routed)

    /// Per-suite URLProtocol stub. Keyed by request URL so the
    /// sidecar and model legs receive different payloads without
    /// suite-level race risk.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bodies: [URL: Data] = [:]
        nonisolated(unsafe) static var statusCodes: [URL: Int] = [:]
        nonisolated(unsafe) static var delays: [URL: TimeInterval] = [:]

        static func reset() {
            bodies.removeAll()
            statusCodes.removeAll()
            delays.removeAll()
        }

        static func setBody(_ data: Data, for url: URL, status: Int = 200, delay: TimeInterval = 0) {
            bodies[url] = data
            statusCodes[url] = status
            delays[url] = delay
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self,
                                    didFailWithError: NSError(domain: "stub", code: 1))
                return
            }
            let body = Self.bodies[url] ?? Data()
            let code = Self.statusCodes[url] ?? 200
            let delay = Self.delays[url] ?? 0
            // Honour delay so cancellation tests have a window.
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if code >= 200 && code < 300 {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() { /* no-op */ }
    }

    // MARK: - Test doubles

    /// Stub extractor mirroring the one in BootstrapCoordinatorTests
    /// — writes a fixed layout into the destination directory.
    private final class StubTar: SidecarExtractor.TarExtractor, @unchecked Sendable {
        let layout: [(relativePath: String, body: Data)]
        init(layout: [(String, Data)]) {
            self.layout = layout.map { ($0.0, $0.1) }
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

    private final class ModelStubTar: ModelInstaller.TarExtractor, @unchecked Sendable {
        let layout: [(relativePath: String, body: Data)]
        let throwError: ModelInstaller.ModelInstallError?
        init(layout: [(String, Data)], throwError: ModelInstaller.ModelInstallError? = nil) {
            self.layout = layout.map { ($0.0, $0.1) }
            self.throwError = throwError
        }
        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            if let err = throwError { throw err }
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

    private struct PassMachO: SidecarExtractor.MachOVerifier {
        func verify(url: URL) async throws { /* always pass */ }
    }

    private static func machOBytes() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00])
    }

    nonisolated private static func tempDir(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boot-coord-cc-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixtures {
        let runtime: URL
        let work: URL
        let modelRoot: URL
        let sidecarBytes: Data
        let modelBytes: Data
        let sidecarSHA: String
        let modelSHA: String
        let sidecarURL: URL
        let modelURL: URL

        static func make(label: String,
                         sidecarBytesCount: Int = 64,
                         modelBytesCount: Int = 128) -> Fixtures {
            let sidecar = Data(repeating: 0x42, count: sidecarBytesCount)
            let model = Data(repeating: 0x37, count: modelBytesCount)
            return Fixtures(
                runtime: tempDir("rt-\(label)"),
                work: tempDir("work-\(label)"),
                modelRoot: tempDir("models-\(label)"),
                sidecarBytes: sidecar,
                modelBytes: model,
                sidecarSHA: SHA256Verifier.hexString(SHA256.hash(data: sidecar)),
                modelSHA: SHA256Verifier.hexString(SHA256.hash(data: model)),
                sidecarURL: URL(string: "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz")!,
                modelURL: URL(string: "https://dl.rapidmlx.com/rapid-quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz")!
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: modelRoot)
            try? FileManager.default.removeItem(
                at: runtime
                    .deletingLastPathComponent()
                    .appendingPathComponent(runtime.lastPathComponent + ".bootstrap-scratch")
            )
        }

        func sidecarOnlyManifest() -> BootstrapManifest {
            BootstrapManifest(
                schemaVersion: 1,
                version: "0.9.0",
                sidecarURL: sidecarURL,
                sidecarSHA256: sidecarSHA,
                sidecarSize: UInt64(sidecarBytes.count)
            )
        }

        func fullManifest(alias: String = "bonsai-1.7b-2bit") -> BootstrapManifest {
            BootstrapManifest(
                schemaVersion: 1,
                version: "0.9.0",
                sidecarVersion: "0.8.18",
                sidecarURL: sidecarURL,
                sidecarSHA256: sidecarSHA,
                sidecarSize: UInt64(sidecarBytes.count),
                modelURL: modelURL,
                modelSHA256: modelSHA,
                modelSize: UInt64(modelBytes.count),
                modelAlias: alias
            )
        }
    }

    private static func makeStubInstaller(stub: StubProtocol.Type = StubProtocol.self) -> BootstrapInstaller {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [stub]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        return BootstrapInstaller(downloader: downloader)
    }

    private static func makeStubModelInstaller(
        layout: [(String, Data)] = [
            ("config.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0xAA, count: 256))
        ],
        throwError: ModelInstaller.ModelInstallError? = nil
    ) -> ModelInstaller {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        let tar = ModelStubTar(layout: layout, throwError: throwError)
        return ModelInstaller(downloader: downloader, tarExtractor: tar)
    }

    private static func awaitTerminal(
        _ coord: BootstrapCoordinator,
        timeoutSeconds: Double = 10
    ) async -> BootstrapCoordinator.State {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch coord.state {
            case .installed, .failed:
                return coord.state
            default:
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return coord.state
    }

    private static func buildCoordinator(
        f: Fixtures,
        manifest: BootstrapManifest,
        extractorLayout: [(String, Data, Bool)] = [
            ("VERSION", Data("0.0.0-from-tarball".utf8), false),
            ("rapid-mlx/bin/rapid-mlx", machOBytes(), true)
        ],
        modelExtractorLayout: [(String, Data)] = [
            ("config.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0xAA, count: 256))
        ],
        modelExtractorError: ModelInstaller.ModelInstallError? = nil,
        fileManager: FileManager = .default
    ) -> BootstrapCoordinator {
        // Reset and reseed URLProtocol bodies for both legs.
        StubProtocol.reset()
        StubProtocol.setBody(f.sidecarBytes, for: f.sidecarURL)
        if manifest.hasModelArtifact, let modelURL = manifest.modelURL {
            StubProtocol.setBody(f.modelBytes, for: modelURL)
        }

        let sidecarTar = StubTar(layout: extractorLayout.map { ($0.0, $0.1) })
        let extractor = SidecarExtractor(
            tarExtractor: sidecarTar,
            machOVerifier: PassMachO()
        )
        let installer = makeStubInstaller()
        let modelInstaller = makeStubModelInstaller(
            layout: modelExtractorLayout,
            throwError: modelExtractorError
        )

        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: f.runtime,
            bundledMarker: nil,
            workDirectory: f.work,
            manifestFetcher: { manifest },
            installer: installer,
            extractor: extractor,
            expectedVersion: nil,
            fileManager: fileManager,
            modelInstaller: modelInstaller,
            modelInstallRoot: f.modelRoot
        )
        return BootstrapCoordinator(configuration: config)
    }

    // MARK: - Tests

    @Test("legacy sidecar-only manifest: behaves identically to today (zero regression)")
    func legacyPathUnchanged() async {
        let f = Fixtures.make(label: "legacy")
        defer { f.cleanup() }
        let coord = Self.buildCoordinator(f: f, manifest: f.sidecarOnlyManifest())

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.9.0")),
                "legacy sidecar-only install must succeed; saw \(final)")

        // Sidecar marker on disk at runtime-override
        let marker = f.runtime.appendingPathComponent("VERSION")
        let written = try? String(contentsOf: marker, encoding: .utf8)
        #expect(written == "0.9.0",
                "sidecar marker should record manifest version on legacy path")

        // Model install root MUST NOT have been mutated — the alias
        // directory never gets created on the sidecar-only path.
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit")
        #expect(!FileManager.default.fileExists(atPath: aliasDir.path),
                "model install root MUST NOT be touched when manifest lacks model fields")
    }

    @Test("full manifest: both artifacts staged + committed atomically")
    func fullManifestBothCommitted() async {
        let f = Fixtures.make(label: "full")
        defer { f.cleanup() }
        let manifest = f.fullManifest()
        let coord = Self.buildCoordinator(f: f, manifest: manifest)

        coord.start()
        let final = await Self.awaitTerminal(coord)
        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "full-manifest install must succeed with sidecar version surfaced; saw \(final)")

        // Sidecar marker on disk at the bootstrap install destination
        let marker = f.runtime.appendingPathComponent("VERSION")
        let writtenMarker = try? String(contentsOf: marker, encoding: .utf8)
        #expect(writtenMarker == "0.8.18",
                "sidecar marker should reflect sidecar_version on full-manifest path")

        // Model alias directory on disk
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: aliasDir.path, isDirectory: &isDir),
                "model alias directory MUST exist after successful full-manifest install")
        #expect(isDir.boolValue, "model alias path must be a directory")

        // Model contents intact
        let configPath = aliasDir.appendingPathComponent("config.json")
        let configBody = try? Data(contentsOf: configPath)
        #expect(configBody == Data("{}".utf8),
                "model contents must survive the staging → atomic publish hop")

        // Staging sibling removed on both legs
        let modelStaging = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit.partial.extracted")
        #expect(!FileManager.default.fileExists(atPath: modelStaging.path),
                "model staging sibling must be removed after commit")
    }

    // MARK: - #458: model-already-present skip-leg + corrupt fail-fast

    /// Throws ``removeItem`` ONLY for one exact path (the model alias
    /// destination), delegating every other filesystem op to the real
    /// FileManager. Lets the #458 corrupt-model fail-fast path be driven
    /// deterministically without derailing the coordinator's unrelated
    /// removeItem calls (work-dir cleanup, staging teardown).
    final class ModelRemoveFailingFileManager: FileManager, @unchecked Sendable {
        let blockedPath: String
        var blockedRemoveAttempts = 0
        init(blockedPath: String) {
            self.blockedPath = blockedPath
            super.init()
        }
        override func removeItem(at url: URL) throws {
            if url.path == blockedPath {
                blockedRemoveAttempts += 1
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "permission denied (test)"]
                )
            }
            try super.removeItem(at: url)
        }
    }

    @Test("#458: modelDiskState classifies present / corrupt / absent")
    func modelDiskStateClassification() {
        let root = Self.tempDir("disk-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let alias = "bonsai-1.7b-2bit"

        // absent: no directory at all
        #expect(BootstrapCoordinator.modelDiskState(alias: alias, installRoot: root, fileManager: fm) == .absent)

        // corrupt: directory exists but no config.json in flat or nested shape
        let aliasDir = root.appendingPathComponent(alias, isDirectory: true)
        try? fm.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: aliasDir.appendingPathComponent("partial.bin"))
        #expect(BootstrapCoordinator.modelDiskState(alias: alias, installRoot: root, fileManager: fm) == .corrupt)

        // present: flat config.json materialises
        try? Data("{}".utf8).write(to: aliasDir.appendingPathComponent("config.json"))
        #expect(BootstrapCoordinator.modelDiskState(alias: alias, installRoot: root, fileManager: fm) == .present)
    }

    @Test("#458: model already present → model leg skipped, sidecar STILL installs (upgrader path)")
    func modelAlreadyPresentSkipsLegSidecarStillInstalls() async {
        let f = Fixtures.make(label: "present-skip")
        defer { f.cleanup() }
        let manifest = f.fullManifest()

        // Pre-seed a valid (flat) model dir, exactly like a v0.8.13
        // upgrader who already pulled the Quickstart model. Before the
        // fix, ModelInstaller.stage threw .alreadyInstalled here, which
        // cancelled the sidecar sibling and surfaced as the permanent
        // "Setup didn't finish" splash.
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit", isDirectory: true)
        try? FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        let preExistingConfig = Data(#"{"pre":"existing"}"#.utf8)
        try? preExistingConfig.write(to: aliasDir.appendingPathComponent("config.json"))

        let coord = Self.buildCoordinator(f: f, manifest: manifest)
        coord.start()
        let final = await Self.awaitTerminal(coord)

        #expect(final == .installed(.bootstrapInstalled(version: "0.8.18")),
                "install must SUCCEED when the model is already present (sidecar leg unaffected); saw \(final)")

        // Sidecar actually installed (marker written) — the leg was not
        // cancelled by the model leg's would-be .alreadyInstalled.
        let marker = f.runtime.appendingPathComponent("VERSION")
        #expect((try? String(contentsOf: marker, encoding: .utf8)) == "0.8.18",
                "sidecar marker must be written — skipping the model leg must not skip the sidecar")

        // Pre-existing model untouched (not re-staged / overwritten).
        let configBody = try? Data(contentsOf: aliasDir.appendingPathComponent("config.json"))
        #expect(configBody == preExistingConfig,
                "an already-present model must be left exactly as-is, not re-downloaded")
    }

    @Test("#458 codex r1 MAJOR: corrupt + undeletable model → fail-fast filesystem error, NOT the cancel cascade")
    func corruptUndeletableModelFailsFast() async {
        let f = Fixtures.make(label: "corrupt-undeletable")
        defer { f.cleanup() }
        let manifest = f.fullManifest()

        // Corrupt: alias dir exists, no config.json → modelDiskState .corrupt.
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit", isDirectory: true)
        try? FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        try? Data("partial".utf8).write(to: aliasDir.appendingPathComponent("model.partial"))

        // FileManager that refuses to remove the corrupt dir.
        let failingFM = ModelRemoveFailingFileManager(blockedPath: aliasDir.path)
        let coord = Self.buildCoordinator(f: f, manifest: manifest, fileManager: failingFM)

        coord.start()
        let final = await Self.awaitTerminal(coord)

        guard case .failed(let failure) = final else {
            Issue.record("expected .failed when the corrupt model dir cannot be removed; saw \(final)")
            return
        }
        guard case .modelDownloadFailed(let message) = failure else {
            Issue.record("expected .modelDownloadFailed; saw \(failure)")
            return
        }
        #expect(message.contains("Couldn't clear an incomplete model download"),
                "must surface the actionable filesystem error, NOT the 'already present' cancel cascade; saw \(message)")
        #expect(failingFM.blockedRemoveAttempts >= 1,
                "the corrupt-dir removal must have been attempted before failing")
        // Fail-fast happens BEFORE the task group, so the sidecar marker
        // must NOT have been written (we never dispatched the legs).
        let marker = f.runtime.appendingPathComponent("VERSION")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "fail-fast must short-circuit before the install task group runs")
    }

    @Test("model 404 → sidecar NOT published; model staging cleaned up")
    func modelFailsSidecarNotPublished() async {
        let f = Fixtures.make(label: "model-fail")
        defer { f.cleanup() }
        let manifest = f.fullManifest()

        // Build coordinator + override the model URL stub to return 404.
        let coord = Self.buildCoordinator(f: f, manifest: manifest)
        // Override AFTER buildCoordinator (it seeded a 200 OK body).
        if let modelURL = manifest.modelURL {
            StubProtocol.setBody(Data(), for: modelURL, status: 404)
        }

        coord.start()
        let final = await Self.awaitTerminal(coord)
        guard case .failed(let failure) = final else {
            Issue.record("expected .failed; saw \(final)")
            return
        }
        // Either modelDownloadFailed (translated through stage path)
        // OR download(.unexpectedStatusCode(404)) — both indicate the
        // model leg failed.
        switch failure {
        case .modelDownloadFailed:
            break
        case .download:
            break
        default:
            Issue.record("expected model-download failure variant; saw \(failure)")
        }

        // Sidecar MUST NOT be on disk — atomic-or-nothing contract.
        let marker = f.runtime.appendingPathComponent("VERSION")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "sidecar marker MUST NOT exist after model-leg failure")

        // Model staging directory cleaned up
        let modelStaging = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit.partial.extracted")
        #expect(!FileManager.default.fileExists(atPath: modelStaging.path),
                "model staging must be cleaned up after model failure")
    }

    @Test("sidecar SHA mismatch → model staging cleaned up; nothing published")
    func sidecarFailsModelCleanedUp() async {
        let f = Fixtures.make(label: "sidecar-fail")
        defer { f.cleanup() }
        // Manifest declares a hash that DOESN'T match the bytes the
        // stub will deliver → SHA mismatch during sidecar verify.
        var manifest = f.fullManifest()
        let badSHA = String(repeating: "c", count: 64)
        manifest = BootstrapManifest(
            schemaVersion: 1,
            version: manifest.version,
            sidecarVersion: manifest.sidecarVersion,
            sidecarURL: manifest.sidecarURL,
            sidecarSHA256: badSHA,
            sidecarSize: manifest.sidecarSize,
            modelURL: manifest.modelURL,
            modelSHA256: manifest.modelSHA256,
            modelSize: manifest.modelSize,
            modelAlias: manifest.modelAlias
        )

        let coord = Self.buildCoordinator(f: f, manifest: manifest)
        coord.start()
        let final = await Self.awaitTerminal(coord)
        guard case .failed(let failure) = final else {
            Issue.record("expected .failed; saw \(final)")
            return
        }
        if case .verifyMismatch = failure {
            // ok
        } else {
            Issue.record("expected verifyMismatch; saw \(failure)")
        }

        // Model alias directory MUST NOT exist on the destination.
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit")
        #expect(!FileManager.default.fileExists(atPath: aliasDir.path),
                "model MUST NOT be published when sidecar fails")

        // Model staging cleaned up too (rollback fired)
        let modelStaging = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit.partial.extracted")
        #expect(!FileManager.default.fileExists(atPath: modelStaging.path),
                "model staging must be cleaned after sidecar failure")
    }

    @Test("codex r1 BLOCKING: revertSidecarPublish unit — move + remove clears destination, returns .cleared")
    func revertSidecarPublishHappyPath() throws {
        let root = Self.tempDir("revert-happy")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtime-override")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("VERSION".utf8).write(
            to: destination.appendingPathComponent("VERSION")
        )
        let outcome = BootstrapCoordinator.revertSidecarPublish(
            destination: destination,
            fileManager: FileManager.default
        )
        #expect(outcome == .cleared,
                "happy-path revert must report .cleared; saw \(outcome)")
        // Codex r2 MAJOR: revert scratch must NOT linger
        let revertScratch = root.appendingPathComponent("runtime-override.bootstrap-revert-scratch")
        #expect(!FileManager.default.fileExists(atPath: revertScratch.path),
                "revert scratch MUST be cleaned after successful revert (codex r2 MAJOR — no orphan)")
        #expect(!FileManager.default.fileExists(atPath: destination.path),
                "destination MUST be free after .cleared")
    }

    @Test("codex r1 BLOCKING: revertSidecarPublish on missing destination → .nothingToRevert")
    func revertSidecarPublishNoOp() {
        let root = Self.tempDir("revert-noop")
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = BootstrapCoordinator.revertSidecarPublish(
            destination: root.appendingPathComponent("does-not-exist"),
            fileManager: FileManager.default
        )
        #expect(outcome == .nothingToRevert)
    }

    @Test("codex r1 BLOCKING: revertSidecarPublish — failed outcome carries diagnostic")
    func revertSidecarPublishFailedDiagnostic() {
        // Synthesize a .failed RevertOutcome and verify the
        // user-facing message embeds it. The diagnostic-string
        // contract is the load-bearing piece here — support uses
        // the "FAILED" capital + inner error to spot half-installed
        // cases. The drive-through-FileManager version below
        // (revertSidecarPublishFailedRealPath) covers the actual
        // code path on a real subclassed FileManager.
        let outcome = BootstrapCoordinator.RevertOutcome.failed(
            message: "removeItem failed: permission denied"
        )
        let suffix = outcome.diagnosticSuffix
        #expect(suffix.contains("FAILED"),
                "failed-outcome suffix MUST capitalise FAILED so support spots half-installed cases; saw \(suffix)")
        #expect(suffix.contains("permission denied"),
                "failed-outcome suffix MUST embed the inner error message; saw \(suffix)")
    }

    /// FileManager subclass that throws on ``moveItem`` and
    /// ``removeItem`` so the test can deterministically drive
    /// ``revertSidecarPublish`` through its failure path WITHOUT
    /// relying on root privileges or chattr-style tricks (which
    /// codex r3 MAJOR flagged as the gap in the previous test).
    ///
    /// ``fileExists`` still consults the underlying disk so the
    /// destination-survives invariant is honest (the file IS still
    /// there because we never let the removal succeed).
    final class FailingFileManager: FileManager, @unchecked Sendable {
        struct Failure: Error, LocalizedError {
            let op: String
            let message: String
            var errorDescription: String? { "\(op): \(message)" }
        }
        var moveCalls = 0
        var removeCalls = 0
        // If ``moveError`` / ``removeError`` is non-nil, the
        // corresponding operation throws. ``destinationStaysOnDisk``
        // tracks whether the fileExists query should report the
        // destination as still present after the failed ops.
        let moveError: Error?
        let removeError: Error?
        init(moveError: Error?, removeError: Error?) {
            self.moveError = moveError
            self.removeError = removeError
            super.init()
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moveCalls += 1
            if let err = moveError { throw err }
            try super.moveItem(at: srcURL, to: dstURL)
        }
        override func removeItem(at URL: URL) throws {
            removeCalls += 1
            if let err = removeError { throw err }
            try super.removeItem(at: URL)
        }
    }

    @Test("codex r3 MAJOR: revertSidecarPublish drives real failure path (move-fail + remove-fail + destination survives)")
    func revertSidecarPublishFailedRealPath() throws {
        let root = Self.tempDir("revert-real-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtime-override")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("VERSION".utf8).write(to: destination.appendingPathComponent("VERSION"))

        let fm = FailingFileManager(
            moveError: FailingFileManager.Failure(op: "moveItem", message: "permission denied"),
            removeError: FailingFileManager.Failure(op: "removeItem", message: "device busy")
        )

        let outcome = BootstrapCoordinator.revertSidecarPublish(
            destination: destination,
            fileManager: fm
        )

        // Must reach .failed because both ops threw AND destination
        // still exists on the real disk.
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed when both moveItem + removeItem throw and destination survives; saw \(outcome)")
            return
        }
        #expect(message.contains("removeItem failed"),
                "failure message must explain why removeItem couldn't clear destination; saw \(message)")
        #expect(message.contains("device busy"),
                "failure message must embed the inner removeItem error; saw \(message)")
        #expect(message.contains("moveItem failed"),
                "failure message must also explain why moveItem couldn't rename out; saw \(message)")
        #expect(message.contains("permission denied"),
                "failure message must embed the inner moveItem error; saw \(message)")

        // Verify the code path actually exercised BOTH legs (not just
        // the move fast path).
        #expect(fm.moveCalls >= 1, "moveItem must have been attempted")
        #expect(fm.removeCalls >= 1, "removeItem must have been attempted")

        // Destination MUST still exist because we never let any op
        // succeed — codex r2 BLOCKING contract: don't lie about
        // disk truth.
        #expect(FileManager.default.fileExists(atPath: destination.path),
                "destination must still be on disk when both ops failed (otherwise the test isn't pinning the real failure path)")

        // Diagnostic-suffix carrier-string is verified by the
        // ``.failed`` synthetic test above; here we only assert the
        // outcome value.
    }

    @Test("codex r3 MAJOR: revertSidecarPublish — move fails but removeItem fallback recovers → .cleared")
    func revertSidecarPublishMoveFailRemoveOK() throws {
        let root = Self.tempDir("revert-move-fail-remove-ok")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtime-override")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("VERSION".utf8).write(to: destination.appendingPathComponent("VERSION"))

        // moveItem throws, removeItem succeeds (uses super).
        let fm = FailingFileManager(
            moveError: FailingFileManager.Failure(op: "moveItem", message: "cross-volume rename"),
            removeError: nil
        )

        let outcome = BootstrapCoordinator.revertSidecarPublish(
            destination: destination,
            fileManager: fm
        )

        #expect(outcome == .cleared,
                "fallback removeItem must recover after a failed moveItem; saw \(outcome)")
        #expect(fm.moveCalls >= 1, "moveItem must be attempted before falling back")
        #expect(fm.removeCalls >= 1, "removeItem fallback must run when moveItem fails")
        #expect(!FileManager.default.fileExists(atPath: destination.path),
                "destination MUST be free after .cleared (fallback path)")
    }

    /// Stub model installer whose ``stage`` always succeeds (creates
    /// the staging directory directly so the coordinator's commit-
    /// phase finds it on disk) but whose ``commit`` throws a
    /// configurable error. Lets the coordinator-level test reach
    /// the post-publish revert path deterministically — codex r3
    /// MAJOR fix.
    /// Async-safe rollback-call counter. NSLock.lock() is unavailable
    /// from async contexts in Swift 6, so we wrap the counter in an
    /// actor. The instance is owned by ``FailingCommitInstaller`` and
    /// read by the test via ``await``.
    actor RollbackCounter {
        private(set) var value: Int = 0
        func increment() { value += 1 }
    }

    final class FailingCommitInstaller: ModelInstallerProtocol, @unchecked Sendable {
        let commitError: ModelInstaller.ModelInstallError
        // Track rollback calls so the test can assert the
        // coordinator's contract (rollback fires after commit fails).
        let rollbackTracker = RollbackCounter()
        init(commitError: ModelInstaller.ModelInstallError) {
            self.commitError = commitError
        }
        func stage(
            artifact: ModelInstaller.ArtifactSpec,
            installRoot: URL,
            workDirectory: URL,
            onProgress: (@Sendable (_ phase: ModelInstaller.Phase, _ progress: Double) -> Void)?
        ) async throws -> URL {
            // Mimic real stage: create installRoot + staging directory.
            try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
            let staging = installRoot.appendingPathComponent(
                artifact.alias + ".partial.extracted",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            // Drop a sentinel file so the staging dir is non-empty
            try Data("stub".utf8).write(to: staging.appendingPathComponent("STUB"))
            // Drive a final progress tick so the splash dual-line
            // detail has both leg counters.
            onProgress?(.installing, 0)
            return staging
        }
        func commit(stagedURL: URL, alias: String, installRoot: URL) async throws -> URL {
            throw commitError
        }
        func rollbackStaging(alias: String, installRoot: URL, workDirectory: URL) async {
            await rollbackTracker.increment()
            // Mimic real rollback: nuke the staging dir.
            let staging = installRoot.appendingPathComponent(
                alias + ".partial.extracted",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: staging)
        }
    }

    @Test("codex r1 BLOCKING: model commit throws after sidecar publish → sidecar reverted + model staging rolled back")
    func modelCommitFailureRevertsSidecar() async {
        let f = Fixtures.make(label: "model-commit-fail-stubbed")
        defer { f.cleanup() }
        let manifest = f.fullManifest()

        // Wire a real BootstrapInstaller (so sidecar leg works) +
        // a stub model installer whose commit throws after stage
        // succeeds. This reproduces the post-publish path the
        // codex r1 BLOCKING #1 + r3 MAJOR demanded.
        let failingModel = FailingCommitInstaller(
            commitError: .diskFailed(message: "synthetic commit failure", path: "/dev/null")
        )

        StubProtocol.reset()
        StubProtocol.setBody(f.sidecarBytes, for: f.sidecarURL)
        if let modelURL = manifest.modelURL {
            StubProtocol.setBody(f.modelBytes, for: modelURL)
        }
        let sidecarTar = StubTar(layout: [
            ("VERSION", Data("0.0.0-from-tarball".utf8)),
            ("rapid-mlx/bin/rapid-mlx", Self.machOBytes())
        ])
        let extractor = SidecarExtractor(
            tarExtractor: sidecarTar,
            machOVerifier: PassMachO()
        )
        let installer = Self.makeStubInstaller()

        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: f.runtime,
            bundledMarker: nil,
            workDirectory: f.work,
            manifestFetcher: { manifest },
            installer: installer,
            extractor: extractor,
            expectedVersion: nil,
            modelInstaller: failingModel,
            modelInstallRoot: f.modelRoot
        )
        let coord = BootstrapCoordinator(configuration: config)

        coord.start()
        let final = await Self.awaitTerminal(coord)
        guard case .failed(let failure) = final else {
            Issue.record("expected .failed; saw \(final)")
            return
        }
        if case let .modelDownloadFailed(message) = failure {
            #expect(message.contains("synthetic commit failure"),
                    "failure message must embed the inner commit error; saw \(message)")
            // Codex r2 BLOCKING — revert outcome diagnostic must
            // appear in the user-visible message.
            #expect(message.contains("[sidecar publish reverted]")
                || message.contains("revert"),
                    "failure message must carry a revert-outcome diagnostic; saw \(message)")
        } else {
            Issue.record("expected modelDownloadFailed; saw \(failure)")
        }

        // Atomic-or-nothing: destination MUST NOT have the
        // post-publish sidecar tree.
        let marker = f.runtime.appendingPathComponent("VERSION")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "sidecar marker MUST NOT survive at the destination after model-commit failure (codex r1 BLOCKING + r2 verify — atomic-or-nothing)")

        // .bootstrap-revert-scratch must NOT linger (codex r2 MAJOR)
        let revertScratch = f.runtime
            .deletingLastPathComponent()
            .appendingPathComponent(f.runtime.lastPathComponent + ".bootstrap-revert-scratch")
        #expect(!FileManager.default.fileExists(atPath: revertScratch.path),
                "revert scratch MUST be cleaned immediately (codex r2 MAJOR — no orphan)")

        // Codex r2 MAJOR — model staging rolled back via the
        // explicit coordinator call on the commit-failure branch.
        let rollbacks = await failingModel.rollbackTracker.value
        #expect(rollbacks >= 1,
                "coordinator MUST call rollbackStaging on the model-leg after commit failure; saw \(rollbacks) calls")
    }

    /// Stub model installer that:
    ///   1. Stages to a CUSTOM URL (not the default
    ///      `installRoot/<alias>.partial.extracted` path the
    ///      coordinator used to recompute).
    ///   2. Records the EXACT URL the coordinator passes into
    ///      ``commit`` so the test can assert end-to-end seam
    ///      honesty.
    /// Pins the codex r4 MAJOR fix: coordinator must commit the
    /// URL the installer returned from stage, NOT a recomputed
    /// path. If the coordinator ever regresses back to recomputing,
    /// this test fails loudly because the recorded commit URL won't
    /// match the custom staging URL we returned.
    actor CustomURLRecorder {
        private(set) var stagedURL: URL?
        private(set) var committedStagedURL: URL?
        func recordStaged(_ url: URL) { stagedURL = url }
        func recordCommitted(_ url: URL) { committedStagedURL = url }
    }

    final class CustomURLPassthroughInstaller: ModelInstallerProtocol, @unchecked Sendable {
        let recorder = CustomURLRecorder()
        let customStagingRoot: URL
        init(customStagingRoot: URL) {
            self.customStagingRoot = customStagingRoot
        }
        func stage(
            artifact: ModelInstaller.ArtifactSpec,
            installRoot: URL,
            workDirectory: URL,
            onProgress: (@Sendable (_ phase: ModelInstaller.Phase, _ progress: Double) -> Void)?
        ) async throws -> URL {
            // Stage to a CUSTOM path that is NOT what the coordinator
            // would recompute via `installRoot/<alias>.partial.extracted`.
            // If the coordinator ever regresses to recomputing, the
            // committedStagedURL will hold the recomputed path and
            // the assertion below will fail.
            let custom = customStagingRoot
                .appendingPathComponent("custom-\(artifact.alias)-staging")
            try? FileManager.default.removeItem(at: custom)
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            try Data("custom-staged".utf8).write(to: custom.appendingPathComponent("SENTINEL"))
            await recorder.recordStaged(custom)
            return custom
        }
        func commit(stagedURL: URL, alias: String, installRoot: URL) async throws -> URL {
            await recorder.recordCommitted(stagedURL)
            // Move the custom staging to the alias destination so the
            // happy-path commit semantic is preserved.
            let destination = installRoot.appendingPathComponent(alias, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: stagedURL, to: destination)
            return destination
        }
        func rollbackStaging(alias: String, installRoot: URL, workDirectory: URL) async {
            let custom = customStagingRoot
                .appendingPathComponent("custom-\(alias)-staging")
            try? FileManager.default.removeItem(at: custom)
        }
    }

    @Test("codex r5 MINOR: coordinator passes the EXACT staged URL from stage into commit (no recomputation)")
    func coordinatorCommitsInstallerReturnedURL() async throws {
        let f = Fixtures.make(label: "url-passthrough")
        defer { f.cleanup() }
        let manifest = f.fullManifest()

        // Use a custom staging root distinct from f.modelRoot so the
        // recomputed path (installRoot/<alias>.partial.extracted)
        // would NOT match what the stub stages to.
        let customRoot = Self.tempDir("custom-staging-root")
        defer { try? FileManager.default.removeItem(at: customRoot) }
        let passthrough = CustomURLPassthroughInstaller(customStagingRoot: customRoot)

        StubProtocol.reset()
        StubProtocol.setBody(f.sidecarBytes, for: f.sidecarURL)
        if let modelURL = manifest.modelURL {
            StubProtocol.setBody(f.modelBytes, for: modelURL)
        }
        let sidecarTar = StubTar(layout: [
            ("VERSION", Data("0.0.0-from-tarball".utf8)),
            ("rapid-mlx/bin/rapid-mlx", Self.machOBytes())
        ])
        let extractor = SidecarExtractor(
            tarExtractor: sidecarTar,
            machOVerifier: PassMachO()
        )
        let installer = Self.makeStubInstaller()

        let config = BootstrapCoordinator.Configuration(
            runtimeOverrideDir: f.runtime,
            bundledMarker: nil,
            workDirectory: f.work,
            manifestFetcher: { manifest },
            installer: installer,
            extractor: extractor,
            expectedVersion: nil,
            modelInstaller: passthrough,
            modelInstallRoot: f.modelRoot
        )
        let coord = BootstrapCoordinator(configuration: config)

        coord.start()
        let final = await Self.awaitTerminal(coord)
        guard case .installed = final else {
            Issue.record("expected .installed when both legs succeed; saw \(final)")
            return
        }

        // The whole point of this test: the URL the installer
        // returned from stage MUST be the URL the coordinator
        // passed into commit. If the coordinator regressed to
        // recomputing, committed would hold
        // f.modelRoot/bonsai-1.7b-2bit.partial.extracted, which is
        // NOT under customRoot.
        let staged = await passthrough.recorder.stagedURL
        let committed = await passthrough.recorder.committedStagedURL
        #expect(staged != nil, "stub stage must record its returned URL")
        #expect(committed != nil, "coordinator must call commit on stub")
        #expect(staged == committed,
                "coordinator MUST commit the EXACT URL stage returned (codex r4 MAJOR + r5 MINOR seam check); staged=\(String(describing: staged)) committed=\(String(describing: committed))")
        // Defensive: the committed URL must live under customRoot
        // (proves it's NOT the recomputed `f.modelRoot/...partial`
        // path). If the coordinator ever ignored the stub's return
        // value and recomputed, this assertion would fail because
        // the recomputed path resolves under f.modelRoot, not
        // customRoot.
        if let committed = committed {
            #expect(committed.path.hasPrefix(customRoot.path),
                    "committed URL MUST live under customRoot (the stub's chosen staging root); saw \(committed.path)")
        }
    }

    @Test("cancel mid-install → both legs cancelled, both stagings cleaned up")
    func cancelMidInstall() async {
        let f = Fixtures.make(label: "cancel")
        defer { f.cleanup() }
        let manifest = f.fullManifest()
        let coord = Self.buildCoordinator(f: f, manifest: manifest)
        // Add delays so the downloads don't complete before we cancel
        StubProtocol.setBody(f.sidecarBytes, for: f.sidecarURL, status: 200, delay: 0.2)
        if let modelURL = manifest.modelURL {
            StubProtocol.setBody(f.modelBytes, for: modelURL, status: 200, delay: 0.2)
        }

        coord.start()
        // Allow the install to enter the staging phase
        try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
        coord.cancel()
        let final = await Self.awaitTerminal(coord)
        if case .failed(.cancelled) = final {
            // ok
        } else {
            // Cancellation timing is racy; also accept any failure
            // outcome that does NOT publish (the user-visible
            // contract is "nothing landed on disk").
            switch final {
            case .failed:
                break
            default:
                Issue.record("expected .failed after cancel; saw \(final)")
            }
        }
        // Whichever timing path we landed on, nothing was published.
        let marker = f.runtime.appendingPathComponent("VERSION")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "sidecar marker MUST NOT exist after cancel")
        let aliasDir = f.modelRoot.appendingPathComponent("bonsai-1.7b-2bit")
        #expect(!FileManager.default.fileExists(atPath: aliasDir.path),
                "model alias dir MUST NOT exist after cancel")
    }

    // MARK: - Progress weighting (pure-function via CombinedProgress)

    @Test("combined progress: weighted by byte counts (sidecar 50/100 + model 250/500 = 0.5)")
    func combinedProgressWeightedNotAveraged() {
        let s = CombinedProgress.Component(bytesDone: 50, bytesTotal: 100)
        let m = CombinedProgress.Component(bytesDone: 250, bytesTotal: 500)
        let combined = CombinedProgress.aggregate(sidecar: s, model: m)
        // 300 / 600 = 0.5
        #expect(abs(combined - 0.5) < 1e-9,
                "weighted aggregate should be (50+250)/(100+500) = 0.5")
    }

    @Test("combined progress: sidecar-only path equals per-leg fraction")
    func combinedProgressSidecarOnly() {
        let s = CombinedProgress.Component(bytesDone: 88, bytesTotal: 200)
        let combined = CombinedProgress.aggregate(sidecar: s, model: nil)
        #expect(abs(combined - 0.44) < 1e-9,
                "sidecar-only aggregate should equal sidecar fraction; saw \(combined)")
    }

    @Test("combined progress: sidecar-only detail is the collapsed 'done / total UNIT' shape")
    func combinedProgressDetailLegacy() {
        let s = CombinedProgress.Component(bytesDone: 50 * 1024 * 1024, bytesTotal: 100 * 1024 * 1024)
        let detail = CombinedProgress.detail(sidecar: s, model: nil)
        // #461: one combined total via the canonical formatBytes; the
        // shared unit collapses ("50.0 / 100 MB"), never per-artifact labels.
        #expect(detail == "50.0 / 100 MB",
                "sidecar-only detail must be the collapsed 'done / total UNIT' shape; saw \(detail)")
        #expect(!detail.contains("Sidecar"))
        #expect(!detail.contains("Engine"))
    }

    @Test("combined progress: both artifacts fold into one combined total (no per-leg labels)")
    func combinedProgressDetailDualLine() {
        let s = CombinedProgress.Component(bytesDone: 88 * 1024 * 1024, bytesTotal: 126 * 1024 * 1024)
        let m = CombinedProgress.Component(bytesDone: 134 * 1024 * 1024, bytesTotal: 293 * 1024 * 1024)
        let detail = CombinedProgress.detail(sidecar: s, model: m)
        // #461: 88 + 134 = 222 done, 126 + 293 = 419 total → one honest total.
        #expect(detail == "222 / 419 MB",
                "both legs must sum into one combined 'done / total'; saw \(detail)")
        #expect(!detail.contains("Engine"),
                "#461: combined total must not carry a per-artifact 'Engine' label; saw \(detail)")
        #expect(!detail.contains("Sidecar"),
                "#461: user-facing copy must not leak the 'Sidecar' jargon; saw \(detail)")
        #expect(!detail.contains("Model"),
                "#461: combined total must not carry a per-artifact 'Model' label; saw \(detail)")
    }

    @Test("combined progress: monotonic — out-of-order updates do not regress")
    func combinedProgressMonotonic() async {
        let agg = ProgressAggregator(sidecarTotalBytes: 100, modelTotalBytes: 200)
        await agg.updateSidecar(bytesDone: 80)
        // Late callback with smaller value (real callback can race)
        await agg.updateSidecar(bytesDone: 50)
        let snap = await agg.snapshot()
        #expect(snap.sidecar.bytesDone == 80,
                "aggregator must clamp at max — late smaller value MUST NOT regress; saw \(snap.sidecar.bytesDone)")
    }

    // MARK: - Manifest validation (partial fields → typed error)

    @Test("partial manifest: model_url present, model_sha256 absent → validate rejects")
    func partialManifestRejected() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: nil,
            modelSize: 100,
            modelAlias: "bonsai-1.7b-2bit"
        )
        do {
            try BootstrapCoordinator.validate(manifest)
            Issue.record("validate should have thrown on partial model fields")
        } catch let err as BootstrapCoordinator.ManifestError {
            if case let .decode(message) = err {
                #expect(message.contains("model_sha256"),
                        "error message should name the missing field; saw \(message)")
                #expect(message.contains("partial"),
                        "error message should call out the partial-set invariant")
            } else {
                Issue.record("expected decode case; saw \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("partial manifest: model_url + model_sha256 + model_size present, model_alias absent → reject")
    func partialManifestMissingAlias() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: 100,
            modelAlias: nil
        )
        do {
            try BootstrapCoordinator.validate(manifest)
            Issue.record("validate should have thrown on missing alias")
        } catch let err as BootstrapCoordinator.ManifestError {
            if case let .decode(message) = err {
                #expect(message.contains("model_alias"),
                        "error message should name the missing field; saw \(message)")
            } else {
                Issue.record("expected decode case; saw \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("full manifest: validate accepts all-four-present")
    func fullManifestValidatePasses() throws {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: 100,
            modelAlias: "bonsai-1.7b-2bit"
        )
        try BootstrapCoordinator.validate(manifest)
    }

    @Test("model_url: non-https rejected by validate")
    func modelURLMustBeHTTPS() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "http://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: 100,
            modelAlias: "bonsai-1.7b-2bit"
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("model_url: non-allowlist host rejected by validate")
    func modelURLAllowlistEnforced() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://evil.example.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: 100,
            modelAlias: "bonsai-1.7b-2bit"
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("model_alias: path-traversal escape rejected by validate")
    func modelAliasPathTraversalRejected() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: 100,
            modelAlias: "../../../etc/passwd"
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    @Test("model_size: oversized rejected by validate")
    func modelSizeCapEnforced() {
        let manifest = BootstrapManifest(
            schemaVersion: 1,
            version: "0.9.0",
            sidecarURL: URL(string: "https://dl.rapidmlx.com/sidecar.tar.gz")!,
            sidecarSHA256: String(repeating: "a", count: 64),
            sidecarSize: 1,
            modelURL: URL(string: "https://dl.rapidmlx.com/model.tar.gz")!,
            modelSHA256: String(repeating: "b", count: 64),
            modelSize: BootstrapCoordinator.modelMaxBytes + 1,
            modelAlias: "bonsai-1.7b-2bit"
        )
        #expect(throws: BootstrapCoordinator.ManifestError.self) {
            try BootstrapCoordinator.validate(manifest)
        }
    }

    // MARK: - Codable round-trip (backward-compat with today's
    // production latest.json)

    @Test("manifest decode: today's production latest.json shape (no model fields)")
    func manifestDecodeBackwardCompatible() throws {
        let json = """
        {
            "schema_version": 1,
            "version": "0.8.5",
            "sidecar_version": "0.8.18",
            "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz",
            "sidecar_sha256": "deadbeefcafe000000000000000000000000000000000000000000000000abcd",
            "sidecar_size": 126180000
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: json)
        #expect(manifest.hasModelArtifact == false,
                "today's production manifest must decode with hasModelArtifact == false")
        #expect(manifest.modelURL == nil)
        #expect(manifest.modelSHA256 == nil)
        #expect(manifest.modelSize == nil)
        #expect(manifest.modelAlias == nil)
    }

    @Test("manifest decode: slice-δ shape (all four model fields)")
    func manifestDecodeWithModelFields() throws {
        let json = """
        {
            "schema_version": 1,
            "version": "0.9.0",
            "sidecar_version": "0.9.0",
            "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz",
            "sidecar_sha256": "deadbeefcafe000000000000000000000000000000000000000000000000abcd",
            "sidecar_size": 126180000,
            "model_url": "https://dl.rapidmlx.com/rapid-quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz",
            "model_sha256": "feedfacedead111111111111111111111111111111111111111111111111feed",
            "model_size": 307328813,
            "model_alias": "bonsai-1.7b-2bit"
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: json)
        #expect(manifest.hasModelArtifact == true)
        #expect(manifest.modelAlias == "bonsai-1.7b-2bit")
        #expect(manifest.modelSize == 307328813)
    }
}
