import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// PR4 (#548) — shared press-feedback button style (§1 "respond on
/// pointer-down").
///
/// The style's press treatment is a pure value pair (scale + opacity) plus a
/// Reduce-Motion seam, so the numeric contract gets real assertions; the view
/// adoptions (onboarding cards, primary CTAs, chips, the scroll pill, and both
/// amber CTAs) are pinned by source guards mirroring the repo's existing
/// source-grep tripwires. The tool-run disclosure header is deliberately NOT
/// adopted — its shared card boundary would detach under a label-scoped scale.
@Suite("PR4 — pressable button style (#548)")
struct PressFeedbackTests {

    // MARK: - The press treatment contract

    @Test("standard press feedback shrinks and dims on pointer-down")
    func standardPressValues() {
        let style = PressableButtonStyle.pressable
        // A real, visible depress — not a no-op — the instant isPressed flips.
        #expect(style.pressedScale < 1.0)
        #expect(style.pressedOpacity < 1.0)
        // But subtle, never a jarring collapse.
        #expect(style.pressedScale >= 0.94)
        #expect(style.pressedOpacity >= 0.75)
    }

    @Test("the default initializer matches the .pressable preset")
    func defaultInitMatchesPreset() {
        let preset = PressableButtonStyle.pressable
        let fresh = PressableButtonStyle()
        #expect(fresh.pressedScale == preset.pressedScale)
        #expect(fresh.pressedOpacity == preset.pressedOpacity)
    }

    @Test("the card variant depresses and dims LESS than the standard one")
    func cardVariantIsGentler() {
        // The same shrink ratio on a large card surface reads as an oversized
        // jump, so cards must move less than buttons/chips (closer to 1.0).
        let button = PressableButtonStyle.pressable
        let card = PressableButtonStyle.pressableCard
        #expect(card.pressedScale > button.pressedScale)
        #expect(card.pressedOpacity > button.pressedOpacity)
        #expect(card.pressedScale < 1.0)   // still visibly reacts
        #expect(card.pressedOpacity < 1.0)
    }

    // MARK: - Reduce-Motion seam (§14)

    @Test("the press style drives its spring through the Reduce-Motion seam")
    func pressStyleHonorsReduceMotion() throws {
        let src = try source("Sources/Rapid/UI/Modifiers/PressableButtonStyle.swift")
        // Scale is the vestibular part — it must be gated on Reduce Motion.
        #expect(src.contains("accessibilityReduceMotion"),
                "the style must read accessibilityReduceMotion to suppress the shrink (§14).")
        #expect(src.contains("!reduceMotion ? pressedScale"),
                "the scaleEffect must collapse to 1.0 under Reduce Motion.")
        // The spring itself routes through the shared Reduce-Motion resolver.
        #expect(src.contains("RapidMotion.resolve(RapidMotion.quick"),
                "the press animation must use the shared interruptible quick spring via resolve().")
        // The opacity dip stays as a non-motion press cue even under Reduce Motion.
        #expect(src.contains("opacity(configuration.isPressed ? pressedOpacity"),
                "the opacity press cue must remain (it is not motion) under Reduce Motion.")
    }

    // MARK: - Source guards for the view adoptions

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("§1/P1: the two selectable onboarding model cards adopt the card press style")
    func onboardingCardsArePressable() throws {
        let src = try source("Sources/Rapid/UI/OnboardingComponents.swift")
        // Both selectable first-run cards must react on press — the audit's P1.
        let count = src.components(separatedBy: ".buttonStyle(.pressableCard)").count - 1
        #expect(count >= 2,
                "QuickstartModelCard and QuickstartCompactCard must both use .pressableCard.")
        // And the dead .plain must be gone from those two cards.
        #expect(!src.contains(".buttonStyle(.plain)\n        .accessibilityIdentifier(\"Quickstart.Choice"),
                "the onboarding choice cards must no longer be feedback-less .plain buttons.")
    }

    @Test("§1: the primary CTAs and empty-state chips adopt the press style")
    func ctasAndChipsArePressable() throws {
        let chat = try source("Sources/Rapid/UI/ChatView.swift")
        // send/stop CTA, capability chips, and the scroll pill — all
        // previously feedback-less .plain. The tool-run disclosure
        // header is deliberately excluded: its card fill/stroke wrap
        // both the header AND the expandable body, so a label-scoped
        // scale would detach the header from the static card edge.
        //
        // History of the floor (audit counted four): the empty-state
        // example-prompt chips were superseded by #589's
        // ``PresetQuickPicker`` — whose chips adopt ``.pressable`` in
        // ``PresetViews.swift``, pinned below — and the inline-edit
        // Cancel/Send pair was retired by the edit-rewind redesign
        // (the pencil now stages the turn into the composer). Both
        // post-date the audit; the intent survives on every surface
        // that still exists.
        let chatAdoptions = chat.components(separatedBy: ".buttonStyle(.pressable)").count - 1
        #expect(chatAdoptions >= 3,
                "the three flagged single-surface ChatView controls (send/stop CTA, capability chips, scroll pill) must use .pressable (§1).")
        let presets = try source("Sources/Rapid/UI/PresetViews.swift")
        #expect(presets.contains(".buttonStyle(.pressable)"),
                "the PresetQuickPicker chips inherited the example-prompt chips' §1 obligation and must stay .pressable.")
        let sidebar = try source("Sources/Rapid/UI/SessionsSidebar.swift")
        #expect(sidebar.contains(".buttonStyle(.pressable)"),
                "the New chat CTA must react on press (§1).")
        let picker = try source("Sources/Rapid/UI/ModelPickerBar.swift")
        #expect(picker.contains(".buttonStyle(.pressable)"),
                "the Start / Download & start CTA must react on press (§1).")
    }

    @Test("§1: the New chat CTA fill lives inside the label so the whole pill depresses")
    func newChatFillIsInsideLabel() throws {
        // A ButtonStyle scales `configuration.label`; if the amber .background
        // stayed OUTSIDE the label the shrink would clip only the text. The
        // fill must sit within the label closure, before .buttonStyle.
        let sidebar = try source("Sources/Rapid/UI/SessionsSidebar.swift")
        guard let fillRange = sidebar.range(of: ".fill(RapidTheme.amber)"),
              let styleRange = sidebar.range(of: ".buttonStyle(.pressable)") else {
            Issue.record("expected the amber fill and the pressable style in the New chat CTA")
            return
        }
        #expect(fillRange.lowerBound < styleRange.lowerBound,
                "the amber fill must be applied inside the label, ahead of .buttonStyle.")
    }

    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
