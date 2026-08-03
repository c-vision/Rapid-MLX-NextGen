import AppKit
import SwiftUI

/// SwiftUI doesn't expose ``NSWindow.setFrameAutosaveName`` natively,
/// so we drop a hidden ``NSViewRepresentable`` into the view tree
/// that walks up to its hosting window and hands it to the caller.
///
/// Cost is zero: the wrapped view is a 1-point invisible ``NSView``
/// that doesn't intercept hit-testing or layout. The closure fires
/// once on the first ``updateNSView`` after the view is added to a
/// window (``view.window`` is nil during ``makeNSView`` because the
/// view hasn't been parented yet — common AppKit-in-SwiftUI gotcha).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Defer to the next runloop tick so the SwiftUI window is
        // fully realised before we touch it. Without the dispatch,
        // ``view.window`` can be ``nil`` on the first call in some
        // macOS 14/15 builds — race that the runtime smoothed over
        // sometime around 26.0 but we keep the safety net.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow(window)
        }
    }
}
