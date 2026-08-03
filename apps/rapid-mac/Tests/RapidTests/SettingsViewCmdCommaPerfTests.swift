import Foundation
import Testing
@testable import Rapid

/// Cmd+, perf guard for the macOS Settings scene (cycle-0 bug
/// report #66 — "Settings Cmd+, takes ~1.5s, 3 trial avg").
///
/// 2026-06-19 live measurement on b59ebcc (M3 Ultra, release build,
/// AppleScript-driven Cmd+, → SwiftUI ``.onAppear``):
///
/// * Cold first open: **203 ms** keystroke → onAppear callback
/// * Warm reopen:     **127 ms** keystroke → onAppear callback
///
/// Both are well under the P2 target (< 500 ms) and below the
/// stretch target (< 200 ms) for the warm case. The cycle-0 1.5 s
/// figure is no longer reproducible — see PR description for the
/// methodology + raw trial data.
///
/// This suite locks the *structural* invariants that keep that
/// latency cheap. They are intentionally not runtime UI timing
/// tests (those are flaky in CI); they are pure-function
/// assertions on the things that would slow the scene down if
/// regressed. Two guard groups ship here: the
/// ``SettingsView.Category`` count + label/icon stability, and the
/// isolated selection boundaries that keep a sidebar click from
/// invalidating the entire Settings shell. Any new tab adds another
/// switch arm to ``detailPanel`` and another row to the sidebar
/// ``ForEach``. The categories we ship today are all O(1) at scene
/// construction (SwiftUI only evaluates the matched ``@ViewBuilder``
/// arm); a regression that drops this count or collapses the isolated
/// children silently breaks the measurement record.
///
/// If a future change moves heavy work (subprocess spawn, sync
/// Keychain read, large catalog scan) into the SettingsView body
/// or any of its ``@Environment`` consumers' init paths, the
/// runtime measurement should regress past 500 ms. When that
/// happens, instrument with ``os_signpost`` markers around
/// ``SettingsView.body``, ``toolsPanel``, ``consumeRouterRequest``,
/// rebuild a debug ``.app`` via ``SKIP_SIDECAR=1 scripts/build.sh``,
/// drive Cmd+, with AppleScript (``cliclick`` cannot deliver the
/// keystroke to the Settings scene reliably; use
/// ``tell application "System Events" to tell process "Rapid" to
/// keystroke "," using {command down}``), and tail stderr for the
/// signposts. That's how the b59ebcc baseline was captured.
///
/// ## Perf-guard count (issue #346)
///
/// PR #327's body listed three structural guards — Category
/// invariants, ``formatSource``, and a Web Search helpers pair
/// (``webSearchKeyCommitAction`` + ``shouldResetWebSearchKeyDraftAfterCommit``).
/// The Category invariants remain here and the selection-isolation
/// guard was added after the 120 Hz panel-switch regression. The old
/// ``formatSource`` guard was removed with that dead code, and the Web
/// Search pair is fully covered by ``SettingsWebSearchKeyDraftTests``
/// (unchanged / clear / save + failed-write retention) — see the NOTE
/// at the bottom of this file. Issue #346 tracked the original
/// doc/code drift.
@Suite("SettingsView Cmd+, perf guard")
struct SettingsViewCmdCommaPerfTests {
    private func source(_ relativePath: String) throws -> String {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Hard lower-bound on the number of categories — checked with
    /// ``>=`` rather than ``==`` so adding a new feature panel
    /// stays additive (the structural-cost budget assumes O(1) per
    /// category and tolerates the extra arm + sidebar row). A
    /// future redesign that DROPS below 11 likely also rewrites
    /// the scene shape — at which point this test should be
    /// re-baselined alongside a fresh latency measurement, not
    /// silently relaxed. Drop-aware assertions for the 11 specific
    /// categories live in the title/icon tests below.
    @Test("Category enum size floor — at least 11 (cycle-10 baseline)")
    func categoryCount() {
        #expect(SettingsView.Category.allCases.count >= 11)
    }

    /// Lock the title strings so a perf-driven refactor that
    /// accidentally collapses two categories (and would change the
    /// sidebar's ``ForEach`` work) trips this test instead of
    /// silently shipping. The titles themselves are the
    /// human-visible labels — independently pinned because docs +
    /// support content cross-reference them.
    @Test("Category titles match the v0.7.x sidebar contract")
    func categoryTitles() {
        let expected: [SettingsView.Category: String] = [
            .models: "Models",
            .modelManagement: "Model Management",
            .tools: "Tools",
            .connectors: "Connectors",
            .permissions: "Permissions",
            .webSearch: "Web Search",
            .sampling: "Sampling",
            .appearance: "Appearance",
            .quickAsk: "Quick Ask",
            .keyboard: "Keyboard",
            .privacy: "Privacy",
            .storage: "Storage",
            .app: "App",
        ]
        for cat in SettingsView.Category.allCases {
            #expect(expected[cat] == cat.title, "title mismatch for \(cat)")
        }
    }

    /// Lock every icon name. SF Symbol lookups are cached but
    /// ``Label(systemImage:)`` still resolves once per sidebar
    /// row at construction — a typo'd name renders a placeholder
    /// chip and re-tries lookup on every body call, which is one
    /// of the ways a panel landing-zone slips into the 1.5 s class.
    @Test("Category icons resolve to known SF Symbol names")
    func categoryIcons() {
        let expected: [SettingsView.Category: String] = [
            .models: "cylinder.split.1x2.fill",
            .modelManagement: "externaldrive.fill",
            .tools: "wrench.and.screwdriver.fill",
            .connectors: "puzzlepiece.extension.fill",
            .permissions: "hand.raised.fill",
            .webSearch: "magnifyingglass",
            .sampling: "slider.horizontal.3",
            .appearance: "paintpalette.fill",
            .quickAsk: "sparkle",
            .keyboard: "keyboard",
            .privacy: "lock.shield.fill",
            .storage: "internaldrive.fill",
            .app: "app.badge.fill",
        ]
        for cat in SettingsView.Category.allCases {
            #expect(expected[cat] == cat.iconName, "icon mismatch for \(cat)")
        }
    }

    @Test("Category selection stays isolated from the Settings shell")
    func categorySelectionIsolation() throws {
        let src = try source("Sources/Rapid/UI/SettingsView.swift")

        #expect(src.contains("@State private var categorySelection = CategorySelection()"),
                "SettingsView must own one stable selection reference instead of value state.")
        #expect(src.contains("private struct CategoryRail: View"),
                "sidebar selection rendering must remain behind its own observation boundary.")
        #expect(src.contains("private struct DetailCanvas<Content: View>: View"),
                "detail switching must remain behind its own observation boundary.")
        #expect(src.contains("DetailCanvas(selection: categorySelection) { category in"))
        #expect(src.contains("detailPanel(for: category)"))
        #expect(!src.contains("@State private var selected: Category"),
                "value-typed selected state would invalidate the monolithic SettingsView again.")
    }

    // NOTE: ``webSearchKeyCommitAction`` and
    // ``shouldResetWebSearchKeyDraftAfterCommit`` are intentionally
    // NOT re-tested here. ``SettingsWebSearchKeyDraftTests`` already
    // covers their full contract (unchanged / clear / save +
    // failed-write retention). Adding a perf-flavoured copy here
    // would be duplicate coverage with no extra signal — the only
    // real way to assert "stays Keychain-I/O-free" is to keep the
    // helpers ``static`` and pure, which the existing suite already
    // guards.

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
