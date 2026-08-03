import Foundation
import SwiftUI
import MarkdownUI
import Testing
@testable import Rapid

/// #546 — Dynamic Type sweep.
///
/// `Font.system(size:)` is a fixed-pixel rail that ignores
/// `\.dynamicTypeSize` entirely, so any text pinned that way stays the
/// same size no matter how large a low-vision user sets their system
/// text — and ``rapidChatDynamicTypeClamp()`` is a no-op for those
/// callers (it only bounds env-driven fonts). PR #546 swept the
/// user-facing text-content sites to ``scaledSystemFont(_:relativeTo:…)``
/// (a `@ScaledMetric`-backed drop-in that keeps the exact point size at
/// the default text size while scaling with Dynamic Type) and made the
/// `.rapidChat` markdown theme size-parametrised so the whole chat
/// answer scales off one dynamic root.
///
/// These tests lock the sweep in three ways:
///   1. a source guard that fails if any text-content site in the
///      swept surfaces regresses back to a pinned numeric
///      `.font(.system(size:))`;
///   2. a build/type check that the ``scaledSystemFont`` helper exists
///      on `View` and applies to both `Text` and `TextField`;
///   3. a construction check that ``MarkdownUI.Theme.rapidChat(baseSize:)``
///      keeps its 13pt default and builds across the Dynamic-Type range.
@Suite("#546 — Dynamic Type scaled-font sweep")
struct DynamicTypeScaledFontTests {

    // MARK: - Helper existence / applicability

    /// The helper must exist as a `View` extension and type-check
    /// against `Text`. A refactor that dropped or renamed it would
    /// fail to build here — exactly the breakage we want surfaced.
    /// `View` is MainActor-isolated under Swift 6, so the call runs on
    /// the main actor.
    @Test("scaledSystemFont applies to Text and builds")
    @MainActor
    func helperAppliesToText() {
        let _ = Text("sample").scaledSystemFont(13)
        let _ = Text("sample").scaledSystemFont(11, relativeTo: .caption, design: .monospaced)
        let _ = Text("sample")
            .scaledSystemFont(25, relativeTo: .largeTitle, weight: .bold)
    }

    /// The QuickAsk composer applies the helper to a `TextField`, not a
    /// `Text` — pin that the modifier composes on any `View`, so the
    /// launcher's prompt field scales too.
    @Test("scaledSystemFont applies to TextField and builds")
    @MainActor
    func helperAppliesToTextField() {
        let _ = TextField("Ask…", text: .constant("")).scaledSystemFont(16)
    }

    // MARK: - Theme root stays fixed (MarkdownUI scales it)

    /// The `.rapidChat` markdown theme root is intentionally a FIXED
    /// 13pt `static let`. Dynamic Type for the chat body is handled by
    /// MarkdownUI itself, which wraps the theme's root `FontSize` in its
    /// own `@ScaledMetric(relativeTo: .body)` (`Markdown.swift`
    /// `ScaledFontSizeModifier`); every other size in the theme is
    /// `.em(...)` relative to that root, so the whole answer scales off
    /// MarkdownUI's single built-in pass. Feeding a second
    /// `@ScaledMetric` base in at the call site would double-scale the
    /// transcript (~13 × scale²) — this test pins that the theme stays a
    /// plain `static let` (i.e. it builds and is a value, not a
    /// size-parametrised function). A refactor that reintroduced a
    /// `rapidChat(baseSize:)` call site would reopen the double-scale
    /// bug; the source guard below backstops the call sites.
    @Test("rapidChat theme root stays a fixed static let")
    @MainActor
    func themeRootIsFixed() {
        let _ = MarkdownUI.Theme.rapidChat
    }

    /// Backstop for the double-scale regression: no chat surface may
    /// feed a scaled base into the theme via a `rapidChat(baseSize:)`
    /// call. Scan the two markdown-rendering surfaces for that shape.
    @Test("No markdown surface passes a scaled base into the theme")
    func noScaledBaseIntoTheme() throws {
        for rel in [
            "Sources/Rapid/UI/Markdown/LaTeXMarkdownView.swift",
            "Sources/Rapid/UI/PoppedConversationView.swift",
        ] {
            let url = Self.sourceRoot.appendingPathComponent(rel)
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !body.contains("rapidChat(baseSize:"),
                "\(rel) passes a scaled base into .rapidChat — MarkdownUI already scales the theme root, so this double-scales the transcript (~13 × scale²). Use the fixed .rapidChat theme."
            )
        }
    }

    // MARK: - Source guard: no pinned numeric system-font on text content

    /// Files intentionally kept on the fixed `.font(.system(size:))`
    /// rail, with the rationale documented at each site:
    ///
    ///   * ``SystemPills.swift`` / ``MemoryPill.swift`` — ambient
    ///     live-telemetry chips (CPU / GPU / RAM / tok-s) in the
    ///     fixed-height bottom status bar. Scaling them with Dynamic
    ///     Type would clip the bar without aiding a reading task; this
    ///     matches the platform convention for menu-bar telemetry
    ///     (Activity Monitor, iStat). This is chrome, not content.
    ///
    /// The ``Bootstrapper`` module is excluded wholesale (see the scan
    /// root): it renders the transient pre-launch splash / gate, shown
    /// for well under a second, with its own display typography — not a
    /// content-reading surface.
    private static let telemetryAllowlist: Set<String> = [
        "SystemPills.swift",
        "MemoryPill.swift",
    ]

    /// Scan every SwiftUI view file on the user-facing content surfaces
    /// (`Sources/Rapid/UI` + `Sources/Rapid/QuickAsk`, excluding the
    /// transient `Bootstrapper` module) and fail if any **text** site
    /// carries a pinned numeric `.font(.system(size: <literal>))`.
    ///
    /// A site is exempt when it is:
    ///   * an icon glyph — the nearest enclosing view expression is an
    ///     `Image(...)` (icons stay on the fixed rail on purpose);
    ///   * a variable-driven size — `.font(.system(size: someVar))`,
    ///     which is how the two `.monospacedDigit()` sites keep a local
    ///     `@ScaledMetric` (those can't route through the helper because
    ///     the digit variant is a Font-level modifier);
    ///   * inside a comment;
    ///   * in an allowlisted telemetry file (see ``telemetryAllowlist``).
    @Test("No pinned numeric system-font on text content across swept surfaces")
    func noPinnedSystemFontOnTextContent() throws {
        let root = Self.sourceRoot
        let scanDirs = [
            root.appendingPathComponent("Sources/Rapid/UI"),
            root.appendingPathComponent("Sources/Rapid/QuickAsk"),
        ]
        var offenders: [String] = []
        for dir in scanDirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if Self.telemetryAllowlist.contains(url.lastPathComponent) { continue }
                let body = try String(contentsOf: url, encoding: .utf8)
                let lines = body.components(separatedBy: "\n")
                for (i, rawLine) in lines.enumerated() {
                    guard let hit = Self.pinnedNumericSystemFont(in: rawLine) else { continue }
                    if Self.baseIsImage(lines: lines, at: i) { continue }
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(hit)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Pinned numeric .font(.system(size:)) found on non-icon text \
            content — this text is locked out of Dynamic Type. Route it \
            through .scaledSystemFont(...) instead (or, for fixed-height \
            footer telemetry, add the file to telemetryAllowlist with a \
            documented rationale). Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Sanity floor: the guard is only meaningful if the swept surfaces
    /// actually adopted the helper. Assert a representative set of swept
    /// files each call ``scaledSystemFont`` at least once, so a bad
    /// merge that reverted the sweep (leaving the guard trivially green
    /// because everything went back to icons/telemetry) trips here.
    @Test("Swept surfaces adopted scaledSystemFont")
    func sweptSurfacesAdoptedHelper() throws {
        let mustAdopt = [
            "Sources/Rapid/UI/ChatView.swift",
            "Sources/Rapid/UI/OnboardingComponents.swift",
            "Sources/Rapid/UI/QuickstartView.swift",
            "Sources/Rapid/UI/SettingsModelManagementPanel.swift",
            "Sources/Rapid/UI/ContentView.swift",
            "Sources/Rapid/UI/DownloadStrip.swift",
            "Sources/Rapid/QuickAsk/QuickAskView.swift",
        ]
        for rel in mustAdopt {
            let url = Self.sourceRoot.appendingPathComponent(rel)
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(
                body.contains(".scaledSystemFont("),
                "\(rel) must adopt .scaledSystemFont(...) — the #546 sweep looks reverted."
            )
        }
    }

    // MARK: - Guard self-tests (meta-pins)

    /// The detector must FLAG a pinned numeric literal and NOT flag the
    /// exempt shapes (variable size, icon base, comment). Without this
    /// the guard could silently rot into always-green.
    @Test("Guard meta-pin: detector classifies representative shapes correctly")
    func detectorClassifiesShapes() {
        // Numeric literal on a Text base → flagged.
        let textLines = ["Text(x)", "    .font(.system(size: 13))"]
        #expect(Self.pinnedNumericSystemFont(in: textLines[1]) != nil)
        #expect(!Self.baseIsImage(lines: textLines, at: 1))

        // Numeric literal on an Image base → exempt (icon).
        let iconLines = ["Image(systemName: \"gear\")", "    .font(.system(size: 13))"]
        #expect(Self.pinnedNumericSystemFont(in: iconLines[1]) != nil)
        #expect(Self.baseIsImage(lines: iconLines, at: 1))

        // Inline Image base on the same line → exempt.
        let inlineIcon = ["Image(systemName: \"x\").font(.system(size: 11))"]
        #expect(Self.pinnedNumericSystemFont(in: inlineIcon[0]) != nil)
        #expect(Self.baseIsImage(lines: inlineIcon, at: 0))

        // Variable-driven size (the @ScaledMetric monospacedDigit
        // sites) → NOT a pinned literal, so not detected at all.
        #expect(Self.pinnedNumericSystemFont(in: "    .font(.system(size: metricValueSize, weight: .semibold).monospacedDigit())") == nil)
        #expect(Self.pinnedNumericSystemFont(in: "        .font(.system(size: labelSize))") == nil)

        // The helper call is never a false positive.
        #expect(Self.pinnedNumericSystemFont(in: "    .scaledSystemFont(13)") == nil)

        // A doc-comment that spells out the pinned shape (as the
        // modifier files' usage examples do) is not a render site.
        #expect(Self.pinnedNumericSystemFont(in: "    /// replace `.font(.system(size: 13))` with …") == nil)

        // Chained modifier between base and font — walk-back finds Image.
        let chained = [
            "Image(systemName: \"tri\")",
            "    .foregroundStyle(.red)",
            "    .font(.system(size: 14, weight: .semibold))",
        ]
        #expect(Self.baseIsImage(lines: chained, at: 2))
    }

    // MARK: - Detector primitives (shared by guard + self-tests)

    /// Returns the matched snippet if `line` contains a pinned numeric
    /// `.font(.system(size: <literal>...))` — i.e. the argument right
    /// after `size:` is a digit or dot (a numeric literal), not an
    /// identifier. Returns nil for variable-driven sizes and for the
    /// `.scaledSystemFont(...)` helper.
    static func pinnedNumericSystemFont(in line: String) -> String? {
        // Skip comment lines — doc comments in the modifier files
        // literally spell out `.font(.system(size: 13))` in their
        // usage examples, and those aren't render sites.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { return nil }
        let marker = ".font(.system(size:"
        guard let r = line.range(of: marker) else { return nil }
        var idx = r.upperBound
        // Skip spaces after "size:".
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return nil }
        let c = line[idx]
        guard c.isNumber || c == "." else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Walk back from a `.font(...)` line through the modifier chain
    /// (lines whose trimmed form starts with `.`, plus blank lines) to
    /// the base view expression, and report whether that base is an
    /// `Image(...)`. Also handles the inline `Image(...).font(...)`
    /// shape on a single line.
    static func baseIsImage(lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if let fr = line.range(of: ".font(.system(size:"),
           line[line.startIndex..<fr.lowerBound].contains("Image(") {
            return true
        }
        var j = index - 1
        while j >= 0 {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { j -= 1; continue }
            if t.hasPrefix(".") { j -= 1; continue }
            return lines[j].contains("Image(")
        }
        return false
    }

    /// Repo root derived from `#filePath`, so the guard runs from any
    /// cwd (swift test, Xcode, CI).
    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
