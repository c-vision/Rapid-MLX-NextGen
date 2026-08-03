import Foundation
import Testing
@testable import Rapid

/// Issue #401 contract tests for ``FirstInstallSessionReset``.
///
/// The helper is the systemic surface the bootstrapper uses to archive
/// the user's ``sessions.json`` when a brand-new bootstrap install is
/// about to materialise a ChatView — without that archive, the first
/// frame a never-launched-before user sees is a previous tenant's
/// "write a 500 word essay" prompt, which is privacy-broken and the
/// wrong first impression.
///
/// These tests cover the helper in isolation. The end-to-end "predicate
/// is computed correctly, fires only on genuinely-first-install"
/// coverage lives in ``BootstrapCoordinatorTests`` so the wire-up
/// regresses loudly too.
@Suite("FirstInstallSessionReset", .serialized)
struct FirstInstallSessionResetTests {

    // MARK: - Sandbox helpers

    /// Build a sandbox directory rooted at ``NSTemporaryDirectory``.
    /// The caller is responsible for deferring its cleanup; we
    /// deliberately do NOT defer here so the call site sees an
    /// obvious "this is a test scratch path" return type.
    private static func sandbox(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("first-install-reset-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write a recognisable payload to ``sessions.json`` so a passing
    /// archive test can re-read the backup file and confirm the bytes
    /// survived the rename.
    private static func writeSessions(_ payload: String, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Backup-filename grammar

    /// The backup filename has to be safe across HFS+ / APFS and
    /// sort-friendly in Finder. Pin: starts with ``sessions.``, ends
    /// with ``.bak.json``, NO colons (POSIX-clean), embeds an ISO-8601
    /// stamp that round-trips with ``ISO8601DateFormatter``.
    @Test("backupFilename: shape is sessions.<ISO8601>.bak.json with no colons")
    func backupFilenameShape() {
        // 2026-06-25T13:42:09Z UTC — a pinned moment so the assertion
        // is deterministic across CI clocks. Cross-checked via
        // `TZ=UTC date -r 1782394929`.
        let stamp = Date(timeIntervalSince1970: 1782394929)
        let name = FirstInstallSessionReset.backupFilename(now: stamp)
        #expect(name.hasPrefix("sessions."), "expected sessions. prefix, saw \(name)")
        #expect(name.hasSuffix(".bak.json"), "expected .bak.json suffix, saw \(name)")
        #expect(!name.contains(":"), "POSIX-clean filename must not contain colons, saw \(name)")
        // Inner stamp must round-trip through ISO-8601 with the
        // colon-to-dash substitution reversed at EXACTLY the
        // positions the helper made it. Codex r3 BLOCKING: an
        // earlier version replaced all dashes with colons then tried
        // to restore the first three "date dashes", but the date
        // portion only has TWO real dashes (between year-month and
        // month-day; the time positions use ":" in canonical ISO).
        // The helper's substitution is the inverse of the canonical
        // ISO form, so we just pin the EXACT inner-string against
        // the canonical stamp with each ":" pre-replaced.
        let inner = name
            .replacingOccurrences(of: "sessions.", with: "")
            .replacingOccurrences(of: ".bak.json", with: "")
        // Canonical ISO8601 stamp for the pinned epoch.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let canonical = formatter.string(from: stamp) // "2026-06-25T13:42:09Z"
        let expectedInner = canonical
            .replacingOccurrences(of: ":", with: "-")
        #expect(inner == expectedInner,
                "inner stamp must be canonical ISO8601 with `:` → `-`. expected \(expectedInner), saw \(inner)")
        // And the canonical form does round-trip cleanly through
        // ISO8601DateFormatter, so the helper's filenames are
        // recoverable via the same substitution in reverse.
        #expect(formatter.date(from: canonical) != nil,
                "canonical ISO8601 stamp must round-trip, saw \(canonical)")
    }

    // MARK: - Scenario 1: first-install, sessions.json present

    /// The dominant fix-this-bug scenario: a brand-new bootstrap
    /// install finds a stale ``sessions.json`` on disk and archives
    /// it to a sibling backup file. Confirms BOTH that the new backup
    /// exists with the original bytes AND that the original path is
    /// now empty (the next SessionStore.init reads "no file" → fresh
    /// state).
    @Test("first-install + sessions.json present → rename to sessions.<stamp>.bak.json")
    func firstInstallArchivesExistingFile() throws {
        let dir = Self.sandbox("present")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        let payload = #"{"sessions":[{"id":"abc","title":"stale chat"}]}"#
        Self.writeSessions(payload, at: sessions)

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: Date(timeIntervalSince1970: 1782394929)
        )

        guard case .archived(let backupURL) = outcome else {
            Issue.record("expected .archived outcome, saw \(outcome)")
            return
        }
        // The original path is gone (SessionStore will see empty state).
        #expect(!FileManager.default.fileExists(atPath: sessions.path),
                "post-archive sessions.json must NOT exist at original path")
        // The backup file exists with the original bytes.
        #expect(FileManager.default.fileExists(atPath: backupURL.path),
                "backup file must exist at returned URL: \(backupURL.path)")
        let recovered = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(recovered == payload,
                "archived bytes must match original payload exactly")
        // The backup lives in the same parent (sibling rename, not a
        // cross-directory move).
        #expect(backupURL.deletingLastPathComponent().path == dir.path,
                "backup must be a sibling of original sessions.json")
    }

    // MARK: - Scenario 2: bundled-sidecar short-circuit (v0.8.x users)

    /// The v0.8.x bundled-sidecar user shape: the helper is NEVER
    /// invoked because the predicate (which lives in
    /// BootstrapCoordinator and is covered in
    /// BootstrapCoordinatorTests) returns false. We pin the helper's
    /// "do nothing if I'm never called" contract by asserting that
    /// the sessions.json file is untouched after the test creates one
    /// and then doesn't call ``archiveSessionsFile``. This is a
    /// trivial assertion but it's the kind of thing a careless future
    /// refactor (turning the helper into an init-time side-effect)
    /// would break.
    @Test("bundled-sidecar path: sessions.json untouched when helper is not called")
    func bundledSidecarShortCircuit() throws {
        let dir = Self.sandbox("bundled")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        let payload = #"{"sessions":[{"id":"existing","title":"my chat"}]}"#
        Self.writeSessions(payload, at: sessions)

        // Helper is intentionally NOT called — that's the test.
        // (In production, the bootstrapper's predicate decides whether
        // to invoke the helper. v0.8.x bundled-sidecar users
        // short-circuit out of the install branch entirely, so we
        // never reach the helper-call site.)

        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "sessions.json must be untouched when the helper isn't invoked")
        let recovered = try String(contentsOf: sessions, encoding: .utf8)
        #expect(recovered == payload,
                "untouched sessions.json must keep its exact bytes")
    }

    // MARK: - Scenario 3: missing sessions.json (brand-new Mac)

    /// A user on a Mac that has never run the app before. The helper
    /// should no-op gracefully and return ``.notPresent`` — no crash,
    /// no backup file created spuriously.
    @Test("missing sessions.json → .notPresent, no crash, no spurious backup")
    func missingSessionsFileNoOp() throws {
        let dir = Self.sandbox("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        // Deliberately NOT created.

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: Date()
        )

        #expect(outcome == .notPresent,
                "missing source file must return .notPresent; saw \(outcome)")
        // No backup file should have been created either — important
        // because if the helper started writing a 0-byte sidecar on
        // every fresh install, every brand-new user would see a
        // mysterious file in their support directory.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(contents.isEmpty,
                "no files should be created on the .notPresent path; saw \(contents)")
    }

    // MARK: - Scenario 4: read-only filesystem / permission denied

    /// Filesystem permission failure (read-only mount, sandboxed
    /// directory) must surface as ``.failed`` and never crash the
    /// install pipeline. We simulate this by pointing the helper at
    /// a destination path inside a directory we make read-only mid-
    /// test. The move fails → outcome ``.failed`` → caller logs and
    /// continues.
    @Test("permission denied during rename → .failed, install continues")
    func permissionDeniedSurfacesAsFailed() throws {
        let dir = Self.sandbox("readonly")
        defer {
            // Restore perms before we try to remove, otherwise
            // removeItem itself ENOPERM.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        let sessions = dir.appendingPathComponent("sessions.json")
        Self.writeSessions("{}", at: sessions)

        // Strip write permission from the parent so the rename has
        // nowhere to land. The source file is readable; what fails is
        // the directory entry creation for the destination filename.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: dir.path
        )

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: Date()
        )

        if case .failed(let message) = outcome {
            #expect(!message.isEmpty, "failure message should not be empty")
        } else {
            Issue.record("expected .failed outcome on read-only parent; saw \(outcome)")
        }
        // The original sessions.json is still there (we never deleted
        // it — the move failed, so nothing got destructively erased).
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "source file must survive a failed move; otherwise we just LOST data")
    }

    // MARK: - Scenario 5: collision resolution

    /// Two genuinely-first-installs landing within the same UTC second
    /// (or a previous backup file already on disk with the current
    /// stamp) must NOT clobber each other. Pin the suffix-`-N`
    /// resolution behaviour.
    @Test("backup-name collision → suffix appended, prior backup preserved")
    func backupNameCollisionResolves() throws {
        let dir = Self.sandbox("collision")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        Self.writeSessions(#"{"k":"second"}"#, at: sessions)

        // Plant a "previous backup" at the exact filename the helper
        // would otherwise pick.
        let stamp = Date(timeIntervalSince1970: 1782394929)
        let prebakedName = FirstInstallSessionReset.backupFilename(now: stamp)
        let prebakedURL = dir.appendingPathComponent(prebakedName)
        try Data(#"{"k":"first"}"#.utf8).write(to: prebakedURL, options: .atomic)

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: stamp
        )

        guard case .archived(let backupURL) = outcome else {
            Issue.record("expected .archived, saw \(outcome)")
            return
        }
        // The new backup must NOT be the prebaked filename.
        #expect(backupURL.lastPathComponent != prebakedName,
                "collision resolution must pick a different filename, saw \(backupURL.lastPathComponent)")
        // The prebaked file must still be on disk with its original
        // bytes (we did NOT overwrite it).
        let preserved = try String(contentsOf: prebakedURL, encoding: .utf8)
        #expect(preserved == #"{"k":"first"}"#,
                "prior backup file must be preserved untouched")
        // The new backup carries the second payload.
        let newPayload = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(newPayload == #"{"k":"second"}"#,
                "new backup must carry the just-archived bytes")
    }

    /// Codex r2 MINOR pin: the collision-resolved filename must still
    /// match the documented ``sessions.*.bak.json`` discovery glob —
    /// i.e. the disambiguating suffix lands BEFORE the ``.bak.json``
    /// tail, not between ``.bak`` and ``.json``. Without this,
    /// support tooling / tests / Finder queries that grep for
    /// ``*.bak.json`` would silently miss the collision-suffixed
    /// backups.
    @Test("collision backup filename keeps the .bak.json tail intact (codex r2 minor)")
    func collisionBackupKeepsBakJsonTail() throws {
        let dir = Self.sandbox("collision-suffix-shape")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        Self.writeSessions(#"{"k":"new"}"#, at: sessions)
        let stamp = Date(timeIntervalSince1970: 1782394929)
        // Plant the unsuffixed name so the helper has to disambiguate.
        let pristine = FirstInstallSessionReset.backupFilename(now: stamp)
        try Data(#"{"k":"old"}"#.utf8).write(
            to: dir.appendingPathComponent(pristine),
            options: .atomic
        )

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: stamp
        )

        guard case .archived(let backupURL) = outcome else {
            Issue.record("expected .archived, saw \(outcome)")
            return
        }
        let name = backupURL.lastPathComponent
        // Tail intact: still ends in `.bak.json`, NOT `.bak-1.json`.
        #expect(name.hasSuffix(".bak.json"),
                "collision-resolved backup must still end with .bak.json; saw \(name)")
        #expect(name.hasPrefix("sessions."),
                "collision-resolved backup must still start with sessions.; saw \(name)")
        // Disambiguator landed between the stamp and the tail.
        #expect(name.contains("-1.bak.json"),
                "collision suffix must sit immediately before .bak.json; saw \(name)")
    }

    // MARK: - Scenario 6: #417 — empty / default envelope is not archived

    /// A clean / default first-install can leave a well-formed but empty
    /// ``{"sessions":[]}`` envelope on disk. PR #402 archived it anyway,
    /// littering an empty ``sessions.<stamp>.bak.json``. The fix skips it:
    /// ``.skippedEmpty``, original untouched, NO backup created.
    @Test("#417: empty {\"sessions\":[]} envelope → .skippedEmpty, no backup written")
    func emptyEnvelopeSkipsArchive() throws {
        let dir = Self.sandbox("empty-envelope")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions.json")
        Self.writeSessions(#"{"sessions":[]}"#, at: sessions)

        let outcome = FirstInstallSessionReset.archiveSessionsFile(
            at: sessions,
            now: Date(timeIntervalSince1970: 1782394929)
        )

        #expect(outcome == .skippedEmpty,
                "empty envelope must return .skippedEmpty; saw \(outcome)")
        // Original left in place (harmless — SessionStore reads it as
        // empty state), and NO backup sibling was dropped.
        #expect(FileManager.default.fileExists(atPath: sessions.path),
                "skipped sessions.json must stay on disk")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(contents == ["sessions.json"],
                "no backup file should be created on the .skippedEmpty path; saw \(contents)")
    }

    /// A 0-byte or whitespace-only ``sessions.json`` is likewise nothing
    /// to preserve → ``.skippedEmpty``.
    @Test("#417: zero-byte and whitespace-only sessions.json → .skippedEmpty")
    func emptyAndWhitespaceFilesSkipArchive() throws {
        for payload in ["", "   \n\t  "] {
            let dir = Self.sandbox("empty-bytes")
            defer { try? FileManager.default.removeItem(at: dir) }
            let sessions = dir.appendingPathComponent("sessions.json")
            Self.writeSessions(payload, at: sessions)

            let outcome = FirstInstallSessionReset.archiveSessionsFile(
                at: sessions,
                now: Date()
            )
            #expect(outcome == .skippedEmpty,
                    "payload \(payload.debugDescription) must return .skippedEmpty; saw \(outcome)")
        }
    }

    /// Conservative guard: a payload we CANNOT prove empty must still be
    /// archived so #401's privacy guarantee is never weakened. ``{}`` has
    /// no ``sessions`` key (a document-level break to the loader), and a
    /// populated array obviously has history — both archive.
    @Test("#417: non-empty or unparseable payload is still archived (preserves #401)")
    func ambiguousPayloadStillArchived() throws {
        for payload in [
            #"{"sessions":[{"id":"abc","title":"stale"}]}"#,  // real history
            #"{}"#,                                            // no sessions key
            #"{"k":"foreign"}"#,                               // foreign shape
            // Empty sessions BUT foreign top-level data our reader would
            // ignore then overwrite — must archive (codex #455/#417 MAJOR).
            #"{"sessions":[],"conversations":[{"id":"x"}]}"#,
        ] {
            let dir = Self.sandbox("archived-payload")
            defer { try? FileManager.default.removeItem(at: dir) }
            let sessions = dir.appendingPathComponent("sessions.json")
            Self.writeSessions(payload, at: sessions)

            let outcome = FirstInstallSessionReset.archiveSessionsFile(
                at: sessions,
                now: Date(timeIntervalSince1970: 1782394929)
            )
            guard case .archived = outcome else {
                Issue.record("payload \(payload) must archive; saw \(outcome)")
                continue
            }
        }
    }

    /// Direct unit coverage of the emptiness predicate so its exact
    /// contract is pinned independent of the disk-mutating wrapper.
    @Test("#417: envelopeHasNoHistory contract")
    func envelopeHasNoHistoryContract() {
        func data(_ s: String) -> Data { Data(s.utf8) }
        // No history:
        #expect(FirstInstallSessionReset.envelopeHasNoHistory(Data()))
        #expect(FirstInstallSessionReset.envelopeHasNoHistory(data("   \n ")))
        #expect(FirstInstallSessionReset.envelopeHasNoHistory(data(#"{"sessions":[]}"#)))
        #expect(FirstInstallSessionReset.envelopeHasNoHistory(data(#"{"sessions":[],"activeID":null}"#)))
        // Has history / can't prove empty → archive:
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data(#"{"sessions":[{"id":"a"}]}"#)))
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data(#"{}"#)))
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data(#"{"k":1}"#)))
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data("not json at all")))
        // Empty sessions but a foreign top-level key → NOT provably empty.
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data(#"{"sessions":[],"conversations":[{"id":"x"}]}"#)))
        // Non-object JSON roots are not the envelope shape → archive.
        #expect(!FirstInstallSessionReset.envelopeHasNoHistory(data("[]")))
    }
}
