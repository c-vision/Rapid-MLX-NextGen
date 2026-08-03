import Foundation
import Testing
@testable import Rapid

/// Pin contract for #129 — the user-facing pill collapses ``.idle``
/// and ``.stopped`` to a single off-state.
///
/// Pre-#129 the status pill rendered:
///   * ``.idle``   → "Idle" with a grey ``.secondary`` dot
///   * ``.stopped`` → "Stopped" with an amber-tinted ``amberDeep`` dot
///
/// At-a-glance these were indistinguishable, and worse, the user had
/// no actionable distinction between them: in both states no warm
/// process exists, Start re-spawns from scratch, and the chat surface
/// gates send the same way. The amber tint read as "warning" with no
/// follow-on action surfaced anywhere else in the UI. Ollama and LM
/// Studio collapse this to a single off-state and let the Start /
/// Stop button label carry the "what action is next" signal.
///
/// The internal ``ServerState`` enum keeps both cases — other
/// surfaces (e.g. session-restore on cold-launch vs after-Stop) can
/// still react. This is purely a pill-copy collapse.
@Suite("ModelPickerBar pill — .idle and .stopped collapse to one off-state (regression #129)")
struct IdleStoppedPillCollapseTests {

    @Test(".idle pill copy is 'Idle'")
    func idleRendersIdle() {
        #expect(ModelPickerBar.stateLabel(state: .idle, activity: .starting) == "Idle")
    }

    @Test(".stopped pill copy collapses to 'Idle' — same as .idle")
    func stoppedCollapsesToIdle() {
        #expect(ModelPickerBar.stateLabel(state: .stopped, activity: .starting) == "Idle")
    }

    @Test("Phase under the off-state is irrelevant — pill always reads 'Idle'")
    func phaseIrrelevantInOffState() {
        // Both states gate to "Idle" regardless of what the
        // downloadProgress.phase happens to be — that field only
        // pertains to ``.starting``. A phase reset bug elsewhere
        // shouldn't leak the wrong copy.
        let activities: [DownloadProgress.StartupActivity] = [
            .starting, .downloading, .loading, .warmingUp,
        ]
        for activity in activities {
            #expect(ModelPickerBar.stateLabel(state: .idle,    activity: activity) == "Idle")
            #expect(ModelPickerBar.stateLabel(state: .stopped, activity: activity) == "Idle")
        }
    }

    @Test("Cold-launch and after-Stop produce the same user-visible copy")
    func coldLaunchAndAfterStopAgree() {
        let coldLaunch = ModelPickerBar.stateLabel(state: .idle, activity: .starting)
        let afterStop = ModelPickerBar.stateLabel(state: .stopped, activity: .starting)
        #expect(
            coldLaunch == afterStop,
            "Two off-states must render identically in the pill — user-facing distinction was the bug #129 was filed for. Got coldLaunch=\"\(coldLaunch)\" vs afterStop=\"\(afterStop)\"."
        )
    }
}
