import Foundation

/// Live INLINE markdown for the streaming fast path: bold, italic and
/// inline code render while the reply is still arriving, so the user
/// no longer reads raw `**bold**` asterisks mid-stream (2026-07
/// dogfood screenshot).
///
/// ## Scope, deliberately narrow
///
/// This is not a markdown renderer. Block-level structure — headings,
/// lists, tables, code-block chrome — still pops in at finalize when
/// the row swaps to MarkdownUI; that one-time reflow is calm. What
/// reads as *broken* during a stream is inline emphasis showing its
/// markers, and that is all this fixes. Full MarkdownUI per coalescer
/// flush stays off the table until someone attaches the Time Profile
/// the v1 audit retirement note demands (docs/plans/
/// v1-prod-readiness-gaps.md, MarkdownUI re-parse entry).
///
/// ## How it stays cheap
///
/// Styling rides `inlinePresentationIntent` runs — no fonts are set
/// here, so the ambient `.scaledSystemFont(15, design: .serif)` and
/// Dynamic Type apply untouched, and `.code` runs go monospaced the
/// same way `Text(markdown:)` output does. The ``Memo`` mirrors the
/// `ChatTextSanitizer.Memo` shape (#296): everything before the last
/// paragraph boundary with balanced fences is formatted once and
/// cached; each coalescer flush re-formats only the live tail —
/// typically one paragraph — so the per-flush cost is O(tail), not
/// O(buffer).
///
/// ## Self-healing by construction
///
/// An unclosed marker renders literally until its closing twin
/// arrives (never style-then-unstyle flicker), fenced code is left
/// untouched apart from a monospaced run, `snake_case` underscores
/// are not emphasis (flanking checks), and any input the scanner
/// can't improve degrades to exactly today's rendering: the plain
/// sanitised string.
enum ChatStreamInlineFormatter {

    /// Format a chunk. `startingInsideFence` carries fence state
    /// across chunk boundaries (the ``Memo`` threads it).
    static func format(
        _ text: String,
        startingInsideFence: Bool = false
    ) -> (result: AttributedString, endsInsideFence: Bool) {
        var out = AttributedString()
        var insideFence = startingInsideFence
        var first = true
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out += AttributedString("\n") }
            first = false
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                var marker = AttributedString(line)
                marker.inlinePresentationIntent = .code
                out += marker
                continue
            }
            if insideFence {
                var run = AttributedString(line)
                run.inlinePresentationIntent = .code
                out += run
                continue
            }
            out += formatInline(line)
        }
        return (out, insideFence)
    }

    // MARK: - Inline scanner (single line, outside fences)

    private static func formatInline(_ line: String) -> AttributedString {
        let chars = Array(line)
        var out = AttributedString()
        var plain = ""
        var i = 0

        func flushPlain() {
            if !plain.isEmpty {
                out += AttributedString(plain)
                plain = ""
            }
        }
        func emit(_ inner: String, _ intent: InlinePresentationIntent) {
            flushPlain()
            var run = AttributedString(inner)
            run.inlinePresentationIntent = intent
            out += run
        }

        while i < chars.count {
            let c = chars[i]

            // `code` — wins over emphasis; markers inside a span are
            // literal, so scan it first.
            if c == "`" {
                if let close = firstIndex(of: "`", in: chars, from: i + 1) {
                    emit(String(chars[(i + 1)..<close]), .code)
                    i = close + 1
                    continue
                }
                plain.append(c)
                i += 1
                continue
            }

            // **bold**
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if i + 2 < chars.count, !chars[i + 2].isWhitespace,
                   let close = firstDoubleIndex(of: "*", in: chars, from: i + 2),
                   !chars[close - 1].isWhitespace {
                    emit(String(chars[(i + 2)..<close]), .stronglyEmphasized)
                    i = close + 2
                    continue
                }
                plain.append("**")
                i += 2
                continue
            }

            // *italic* — a lone asterisk followed by whitespace is
            // arithmetic ("3 * 4"), not emphasis.
            if c == "*" {
                if i + 1 < chars.count, !chars[i + 1].isWhitespace, chars[i + 1] != "*",
                   let close = firstIndex(of: "*", in: chars, from: i + 1),
                   !chars[close - 1].isWhitespace {
                    emit(String(chars[(i + 1)..<close]), .emphasized)
                    i = close + 1
                    continue
                }
                plain.append(c)
                i += 1
                continue
            }

            // _italic_ — word-internal underscores (snake_case) are
            // not emphasis: the opener must not follow a word
            // character, and the closer must not precede one.
            if c == "_" {
                let openerOK = i == 0 || !isWordChar(chars[i - 1])
                if openerOK, i + 1 < chars.count, !chars[i + 1].isWhitespace, chars[i + 1] != "_",
                   let close = firstIndex(of: "_", in: chars, from: i + 1),
                   !chars[close - 1].isWhitespace,
                   close + 1 == chars.count || !isWordChar(chars[close + 1]) {
                    emit(String(chars[(i + 1)..<close]), .emphasized)
                    i = close + 1
                    continue
                }
                plain.append(c)
                i += 1
                continue
            }

            plain.append(c)
            i += 1
        }
        flushPlain()
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func firstIndex(of target: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func firstDoubleIndex(of target: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i + 1 < chars.count {
            if chars[i] == target, chars[i + 1] == target { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Per-row memo (#296 pattern)

    /// Incremental wrapper: formats the stable prefix once, re-formats
    /// only the live tail on each flush. Monotone-extension contract
    /// like `ChatTextSanitizer.Memo` — if the input stops extending
    /// the previous one (row reuse, regenerate), the memo resets and
    /// rebuilds from scratch, which is always correct, just cold.
    struct Memo {
        private var stablePrefix = ""
        private var stableFormatted = AttributedString()
        private var stableEndsInFence = false

        mutating func formatted(_ input: String) -> AttributedString {
            if !input.hasPrefix(stablePrefix) {
                stablePrefix = ""
                stableFormatted = AttributedString()
                stableEndsInFence = false
            }
            let tail = String(input.dropFirst(stablePrefix.count))
            // Advance the stable boundary to the last paragraph break
            // whose prefix leaves all fences closed — inline markers
            // don't span paragraphs, so everything before it can never
            // change styling again.
            if let boundary = Self.stableBoundary(in: tail, startingInsideFence: stableEndsInFence) {
                let newStable = String(tail[..<boundary])
                let (formatted, endsInFence) = ChatStreamInlineFormatter.format(
                    newStable,
                    startingInsideFence: stableEndsInFence
                )
                stableFormatted += formatted
                stablePrefix += newStable
                stableEndsInFence = endsInFence
            }
            let live = String(input.dropFirst(stablePrefix.count))
            let (liveFormatted, _) = ChatStreamInlineFormatter.format(
                live,
                startingInsideFence: stableEndsInFence
            )
            return stableFormatted + liveFormatted
        }

        /// Index just past the last `\n\n` in `chunk` at which fence
        /// state is closed, or nil when no such boundary exists yet.
        static func stableBoundary(
            in chunk: String,
            startingInsideFence: Bool
        ) -> String.Index? {
            var searchEnd = chunk.endIndex
            while let range = chunk.range(of: "\n\n", options: .backwards, range: chunk.startIndex..<searchEnd) {
                let prefix = chunk[chunk.startIndex..<range.upperBound]
                var fence = startingInsideFence
                for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        fence.toggle()
                    }
                }
                if !fence { return range.upperBound }
                searchEnd = range.lowerBound
            }
            return nil
        }
    }
}
