import Foundation
import Testing
@testable import Rapid

/// Cycle-8 (2026-06-19) regression pin for the chat-view tool-dispatch
/// placeholder bug filed by cycle-6 fuzz-correctness F-CORR-3.
///
/// Symptom: an assistant turn that finishes with ``finish_reason ==
/// "tool_calls"`` and no preamble prose (e.g. gemma-4-26b's behaviour
/// — emits a ``tool_calls`` envelope with ``content == ""`` and no
/// ``reasoning_content``) used to land in the chat view with no
/// caption above the tool-call chip(s). The chip alone reads as
/// debug metadata; the user sees "an empty bubble for ~1-2 seconds"
/// before the tool result arrives. Pre-cycle-8 there was no text
/// affordance to communicate "the model is dispatching a tool right
/// now" for this empty-content path.
///
/// Fix:
/// ``ChatMessage.toolDispatchPlaceholderCaption(content:reasoning:toolCalls:settledToolCallIDs:)``
/// returns a human-readable "Calling <name>…" caption (with
/// grammatical agreement for multiple calls) that the chat view
/// renders above the ``ToolCallChip`` row whenever the assistant
/// message lands in the empty-content + non-empty tool_calls shape
/// — STREAMING or COMPLETE — and clears the caption the moment
/// every dispatched call's result row arrives in the transcript
/// (codex r1 BLOCKING handoff fix). Partial settlement keeps the
/// placeholder up but lists ONLY pending call names.
///
/// Distinct from PR #317's ``reasoningTruncated`` fallback (which
/// covers ``finish_reason == "length"`` mid-think with empty content
/// + populated reasoning): F-CORR-3 covers ``finish_reason ==
/// "tool_calls"`` with empty content + populated ``tool_calls``.
/// The helper is structural — it doesn't try to infer "tool-call
/// dispatch" from ``finish_reason`` (the row in flight doesn't have
/// one yet); it keys on the message shape.
@MainActor
@Suite("Cycle-8 tool-call dispatch placeholder (chat-view F-CORR-3)")
struct ToolCallDispatchPlaceholderTests {

    // MARK: - Helper input shapes used across the test cases

    private func makeCall(name: String, args: String = "{}") -> ToolCall {
        ToolCall(id: "call_\(name)_\(UUID().uuidString.prefix(6))", name: name, arguments: args)
    }

    // MARK: - Case (a): content non-empty → no placeholder

    @Test("Helper returns nil when assistant prose is non-empty (case a — normal reply)")
    func helperNilWhenContentPresent() {
        // A normal narrating assistant turn ("I'll call web_search for
        // you…") — the model HAS spoken, so the chat view renders the
        // prose body and the chip; no placeholder caption needed.
        let calls = [makeCall(name: "web_search")]
        let result = ChatMessage.toolDispatchPlaceholderCaption(
            content: "I'll search the web for that.",
            reasoning: "",
            toolCalls: calls
        )
        #expect(result == nil)
    }

    @Test("Helper returns nil when content is whitespace-only is also treated as non-empty? No — whitespace is empty")
    func helperWhitespaceContentIsEmpty() {
        // Whitespace-only ``content`` is functionally empty for the
        // user (nothing visible in the bubble). Treat the same as
        // ``""`` so a model that emits one trailing space + tool
        // call doesn't get an exception path.
        let calls = [makeCall(name: "web_search")]
        let result = ChatMessage.toolDispatchPlaceholderCaption(
            content: "   \n  ",
            reasoning: "",
            toolCalls: calls
        )
        #expect(result != nil, "Whitespace-only content must fall through to the placeholder, not be treated as visible prose.")
    }

    // MARK: - Case (b): reasoning present, content empty — DON'T regress PR #317

    @Test("Helper returns nil when reasoning is populated and content is empty (case b — PR #317 path is preserved)")
    func helperNilWhenReasoningPresent() {
        // Cycle-2 (PR #317) handles this shape via the reasoning
        // disclosure auto-expand. The placeholder must defer so the
        // two fallbacks don't double-paint.
        let calls = [makeCall(name: "web_search")]
        let result = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "Let me think about whether to search…",
            toolCalls: calls
        )
        #expect(result == nil, "Reasoning-populated path is owned by PR #317; placeholder must not paint here.")
    }

    // MARK: - Case (c): content empty + reasoning empty + tool_calls present → FIRE

    @Test("Helper returns 'Calling <name>…' for the canonical empty-content + single tool_call case")
    func helperFiresForSingleEmptyContentToolCall() {
        // The F-CORR-3 canonical shape: gemma-4-26b emits one
        // tool_call envelope with no preamble at all.
        let calls = [makeCall(name: "web_search")]
        guard let caption = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: calls
        ) else {
            #expect(Bool(false), "Helper must fire for the empty-content + tool_call shape (F-CORR-3 root cause).")
            return
        }
        // Caption MUST name the tool so the user knows what's
        // happening — "Calling…" alone reads as a spinner; "Calling
        // web_search…" reads as a specific dispatch.
        #expect(caption.contains("web_search"),
                "Caption must name the tool the model dispatched; got: \(caption)")
        // Must read as an in-flight action verb (present participle
        // or active "Calling …"). Pin against accidental rewrites
        // that drop the verb into a label-only shape.
        let lower = caption.lowercased()
        #expect(lower.contains("call") || lower.contains("running") || lower.contains("invok"),
                "Caption must use an action verb so the user sees motion; got: \(caption)")
        // Ellipsis (the figure-character ``…`` OR three dots) so the
        // copy reads as in-flight. Without it the line looks like a
        // completed status, not a pending dispatch.
        #expect(caption.contains("…") || caption.contains("..."),
                "Caption must end with an ellipsis to signal in-flight dispatch; got: \(caption)")
    }

    @Test("Helper names every tool when the assistant dispatches multiple in one envelope")
    func helperListsAllToolsForParallelDispatch() {
        // Some models emit multiple tool_calls in one envelope (e.g.
        // gpt-oss-20b's "search the web and check the weather"
        // route). The placeholder must surface every name so the
        // user sees the full dispatch, not just the first.
        let calls = [
            makeCall(name: "web_search"),
            makeCall(name: "weather"),
        ]
        guard let caption = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: calls
        ) else {
            #expect(Bool(false), "Helper must fire for multi-tool dispatch too.")
            return
        }
        #expect(caption.contains("web_search"),
                "Caption must include the first tool name; got: \(caption)")
        #expect(caption.contains("weather"),
                "Caption must include the second tool name; got: \(caption)")
    }

    // MARK: - Case (d): degenerate empty everything → nil (no placeholder, no false signal)

    @Test("Helper returns nil when EVERY field is empty / nil (case d — degenerate)")
    func helperNilWhenEverythingEmpty() {
        // Pre-classifyTerminal arrival (or the stream never produced
        // anything). This must NOT manufacture a placeholder out of
        // thin air — that would lie about the model's behaviour.
        let result: String? = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: nil
        )
        #expect(result == nil)

        let result2: String? = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: []
        )
        #expect(result2 == nil)
    }

    // MARK: - Hardening: control-character / injection safety for tool name

    @Test("Helper sanitises the tool name so a malicious server cannot inject control characters into the caption")
    func helperSanitisesToolName() {
        // Defence-in-depth — a malicious server (or a crash-corrupted
        // SSE chunk) could land a ``\u{0000}`` or ``\u{200E}`` (RTL
        // mark) in the function name. The placeholder ultimately
        // feeds a ``Text`` view; pre-sanitising here keeps the
        // caption from rendering control-character noise OR flipping
        // the bidi context for everything downstream.
        let dirtyName = "web_search\u{0000}\u{202E}drop"
        let calls = [makeCall(name: dirtyName)]
        guard let caption = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: calls
        ) else {
            #expect(Bool(false), "Helper must fire for the empty-content + tool_call shape even when the name carries control chars.")
            return
        }
        // No NUL, no bidi override.
        #expect(!caption.unicodeScalars.contains(where: { $0.value == 0x0000 }),
                "Caption must strip NUL; got: \(caption.debugDescription)")
        #expect(!caption.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }),
                "Caption must strip bidi-override controls; got: \(caption.debugDescription)")
        // The visible suffix of the name (after the NUL strip) must
        // still be readable — the user shouldn't see a randomly
        // truncated name just because a control char snuck in.
        #expect(caption.contains("web_search"),
                "Caption must keep the visible portion of the name; got: \(caption)")
    }

    // MARK: - Hardening: don't be fooled by a tool result message

    @Test("Helper ignores the .tool role — the caller is responsible for only invoking it on assistant rows")
    func helperContractIsCallerFacing() {
        // The helper takes raw (content, reasoning, toolCalls) so it
        // is reusable from contexts other than ``ChatMessage`` itself
        // (the view layer passes the row's fields straight through).
        // The CALLER is responsible for only invoking on assistant
        // rows — pin that explicitly here so a future refactor that
        // wires the helper to ``.tool`` messages by mistake gets
        // caught by review, not by a confused user.
        //
        // This test is documentation: the helper accepts whatever you
        // pass it. The view-layer integration test below is what pins
        // the role gate.
        let captionFromAssistantShape = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [makeCall(name: "web_search")]
        )
        #expect(captionFromAssistantShape != nil,
                "Sanity check: helper returns non-nil for the canonical empty-content + tool_call shape.")
    }

    // MARK: - Codex r1 BLOCKING-1: handoff to ToolCallChip when results arrive

    @Test("Helper drops the placeholder once EVERY dispatched call has a tool-result row (single-call handoff)")
    func placeholderClearsWhenSingleCallSettles() {
        // The F-CORR-3 root user experience: the placeholder is a
        // FILLER for the 1-2 second window between the assistant's
        // tool_calls envelope landing and the tool result coming
        // back. Once the result row is in the transcript, the
        // ``ToolCallChip`` flips to a checkmark + result body — a
        // lingering "Calling web_search…" caption above it would lie
        // about the dispatch still being in flight. Pin the
        // single-call settlement → caption clears.
        let call = makeCall(name: "web_search")
        let captionBefore = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [call],
            settledToolCallIDs: []
        )
        #expect(captionBefore != nil,
                "Sanity: placeholder fires before the result lands.")
        let captionAfter = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [call],
            settledToolCallIDs: [call.id]
        )
        #expect(captionAfter == nil,
                "Once the call's result lands, the chip owns the bubble — the caption must vanish; got: \(captionAfter ?? "<nil>")")
    }

    @Test("Helper drops the placeholder when ALL parallel calls have settled")
    func placeholderClearsWhenAllParallelCallsSettle() {
        // Multi-call dispatch (gpt-oss-20b's "search and weather"
        // route). Caption stays up while ANY call is pending; the
        // moment the LAST result lands, the chip row tells the full
        // story and the caption must step aside.
        let a = makeCall(name: "web_search")
        let b = makeCall(name: "weather")
        let captionAllPending = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [a, b],
            settledToolCallIDs: []
        )
        #expect(captionAllPending != nil)

        let captionAllSettled = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [a, b],
            settledToolCallIDs: [a.id, b.id]
        )
        #expect(captionAllSettled == nil,
                "Both calls settled — chip row owns the bubble; got: \(captionAllSettled ?? "<nil>")")
    }

    @Test("Helper keeps the placeholder up for partial settlement (one call back, one still pending)")
    func placeholderStaysOnPartialSettlement() {
        // The intermediate state: one parallel call's result has
        // landed (chip flipped to checkmark) but the other is still
        // in flight. The placeholder must stay up so the user still
        // sees the in-flight signal for the pending call. The
        // caption also lists ONLY the pending call so the line reads
        // honestly ("Calling weather…" — not "Calling web_search,
        // weather…" because web_search already finished).
        let a = makeCall(name: "web_search")
        let b = makeCall(name: "weather")
        let caption = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [a, b],
            settledToolCallIDs: [a.id]
        )
        guard let caption else {
            #expect(Bool(false), "Partial settlement must keep the placeholder up; got nil.")
            return
        }
        #expect(caption.contains("weather"),
                "Caption must still name the pending call; got: \(caption)")
        #expect(!caption.contains("web_search"),
                "Caption must NOT name the already-settled call; got: \(caption)")
    }

    @Test("Default settledToolCallIDs is empty — old callers keep the all-in-flight semantics")
    func defaultSettledSetIsEmpty() {
        // Back-compat: callers that don't pass the new argument get
        // the pre-codex-r1 behaviour (no settlement). Pin this
        // explicitly so a future "default to all settled" refactor
        // can't silently turn the helper into a constant-nil function.
        let call = makeCall(name: "web_search")
        let caption = ChatMessage.toolDispatchPlaceholderCaption(
            content: "",
            reasoning: "",
            toolCalls: [call]
        )
        #expect(caption != nil,
                "Default-argument call must behave like all-pending.")
    }
}
