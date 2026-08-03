import SwiftUI

/// Press-feedback button styles (#548 · §1 of the Apple fluid-interface audit).
///
/// §1 — "Respond on pointer-down." A `.plain` Button (or a bare
/// `.onTapGesture` view) gives ZERO visual acknowledgement while the pointer
/// is held: the control feels dead until its action completes. macOS's
/// `.borderless` / `.bordered` / `.borderedProminent` already supply a system
/// press highlight, so those are left alone — but every `.plain` CTA, chip,
/// card, and tap-row in the app had no press response at all.
///
/// These two styles add the canonical acknowledgement — a slight shrink plus a
/// small opacity dip the instant `configuration.isPressed` flips — driven by
/// the shared interruptible spring (``RapidMotion/quick``) so a
/// released-then-repressed tap blends instead of snapping.
///
/// Reduce Motion (§14): the *scale* is the vestibular part, so it is suppressed
/// under Reduce Motion; the opacity dip stays (it is a non-motion press cue),
/// and the spring collapses to an instant change via
/// ``RapidMotion/resolve(_:reduceMotion:)``.
struct PressableButtonStyle: ButtonStyle {
    /// Scale applied while pressed. Buttons and chips shrink a touch more than
    /// cards — the same ratio on a large surface reads as an oversized jump.
    var pressedScale: CGFloat = 0.97

    /// Opacity applied while pressed. Doubles as the Reduce-Motion press cue.
    var pressedOpacity: Double = 0.82

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(
            configuration: configuration,
            pressedScale: pressedScale,
            pressedOpacity: pressedOpacity
        )
    }

    /// A `ButtonStyle` can't read `@Environment` directly, so the press
    /// treatment lives in a real `View` that can consult Reduce Motion.
    private struct PressableLabel: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: PressableButtonStyle.Configuration
        let pressedScale: CGFloat
        let pressedOpacity: Double

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
                .opacity(configuration.isPressed ? pressedOpacity : 1.0)
                .animation(
                    RapidMotion.resolve(RapidMotion.quick, reduceMotion: reduceMotion),
                    value: configuration.isPressed
                )
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Standard press feedback for buttons, chips, and CTAs (§1).
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// Gentler press feedback for large selectable cards — the same shrink
    /// ratio on a big surface reads as an oversized jump, so cards depress
    /// less and dim less.
    static var pressableCard: PressableButtonStyle {
        PressableButtonStyle(pressedScale: 0.985, pressedOpacity: 0.94)
    }
}
