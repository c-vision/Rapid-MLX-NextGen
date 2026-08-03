import Foundation
import Testing
@testable import Rapid

/// Live inline markdown on the streaming fast path (2026-07 typography
/// sweep). The formatter is a mini-parser with known sharp edges —
/// fences, flanking rules, unclosed markers mid-stream — so the truth
/// table is pinned here. Styling is asserted through
/// `inlinePresentationIntent` runs; plain-character content is
/// asserted by stripping the markers.
@Suite("ChatStreamInlineFormatter — streaming inline markdown")
struct ChatStreamInlineFormatterTests {

    private func plain(_ a: AttributedString) -> String {
        String(a.characters)
    }

    private func runs(_ a: AttributedString) -> [(String, InlinePresentationIntent?)] {
        a.runs.map { run in
            (String(a.characters[run.range]), run.inlinePresentationIntent)
        }
    }

    // MARK: - The reported bug

    @Test("**bold** renders as a strongly-emphasized run with the markers stripped")
    func boldStripsMarkers() {
        let (out, _) = ChatStreamInlineFormatter.format("il **canone mensile** è di 1.250 euro")
        #expect(plain(out) == "il canone mensile è di 1.250 euro")
        #expect(runs(out).contains { $0.0 == "canone mensile" && $0.1 == .stronglyEmphasized })
    }

    @Test("*italic*, _italic_ and `code` all style with markers stripped")
    func italicAndCode() {
        let (star, _) = ChatStreamInlineFormatter.format("una *parola* sola")
        #expect(plain(star) == "una parola sola")
        #expect(runs(star).contains { $0.0 == "parola" && $0.1 == .emphasized })

        let (underscore, _) = ChatStreamInlineFormatter.format("una _parola_ sola")
        #expect(plain(underscore) == "una parola sola")
        #expect(runs(underscore).contains { $0.0 == "parola" && $0.1 == .emphasized })

        let (code, _) = ChatStreamInlineFormatter.format("chiama `ensureServing` qui")
        #expect(plain(code) == "chiama ensureServing qui")
        #expect(runs(code).contains { $0.0 == "ensureServing" && $0.1 == .code })
    }

    // MARK: - Self-healing: unclosed markers stay literal

    @Test("an unclosed marker renders literally until its twin arrives")
    func unclosedMarkersStayLiteral() {
        // Mid-stream: the model has emitted the opener but not yet the
        // closer. No styling, no vanishing characters.
        let (bold, _) = ChatStreamInlineFormatter.format("questo è **importante ma non anco")
        #expect(plain(bold) == "questo è **importante ma non anco")
        #expect(!runs(bold).contains { $0.1 == .stronglyEmphasized })

        let (tick, _) = ChatStreamInlineFormatter.format("vedi `ensureSer")
        #expect(plain(tick) == "vedi `ensureSer")
        #expect(!runs(tick).contains { $0.1 == .code })
    }

    // MARK: - Flanking rules

    @Test("snake_case and arithmetic asterisks are not emphasis")
    func flankingRules() {
        let (snake, _) = ChatStreamInlineFormatter.format("usa max_attachment_bytes qui")
        #expect(plain(snake) == "usa max_attachment_bytes qui")
        #expect(!runs(snake).contains { $0.1 == .emphasized })

        let (math, _) = ChatStreamInlineFormatter.format("3 * 4 * 5 fa 60")
        #expect(plain(math) == "3 * 4 * 5 fa 60")
        #expect(!runs(math).contains { $0.1 == .emphasized })
    }

    // MARK: - Fences

    @Test("no styling inside ``` fences; fence state survives chunk boundaries")
    func fencesSuppressStyling() {
        let text = "prima **vera**\n```\nlet a = **not bold**\n```\ndopo **vera**"
        let (out, endsInFence) = ChatStreamInlineFormatter.format(text)
        #expect(!endsInFence)
        // The fenced line keeps its asterisks verbatim.
        #expect(plain(out).contains("**not bold**"))
        // Both prose lines styled.
        #expect(runs(out).filter { $0.1 == .stronglyEmphasized }.count == 2)

        // A chunk ending inside an open fence reports it, and a
        // follow-up chunk starting inside one stays literal.
        let (_, open) = ChatStreamInlineFormatter.format("testo\n```swift\nlet x = 1")
        #expect(open)
        let (inside, _) = ChatStreamInlineFormatter.format("**still code**", startingInsideFence: true)
        #expect(plain(inside) == "**still code**")
        #expect(!runs(inside).contains { $0.1 == .stronglyEmphasized })
    }

    // MARK: - Memo

    @Test("memo output is identical to a cold full format at every streaming step")
    func memoMatchesColdFormat() {
        // Simulate a stream arriving in arbitrary small deltas across
        // paragraphs and a fence; at every step the memoised result
        // must equal formatting the whole buffer from scratch.
        let full = "primo **paragrafo** con `code`.\n\nsecondo _paragrafo_\n\n```\n**fenced**\n```\n\nterzo **finale**"
        var memo = ChatStreamInlineFormatter.Memo()
        var buffer = ""
        for chunk in full.split(separator: " ", omittingEmptySubsequences: false).map({ $0 + " " }) {
            buffer += chunk
            let viaMemo = memo.formatted(buffer)
            let cold = ChatStreamInlineFormatter.format(buffer).result
            #expect(viaMemo == cold, "divergence at buffer length \(buffer.count)")
        }
    }

    @Test("memo resets safely when the input stops extending the previous one")
    func memoResetsOnNonExtension() {
        var memo = ChatStreamInlineFormatter.Memo()
        _ = memo.formatted("una **prima** risposta\n\ncon coda")
        // Row reuse / regenerate: entirely different content.
        let fresh = memo.formatted("**nuova** risposta")
        #expect(plain(fresh) == "nuova risposta")
        #expect(runs(fresh).contains { $0.0 == "nuova" && $0.1 == .stronglyEmphasized })
    }

    @Test("stableBoundary refuses to settle inside an open fence")
    func stableBoundaryRespectsFences() {
        // The only paragraph break sits inside an open fence — no
        // stable boundary may be declared there.
        let chunk = "```\ncode\n\nstill code"
        #expect(
            ChatStreamInlineFormatter.Memo.stableBoundary(
                in: chunk, startingInsideFence: false
            ) == nil
        )
        // Same text with the fence closed before the break: boundary OK.
        let closed = "```\ncode\n```\n\nprosa"
        #expect(
            ChatStreamInlineFormatter.Memo.stableBoundary(
                in: closed, startingInsideFence: false
            ) != nil
        )
    }

    // MARK: - Perf smoke (budget, not benchmark)

    @Test("per-flush cost on a 20K buffer with a small delta stays in budget")
    func perFlushBudget() {
        let paragraph = "Testo con **grassetto** e `codice` e _corsivo_ ripetuto più volte.\n\n"
        var buffer = String(repeating: paragraph, count: 300)  // ~20K chars
        var memo = ChatStreamInlineFormatter.Memo()
        _ = memo.formatted(buffer)  // warm: stable prefix built

        let start = ContinuousClock.now
        for _ in 0..<60 {  // one second of coalescer flushes
            buffer += "parola "
            _ = memo.formatted(buffer)
        }
        let elapsed = ContinuousClock.now - start
        // 60 flushes over a warm memo must land well under a frame
        // budget each. Generous ceiling (500 ms total ≈ 8 ms/flush)
        // so CI load can't flake it; the point is catching an
        // accidental O(buffer)-per-flush regression, which would blow
        // past this by an order of magnitude.
        #expect(elapsed < .milliseconds(500), "per-flush formatting cost regressed: \(elapsed)")
    }
}
