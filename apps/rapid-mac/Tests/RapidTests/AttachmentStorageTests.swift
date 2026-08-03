import Foundation
import Testing
import CryptoKit
@testable import Rapid

/// Issue #22: pin the ``AttachmentStorage`` contract. Storage is the
/// single piece between "user dropped an image" and "image bytes
/// survive across launches" — every regression here corrupts either
/// the on-disk layout or the wire shape.
@Suite("AttachmentStorage — content-addressed blob store (issue #22)")
struct AttachmentStorageTests {
    private func tempStorage() -> AttachmentStorage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("attach-storage-\(UUID().uuidString)", isDirectory: true)
        return AttachmentStorage(directory: dir)
    }

    @Test("write() returns a 64-char lowercase hex hash matching the SHA-256 of the input")
    func writeReturnsHexHash() throws {
        let storage = tempStorage()
        let bytes = Data("hello world".utf8)
        let hash = try storage.write(bytes)
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(AttachmentStorage.isHexHash(hash))
        // Independent SHA-256 (CryptoKit) of the same bytes must match.
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(hash == expected)
    }

    @Test("write() places bytes at directory/<hex> on disk")
    func writeCreatesBlobFile() throws {
        let storage = tempStorage()
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hash = try storage.write(bytes)
        let blobURL = storage.url(forHash: hash)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))
        let readBack = try #require(storage.read(hash: hash))
        #expect(readBack == bytes)
    }

    @Test("write() is idempotent — same bytes → same hash → overwrites cleanly")
    func writeIsIdempotent() throws {
        let storage = tempStorage()
        let bytes = Data("repeat".utf8)
        let first = try storage.write(bytes)
        let second = try storage.write(bytes)
        #expect(first == second)
        // Still exactly one file in the dir.
        let entries = try FileManager.default.contentsOfDirectory(
            at: storage.directory,
            includingPropertiesForKeys: nil
        )
        #expect(entries.count == 1)
    }

    @Test("write() creates the directory on demand — no eager mkdir at init")
    func writeCreatesDirectoryLazily() throws {
        let storage = tempStorage()
        // Brand-new tmp dir doesn't exist yet.
        #expect(!FileManager.default.fileExists(atPath: storage.directory.path))
        _ = try storage.write(Data([0x01]))
        #expect(FileManager.default.fileExists(atPath: storage.directory.path))
    }

    @Test("read() returns nil for a hash that's never been written")
    func readMissingReturnsNil() {
        let storage = tempStorage()
        let missing = String(repeating: "0", count: 64)
        #expect(storage.read(hash: missing) == nil)
    }

    @Test("sweep() deletes orphans, keeps referenced blobs, and skips unknown filenames")
    func sweepOrphansOnly() throws {
        let storage = tempStorage()
        let keepHash = try storage.write(Data("keep".utf8))
        let orphanHash = try storage.write(Data("orphan".utf8))
        // Drop a non-hex stub in the dir so sweep MUST NOT touch it
        // (defence — only delete files whose name matches our naming
        // contract).
        let unrelated = storage.directory.appendingPathComponent("README", isDirectory: false)
        try Data("not a blob".utf8).write(to: unrelated)
        let deleted = storage.sweep(referenced: [keepHash])
        #expect(deleted == 1, "should delete the one orphan blob")
        #expect(storage.read(hash: keepHash) != nil)
        #expect(storage.read(hash: orphanHash) == nil)
        #expect(FileManager.default.fileExists(atPath: unrelated.path),
                "sweep must not touch non-hex-named files")
    }

    @Test("sweep() on a missing directory returns 0 without throwing")
    func sweepOnMissingDirectory() {
        let storage = tempStorage()
        // Never wrote → dir doesn't exist.
        #expect(storage.sweep(referenced: []) == 0)
    }

    @Test("isHexHash rejects wrong length, uppercase, and non-hex characters")
    func isHexHashStrict() {
        #expect(AttachmentStorage.isHexHash(String(repeating: "0", count: 64)))
        #expect(AttachmentStorage.isHexHash(String(repeating: "a", count: 64)))
        #expect(!AttachmentStorage.isHexHash(String(repeating: "0", count: 63)))
        #expect(!AttachmentStorage.isHexHash(String(repeating: "0", count: 65)))
        #expect(!AttachmentStorage.isHexHash(String(repeating: "A", count: 64))) // uppercase rejected
        #expect(!AttachmentStorage.isHexHash(String(repeating: "g", count: 64))) // non-hex
        #expect(!AttachmentStorage.isHexHash(""))
    }
}

@Suite("AttachmentBodyPrefix — body-string discriminator (issue #22)")
struct AttachmentBodyPrefixTests {
    @Test("hash() extracts the hex from a well-formed sha256: body")
    func extractGoodHash() {
        let hex = String(repeating: "a", count: 64)
        let body = "sha256:\(hex)"
        #expect(AttachmentBodyPrefix.hash(in: body) == hex)
    }

    @Test("hash() returns nil for legacy data: bodies")
    func legacyDataURLNotHash() {
        #expect(AttachmentBodyPrefix.hash(in: "data:image/png;base64,AAAA") == nil)
    }

    @Test("hash() returns nil for malformed sha256: bodies (wrong hex length)")
    func malformedHashRejected() {
        #expect(AttachmentBodyPrefix.hash(in: "sha256:short") == nil)
        #expect(AttachmentBodyPrefix.hash(in: "sha256:\(String(repeating: "a", count: 63))") == nil)
        #expect(AttachmentBodyPrefix.hash(in: "sha256:\(String(repeating: "A", count: 64))") == nil) // uppercase
    }
}

@Suite("Attachment.imageData / imageDataURL — read path (issue #22)")
struct AttachmentImageReadPathTests {
    private func tempStorage() -> AttachmentStorage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("attach-storage-\(UUID().uuidString)", isDirectory: true)
        return AttachmentStorage(directory: dir)
    }

    @Test("imageData() resolves hash-ref bodies via storage")
    func hashRefRoundTrips() throws {
        let storage = tempStorage()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let hash = try storage.write(bytes)
        let att = Attachment(
            kind: .image,
            filename: "x.png",
            mime: "image/png",
            body: "sha256:\(hash)",
            sizeBytes: bytes.count
        )
        #expect(att.imageData(using: storage) == bytes)
    }

    @Test("imageData() decodes legacy data-URL bodies inline (back-compat)")
    func legacyDataURLDecodes() {
        let bytes: [UInt8] = [0xDE, 0xAD]
        let b64 = Data(bytes).base64EncodedString()
        let att = Attachment(
            kind: .image,
            filename: "x.png",
            mime: "image/png",
            body: "data:image/png;base64,\(b64)",
            sizeBytes: bytes.count
        )
        #expect(att.imageData(using: AttachmentStorage(directory: URL(fileURLWithPath: "/tmp/unused"))) == Data(bytes))
    }

    @Test("imageData() returns nil for textFile kind")
    func textFileNeverYieldsImageData() {
        let att = Attachment(
            kind: .textFile,
            filename: "notes.txt",
            mime: "text/plain",
            body: "hello",
            sizeBytes: 5
        )
        #expect(att.imageData(using: AttachmentStorage(directory: URL(fileURLWithPath: "/tmp/unused"))) == nil)
    }

    @Test("imageData() returns nil for a hash-ref pointing at a missing blob")
    func missingBlobReturnsNil() {
        let storage = AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString)"))
        let att = Attachment(
            kind: .image,
            filename: "x.png",
            mime: "image/png",
            body: "sha256:\(String(repeating: "0", count: 64))",
            sizeBytes: 0
        )
        #expect(att.imageData(using: storage) == nil)
    }

    @Test("imageDataURL() rebuilds a data URL from disk for hash-ref bodies")
    func hashRefRebuildsDataURL() throws {
        let storage = tempStorage()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let hash = try storage.write(bytes)
        let att = Attachment(
            kind: .image,
            filename: "x.png",
            mime: "image/png",
            body: "sha256:\(hash)",
            sizeBytes: bytes.count
        )
        let dataURL = try #require(att.imageDataURL(using: storage))
        #expect(dataURL == "data:image/png;base64,\(bytes.base64EncodedString())")
    }

    @Test("imageDataURL() passes legacy data-URL bodies through unchanged")
    func legacyDataURLPassThrough() {
        let body = "data:image/png;base64,AAAA"
        let att = Attachment(
            kind: .image,
            filename: "x.png",
            mime: "image/png",
            body: body,
            sizeBytes: 3
        )
        #expect(att.imageDataURL(using: AttachmentStorage(directory: URL(fileURLWithPath: "/tmp/unused"))) == body)
    }
}
