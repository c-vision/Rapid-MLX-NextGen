import Foundation
import Testing

/// The model picker must render as a *control*.
///
/// For a long time the picker's pill chrome existed in source but never
/// reached the screen: `.menuStyle(.borderlessButton)` bridges a `Menu`
/// to an AppKit `SwiftUIPopupButton` (an `NSPopUpButton` subclass) and
/// transcodes the SwiftUI label into that control's `title` + `image`,
/// discarding the background, the stroke, the padding, the `Spacer` and
/// the trailing chevron — then tinting the two survivors with the app
/// accent. The dumped AppKit subtree under the old style was exactly
/// `[NSButtonImageView, NSButtonTextField]`. On screen that read as a
/// blue status label, and a dogfooding user reported they would never
/// have known it was clickable.
///
/// These are source greps rather than renders because the failure mode
/// is a *style choice*, and the pixel baselines are opt-in and
/// host-specific. Every grep runs against a comment-stripped copy of the
/// file — the fix's own commentary names the very styles it forbids.
@Suite("Model picker reads as a control")
struct ModelPickerAffordanceTests {

    /// The styles that go back through the AppKit bridge and re-flatten
    /// the label. `.borderless` is especially treacherous: it is what
    /// the SDK's own deprecation note for `.borderlessButton` points at,
    /// and it reproduces the bug exactly.
    @Test("the picker is not on an AppKit-bridged menu / button style")
    func pickerAvoidsBridgedStyles() throws {
        let src = try Self.strippedPickerSource()
        #expect(
            !src.contains(".menuStyle(.borderlessButton)"),
            "`.borderlessButton` renders the Menu through NSPopUpButton and drops the label's chrome."
        )
        #expect(
            src.contains(".menuStyle(.button)"),
            "the picker must stay on SwiftUI's own rendering path via `.menuStyle(.button)`."
        )
        #expect(
            !src.contains(".buttonStyle(.borderless)"),
            "`.borderless` routes back through the AppKit bridge and reproduces the flattened label."
        )
        #expect(
            !src.contains(".buttonStyle(.accessoryBar)"),
            "`.accessoryBar` routes back through the AppKit bridge and reproduces the flattened label."
        )
    }

    /// `.menuStyle(.button)` promotes EVERY leaf of the label to its own
    /// AXMenuButton element, so a VoiceOver user lands on the picker
    /// three times unless the decorative glyphs are hidden. Nothing
    /// fails at build time, so pin it here.
    @Test("the picker's decorative glyphs stay hidden from VoiceOver")
    func decorativeGlyphsAreHiddenFromAX() throws {
        let label = try Self.pickerLabelBlock()
        let hidden = label.components(separatedBy: ".accessibilityHidden(true)").count - 1
        #expect(
            hidden == 2,
            """
            both label glyphs must be .accessibilityHidden(true), or `.menuStyle(.button)` \
            publishes duplicate AXMenuButton elements. Found \(hidden).
            """
        )
        #expect(
            !label.contains(".accessibilityElement(children: .ignore)"),
            "`children: .ignore` de-duplicates but downgrades the role to AXUnknown — hide the glyphs instead."
        )
    }

    /// The picker is the only control in the bar without a system bezel,
    /// so hover is what actually sells it as interactive — and it has to
    /// go through the Reduce-Motion seam like every other animation.
    @Test("the picker has a Reduce-Motion-aware hover response and an AX identity")
    func pickerHasHoverAndIdentity() throws {
        let src = try Self.strippedPickerSource()
        #expect(
            src.contains(".onHover { pickerHovering = $0 }"),
            "the picker must respond to the pointer."
        )
        #expect(
            src.contains(".rapidAnimation(RapidMotion.quick, value: pickerHovering)"),
            "the hover transition must route through the Reduce-Motion seam."
        )
        #expect(
            src.contains("\"ModelPickerBar.ModelMenu\""),
            "the picker needs an accessibility identifier so scripts/walkthrough.sh can drive it."
        )
    }

    // MARK: - Helpers

    /// ``ModelPickerBar.swift`` with every whole-line `//` comment
    /// removed, so the fix's own explanatory prose — which names the
    /// forbidden styles verbatim — can't make these greps lie.
    static func strippedPickerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Rapid/UI/ModelPickerBar.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
        return body
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The picker `Menu`'s label closure: the last `} label: {` that
    /// precedes `.menuStyle(.button)`.
    static func pickerLabelBlock() throws -> String {
        let src = try strippedPickerSource()
        guard let styleRange = src.range(of: ".menuStyle(.button)") else {
            Issue.record("`.menuStyle(.button)` not found in ModelPickerBar.swift — the picker fix looks reverted.")
            return ""
        }
        let head = src[src.startIndex..<styleRange.lowerBound]
        guard let labelRange = head.range(of: "} label: {", options: .backwards) else {
            Issue.record("Could not locate the picker Menu's label closure in ModelPickerBar.swift")
            return ""
        }
        return String(src[labelRange.upperBound..<styleRange.lowerBound])
    }
}
