import Foundation
import Testing
@testable import Rapid

/// Pin the attachment ingest path. ``AttachmentIngest.makeAttachment``
/// is the single point that decides whether a dropped file becomes
/// an image (issue #22: hash-ref'd to the blob store) or a text
/// file (UTF-8 inlined) — or gets rejected. Regressions here would
/// silently change what the UI accepts at the drop edge.
@Suite("AttachmentIngest")
struct AttachmentIngestTests {
    /// Helper that writes ``bytes`` to a temp file with ``ext`` as
    /// the extension and returns the URL. Caller is responsible for
    /// any cleanup; ``/tmp`` is fine for transient tests.
    private func tempFile(ext: String, bytes: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("attach-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url)
        return url
    }

    /// Issue #22: per-test isolated attachment storage so tests don't
    /// leak blobs into the user's real ``~/Library/Application Support/Rapid/attachments``.
    private func tempStorage() -> AttachmentStorage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("attach-storage-\(UUID().uuidString)", isDirectory: true)
        return AttachmentStorage(directory: dir)
    }

    @Test("PNG byte stream becomes an image attachment with sha256 hash-ref body (issue #22)")
    func pngBecomesImage() throws {
        // Smallest valid PNG (1x1 transparent). We only need it to
        // parse as bytes; ingest doesn't actually decode the image.
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let url = try tempFile(ext: "png", bytes: Data(pngHeader))
        let storage = tempStorage()
        let att = try #require(AttachmentIngest.makeAttachment(from: url, storage: storage))
        #expect(att.kind == .image)
        #expect(att.mime == "image/png")
        // Issue #22: body now carries a content-addressed hash ref
        // (``sha256:<hex>``) instead of a base64 data URL. The bytes
        // live in ``AttachmentStorage`` at the matching hash.
        #expect(att.body.hasPrefix(AttachmentBodyPrefix.hashRef))
        let hash = try #require(AttachmentBodyPrefix.hash(in: att.body))
        #expect(hash == AttachmentStorage.sha256Hex(Data(pngHeader)),
                "body hash must match sha256 of the input bytes")
        // Blob must be on disk at <storage>/<hex>.
        let blobURL = storage.url(forHash: hash)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))
        // Resolving the data URL via the storage must reproduce the
        // wire-shape pre-#22 callers would have built directly.
        let resolved = try #require(att.imageDataURL(using: storage))
        #expect(resolved.hasPrefix("data:image/png;base64,"))
        #expect(att.sizeBytes == pngHeader.count)
    }

    @Test("UTF-8 source file becomes a text-file attachment")
    func utf8BecomesTextFile() throws {
        let url = try tempFile(ext: "txt", bytes: Data("hello world".utf8))
        let att = try #require(AttachmentIngest.makeAttachment(from: url, storage: tempStorage()))
        #expect(att.kind == .textFile)
        #expect(att.body == "hello world")
        #expect(att.mime == "text/plain")
    }

    @Test("Oversize file is rejected")
    func oversizeRejected() throws {
        let big = Data(repeating: 0x41, count: AttachmentIngest.maxAttachmentBytes + 16)
        let url = try tempFile(ext: "txt", bytes: big)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: tempStorage()) == nil)
    }

    @Test("Binary file with no extension we recognize is rejected")
    func binaryRejected() throws {
        // 0xFF 0xD8 are the JPEG SOI bytes, but the file ends in
        // ``.bin`` so the extension lookup fails — and 0xFF isn't
        // valid UTF-8, so the text fallback also fails. Net: reject.
        let url = try tempFile(ext: "bin", bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(AttachmentIngest.makeAttachment(from: url, storage: tempStorage()) == nil)
    }

    @Test("Image extension with non-image bytes is rejected")
    func spoofedImageExtensionRejected() throws {
        let url = try tempFile(ext: "png", bytes: Data("<html><script>alert(1)</script></html>".utf8))
        #expect(AttachmentIngest.makeAttachment(from: url, storage: tempStorage()) == nil)
    }

    @Test("HEIF extension maps and validates as an image attachment with sha256 body (issue #22)")
    func heifBecomesImage() throws {
        let bytes = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // ftyp
            0x6D, 0x69, 0x66, 0x31, // mif1
            0x00, 0x00, 0x00, 0x00,
            0x68, 0x65, 0x69, 0x66, // heif
            0x6D, 0x69, 0x61, 0x66,
        ])
        let url = try tempFile(ext: "heif", bytes: bytes)
        let storage = tempStorage()
        let att = try #require(AttachmentIngest.makeAttachment(from: url, storage: storage))
        #expect(att.kind == .image)
        #expect(att.mime == "image/heif")
        // Issue #22: hash-ref body, not data URL.
        #expect(att.body.hasPrefix(AttachmentBodyPrefix.hashRef))
        let hash = try #require(AttachmentBodyPrefix.hash(in: att.body))
        let blobURL = storage.url(forHash: hash)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))
        let resolved = try #require(att.imageDataURL(using: storage))
        #expect(resolved.hasPrefix("data:image/heif;base64,"))
    }

    @Test("JPEG / GIF / WEBP / HEIC / HEIF extensions all map to image kind")
    func imageMimeMapping() {
        #expect(AttachmentIngest.imageMimeForExtension("jpg") == "image/jpeg")
        #expect(AttachmentIngest.imageMimeForExtension("jpeg") == "image/jpeg")
        #expect(AttachmentIngest.imageMimeForExtension("gif") == "image/gif")
        #expect(AttachmentIngest.imageMimeForExtension("webp") == "image/webp")
        #expect(AttachmentIngest.imageMimeForExtension("heic") == "image/heic")
        #expect(AttachmentIngest.imageMimeForExtension("heif") == "image/heif")
        #expect(AttachmentIngest.imageMimeForExtension("png") == "image/png")
        #expect(AttachmentIngest.imageMimeForExtension("txt") == nil)
    }
}

/// VisionDetector decides whether the active alias can accept image
/// content. Wrong answer in either direction is user-visible:
/// false positive → silent 400 from the server, false negative →
/// user can't attach to a model that supports it.
@Suite("VisionDetector alias classification")
struct VisionDetectorTests {
    @Test("Known VLM aliases are tagged as vision")
    func visionAliases() {
        #expect(VisionDetector.isVisionAlias("qwen3-vl-4b"))
        #expect(VisionDetector.isVisionAlias("qwen3-vl-7b"))
        #expect(VisionDetector.isVisionAlias("llava-1.6-mistral-7b"))
        #expect(VisionDetector.isVisionAlias("internvl-2-8b"))
        #expect(VisionDetector.isVisionAlias("gemma3-vl-12b"))
    }

    @Test("Text-only aliases are NOT tagged as vision")
    func textOnlyAliases() {
        #expect(!VisionDetector.isVisionAlias("qwen3.5-4b"))
        #expect(!VisionDetector.isVisionAlias("qwen3.6-27b"))
        #expect(!VisionDetector.isVisionAlias("gemma-3-12b"))
        #expect(!VisionDetector.isVisionAlias("llama-3.2-8b"))
        #expect(!VisionDetector.isVisionAlias(""))
    }
}

/// Defense-in-depth gate for the image-upload affordance. The 4
/// combinations of (server modality, alias-name heuristic) below
/// pin the rapid-mlx F-303 backstop: a server that lies about an
/// MLLM alias's modality (e.g. ``gemma-3n-e4b-4bit`` reported as
/// ``"text"``) must still let the user attach images; a text-only
/// alias must not get the upload affordance even if the server is
/// silent. Covers cycle-5 fuzz-stress F-506.
@Suite("VisionDetector.supportsImageAttachments combinations")
struct VisionDetectorSupportsImageAttachmentsTests {
    @Test("server modality says multimodal → can attach (alias label doesn't matter)")
    func serverModalityWins() {
        // (a) modality reports a multimodal label → can attach even on
        // an alias the desktop hasn't been taught about. This is the
        // "new VLM family ships" path — desktop doesn't need a bump.
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "mllm"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "vision"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "image"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "multimodal"
        ))
        // Case-insensitive + whitespace-tolerant.
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "MLLM"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "brand-new-vlm-9b",
            serverModality: "  Vision  "
        ))
    }

    @Test("server modality says text but alias is a known VLM family → can attach (F-303 backstop)")
    func aliasBackstopsServerLie() {
        // (b) The cycle-3 / cycle-5 F-303 case: rapid-mlx reports
        // ``modality:"text"`` for gemma-3n MLLM aliases. The alias
        // heuristic must rescue the user.
        #expect(VisionDetector.supportsImageAttachments(
            alias: "gemma-3n-e2b-4bit",
            serverModality: "text"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "gemma-3n-e4b-4bit",
            serverModality: "text"
        ))
        // Same backstop for the other VLM families — a future
        // rapid-mlx bug on any of these doesn't disable uploads.
        #expect(VisionDetector.supportsImageAttachments(
            alias: "qwen3-vl-4b",
            serverModality: "text"
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "llava-1.6-mistral-7b",
            serverModality: "text"
        ))
    }

    @Test("server modality says text AND alias is not a known VLM → CANNOT attach (no false positive)")
    func textOnlyStaysTextOnly() {
        // (c) Negative pin. A user picking a text-only alias on a
        // server that reports the truthful ``"text"`` modality must
        // NOT get the upload affordance — that would silently 400
        // on send.
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "qwen3.5-4b",
            serverModality: "text"
        ))
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "qwen3.6-27b",
            serverModality: "text"
        ))
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "llama-3.2-8b",
            serverModality: "text"
        ))
        // text-diffusion is a generation-only modality (Bonsai
        // Image-4B etc.) — text-to-image is not the same as
        // image-to-text input. Do not enable the upload affordance.
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "bonsai-image-4b",
            serverModality: "text-diffusion"
        ))
        // Unknown / future modality label that we haven't decided
        // is multimodal yet must NOT silently enable uploads.
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "qwen3.5-4b",
            serverModality: "audio"
        ))
    }

    @Test("missing server modality (nil / empty) → falls back to alias-name heuristic")
    func nilOrEmptyModalityFallsBackToAlias() {
        // (d) The "older Rapid-MLX server / fetch failed / chat view
        // doesn't carry the profile" path. Behaviour must be exactly
        // equivalent to ``isVisionAlias`` — that's the pre-F-506
        // contract callers depended on.
        // VLM alias → true.
        #expect(VisionDetector.supportsImageAttachments(
            alias: "qwen3-vl-4b",
            serverModality: nil
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "gemma-3n-e4b-4bit",
            serverModality: nil
        ))
        #expect(VisionDetector.supportsImageAttachments(
            alias: "qwen3-vl-4b",
            serverModality: ""
        ))
        // Text-only alias → false.
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "qwen3.5-4b",
            serverModality: nil
        ))
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "llama-3.2-8b",
            serverModality: ""
        ))
        #expect(!VisionDetector.supportsImageAttachments(
            alias: "",
            serverModality: nil
        ))
        // Default parameter exercise: omitting serverModality must
        // behave the same as passing nil.
        #expect(VisionDetector.supportsImageAttachments(alias: "qwen3-vl-4b"))
        #expect(!VisionDetector.supportsImageAttachments(alias: "qwen3.5-4b"))
    }
}

/// Wire-shape encoding. The OpenAI multimodal spec accepts either a
/// plain string OR an array of typed parts for the ``content`` field.
/// We branch at encode time; a regression here silently sends an
/// image attachment as the literal string "data:image/png;base64,..."
/// which the server can't route.
@Suite("Wire.Message multimodal encoding")
struct WireMessageEncodingTests {
    private func encoded(_ message: Wire.Message) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(message)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("Text-only user message encodes content as a string")
    func textOnlyEncodesString() throws {
        let msg = ChatMessage(role: .user, content: "hello", status: .complete)
        let wire = Wire.Message(from: msg)
        let json = try encoded(wire)
        #expect(json.contains("\"content\":\"hello\""))
        // No type-tagged parts in the payload.
        #expect(!json.contains("\"type\":\"text\""))
        #expect(!json.contains("\"image_url\""))
    }

    @Test("User message with image attachment encodes content as parts array")
    func imageEncodesAsParts() throws {
        let img = Attachment(
            kind: .image,
            filename: "shot.png",
            mime: "image/png",
            body: "data:image/png;base64,AAAA",
            sizeBytes: 4
        )
        let msg = ChatMessage(
            role: .user,
            content: "what's in this?",
            status: .complete,
            attachments: [img]
        )
        let wire = Wire.Message(from: msg)
        let json = try encoded(wire)
        // Parts layout: [{type:"text",...},{type:"image_url",...}]
        #expect(json.contains("\"type\":\"image_url\""))
        #expect(json.contains("\"type\":\"text\""))
        #expect(json.contains("\"url\":\"data:image\\/png;base64,AAAA\""))
    }

    @Test("Text-file attachment is inlined into prose, not turned into parts")
    func textFileInlinesProse() throws {
        let f = Attachment(
            kind: .textFile,
            filename: "main.swift",
            mime: "text/plain",
            body: "print(1)",
            sizeBytes: 8
        )
        let msg = ChatMessage(
            role: .user,
            content: "explain",
            status: .complete,
            attachments: [f]
        )
        let wire = Wire.Message(from: msg)
        let json = try encoded(wire)
        // String content (no parts array) — text files don't trigger
        // the multimodal branch.
        #expect(!json.contains("\"type\":\"image_url\""))
        // Bolded filename header + fenced code block reach the prose,
        // and so does the file body and the user's prompt.
        #expect(json.contains("**main.swift**"))
        #expect(json.contains("```swift"))
        #expect(json.contains("print(1)"))
        #expect(json.contains("explain"))
    }

    @Test("Mixed image + text-file uses parts AND inlines the text file in the prose")
    func mixedAttachmentsProse() throws {
        let img = Attachment(kind: .image, filename: "s.png", mime: "image/png",
                             body: "data:image/png;base64,AAAA", sizeBytes: 4)
        let txt = Attachment(kind: .textFile, filename: "n.txt", mime: "text/plain",
                             body: "context line", sizeBytes: 12)
        let msg = ChatMessage(role: .user, content: "q?", status: .complete, attachments: [img, txt])
        let wire = Wire.Message(from: msg)
        let json = try encoded(wire)
        #expect(json.contains("\"type\":\"image_url\""))
        // The text part should carry the file inline.
        #expect(json.contains("**n.txt**"))
        #expect(json.contains("context line"))
    }

    @Test("composeProseWithFileAttachments is a no-op when no text files are present")
    func composeProseNoOp() {
        let img = Attachment(kind: .image, filename: "s.png", mime: "image/png",
                             body: "data:image/png;base64,A", sizeBytes: 1)
        let result = ChatStreamClient.composeProseWithFileAttachments(
            text: "hi", attachments: [img]
        )
        #expect(result == "hi")
    }

    @Test("Empty user prose with one attached file falls back to a Summarize instruction")
    func emptyTextDefaultsToSummarize() {
        let f = Attachment(kind: .textFile, filename: "log.txt", mime: "text/plain",
                           body: "boot complete\n", sizeBytes: 14)
        let out = ChatStreamClient.composeProseWithFileAttachments(text: "   ", attachments: [f])
        #expect(out.contains("Please summarize this file."))
    }

    @Test("Fence length grows when file body contains long backtick runs")
    func fenceAdaptsToBackticks() {
        // A file documenting markdown can contain its own 3-backtick
        // fences. The output fence must be longer or we'd close the
        // surrounding code block early.
        let body = "Here is a fence: ``` and another: ``````"
        let fence = ChatStreamClient.pickFence(for: body)
        // Longest run is 6 → fence must be at least 7.
        #expect(fence.count >= 7)
        #expect(fence.allSatisfy { $0 == "`" })
    }

    @Test("Plain content gets the standard 3-backtick fence")
    func fenceMinIsThree() {
        let fence = ChatStreamClient.pickFence(for: "print(1)\nprint(2)\n")
        #expect(fence == "```")
    }

    @Test("Known extensions get language hints; unknown ones get empty string")
    func languageHintsCoverCommonExtensions() {
        #expect(ChatStreamClient.languageHint(forFilename: "foo.swift") == "swift")
        #expect(ChatStreamClient.languageHint(forFilename: "foo.py") == "python")
        #expect(ChatStreamClient.languageHint(forFilename: "foo.json") == "json")
        #expect(ChatStreamClient.languageHint(forFilename: "foo.yaml") == "yaml")
        #expect(ChatStreamClient.languageHint(forFilename: "foo.unknownext") == "")
    }
}

/// Per-format negative coverage for the magic-byte sniff gate
/// (``AttachmentIngest.validatedImageMime``). The single existing
/// "spoofed .png with HTML" case in ``AttachmentIngestTests`` proved
/// the gate exists; this suite pins every format family individually
/// so a future refactor of one branch can't silently regress while
/// the others keep passing.
///
/// Threat shape: the README claims a renamed `.html` (or any other
/// non-image) cannot ride into the multimodal payload as
/// ``data:image/...;base64,...``. Each test below names one
/// specific way an attacker / careless user could try.
@Suite("AttachmentIngest MIME-sniff negative coverage (README L80-81 gate)")
struct AttachmentMimeSniffNegativeTests {
    private func tempFile(ext: String, bytes: Data) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("sniff-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url)
        return url
    }

    // MARK: - .png

    @Test(".png with JPEG bytes is rejected")
    func pngExtWithJpegBytes() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let url = try tempFile(ext: "png", bytes: jpeg)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".png with truncated PNG signature is rejected")
    func pngExtWithTruncatedSignature() throws {
        // First 6 of the 8-byte PNG sig — should NOT pass.
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let url = try tempFile(ext: "png", bytes: truncated)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    // MARK: - .jpg / .jpeg

    @Test(".jpg with PNG bytes is rejected")
    func jpgExtWithPngBytes() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = try tempFile(ext: "jpg", bytes: png)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".jpeg with HTML bytes is rejected (renamed-html attack vector)")
    func jpegExtWithHtmlBytes() throws {
        let html = Data("<!DOCTYPE html><html><body>hi</body></html>".utf8)
        let url = try tempFile(ext: "jpeg", bytes: html)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    // MARK: - .gif

    @Test(".gif with PNG bytes is rejected")
    func gifExtWithPngBytes() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = try tempFile(ext: "gif", bytes: png)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".gif with GIF87a header is accepted (positive control)")
    func gifWithValidHeader() throws {
        let gif = Data(Array("GIF87a".utf8) + [0x01, 0x00, 0x01, 0x00])
        let url = try tempFile(ext: "gif", bytes: gif)
        let storage = AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))
        let att = try #require(AttachmentIngest.makeAttachment(from: url, storage: storage))
        #expect(att.mime == "image/gif")
    }

    // MARK: - .webp

    @Test(".webp without RIFF prefix is rejected")
    func webpExtWithoutRiff() throws {
        let bytes = Data("WEBPxxxxWEBPnotvalid".utf8)
        let url = try tempFile(ext: "webp", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".webp with RIFF prefix but wrong subtype is rejected (.wav-shaped)")
    func webpExtWithWavRiff() throws {
        // Valid RIFF header but the subtype slot says WAVE, not WEBP.
        let bytes = Data(Array("RIFF".utf8) + [0x10, 0x00, 0x00, 0x00] + Array("WAVE".utf8))
        let url = try tempFile(ext: "webp", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".webp shorter than 12 bytes is rejected (size guard)")
    func webpExtTooShort() throws {
        let bytes = Data(Array("RIFF".utf8) + [0x00])
        let url = try tempFile(ext: "webp", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    // MARK: - .heic / .heif

    @Test(".heic with no ftyp box is rejected")
    func heicWithoutFtyp() throws {
        let bytes = Data([
            0x00, 0x00, 0x00, 0x18,
            // NOT 'ftyp' — should fail at the box-type check.
            0x6D, 0x6F, 0x6F, 0x76, // 'moov'
            0x68, 0x65, 0x69, 0x63, // 'heic' brand follows
        ])
        let url = try tempFile(ext: "heic", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".heic with valid ftyp but a non-HEIF brand is rejected (e.g. mp4 'isom')")
    func heicWithMp4Brand() throws {
        let bytes = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // 'ftyp'
            0x69, 0x73, 0x6F, 0x6D, // 'isom' — mp4, NOT in HEIF brand whitelist
            0x00, 0x00, 0x00, 0x00,
            0x6D, 0x70, 0x34, 0x32, // 'mp42'
            0x6D, 0x70, 0x34, 0x31, // 'mp41'
        ])
        let url = try tempFile(ext: "heic", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }

    @Test(".heif shorter than 12 bytes is rejected (size guard)")
    func heifTooShort() throws {
        let bytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74])
        let url = try tempFile(ext: "heif", bytes: bytes)
        #expect(AttachmentIngest.makeAttachment(from: url, storage: AttachmentStorage(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("sniff-storage-\(UUID().uuidString)", isDirectory: true))) == nil)
    }
}
