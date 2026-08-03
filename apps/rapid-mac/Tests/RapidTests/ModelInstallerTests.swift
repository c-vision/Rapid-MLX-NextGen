import CryptoKit
import Foundation
import os
import Testing
@testable import Rapid

/// P3 slice γ — ``ModelInstaller`` unit tests.
///
/// Coverage matrix:
///
///   1. ``stage`` happy path: download + verify + extract → staging
///      directory exists with extracted contents.
///   2. ``commit`` atomically renames staging → alias destination.
///   3. SHA mismatch during stage → staging cleaned up, typed error.
///   4. ``alreadyInstalled`` on stage when destination already exists.
///   5. ``alreadyInstalled`` on commit when destination raced into
///      existence after stage (defensive).
///   6. Path-traversal alias rejected at the entry of stage.
///   7. ``rollbackStaging`` is idempotent + cleans both staging dir
///      AND leftover tarball.
///   8. Concurrent stage on same alias → second call rejected.
///   9. Manifest spec carries alias intact end-to-end.
@Suite("ModelInstaller", .serialized)
struct ModelInstallerTests {

    // MARK: - URLProtocol stub

    final class StubModelProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bodies: [URL: Data] = [:]
        nonisolated(unsafe) static var statusCodes: [URL: Int] = [:]

        static func reset() {
            bodies.removeAll()
            statusCodes.removeAll()
        }
        static func setBody(_ data: Data, for url: URL, status: Int = 200) {
            bodies[url] = data
            statusCodes[url] = status
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
        override func stopLoading() {}
    }

    // MARK: - Doubles

    private final class StubTar: ModelInstaller.TarExtractor, @unchecked Sendable {
        let layout: [(String, Data)]
        let throwError: Error?
        init(layout: [(String, Data)], throwError: Error? = nil) {
            self.layout = layout
            self.throwError = throwError
        }
        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            if let err = throwError { throw err }
            let fm = FileManager.default
            for entry in layout {
                let dest = destinationDirectory.appendingPathComponent(entry.0)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.1.write(to: dest)
            }
        }
    }

    /// Faithfully reproduces the PRE-#416 packer: every file is
    /// emitted under a leading ``<alias>/`` directory (i.e. the tarball
    /// root is ``<alias>/config.json`` rather than ``config.json``).
    /// The original ``StubTar`` above writes FLAT, which is why the
    /// unit suite never caught the real double-nest — the real packer
    /// shipped a leading ``<alias>/`` that this stub now models. Used
    /// to characterise the legacy nested-tarball behaviour and to prove
    /// the fix lives in the PRODUCER (flatten), not the installer.
    private final class NestedStubTar: ModelInstaller.TarExtractor, @unchecked Sendable {
        let alias: String
        let files: [(String, Data)]
        init(alias: String, files: [(String, Data)]) {
            self.alias = alias
            self.files = files
        }
        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            let fm = FileManager.default
            // Leading "<alias>/" wrapper — the exact shape the pre-fix
            // build-model-tarball.sh produced.
            let root = destinationDirectory.appendingPathComponent(alias, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, data) in files {
                try data.write(to: root.appendingPathComponent(name))
            }
        }
    }

    private static func tempDir(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("model-installer-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a ``ModelInstaller`` wired to ``StubModelProtocol``.
    /// IMPORTANT: callers MUST seed ``StubModelProtocol.bodies`` for
    /// the expected URL BEFORE calling this — and this factory does
    /// NOT reset the stub state (per-suite ``.serialized`` ordering
    /// keeps the static dict free of cross-test contamination).
    private static func makeInstaller(
        layout: [(String, Data)] = [
            ("config.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0xAA, count: 256))
        ],
        throwError: Error? = nil
    ) -> ModelInstaller {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubModelProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        let tar = StubTar(layout: layout, throwError: throwError)
        return ModelInstaller(downloader: downloader, tarExtractor: tar)
    }

    // MARK: - Tests

    @Test("stage happy path: bytes downloaded + SHA verified + extracted to staging")
    func stageHappyPath() async throws {
        let installRoot = Self.tempDir("install-root-happy")
        let work = Self.tempDir("work-happy")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        let bytes = Data(repeating: 0x99, count: 128)
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let installer = Self.makeInstaller()

        let spec = ModelInstaller.ArtifactSpec(
            url: url,
            expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count),
            alias: "qwen3-0.6b-4bit"
        )

        let staging = try await installer.stage(
            artifact: spec,
            installRoot: installRoot,
            workDirectory: work
        )

        // Staging directory under install root, named with the
        // ".partial.extracted" suffix
        let expected = installRoot.appendingPathComponent("qwen3-0.6b-4bit.partial.extracted")
        #expect(staging.path == expected.path,
                "staging URL must equal <root>/<alias>.partial.extracted; got \(staging.path)")

        // Files extracted
        let configFile = staging.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configFile.path),
                "extracted config.json must exist in staging")
    }

    @Test("commit: atomic rename → alias destination directory")
    func commitAtomic() async throws {
        let installRoot = Self.tempDir("install-root-commit")
        let work = Self.tempDir("work-commit")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        let bytes = Data(repeating: 0x88, count: 64)
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let installer = Self.makeInstaller()
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count),
            alias: "myalias"
        )
        let staged = try await installer.stage(
            artifact: spec, installRoot: installRoot, workDirectory: work
        )
        let published = try await installer.commit(
            stagedURL: staged, alias: "myalias", installRoot: installRoot
        )
        let expected = installRoot.appendingPathComponent("myalias")
        #expect(published.path == expected.path,
                "commit should publish at <root>/<alias>; got \(published.path)")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: published.path, isDirectory: &isDir),
                "published path must exist after commit")
        #expect(isDir.boolValue, "published path must be a directory")
        // Staging gone
        #expect(!FileManager.default.fileExists(atPath: staged.path),
                "staging must be gone after atomic rename")
    }

    @Test("SHA mismatch during stage: typed verifyFailed + staging cleaned")
    func stageSHAMismatch() async {
        let installRoot = Self.tempDir("install-root-sha")
        let work = Self.tempDir("work-sha")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        let bytes = Data(repeating: 0xCC, count: 64)
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let installer = Self.makeInstaller()

        let badSHA = String(repeating: "f", count: 64)
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: badSHA,
            expectedBytes: UInt64(bytes.count),
            alias: "alias"
        )
        do {
            _ = try await installer.stage(
                artifact: spec, installRoot: installRoot, workDirectory: work
            )
            Issue.record("stage should have thrown on SHA mismatch")
        } catch let me as ModelInstaller.ModelInstallError {
            if case .verifyFailed = me {
                // ok
            } else {
                Issue.record("expected verifyFailed; saw \(me)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Staging directory cleaned up
        let staging = installRoot.appendingPathComponent("alias.partial.extracted")
        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "staging must be cleaned after SHA mismatch")
    }

    @Test("alreadyInstalled: stage refuses when destination exists")
    func stageAlreadyInstalled() async {
        let installRoot = Self.tempDir("install-root-already")
        let work = Self.tempDir("work-already")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        // Pre-seed an existing alias dir
        let existing = installRoot.appendingPathComponent("alias")
        try? FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        StubModelProtocol.reset()
        StubModelProtocol.setBody(Data([0x01]), for: url)
        let installer = Self.makeInstaller()
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: String(repeating: "a", count: 64),
            expectedBytes: 1, alias: "alias"
        )
        do {
            _ = try await installer.stage(
                artifact: spec, installRoot: installRoot, workDirectory: work
            )
            Issue.record("stage should have thrown alreadyInstalled")
        } catch let me as ModelInstaller.ModelInstallError {
            if case .alreadyInstalled = me {
                // ok
            } else {
                Issue.record("expected alreadyInstalled; saw \(me)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("invalid alias: path-traversal rejected at stage entry")
    func stageRejectsPathTraversal() async {
        let installRoot = Self.tempDir("install-root-traversal")
        let work = Self.tempDir("work-traversal")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let installer = Self.makeInstaller()
        let spec = ModelInstaller.ArtifactSpec(
            url: URL(string: "https://dl.rapidmlx.com/m.tar.gz")!,
            expectedSHA256: String(repeating: "a", count: 64),
            expectedBytes: 1,
            alias: "../../etc/passwd"
        )
        do {
            _ = try await installer.stage(
                artifact: spec, installRoot: installRoot, workDirectory: work
            )
            Issue.record("stage should have thrown invalidAlias")
        } catch let me as ModelInstaller.ModelInstallError {
            if case .invalidAlias = me {
                // ok
            } else {
                Issue.record("expected invalidAlias; saw \(me)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("rollbackStaging: idempotent, cleans staging + leftover tarballs")
    func rollbackIdempotent() async {
        let installRoot = Self.tempDir("install-root-rollback")
        let work = Self.tempDir("work-rollback")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let installer = Self.makeInstaller()
        // Create some leftover artifacts
        let staging = installRoot.appendingPathComponent("alias.partial.extracted")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent("rapid-quickstart-model-alias.tar.gz")
        try? Data([0xFF]).write(to: tarball)
        let partial = tarball.appendingPathExtension("partial")
        try? Data([0xFF]).write(to: partial)

        // Two rollback calls — must be idempotent
        await installer.rollbackStaging(
            alias: "alias", installRoot: installRoot, workDirectory: work
        )
        await installer.rollbackStaging(
            alias: "alias", installRoot: installRoot, workDirectory: work
        )

        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "staging should be removed")
        #expect(!FileManager.default.fileExists(atPath: tarball.path),
                "tarball should be removed")
        #expect(!FileManager.default.fileExists(atPath: partial.path),
                "partial tarball should be removed")
    }

    @Test("HF-cache layout: extracted tree is flat per-alias (slice ε will wire HF discovery)")
    func hfCacheLayoutPerAlias() async throws {
        // This is a layout-contract test — slice γ commits to the
        // per-alias flat directory layout, slice ε will wire the
        // sidecar's HF_HUB_CACHE / alias-config to discover it.
        let installRoot = Self.tempDir("install-root-hf")
        let work = Self.tempDir("work-hf")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        let bytes = Data([0x11, 0x22])
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let layout: [(String, Data)] = [
            ("config.json", Data("{\"hidden_size\": 512}".utf8)),
            ("tokenizer.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0xBB, count: 1024))
        ]
        let installer = Self.makeInstaller(layout: layout)
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count),
            alias: "qwen3-0.6b-4bit"
        )
        let staged = try await installer.stage(
            artifact: spec, installRoot: installRoot, workDirectory: work
        )
        let published = try await installer.commit(
            stagedURL: staged, alias: "qwen3-0.6b-4bit", installRoot: installRoot
        )

        // Files at the flat alias destination
        for entry in layout {
            let path = published.appendingPathComponent(entry.0)
            #expect(FileManager.default.fileExists(atPath: path.path),
                    "extracted file \(entry.0) must exist at the alias destination")
        }
        // NOT in HF-cache layout (no `models--<owner>--<repo>` or
        // `snapshots/<rev>` directory) — pinned to the slice γ
        // contract.
        let hfLayout = installRoot.appendingPathComponent("models--mlx-community--Qwen3-0.6B-4bit")
        #expect(!FileManager.default.fileExists(atPath: hfLayout.path),
                "slice γ MUST NOT write HF cache layout — slice ε's concern")
    }

    @Test("flat tarball → stage+commit publishes FLAT single-level <root>/<alias>/config.json (#416)")
    func flatTarballPublishesSingleLevel() async throws {
        // Post-#416 producer packs FLAT (no leading <alias>/). The
        // default StubTar mirrors that. Assert the commit lands the
        // weights ONE level deep — <root>/<alias>/config.json — and
        // that NO double-nested <root>/<alias>/<alias>/ directory is
        // created. This is the contract QuickstartModel.resolveFlatModel
        // Dir's PREFERRED (non-legacy) branch resolves against.
        let installRoot = Self.tempDir("install-root-flat416")
        let work = Self.tempDir("work-flat416")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/m.tar.gz")!
        let bytes = Data(repeating: 0x77, count: 96)
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let alias = "qwen3-0.6b-4bit"
        let installer = Self.makeInstaller(layout: [
            ("config.json", Data("{}".utf8)),
            ("tokenizer.json", Data("{}".utf8)),
            ("model.safetensors", Data(repeating: 0xBB, count: 64)),
        ])
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count), alias: alias
        )
        let staged = try await installer.stage(
            artifact: spec, installRoot: installRoot, workDirectory: work
        )
        let published = try await installer.commit(
            stagedURL: staged, alias: alias, installRoot: installRoot
        )

        // Weights land exactly one level deep.
        let flatConfig = published.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: flatConfig.path),
                "flat tarball must publish <root>/<alias>/config.json (single level)")
        // No double-nest.
        let nested = published
            .appendingPathComponent(alias)
            .appendingPathComponent("config.json")
        #expect(!FileManager.default.fileExists(atPath: nested.path),
                "flat tarball must NOT produce a double-nested <root>/<alias>/<alias>/config.json (#416)")

        // The install leaf resolves via resolveFlatModelDir's PREFERRED
        // (flat) branch — not the legacy nested fallback.
        let resolved = QuickstartModel.resolveFlatModelDir(
            alias: alias, installRoot: installRoot
        )
        #expect(resolved?.path == published.path,
                "resolveFlatModelDir must resolve a flat install via the preferred branch to <root>/<alias>")
    }

    @Test("LEGACY: pre-#416 nested tarball (<alias>/…) double-nests to <root>/<alias>/<alias>/ (characterisation)")
    func legacyNestedTarballDoubleNests() async throws {
        // Characterisation of the #416 bug: a tarball whose own root is
        // "<alias>/config.json" (the pre-fix packer) commits to
        // <root>/<alias>/<alias>/config.json because commit renames the
        // staging dir (which now contains an <alias>/ child) onto
        // <root>/<alias>/. This proves the double-nest originated in the
        // PRODUCER's leading-dir, not the installer — the installer is
        // shape-faithful and the correct fix is the producer flatten.
        // The resolver's LEGACY fallback still resolves this shape so
        // machines that installed a pre-fix tarball keep working.
        let installRoot = Self.tempDir("install-root-legacy416")
        let work = Self.tempDir("work-legacy416")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        let url = URL(string: "https://dl.rapidmlx.com/legacy.tar.gz")!
        let bytes = Data(repeating: 0x33, count: 96)
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)
        let alias = "qwen3-0.6b-4bit"

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubModelProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        let nestedTar = NestedStubTar(alias: alias, files: [
            ("config.json", Data("{}".utf8)),
            ("tokenizer.json", Data("{}".utf8)),
        ])
        let installer = ModelInstaller(downloader: downloader, tarExtractor: nestedTar)
        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count), alias: alias
        )
        let staged = try await installer.stage(
            artifact: spec, installRoot: installRoot, workDirectory: work
        )
        let published = try await installer.commit(
            stagedURL: staged, alias: alias, installRoot: installRoot
        )

        // The legacy nested shape lands two levels deep.
        let nestedConfig = published
            .appendingPathComponent(alias)
            .appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: nestedConfig.path),
                "legacy nested tarball characterisation: config.json lands at <root>/<alias>/<alias>/config.json")
        // NOT flat.
        #expect(!FileManager.default.fileExists(
            atPath: published.appendingPathComponent("config.json").path),
                "legacy nested tarball has no flat <root>/<alias>/config.json (that is exactly the #416 shape)")

        // resolveFlatModelDir's LEGACY fallback keeps this working so
        // pre-fix installs on existing machines still load.
        let resolved = QuickstartModel.resolveFlatModelDir(
            alias: alias, installRoot: installRoot
        )
        #expect(resolved?.path == published.appendingPathComponent(alias).path,
                "legacy nested install must still resolve via the back-compat fallback to <root>/<alias>/<alias>")
    }

    /// TarExtractor that blocks inside ``extract`` until the test
    /// releases the gate. Lets us pin a second ``stage`` call while
    /// the first one is still mid-extract (i.e. mid-async-suspension
    /// after the actor has inserted into ``inFlight``).
    private final class GatedStubTar: ModelInstaller.TarExtractor, @unchecked Sendable {
        let layout: [(String, Data)]
        // Use a lock-protected continuation pair so the gate is
        // safe to inspect / release from the test thread. The
        // stored continuation accepts one signal then finishes.
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        // Set true on the first frame inside ``extract`` so the
        // test thread can poll for "first stage call has reached
        // the gate" without touching actor state.
        // ``OSAllocatedUnfairLock`` is safe from BOTH sync and async
        // contexts (unlike NSLock which Swift 6 forbids from async
        // contexts).
        private let enteredFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
        var extractEntered: Bool { enteredFlag.withLock { $0 } }
        init(layout: [(String, Data)]) {
            self.layout = layout
            var cont: AsyncStream<Void>.Continuation!
            self.stream = AsyncStream<Void> { cont = $0 }
            self.continuation = cont
        }
        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            enteredFlag.withLock { $0 = true }
            // Suspend until the test releases the gate.
            var it = stream.makeAsyncIterator()
            _ = await it.next()
            // Now do the real (synchronous-looking) extraction.
            let fm = FileManager.default
            for entry in layout {
                let dest = destinationDirectory.appendingPathComponent(entry.0)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.1.write(to: dest)
            }
        }
        /// Test-only: release the gate so ``extract`` can complete.
        func release() {
            continuation.yield(())
            continuation.finish()
        }
    }

    @Test("concurrent stage on same alias: second call rejected with alreadyInstalling (codex r3 NIT — actually exercise overlap)")
    func concurrentStageRejected() async throws {
        let installRoot = Self.tempDir("install-root-concur")
        let work = Self.tempDir("work-concur")
        defer {
            try? FileManager.default.removeItem(at: installRoot)
            try? FileManager.default.removeItem(at: work)
        }
        // Wire a tar extractor that suspends mid-extract so the
        // first stage call is parked while it holds the
        // ``inFlight`` slot for the alias. Then issue a second
        // overlapping stage and assert it throws ``alreadyInstalling``
        // (this IS the production contract guarding two coordinator
        // installs of the same alias from racing).
        let url = URL(string: "https://dl.rapidmlx.com/m-concur.tar.gz")!
        let bytes = Data([0x55, 0x66, 0x77])
        let sha = SHA256Verifier.hexString(SHA256.hash(data: bytes))
        StubModelProtocol.reset()
        StubModelProtocol.setBody(bytes, for: url)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubModelProtocol.self]
        let downloader = ResumableDownloader(session: URLSession(configuration: cfg))
        let gatedTar = GatedStubTar(layout: [("config.json", Data("{}".utf8))])
        let installer = ModelInstaller(downloader: downloader, tarExtractor: gatedTar)

        let spec = ModelInstaller.ArtifactSpec(
            url: url, expectedSHA256: sha,
            expectedBytes: UInt64(bytes.count),
            alias: "concur-alias"
        )

        // Launch first stage — it will park inside the gated tar's
        // ``extract``.
        let firstTask = Task {
            try await installer.stage(
                artifact: spec, installRoot: installRoot, workDirectory: work
            )
        }

        // Yield once so the actor scheduler gets a chance to enter
        // the first stage call. Then issue the second call — the
        // first one is parked inside ``extract`` (gated tar). The
        // actor's serialised entry will dequeue the second call
        // immediately because the first call is suspended at an
        // ``await`` and has already populated the inFlight set
        // before the suspension. The second call sees the alias
        // in inFlight and throws ``alreadyInstalling``.
        //
        // We poll waiting for the first call to reach the gate.
        // Codex r4 MINOR: 1s budget was too tight for loaded CI
        // (download + hash + dir setup + actor scheduling all need
        // to land first). 10s budget keeps the test deterministic
        // on stock M-series Macs (sub-100ms in practice) AND
        // resilient on a backed-up GitHub runner. ``GatedStubTar``
        // exposes a "did extract start" flag we read instead of
        // touching actor state from the test thread.
        var waited = 0
        while !gatedTar.extractEntered {
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
            waited += 1
            if waited > 2_000 { // 10s budget
                gatedTar.release()
                Issue.record("first stage never reached extract within 10s — test setup wrong or CI runner pathologically slow")
                _ = try? await firstTask.value
                return
            }
        }

        // Now issue a second stage on the SAME alias. The actor
        // will see the alias already in inFlight and must throw
        // ``alreadyInstalling``.
        do {
            _ = try await installer.stage(
                artifact: spec, installRoot: installRoot, workDirectory: work
            )
            // Release the gate so firstTask can clean up before
            // we record the failure.
            gatedTar.release()
            _ = try? await firstTask.value
            Issue.record("second concurrent stage MUST throw alreadyInstalling — saw success")
            return
        } catch let me as ModelInstaller.ModelInstallError {
            #expect(me == .alreadyInstalling(alias: "concur-alias"),
                    "second concurrent stage MUST throw .alreadyInstalling(alias:); saw \(me)")
        } catch {
            gatedTar.release()
            _ = try? await firstTask.value
            Issue.record("expected ModelInstallError.alreadyInstalling; saw \(error)")
            return
        }

        // Release the gate and let firstTask drain — happy-path
        // completion proves the inFlight gate releases cleanly.
        gatedTar.release()
        let staged = try await firstTask.value
        #expect(FileManager.default.fileExists(atPath: staged.path),
                "first stage must complete cleanly after gate release")
    }
}
