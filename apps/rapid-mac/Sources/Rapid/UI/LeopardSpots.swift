import SwiftUI

/// A sparse scatter of small amber "leopard spots" — subtle brand
/// texture for welcome / setup surfaces. Deliberately low-opacity and
/// few, so it reads as a faint watermark, never a wallpaper, and never
/// sits over body text (callers place it in the background/margins).
/// Positions come from a fixed seed list (no RNG) so layout is stable.
struct LeopardSpots: View {
    /// Normalised (x, y, radius-as-fraction-of-min-dimension).
    private static let spots: [(CGFloat, CGFloat, CGFloat)] = [
        (0.07, 0.16, 0.030), (0.16, 0.40, 0.018), (0.10, 0.68, 0.022),
        (0.90, 0.22, 0.028), (0.94, 0.52, 0.018), (0.84, 0.78, 0.024),
        (0.50, 0.93, 0.016),
    ]
    var opacity: Double = 0.10

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = min(w, h)
            ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, s in
                Circle()
                    .fill(RapidTheme.amber)
                    .frame(width: s.2 * d, height: s.2 * d)
                    .position(x: s.0 * w, y: s.1 * h)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
