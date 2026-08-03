import AppKit
import Foundation

/// Pure helper that clamps a window frame so it sits entirely inside
/// a screen's visible area.
///
/// Why: ``NSWindow.setFrameAutosaveName`` restores the last saved
/// frame on launch but does NOT re-snap that frame to the current
/// screen's bounds if the user's display setup has changed since
/// the save (external display detached, resolution change, dock
/// added). On a 1920x1080 logical screen, a frame saved on a wider
/// display can land with its right edge ~90 logical points past
/// the visible area — toolbar controls and resize handles become
/// unreachable, and ``cliclick``/``System Events`` callers can't
/// dispatch hits to the off-screen pixels.
///
/// The helper is pure (no AppKit state, no globals) so it can be
/// exercised in unit tests against synthetic ``NSRect`` inputs.
/// ``WindowAccessor``'s closure calls it with the live window frame
/// and ``window.screen?.visibleFrame`` (falling back to
/// ``NSScreen.main`` when the window hasn't been positioned yet).
enum WindowFrameClamp {
    /// Returns ``frame`` adjusted so it fits entirely inside
    /// ``visibleFrame``. Sliding wins over resizing when possible
    /// (the user's chosen size is more interesting than the exact
    /// origin); resizing only kicks in when ``frame`` is larger
    /// than ``visibleFrame``.
    static func clamp(frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        // Defensive: a zero-or-negative visible frame is meaningless
        // (no screen, or a stale cache from a hot-unplug). Return
        // the input untouched so the caller can keep the AppKit-
        // restored frame as-is.
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return frame
        }
        var clamped = frame
        clamped.size.width = min(clamped.size.width, visibleFrame.width)
        clamped.size.height = min(clamped.size.height, visibleFrame.height)
        if clamped.maxX > visibleFrame.maxX {
            clamped.origin.x = visibleFrame.maxX - clamped.size.width
        }
        if clamped.origin.x < visibleFrame.origin.x {
            clamped.origin.x = visibleFrame.origin.x
        }
        if clamped.maxY > visibleFrame.maxY {
            clamped.origin.y = visibleFrame.maxY - clamped.size.height
        }
        if clamped.origin.y < visibleFrame.origin.y {
            clamped.origin.y = visibleFrame.origin.y
        }
        return clamped
    }

    /// Minimum on-screen overlap (logical points) below which a window is
    /// "stranded" — too little of it is reachable to grab the title bar
    /// and drag it back. ~100 pt clears the traffic-light cluster plus a
    /// slice of draggable title bar; the #364 repro left only ~12 pt
    /// visible.
    static let strandedGraceMargin: CGFloat = 100

    /// ``true`` when so little of ``frame`` overlaps ``visibleFrame`` that
    /// the window is effectively unreachable (title bar can't be grabbed).
    ///
    /// Used to decide whether to RE-clamp on a *later* ``WindowAccessor``
    /// callback — the launch-time clamp runs only once (guarded on the
    /// autosave name), but AppKit re-positions the main window
    /// off-screen-right when the first-launch ``OnboardingTour`` sheet
    /// tears down (issue #364: X jumps to ~1908 on a 1920-wide display).
    /// The re-clamp must NOT fight a user who merely parked the window a
    /// little past an edge, so it fires only for a genuinely-stranded
    /// window: no overlap at all, or an on-screen sliver thinner than
    /// ``strandedGraceMargin`` on either axis.
    static func isStranded(frame: NSRect, in visibleFrame: NSRect) -> Bool {
        // No screen basis (hot-unplug / empty cache) → don't move it.
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return false
        }
        let overlap = frame.intersection(visibleFrame)
        if overlap.isNull || overlap.isEmpty {
            return true
        }
        // A window narrower/shorter than the margin can't require more
        // overlap than its own size, so clamp the threshold to the frame.
        return overlap.width < min(frame.width, strandedGraceMargin)
            || overlap.height < min(frame.height, strandedGraceMargin)
    }
}
