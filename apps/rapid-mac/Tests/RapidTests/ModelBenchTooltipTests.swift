import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// v0.7.16 — pin the picker hover tooltip's pure rendering rules:
///
///   * The 5-axis bar values are formatted as "82.5" for LLM benches
///     (one decimal place) and "262 t/s" for Speed.
///   * Below-good → grey; good (≥ good, < great) → yellow.opacity(0.85);
///     great (≥ great) → accent. n/a → dashed track + em-dash.
///   * The footer surfaces the General-&-Reasoning basis when both
///     MMLU-Pro and GPQA are present and the Apple M3 Ultra speed
///     caveat whenever a speed number exists.
///   * Accessibility label folds the alias, tagline, and a per-axis
///     status sentence into a single string so VoiceOver users get
///     the same information sighted users glean from the bars.
///
/// These are deliberately property tests against the pure helpers on
/// ``BenchBarRow`` / ``ModelBenchTooltip`` rather than NSHostingView
/// snapshots — snapshots add CI fragility (NSAttributedString line
/// metrics drift across SwiftUI versions) and the bars' visual logic
/// reduces to "thresholds + format string + a Color". The unit
/// suite already has SnapshotHelpers for surfaces that need pixel
/// regression coverage; this surface doesn't.
@Suite("ModelBenchTooltip — bar formatting + rating + footer + accessibility")
struct ModelBenchTooltipTests {

    // MARK: - Value formatting

    @Test("Speed values render as integer t/s")
    func speedFormatsAsTokensPerSecond() {
        #expect(BenchBarRow.formattedValue(axis: .speed, value: 262.0) == "262 t/s")
        #expect(BenchBarRow.formattedValue(axis: .speed, value: 95.2) == "95 t/s")
        #expect(BenchBarRow.formattedValue(axis: .speed, value: 159.6) == "160 t/s")
    }

    @Test("LLM-bench values render with one decimal place")
    func llmBenchFormatsAsOneDecimal() {
        #expect(BenchBarRow.formattedValue(axis: .generalReasoning, value: 82.1) == "82.1")
        #expect(BenchBarRow.formattedValue(axis: .code, value: 65.6) == "65.6")
        #expect(BenchBarRow.formattedValue(axis: .tool, value: 50.0) == "50.0")
        #expect(BenchBarRow.formattedValue(axis: .ifeval, value: 88.0) == "88.0")
    }

    @Test("nil values render as the em-dash on every axis")
    func nilRendersAsEmDash() {
        for axis in BenchScores.Axis.allCases {
            #expect(BenchBarRow.formattedValue(axis: axis, value: nil) == "—")
        }
    }

    // MARK: - Rating classification

    @Test("MMLU-Pro 82.5 alone classifies as great (≥ 80)")
    func mmluProGreatClassification() {
        let t = BenchScores.Axis.generalReasoning.thresholds
        // Merged G&R uses (50, 75). Pure MMLU-Pro 82.5 piped in is
        // a great score on the merged scale.
        #expect(BenchBarRow.rating(for: 82.5, thresholds: t) == .great)
    }

    @Test("General-&-Reasoning 60 classifies as good (≥ 50 && < 75)")
    func generalReasoningGoodClassification() {
        let t = BenchScores.Axis.generalReasoning.thresholds
        #expect(BenchBarRow.rating(for: 60.0, thresholds: t) == .good)
    }

    @Test("General-&-Reasoning 30 classifies as below good (< 50)")
    func generalReasoningBelowClassification() {
        let t = BenchScores.Axis.generalReasoning.thresholds
        #expect(BenchBarRow.rating(for: 30.0, thresholds: t) == .below)
    }

    @Test("Code: 65 is great, 30 is good, 10 is below")
    func codeRatingBoundaries() {
        let t = BenchScores.Axis.code.thresholds
        #expect(BenchBarRow.rating(for: 65.0, thresholds: t) == .great)
        #expect(BenchBarRow.rating(for: 64.9, thresholds: t) == .good)
        #expect(BenchBarRow.rating(for: 30.0, thresholds: t) == .good)
        #expect(BenchBarRow.rating(for: 29.9, thresholds: t) == .below)
    }

    @Test("Speed: 262 t/s is great, 100 t/s is good, 40 t/s is below")
    func speedRatingBoundaries() {
        let t = BenchScores.Axis.speed.thresholds
        #expect(BenchBarRow.rating(for: 262.0, thresholds: t) == .great)
        #expect(BenchBarRow.rating(for: 180.0, thresholds: t) == .great)
        #expect(BenchBarRow.rating(for: 179.9, thresholds: t) == .good)
        #expect(BenchBarRow.rating(for: 80.0, thresholds: t) == .good)
        #expect(BenchBarRow.rating(for: 79.9, thresholds: t) == .below)
    }

    @Test("Color matches the rating: great = accent, good = yellow, below = secondary")
    func colorTracksRating() {
        let t = BenchScores.Axis.tool.thresholds
        #expect(BenchBarRow.color(for: 75.0, thresholds: t) == Color.accentColor)
        #expect(BenchBarRow.color(for: 60.0, thresholds: t) == Color.yellow.opacity(0.85))
        #expect(BenchBarRow.color(for: 20.0, thresholds: t) == Color.secondary)
    }

    // MARK: - Footer

    @Test("Footer surfaces the General-&-Reasoning basis when both MMLU-Pro and GPQA are present")
    func footerSurfacesGRBasis() {
        let scores = BenchScores(
            generalReasoning: 82.1,
            generalReasoningSource: "mean(mmlu_pro, gpqa_diamond)",
            mmluPro: 82.5,
            gpqaDiamond: 81.7,
            code: 65.6, tool: 66.1, ifeval: 91.5, speedTps: 106.4
        )
        let lines = ModelBenchTooltip.footerLines(for: scores)
        #expect(lines.count == 2)
        #expect(lines[0].contains("MMLU-Pro 82.5"))
        #expect(lines[0].contains("GPQA 81.7"))
        #expect(lines[1] == "Speed measured on Apple M3 Ultra.")
    }

    @Test("Footer uses MMLU-only basis when GPQA is missing")
    func footerMMLUOnly() {
        let scores = BenchScores(
            generalReasoning: 60.6,
            generalReasoningSource: "mmlu_pro only",
            mmluPro: 60.6,
            gpqaDiamond: nil,
            code: nil, tool: nil, ifeval: 88.9, speedTps: nil
        )
        let lines = ModelBenchTooltip.footerLines(for: scores)
        #expect(lines.contains { $0.contains("MMLU-Pro 60.6 only") })
        // No speed caveat — speedTps is nil.
        #expect(!lines.contains { $0.contains("Apple M3 Ultra") })
    }

    @Test("Footer is empty when neither basis nor speed are known")
    func footerEmptyForAllNil() {
        let scores = BenchScores(
            generalReasoning: nil,
            generalReasoningSource: nil,
            mmluPro: nil, gpqaDiamond: nil,
            code: nil, tool: nil, ifeval: nil, speedTps: nil
        )
        let lines = ModelBenchTooltip.footerLines(for: scores)
        #expect(lines.isEmpty)
    }

    // MARK: - Accessibility label

    @Test("Accessibility label includes the alias, tagline, and every axis sentence")
    func accessibilityLabelComposes() {
        let scores = BenchScores(
            generalReasoning: 82.1,
            generalReasoningSource: "mean(mmlu_pro, gpqa_diamond)",
            mmluPro: 82.5, gpqaDiamond: 81.7,
            code: 65.6, tool: 66.1, ifeval: 91.5, speedTps: 106.4
        )
        let label = ModelBenchTooltip.accessibilityLabel(
            alias: "qwen3.5-9b-4bit",
            tagline: "Best balance — what we'd pick first",
            scores: scores
        )
        #expect(label.contains("qwen3.5-9b-4bit"))
        #expect(label.contains("Best balance"))
        #expect(label.contains("General & Reasoning"))
        #expect(label.contains("great"))      // 82.1 ≥ 75 great
        #expect(label.contains("106 tokens per second"))
    }

    @Test("Accessibility label flags n/a axes as 'not measured'")
    func accessibilityLabelHandlesNA() {
        let scores = BenchScores(
            generalReasoning: 17.0,
            generalReasoningSource: "mean(mmlu_pro, gpqa_diamond)",
            mmluPro: 14.7, gpqaDiamond: 19.2,
            code: 1.9, tool: nil, ifeval: 80.2, speedTps: 262.0
        )
        let label = ModelBenchTooltip.accessibilityLabel(
            alias: "gemma3-1b-qat-4bit",
            tagline: "Tiny + fast (~262 t/s). Trades depth for snappiness.",
            scores: scores
        )
        #expect(label.contains("Tool not measured"))
        #expect(label.contains("262 tokens per second"))
        // IFEval 80.2 is great (≥ 88) ? No — 80.2 < 88, so it's good
        // (≥ 75). Make sure the classifier renders the right word.
        #expect(label.contains("Instruction Following 80.2, good"))
    }

    @Test("Accessibility label degrades gracefully when no score row exists")
    func accessibilityLabelHandlesMissingScores() {
        let label = ModelBenchTooltip.accessibilityLabel(
            alias: "custom-alias",
            tagline: "Type alias…",
            scores: nil
        )
        #expect(label.contains("custom-alias"))
        #expect(label.contains("Type alias…"))
        #expect(label.contains("not yet recorded"))
    }
}

// MARK: - roleRow help-text helper

/// The picker dropdown is built from a SwiftUI ``Menu``, which
/// converts each row Button into an NSMenuItem. NSMenuItems silently
/// drop ``.popover`` / ``.onHover`` modifiers, so the rich hover
/// tooltip is delivered via NSMenu's native tooltip surface
/// (``.help(_:)``) inside the open dropdown. The popover wiring is
/// still attached for surfaces that DO honour ``.popover`` on hover
/// (future "Recommended" sidebars, accessibility tools).
///
/// These tests pin the synthesised help-text shape so a typo in the
/// row builder is caught at CI time.
@Suite("ModelPickerBar.roleRowHelpText — NSMenu fallback for rich tooltip")
struct ModelPickerBarHelpTextTests {

    @Test("Help text includes the tagline and every axis line")
    func helpTextIncludesAllAxes() {
        let scores = BenchScores(
            generalReasoning: 82.1,
            generalReasoningSource: "mean(mmlu_pro, gpqa_diamond)",
            mmluPro: 82.5, gpqaDiamond: 81.7,
            code: 65.6, tool: 66.1, ifeval: 91.5, speedTps: 106.4
        )
        let tagline = "Best balance — what we'd pick first"
        let text = ModelPickerBar.roleRowHelpText(tagline: tagline, scores: scores)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == tagline)
        // Five axes, one line each, after the tagline.
        #expect(lines.count == 6)
        #expect(lines.contains("General & Reasoning: 82.1"))
        #expect(lines.contains("Code: 65.6"))
        #expect(lines.contains("Tool: 66.1"))
        #expect(lines.contains("Instruction Following: 91.5"))
        #expect(lines.contains("Speed: 106 t/s"))
    }

    @Test("Help text renders em-dash for n/a axes")
    func helpTextHandlesNA() {
        let scores = BenchScores(
            generalReasoning: 17.0,
            generalReasoningSource: "mean(mmlu_pro, gpqa_diamond)",
            mmluPro: 14.7, gpqaDiamond: 19.2,
            code: 1.9, tool: nil, ifeval: 80.2, speedTps: 262.0
        )
        let text = ModelPickerBar.roleRowHelpText(
            tagline: "Tiny + fast",
            scores: scores
        )
        #expect(text.contains("Tool: —"))
        #expect(text.contains("Speed: 262 t/s"))
    }

    @Test("Help text falls back to the tagline alone when no score row exists")
    func helpTextFallback() {
        let text = ModelPickerBar.roleRowHelpText(tagline: "Best balance", scores: nil)
        #expect(text == "Best balance")
    }
}

/// Codex r1 MINOR on PR #283: a quick brush of the cursor (enter
/// then exit before the 400 ms debounce) used to leak the popover
/// open AFTER the cursor had already left. The enter task captured
/// the alias, the exit branch saw ``hoveredBenchAlias == nil`` and
/// did nothing, and the delayed body then set the popover live.
///
/// The fix tracks a monotonically-increasing generation token; the
/// delayed task captures the token at scheduling time and bails if
/// any newer event has bumped the counter. These tests pin the
/// pure ``reduceBenchHover`` mirror so the race semantics are
/// regression-safe.
@Suite("ModelPickerBar.reduceBenchHover — debounce race (codex r1)")
struct ModelPickerBarHoverRaceTests {

    @Test("Hover-enter with no later event opens the popover for that alias")
    func enterAloneOpens() {
        let (gen, alias) = ModelPickerBar.reduceBenchHover(
            previousGeneration: 0,
            previousHoveredAlias: nil,
            eventAlias: "qwen3.5-9b-4bit",
            hovering: true
        )
        #expect(gen == 1)
        #expect(alias == "qwen3.5-9b-4bit")
    }

    @Test("Hover-enter followed by quick exit BEFORE the timer fires must NOT open the popover")
    func enterThenExitBeforeFire() {
        // Step 1: enter. Force the predicate to "yes, the generation
        // got bumped after we scheduled" — modeling the case where
        // the exit fired during the 400 ms sleep.
        let after1 = ModelPickerBar.reduceBenchHover(
            previousGeneration: 0,
            previousHoveredAlias: nil,
            eventAlias: "qwen3.5-9b-4bit",
            hovering: true,
            wasGenerationBumpedBeforeFire: { _ in true }
        )
        // The simulated body bailed: previousHoveredAlias stays nil.
        #expect(after1.hoveredAlias == nil)
        #expect(after1.generation == 1)

        // Step 2: the (delayed) exit event itself. It must bump the
        // generation and leave hoveredAlias untouched (the popover
        // was never opened).
        let after2 = ModelPickerBar.reduceBenchHover(
            previousGeneration: after1.generation,
            previousHoveredAlias: after1.hoveredAlias,
            eventAlias: "qwen3.5-9b-4bit",
            hovering: false
        )
        #expect(after2.hoveredAlias == nil)
        #expect(after2.generation == 2)
    }

    @Test("Hover-enter on a SECOND row before the first's timer fires keeps only the latest target")
    func freshHoverWinsRace() {
        // First row enters and is "still pending" when a second row
        // takes over. The first row's delayed body should bail and
        // the second row's body should win.
        let firstEnter = ModelPickerBar.reduceBenchHover(
            previousGeneration: 0,
            previousHoveredAlias: nil,
            eventAlias: "rowA",
            hovering: true,
            wasGenerationBumpedBeforeFire: { _ in true }   // bumped by rowB
        )
        #expect(firstEnter.hoveredAlias == nil)

        let secondEnter = ModelPickerBar.reduceBenchHover(
            previousGeneration: firstEnter.generation,
            previousHoveredAlias: firstEnter.hoveredAlias,
            eventAlias: "rowB",
            hovering: true,
            wasGenerationBumpedBeforeFire: { _ in false }  // no newer event
        )
        #expect(secondEnter.hoveredAlias == "rowB")
        #expect(secondEnter.generation == 2)
    }

    @Test("Hover-exit on an unrelated row leaves the open popover untouched")
    func exitOnUnrelatedRowKeepsOpenPopover() {
        let result = ModelPickerBar.reduceBenchHover(
            previousGeneration: 5,
            previousHoveredAlias: "rowA",
            eventAlias: "rowB",
            hovering: false
        )
        #expect(result.hoveredAlias == "rowA")
        #expect(result.generation == 6)
    }
}
