import SwiftUI
import AppKit
import SwiftMath

/// Issue #131: SwiftUI wrapper around SwiftMath's ``MTMathUILabel``
/// (the macOS-friendly Swift port of iosMath). Renders a LaTeX
/// expression natively — no ``WKWebView``, no JS.
///
/// The label is an ``NSView`` subclass; we bridge it via
/// ``NSViewRepresentable`` and recompute the intrinsic size on
/// every update so the SwiftUI layout system gives us the right
/// frame.
///
/// Why a fresh ``label.sizeToFit()`` on every update:
/// ``MTMathUILabel`` is a CoreText-backed view. When the latex
/// changes, the internal mathlist re-parses and the natural size
/// can shift dramatically (a ``\frac`` row is much taller than a
/// plain ``x^2`` baseline). SwiftUI caches our frame between
/// ``updateNSView`` calls, so we must publish the new size or the
/// glyph either clips or floats inside an oversize bounding box.
///
/// Error states: an unparseable LaTeX body falls back to rendering
/// the raw source in a monospaced ``Text``. Better than an empty
/// hole — gives the user a hint that the model emitted something
/// the renderer didn't understand.
struct MathView: View {
    let latex: String
    let displayMode: Bool

    @Environment(\.colorScheme) private var colorScheme

    /// #546: match the transcript's Dynamic-Type scaling. ``MarkdownUI``
    /// scales the surrounding prose by wrapping the ``.rapidChat`` theme's
    /// fixed root size in its own `@ScaledMetric(relativeTo: .body)`
    /// (`Markdown.swift` `ScaledFontSizeModifier`). Mirror that exact
    /// curve here so a rendered formula tracks the prose instead of
    /// staying pinned while the text around it grows. 15 matches the
    /// theme root (2026-07 typography sweep) — this literal moves in
    /// lockstep with `.rapidChat`'s `FontSize` and the streaming Text,
    /// or formulas render one size off from the prose around them.
    @ScaledMetric(relativeTo: .body) private var baseFontSize: CGFloat = 15

    var body: some View {
        // Probe-render once on the main thread to detect bodies
        // SwiftMath can't parse. Cheap: parse goes ``String`` →
        // ``MTMathList`` without doing any layout. If it fails,
        // surface the raw source.
        if Self.parses(latex: latex) {
            MathHost(
                latex: latex,
                displayMode: displayMode,
                colorScheme: colorScheme,
                baseFontSize: baseFontSize
            )
                .accessibilityLabel("Math: \(latex)")
        } else {
            Text(displayMode ? "$$\(latex)$$" : "$\(latex)$")
                .scaledSystemFont(14, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Unrenderable math: \(latex)")
        }
    }

    /// Static parse probe. ``MTMathListBuilder.build`` returns nil
    /// on parse failure and we don't need the result here.
    private static func parses(latex: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        return list != nil && error == nil
    }
}

private struct MathHost: NSViewRepresentable {
    let latex: String
    let displayMode: Bool
    let colorScheme: ColorScheme
    /// Dynamic-Type-scaled base point size, resolved by ``MathView``'s
    /// `@ScaledMetric` and threaded in so the label tracks the prose.
    let baseFontSize: CGFloat

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configure(label)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.latex = latex
        label.labelMode = displayMode ? .display : .text
        // Use the Dynamic-Type-scaled body point size so inline math
        // sits on the same baseline as surrounding ``MarkdownUI`` prose
        // AND grows with it (#546). Display math gets a small bump for
        // visual prominence, matching MathJax / KaTeX default conventions.
        let baseSize = baseFontSize
        label.fontSize = displayMode ? baseSize + 2 : baseSize
        label.textAlignment = displayMode ? .center : .left
        // Tint glyphs to match the current colour scheme so dark
        // mode doesn't render math as black-on-black.
        let glyphColor: NSColor = (colorScheme == .dark) ? .white : .black
        label.textColor = MTColor(cgColor: glyphColor.cgColor) ?? MTColor.black
        // Intrinsic-size recompute — see file header. SwiftMath's
        // ``MTMathUILabel`` overrides ``intrinsicContentSize`` so
        // ``invalidateIntrinsicContentSize`` is the right trigger;
        // there's no ``sizeToFit`` API to call on this NSView.
        label.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        // Codex r1 P1 (#131): on macOS, ``MTMathUILabel`` overrides
        // ``NSView.fittingSize``, NOT ``intrinsicContentSize`` — the
        // latter returns AppKit's no-intrinsic-metric sentinel and
        // SwiftUI lays the view out as zero-size, hiding every
        // rendered formula. ``fittingSize`` re-runs the underlying
        // ``_sizeThatFits`` math and returns the real glyph bounds.
        nsView.fittingSize
    }
}
