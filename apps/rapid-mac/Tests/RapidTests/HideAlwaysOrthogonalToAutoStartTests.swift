import Foundation
import Testing
@testable import Rapid

/// v0.8.2 dogfood finding #9 (LOW) — `01-launch-fuzz.md`:
/// in ``HideDockChoice.hideAlways`` mode the SwiftUI ``WindowGroup``
/// is still instantiated (``window count == 1, visible == false``),
/// so every ``.task`` modifier on ``ContentView`` fires on launch
/// — including the one that calls ``AutoStartDecision.decide`` and
/// (when the gate passes) spawns the rapid-mlx sidecar.
///
/// This is **intentional by product design** — Ollama / LM Studio
/// both warm up their server in menu-bar-only mode so Quick Ask
/// (⌥+Space) and tray-driven window opens land on a ready surface
/// — but users have surprised us before, so this suite pins the
/// orthogonality contract at the behavior level:
///
/// 1. ``AutoStartPreference`` (``userOptedIn``) is the user-facing
///    escape hatch. ``false`` beats every other gate, including the
///    would-pass case where all 3 conditions hold.
/// 2. The default stays ``true`` so existing users see the Ollama-
///    shape auto-start UX they already have.
/// 3. ``HideDockChoice`` and ``AutoStartPreference`` live in
///    distinct UserDefaults namespaces (``rapid.window.*`` vs
///    ``rapid.server.*``) so toggling one cannot mutate the other.
///
/// The companion doc comments on ``AutoStartDecision`` and the
/// ``RapidApp`` ``WindowGroup`` body site explain WHY the
/// orthogonality matters; this suite checks that the runtime
/// surface still honours the contract.
@MainActor
@Suite("Hide-always is orthogonal to auto-start (dogfood #9)")
struct HideAlwaysOrthogonalToAutoStartTests {

    /// The escape hatch a ``hideAlways`` user reaches for when they
    /// want zero background activity. ``userOptedIn: false`` short-
    /// circuits every other gate — even the "all 3 conditions hold"
    /// case where auto-start would otherwise fire ``.start(alias)``.
    @Test("userOptedIn=false suppresses auto-start even when every other gate would pass")
    func userOptOutBeatsEveryOtherGate() {
        let decision = AutoStartDecision.decide(
            lastServedAlias: "qwen3.5-4b-4bit",
            bundledFallbackAlias: "gemma3-1b-qat-4bit",
            binaryReachable: true,
            cachedAliases: ["qwen3.5-4b-4bit"],
            serverState: .idle,
            userOptedIn: false
        )
        #expect(decision == .skip(reason: .userOptedOut))
    }

    /// Default behavior is unchanged: a user who never visits
    /// Settings → Models keeps the v0.7.x auto-start UX (Ollama-
    /// shape). This is the contract that makes the orthogonality
    /// claim above safe — ``hideAlways`` users who DIDN'T opt out
    /// see the same auto-start as ``.regular`` users.
    @Test("default userOptedIn=true keeps auto-start firing (Ollama-shape default)")
    func defaultOptInPreservesAutoStart() {
        let decision = AutoStartDecision.decide(
            lastServedAlias: "qwen3.5-4b-4bit",
            bundledFallbackAlias: nil,
            binaryReachable: true,
            cachedAliases: ["qwen3.5-4b-4bit"],
            serverState: .idle
            // userOptedIn defaults to true
        )
        #expect(decision == .start(alias: "qwen3.5-4b-4bit"))
    }

    /// AutoStartPreference's documented default — flipping it would
    /// silently break the upgrade contract for every existing user.
    @Test("AutoStartPreference.defaultValue stays true (Ollama-shape default)")
    func autoStartPreferenceDefaultStaysTrue() {
        #expect(AutoStartPreference.defaultValue == true)
    }

    /// AutoStartPreference + HideDockChoice keys live in distinct
    /// UserDefaults namespaces — toggling one can't accidentally
    /// mutate the other. Pinning the literal keys means a future
    /// rename that collides surfaces here, not as a silent user
    /// regression.
    @Test("AutoStartPreference and HideDockChoice keys do not collide")
    func preferenceKeysDoNotCollide() {
        #expect(AutoStartPreference.storageKey == "rapid.server.auto_start_on_launch.v1")
        #expect(DockVisibilityPromptStore.choiceKey == "rapid.window.hideDockChoice")
        #expect(AutoStartPreference.storageKey != DockVisibilityPromptStore.choiceKey)
        // Prefix-distinct (``rapid.server.*`` vs ``rapid.window.*``)
        // so a future ``defaults delete`` scoped to either family
        // doesn't accidentally wipe the other.
        #expect(AutoStartPreference.storageKey.hasPrefix("rapid.server."))
        #expect(DockVisibilityPromptStore.choiceKey.hasPrefix("rapid.window."))
    }

    /// Round-trip the ``hideAlways`` choice through a real
    /// ``DockVisibilityPromptStore`` and confirm the persisted
    /// state is observable via the store's API — without it leaking
    /// into ``AutoStartPreference``'s namespace. Catches the
    /// "rename one key, accidentally alias the other" shape.
    @Test("hideAlways persistence does not bleed into AutoStartPreference's key")
    func hideAlwaysPersistsWithoutTouchingAutoStartKey() {
        let suiteName = "test.hide-always.orthogonal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DockVisibilityPromptStore(initial: .notAsked, defaults: defaults)
        store.record(userPickedYes: true, dontAskAgain: true)

        #expect(store.choice == .hideAlways)
        #expect(defaults.string(forKey: DockVisibilityPromptStore.choiceKey) == HideDockChoice.hideAlways.rawValue)
        // The auto-start key MUST remain untouched by the Dock-
        // visibility write — orthogonal namespaces, mechanical
        // proof.
        #expect(defaults.object(forKey: AutoStartPreference.storageKey) == nil)
    }
}
