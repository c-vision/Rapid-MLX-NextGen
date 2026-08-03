import Carbon.HIToolbox
import Foundation
import Testing
@testable import Rapid

/// Contract for the user-rebindable Quick Ask chord persistence
/// layer (v0.5.0). Pins:
///
///   - First launch with no UserDefaults entry → chord is the
///     ⌥+Space default (so Quick Ask is wired out of the box).
///   - Mutating ``chord`` writes a self-describing JSON envelope
///     to ``rapid.quickask.v1.chord`` so a relaunch reloads the
///     same value.
///   - Setting ``chord = nil`` is the user's "disable global
///     hotkey" command. The envelope survives a relaunch as
///     ``{"chord":null}`` instead of falling back to the default
///     (the pre-envelope ``removeObject`` shape would have lost
///     the user's preference).
///   - ``resetToDefault()`` matches the inline ⌥+Space chord, not
///     a stale snapshot, so a future ``defaultChord`` bump
///     propagates without a per-config migration.
///   - ``install(handler:)`` is the one-time wire-up the App
///     hands a config on launch; subsequent chord mutations
///     re-register against the stored handler without the App
///     having to call install again.
@MainActor
@Suite("QuickAskConfig — v0.5.0 chord persistence")
struct QuickAskConfigTests {
    /// Wipe the live UserDefaults key so every test gets a clean
    /// slate. Same pattern OnboardingStateTests uses.
    private func freshDefaults() {
        UserDefaults.standard.removeObject(forKey: QuickAskConfig.storageKey)
    }

    // MARK: - Initial state

    @Test("Storage key uses the rapid.*.v1 versioned namespace")
    func storageKeyShape() {
        #expect(QuickAskConfig.storageKey == "rapid.quickask.v1.chord")
    }

    @Test("Fresh install — chord defaults to ⌥+Space")
    func firstLaunchDefault() {
        freshDefaults()
        let config = QuickAskConfig()
        #expect(config.chord == HotkeyChord.defaultChord)
        #expect(config.chord?.displayString == "⌥ Space")
    }

    // MARK: - Persistence round-trip

    @Test("Mutating chord persists and reloads on next instance")
    func chordPersists() {
        freshDefaults()
        let first = QuickAskConfig()
        let custom = HotkeyChord(
            keyCode: kVK_ANSI_K,
            modifiers: [.command, .option]
        )
        first.chord = custom

        let second = QuickAskConfig()
        #expect(second.chord == custom)
        #expect(second.chord?.displayString == "⌥⌘ K")
    }

    @Test("Disabled state (chord == nil) survives relaunch — does NOT silently fall back to default")
    func disabledStateSurvivesRelaunch() {
        // Regression guard. The pre-envelope persist scheme used
        // ``removeObject`` for nil chord, which made "user
        // disabled global hotkey" indistinguishable from "user
        // never opened Settings" — second launch would silently
        // re-arm the default. The envelope persists ``{"chord":null}``
        // explicitly so the user choice sticks.
        freshDefaults()
        let first = QuickAskConfig()
        first.chord = nil

        let second = QuickAskConfig()
        #expect(second.chord == nil)
    }

    // MARK: - resetToDefault

    @Test("resetToDefault() restores ⌥+Space from any prior state")
    func resetToDefaultFromCustom() {
        freshDefaults()
        let config = QuickAskConfig()
        config.chord = HotkeyChord(keyCode: kVK_ANSI_J, modifiers: [.control])
        config.resetToDefault()
        #expect(config.chord == HotkeyChord.defaultChord)
    }

    @Test("resetToDefault() works after the user disabled the hotkey")
    func resetToDefaultFromDisabled() {
        freshDefaults()
        let config = QuickAskConfig()
        config.chord = nil
        config.resetToDefault()
        #expect(config.chord == HotkeyChord.defaultChord)
    }

    // MARK: - install(handler:) wire-up

    @Test("install(handler:) stores the handler so future chord changes re-register without re-installation")
    func installStoresHandlerForLaterChordChanges() {
        // We can't easily inspect Carbon registration from here,
        // but we CAN observe that ``install`` doesn't crash and
        // that subsequent ``chord`` mutations don't require
        // re-passing the handler — they trigger ``apply()`` which
        // re-uses the stored handler.
        freshDefaults()
        let config = QuickAskConfig()
        var handlerCalls = 0
        config.install { handlerCalls += 1 }
        // Mutate chord — this should drive a re-registration but
        // NOT fire the handler (registration is async / chord-press
        // driven, not state-change driven).
        config.chord = HotkeyChord(keyCode: kVK_ANSI_J, modifiers: [.control])
        #expect(handlerCalls == 0)
        // ``lastInstallFailed`` is the only observable signal of
        // registration outcome in this code path. The default ⌥+J
        // chord on a clean session shouldn't be owned by anyone —
        // but Carbon may refuse if Spotlight or another app holds
        // it, in which case the flag flips. Either outcome is a
        // valid post-condition; we just want to confirm no crash.
        _ = config.lastInstallFailed
    }

    // MARK: - Codex r1 P2 (#25 follow-up): upgrade-path denylist surfacing

    @Test("Persisted denylisted chord surfaces .denylisted in lastValidationError at init")
    func upgradePathDenylistedChordSurfaces() throws {
        // Simulates the upgrade-from-old-build path: a user who set
        // Cmd+Space (or Cmd+,) on v0.5.0 — both legal then, both
        // denylisted now — relaunches into the new build. The init
        // path falls back to ⌥+Space, and the Settings inline row
        // needs to *explain* why; the property observer doesn't run
        // during init so the explainer was silent without this fix.
        freshDefaults()

        // Manually encode the persisted envelope so we don't depend
        // on PersistedConfig being public. Shape matches what
        // QuickAskConfig.persist() writes today.
        struct LegacyEnvelope: Codable { var chord: HotkeyChord? }
        let cmdSpace = HotkeyChord(keyCode: kVK_Space, modifiers: [.command])
        let envelope = LegacyEnvelope(chord: cmdSpace)
        let encoded = try JSONEncoder().encode(envelope)
        UserDefaults.standard.set(encoded, forKey: QuickAskConfig.storageKey)

        let config = QuickAskConfig()
        #expect(config.chord == HotkeyChord.defaultChord,
                "init must fall back to shipping default when persisted chord is denylisted")
        guard case let .denylisted(rejected) = config.lastValidationError else {
            Issue.record("expected .denylisted to be set at init; got \(String(describing: config.lastValidationError))")
            return
        }
        #expect(rejected == cmdSpace,
                "init must surface the OFFENDING chord so the UI quotes the right one")
    }

    @Test("Legal persisted chord does NOT spuriously trip lastValidationError at init")
    func upgradePathLegalChordStaysQuiet() throws {
        freshDefaults()
        struct LegacyEnvelope: Codable { var chord: HotkeyChord? }
        let legal = HotkeyChord(keyCode: kVK_ANSI_K, modifiers: [.command, .option])
        let envelope = LegacyEnvelope(chord: legal)
        let encoded = try JSONEncoder().encode(envelope)
        UserDefaults.standard.set(encoded, forKey: QuickAskConfig.storageKey)

        let config = QuickAskConfig()
        #expect(config.chord == legal)
        #expect(config.lastValidationError == nil,
                "init must NOT set a validation error when the persisted chord is legal")
    }
}
