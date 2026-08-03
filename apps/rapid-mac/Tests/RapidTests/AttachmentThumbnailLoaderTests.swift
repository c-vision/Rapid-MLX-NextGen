import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Rapid

/// Issue #479: pin the off-main-thread thumbnail loader. The loader is
/// the single unit between "a chip needs a 28 pt thumbnail" and "bytes
/// are on disk", so every regression here either re-introduces the
/// main-thread decode (perf) or corrupts the rendered thumbnail
/// (orientation / size / staleness). SwiftUI pixels aren't
/// introspectable, so we test the loader/cache/downsample directly.
@Suite("AttachmentThumbnailLoader — downsample + content-addressed cache (issue #479)")
struct AttachmentThumbnailLoaderTests {
    // MARK: - Fixtures

    private func tempStorage() -> AttachmentStorage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("thumb-storage-\(UUID().uuidString)", isDirectory: true)
        return AttachmentStorage(directory: dir)
    }

    /// Solid-colour `CGImage` at the requested pixel dims.
    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Encode a `CGImage` to PNG bytes.
    private func makePNG(width: Int, height: Int) -> Data {
        let img = makeCGImage(width: width, height: height)
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Encode a `CGImage` to JPEG bytes, tagging the given EXIF
    /// orientation (1 = up, 6 = rotate 90° CW on display).
    private func makeJPEG(width: Int, height: Int, orientation: Int) -> Data {
        let img = makeCGImage(width: width, height: height)
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Await a semaphore from an async test body. `DispatchSemaphore.wait()`
    /// is banned in async contexts (it blocks a thread), so we bounce the
    /// blocking wait through a detached GCD queue and resume on completion.
    private func waitAsync(_ sem: DispatchSemaphore) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                sem.wait()
                cont.resume()
            }
        }
    }

    private func imageAttachment(hash: String, sizeBytes: Int = 0) -> Attachment {
        Attachment(
            kind: .image,
            filename: "shot.png",
            mime: "image/png",
            body: "sha256:\(hash)",
            sizeBytes: sizeBytes
        )
    }

    // MARK: - Downsample

    @Test("Large source downsamples so the longer side == maxPixel")
    func downsampleCapsLongerSide() async throws {
        let storage = tempStorage()
        let png = makePNG(width: 400, height: 200)
        let hash = try storage.write(png)
        let loader = AttachmentThumbnailLoader(storage: storage)

        let cg = try #require(await loader.thumbnail(for: imageAttachment(hash: hash), maxPixel: 64))
        // 400×200 capped at 64 → 64×32. Longer side is exactly the cap.
        #expect(max(cg.width, cg.height) == 64)
        #expect(cg.width == 64)
        #expect(cg.height == 32)
    }

    @Test("Small source is not upscaled past its native size")
    func downsampleNeverUpscales() async throws {
        let storage = tempStorage()
        // 20×10 native, but we ask for a 64 px thumbnail.
        let png = makePNG(width: 20, height: 10)
        let hash = try storage.write(png)
        let loader = AttachmentThumbnailLoader(storage: storage)

        let cg = try #require(await loader.thumbnail(for: imageAttachment(hash: hash), maxPixel: 64))
        #expect(max(cg.width, cg.height) <= 64, "must never upscale a small source")
        #expect(cg.width == 20)
        #expect(cg.height == 10)
    }

    // MARK: - Cache

    @Test("Second call for the same hash hits the cache — no re-decode")
    func cacheHitSkipsDecode() async throws {
        let storage = tempStorage()
        let hash = try storage.write(makePNG(width: 120, height: 120))
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = imageAttachment(hash: hash)

        let first = try #require(await loader.thumbnail(for: att, maxPixel: 56))
        let second = try #require(await loader.thumbnail(for: att, maxPixel: 56))

        // Only one real decode; second call served from cache.
        #expect(await loader.decodeCount == 1)
        // Same CGImage instance — proves it came from the cache, not a
        // fresh decode (which would be a distinct object).
        #expect(first === second)
    }

    @Test("Different maxPixel for the same hash is a distinct cache entry")
    func distinctPixelSizeIsDistinctEntry() async throws {
        let storage = tempStorage()
        let hash = try storage.write(makePNG(width: 400, height: 200))
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = imageAttachment(hash: hash)

        let small = try #require(await loader.thumbnail(for: att, maxPixel: 32))
        let large = try #require(await loader.thumbnail(for: att, maxPixel: 64))
        #expect(await loader.decodeCount == 2)
        #expect(max(small.width, small.height) == 32)
        #expect(max(large.width, large.height) == 64)
    }

    // MARK: - In-flight coalescing

    @Test("N concurrent calls for the same hash decode exactly once")
    func concurrentCallsCoalesce() async throws {
        let storage = tempStorage()
        let hash = try storage.write(makePNG(width: 512, height: 512))
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = imageAttachment(hash: hash)

        let results: [CGImage?] = await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<16 {
                group.addTask { await loader.thumbnail(for: att, maxPixel: 56) }
            }
            var acc: [CGImage?] = []
            for await r in group { acc.append(r) }
            return acc
        }

        // Exactly one decode despite 16 concurrent requests.
        #expect(await loader.decodeCount == 1)
        #expect(results.count == 16)
        let decoded = results.compactMap { $0 }
        #expect(decoded.count == 16, "every caller got a non-nil thumbnail")
        // All callers share the one decoded instance.
        let first = try #require(decoded.first)
        #expect(decoded.allSatisfy { $0 === first })
    }

    @Test("Same-key coalescing invokes the decoder exactly once even while a decode is in-flight")
    func coalescingInvokesDecoderOnce() async throws {
        // Inject a decoder that blocks mid-decode so a second same-key
        // caller MUST arrive while the first decode is still running.
        // The decoder is invoked exactly once regardless of whether the
        // second caller coalesces onto the in-flight task or lands on
        // the freshly-cached result — the only way it runs twice is a
        // broken cache+in-flight gap.
        let invocations = DecodeInvocationCounter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let img = makeCGImage(width: 8, height: 8)
        let loader = AttachmentThumbnailLoader(storage: tempStorage()) { _, _, _ in
            invocations.bump()
            started.signal()
            release.wait()
            return img
        }
        let att = imageAttachment(hash: String(repeating: "c", count: 64))

        async let r1 = loader.thumbnail(for: att, maxPixel: 40)
        await waitAsync(started) // decode 1 is now in-flight, blocked on `release`
        async let r2 = loader.thumbnail(for: att, maxPixel: 40)
        release.signal()
        let (a, b) = await (r1, r2)

        #expect(invocations.value == 1, "decoder must run once for two same-key callers")
        #expect(await loader.decodeCount == 1)
        #expect(a === b)
        #expect(a === img)
    }

    @Test("Decodes for different keys run concurrently — decode is off the actor")
    func decodesRunOffActor() async throws {
        // If the decode ran ON the loader actor (e.g. a plain `Task {}`
        // inheriting actor isolation), the second key's decode could
        // not start until the first returned, so only ONE `started`
        // signal would arrive and the second wait would time out. With
        // `Task.detached` both decodes run concurrently on the generic
        // executor and both signal. Bounded so a regression fails
        // instead of hanging.
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let img = makeCGImage(width: 8, height: 8)
        let loader = AttachmentThumbnailLoader(storage: tempStorage()) { _, _, _ in
            started.signal()
            release.wait()
            return img
        }
        let attA = imageAttachment(hash: String(repeating: "a", count: 64))
        let attB = imageAttachment(hash: String(repeating: "b", count: 64))

        async let a = loader.thumbnail(for: attA, maxPixel: 40)
        async let b = loader.thumbnail(for: attB, maxPixel: 40)

        // Both decodes must be able to be in-flight simultaneously.
        let bothStarted: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let first = started.wait(timeout: .now() + 5)
                let second = started.wait(timeout: .now() + 5)
                cont.resume(returning: first == .success && second == .success)
            }
        }
        release.signal()
        release.signal()
        _ = await (a, b)

        #expect(bothStarted, "two different-key decodes must run concurrently (decode is off-actor)")
    }

    // MARK: - Missing / non-image

    @Test("Missing blob → nil (falls back to placeholder)")
    func missingBlobReturnsNil() async {
        let storage = tempStorage()
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = imageAttachment(hash: String(repeating: "0", count: 64))
        #expect(await loader.thumbnail(for: att, maxPixel: 56) == nil)
    }

    @Test("Non-image attachment → nil without touching disk")
    func textFileReturnsNil() async {
        let storage = tempStorage()
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = Attachment(
            kind: .textFile,
            filename: "notes.txt",
            mime: "text/plain",
            body: "hello",
            sizeBytes: 5
        )
        #expect(await loader.thumbnail(for: att, maxPixel: 56) == nil)
        #expect(await loader.decodeCount == 0)
    }

    // MARK: - Legacy data: bodies

    @Test("Legacy data: body decodes via CreateWithData fallback")
    func legacyDataURLDecodes() async throws {
        // No hash-ref → the loader must fall back to the in-memory
        // `data:` decode path (CGImageSourceCreateWithData).
        let png = makePNG(width: 200, height: 100)
        let att = Attachment(
            kind: .image,
            filename: "legacy.png",
            mime: "image/png",
            body: "data:image/png;base64,\(png.base64EncodedString())",
            sizeBytes: png.count
        )
        // Storage directory is irrelevant for a data: body.
        let loader = AttachmentThumbnailLoader(storage: tempStorage())

        let cg = try #require(await loader.thumbnail(for: att, maxPixel: 50))
        #expect(max(cg.width, cg.height) == 50)
    }

    @Test("Legacy data: bodies key on attachment id (distinct ids don't collide)")
    func legacyDataURLKeysOnId() async throws {
        let png = makePNG(width: 100, height: 100)
        let b64 = png.base64EncodedString()
        let a = Attachment(kind: .image, filename: "a.png", mime: "image/png",
                           body: "data:image/png;base64,\(b64)", sizeBytes: png.count)
        let b = Attachment(kind: .image, filename: "b.png", mime: "image/png",
                           body: "data:image/png;base64,\(b64)", sizeBytes: png.count)
        let loader = AttachmentThumbnailLoader(storage: tempStorage())

        _ = try #require(await loader.thumbnail(for: a, maxPixel: 40))
        _ = try #require(await loader.thumbnail(for: b, maxPixel: 40))
        // Distinct ids → distinct keys → two decodes (they don't share
        // a content hash because legacy bodies have none).
        #expect(await loader.decodeCount == 2)
    }

    // MARK: - Orientation

    @Test("EXIF orientation 6 downsamples with swapped dims (WithTransform bakes rotation)")
    func exifOrientationIsBakedIn() async throws {
        let storage = tempStorage()
        // Landscape raw pixels (4:1). Orientation 6 = rotate 90° CW on
        // display → the transformed thumbnail must be PORTRAIT.
        let jpeg = makeJPEG(width: 240, height: 60, orientation: 6)
        let hash = try storage.write(jpeg)
        let loader = AttachmentThumbnailLoader(storage: storage)
        let att = Attachment(kind: .image, filename: "rot.jpg", mime: "image/jpeg",
                             body: "sha256:\(hash)", sizeBytes: jpeg.count)

        let cg = try #require(await loader.thumbnail(for: att, maxPixel: 120))
        // Transform applied: the long side (240 raw) becomes the
        // HEIGHT, so height > width. Without WithTransform this would
        // be landscape (width > height) and the chip would show a
        // sideways screenshot.
        #expect(cg.height > cg.width, "orientation-6 image must render upright (portrait)")
        #expect(max(cg.width, cg.height) == 120)
    }
}

/// Thread-safe decode-invocation counter. The injected decoder runs on
/// the generic executor (off the loader actor), so a plain `Int` would
/// race; a lock keeps the count sound.
private final class DecodeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
