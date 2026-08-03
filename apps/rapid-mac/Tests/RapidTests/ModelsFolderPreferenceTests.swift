import Foundation
import Testing
@testable import Rapid

/// Issue #503 (@LewnWorx): the user can point Rapid at an explicit
/// models folder — e.g. a large shared collection on an external drive
/// — instead of always downloading to the internal default. This suite
/// pins ``ModelsFolderPreference``: the single source of truth every
/// disk-facing surface (engine env, byte monitor, deletion, catalog,
/// background pull) reads so "what the app shows" matches "where the
/// engine reads/writes".
///
/// The unplugged-drive fallback (point 4 of the issue: non-fatal, no
/// crash) is the load-bearing behaviour and gets the most coverage: a
/// stored-but-unreachable folder must resolve to ``nil`` so callers
/// fall back to the default location.
@Suite("Models folder preference (issue #503)")
struct ModelsFolderPreferenceTests {

    /// Fresh isolated defaults so a test never reads/writes the real
    /// ``UserDefaults.standard`` (which would leak the developer's own
    /// Settings choice into CI and vice-versa).
    private func makeDefaults() -> UserDefaults {
        let suite = "rapid.tests.modelsfolder.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-models-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - store / read / clear

    @Test("storedPath is nil until a folder is set, then round-trips")
    func storedPathRoundTrips() {
        let defaults = makeDefaults()
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == nil)
        #expect(ModelsFolderPreference.hasCustomFolder(defaults: defaults) == false)

        ModelsFolderPreference.setStoredPath("/Volumes/T7/models", defaults: defaults)
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == "/Volumes/T7/models")
        #expect(ModelsFolderPreference.hasCustomFolder(defaults: defaults) == true)
    }

    @Test("Blank / whitespace path is treated as no override, not a bogus root")
    func blankPathClearsOverride() {
        let defaults = makeDefaults()
        ModelsFolderPreference.setStoredPath("/Volumes/T7/models", defaults: defaults)
        // A cleared field arrives as empty / whitespace — must NOT
        // persist a blank root that later resolves to "/" or similar.
        ModelsFolderPreference.setStoredPath("   ", defaults: defaults)
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == nil)
        #expect(ModelsFolderPreference.hasCustomFolder(defaults: defaults) == false)
    }

    @Test("setStoredPath(nil) removes the override entirely")
    func nilClearsOverride() {
        let defaults = makeDefaults()
        ModelsFolderPreference.setStoredPath("/Volumes/T7/models", defaults: defaults)
        ModelsFolderPreference.setStoredPath(nil, defaults: defaults)
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == nil)
    }

    @Test("Stored path is trimmed so a trailing space can't defeat the blank check")
    func storedPathIsTrimmed() {
        let defaults = makeDefaults()
        ModelsFolderPreference.setStoredPath("  /Volumes/T7/models  ", defaults: defaults)
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == "/Volumes/T7/models")
    }

    // MARK: - validate() pure seam

    @Test("validate returns a directory URL for a real absolute directory")
    func validateAcceptsRealDirectory() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = ModelsFolderPreference.validate(path: dir.path)
        #expect(url?.path == dir.path)
    }

    @Test("validate rejects a non-existent path (unplugged drive)")
    func validateRejectsMissingPath() {
        // The canonical #503 failure mode: the stored path pointed at an
        // external volume that is no longer mounted.
        let missing = "/Volumes/NotMounted-\(UUID().uuidString)/models"
        #expect(ModelsFolderPreference.validate(path: missing) == nil)
    }

    @Test("validate rejects a path that is a file, not a directory")
    func validateRejectsFile() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(ModelsFolderPreference.validate(path: file.path) == nil)
    }

    @Test("validate rejects a relative path and nil")
    func validateRejectsRelativeAndNil() {
        #expect(ModelsFolderPreference.validate(path: nil) == nil)
        #expect(ModelsFolderPreference.validate(path: "relative/models") == nil)
        #expect(ModelsFolderPreference.validate(path: "") == nil)
    }

    // MARK: - validatedOverrideURL + unavailable derivation

    @Test("validatedOverrideURL resolves a set-and-reachable folder")
    func validatedOverrideResolvesReachable() throws {
        let defaults = makeDefaults()
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ModelsFolderPreference.setStoredPath(dir.path, defaults: defaults)
        let url = ModelsFolderPreference.validatedOverrideURL(defaults: defaults)
        #expect(url?.path == dir.path)
        #expect(ModelsFolderPreference.customFolderUnavailable(defaults: defaults) == false)
    }

    @Test("validatedOverrideURL falls back to nil when the set folder is gone")
    func validatedOverrideFallsBackWhenGone() throws {
        let defaults = makeDefaults()
        let dir = try makeTmpDir()
        ModelsFolderPreference.setStoredPath(dir.path, defaults: defaults)
        // Simulate the drive being unplugged / the folder deleted AFTER
        // the preference was stored.
        try FileManager.default.removeItem(at: dir)

        #expect(ModelsFolderPreference.validatedOverrideURL(defaults: defaults) == nil)
        // The preference is still SET (so the UI keeps the "Use default"
        // affordance + shows the path), but it's flagged unavailable so
        // the warning banner appears and callers use the default cache.
        #expect(ModelsFolderPreference.storedPath(defaults: defaults) == dir.path)
        #expect(ModelsFolderPreference.customFolderUnavailable(defaults: defaults) == true)
    }

    @Test("customFolderUnavailable is false when no folder is set at all")
    func unavailableFalseWhenNoFolder() {
        let defaults = makeDefaults()
        #expect(ModelsFolderPreference.customFolderUnavailable(defaults: defaults) == false)
    }
}
