import Carbon.HIToolbox
import Foundation
import Testing
@testable import Rapid

/// Contract for the Carbon-backed global hotkey wrapper introduced
/// in v0.5.0 (Quick Ask launcher). We can't exercise the actual
/// ``RegisterEventHotKey`` call from a unit test (it needs the
/// AppKit run loop and a real focused process), so this suite
/// pins the surrounding value-type behaviour: chord display
/// formatting, the Carbon-flag projection for ``RegisterEventHotKey``,
/// the default chord shape, and the key-name lookup table.
@MainActor
@Suite("GlobalHotkey — v0.5.0 launcher chord")
struct GlobalHotkeyTests {

    // MARK: - HotkeyChord defaults

    @Test("Default chord is ⌥+Space, matching ChatGPT Desktop")
    func defaultChordIsOptionSpace() {
        let chord = HotkeyChord.defaultChord
        #expect(chord.keyCode == kVK_Space)
        #expect(chord.modifiers == [.option])
        #expect(chord.displayString == "⌥ Space")
    }

    // MARK: - displayString formatting

    @Test("displayString renders modifiers in canonical order ⌃⌥⇧⌘")
    func displayStringModifierOrder() {
        // Hand-craft a chord with all four modifiers so we can pin
        // the visual order (matches macOS HIG: control, option,
        // shift, command).
        let chord = HotkeyChord(
            keyCode: kVK_Space,
            modifiers: [.shift, .command, .option, .control]
        )
        #expect(chord.displayString == "⌃⌥⇧⌘ Space")
    }

    @Test("displayString renders a single modifier without leading separator")
    func displayStringSingleModifier() {
        let cmd = HotkeyChord(keyCode: kVK_ANSI_K, modifiers: [.command])
        #expect(cmd.displayString == "⌘ K")
    }

    @Test("Bare keycode with no modifiers renders just the key")
    func displayStringNoModifiers() {
        let chord = HotkeyChord(keyCode: kVK_Escape, modifiers: [])
        #expect(chord.displayString == "Esc")
    }

    @Test("Unknown keycode falls back to numeric label")
    func displayStringUnknownKey() {
        // 0xFF is not in the lookup table — wrapper should still
        // produce a parseable string rather than crashing.
        let chord = HotkeyChord(keyCode: 0xFF, modifiers: [.command])
        #expect(chord.displayString == "⌘ key 255")
    }

    // MARK: - Carbon flag projection

    @Test("HotkeyModifiers.carbonFlags matches Carbon's bit layout")
    func carbonFlagsMatchCarbonConstants() {
        // These are the canonical Carbon bit positions —
        // ``RegisterEventHotKey`` reads them verbatim, so this is
        // the contract the wrapper has to satisfy.
        #expect(HotkeyModifiers([.command]).carbonFlags == 1 << 8)      // cmdKey
        #expect(HotkeyModifiers([.shift]).carbonFlags == 1 << 9)        // shiftKey
        #expect(HotkeyModifiers([.option]).carbonFlags == 1 << 11)      // optionKey
        #expect(HotkeyModifiers([.control]).carbonFlags == 1 << 12)     // controlKey
    }

    @Test("carbonFlags is OR of constituents — full set check")
    func carbonFlagsCombined() {
        let all: HotkeyModifiers = [.command, .shift, .option, .control]
        let expected = (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12)
        #expect(all.carbonFlags == expected)
    }

    @Test("Empty modifier set produces zero carbon flags")
    func carbonFlagsEmpty() {
        #expect(HotkeyModifiers([]).carbonFlags == 0)
    }

    // MARK: - Codable round-trip (chord persistence)

    // MARK: - EventHotKeyID signature pin

    /// README "Quick Ask" section "audit batch 7" promises
    /// "Carbon ``RegisterEventHotKey`` with explicit ``EventHotKeyID``
    /// verification". The verification at GlobalHotkey.swift
    /// (``handleCarbonEvent``) compares the live Carbon event's
    /// ``EventHotKeyID`` against ``GlobalHotkey.signature`` and id
    /// ``1``. The two constants are coupled — if a refactor changes
    /// either side in isolation, ``RegisterEventHotKey`` registers
    /// with one signature but ``handleCarbonEvent`` filters on a
    /// different one, and the hot-key silently never fires.
    ///
    /// We pin the signature constant explicitly to the documented
    /// "RAPD" 4-byte packed UInt32. The signature appears as a
    /// human-readable tag in Carbon event traces, so the value is
    /// also documentation: a debugger inspecting the event sees
    /// "RAPD" and knows our handler is the one firing.
    @Test("GlobalHotkey.signature is the 'RAPD' 4-byte packed constant")
    func signatureIsRAPD() {
        // Computed exactly the way the source builds it: pack the
        // ASCII bytes for "RAPD" into a big-endian UInt32.
        let expected: UInt32 = (UInt32(0x52) << 24)
            | (UInt32(0x41) << 16)
            | (UInt32(0x50) << 8)
            |  UInt32(0x44)
        #expect(GlobalHotkey.signature == expected)
        #expect(GlobalHotkey.signature == 0x5241_5044)
    }

    /// Pins the predicate ``handleCarbonEvent`` uses to decide
    /// whether an incoming Carbon ``EventHotKeyID`` is ours. This is
    /// the README "explicit ``EventHotKeyID`` verification" half of
    /// the audit batch 7 claim. The previous coverage only pinned
    /// ``GlobalHotkey.signature``'s value — a refactor that left the
    /// signature constant intact but dropped the predicate's
    /// signature/id check (or matched the wrong id) would slip past
    /// the prior tests but flip this one red.
    @Test("isOurHotkey accepts an EventHotKeyID matching the registered tuple")
    func acceptsRegisteredHotkey() {
        let theirs = EventHotKeyID(
            signature: GlobalHotkey.signature,
            id: GlobalHotkey.registeredID
        )
        #expect(GlobalHotkey.isOurHotkey(theirs))
    }

    /// Negative half of the verification contract: a sibling app or
    /// in-process component installing a separate Carbon hot-key
    /// against the same application target must NOT pass our
    /// predicate. Sweep three concrete mismatch shapes: different
    /// signature, different id, both different. If any of these
    /// returns true, the audit-batch-7 F10 fix has regressed and
    /// foreign hot-keys can re-fire ``GlobalHotkey.shared.fire``.
    @Test("isOurHotkey rejects every foreign signature/id combination")
    func rejectsForeignHotkey() {
        let foreignSig: UInt32 = 0xDEAD_BEEF
        let foreignID: UInt32 = 42

        #expect(!GlobalHotkey.isOurHotkey(EventHotKeyID(
            signature: foreignSig,
            id: GlobalHotkey.registeredID
        )))
        #expect(!GlobalHotkey.isOurHotkey(EventHotKeyID(
            signature: GlobalHotkey.signature,
            id: foreignID
        )))
        #expect(!GlobalHotkey.isOurHotkey(EventHotKeyID(
            signature: foreignSig,
            id: foreignID
        )))
        // Zero-initialised EventHotKeyID (the shape a fresh-decoded
        // event takes before GetEventParameter populates it on a
        // failed read) must also reject — defence against a status
        // check that gets removed elsewhere.
        #expect(!GlobalHotkey.isOurHotkey(EventHotKeyID(signature: 0, id: 0)))
    }

    /// Pin the AND-chain inside ``handleCarbonEvent`` end-to-end via
    /// the ``shouldFire(status:hotkeyID:)`` seam that the live code
    /// path delegates to. The previous ``isOurHotkey`` tests only
    /// pinned half the chain — they couldn't catch a regression that
    /// dropped the ``status == noErr`` half (firing on a failed
    /// ``GetEventParameter`` would mean we'd act on uninitialised
    /// ``EventHotKeyID`` bytes that happened to match our tuple). The
    /// shouldFire seam lifts the whole conjunction the runtime
    /// evaluates so this whole class of regression now goes red.
    @Test("shouldFire fires only when both status is noErr AND the hotkey is ours")
    func shouldFireCoversFullANDChain() {
        let ours = EventHotKeyID(
            signature: GlobalHotkey.signature,
            id: GlobalHotkey.registeredID
        )
        let foreign = EventHotKeyID(signature: 0xDEAD_BEEF, id: 42)

        // Happy path: real Carbon hot-key event matching our tuple.
        #expect(GlobalHotkey.shouldFire(status: noErr, hotkeyID: ours))

        // GetEventParameter failed (status != noErr). Even if the
        // tuple bytes coincidentally match ours (e.g. test-init,
        // stack residue), the decoder didn't actually populate the
        // EventHotKeyID and we MUST not fire on those bytes.
        let bogusStatus: OSStatus = -50 // paramErr
        #expect(!GlobalHotkey.shouldFire(status: bogusStatus, hotkeyID: ours))

        // Status ok but tuple foreign — already covered by
        // isOurHotkey, but include here so the AND-chain pin is
        // self-contained without depending on the predicate suite.
        #expect(!GlobalHotkey.shouldFire(status: noErr, hotkeyID: foreign))

        // Both wrong — the trivial reject.
        #expect(!GlobalHotkey.shouldFire(status: bogusStatus, hotkeyID: foreign))
    }

    @Test("HotkeyChord survives a JSON round trip — Settings persistence")
    func chordCodableRoundTrip() throws {
        let original = HotkeyChord(
            keyCode: kVK_ANSI_K,
            modifiers: [.command, .option]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyChord.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.displayString == "⌥⌘ K")
    }
}
