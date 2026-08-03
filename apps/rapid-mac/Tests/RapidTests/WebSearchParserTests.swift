import Foundation
import Testing
@testable import Rapid

/// Pin the DDG-HTML parser. The endpoint is unversioned and the
/// markup can drift quietly; without a baseline sample the first
/// signal that web_search broke would be a silent "no results"
/// reply to the user.
@Suite("WebSearchTool DDG HTML parser")
struct WebSearchParserTests {
    /// A trimmed sample of what html.duckduckgo.com/html/?q=apple
    /// looks like in the wild. Two result blocks; the parser
    /// should pull both titles + URLs + snippets and decode the
    /// ``/l/?uddg=…`` redirect wrapper.
    static let sampleHTML = #"""
    <html>
    <body>
    <div class="results">
      <div class="result results_links">
        <div class="result__body">
          <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.apple.com%2F&amp;rut=foo">Apple</a></h2>
          <a class="result__snippet" href="https://www.apple.com/">Apple makes the iPhone, iPad, Mac, and AirPods. Visit Apple.com to <b>shop</b> the lineup.</a>
        </div>
      </div>
      <div class="result results_links">
        <div class="result__body">
          <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FApple_Inc.&amp;rut=bar">Apple Inc. - Wikipedia</a></h2>
          <a class="result__snippet" href="https://en.wikipedia.org/wiki/Apple_Inc.">Apple Inc. is an American multinational technology company headquartered in Cupertino, California.</a>
        </div>
      </div>
    </div>
    </body>
    </html>
    """#

    @Test("Pulls two results out of the sample HTML")
    func parsesSample() {
        let results = WebSearchTool.parseDDGHTML(Self.sampleHTML, cap: 6)
        #expect(results.count == 2)
        #expect(results[0].title == "Apple")
        #expect(results[1].title == "Apple Inc. - Wikipedia")
    }

    @Test("Decodes the DDG redirect wrapper into the real URL")
    func decodesRedirect() {
        let results = WebSearchTool.parseDDGHTML(Self.sampleHTML, cap: 6)
        #expect(results[0].url == "https://www.apple.com/")
        #expect(results[1].url == "https://en.wikipedia.org/wiki/Apple_Inc.")
    }

    @Test("Snippet strips HTML tags and entities")
    func snippetStripsTags() {
        let results = WebSearchTool.parseDDGHTML(Self.sampleHTML, cap: 6)
        // Sample has ``<b>shop</b>`` in the first snippet; tag should be gone.
        #expect(!results[0].snippet.contains("<b>"))
        #expect(results[0].snippet.contains("shop"))
    }

    @Test("Result cap is honoured")
    func capLimits() {
        let results = WebSearchTool.parseDDGHTML(Self.sampleHTML, cap: 1)
        #expect(results.count == 1)
    }

    @Test("Empty HTML returns empty results, not a crash")
    func emptyInput() {
        #expect(WebSearchTool.parseDDGHTML("", cap: 6).isEmpty)
        #expect(WebSearchTool.parseDDGHTML("<html><body>nothing</body></html>", cap: 6).isEmpty)
    }

    @Test("javascript: redirects are dropped, not surfaced to the model")
    func dropsJavaScriptScheme() {
        // Regression for the v0.3 code review: DDG's HTML surface
        // has historically been a vector for ``javascript:`` /
        // ``data:`` URIs smuggled into the ``uddg=`` parameter.
        // The model would happily turn those into clickable result
        // links. The parser now refuses anything that isn't
        // http(s).
        let raw = "//duckduckgo.com/l/?uddg=javascript%3Aalert(1)&rut=foo"
        #expect(WebSearchTool.ddgRedirectExtract(raw) == nil)
    }

    @Test("data: URIs are dropped too")
    func dropsDataScheme() {
        let raw = "//duckduckgo.com/l/?uddg=data%3Atext%2Fhtml%3Bbase64%2CPHNjcmlwdD4&rut=bar"
        #expect(WebSearchTool.ddgRedirectExtract(raw) == nil)
    }

    @Test("Valid http and https redirects are preserved")
    func keepsHttpAndHttps() {
        let http = "//duckduckgo.com/l/?uddg=http%3A%2F%2Fexample.com%2F&rut=x"
        let https = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F&rut=x"
        #expect(WebSearchTool.ddgRedirectExtract(http) == "http://example.com/")
        #expect(WebSearchTool.ddgRedirectExtract(https) == "https://example.com/")
    }

    /// Regression for the 2026-06-09 silent break: DDG reordered
    /// the ``result__body`` class chain from prefix-position to
    /// suffix-position. The v0.3 parser anchored on
    /// ``class="result__body`` so the split stopped firing and
    /// every search returned "no results found." The fix moved to
    /// a bare ``result__body`` token; this fixture pins the new
    /// markup so the next reorder shows up as a test failure
    /// instead of a silent UX regression.
    static let live2026HTML = #"""
    <html>
    <body>
    <div class="results">
      <div class="result results_links results_links_deep web-result ">
        <div class="links_main links_deep result__body">
          <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2F&amp;rut=z">Example Org</a></h2>
          <a class="result__snippet" href="https://example.org/">An IANA-reserved domain commonly used for documentation.</a>
        </div>
      </div>
      <div class="result results_links results_links_deep web-result ">
        <div class="links_main links_deep result__body">
          <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.iana.org%2F&amp;rut=z">IANA</a></h2>
          <a class="result__snippet" href="https://www.iana.org/">The Internet Assigned Numbers Authority.</a>
        </div>
      </div>
    </div>
    </body>
    </html>
    """#

    @Test("Parser still finds results when result__body is suffix-position in class chain (2026-06-09 DDG layout)")
    func parsesSuffixPositionClassChain() {
        let results = WebSearchTool.parseDDGHTML(Self.live2026HTML, cap: 6)
        // The whole point of the v0.4 fix — the prefix-anchored
        // marker matched zero blocks on the new layout. If this
        // assertion ever drops to zero, DDG changed something
        // again and the bare-token strategy needs another pass.
        #expect(results.count == 2)
        #expect(results[0].title == "Example Org")
        #expect(results[0].url == "https://example.org/")
        #expect(results[1].title == "IANA")
        #expect(results[1].url == "https://www.iana.org/")
    }

    /// Trimmed shape of the body DDG serves when it has decided the
    /// caller looks like a bot. Real responses run hundreds of
    /// lines of CSS + form markup; the only load-bearing parts for
    /// detection are the ``anomaly-modal`` class tokens and the
    /// ``cc=botnet`` form action. HTTP status is 200, no
    /// ``result__body`` blocks anywhere on the page.
    static let antiBotHTML = #"""
    <html>
    <body>
    <div class="anomaly-modal">
      <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
      <form action="/?q=apple&amp;cc=botnet" method="POST">
        <button>Continue</button>
      </form>
    </div>
    </body>
    </html>
    """#

    /// What a legitimately empty-results page should look like —
    /// the wrapper HTML DDG serves when ``parseDDGHTML`` correctly
    /// pulls zero hits. Crucially carries neither ``anomaly-modal``
    /// nor ``cc=botnet`` so the anti-bot detector must NOT fire.
    static let emptyResultsHTML = #"""
    <html>
    <body>
    <div class="results">
      <div class="no-results">No results.</div>
    </div>
    </body>
    </html>
    """#

    @Test("Anti-bot detector fires on the anomaly-modal page")
    func detectsAnomalyModal() {
        #expect(WebSearchTool.detectDDGAntiBot(Self.antiBotHTML))
    }

    @Test("Anti-bot detector also fires on a bare cc=botnet marker")
    func detectsBotnetClassificationMarker() {
        // Defensive: even if DDG renames the modal class, the
        // form's ``cc=botnet`` classification token is enough to
        // trip the detector.
        let html = "<html><body><form action=\"/?q=x&cc=botnet\"></form></body></html>"
        #expect(WebSearchTool.detectDDGAntiBot(html))
    }

    @Test("Anti-bot detector does NOT misclassify a legitimately empty results page")
    func cleanEmptyResultsIsNotFlagged() {
        // Critical guard rail — if this ever flips, the runner
        // would return a misleading "DuckDuckGo blocked" error for
        // queries that genuinely matched nothing.
        #expect(!WebSearchTool.detectDDGAntiBot(Self.emptyResultsHTML))
        #expect(WebSearchTool.parseDDGHTML(Self.emptyResultsHTML, cap: 6).isEmpty)
    }

    @Test("Anti-bot detector ignores normal result pages")
    func cleanResultsAreNotFlagged() {
        // Same shape, populated. The detector must stay quiet on
        // the happy path or every successful search would be
        // reported as a block.
        #expect(!WebSearchTool.detectDDGAntiBot(Self.sampleHTML))
        #expect(!WebSearchTool.detectDDGAntiBot(Self.live2026HTML))
    }

    /// Codex PR #184 round-1 P2 regression: a self-referential
    /// query (e.g. "what is duckduckgo's anomaly-modal page?")
    /// could legitimately match real results whose echoed title or
    /// snippet contains the marker substring. Before the
    /// ``result__body`` gate, the detector would misclassify those
    /// hits as a block and the model would get an error instead of
    /// the actual answer.
    ///
    /// This fixture pins both halves of the gate: the page has a
    /// real result block (so the structural guard short-circuits)
    /// AND its snippet contains the bare ``anomaly-modal`` and
    /// ``cc=botnet`` marker tokens (which would otherwise fire the
    /// detector). Both assertions must hold for the contract to
    /// survive.
    static let metaQueryHTML = #"""
    <html>
    <body>
    <div class="results">
      <div class="result results_links">
        <div class="result__body">
          <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fbot-challenge&amp;rut=z">How DDG's anomaly-modal challenge works</a></h2>
          <a class="result__snippet" href="https://example.org/bot-challenge">When you hit the rate limit DDG returns an anomaly-modal page and the form action carries cc=botnet.</a>
        </div>
      </div>
    </div>
    </body>
    </html>
    """#

    @Test("Self-referential query: marker substring inside a real result is NOT misclassified as blocked")
    func selfReferentialQueryIsNotFlagged() {
        // Critical regression guard — the previous substring-only
        // form returned true here and would have hidden a real hit
        // behind a "DuckDuckGo blocked" error.
        #expect(!WebSearchTool.detectDDGAntiBot(Self.metaQueryHTML))
        // Sanity: the parser does still find the hit so the user
        // gets the real answer in the same scenario.
        let results = WebSearchTool.parseDDGHTML(Self.metaQueryHTML, cap: 6)
        #expect(results.count == 1)
        #expect(results[0].url == "https://example.org/bot-challenge")
    }

    /// Codex PR #184 round-2 P3 regression: DDG's challenge page
    /// echoes the original query into a form ``value=""`` attribute
    /// without escaping underscores. If the user searched for the
    /// literal token ``result__body``, the bare substring check
    /// would mistakenly conclude the page has result blocks and the
    /// detector would short-circuit before checking the challenge
    /// markers — silently reverting to "no results found" UX.
    ///
    /// The fix moves the structural guard to ``class="…"``
    /// attribute scoping. This fixture pins the scenario: a
    /// challenge page whose echoed query carries ``result__body``
    /// in a form input value, alongside the real ``anomaly-modal``
    /// markup. The detector must still classify the page as
    /// blocked.
    static let adversarialEchoedQueryHTML = #"""
    <html>
    <body>
    <div class="anomaly-modal">
      <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
      <form action="/?q=result__body&amp;cc=botnet" method="POST">
        <input type="hidden" name="q" value="result__body">
        <button>Continue</button>
      </form>
    </div>
    </body>
    </html>
    """#

    @Test("Adversarial query echoing 'result__body' into a form value does NOT bypass the detector (codex r2 P3)")
    func adversarialEchoedQueryStillDetected() {
        // Without the class-attribute scoping the bare substring
        // check on ``result__body`` would have returned true and
        // the detector would have wrongly stayed silent. Pin the
        // contract so a future "simplification" can't regress it.
        #expect(!WebSearchTool.containsResultBodyClassToken(Self.adversarialEchoedQueryHTML))
        #expect(WebSearchTool.detectDDGAntiBot(Self.adversarialEchoedQueryHTML))
    }

    @Test("containsResultBodyClassToken anchors on real markup")
    func resultBodyClassTokenIsScoped() {
        // True positive: the live 2026 fixture has the token in a
        // real ``class="…"`` list.
        #expect(WebSearchTool.containsResultBodyClassToken(Self.live2026HTML))
        // True positive: the original sample HTML too.
        #expect(WebSearchTool.containsResultBodyClassToken(Self.sampleHTML))
        // False positive guard: token sitting outside any tag
        // (e.g. as page text) is not a class token.
        #expect(!WebSearchTool.containsResultBodyClassToken("the class result__body is used by DDG"))
        // False positive guard: token inside an input value, not a
        // class attribute.
        #expect(!WebSearchTool.containsResultBodyClassToken(
            "<input type=\"hidden\" name=\"q\" value=\"result__body\">"
        ))
    }
}
