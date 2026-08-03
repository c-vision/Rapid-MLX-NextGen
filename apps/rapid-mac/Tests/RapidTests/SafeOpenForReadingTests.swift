import Foundation
import Testing
@testable import Rapid

/// Pins the `O_NOFOLLOW`-on-leaf hardening that closes the
/// residual TOCTOU window in `read_file` / `read_image`. Audit
/// P1 (`SandboxManager.swift:66-99`).
///
/// The existing call sites already canonicalize + recheck
/// immediately before opening, shrinking the TOCTOU window to
/// microseconds. `O_NOFOLLOW` eliminates the leaf-symlink-swap
/// vector in that window completely: if the canonical leaf
/// becomes a symlink between recheck and open, the kernel
/// returns ELOOP and we surface a clear `symlinkAtLeaf` error.
@Suite("FilesystemTools.safeOpenForReading — O_NOFOLLOW leaf hardening")
struct SafeOpenForReadingTests {

    /// Happy path: a real regular file with no symlinks on the
    /// final component opens cleanly and returns its bytes.
    @Test("Regular file opens and reads the same bytes as on-disk")
    func regular_file_opens_cleanly() throws {
        let url = Self.scratchURL(suffix: "regular.txt")
        let payload = "hello, sandbox\n".data(using: .utf8)!
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FilesystemTools.safeOpenForReading(canonical: url)
        let read = handle.readDataToEndOfFile()
        try? handle.close()
        #expect(read == payload)
    }

    /// The audit P1 vector: a symlink stands in for the leaf
    /// between recheck and open. The kernel must refuse with
    /// ELOOP and the helper surfaces `.symlinkAtLeaf`. Pre-fix
    /// this would have silently followed the symlink and read
    /// the attacker's target file.
    @Test("Symlink at leaf is refused with .symlinkAtLeaf (O_NOFOLLOW closes the TOCTOU vector)")
    func symlink_at_leaf_is_refused() throws {
        let dir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try "this should never be readable\n".data(using: .utf8)!.write(to: secret)

        let linkURL = dir.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: secret
        )

        do {
            _ = try FilesystemTools.safeOpenForReading(canonical: linkURL)
            Issue.record("Expected .symlinkAtLeaf, got success — TOCTOU window is open")
        } catch FilesystemTools.SafeOpenError.symlinkAtLeaf(let url) {
            #expect(url == linkURL,
                    "symlinkAtLeaf must carry the URL we tried to open")
        } catch {
            Issue.record("Expected .symlinkAtLeaf, got \(type(of: error)): \(error)")
        }
    }

    /// Sanity check the error shape for the broader "open failed"
    /// case — a path that doesn't exist should surface
    /// `.openFailed(_, errno: ENOENT)`. The recovery message in
    /// production includes `errno` so an operator reading logs
    /// can distinguish ENOENT from EACCES from ELOOP.
    @Test("Missing file surfaces .openFailed with ENOENT")
    func missing_file_surfaces_open_failed() {
        let url = Self.scratchURL(suffix: "does-not-exist-\(UUID().uuidString)")
        do {
            _ = try FilesystemTools.safeOpenForReading(canonical: url)
            Issue.record("Expected .openFailed, got success")
        } catch FilesystemTools.SafeOpenError.openFailed(let u, let err) {
            #expect(u == url)
            #expect(err == ENOENT,
                    "Expected ENOENT (\(ENOENT)), got errno \(err)")
        } catch FilesystemTools.SafeOpenError.symlinkAtLeaf {
            Issue.record("Missing file should NOT surface as symlinkAtLeaf")
        } catch {
            Issue.record("Expected .openFailed, got \(type(of: error)): \(error)")
        }
    }

    /// Belt-and-suspenders: a leaf that IS a symlink pointing at
    /// the SAME directory it lives in (a self-loop, not a
    /// retarget) — still refused. The O_NOFOLLOW check happens
    /// at the leaf regardless of where the symlink points.
    @Test("Symlink at leaf is refused even when target is in the same approved dir")
    func symlink_at_leaf_within_approved_dir_still_refused() throws {
        let dir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("approved.txt")
        try "approved\n".data(using: .utf8)!.write(to: target)

        let linkURL = dir.appendingPathComponent("approved-link")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: target
        )

        do {
            _ = try FilesystemTools.safeOpenForReading(canonical: linkURL)
            Issue.record("Even an intra-dir symlink at leaf must be refused")
        } catch FilesystemTools.SafeOpenError.symlinkAtLeaf {
            // expected
        } catch {
            Issue.record("Expected .symlinkAtLeaf, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Helpers

    private static func scratchDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-toctou-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func scratchURL(suffix: String) -> URL {
        scratchDir().appendingPathComponent(suffix, isDirectory: false)
    }
}
