import Foundation
import Testing
@testable import Rapid

/// Coverage for ``BrowseContentCache`` — the paging store. Verifies key
/// normalisation, round-trip, LRU eviction on entry count, and byte-budget
/// eviction.
@Suite("BrowseContentCache")
struct BrowseContentCacheTests {

    private func entry(_ md: String) -> BrowseContentCache.Entry {
        BrowseContentCache.Entry(title: nil, markdown: md, finalURL: "https://x")
    }

    /// Memory-only cache (``diskDirectory: nil``) — the pre-persistence
    /// behaviour these tests were written against. Keeps them off the real
    /// Application Support tree.
    private func memoryOnly(maxEntries: Int = 16, maxBytes: Int = 8 * 1024 * 1024) -> BrowseContentCache {
        BrowseContentCache(maxEntries: maxEntries, maxBytes: maxBytes, diskDirectory: nil)
    }

    @Test("Put then get round-trips by URL")
    func roundTrip() {
        let c = memoryOnly()
        c.put("https://example.com/a", entry: entry("hello"))
        #expect(c.get("https://example.com/a")?.markdown == "hello")
        #expect(c.get("https://example.com/b") == nil)
    }

    @Test("An expired memory entry is a cache miss")
    func expiredMemoryEntryMisses() {
        let c = memoryOnly()
        let old = BrowseContentCache.Entry(
            title: nil,
            markdown: "old body",
            finalURL: "https://example.com/old",
            fetchedAt: Date(timeIntervalSinceNow: -(BrowseContentCache.defaultTTL + 1))
        )
        c.put("https://example.com/old", entry: old)
        #expect(c.get("https://example.com/old") == nil)
    }

    @Test("Only scheme + host are case-normalised in the key; path stays exact")
    func keyNormalisation() {
        #expect(BrowseContentCache.key(for: "HTTPS://Example.COM/Path?Q=1")
                == "https://example.com/Path?Q=1")
        // Different path casing → different key (paths are case-sensitive).
        #expect(BrowseContentCache.key(for: "https://e.com/A")
                != BrowseContentCache.key(for: "https://e.com/a"))
    }

    @Test("A host-only case change hits the same entry")
    func caseInsensitiveHostHit() {
        let c = memoryOnly()
        c.put("https://Example.com/x", entry: entry("v"))
        #expect(c.get("https://example.COM/x")?.markdown == "v")
    }

    @Test("LRU evicts the oldest entry past the count cap")
    func lruEviction() {
        let c = memoryOnly(maxEntries: 2, maxBytes: 10_000_000)
        c.put("https://e.com/1", entry: entry("one"))
        c.put("https://e.com/2", entry: entry("two"))
        _ = c.get("https://e.com/1")               // touch 1 → 2 is now oldest
        c.put("https://e.com/3", entry: entry("three"))
        #expect(c.get("https://e.com/2") == nil)   // evicted
        #expect(c.get("https://e.com/1") != nil)
        #expect(c.get("https://e.com/3") != nil)
    }

    @Test("Byte budget evicts even under the entry cap")
    func byteEviction() {
        let c = memoryOnly(maxEntries: 100, maxBytes: 1000)
        c.put("https://e.com/a", entry: entry(String(repeating: "a", count: 600)))
        c.put("https://e.com/b", entry: entry(String(repeating: "b", count: 600)))
        // Total would be 1200 > 1000 → oldest (a) evicted.
        #expect(c.get("https://e.com/a") == nil)
        #expect(c.get("https://e.com/b") != nil)
    }

    // MARK: - Disk persistence tier

    /// Per-test temp directory so the disk tier never touches the real
    /// Application Support tree. Caller cleans up.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("browse-cache-test-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test("A page survives across cache instances via the disk tier")
    func diskPersistsAcrossInstances() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First "launch": write a page, then drop the instance.
        do {
            let c = BrowseContentCache(diskDirectory: dir)
            c.put("https://example.com/doc", entry: entry("persisted body"))
        }
        // Second "launch": a fresh instance has an empty memory tier but must
        // still resolve the URL from disk with zero re-fetch.
        let c2 = BrowseContentCache(diskDirectory: dir)
        let got = c2.get("https://example.com/doc")
        #expect(got?.markdown == "persisted body")
    }

    @Test("An expired disk entry is a cache miss")
    func expiredDiskEntryMisses() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = "https://example.com/old"
        let writer = BrowseContentCache(diskDirectory: dir)
        writer.put(url, entry: entry("old body"))

        let file = try #require(diskEntries(in: dir).first?.url)
        let data = try Data(contentsOf: file)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["fetchedAt"] = Date(timeIntervalSince1970: 0).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)

        let reader = BrowseContentCache(diskDirectory: dir)
        #expect(reader.get(url) == nil)
    }

    @Test("A page evicted from the hot memory tier is still served from disk")
    func diskServesAfterMemoryEviction() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // maxEntries 1 → the second put evicts the first from memory, but disk
        // keeps both.
        let c = BrowseContentCache(maxEntries: 1, maxBytes: 10_000_000, diskDirectory: dir)
        c.put("https://e.com/1", entry: entry("one"))
        c.put("https://e.com/2", entry: entry("two"))   // evicts 1 from memory
        #expect(c.get("https://e.com/1")?.markdown == "one")   // disk fallback
        #expect(c.get("https://e.com/2")?.markdown == "two")
    }

    @Test("Disk fallback promotes the entry back into the hot memory tier")
    func diskFallbackPromotesToMemory() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BrowseContentCache(diskDirectory: dir)
        writer.put("https://e.com/x", entry: entry("body"))
        // A fresh instance starts with empty memory, so this first read must use
        // disk and promote the entry into the reader's hot tier.
        let reader = BrowseContentCache(diskDirectory: dir)
        #expect(reader.get("https://e.com/x")?.markdown == "body")
        // Wipe the disk so a second disk read would miss. The value must still
        // be available from the reader's memory tier.
        try? FileManager.default.removeItem(at: dir)
        #expect(reader.get("https://e.com/x")?.markdown == "body")
    }

    @Test("Host/scheme casing maps to the same disk file")
    func diskKeyNormalisation() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let c1 = BrowseContentCache(diskDirectory: dir)
        c1.put("https://Example.com/p", entry: entry("v"))
        // A fresh instance querying with different host casing hits the same
        // normalised key → same disk file.
        let c2 = BrowseContentCache(diskDirectory: dir)
        #expect(c2.get("https://example.COM/p")?.markdown == "v")
    }

    @Test("Disk LRU keeps a recently read entry past the entry cap")
    func diskSweepEntryCapUsesReadRecency() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 2,
            maxDiskBytes: 100_000_000
        )
        writer.put("https://e.com/1", entry: entry("one"))
        writer.put("https://e.com/2", entry: entry("two"))

        let initialFiles = try diskEntries(in: dir)
        let one = try #require(initialFiles.first { $0.entry.markdown == "one" })
        let two = try #require(initialFiles.first { $0.entry.markdown == "two" })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: one.url.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: two.url.path
        )

        // A fresh reader must hit disk for entry one, making it the most recent.
        let reader = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 2,
            maxDiskBytes: 100_000_000
        )
        #expect(reader.get("https://e.com/1")?.markdown == "one")
        reader.put("https://e.com/3", entry: entry("three"))

        let remaining = try diskEntries(in: dir).map(\.entry.markdown)
        #expect(Set(remaining) == Set(["one", "three"]))
    }

    @Test("Disk bounds are restored when a cache instance starts")
    func diskSweepRunsOnInitialization() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 10,
            maxDiskBytes: 100_000_000
        )
        writer.put("https://e.com/1", entry: entry("one"))
        writer.put("https://e.com/2", entry: entry("two"))
        writer.put("https://e.com/3", entry: entry("three"))
        #expect(try diskEntries(in: dir).count == 3)

        _ = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 2,
            maxDiskBytes: 100_000_000
        )
        #expect(try diskEntries(in: dir).count == 2)
    }

    @Test("Disk sweep enforces the total byte cap")
    func diskSweepByteCap() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let maxDiskBytes = 1_000
        let c = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 100,
            maxDiskBytes: maxDiskBytes
        )
        c.put("https://e.com/1", entry: entry(String(repeating: "a", count: 700)))
        c.put("https://e.com/2", entry: entry(String(repeating: "b", count: 700)))

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { BrowseContentCache.isDiskCacheFileName($0.lastPathComponent) }
        let totalBytes = try files.reduce(into: 0) { total, url in
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        #expect(files.count == 1)
        #expect(totalBytes <= maxDiskBytes)
    }

    @Test("A stale concurrent put cannot overwrite the newest disk value")
    func concurrentPutsKeepNewestValueOnDisk() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = "https://e.com/concurrent"
        let oldEntry = entry(String(repeating: "a", count: 16 * 1024 * 1024))
        let newestEntry = entry("newest")
        let c = BrowseContentCache(
            maxEntries: 2,
            maxBytes: 32 * 1024 * 1024,
            diskDirectory: dir,
            maxDiskEntries: 10,
            maxDiskBytes: 32 * 1024 * 1024
        )

        let slowPut = Task.detached {
            c.put(url, entry: oldEntry)
        }
        // Observe the first memory insertion before issuing the newer put. The
        // large JSON payload keeps its disk work in flight long enough to overlap
        // with the second put, exercising the stale-write drop logic.
        while c.get(url)?.markdown.count != oldEntry.markdown.count {
            await Task.yield()
        }
        c.put(url, entry: newestEntry)
        await slowPut.value

        let fresh = BrowseContentCache(
            diskDirectory: dir,
            maxDiskEntries: 10,
            maxDiskBytes: 32 * 1024 * 1024
        )
        #expect(fresh.get(url)?.markdown == "newest")
    }

    @Test("Disk cache directory and files use private permissions")
    func diskPermissionsArePrivate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let c = BrowseContentCache(diskDirectory: dir)
        c.put("https://e.com/private", entry: entry("private body"))

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        let dirMode = try #require(dirAttributes[.posixPermissions] as? NSNumber)
        #expect(dirMode.intValue == 0o700)

        let files = try diskEntries(in: dir)
        #expect(files.count == 1)
        let file = try #require(files.first?.url)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue == 0o600)
    }

    @Test("isDiskCacheFileName only accepts <64-hex>.json")
    func diskFileNameShape() {
        #expect(BrowseContentCache.isDiskCacheFileName(String(repeating: "a", count: 64) + ".json"))
        #expect(!BrowseContentCache.isDiskCacheFileName("sessions.json"))
        #expect(!BrowseContentCache.isDiskCacheFileName(String(repeating: "a", count: 63) + ".json"))
        #expect(!BrowseContentCache.isDiskCacheFileName(String(repeating: "g", count: 64) + ".json"))
        #expect(!BrowseContentCache.isDiskCacheFileName(String(repeating: "a", count: 64)))
    }

    private struct StoredDiskEntry {
        let url: URL
        let entry: BrowseContentCache.Entry
    }

    private func diskEntries(in directory: URL) throws -> [StoredDiskEntry] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { BrowseContentCache.isDiskCacheFileName($0.lastPathComponent) }
            .map { url in
                StoredDiskEntry(
                    url: url,
                    entry: try JSONDecoder().decode(
                        BrowseContentCache.Entry.self,
                        from: Data(contentsOf: url)
                    )
                )
            }
    }
}
