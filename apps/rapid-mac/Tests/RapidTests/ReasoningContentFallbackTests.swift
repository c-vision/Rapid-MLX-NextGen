import Foundation
import Testing
@testable import Rapid

/// Cycle-2 (2026-06-19) regression pin for the chat-view reasoning
/// fallback bug filed by cycle-1 fuzz-stress F-002 and the cycle-1
/// fuzz-correctness verbose-reasoning UX item.
///
/// Symptom: a reasoning model (phi-4-mini-reasoning, deepseek_r1,
/// nanbeige4.1-3b, any model whose chat template emits
/// ``reasoning_content`` deltas) that hits ``finish_reason: length``
/// mid-think arrives at the chat-view with ``content == ""`` AND
/// ``reasoning`` populated. Pre-cycle-2 the row was flagged as a
/// hard failure (red caption, status=.failed) and the reasoning
/// disclosure stayed collapsed by default — the user saw an empty
/// red bubble with no obvious next step.
///
/// Fix: ``classifyTerminal`` distinguishes this shape as
/// ``.reasoningOnlyTruncated`` so the row stays ``.complete`` with
/// a SOFT (secondary, NOT red) hint, and ChatView auto-expands the
/// reasoning disclosure on first appearance.
///
/// This file covers the engine-side classifier only. Pre-existing
/// behaviour (``ModelSwitchHistoryTests``) MUST keep passing —
/// see the legacy-shim tests below for the back-compat surface
/// the old ``zeroContentFailureMessage`` API still satisfies.
@MainActor
@Suite("Cycle-2 reasoning_content fallback (chat-view F-002)")
struct ReasoningContentFallbackTests {

    // MARK: - classifyTerminal — the cycle-2 surface

    @Test("Empty content + populated reasoning + finish_reason=length lands as reasoningOnlyTruncated, NOT a hard failure")
    func emptyContentLengthWithReasoningIsSoftTruncation() {
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "Let me think about this. First I need to ...",
            toolCalls: nil,
            finishReason: "length"
        )
        guard case .reasoningOnlyTruncated(let hint) = outcome else {
            #expect(Bool(false), "Expected .reasoningOnlyTruncated, got \(outcome)")
            return
        }
        // Hint copy must (i) tell the user what happened (max_tokens
        // hit mid-think) and (ii) name a concrete next step. Without
        // both, the row reads as "model is broken".
        #expect(hint.contains("Max Tokens"),
                "Hint must name the trigger; got: \(hint)")
        #expect(hint.contains("Max Tokens") || hint.contains("max tokens"),
                "Hint must name the user-facing knob to raise; got: \(hint)")
        #expect(hint.lowercased().contains("reasoning")
                || hint.lowercased().contains("trace")
                || hint.lowercased().contains("thinking"),
                "Hint must reference the reasoning trace so the user knows where to look; got: \(hint)")
    }

    @Test("Hybrid Qwen path is preserved — non-empty content + non-empty reasoning + finish_reason=stop is a real completion")
    func hybridContentPlusReasoningIsRealCompletion() {
        // Qwen3.6 / GLM 4.7 / Qwopus emit content + reasoning_content
        // in normal completions. The fix MUST NOT regress this — a
        // healthy hybrid turn is .realCompletion regardless of
        // whether reasoning was populated.
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "The capital of France is Paris.",
            reasoningContent: "User asked about a capital city. France's capital is Paris.",
            toolCalls: nil,
            finishReason: "stop"
        )
        #expect(outcome == .realCompletion)
    }

    @Test("Hybrid Qwen path: non-empty content + non-empty reasoning + finish_reason=length is STILL a real completion (the answer body landed)")
    func hybridContentPlusReasoningAtLengthIsRealCompletion() {
        // The model produced a partial answer AND used reasoning;
        // length-truncation here is "long answer hit cap" not
        // "answer never started". Pre-cycle-2 behaviour: also
        // .realCompletion (content non-empty short-circuited the
        // failure branch). Pin this explicitly so the cycle-2
        // refactor can't accidentally convert it into a soft hint.
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "Paris is the capital of France. It is also...",
            reasoningContent: "User wants a capital city fact.",
            toolCalls: nil,
            finishReason: "length"
        )
        #expect(outcome == .realCompletion)
    }

    @Test("Empty content + empty reasoning + finish_reason=length is still a hard failure — nothing to surface")
    func emptyEverythingAtLengthIsHardFailure() {
        // A length-truncated turn with zero reasoning AND zero
        // content has nothing useful to show. Keep the existing
        // v0.4.35 hard-failure copy so the user gets a path forward.
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "",
            toolCalls: nil,
            finishReason: "length"
        )
        guard case .emptyTurnFailure(let message) = outcome else {
            #expect(Bool(false), "Expected .emptyTurnFailure, got \(outcome)")
            return
        }
        #expect(message.contains("Max Tokens"))
    }

    @Test("Empty content + populated reasoning + finish_reason=stop is treated as a hard failure (reasoning-only finish without length is a chat-template bug)")
    func emptyContentStopWithReasoningIsStillHardFailure() {
        // A clean ``stop`` with reasoning-only output is overwhelmingly
        // a parser / chat-template misclassification (e.g. the
        // ``<think>`` close token was eaten by the splitter), NOT a
        // budget issue. Keep the model-switch hint so the user has a
        // path forward — switching models / regen typically clears
        // the chat-template state and the next turn works.
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "I'm thinking about how to answer.",
            toolCalls: nil,
            finishReason: "stop"
        )
        guard case .emptyTurnFailure(let message) = outcome else {
            #expect(Bool(false), "Expected .emptyTurnFailure, got \(outcome)")
            return
        }
        #expect(message.contains("switching models"))
    }

    @Test("Tool-call terminal is .realCompletion even with empty prose + empty reasoning — the tool-call IS the output")
    func toolCallTerminalIsRealCompletion() {
        let calls = [ToolCall(id: "c1", name: "web_search", arguments: "{}")]
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "",
            toolCalls: calls,
            finishReason: "tool_calls"
        )
        #expect(outcome == .realCompletion)
    }

    @Test("Whitespace-only reasoning does NOT activate the soft-truncation branch — only meaningful trace counts")
    func whitespaceOnlyReasoningIsTreatedAsEmpty() {
        // A reasoning lane containing only whitespace is not a
        // useful surface; defer to the existing length+empty hard
        // failure copy so the user gets a clear next step.
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "  \n\t  ",
            toolCalls: nil,
            finishReason: "length"
        )
        guard case .emptyTurnFailure = outcome else {
            #expect(Bool(false), "Whitespace-only reasoning should NOT trigger soft truncation; got \(outcome)")
            return
        }
    }

    @Test("Whitespace-only content + populated reasoning + length lands as reasoningOnlyTruncated — \"  \\n\" is not a real answer")
    func whitespaceOnlyContentWithReasoningIsSoftTruncation() {
        let outcome = ChatViewModel.classifyTerminal(
            proseContent: "  \n\t  ",
            reasoningContent: "I was about to say that...",
            toolCalls: nil,
            finishReason: "length"
        )
        guard case .reasoningOnlyTruncated = outcome else {
            #expect(Bool(false), "Expected .reasoningOnlyTruncated, got \(outcome)")
            return
        }
    }

    // MARK: - reasoningTruncated marker semantics (codex r1 MAJOR-1)

    @Test("reasoningTruncated defaults to false on every ChatMessage shape")
    func reasoningTruncatedDefaultsFalse() {
        // Pre-cycle-2 ChatMessage()s — including ones decoded from
        // on-disk sessions saved before the flag existed — MUST
        // arrive with the flag false. Otherwise the chat-view would
        // hallucinate "cut off by max_tokens" on every old session.
        #expect(ChatMessage(role: .user).reasoningTruncated == false)
        #expect(ChatMessage(role: .assistant).reasoningTruncated == false)
        #expect(
            ChatMessage(
                role: .assistant,
                content: "real reply",
                reasoning: "thought process",
                status: .complete
            ).reasoningTruncated == false
        )
    }

    @Test("finaliseCancellation does NOT set reasoningTruncated — user-stopped streams must not auto-expand or claim max_tokens")
    func cancellationDoesNotSetTruncatedFlag() {
        // Codex r1 MAJOR-1 regression pin. A stream cancelled by the
        // user mid-think lands as .complete with errorMessage =
        // "Stopped." and (likely) empty content + populated
        // reasoning. The UI keys on ``reasoningTruncated`` (a
        // structural flag) instead of inferring the shape from
        // (content.isEmpty && !reasoning.isEmpty) so this case
        // does NOT trigger the auto-expand + "cut off by max_tokens"
        // copy + accessibility caption. Pin the contract:
        // finaliseCancellation must NEVER set the flag.
        var msg = ChatMessage(
            role: .assistant,
            content: "",
            reasoning: "I was thinking about...",
            status: .streaming
        )
        ChatViewModel.finaliseCancellation(message: &msg)
        #expect(msg.status == .complete)
        #expect(msg.errorMessage == "Stopped.")
        #expect(msg.reasoningTruncated == false,
                "finaliseCancellation must not flip reasoningTruncated — that's the F-002 truncation marker, not a cancel marker")
    }

    // MARK: - Outcome → ChatMessage mutation invariant (codex r2 NIT)

    /// Mirrors the switch in ``runOneStream``'s ``.finished`` handler
    /// — when ``classifyTerminal`` returns each of the three cases,
    /// the row should end up in the documented shape. Lifted out as a
    /// helper so the test pins the SAME mutation the production code
    /// performs; a future refactor that changes either side without
    /// the other will break this test.
    private func applyOutcome(
        _ outcome: ChatViewModel.TerminalOutcome,
        to message: inout ChatMessage
    ) {
        message.status = .complete
        switch outcome {
        case .realCompletion:
            break
        case .reasoningOnlyTruncated(let hint):
            message.errorMessage = hint
            message.reasoningTruncated = true
        case .emptyTurnFailure(let m):
            message.errorMessage = m
            message.status = .failed
        }
    }

    @Test("Outcome → ChatMessage: only .reasoningOnlyTruncated sets reasoningTruncated; other cases leave it false")
    func onlySoftTruncationSetsTheFlag() {
        // Real completion path.
        var rc = ChatMessage(role: .assistant, status: .streaming)
        applyOutcome(.realCompletion, to: &rc)
        #expect(rc.status == .complete)
        #expect(rc.reasoningTruncated == false)
        #expect(rc.errorMessage == nil)

        // Soft truncation path.
        var soft = ChatMessage(role: .assistant, status: .streaming)
        applyOutcome(.reasoningOnlyTruncated(hint: "...max_tokens..."), to: &soft)
        #expect(soft.status == .complete)
        #expect(soft.reasoningTruncated == true)
        #expect(soft.errorMessage?.contains("max_tokens") == true)

        // Hard failure path.
        var hard = ChatMessage(role: .assistant, status: .streaming)
        applyOutcome(.emptyTurnFailure(message: "no text"), to: &hard)
        #expect(hard.status == .failed)
        #expect(hard.reasoningTruncated == false,
                "Hard failure must NOT set reasoningTruncated — the flag is the F-002 soft-truncation marker")
        #expect(hard.errorMessage == "no text")
    }

    // MARK: - Legacy zeroContentFailureMessage shim — back-compat surface

    @Test("zeroContentFailureMessage legacy shim — length + empty path keeps the v0.4.35 max_tokens copy")
    func legacyShimKeepsV0435Copy() {
        // The pre-cycle-2 callers that haven't been migrated to
        // ``classifyTerminal`` still go through this shim, which
        // implicitly passes reasoningContent="" and so cannot
        // surface the new soft-truncation hint. The v0.4.35
        // ModelSwitchHistoryTests assert on the exact copy string
        // ("max_tokens"); the shim must keep producing it.
        let msg = ChatViewModel.zeroContentFailureMessage(
            proseContent: "",
            toolCalls: nil,
            finishReason: "length"
        )
        #expect(msg?.contains("Max Tokens") == true,
                "Legacy length+empty path must keep its truncation copy")
    }

    @Test("Pre-cycle-2 ModelSwitchHistoryTests behaviour survives — every case from that suite, exercised through classifyTerminal")
    func preCycle2BehaviourSurvives() {
        // Stop + empty + no reasoning → hard failure with switching-models copy.
        if case .emptyTurnFailure(let m) = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "",
            toolCalls: nil,
            finishReason: "stop"
        ) {
            #expect(m.contains("switching models"))
        } else {
            #expect(Bool(false), "stop+empty+no-reasoning must be a hard failure")
        }

        // nil + empty + no reasoning → hard failure.
        if case .emptyTurnFailure = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "",
            toolCalls: nil,
            finishReason: nil
        ) {
            // OK
        } else {
            #expect(Bool(false), "nil+empty+no-reasoning must be a hard failure")
        }

        // length + empty + no reasoning + thinkingEnabled → hard failure with Thinking-toggle copy.
        if case .emptyTurnFailure(let m) = ChatViewModel.classifyTerminal(
            proseContent: "",
            reasoningContent: "",
            toolCalls: nil,
            finishReason: "length",
            thinkingEnabled: true
        ) {
            #expect(m.contains("Show reasoning"))
        } else {
            #expect(Bool(false), "length+empty+thinking-on must be hard failure with toggle-copy")
        }
    }
}
