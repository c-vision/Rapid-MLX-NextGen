import Testing
@testable import Rapid

/// Pins the Settings → Keyboard cheatsheet so a silent regression
/// (a section accidentally emptied during a refactor, the ⌘L row
/// dropped while moving the focus-compose plumbing) fails CI.
@Suite struct KeyboardShortcutCheatsheetTests {
    @Test func catalog_has_all_three_sections() {
        let titles = SettingsView.keyboardCheatsheetSections.map(\.title)
        #expect(titles == ["Chat", "Sessions", "App"])
    }

    @Test func every_row_has_non_empty_chord_and_label() {
        for section in SettingsView.keyboardCheatsheetSections {
            #expect(!section.rows.isEmpty, "Section \(section.title) has no rows")
            for row in section.rows {
                #expect(!row.chord.isEmpty,
                        "Section \(section.title) has a row with empty chord")
                #expect(!row.label.isEmpty,
                        "Row \(row.chord) in \(section.title) has empty label")
            }
        }
    }

    @Test func chords_are_unique_across_all_sections() {
        let chords = SettingsView.keyboardCheatsheetSections.flatMap { $0.rows.map(\.chord) }
        #expect(chords.count == Set(chords).count,
                "Duplicate chord found across cheatsheet sections")
    }

    /// The P1 shortcuts the panel was added to surface (⌘L
    /// focus-compose, ⌘⇧R regenerate) must be present in the
    /// "Chat" section — they're the discoverability problem this
    /// panel solves. ⌘[ / ⌘] belong in "Sessions". A silent
    /// reshuffle (e.g. ⌘L moved into "App") fails CI.
    @Test func chat_shortcuts_pinned_to_chat_section() {
        let chat = SettingsView.keyboardCheatsheetSections.first(where: { $0.title == "Chat" })
        #expect(chat != nil, "Chat section missing")
        let chatChords = Set((chat?.rows ?? []).map(\.chord))
        #expect(chatChords.contains("⌘L"),
                "⌘L must live in the Chat section, not elsewhere")
        #expect(chatChords.contains("⌘⇧R"),
                "⌘⇧R must live in the Chat section, not elsewhere")
    }

    @Test func session_shortcuts_pinned_to_sessions_section() {
        let sessions = SettingsView.keyboardCheatsheetSections.first(where: { $0.title == "Sessions" })
        #expect(sessions != nil, "Sessions section missing")
        let chords = Set((sessions?.rows ?? []).map(\.chord))
        #expect(chords.contains("⌘["),
                "⌘[ must live in the Sessions section")
        #expect(chords.contains("⌘]"),
                "⌘] must live in the Sessions section")
    }

    /// Codex r1 BLOCKING-2: panel header claims "every chord
    /// wired" — verify the high-traffic chords that previously
    /// went undocumented (⌘1–⌘9, ⌘⇧O, ⌘⌥T) made it in.
    @Test func documents_recently_added_wired_chords() {
        let allChords = Set(
            SettingsView.keyboardCheatsheetSections.flatMap { $0.rows.map(\.chord) }
        )
        #expect(allChords.contains("⌘1 – ⌘9"),
                "⌘1–⌘9 (jump to session by ordinal) must appear")
        #expect(allChords.contains("⌘⇧O"),
                "⌘⇧O (open conversation in new window) must appear")
        #expect(allChords.contains("⌘⌥T"),
                "⌘⌥T (keep window on top) must appear")
    }

    /// v0.5.17: find-next / find-prev chords land in the Chat
    /// section, matching Safari / Chrome / Firefox / Xcode where
    /// ⌘G + ⇧⌘G are the universal "next match / previous match"
    /// bindings. If a future refactor moves these to "App" or
    /// drops them entirely, the panel falls silent again — fail
    /// loudly instead.
    @Test func find_next_prev_chords_pinned_to_chat_section() {
        let chat = SettingsView.keyboardCheatsheetSections.first(where: { $0.title == "Chat" })
        #expect(chat != nil, "Chat section missing")
        let chatChords = Set((chat?.rows ?? []).map(\.chord))
        #expect(chatChords.contains("⌘G"),
                "⌘G (next match) must live in the Chat section")
        #expect(chatChords.contains("⇧⌘G"),
                "⇧⌘G (previous match) must live in the Chat section")
        // ⌘F must remain alongside ⌘G/⇧⌘G — without the find bar
        // open, the navigation chords have nothing to act on, so
        // a panel that documented next/prev but not Find would
        // mislead users into thinking ⌘G works outside Find.
        #expect(chatChords.contains("⌘F"),
                "⌘F (find in chat) must accompany ⌘G/⇧⌘G")
    }
}
