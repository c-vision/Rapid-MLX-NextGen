import Foundation

/// Pure, side-effect-free core that decides *what* (if anything) to
/// speak to VoiceOver as an assistant reply streams in.
///
/// Issue #478: streaming replies are not a VoiceOver live region, so a
/// blind user activates Send and then gets no signal that the model
/// started, is streaming, or finished. macOS SwiftUI has no
/// ``accessibilityLiveRegion`` equivalent, so the fix is a throttled
/// stream of AppKit announcements. This type owns the *decision* half;
/// it is deliberately free of AppKit / SwiftUI so the throttling and
/// chunking logic is unit-testable in isolation. The AppKit posting
/// lives in ``VoiceOverAnnouncer`` and the wiring in ``ChatViewModel``.
///
/// Contract:
///   * ``firstTokenCue`` fires once, on the empty -> non-empty flip, so
///     the user learns the model began responding.
///   * ``onDelta`` emits ONLY the trailing un-announced sentence(s),
///     and only when a sentence terminator (``.`` ``!`` ``?`` or a
///     ``\n\n`` paragraph break) has landed past ``announcedOffset``
///     AND ``minInterval`` has elapsed since the last announcement.
///     This throttles per-token spam. VoiceOver already has the full
///     body navigable, so we never re-read the whole buffer — only the
///     new tail. Scanning starts at ``announcedOffset`` so the cost is
///     O(new text), never O(buffer).
///   * ``onTerminal`` fires exactly once with a short terminal cue
///     ("Response complete" / "Response stopped" / the error string) —
///     never the reply body.
struct AssistantStreamAnnouncer {
    /// Terminal disposition of the stream, decoupled from the app's
    /// ``ChatMessage.Status`` so the core stays model-agnostic.
    enum Terminal: Equatable {
        case complete
        case cancelled
        case failed
    }

    /// Count of characters already spoken via ``onDelta``. Scanning
    /// starts here so the per-delta cost is O(new text), never
    /// O(buffer).
    private(set) var announcedOffset: Int = 0
    /// Timestamp of the last ``onDelta`` announcement; nil until the
    /// first streamed chunk is spoken. Drives the ``minInterval``
    /// throttle.
    private(set) var lastAnnounceAt: Date?
    /// Minimum spacing between streamed-body announcements.
    let minInterval: TimeInterval

    private var firstTokenAnnounced = false
    private var terminalAnnounced = false

    init(minInterval: TimeInterval = 2.0) {
        self.minInterval = minInterval
    }

    /// Emit "Rapid is responding" exactly once, on the first delta that
    /// makes ``fullContent`` non-empty. Cheap (O(1)); safe to call on
    /// every content delta.
    mutating func firstTokenCue(fullContent: String) -> String? {
        guard !firstTokenAnnounced, !fullContent.isEmpty else { return nil }
        firstTokenAnnounced = true
        return "Rapid is responding"
    }

    /// Emit the trailing un-announced sentence(s) when a terminator has
    /// landed past ``announcedOffset`` AND ``minInterval`` has elapsed
    /// since the last spoken chunk. Returns nil (announces nothing)
    /// otherwise. Only ever returns NEW text — never the whole buffer.
    mutating func onDelta(fullContent: String, now: Date) -> String? {
        // Only look at the un-announced tail — O(delta), never
        // O(buffer). VoiceOver already has the full body navigable.
        guard fullContent.count > announcedOffset else { return nil }
        let start = fullContent.index(
            fullContent.startIndex,
            offsetBy: announcedOffset
        )
        let tail = fullContent[start...]
        // Speak whole sentences: advance to the LAST terminator in the
        // tail so we don't leave a half-sentence dangling.
        guard let boundary = Self.lastSentenceBoundary(in: tail) else {
            return nil
        }
        // Throttle BEFORE advancing the offset — a suppressed sentence
        // must stay un-announced so a later call can still speak it.
        if let last = lastAnnounceAt,
           now.timeIntervalSince(last) < minInterval {
            return nil
        }
        let chunk = tail[..<boundary]
        // Advance past the whole chunk (incl. any trailing terminator /
        // newlines) even if it trims to empty, so we never rescan it.
        announcedOffset += chunk.count
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lastAnnounceAt = now
        return trimmed
    }

    /// Emit a short terminal cue exactly once. A second call (any
    /// disposition) returns nil.
    mutating func onTerminal(_ terminal: Terminal, errorMessage: String?) -> String? {
        guard !terminalAnnounced else { return nil }
        terminalAnnounced = true
        switch terminal {
        case .complete:
            return "Response complete"
        case .cancelled:
            return "Response stopped"
        case .failed:
            if let msg = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !msg.isEmpty {
                return msg
            }
            return "Response failed"
        }
    }

    // MARK: - Boundary scan

    /// Index *just past* the last sentence terminator in ``text`` — a
    /// ``.`` ``!`` ``?`` OR a blank-line (``\n\n``) paragraph break.
    /// Returns nil when no terminator is present. O(text.count).
    private static func lastSentenceBoundary(in text: Substring) -> Substring.Index? {
        var result: Substring.Index?
        var previous: Character?
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            let next = text.index(after: idx)
            if ch == "." || ch == "!" || ch == "?" {
                result = next
            } else if ch == "\n", previous == "\n" {
                result = next
            }
            previous = ch
            idx = next
        }
        return result
    }
}
