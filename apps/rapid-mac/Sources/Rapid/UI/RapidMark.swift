import SwiftUI

/// The Rapid brand mark — three forward-leaning "speed streaks" that
/// echo the motion lines in the Rapid-MLX logo / GitHub banner.
///
/// This replaces the v0.4 ``CheetahMark`` running-cat silhouette. The
/// cat read as playful-but-geeky and, rendered as a white shape inside
/// a saturated blue disc, gave the app a mascot-y "hacker tool" feel
/// the v0.5 refresh is deliberately moving away from. The streaks are
/// calmer, abstract, and unmistakably say "fast" — the one word the
/// brand leads with.
///
/// Why a code-drawn ``Shape`` rather than an image asset:
///   * It's a single fillable path, so it renders correctly as a
///     monochrome *template* in the menu-bar tray (where a coloured
///     bitmap would look wrong) AND as a white knockout inside the
///     brand disc, from the same source.
///   * No bundle / asset-catalog plumbing, so the build stays green
///     with zero new resources.
///
/// When the real vector logo is available, drop it into the existing
/// ``Sources/Rapid/Resources/Assets.xcassets`` catalog and swap the
/// ``RapidMark()`` call sites for ``Image("RapidLogo")`` — see the
/// repo notes accompanying the v0.5 UI pass for the exact wiring.
///
/// Geometry: three horizontal capsule streaks stacked vertically and
/// staggered along x so the middle one trails furthest left and
/// reaches furthest right — the classic "whoosh" that reads as speed
/// even at 11 pt. Normalised (0…1) coordinates, top-left origin.
struct RapidMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        // (leftX, rightX, centerY) for each streak, normalised. The
        // middle streak is the longest and pushes furthest right to
        // anchor the motion; the outer two are shorter and inset so
        // the silhouette tapers like a speed trail.
        let streaks: [(CGFloat, CGFloat, CGFloat)] = [
            (0.34, 0.90, 0.24),
            (0.06, 0.98, 0.50),
            (0.40, 0.84, 0.76),
        ]
        // Streak thickness as a fraction of height. Capsule ends use
        // a corner radius of half the thickness so the bars read as
        // rounded strokes, not hard rectangles.
        let thickness = rect.height * 0.18
        let radius = thickness / 2

        for (leftX, rightX, centerY) in streaks {
            let x = rect.minX + leftX * rect.width
            let y = rect.minY + centerY * rect.height - thickness / 2
            let w = (rightX - leftX) * rect.width
            let bar = CGRect(x: x, y: y, width: w, height: thickness)
            p.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return p
    }
}
