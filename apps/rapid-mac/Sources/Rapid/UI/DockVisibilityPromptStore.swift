import AppKit
import Foundation
import Observation

/// Persists the user's answer to the "hide Dock icon when closing the
/// main window?" one-time prompt (issue #260) and drives the
/// ``NSApp`` activation-policy flip that hides / re-shows the Dock
/// icon.
///
/// Reference UX (Trend Micro Antivirus One): on the FIRST main-window
/// close, present an ``NSAlert``:
///
/// > **Would you like to hide the application icon from Dock?**
/// > The application will keep running in the background.
/// > [ ] Don't ask me again
/// > [ No ]   [ Yes ]
///
/// State machine (``HideDockChoice``):
///   * ``.notAsked`` — the default for new installs. The next close
///     triggers the alert.
///   * ``.askEveryTime`` — the user picked Yes/No but left "Don't ask
///     again" unchecked. The next close re-presents the alert.
///     (Same behaviour as ``.notAsked`` for prompt-this-time? — the
///     two states differ only in onboarding-reset semantics: a "Reset
///     onboarding alerts" affordance should land back at
///     ``.notAsked``.)
///   * ``.hideAlways`` — user picked Yes + "Don't ask again". Future
///     closes silently flip to ``.accessory`` (hidden Dock icon).
///   * ``.keepAlways`` — user picked No + "Don't ask again". Future
///     closes keep the current behaviour (the SwiftUI App still
///     returns ``false`` from
///     ``applicationShouldTerminateAfterLastWindowClosed`` so the app
///     stays alive via ``MenuBarExtra``; user re-summons via
///     menu-bar).
///
/// Persistence lives in UserDefaults under ``rapid.window.hideDockChoice``.
@MainActor
@Observable
final class DockVisibilityPromptStore {
    /// Current persisted choice, observable so the Settings → App
    /// toggle reflects external mutations and so the close handler
    /// can read the freshest value.
    private(set) var choice: HideDockChoice

    private let defaults: UserDefaults

    /// UserDefaults key. Namespaced consistently with
    /// ``rapid.install.*`` from ``InstallTracker``.
    static let choiceKey = "rapid.window.hideDockChoice"

    /// Production init — reads the stored choice (``.notAsked`` if
    /// unset).
    convenience init(defaults: UserDefaults = .standard) {
        let raw = defaults.string(forKey: Self.choiceKey)
        let initial = HideDockChoice(rawValue: raw ?? "") ?? .notAsked
        self.init(initial: initial, defaults: defaults)
    }

    /// Test seam — caller supplies the starting choice + a private
    /// UserDefaults suite so the persistence side-effects don't leak
    /// into the global default suite.
    init(initial: HideDockChoice, defaults: UserDefaults) {
        self.choice = initial
        self.defaults = defaults
    }

    /// Apply the persisted choice to ``NSApp``'s activation policy on
    /// the FIRST main-window close. Returns ``true`` when the alert
    /// should be presented (caller renders ``NSAlert``); returns
    /// ``false`` when the choice has already been committed and the
    /// caller should apply it directly via ``applyHide(_:)``.
    var shouldPromptOnClose: Bool {
        switch choice {
        case .notAsked, .askEveryTime:
            return true
        case .hideAlways, .keepAlways:
            return false
        }
    }

    /// Map the persisted choice to "should we hide the Dock icon on
    /// this close?". Only meaningful when ``shouldPromptOnClose`` is
    /// false; the caller short-circuits when the alert is up.
    var resolvedHideOnClose: Bool {
        choice == .hideAlways
    }

    /// User clicked Yes or No in the alert. Persists the resulting
    /// state-machine value. The activation-policy flip itself is
    /// owned by the caller (``MainWindowCloseInterceptor`` invokes
    /// ``applyHide`` after consulting the close action; the Settings
    /// toggle does the same on the panel side) so a future call site
    /// can opt out of the immediate flip — e.g. a future Cmd-W that
    /// wants to record the choice but defer the policy switch to a
    /// trailing animation.
    func record(userPickedYes: Bool, dontAskAgain: Bool) {
        let next = HideDockChoice.next(
            current: choice,
            userPickedYes: userPickedYes,
            dontAskAgain: dontAskAgain
        )
        commit(next)
    }

    /// Settings toggle path — user flipped "Hide Dock icon when
    /// closing window" in Settings → App. Treat as an explicit "Don't
    /// ask again" choice for the corresponding direction. A future
    /// reset can bring the prompt back via ``resetOnboarding()``.
    func setHideOnClose(_ hide: Bool) {
        commit(hide ? .hideAlways : .keepAlways)
    }

    /// Resets the choice back to ``.notAsked`` so the prompt fires
    /// again on the next close. Used by Settings → App "Reset
    /// onboarding alerts".
    func resetOnboarding() {
        commit(.notAsked)
    }

    /// Apply the Dock-icon visibility to the running ``NSApp``.
    /// Exposed as ``static`` + ``@MainActor`` so the call site can be
    /// the close-delegate path OR the Settings toggle path without
    /// indirecting through the store. When ``hide`` is true the app
    /// flips to ``.accessory`` (Dock icon disappears, menu-bar icon
    /// stays — same shape Ollama / Quick Ask launchers use). When
    /// false the app sits at ``.regular``; if it was previously
    /// hidden, this re-activates so the icon comes back without
    /// requiring the user to re-launch.
    @MainActor
    static func applyHide(_ hide: Bool) {
        if hide {
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Returning to .regular from .accessory needs an explicit
            // activate so the Dock icon re-mounts in the right Mission
            // Control space. AppKit silently drops the change without
            // it on some macOS 14/15 builds (the policy flips but the
            // Dock doesn't re-render until the next launch).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func commit(_ next: HideDockChoice) {
        choice = next
        defaults.set(next.rawValue, forKey: Self.choiceKey)
    }
}

/// Persisted state for the "hide Dock icon on close" prompt. Stored
/// as the raw string so a future schema migration can add a case
/// without breaking previously-installed builds.
enum HideDockChoice: String, Equatable, CaseIterable {
    /// New install — first close presents the alert.
    case notAsked

    /// User answered Yes or No but left "Don't ask again" unchecked.
    /// Treated identically to ``.notAsked`` by ``shouldPromptOnClose``
    /// — the alert re-presents on the next close. Stored as a
    /// distinct case so a future "Reset onboarding alerts" can
    /// distinguish "user never saw the alert" from "user answered but
    /// asked us to keep asking".
    case askEveryTime

    /// User answered Yes + "Don't ask again". Future closes silently
    /// flip Dock to hidden.
    case hideAlways

    /// User answered No + "Don't ask again". Future closes keep the
    /// current behaviour (window closes, menu-bar agent stays alive,
    /// Dock icon visible until the user quits via menu-bar).
    case keepAlways

    /// Pure state-machine transition. Driven by the alert's Yes/No
    /// button + "Don't ask again" checkbox. Exposed as ``static`` so
    /// a unit test can pin all 4 combinations without standing up an
    /// NSAlert. ``current`` is intentionally accepted but currently
    /// unused by the transition — kept in the signature so a future
    /// "remember the user's last answer until they restart" semantic
    /// can be slotted in without touching every call site.
    static func next(
        current: HideDockChoice,
        userPickedYes: Bool,
        dontAskAgain: Bool
    ) -> HideDockChoice {
        _ = current
        switch (userPickedYes, dontAskAgain) {
        case (true, true):
            return .hideAlways
        case (true, false):
            return .askEveryTime
        case (false, true):
            return .keepAlways
        case (false, false):
            return .askEveryTime
        }
    }
}
