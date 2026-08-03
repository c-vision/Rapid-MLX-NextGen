import Carbon.HIToolbox
import Foundation
import Testing
@testable import Rapid

/// Contract for the Settings → Quick Ask preset list (v0.5.0).
/// We can't drive the SwiftUI Picker from a headless test, but the
/// preset enum's identity / chord mapping / display labels are the
/// load-bearing pieces — they determine whether the Picker
/// round-trips faithfully against ``QuickAskConfig.chord``.
@MainActor
@Suite("QuickAskChordPreset — v0.5.0 Settings picker")
struct QuickAskChordPresetTests {

    @Test("All presets are addressable via stable rawValue ids")
    func presetIdsAreStable() {
        let ids = Set(QuickAskChordPreset.allCases.map(\.id))
        // Catch a future careless rename — the rawValue is what
        // SwiftUI uses to identify Picker rows AND what we'd
        // persist if we ever cached the last-picked preset.
        #expect(ids.count == QuickAskChordPreset.allCases.count)
        #expect(ids.contains("optionSpace"))
        #expect(ids.contains("commandOptionSpace"))
        #expect(ids.contains("controlSpace"))
        #expect(ids.contains("commandOptionK"))
        #expect(ids.contains("disabled"))
        #expect(ids.contains("custom"))
    }

    @Test("optionSpace preset is exactly HotkeyChord.defaultChord")
    func optionSpaceIsDefault() {
        #expect(QuickAskChordPreset.optionSpace.chord == HotkeyChord.defaultChord)
    }

    @Test("commandOptionSpace dodges Spotlight — explicit chord shape")
    func commandOptionSpaceShape() {
        let chord = QuickAskChordPreset.commandOptionSpace.chord
        #expect(chord?.keyCode == kVK_Space)
        #expect(chord?.modifiers == [.command, .option])
    }

    @Test("commandOptionK uses K, not Space")
    func commandOptionKShape() {
        let chord = QuickAskChordPreset.commandOptionK.chord
        #expect(chord?.keyCode == kVK_ANSI_K)
        #expect(chord?.modifiers == [.command, .option])
    }

    @Test(".disabled has nil chord (kills global hotkey)")
    func disabledHasNilChord() {
        #expect(QuickAskChordPreset.disabled.chord == nil)
    }

    @Test(".custom has nil chord (Picker treats as read-only)")
    func customHasNilChord() {
        #expect(QuickAskChordPreset.custom.chord == nil)
    }

    // MARK: - match(_:) reverse lookup

    @Test("match(nil) — user disabled the hotkey")
    func matchNilIsDisabled() {
        #expect(QuickAskChordPreset.match(nil) == .disabled)
    }

    @Test("match(.defaultChord) round-trips to optionSpace")
    func matchDefaultRoundTrips() {
        #expect(QuickAskChordPreset.match(HotkeyChord.defaultChord) == .optionSpace)
    }

    @Test("match(commandOptionSpace.chord) round-trips")
    func matchCommandOptionSpaceRoundTrips() {
        let preset = QuickAskChordPreset.commandOptionSpace
        #expect(QuickAskChordPreset.match(preset.chord) == preset)
    }

    @Test("match(commandOptionK.chord) round-trips")
    func matchCommandOptionKRoundTrips() {
        let preset = QuickAskChordPreset.commandOptionK
        #expect(QuickAskChordPreset.match(preset.chord) == preset)
    }

    @Test("match() of an unknown chord falls back to .custom")
    func matchUnknownChordIsCustom() {
        // ⇧ + Tab — not a chord we expose in the Picker today.
        let weird = HotkeyChord(keyCode: kVK_Tab, modifiers: [.shift])
        #expect(QuickAskChordPreset.match(weird) == .custom)
    }

    // MARK: - Display labels (UI contract)

    @Test("Default preset is labelled so the user can identify the shipping chord")
    func defaultPresetLabel() {
        // The "(default)" tag matters — a user opening Settings for
        // the first time needs to see which row is the shipping
        // value so they know what they're swapping away from.
        #expect(QuickAskChordPreset.optionSpace.displayLabel.contains("default"))
    }

    @Test("Every preset has a non-empty hint")
    func everyPresetHasAHint() {
        for preset in QuickAskChordPreset.allCases {
            #expect(!preset.hint.isEmpty, "Preset \(preset.id) has empty hint — UI caption row will collapse")
        }
    }
}
