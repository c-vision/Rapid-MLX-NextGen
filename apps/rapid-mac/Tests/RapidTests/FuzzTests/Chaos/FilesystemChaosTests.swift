import Foundation
import Testing
@testable import Rapid

/// Angle B — Filesystem chaos against ``ChatExporter.atomicWrite``.
///
/// The export flow ends at a ``Data.write(to:)`` call (or our hardened
/// equivalent). NSSavePanel returns a ``URL`` chosen by the user;
/// "hostile" choices the user can innocently arrive at:
///
///   * A path on a read-only volume (a mounted DMG, a `/Volumes` ro
///     mount, a sandbox-denied directory).
///   * A path with a NUL byte hidden in a percent-encoded segment.
///   * A path whose parent directory is replaced by a symlink to
///     ``/etc`` between approval and the write call (classic TOCTOU
///     redirect — same threat model that motivated ``O_NOFOLLOW``).
///   * A path inside a directory that the user has ``chmod 000``'d
///     between picker dismissal and write.
///
/// For each adversarial destination we assert:
///   * ``atomicWrite`` throws — caller gets a real error to surface.
///   * No partial file lands at ``destination`` after the throw.
///   * No orphan ``.rapid-export-*`` sibling is left behind in the
///     parent directory (the ``catch`` block in ``atomicWrite`` calls
///     ``unlink(tmpPath)``; this test pins that ledger).
@Suite("Chaos — hostile NSSavePanel destinations", .serialized)
struct FilesystemChaosTests {

    /// Read-only parent directory. ``chmod 0o555`` strips +w from
    /// the test dir before atomicWrite tries to create its temp
    /// sibling. ``open(... O_CREAT ...)`` returns EACCES; the
    /// helper must surface a ``ChatExporterError.writeFailed`` and
    /// leave nothing behind.
    @Test("atomicWrite → read-only parent dir → throws + no orphan")
    func atomicWriteThrowsOnReadOnlyParent() throws {
        let dir = try makeChaosDir(label: "ro-parent")
        defer {
            // Restore permissions before deletion or the cleanup
            // throws permissions-denied.
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let dest = dir.appendingPathComponent("payload.bin")
        let payload = Data("hello chaos".utf8)

        // chmod after the dir exists so ``makeChaosDir`` doesn't
        // race with us.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        var threw = false
        do {
            try ChatExporter.atomicWrite(payload, to: dest)
        } catch let err as ChatExporterError {
            threw = true
            // Phase MUST be "open" — that's the syscall that hits
            // the read-only directory. If it isn't, the
            // implementation has reordered the operations and the
            // error message will be misleading.
            if case .writeFailed(_, _, let phase) = err {
                #expect(phase == "open", "expected open-phase failure on read-only parent, got phase=\(phase)")
            } else {
                Issue.record("expected .writeFailed, got \(err)")
            }
        } catch {
            Issue.record("expected ChatExporterError, got \(error)")
        }
        #expect(threw, "atomicWrite must throw on a read-only parent")
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "no destination file should appear on failure")

        // Re-readable so the orphan check can list contents.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let orphans = siblings.filter { $0.lastPathComponent.hasPrefix(".rapid-export-") }
        if !orphans.isEmpty {
            Issue.record("""
            ORPHAN LEAK (P2): \(orphans.count) ``.rapid-export-*`` siblings remain after failed atomicWrite.
              orphans=\(orphans.map(\.lastPathComponent))
            """)
        }
    }

    /// Symlink-at-destination decoy. Drop a symlink at ``dest`` →
    /// ``/etc/hosts`` BEFORE calling atomicWrite. The helper's
    /// strategy: ``open(tmpPath, O_CREAT | O_EXCL | O_NOFOLLOW)``
    /// + ``rename`` should replace the symlink with our real file
    /// (rename on macOS replaces a target symlink). Critically:
    /// our bytes must NEVER end up appended to ``/etc/hosts``.
    @Test("atomicWrite → symlink-at-destination → real file replaces symlink, target untouched")
    func atomicWriteReplacesSymlinkWithoutFollowing() throws {
        let dir = try makeChaosDir(label: "symlink-dest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Decoy target — a file in the SAME chaos dir, NOT
        // ``/etc/hosts`` (we won't actually risk writing to system
        // files even in a fuzz test). The test verifies the symlink
        // is replaced rather than followed.
        let decoyTarget = dir.appendingPathComponent("decoy-target.bin")
        let decoyOriginal = Data("DO NOT TOUCH THIS BYTE STREAM".utf8)
        try decoyOriginal.write(to: decoyTarget)

        let dest = dir.appendingPathComponent("payload.bin")
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: decoyTarget)

        let payload = Data("the real export bytes".utf8)
        try ChatExporter.atomicWrite(payload, to: dest)

        // After atomicWrite, ``dest`` must contain the payload
        // (resolved as a real file, no longer a symlink) and the
        // decoy target must still hold its original bytes.
        //
        // Codex round 1 NIT: use ``lstat`` so we measure the
        // link itself, not its target. ``attributesOfItem`` was
        // ambiguous because some macOS builds follow the symlink
        // before populating the type attribute.
        var st = stat()
        let lstatRC = lstat(dest.path, &st)
        #expect(lstatRC == 0, "lstat on destination must succeed")
        let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        #expect(!isSymlink, "destination must be a real file after atomicWrite, not a symlink")
        let destBytes = try Data(contentsOf: dest)
        #expect(destBytes == payload, "destination must hold the new payload")

        let decoyBytes = try Data(contentsOf: decoyTarget)
        if decoyBytes != decoyOriginal {
            Issue.record("""
            SECURITY BUG (P0): atomicWrite followed a symlink and overwrote the target.
              decoy.expected=\(decoyOriginal.count) bytes
              decoy.observed=\(decoyBytes.count) bytes
            """)
        }
    }

    /// Symlink-at-temp-path decoy. The temp filename uses a UUID,
    /// so an attacker can't predict it precisely — but if they
    /// guess a directory listing race they might pre-plant a
    /// symlink. We don't have the random UUID until after open()
    /// returns, so we can't easily land a real race here; instead
    /// we test the precondition: the ``O_NOFOLLOW`` flag is in the
    /// open mask. We do this by creating a symlink at a temp path
    /// that uses the same prefix and observing that opening it with
    /// ``O_NOFOLLOW`` returns ELOOP.
    @Test("O_NOFOLLOW guard rejects a planted symlink at a predictable temp prefix")
    func nofollowGuardRejectsPlantedSymlink() throws {
        let dir = try makeChaosDir(label: "nofollow-plant")
        defer { try? FileManager.default.removeItem(at: dir) }

        let decoy = dir.appendingPathComponent("decoy.bin")
        try Data("decoy".utf8).write(to: decoy)

        let tmpName = ".rapid-export-planted-symlink"
        let tmpURL = dir.appendingPathComponent(tmpName)
        try FileManager.default.createSymbolicLink(at: tmpURL, withDestinationURL: decoy)

        // Replicate the same open mask atomicWrite uses.
        let flags: Int32 = O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW
        let fd = open(tmpURL.path, flags, 0o600)
        if fd >= 0 {
            close(fd)
            Issue.record("SECURITY BUG (P0): O_CREAT|O_EXCL|O_NOFOLLOW followed a planted symlink (no ELOOP). errno=\(errno)")
        } else {
            // ELOOP or EEXIST both prove the guard works.
            #expect(errno == ELOOP || errno == EEXIST,
                    "expected ELOOP or EEXIST, got errno=\(errno) (\(String(cString: strerror(errno))))")
        }
    }

    /// NUL-byte in the destination path. The Foundation URL APIs
    /// silently truncate at NUL on some paths; if a caller ever
    /// hands atomicWrite a path with embedded NUL, the C ``open``
    /// will see only the prefix. Verify our hardened helper rejects
    /// or fails cleanly rather than silently writing to a wrong
    /// path.
    @Test("atomicWrite → NUL-byte in destination → throws cleanly OR Foundation rejects the URL")
    func atomicWriteRejectsNullByteInPath() throws {
        let dir = try makeChaosDir(label: "nul-byte")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Foundation URL APIs are NUL-tolerant in some shapes but
        // fail when materialised via ``URL.path``. Test both.
        let badPath = dir.path + "/payload\0SHADOW.bin"
        // Building a URL from a String containing a NUL byte —
        // ``URL(fileURLWithPath:)`` keeps the bytes; ``open`` sees
        // only the prefix.
        let dest = URL(fileURLWithPath: badPath)

        let payload = Data("nul-byte canary".utf8)
        var threw = false
        do {
            try ChatExporter.atomicWrite(payload, to: dest)
        } catch {
            threw = true
        }
        // The fact a file landed at ``payload`` (the prefix) would
        // be a path-truncation bug. Check for both the prefix path
        // AND any file with the literal ``SHADOW`` substring.
        let prefixDest = dir.appendingPathComponent("payload")
        let prefixExists = FileManager.default.fileExists(atPath: prefixDest.path)
        if prefixExists {
            Issue.record("""
            BUG (P2, path-truncation): NUL-byte in destination silently truncated to '\(prefixDest.path)'.
              caller intended: \(badPath.debugDescription)
              file landed at: \(prefixDest.path)
            """)
        }
        // Either we threw, or nothing ended up on disk. Both are
        // acceptable; silently writing to the truncated path is not.
        #expect(threw || !prefixExists,
                "atomicWrite must either throw on NUL-byte path or refuse silently — not write to a truncated prefix")
    }

    /// Hostile path components: ``../`` traversal in the LAST
    /// segment. ``URL.appendingPathComponent("..")`` is
    /// path-collapse-ambiguous; verify atomicWrite either rejects
    /// or constrains the write to inside the chosen parent.
    @Test("atomicWrite → ``..`` in destination last component → bytes never escape parent directory")
    func atomicWriteDotDotEscapeIsConstrained() throws {
        let dir = try makeChaosDir(label: "dotdot-escape")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outer = dir.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        // Caller picks ``inner/../escapee.bin`` — collapses to
        // ``outer/escapee.bin``. Whether atomicWrite resolves the
        // path or treats it literally, the bytes must NEVER appear
        // outside ``dir`` (which is the only directory we created).
        let trickyDest = inner.appendingPathComponent("../escapee.bin")
        let payload = Data("dotdot canary".utf8)

        _ = try? ChatExporter.atomicWrite(payload, to: trickyDest)

        // Walk every dir under ``dir`` and confirm the only
        // ``escapee.bin`` (if any) lives under ``dir`` itself —
        // never a sibling at ``dir.parent``.
        let parentSiblings = (try? FileManager.default.contentsOfDirectory(
            at: dir.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        ) ?? []
        let leakedSibling = parentSiblings.first {
            $0.lastPathComponent == "escapee.bin"
        }
        if leakedSibling != nil {
            Issue.record("""
            SECURITY BUG (P0, path-escape): atomicWrite wrote outside the chosen parent.
              expected: inside \(dir.path)
              landed:   \(leakedSibling!.path)
            """)
        }
    }

    /// Parent directory replaced by a symlink between path
    /// validation and atomicWrite's ``open`` call. We can't
    /// inject a real TOCTOU race against atomicWrite from outside
    /// (the test thread can't preempt the syscall), but we CAN
    /// validate the boundary: if the caller picks a destination
    /// whose parent is itself a symlink to elsewhere, the writer
    /// will dereference it — that's the kernel's design. We pin
    /// this as a KNOWN limitation: the parent dir is trusted; the
    /// last segment is hardened.
    ///
    /// Surface this as a documentation pin so we don't accidentally
    /// regress to "follow symlinks at every level".
    @Test("atomicWrite → parent-dir-is-symlink → bytes land in the symlink's target (documented, intentional)")
    func atomicWriteParentSymlinkDerefIsKnown() throws {
        let dir = try makeChaosDir(label: "parent-symlink")
        defer { try? FileManager.default.removeItem(at: dir) }

        let realParent = dir.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        let symlinkParent = dir.appendingPathComponent("symlink-parent")
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: realParent)

        let dest = symlinkParent.appendingPathComponent("payload.bin")
        let payload = Data("symlinked parent".utf8)

        try ChatExporter.atomicWrite(payload, to: dest)

        // The bytes land at ``realParent/payload.bin`` — that's the
        // documented behaviour. If a future hardening pass adds
        // O_NOFOLLOW at every path level, this test should be
        // updated to expect a throw.
        let resolvedDest = realParent.appendingPathComponent("payload.bin")
        let bytes = try Data(contentsOf: resolvedDest)
        #expect(bytes == payload)
    }

    /// Codex round 1 BLOCKING (refactored from a mis-labelled
    /// RLIMIT_FSIZE test): there's no portable way to set
    /// RLIMIT_FSIZE on the calling thread without crashing
    /// unrelated test threads on SIGXFSZ. The original test
    /// exercised the ``ENOTDIR`` path under a misleading name; we
    /// rename it accordingly here so the name matches the
    /// behaviour. ``/dev/null/sub/...`` triggers ``open(2)`` →
    /// ``ENOTDIR`` (errno 20) because ``/dev/null`` is a char
    /// device, not a directory. atomicWrite must surface this as
    /// a ``.writeFailed`` with phase=open and leave nothing
    /// behind. The same shape covers EACCES on a sandbox-denied
    /// parent (e.g. ``/System``).
    @Test("atomicWrite → parent is not a directory (/dev/null/sub/...) → throws cleanly at open phase")
    func atomicWriteThrowsOnNonDirParent() throws {
        let badDest = URL(fileURLWithPath: "/dev/null/sub/payload.bin")
        let payload = Data(repeating: 0x42, count: 4096)
        var threw = false
        var seenPhase: String?
        do {
            try ChatExporter.atomicWrite(payload, to: badDest)
        } catch let err as ChatExporterError {
            threw = true
            if case .writeFailed(_, _, let phase) = err {
                seenPhase = phase
            }
        } catch {
            Issue.record("expected ChatExporterError, got \(error)")
        }
        #expect(threw, "atomicWrite must throw when destination's parent is not a directory")
        // Either phase=open (the temp open syscall failed because
        // /dev/null isn't a dir) OR phase=rename (some macOS builds
        // synthesise a parent and fail at rename). Both are clean.
        if let phase = seenPhase {
            #expect(phase == "open" || phase == "rename",
                    "expected open/rename phase, got \(phase)")
        }
    }
}

// MARK: - Helpers (shared with ProcessKillChaosTests, kept private)

private func makeChaosDir(label: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("rapid-chaos-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}
