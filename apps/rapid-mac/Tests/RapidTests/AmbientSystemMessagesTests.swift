import Foundation
import Testing
@testable import Rapid

/// v0.6.4 — coverage for the ambient-system-message composition that
/// fixes the chat-surface confabulation bug.
///
/// User-reported 2026-06-15: qwen3.5-9b-4bit fabricated 8 group-stage
/// World Cup match results (Italy, Russia, Sweden — none of whom
/// qualified for 2026) after firing `web_search`. The unit-isolated
/// /v1/chat/completions probe with the same DDG fixture answered
/// correctly, so the bug was the chat-surface flow: when the user
/// hasn't set a per-session system prompt AND tools are advertised,
/// nothing nudges the model away from confabulation.
///
/// `ChatViewModel.ambientSystemMessages` now prepends a
/// `toolGuidancePreamble` whenever tools are on the wire, with the
/// user's per-session prompt (if any) coming AFTER so it always has
/// the final word.
///
/// These tests pin the contract — the chat-surface call site reads as
/// a single `history.insert(contentsOf: ambientSystemMessages(...))`
/// and the verifier here proves that helper produces the right
/// prefix in every combination.
@MainActor
@Suite("v0.6.4 ambient tool-guidance system message")
struct AmbientSystemMessagesTests {

    @Test("Tools advertised, no session prompt: emits exactly the tool guidance row")
    func toolsOnlyEmitsGuidance() {
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: nil,
            historyOpensWithSystem: false,
            toolsAdvertised: true
        )
        #expect(prefix.count == 1)
        #expect(prefix[0].role == .system)
        #expect(prefix[0].content == ChatViewModel.toolGuidancePreamble)
    }

    @Test("Tools advertised AND session prompt set: single concatenated system row")
    func toolsPlusSessionPromptConcatenated() {
        // Codex r1 #177 finding: a SECOND leading system row gets
        // walked as body content by ``trimMessagesForContextWindow``,
        // so the user's session prompt was being silently dropped on
        // any tool-enabled chat that overflowed the context window —
        // even though the ambient guidance row stayed. Concatenate
        // into one row so the trim is lossless.
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: "You speak only in haiku.",
            historyOpensWithSystem: false,
            toolsAdvertised: true
        )
        #expect(prefix.count == 1)
        #expect(prefix[0].role == .system)
        // Order: guidance FIRST, user prompt AFTER. Chat templates
        // treat "later instructions override earlier" as natural
        // priority, so a power user who wants the model to roleplay
        // or brainstorm freely has the last word.
        let content = prefix[0].content
        #expect(content.hasPrefix(ChatViewModel.toolGuidancePreamble))
        #expect(content.hasSuffix("You speak only in haiku."))
        #expect(content.contains("\n\n"))
    }

    @Test("Whitespace-only session prompt with tools: just the guidance, no spurious newlines")
    func whitespaceOnlySessionPromptIgnoredButGuidanceKept() {
        // Codex r1 #177 follow-up: an empty-after-trim session prompt
        // must not concatenate as ``preamble + "\n\n" + ""`` —
        // trailing whitespace bloats the context window and shows up
        // in token-counter telemetry as noise.
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: "   \n\n  ",
            historyOpensWithSystem: false,
            toolsAdvertised: true
        )
        #expect(prefix.count == 1)
        #expect(prefix[0].content == ChatViewModel.toolGuidancePreamble)
    }

    @Test("No tools, session prompt set: only the user prompt is emitted")
    func sessionPromptOnly() {
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: "Be terse.",
            historyOpensWithSystem: false,
            toolsAdvertised: false
        )
        #expect(prefix.count == 1)
        #expect(prefix[0].role == .system)
        #expect(prefix[0].content == "Be terse.")
    }

    @Test("Resumed transcript already opens with a system row: no prepend, ever")
    func historyOpensWithSystemSuppressesEverything() {
        // Some future feature (saved prompt template, MCP-injected
        // system, etc.) might lead the rehydrated transcript to start
        // with a system row. Skip our prepend in that case — two
        // competing system rows are worse than letting the user's
        // explicit one win.
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: "Be terse.",
            historyOpensWithSystem: true,
            toolsAdvertised: true
        )
        #expect(prefix.isEmpty)
    }

    @Test("No tools, no session prompt: empty prefix")
    func noToolsNoPromptEmitsNothing() {
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: nil,
            historyOpensWithSystem: false,
            toolsAdvertised: false
        )
        #expect(prefix.isEmpty)
    }

    @Test("Empty session prompt is treated as no prompt")
    func emptySessionPromptCountsAsAbsent() {
        let prefix = ChatViewModel.ambientSystemMessages(
            sessionPrompt: "",
            historyOpensWithSystem: false,
            toolsAdvertised: true
        )
        #expect(prefix.count == 1)
        #expect(prefix[0].content == ChatViewModel.toolGuidancePreamble)
    }

    @Test("toolGuidancePreamble names every load-bearing rule")
    func preambleNamesEveryRule() {
        // The preamble's text is the contract. If the rules drift
        // we want the test to flag it — fewer cases than a full
        // string match (which would churn every wording tweak)
        // but enough that "we forgot to forbid enumerating lists
        // from memory" doesn't ship silently.
        //
        // Strengthened 2026-06-15 after qwen3.6-27b-4bit + weak DDG
        // English snippets reproduced the original fabrication shape
        // (48-team list invented, mid-stream "更正:" self-corrections).
        // Empirical sweep showed sampling tweaks didn't fix it — the
        // preamble is the only effective lever. The new text must
        // explicitly OVERRIDE training data and forbid enumerating
        // lists from memory, so we pin those marker phrases here.
        let p = ChatViewModel.toolGuidancePreamble
        #expect(p.contains("OVERRIDE your training data"))  // headline — load-bearing assertion
        #expect(p.contains("ONLY source of truth"))         // rule 1 — grounding
        #expect(p.contains("NEVER enumerate a list"))       // rule 2 — no list-from-memory
        #expect(p.contains("Forbidden phrases"))            // rule 3 — phrase blocklist
        #expect(p.contains("partial coverage"))             // rule 4 — list ONLY what is present
        #expect(p.contains("clarifying"))                   // rule 5 — ambiguity → clarify
        #expect(p.contains("STOP"))                         // rule 6 — bail out + re-query
    }
}
