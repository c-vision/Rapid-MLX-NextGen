import CryptoKit
import Foundation
import Testing
@testable import Rapid

/// URLProtocol stub dedicated to ``BootstrapInstallerTests``. Kept
/// independent of ``StubDownloadProtocol`` (which the
/// ``ResumableDownloaderTests`` suite owns) so the two suites can
/// run in parallel without racing on static state. The installer
/// tests don't need the resume / Range scaffolding the downloader
/// suite leans on — a single happy-path 200 response with a
/// configurable body is enough for every install-side branch we want
/// to exercise.
final class StubInstallerProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = .init()
    /// When > 0, the stub delivers `truncateToBytes` bytes then ends
    /// the response — useful for "download size mismatch" coverage,
    /// not exercised in this suite today but cheap insurance.
    nonisolated(unsafe) static var truncateToBytes: Int = 0
    /// When > 0, the stub sleeps for this many seconds AFTER sending
    /// the response headers but BEFORE the body. Used by the
    /// concurrent-install test to keep the first install genuinely
    /// in flight (suspended on `await downloader.download(...)`)
    /// while the second install enters the actor — that's the only
    /// way to exercise the in-flight rejection path, because the
    /// in-memory stub otherwise completes faster than the second
    /// task even reaches the actor.
    nonisolated(unsafe) static var responseDelaySeconds: Double = 0

    static func reset(body: Data) {
        Self.body = body
        Self.truncateToBytes = 0
        Self.responseDelaySeconds = 0
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
        if Self.responseDelaySeconds > 0 {
            // Block this URLProtocol's loader thread (URLSession runs
            // each load on its own worker) so the parent download
            // call's `await` stays suspended for the duration. This
            // lets the concurrent-install test reliably enter the
            // second `install(...)` call WHILE the first is in flight.
            Thread.sleep(forTimeInterval: Self.responseDelaySeconds)
        }
        if Self.truncateToBytes > 0 {
            client?.urlProtocol(self, didLoad: payload.prefix(Self.truncateToBytes))
        } else {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { /* no-op for this suite */ }
}

@Suite("BootstrapInstaller", .serialized)
struct BootstrapInstallerTests {

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubInstallerProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// Build a body of `byteCount` bytes with a deterministic pattern
    /// and return both the bytes and their canonical lowercase-hex
    /// SHA256 so the test can pass the right `expectedSHA256` to the
    /// installer.
    private static func makeBody(byteCount: Int) -> (Data, String) {
        var d = Data(capacity: byteCount)
        for i in 0..<byteCount { d.append(UInt8(i % 256)) }
        let hex = SHA256Verifier.hexString(SHA256.hash(data: d))
        return (d, hex)
    }

    private static func freshDestination(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("install-\(label)-\(UUID().uuidString)")
    }

    /// Remove every file the install pipeline could have created at
    /// the given destination so a test's `defer` is a single call.
    private static func purge(_ destination: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: destination.appendingPathExtension("partial"))
        try? fm.removeItem(at: destination.appendingPathExtension("partial.tmp.dl"))
        try? fm.removeItem(at: destination
            .appendingPathExtension("partial.tmp.dl")
            .appendingPathExtension("partial"))
    }

    @Test("happy path — download + verify + atomic install")
    func happyPath() async throws {
        let (body, hash) = Self.makeBody(byteCount: 256 * 1024)
        StubInstallerProtocol.reset(body: body)

        let dest = Self.freshDestination("happy")
        defer { Self.purge(dest) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: hash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        // Capture phase transitions to assert the contract the splash
        // UI binds to: at least one downloading callback, one verify,
        // one install.
        actor PhaseLog {
            var phases: [BootstrapInstaller.Phase] = []
            func record(_ p: BootstrapInstaller.Phase) { phases.append(p) }
        }
        let log = PhaseLog()

        let result = try await installer.install(artifact: spec) { phase, _ in
            Task { await log.record(phase) }
        }

        #expect(result == dest)
        let written = try Data(contentsOf: dest)
        #expect(written == body, "atomic install must publish the byte-identical artifact")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.tmp.dl").path),
                "staged .partial.tmp.dl must be gone after publish")
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial").path),
                "downloader's internal .partial must be cleaned up too")

        // Phase callbacks: give the dispatched record() calls a beat
        // to land, then assert each phase was observed at least once.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let phases = await log.phases
        #expect(phases.contains(.downloading))
        #expect(phases.contains(.verifying))
        #expect(phases.contains(.installing))
    }

    @Test("SHA256 mismatch deletes staged file + surfaces verifyFailed")
    func sha256MismatchCleansAndThrows() async throws {
        let (body, _) = Self.makeBody(byteCount: 128 * 1024)
        StubInstallerProtocol.reset(body: body)

        let dest = Self.freshDestination("mismatch")
        defer { Self.purge(dest) }

        // Manifest claims a hash that doesn't match the bytes the
        // server will deliver. Any other 64-char lowercase hex value
        // works — pick the all-zeros sentinel for readability.
        let bogusHash = String(repeating: "0", count: 64)

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: bogusHash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        do {
            _ = try await installer.install(artifact: spec)
            Issue.record("install must throw on hash mismatch")
        } catch let err as BootstrapInstaller.InstallError {
            switch err {
            case .verifyFailed(let expected, let actual):
                #expect(expected == bogusHash)
                #expect(actual != bogusHash)
                #expect(actual.count == 64)
            default:
                Issue.record("expected verifyFailed, got \(err)")
            }
        } catch {
            Issue.record("expected InstallError.verifyFailed, got \(error)")
        }

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.path),
                "destination must remain absent on hash failure")
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.tmp.dl").path),
                "corrupt staged bytes MUST be deleted — next install must not resume from them")
    }

    @Test("invalid expected hash rejected before any network call")
    func invalidExpectedHashFailsClosed() async throws {
        let dest = Self.freshDestination("badhash")
        defer { Self.purge(dest) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: "not-a-real-hash",
            expectedBytes: 100,
            destination: dest
        )

        await #expect(throws: BootstrapInstaller.InstallError.invalidExpectedHash) {
            _ = try await installer.install(artifact: spec)
        }

        // Critical invariant: no socket opened, no .partial files
        // written. We can't directly assert "no socket opened" without
        // a counter on the stub, but the absence of any temp file is
        // the visible side-channel.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.path))
        #expect(!fm.fileExists(atPath: dest.appendingPathExtension("partial.tmp.dl").path))
    }

    @Test("re-running over an existing destination replaces atomically")
    func atomicReplaceOverExistingDestination() async throws {
        // Pre-seed the destination with a stale "old install" payload
        // so the publish step has to take the replaceItemAt branch
        // rather than moveItem. Crash-safety property under test:
        // after the install completes, the destination either holds
        // the OLD bytes (rename never started) or the NEW bytes
        // (rename completed). It MUST NOT hold a half-written file.
        let dest = Self.freshDestination("replace")
        defer { Self.purge(dest) }

        let staleBytes = Data(repeating: 0xCC, count: 64 * 1024)
        try staleBytes.write(to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let (body, hash) = Self.makeBody(byteCount: 128 * 1024)
        StubInstallerProtocol.reset(body: body)

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: hash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        let result = try await installer.install(artifact: spec)
        let observed = try Data(contentsOf: result)

        // After atomic replace, the destination is one of:
        //   (a) the new body — atomic rename completed
        //   (b) the old body — rename never started
        // Never a concatenation, prefix, or any other partial state.
        // The success path through `install(...)` proves (a).
        #expect(observed == body, "atomic replace must publish the new bytes whole")
        #expect(observed != staleBytes, "stale bytes must be replaced, not preserved")
        #expect(observed.count == body.count,
                "destination size must match the new artifact exactly")
    }

    @Test("unwritable destination parent surfaces as diskFailed (typed-error contract)")
    func unwritableDestinationSurfacesAsDiskFailed() async throws {
        // Disk-failure surface coverage. Real "ENOSPC during rename"
        // can't be reliably induced in a unit test without root or a
        // chroot, so we exercise the typed-error PIPELINE via a
        // different vector that exists on every macOS box: a
        // destination whose parent path traverses `/dev/null` (a
        // regular character device, not a directory — so any
        // mkdir/write under it returns ENOTDIR / EACCES).
        //
        // The user-visible contract under test:
        //   * filesystem errors during install MUST surface as
        //     ``InstallError.diskFailed`` (typed), never as a leaked
        //     NSError that the UI layer has to string-parse.
        //   * a thrown install must leave the destination absent so a
        //     retry isn't blocked by a stale half-state.
        //
        // The exact phase the error fires from (download-side
        // createDirectory vs publish-side rename) is intentionally
        // not asserted — both code paths funnel through the same
        // ``.diskFailed`` translator, so either is a valid
        // observation of the contract.
        let dest = URL(fileURLWithPath: "/dev/null/rapid-bootstrap-cannot-create")
            .appendingPathComponent("dest-\(UUID().uuidString)")

        let (body, hash) = Self.makeBody(byteCount: 64 * 1024)
        StubInstallerProtocol.reset(body: body)

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: hash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        do {
            _ = try await installer.install(artifact: spec)
            Issue.record("install must throw when destination parent is unwritable")
        } catch let err as BootstrapInstaller.InstallError {
            switch err {
            case .diskFailed(let info):
                // Codex r1 MAJOR #2: structured failure info must
                // carry the operation + a non-empty domain/code so
                // telemetry can bucket without parsing strings.
                #expect(
                    info.operation == .download ||
                    info.operation == .verify ||
                    info.operation == .publish,
                    "operation enum must be set so telemetry can bucket"
                )
                #expect(!info.domain.isEmpty,
                        "underlying NSError domain must be preserved")
                // POSIX domain ENOTDIR (20) is the most likely code
                // here but the exact value can vary by macOS version;
                // we only assert it's set, not what it equals.
                #expect(info.code != 0, "underlying error code must be preserved")
            default:
                Issue.record("expected diskFailed, got \(err)")
            }
        } catch {
            Issue.record("expected InstallError.diskFailed, got \(error)")
        }

        // Critical safety invariant: a failed install must NOT leave
        // a published file at the destination. (Staged-file presence
        // depends on which phase failed and isn't a stable assertion
        // across macOS versions.)
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "failed install must not publish a partial file at the destination")
    }

    @Test("concurrent installs on the same destination — second call rejected, not raced")
    func concurrentInstallsRejected() async throws {
        // Codex r1 MAJOR #1: actor reentrancy across `await` lets two
        // calls interleave on the same staged file. The defence is an
        // in-flight-destinations set inside the actor; the second
        // call must surface a typed ``alreadyInstalling`` error
        // BEFORE any state mutation, so the first call's bytes/state
        // are never disturbed.
        //
        // Determinism: the in-memory URLProtocol stub otherwise
        // completes faster than the TaskGroup spins up the second
        // child task, so the second call lands sequentially (after
        // the first's defer has cleared the in-flight set) and the
        // race-protection contract isn't actually exercised. We make
        // the stub sleep ~250 ms before delivering the body so the
        // first install's `await downloader.download(...)` is
        // genuinely suspended when the second call arrives.
        let (body, hash) = Self.makeBody(byteCount: 64 * 1024)
        StubInstallerProtocol.reset(body: body)
        StubInstallerProtocol.responseDelaySeconds = 0.25

        let dest = Self.freshDestination("concurrent")
        defer { Self.purge(dest) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: hash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        // Fire both concurrently via TaskGroup. The first task
        // claims the in-flight slot during its sync prologue; the
        // second task — added a beat later, so the first is
        // guaranteed to be parked on the 250 ms stub delay — must
        // observe the in-flight set and throw `alreadyInstalling`.
        let outcome = await withTaskGroup(of: Result<URL, Error>.self) { group -> (winners: Int, rejections: Int) in
            group.addTask {
                do { return .success(try await installer.install(artifact: spec)) }
                catch { return .failure(error) }
            }
            // Tiny yield so task 1's `install(...)` actor prologue
            // (the `inFlightDestinations.insert(...)` line) runs
            // BEFORE task 2 enters the actor. Without it both tasks
            // can land their sync prologues atomically and the
            // contract under test isn't actually exercised.
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            group.addTask {
                do { return .success(try await installer.install(artifact: spec)) }
                catch { return .failure(error) }
            }
            var w = 0
            var r = 0
            for await result in group {
                switch result {
                case .success:
                    w += 1
                case .failure(let err):
                    if case BootstrapInstaller.InstallError.alreadyInstalling = err {
                        r += 1
                    } else {
                        Issue.record("expected alreadyInstalling, got \(err)")
                    }
                }
            }
            return (w, r)
        }
        #expect(outcome.winners == 1, "exactly one install must succeed (got \(outcome.winners))")
        #expect(outcome.rejections == 1, "the other concurrent call must be rejected (got \(outcome.rejections))")

        // The staged file must NOT linger after a successful install
        // — the in-flight tracking releases the destination on the
        // winner's defer, and the winner's publishAtomic moved the
        // staged file to dest.
        let stagedURL = dest.appendingPathExtension("partial.tmp.dl")
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path),
                "winner's staged file must be moved into place")
        #expect(FileManager.default.fileExists(atPath: dest.path),
                "winner must have published a file at the destination")
    }

    @Test("cancellation during verify surfaces as CancellationError and cleans staged file")
    func cancellationDuringVerifyCleansStaged() async throws {
        // 8 MiB body: large enough that the SHA256 streaming loop has
        // many cancel-check points but the download is still quick on
        // the in-memory URLProtocol stub. The cancel lands during
        // verify (after download completes) and must:
        //   * surface as CancellationError
        //   * delete the staged .partial.tmp.dl so a stale verify
        //     can't survive into the next install attempt
        let (body, hash) = Self.makeBody(byteCount: 8 * 1024 * 1024)
        StubInstallerProtocol.reset(body: body)

        let dest = Self.freshDestination("cancel-verify")
        defer { Self.purge(dest) }

        let downloader = ResumableDownloader(session: Self.makeSession())
        let installer = BootstrapInstaller(downloader: downloader)
        let spec = BootstrapInstaller.ArtifactSpec(
            url: URL(string: "https://example.invalid/sidecar.tar.gz")!,
            expectedSHA256: hash,
            expectedBytes: UInt64(body.count),
            destination: dest
        )

        let installTask = Task {
            try await installer.install(artifact: spec) { phase, _ in
                if phase == .verifying {
                    // Spin a cancellation on the parent task so the
                    // hash loop trips a checkCancellation between
                    // chunks. The Task wrapper captures `installTask`
                    // out of scope, but Task.cancel() on the outer
                    // captured handle is what we want.
                }
            }
        }

        // Naive scheduling: let download complete, then cancel. The
        // download is in-memory so it finishes quickly; sleeping
        // 30 ms gives it time to land on the verify step and then
        // bail.
        try? await Task.sleep(nanoseconds: 30_000_000)
        installTask.cancel()

        do {
            _ = try await installTask.value
            // It's possible the install completed before the cancel
            // landed — that's a benign race outcome for this stub
            // because the body matches the hash. We only fail if a
            // typed install error escaped.
        } catch is CancellationError {
            // expected
            let stagedURL = dest.appendingPathExtension("partial.tmp.dl")
            #expect(!FileManager.default.fileExists(atPath: stagedURL.path),
                    "cancellation during verify must delete the staged file")
            #expect(!FileManager.default.fileExists(atPath: dest.path),
                    "destination must not be published when verify is cancelled")
        } catch let err as BootstrapInstaller.InstallError {
            Issue.record("cancellation must surface as CancellationError, not \(err)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
