import Foundation
import Testing
@testable import Rapid

/// v0.4.38 contract pin for the ⌘. stop-streaming shortcut.
///
/// The shortcut lives in a hidden carrier that only renders when
/// ``ChatViewModel.isStreaming`` is true — so the carrier itself is
/// hard to drive without SwiftUI introspection. The carrier's
/// payload is a single call to ``ChatViewModel.stop()``, which is
/// the actual contract the user sees. We pin two invariants of
/// that call so an idle ⌘. (or a runaway race where the carrier
/// is rendered while the stream just finished) can never crash:
///
///   1. ``stop()`` on a fresh view-model — no stream ever started
///      — must be a no-op rather than a fault.
///   2. ``stop()`` called twice in a row must remain a no-op on
///      the second invocation (so ⌘.-⌘. in rapid succession is
///      safe, mirroring ChatGPT Desktop where users sometimes
///      hammer the shortcut to make absolutely sure the stream
///      stopped).
@MainActor
@Suite("Cmd+. stop-shortcut — v0.4.38 safety contract")
struct StopShortcutTests {
    private func makeStore() -> SessionStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-stop-shortcut-tests-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: tmp)
    }

    @Test("Idle stop() is a safe no-op — pinning the contract for a stray ⌘.")
    func idleStopIsSafe() {
        // No stream has ever started, so ``inflight`` is nil and
        // the optional-chain inside ``stop()`` short-circuits.
        // Recording the expected behaviour here protects against
        // a future refactor that adds an unchecked force-unwrap
        // or a precondition on ``inflight``.
        let vm = ChatViewModel(store: makeStore())
        vm.stop()
        #expect(!vm.isStreaming, "Idle stop() must leave isStreaming false")
    }

    @Test("Double-stop() in rapid succession is safe")
    func doubleStopIsSafe() {
        // ⌘.-⌘. is a real user pattern when the spinner appears
        // to hang for a beat after the first press. Both calls
        // must remain no-ops since no stream is in flight.
        let vm = ChatViewModel(store: makeStore())
        vm.stop()
        vm.stop()
        #expect(!vm.isStreaming, "Repeated stop() while idle must still leave isStreaming false")
    }
}
