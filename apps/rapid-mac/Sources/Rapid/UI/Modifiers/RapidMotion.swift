import SwiftUI

/// Shared interruptible-motion vocabulary (#547 · §3/§4/§14 of the Apple
/// fluid-interface audit).
///
/// Two codebase-wide problems this consolidates:
///
///  1. **§3/§4 — interruptibility.** Every prior animation used a
///     fixed-duration easing curve (`.easeInOut` / `.easeOut` / …), which
///     cannot be grabbed and reversed mid-flight — the single most
///     important fluid-interface property. The constants below are springs
///     instead, critically damped (zero bounce; bounce is reserved for
///     momentum-driven gestures, which we don't have here).
///
///  2. **§14 — Reduce Motion.** `@Environment(\.accessibilityReduceMotion)`
///     was honored in exactly one view before this. Every helper here
///     collapses to an INSTANT (no-animation) state change when the user
///     has Reduce Motion on. A bare `Animation` constant can't read the
///     environment, so the reduce-motion decision lives in the view-level
///     ``View/rapidAnimation(_:value:)`` modifier and the ``resolve(_:reduceMotion:)``
///     seam for imperative `withAnimation` blocks — never in the constants.
enum RapidMotion {
    /// Standard selection / panel-switch / step-advance transition.
    static let standard: Animation = .snappy(duration: 0.28, extraBounce: 0)

    /// Quicker flip for small state changes (chips, badges, dot toggles).
    static let quick: Animation = .snappy(duration: 0.18, extraBounce: 0)

    /// Autoscroll / large repositions — a touch softer so an interrupting
    /// scroll gesture blends with it instead of fighting a hard easing
    /// curve (§3).
    static let scroll: Animation = .spring(duration: 0.32, bounce: 0)

    /// The slow "breathing" base curve for live-status dots. Callers wrap
    /// it in `.repeatForever` AND gate it on Reduce Motion — a perpetual
    /// loop is the canonical §14 vestibular offender, so it must be fully
    /// suppressed (not merely shortened) when Reduce Motion is on.
    static let breathe: Animation = .easeInOut(duration: 0.9)

    /// Reduce-Motion seam for imperative `withAnimation` blocks: the caller
    /// reads `@Environment(\.accessibilityReduceMotion)` (a free
    /// `withAnimation` can't) and passes it here. Returns `nil` under Reduce
    /// Motion so the state change lands instantly. Pure — unit-testable
    /// without standing up a view.
    static func resolve(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Whether a looping status dot should actively pulse: only when it has
    /// something to signal (`isAnimating`) AND Reduce Motion is off — a
    /// perpetual loop is fully suppressed, not merely shortened (§14).
    /// Callers drive their `pulse` @State off this from both `onAppear` and
    /// `onChange(of: reduceMotion)` so flipping the setting at runtime
    /// starts / stops the loop instead of freezing the dot mid-phase. Pure,
    /// so the start/stop contract is unit-testable without a view.
    static func shouldPulse(isAnimating: Bool, reduceMotion: Bool) -> Bool {
        isAnimating && !reduceMotion
    }
}

/// Reduce-Motion-aware `animation(_:value:)`.
private struct RapidAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(
            RapidMotion.resolve(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}

extension View {
    /// Animate changes to `value` with `animation`, but drop to an instant
    /// (no-animation) change when Reduce Motion is on (#547). Springs stay
    /// interruptible (§3); Reduce Motion falls back to a static swap (§14).
    func rapidAnimation<V: Equatable>(
        _ animation: Animation = RapidMotion.standard,
        value: V
    ) -> some View {
        modifier(RapidAnimationModifier(animation: animation, value: value))
    }
}
