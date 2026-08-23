import Foundation
import Testing

@testable import Rapid

@Suite("Chat attachment draft state")
struct ChatAttachmentDraftTests {
    @Test("consume atomically clears attachments, identity, notice, and import state")
    func consumeClearsEveryTransientField() throws {
        let image = try makeImage(name: "first.png")
        let file = try makeFile(name: "notes.txt", text: "first turn")
        let imageURL = URL(fileURLWithPath: "/tmp/first.png")
        let fileURL = URL(fileURLWithPath: "/tmp/notes.txt")
        var draft = ChatAttachmentDraft()
        draft.appendImage(image, sourceURL: imageURL)
        draft.finishFileImport([(file, fileURL)], notice: "old notice")
        draft.isImportingFiles = true

        let payload = draft.consume()

        #expect(payload.images == [image])
        #expect(payload.files == [file])
        #expect(!draft.hasAttachments)
        #expect(draft.sourcePaths.isEmpty)
        #expect(draft.notice == nil)
        #expect(!draft.isImportingFiles)
    }

    @Test("a second turn cannot inherit the first turn's image or file")
    func sequentialTurnsRemainIsolated() throws {
        let firstImage = try makeImage(name: "first.png")
        let secondImage = try makeImage(name: "second.png")
        let firstFile = try makeFile(name: "first.txt", text: "alpha")
        let secondFile = try makeFile(name: "second.txt", text: "beta")
        var draft = ChatAttachmentDraft()

        draft.appendImage(firstImage)
        draft.finishFileImport([(firstFile, URL(fileURLWithPath: "/tmp/first.txt"))], notice: nil)
        let first = draft.consume()

        draft.appendImage(secondImage)
        draft.finishFileImport([(secondFile, URL(fileURLWithPath: "/tmp/second.txt"))], notice: nil)
        let second = draft.consume()

        #expect(first.images.map(\.filename) == ["first.png"])
        #expect(first.files.map(\.filename) == ["first.txt"])
        #expect(second.images.map(\.filename) == ["second.png"])
        #expect(second.files.map(\.filename) == ["second.txt"])
    }

    @Test("removing an attachment also releases its source identity")
    func removalReleasesIdentity() throws {
        let url = URL(fileURLWithPath: "/tmp/reusable.png")
        let image = try makeImage(name: "reusable.png")
        var draft = ChatAttachmentDraft()
        draft.appendImage(image, sourceURL: url)
        #expect(draft.filteringAlreadyAttached([url]).duplicates == 1)

        draft.removeImage(id: image.id)

        #expect(draft.filteringAlreadyAttached([url]).fresh == [url])
    }

    @Test("all input methods share one path-normalized duplicate filter")
    func duplicateFilterCoversExistingAndBatchDuplicates() {
        let existing = URL(fileURLWithPath: "/tmp/docs/photo.png")
        let sameSpelling = URL(fileURLWithPath: "/tmp/docs/../docs/photo.png")
        let fresh = URL(fileURLWithPath: "/tmp/new.txt")
        var draft = ChatAttachmentDraft()
        let image = try? makeImage(name: "photo.png")
        if let image { draft.appendImage(image, sourceURL: existing) }

        let result = draft.filteringAlreadyAttached([sameSpelling, fresh, fresh])

        #expect(result.fresh == [fresh])
        #expect(result.duplicates == 2)
    }

    private func makeImage(name: String) throws -> ChatImageAttachment {
        try ChatImageAttachment(
            filename: name,
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    private func makeFile(name: String, text: String) throws -> ChatFileAttachment {
        try ChatFileAttachment(
            filename: name,
            kind: .txt,
            extractedText: text,
            sourceByteCount: text.utf8.count
        )
    }
}
