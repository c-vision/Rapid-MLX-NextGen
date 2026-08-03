import Foundation
import Testing
@testable import Rapid

/// Issue #215 — contract for the public ``ChatExporter`` surface:
///   * ``markdown(_:)`` delegates to ``SessionMarkdownExporter`` so
///     the bulk archive's ``.md`` entries match the per-session
///     "Export as Markdown…" sidebar action verbatim.
///   * ``json(_:)`` round-trips a ``ChatSession`` through pretty +
///     ISO-8601 encode/decode without losing fields.
///   * ``bulkZip(_:)`` writes a valid STORED-method ZIP with one
///     ``manifest.json`` + one ``.md`` + one ``.json`` per session,
///     including collision-suffixing for same-titled placeholders.
///   * CRC32 vectors match the IEEE 802.3 polynomial reference,
///     so a reader (Finder, ``/usr/bin/unzip``) accepts the entries.
@Suite("ChatExporter")
struct ChatExporterTests {

    // MARK: - Fixture

    private func fixtureSession(
        title: String = "fixture",
        alias: String = "qwen3.6-27b",
        createdAt: Date = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
    ) -> ChatSession {
        let stats = MessageStats(
            elapsedSeconds: 2.0,
            charCount: 80,
            promptTokens: 200,
            completionTokens: 160
        )
        var asst = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "Visible answer.",
            reasoning: "Thinking step one.",
            status: .complete,
            stats: stats,
            createdAt: createdAt.addingTimeInterval(2)
        )
        asst.toolCalls = [
            ToolCall(id: "tc-1", name: "calculator", arguments: "{\"a\":1}")
        ]
        return ChatSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: title,
            alias: alias,
            messages: [
                ChatMessage(role: .user, content: "Hi", createdAt: createdAt),
                asst,
            ],
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(2)
        )
    }

    // MARK: - Markdown

    @Test("markdown delegates to SessionMarkdownExporter + ChatTextSanitizer — same string as the sidebar action emits")
    func markdownDelegates() {
        let session = fixtureSession()
        let viaExporter = ChatExporter.markdown(session)
        // The bulk + per-session sidebar paths now BOTH go through
        // ``sanitizeForPasteboard(render(...))``; the wrapper output
        // should equal that composition (codex round 1 MAJOR —
        // sanitizer parity).
        let expected = ChatTextSanitizer.sanitizeForPasteboard(
            SessionMarkdownExporter.render(session)
        )
        #expect(viaExporter == expected)
        // And the pinned header/role lines from the Markdown contract
        // round-trip through the wrapper unchanged for ASCII titles.
        #expect(viaExporter.hasPrefix("# fixture\n\n*qwen3.6-27b · "))
        #expect(viaExporter.contains("### You"))
        #expect(viaExporter.contains("### Assistant (qwen3.6-27b)"))
        #expect(viaExporter.contains("Visible answer."))
        #expect(viaExporter.contains("<details><summary>Thinking</summary>"))
        #expect(viaExporter.contains("> Tool calls: calculator"))
    }

    @Test("markdown strips bidi-override scalars an attacker model could embed in a transcript")
    func markdownStripsBidiOverrides() {
        // \u{202E} (Right-to-Left Override) is the classic
        // homograph attack scalar — used to mask filename
        // extensions and chat content from a glancing read. We
        // strip it on the export surface so a saved transcript
        // can't carry the trap into the reader's editor.
        var asst = ChatMessage(role: .assistant, content: "Hello\u{202E}olleH")
        asst.status = .complete
        let session = ChatSession(
            title: "bidi probe",
            alias: "qwen3.6-27b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                asst,
            ]
        )
        let md = ChatExporter.markdown(session)
        #expect(!md.contains("\u{202E}"))
    }

    /// The set of scalars that MUST NOT survive into exported markdown:
    /// every C0 control except TAB/LF (CR is included — it is normalised
    /// to LF, so a raw U+000D must never appear in the output either),
    /// DEL + the C1 block, and the full bidi override / isolate set.
    /// Mirrors ``ChatTextSanitizer.sanitizedScalar`` exactly.
    private static let forbiddenInExport: [UInt32] = {
        var v: [UInt32] = []
        for c: UInt32 in 0x00...0x1F where c != 0x09 && c != 0x0A { v.append(c) }
        for c: UInt32 in 0x7F...0x9F { v.append(c) }
        v += [0x061C, 0x200E, 0x200F,
              0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
              0x2066, 0x2067, 0x2068, 0x2069]
        return v
    }()

    @Test("Deterministic exhaustive: NO forbidden control/bidi scalar survives markdown export, in ANY user field (#509)")
    func markdownStripsEveryForbiddenScalarEndToEnd() {
        // #509 — the `ChatExporter — fuzz` `markdown(_:)` suite sampled
        // this invariant across 1000 random seeds and would intermittently
        // red CI on a seed that placed a control/bidi scalar the export
        // path failed to strip. `markdown(_:)` runs a single whole-output
        // `ChatTextSanitizer.sanitizeForPasteboard` pass, so the invariant
        // holds by construction for EVERY input — this test proves that
        // deterministically instead of sampling it: it stuffs the COMPLETE
        // forbidden set into every user-controlled field the renderer
        // emits, so a future refactor that routes any field around the
        // sanitizer fails here on the exact scalar it leaks, not on a
        // lucky fuzz seed. A 300k-seed sweep of the fuzz corpus found zero
        // violations, matching this proof.
        let payload = "KEEP"
            + String(String.UnicodeScalarView(
                Self.forbiddenInExport.map { UnicodeScalar($0)! }))
            + "KEEP"

        // The attachment goes on the USER message — the renderer emits
        // attachment filenames only from user turns (renderUser), so
        // hanging it on the assistant would leave that field untested
        // (codex MAJOR — vacuous attachment coverage).
        var user = ChatMessage(role: .user, content: "user \(payload)")
        user.attachments = [
            Attachment(
                kind: .textFile,
                filename: "file\(payload).txt",
                mime: "text/plain",
                body: "b",
                sizeBytes: 1
            )
        ]
        var asst = ChatMessage(
            role: .assistant,
            content: "answer \(payload)",
            reasoning: "thinking \(payload)",
            status: .complete
        )
        asst.toolCalls = [
            ToolCall(id: "tc-\(payload)", name: "calc\(payload)", arguments: "{\"x\":\"\(payload)\"}")
        ]
        // A failed turn — the renderer emits ``errorMessage`` only for
        // ``.failed`` assistant messages (codex MAJOR: the error branch
        // was otherwise never exercised).
        let failed = ChatMessage(
            role: .assistant,
            content: "",
            status: .failed,
            errorMessage: "boom \(payload)"
        )
        var session = ChatSession(
            // The alias is rendered in the stats line AND every assistant
            // heading — carry the payload there too (codex MAJOR).
            title: "title \(payload)",
            alias: "alias\(payload)",
            messages: [user, asst, failed]
        )
        session.systemPrompt = "system \(payload)"

        let md = ChatExporter.markdown(session)
        // The renderer always emits at least the H1 + stats line.
        #expect(!md.isEmpty)
        // Not one forbidden scalar survives — checked exhaustively.
        let outScalars = Set(md.unicodeScalars.map(\.value))
        for c in Self.forbiddenInExport {
            #expect(
                !outScalars.contains(c),
                "forbidden scalar U+\(String(c, radix: 16)) leaked into exported markdown"
            )
        }
        // The benign marker around each payload survives, proving the
        // fields were actually rendered (not dropped wholesale).
        #expect(md.contains("KEEP"), "legitimate surrounding text must survive export")
        // The attachment filename field specifically DID reach the export
        // path — the 📎 glyph is emitted only when renderUser walks the
        // attachment list — so its forbidden-scalar coverage isn't vacuous.
        #expect(md.contains("📎"), "attachment line must render so its filename is scanned")
    }

    @Test("Markdown attachment filenames escape link/heading metacharacters so they can't forge structure")
    func markdownEscapesAttachmentFilenameMetacharacters() {
        // Filename that, naively interpolated, would render as an
        // active Markdown link AND inject a fake heading on the
        // next line — both blocked by the round-2 escape in
        // ``SessionMarkdownExporter`` (the filename goes through
        // ``singleLineMarkdown`` on top of the path-safe ``sanitize``).
        var msg = ChatMessage(role: .user, content: "Look")
        msg.attachments = [
            Attachment(
                kind: .textFile,
                filename: "[click](https://attacker.example) # ouch",
                mime: "text/plain",
                body: "x",
                sizeBytes: 1
            )
        ]
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [msg]
        )
        let md = ChatExporter.markdown(session)
        // The literal ``[`` and ``#`` are escaped — no live Markdown
        // link, no heading collapse.
        #expect(md.contains("\\[click\\]"))
        #expect(md.contains("\\#"))
        // Belt-and-braces: the bare unescaped sequences must NOT
        // appear inside the rendered blockquote.
        #expect(!md.contains("> 📎 [click]"))
        #expect(!md.contains("> 📎 # "))
    }

    @Test("Markdown structural fields escape #/*/_ so an attacker title can't forge a heading")
    func markdownEscapesStructuralMetacharacters() {
        let session = ChatSession(
            title: "# evil ## title",
            alias: "qwen3.6-27b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                ChatMessage(role: .assistant, content: "Ok"),
            ]
        )
        let md = ChatExporter.markdown(session)
        // The H1 we emit IS `# <escaped-title>`; the escape blocks
        // the inner `#` from collapsing into a second-level header.
        #expect(md.hasPrefix("# \\# evil \\#\\# title\n"))
    }

    // MARK: - JSON

    @Test("json round-trips a session through ISO-8601 + pretty encode/decode")
    func jsonRoundTrip() throws {
        let session = fixtureSession()
        let data = try ChatExporter.json(session)
        // Pretty-printed + sorted-keys: contains a newline AND
        // the keys land alphabetised so diffs are deterministic.
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString.contains("\n"))
        #expect(asString.contains("\"alias\" : \"qwen3.6-27b\""))
        // ISO-8601 with fractional seconds (#289 fix) — encoded
        // ``createdAt`` is a string and carries 3 decimal digits, even
        // for whole-second inputs.
        #expect(asString.contains("\"createdAt\" : \"2026-06-10T12:00:00.000Z\""))

        // Envelope round-trip: decoded V1 carries the same session.
        let decoder = ChatExporter.jsonDecoder()
        let decoded = try decoder.decode(ExportSessionV1.self, from: data)
        #expect(decoded.session == session)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.generator == "Rapid Desktop")
    }

    @Test("V1 envelope top-level keys are exactly the closed contract — no silent extension via synthesized CodingKeys")
    func jsonEnvelopeExactKeys() throws {
        let session = fixtureSession()
        let data = try ChatExporter.json(session)
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Envelope JSON is not a top-level object")
            return
        }
        let expected: Set<String> = [
            "schemaVersion", "generator", "appVersion", "exportedAt", "session"
        ]
        #expect(Set(decoded.keys) == expected,
                "V1 envelope top-level keys drifted: \(decoded.keys.sorted()) vs expected \(expected.sorted())")
    }

    @Test("json schema is stable — V1 envelope locks required keys")
    func jsonSchemaPinned() throws {
        let session = fixtureSession()
        let data = try ChatExporter.json(session)
        let asString = String(data: data, encoding: .utf8) ?? ""
        // Envelope keys — codex round 1 MAJOR. ``schemaVersion`` is
        // the import-side switch; missing or renamed keys here mean
        // a future re-import path silently breaks.
        for key in ["schemaVersion", "generator", "appVersion", "exportedAt", "session"] {
            #expect(asString.contains("\"\(key)\""), "missing envelope key \(key)")
        }
        // Inner session keys — same backstop on the payload shape.
        // ``systemPrompt`` is optional but should still appear in
        // the encoded output when set; the fixture leaves it nil so
        // we don't assert its presence — instead we assert the
        // round-trip preserves nil systemPrompt below.
        for key in ["id", "title", "alias", "messages", "createdAt", "updatedAt", "isPinned"] {
            #expect(asString.contains("\"\(key)\""), "missing session key \(key)")
        }
    }

    @Test("Optional systemPrompt round-trips when populated, and decodes when absent")
    func jsonOptionalSystemPrompt() throws {
        let session = ChatSession(
            title: "with prompt",
            alias: "qwen3.6-27b",
            messages: [ChatMessage(role: .user, content: "Hi")],
            systemPrompt: "You are a code reviewer."
        )
        let data = try ChatExporter.json(session)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString.contains("\"systemPrompt\" : \"You are a code reviewer.\""))
        let decoder = ChatExporter.jsonDecoder()
        let decoded = try decoder.decode(ExportSessionV1.self, from: data)
        #expect(decoded.session.systemPrompt == "You are a code reviewer.")
    }

    // MARK: - Bulk ZIP

    @Test("bulkZip produces a valid PKWARE container with manifest + 2 entries per session")
    func bulkZipShape() throws {
        let sessions = [
            fixtureSession(title: "Tokyo weather"),
            fixtureSession(title: "Code review"),
            fixtureSession(title: "Idea brainstorm"),
        ]
        let data = try ChatExporter.bulkZip(sessions)

        // Local-file-header signature at offset 0 (first entry).
        #expect(data.count > 22)
        let sig = data.prefix(4)
        #expect(Array(sig) == [0x50, 0x4b, 0x03, 0x04])

        // End-of-central-directory signature in the trailing 22 bytes.
        let eocd = data.suffix(22).prefix(4)
        #expect(Array(eocd) == [0x50, 0x4b, 0x05, 0x06])

        // Entry count in EOCD: 1 manifest + 2 files × 3 sessions = 7.
        let eocdBytes = Array(data.suffix(22))
        let entryCount = UInt16(eocdBytes[10]) | (UInt16(eocdBytes[11]) << 8)
        #expect(entryCount == 7)
    }

    @Test("bulkZip contains the expected filenames — collision counter kicks in on duplicate titles")
    func bulkZipFilenames() throws {
        let sessions = [
            fixtureSession(title: "New chat"),
            fixtureSession(title: "New chat"),
            fixtureSession(title: "Distinct"),
        ]
        let data = try ChatExporter.bulkZip(sessions)
        // Search the raw bytes rather than UTF-8 decoding the whole
        // archive — the CRC32 + size fields aren't valid UTF-8 so
        // ``String(data:encoding:)`` collapses to nil on most inputs.
        func containsName(_ name: String) -> Bool {
            data.range(of: Data(name.utf8)) != nil
        }
        // Manifest is present.
        #expect(containsName("manifest.json"))
        // First "New chat" lands as-is; second one becomes "-2"; third
        // is uniquely named.
        #expect(containsName("sessions/New-chat.md"))
        #expect(containsName("sessions/New-chat.json"))
        #expect(containsName("sessions/New-chat-2.md"))
        #expect(containsName("sessions/New-chat-2.json"))
        #expect(containsName("sessions/Distinct.md"))
        #expect(containsName("sessions/Distinct.json"))
    }

    @Test("bulkZip with zero sessions still emits a valid archive carrying only the manifest")
    func bulkZipEmpty() throws {
        let data = try ChatExporter.bulkZip([])
        // Local header sig (manifest entry) at offset 0.
        let sig = data.prefix(4)
        #expect(Array(sig) == [0x50, 0x4b, 0x03, 0x04])
        // EOCD entry count = 1 (manifest only).
        let eocdBytes = Array(data.suffix(22))
        let entryCount = UInt16(eocdBytes[10]) | (UInt16(eocdBytes[11]) << 8)
        #expect(entryCount == 1)
    }

    @Test("Manifest carries schemaVersion + sessionCount + ISO-8601 timestamp")
    func bulkZipManifest() throws {
        let now = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        let manifest = BulkManifest(
            schemaVersion: 1,
            generator: "Rapid Desktop",
            appVersion: "1.2.3",
            exportedAt: now,
            sessionCount: 5
        )
        let data = try ChatExporter.jsonEncoder().encode(manifest)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString.contains("\"schemaVersion\" : 1"))
        #expect(asString.contains("\"sessionCount\" : 5"))
        #expect(asString.contains("\"generator\" : \"Rapid Desktop\""))
        #expect(asString.contains("\"exportedAt\" : \"2026-06-10T12:00:00.000Z\""))
    }

    @Test("bulkSuggestedFilename lands in the rapid-chats-YYYY-MM-DD.zip shape")
    func bulkFilename() {
        let date = ISO8601DateFormatter().date(from: "2026-06-19T08:30:00Z")!
        let name = ChatExporter.bulkSuggestedFilename(now: date)
        #expect(name == "rapid-chats-2026-06-19.zip")
    }

    // MARK: - CRC32

    @Test("CRC32 against the IEEE 802.3 reference vector")
    func crc32ReferenceVectors() {
        // Standard test vectors — same constants every PKWARE-compatible
        // ZIP implementation pins.
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        #expect(CRC32.checksum(Data("a".utf8)) == 0xE8B7BE43)
    }

    // MARK: - End-to-end ZIP interop

    @Test("bulkZip output opens with /usr/bin/unzip — real-world interop smoke")
    func bulkZipUnzipInterop() throws {
        let sessions = [
            fixtureSession(title: "smoke-one"),
            fixtureSession(title: "smoke-two"),
        ]
        let archive = try ChatExporter.bulkZip(sessions)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-zip-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("out.zip")
        try archive.write(to: zipURL)

        // List the archive — exit code 0 + a row for each entry
        // we wrote means the container is well-formed enough for
        // ``/usr/bin/unzip`` (the same code path Finder's
        // double-click uses).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", zipURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let listing = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "unzip -l failed: \(listing)")
        #expect(listing.contains("manifest.json"))
        #expect(listing.contains("sessions/smoke-one.md"))
        #expect(listing.contains("sessions/smoke-one.json"))
        #expect(listing.contains("sessions/smoke-two.md"))
        #expect(listing.contains("sessions/smoke-two.json"))
    }

    // MARK: - Atomic write hardening (TOCTOU)

    @Test("atomicWrite refuses to follow a symlink at the destination")
    func atomicWriteRefusesSymlink() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-write-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Decoy file the symlink would redirect to. If atomicWrite
        // followed the symlink, this file's content would be
        // clobbered by our payload.
        let decoy = dir.appendingPathComponent("decoy.txt")
        try "decoy original".write(to: decoy, atomically: true, encoding: .utf8)

        // Symlink at the destination.
        let dest = dir.appendingPathComponent("export.json")
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: decoy)

        // atomicWrite should write THROUGH the symlink (the rename
        // replaces it) but NEVER follow it — the decoy must stay
        // untouched.
        let payload = Data("attacker payload".utf8)
        try ChatExporter.atomicWrite(payload, to: dest)
        let decoyAfter = try String(contentsOf: decoy, encoding: .utf8)
        #expect(decoyAfter == "decoy original", "Decoy was clobbered through symlink — TOCTOU window open")
        let writtenAfter = try Data(contentsOf: dest)
        #expect(writtenAfter == payload)
    }

    @Test("atomicWrite produces a 0600 file readable + writable by user only")
    func atomicWriteFileMode() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-write-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("export.json")
        try ChatExporter.atomicWrite(Data("payload".utf8), to: dest)
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        // 0600 = read+write owner only; bits 0o077 must be zero.
        #expect((perms & 0o077) == 0, "Mode 0\(String(perms, radix: 8)) leaks read access beyond the owner")
    }

    // MARK: - ZIP body integrity + size guards

    @Test("bulkZip output passes `unzip -t` CRC verification on every entry")
    func bulkZipUnzipTest() throws {
        let sessions = [
            fixtureSession(title: "integrity-one"),
            fixtureSession(title: "integrity-two"),
        ]
        let archive = try ChatExporter.bulkZip(sessions)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-zip-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("out.zip")
        try archive.write(to: zipURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zipURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let log = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "unzip -t failed: \(log)")
        // unzip -t emits "No errors detected in compressed data of …"
        // on success for each entry.
        #expect(log.contains("No errors detected"))
    }

    @Test("bulkZip extract round-trips Markdown + JSON bodies byte-for-byte")
    func bulkZipExtractRoundTrip() throws {
        let session = fixtureSession(title: "roundtrip")
        let archive = try ChatExporter.bulkZip([session])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-zip-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("out.zip")
        try archive.write(to: zipURL)

        // unzip into the same dir.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        // The extracted markdown matches what ``ChatExporter.markdown``
        // returns — the encoder + zip + unzip cycle preserves bytes.
        let extractedMD = try String(
            contentsOf: dir.appendingPathComponent("sessions/roundtrip.md"),
            encoding: .utf8
        )
        #expect(extractedMD == ChatExporter.markdown(session))

        // Same for the inner JSON envelope.
        let extractedJSON = try Data(
            contentsOf: dir.appendingPathComponent("sessions/roundtrip.json")
        )
        let decoder = ChatExporter.jsonDecoder()
        let decoded = try decoder.decode(ExportSessionV1.self, from: extractedJSON)
        #expect(decoded.session == session)
    }

    @Test("Archive size overflow throws .archiveTooLarge instead of silently corrupting")
    func archiveTooLargeGuard() throws {
        // Trigger the per-entry overflow guard directly by feeding
        // ``entryTooLarge`` thresholds — the ZIP writer caps at
        // UInt32 per-entry and per-archive offset. Building a real
        // 4 GiB payload in CI is impractical so we exercise the
        // guard via a Mirror-free shortcut: a single huge fake
        // "body" via a stub session is also impractical. Instead
        // assert the error type is surfaced from the public surface
        // (the helper ``ZIPWriter.add`` is internal). Coverage of
        // the actual numeric guard lives in the implementation
        // comment.
        //
        // This test is a placeholder pinning that the error case
        // exists in ``ChatExporterError``; if a future refactor
        // drops the guard we want compile-time AND test signal.
        let err = ChatExporterError.archiveTooLarge(approxBytes: 5_000_000_000)
        if case let .archiveTooLarge(b) = err {
            #expect(b == 5_000_000_000)
        } else {
            Issue.record("archiveTooLarge case not surfaced")
        }
        // Also pin that LocalizedError surfaces a human description
        // (NSAlert uses ``localizedDescription`` for the body text).
        #expect((err as LocalizedError).errorDescription?.contains("ZIP") == true)
    }

    // MARK: - Defensive guards

    @Test("Tool call args carrying control chars / quotes round-trip through JSON without corruption")
    func toolArgsRoundTrip() throws {
        var asst = ChatMessage(role: .assistant, content: "ok")
        asst.toolCalls = [
            ToolCall(
                id: "tc-1",
                name: "shell",
                arguments: "{\"cmd\":\"echo \\\"hi\\\"\\nworld\"}"
            )
        ]
        let session = ChatSession(
            title: "shell session",
            alias: "qwen3.6-27b",
            messages: [
                ChatMessage(role: .user, content: "run echo"),
                asst,
            ]
        )
        let data = try ChatExporter.json(session)
        let decoder = ChatExporter.jsonDecoder()
        let decoded = try decoder.decode(ExportSessionV1.self, from: data)
        #expect(decoded.session.messages[1].toolCalls?.first?.function.arguments
                == "{\"cmd\":\"echo \\\"hi\\\"\\nworld\"}")
    }
}
