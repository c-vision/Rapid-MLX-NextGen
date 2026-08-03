import AppKit

/// Thin AppKit sink that speaks a string through VoiceOver.
///
/// Issue #478: macOS SwiftUI has no `.accessibilityLiveRegion`, so a
/// streaming reply is invisible to VoiceOver as it grows. The canonical
/// macOS path is an ``NSAccessibility/post(element:notification:userInfo:)``
/// ``announcementRequested`` — more reliable than SwiftUI's
/// ``AccessibilityNotification/Announcement``, which is frequently
/// dropped on macOS. ``AssistantStreamAnnouncer`` decides *what* to
/// speak (and throttles); this only posts it.
///
/// The whole thing is a no-op when the string is empty. Callers gate on
/// ``NSWorkspace/isVoiceOverEnabled`` so nothing is scanned or posted
/// when VoiceOver is off.
@MainActor
enum VoiceOverAnnouncer {
    /// Post ``text`` as a high-priority VoiceOver announcement. The
    /// element is the main window when one exists, falling back to the
    /// application object so the announcement still routes when no
    /// window is key (e.g. a background stream landing).
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let element: Any = NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
