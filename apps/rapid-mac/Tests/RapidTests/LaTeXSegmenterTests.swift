import Foundation
import Testing
@testable import Rapid

/// Issue #131: pin the ``LaTeXSegmenter`` contract. Math-rendering
/// regressions are easy to miss visually (the difference between
/// "rendered fine" and "rendered as source" is only obvious if you
/// know what to look for), so we lean on a thick test that
/// hard-codes the expected segment shape for every wire-shape we
/// see from real models.
@Suite("LaTeXSegmenter — math/markdown split (issue #131)")
struct LaTeXSegmenterTests {

    // MARK: - Empty / no-math hot path

    @Test("Empty input returns zero segments")
    func emptyInput() {
        #expect(LaTeXSegmenter.segment("") == [])
    }

    @Test("Plain markdown with no math returns ONE markdown segment (hot path)")
    func plainMarkdownHotPath() {
        let body = """
        # Title

        A paragraph with **bold** and *italic*.

        - bullet one
        - bullet two
        """
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)],
                "no math markers → exactly one .markdown segment, byte-for-byte input")
    }

    // MARK: - Inline math ($...$)

    @Test("Inline math in prose splits cleanly")
    func inlineMathInProse() {
        let body = "We compute $x^2 + y^2$ to find the radius."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [
            .markdown("We compute "),
            .math(latex: "x^2 + y^2", displayMode: false),
            .markdown(" to find the radius.")
        ])
    }

    @Test("Two inline math runs on the same line")
    func twoInlineMath() {
        let body = "Let $a = 1$ and $b = 2$."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [
            .markdown("Let "),
            .math(latex: "a = 1", displayMode: false),
            .markdown(" and "),
            .math(latex: "b = 2", displayMode: false),
            .markdown(".")
        ])
    }

    @Test("Inline math at start of line emits no leading empty markdown")
    func inlineMathAtStart() {
        let body = "$y = mx + b$ is the formula."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [
            .math(latex: "y = mx + b", displayMode: false),
            .markdown(" is the formula.")
        ])
    }

    // MARK: - Display math ($$...$$)

    @Test("Display math on its own block")
    func displayMathBlock() {
        let body = """
        Integration by parts:

        $$ \\int u \\, dv = uv - \\int v \\, du $$

        Apply twice for x^2 sin(x).
        """
        let segments = LaTeXSegmenter.segment(body)
        let expectedLatex = " \\int u \\, dv = uv - \\int v \\, du "
        #expect(segments == [
            .markdown("Integration by parts:\n\n"),
            .math(latex: expectedLatex, displayMode: true),
            .markdown("\n\nApply twice for x^2 sin(x).")
        ])
    }

    @Test("Multi-line display math (the common case for derivations)")
    func multiLineDisplayMath() {
        let body = """
        $$
        f(x) = ax^2 + bx + c
        $$
        """
        let segments = LaTeXSegmenter.segment(body)
        let expectedLatex = "\nf(x) = ax^2 + bx + c\n"
        #expect(segments == [
            .math(latex: expectedLatex, displayMode: true)
        ])
    }

    // MARK: - Anti-cases (must NOT be treated as math)

    @Test("Fenced code block: $...$ inside ``` stays literal")
    func fencedCodeBlockSurvives() {
        let body = """
        Here's a shell snippet:

        ```bash
        echo "$5.00 paid"
        ```

        Plain prose after.
        """
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)],
                "fenced code body must NOT have its $ treated as math open")
    }

    @Test("Inline backtick code: `$5.00` stays literal")
    func inlineBacktickSurvives() {
        let body = "Today it cost `$5.00` to ship."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)])
    }

    @Test("Escaped dollar (\\$) stays literal")
    func escapedDollarSurvives() {
        let body = "Cost: \\$20 plus tax."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)])
    }

    @Test("Bare dollar with no closer is treated as literal prose")
    func bareDollarNoCloser() {
        let body = "Pay $20 today, please."
        let segments = LaTeXSegmenter.segment(body)
        // Inline math is single-line; the lack of a closing $ on the
        // same line means we fall back to literal markdown.
        #expect(segments == [.markdown(body)],
                "bare $ with no inline close → literal markdown, no false-positive math")
    }

    @Test("Single $ followed by newline does NOT open math")
    func dollarBeforeNewline() {
        let body = "Total: $20\nNext line"
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)])
    }

    // MARK: - Edge cases worth pinning

    @Test("Display math right after inline math, no plain between")
    func displayRightAfterInline() {
        let body = "$x$$$y$$"
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [
            .math(latex: "x", displayMode: false),
            .math(latex: "y", displayMode: true)
        ])
    }

    // MARK: - Codex r1 anti-cases (#131)

    @Test("Currency dollars on one line: $20 to $30 stays literal")
    func currencyDollarsOnOneLine() {
        let body = "Revenue rose from $20 to $30 this quarter."
        let segments = LaTeXSegmenter.segment(body)
        // Codex r1 P1 (#131): MathJax convention — $ followed by a
        // digit is currency, not math. Without the guard, the two $
        // would otherwise pair as an inline math run.
        #expect(segments == [.markdown(body)],
                "currency-dollar pairs must NOT become a math segment")
    }

    @Test("Currency followed by non-digit math: $x$ to $20 splits cleanly")
    func currencyAfterRealMath() {
        let body = "Let $x$ be the input, and $20 be the price."
        let segments = LaTeXSegmenter.segment(body)
        // First $...$ is real math; second $ is currency (digit follows).
        // With the guard, the second $ is rejected and never opens math,
        // so the tail stays a single markdown segment.
        #expect(segments == [
            .markdown("Let "),
            .math(latex: "x", displayMode: false),
            .markdown(" be the input, and $20 be the price.")
        ])
    }

    @Test("4-space-indented code block: $x$ stays literal markdown")
    func indentedCodeBlockSurvives() {
        // CommonMark treats 4+ leading spaces as a code block. The
        // segmenter must NOT scan its body for dollars.
        let body = """
        Before:

            echo "$x = 1$"
            echo "$y$$z$"

        After.
        """
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)],
                "indented code block contents must stay literal")
    }

    @Test("Tab-indented code block: $y$ stays literal markdown")
    func tabIndentedCodeSurvives() {
        let body = "Snippet:\n\n\tprintf \"$x$\\n\"\n\nDone."
        let segments = LaTeXSegmenter.segment(body)
        #expect(segments == [.markdown(body)],
                "tab-indented code block contents must stay literal")
    }

    // MARK: - LaTeXMarkdownView.displayMathOnly collapse (#131 v1)

    @Test("displayMathOnly: pure markdown passes through unchanged")
    func displayMathOnlyPassThrough() {
        let segs: [LaTeXSegment] = [.markdown("hello world")]
        #expect(LaTeXMarkdownView.displayMathOnly(segs) == segs)
    }

    @Test("displayMathOnly: inline math is re-wrapped back into adjacent markdown")
    func displayMathOnlyInlineCollapse() {
        // The segmenter emitted three pieces around an inline run; the
        // view's v1 collapse should fold them into ONE markdown segment
        // so MarkdownUI can keep the surrounding paragraph intact.
        let segs: [LaTeXSegment] = [
            .markdown("We compute "),
            .math(latex: "x^2 + y^2", displayMode: false),
            .markdown(" to find the radius.")
        ]
        #expect(LaTeXMarkdownView.displayMathOnly(segs) == [
            .markdown("We compute $x^2 + y^2$ to find the radius.")
        ])
    }

    @Test("displayMathOnly: display math is preserved as its own segment")
    func displayMathOnlyDisplayPreserved() {
        let segs: [LaTeXSegment] = [
            .markdown("Result:\n\n"),
            .math(latex: "f(x) = ax^2 + bx + c", displayMode: true),
            .markdown("\n\nDone.")
        ]
        #expect(LaTeXMarkdownView.displayMathOnly(segs) == segs)
    }

    @Test("displayMathOnly: mixed inline+display in one body")
    func displayMathOnlyMixed() {
        // Inline math is folded back; display math survives. Around the
        // display segment, the markdown chunks remain separate so
        // MarkdownUI doesn't have to render the display math as source.
        let segs: [LaTeXSegment] = [
            .markdown("Inline "),
            .math(latex: "a", displayMode: false),
            .markdown(" then\n\n"),
            .math(latex: "b = c", displayMode: true),
            .markdown("\n\nand inline "),
            .math(latex: "d", displayMode: false),
            .markdown(" again.")
        ]
        #expect(LaTeXMarkdownView.displayMathOnly(segs) == [
            .markdown("Inline $a$ then\n\n"),
            .math(latex: "b = c", displayMode: true),
            .markdown("\n\nand inline $d$ again.")
        ])
    }

    @Test("Round-trip: segments concatenated with delimiters re-form input")
    func roundTrip() {
        let inputs = [
            "Plain text.",
            "Inline $x^2$ in middle.",
            "$$y = mx + b$$",
            "Mixed: $a$ then $$b$$ then $c$.",
            "Code: ```\n$x$\n``` keeps source.",
        ]
        for body in inputs {
            let segments = LaTeXSegmenter.segment(body)
            let reconstructed = segments.map { seg -> String in
                switch seg {
                case .markdown(let s): return s
                case .math(let latex, let display):
                    return display ? "$$\(latex)$$" : "$\(latex)$"
                }
            }.joined()
            #expect(reconstructed == body,
                    "segmenter must be lossless: '\(body)' → '\(reconstructed)'")
        }
    }
}
