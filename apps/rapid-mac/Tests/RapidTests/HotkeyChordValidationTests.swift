import Carbon
import Foundation
import Testing
@testable import Rapid

/// Issue #25 (codex audit batch 7 F5+F6): defense-in-depth chord
/// validation at the model + persistence layer. The UI Picker is
/// enum-bound today so a user can't TYPE Cmd+Tab; the persistence
/// layer (UserDefaults / future chord-recorder) needs the gate.
@Suite("HotkeyChord validation (issue #25)")
struct HotkeyChordValidationTests {

    // MARK: - HotkeyChord.isAllowedAsQuickAskBinding

    @Test("shipping default ⌥+Space passes the gate")
    func defaultChordIsAllowed() {
        #expect(HotkeyChord.defaultChord.isAllowedAsQuickAskBinding)
    }

    @Test("all shipping QuickAskChordPreset values pass the gate")
    func everyShippingPresetIsAllowed() {
        for preset in QuickAskChordPreset.allCases {
            guard let chord = preset.chord else { continue }
            #expect(
                chord.isAllowedAsQuickAskBinding,
                "preset \(preset) chord \(chord.displayString) must not be denylisted — would break users who picked it"
            )
        }
    }

    @Test("Cmd+Tab is rejected (app switcher)")
    func cmdTabRejected() {
        let chord = HotkeyChord(keyCode: kVK_Tab, modifiers: [.command])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+Shift+Tab is rejected (reverse app switcher)")
    func cmdShiftTabRejected() {
        let chord = HotkeyChord(keyCode: kVK_Tab, modifiers: [.command, .shift])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+Q is rejected (quit)")
    func cmdQRejected() {
        let chord = HotkeyChord(keyCode: kVK_ANSI_Q, modifiers: [.command])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+W / Cmd+M / Cmd+H rejected (window mgmt + hide app)")
    func cmdWMHRejected() {
        for key in [kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_H] {
            let chord = HotkeyChord(keyCode: key, modifiers: [.command])
            #expect(!chord.isAllowedAsQuickAskBinding, "key \(key) must be denylisted")
        }
    }

    @Test("Cmd+Opt+Esc rejected (force-quit)")
    func forceQuitRejected() {
        let chord = HotkeyChord(keyCode: kVK_Escape, modifiers: [.command, .option])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+Space rejected (Spotlight)")
    func cmdSpaceRejected() {
        // Spotlight wins this chord at the system level.
        // ``RegisterEventHotKey`` would either silently no-op
        // (Spotlight already owns it) or, worse, steal Spotlight
        // from the user — both are worse than making them pick
        // again. Not a shipped preset, only reachable today via
        // a hand-edited UserDefaults entry.
        let chord = HotkeyChord(keyCode: kVK_Space, modifiers: [.command])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+Comma rejected (every Mac app's Preferences shortcut)")
    func cmdCommaRejected() {
        // Standard "Preferences…" shortcut every macOS app
        // implements. Globally registering it would shadow it
        // in every other app the user has open.
        let chord = HotkeyChord(keyCode: kVK_ANSI_Comma, modifiers: [.command])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    @Test("Cmd+Opt+Space stays ALLOWED (shipping commandOptionSpace preset must not regress)")
    func cmdOptSpaceStaysAllowed() {
        // Belt-and-suspenders against a future expansion of the
        // denylist that accidentally swallows the
        // ``QuickAskChordPreset.commandOptionSpace`` value. The
        // ``everyShippingPresetIsAllowed`` test above iterates
        // all presets; this explicit case pins the most-at-risk
        // one with a fixed key/modifier shape so a denylist
        // refactor that drifts can't silently break it.
        let chord = HotkeyChord(keyCode: kVK_Space, modifiers: [.command, .option])
        #expect(chord.isAllowedAsQuickAskBinding)
    }

    @Test("modifierless single key is rejected (F6 — bare letter would steal every press)")
    func modifierlessChordRejected() {
        let bare = HotkeyChord(keyCode: kVK_ANSI_A, modifiers: [])
        #expect(!bare.isAllowedAsQuickAskBinding)
    }

    @Test("modifierless Space is rejected")
    func modifierlessSpaceRejected() {
        let chord = HotkeyChord(keyCode: kVK_Space, modifiers: [])
        #expect(!chord.isAllowedAsQuickAskBinding)
    }

    // MARK: - QuickAskConfig setter integration

    @MainActor
    @Test("setter rejects a denylisted assignment, reverts to oldValue, sets lastValidationError")
    func setterRejectsDenylistedChord() {
        let config = QuickAskConfig()
        let before = config.chord
        let hostile = HotkeyChord(keyCode: kVK_Tab, modifiers: [.command])

        config.chord = hostile

        #expect(config.chord == before, "setter must revert to previous chord")
        guard case let .denylisted(rejected) = config.lastValidationError else {
            Issue.record("expected .denylisted error; got \(String(describing: config.lastValidationError))")
            return
        }
        #expect(rejected == hostile, "error must carry the offending chord so UI can quote it")
    }

    @MainActor
    @Test("setter clears lastValidationError on a subsequent valid assignment")
    func setterClearsErrorOnValidAssignment() {
        let config = QuickAskConfig()
        config.chord = HotkeyChord(keyCode: kVK_Tab, modifiers: [.command])
        #expect(config.lastValidationError != nil)

        let valid = HotkeyChord(keyCode: kVK_ANSI_K, modifiers: [.command, .option])
        config.chord = valid

        #expect(config.chord == valid)
        #expect(config.lastValidationError == nil)
    }

    @MainActor
    @Test("setter accepts nil (disable hotkey) without tripping validation")
    func setterAcceptsNilDisable() {
        let config = QuickAskConfig()
        config.chord = nil
        #expect(config.chord == nil)
        #expect(config.lastValidationError == nil)
    }

    // MARK: - Codex r1 P3: comma key gets a readable label

    @Test("Cmd+, displayString reads ⌘ , not ⌘ key 43")
    func cmdCommaDisplayString() {
        let chord = HotkeyChord(keyCode: kVK_ANSI_Comma, modifiers: [.command])
        // The exact glyph format is "⌘ ," (modifier U+2318 + space + ',')
        // — assert the readable suffix instead of the full string so a
        // future modifier-glyph reorder doesn't break the test.
        #expect(
            chord.displayString.hasSuffix(","),
            "Cmd+, displayString must end with ',' (got \(chord.displayString))"
        )
        #expect(
            !chord.displayString.contains("key "),
            "Cmd+, must not fall through to the 'key NN' fallback (got \(chord.displayString))"
        )
    }
}
