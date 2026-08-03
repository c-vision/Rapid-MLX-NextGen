import Foundation
import Testing
@testable import Rapid

/// Contract for the Cmd+/ shortcuts overlay catalog (v0.5.0). The
/// overlay is a user-facing discovery surface, so the catalog
/// shape is the contract — a regression that silently drops the
/// ⇧⌘C row or shows a stale chord means users can't find the
/// feature.
@MainActor
@Suite("QuickAskShortcuts — v0.5.0 overlay catalog")
struct QuickAskShortcutsTests {

    // MARK: - Dynamic chord row

    @Test("Global hotkey row reflects the user's current chord")
    func currentChordShown() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        let opener = shortcuts.first(where: { $0.description == "Open Quick Ask" })
        #expect(opener?.chord == "⌥ Space")
        #expect(opener?.category == .global)
    }

    @Test("Custom chord display string flows through to the catalog")
    func customChordFlows() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌘⌥ Space")
        let opener = shortcuts.first(where: { $0.description == "Open Quick Ask" })
        #expect(opener?.chord == "⌘⌥ Space")
    }

    @Test("Nil chord swaps the row to the disabled-state explanation")
    func nilChordShowsDisabledRow() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: nil)
        let opener = shortcuts.first(where: { $0.description == QuickAskShortcuts.openWhenDisabled })
        #expect(opener != nil)
        #expect(opener?.chord == "—")
        // The "Open Quick Ask" label MUST NOT also appear when
        // disabled — otherwise the overlay shows two contradictory
        // rows about the same feature.
        let plainOpener = shortcuts.first(where: { $0.description == "Open Quick Ask" })
        #expect(plainOpener == nil)
    }

    // MARK: - Static rows

    @Test("Catalog always includes the ⌘⌥K menubar fallback")
    func includesMenuBarFallback() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        #expect(shortcuts.contains(where: { $0.chord == "⌘⌥K" }))
    }

    @Test("Catalog includes the panel Esc / ⌘/ shortcuts")
    func includesPanelShortcuts() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        let panelEntries = shortcuts.filter { $0.category == .panel }
        let chords = panelEntries.map(\.chord)
        #expect(chords.contains("Esc"))
        #expect(chords.contains("⌘/"))
    }

    @Test("Catalog includes ⌘↩ send and ⇧⌘C copy")
    func includesChatShortcuts() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        let chatEntries = shortcuts.filter { $0.category == .chat }
        let chords = chatEntries.map(\.chord)
        #expect(chords.contains("⌘↩"))
        #expect(chords.contains("⇧⌘C"))
    }

    // MARK: - Grouping

    @Test("grouped() returns categories in canonical order")
    func groupedRespectsCategoryOrder() {
        let groups = QuickAskShortcuts.grouped(quickAskChord: "⌥ Space")
        let order = groups.map(\.0)
        #expect(order == [.global, .panel, .chat])
    }

    @Test("grouped() per-section entries match the unrouped catalog filtered by category")
    func groupedMatchesUngrouped() {
        let chord = "⌘⌥ Space"
        let flat = QuickAskShortcuts.all(quickAskChord: chord)
        let groups = QuickAskShortcuts.grouped(quickAskChord: chord)
        for (category, entries) in groups {
            let expected = flat.filter { $0.category == category }
            #expect(entries == expected)
        }
    }

    // MARK: - Stability

    @Test("Every shortcut has a unique id (drives ForEach in the overlay)")
    func uniqueIDs() {
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        let ids = Set(shortcuts.map(\.id))
        #expect(ids.count == shortcuts.count)
    }

    @Test("Catalog size matches the documented overlay row count (6 entries)")
    func expectedCount() {
        // 1 global chord + 1 menubar + 1 Esc + 1 ⌘/ + 1 ⌘↩ + 1 ⇧⌘C = 6
        let shortcuts = QuickAskShortcuts.all(quickAskChord: "⌥ Space")
        #expect(shortcuts.count == 6, "Catalog gained or lost a row — update OVERNIGHT_REPORT.md + the test if intentional")
    }

    // MARK: - Category metadata

    @Test("Every category has a non-empty display name")
    func categoriesHaveDisplayNames() {
        for category in QuickAskShortcut.Category.allCases {
            #expect(!category.displayName.isEmpty)
        }
    }
}
