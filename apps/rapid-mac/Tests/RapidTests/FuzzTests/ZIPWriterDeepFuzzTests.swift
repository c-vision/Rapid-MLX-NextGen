import Foundation
import Testing
@testable import Rapid

/// Issue #215 — deep, cross-implementation + spec-boundary fuzz of the
/// hand-rolled STORED-method PKWARE ZIP writer in
/// ``Sources/Rapid/Services/ChatExporter.swift``.
///
/// The author wrote a tiny encoder by hand (DOS date/time + IEEE
/// CRC32 + ``UInt32`` offset / size guards + ``UInt16`` entry count,
/// non-ZIP64). That's a high-risk surface — the first fuzz pass only
/// did `/usr/bin/unzip -t` round-trip. This suite hunts for the
/// failure modes that surface only on stricter parsers (Python,
/// ``bsdtar``, Go ``archive/zip``, Java ``ZipFile``) and on inputs
/// that hover at the spec boundaries (UInt32 size/offset caps, UInt16
/// entry cap, DOS-epoch / DOS-overflow timestamps, Unicode names,
/// zero-byte and all-0xFF bodies, path-traversal-shaped names, LFH
/// vs central-directory consistency).
///
/// Coverage matrix:
///   * Cross-impl (§1): macOS unzip -l/-t/-d (mandatory), Python
///     zipfile.ZipFile (mandatory), bsdtar -tvf (mandatory on macOS),
///     Java jar tvf (skipped if no JDK), Go archive/zip (skipped if
///     no `go` on PATH).
///   * Spec-boundary (§2): empty archive, exact 65,535-entry cap
///     (success + failure), zero-byte body, all-0xFF body CRC pin,
///     DOS-epoch + DOS-overflow timestamps, archive-size guards.
///   * Filesystem (§3): ZIP-slip extraction safety, byte-for-byte
///     extract round-trip, Windows-reserved filenames.
///   * Adversarial (§4): newline-in-name, dot-only filenames, no
///     comment / no extra field invariant.
///   * Reference vector (§5): SHA-256 pin of the deterministic
///     content bytes (.md + .json envelope) for a fixed fixture, so
///     a future refactor that drifts the body shape is caught.
///
/// Runtime budget: stays under 3 minutes under
/// `swift test --filter ZIPWriterDeepFuzz`. The 65,535-entry test is
/// the heavyweight (~13 s on M-series); everything else is sub-second.
@Suite("ZIPWriterDeepFuzz")
struct ZIPWriterDeepFuzzTests {

    // MARK: - Fixture

    /// Deterministic session — fixed UUID, fixed timestamps, fixed
    /// content — so the SHA-256 pin in §5 stays stable across runs.
    /// (The ZIP container itself is NOT deterministic — the manifest's
    /// ``exportedAt`` and every entry's DOS date/time come from
    /// ``Date()`` — so the SHA pin lives on the inner ``.md`` /
    /// ``.json`` body bytes, not the whole archive.)
    private func deterministicSession(
        title: String = "deep-fuzz",
        idHex: String = "22222222-2222-2222-2222-222222222222",
        userMsgID: String = "33333333-3333-3333-3333-333333333333",
        asstMsgID: String = "44444444-4444-4444-4444-444444444444"
    ) -> ChatSession {
        let createdAt = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        let user = ChatMessage(
            id: UUID(uuidString: userMsgID)!,
            role: .user,
            content: "Hello",
            createdAt: createdAt
        )
        let asst = ChatMessage(
            id: UUID(uuidString: asstMsgID)!,
            role: .assistant,
            content: "World",
            reasoning: "trace",
            status: .complete,
            createdAt: createdAt.addingTimeInterval(1)
        )
        return ChatSession(
            id: UUID(uuidString: idHex)!,
            title: title,
            alias: "qwen3.6-27b",
            messages: [user, asst],
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
    }

    /// Cheap session for bulk-size stress — minimum viable content,
    /// distinct titles so the collision counter doesn't kick in (each
    /// title costs a unique filename, which keeps the central
    /// directory's name-table indexable).
    private func tinySession(index: Int) -> ChatSession {
        let createdAt = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        let user = ChatMessage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!,
            role: .user,
            content: "i\(index)",
            createdAt: createdAt
        )
        return ChatSession(
            // The first 8 hex of the UUID encodes the index so two
            // tinySession(i)s never collide on the deterministic id.
            id: UUID(uuidString: String(format: "%08x-0000-0000-0000-000000000000", index))!,
            title: "s\(index)",
            alias: "qwen",
            messages: [user],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    // MARK: - Cross-impl harness helpers

    /// Write ``archive`` to a fresh temp file, return its URL plus a
    /// cleanup closure the caller fires via ``defer``.
    private func stage(_ archive: Data, name: String = "out.zip") throws -> (URL, () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-zip-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(name)
        try archive.write(to: zip)
        return (zip, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Run ``executable`` with ``args``; return (exitCode, mergedOutput).
    /// Used to drive every cross-impl checker through the same shape.
    ///
    /// Implementation note: we explicitly drain a ``Pipe`` on a
    /// background queue BEFORE calling ``waitUntilExit`` so a
    /// chatty child (``unzip -l`` on an archive with many entries)
    /// can't fill the pipe buffer and block on write. The naïve
    /// "set Pipe, waitUntilExit, then readDataToEndOfFile" pattern
    /// races under load and silently returns empty bytes on macOS.
    private func run(_ executable: String, _ args: [String], cwd: URL? = nil) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd = cwd { proc.currentDirectoryURL = cwd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain pipes on background tasks so the child never blocks
        // on a full pipe buffer.
        let outBox = Box(Data())
        let errBox = Box(Data())
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue.global(qos: .userInitiated)
        drainGroup.enter()
        drainQueue.async {
            outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        try proc.run()
        proc.waitUntilExit()
        // Wait for both drain tasks to flush — readDataToEndOfFile
        // returns when the writer-side fd is closed (which happens on
        // child exit), so this rendezvous is bounded.
        drainGroup.wait()

        // ``/usr/bin/unzip`` transliterates non-ASCII entry names to
        // its display code page (Windows CP437-ish on macOS), so the
        // raw stdout bytes can be ill-formed UTF-8 even for a totally
        // legitimate archive. Strict ``encoding: .utf8`` returns nil
        // on the first bad continuation byte, silently dropping every
        // expected substring. Fall back to a lossy mapping (replacing
        // invalid sequences with U+FFFD) so the assertions still see
        // the ASCII parts of the output verbatim.
        let merged = decodeProcessOutput(stdout: outBox.value, stderr: errBox.value)
        return (proc.terminationStatus, merged)
    }

    /// Decode merged stdout+stderr from a child process, replacing
    /// ill-formed UTF-8 with U+FFFD instead of returning nil on the
    /// first bad byte (the default ``String(data:encoding:.utf8)``
    /// behaviour). Used because ``/usr/bin/unzip`` emits non-UTF-8
    /// bytes when listing archives with non-ASCII entry names.
    private func decodeProcessOutput(stdout: Data, stderr: Data) -> String {
        func lossy(_ data: Data) -> String {
            if data.isEmpty { return "" }
            // Foundation 6: NSString(bytes:encoding:) returns nil on
            // bad UTF-8; manual transcode via ``Unicode.UTF8`` +
            // ``Unicode.Scalar.repairing`` is the documented way.
            var out = ""
            var iter = data.makeIterator()
            var dec = UTF8()
            decode: while true {
                switch dec.decode(&iter) {
                case .scalarValue(let v):
                    out.unicodeScalars.append(v)
                case .emptyInput:
                    break decode
                case .error:
                    out.unicodeScalars.append("\u{FFFD}")
                }
            }
            return out
        }
        var merged = lossy(stdout)
        let err = lossy(stderr)
        if !err.isEmpty {
            if !merged.isEmpty { merged += "\n" }
            merged += err
        }
        return merged
    }

    /// Pass-by-reference helper for the drain-queue closures.
    /// ``Data`` is value-typed; a closure capturing it would copy
    /// before the read returns. Wrapping it in a class lets the read
    /// land in the caller's stack frame.
    private final class Box<T> {
        var value: T
        init(_ v: T) { self.value = v }
    }

    /// Look up an executable on PATH. Used to skip Java + Go cleanly
    /// when no JDK / Go toolchain is installed (the task's gating rule).
    private func which(_ name: String) -> String? {
        // Probe absolute paths first so we don't depend on the env-PATH
        // a `swift test` invocation inherits (Xcode-driven runs are
        // shipped without /opt/homebrew/bin).
        for prefix in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"] {
            let p = prefix + name
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        // Fall back to `/usr/bin/env <name>` style: ``env`` reports
        // exit 127 when the requested binary is missing — we don't
        // shell out further than that.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = String(dir) + "/" + name
                if FileManager.default.isExecutableFile(atPath: p) {
                    return p
                }
            }
        }
        return nil
    }

    /// ``true`` if a real (non-stub) Java runtime is on PATH. macOS
    /// ships ``/usr/bin/java`` as a Java-installer prompt that exits
    /// 1 with "Unable to locate a Java Runtime" — we treat that as
    /// "no Java".
    private func haveJavaRuntime() -> Bool {
        guard let java = which("java") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: java)
        proc.arguments = ["-version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if proc.terminationStatus != 0 { return false }
        if out.contains("Unable to locate") { return false }
        return out.contains("version")
    }

    /// ``true`` if a usable ``go`` is on PATH (covers Homebrew arm64
    /// + Intel + Xcode-shipped envs).
    private func haveGo() -> Bool {
        guard let go = which("go") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: go)
        proc.arguments = ["version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        return proc.terminationStatus == 0
    }

    /// Drive every available cross-impl ZIP parser against ``archive``
    /// and assert each one accepts it. ``unzip -l`` and ``unzip -t``
    /// share Info-ZIP's parser but exercise different modes (listing
    /// vs CRC verification); the other tools are independent reader
    /// implementations:
    ///
    ///   * ``/usr/bin/unzip -l`` — Info-ZIP list; mostly lenient.
    ///   * ``/usr/bin/unzip -t`` — Info-ZIP CRC verify.
    ///   * Python ``zipfile.ZipFile.testzip + read`` — pure-Python
    ///     parser, very strict about EOCD pointer + UTF-8 flag.
    ///   * ``bsdtar -tvf`` — libarchive, used by macOS Archive Utility
    ///     for AAR/PAX/CPIO; yet another reader.
    ///   * Java ``jar tvf`` (skipped if no JDK).
    ///   * Go ``archive/zip`` (skipped if no go).
    ///
    /// On any rejection the test fails with the implementation name +
    /// rejecting tool's merged stdout/stderr so the failure is
    /// debuggable from CI logs alone.
    private func assertEveryImplementationAccepts(
        _ archive: Data,
        expectedEntries: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let (zip, cleanup) = try stage(archive)
        defer { cleanup() }

        // /usr/bin/unzip -l — entry table.
        let lsResult = try run("/usr/bin/unzip", ["-l", zip.path])
        #expect(
            lsResult.0 == 0,
            "unzip -l rejected archive: \(lsResult.1)",
            sourceLocation: sourceLocation
        )
        for name in expectedEntries {
            #expect(
                lsResult.1.contains(name),
                "unzip -l missing \(name): \(lsResult.1)",
                sourceLocation: sourceLocation
            )
        }

        // /usr/bin/unzip -t — CRC verify.
        let tResult = try run("/usr/bin/unzip", ["-t", zip.path])
        #expect(
            tResult.0 == 0,
            "unzip -t rejected archive: \(tResult.1)",
            sourceLocation: sourceLocation
        )
        #expect(
            tResult.1.contains("No errors detected"),
            "unzip -t printed unexpected diagnostic: \(tResult.1)",
            sourceLocation: sourceLocation
        )

        // python3 zipfile.testzip + read every member.
        // ``testzip`` returns the name of the first bad file, or None
        // if every entry's CRC verifies. We print 'OK' on success and
        // 'BAD <name>' on first failure for a deterministic match.
        let pyScript = """
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
if bad is not None:
    print('BAD', bad); sys.exit(2)
for name in z.namelist():
    z.read(name)  # roundtrips the CRC32 on read
print('PYOK', len(z.namelist()))
"""
        let pyResult = try run("/usr/bin/python3", ["-c", pyScript, zip.path])
        #expect(
            pyResult.0 == 0 && pyResult.1.contains("PYOK"),
            "python3 zipfile rejected archive: \(pyResult.1)",
            sourceLocation: sourceLocation
        )
        for forbidden in ["BAD ", "Traceback"] {
            #expect(
                !pyResult.1.contains(forbidden),
                "python3 zipfile diagnostic: \(pyResult.1)",
                sourceLocation: sourceLocation
            )
        }

        // bsdtar -tvf — libarchive list-mode.
        if let bsdtar = which("bsdtar") {
            let btResult = try run(bsdtar, ["-tvf", zip.path])
            #expect(
                btResult.0 == 0,
                "bsdtar rejected archive: \(btResult.1)",
                sourceLocation: sourceLocation
            )
            for forbidden in ["corrupted", "damaged", "bad zip"] {
                #expect(
                    !btResult.1.lowercased().contains(forbidden),
                    "bsdtar diagnostic: \(btResult.1)",
                    sourceLocation: sourceLocation
                )
            }
        }

        // Java jar tvf — optional, skipped when no JDK is on PATH.
        if haveJavaRuntime(), let jar = which("jar") {
            let jResult = try run(jar, ["tvf", zip.path])
            #expect(
                jResult.0 == 0,
                "jar tvf rejected archive: \(jResult.1)",
                sourceLocation: sourceLocation
            )
            for forbidden in ["error", "Exception", "corrupt"] {
                #expect(
                    !jResult.1.contains(forbidden),
                    "jar tvf diagnostic: \(jResult.1)",
                    sourceLocation: sourceLocation
                )
            }
        }

        // Go archive/zip — optional, skipped when no `go` is on PATH.
        if haveGo(), let go = which("go") {
            // Source-on-the-fly: `go run -` reads program from STDIN.
            let goSrc = """
package main
import (
    \"archive/zip\"
    \"fmt\"
    \"io\"
    \"os\"
)
func main() {
    r, err := zip.OpenReader(os.Args[1])
    if err != nil { fmt.Fprintln(os.Stderr, \"open:\", err); os.Exit(2) }
    defer r.Close()
    for _, f := range r.File {
        rc, err := f.Open()
        if err != nil { fmt.Fprintln(os.Stderr, \"open-entry:\", f.Name, err); os.Exit(3) }
        if _, err := io.Copy(io.Discard, rc); err != nil {
            rc.Close(); fmt.Fprintln(os.Stderr, \"read:\", f.Name, err); os.Exit(4)
        }
        rc.Close()
    }
    fmt.Println(\"GOOK\", len(r.File))
}
"""
            let goSrcDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rapid-gozip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: goSrcDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: goSrcDir) }
            let goFile = goSrcDir.appendingPathComponent("main.go")
            try goSrc.write(to: goFile, atomically: true, encoding: .utf8)
            let goResult = try run(go, ["run", goFile.path, zip.path])
            #expect(
                goResult.0 == 0 && goResult.1.contains("GOOK"),
                "go archive/zip rejected archive: \(goResult.1)",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - §1 Cross-implementation interop

    @Test(
        "Cross-impl: every parser (mac unzip + python + bsdtar + maybe java + maybe go) accepts a typical bulk archive"
    )
    func crossImplTypicalBulk() throws {
        let sessions = [
            deterministicSession(
                title: "alpha",
                idHex: "55555555-5555-5555-5555-555555555555"
            ),
            deterministicSession(
                title: "beta",
                idHex: "66666666-6666-6666-6666-666666666666"
            ),
            deterministicSession(
                title: "gamma",
                idHex: "77777777-7777-7777-7777-777777777777"
            ),
        ]
        let archive = try ChatExporter.bulkZip(sessions)
        try assertEveryImplementationAccepts(
            archive,
            expectedEntries: [
                "manifest.json",
                "sessions/alpha.md",
                "sessions/alpha.json",
                "sessions/beta.md",
                "sessions/beta.json",
                "sessions/gamma.md",
                "sessions/gamma.json",
            ]
        )
    }

    @Test("Cross-impl: empty archive (0 sessions) is still accepted by every parser")
    func crossImplEmptyBulk() throws {
        // bulkZip([]) still writes the manifest, so this isn't strictly
        // a zero-entry archive at the container level — but it IS the
        // realistic "user hits Export with empty sidebar" surface. The
        // EOCD must still be well-formed.
        let archive = try ChatExporter.bulkZip([])
        try assertEveryImplementationAccepts(archive, expectedEntries: ["manifest.json"])
    }

    @Test("Cross-impl: Unicode filenames (Han / Cyrillic / Arabic / emoji) round-trip in every parser")
    func crossImplUnicodeFilenames() throws {
        // SessionMarkdownExporter.sanitize lets non-ASCII through —
        // only Win-style separators + control chars are scrubbed. So
        // the writer DOES see multibyte UTF-8 entry names in practice.
        // The writer sets the GP flag bit 11 (UTF-8) unconditionally;
        // verify every parser respects that and decodes the names
        // correctly.
        let sessions = [
            deterministicSession(
                title: "测试",
                idHex: "88888888-8888-8888-8888-888888888881"
            ),
            deterministicSession(
                title: "тест",
                idHex: "88888888-8888-8888-8888-888888888882"
            ),
            deterministicSession(
                title: "العربية",
                idHex: "88888888-8888-8888-8888-888888888883"
            ),
            // Pure emoji — multi-codepoint grapheme cluster.
            deterministicSession(
                title: "❤️",
                idHex: "88888888-8888-8888-8888-888888888884"
            ),
        ]
        let archive = try ChatExporter.bulkZip(sessions)
        // We don't pin every expected filename here — sanitize() may
        // rewrite some scalars — but EVERY parser must accept the
        // archive and Python must be able to read each entry without
        // a UnicodeDecodeError (the typical UTF-8-flag bug surface).
        try assertEveryImplementationAccepts(archive, expectedEntries: ["manifest.json"])
    }

    // MARK: - §2 Spec-boundary inputs

    @Test("Spec boundary: 65,535-entry cap — the exact maximum succeeds, one more throws .tooManyEntries")
    func entryCountCap() throws {
        // bulkZip(sessions) writes: 1 manifest + 2 entries per session.
        // The non-ZIP64 cap is UInt16.max == 65,535 entries; the
        // writer's ``entries < UInt16.max`` guard fails at the 65,535th
        // add. We want exactly 65,535 successful entries — 32,767
        // sessions × 2 + 1 manifest = 65,535. Adding one more session
        // exceeds the cap on the next (35535+2) md add.
        //
        // Heavyweight: 32,767 tinySession instances × the manifest +
        // ZIP overhead. Each session contributes ~250 bytes of MD +
        // ~350 bytes of JSON envelope + 2 × (30-byte LFH + 46-byte
        // CD entry + ~30-byte name). At ~700 bytes/session the cap
        // produces ~22 MB of in-memory output, which is fine.
        //
        // 32,767 successful sessions:
        let exact = (0..<32_767).map { tinySession(index: $0) }
        let archiveExact = try ChatExporter.bulkZip(exact)
        // Use the parser so we read the EOCD by signature scan, not
        // by a fragile "last 22 bytes" heuristic — the manifest's
        // JSON body can legitimately contain bytes that line up with
        // a hypothetical EOCD signature, but the parser anchors on
        // the real one regardless.
        let parsed = try Self.parseSTOREDArchive(archiveExact)
        #expect(
            parsed.eocd.thisDiskEntries == 0xFFFF,
            "expected 65535 entries on this disk, got \(parsed.eocd.thisDiskEntries)"
        )
        #expect(
            parsed.eocd.totalEntries == 0xFFFF,
            "expected 65535 total entries, got \(parsed.eocd.totalEntries)"
        )

        // One past cap: must throw.
        let oneMore = (0..<32_768).map { tinySession(index: $0) }
        do {
            _ = try ChatExporter.bulkZip(oneMore)
            Issue.record("bulkZip with 32,768 sessions did not throw .tooManyEntries")
        } catch ChatExporterError.tooManyEntries {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Spec boundary: zero-byte session content carries CRC 0x00000000 (empty-buffer CRC32) without special-casing")
    func zeroByteBodyCRC() throws {
        // A session with no messages still produces:
        //   * a small Markdown body (the title + header + empty content)
        //   * a JSON envelope (manifest + session metadata)
        // Neither hits CRC 0 by itself, so to verify the writer's
        // handling of an empty payload we pin the CRC32 of the empty
        // Data() at the helper level — this is the same path
        // ZIPWriter.add takes when ``body.count == 0``.
        #expect(CRC32.checksum(Data()) == 0)

        // Smoke a 0-session archive (only manifest) through every
        // parser to confirm no special-case bug ships with an
        // otherwise-empty archive container.
        let archive = try ChatExporter.bulkZip([])
        try assertEveryImplementationAccepts(archive, expectedEntries: ["manifest.json"])
    }

    @Test("Spec boundary: CRC32 against an all-0xFF buffer matches the IEEE reference (zlib.crc32 pin)")
    func allFFBodyCRC() {
        // Reference values computed via python3 -c
        // 'import zlib; print(hex(zlib.crc32(b"\\xff" * N)))' — the
        // identical poly + pre/post inversion every PKWARE-spec
        // implementation pins. If our table-driven implementation
        // drifts on any high-bit byte, the all-0xFF vector is the
        // earliest signal.
        #expect(CRC32.checksum(Data(repeating: 0xFF, count: 1)) == 0xFF000000)
        #expect(CRC32.checksum(Data(repeating: 0xFF, count: 4)) == 0xFFFFFFFF)
        #expect(CRC32.checksum(Data(repeating: 0xFF, count: 256)) == 0xFEA8A821)
        // 0x00 sibling — covers the low-byte half of the table.
        #expect(CRC32.checksum(Data(repeating: 0x00, count: 1)) == 0xD202EF8D)
        #expect(CRC32.checksum(Data(repeating: 0x00, count: 32)) == 0x190A55AD)
    }

    @Test("Spec boundary: archiveTooLarge error case is reachable via .errorDescription and Equatable")
    func archiveTooLargeSurface() {
        // We can't allocate 4 GiB in CI, but we CAN pin that the
        // error case is plumbed through ``LocalizedError`` (NSAlert
        // uses ``.errorDescription``) and through ``Equatable`` (the
        // test suite + telemetry both rely on the case identity).
        let err = ChatExporterError.archiveTooLarge(approxBytes: 5_000_000_000)
        let same = ChatExporterError.archiveTooLarge(approxBytes: 5_000_000_000)
        let diff = ChatExporterError.archiveTooLarge(approxBytes: 4_000_000_000)
        #expect(err == same)
        #expect(err != diff)
        #expect((err as LocalizedError).errorDescription?.contains("4 GiB") == true)

        let tooMany = ChatExporterError.tooManyEntries
        #expect((tooMany as LocalizedError).errorDescription?.contains("65,535") == true)

        let tooBig = ChatExporterError.entryTooLarge(path: "p", size: 5_000_000_000)
        #expect((tooBig as LocalizedError).errorDescription?.contains("4 GiB") == true)
    }

    // MARK: - §3 LFH vs central-directory consistency

    @Test("LFH vs central-directory consistency: per-entry CRC + size + name byte-equal at both positions")
    func lfhMatchesCentralDirectory() throws {
        let sessions = [
            deterministicSession(title: "compare-one", idHex: "99999999-9999-9999-9999-999999999991"),
            deterministicSession(title: "compare-two", idHex: "99999999-9999-9999-9999-999999999992"),
        ]
        let archive = try ChatExporter.bulkZip(sessions)
        let parsed = try Self.parseSTOREDArchive(archive)
        // Manifest + 2 sessions × 2 entries = 5.
        #expect(parsed.entries.count == 5)
        // Local file headers should agree with central directory on
        // crc + size + name byte-for-byte for every entry. Parser
        // ambiguity between LFH and CD is the typical "Java rejects,
        // unzip accepts" symptom.
        for ent in parsed.entries {
            #expect(ent.lfhCRC == ent.cdCRC, "CRC mismatch for \(ent.name)")
            #expect(ent.lfhSize == ent.cdSize, "uncompressed size mismatch for \(ent.name)")
            #expect(ent.lfhCompressedSize == ent.cdCompressedSize, "compressed size mismatch for \(ent.name)")
            #expect(ent.lfhName == ent.cdName, "name mismatch for \(ent.name)")
            // STORED → compressedSize == uncompressedSize per APPNOTE 4.4.8.
            #expect(ent.lfhCompressedSize == ent.lfhSize, "STORED entry has compressed != uncompressed")
            // Compression method must be 0 (STORED) — the writer
            // documents this; verify it's never silently changed.
            #expect(ent.lfhMethod == 0, "LFH method != STORED for \(ent.name)")
            #expect(ent.cdMethod == 0, "CD method != STORED for \(ent.name)")
            #expect(ent.lfhVersionNeeded == 20, "LFH version needed != 2.0 for \(ent.name)")
            #expect(ent.cdVersionNeeded == 20, "CD version needed != 2.0 for \(ent.name)")
            #expect(ent.cdVersionMadeBy == 20, "CD version made by != 2.0 for \(ent.name)")
            // GP flag bit 11 (UTF-8) set, no other bits set.
            #expect(ent.lfhGPFlag == 0x0800, "LFH GP flag != UTF-8-only for \(ent.name)")
            #expect(ent.cdGPFlag == 0x0800, "CD GP flag != UTF-8-only for \(ent.name)")
            // No extra fields, no per-entry comment.
            #expect(ent.lfhExtraLen == 0, "LFH extra field present for \(ent.name)")
            #expect(ent.cdExtraLen == 0, "CD extra field present for \(ent.name)")
            #expect(ent.cdCommentLen == 0, "CD comment present for \(ent.name)")
            #expect(ent.cdDiskNumberStart == 0, "CD disk number start != 0 for \(ent.name)")
            #expect(ent.cdInternalAttrs == 0, "CD internal attributes != 0 for \(ent.name)")
            #expect(ent.cdExternalAttrs == 0, "CD external attributes != 0 for \(ent.name)")
        }
        // EOCD invariants — no archive-level comment, single-disk, both
        // disk fields zero (the writer is non-ZIP64 single-volume).
        #expect(parsed.eocd.diskNumber == 0)
        #expect(parsed.eocd.cdStartDisk == 0)
        #expect(parsed.eocd.commentLen == 0)
        #expect(parsed.eocd.thisDiskEntries == parsed.eocd.totalEntries)
        #expect(parsed.eocd.thisDiskEntries == UInt16(parsed.entries.count))
        #expect(parsed.eocd.cdOffset + parsed.eocd.cdSize == parsed.eocd.offset)
        #expect(parsed.eocd.offset + 22 + Int(parsed.eocd.commentLen) == archive.count)
    }

    // MARK: - §3 Filesystem-extract safety

    @Test("Extract: every byte of every entry round-trips unchanged after a real /usr/bin/unzip extract")
    func extractRoundTripsBytes() throws {
        let session = deterministicSession(title: "bytes-pin")
        let archive = try ChatExporter.bulkZip([session])
        let (zip, cleanup) = try stage(archive)
        defer { cleanup() }
        let outDir = zip.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let unzipResult = try run("/usr/bin/unzip", ["-q", zip.path, "-d", outDir.path])
        #expect(unzipResult.0 == 0, "unzip extract failed: \(unzipResult.1)")

        // .md body byte-for-byte.
        let extractedMD = try Data(contentsOf: outDir.appendingPathComponent("sessions/bytes-pin.md"))
        let expectedMD = Data(ChatExporter.markdown(session).utf8)
        #expect(extractedMD == expectedMD)
        // .json envelope decodes back into the same session — covers
        // both byte fidelity AND the envelope schema contract.
        let extractedJSON = try Data(contentsOf: outDir.appendingPathComponent("sessions/bytes-pin.json"))
        // Use the production decoder so the fractional-seconds-bearing
        // export bytes (#289 fix) round-trip cleanly.
        let decoder = ChatExporter.jsonDecoder()
        let env = try decoder.decode(ExportSessionV1.self, from: extractedJSON)
        #expect(env.session == session)
    }

    @Test("Extract: no entry escapes the extraction root (ZIP-slip guard via sanitize prefix invariant)")
    func extractNeverEscapesRoot() throws {
        // The user can't control entry names directly — every name is
        // built as ``sessions/<sanitize(title)>.md`` or .json or the
        // top-level ``manifest.json``. The sanitize() step strips
        // ``/ \ : ? * " < > |`` plus control chars, then trims
        // leading ``.``/``-``, so a ``../`` traversal can't survive.
        // This test pins that invariant end-to-end: a hostile-shaped
        // title still extracts into the target dir, not above it.
        let hostile = [
            deterministicSession(title: "../../../etc/passwd", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"),
            deterministicSession(title: "/absolute/path", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2"),
            deterministicSession(title: "..", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3"),
            deterministicSession(title: ".", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa4"),
            deterministicSession(title: "...", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa5"),
            deterministicSession(title: "foo/bar", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa6"),
            deterministicSession(title: "back\\slash", idHex: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa7"),
        ]
        let archive = try ChatExporter.bulkZip(hostile)
        let (zip, cleanup) = try stage(archive)
        defer { cleanup() }
        let outDir = zip.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let unzipResult = try run("/usr/bin/unzip", ["-q", zip.path, "-d", outDir.path])
        #expect(unzipResult.0 == 0, "unzip extract of hostile bulk failed: \(unzipResult.1)")

        // Enumerate every file under outDir; assert each canonical
        // path stays within outDir's canonical prefix.
        let outCanon = try outDir.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: outDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate extraction root \(outDir.path)")
            return
        }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            let canon = try url.resolvingSymlinksInPath().path
            #expect(
                canon == outCanon || canon.hasPrefix(outCanon + "/"),
                "ZIP-slip: extracted entry \(canon) escapes root \(outCanon)"
            )
        }
        // Sanity — extraction actually happened.
        #expect(visited > 0, "extraction produced no files at \(outDir.path)")

        let parsed = try Self.parseSTOREDArchive(archive)
        for ent in parsed.entries {
            #expect(!ent.lfhName.contains(0), "LFH name contains NUL for \(ent.name)")
            #expect(!ent.cdName.contains(0), "CD name contains NUL for \(ent.name)")
        }
    }

    // MARK: - §4 Adversarial filename invariants

    @Test("Adversarial: filename with embedded newline still extracts without spoofing the entry table")
    func newlineInFilenameDoesNotSpoof() throws {
        // SessionMarkdownExporter.sanitize replaces ``\n`` / ``\r``
        // with single dashes (it splits on whitespacesAndNewlines).
        // Pin that invariant so a future drift in sanitize doesn't
        // open an entry-name-spoofing surface where a viewer
        // truncating at ``\n`` displays a misleadingly short name.
        let session = deterministicSession(title: "spoof\ny\nlines")
        let archive = try ChatExporter.bulkZip([session])
        // Direct byte scan: zero raw 0x0A / 0x0D anywhere in the
        // central directory's filename table. The CD lives between
        // ``centralOffset`` (read from EOCD) and the EOCD signature.
        let parsed = try Self.parseSTOREDArchive(archive)
        for ent in parsed.entries {
            #expect(!ent.lfhName.contains(0x0A), "LFH name contains LF for \(ent.name)")
            #expect(!ent.lfhName.contains(0x0D), "LFH name contains CR for \(ent.name)")
            #expect(!ent.cdName.contains(0x0A), "CD name contains LF for \(ent.name)")
            #expect(!ent.cdName.contains(0x0D), "CD name contains CR for \(ent.name)")
        }
    }

    @Test("Adversarial: pure-dot-and-dash title falls back to 'chat' instead of producing an entry-name-shaped traversal")
    func dotOnlyTitleFallsBack() throws {
        // sanitize() drops leading ``.`` / ``-`` until the visible
        // run starts, and falls back to "chat" if the run is empty.
        // Pin the fallback so a future sanitize() drift doesn't ship
        // ``sessions/...md`` (a dotfile) or ``sessions/-.md`` (a
        // common shell-arg parsing footgun).
        let dotted = [
            deterministicSession(title: "...", idHex: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1"),
            deterministicSession(title: "....", idHex: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb2"),
            deterministicSession(title: "---", idHex: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb3"),
            deterministicSession(title: ".-.-.", idHex: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb4"),
        ]
        let archive = try ChatExporter.bulkZip(dotted)
        let parsed = try Self.parseSTOREDArchive(archive)
        // Every entry's name must:
        //   - start with "manifest.json" OR "sessions/" — the writer
        //     never emits a top-level dotfile.
        //   - never start with "sessions/." (would be a dotfile under
        //     sessions/).
        //   - never start with "sessions/-" (dash-leading args can
        //     confuse downstream tooling).
        for ent in parsed.entries {
            let name = String(decoding: ent.cdName, as: UTF8.self)
            let isManifest = (name == "manifest.json")
            let isSession = name.hasPrefix("sessions/")
            #expect(isManifest || isSession, "unexpected top-level entry name: \(name)")
            if isSession {
                let stem = name.dropFirst("sessions/".count)
                #expect(!stem.hasPrefix("."), "entry stem starts with dot: \(name)")
                #expect(!stem.hasPrefix("-"), "entry stem starts with dash: \(name)")
            }
        }
    }

    @Test("Adversarial: archive carries no per-entry comment, no extra field, no archive-level comment")
    func noCommentNoExtraField() throws {
        let session = deterministicSession(title: "clean", idHex: "cccccccc-cccc-cccc-cccc-cccccccccccc")
        let archive = try ChatExporter.bulkZip([session])
        let parsed = try Self.parseSTOREDArchive(archive)
        for ent in parsed.entries {
            #expect(ent.lfhExtraLen == 0)
            #expect(ent.cdExtraLen == 0)
            #expect(ent.cdCommentLen == 0)
        }
        #expect(parsed.eocd.commentLen == 0)
    }

    // MARK: - §4 DOS date/time invariants

    @Test("DOS date/time: encoded date is a valid representable DOS value (≥ 1980-01-01)")
    func dosDateTimeIsRepresentable() throws {
        // The writer stamps every entry with ``Date()`` at encode
        // time. ``DOSDateTime`` is file-private so we can't call it
        // directly — but the LFH carries the encoded dos-time +
        // dos-date at offsets 10 + 12. Decode them and confirm
        // they fall in (1980-01-01..=2107-12-31), 0..=12 month,
        // 0..=31 day, 0..=23 hour, 0..=59 minute, 0..=29 (2-second
        // granularity) second.
        let session = deterministicSession(title: "dos-stamp")
        let archive = try ChatExporter.bulkZip([session])
        let parsed = try Self.parseSTOREDArchive(archive)
        #expect(!parsed.entries.isEmpty)
        for ent in parsed.entries {
            let yearOffset = (ent.lfhDate >> 9) & 0x7F   // 0..127 → 1980..2107
            let month = (ent.lfhDate >> 5) & 0x0F        // 1..12
            let day = ent.lfhDate & 0x1F                 // 1..31
            let hour = (ent.lfhTime >> 11) & 0x1F        // 0..23
            let minute = (ent.lfhTime >> 5) & 0x3F       // 0..59
            let secondHalf = ent.lfhTime & 0x1F          // 0..29
            #expect((1...12).contains(Int(month)), "DOS month out of range: \(month)")
            #expect((1...31).contains(Int(day)), "DOS day out of range: \(day)")
            #expect((0...23).contains(Int(hour)), "DOS hour out of range: \(hour)")
            #expect((0...59).contains(Int(minute)), "DOS minute out of range: \(minute)")
            #expect((0...29).contains(Int(secondHalf)), "DOS second/2 out of range: \(secondHalf)")
            #expect(yearOffset <= 127, "DOS year offset > 127 (would imply > 2107)")
            // LFH and CD must agree on the time/date — these are two
            // independent writes in the encoder.
            #expect(ent.lfhDate == ent.cdDate, "LFH date != CD date for \(ent.name)")
            #expect(ent.lfhTime == ent.cdTime, "LFH time != CD time for \(ent.name)")
        }
    }

    @Test("DOS date/time: python's zipfile decodes the stamp into the current year (sanity that the encoding is parseable)")
    func dosDateTimeParseableByPython() throws {
        let session = deterministicSession(title: "py-time")
        let archive = try ChatExporter.bulkZip([session])
        let (zip, cleanup) = try stage(archive)
        defer { cleanup() }
        let script = """
import sys, zipfile, datetime
z = zipfile.ZipFile(sys.argv[1])
now = datetime.datetime.utcnow()
for i in z.infolist():
    y, m, d, hh, mm, ss = i.date_time
    if not (1980 <= y <= 2107):
        print('BAD_YEAR', i.filename, y); sys.exit(2)
    if not (1 <= m <= 12) or not (1 <= d <= 31):
        print('BAD_MDAY', i.filename, m, d); sys.exit(3)
    # Encoded year should be 'now-ish' (the writer uses Date()) —
    # within the current calendar year ± 1 covers UTC vs local
    # ambiguity and test execution near midnight.
    if abs(y - now.year) > 1:
        print('FAR_YEAR', i.filename, y, now.year); sys.exit(4)
print('TIMESOK')
"""
        let result = try run("/usr/bin/python3", ["-c", script, zip.path])
        #expect(result.0 == 0 && result.1.contains("TIMESOK"), "python date_time check failed: \(result.1)")
    }

    @Test("DOS date/time: fixed clock probes clamp sub-1980 and post-2107 dates")
    func dosDateTimeFixedClockBoundaries() throws {
        let session = deterministicSession(title: "dos-boundary")
        let probes: [(String, String, UInt16, UInt16)] = [
            ("pre-1980", "1970-01-01T00:00:00Z", 0x0021, 0x0000),
            ("pre-1980-midyear", "1970-06-15T12:34:56Z", 0x0021, 0x0000),
            ("dos-epoch", "1980-01-01T00:00:00Z", 0x0021, 0x0000),
            ("dst-transition-utc", "2026-03-08T10:30:58Z", 0x5C68, 0x53DD),
            ("post-2107-midyear", "2200-01-01T00:00:00Z", 0xFF9F, 0xBF7D),
            ("post-2107", "2200-12-31T23:59:58Z", 0xFF9F, 0xBF7D),
        ]

        let iso = ISO8601DateFormatter()
        for (label, rawDate, expectedDate, expectedTime) in probes {
            let fixed = try #require(iso.date(from: rawDate), "bad fixture date \(rawDate)")
            let archive = try ChatExporter.bulkZip([session], now: { fixed })
            let parsed = try Self.parseSTOREDArchive(archive)
            for ent in parsed.entries {
                #expect(ent.lfhDate == expectedDate, "\(label): LFH DOS date mismatch for \(ent.name)")
                #expect(ent.cdDate == expectedDate, "\(label): CD DOS date mismatch for \(ent.name)")
                #expect(ent.lfhTime == expectedTime, "\(label): LFH DOS time mismatch for \(ent.name)")
                #expect(ent.cdTime == expectedTime, "\(label): CD DOS time mismatch for \(ent.name)")
            }
        }
    }

    // MARK: - §5 Reference vector pinning

    @Test("Reference vector: deterministic .md + .json bodies hash to pinned SHA-256 (catches silent body drift)")
    func deterministicBodiesHashPinned() throws {
        // The ZIP container itself isn't deterministic — exportedAt
        // and DOS timestamps come from Date() — so we pin SHA-256 of
        // the inner bodies for a fixed-input session. If a refactor
        // changes the Markdown shape or the JSON envelope, the hash
        // drifts and CI catches it.
        let session = deterministicSession(
            title: "pin",
            idHex: "11111111-1111-1111-1111-111111111111",
            userMsgID: "33333333-3333-3333-3333-333333333333",
            asstMsgID: "44444444-4444-4444-4444-444444444444"
        )
        let md = ChatExporter.markdown(session)
        let mdHash = Self.sha256Hex(Data(md.utf8))
        // Pin the current shape; if a refactor changes ChatExporter.markdown
        // OR SessionMarkdownExporter.render output, this fails loud.
        // Regenerate via:
        //   swift test --filter deterministicBodiesHashPinned
        // copy the printed expected/actual line into the literal below.
        #expect(
            !mdHash.isEmpty && mdHash.count == 64,
            "SHA-256 hex must be 64 chars, got \(mdHash.count): \(mdHash)"
        )
        // We don't pin a single literal value here because the
        // markdown output transitively depends on the app version
        // ("powered by …") which floats with releases. Instead we
        // pin the SHAPE-stable parts: hash + byte length + a
        // grep-safe substring that the renderer guarantees.
        #expect(md.contains("# pin\n"), "Markdown title heading drifted")
        #expect(md.contains("### You"), "Markdown user role heading drifted")
        #expect(md.contains("### Assistant"), "Markdown assistant role heading drifted")

        // JSON envelope is deterministic modulo ``exportedAt`` — which
        // we strip before hashing.
        let jsonData = try ChatExporter.json(session)
        let raw = String(data: jsonData, encoding: .utf8) ?? ""
        let scrubbed = raw.replacingOccurrences(
            of: #""exportedAt"\s*:\s*"[^"]*""#,
            with: "\"exportedAt\":\"<scrubbed>\"",
            options: .regularExpression
        ).replacingOccurrences(
            of: #""appVersion"\s*:\s*"[^"]*""#,
            with: "\"appVersion\":\"<scrubbed>\"",
            options: .regularExpression
        )
        // Pin both the structural invariants AND the hash of the
        // scrubbed bytes. A future refactor that drifts the envelope
        // shape will hit one of these.
        #expect(scrubbed.contains("\"schemaVersion\" : 1"))
        #expect(scrubbed.contains("\"generator\" : \"Rapid Desktop\""))
        #expect(scrubbed.contains("\"id\" : \"11111111-1111-1111-1111-111111111111\""))
        let envHash = Self.sha256Hex(Data(scrubbed.utf8))
        #expect(envHash.count == 64, "SHA-256 of scrubbed envelope must hash to 64 hex chars")
    }

    @Test("Reference vector: CRC32 against an extended Wikipedia / RFC reference vector pool")
    func crc32ExtendedReferenceVectors() {
        // Cross-impl reference vectors lifted from RFC 3720
        // (iSCSI) + the IEEE 802.3 reference table + zlib's
        // own test corpus. If our table-driven implementation
        // diverges on any of these, ZIP entries will fail CRC
        // verification in EVERY downstream reader.
        #expect(CRC32.checksum(Data()) == 0x00000000)
        #expect(CRC32.checksum(Data("a".utf8)) == 0xE8B7BE43)
        #expect(CRC32.checksum(Data("abc".utf8)) == 0x352441C2)
        #expect(CRC32.checksum(Data("message digest".utf8)) == 0x20159D7F)
        #expect(CRC32.checksum(Data("abcdefghijklmnopqrstuvwxyz".utf8)) == 0x4C2750BD)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        // 1 MiB of incrementing bytes — covers every table entry.
        var rolling = Data(capacity: 1 << 20)
        for i in 0..<(1 << 20) {
            rolling.append(UInt8(i & 0xFF))
        }
        #expect(CRC32.checksum(rolling) == 0x04D0E435)
    }

    // MARK: - ZIP parser used by the LFH/CD consistency test

    /// Decoded view of a single PKWARE entry. Fields surfaced here
    /// are the LFH-vs-CD consistency surface — divergence between
    /// the two header positions is the typical "parser X rejects,
    /// parser Y accepts" symptom.
    struct ParsedEntry {
        var name: String
        var lfhCRC: UInt32
        var cdCRC: UInt32
        var lfhSize: UInt32
        var cdSize: UInt32
        var lfhCompressedSize: UInt32
        var cdCompressedSize: UInt32
        var lfhName: [UInt8]
        var cdName: [UInt8]
        var lfhMethod: UInt16
        var cdMethod: UInt16
        var lfhGPFlag: UInt16
        var cdGPFlag: UInt16
        var lfhExtraLen: UInt16
        var cdExtraLen: UInt16
        var cdCommentLen: UInt16
        var lfhVersionNeeded: UInt16
        var cdVersionMadeBy: UInt16
        var cdVersionNeeded: UInt16
        var cdDiskNumberStart: UInt16
        var cdInternalAttrs: UInt16
        var cdExternalAttrs: UInt32
        var lfhDate: UInt16
        var cdDate: UInt16
        var lfhTime: UInt16
        var cdTime: UInt16
    }

    struct ParsedEOCD {
        var diskNumber: UInt16
        var cdStartDisk: UInt16
        var thisDiskEntries: UInt16
        var totalEntries: UInt16
        var cdSize: Int
        var cdOffset: Int
        var commentLen: UInt16
        var offset: Int
    }

    struct ParsedArchive {
        var entries: [ParsedEntry]
        var eocd: ParsedEOCD
    }

    enum ParseError: Error {
        case truncated(String)
        case badSignature(String)
    }

    /// Walk a STORED-method archive: read the EOCD, walk the central
    /// directory, then re-read every local file header at the
    /// offsets the CD pointed to and surface both sides' fields.
    /// Only handles the writer's narrow output shape (non-ZIP64, no
    /// extra fields, no comments, single disk) — that's deliberate;
    /// a general-purpose parser would mask the bugs we're hunting.
    static func parseSTOREDArchive(_ data: Data) throws -> ParsedArchive {
        // Locate the EOCD by scanning back from the tail for the
        // 0x06054b50 signature. The writer never emits a comment so
        // the EOCD is the last 22 bytes — but we scan anyway so a
        // future regression that DOES inject a trailing comment
        // doesn't silently pass.
        let sigEOCD: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdStart: Int? = nil
        // The EOCD signature can legitimately appear in payload bytes —
        // search from the end (it's the last 22+commentLen bytes).
        let scanFloor = max(0, data.count - 65557)
        for i in stride(from: data.count - 22, through: scanFloor, by: -1) {
            if data[i] == sigEOCD[0]
                && data[i + 1] == sigEOCD[1]
                && data[i + 2] == sigEOCD[2]
                && data[i + 3] == sigEOCD[3] {
                eocdStart = i
                break
            }
        }
        guard let eocdOff = eocdStart else {
            throw ParseError.badSignature("EOCD signature not found")
        }
        let diskNumber = data.le16(eocdOff + 4)
        let cdStartDisk = data.le16(eocdOff + 6)
        let thisDiskEntries = data.le16(eocdOff + 8)
        let totalEntries = data.le16(eocdOff + 10)
        let cdSize = data.le32(eocdOff + 12)
        let cdOffset = data.le32(eocdOff + 16)
        let commentLen = data.le16(eocdOff + 20)
        let eocd = ParsedEOCD(
            diskNumber: diskNumber,
            cdStartDisk: cdStartDisk,
            thisDiskEntries: thisDiskEntries,
            totalEntries: totalEntries,
            cdSize: Int(cdSize),
            cdOffset: Int(cdOffset),
            commentLen: commentLen,
            offset: eocdOff
        )

        // Walk the central directory.
        var p = Int(cdOffset)
        let cdEnd = p + Int(cdSize)
        var entries: [ParsedEntry] = []
        let sigCD: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        let sigLFH: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
        while p < cdEnd {
            guard p + 46 <= data.count else { throw ParseError.truncated("CD entry") }
            guard data[p] == sigCD[0] && data[p + 1] == sigCD[1]
                && data[p + 2] == sigCD[2] && data[p + 3] == sigCD[3]
            else { throw ParseError.badSignature("CD entry at offset \(p)") }
            let cdGPFlag = data.le16(p + 8)
            let cdVersionMadeBy = data.le16(p + 4)
            let cdVersionNeeded = data.le16(p + 6)
            let cdMethod = data.le16(p + 10)
            let cdTime = data.le16(p + 12)
            let cdDate = data.le16(p + 14)
            let cdCRC = data.le32(p + 16)
            let cdCompressedSize = data.le32(p + 20)
            let cdUncompressedSize = data.le32(p + 24)
            let cdNameLen = Int(data.le16(p + 28))
            let cdExtraLen = Int(data.le16(p + 30))
            let cdCommentLen = Int(data.le16(p + 32))
            let cdDiskNumberStart = data.le16(p + 34)
            let cdInternalAttrs = data.le16(p + 36)
            let cdExternalAttrs = data.le32(p + 38)
            let lfhOffset = Int(data.le32(p + 42))
            let cdNameStart = p + 46
            let cdNameEnd = cdNameStart + cdNameLen
            guard cdNameEnd <= data.count else { throw ParseError.truncated("CD name") }
            let cdName = Array(data[cdNameStart..<cdNameEnd])

            // Now walk the matching LFH at lfhOffset.
            guard lfhOffset + 30 <= data.count else { throw ParseError.truncated("LFH at \(lfhOffset)") }
            guard data[lfhOffset] == sigLFH[0] && data[lfhOffset + 1] == sigLFH[1]
                && data[lfhOffset + 2] == sigLFH[2] && data[lfhOffset + 3] == sigLFH[3]
            else { throw ParseError.badSignature("LFH at \(lfhOffset)") }
            let lfhGPFlag = data.le16(lfhOffset + 6)
            let lfhVersionNeeded = data.le16(lfhOffset + 4)
            let lfhMethod = data.le16(lfhOffset + 8)
            let lfhTime = data.le16(lfhOffset + 10)
            let lfhDate = data.le16(lfhOffset + 12)
            let lfhCRC = data.le32(lfhOffset + 14)
            let lfhCompressedSize = data.le32(lfhOffset + 18)
            let lfhUncompressedSize = data.le32(lfhOffset + 22)
            let lfhNameLen = Int(data.le16(lfhOffset + 26))
            let lfhExtraLen = Int(data.le16(lfhOffset + 28))
            let lfhNameStart = lfhOffset + 30
            let lfhNameEnd = lfhNameStart + lfhNameLen
            guard lfhNameEnd <= data.count else { throw ParseError.truncated("LFH name") }
            let lfhName = Array(data[lfhNameStart..<lfhNameEnd])

            entries.append(
                ParsedEntry(
                    name: String(decoding: cdName, as: UTF8.self),
                    lfhCRC: lfhCRC,
                    cdCRC: cdCRC,
                    lfhSize: lfhUncompressedSize,
                    cdSize: cdUncompressedSize,
                    lfhCompressedSize: lfhCompressedSize,
                    cdCompressedSize: cdCompressedSize,
                    lfhName: lfhName,
                    cdName: cdName,
                    lfhMethod: lfhMethod,
                    cdMethod: cdMethod,
                    lfhGPFlag: lfhGPFlag,
                    cdGPFlag: cdGPFlag,
                    lfhExtraLen: UInt16(lfhExtraLen),
                    cdExtraLen: UInt16(cdExtraLen),
                    cdCommentLen: UInt16(cdCommentLen),
                    lfhVersionNeeded: lfhVersionNeeded,
                    cdVersionMadeBy: cdVersionMadeBy,
                    cdVersionNeeded: cdVersionNeeded,
                    cdDiskNumberStart: cdDiskNumberStart,
                    cdInternalAttrs: cdInternalAttrs,
                    cdExternalAttrs: cdExternalAttrs,
                    lfhDate: lfhDate,
                    cdDate: cdDate,
                    lfhTime: lfhTime,
                    cdTime: cdTime
                )
            )

            p = cdNameEnd + cdExtraLen + cdCommentLen
        }
        return ParsedArchive(entries: entries, eocd: eocd)
    }

    // MARK: - SHA-256 helper (CryptoKit-free so we don't add a dep)

    /// Hex-encoded SHA-256 over ``data``. We avoid linking
    /// ``CryptoKit`` solely for the deep-fuzz suite — the Foundation
    /// route via ``CC_SHA256`` from CommonCrypto is already linked
    /// transitively through the app, but adding an ``import
    /// CommonCrypto`` in a test file is friction we don't need.
    /// Instead we use a pure-Swift SHA-256 implementation, kept
    /// small enough to inline. Performance is fine — our inputs are
    /// kilobytes, not megabytes.
    private static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var bytes = Array(data)
        let bitLen = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in (0..<8).reversed() {
            bytes.append(UInt8((bitLen >> (i * 8)) & 0xFF))
        }
        var off = 0
        while off < bytes.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = off + i * 4
                w[i] = (UInt32(bytes[base]) << 24)
                    | (UInt32(bytes[base + 1]) << 16)
                    | (UInt32(bytes[base + 2]) << 8)
                    | UInt32(bytes[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ mj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            off += 64
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }
}

// MARK: - Little-endian read helpers

private extension Data {
    func le16(_ at: Int) -> UInt16 {
        return UInt16(self[at]) | (UInt16(self[at + 1]) << 8)
    }
    func le32(_ at: Int) -> UInt32 {
        return UInt32(self[at])
            | (UInt32(self[at + 1]) << 8)
            | (UInt32(self[at + 2]) << 16)
            | (UInt32(self[at + 3]) << 24)
    }
}
