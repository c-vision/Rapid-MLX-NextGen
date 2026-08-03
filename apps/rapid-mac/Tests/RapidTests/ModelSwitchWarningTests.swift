import Foundation
import Testing
@testable import Rapid

/// Pins the visibility predicate for the model-switch warning banner
/// (audit P1 `ChatView.swift:247-251`). The banner appears when the
/// picker alias diverges from the alias the active session was first
/// sent to AFTER the user has committed at least one turn — so the
/// user knows their next reply will be served by a different model
/// than the history was generated under, and that template / tool
/// behavior may shift.
@Suite("ModelSwitchWarning visibility predicate")
struct ModelSwitchWarningTests {

    private let sessionA = UUID()
    private let sessionB = UUID()

    private func inputs(
        active: UUID? = nil,
        session: String = "qwen3.6-35b-4bit",
        picker: String = "qwen3.6-35b-4bit",
        userMessages: Int = 0,
        dismissed: Set<UUID> = []
    ) -> ModelSwitchWarningInputs {
        ModelSwitchWarningInputs(
            activeSessionID: active,
            sessionAlias: session,
            pickerAlias: picker,
            userMessageCount: userMessages,
            dismissedSessionIDs: dismissed
        )
    }

    // MARK: - Negative cases (suppression)

    @Test("No active session ⇒ hidden — the banner has nothing to anchor to")
    func no_active_session_hides_banner() {
        let input = inputs(active: nil, session: "alpha", picker: "beta", userMessages: 3)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Zero user turns ⇒ hidden — picker change on a fresh session is just the initial choice")
    func empty_session_hides_banner_even_on_mismatch() {
        let input = inputs(active: sessionA, session: "alpha", picker: "beta", userMessages: 0)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Picker matches session alias exactly ⇒ hidden — no divergence to warn about")
    func exact_match_hides_banner() {
        let input = inputs(active: sessionA, session: "qwen", picker: "qwen", userMessages: 5)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Empty session alias ⇒ hidden — 'earlier turns were sent to (empty)' is nonsense copy")
    func empty_session_alias_hides_banner() {
        let input = inputs(active: sessionA, session: "", picker: "qwen", userMessages: 2)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Empty picker alias ⇒ hidden — no concrete next-turn target to surface")
    func empty_picker_alias_hides_banner() {
        let input = inputs(active: sessionA, session: "qwen", picker: "", userMessages: 2)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Whitespace-only aliases trimmed to empty ⇒ hidden — defensive against stored garbage")
    func whitespace_only_alias_hides_banner() {
        let input = inputs(active: sessionA, session: "   ", picker: "qwen", userMessages: 2)
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Capitalization/whitespace-only difference ⇒ hidden — sloppy stored history not a real switch")
    func case_insensitive_match_hides_banner() {
        let input = inputs(
            active: sessionA,
            session: "  Qwen3.6-35B-4bit  ",
            picker: "qwen3.6-35b-4bit",
            userMessages: 3
        )
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("User dismissed this session ⇒ hidden — even if mismatch persists")
    func dismissed_session_hides_banner() {
        let input = inputs(
            active: sessionA,
            session: "qwen",
            picker: "gpt-oss-20b",
            userMessages: 4,
            dismissed: [sessionA]
        )
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    @Test("Dismissal is per-session — a dismissal on session B does not silence session A")
    func dismissal_is_scoped_per_session() {
        let input = inputs(
            active: sessionA,
            session: "qwen",
            picker: "gpt-oss-20b",
            userMessages: 4,
            dismissed: [sessionB]
        )
        #expect(ModelSwitchWarning.shouldShow(input) == true)
    }

    // MARK: - Quant-suffix equivalence (codex r1 BLOCKING-1)

    /// `family-size-4bit` → `family-size-8bit` swaps precision but
    /// keeps chat template / tool support / context formatting
    /// identical. The banner copy explicitly cites those three things
    /// as "what could differ" — firing on a quant-only delta would be
    /// a false alarm. The predicate strips the documented quant
    /// suffixes (`-2bit`/`-4bit`/`-6bit`/`-8bit`/`-mxfp4`/`-mxfp4-q8`/
    /// `-ud`/`-dwq`) before comparison.
    @Test("Quant-only delta on identical family+size ⇒ hidden — same model, different precision")
    func quant_only_delta_hides_banner() {
        let pairs: [(String, String)] = [
            ("qwen3.6-35b-4bit", "qwen3.6-35b-8bit"),
            ("qwen3.6-35b-4bit", "qwen3.6-35b-mxfp4"),
            ("qwen3.6-35b-mxfp4", "qwen3.6-35b-mxfp4-q8"),
            ("deepseek-v4-flash-2bit", "deepseek-v4-flash-4bit"),
            ("qwen3.6-35b-4bit", "qwen3.6-35b-dwq"),
            ("qwen3.6-35b-4bit", "qwen3.6-35b-ud"),
            // Codex r2 BLOCKING: `kimi-k2.5-3bit` ships in
            // `vllm_mlx/aliases.json`. Strip must cover `-3bit` so a
            // future `kimi-k2.5-4bit` sibling doesn't false-positive.
            ("kimi-k2.5-3bit", "kimi-k2.5-4bit"),
            ("kimi-k2.5-3bit", "kimi-k2.5-8bit"),
            // Codex r3 BLOCKING: Gemma 4 ships sibling pairs where
            // the QAT-trained variant and the standard variant of the
            // same family+size are interchangeable from a chat-template
            // / tool-support standpoint. The `-qat-4bit` / `-qat-8bit`
            // suffixes MUST sit ahead of bare `-4bit` / `-8bit` in
            // the strip list or the longer suffix gets eaten by the
            // shorter one and the predicate false-fires.
            ("gemma-4-12b-4bit", "gemma-4-12b-qat-4bit"),
            ("gemma-4-12b-4bit", "gemma-4-12b-qat-8bit"),
            ("gemma-4-26b-4bit", "gemma-4-26b-qat-4bit"),
            ("gemma-4-31b-4bit", "gemma-4-31b-qat-8bit"),
            ("gemma-4-31b-qat-4bit", "gemma-4-31b-qat-8bit"),
            // Codex r4 BLOCKING: `bonsai-{1.7b,4b,8b}-unpacked` ships
            // as a packaging variant. Same family+size, same chat
            // template; if a future `bonsai-4b-4bit` lands as a
            // sibling the strip must collapse both to `bonsai-4b`.
            ("bonsai-4b-unpacked", "bonsai-4b-4bit"),
            ("bonsai-1.7b-unpacked", "bonsai-1.7b-8bit"),
        ]
        for (session, picker) in pairs {
            let input = inputs(active: sessionA, session: session, picker: picker, userMessages: 3)
            #expect(ModelSwitchWarning.shouldShow(input) == false,
                    "\(session) → \(picker) is quant-only and should not warn")
        }
    }

    @Test("Compound `-mxfp4-q8` strips before bare `-mxfp4` so order doesn't false-positive")
    func compound_quant_suffix_orders_correctly() {
        // If the predicate stripped `-mxfp4` first it would leave
        // `qwen-q8` vs `qwen` and fire the warning. The longest-first
        // ordering of `knownQuantSuffixes` is the load-bearing
        // invariant we're pinning here.
        let input = inputs(
            active: sessionA,
            session: "qwen3.6-35b-mxfp4-q8",
            picker: "qwen3.6-35b-mxfp4",
            userMessages: 2
        )
        #expect(ModelSwitchWarning.shouldShow(input) == false)
    }

    // MARK: - Positive cases (show)

    @Test("Family mismatch on the very first user turn ⇒ shown — earliest possible signal")
    func family_mismatch_fires_at_first_turn() {
        let input = inputs(
            active: sessionA,
            session: "qwen3.6-35b-4bit",
            picker: "gpt-oss-20b-8bit",
            userMessages: 1
        )
        #expect(ModelSwitchWarning.shouldShow(input) == true)
    }

    @Test("Family mismatch with deep history (many turns) also fires")
    func family_mismatch_fires_with_deep_history() {
        let input = inputs(
            active: sessionA,
            session: "qwen3.6-35b-4bit",
            picker: "gpt-oss-20b-8bit",
            userMessages: 47
        )
        #expect(ModelSwitchWarning.shouldShow(input) == true)
    }

    @Test("Size mismatch within same family ⇒ shown — 4b vs 35b chat-template caps may differ")
    func size_mismatch_within_family_shows_banner() {
        let input = inputs(
            active: sessionA,
            session: "qwen3.6-4b-4bit",
            picker: "qwen3.6-35b-4bit",
            userMessages: 3
        )
        #expect(ModelSwitchWarning.shouldShow(input) == true)
    }
}
