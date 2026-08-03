import CoreGraphics
import Testing
@testable import Rapid

/// #459: regression guard for the main-window minimum-width floor.
///
/// The bug: clicking the green traffic-light button on a built-in
/// MacBook display puts the window into macOS full-screen *tiling*,
/// which snaps the window to exactly one half of the screen. The main
/// window scene is ``.windowResizability(.contentMinSize)`` (see
/// ``RapidApp``), so ``ContentView.minWindowWidth`` is the HARD
/// minimum the OS will allow — it cannot tile the window narrower than
/// that. With the old 880-pt floor, half of any display narrower than
/// 1760 pt (every built-in MacBook screen — half ≈ 640–860 pt) is less
/// than the floor, so the content overflows the tiled frame: the brand
/// header collapses, the chat transcript blanks, and the composer is
/// clipped off the right edge. Reported during v0.8.14 dogfood as
/// "green-button maximise → the whole layout breaks".
///
/// These are pure-constant checks (no SwiftUI hosting) for the same
/// reason as ``ContentViewTests`` — ``ContentView`` uses
/// Observation-framework ``@Environment`` injection that ViewInspector
/// can't introspect. The invariant we actually care about is numeric:
/// the floor must be small enough to fit a half-screen tile on the
/// smallest Mac display we support.
@Suite("ContentView window-size floor (#459)")
struct ContentViewLayoutTests {
    /// The narrowest built-in Mac display in logical points we still
    /// want green-button tiling to work on. A 13-inch MacBook at its
    /// "More Space" / native-ish scaling reports ~1280 pt wide; older
    /// 1280×800 panels report exactly 1280. Half of that is the tile
    /// width the OS hands us.
    private static let smallestSupportedDisplayWidth: CGFloat = 1280

    @Test("min window width fits a half-screen tile on the smallest supported display")
    func floorFitsHalfScreenTile() {
        let halfScreen = Self.smallestSupportedDisplayWidth / 2
        #expect(
            ContentView.minWindowWidth <= halfScreen,
            """
            ContentView.minWindowWidth (\(ContentView.minWindowWidth)) must be \
            <= half of the smallest supported display (\(halfScreen)) or \
            green-button full-screen tiling overflows the window on built-in \
            MacBook screens — the #459 layout collapse. Do not raise it back \
            toward 880.
            """
        )
    }

    @Test("min window width stays usable (sidebar ≥ 220 + a readable chat column)")
    func floorLeavesRoomForSidebarPlusChat() {
        // The sidebar column rest-min is 220 pt
        // (``.navigationSplitViewColumnWidth(min: 220, …)``). Whatever
        // the floor is, it must leave a non-trivial detail column or the
        // chat surface itself becomes the regression.
        let sidebarMin: CGFloat = 220
        let detailColumn = ContentView.minWindowWidth - sidebarMin
        #expect(
            detailColumn >= 380,
            "Detail column at the width floor is only \(detailColumn) pt — too cramped for the chat surface."
        )
    }

    @Test("min window height floor is unchanged and sane")
    func heightFloorSane() {
        #expect(ContentView.minWindowHeight == 560)
    }
}

/// #459 follow-up: regression guard for the composer-clip-on-inference
/// bug.
///
/// The bug: on macOS 14/15 a ``NavigationSplitView`` nested in a
/// ``VStack`` (with the status footer as a sibling row) proposes an
/// UNBOUNDED height to its detail content. The outer VStack clamps the
/// split's own frame, but inside, the detail column's flexible chat
/// ``ScrollView`` grows to its full transcript content height instead of
/// scrolling — pushing the compose bar far below the window's bottom
/// edge once the conversation exceeds the window height. macOS 26 bounds
/// the detail correctly, which is why it only reproduced on the user's
/// MacBook after inference produced a tall transcript. Reported during
/// v0.8.15 dogfood as "after you start inference the layout breaks — the
/// compose box disappears".
///
/// The fix has three load-bearing parts and NONE of them can be caught
/// by the snapshot suite (which renders on the CI macOS-26 host where
/// the detail is already bounded). This source-anchor guard is the only
/// realistic net, so it pins the wiring the way ``DynamicTypeClampTests``
/// pins the clamp call-sites:
///   1. ``ContentView`` measures the viewport the outer VStack hands the
///      split (``splitViewportHeight`` via a background ``GeometryReader``).
///   2. ``ContentView`` caps the detail column at that measured height so
///      the inner ScrollView scrolls instead of overflowing.
///   3. ``ChatView`` carries the compose bar + banners in a bottom
///      ``safeAreaInset`` on the transcript so they ride the scroll
///      viewport's bottom edge rather than a sibling row that the
///      overflowing transcript shoves off-screen.
@Suite("ContentView detail-height cap (#459 follow-up)")
struct ContentViewDetailHeightCapTests {
    static func source(_ relativePath: String) throws -> String {
        let root = try DynamicTypeClampTests.findPackageRoot()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("ContentView measures the split viewport via a GeometryReader")
    func measuresViewport() throws {
        let src = try Self.source("Sources/Rapid/UI/ContentView.swift")
        #expect(src.contains("splitViewportHeight"))
        #expect(src.contains("GeometryReader"))
        #expect(src.contains("proxy.size.height"))
    }

    @Test("ContentView caps the detail column at the measured viewport height")
    func capsDetailColumn() throws {
        let src = try Self.source("Sources/Rapid/UI/ContentView.swift")
        #expect(
            src.contains("maxHeight: splitViewportHeight"),
            "The detail column must cap its height at the measured viewport, or the macOS 14/15 unbounded-detail composer clip returns."
        )
    }

    @Test("ChatView anchors the compose bar in a bottom safeAreaInset")
    func composeBarInSafeAreaInset() throws {
        let src = try Self.source("Sources/Rapid/UI/ChatView.swift")
        #expect(
            src.contains(".safeAreaInset(edge: .bottom"),
            "The compose bar + banners must live in a bottom safeAreaInset on the transcript so they ride the scroll viewport, not a sibling row the overflow shoves off-screen."
        )
    }
}

/// Keeps the model controls in the otherwise-unused trailing titlebar space.
/// Reintroducing the picker as a detail-column child costs a permanent row of
/// chat height and duplicates the native toolbar controls.
@Suite("ContentView titlebar model controls")
struct ContentViewTitlebarControlsTests {
    @Test("model controls occupy the native titlebar primary-action area")
    func controlsUseTitlebar() throws {
        let src = try ContentViewDetailHeightCapTests.source(
            "Sources/Rapid/UI/ContentView.swift"
        )

        #expect(src.contains("ToolbarItem(placement: .primaryAction)"))
        #expect(src.contains("modelControlBar"))
        #expect(src.contains("titlebarStyle: true"))
        #expect(
            src.contains(".sharedBackgroundVisibility(.hidden)"),
            "macOS 26 must not draw a large white shared background behind the model controls."
        )
    }

    @Test("detail content does not render a second model-control row")
    func noDuplicateDetailRow() throws {
        let src = try ContentViewDetailHeightCapTests.source(
            "Sources/Rapid/UI/ContentView.swift"
        )
        let contentBeforeToolbar = src.components(separatedBy: ".toolbar {").first ?? src

        #expect(
            !contentBeforeToolbar.contains("ModelPickerBar("),
            "ModelPickerBar must stay out of the detail VStack; it belongs in the trailing native titlebar."
        )
    }
}
