import Foundation
import Testing
@testable import Rapid

/// Pin the wire-side tools-strip for aliases empirically broken at
/// tool-calling. The compose-row Tools chip disabling (see
/// ``ToolUseCapabilityTests``) is the cosmetic half of the cycle-12
/// F-11-5 fix; this suite covers the load-bearing half — the
/// request body MUST NOT carry tools when the model is going to
/// silently ignore them or schema-leak the wrapper.
///
/// Codex round 1 finding: without this strip, the chip-disable
/// alone is a UX-only mitigation — ``runToolLoop`` still reads
/// ``enabledDefinitions`` directly and ships them, so a user who
/// uses Cmd+Enter shortcuts or the API path still hits the broken
/// model with tools. The static ``ChatViewModel.wireDefinitions``
/// helper is the testable seam.
@Suite("ChatViewModel.wireDefinitions — wire-side strip for broken aliases")
struct ChatViewModelWireToolsForBrokenAliasTests {

    /// Synthetic tool definition for the test fixtures. Shape mirrors
    /// what ``ToolRegistry.definitions`` returns at runtime — we don't
    /// care which specific tools live in the registry, only that the
    /// strip removes them entirely (or leaves them entirely intact).
    private static let fakeTools: [ToolDefinition] = [
        ToolDefinition(
            name: "fake_calculator",
            description: "stub tool 1",
            parameters: .object(["type": .string("object")])
        ),
        ToolDefinition(
            name: "fake_weather",
            description: "stub tool 2",
            parameters: .object(["type": .string("object")])
        ),
    ]

    @Test("phi-4-mini-reasoning-4bit (F-11-5) → wire tools are stripped to []")
    func phi4MiniReasoningStripped() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "phi-4-mini-reasoning-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "Cycle-11 F-11-5: phi-4-mini-reasoning silently ignores tools; request must not advertise them.")
    }

    @Test("hermes3-8b-4bit (cycle-4 F-1) → wire tools are stripped to []")
    func hermes3_8bStripped() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "hermes3-8b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "Cycle-4 F-1: hermes3-8b never emits <tool_call> for auto tool_choice; request must not advertise tools.")
    }

    @Test("llama3-1b-4bit (cycle-9 F9-001) → wire tools are stripped to []")
    func llama3_1bStripped() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "llama3-1b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "Cycle-9 F9-001: llama3-1b schema-leaks JSON-Schema wrapper into function.arguments; request must not advertise tools.")
    }

    // MARK: - 2026-07-09 recommended-model tool-usability sweep

    @Test("phi-4-mini-4bit (2026-07-09: refuses tools) → wire tools stripped to []")
    func phi4MiniInstructStripped() {
        // The non-reasoning phi-4-mini flatly refuses every tool-eligible
        // prompt (6/6 "I can't assist with that") — distinct from the
        // -reasoning sibling's silent-ignore, same wire remedy.
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "phi-4-mini-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "2026-07-09 sweep: phi-4-mini refuses tool-eligible prompts; request must not advertise tools.")
    }

    @Test("deepseek-coder-v2-lite-16b-4bit (2026-07-09: 6/6 leak) → wire tools stripped to []")
    func deepseekCoderV2LiteStripped() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "deepseek-coder-v2-lite-16b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "2026-07-09 sweep: parser=None + invented tool names → 6/6 raw envelope leak; request must not advertise tools.")
    }

    @Test("deepseek-r1-8b-4bit (2026-07-09 F3: 4/8 leak) → wire tools stripped to []")
    func deepseekR1_8bStripped() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "deepseek-r1-8b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "2026-07-09 F3: R1-8B distill invents a JSON schema per run → 4/8 leak; request must not advertise tools.")
    }

    @Test("devstral-v2-24b-4bit (Mistral parser now bundled) → wire tools pass through")
    func devstralV2ToolsPassThrough() {
        // The 2026-07-09 Cat-B strip was a PARSER MISCONFIG stopgap, not
        // model incapacity — the model emits a textbook
        // [TOOL_CALLS]…[ARGS]{…} call. The engine parser fix (rapid-mlx
        // #1071/#1077 — route the Mistral family to the mistral parser)
        // is NOW BUNDLED (submodule 7b6a787) and this alias re-benched
        // clean on the bundled engine (get_weather tool_call), so it is
        // .known again and the request must advertise tools.
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "devstral-v2-24b-4bit",
            enabled: Self.fakeTools
        )
        #expect(!wire.isEmpty, "Mistral parser is bundled now (7b6a787); devstral-v2-24b tool_calls parse cleanly, so tools must pass through.")
    }

    @Test("mistral-24b-4bit (Mistral parser now bundled) → wire tools pass through")
    func mistral24bToolsPassThrough() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "mistral-24b-4bit",
            enabled: Self.fakeTools
        )
        #expect(!wire.isEmpty, "Same family fix as devstral — mistral parser is bundled (7b6a787), so tools pass through.")
    }

    @Test("qwen3-coder-30b-4bit (new 25–36 Coding pick, swept 6/6) → wire tools pass through")
    func qwen3Coder30bUnchanged() {
        // The replacement for the dropped deepseek-coder-v2-lite. Verify
        // the strip does NOT touch it — it must keep advertising tools.
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "qwen3-coder-30b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.count == Self.fakeTools.count, "qwen3-coder-30b is .known (swept 6/6); tools must pass through.")
    }

    @Test("qwen3.5-4b (.known) → wire tools pass through unchanged")
    func qwen35_4bUnchanged() {
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "qwen3.5-4b",
            enabled: Self.fakeTools
        )
        #expect(wire.count == Self.fakeTools.count, ".known aliases must keep tools — would regress on a working model.")
        #expect(wire.map(\.function.name) == Self.fakeTools.map(\.function.name))
    }

    @Test("Unbenched alias (.unknown) → wire tools pass through unchanged")
    func unknownAliasUnchanged() {
        // Default for new aliases the loop hasn't covered. We do NOT
        // regress on .unknown — the user might be on a perfectly
        // working future model.
        let wire = ChatViewModel.wireDefinitions(
            forAlias: "future-7b-mxfp4",
            enabled: Self.fakeTools
        )
        #expect(wire.count == Self.fakeTools.count)
    }

    @Test("Empty alias → tools pass through (don't strip on bad inputs)")
    func emptyAliasUnchanged() {
        // ``ToolUseCapability.confidence(for: "")`` returns .unknown;
        // ``shouldDisableToolsChip`` returns false. Confirm the
        // wire helper doesn't accidentally clamp empty-alias to
        // .broken (e.g. via a String/prefix bug where "" matches
        // everything).
        let wire = ChatViewModel.wireDefinitions(forAlias: "", enabled: Self.fakeTools)
        #expect(wire.count == Self.fakeTools.count)
    }

    @Test("Empty enabled set → still returns empty (no synthesis)")
    func emptyInputEmptyOutput() {
        // Caller passes [] when the user has disabled every tool.
        // The strip must never SYNTHESISE tools; only remove them.
        let wire = ChatViewModel.wireDefinitions(forAlias: "qwen3.5-4b", enabled: [])
        #expect(wire.isEmpty)
    }

    @Test("Strip is identity-preserving on the order of definitions for non-broken aliases")
    func orderPreserved() {
        // The tool-loop's forced-tool snapshot logic depends on the
        // order surviving the wire layer. Confirm explicitly so a
        // future refactor that sorts/dedupes doesn't silently
        // reshuffle.
        let wire = ChatViewModel.wireDefinitions(forAlias: "qwen3.5-4b", enabled: Self.fakeTools)
        #expect(wire.map(\.function.name) == ["fake_calculator", "fake_weather"])
    }

    // MARK: - effectiveWireDefinitions (Quick Ask suppressTools override)

    @Test("suppressTools=true → [] even on a .known alias with enabled tools")
    func suppressToolsForcesEmptyOnKnownAlias() {
        // Quick Ask's contract: a launcher-style quick answer is
        // prose-only regardless of the enabled set or model capability.
        let wire = ChatViewModel.effectiveWireDefinitions(
            suppressTools: true,
            forAlias: "qwen3.5-4b",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "suppressTools must strip tools even when wireDefinitions would pass them through.")
    }

    @Test("suppressTools=false on a .known alias → identical to wireDefinitions (pass through)")
    func suppressToolsFalseDelegatesPassThrough() {
        let effective = ChatViewModel.effectiveWireDefinitions(
            suppressTools: false,
            forAlias: "qwen3.5-4b",
            enabled: Self.fakeTools
        )
        let base = ChatViewModel.wireDefinitions(forAlias: "qwen3.5-4b", enabled: Self.fakeTools)
        #expect(effective.map(\.function.name) == base.map(\.function.name),
                "suppressTools=false must be a pure delegate to wireDefinitions.")
        #expect(!effective.isEmpty)
    }

    @Test("suppressTools=false on a broken alias → still [] (delegates the strip)")
    func suppressToolsFalseStillStripsBrokenAlias() {
        let wire = ChatViewModel.effectiveWireDefinitions(
            suppressTools: false,
            forAlias: "hermes3-8b-4bit",
            enabled: Self.fakeTools
        )
        #expect(wire.isEmpty, "suppressTools=false must not resurrect tools that wireDefinitions strips for a broken alias.")
    }

    @Test("suppressTools=true with empty enabled set → [] (no synthesis)")
    func suppressToolsEmptyInputEmptyOutput() {
        let wire = ChatViewModel.effectiveWireDefinitions(
            suppressTools: true,
            forAlias: "qwen3.5-4b",
            enabled: []
        )
        #expect(wire.isEmpty)
    }

    // MARK: - toolRefusalMessage (codex MAJOR: gate dispatch, not just the request)

    @Test("suppressTools=true refuses a call even when the tool is NOT user-disabled")
    func suppressToolsRefusesHallucinatedCall() {
        // The load-bearing half of the Quick Ask fix: omitting `tools:`
        // from the request doesn't stop a malformed model emitting a
        // tool_call, and `tools.run` would execute it. The refusal must
        // fire for ANY call name when suppressTools is on.
        let msg = ChatViewModel.toolRefusalMessage(
            name: "web_search",
            suppressTools: true,
            disabledTools: []
        )
        #expect(msg != nil, "suppressTools must refuse a hallucinated tool call so tools.run never runs it.")
        #expect(msg?.contains("quick question") == true)
    }

    @Test("suppressTools=true takes precedence over the disabled-tool copy")
    func suppressToolsPrecedesDisabledCopy() {
        let msg = ChatViewModel.toolRefusalMessage(
            name: "calculator",
            suppressTools: true,
            disabledTools: ["calculator"]
        )
        // Quick Ask copy, not the "re-enable from the wrench menu" copy —
        // there is no wrench menu in the Quick Ask panel.
        #expect(msg?.contains("quick question") == true)
        #expect(msg?.contains("wrench") != true)
    }

    @Test("suppressTools=false + user-disabled tool → the disabled explainer (byte-exact, unchanged)")
    func disabledToolCopyPreserved() {
        // Assert the EXACT prior copy (codex r2 NIT): a substring check
        // would pass a wording regression that still mentions the tool
        // name and "disabled". Lock the whole string so the v0.4.1
        // contract can't silently drift when this branch was folded into
        // toolRefusalMessage.
        let msg = ChatViewModel.toolRefusalMessage(
            name: "web_search",
            suppressTools: false,
            disabledTools: ["web_search"]
        )
        #expect(msg == "tool 'web_search' is disabled in this conversation — re-enable it from the wrench menu in the compose bar to run it.")
    }

    @Test("suppressTools=false + enabled tool → nil (call is dispatched normally)")
    func enabledToolRunsNormally() {
        let msg = ChatViewModel.toolRefusalMessage(
            name: "web_search",
            suppressTools: false,
            disabledTools: ["calculator"]  // a DIFFERENT tool is off
        )
        #expect(msg == nil, "A non-suppressed, non-disabled tool must be allowed to run (nil = dispatch).")
    }
}
