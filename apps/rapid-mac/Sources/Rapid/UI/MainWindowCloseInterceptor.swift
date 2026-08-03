import AppKit
import Foundation

/// Intercepts the main window's close button click and routes through
/// the "Hide Dock icon?" prompt (rapid-desktop issue #260) before
/// SwiftUI tears the scene down.
///
/// SwiftUI's ``Window`` scene auto-creates an ``NSWindow`` and sets
/// SwiftUI's own delegate on it. We chain through: install ourselves
/// as the delegate, hold a weak reference to the previous delegate,
/// and forward every selector we don't claim. Only
/// ``windowShouldClose(_:)`` and ``windowWillClose(_:)`` get our own
/// behaviour:
///
///   * ``windowShouldClose`` — when the persisted choice says "hide",
///     we ``orderOut`` the window FIRST (so the Dock-icon-removing
///     animation doesn't run while the main window is still
///     onscreen) and THEN flip ``NSApp.setActivationPolicy(.accessory)``,
///     instead of letting SwiftUI destroy the scene. Otherwise the
///     next "Reopen Window" (Dock click in ``.regular`` mode,
///     menu-bar in ``.accessory`` mode) would have to re-instantiate
///     the whole view tree which is measurably slower (≈300 ms cold)
///     and loses transient state like the scroll offset.
///   * ``windowShouldClose`` returning ``false`` is what tells AppKit
///     "I handled this myself, don't close the window". The window
///     stays alive but hidden in ``.accessory`` mode; in ``.regular``
///     fall-through it returns ``true`` and SwiftUI closes normally.
///     If we observe ``.accessory`` already in effect on a normal
///     close, we restore ``.regular`` so a No-after-Yes-without-
///     DontAsk cycle doesn't leave the Dock icon stuck off (codex
///     r1 BLOCKING #1).
///   * Installation is driven by ``ContentView``'s ``WindowAccessor``
///     so the proxy attaches the moment the SwiftUI scene's
///     ``NSWindow`` materialises, and re-attaches if SwiftUI
///     destroys + rebuilds it across a normal close + reopen (codex
///     r1 BLOCKING #2 — see ``shouldReinstall``).
@MainActor
final class MainWindowCloseInterceptor: NSObject, NSWindowDelegate {
    /// The store driving the prompt + persistence.
    private let store: DockVisibilityPromptStore

    /// The window this interceptor is attached to. Weak so
    /// destroying the scene doesn't keep the interceptor alive
    /// indefinitely. Exposed so the install site can detect that the
    /// SwiftUI ``Window`` scene re-mounted a fresh ``NSWindow``
    /// (post-normal-close reopen) and re-attach the proxy.
    weak var attachedWindow: NSWindow?

    /// SwiftUI's own delegate. Held weakly so we don't extend its
    /// lifetime past SwiftUI's own retain. Forwarded for every
    /// selector we don't override.
    ///
    /// ``nonisolated(unsafe)`` because the Objective-C dispatch
    /// machinery on ``responds(to:)`` / ``forwardingTarget(for:)``
    /// is a hot path called by AppKit before it knows what isolation
    /// the receiver wants. AppKit only ever calls these on the main
    /// thread (where this whole class lives via ``@MainActor``), so
    /// the unsafe annotation is honest about who reads the slot
    /// (the main thread exclusively).
    private nonisolated(unsafe) weak var previousDelegate: NSWindowDelegate?

    init(window: NSWindow, store: DockVisibilityPromptStore) {
        self.store = store
        self.attachedWindow = window
        self.previousDelegate = window.delegate
        super.init()
        window.delegate = self
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Honour any chained delegate's veto first (e.g. an unsaved-
        // edits guard). Without this, our handler could swallow the
        // close while a downstream delegate had a perfectly good
        // reason to abort it.
        if let prev = previousDelegate,
           prev.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           prev.windowShouldClose?(sender) == false {
            return false
        }

        return handleCloseRequest(window: sender)
    }

    /// Resolved truth-table for the "should we hide or quit?" branch.
    /// Pure so it can be exercised by a future unit test without
    /// standing up an NSWindow.
    enum CloseAction: Equatable {
        /// User picked Yes (or persisted ``hideAlways``). Flip to
        /// ``.accessory`` and hide the window. ``windowShouldClose``
        /// returns ``false`` so SwiftUI keeps the scene mounted.
        case hideToAccessory
        /// User picked No (or persisted ``keepAlways``). Let SwiftUI
        /// close the window; ``applicationShouldTerminateAfterLastWindowClosed``
        /// keeps the app alive via MenuBarExtra.
        case closeNormally
    }

    static func resolve(
        shouldPrompt: Bool,
        promptOutcome: DockVisibilityPrompt.Outcome?,
        resolvedHideOnClose: Bool
    ) -> CloseAction {
        if shouldPrompt {
            // The caller already ran the modal; ``promptOutcome``
            // carries the user's pick.
            return (promptOutcome?.hideDockNow ?? false)
                ? .hideToAccessory
                : .closeNormally
        }
        return resolvedHideOnClose ? .hideToAccessory : .closeNormally
    }

    /// Codex r1 BLOCKING (#1) helper: decides whether
    /// ``handleCloseRequest`` needs to flip ``NSApp`` back to
    /// ``.regular`` on the close-normally branch. The bug it pins:
    /// the user picks Yes-without-DontAsk (``.askEveryTime``), the
    /// app hides to accessory, the user reopens via the menu bar
    /// and on the next close picks No. Without this fix-up the
    /// activation policy stays at ``.accessory`` forever, even
    /// though the user just told us not to hide.
    ///
    /// Pure so the contract can be pinned by a unit test without
    /// standing up an ``NSApp``.
    static func shouldRestoreRegularPolicyOnNormalClose(
        currentPolicy: NSApplication.ActivationPolicy
    ) -> Bool {
        currentPolicy == .accessory
    }

    /// Codex r1 BLOCKING (#2) helper: decides whether the call site
    /// (``ContentView``'s ``WindowAccessor``) should construct a
    /// fresh interceptor against ``newWindow``. Three cases:
    ///
    ///   * No interceptor yet (first launch) → install.
    ///   * Existing interceptor's ``attachedWindow`` is nil (the
    ///     SwiftUI scene's ``NSWindow`` was destroyed by a previous
    ///     normal-close) → install.
    ///   * Existing interceptor still attached to a different live
    ///     ``NSWindow`` than ``newWindow`` (scene re-mount across
    ///     identifiers) → install.
    ///   * Otherwise (same live window already proxied) → skip.
    ///
    /// Pure so the contract can be pinned by a unit test without
    /// standing up an ``NSWindow``.
    static func shouldReinstall(
        currentAttachedWindow: NSWindow?,
        newWindow: NSWindow
    ) -> Bool {
        currentAttachedWindow !== newWindow
    }

    private func handleCloseRequest(window: NSWindow) -> Bool {
        let outcome: DockVisibilityPrompt.Outcome?
        if store.shouldPromptOnClose {
            outcome = DockVisibilityPrompt.runModal(store: store)
        } else {
            outcome = nil
        }

        let action = Self.resolve(
            shouldPrompt: store.shouldPromptOnClose && outcome != nil,
            promptOutcome: outcome,
            resolvedHideOnClose: store.resolvedHideOnClose
        )

        switch action {
        case .hideToAccessory:
            // Codex r2 NIT: order matters. Drop the window from the
            // screen FIRST so the policy flip (which animates the
            // Dock icon out) doesn't briefly render alongside the
            // still-onscreen main window. Hide instead of close so
            // the SwiftUI scene stays mounted — the menu-bar "Open
            // Rapid-MLX Desktop" path then just orderFronts the
            // window again, avoiding a full scene rebuild (and a
            // ≈300 ms cold-mount delay).
            window.orderOut(nil)
            DockVisibilityPromptStore.applyHide(true)
            return false
        case .closeNormally:
            // Codex r1 BLOCKING (#1): if a previous close had picked
            // Yes without "Don't ask again" (``.askEveryTime``) we
            // flipped the activation policy to ``.accessory`` and
            // hid the window; the user reopened via menu-bar, and
            // is now closing again with No. The persisted state is
            // updated by ``record(...)`` but the activation policy
            // would stay at ``.accessory`` — the Dock icon would
            // never come back without a relaunch. Restore
            // ``.regular`` whenever we observe the process sitting
            // in ``.accessory`` despite the user choosing not to
            // hide on this close.
            //
            // Only call when we're actually at ``.accessory`` so a
            // normal close (already at ``.regular``) doesn't yank
            // focus back to us right before SwiftUI tears the scene
            // down. ``applyHide(false)`` activates the app — fine
            // for the accessory→regular recovery (the Dock icon
            // re-mounts under the cursor), wrong for the steady-
            // state regular close.
            if Self.shouldRestoreRegularPolicyOnNormalClose(
                currentPolicy: NSApp.activationPolicy()
            ) {
                DockVisibilityPromptStore.applyHide(false)
            }
            return true
        }
    }

    // MARK: - Delegate forwarding

    /// AppKit asks the delegate first whether it responds to a
    /// selector; if false, the system skips delegate calls entirely.
    /// We claim every selector our chained delegate handles plus our
    /// own ``windowShouldClose`` so AppKit always routes through us.
    ///
    /// ``responds(to:)`` is a nonisolated override but AppKit always
    /// invokes it on the main thread (the only thread the AppKit
    /// runloop dispatches windowed delegate callbacks on); the
    /// ``previousDelegate`` storage is ``nonisolated(unsafe)`` to
    /// match.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousDelegate?.responds(to: aSelector) ?? false
    }

    /// Forward to the chained delegate for every selector we don't
    /// implement ourselves. Without this, SwiftUI's own delegate
    /// machinery (frame autosave, key-window tracking, sheet
    /// presentation) breaks the moment we install our interceptor.
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let prev = previousDelegate, prev.responds(to: aSelector) {
            return prev
        }
        return nil
    }
}
