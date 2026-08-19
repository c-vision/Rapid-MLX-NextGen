import AppKit
import SwiftUI

/// Typography and layout parameters for markdown rendering.
///
/// The field list is transcribed from ChatGPT's own
/// `OAIMarkdown.MarkdownOptions`, recovered by reflection dump: 72 fields, 36
/// of them metrics. Copying the *shape* is deliberate — it is a finished
/// design-system interface, already factored by someone who shipped this UI,
/// and inventing our own would mean rediscovering the same distinctions
/// (four separate padding concepts, per-block text styles, list metrics
/// broken out to nine parameters) by trial and error.
///
/// What could not be recovered is the values: Swift compiles struct defaults
/// into a static template instance, and the binary is stripped. So each
/// constant below is one of:
///
///   * **实测** — measured off a running ChatGPT via circle-fit on corner
///     arcs, ink-height for type, or baseline delta for line spacing.
///   * **推导** — derived arithmetically from a measurement.
///   * **待校准** — a 4pt-grid placeholder. The binary's `fmov` immediate
///     histogram (16.0×392, 12.0×290, 8.0×247, 24.0×227) shows ChatGPT is a
///     strict 4pt-grid system, so these are constrained guesses, not
///     arbitrary ones. Calibrate with the debug colour probe.
/// Not `Equatable`: `NSDirectionalEdgeInsets` isn't, and adding a global
/// conformance for it to satisfy a config struct would be a poor trade.
/// Callers that need change detection should compare the specific field they
/// care about.
struct MarkdownOptions: @unchecked Sendable {

    // MARK: - Text

    public var fontSizeSetting: FontSizeSetting = .default
    /// 实测: CJK ink height 14.0 → 15pt body.
    public var textPointSize: CGFloat = 15
    /// 待校准. 1.35 is the conventional ratio for this size; ChatGPT's own
    /// value is in `lineHeightMultiple`, which we could not recover.
    public var lineHeightMultiple: CGFloat = 1.35
    /// 待校准.
    public var paragraphSpacing: CGFloat = 16
    /// ChatGPT ships nil kerning at body size.
    public var kern: CGFloat?
    public var strongTextWeight: NSFont.Weight = .semibold
    /// nil inherits `textColor`.
    public var strongTextColor: NSColor?
    public var textColor: NSColor = .textColor
    /// 待校准. Gap between rendered blocks. `@ScaledMetric` in the original.
    public var interContentSpacing: CGFloat = 16

    // MARK: - Padding
    //
    // ChatGPT carries four distinct padding concepts. They are not redundant:
    // `insets` frames the block, `textInsets` insets text within that frame,
    // `textContainerInset` belongs to the NSTextContainer and so changes the
    // available layout width, and `textPadding` is a SwiftUI-side padding on
    // the hosting wrapper. We start with only the two that affect text layout
    // and leave the others at zero until a specific mismatch demands them.

    public var insets: NSDirectionalEdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
    public var textInsets: NSDirectionalEdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
    public var textContainerInset: CGSize = .zero
    public var textPadding: NSDirectionalEdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)

    // MARK: - Links

    public var linkColor: NSColor = .linkColor
    public var linkUnderlineStyle: NSUnderlineStyle?
    public var linkUnderlineColor: NSColor?

    // MARK: - Inline code

    public var inlineCodeBackgroundEnabled: Bool = true
    public var inlineCodeBackgroundColor: NSColor?
    /// 待校准 — the element is too small to circle-fit reliably.
    public var inlineCodeCornerRadius: CGFloat = 4
    public var inlineCodeInsets: NSDirectionalEdgeInsets = .init(
        top: 1, leading: 4, bottom: 1, trailing: 4
    )
    public var inlineCodeTextColor: NSColor?

    // MARK: - Code blocks

    /// 实测 (light) was #F8F8F8, and that measurement is now deliberately not
    /// used: sampled against ChatGPT's white page it separates, but this app's
    /// canvas is `RapidTheme.canvas` #FAFAF9, two levels away — the card
    /// vanished into the transcript. #F1F0EC is the same distance below our
    /// canvas that the measured swatch sat below ChatGPT's.
    ///
    /// The dark value is NOT measured — ChatGPT's reference conversation was
    /// captured in light mode. It is `RapidTheme.card`'s #1A1D21, i.e. one
    /// step *above* the #141619 canvas rather than the recessed
    /// `surfaceCode`: a code card sits directly on the transcript, so a
    /// recessed fill would be indistinguishable from the background.
    ///
    /// This used to be a single light literal, which meant the card stayed
    /// near-white in dark mode while the syntax palette resolved to its dark
    /// variants — pale purple keywords on white. Both halves have to switch
    /// together, so this has to be dynamic.
    public var codeBlockBackground: NSColor = markdownDynamicColor(
        light: (0xF1, 0xF0, 0xEC), dark: (0x1A, 0x1D, 0x21)
    )
    /// Same hairline the table uses, for the same reason: fill alone is not
    /// enough separation from the canvas at these low contrasts.
    public var codeBlockBorder: NSColor? = markdownDynamicColor(
        light: (0xE0, 0xE0, 0xDC), dark: (0x2E, 0x32, 0x38)
    )
    /// 实测: circle-fit 14.24 (n=40, mid-arc samples).
    public var codeCornerRadius: CGFloat = 14
    /// 待校准.
    public var codeBlockSpacing: CGFloat = 20
    public var codeInsets: NSDirectionalEdgeInsets = .init(
        top: 12, leading: 14, bottom: 12, trailing: 14
    )
    public var codeTextContainerInset: CGSize = .zero
    public var codeHeaderInsets: NSDirectionalEdgeInsets = .init(
        top: 8, leading: 14, bottom: 8, trailing: 8
    )
    /// 推导: measured line spacing 16.0 ÷ 1.23 ≈ 13pt.
    public var codePointSize: CGFloat = 13
    /// 实测: baseline Δ=16.0 in the code block.
    public var codeLineHeight: CGFloat = 16

    // MARK: - Tables
    //
    // ChatGPT's field list has `tableCellInsets`, `tableBorderCornerRadius`,
    // `tableHeaderBackgroundColor` and `tableTextStyle` — and nothing for cell
    // borders, which we first read as evidence that the table is separated by
    // rhythm alone. In practice a borderless table in this transcript reads as
    // three columns of loose text, so `tableBorderColor` is ours rather than
    // transcribed. `nil` restores the original borderless rendering.

    /// 推导 from the measured 42pt row height.
    public var tableCellInsets: NSDirectionalEdgeInsets = .init(
        top: 8, leading: 12, bottom: 8, trailing: 12
    )
    /// 待校准.
    public var tableBorderCornerRadius: CGFloat = 8
    /// Grid line around the table and between its cells. Quiet enough to
    /// stay out of the prose's way — one step softer than
    /// `RapidTheme.hairlineStrong` in both modes.
    public var tableBorderColor: NSColor? = markdownDynamicColor(
        light: (0xE0, 0xE0, 0xDC), dark: (0x2E, 0x32, 0x38)
    )
    public var tableBorderWidth: CGFloat = 1
    /// A quiet fill so the header row reads as a header.
    ///
    /// Left nil originally, on the reading that ChatGPT's table separates rows
    /// by rhythm alone. It does — but rhythm plus a header fill, and with the
    /// fill absent the whole table collapsed into three columns of loose text
    /// with nothing marking the head. `Color.clear` under a nil is still the
    /// escape hatch for a caller that wants the fill gone.
    public var tableHeaderBackgroundColor: NSColor? = markdownDynamicColor(
        light: (0xF1, 0xF1, 0xEF), dark: (0x22, 0x25, 0x2A)
    )
    /// 实测: AX row frame h=42, confirmed by baseline Δ=42.
    public var tableRowHeight: CGFloat = 42
    public var tablePointSize: CGFloat = 14

    // MARK: - Lists
    //
    // Nine parameters because ChatGPT has nine. Lists are rendered with
    // NSParagraphStyle hanging indents rather than stacked views — which is
    // what these metrics describe, and what keeps a list inside one text
    // block so the fade animator can address it.

    /// 推导 from measured inter-item Δ=27 minus one line height.
    public var listInterItemSpacing: CGFloat = 6
    /// 待校准.
    public var listDepthIndent: CGFloat = 22
    public var unorderedListBaseLeftMargin: CGFloat = 0
    public var orderedListBaseLeftMargin: CGFloat = 0
    public var unorderedListSpacingFromMarker: CGFloat = 10
    public var listSpacingFromIndex: CGFloat = 8
    /// Bullet diameter as a fraction of line height.
    public var listBulletHeightMultiplier: CGFloat = 0.34
    public var indentFirstUnorderedListLevel: Bool = false
    public var whitespaceAfterUnorderedListIcon: CGFloat = 0

    // MARK: - Block quotes

    public var blockQuoteBarColor: NSColor?
    public var blockQuoteBarWidth: CGFloat = 2
    public var blockQuoteLeadingInset: CGFloat = 16
    public var blockQuoteIndentation: CGFloat = 16

    // MARK: - Horizontal rules

    public var horizontalRuleColor: NSColor?
    public var horizontalRuleHeight: CGFloat = 1
    public var horizontalRuleInsets: NSDirectionalEdgeInsets = .init(
        top: 20, leading: 0, bottom: 20, trailing: 0
    )

    // MARK: - Images

    /// 待校准 — no images in the reference conversation.
    public var imageCornerRadius: CGFloat = 12
    public var gridImageCornerRadius: CGFloat = 8
    public var maxImageWidth: CGFloat = 512
    public var maxImageHeight: CGFloat = 512
    public var maxImageGridWidth: CGFloat = 640
    public var imageGridSpacing: CGFloat = 8
    /// ChatGPT switches grid density by size class.
    public var maxImagesPerGridRowCompact: Int = 2
    public var maxImagesPerGridRowRegular: Int = 3

    // MARK: - Layout

    /// Tables are allowed to exceed the prose column and scroll horizontally —
    /// that is what `nonTableMaxWidth` implies in the original.
    public var nonTableMaxWidth: CGFloat?
    public var textBlockLineLimit: Int = 0
    public var hugsTextHorizontally: Bool = false

    public init() {}
}

/// An appearance-aware `NSColor` for markdown chrome.
///
/// Every colour in this file has to be resolved at *draw* time, not at struct
/// construction: `MarkdownOptions` is built once per view update and outlives
/// an appearance change, so a colour baked from a light/dark test at init
/// freezes to whatever the theme was on that pass — the same failure the
/// syntax palette documents in ``SyntaxHighlighter``. A dynamic provider is
/// re-evaluated by AppKit on each resolve instead.
///
/// Spelled out here rather than reusing `RapidTheme`'s tokens because those
/// are SwiftUI `Color`s and this layer needs `NSColor`; the round trip back
/// through `NSColor(_:)` loses the dynamic provider.
func markdownDynamicColor(
    light: (Int, Int, Int), dark: (Int, Int, Int)
) -> NSColor {
    NSColor(name: nil, dynamicProvider: { appearance in
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastDarkAqua
        ])
        let isDark = (match == .darkAqua || match == .accessibilityHighContrastDarkAqua)
        let c = isDark ? dark : light
        return NSColor(
            deviceRed: CGFloat(c.0) / 255.0,
            green: CGFloat(c.1) / 255.0,
            blue: CGFloat(c.2) / 255.0,
            alpha: 1
        )
    })
}

// MARK: - Presets

extension MarkdownOptions {
    /// Assistant transcript body: full width, no bubble.
    static func assistantTranscript(_ size: FontSizeSetting = .default) -> MarkdownOptions {
        var o = MarkdownOptions()
        o.fontSizeSetting = size
        o.textPointSize = size.bodyPointSize
        o.codePointSize = size.codePointSize
        o.codeLineHeight = size.codeLineHeight
        return o
    }

    /// User message: same type, but rendered inside a bubble that caps its
    /// own width, so the block does not add horizontal insets of its own.
    static func userBubble(_ size: FontSizeSetting = .default) -> MarkdownOptions {
        var o = assistantTranscript(size)
        o.insets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        o.paragraphSpacing = 8
        // The bubble sizes to its text rather than filling the column. Without
        // this a three-word message renders as wide as a paragraph.
        o.hugsTextHorizontally = true
        return o
    }
}
