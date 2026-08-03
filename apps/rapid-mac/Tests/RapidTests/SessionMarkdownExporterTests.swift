import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.15 ``SessionMarkdownExporter`` — the
/// session-to-Markdown formatter behind the sidebar "Export as
/// Markdown…" action. Pins:
///   - heading shape (### You / ### Assistant (alias))
///   - reasoning trace lands inside <details> so the export reads
///     as the final answer by default
///   - tool calls collapse into a "> Tool calls: …" quote line
///   - failed turns surface their errorMessage so the export
///     doesn't truncate mysteriously
///   - stats footer round-trips ~84 tok/s · 2.4s
///   - filename sanitiser strips / : ? * and trims to 64 chars
@Suite("SessionMarkdownExporter render")
struct SessionMarkdownExporterTests {

    @Test("Renders title, alias, ISO date, and turn count in the header")
    func headerShape() {
        let session = ChatSession(
            title: "Tokyo weather",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "hi"),
                ChatMessage(role: .assistant, content: "hello"),
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.hasPrefix("# Tokyo weather\n\n*qwen3.5-4b · "))
        #expect(md.contains("2 turns"))
    }

    @Test("User and assistant rows use ### headings; system/tool rows skip")
    func roleHeadings() {
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .system, content: "You are a helpful assistant."),
                ChatMessage(role: .user, content: "What's 2+2?"),
                ChatMessage(role: .assistant, content: "Four."),
                ChatMessage(role: .tool, content: "{}", toolCallID: "abc"),
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("### You"))
        #expect(md.contains("### Assistant (qwen3.5-4b)"))
        #expect(md.contains("What's 2+2?"))
        #expect(md.contains("Four."))
        // System + tool messages don't appear as their own rows.
        #expect(!md.contains("You are a helpful assistant."))
    }

    @Test("Reasoning trace lands inside <details> so the export reads as the final answer")
    func reasoningCollapsed() {
        var msg = ChatMessage(role: .assistant, content: "Visible answer")
        msg.reasoning = "Internal thinking goes here"
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("<details><summary>Thinking</summary>"))
        #expect(md.contains("Internal thinking goes here"))
        #expect(md.contains("</details>"))
        #expect(md.contains("Visible answer"))
    }

    @Test("Assistant turn with no reasoning skips the <details> block")
    func noReasoningNoDetails() {
        let msg = ChatMessage(role: .assistant, content: "Just an answer")
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(!md.contains("<details>"))
        #expect(md.contains("Just an answer"))
    }

    @Test("Tool calls collapse into a single '> Tool calls: …' quote line")
    func toolCallsQuoted() {
        let calls: [ToolCall] = [
            ToolCall(id: "1", name: "web_search", arguments: "{}"),
            ToolCall(id: "2", name: "calculator", arguments: "{}"),
        ]
        var msg = ChatMessage(role: .assistant, content: "Used some tools.")
        msg.toolCalls = calls
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("> Tool calls: web_search, calculator"))
    }

    @Test("Failed turns surface errorMessage as a ⚠️ quote line — no silent truncation")
    func failedTurnSurfacesError() {
        var msg = ChatMessage(role: .assistant, content: "Partial output")
        msg.status = .failed
        msg.errorMessage = "Server crashed mid-response."
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("> ⚠️ Server crashed mid-response."))
        #expect(md.contains("Partial output"))
    }

    @Test("Stats footer renders the same caption the live UI shows")
    func statsFooter() {
        var msg = ChatMessage(role: .assistant, content: "Answer.")
        msg.stats = MessageStats(
            elapsedSeconds: 2.4,
            charCount: 100,
            promptTokens: nil,
            completionTokens: nil
        )
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        // Char-count estimate path — tilde stays in.
        #expect(md.contains("~"))
        #expect(md.contains("tok/s"))
        #expect(md.contains("2.4 s"))
    }

    @Test("Stats footer drops the tilde when usage was server-reported")
    func statsFooterAuthoritative() {
        var msg = ChatMessage(role: .assistant, content: "Hello world.")
        msg.stats = MessageStats(
            elapsedSeconds: 2.0,
            charCount: 50,
            promptTokens: 12,
            completionTokens: 180
        )
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                msg,
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        // Reported = 90 tok/s; the line should NOT lead with "~".
        #expect(md.contains("90 tok/s"))
        // It can still contain "~" in the user prose, but the
        // stats line specifically should not.
        let lines = md.split(separator: "\n").map(String.init)
        let statsLines = lines.filter { $0.contains("tok/s") }
        #expect(!statsLines.contains(where: { $0.contains("~") }))
    }

    @Test("Attachment filenames land as 📎 / 🖼️ quote lines")
    func attachmentsListed() {
        var msg = ChatMessage(role: .user, content: "Look at this")
        msg.attachments = [
            Attachment(kind: .image, filename: "screenshot.png", mime: "image/png", body: "data:image/png;base64,xxxxx", sizeBytes: 0),
            Attachment(kind: .textFile, filename: "notes.txt", mime: "text/plain", body: "notes", sizeBytes: 5),
        ]
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [msg],
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("> 🖼️ screenshot.png"))
        #expect(md.contains("> 📎 notes.txt"))
    }

    @Test("Attachment filenames are sanitized before interpolation")
    func attachmentFilenamesSanitized() {
        var msg = ChatMessage(role: .user, content: "Look at this")
        msg.attachments = [
            Attachment(kind: .image, filename: "../bad\u{001B}/Screen.PNG", mime: "image/png", body: "data:image/png;base64,xxxxx", sizeBytes: 0),
        ]
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [msg],
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(!md.contains("../bad"))
        #expect(!md.contains("\u{001B}"))
        #expect(md.contains("> 🖼️ bad-Screen.png"))
    }

    @Test("Suggested filename uses the safe title + ISO date and .md extension")
    func suggestedFilename() {
        let session = ChatSession(
            title: "Tokyo / weather: today?",
            alias: "qwen3.5-4b",
            messages: [],
            createdAt: ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        )
        let name = SessionMarkdownExporter.suggestedFilename(for: session)
        #expect(name.hasSuffix(".md"))
        #expect(name.contains("2026-06-10"))
        // Filesystem-illegal chars stripped.
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("?"))
    }

    @Test("Suggested filename strips path separators/control chars and keeps lowercase .md")
    func suggestedFilenameHardening() {
        let session = ChatSession(
            title: "../Tokyo\u{001B}/Weather.MD",
            alias: "qwen3.5-4b",
            messages: [],
            createdAt: ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        )
        let name = SessionMarkdownExporter.suggestedFilename(for: session)
        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect(!name.contains("\u{001B}"))
        #expect(!name.hasPrefix("."))
        #expect(name.hasSuffix(".md"))
    }

    @Test("Oversized inline image base64 is omitted from exports")
    func oversizedInlineImageDataOmitted() {
        let payload = String(
            repeating: "A",
            count: SessionMarkdownExporter.maxInlineImageBase64Bytes + 1
        )
        let msg = ChatMessage(
            role: .assistant,
            content: "Screenshot: ![x](data:image/png;base64,\(payload))"
        )
        let session = ChatSession(
            title: "x",
            alias: "qwen3.5-4b",
            messages: [msg]
        )
        let md = SessionMarkdownExporter.render(session)
        #expect(md.contains("[image data omitted: exceeds 4 MB export cap]"))
        #expect(!md.contains("data:image/png;base64"))
        #expect(md.utf8.count < 10_000)
    }

    @Test("renderAssistant(public, v0.4.24) — assistant-only output for per-message Copy as Markdown")
    func renderAssistantPublicSurface() {
        let stats = MessageStats(
            elapsedSeconds: 1.5, charCount: 80,
            promptTokens: 200, completionTokens: 60
        )
        let asst = ChatMessage(
            role: .assistant,
            content: "Final answer with **markdown**.",
            reasoning: "Step 1: consider X. Step 2: consider Y.",
            status: .complete,
            stats: stats
        )
        let md = SessionMarkdownExporter.renderAssistant(asst, alias: "qwen3.6-27b")
        // Header carries the alias so the paste is self-describing.
        #expect(md.contains("### Assistant (qwen3.6-27b)"))
        // Reasoning is wrapped in a collapsible <details> block.
        #expect(md.contains("<details><summary>Thinking</summary>"))
        #expect(md.contains("Step 1: consider X."))
        // Body lands verbatim, no escaping of the bold marker.
        #expect(md.contains("Final answer with **markdown**."))
        // Authoritative stats footer (no tilde, since usage was reported).
        #expect(md.contains("tok/s"))
        #expect(md.contains("> _"))  // stats line is an italicised quote
    }

    @Test("renderAssistant — empty alias renders 'Assistant' label without parenthesis noise")
    func renderAssistantEmptyAlias() {
        let asst = ChatMessage(role: .assistant, content: "Hello.")
        let md = SessionMarkdownExporter.renderAssistant(asst, alias: "")
        #expect(md.contains("### Assistant\n"))
        #expect(!md.contains("Assistant ()"))
    }

    @Test("Sanitiser keeps Unicode characters and trims to ≤ 64 graphemes")
    func sanitizeUnicodeAndLength() {
        let huge = String(repeating: "café-", count: 30)
        let safe = SessionMarkdownExporter.sanitize(huge)
        #expect(safe.count <= 64)
        #expect(safe.contains("café"))

        // Empty / whitespace-only titles fall back to "chat".
        #expect(SessionMarkdownExporter.sanitize("") == "chat")
        #expect(SessionMarkdownExporter.sanitize("    ") == "chat")
    }

    @Test("Output round-trips through string interpolation cleanly — no doubled newlines or trailing whitespace at line ends")
    func wellFormedMarkdown() {
        let session = ChatSession(
            title: "smoke",
            alias: "qwen3.5-4b",
            messages: [
                ChatMessage(role: .user, content: "Hi"),
                ChatMessage(role: .assistant, content: "Hello"),
            ]
        )
        let md = SessionMarkdownExporter.render(session)
        // No triple-newline runs anywhere — the formatter should
        // never emit `\n\n\n` because some markdown viewers treat
        // that as a hard break + spacer.
        #expect(!md.contains("\n\n\n"))
        // Ends in a trailing newline so concatenation downstream
        // doesn't produce "stuff---stuff".
        #expect(md.hasSuffix("\n"))
    }
}
