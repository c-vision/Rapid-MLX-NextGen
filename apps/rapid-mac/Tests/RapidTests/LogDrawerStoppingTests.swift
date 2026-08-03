import Foundation
import Testing
@testable import Rapid

/// v0.4.28 contract pins for two quality-of-life UX fixes:
///   * Stop-button "Stopping…" label — purely a function of
///     ``(ServerState, isOperating)``, so the truth table can be pinned
///     without standing up a real ``ServerManager``.
///   * LogDrawer auto-scroll — the bottom-anchor id is the only piece
///     of test surface; the scroll behaviour itself is rendered through
///     ``ScrollViewReader`` and only verifiable with a live window.
@MainActor
@Suite("v0.4.28 stop-label + log-drawer auto-scroll")
struct LogDrawerStoppingTests {
    // MARK: - Stopping-in-flight truth table

    @Test("Idle + not operating → no Stopping label (nothing in flight)")
    func idleNotOperating() {
        #expect(!ModelPickerBar.isStoppingInFlight(state: .idle, isOperating: false))
    }

    @Test("Ready + not operating → no Stopping label (steady-state)")
    func readyNotOperating() {
        #expect(!ModelPickerBar.isStoppingInFlight(state: .ready(alias: "any-alias"), isOperating: false))
    }

    @Test("Ready + operating → SHOW Stopping (graceful shutdown in flight)")
    func readyOperating() {
        // ServerManager keeps the published state at .ready until the
        // child has drained, so this is the canonical mid-stop window.
        #expect(ModelPickerBar.isStoppingInFlight(state: .ready(alias: "qwen3.5-4b"), isOperating: true))
    }

    @Test("Crashed + operating → SHOW Stopping (post-crash cleanup)")
    func crashedOperating() {
        // The user can hit Stop after a crash to release the crashed
        // state; that path also flips isOperating.
        #expect(
            ModelPickerBar.isStoppingInFlight(
                state: .crashed(alias: "qwen3.5-4b", message: "OOM"),
                isOperating: true
            )
        )
    }

    @Test("Starting + operating → NO Stopping (it's spinning UP, not down)")
    func startingOperating() {
        // The state badge already says "Starting / Downloading /
        // Loading <alias>"; surfacing "Stopping" here would mislead.
        #expect(!ModelPickerBar.isStoppingInFlight(state: .starting(alias: "qwen3.5-4b"), isOperating: true))
    }

    @Test("Stopped + operating → NO Stopping (already done)")
    func stoppedOperating() {
        // Edge: in the millisecond between state flipping to .stopped
        // and isOperating clearing, we don't want a stale label.
        #expect(!ModelPickerBar.isStoppingInFlight(state: .stopped, isOperating: true))
    }

    @Test("Missing + operating → NO Stopping (binary gone, nothing running)")
    func missingOperating() {
        #expect(!ModelPickerBar.isStoppingInFlight(state: .missing, isOperating: true))
    }
}
