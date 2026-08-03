import Testing
@testable import Rapid

/// v0.6.7 — pin every (bucket, role) → alias slot in the curated
/// recommendation table. 6 buckets × 5 roles = 30 slots. A regression
/// here would silently change what the picker recommends to a user
/// on a given RAM bucket, which is exactly the kind of drift the
/// hard table was introduced to prevent.
///
/// The catalog of valid aliases is the rapid-mlx submodule's
/// ``aliases.json``. We don't read it here (that would couple the
/// test suite to a submodule path); instead the test pins the
/// expected literals and a sibling smoke-test (``allSlotsCovered``)
/// verifies every role for every bucket returns a non-empty alias.
/// The submodule path is verified out-of-band during the PR pre-flight.
@Suite("ModelRecommendations — five role-anchored slots per RAM bucket (v0.6.7)")
struct ModelRecommendationsTests {

    // MARK: - Bucket: ≤ 16 GB

    @Test("≤16 GB — default = qwen3.5-4b-4bit")
    func bucket16Default() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 16)
        #expect(recs[.default] == "qwen3.5-4b-4bit")
    }

    @Test("≤16 GB — speed = qwen3.5-4b-4bit (2026-07-09: dropped phi-4-mini, refuses tools)")
    func bucket16Speed() {
        // v0.8.18 demoted gemma3-1b-qat-4bit (~262 t/s, incoherent).
        // ≤16 GB then used phi-4-mini-4bit (~159 t/s) as a
        // distinct-from-Default Speed pick. The 2026-07-09
        // recommended-model tool-usability sweep found phi-4-mini
        // flatly REFUSES every tool-eligible prompt (6/6 "I can't
        // assist with that") — and at ~1 t/s faster than
        // qwen3.5-4b-4bit it bought no real speed. Dropped in favour of
        // the verified qwen3.5-4b-4bit even though Speed now duplicates
        // Default on this bucket: a tool-capable duplicate beats a
        // distinct model that breaks the Tools flow.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 16)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("≤16 GB — quality = qwen3.5-9b-4bit")
    func bucket16Quality() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 16)
        #expect(recs[.quality] == "qwen3.5-9b-4bit")
    }

    @Test("≤16 GB — coding intentionally reuses default (no small coder fits)")
    func bucket16Coding() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 16)
        #expect(recs[.coding] == "qwen3.5-4b-4bit")
    }

    @Test("≤16 GB — multimodal = qwen3-vl-4b-4bit")
    func bucket16Multimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 16)
        #expect(recs[.multimodal] == "qwen3-vl-4b-4bit")
    }

    // MARK: - Bucket: 17–24 GB

    @Test("17–24 GB — default = qwen3.5-9b-4bit")
    func bucket24Default() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 18)
        #expect(recs[.default] == "qwen3.5-9b-4bit")
    }

    @Test("17–24 GB — speed = qwen3.5-4b-4bit (v0.8.18: demoted gemma3-1b)")
    func bucket24Speed() {
        // v0.8.18: qwen3.5-4b-4bit (~158 t/s, 65.8) replaces the
        // demoted gemma3-1b. Almost the same tok/s, 4× the reasoning,
        // and it's not the default here (default is qwen3.5-9b-4bit).
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 18)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("17–24 GB — quality = gemma-4-12b-4bit")
    func bucket24Quality() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 18)
        #expect(recs[.quality] == "gemma-4-12b-4bit")
    }

    @Test("17–24 GB — coding reuses default (2026-07-09: dropped devstral, engine mis-parses its tool calls)")
    func bucket24Coding() {
        // v0.7.16 had graduated this slot to devstral-v2-24b-4bit for
        // distinctiveness. The 2026-07-09 recommended-model
        // tool-usability sweep found the bundled engine ships every
        // Mistral-family alias with tool_call_parser=hermes, which
        // can't read Devstral's [TOOL_CALLS]…[ARGS]{…} output → 6/6
        // schema-leak on a tools-on prompt. (The model is fine — a
        // parser swap to "mistral" turns the same prompts into 6/6
        // clean tool_calls — but that is an engine-side fix tracked
        // upstream.) Until it ships bundled, no dedicated coder both
        // fits ≤24 GB AND tool-calls, so the slot falls back to the
        // verified qwen3.5-9b-4bit default.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 18)
        #expect(recs[.coding] == "qwen3.5-9b-4bit")
    }

    @Test("17–24 GB — multimodal = qwen3-vl-8b-4bit")
    func bucket24Multimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 18)
        #expect(recs[.multimodal] == "qwen3-vl-8b-4bit")
    }

    // MARK: - Bucket: 25–36 GB

    @Test("25–36 GB — default = gpt-oss-20b-mxfp4-q8")
    func bucket36Default() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 32)
        #expect(recs[.default] == "gpt-oss-20b-mxfp4-q8")
    }

    @Test("25–36 GB — speed = qwen3.5-4b-4bit (v0.8.18: was phi-4-mini-4bit)")
    func bucket36Speed() {
        // v0.8.18: unified the speed slot on qwen3.5-4b-4bit. It
        // matches phi-4-mini's tok/s (158 vs 159) but scores far
        // higher (reasoning 65.8 vs 44.9, code 35.1 vs 30.5), and it
        // is distinct from this bucket's default (gpt-oss-20b-mxfp4-q8).
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 32)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("25–36 GB — quality = gemma-4-26b-4bit")
    func bucket36Quality() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 32)
        #expect(recs[.quality] == "gemma-4-26b-4bit")
    }

    @Test("25–36 GB — coding = qwen3-coder-30b-4bit (2026-07-09: dropped deepseek-coder-v2-lite, 6/6 leak)")
    func bucket36Coding() {
        // The 2026-07-09 sweep found deepseek-coder-v2-lite-16b-4bit
        // ships tool_call_parser=None and invents ad-hoc tool names
        // wrapped in an unrecoverable DeepSeek-V3 envelope → 6/6 raw
        // leak on a tools-on prompt. Replaced by the headline coder
        // qwen3-coder-30b-4bit (~17 GB, fits the 25–36 GB floor,
        // swept 6/6 clean tool_calls).
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 32)
        #expect(recs[.coding] == "qwen3-coder-30b-4bit")
    }

    @Test("25–36 GB — multimodal = qwen3-vl-8b-4bit")
    func bucket36Multimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 32)
        #expect(recs[.multimodal] == "qwen3-vl-8b-4bit")
    }

    // MARK: - Bucket: 37–48 GB

    @Test("37–48 GB — default = qwen3.6-27b-4bit")
    func bucket48Default() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 42)
        #expect(recs[.default] == "qwen3.6-27b-4bit")
    }

    @Test("37–48 GB — speed = qwen3.5-4b-4bit (v0.8.18: demoted gemma3-1b)")
    func bucket48Speed() {
        // v0.8.18: speed means "fastest tok/s that is still coherent".
        // qwen3.5-4b-4bit (~158 t/s) is far faster than the 27B
        // default while staying usable, unlike the demoted gemma3-1b.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 42)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("37–48 GB — quality = gemma-4-31b-4bit")
    func bucket48Quality() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 42)
        #expect(recs[.quality] == "gemma-4-31b-4bit")
    }

    @Test("37–48 GB — coding = qwen3-coder-30b-4bit")
    func bucket48Coding() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 42)
        #expect(recs[.coding] == "qwen3-coder-30b-4bit")
    }

    @Test("37–48 GB — multimodal = qwen3-vl-30b-4bit")
    func bucket48Multimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 42)
        #expect(recs[.multimodal] == "qwen3-vl-30b-4bit")
    }

    // MARK: - Bucket: 49–96 GB

    @Test("49–96 GB — default = qwen3.6-35b-4bit")
    func bucket96Default() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 64)
        #expect(recs[.default] == "qwen3.6-35b-4bit")
    }

    @Test("49–96 GB — speed = qwen3.5-4b-4bit (v0.8.18: demoted gemma3-1b)")
    func bucket96Speed() {
        // Same v0.8.18 logic as the 37–48 bucket — speed = fastest
        // tok/s that is still coherent, regardless of bucket scale.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 64)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("49–96 GB — quality = qwen3.6-35b-8bit")
    func bucket96Quality() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 64)
        #expect(recs[.quality] == "qwen3.6-35b-8bit")
    }

    @Test("49–96 GB — coding = qwen3-coder-30b-4bit")
    func bucket96Coding() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 64)
        #expect(recs[.coding] == "qwen3-coder-30b-4bit")
    }

    @Test("49–96 GB — multimodal = qwen3-vl-30b-4bit")
    func bucket96Multimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 64)
        #expect(recs[.multimodal] == "qwen3-vl-30b-4bit")
    }

    // MARK: - Bucket: 97+ GB

    @Test("97+ GB — default = qwen3.6-35b-4bit (deliberately NOT 122B; first-touch UX)")
    func bucketUltraDefault() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 256)
        #expect(recs[.default] == "qwen3.6-35b-4bit")
    }

    @Test("97+ GB — speed = qwen3.5-4b-4bit (v0.8.18: demoted gemma3-1b)")
    func bucketUltraSpeed() {
        // Same v0.8.18 logic — speed = fastest coherent tok/s
        // regardless of bucket scale.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 256)
        #expect(recs[.speed] == "qwen3.5-4b-4bit")
    }

    @Test("97+ GB — quality = qwen3.5-122b-8bit (v0.7.16: was -mxfp4 variant)")
    func bucketUltraQuality() {
        // v0.7.16 cell flip: 8bit weights (129.8 GB on disk) score
        // 1pp higher on the internal avg and the mxfp4 variant has a
        // known load bug (see model_profiles.md). On a 97+ GB Mac
        // (M3 Ultra-class, 192–256 GB common) the 8bit fits and is
        // the right "quality" first impression. Users on a 128 GB
        // tier with bandwidth constraints can still pick mxfp4 from
        // the All Models list.
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 256)
        #expect(recs[.quality] == "qwen3.5-122b-8bit")
    }

    @Test("97+ GB — coding = qwen3-coder-30b-4bit")
    func bucketUltraCoding() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 256)
        #expect(recs[.coding] == "qwen3-coder-30b-4bit")
    }

    @Test("97+ GB — multimodal = qwen3-vl-30b-4bit")
    func bucketUltraMultimodal() {
        let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: 256)
        #expect(recs[.multimodal] == "qwen3-vl-30b-4bit")
    }

    // MARK: - Invariants

    @Test("Every bucket × every role returns a non-empty alias — no missing slot")
    func everySlotPopulated() {
        // One RAM value per bucket so we hit all six.
        let bucketProbeRAMs: [Double] = [8, 18, 32, 42, 64, 256]
        for ram in bucketProbeRAMs {
            let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: ram)
            for role in RAMBucketedDefault.Role.allCases {
                let alias = recs[role] ?? ""
                #expect(!alias.isEmpty, "Missing role \(role) at \(ram) GB")
            }
        }
    }

    @Test("orderedRecommendations preserves the canonical role order")
    func orderedRecommendationsRespectsRoleOrder() {
        let ordered = RAMBucketedDefault.orderedRecommendations(forPhysicalRAMGB: 64)
        let observedOrder = ordered.map(\.0)
        let expectedOrder = RAMBucketedDefault.Role.allCases
        #expect(observedOrder == expectedOrder)
    }

    @Test("Default role at every bucket matches the bucket's top-level default")
    func defaultRoleMatchesBucketDefault() {
        // Belt-and-braces: alias(forPhysicalRAMGB:) and
        // recommendations[.default] must always agree, even if a
        // future refactor adds a per-role override knob.
        let probes: [Double] = [8, 16, 17, 24, 25, 36, 37, 48, 49, 96, 97, 256]
        for ram in probes {
            let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: ram)
            #expect(recs[.default] == RAMBucketedDefault.alias(forPhysicalRAMGB: ram), "Mismatch at \(ram) GB")
        }
    }

    // MARK: - Role metadata

    @Test("Every role has a non-empty label and blurb — picker UI never shows ''")
    func roleMetadataNonEmpty() {
        for role in RAMBucketedDefault.Role.allCases {
            #expect(!role.label.isEmpty, "Empty label for \(role)")
            #expect(!role.blurb.isEmpty, "Empty blurb for \(role)")
        }
    }

    @Test("Role labels are unique — no two rows render the same heading")
    func roleLabelsUnique() {
        let labels = RAMBucketedDefault.Role.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // MARK: - ModelSizing × curated-table agreement (codex r1 PR #196)

    /// Snapshot of which (bucket-floor, role) slots ``ModelSizing``
    /// flags as ``.tooBig`` despite being in the operator-curated
    /// recommendation table. Pinned here so a future ModelSizing
    /// recalibration, a curated-table change, or a new alias that
    /// shifts the bucket — any of which can move a slot in or out
    /// of the disagreement set — shows up as an explicit test diff
    /// rather than a silent behaviour change.
    ///
    /// The disagreement is by design. The user spec for v0.6.7 said
    /// "trust the curated bucket table — if it's recommended, it
    /// fits", on the operator's testing that ModelSizing's heuristic
    /// (which uses fixed bits-per-weight and a fixed KV reserve) is
    /// conservative relative to mlx-vlm's real runtime cost on the
    /// listed aliases. The picker rows render WITHOUT warning icons
    /// either way (per spec) — this test exists to surface a drift
    /// in the disagreement set when someone next opens the picker
    /// schema, not to gate the curation against ModelSizing.
    ///
    /// Codex r1 BLOCKING on PR #196 surfaced the original concern:
    /// some quality / coding / multimodal entries trip
    /// ``ModelSizing.classify -> .tooBig`` at the lower edge of
    /// their bucket. The resolution chosen was to document the
    /// disagreement (this test) rather than reintroduce per-row
    /// warning glyphs or click-gating, both of which violate the
    /// v0.6.7 UX direction.
    @Test("ModelSizing × curated-table disagreement set stays documented")
    func curatedTableDisagreementsStayDocumented() {
        // RAM probe at each bucket's floor — the tightest point for
        // every slot in that bucket.
        let probes: [Double] = [16, 17, 25, 37, 49, 97]
        var observed: Set<String> = []
        for ram in probes {
            let recs = RAMBucketedDefault.recommendations(forPhysicalRAMGB: ram)
            let host = MacHardware(
                brandString: "Apple M3", family: .m3, tier: .pro,
                physicalRAMBytes: UInt64(ram) * 1024 * 1024 * 1024,
                memoryBandwidthGBs: 150
            )
            for role in RAMBucketedDefault.Role.allCases {
                guard let alias = recs[role] else { continue }
                let fit = ModelSizing.classify(ModelSizing.estimate(alias: alias), on: host)
                if fit == .tooBig {
                    observed.insert("\(Int(ram))|\(role.rawValue)|\(alias)")
                }
            }
        }
        // Documented disagreements — operator-verified to run
        // despite ModelSizing's .tooBig classification at the
        // bucket floor. Adding to this set is a deliberate act
        // ("we accept this is heuristic-borderline but verified");
        // removing from this set means either a curation tighten
        // (good) or a ModelSizing recalibration (also good).
        let documented: Set<String> = [
            // 17 GB Mac, lower edge of 17–24 bucket
            "17|quality|gemma-4-12b-4bit",
            // (2026-07-09: the 17|coding slot dropped devstral-v2-24b-4bit
            // — engine mis-parses its tool calls, 6/6 leak — and fell
            // back to the qwen3.5-9b-4bit default, which fits the 17 GB
            // floor cleanly, so it no longer trips .tooBig here.)
            // 25 GB lower edge of 25–36 — mxfp4-q8 fits but the
            // estimator treats it as 4-bit dense (16.2 GB).
            "25|default|gpt-oss-20b-mxfp4-q8",
            "25|quality|gemma-4-26b-4bit",
            // 2026-07-09: coding graduated to qwen3-coder-30b-4bit
            // (the headline coder; the previous deepseek-coder-v2-lite
            // 6/6-leaks tool calls). Its ~17 GB weights trip .tooBig at
            // the 25 GB theoretical floor exactly as they do at the
            // 37 GB floor below — most 25–36 GB Macs are 32 GB+ where it
            // fits, and its tool-calling was swept 6/6 clean.
            "25|coding|qwen3-coder-30b-4bit",
            // 37 GB lower edge of 37–48 — operator tested on 48 GB
            // M3 Max; bucket lower edge is theoretical.
            "37|quality|gemma-4-31b-4bit",
            "37|coding|qwen3-coder-30b-4bit",
            "37|multimodal|qwen3-vl-30b-4bit",
            // 49 GB lower edge of 49–96 — 35B-8bit known tight on
            // 64 GB M3 Max but verified working at that scale.
            "49|quality|qwen3.6-35b-8bit",
            // 97 GB lower edge of 97+ — 122B flagship is the
            // largest first-party alias; user has to opt in
            // explicitly by selecting Quality. v0.7.16 moved this
            // from -mxfp4 (65 GB on-disk) to -8bit (130 GB on-disk)
            // because the 8bit weights score 1pp higher on the
            // internal avg and the mxfp4 variant has a known load
            // bug; on the M3 Ultra-class machines that hit this
            // bracket disk is rarely the constraint.
            "97|quality|qwen3.5-122b-8bit",
        ]
        #expect(
            observed == documented,
            """
            Curated-table × ModelSizing disagreement set drifted.
            Observed (\(observed.count)): \(observed.sorted())
            Documented (\(documented.count)): \(documented.sorted())
            Either retune the bucket in RAMBucketedDefault or update
            this documented set with a written rationale.
            """
        )
    }
}
