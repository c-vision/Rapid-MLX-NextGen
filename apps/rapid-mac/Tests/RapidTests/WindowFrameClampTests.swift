import AppKit
import Testing
@testable import Rapid

/// Contract for ``WindowFrameClamp.clamp(frame:to:)``. The clamp
/// runs at launch right after ``setFrameAutosaveName`` so a frame
/// AppKit restored from a no-longer-attached display lands inside
/// the active screen instead of letting the right/bottom edge sit
/// past the visible bounds.
@Suite("WindowFrameClamp")
struct WindowFrameClampTests {
    @Test("Frame already inside visible area is returned unchanged")
    func unchangedWhenInside() {
        let visible = NSRect(x: 0, y: 25, width: 1920, height: 1055)
        let frame = NSRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(WindowFrameClamp.clamp(frame: frame, to: visible) == frame)
    }

    @Test("Right-edge overflow slides the frame left, preserves size")
    func slidesLeftOnRightOverflow() {
        // The reproducer: saved (612, 91) sz 1400x900 on 1920x1080
        // logical screen → right edge at 2012, off by 92 px.
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 612, y: 91, width: 1400, height: 900)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.size == frame.size)
        #expect(clamped.maxX == visible.maxX)
        #expect(clamped.origin.x == 520)
        #expect(clamped.origin.y == frame.origin.y)
    }

    @Test("Left-edge underflow slides the frame right")
    func slidesRightOnLeftUnderflow() {
        // Synthetic: a saved frame whose origin is negative because
        // it lived on a screen sitting to the left of the current
        // main display (multi-monitor → single-monitor).
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: -300, y: 100, width: 800, height: 600)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.origin.x == 0)
        #expect(clamped.size == frame.size)
    }

    @Test("Bottom-edge overflow slides the frame up")
    func slidesUpOnBottomOverflow() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 100, y: 600, width: 800, height: 600)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.maxY == visible.maxY)
        #expect(clamped.size == frame.size)
    }

    @Test("Frame wider than the screen shrinks horizontally")
    func shrinksWhenWiderThanScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0, width: 1600, height: 700)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.size.width == 1280)
        #expect(clamped.size.height == 700)
        #expect(clamped.origin.x == 0)
    }

    @Test("Frame taller than the screen shrinks vertically")
    func shrinksWhenTallerThanScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 800)
        let frame = NSRect(x: 100, y: 0, width: 1200, height: 1000)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.size.height == 800)
        #expect(clamped.size.width == 1200)
    }

    @Test("Combined right + bottom overflow adjusts both axes")
    func combinedOverflow() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 1500, y: 800, width: 800, height: 500)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.maxX == visible.maxX)
        #expect(clamped.maxY == visible.maxY)
        #expect(clamped.size == frame.size)
    }

    @Test("Visible area with non-zero origin (menu bar) is honored")
    func nonZeroVisibleOrigin() {
        // macOS reserves the top ~25 logical pts for the menu bar;
        // visibleFrame.origin.y is non-zero accordingly. A frame
        // whose top edge sits in the menu-bar region should slide
        // down so it doesn't get clipped under the bar.
        let visible = NSRect(x: 0, y: 25, width: 1920, height: 1055)
        let frame = NSRect(x: 100, y: 1060, width: 800, height: 500)
        let clamped = WindowFrameClamp.clamp(frame: frame, to: visible)
        #expect(clamped.maxY == visible.maxY)
        #expect(clamped.origin.y >= visible.origin.y)
    }

    @Test("Empty visible frame returns the input untouched")
    func emptyVisibleFrameNoops() {
        // No screen attached or stale cache from a hot-unplug —
        // we have no basis to clamp, so leave AppKit's restored
        // frame as-is rather than silently zeroing it out.
        let frame = NSRect(x: 612, y: 91, width: 1400, height: 900)
        #expect(WindowFrameClamp.clamp(frame: frame, to: .zero) == frame)
    }

    // MARK: - #364 isStranded predicate (re-clamp trigger after tour dismiss)

    @Test("The #364 reproducer (X=1908 on a 1920 display) is stranded")
    func reproducerIsStranded() {
        // Centered 1110-wide window jumps to X=1908 → only 12 pt visible
        // on the right edge, title bar unreachable.
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let jumped = NSRect(x: 1908, y: 100, width: 1110, height: 720)
        #expect(WindowFrameClamp.isStranded(frame: jumped, in: visible))
        // …and clamp brings it fully back on-screen.
        let clamped = WindowFrameClamp.clamp(frame: jumped, to: visible)
        #expect(clamped.maxX <= visible.maxX)
        #expect(clamped.origin.x >= visible.origin.x)
        #expect(!WindowFrameClamp.isStranded(frame: clamped, in: visible))
    }

    @Test("A fully on-screen window is not stranded")
    func onScreenNotStranded() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 400, y: 100, width: 1110, height: 720)
        #expect(!WindowFrameClamp.isStranded(frame: frame, in: visible))
    }

    @Test("A window merely parked partly past an edge is NOT stranded (don't fight the user)")
    func partlyPastEdgeNotStranded() {
        // User dragged so the right ~200 pt hangs off — still plenty of
        // title bar reachable, so we must leave it alone.
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 1720, y: 100, width: 400, height: 300) // 200 pt visible
        #expect(!WindowFrameClamp.isStranded(frame: frame, in: visible))
    }

    @Test("A window with under the grace margin visible on an axis is stranded")
    func thinSliverIsStranded() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // Only 40 pt of width overlaps (< 100 pt margin).
        let frame = NSRect(x: 1880, y: 100, width: 800, height: 300)
        #expect(WindowFrameClamp.isStranded(frame: frame, in: visible))
    }

    @Test("A window entirely off-screen (no overlap) is stranded")
    func noOverlapIsStranded() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 3000, y: 100, width: 800, height: 600)
        #expect(WindowFrameClamp.isStranded(frame: frame, in: visible))
    }

    @Test("An empty/absent visible frame is never treated as stranded")
    func emptyVisibleNotStranded() {
        // Mirrors clamp's hot-unplug guard: with no screen basis we must
        // not move the window (isStranded==false ⇒ the re-clamp no-ops).
        let frame = NSRect(x: 1908, y: 100, width: 1110, height: 720)
        #expect(!WindowFrameClamp.isStranded(frame: frame, in: .zero))
    }
}
