import Foundation
import Testing

@testable import Rapid

/// Contract for issue #478's ``AssistantStreamAnnouncer`` — the pure,
/// throttled decision core behind the streaming VoiceOver live region.
/// Pins the sentence/interval throttle, the "only new text" chunking,
/// and the one-shot start / terminal cues so a refactor can't quietly
/// reintroduce per-token spam or re-read the whole reply on finalize.
@Suite("AssistantStreamAnnouncer — throttled live-region core")
struct AssistantStreamAnnouncerTests {

    // MARK: - onDelta: terminator gate

    @Test("No announcement until a sentence terminator lands past announcedOffset")
    func noAnnouncementWithoutTerminator() {
        var a = AssistantStreamAnnouncer(minInterval: 2)
        let t0 = Date()
        // No terminator yet → nothing spoken, offset unmoved.
        #expect(a.onDelta(fullContent: "Hello world", now: t0) == nil)
        #expect(a.announcedOffset == 0)
        // Terminator lands → the sentence is announced.
        #expect(a.onDelta(fullContent: "Hello world.", now: t0) == "Hello world.")
        #expect(a.announcedOffset == 12)
    }

    // MARK: - onDelta: interval throttle

    @Test("Second sentence within minInterval is suppressed, then announced after the interval")
    func intervalThrottleSuppressesThenReleases() {
        var a = AssistantStreamAnnouncer(minInterval: 2)
        let t0 = Date()
        #expect(a.onDelta(fullContent: "First sentence.", now: t0) == "First sentence.")
        // Within the interval → suppressed, and NOT consumed (offset held).
        #expect(
            a.onDelta(
                fullContent: "First sentence. Second sentence.",
                now: t0.addingTimeInterval(0.5)
            ) == nil
        )
        #expect(a.announcedOffset == 15)
        // After the interval → the held sentence is released.
        #expect(
            a.onDelta(
                fullContent: "First sentence. Second sentence.",
                now: t0.addingTimeInterval(2.5)
            ) == "Second sentence."
        )
    }

    // MARK: - onDelta: only-new-text

    @Test("Returned chunk is only the NEW text, never the full buffer")
    func returnsOnlyNewText() {
        var a = AssistantStreamAnnouncer(minInterval: 0)
        let t0 = Date()
        #expect(a.onDelta(fullContent: "Alpha beta.", now: t0) == "Alpha beta.")
        let second = a.onDelta(
            fullContent: "Alpha beta. Gamma delta.",
            now: t0.addingTimeInterval(1)
        )
        #expect(second == "Gamma delta.")
        #expect(second != "Alpha beta. Gamma delta.")
    }

    @Test("No new text past announcedOffset returns nil")
    func noNewTextReturnsNil() {
        var a = AssistantStreamAnnouncer(minInterval: 0)
        let t0 = Date()
        #expect(a.onDelta(fullContent: "Done.", now: t0) == "Done.")
        // Same buffer, nothing new → nil.
        #expect(a.onDelta(fullContent: "Done.", now: t0.addingTimeInterval(5)) == nil)
    }

    // MARK: - onDelta: paragraph boundary

    @Test("A \\n\\n paragraph break triggers a chunk even without .!?")
    func paragraphBreakTriggersChunk() {
        var a = AssistantStreamAnnouncer(minInterval: 0)
        let t0 = Date()
        // No sentence terminator yet.
        #expect(a.onDelta(fullContent: "A heading line", now: t0) == nil)
        // Blank-line paragraph break is a boundary.
        #expect(a.onDelta(fullContent: "A heading line\n\n", now: t0) == "A heading line")
    }

    // MARK: - onTerminal

    @Test("Complete announces once; a second call returns nil")
    func completeAnnouncedOnce() {
        var a = AssistantStreamAnnouncer()
        #expect(a.onTerminal(.complete, errorMessage: nil) == "Response complete")
        #expect(a.onTerminal(.complete, errorMessage: nil) == nil)
    }

    @Test("Cancellation and failure produce distinct cues from complete")
    func terminalDispositionsAreDistinct() {
        var cancelled = AssistantStreamAnnouncer()
        #expect(cancelled.onTerminal(.cancelled, errorMessage: nil) == "Response stopped")

        var failed = AssistantStreamAnnouncer()
        #expect(
            failed.onTerminal(.failed, errorMessage: "Network unreachable.") == "Network unreachable."
        )

        var complete = AssistantStreamAnnouncer()
        let completeCue = complete.onTerminal(.complete, errorMessage: nil)
        #expect(completeCue == "Response complete")
        #expect(completeCue != "Response stopped")
    }

    @Test("Failed with empty/whitespace error falls back to a generic cue")
    func failedEmptyErrorFallsBack() {
        var nilError = AssistantStreamAnnouncer()
        #expect(nilError.onTerminal(.failed, errorMessage: nil) == "Response failed")

        var blankError = AssistantStreamAnnouncer()
        #expect(blankError.onTerminal(.failed, errorMessage: "   ") == "Response failed")
    }

    // MARK: - firstTokenCue

    @Test("First-token cue fires once on the empty -> non-empty flip")
    func firstTokenCueFiresOnce() {
        var a = AssistantStreamAnnouncer()
        // Still empty → no cue.
        #expect(a.firstTokenCue(fullContent: "") == nil)
        // First non-empty content → start cue.
        #expect(a.firstTokenCue(fullContent: "H") == "Rapid is responding")
        // Already fired → silent thereafter.
        #expect(a.firstTokenCue(fullContent: "Hello") == nil)
    }
}
