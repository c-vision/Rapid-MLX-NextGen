import Foundation
import Testing
@testable import Rapid

/// Cycle-13 fix B regression pin (2026-06-20) — broaden the PR #318
/// floor contract from the single-alias coverage already in
/// ``ChatViewModelReasoningMaxTokensTests`` (vibethinker only) to a
/// matrix of reasoning + non-reasoning aliases.
///
/// Why this matters: the cycle-3 fuzz-correctness finding
/// (qwen3-4b-thinking-2507-4bit empty bubble at default ``max_tokens
/// = 2048``) asked for a *hard-coded* list extension. PR #318
/// deliberately replaced the hard-coded list with a wire-level
/// signal — the server-reported ``reasoning_parser`` on
/// ``/v1/models/{id}``. So the right verification is: pin the
/// behaviour of ``SamplingConfig.effectiveMaxTokens(toolsEnabled:)``
/// across every reasoning alias the user can pick today, so that any
/// future refactor that breaks the contract on a NEW alias
/// (architecturally distinct but still reasoning) fails CI before
/// shipping.
///
/// Coverage rationale: pick at least one alias from each parser
/// family that ships in ``aliases.json`` with ``reasoning_parser !=
/// null`` — qwen3 (Qwen3.x / qwen3-4b-thinking), deepseek_r1
/// (DeepSeek-R1 / phi-4-mini-reasoning), hermes (Hermes /
/// nemotron-thinking), vibethinker (custom), glm47 (GLM-4.7) — plus
/// one non-reasoning baseline (instruct-2507) to prove the
/// pass-through path.
///
/// What this DOESN'T pin: the per-alias parser *value* itself (e.g.
/// "qwen3-4b-thinking → qwen3"). The desktop is wire-driven — if the
/// server changes the parser name, the desktop adapts. The contract
/// here is "non-null reasoning_parser + (auto-scaled OR maxTokens ==
/// maxTokensDefault) → floor lifts" / "null parser OR explicit user
/// override of maxTokens → pass-through". See
/// ``userOverrideSuppressesFloorOnCycle3Alias`` for the override
/// carve-out the PR #318 codex r1 MAJOR fix introduced. The
/// cycle-13 verification methodology (replayed in the PR body)
/// covers the per-alias wire value.
@MainActor
@Suite("SamplingConfig.effectiveMaxTokens — reasoning floor matrix (cycle-13 regression pin)", .serialized)
final class SamplingConfigReasoningAliasFloorTests {
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults() -> UserDefaults {
        let name = TestDefaultsScope.mintSuiteName(prefix: "rapid-sampling-c13-test-")
        createdSuiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Hard-pinned matrix of reasoning aliases that ship in
    /// ``aliases.json`` today with ``reasoning_parser != null``. If
    /// the rapid-mlx server adds a new reasoning alias, append a
    /// row; deletion of a row should be paired with a server-side
    /// alias retirement so the desktop's contract surface stays
    /// honest.
    ///
    /// ``qwen3-4b-thinking-2507-4bit`` is the cycle-3 fuzz-correctness
    /// finding (PR closure) — verified via rapid-mlx aliases.json on
    /// 2026-06-20: ``reasoning_parser='qwen3'``, so the floor mechanism
    /// auto-fires on alias swap. The finding's request for a hard-coded
    /// list is OBSOLETE — this row is the regression pin instead.
    // ``nonisolated`` so the ``@Test(arguments:)`` macro can read
    // the matrix from outside the MainActor — the values are pure
    // ``Sendable`` literals so the isolation carve-out is safe.
    nonisolated(unsafe) private static let reasoningAliases: [(alias: String, parser: String)] = [
        // Cycle-3 finding closure — the alias that triggered this suite.
        ("qwen3-4b-thinking-2507-4bit", "qwen3"),
        // Hybrid-thinking flagship (cycle-2 vibethinker sibling — different family).
        ("qwen3.5-4b", "qwen3"),
        ("qwen3.6-27b-8bit", "qwen3"),
        // DeepSeek-R1 distill family — F-11-2 closure verified the floor on phi-4 (deepseek_r1 parser).
        ("phi-4-mini-reasoning-4bit", "deepseek_r1"),
        ("deepseek-r1-8b-4bit", "deepseek_r1"),
        // VibeThinker — already covered by ChatViewModelReasoningMaxTokensTests; included
        // here for matrix completeness (parser-family delta).
        ("vibethinker-3b-8bit", "vibethinker"),
        // Hermes-family reasoning (nemotron thinking-on path).
        ("nemotron-30b-4bit", "hermes"),
        // GLM-4.7 reasoning family.
        ("glm4.7-9b-8bit", "glm47"),
    ]

    nonisolated(unsafe) private static let nonReasoningAliases: [String] = [
        // Instruct sibling — proves pass-through (no floor fires on null parser).
        "qwen3-4b-instruct-2507-4bit",
        // Pure-instruct non-hybrid family (paired with qwen3.5-4b reasoning above).
        "qwen3-4b-8bit-instruct",
    ]

    /// Reasoning alias on a fresh-install SamplingConfig (slider at
    /// ``maxTokensDefault = 4096``) → ``effectiveMaxTokens(toolsEnabled:
    /// false)`` exactly ``max(maxTokens, reasoningChatFloor)`` AND
    /// ``effectiveMaxTokens(toolsEnabled: true)`` exactly
    /// ``max(maxTokens, reasoningToolsFloor)``.
    ///
    /// Why strict equality, not ``>=`` (cycle-13 codex r1 MAJOR):
    /// today's constants put both floors at-or-below the baseline
    /// (2,048 < 4,096 and 4,096 == 4,096), so a ``>=`` assertion
    /// would still pass against a degenerate ``effectiveMaxTokens``
    /// that silently returned raw ``maxTokens`` on a reasoning alias
    /// — the cross-alias matrix would not catch a future
    /// parser-family whitelist regression (e.g. dropping ``qwen3``
    /// from the floor gate while keeping ``activeReasoningParser``
    /// populated). Strict equality fixes that the moment a future
    /// floor lift makes the two values diverge:
    /// * Bump ``reasoningChatFloor`` to ``8_192`` (DeepSeek-R1
    ///   request in F-706) and the chat assertion immediately
    ///   demands ``8_192`` on every reasoning alias — a whitelist
    ///   regression that omits one parser instantly fails its row.
    /// * The tools floor is already at the baseline today; any
    ///   subsequent raise hits the same gate.
    @Test(
        "PR #318 floor fires on every reasoning alias — fresh-install slider, strict equality",
        arguments: reasoningAliases
    )
    func reasoningAliasLiftsBothFloors(alias: String, parser: String) {
        let sampling = SamplingConfig(defaults: freshDefaults())
        let profile = ServerModelProfile(
            id: alias,
            recommendedSampling: nil,
            isHybrid: nil,
            isMoe: nil,
            toolCallParser: nil,
            reasoningParser: parser,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)

        // Sanity — the parser signal must be captured even with a
        // nil recommended_sampling block; the floor mechanism is
        // independent of curated sampling.
        #expect(sampling.activeReasoningParser == parser,
                "\(alias): applyServerProfile did not capture reasoning_parser \(parser)")

        // Strict equality: chat budget MUST equal max(raw, floor).
        // Today both terms equal 4,096; a future floor raise makes
        // the right-hand-side dominate and the test pins the lift
        // value precisely.
        let expectedChat = max(sampling.maxTokens, SamplingConfig.reasoningChatFloor)
        let chatBudget = sampling.effectiveMaxTokens(toolsEnabled: false)
        #expect(chatBudget == expectedChat,
                "\(alias): chat budget \(chatBudget) != max(maxTokens \(sampling.maxTokens), reasoningChatFloor \(SamplingConfig.reasoningChatFloor)) — PR #318 floor contract broken")

        // Strict equality: tools budget MUST equal max(raw, tools floor).
        let expectedTools = max(sampling.maxTokens, SamplingConfig.reasoningToolsFloor)
        let toolsBudget = sampling.effectiveMaxTokens(toolsEnabled: true)
        #expect(toolsBudget == expectedTools,
                "\(alias): tools budget \(toolsBudget) != max(maxTokens \(sampling.maxTokens), reasoningToolsFloor \(SamplingConfig.reasoningToolsFloor)) — PR #318 tools floor contract broken")
    }

    /// Path-coverage observability check (cycle-13 codex r1 MAJOR
    /// follow-up): prove the floor logic **actually executes** on a
    /// reasoning alias, not merely that the observed value is
    /// >= floor.
    ///
    /// Mechanism: ``applyServerProfile``'s auto-scale path calls
    /// ``maxTokens = newValue``. The ``didSet`` observer
    /// unconditionally invokes ``persist(_:value:)`` — Swift didSet
    /// fires on any assignment, even when the new value equals the
    /// old one. So if the floor gate actually fires, the
    /// ``rapid.sampling.v0.maxTokens`` UserDefaults key gets written;
    /// if a future regression drops a parser family from the gate
    /// (the exact scenario codex r1 MAJOR called out), the auto-scale
    /// path is skipped, ``maxTokens`` is never assigned, and the
    /// UserDefaults key stays absent.
    ///
    /// We remove the key before ``applyServerProfile`` and assert
    /// it's present afterwards — strict path coverage for the
    /// "floor fires per parser family" claim.
    ///
    /// Trade-off: we observe the side effect of the auto-scale path
    /// (persistence write) rather than the return value of
    /// ``effectiveMaxTokens``, because today's constants
    /// (``maxTokensDefault == reasoningToolsFloor == 4096``) make
    /// the return value indistinguishable from a pass-through.
    /// Both checks (return-value + persistence side-effect) together
    /// form the if-and-only-if contract.
    @Test(
        "Path coverage: applyServerProfile triggers auto-scale persistence on every reasoning alias",
        arguments: reasoningAliases
    )
    func reasoningAliasTriggersAutoScalePath(alias: String, parser: String) {
        let defaults = freshDefaults()
        let sampling = SamplingConfig(defaults: defaults)
        // Sanity — fresh-install slider at the baseline. Required
        // for the auto-scale gate (which fires on ``maxTokens ==
        // maxTokensDefault`` per SamplingConfig.swift:294-296).
        #expect(sampling.maxTokens == SamplingConfig.maxTokensDefault,
                "\(alias): test precondition broken — fresh SamplingConfig should be at default 4,096")

        // Remove the persisted key. ``init`` didn't write it (the
        // ctor reads with a default fallback rather than writing on
        // first launch — SamplingConfig.swift:222-225), so this is
        // belt-and-braces. If the auto-scale path later assigns
        // maxTokens, the didSet observer's ``persist`` call lands
        // here.
        let persistedKey = "rapid.sampling.v0.maxTokens"
        defaults.removeObject(forKey: persistedKey)
        #expect(defaults.object(forKey: persistedKey) == nil,
                "\(alias): test precondition broken — persisted key already populated before applyServerProfile")

        let profile = ServerModelProfile(
            id: alias,
            recommendedSampling: nil,
            isHybrid: nil,
            isMoe: nil,
            toolCallParser: nil,
            reasoningParser: parser,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)

        // Path coverage proof: the persistence side effect of
        // ``autoScaleMaxTokens`` is observable as a populated
        // UserDefaults key. Absence here means the auto-scale path
        // didn't run — i.e. the parser-family gate skipped this
        // alias. Today's value is 4,096 (== max(default, chatFloor)),
        // but the key MUST exist.
        let persistedValue = defaults.object(forKey: persistedKey) as? Int
        #expect(persistedValue != nil,
                "\(alias) (parser=\(parser)): applyServerProfile did NOT trigger auto-scale path — UserDefaults key absent. PR #318 floor gate skipped this parser family.")
        if let v = persistedValue {
            #expect(v == max(SamplingConfig.maxTokensDefault, SamplingConfig.reasoningChatFloor),
                    "\(alias): auto-scale wrote \(v), expected max(default, chatFloor) = \(max(SamplingConfig.maxTokensDefault, SamplingConfig.reasoningChatFloor))")
        }
    }

    /// Non-reasoning alias on a fresh-install SamplingConfig →
    /// ``effectiveMaxTokens`` returns ``maxTokens`` unchanged for
    /// BOTH ``toolsEnabled`` values. Proves the floor is gated on
    /// the parser signal, not unconditionally applied.
    ///
    /// This pin is what stops a future "let's just always lift to
    /// 4,096" simplification from silently broadening the contract —
    /// a non-reasoning alias with the user's persisted
    /// ``maxTokens = 512`` (e.g. a latency-sensitive lab setup) must
    /// continue to ship 512, not get bumped to 4,096.
    @Test(
        "Non-reasoning alias pass-through — null parser keeps slider unchanged",
        arguments: nonReasoningAliases
    )
    func nonReasoningAliasPassThrough(alias: String) {
        let sampling = SamplingConfig(defaults: freshDefaults())
        // Pick a value distinct from the default + from both floors so
        // any silent bump shows up as an inequality. 1,024 sits below
        // the chat floor (2,048) → if the floor leaks across the
        // gate, both branches return >= 2,048 instead of 1,024.
        sampling.maxTokens = 1_024
        let profile = ServerModelProfile(
            id: alias,
            recommendedSampling: nil,
            isHybrid: nil,
            isMoe: nil,
            toolCallParser: "hermes",
            reasoningParser: nil,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)
        #expect(sampling.activeReasoningParser == nil,
                "\(alias): null reasoning_parser must not surface as activeReasoningParser")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: false) == 1_024,
                "\(alias): non-reasoning chat path bumped 1024 → \(sampling.effectiveMaxTokens(toolsEnabled: false))")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: true) == 1_024,
                "\(alias): non-reasoning tools path bumped 1024 → \(sampling.effectiveMaxTokens(toolsEnabled: true))")
    }

    /// User-override carve-out — once the user drags the slider to a
    /// value distinct from ``maxTokensDefault``, the floor is
    /// SUPPRESSED even on a reasoning alias. This is the "respect
    /// user intent" contract that the PR #318 codex r1 MAJOR fix
    /// carved out (the bookkeeping flag landmark). A reasoning alias
    /// with ``maxTokens = 256`` (set explicitly by a latency-bench
    /// operator) must ship 256, not get bumped to 4,096.
    ///
    /// Replays the contract specifically on
    /// ``qwen3-4b-thinking-2507-4bit`` to anchor the cycle-3 finding
    /// closure rationale: the floor isn't "always on for thinking
    /// aliases" — it's "on for thinking aliases when the user hasn't
    /// touched the slider". The finding asked for a hard-coded list;
    /// PR #318 chose a wire-driven gate with an explicit user-override
    /// carve-out. Both behaviours are pinned here.
    /// XOR test (cycle-13 codex r4 MAJOR doc-correction): the round
    /// 1-3 doc-comments overclaimed that this test catches an
    /// ``effectiveMaxTokens``-internal parser whitelist regression.
    /// Under today's constants (``maxTokensDefault == 4096``,
    /// ``reasoningChatFloor == 2048``, ``reasoningToolsFloor == 4096``)
    /// the applied and cleared return values are BOTH ``4096`` —
    /// numerically indistinguishable. A hypothetical regression like
    /// "``effectiveMaxTokens`` checks ``parser == "qwen3"`` and
    /// returns raw" would still produce ``4096 == 4096`` and pass
    /// every row.
    ///
    /// What this test ACTUALLY pins (the honest scope):
    /// * ``clearActiveReasoningParser`` actually drops the parser
    ///   signal — the FIRST guard at SamplingConfig.swift:346-348
    ///   ((``parser == nil``) branch) is reachable and returns raw
    ///   ``maxTokens``.
    /// * The clear+reapply cycle is idempotent on the return value —
    ///   no leftover state corrupts a second observation.
    /// * The ``activeReasoningParser`` is correctly re-armed by a
    ///   second ``applyServerProfile`` call.
    ///
    /// What this test does NOT catch (the structural limitation):
    /// * A future ``effectiveMaxTokens``-internal regression that
    ///   shortcuts a specific parser family before reaching the
    ///   floor branch. This remains structurally indistinguishable
    ///   from raw pass-through until either (a) production-code
    ///   instrumentation lets the test observe control flow, or (b)
    ///   a future floor lift crosses ``maxTokensDefault`` and makes
    ///   the floor-branch return value numerically distinct from the
    ///   raw branch. The ``constantsInvariantToday`` test surfaces
    ///   the latter transition as a CI delta, forcing the maintainer
    ///   to re-evaluate the matrix's role.
    ///
    /// What DOES catch an ``applyServerProfile``-side whitelist
    /// regression: ``reasoningAliasFlipsAutoScaledFlag`` below — it
    /// inspects the private ``maxTokensIsAutoScaled`` bookkeeping
    /// flag via Mirror, which is true if-and-only-if the
    /// ``applyServerProfile`` floor gate accepted the parser
    /// family. That's the strict structural detector for one side
    /// of the floor gate.
    @Test(
        "effectiveMaxTokens parser-gate XOR — clear() returns raw; reapply re-arms parser signal idempotently",
        arguments: reasoningAliases
    )
    func effectiveMaxTokensParserGateXOR(alias: String, parser: String) {
        let sampling = SamplingConfig(defaults: freshDefaults())
        let profile = ServerModelProfile(
            id: alias,
            recommendedSampling: nil,
            isHybrid: nil,
            isMoe: nil,
            toolCallParser: nil,
            reasoningParser: parser,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)
        let appliedChat = sampling.effectiveMaxTokens(toolsEnabled: false)
        let appliedTools = sampling.effectiveMaxTokens(toolsEnabled: true)

        // Clear the parser signal — simulates the alias-swap race
        // gap RapidApp's `.task(id:)` guards against. The first
        // guard of effectiveMaxTokens (line 346-348) returns raw
        // maxTokens.
        sampling.clearActiveReasoningParser()
        #expect(sampling.activeReasoningParser == nil,
                "\(alias): clearActiveReasoningParser did not drop the parser signal")

        let clearedChat = sampling.effectiveMaxTokens(toolsEnabled: false)
        let clearedTools = sampling.effectiveMaxTokens(toolsEnabled: true)

        // The cleared path MUST return raw maxTokens, regardless of
        // alias. Today raw == 4,096 so this equals appliedChat too;
        // a future floor lift makes the values diverge and this
        // becomes a strict numerical differential.
        #expect(clearedChat == sampling.maxTokens,
                "\(alias): cleared-parser effectiveMaxTokens(toolsEnabled:false) returned \(clearedChat), expected raw maxTokens \(sampling.maxTokens) — first guard at SamplingConfig.swift:346 broken")
        #expect(clearedTools == sampling.maxTokens,
                "\(alias): cleared-parser effectiveMaxTokens(toolsEnabled:true) returned \(clearedTools), expected raw maxTokens \(sampling.maxTokens) — first guard at SamplingConfig.swift:346 broken")

        // Re-apply the profile — the parser signal must re-arm and
        // the return value must be idempotent across the
        // clear+reapply cycle (no leftover state corrupts the second
        // observation). Does NOT prove the floor branch executed —
        // see the doc-comment above for the structural limitation.
        _ = sampling.applyServerProfile(profile)
        #expect(sampling.activeReasoningParser == parser,
                "\(alias): reapply did not re-arm activeReasoningParser")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: false) == appliedChat,
                "\(alias): chat budget non-idempotent across clear+reapply (\(appliedChat) → \(sampling.effectiveMaxTokens(toolsEnabled: false)))")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: true) == appliedTools,
                "\(alias): tools budget non-idempotent across clear+reapply (\(appliedTools) → \(sampling.effectiveMaxTokens(toolsEnabled: true)))")
    }

    /// Cycle-13 codex r3 MAJOR followup — DIRECT control-flow proof
    /// of the ``applyServerProfile`` auto-scale/floor gate via
    /// private-state Mirror. The strict-equality matrix and the XOR
    /// test pin the *return values* of ``effectiveMaxTokens``, but
    /// those return values are numerically equivalent across the
    /// floor-branch and the raw branch under today's constants (PR
    /// #318 deliberately picked floor ≤ default to avoid breaking
    /// existing users). The way to *strictly* prove the
    /// ``applyServerProfile`` floor gate accepted a parser family is
    /// to inspect the private bookkeeping flag that that gate sets —
    /// ``maxTokensIsAutoScaled``. This is the
    /// ``applyServerProfile``-side strict detector; the
    /// ``effectiveMaxTokens``-side internal whitelist regression
    /// remains structurally indistinguishable under today's
    /// constants (see XOR test doc-comment for the trade-off).
    ///
    /// Mirror is the least invasive way: it reads the private field
    /// via Swift's runtime reflection without requiring a production
    /// API surface change. We isolate the reflection in a single
    /// helper so a future refactor that renames the field surfaces
    /// here as one fix-up site.
    ///
    /// What this catches that the strict matrix can't:
    /// * Hypothetical ``applyServerProfile`` regression "drop
    ///   ``qwen3`` from the floor gate" — autoScale skipped for
    ///   qwen3-aliased rows; flag stays ``false``; this test fails
    ///   the qwen3 rows specifically, even when the return value
    ///   remains 4,096.
    /// * Hypothetical regression "always autoScale, ignore parser" —
    ///   covered by the non-reasoning pass-through test.
    /// * Hypothetical regression "autoScale but stash flag wrong" —
    ///   the bookkeeping pin below catches the flag delta.
    ///
    /// What this still does NOT catch:
    /// * Hypothetical ``effectiveMaxTokens``-internal whitelist
    ///   regression (an internal shortcut shortcutting the floor
    ///   branch for one parser family after the flag is correctly
    ///   set). The constants invariant test surfaces the transition
    ///   when a future floor lift crosses ``maxTokensDefault``.
    ///
    /// Trade-off: reaching across the access boundary couples the
    /// test to the field name. The benefit is strict path coverage
    /// for the ``applyServerProfile`` side that survives the
    /// numerical-equivalence of today's constants; the cost is a
    /// single-site rename burden. Documented in the helper.
    @Test(
        "Strict path coverage: applyServerProfile sets the private maxTokensIsAutoScaled flag for every reasoning alias",
        arguments: reasoningAliases
    )
    func reasoningAliasFlipsAutoScaledFlag(alias: String, parser: String) {
        let sampling = SamplingConfig(defaults: freshDefaults())
        #expect(autoScaledFlag(of: sampling) == false,
                "\(alias): test precondition broken — fresh SamplingConfig should have maxTokensIsAutoScaled == false")

        let profile = ServerModelProfile(
            id: alias,
            recommendedSampling: nil,
            isHybrid: nil,
            isMoe: nil,
            toolCallParser: nil,
            reasoningParser: parser,
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)

        // STRICT path-coverage assertion: the floor gate inside
        // applyServerProfile flipped the bookkeeping flag because
        // this parser family was accepted. If a future regression
        // ``if parser in whitelist`` drops one family, that family's
        // row will assert ``false == true`` here and fail
        // independently of any return-value behaviour. This survives
        // the numerical-equivalence period of today's constants.
        #expect(autoScaledFlag(of: sampling) == true,
                "\(alias) (parser=\(parser)): applyServerProfile did NOT flip maxTokensIsAutoScaled — PR #318 floor gate skipped this parser family. This is the strict control-flow regression detector independent of return-value numerics.")
    }

    /// Mirror helper — reads ``SamplingConfig.maxTokensIsAutoScaled``
    /// via Swift runtime reflection. Returns ``nil`` if the field is
    /// renamed / removed / its type changes (so a refactor of the
    /// production type surfaces as a clean test failure rather than
    /// an obscure crash).
    ///
    /// Why Mirror over an ``@testable`` ``internal`` accessor: PR
    /// #318 deliberately scoped the flag ``private`` to keep the
    /// public API small. Adding an ``internal`` getter just for
    /// tests would broaden the surface a future refactor has to
    /// maintain; Mirror keeps the production type pristine.
    private func autoScaledFlag(of sampling: SamplingConfig) -> Bool? {
        let mirror = Mirror(reflecting: sampling)
        for child in mirror.children where child.label == "maxTokensIsAutoScaled" {
            return child.value as? Bool
        }
        return nil
    }

    /// Constants invariant pin (cycle-13 codex r2 MAJOR followup):
    /// today's constants make ``maxTokensDefault >= reasoningChatFloor``
    /// AND ``maxTokensDefault >= reasoningToolsFloor`` — the
    /// numerical-equivalence reason the strict-equality matrix above
    /// can't directly distinguish floor lift from raw pass-through.
    /// If a future maintainer raises ``reasoningChatFloor`` above
    /// ``maxTokensDefault`` (e.g. F-706 8,192 for DeepSeek-R1
    /// distills), the strict-equality matrix immediately becomes a
    /// magnitude-distinguishing pin AND this invariant fails —
    /// surfacing the change as a paired CI delta on both the matrix
    /// and the invariant, which is the structural signal that the
    /// contract has crossed the lift/raw boundary.
    @Test("Constants invariant: today's defaults sit at-or-above both floors — strict-equality matrix above is path-distinguishing iff this invariant flips")
    func constantsInvariantToday() {
        // If either of these stops holding, the matrix above flips
        // from "numerical-equal-today, structural-pin" to
        // "magnitude-pin". Both states are intentional; the test
        // forces the maintainer to update the matrix doc-comment
        // along with the floor raise.
        #expect(SamplingConfig.maxTokensDefault >= SamplingConfig.reasoningChatFloor,
                "Floor lift crossed default — update reasoningAliasLiftsBothFloors doc comment and re-evaluate the differential's magnitude-distinguishing role")
        #expect(SamplingConfig.maxTokensDefault >= SamplingConfig.reasoningToolsFloor,
                "Tools floor lift crossed default — same as above")
    }

    @Test("User override (maxTokens = 256) suppresses the floor on qwen3-4b-thinking-2507-4bit")
    func userOverrideSuppressesFloorOnCycle3Alias() {
        let sampling = SamplingConfig(defaults: freshDefaults())
        // Drag the slider FIRST (any value != maxTokensDefault), THEN
        // observe the reasoning profile. This is the realistic order:
        // a user touches Settings → Sampling, then later swaps to a
        // reasoning alias.
        sampling.maxTokens = 256
        let profile = ServerModelProfile(
            id: "qwen3-4b-thinking-2507-4bit",
            recommendedSampling: nil,
            isHybrid: false,
            isMoe: false,
            toolCallParser: "hermes",
            reasoningParser: "qwen3",
            modality: "text"
        )
        _ = sampling.applyServerProfile(profile)

        #expect(sampling.activeReasoningParser == "qwen3",
                "parser signal must still be captured for diagnostics")
        #expect(sampling.maxTokens == 256,
                "user-touched slider must not be silently bumped by applyServerProfile")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: false) == 256,
                "explicit user override 256 must reach the wire unchanged on chat path")
        #expect(sampling.effectiveMaxTokens(toolsEnabled: true) == 256,
                "explicit user override 256 must reach the wire unchanged on tools path")
    }
}
