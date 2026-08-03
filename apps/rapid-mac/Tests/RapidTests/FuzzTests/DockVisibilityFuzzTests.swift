import AppKit
import Foundation
import Testing
@testable import Rapid

/// Adversarial input coverage for ``DockVisibilityPromptStore`` +
/// ``HideDockChoice`` (issue #260). State-machine total enumeration +
/// UserDefaults garbage handling. The state machine is small; the
/// invariant is "every input maps to a defined state" — we walk every
/// combination and assert the live function matches an independent
/// expected-output table. Disagreements get reported as bugs.
@MainActor
@Suite("DockVisibility — fuzz")
struct DockVisibilityFuzzTests {

    private func freshDefaults() -> UserDefaults {
        let name = "rapid-fuzz.dockvisibility.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Independent expected-output table. The agent's PR claims the
    /// transition is position-independent in ``current``; we encode
    /// the expected output as a function of (yes, dontAsk) only and
    /// then walk every (current, yes, dontAsk) triple to confirm.
    private func expectedNext(yes: Bool, dontAsk: Bool) -> HideDockChoice {
        switch (yes, dontAsk) {
        case (true, true): return .hideAlways
        case (true, false): return .askEveryTime
        case (false, true): return .keepAlways
        case (false, false): return .askEveryTime
        }
    }

    /// 4 states × 2 yes × 2 dontAsk = 16 combinations. Walk all of
    /// them. The function must be total: a missing transition would
    /// surface as a crash here.
    @Test("HideDockChoice.next: exhaustive 16-row truth table matches expected output")
    func nextExhaustiveTruthTable() {
        for current in HideDockChoice.allCases {
            for yes in [true, false] {
                for dontAsk in [true, false] {
                    let actual = HideDockChoice.next(
                        current: current,
                        userPickedYes: yes,
                        dontAskAgain: dontAsk
                    )
                    let expected = expectedNext(yes: yes, dontAsk: dontAsk)
                    #expect(
                        actual == expected,
                        "next(current=\(current), yes=\(yes), dontAsk=\(dontAsk)) = \(actual), expected \(expected)"
                    )
                }
            }
        }
    }

    /// 1000-iteration randomised drive of ``next`` through arbitrary
    /// input chains. Any panic / fatalError / out-of-range condition
    /// would surface here.
    @Test("HideDockChoice.next: 1000 random input chains never crash + always land in CaseIterable")
    func nextFuzzNeverCrashes() {
        let baseSeed: UInt64 = 0xD0CC_D0CC_D0CC_D0CC
        let valid = Set(HideDockChoice.allCases)
        for i in 0..<1000 {
            var rng = SplitMix64(seed: baseSeed &+ UInt64(i))
            // Random starting state from the case enum
            let allCases = HideDockChoice.allCases
            var current = allCases[Int(rng.next() % UInt64(allCases.count))]
            // 100 transitions per iteration
            for _ in 0..<100 {
                let yes = (rng.next() & 1) == 1
                let dontAsk = (rng.next() & 1) == 1
                current = HideDockChoice.next(
                    current: current,
                    userPickedYes: yes,
                    dontAskAgain: dontAsk
                )
                #expect(valid.contains(current))
            }
        }
    }

    // MARK: - UserDefaults garbage handling

    /// The store's convenience init reads a string from UserDefaults
    /// and falls back to ``.notAsked`` for ANY non-matching value.
    /// Pre-seed every realistic garbage shape and assert the init
    /// degrades gracefully.
    @Test("DockVisibilityPromptStore.init: every garbage UserDefaults value degrades to .notAsked")
    func initDegradesOnGarbage() {
        // String values that aren't valid raw values
        let stringGarbage: [String] = [
            "not-an-enum",
            "",
            " ",
            "notAsked\u{0000}",  // null byte
            "HIDEALWAYS",         // wrong case
            "/etc/passwd",
            "\u{202E}flipped",
            String(repeating: "x", count: 16384),
        ]
        for value in stringGarbage {
            let defaults = freshDefaults()
            defaults.set(value, forKey: DockVisibilityPromptStore.choiceKey)
            let store = DockVisibilityPromptStore(defaults: defaults)
            #expect(store.choice == .notAsked,
                    "garbage string value '\(value.prefix(64))' did not degrade to .notAsked")
        }
        // Non-string values stored at the key.
        let defaults = freshDefaults()
        defaults.set(42, forKey: DockVisibilityPromptStore.choiceKey)
        let storeInt = DockVisibilityPromptStore(defaults: defaults)
        #expect(storeInt.choice == .notAsked)

        let defaults2 = freshDefaults()
        defaults2.set(["a", "b"], forKey: DockVisibilityPromptStore.choiceKey)
        let storeArr = DockVisibilityPromptStore(defaults: defaults2)
        #expect(storeArr.choice == .notAsked)

        let defaults3 = freshDefaults()
        defaults3.set(true, forKey: DockVisibilityPromptStore.choiceKey)
        let storeBool = DockVisibilityPromptStore(defaults: defaults3)
        #expect(storeBool.choice == .notAsked)
    }

    /// Calling init() 100 times in a row produces the same .choice —
    /// the read path is idempotent.
    @Test("DockVisibilityPromptStore.init: 100 consecutive reads produce the same choice")
    func initIdempotent() {
        let defaults = freshDefaults()
        defaults.set(HideDockChoice.hideAlways.rawValue, forKey: DockVisibilityPromptStore.choiceKey)
        for _ in 0..<100 {
            let store = DockVisibilityPromptStore(defaults: defaults)
            #expect(store.choice == .hideAlways)
        }
    }

    /// 16-thread race on setHideOnClose. The final stored value must
    /// be one of {.hideAlways, .keepAlways} — never a torn / unknown
    /// rawValue. (``setHideOnClose`` is @MainActor so the writes
    /// serialize on the main queue; the test still exercises the path
    /// to catch a future relaxation of the actor isolation.)
    @Test("setHideOnClose: 16 concurrent writes produce a valid final state (no torn write)")
    func setHideOnCloseRaceIsSafe() async {
        // We can't run real "16 threads simultaneously" cross-actor —
        // the store is @MainActor and the writes serialize on main.
        // Instead we fire 16 tasks that all hop onto the main actor;
        // they interleave at the await boundary, exercising the same
        // happens-before contract.
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(defaults: defaults)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask { @MainActor in
                    store.setHideOnClose((i & 1) == 0)
                }
            }
        }
        // Final stored value must be one of the two valid choices.
        let raw = defaults.string(forKey: DockVisibilityPromptStore.choiceKey) ?? ""
        let parsed = HideDockChoice(rawValue: raw)
        #expect(parsed == .hideAlways || parsed == .keepAlways,
                "final stored value '\(raw)' is not a valid HideDockChoice")
    }

    /// Sanity: every persisted rawValue from a valid commit round-
    /// trips through the convenience init.
    @Test("DockVisibilityPromptStore: every valid HideDockChoice round-trips through UserDefaults")
    func everyChoiceRoundTrips() {
        for c in HideDockChoice.allCases {
            let defaults = freshDefaults()
            defaults.set(c.rawValue, forKey: DockVisibilityPromptStore.choiceKey)
            let store = DockVisibilityPromptStore(defaults: defaults)
            #expect(store.choice == c,
                    "round-trip drift: stored \(c.rawValue) -> loaded \(store.choice)")
        }
    }

    /// shouldPromptOnClose / resolvedHideOnClose pinned for every
    /// state — the truth table is small enough to enumerate.
    @Test("shouldPromptOnClose + resolvedHideOnClose truth table")
    func promptAndResolvedTruthTable() {
        let table: [(HideDockChoice, Bool, Bool)] = [
            (.notAsked, true, false),
            (.askEveryTime, true, false),
            (.hideAlways, false, true),
            (.keepAlways, false, false),
        ]
        for (state, expectPrompt, expectHide) in table {
            let store = DockVisibilityPromptStore(initial: state, defaults: freshDefaults())
            #expect(store.shouldPromptOnClose == expectPrompt,
                    "\(state): shouldPromptOnClose expected \(expectPrompt)")
            #expect(store.resolvedHideOnClose == expectHide,
                    "\(state): resolvedHideOnClose expected \(expectHide)")
        }
    }
}
