import Foundation

/// Product state for attachments waiting in the Chat composer.
///
/// Keeping this outside ``ChatView`` makes the important identity and lifecycle
/// rules directly testable: every input method feeds the same draft, a send
/// atomically consumes it, and a later turn cannot inherit stale attachments.
struct ChatAttachmentDraft: Equatable {
    struct Payload: Equatable {
        let images: [ChatImageAttachment]
        let files: [ChatFileAttachment]
    }

    private(set) var images: [ChatImageAttachment] = []
    private(set) var files: [ChatFileAttachment] = []
    private(set) var sourcePaths: [UUID: String] = [:]
    var notice: String?
    var isImportingFiles = false

    var hasAttachments: Bool { !images.isEmpty || !files.isEmpty }

    mutating func appendImage(_ image: ChatImageAttachment, sourceURL: URL? = nil) {
        images.append(image)
        if let sourceURL { sourcePaths[image.id] = Self.attachmentKey(for: sourceURL) }
    }

    mutating func appendImages(
        _ imported: [(attachment: ChatImageAttachment, sourceURL: URL)]
    ) {
        for item in imported { appendImage(item.attachment, sourceURL: item.sourceURL) }
    }

    mutating func finishFileImport(
        _ imported: [(attachment: ChatFileAttachment, sourceURL: URL)],
        notice: String?
    ) {
        files = ChatFileAttachment.fittedForMessage(files + imported.map(\.attachment))
        for item in imported {
            sourcePaths[item.attachment.id] = Self.attachmentKey(for: item.sourceURL)
        }
        self.notice = notice
        isImportingFiles = false
    }

    mutating func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
        sourcePaths[id] = nil
    }

    mutating func removeFile(id: UUID) {
        files.removeAll { $0.id == id }
        sourcePaths[id] = nil
    }

    /// Returns exactly one turn's attachments and clears all transient state.
    /// This is intentionally one mutation so a new import cannot observe an
    /// old source-path map after the visible chips have already disappeared.
    mutating func consume() -> Payload {
        let payload = Payload(images: images, files: files)
        images = []
        files = []
        sourcePaths = [:]
        notice = nil
        isImportingFiles = false
        return payload
    }

    func filteringAlreadyAttached(_ urls: [URL]) -> (fresh: [URL], duplicates: Int) {
        Self.withoutAlreadyAttached(urls, attached: Set(sourcePaths.values))
    }

    /// Identity for "the same file". Symlinks and `..` are resolved; equal
    /// bytes at distinct real paths deliberately remain separate attachments.
    static func attachmentKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func withoutAlreadyAttached(
        _ urls: [URL], attached: Set<String>
    ) -> (fresh: [URL], duplicates: Int) {
        var seen = attached
        var fresh: [URL] = []
        for url in urls where seen.insert(attachmentKey(for: url)).inserted {
            fresh.append(url)
        }
        return (fresh, urls.count - fresh.count)
    }
}
