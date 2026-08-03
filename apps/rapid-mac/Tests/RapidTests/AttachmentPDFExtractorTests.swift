import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import Rapid

/// PDF attachment ingest — extract-the-text-layer-at-ingest design.
///
/// Layered like the implementation: the ``plan`` truth table is pinned
/// against plain string arrays (no PDFKit, no fixtures), and the
/// ``extract`` shim is pinned against real PDFs generated fully
/// in-code — a CGContext PDF consumer for text-layer documents,
/// ``PDFPage(image:)`` for genuinely scanned-style pages, and
/// ``PDFDocument.write(to:withOptions:)`` with password options for
/// the locked case. No binary fixtures anywhere.
@Suite("AttachmentPDFExtractor — PDF ingest truth table")
struct AttachmentPDFExtractorTests {

    // MARK: - Fixture builders (all in-code)

    private func tempURL(ext: String = "pdf") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-extractor-test-\(UUID().uuidString).\(ext)")
    }

    /// Text-layer PDF: one page per string, drawn with Core Text so
    /// ``PDFPage.string`` genuinely returns it.
    private func makeTextPDF(pages: [String]) throws -> URL {
        let url = tempURL()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: mediaBox.insetBy(dx: 36, dy: 36), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), path, nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Image-only pages — the real "scanned document" shape: the pages
    /// exist and render, but there is no text layer to extract.
    private func makeScannedPDF(pageCount: Int) throws -> URL {
        let url = tempURL()
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
                NSColor.systemRed.setFill()
                rect.fill()
                return true
            }
            guard let page = PDFPage(image: image) else {
                throw CocoaError(.fileWriteUnknown)
            }
            document.insert(page, at: index)
        }
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    // MARK: - plan: scanned floor

    @Test("plan — all-empty pages read as scanned, and the 40-char floor is exact")
    func planScannedFloor() {
        // Genuine scan: nils and empties only.
        #expect(
            AttachmentPDFExtractor.plan(pageTexts: [nil, "", "   \n"], totalPages: 3)
                == .scanned
        )
        // 39 meaningful chars → still scanned; 40 → extracted. The
        // floor is absolute, not per-page, so a deck of images with
        // one caption passes.
        let thirtyNine = String(repeating: "a", count: 39)
        let forty = String(repeating: "a", count: 40)
        #expect(
            AttachmentPDFExtractor.plan(pageTexts: [thirtyNine, nil], totalPages: 2)
                == .scanned
        )
        #expect(
            AttachmentPDFExtractor.plan(pageTexts: [forty, nil], totalPages: 2)
                == .extracted(text: forty, pagesIncluded: 2, truncated: false)
        )
        // Whitespace doesn't count toward the floor.
        let paddedThirtyNine = "  " + thirtyNine + "\n\n"
        #expect(
            AttachmentPDFExtractor.plan(pageTexts: [paddedThirtyNine], totalPages: 1)
                == .scanned
        )
    }

    // MARK: - plan: truncation

    @Test("plan — pages are included whole while they fit; the cut is a page boundary")
    func planTruncationBoundary() {
        let pageA = String(repeating: "a", count: 100)
        let pageB = String(repeating: "b", count: 100)
        let pageC = String(repeating: "c", count: 100)

        // All three fit (100+2+100+2+100 = 304 ≤ 400): no truncation.
        #expect(
            AttachmentPDFExtractor.plan(
                pageTexts: [pageA, pageB, pageC], totalPages: 3, maxChars: 400
            ) == .extracted(
                text: pageA + "\n\n" + pageB + "\n\n" + pageC,
                pagesIncluded: 3,
                truncated: false
            )
        )
        // Cap admits only two (100+2+100 = 202 ≤ 250; +2+100 would be 304): page-boundary cut.
        #expect(
            AttachmentPDFExtractor.plan(
                pageTexts: [pageA, pageB, pageC], totalPages: 3, maxChars: 250
            ) == .extracted(
                text: pageA + "\n\n" + pageB,
                pagesIncluded: 2,
                truncated: true
            )
        )
        // The walk may have read fewer pages than the document holds
        // (caps stop it early) — totalPages is what makes `truncated`
        // honest in that case.
        #expect(
            AttachmentPDFExtractor.plan(
                pageTexts: [pageA, pageB], totalPages: 50, maxChars: 400
            ) == .extracted(
                text: pageA + "\n\n" + pageB,
                pagesIncluded: 2,
                truncated: true
            )
        )
    }

    @Test("plan — a first page that alone overflows the cap ships its prefix, not nothing")
    func planFirstPageOverflow() {
        let huge = String(repeating: "x", count: 500)
        let plan = AttachmentPDFExtractor.plan(
            pageTexts: [huge, "second"], totalPages: 2, maxChars: 200
        )
        #expect(
            plan == .extracted(
                text: String(repeating: "x", count: 200),
                pagesIncluded: 0,
                truncated: true
            )
        )
    }

    // MARK: - extract: the PDFKit shim against real files

    @Test("extract — a text-layer PDF comes back with its text and page count")
    func extractHappyPath() throws {
        let url = try makeTextPDF(pages: [
            "Rent for the apartment is 1200 euro per month, due on the first.",
            "The deposit equals two months of rent and is refundable.",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .extracted(let text, let pagesIncluded, let totalPages, let truncated) =
            AttachmentPDFExtractor.extract(from: url)
        else {
            Issue.record("expected .extracted, got \(AttachmentPDFExtractor.extract(from: url))")
            return
        }
        #expect(text.contains("1200 euro"))
        #expect(text.contains("refundable"))
        #expect(pagesIncluded == 2)
        #expect(totalPages == 2)
        #expect(truncated == false)
    }

    @Test("extract — image-only pages are rejected as scanned")
    func extractScanned() throws {
        let url = try makeScannedPDF(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AttachmentPDFExtractor.extract(from: url) == .scanned)
    }

    @Test("extract — a password-protected PDF is rejected as locked")
    func extractPasswordProtected() throws {
        // Build a locked file by writing any one-page document with
        // password options.
        let plain = try makeScannedPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: plain) }
        guard let document = PDFDocument(url: plain) else {
            Issue.record("fixture unreadable")
            return
        }
        let locked = tempURL()
        defer { try? FileManager.default.removeItem(at: locked) }
        let wrote = document.write(to: locked, withOptions: [
            .userPasswordOption: "segreto",
            .ownerPasswordOption: "segreto",
        ])
        #expect(wrote)
        #expect(AttachmentPDFExtractor.extract(from: locked) == .passwordProtected)
    }

    @Test("extract — a renamed HTML file does not ride in through the PDF branch")
    func extractRenamedHTML() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html><body>not a pdf</body></html>".utf8).write(to: url)
        #expect(AttachmentPDFExtractor.extract(from: url) == .notAPDF)
    }

    @Test("extract — bytes that fake the %PDF- header but aren't a PDF are unreadable")
    func extractCorrupt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.7 this is not actually a pdf body".utf8).write(to: url)
        #expect(AttachmentPDFExtractor.extract(from: url) == .unreadable)
    }

    @Test("extract — the file-size ceiling rejects before any parsing")
    func extractTooLarge() throws {
        let url = try makeTextPDF(pages: ["small but over a tiny test ceiling"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            AttachmentPDFExtractor.extract(from: url, maxFileBytes: 10) == .tooLarge
        )
    }

    @Test("extract — the char cap truncates a real multi-page document on a page boundary")
    func extractTruncatesReal() throws {
        let url = try makeTextPDF(pages: [
            "First page body with some real words on it.",
            "Second page body, also fairly short.",
            "Third page body that should be cut off.",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .extracted(let text, let pagesIncluded, let totalPages, let truncated) =
            AttachmentPDFExtractor.extract(from: url, maxChars: 90)
        else {
            Issue.record("expected .extracted")
            return
        }
        #expect(truncated)
        #expect(totalPages == 3)
        #expect(pagesIncluded < 3)
        #expect(text.contains("First page"))
        #expect(!text.contains("Third page"))
    }

    // MARK: - Copy pins

    @Test("truncation note names the file and the page split, and is model-facing prose")
    func truncationNotePinned() {
        #expect(
            AttachmentPDFExtractor.truncationNote(
                filename: "report.pdf", pagesIncluded: 12, totalPages: 87
            ) == "[Note: showing the first 12 of 87 pages of report.pdf; the rest was omitted to fit the model's context window.]\n\n"
        )
        // The page-1-overflow variant says "beginning", not "first 0 pages".
        let overflow = AttachmentPDFExtractor.truncationNote(
            filename: "contract.pdf", pagesIncluded: 0, totalPages: 3
        )
        #expect(overflow.contains("beginning of contract.pdf"))
        #expect(!overflow.contains("first 0"))
    }

    @Test("every rejection message names the file")
    func rejectionMessagesNameTheFile() {
        let name = "contratto d'affitto.pdf"
        for message in [
            AttachmentPDFExtractor.notAPDFMessage(filename: name),
            AttachmentPDFExtractor.tooLargeMessage(filename: name),
            AttachmentPDFExtractor.unreadableMessage(filename: name),
            AttachmentPDFExtractor.passwordProtectedMessage(filename: name),
            AttachmentPDFExtractor.scannedMessage(filename: name),
        ] {
            #expect(message.contains(name))
        }
        // The scanned copy must say what's wrong in user words, and the
        // locked copy must offer the way out.
        #expect(AttachmentPDFExtractor.scannedMessage(filename: name).contains("scanned"))
        #expect(AttachmentPDFExtractor.passwordProtectedMessage(filename: name).contains("password"))
    }

    // MARK: - Integration seams

    @Test("extracted text rides the existing textFile wire path")
    func extractedTextReachesTheWire() throws {
        // Long enough to clear the 40-char scanned floor — a one-line
        // page below it is indistinguishable from scanner noise.
        let url = try makeTextPDF(pages: [
            "The total invoice amount is 4321 euro, payable within thirty days of receipt.",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .extracted(let text, _, _, _) = AttachmentPDFExtractor.extract(from: url) else {
            Issue.record("expected .extracted")
            return
        }
        let attachment = Attachment(
            kind: .textFile,
            filename: "invoice.pdf",
            mime: "text/plain",
            body: text,
            sizeBytes: 1234
        )
        let prose = ChatStreamClient.composeProseWithFileAttachments(
            text: "How much is the invoice?",
            attachments: [attachment]
        )
        #expect(prose.contains("invoice.pdf"))
        #expect(prose.contains("4321 euro"))
    }

    @Test("makeAttachment refuses .pdf so the UTF-8 fallback can't leak raw PDF source")
    func makeAttachmentRefusesPDF() throws {
        // An ASCII-only file named .pdf WOULD decode as UTF-8 and ride
        // in as raw "%PDF-…" source without the guard.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.4 fake but fully ASCII".utf8).write(to: url)
        #expect(AttachmentIngest.makeAttachment(from: url) == nil)
    }
}
