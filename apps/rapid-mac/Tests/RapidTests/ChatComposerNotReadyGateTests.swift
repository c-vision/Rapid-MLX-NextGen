import Foundation
import Testing
@testable import Rapid

/// Cycle-13 P3 (cycle-0 bug-fuzz): "chat input accepts text + Enter
/// while model not Ready, no feedback."
///
/// Repro before the fix: with the server in ``.idle`` / ``.stopped``,
/// ChatView is rendered with ``serverReady = false``. The composer pill
/// accepts text, the user hits Return, ``ComposeTextEditor`` calls
/// ``ChatView.trySend`` which silently no-ops on the ``canSend`` guard.
/// No copy explains the gate, the Send button's hover tooltip still
/// reads "Send (Return)", and the editor placeholder still reads
/// "Send a message…" — every visible affordance promises the app will
/// send, and then it doesn't.
///
/// The fix introduces three pure helpers on ``ChatView``
/// (``notReadyHintText``, ``composerPlaceholder``, ``sendButtonTooltip``)
/// plus an inline caption above the composer pill. This suite pins the
/// helpers so a future edit to the copy / state-routing rules can't
/// silently regress the gate. The caption-rendering itself is covered
/// by the existing snapshot suite (it picks up changes to the composer
/// VStack on its next refresh).
///
/// Competitor reference (per ``feedback_copy_mature_competitors``):
/// ChatGPT Desktop, Claude Desktop, and LM Studio all gate the composer
/// until the model is loaded with a placeholder swap + tooltip + visual
/// "not ready" cue. We mirror their pattern; this suite is the contract.
@Suite("Chat composer not-ready gate (cycle-13 P3)")
struct ChatComposerNotReadyGateTests {
    // MARK: - notReadyHintText

    @Test("Hint suppressed when server is .ready")
    func hintNilWhenReady() {
        let hint = ChatView.notReadyHintText(for: .ready(alias: "qwen3.5-4b"))
        #expect(hint == nil)
    }

    @Test("Hint suppressed when server is .crashed — crash banner owns the surface")
    func hintNilWhenCrashed() {
        // The crash banner already explains the error inline above the
        // composer; a second caption would double-message the user.
        // See ``ChatView.notReadyHintText`` for the contract.
        let hint = ChatView.notReadyHintText(
            for: .crashed(alias: "qwen3.5-4b", message: "EXIT 1")
        )
        #expect(hint == nil)
    }

    @Test("Hint suppressed when server is .missing — missingOverlay owns the surface")
    func hintNilWhenMissing() {
        // ``.missing`` routes to ``ContentView.missingOverlay`` upstream,
        // so ChatView never actually renders in this state. Defensive
        // ``nil`` keeps the helper total.
        #expect(ChatView.notReadyHintText(for: .missing) == nil)
    }

    @Test("Hint visible and loading-flavoured when server is .starting")
    func hintLoadingWhenStarting() {
        let hint = ChatView.notReadyHintText(for: .starting(alias: "qwen3.5-4b"))
        #expect(hint != nil)
        #expect(hint == "Model is loading…")
    }

    @Test("Hint visible and idle-flavoured when server is .idle")
    func hintIdleWhenIdle() {
        let hint = ChatView.notReadyHintText(for: .idle)
        #expect(hint != nil)
        // The copy must steer the user to the picker so they know how
        // to unblock themselves — bare "model not ready" leaves the
        // next action ambiguous (LM Studio's exact convention).
        #expect(hint?.contains("picker") == true)
    }

    @Test("Hint visible when server is .stopped")
    func hintIdleWhenStopped() {
        // ``.stopped`` is a user-initiated terminal state (they hit
        // Stop). Same recovery path as ``.idle`` (pick a model).
        let hint = ChatView.notReadyHintText(for: .stopped)
        #expect(hint != nil)
        #expect(hint?.contains("picker") == true)
    }

    // MARK: - composerPlaceholder

    @Test("Composer placeholder is unchanged for .ready")
    func placeholderUnchangedWhenReady() {
        // The DO-NOT-CHANGE constraint from the cycle-13 brief: the
        // existing v0.4 copy must survive the ready path so we don't
        // regress muscle memory.
        let copy = ChatView.composerPlaceholder(for: .ready(alias: "qwen3.5-4b"))
        #expect(copy == "Send a message…")
    }

    @Test("Composer placeholder is state-specific: .idle / .stopped read 'isn't running'")
    func placeholderIdleAndStopped() {
        // Codex r1 BLOCKING: the placeholder must match the real WHY
        // for each state — "Model is loading…" on .idle / .stopped is
        // a lie (those states are NOT loading) and contradicts both
        // the inline hint and the picker-driven recovery path.
        let idle = ChatView.composerPlaceholder(for: .idle)
        let stopped = ChatView.composerPlaceholder(for: .stopped)
        // Send now STARTS the model, so the placeholder promises the
        // action rather than reporting a process state the user can do
        // nothing about. The old copy ("Model isn't running…") paired
        // with a dead Send button and an instruction to use the picker
        // — and following that instruction unmounted ChatView and
        // destroyed the draft.
        #expect(idle != "Send a message…")
        #expect(stopped != "Send a message…")
        #expect(idle == "Send a message to start the model…")
        #expect(stopped == "Send a message to start the model…")
    }

    @Test("Composer placeholder for .starting reads 'loading'")
    func placeholderStarting() {
        let copy = ChatView.composerPlaceholder(for: .starting(alias: "qwen3.5-4b"))
        #expect(copy == "Model is loading…")
    }

    @Test("Composer placeholder for .crashed reads 'crashed' — not 'loading'")
    func placeholderCrashed() {
        // Codex r1 BLOCKING follow-up: ChatView is rendered for
        // .crashed (the inline crash banner sits above the composer).
        // The placeholder must NOT contradict it with "loading" copy.
        let copy = ChatView.composerPlaceholder(
            for: .crashed(alias: "qwen3.5-4b", message: "EXIT 1")
        )
        #expect(copy != "Send a message…")
        #expect(copy != "Model is loading…")
        #expect(copy.lowercased().contains("crash"))
    }

    @Test("Composer placeholder never leaks the ready-state copy when not ready")
    func placeholderNeverLeaksReadyCopy() {
        let states: [ServerState] = [
            .starting(alias: "qwen3.5-4b"),
            .crashed(alias: "qwen3.5-4b", message: "EXIT 1"),
            .idle,
            .stopped,
            .missing
        ]
        for s in states {
            let copy = ChatView.composerPlaceholder(for: s)
            #expect(
                copy != "Send a message…",
                "Placeholder for \(s) leaked the ready-state copy"
            )
        }
    }

    // MARK: - sendButtonTooltip

    @Test("Send tooltip reads 'Send (Return)' when ready and not streaming")
    func sendTooltipReadyState() {
        let copy = ChatView.sendButtonTooltip(
            for: .ready(alias: "qwen3.5-4b"),
            isStreaming: false
        )
        #expect(copy == "Send (Return)")
    }

    @Test("Send tooltip flips to stop copy while streaming, regardless of server state")
    func sendTooltipStreamingWins() {
        // Streaming wins over server state: the circle is the Stop
        // button right now, and "Send isn't ready" would be a lie.
        let copy = ChatView.sendButtonTooltip(
            for: .ready(alias: "qwen3.5-4b"),
            isStreaming: true
        )
        #expect(copy.contains("Stop"))
        // Same applies even from a not-ready state (a streaming
        // request that crossed a state flip mid-flight — defensive).
        let copy2 = ChatView.sendButtonTooltip(
            for: .idle,
            isStreaming: true
        )
        #expect(copy2.contains("Stop"))
    }

    @Test("Send tooltip explains the gate when not ready and not streaming")
    func sendTooltipExplainsGate() {
        // Each not-ready state should yield a tooltip that explains
        // WHY (so the disabled hover isn't a dead-end), not the
        // ready-state "Send (Return)" promise.
        let cases: [(ServerState, String)] = [
            // Was "picker": the tooltip used to send the user to the
            // Start CTA. Send does that itself now.
            (.idle, "start"),
            (.stopped, "start"),
            (.crashed(alias: "qwen3.5-4b", message: "EXIT 1"), "Restart"),
            (.starting(alias: "qwen3.5-4b"), "loading"),
            // No-jargon contract: the not-set-up tooltip must NOT name the
            // engine ("rapid-mlx"); it points the user at the fix instead.
            (.missing, "set up")
        ]
        for (state, expectedNeedle) in cases {
            let copy = ChatView.sendButtonTooltip(
                for: state,
                isStreaming: false
            )
            #expect(
                copy != "Send (Return)",
                "Tooltip for \(state) still reads the ready copy"
            )
            #expect(
                copy.lowercased().contains(expectedNeedle.lowercased()),
                "Tooltip for \(state) missing needle '\(expectedNeedle)': \(copy)"
            )
        }
    }

    // MARK: - Hint visibility predicate cross-check

    @Test("Hint visibility tracks the gate's WHY-needs-explaining states")
    func hintVisibilityMatchesGate() {
        // The composer caption should appear exactly when the editor
        // is interactive AND the gate is active AND no sibling banner
        // already owns the WHY. That is: .idle / .stopped / .starting
        // (the latter only on defensive routing — startingOverlay
        // normally hides ChatView). .ready (no gate) and .crashed
        // (crashBanner above the composer) suppress. .missing is
        // already gone from the ChatView surface by routing.
        let visible: [ServerState] = [
            .idle,
            .stopped,
            .starting(alias: "qwen3.5-4b")
        ]
        let suppressed: [ServerState] = [
            .ready(alias: "qwen3.5-4b"),
            .crashed(alias: "qwen3.5-4b", message: "EXIT 1"),
            .missing
        ]
        for s in visible {
            #expect(
                ChatView.notReadyHintText(for: s) != nil,
                "Expected hint visible for \(s)"
            )
        }
        for s in suppressed {
            #expect(
                ChatView.notReadyHintText(for: s) == nil,
                "Expected hint suppressed for \(s)"
            )
        }
    }

    // MARK: - composerKeyboardHint (fresh-composer keyboard affordance)

    @Test("Keyboard hint visible on a fresh, ready, empty composer")
    func keyboardHintVisibleOnFreshComposer() {
        // The onboarding moment: ⌘N or a new chat leaves the model
        // loaded (.ready), an empty transcript, and an empty draft —
        // exactly when teaching Return-to-send pays off.
        let hint = ChatView.composerKeyboardHint(
            state: .ready(alias: "qwen3.5-4b"),
            isStreaming: false,
            draftIsEmpty: true,
            transcriptIsEmpty: true
        )
        #expect(hint != nil)
        #expect(hint?.contains("send") == true)
        #expect(hint?.contains("new line") == true)
    }

    @Test("Keyboard hint hidden the moment the user starts typing")
    func keyboardHintHiddenWhileTyping() {
        let hint = ChatView.composerKeyboardHint(
            state: .ready(alias: "qwen3.5-4b"),
            isStreaming: false,
            draftIsEmpty: false,
            transcriptIsEmpty: true
        )
        #expect(hint == nil)
    }

    @Test("Keyboard hint hidden once the transcript has any messages")
    func keyboardHintHiddenAfterFirstTurn() {
        // Onboarding is over once the chat has content — the persistent
        // caption would be clutter while the user reads a reply.
        let hint = ChatView.composerKeyboardHint(
            state: .ready(alias: "qwen3.5-4b"),
            isStreaming: false,
            draftIsEmpty: true,
            transcriptIsEmpty: false
        )
        #expect(hint == nil)
    }

    @Test("Keyboard hint hidden while streaming (the circle is Stop, not Send)")
    func keyboardHintHiddenWhileStreaming() {
        let hint = ChatView.composerKeyboardHint(
            state: .ready(alias: "qwen3.5-4b"),
            isStreaming: true,
            draftIsEmpty: true,
            transcriptIsEmpty: true
        )
        #expect(hint == nil)
    }

    @Test("Keyboard hint hidden in every non-ready state (not-ready gate owns the slot)")
    func keyboardHintHiddenWhenNotReady() {
        let notReady: [ServerState] = [
            .idle,
            .stopped,
            .starting(alias: "qwen3.5-4b"),
            .crashed(alias: "qwen3.5-4b", message: "EXIT 1"),
            .missing
        ]
        for s in notReady {
            #expect(
                ChatView.composerKeyboardHint(
                    state: s,
                    isStreaming: false,
                    draftIsEmpty: true,
                    transcriptIsEmpty: true
                ) == nil,
                "Keyboard hint must defer to the not-ready gate for \(s)"
            )
        }
    }

    // MARK: - Send-starts-the-model consent gates
    //
    // Send no longer refuses when the model is stopped — it starts it.
    // "Silently" must never stretch to committing the user to a
    // multi-gigabyte download or to a model that will push their Mac
    // into swap, so the two gates that used to live only on the
    // picker's Start CTA now guard this path too.

    @Test("Already serving ⇒ send, no questions asked")
    func preflightReadyJustSends() {
        for fit in [ModelSizing.Fit.recommended, .borderline, .tooBig] {
            #expect(
                ChatView.sendPreflight(
                    serverReady: true,
                    existsInCatalog: true,
                    isDownloaded: false,
                    fit: fit
                ) == .send,
                "a live server must never re-litigate size or download state"
            )
        }
    }

    @Test("A cached model that fits starts silently")
    func preflightCachedFitsSends() {
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: true,
                isDownloaded: true,
                fit: .recommended
            ) == .send
        )
        // Borderline is a yellow flag in the picker, not a blocker —
        // it must not grow a dialog here either.
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: true,
                isDownloaded: true,
                fit: .borderline
            ) == .send
        )
    }

    @Test("An uncached model asks before spending the bandwidth")
    func preflightUncachedConfirms() {
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: true,
                isDownloaded: false,
                fit: .recommended
            ) == .confirmDownload
        )
    }

    @Test("Size is asked about before bandwidth")
    func preflightTooBigWinsOverDownload() {
        // A model that won't fit shouldn't be downloaded either, so
        // the RAM question comes first — otherwise the user consents
        // to 6 GB and only then learns it won't run.
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: true,
                isDownloaded: false,
                fit: .tooBig
            ) == .confirmTooBig
        )
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: true,
                isDownloaded: true,
                fit: .tooBig
            ) == .confirmTooBig
        )
    }

    @Test("An alias the catalog doesn't know stays blocked")
    func preflightUnknownAliasBlocked() {
        // Nothing sensible to start — keep the old disabled-Send
        // behaviour rather than spawning against a bad alias.
        #expect(
            ChatView.sendPreflight(
                serverReady: false,
                existsInCatalog: false,
                isDownloaded: false,
                fit: .recommended
            ) == .blocked
        )
    }
}
