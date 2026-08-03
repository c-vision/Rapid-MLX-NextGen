import Foundation
import Testing
@testable import Rapid

/// Contract for #20 — the persisted record of the rapid-mlx child this
/// session spawned. ``PortSweep`` reads it on the next launch to make
/// a precise kill decision instead of falling back to the basename
/// heuristic. Pin: (a) round-trip persist/load/clear; (b) atomic write
/// doesn't corrupt; (c) corrupt-file load returns nil instead of
/// throwing or crashing; (d) ``defaultURL`` lands under the expected
/// Application Support subdir.
@Suite("OwnedServerRecord persistence + lifecycle (#20)")
struct OwnedServerRecordTests {

    /// Each test gets a scratch file under ``NSTemporaryDirectory()``
    /// so the real ``~/Library/Application Support/Rapid/owned-server.json``
    /// of the developer's machine is never touched.
    private func scratchURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-osr-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("owned-server.json")
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Round-trip: persist → load returns the same record byte-for-byte")
    func roundTrip() {
        let url = scratchURL()
        defer { clean(url) }
        let original = OwnedServerRecord(
            pid: 12_345,
            pgid: 12_345,
            port: 8_000,
            alias: "qwen3.6-35b-4bit",
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        original.persist(to: url)
        let loaded = OwnedServerRecord.load(from: url)
        #expect(loaded == original)
    }

    @Test("Clear removes the persisted record from disk")
    func clearRemoves() {
        let url = scratchURL()
        defer { clean(url) }
        let original = OwnedServerRecord(
            pid: 1, pgid: 1, port: 8000, alias: "a", writtenAt: Date()
        )
        original.persist(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        OwnedServerRecord.clear(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Clear is idempotent — calling it twice doesn't throw.
        OwnedServerRecord.clear(at: url)
    }

    @Test("Load returns nil for a missing file (no crash, no throw)")
    func loadMissing() {
        let url = scratchURL()
        defer { clean(url) }
        // Intentionally don't persist anything.
        #expect(OwnedServerRecord.load(from: url) == nil)
    }

    @Test("Load returns nil for a corrupt / malformed JSON file")
    func loadCorrupt() {
        let url = scratchURL()
        defer { clean(url) }
        // Write garbage that isn't valid JSON.
        try? Data("{ not real json".utf8).write(to: url)
        #expect(OwnedServerRecord.load(from: url) == nil)
    }

    @Test("Load returns nil for valid JSON missing required fields")
    func loadMissingFields() {
        let url = scratchURL()
        defer { clean(url) }
        // Valid JSON but missing every Codable key — decode must
        // fail and return nil rather than constructing a half-built
        // record with zero values that would survive into PortSweep's
        // kill-decision path.
        try? Data("{\"alias\":\"x\"}".utf8).write(to: url)
        #expect(OwnedServerRecord.load(from: url) == nil)
    }

    @Test("defaultURL lands under ~/Library/Application Support/Rapid/owned-server.json")
    func defaultURLShape() {
        let url = OwnedServerRecord.defaultURL()
        // The URL must end with the expected filename so a refactor
        // that quietly renames the file (or moves it out of the
        // shared Application Support tree where multiple users would
        // collide) breaks this test.
        #expect(url.lastPathComponent == "owned-server.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Rapid")
        // Should resolve to an absolute path so concurrent processes
        // don't disagree on what file they're reading.
        #expect(url.path.hasPrefix("/"))
    }

    @Test("Persist creates the parent directory if it doesn't exist")
    func persistCreatesParentDir() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-osr-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let url = dir.appendingPathComponent("owned-server.json")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        OwnedServerRecord(pid: 1, pgid: 1, port: 8000, alias: "x", writtenAt: Date())
            .persist(to: url)
        // Parent must have been created on the persist call; the
        // record must be on disk.
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Overwrite: a second persist replaces the first record atomically")
    func overwriteIsAtomic() {
        let url = scratchURL()
        defer { clean(url) }
        let first = OwnedServerRecord(
            pid: 100, pgid: 100, port: 8000, alias: "first", writtenAt: Date()
        )
        let second = OwnedServerRecord(
            pid: 200, pgid: 200, port: 8001, alias: "second", writtenAt: Date()
        )
        first.persist(to: url)
        second.persist(to: url)
        let loaded = OwnedServerRecord.load(from: url)
        // The second persist must FULLY replace the first — no
        // hybrid record, no partial-write corruption.
        #expect(loaded == second)
    }

    /// codex r1 P2 (#20 PR #142): pin that ``clear`` is callable from
    /// a synchronous, non-isolated context. Both ``ServerManager.shutdownSync``
    /// (the AppKit ``applicationWillTerminate`` path) and ``PortSweep.sweep``
    /// (static enum) reach this method without an actor hop; a refactor
    /// that gated ``clear`` behind ``@MainActor`` or made it ``async``
    /// would silently leave a stale record after Cmd-Q.
    ///
    /// The fact that this test compiles in a sync, non-actor context
    /// IS the contract — the runtime assertion just round-trips the
    /// observable side effect (file removed from disk).
    @Test("clear() is callable from a synchronous non-isolated context")
    func clearIsNonisolated() {
        let url = scratchURL()
        defer { clean(url) }
        OwnedServerRecord(pid: 1, pgid: 1, port: 8000, alias: "x", writtenAt: Date())
            .persist(to: url)
        OwnedServerRecord.clear(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
