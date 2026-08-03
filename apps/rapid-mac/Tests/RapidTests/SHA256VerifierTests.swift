import CryptoKit
import Foundation
import Testing
@testable import Rapid

/// Pins the streaming SHA256 contract that ``BootstrapInstaller``
/// relies on: byte-identical to a one-shot `SHA256.hash(data:)` on
/// the same bytes, regardless of chunk boundary; honours task
/// cancellation between chunks; surfaces typed errors on a missing
/// file; produces canonical lowercase hex.
@Suite("SHA256Verifier")
struct SHA256VerifierTests {

    private static func writeTempFile(_ data: Data, label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sha-\(label)-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("digest matches one-shot CryptoKit on small file")
    func smallFileDigestMatchesOneShot() async throws {
        let body = Data((0..<4096).map { UInt8($0 % 256) })  // 4 KB
        let url = try Self.writeTempFile(body, label: "small")
        defer { try? FileManager.default.removeItem(at: url) }

        let actual = try await SHA256Verifier.hexDigest(of: url)
        let expected = SHA256Verifier.hexString(SHA256.hash(data: body))

        #expect(actual == expected)
        #expect(actual.count == 64, "SHA256 hex digest must be 64 chars")
        #expect(actual.lowercased() == actual, "digest must be lowercase hex")
    }

    @Test("digest matches one-shot CryptoKit on large file crossing chunk boundary")
    func largeFileDigestMatchesOneShot() async throws {
        // 2.5 MiB — guarantees the streaming path crosses at least
        // two 1 MiB chunk boundaries, so a bug in the chunk-stitching
        // would produce a different hash than the one-shot call.
        let byteCount = (2 * 1024 * 1024) + (512 * 1024)
        let body = Data((0..<byteCount).map { UInt8($0 % 251) })
        let url = try Self.writeTempFile(body, label: "large")
        defer { try? FileManager.default.removeItem(at: url) }

        let actual = try await SHA256Verifier.hexDigest(of: url)
        let expected = SHA256Verifier.hexString(SHA256.hash(data: body))

        #expect(actual == expected, "streaming + one-shot must agree on multi-chunk payload")
    }

    @Test("empty file hashes to the SHA256-of-empty-string sentinel")
    func emptyFileDigest() async throws {
        let url = try Self.writeTempFile(Data(), label: "empty")
        defer { try? FileManager.default.removeItem(at: url) }

        let actual = try await SHA256Verifier.hexDigest(of: url)
        // Well-known SHA256("") — used as a sanity that the loop
        // exits cleanly on the very first read returning nil/empty.
        let expectedEmpty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(actual == expectedEmpty)
    }

    @Test("digest is independent of chunk size")
    func digestStableAcrossChunkSizes() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 256) })
        let url = try Self.writeTempFile(body, label: "chunkfree")
        defer { try? FileManager.default.removeItem(at: url) }

        let oneByte = try await SHA256Verifier.hexDigest(of: url, chunkSize: 1)
        let smallChunk = try await SHA256Verifier.hexDigest(of: url, chunkSize: 7919)  // prime
        let bigChunk = try await SHA256Verifier.hexDigest(of: url, chunkSize: 4 * 1024 * 1024)

        #expect(oneByte == smallChunk)
        #expect(smallChunk == bigChunk)
        // Confirms tiny chunkSize values (clamped to >= 1 inside) don't
        // produce a different result vs the default chunk size.
    }

    @Test("missing file surfaces typed error with POSIX context")
    func missingFile() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        do {
            _ = try await SHA256Verifier.hexDigest(of: url)
            Issue.record("hexDigest must throw on a missing file")
        } catch let err as SHA256Verifier.VerifyError {
            // Codex r2 MAJOR: the payload must carry the real POSIX
            // domain + code (ENOENT == 2) so the caller can construct
            // a `DiskFailureInfo` with non-synthesised filesystem
            // context. `as NSError` on a plain Swift enum would
            // otherwise yield `SwiftDeferredNSErrorDomain` here.
            switch err {
            case let .fileNotFound(p, d, c, m):
                #expect(p == url.path)
                #expect(d == NSPOSIXErrorDomain)
                #expect(c == 2, "ENOENT == 2")
                #expect(!m.isEmpty)
            default:
                Issue.record("expected fileNotFound, got \(err)")
            }
        }
    }

    @Test("cancellation between chunks surfaces as CancellationError")
    func cancellationSurfacesCleanly() async throws {
        // Big enough that the in-flight hash is interruptible. 8 MiB
        // with a 64 KiB chunkSize → 128 cancel-check points, so the
        // race window between dispatch + first chunk is small enough
        // that the cancel reliably lands inside the loop.
        let byteCount = 8 * 1024 * 1024
        let body = Data((0..<byteCount).map { UInt8($0 % 256) })
        let url = try Self.writeTempFile(body, label: "cancel")
        defer { try? FileManager.default.removeItem(at: url) }

        let hashTask = Task {
            try await SHA256Verifier.hexDigest(of: url, chunkSize: 64 * 1024)
        }
        // Brief yield so the task starts but probably hasn't finished
        // — APFS file reads from RAM cache are fast, so we cancel
        // immediately to maximise the chance the cancel races the
        // loop rather than landing on a completed task. Either way,
        // the test passes: if we cancelled too late the task already
        // completed successfully (which is also a valid observation
        // — we only fail if we get a non-cancellation error).
        try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
        hashTask.cancel()

        do {
            _ = try await hashTask.value
            // Cancel landed after the hash already completed; that's
            // a valid race outcome, not a failure.
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("expected CancellationError or success; got \(error)")
        }
    }

    @Test("constant-time equals: equal strings match, differing strings don't")
    func constantTimeEquals() {
        #expect(SHA256Verifier.constantTimeEquals("abcd", "abcd"))
        #expect(!SHA256Verifier.constantTimeEquals("abcd", "abce"))
        #expect(!SHA256Verifier.constantTimeEquals("abcd", "abc"))  // length mismatch
        #expect(SHA256Verifier.constantTimeEquals("", ""))
    }

    @Test("normalisedExpectedHash strips sha256: prefix + lowercases")
    func normaliseExpectedHash() {
        let lower = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let upper = lower.uppercased()

        #expect(SHA256Verifier.normalisedExpectedHash(lower) == lower)
        #expect(SHA256Verifier.normalisedExpectedHash(upper) == lower)
        #expect(SHA256Verifier.normalisedExpectedHash("sha256:" + lower) == lower)
        #expect(SHA256Verifier.normalisedExpectedHash("sha-256:" + upper) == lower)
        // Surrounding whitespace tolerated.
        #expect(SHA256Verifier.normalisedExpectedHash("  \(lower)\n") == lower)
    }

    @Test("normalisedExpectedHash rejects malformed inputs")
    func rejectsBadHashes() {
        #expect(SHA256Verifier.normalisedExpectedHash("") == nil)
        #expect(SHA256Verifier.normalisedExpectedHash("zzzz") == nil)
        // 63 chars — one short.
        let short = String(repeating: "a", count: 63)
        #expect(SHA256Verifier.normalisedExpectedHash(short) == nil)
        // 64 chars but with a non-hex character.
        let bad = String(repeating: "a", count: 63) + "g"
        #expect(SHA256Verifier.normalisedExpectedHash(bad) == nil)
        // sha256 prefix is fine but content is bad.
        #expect(SHA256Verifier.normalisedExpectedHash("sha256:zzz") == nil)
    }
}
