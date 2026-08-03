import AppKit
import Foundation
import Testing
@testable import Rapid

/// rapid-desktop issue #260 — opt-in "hide Dock icon on first window
/// close" prompt. The store owns the persisted choice + the pure
/// ``HideDockChoice.next(...)`` transition table; these tests pin both
/// halves so a future refactor can't silently change the state
/// machine.
@MainActor
@Suite("DockVisibilityPromptStore — hide-Dock-on-close prompt (#260)")
struct DockVisibilityPromptStoreTests {
    private let suiteName = "rapid-tests.dockvisibility.\(UUID().uuidString)"

    private func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    // MARK: - Pure HideDockChoice.next transition table

    @Test("Yes + Don't ask again → .hideAlways")
    func yesAndDontAsk() {
        #expect(
            HideDockChoice.next(
                current: .notAsked,
                userPickedYes: true,
                dontAskAgain: true
            ) == .hideAlways
        )
    }

    @Test("Yes + keep asking → .askEveryTime (re-prompt next close)")
    func yesAndKeepAsking() {
        #expect(
            HideDockChoice.next(
                current: .notAsked,
                userPickedYes: true,
                dontAskAgain: false
            ) == .askEveryTime
        )
    }

    @Test("No + Don't ask again → .keepAlways")
    func noAndDontAsk() {
        #expect(
            HideDockChoice.next(
                current: .notAsked,
                userPickedYes: false,
                dontAskAgain: true
            ) == .keepAlways
        )
    }

    @Test("No + keep asking → .askEveryTime (re-prompt next close)")
    func noAndKeepAsking() {
        #expect(
            HideDockChoice.next(
                current: .notAsked,
                userPickedYes: false,
                dontAskAgain: false
            ) == .askEveryTime
        )
    }

    /// "Don't ask again" SHOULD overwrite a previous opposite-direction
    /// choice. If the user previously picked Yes + DontAsk and then
    /// (via Reset onboarding alerts) re-saw the prompt, picking No +
    /// DontAsk must land at ``.keepAlways`` — the transition is
    /// position-independent in ``current``.
    @Test("flip direction with Don't ask again: overrides previous choice")
    func flipDirectionWithDontAsk() {
        #expect(
            HideDockChoice.next(
                current: .hideAlways,
                userPickedYes: false,
                dontAskAgain: true
            ) == .keepAlways
        )
        #expect(
            HideDockChoice.next(
                current: .keepAlways,
                userPickedYes: true,
                dontAskAgain: true
            ) == .hideAlways
        )
    }

    // MARK: - shouldPromptOnClose truth table

    @Test("default install: shouldPromptOnClose == true")
    func defaultInstallPrompts() {
        let store = DockVisibilityPromptStore(
            initial: .notAsked,
            defaults: freshDefaults()
        )
        #expect(store.shouldPromptOnClose == true)
        #expect(store.resolvedHideOnClose == false)
    }

    @Test("askEveryTime: shouldPromptOnClose == true")
    func askEveryTimePrompts() {
        let store = DockVisibilityPromptStore(
            initial: .askEveryTime,
            defaults: freshDefaults()
        )
        #expect(store.shouldPromptOnClose == true)
        #expect(store.resolvedHideOnClose == false)
    }

    @Test("hideAlways: skips prompt + resolvedHideOnClose == true")
    func hideAlwaysSkipsPrompt() {
        let store = DockVisibilityPromptStore(
            initial: .hideAlways,
            defaults: freshDefaults()
        )
        #expect(store.shouldPromptOnClose == false)
        #expect(store.resolvedHideOnClose == true)
    }

    @Test("keepAlways: skips prompt + resolvedHideOnClose == false")
    func keepAlwaysSkipsPrompt() {
        let store = DockVisibilityPromptStore(
            initial: .keepAlways,
            defaults: freshDefaults()
        )
        #expect(store.shouldPromptOnClose == false)
        #expect(store.resolvedHideOnClose == false)
    }

    // MARK: - UserDefaults persistence

    @Test("record(Yes, DontAsk): persists .hideAlways to UserDefaults")
    func recordYesDontAskPersists() {
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(initial: .notAsked, defaults: defaults)
        store.record(userPickedYes: true, dontAskAgain: true)
        #expect(store.choice == .hideAlways)
        #expect(
            defaults.string(forKey: DockVisibilityPromptStore.choiceKey) == HideDockChoice.hideAlways.rawValue
        )
    }

    @Test("record(No, KeepAsking): persists .askEveryTime")
    func recordNoKeepAskingPersists() {
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(initial: .notAsked, defaults: defaults)
        store.record(userPickedYes: false, dontAskAgain: false)
        #expect(store.choice == .askEveryTime)
        #expect(
            defaults.string(forKey: DockVisibilityPromptStore.choiceKey) == HideDockChoice.askEveryTime.rawValue
        )
    }

    @Test("convenience init reads the persisted choice")
    func convenienceInitReadsPersisted() {
        let defaults = freshDefaults()
        defaults.set(HideDockChoice.hideAlways.rawValue, forKey: DockVisibilityPromptStore.choiceKey)
        let store = DockVisibilityPromptStore(defaults: defaults)
        #expect(store.choice == .hideAlways)
    }

    @Test("convenience init: missing key defaults to .notAsked")
    func convenienceInitDefaultsNotAsked() {
        let store = DockVisibilityPromptStore(defaults: freshDefaults())
        #expect(store.choice == .notAsked)
    }

    @Test("convenience init: unknown key value defaults to .notAsked")
    func convenienceInitUnknownDefaultsNotAsked() {
        let defaults = freshDefaults()
        // Simulate a future schema migration writing a value the
        // current build doesn't recognise — the store must fall back
        // to ``.notAsked`` instead of force-unwrapping nil.
        defaults.set("future-schema-v2-value", forKey: DockVisibilityPromptStore.choiceKey)
        let store = DockVisibilityPromptStore(defaults: defaults)
        #expect(store.choice == .notAsked)
    }

    @Test("setHideOnClose(true): persists .hideAlways without re-prompt")
    func setHideOnCloseTrue() {
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(initial: .notAsked, defaults: defaults)
        store.setHideOnClose(true)
        #expect(store.choice == .hideAlways)
        #expect(store.shouldPromptOnClose == false)
    }

    @Test("setHideOnClose(false): persists .keepAlways without re-prompt")
    func setHideOnCloseFalse() {
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(initial: .hideAlways, defaults: defaults)
        store.setHideOnClose(false)
        #expect(store.choice == .keepAlways)
        #expect(store.shouldPromptOnClose == false)
    }

    @Test("resetOnboarding(): brings the prompt back")
    func resetOnboardingBringsPromptBack() {
        let defaults = freshDefaults()
        let store = DockVisibilityPromptStore(initial: .hideAlways, defaults: defaults)
        #expect(store.shouldPromptOnClose == false)
        store.resetOnboarding()
        #expect(store.choice == .notAsked)
        #expect(store.shouldPromptOnClose == true)
        #expect(
            defaults.string(forKey: DockVisibilityPromptStore.choiceKey) == HideDockChoice.notAsked.rawValue
        )
    }

    // MARK: - MainWindowCloseInterceptor.resolve

    @Test("interceptor resolve: prompt-true + Yes → hideToAccessory")
    func interceptorPromptYesHides() {
        #expect(
            MainWindowCloseInterceptor.resolve(
                shouldPrompt: true,
                promptOutcome: DockVisibilityPrompt.Outcome(hideDockNow: true),
                resolvedHideOnClose: false
            ) == .hideToAccessory
        )
    }

    @Test("interceptor resolve: prompt-true + No → closeNormally")
    func interceptorPromptNoCloses() {
        #expect(
            MainWindowCloseInterceptor.resolve(
                shouldPrompt: true,
                promptOutcome: DockVisibilityPrompt.Outcome(hideDockNow: false),
                resolvedHideOnClose: false
            ) == .closeNormally
        )
    }

    @Test("interceptor resolve: prompt-false + hideAlways → hideToAccessory")
    func interceptorNoPromptHideAlways() {
        #expect(
            MainWindowCloseInterceptor.resolve(
                shouldPrompt: false,
                promptOutcome: nil,
                resolvedHideOnClose: true
            ) == .hideToAccessory
        )
    }

    @Test("interceptor resolve: prompt-false + keepAlways → closeNormally")
    func interceptorNoPromptKeepAlways() {
        #expect(
            MainWindowCloseInterceptor.resolve(
                shouldPrompt: false,
                promptOutcome: nil,
                resolvedHideOnClose: false
            ) == .closeNormally
        )
    }

    // MARK: - Codex r1 BLOCKING #1: post-normal-close policy fix-up

    @Test("normal close from .accessory: restores .regular (Dock icon comes back)")
    func normalCloseFromAccessoryRestoresRegular() {
        #expect(
            MainWindowCloseInterceptor.shouldRestoreRegularPolicyOnNormalClose(
                currentPolicy: .accessory
            ) == true
        )
    }

    @Test("normal close from .regular: leaves policy alone (no focus yank)")
    func normalCloseFromRegularLeavesPolicy() {
        #expect(
            MainWindowCloseInterceptor.shouldRestoreRegularPolicyOnNormalClose(
                currentPolicy: .regular
            ) == false
        )
    }

    @Test("normal close from .prohibited: leaves policy alone (not our state)")
    func normalCloseFromProhibitedLeavesPolicy() {
        #expect(
            MainWindowCloseInterceptor.shouldRestoreRegularPolicyOnNormalClose(
                currentPolicy: .prohibited
            ) == false
        )
    }

    // MARK: - Codex r1 BLOCKING #2: interceptor reinstall on scene re-mount

    @Test("install gate: no existing interceptor → reinstall")
    func reinstallWhenNoExistingInterceptor() {
        let window = NSWindow()
        #expect(
            MainWindowCloseInterceptor.shouldReinstall(
                currentAttachedWindow: nil,
                newWindow: window
            ) == true
        )
    }

    @Test("install gate: same live window → skip (idempotent appear)")
    func skipReinstallWhenSameWindow() {
        let window = NSWindow()
        #expect(
            MainWindowCloseInterceptor.shouldReinstall(
                currentAttachedWindow: window,
                newWindow: window
            ) == false
        )
    }

    @Test("install gate: SwiftUI scene re-mount (new NSWindow) → reinstall")
    func reinstallOnSwiftUISceneRemount() {
        let oldWindow = NSWindow()
        let newWindow = NSWindow()
        #expect(
            MainWindowCloseInterceptor.shouldReinstall(
                currentAttachedWindow: oldWindow,
                newWindow: newWindow
            ) == true
        )
    }
}
