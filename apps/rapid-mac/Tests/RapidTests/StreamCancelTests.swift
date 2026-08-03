import Foundation
import Testing
@testable import Rapid

/// v0.4.29 regression pin for the stream-cancel contract.
///
/// What we're guarding against: a future refactor of
/// ``ChatViewModel.runOneStream`` flipping the cancel-catch path from
/// ``.complete`` to ``.failed``. The user-visible difference is huge:
///   * ``.complete`` keeps the half-streamed reply in normal styling
///     with a small "Stopped." footer — what a user expects after
///     clicking the Stop button.
///   * ``.failed`` paints a red error bubble and visually drops the
///     partial reply, even though the bytes are still in
///     ``message.content``. Users hit Stop expecting to keep what
///     they already read.
///
/// We pin via the ``finaliseCancellation(message:)`` static helper
/// because the actual `runOneStream` is private + async + driven by
/// URLProtocol — too much rope to test the inline behaviour directly
/// without a heavyweight mock stream.
@MainActor
@Suite("ChatViewModel.finaliseCancellation — v0.4.29 cancel contract")
struct StreamCancelTests {
    @Test("Half-streamed content is preserved")
    func preservesContent() {
        var msg = ChatMessage(
            role: .assistant,
            content: "The capital of France is Pa",
            status: .streaming
        )
        ChatViewModel.finaliseCancellation(message: &msg)
        // The 26 chars the user already read MUST stay verbatim.
        #expect(msg.content == "The capital of France is Pa")
    }

    @Test("Status flips to .complete (NOT .failed)")
    func marksComplete() {
        // The whole point: .failed would paint the red Retry bubble
        // and visually drop the partial reply. .complete keeps the
        // half-streamed reply legible.
        var msg = ChatMessage(role: .assistant, content: "anything", status: .streaming)
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.status == .complete)
        #expect(msg.status != .failed)
    }

    @Test("Sets a short Stopped. footer caption")
    func stoppedFooter() {
        var msg = ChatMessage(role: .assistant, content: "anything", status: .streaming)
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.errorMessage == "Stopped.")
    }

    @Test("Already-complete message — finalising is idempotent (defensive)")
    func idempotent() {
        var msg = ChatMessage(role: .assistant, content: "All done.", status: .complete)
        msg.errorMessage = nil
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.status == .complete)
        #expect(msg.errorMessage == "Stopped.")
        #expect(msg.content == "All done.")
    }

    @Test("Empty placeholder cancel — still completes cleanly with just the footer")
    func emptyPlaceholderCancel() {
        // User hit Stop before any bytes arrived. The bubble is
        // empty but should still resolve to .complete + footer so it
        // doesn't sit as a spinning .streaming forever.
        var msg = ChatMessage(role: .assistant, content: "", status: .streaming)
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.status == .complete)
        #expect(msg.content == "")
        #expect(msg.errorMessage == "Stopped.")
    }

    /// Codex audit r1 (ChatViewModel.swift:737): a Stop click that
    /// lands in the gap between ``finish_reason: "tool_calls"`` and
    /// the tool-loop dispatching the first call leaves an assistant
    /// ``tool_calls`` row with no matching ``role: "tool"`` results.
    /// Most chat templates (Qwen, GLM, Hermes) 400 on a bare
    /// assistant tool_calls row in the next wire body. The previous
    /// test pinned the broken behaviour of preserving the staged
    /// calls; the corrected contract clears them so the cancel
    /// turns the row into a plain prose-bubble that the wire body
    /// is happy to ship as history.
    @Test("Cancel-mid-tool-call clears the staged tool_calls (prevents orphan-row 400)")
    func toolCallsClearedOnCancel() {
        var msg = ChatMessage(role: .assistant, content: "calling tool…", status: .streaming)
        msg.toolCalls = [
            ToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\"/tmp/x\"}")
        ]
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.toolCalls == nil)
        #expect(msg.status == .complete)
        #expect(msg.errorMessage == "Stopped.")
        // The user-visible prose is still there — the partial
        // streaming reply the user already read shouldn't vanish.
        #expect(msg.content == "calling tool…")
    }

    // MARK: - Cancellation-shape classification (2026-07 dogfood)

    /// Stop mid-stream painted "Couldn't reach the model. Restart it
    /// from the model bar at the top and try again." over a healthy
    /// model. Root cause: ``Task.cancel()`` landing while the stream
    /// is parked inside URLSession's async machinery surfaces as
    /// ``URLError(.cancelled)`` (NSURLErrorDomain -999), NOT as
    /// Swift's ``CancellationError`` — and the catch chain in
    /// ``runOneStream`` only routed the latter to
    /// ``finaliseCancellation``. The URLError shape fell through to
    /// the generic failure catch: red bubble, false network-error
    /// banner, both persisted to the transcript.
    ///
    /// ``ChatViewModel.isCancellation`` is the single classifier both
    /// shapes now route through. This table is the regression pin.
    @Test("isCancellation: both cancellation shapes are recognised")
    func cancellationShapes() {
        #expect(ChatViewModel.isCancellation(CancellationError()))
        #expect(ChatViewModel.isCancellation(URLError(.cancelled)))
        // The NSError spelling of the same wire-level fact.
        #expect(ChatViewModel.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
    }

    @Test("isCancellation: real failures are NOT swallowed as cancels")
    func realFailuresStayFailures() {
        // Every one of these must keep taking the humanize() failure
        // path — classifying a genuine network death as a polite
        // "Stopped." would hide real outages from the user.
        #expect(!ChatViewModel.isCancellation(URLError(.timedOut)))
        #expect(!ChatViewModel.isCancellation(URLError(.cannotConnectToHost)))
        #expect(!ChatViewModel.isCancellation(URLError(.networkConnectionLost)))
        #expect(!ChatViewModel.isCancellation(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        ))
        struct Boom: Error {}
        #expect(!ChatViewModel.isCancellation(Boom()))
        // -999 in a foreign domain is not URLSession's cancel.
        #expect(!ChatViewModel.isCancellation(
            NSError(domain: "com.example.other", code: NSURLErrorCancelled)
        ))
    }

    // MARK: - Stale error banner lifecycle (2026-07 dogfood)

    /// The chat error banner survived a manual model stop → start
    /// cycle: nothing cleared ``lastError`` when the server got back
    /// to ``.ready``, so the "restart it and try again" advice kept
    /// showing after the user had followed it. The fix is
    /// ``clearStaleErrorBanner()`` called from ContentView's
    /// ``.onChange(of: server.state)`` on the ``.ready`` transition.
    @Test("clearStaleErrorBanner: no-op safe on a fresh view model")
    func clearBannerFreshVM() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-stream-cancel-tests-\(UUID().uuidString).json")
        let vm = ChatViewModel(store: SessionStore(customStoreURL: tmp))
        vm.clearStaleErrorBanner()
        #expect(vm.lastError == nil)
        #expect(!vm.isStreaming)
    }

    /// ``lastError`` is ``private(set)`` and every writer is private
    /// + async, so the ContentView wiring is pinned the way this
    /// suite's neighbours pin render-site contracts: by source shape.
    /// The ``.ready`` transition handler must invoke the clearer.
    @Test("ContentView wires clearStaleErrorBanner into the .ready transition")
    func contentViewWiresBannerClear() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Rapid/UI/ContentView.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("chat.clearStaleErrorBanner()"),
            "ContentView's server-state onChange must clear the stale chat error banner on .ready — see the 2026-07 dogfood report (banner outlived a stop → start cycle)."
        )
    }

    // MARK: - Cold-start cancel contract (PR #581 review)

    /// The "Send starts the model" path added a NEW place a
    /// Stop-during-cold-load could masquerade as a failure — and a worse
    /// one where it wedged the whole app:
    ///   * User clicks Stop while the model is still ``.starting`` →
    ///     ``ensureServing`` returns false → the pre-fix code called
    ///     ``finishWithStartupFailure``, painting a red "Couldn't start …"
    ///     bubble + error banner over a model that was in fact still
    ///     loading fine. This is the exact "Stop no longer masquerades as
    ///     a failure" bug the mid-stream fix closed, reopened on the
    ///     cold-start path.
    ///   * If the Stop landed the instant the model reached ``.ready``,
    ///     ``ensureServing`` returned true and the bare
    ///     ``guard !Task.isCancelled else { return }`` returned with NO
    ///     state reset — ``isStreaming`` stuck ``true`` forever, so every
    ///     future send in every session was blocked behind ``send``'s
    ///     ``guard !isStreaming``, recoverable only by an app restart.
    ///
    /// ``finishStartupCancellation`` is the finaliser both cases now route
    /// through. This pins its contract: the placeholder resolves to
    /// ``.complete`` + "Stopped." (NOT ``.failed``), no ``lastError``
    /// banner is raised, and the streaming state is reset so ``send`` is
    /// usable again.
    @Test("finishStartupCancellation: deliberate cold-start Stop is a clean cancel, not a failure")
    func startupCancelIsCleanCancel() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-startup-cancel-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: tmp)
        let vm = ChatViewModel(store: store)

        let sid = store.newSession(alias: "qwen3.5-4b-4bit")
        store.activeID = sid
        _ = store.appendMessage(
            sessionID: sid,
            ChatMessage(role: .user, content: "hi", status: .complete)
        )
        guard let phIndex = store.appendMessage(
            sessionID: sid,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("failed to seed a streaming placeholder")
            return
        }

        vm.finishStartupCancellation(sessionID: sid, placeholderIndex: phIndex)

        let placeholder = store.sessions.first(where: { $0.id == sid })?.messages[phIndex]
        // The differentiators from finishWithStartupFailure:
        #expect(placeholder?.status == .complete)   // NOT .failed
        #expect(placeholder?.status != .failed)
        #expect(placeholder?.errorMessage == "Stopped.")
        #expect(vm.lastError == nil)                // NO "Couldn't start" banner
        // Streaming state reset so the app isn't wedged behind send's guard.
        #expect(!vm.isStreaming)
        #expect(vm.streamingSessionID == nil)
    }

    /// A genuine cold-start FAILURE (not a cancel) must classify the
    /// error banner as ``.modelLoadFailed`` so #590's diagnosis surfaces
    /// "check the model files or choose another model" + an Open Model
    /// Management action — not the generic ``.requestFailed`` fallback
    /// (from `chatFailureKind("Couldn't start …")`) whose Retry action
    /// just re-runs the same failing start.
    @Test("finishWithStartupFailure classifies the banner as .modelLoadFailed, not generic requestFailed")
    func startupFailureSetsModelLoadKind() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rapid-startup-fail-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: tmp)
        let vm = ChatViewModel(store: store)

        let sid = store.newSession(alias: "qwen3.5-4b-4bit")
        store.activeID = sid
        _ = store.appendMessage(
            sessionID: sid,
            ChatMessage(role: .user, content: "hi", status: .complete)
        )
        guard let phIndex = store.appendMessage(
            sessionID: sid,
            ChatMessage(role: .assistant, status: .streaming)
        ) else {
            Issue.record("failed to seed a streaming placeholder")
            return
        }

        vm.finishWithStartupFailure(sessionID: sid, placeholderIndex: phIndex, alias: "qwen3.5-4b-4bit")

        #expect(vm.lastFailureKind == .modelLoadFailed)
        #expect(vm.lastError != nil)
        let placeholder = store.sessions.first(where: { $0.id == sid })?.messages[phIndex]
        #expect(placeholder?.status == .failed)
        #expect(!vm.isStreaming)
    }

    /// Source-shape pin for the WIRING: ``send``'s cold-start block must
    /// route a cancellation to ``finishStartupCancellation``, and it must
    /// check ``Task.isCancelled`` BEFORE the ``guard ready`` failure
    /// branch (so a Stop that races the ``.ready`` flip can't fall through
    /// to the "Couldn't start" failure path). Pinned by source shape
    /// because the cancel timing is an async race this suite deliberately
    /// does not drive live (see this file's header rationale).
    @Test("send() routes a cold-start cancel to finishStartupCancellation, before the failure branch")
    func sendWiresStartupCancel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Rapid/Chat/ChatViewModel.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("finishStartupCancellation("),
            "send()'s cold-start path must finalise a user Stop through finishStartupCancellation — see PR #581 review (cold-start Stop wedged the app / faked a failure)."
        )
        guard
            let cancelPos = source.range(of: "finishStartupCancellation(")?.lowerBound,
            let failPos = source.range(of: "guard ready else {")?.lowerBound
        else {
            Issue.record("Expected both the cancel finaliser call and the `guard ready` failure branch in send().")
            return
        }
        #expect(
            cancelPos < failPos,
            "The Task.isCancelled check must come BEFORE `guard ready` so a Stop racing the .ready flip is not mislabelled a start failure."
        )
    }
}
