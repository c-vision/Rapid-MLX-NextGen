import Foundation
import Testing
@testable import Rapid

/// Coverage for ``HTMLToMarkdown`` — the readability-lite extractor. Verifies
/// non-content elements are dropped, the main region is preferred, common block
/// / inline structure becomes Markdown, entities decode, and adversarial /
/// malformed markup degrades safely instead of crashing.
@Suite("HTMLToMarkdown")
struct HTMLToMarkdownTests {

    @Test("script / style / noscript bodies are removed")
    func stripsNonContent() {
        let html = """
        <html><head><title>T</title><style>.x{color:red}</style></head>
        <body><script>alert('x'); var leak='secret'</script>
        <p>Visible text.</p><noscript>enable js</noscript></body></html>
        """
        let r = HTMLToMarkdown.extract(html)
        #expect(r.markdown.contains("Visible text."))
        #expect(!r.markdown.contains("secret"))
        #expect(!r.markdown.contains("alert"))
        #expect(!r.markdown.contains("color:red"))
        #expect(!r.markdown.contains("enable js"))
    }

    @Test("HTML comments are stripped")
    func stripsComments() {
        let r = HTMLToMarkdown.extract("<p>a<!-- hidden <b>tags</b> -->b</p>")
        #expect(!r.markdown.contains("hidden"))
        #expect(r.markdown.contains("a"))
        #expect(r.markdown.contains("b"))
    }

    @Test("The <article> region is preferred over surrounding chrome")
    func prefersArticle() {
        let html = """
        <body><nav><a href="/">Home</a> <a href="/about">About</a></nav>
        <article><h1>Title</h1><p>Body paragraph.</p></article>
        <footer>Copyright boilerplate 2026</footer></body>
        """
        let r = HTMLToMarkdown.extract(html)
        #expect(r.markdown.contains("Body paragraph."))
        #expect(!r.markdown.contains("Copyright boilerplate"))
        #expect(!r.markdown.contains("About"))
    }

    @Test("Title comes from <title>")
    func extractsTitle() {
        let r = HTMLToMarkdown.extract("<html><head><title>My &amp; Page</title></head><body>x</body></html>")
        #expect(r.title == "My & Page")
    }

    @Test("Headings render with the right number of hashes")
    func headings() {
        let r = HTMLToMarkdown.extract("<h1>One</h1><h2>Two</h2><h3>Three</h3>")
        #expect(r.markdown.contains("# One"))
        #expect(r.markdown.contains("## Two"))
        #expect(r.markdown.contains("### Three"))
    }

    @Test("List items become dash bullets")
    func lists() {
        let r = HTMLToMarkdown.extract("<ul><li>Alpha</li><li>Beta</li></ul>")
        #expect(r.markdown.contains("- Alpha"))
        #expect(r.markdown.contains("- Beta"))
    }

    @Test("Anchors become Markdown links; javascript:/# hrefs degrade to text")
    func links() {
        let safe = HTMLToMarkdown.extract("<p><a href=\"https://example.com/x\">click</a></p>")
        #expect(safe.markdown.contains("[click](https://example.com/x)"))
        let unsafe = HTMLToMarkdown.extract("<p><a href=\"javascript:steal()\">danger</a></p>")
        #expect(unsafe.markdown.contains("danger"))
        #expect(!unsafe.markdown.contains("javascript:"))
        let frag = HTMLToMarkdown.extract("<p><a href=\"#top\">top</a></p>")
        #expect(frag.markdown.contains("top"))
        #expect(!frag.markdown.contains("](#top)"))
    }

    @Test("Emphasis and inline code render")
    func inlineFormatting() {
        let r = HTMLToMarkdown.extract("<p><strong>bold</strong> <em>ital</em> <code>x=1</code></p>")
        #expect(r.markdown.contains("**bold**"))
        #expect(r.markdown.contains("*ital*"))
        #expect(r.markdown.contains("`x=1`"))
    }

    @Test("pre blocks are fenced and preserve interior whitespace")
    func preservesPre() {
        let r = HTMLToMarkdown.extract("<pre>line1\n    indented</pre>")
        #expect(r.markdown.contains("```"))
        #expect(r.markdown.contains("    indented"))
    }

    @Test("Named + numeric entities decode")
    func entities() {
        let r = HTMLToMarkdown.extract("<p>a &amp; b &lt;c&gt; &#65; &#x42; &nbsp;end &copy;</p>")
        #expect(r.markdown.contains("a & b <c> A B"))
        #expect(r.markdown.contains("©"))
    }

    @Test("Excess whitespace collapses; no runaway blank lines")
    func whitespace() {
        let r = HTMLToMarkdown.extract("<p>a   \n\n  b</p><p></p><p></p><p>c</p>")
        #expect(!r.markdown.contains("\n\n\n"))
        #expect(r.markdown.contains("a b") || r.markdown.contains("a\nb") || r.markdown.contains("a b"))
    }

    @Test("An unterminated tag / lone '<' does not crash and keeps text")
    func malformedSafe() {
        let cases = ["<p>unclosed paragraph and <b>bold", "a < b and c > d",
                     "<<<>>><p>ok</p>", "<script>no close", "<div class=\"a>b\">x</div>"]
        for c in cases {
            let r = HTMLToMarkdown.extract(c)
            _ = r.markdown   // must simply not trap
        }
        #expect(HTMLToMarkdown.extract("a < b and c > d").markdown.contains("a"))
    }

    @Test("A '>' inside an attribute value doesn't end the tag early")
    func attributeQuoting() {
        let r = HTMLToMarkdown.extract("<a href=\"https://e.com/?a=1&amp;b=2\" title=\"x > y\">L</a>")
        #expect(r.markdown.contains("[L](https://e.com/?a=1&b=2)"))
    }

    @Test("Adversarial unterminated tags stay linear (no O(n²) freeze)")
    func adversarialUnterminatedTagsAreLinear() {
        // A long run of `<a` with no closing '>' used to make every '<' re-scan
        // the tail to EOF (O(n²)); at this size an unbounded parser would take
        // many seconds / effectively hang. Bounded parsing returns near-instantly.
        // Titles + main-region + tokenizer all share the same tag scanner, so
        // cover each: an unterminated `<title`, an unterminated open-tag run, and
        // a runaway unclosed quote.
        let openRun = String(repeating: "<a", count: 300_000)          // 600k chars, no '>'
        let quoteRun = String(repeating: "<a title=\"", count: 80_000)  // unclosed quotes
        let titleRun = "<title" + String(repeating: "<a", count: 200_000)
        for pathological in [openRun, quoteRun, titleRun] {
            let r = HTMLToMarkdown.extract(pathological)
            _ = r.markdown   // must simply return, not hang or trap
        }
        // Sanity: the bound doesn't break a normal (well-formed) tag.
        #expect(HTMLToMarkdown.extract("<p>hello</p>").markdown.contains("hello"))
    }
}
