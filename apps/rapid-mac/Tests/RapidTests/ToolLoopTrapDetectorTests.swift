import Foundation
import Testing
@testable import Rapid

/// Contract for ``ChatViewModel.detectToolLoopTrap`` + the
/// model-aware cap-hit copy added in #185. Detector fires on EITHER
/// signal (static known-bad alias list OR shape: 3+ consecutive
/// same-name tool calls in the current turn with zero content
/// produced), and we keep the existing terse cap-hit caption for
/// generally-capable models that legitimately ran out of rounds.
///
/// Tests are pure functions over ``alias`` + a slice of assistant
/// ``ChatMessage`` so the contract pins without standing up the
/// async tool-call loop.
@MainActor
@Suite("ChatViewModel.detectToolLoopTrap branches on alias OR shape (#185)")
struct ToolLoopTrapDetectorTests {

    // MARK: - Test fixtures

    /// One assistant turn whose only output was a single tool call
    /// named ``name`` (no synthesised prose, no reasoning text). The
    /// shape detector reads this stream of placeholders.
    private static func assistantToolCall(name: String) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "",
            status: .complete,
            toolCalls: [ToolCall(id: "call_\(UUID().uuidString.prefix(6))", name: name, arguments: "{}")]
        )
    }

    private static func assistantWithContent(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, status: .complete)
    }

    /// Convenience: pull the looping tool name out of a verdict so a
    /// single assertion can check both the trap-fired bit AND the
    /// named tool. Returns ``nil`` when not trapped.
    private static func loopingName(_ v: ChatViewModel.ToolLoopTrapVerdict) -> String? {
        if case let .trapped(name, _) = v { return name }
        return nil
    }

    /// Same shape, for the run length so the cap-hit copy assertion
    /// can check the count is the actual run length, not the cap.
    private static func runLength(_ v: ChatViewModel.ToolLoopTrapVerdict) -> Int? {
        if case let .trapped(_, length) = v { return length }
        return nil
    }

    // MARK: - (a) static known-bad alias list

    @Test("alias on the known-bad list trips the detector regardless of message shape")
    func returnsTrueForGptOss20bAlias() {
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "gpt-oss-20b-mxfp4-q8",
            turnAssistantMessages: [Self.assistantToolCall(name: "web_search")]
        )
        #expect(v == .trapped(loopingToolName: "web_search", loopingRunLength: 1))

        // Even an empty turn slice is enough — the alias alone is
        // intrinsic evidence per Rapid-MLX #592. The detector must
        // not require shape corroboration when the model is on
        // the static list. Both name and run length are nil here;
        // the cap-hit branch falls through to its last-call name
        // and the cap value for the rendered copy.
        let vEmpty = ChatViewModel.detectToolLoopTrap(
            alias: "gpt-oss-20b-mxfp4-q8",
            turnAssistantMessages: []
        )
        #expect(vEmpty == .trapped(loopingToolName: nil, loopingRunLength: nil))
    }

    // MARK: - (b) shape-based detection

    @Test("3+ consecutive same-name tool calls + zero content → trap (shape signal)")
    func returnsTrueForShape_threeSameNameToolCalls() {
        // qwen3.5-9b-4bit is NOT on the known-bad list, so the only
        // way the detector fires here is via the shape clause.
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(v == .trapped(loopingToolName: "web_search", loopingRunLength: 3))
    }

    @Test("cap-hit on a generally-capable model with mixed tools → no trap")
    func returnsFalseForGenericCapHit() {
        // The healthy-but-stubborn case: model used multiple
        // different tools across the turn, never settled on one
        // name 3+ times in a row, and the user just exhausted the
        // budget. Keep the existing terse caption — the trap
        // copy would be actively misleading here.
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "calculator"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "datetime"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.6-27b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(v == .notTrapped)
    }

    @Test("any non-empty content earlier in the turn breaks the trap signal")
    func returnsFalseWhenContentPresent() {
        // The model DID synthesise a partial answer at some point
        // in the turn, then went back to searching. That's not
        // the "never produces final answer" trap — the user got
        // SOMETHING. Generic cap-hit copy is the right call here
        // even if the trailing 3 turns all called web_search.
        let msgs: [ChatMessage] = [
            Self.assistantWithContent("Based on the search, "),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(v == .notTrapped)
    }

    @Test("only two consecutive same-name tool calls is below the shape threshold")
    func returnsFalseForFewerThanThreeRepeats() {
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(v == .notTrapped)
    }

    @Test("a different tool name between two same-name calls resets the run-length")
    func returnsFalseWhenInterleavedToolBreaksRun() {
        // web_search, calculator, web_search, web_search — longest
        // consecutive same-name run is 2 (the trailing pair). Below
        // the 3-threshold so the trap does not fire.
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "calculator"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(v == .notTrapped)
    }

    // MARK: - Looping-tool-name correctness (codex r1 P3)

    @Test("shape signal names the looping tool even when a different tool ran last")
    func loopingToolIsTheRepeatedOneNotTheLatest() {
        // web_search × 3 → calculator. The detector must blame
        // ``web_search`` (the repeated run), not the most-recent
        // ``calculator``. Previously this fell out of the
        // ``calls.last`` shortcut at the cap-hit branch and would
        // have told the user to disable a tool that ran exactly
        // once.
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "calculator"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(Self.loopingName(v) == "web_search")
    }

    @Test("alias signal also names the longest-run tool, not the latest call")
    func aliasSignalReportsLongestRunNotLatest() {
        // On the static known-bad alias list the detector fires
        // unconditionally, but the rendered copy still needs the
        // right tool name. Same mixed-tail fixture as the shape
        // case — must point at web_search, not calculator.
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "calculator"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "gpt-oss-20b-mxfp4-q8",
            turnAssistantMessages: msgs
        )
        #expect(Self.loopingName(v) == "web_search")
    }

    @Test("run length reflects the actual same-name run, not the cap (codex r2 P3)")
    func runLengthIsActualRunNotCap() {
        // Mixed cap-hit: 3 web_search calls then a calculator. The
        // run is 3, but ``maxToolRounds`` is 10. The cap-hit copy
        // must say "called web_search 3 times", not "10 times".
        let msgs: [ChatMessage] = [
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "web_search"),
            Self.assistantToolCall(name: "calculator"),
        ]
        let v = ChatViewModel.detectToolLoopTrap(
            alias: "qwen3.5-9b-4bit",
            turnAssistantMessages: msgs
        )
        #expect(Self.runLength(v) == 3)
    }

    // MARK: - Cap-hit user-visible message contract

    @Test("trap message names the looping tool and a recommended alternate alias")
    func capHitMessageIncludesRecommendedAlternateAlias() {
        // Optional end-to-end shape from the issue body: a cap-hit
        // session on gpt-oss-20b should land copy that mentions a
        // recommended alternate (one of the three known-good
        // tool-use models in ``toolLoopRecommendedAliases``) AND
        // names the tool that was looping. Locks the user-visible
        // contract so a future copy refactor can't silently strip
        // the actionable bits.
        // No explicit callCount → falls back to cap. This is the
        // "alias-list fires on a turn we couldn't measure" edge
        // (e.g. empty turn slice) — the cap is the best we have.
        let copy = ChatViewModel.toolLoopTrapMessage(
            cap: 10,
            loopingToolName: "web_search"
        )
        #expect(copy.contains("web_search"))
        #expect(copy.contains("10"))
        // At least one of the recommended alternates must show up
        // in the rendered message — the user needs an actionable
        // model name to switch to. The PR brief calls out
        // qwen3.5-9b-4bit explicitly as the must-have alternate.
        #expect(copy.contains("qwen3.5-9b-4bit"))
        // The copy must point at the cap value through the formatter,
        // not a hard-coded literal — confirm by passing a different
        // cap and checking the number flows through.
        let altCap = ChatViewModel.toolLoopTrapMessage(
            cap: 7,
            loopingToolName: "web_search"
        )
        #expect(altCap.contains("7"))
    }

    @Test("explicit callCount overrides cap in the rendered copy (codex r2 P3)")
    func explicitCallCountOverridesCap() {
        // Shape-detected trap on a mixed sequence reports
        // ``loopingRunLength = 3`` while the cap is 10. The copy
        // must say "called web_search 3 times", and crucially must
        // NOT also say "10 times" — that would be wrong (and
        // contradictory) for the same tool.
        let copy = ChatViewModel.toolLoopTrapMessage(
            cap: 10,
            loopingToolName: "web_search",
            callCount: 3
        )
        #expect(copy.contains("called web_search 3 times"))
        #expect(!copy.contains("10 times"))
    }
}
