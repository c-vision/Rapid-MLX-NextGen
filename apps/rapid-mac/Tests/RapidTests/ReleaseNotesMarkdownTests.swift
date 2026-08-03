import Testing
@testable import Rapid

/// Pins the block parse used by the update dialog's release notes.
/// A regression here means users see raw ``##`` / ``-`` Markdown again
/// (the "升级页面太丑" report that motivated v0.8.18's renderer).
@Suite("ReleaseNotesMarkdown — block parse for the update dialog")
struct ReleaseNotesMarkdownTests {

    private func kinds(_ raw: String) -> [ReleaseNotesMarkdown.Block.Kind] {
        ReleaseNotesMarkdown.parse(raw).map(\.kind)
    }

    @Test("Leading version heading is dropped (redundant with dialog header)")
    func dropsLeadingVersionHeading() {
        let raw = """
        ## [0.8.18] — 2026-06-29

        ### Changed
        - Speed pick is now qwen3.5-4b-4bit
        """
        let parsed = ReleaseNotesMarkdown.parse(raw)
        // First block should be the "### Changed" heading, NOT the version.
        guard case .heading(let level, let text) = parsed.first?.kind else {
            Issue.record("expected first block to be a heading, got \(String(describing: parsed.first?.kind))")
            return
        }
        #expect(level == 3)
        #expect(text == "Changed")
        // The version string must not survive anywhere as a heading.
        for block in parsed {
            if case .heading(_, let t) = block.kind {
                #expect(!t.contains("0.8.18"))
            }
        }
    }

    @Test("A non-version leading heading is preserved")
    func keepsNonVersionLeadingHeading() {
        let raw = """
        ## Highlights
        - thing
        """
        guard case .heading(let level, let text) = kinds(raw).first else {
            Issue.record("expected heading first")
            return
        }
        #expect(level == 2)
        #expect(text == "Highlights")
    }

    @Test("A leading numeric-but-not-version heading (\"5 things\") is preserved")
    func leadingNumberWordHeadingNotMistakenForVersion() {
        let raw = "## 5 things changed\n- a"
        guard case .heading(_, let text) = kinds(raw).first else {
            Issue.record("expected heading first")
            return
        }
        #expect(text == "5 things changed")
    }

    @Test("Heading levels 1–3 parse from #/##/###")
    func headingLevels() {
        let raw = "# One\n## Two\n### Three"
        let ks = kinds(raw)
        #expect(ks.count == 3)
        if case .heading(let l1, _) = ks[0] { #expect(l1 == 1) } else { Issue.record("not h1") }
        if case .heading(let l2, _) = ks[1] { #expect(l2 == 2) } else { Issue.record("not h2") }
        if case .heading(let l3, _) = ks[2] { #expect(l3 == 3) } else { Issue.record("not h3") }
    }

    @Test("Bullets with -, *, + all parse to .bullet")
    func bulletMarkers() {
        let raw = "- dash\n* star\n+ plus"
        let ks = kinds(raw)
        #expect(ks.count == 3)
        for k in ks {
            guard case .bullet = k else { Issue.record("expected bullet, got \(k)"); continue }
        }
        if case .bullet(let t) = ks[0] { #expect(t == "dash") }
    }

    @Test("Ordered list keeps its marker")
    func orderedList() {
        let raw = "1. first\n2. second"
        let ks = kinds(raw)
        guard case .ordered(let marker, let text) = ks.first else {
            Issue.record("expected ordered"); return
        }
        #expect(marker == "1.")
        #expect(text == "first")
    }

    @Test("Fenced code block is captured as one .code block")
    func fencedCode() {
        let raw = """
        Run:

        ```
        rapid-mlx serve qwen3.5-4b-4bit
        ```
        """
        let ks = kinds(raw)
        let codeBlocks = ks.compactMap { kind -> String? in
            if case .code(let t) = kind { return t }
            return nil
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks.first == "rapid-mlx serve qwen3.5-4b-4bit")
    }

    @Test("Unrecognised line degrades to a paragraph (never dropped)")
    func unknownLineIsParagraph() {
        let raw = "Just a normal sentence with **bold** and `code`."
        let ks = kinds(raw)
        #expect(ks.count == 1)
        guard case .paragraph(let t) = ks.first else {
            Issue.record("expected paragraph"); return
        }
        #expect(t.contains("**bold**"))   // raw kept; inline() styles it at render time
    }

    @Test("Blank lines are separators, not blocks")
    func blankLinesSkipped() {
        let raw = "a\n\n\n\nb"
        let ks = kinds(raw)
        #expect(ks.count == 2)
    }

    @Test("Inline renderer never blanks a line, even on odd markup")
    func inlineFallbackNonEmpty() {
        // A malformed link must not produce an empty AttributedString.
        let attr = ReleaseNotesMarkdown.inline("see [broken](")
        #expect(!String(attr.characters).isEmpty)
        let bold = ReleaseNotesMarkdown.inline("**Gemma 3** fix")
        #expect(String(bold.characters).contains("Gemma 3"))
    }

    @Test("Hard-wrapped bullet folds into ONE bullet (bold across the wrap survives)")
    func wrappedBulletFolds() {
        // Mirrors the real CHANGELOG shape: a single bullet hard-wrapped
        // across indented continuation lines, with **bold** straddling
        // the line break.
        let raw = """
        ### Changed

        * **The "Speed" model recommendation no longer points at a model
          that can't hold a conversation.** It now uses qwen3.5-4b-4bit
          instead of gemma3-1b-qat-4bit.
        """
        let parsed = ReleaseNotesMarkdown.parse(raw)
        let bullets = parsed.compactMap { b -> String? in
            if case .bullet(let t) = b.kind { return t }
            return nil
        }
        #expect(bullets.count == 1)   // NOT split into a bullet + paragraphs
        guard let only = bullets.first else { return }
        // The bold span is intact (both ** on the same folded string) and
        // the soft breaks became single spaces (no double spaces).
        #expect(only.hasPrefix("**The \"Speed\""))
        #expect(only.contains("conversation.**"))
        #expect(only.contains("gemma3-1b-qat-4bit"))
        #expect(!only.contains("  "))
        // And it renders to non-empty styled text with the bold applied.
        #expect(!String(ReleaseNotesMarkdown.inline(only).characters).isEmpty)
    }

    @Test("Hard-wrapped paragraph folds into ONE paragraph")
    func wrappedParagraphFolds() {
        let raw = """
        A model-recommendation quality fix plus a cosmetic cleanup of the
        update window. No change to the bundled inference engine.
        """
        let parsed = ReleaseNotesMarkdown.parse(raw)
        #expect(parsed.count == 1)
        guard case .paragraph(let t) = parsed.first?.kind else {
            Issue.record("expected one paragraph"); return
        }
        #expect(t.contains("quality fix plus a cosmetic cleanup of the update window"))
    }

    @Test("Blank line separates two wrapped paragraphs")
    func blankLineSeparatesWrappedParagraphs() {
        let raw = "line one\nstill one\n\nline two\nstill two"
        let parsed = ReleaseNotesMarkdown.parse(raw)
        #expect(parsed.count == 2)
    }

    @Test("Realistic CHANGELOG section renders without raw ## or leading version")
    func realisticSection() {
        let raw = """
        ## [0.8.18] — 2026-06-29

        ### Changed
        - **Speed** model recommendation no longer surfaces `gemma3-1b-qat-4bit`.

        ### Fixed
        - Update dialog now renders release notes as formatted text.
        """
        let parsed = ReleaseNotesMarkdown.parse(raw)
        // No block should be a heading whose text is the version.
        let headingTexts = parsed.compactMap { b -> String? in
            if case .heading(_, let t) = b.kind { return t }
            return nil
        }
        #expect(headingTexts == ["Changed", "Fixed"])
        // Two bullets survive.
        let bulletCount = parsed.filter { if case .bullet = $0.kind { return true }; return false }.count
        #expect(bulletCount == 2)
    }
}
