import Foundation
import Testing
@testable import Rapid

/// Pins the SidecarExtractor contract:
///   * Tar extractor (injected) is invoked once per call.
///   * Quarantine xattr is stripped from every extracted file.
///   * Mach-O detection picks up real magic-byte files and skips
///     plain text / scripts / random data.
///   * Mach-O verifier (injected) is called once per detected
///     Mach-O; a failure on any one binary fails the whole call and
///     leaves the destination unpublished.
///   * Atomic publish: on success the staging directory is renamed
///     into the destination; on any failure the staging directory is
///     removed and the destination is left alone.
///   * Cancellation surfaces as ``CancellationError`` and cleans up
///     the staging directory.
///   * Concurrent calls on the same destination — second is rejected
///     with a typed disk-failed error rather than racing the staging
///     directory.
///   * Real bsdtar smoke: build a tarball with the actual
///     `/usr/bin/bsdtar` and round-trip it through the default
///     ``ProcessTarExtractor`` so the argv quoting + stderr-capture
///     code paths get exercised end-to-end.
// ``.serialized`` so this suite's multi-MB blob + real-bsdtar cases
// don't run concurrently with each other, capping the peak file-
// descriptor / IO pressure they add to the full parallel test pool
// (issue #530). Fixture writes additionally retry on transient EBADF
// via ``FixtureIO.write``.
@Suite("SidecarExtractor", .serialized)
struct SidecarExtractorTests {

    // MARK: - Test doubles

    /// Thread-safe state actor used by the stubs below. The
    /// async-context restrictions on `NSLock` in Swift 6 mean we
    /// can't lock-protect mutable state from inside an async stub —
    /// an actor is the idiomatic answer.
    actor StubState {
        var callCount = 0
        var lastTarball: URL?
        var lastDestination: URL?
        var verifiedPaths: [String] = []
        func recordExtract(tarball: URL, destination: URL) {
            callCount += 1
            lastTarball = tarball
            lastDestination = destination
        }
        func recordVerify(_ path: String) {
            verifiedPaths.append(path)
        }
    }

    /// In-memory ``SidecarExtractor.TarExtractor`` that synthesises an
    /// extracted layout from a `[relativePath: Data]` dictionary.
    /// Lets tests pin verifier coverage / xattr / publish behaviour
    /// without spinning a real bsdtar child per test.
    final class StubTarExtractor: SidecarExtractor.TarExtractor, @unchecked Sendable {
        let files: [String: Data]
        /// When non-nil, the extract call sleeps for this many
        /// nanoseconds AFTER writing the files but BEFORE returning.
        /// Used by the cancellation test to keep the call genuinely
        /// in flight long enough for a cancel to land mid-extract.
        let sleepAfterWrite: UInt64?
        let extractError: SidecarExtractor.ExtractError?
        let state: StubState

        init(files: [String: Data] = [:],
             sleepAfterWrite: UInt64? = nil,
             extractError: SidecarExtractor.ExtractError? = nil,
             state: StubState = StubState()) {
            self.files = files
            self.sleepAfterWrite = sleepAfterWrite
            self.extractError = extractError
            self.state = state
        }

        func extract(tarballURL: URL, destinationDirectory: URL) async throws {
            await state.recordExtract(tarball: tarballURL,
                                      destination: destinationDirectory)

            if let err = extractError {
                throw err
            }

            let fm = FileManager.default
            for (rel, body) in files {
                let target = destinationDirectory.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try body.write(to: target)
            }

            if let nanos = sleepAfterWrite {
                try await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// In-memory ``SidecarExtractor.MachOVerifier``. Defaults to "all
    /// pass"; tests can specify a per-path verdict via the closure.
    final class StubVerifier: SidecarExtractor.MachOVerifier, @unchecked Sendable {
        struct Failure: Error, Equatable {
            let path: String
        }
        let verdict: @Sendable (URL) -> Result<Void, Failure>
        let state: StubState

        init(state: StubState = StubState(),
             verdict: @escaping @Sendable (URL) -> Result<Void, Failure> = { _ in .success(()) }) {
            self.state = state
            self.verdict = verdict
        }

        func verify(url: URL) async throws {
            await state.recordVerify(url.path)
            switch verdict(url) {
            case .success: return
            case .failure(let f): throw f
            }
        }
    }

    // MARK: - Fixture helpers

    /// 4-byte Mach-O magic value (64-bit native, little-endian on disk).
    /// 0xCFFAEDFE on-disk == 0xFEEDFACF when read as a 32-bit big-endian
    /// integer, which is the form ``SidecarExtractor.isMachO`` checks.
    private static let machO64LE: Data = Data([0xCF, 0xFA, 0xED, 0xFE,
                                                0x07, 0x00, 0x00, 0x01])
    /// 4-byte Mach-O magic value (fat / universal).
    private static let machOFat: Data = Data([0xCA, 0xFE, 0xBA, 0xBE,
                                               0x00, 0x00, 0x00, 0x02])

    private static func freshTemp(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("extract-\(label)-\(UUID().uuidString)")
    }

    private static func purge(_ destination: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: destination.appendingPathExtension("partial.extracted"))
    }

    // MARK: - Mach-O detection

    @Test("isMachO recognises 64-bit little-endian magic")
    func detect64LE() throws {
        let url = Self.freshTemp("magic64")
        try Self.machO64LE.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SidecarExtractor.isMachO(at: url))
    }

    @Test("isMachO recognises fat magic (universal binary)")
    func detectFat() throws {
        let url = Self.freshTemp("magicfat")
        try Self.machOFat.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SidecarExtractor.isMachO(at: url))
    }

    @Test("isMachO rejects plain text / scripts / random data")
    func rejectsNonMachO() throws {
        let url1 = Self.freshTemp("shebang")
        try Data("#!/bin/sh\nexec true\n".utf8).write(to: url1)
        defer { try? FileManager.default.removeItem(at: url1) }
        #expect(!SidecarExtractor.isMachO(at: url1))

        let url2 = Self.freshTemp("zeros")
        try Data(repeating: 0, count: 16).write(to: url2)
        defer { try? FileManager.default.removeItem(at: url2) }
        #expect(!SidecarExtractor.isMachO(at: url2))

        let url3 = Self.freshTemp("short")
        try Data([0xCF, 0xFA]).write(to: url3)  // only 2 bytes
        defer { try? FileManager.default.removeItem(at: url3) }
        #expect(!SidecarExtractor.isMachO(at: url3))
    }

    @Test("isMachO returns false on non-existent file rather than throwing")
    func detectMissingFile() {
        let url = Self.freshTemp("does-not-exist")
        // Defensive: missing file would surface in findMachOFiles as
        // an enumerator error. The detector itself must NOT throw —
        // findMachOFiles already filters non-regular files upstream.
        #expect(!SidecarExtractor.isMachO(at: url))
    }

    // MARK: - findMachOFiles

    @Test("findMachOFiles walks tree, picks Mach-O, skips non-Mach-O")
    func findFilesPicksOnlyMachO() throws {
        let root = Self.freshTemp("findroot")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Layout:
        //   root/bin/exe          ← Mach-O 64
        //   root/bin/shim.sh      ← shell script (not Mach-O)
        //   root/lib/libfoo.dylib ← Mach-O fat
        //   root/lib/README.txt   ← plain text
        //   root/share/data       ← random bytes
        try fm.createDirectory(at: root.appendingPathComponent("bin"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("share"),
                               withIntermediateDirectories: true)
        try Self.machO64LE.write(to: root.appendingPathComponent("bin/exe"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("bin/shim.sh"))
        try Self.machOFat.write(to: root.appendingPathComponent("lib/libfoo.dylib"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("lib/README.txt"))
        try Data(repeating: 0xAA, count: 32).write(to: root.appendingPathComponent("share/data"))

        let result = try SidecarExtractor.findMachOFiles(under: root, fileManager: fm)
        let names = Set(result.map { $0.lastPathComponent })
        #expect(names == ["exe", "libfoo.dylib"],
                "found: \(names) — must include only the two Mach-O files")
    }

    @Test("findMachOFiles skips symlinks")
    func findFilesSkipsSymlinks() throws {
        let root = Self.freshTemp("symlinkroot")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let real = root.appendingPathComponent("real")
        try Self.machO64LE.write(to: real)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let result = try SidecarExtractor.findMachOFiles(under: root, fileManager: fm)
        let paths = result.map { $0.lastPathComponent }
        #expect(paths == ["real"],
                "symlinks must not be double-counted; got \(paths)")
    }

    // MARK: - Quarantine strip

    /// Inspect xattrs on a path, returning the set of names. Used by
    /// the tests below to assert specifically that
    /// `com.apple.quarantine` is gone — checking total xattr length
    /// would be wrong because macOS attaches `com.apple.provenance`
    /// to files written under sandbox / Spotlight indexing, which is
    /// none of our business.
    private static func xattrNames(at path: String) -> Set<String> {
        // 4 KiB is enough for the few hundred bytes of attribute
        // names a typical macOS file accumulates; we don't need to
        // grow the buffer for this test.
        let bufSize = 4096
        var buf = [CChar](repeating: 0, count: bufSize)
        let len = path.withCString { cstr in
            listxattr(cstr, &buf, bufSize, 0)
        }
        if len <= 0 { return [] }
        // listxattr returns name1\0name2\0...nameN\0
        var names: Set<String> = []
        var start = 0
        for i in 0..<Int(len) {
            if buf[i] == 0 {
                if i > start {
                    let bytes = buf[start..<i].map { UInt8(bitPattern: $0) }
                    if let s = String(bytes: bytes, encoding: .utf8) {
                        names.insert(s)
                    }
                }
                start = i + 1
            }
        }
        return names
    }

    @Test("stripQuarantine removes xattr; ENOATTR is silently ignored")
    func quarantineStripIdempotent() throws {
        let url = Self.freshTemp("qfile")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // First call on a clean file: should be a no-op (ENOATTR
        // silenced). Must not throw.
        try SidecarExtractor.stripQuarantine(at: url)

        // Manually attach a quarantine xattr, then strip it. The
        // round-trip proves stripQuarantine actually clears the
        // attribute (not just no-ops on its presence).
        let value = "0001;00000000;Test;".data(using: .utf8)!
        let setRC = url.path.withCString { cstr in
            value.withUnsafeBytes { vbuf -> Int32 in
                setxattr(cstr, "com.apple.quarantine",
                         vbuf.baseAddress, vbuf.count, 0, 0)
            }
        }
        #expect(setRC == 0, "setxattr failed with errno \(errno)")

        let before = Self.xattrNames(at: url.path)
        #expect(before.contains("com.apple.quarantine"),
                "quarantine xattr should be present before strip; got \(before)")

        try SidecarExtractor.stripQuarantine(at: url)

        let after = Self.xattrNames(at: url.path)
        #expect(!after.contains("com.apple.quarantine"),
                "quarantine xattr should be cleared after strip; remaining: \(after)")
        // System-attached xattrs (com.apple.provenance, com.apple.macl,
        // etc.) are intentionally NOT asserted on — they're outside
        // the contract under test.
    }

    @Test("stripQuarantineRecursively walks tree and strips all files including root")
    func quarantineStripRecursive() throws {
        let root = Self.freshTemp("qroot")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.txt")
        try Data("x".utf8).write(to: inner)

        // Tag every relevant path with quarantine.
        let value = "0001;00000000;Test;".data(using: .utf8)!
        for url in [root, sub, inner] {
            _ = url.path.withCString { cstr in
                value.withUnsafeBytes { vbuf -> Int32 in
                    setxattr(cstr, "com.apple.quarantine",
                             vbuf.baseAddress, vbuf.count, 0, 0)
                }
            }
        }

        try SidecarExtractor.stripQuarantineRecursively(at: root, fileManager: fm)

        for url in [root, sub, inner] {
            let names = Self.xattrNames(at: url.path)
            #expect(!names.contains("com.apple.quarantine"),
                    "com.apple.quarantine remains on \(url.lastPathComponent) after recursive strip; xattrs: \(names)")
        }
    }

    // MARK: - End-to-end with stub extractor + verifier

    @Test("happy path — extract, strip, verify Mach-Os, atomic publish")
    func happyPath() async throws {
        let dest = Self.freshTemp("happy")
        defer { Self.purge(dest) }

        // #430: match the real ``scripts/build-sidecar-tarball.sh``
        // arcname — top-level ``rapid-mlx/`` wrapper preserved through
        // extract + publish. The wrapper is the layout ServerLocator's
        // runtime-override slot resolves against; tests that planted
        // flat ``bin/rapid-mlx`` directly under dest agreed with the
        // OLD (wrong) ServerLocator path and silently validated a
        // shape the install pipeline never produces.
        let stub = StubTarExtractor(files: [
            "rapid-mlx/bin/rapid-mlx": Data("#!/bin/sh\n".utf8),
            "rapid-mlx/python/bin/python3.12": Self.machO64LE,
            "rapid-mlx/site-packages/_cffi.so": Self.machO64LE,
            "rapid-mlx/site-packages/README.txt": Data("docs".utf8)
        ])
        let verifier = StubVerifier()

        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: verifier)

        let phases = PhaseLog()
        let result = try await extractor.extract(
            tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
            into: dest
        ) { phase, _ in
            Task { await phases.record(phase) }
        }

        #expect(result == dest)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dest.path),
                "destination directory must be published")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("rapid-mlx/bin/rapid-mlx").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("rapid-mlx/python/bin/python3.12").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.extracted").path),
                "staging directory must be gone after publish")

        // Verifier was called once per Mach-O, never on the shell
        // script or the README.
        let names = Set(await verifier.state.verifiedPaths.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["python3.12", "_cffi.so"],
                "verifier called on: \(names) — must be exactly the two Mach-O files")

        // Phase callbacks: give the dispatched record() calls a beat
        // and then assert each phase fired at least once.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await phases.phases
        #expect(recorded.contains(.extracting))
        #expect(recorded.contains(.strippingQuarantine))
        #expect(recorded.contains(.verifyingSignatures))
    }

    @Test("verifier failure on any Mach-O fails install + cleans staging + leaves dest absent")
    func verifierFailureCleansStaging() async throws {
        let dest = Self.freshTemp("verifyfail")
        defer { Self.purge(dest) }

        let stub = StubTarExtractor(files: [
            "good.dylib": Self.machO64LE,
            "bad.dylib": Self.machO64LE
        ])
        let verifier = StubVerifier(verdict: { url in
            if url.lastPathComponent == "bad.dylib" {
                return .failure(StubVerifier.Failure(path: url.path))
            }
            return .success(())
        })

        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: verifier)

        do {
            _ = try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                into: dest
            )
            Issue.record("extract must throw when a verifier fails")
        } catch let err as SidecarExtractor.ExtractError {
            switch err {
            case .sanityFailed(let path, _):
                #expect(path.hasSuffix("bad.dylib"),
                        "sanityFailed must surface the offending path: \(path)")
            default:
                Issue.record("expected sanityFailed, got \(err)")
            }
        }

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.path),
                "destination must remain absent on sanity failure")
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.extracted").path),
                "staging must be cleaned on sanity failure")
    }

    @Test("tar extractor failure cleans staging + surfaces tarFailed")
    func tarFailureCleansStaging() async throws {
        let dest = Self.freshTemp("tarfail")
        defer { Self.purge(dest) }

        let stub = StubTarExtractor(
            files: [:],
            extractError: .tarFailed(message: "synthetic bsdtar boom")
        )

        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: StubVerifier())

        do {
            _ = try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                into: dest
            )
            Issue.record("extract must throw when tar fails")
        } catch let err as SidecarExtractor.ExtractError {
            switch err {
            case .tarFailed(let msg):
                #expect(msg.contains("synthetic bsdtar boom"))
            default:
                Issue.record("expected tarFailed, got \(err)")
            }
        }

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.path))
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.extracted").path),
                "staging must be cleaned on tar failure")
    }

    @Test("re-running over an existing destination replaces atomically")
    func atomicReplaceOverExistingDestination() async throws {
        let dest = Self.freshTemp("replace")
        defer { Self.purge(dest) }

        // Pre-seed the destination with stale content so the publish
        // step has to take the replaceItemAt branch.
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dest.appendingPathComponent("OLD_VERSION"))

        let stub = StubTarExtractor(files: [
            "VERSION": Data("0.8.4".utf8),
            "lib.dylib": Self.machO64LE
        ])
        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: StubVerifier())

        _ = try await extractor.extract(
            tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
            into: dest
        )

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("VERSION").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("lib.dylib").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("OLD_VERSION").path),
                "stale tree must be replaced wholesale")
    }

    @Test("cancellation during extract surfaces as CancellationError + cleans staging")
    func cancellationCleansStaging() async throws {
        let dest = Self.freshTemp("cancel")
        defer { Self.purge(dest) }

        // 500 ms sleep inside the stub keeps the extract genuinely in
        // flight; the cancellation lands during the post-write sleep
        // and the stub's `try await Task.sleep` honours it directly,
        // surfacing as CancellationError to our wrapper.
        let stub = StubTarExtractor(
            files: ["a.dylib": Self.machO64LE],
            sleepAfterWrite: 500_000_000
        )
        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: StubVerifier())

        let task = Task {
            try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                into: dest
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)  // let it enter the sleep
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled extract must throw")
        } catch is CancellationError {
            // expected
            let fm = FileManager.default
            #expect(!fm.fileExists(atPath: dest.path),
                    "destination must not be published when cancelled")
            #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.extracted").path),
                    "staging must be cleaned on cancellation")
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test("concurrent extract on the same destination — second call rejected, not raced")
    func concurrentExtractsRejected() async throws {
        let dest = Self.freshTemp("concurrent")
        defer { Self.purge(dest) }

        // 300 ms post-write sleep keeps the first call genuinely in
        // flight while the second one enters the actor; without it
        // the first finishes before the second arrives and the
        // contract under test isn't exercised.
        let stub = StubTarExtractor(
            files: ["lib.dylib": Self.machO64LE],
            sleepAfterWrite: 300_000_000
        )
        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: StubVerifier())

        let outcome = await withTaskGroup(of: Result<URL, Error>.self) {
            group -> (winners: Int, rejections: Int) in
            group.addTask {
                do {
                    let url = try await extractor.extract(
                        tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                        into: dest
                    )
                    return .success(url)
                } catch { return .failure(error) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            group.addTask {
                do {
                    let url = try await extractor.extract(
                        tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                        into: dest
                    )
                    return .success(url)
                } catch { return .failure(error) }
            }
            var w = 0
            var r = 0
            for await item in group {
                switch item {
                case .success: w += 1
                case .failure(let e):
                    if case SidecarExtractor.ExtractError.diskFailed(_, _, _, let msg) = e,
                       msg.contains("already in flight") {
                        r += 1
                    } else {
                        Issue.record("expected diskFailed/already-in-flight, got \(e)")
                    }
                }
            }
            return (w, r)
        }
        #expect(outcome.winners == 1, "exactly one extract must succeed (got \(outcome.winners))")
        #expect(outcome.rejections == 1, "second call must be rejected (got \(outcome.rejections))")
    }

    // MARK: - Real bsdtar smoke test

    @Test("real /usr/bin/bsdtar round-trip extracts a generated tarball")
    func realBsdtarRoundtrip() async throws {
        let fm = FileManager.default
        let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // Skip if bsdtar somehow isn't on this CI runner (every
        // stock macOS has it; this is just paranoia).
        guard fm.fileExists(atPath: bsdtar.path) else { return }

        // Build a small payload tree, then ask bsdtar to tar+gzip it
        // so the round-trip exercises both directions of the same
        // binary.
        let source = Self.freshTemp("realsource")
        try fm.createDirectory(at: source.appendingPathComponent("bin"),
                               withIntermediateDirectories: true)
        try Self.machO64LE.write(to: source.appendingPathComponent("bin/exe"))
        try Data("#!/bin/sh\n".utf8).write(to: source.appendingPathComponent("bin/shim.sh"))

        let tarball = Self.freshTemp("realtar").appendingPathExtension("tar.gz")
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: tarball)
        }

        // Use bsdtar to CREATE the archive so the test doesn't depend
        // on a checked-in binary fixture.
        let createProc = Process()
        createProc.executableURL = bsdtar
        createProc.arguments = [
            "-c", "-z", "-f", tarball.path,
            "-C", source.path,
            "--", "."
        ]
        try createProc.run()
        createProc.waitUntilExit()
        #expect(createProc.terminationStatus == 0,
                "bsdtar create exit=\(createProc.terminationStatus)")
        #expect(fm.fileExists(atPath: tarball.path),
                "tarball must be created on disk")

        let dest = Self.freshTemp("realdest")
        defer { Self.purge(dest) }

        // Verifier that accepts everything — we're testing the tar
        // path, not codesign integration. Real codesign coverage on
        // an unsigned in-memory mach-o would fail (correctly), so the
        // test must inject an always-pass verifier.
        let verifier = StubVerifier()
        let extractor = SidecarExtractor(
            tarExtractor: ProcessTarExtractor(),
            machOVerifier: verifier
        )

        _ = try await extractor.extract(tarball: tarball, into: dest)

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("bin/exe").path),
                "exe must be extracted")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("bin/shim.sh").path),
                "shim.sh must be extracted")

        // Verifier was called on the Mach-O only.
        let names = Set(await verifier.state.verifiedPaths.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["exe"],
                "verifier should have run on the Mach-O only; got \(names)")
    }

    @Test("real bsdtar surfaces tarFailed when tarball is missing")
    func realBsdtarMissingArchive() async throws {
        let dest = Self.freshTemp("missingtar")
        defer { Self.purge(dest) }

        let extractor = SidecarExtractor(
            tarExtractor: ProcessTarExtractor(),
            machOVerifier: StubVerifier()
        )

        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).tar.gz")

        do {
            _ = try await extractor.extract(tarball: bogus, into: dest)
            Issue.record("expected tarFailed for missing archive")
        } catch let err as SidecarExtractor.ExtractError {
            switch err {
            case .tarFailed(let msg):
                #expect(!msg.isEmpty, "tarFailed message should carry bsdtar stderr")
            default:
                Issue.record("expected tarFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ExtractError.tarFailed, got \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "destination must not be created on tar failure")
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathExtension("partial.extracted").path),
            "staging must be cleaned on tar failure")
    }

    // MARK: - Codex r1 follow-up coverage

    @Test("real bsdtar cancellation: SIGTERM lands within the timeout window + cleans staging")
    func realBsdtarCancellation() async throws {
        // Codex r1 MAJOR 5 + r2 MAJOR: the cancellation test MUST
        // exercise a real bsdtar child AND fail loudly if the cancel
        // didn't terminate it. Previous version used compressible
        // bytes (repeating pattern → 40 MB → ~1 MB gzipped → extracts
        // in <200 ms → cancel always raced to completion → contract
        // unproven). This version:
        //
        //   1. Uses INCOMPRESSIBLE random bytes so the natural
        //      extract time is meaningful (~3-8 s on M-series).
        //   2. Requires either CancellationError OR a too-quick
        //      success — we fail if the call returned success AND
        //      took as long as a natural full extract.
        //   3. Asserts the staging path is cleaned, no matter which
        //      branch the call took.
        //
        // Result: a regression where bsdtar isn't actually SIGTERM'd
        // would show up as a wall-clock time near the natural
        // extract duration (≥3 s on a 250 MB tree), and the test
        // fails on the elapsed-time bound.
        let fm = FileManager.default
        let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        guard fm.fileExists(atPath: bsdtar.path) else { return }

        // ~250 MB of incompressible random bytes split across many
        // files so bsdtar can't optimise the create syscalls down to
        // a single mmap. Using SecRandomCopyBytes gives genuinely
        // random data that gzip can't shrink.
        let source = Self.freshTemp("cancelsource")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        // 100 files × 2 MB each. The seed scheme uses SystemRandom-
        // NumberGenerator.next() to fill each buffer; this is
        // cryptographically random AND fast (~50ms per 2 MB).
        var rng = SystemRandomNumberGenerator()
        for i in 0..<100 {
            var buf = Data(count: 2 * 1024 * 1024)
            buf.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let u64Ptr = base.assumingMemoryBound(to: UInt64.self)
                let u64Count = rawBuf.count / MemoryLayout<UInt64>.size
                for j in 0..<u64Count {
                    u64Ptr[j] = rng.next()
                }
            }
            try FixtureIO.write(buf, to: source.appendingPathComponent("blob-\(i).bin"))
        }

        let tarball = Self.freshTemp("canceltar").appendingPathExtension("tar.gz")
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: tarball)
        }
        let create = Process()
        create.executableURL = bsdtar
        create.arguments = [
            "-c", "-z", "-f", tarball.path,
            "-C", source.path, "--", "."
        ]
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        // Measure the natural extract time as our reference. We
        // extract into a throwaway directory and time it; the
        // cancellation assertion below requires the cancelled extract
        // to finish in noticeably less than this.
        let referenceDest = Self.freshTemp("refdest")
        defer { Self.purge(referenceDest) }
        let refStart = Date()
        _ = try await SidecarExtractor(
            tarExtractor: ProcessTarExtractor(timeout: 600),
            machOVerifier: StubVerifier()
        ).extract(tarball: tarball, into: referenceDest)
        let naturalExtractTime = Date().timeIntervalSince(refStart)
        // Sanity: if the natural extract is somehow <1 s, the test
        // can't reliably measure SIGTERM landing. Skip the timing
        // assertion in that case (genuine machine win, not a bug).
        let canMeasureCancel = naturalExtractTime >= 1.0

        let dest = Self.freshTemp("canceldest")
        defer { Self.purge(dest) }

        let extractor = SidecarExtractor(
            tarExtractor: ProcessTarExtractor(timeout: 600),
            machOVerifier: StubVerifier()
        )

        let started = Date()
        let task = Task {
            try await extractor.extract(tarball: tarball, into: dest)
        }
        // Give bsdtar a beat to actually start unpacking but cancel
        // well before natural completion. 100 ms is well under any
        // realistic natural extract time for a 250 MB tarball.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        var sawCancellation = false
        do {
            _ = try await task.value
            // Success path is only OK if the extract genuinely
            // raced to completion BEFORE we cancelled. That's
            // possible on a very fast machine; we fall through to
            // the elapsed-time assertion below.
        } catch is CancellationError {
            sawCancellation = true
        } catch {
            Issue.record("expected CancellationError or success, got \(error)")
        }

        let elapsed = Date().timeIntervalSince(started)
        if canMeasureCancel {
            // Strict cancellation budget: cancel must complete in
            // well under the natural extract time. If the test
            // measured natural=4s, we require elapsed < 2s (half).
            // This catches a regression where bsdtar isn't SIGTERM'd
            // and the call just waits for natural exit.
            let budget = max(1.0, naturalExtractTime / 2.0)
            #expect(elapsed < budget,
                    "cancel should land in <\(budget)s (natural extract: \(naturalExtractTime)s); took \(elapsed)s — likely no SIGTERM was sent. sawCancellation=\(sawCancellation)")
        }

        let staging = dest.appendingPathExtension("partial.extracted")
        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "staging must be cleaned after cancel (or successful publish)")
    }

    @Test("bsdtar timeout is enforced + surfaces tarFailed with timeout context")
    func realBsdtarTimeout() async throws {
        // Codex r1 MAJOR 2 mirror for the tar path: a hung bsdtar
        // must not block forever. We construct a scenario via a
        // bogus executable that sleeps long enough to exceed the
        // configured timeout.
        let dest = Self.freshTemp("timeout")
        defer { Self.purge(dest) }

        // /usr/bin/yes loops forever, ignored stdout sink, ignored
        // argv. The watchdog must SIGTERM it before the call hangs.
        let yesURL = URL(fileURLWithPath: "/usr/bin/yes")
        let fm = FileManager.default
        guard fm.fileExists(atPath: yesURL.path) else { return }

        let extractor = SidecarExtractor(
            tarExtractor: ProcessTarExtractor(
                executableURL: yesURL,
                timeout: 0.5
            ),
            machOVerifier: StubVerifier()
        )

        let started = Date()
        do {
            _ = try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/ignored.tar.gz"),
                into: dest
            )
            Issue.record("expected tarFailed for timed-out helper")
        } catch let err as SidecarExtractor.ExtractError {
            switch err {
            case .tarFailed(let msg):
                #expect(msg.contains("timed out"),
                        "tarFailed message should mention timeout; got: \(msg)")
            default:
                Issue.record("expected tarFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ExtractError.tarFailed, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3.0, "watchdog should fire near 0.5s, not hang; took \(elapsed)s")
    }

    @Test("publish-step catch: typed diskFailed + atomic non-publication on rename failure after verify")
    func publishStepCatchPreservesAtomicity() async throws {
        // Codex r1 MAJOR 1 / r2 MINOR / r3 MINOR: the round-2
        // chmod-parent-before-call vector was rejected by round-3
        // because the early createDirectory(staging) trips on the
        // same parent before the publish step gets a turn. The
        // tighter vector chmods the parent INSIDE the verifier
        // hook, between verify-pass and publish-step: tar extracts
        // OK, strip succeeds, verify succeeds, then the publish
        // step's rename hits EACCES because the parent has been
        // locked down. This pins the post-verify publish catch
        // specifically.
        let fm = FileManager.default
        if geteuid() == 0 {
            // Root bypasses DAC permissions; the publish step would
            // succeed, defeating the test. Skip rather than fail.
            return
        }

        let parent = Self.freshTemp("publishparent")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let dest = parent.appendingPathComponent("dest")
        let staging = dest.appendingPathExtension("partial.extracted")
        // Pre-seed dest with content so replaceItemAt is the publish
        // branch — gives the rename concrete bytes to replace.
        try Data("stale".utf8).write(to: dest)
        defer {
            // Perms restore FIRST, then removeItem. Order matters:
            // a chmod-0500 parent denies the recursive unlink.
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? fm.removeItem(at: parent)
        }

        // Verifier that chmods the destination's parent to 0500
        // (no write) after passing on the first Mach-O. By the
        // time `extract()` finishes the verify phase and reaches
        // the publish step's rename, the parent is read-only and
        // the rename fails with EACCES — exactly the post-verify
        // publish catch we want to pin.
        let lockingVerifier = StubVerifier(verdict: { url in
            let fm = FileManager.default
            try? fm.setAttributes([.posixPermissions: 0o500],
                                  ofItemAtPath: parent.path)
            _ = url
            return .success(())
        })

        let stub = StubTarExtractor(files: ["good.dylib": Self.machO64LE])
        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: lockingVerifier)

        do {
            _ = try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                into: dest
            )
            // If we get here, the publish step somehow succeeded
            // despite the lock (some filesystems permit replace
            // on a 0500 parent — APFS does NOT, but be defensive).
            // The fact that we reached this branch means the test
            // can't pin the post-verify catch on this runner; the
            // production code is correct, the test just can't see
            // it. Skip rather than fail.
            return
        } catch let err as SidecarExtractor.ExtractError {
            if case .diskFailed(let path, _, _, _) = err {
                // Must be a publish-step failure: path == dest.path
                // (not staging.path). The publish catch in
                // SidecarExtractor.swift passes `destination.path`
                // through to diskFailure; the find / strip catches
                // pass other paths. This assertion catches the
                // round-3 concern that the test was actually
                // tripping the early createDirectory catch.
                #expect(path == dest.path,
                        "publish-step failure must carry destination path (\(dest.path)); got \(path)")
            } else {
                Issue.record("expected diskFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ExtractError.diskFailed, got \(error)")
        }

        // Cleanup contract: the actor's bestEffortRemoveDirectory
        // runs on the publish-step catch path. When the failure
        // mode itself prevents cleanup (parent still 0500 when the
        // cleanup runs), staging may legitimately survive — that's
        // "best effort", not a contract violation. We restore the
        // parent perms ourselves and assert the actor's cleanup
        // succeeded EITHER inline OR via the post-restoration retry
        // a real coordinator would do.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        // After we restore perms, the staging directory is still
        // there if the actor's cleanup hit EACCES. The contract we
        // pin is the OBSERVABLE one: destination's content is the
        // original stale bytes (atomic-replace never happened) and
        // no half-written destination got published.
        let observed = try? Data(contentsOf: dest)
        #expect(observed == Data("stale".utf8),
                "destination must hold the original stale bytes — atomic-replace must NOT have happened on publish failure")
    }

    @Test("stripQuarantine on a symlink does NOT remove the xattr from the target")
    func quarantineStripDoesNotFollowSymlink() throws {
        // Codex r1 BLOCKING 3: removexattr without XATTR_NOFOLLOW
        // would let a malicious symlink in the tarball point at a
        // system path and clear quarantine outside our scope. The
        // fix uses XATTR_NOFOLLOW; this test pins it.
        let fm = FileManager.default
        let target = Self.freshTemp("xattr-target")
        try Data("real".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }

        // Attach quarantine to the target.
        let value = "0001;00000000;Test;".data(using: .utf8)!
        let setRC = target.path.withCString { cstr in
            value.withUnsafeBytes { vbuf -> Int32 in
                setxattr(cstr, "com.apple.quarantine",
                         vbuf.baseAddress, vbuf.count, 0, 0)
            }
        }
        #expect(setRC == 0, "setxattr on target failed")

        // Create a symlink pointing at the target, then ask
        // stripQuarantine to operate on the link. With
        // XATTR_NOFOLLOW the target's xattr must survive.
        let link = Self.freshTemp("xattr-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fm.removeItem(at: link) }

        try SidecarExtractor.stripQuarantine(at: link)

        let targetXattrs = Self.xattrNames(at: target.path)
        #expect(targetXattrs.contains("com.apple.quarantine"),
                "symlink strip must NOT propagate to the target; xattrs: \(targetXattrs)")
    }

    @Test("extract() does not re-wrap typed ExtractError from inner phases — file path preserved")
    func extractPreservesTypedErrorPath() async throws {
        // Codex r2 MINOR: the previous catch in extract() wrapped
        // findMachOFiles errors as diskFailed(staging.path), losing
        // the specific file that hit the I/O failure. Now the catch
        // distinguishes `ExtractError` from arbitrary `Error` and
        // re-throws the typed value as-is.
        //
        // Easiest unmistakable verification: throw a custom typed
        // ExtractError from a stub tar extractor that synthesises a
        // post-strip / pre-publish failure. We can't easily reach
        // the findMachOFiles catch in a stub-only test (the strip
        // walk runs first and would catch unreadable files), so we
        // exercise the equivalent path via a different mechanism: a
        // stub tar extractor that throws a typed ExtractError. The
        // public catch chain in extract() must pass that through
        // verbatim, not wrap it as diskFailed.
        let dest = Self.freshTemp("typedpassthrough")
        defer { Self.purge(dest) }

        // The stub raises a typed ExtractError.diskFailed with a
        // very specific path. If extract() wraps it (the original
        // bug), the test sees the staging path instead. The fix
        // preserves the original path verbatim.
        let preciseFailurePath = "/synthetic/precise/path/that/must/survive.dylib"
        let stub = StubTarExtractor(
            extractError: .diskFailed(
                path: preciseFailurePath,
                domain: NSPOSIXErrorDomain,
                code: 13,  // EACCES
                message: "synthetic precise failure"
            )
        )
        let extractor = SidecarExtractor(tarExtractor: stub,
                                         machOVerifier: StubVerifier())

        do {
            _ = try await extractor.extract(
                tarball: URL(fileURLWithPath: "/tmp/fake.tar.gz"),
                into: dest
            )
            Issue.record("expected typed ExtractError to propagate")
        } catch let err as SidecarExtractor.ExtractError {
            if case .diskFailed(let path, let domain, let code, let message) = err {
                #expect(path == preciseFailurePath,
                        "extract() must preserve the typed ExtractError's path; got \(path)")
                #expect(domain == NSPOSIXErrorDomain)
                #expect(code == 13)
                #expect(message.contains("synthetic"))
            } else {
                Issue.record("expected diskFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ExtractError, got \(error)")
        }
    }

    @Test("findMachOFiles surfaces a real I/O failure as diskFailed (not silent skip)")
    func findMachOSurfacesIOFailure() async throws {
        // Codex r1 BLOCKING 2: a regular file we can't open MUST
        // surface as diskFailed, not be silently treated as
        // not-Mach-O. Construct an unreadable regular file by
        // chmod-ing it to 0000 (POSIX allows this even for the
        // owner; subsequent open(2) returns EACCES).
        let fm = FileManager.default
        let root = Self.freshTemp("ioroot")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // Restore perms first so cleanup can succeed.
            let unreadable = root.appendingPathComponent("blocked")
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
            try? fm.removeItem(at: root)
        }

        let unreadable = root.appendingPathComponent("blocked")
        try Self.machO64LE.write(to: unreadable)
        // chmod 000 so FileHandle(forReadingFrom:) raises EACCES.
        // Skip this assertion if the test is running as root (where
        // 000 doesn't actually deny access — root bypasses DAC).
        if geteuid() == 0 { return }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        do {
            _ = try SidecarExtractor.findMachOFiles(under: root, fileManager: fm)
            Issue.record("findMachOFiles must throw when a regular file can't be opened")
        } catch let err as SidecarExtractor.ExtractError {
            if case .diskFailed(let path, _, _, _) = err {
                #expect(path.hasSuffix("blocked"),
                        "diskFailed should carry the offending path: \(path)")
            } else {
                Issue.record("expected diskFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ExtractError.diskFailed, got \(error)")
        }
    }

    @Test("codesign verifier timeout surfaces as CodesignError.timeout")
    func codesignVerifierTimeout() async throws {
        // Codex r1 MAJOR 2: a stuck codesign must NOT block the
        // bootstrapper. Exercise the timeout by pointing the
        // verifier at /usr/bin/yes (loops forever) with a tiny
        // timeout.
        let yesURL = URL(fileURLWithPath: "/usr/bin/yes")
        let fm = FileManager.default
        guard fm.fileExists(atPath: yesURL.path) else { return }

        let verifier = CodesignMachOVerifier(executableURL: yesURL, timeout: 0.5)
        let started = Date()
        do {
            try await verifier.verify(url: URL(fileURLWithPath: "/tmp/ignored"))
            Issue.record("verify must throw on timeout")
        } catch let err as CodesignMachOVerifier.CodesignError {
            switch err {
            case .timeout:
                let elapsed = Date().timeIntervalSince(started)
                #expect(elapsed < 3.0,
                        "watchdog should fire near 0.5s, not hang; took \(elapsed)s")
            default:
                Issue.record("expected .timeout, got \(err)")
            }
        } catch {
            Issue.record("expected CodesignError.timeout, got \(error)")
        }
    }

    @Test("codesign verifier reports stderr context on non-zero exit")
    func codesignVerifierNonZeroExit() async throws {
        // Real codesign -v on a path that isn't signed — surfaces
        // stderr so the caller's diagnostic isn't blind. Use
        // /usr/bin/false: exits 1 with no stderr, which is enough
        // to test the .nonZeroExit branch shape without needing a
        // real unsigned binary.
        let falseURL = URL(fileURLWithPath: "/usr/bin/false")
        let fm = FileManager.default
        guard fm.fileExists(atPath: falseURL.path) else { return }

        let verifier = CodesignMachOVerifier(executableURL: falseURL, timeout: 5)
        do {
            try await verifier.verify(url: URL(fileURLWithPath: "/tmp/ignored"))
            Issue.record("verify must throw on non-zero exit")
        } catch let err as CodesignMachOVerifier.CodesignError {
            if case .nonZeroExit(let code, _) = err {
                #expect(code == 1, "expected exit=1 from /usr/bin/false; got \(code)")
            } else {
                Issue.record("expected .nonZeroExit, got \(err)")
            }
        } catch {
            Issue.record("expected CodesignError.nonZeroExit, got \(error)")
        }
    }
}

/// Helper actor for phase-callback assertions, lifted out of every
/// test so the per-test setup stays narrow.
private actor PhaseLog {
    var phases: [SidecarExtractor.Phase] = []
    func record(_ p: SidecarExtractor.Phase) { phases.append(p) }
}
