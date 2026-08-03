import Foundation
import Observation

/// Deep-link channel into the Settings window.
///
/// macOS's ``@Environment(\.openSettings)`` action opens (or focuses)
/// the Settings scene but doesn't accept a category — call sites can
/// only say "open Settings," not "open Settings on the CLI panel."
/// Users (2026-06-10) called this out: clicking the bottom-bar CLI
/// status pill lands them on the default Tools tab and they have to
/// hunt for the rapid-mlx CLI sidebar item before they can recheck /
/// see the binary path.
///
/// ``SettingsRouter`` is a tiny ``@Observable`` shared via the SwiftUI
/// environment. A call site sets ``requestedCategory`` to the desired
/// tab and then invokes ``openSettings()``; ``SettingsView`` observes
/// the field via ``.onAppear`` (covers the "first open this session"
/// case) and ``.onChange`` (covers the "already-open Settings gets
/// re-focused" case), applies the request, and clears it back to nil
/// so a subsequent open without a request lands on the user's last
/// selected tab.
///
/// Why an ``@Observable`` instead of a stored property on
/// ``SettingsView``: SettingsView's ``@State`` lifetime is tied to
/// the Settings scene, which can be created/destroyed independently
/// of the main window. A router living on ``RapidApp`` survives both
/// and lets ``ContentView`` (or any other surface) hand off a target
/// before the Settings scene even exists.
@MainActor
@Observable
final class SettingsRouter {
    /// Pending deep-link target. Set by call sites just before
    /// ``openSettings()``; consumed and cleared by ``SettingsView``
    /// on appear / on change. Nil means "no override — land on the
    /// user's last selected tab."
    var requestedCategory: SettingsView.Category?
}
