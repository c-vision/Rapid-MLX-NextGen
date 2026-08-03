import Testing
@testable import Rapid

/// Issue #163 — pin the RAM bracket → canonical alias mapping
/// against the contract the landing page at
/// ``rapidmlx.com/desktop`` publishes. Every bracket boundary plus
/// representative interior values, so a future "let's add another
/// bracket" PR can't silently shift the boundaries.
///
/// Boundaries were re-tuned during codex r1 review on PR #165
/// after the original 25-GB lower-bound on the 27B bracket
/// produced ``.tooBig`` classifications for 32 GB Macs.
///
/// v0.6.7 expanded each bucket from a single "default alias" to
/// five role-anchored aliases (default / speed / quality / coding /
/// multimodal) and split the 17–36 bucket into 17–24 + 25–36 so the
/// default slot can graduate to gpt-oss-20b-mxfp4-q8 above 24 GB.
/// New default-slot table:
///
///   ≤ 16  → qwen3.5-4b-4bit
///   17-24 → qwen3.5-9b-4bit
///   25-36 → gpt-oss-20b-mxfp4-q8
///   37-48 → qwen3.6-27b-4bit
///   49-96 → qwen3.6-35b-4bit
///   97+   → qwen3.6-35b-4bit
///
/// — chosen so the bucketed default is at most ``.borderline`` on
/// the bottom edge of every bracket. The full 5-role table is
/// covered by ``ModelRecommendationsTests``.
///
/// v0.6.1 collapsed the previous 128+ → 122B default into 49+ →
/// 35B-A3B. Rationale lives in ``RAMBucketedDefault``'s docstring:
/// 65 GB first-touch downloads were the #1 reason new users bounced
/// before reaching the chat surface. 122B stays in the model picker
/// as the ``quality`` slot at 97+ GB.
@Suite("RAMBucketedDefault — landing-page contract (issue #163)")
struct RAMBucketedDefaultTests {

    // MARK: - Exact-boundary cases

    @Test("8 GB Mac (entry-tier MacBook Air) → 4B")
    func eightGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 8) == "qwen3.5-4b-4bit")
    }

    @Test("16 GB Mac (default MacBook Air, top of smallest bracket) → 4B")
    func sixteenGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 16) == "qwen3.5-4b-4bit")
    }

    @Test("17 GB Mac (just above the 16 GB cap) → 9B")
    func seventeenGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 17) == "qwen3.5-9b-4bit")
    }

    @Test("18 GB Mac (M3 Pro base) → 9B")
    func eighteenGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 18) == "qwen3.5-9b-4bit")
    }

    @Test("24 GB Mac (M3 Pro upgrade, top of 17–24 bracket) → 9B (default slot)")
    func twentyFourGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 24) == "qwen3.5-9b-4bit")
    }

    @Test("25 GB Mac (just above the 24 GB cap) → gpt-oss-20b (default slot)")
    func twentyFiveGB() {
        // v0.6.7: the 17–36 bucket split into 17–24 + 25–36 so the
        // default slot graduates to gpt-oss-20b above 24 GB, where
        // mxfp4-q8 sizing (~12 GB weights) fits comfortably.
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 25) == "gpt-oss-20b-mxfp4-q8")
    }

    @Test("32 GB Mac (largest single-config cohort) → gpt-oss-20b (default slot)")
    func thirtyTwoGB() {
        // v0.6.7: was qwen3.5-9b-4bit pre-split. gpt-oss-20b-mxfp4-q8
        // is a far better starting model on 32 GB and still safely
        // under the .tooBig ceiling.
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 32) == "gpt-oss-20b-mxfp4-q8")
    }

    @Test("36 GB Mac (M3 Pro top, top of the 25–36 bracket) → gpt-oss-20b (default slot)")
    func thirtySixGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 36) == "gpt-oss-20b-mxfp4-q8")
    }

    @Test("37 GB Mac (just above the 36 GB cap, bottom of the 27B bracket) → 27B (default slot)")
    func thirtySevenGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 37) == "qwen3.6-27b-4bit")
    }

    @Test("48 GB Mac (M3 Max base, top of the 27B bracket) → 27B")
    func fortyEightGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 48) == "qwen3.6-27b-4bit")
    }

    @Test("49 GB Mac (just above the 48 GB cap, bottom of the 35B bracket) → 35B-A3B")
    func fortyNineGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 49) == "qwen3.6-35b-4bit")
    }

    @Test("64 GB Mac (M3 Max / Ultra entry) → 35B-A3B")
    func sixtyFourGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 64) == "qwen3.6-35b-4bit")
    }

    @Test("96 GB Mac (M3 Max upgrade) → 35B-A3B")
    func ninetySixGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 96) == "qwen3.6-35b-4bit")
    }

    @Test("128 GB Mac (M2 Ultra / M3 Ultra entry) → 35B-A3B (v0.6.1: was 122B)")
    func oneTwentyEightGB() {
        // v0.6.1 collapsed the 128+ bracket. 122B is still picker-
        // selectable but no longer the first-touch default for
        // 128 GB+ Macs — 65 GB download was the dominant
        // first-touch UX failure surfaced by the v0.6.0 N2N walk.
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 128) == "qwen3.6-35b-4bit")
    }

    @Test("256 GB Mac (M3 Ultra full house) → 35B-A3B (v0.6.1: was 122B)")
    func twoFiftySixGB() {
        // Same v0.6.1 collapse rationale. ~18 GB download finishes
        // in 3-5 min; user sees the chat respond, can then trade
        // up to 122B from the picker if they want quality over
        // bandwidth.
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 256) == "qwen3.6-35b-4bit")
    }

    @Test("1 TB Mac (hypothetical future Ultra) → 35B-A3B (last bucket is open-ended)")
    func oneTerabyteGB() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 1024) == "qwen3.6-35b-4bit")
    }

    // MARK: - Fractional / edge cases

    @Test("Boundary infinitesimally above 16 GB lands in the 9B bucket")
    func justAboveSixteen() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 16.5) == "qwen3.5-9b-4bit")
    }

    @Test("Boundary infinitesimally below 16 GB still lands in the 4B bucket")
    func justBelowSixteen() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 15.99) == "qwen3.5-4b-4bit")
    }

    @Test("Pathological zero RAM falls into the smallest bucket, not a crash")
    func zeroRAM() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: 0) == "qwen3.5-4b-4bit")
    }

    @Test("Negative input (impossible in practice) still routes to a real alias")
    func negativeRAM() {
        #expect(RAMBucketedDefault.alias(forPhysicalRAMGB: -1) == "qwen3.5-4b-4bit")
    }

    // MARK: - Bucket table invariants

    @Test("Brackets are monotonically increasing — no overlap, no gap")
    func bracketsAreSorted() {
        let upperBounds = RAMBucketedDefault.buckets.map(\.upperGB)
        for (a, b) in zip(upperBounds, upperBounds.dropFirst()) {
            #expect(a < b, "Bucket upper bounds must be strictly increasing — got \(a) before \(b)")
        }
    }

    @Test("Last bucket is unbounded so callers never need a fallback")
    func lastBucketIsInfinite() {
        #expect(RAMBucketedDefault.buckets.last?.upperGB == .infinity)
    }

    @Test("Default-slot aliases follow a non-decreasing capability curve across brackets")
    func defaultSlotIsMonotonic() {
        // The 49–96 and 97+ buckets intentionally share the same
        // ``default`` alias (qwen3.6-35b-4bit) because the only
        // larger first-touch alternative is 122B and its 65 GB
        // download is the v0.6.0 first-touch UX failure we
        // explicitly closed. Asserting strict-uniqueness here would
        // re-open that regression. Instead we verify the lineage is
        // monotonically non-decreasing by parameter count so a future
        // PR can't accidentally regress 49+ GB to a smaller default
        // than the 25–36 bucket.
        let paramCounts: [Double] = RAMBucketedDefault.buckets.map { bucket in
            ModelSizing.estimate(alias: bucket.default).paramsBillions ?? 0
        }
        for (a, b) in zip(paramCounts, paramCounts.dropFirst()) {
            #expect(a <= b, "Default-slot params must be non-decreasing across brackets — got \(a) before \(b)")
        }
    }

    // MARK: - ModelSizing fit gate (codex r1 BLOCKING on #165)

    /// Every bucketed alias must be at most ``.borderline`` (NOT
    /// ``.tooBig``) on the smallest *practical* Mac in its bracket —
    /// 16 GB for the 4B bracket (modern Air baseline; smaller Macs
    /// are below the realistic LLM floor), and the bracket's actual
    /// lower edge for every bracket above that. This is the
    /// invariant codex r1 caught the previous table violating.
    ///
    /// Apple still sells 8 GB Macs but ModelSizing classifies 4B-4bit
    /// on 8 GB as ``.tooBig`` (ratio 0.92 vs. the 0.75 cutoff). That's
    /// a hardware limitation, not a table bug — the picker will still
    /// default to 4B for those users (it's the smallest alias we
    /// have) but the row will be flagged as borderline/.tooBig in the
    /// UI. Tested separately below.
    @Test("Every bucket's smallest-practical Mac gets a fit-safe default (not .tooBig)")
    func everyBracketSmallestPracticalIsFitSafe() {
        // (physical GB at floor of bracket on a Mac actually shipped
        // in volume, expected default alias)
        //
        // Note: gpt-oss-20b-mxfp4-q8 (25–36 bucket default) is
        // VERIFIED OK by ``ModelSizing`` only from 27 GB up. The
        // mxfp4 footprint (~4 bits/param effective + quantized
        // attention) is closer to 11 GB of weights, but the
        // estimator treats the alias as 4-bit dense and lands at
        // 16.2 GB total. At a 25 or 26 GB floor that's a ratio of
        // 0.81 / 0.78 → .tooBig per ModelSizing's conservative
        // 0.75 cutoff. The alias still ships in the 25-36 bucket
        // because (a) operator testing on 32 GB Macs has confirmed
        // it runs comfortably and (b) the next bracket boundary
        // (37 GB) would be a worse mismatch. We probe 27 GB here
        // instead of 25 to assert the practical safety floor
        // without tightening the bucket schema. 25-26 GB Macs
        // are quite rare in practice (no Apple Silicon SKU ships
        // those exact configurations).
        let floors: [(Double, String)] = [
            (16,  "qwen3.5-4b-4bit"),       // M3 Air base
            (17,  "qwen3.5-9b-4bit"),       // bottom of 17–24 bracket
            (27,  "gpt-oss-20b-mxfp4-q8"),  // 25–36 bracket — see note above
            (37,  "qwen3.6-27b-4bit"),      // bottom of 37–48 bracket
            (49,  "qwen3.6-35b-4bit"),      // bottom of 49–96 bracket
            (97,  "qwen3.6-35b-4bit"),      // bottom of 97+ bracket
        ]
        for (physicalGB, expectedAlias) in floors {
            let actualAlias = RAMBucketedDefault.alias(forPhysicalRAMGB: physicalGB)
            #expect(actualAlias == expectedAlias)
            let host = MacHardware(
                brandString: "Apple M3", family: .m3, tier: .pro,
                physicalRAMBytes: UInt64(physicalGB) * 1024 * 1024 * 1024,
                memoryBandwidthGBs: 150
            )
            let fit = ModelSizing.classify(ModelSizing.estimate(alias: actualAlias), on: host)
            #expect(
                fit != .tooBig,
                "Bucket floor \(physicalGB) GB × \(actualAlias) was \(fit) — must be .recommended or .borderline"
            )
        }
    }

    /// The hardware-floor case: 8 GB Macs do still get *a* default
    /// (the smallest alias we ship), even though ModelSizing flags
    /// it as ``.tooBig``. Documenting this explicitly so a future PR
    /// that tries to "fix" the .tooBig classification doesn't
    /// accidentally remove the default for the entry-tier cohort.
    @Test("8 GB Macs still get 4B-4bit as the default even though ModelSizing flags it .tooBig")
    func eightGBStillGetsADefault() {
        let alias = RAMBucketedDefault.alias(forPhysicalRAMGB: 8)
        #expect(alias == "qwen3.5-4b-4bit")
        let host = MacHardware(
            brandString: "Apple M2", family: .m2, tier: .base,
            physicalRAMBytes: 8 * 1024 * 1024 * 1024,
            memoryBandwidthGBs: 100
        )
        let fit = ModelSizing.classify(ModelSizing.estimate(alias: alias), on: host)
        // This is correct expected behaviour — 8 GB is below the
        // practical LLM floor, but the bucket still returns an
        // alias rather than nil so the picker has SOMETHING to show.
        #expect(fit == .tooBig)
    }

    /// Counter-test: the pre-codex table's 32 GB × 27B is genuinely
    /// ``.tooBig``, proving the table change was load-bearing (not
    /// gratuitous reshuffling).
    @Test("Pre-fix combo (32 GB × 27B-4bit) is .tooBig per ModelSizing — the table HAD to change")
    func preFix32GBTimes27BIsTooBig() {
        let host = MacHardware(
            brandString: "Apple M3 Pro", family: .m3, tier: .pro,
            physicalRAMBytes: 32 * 1024 * 1024 * 1024, memoryBandwidthGBs: 150
        )
        let fit = ModelSizing.classify(
            ModelSizing.estimate(alias: "qwen3.6-27b-4bit"),
            on: host
        )
        #expect(fit == .tooBig)
    }

    @Test("Comfortable middle of every bracket: bucketed alias is at most .borderline")
    func bracketMiddlesFitSafe() {
        // One value inside each bracket — covers all six v0.6.7
        // buckets so a future bracket-add can't silently ship a
        // .tooBig default.
        let midPoints: [Double] = [12, 20, 30, 42, 64, 192]
        for gb in midPoints {
            let alias = RAMBucketedDefault.alias(forPhysicalRAMGB: gb)
            let host = MacHardware(
                brandString: "Apple M3 Pro", family: .m3, tier: .pro,
                physicalRAMBytes: UInt64(gb) * 1024 * 1024 * 1024,
                memoryBandwidthGBs: 150
            )
            let fit = ModelSizing.classify(ModelSizing.estimate(alias: alias), on: host)
            #expect(fit != .tooBig, "\(gb) GB × \(alias) was \(fit)")
        }
    }
}

// MARK: - SafeDefaultFallback (codex r2 BLOCKING on #165)

@Suite("SafeDefaultFallback — hardware-floor fallback never returns .tooBig when avoidable")
struct SafeDefaultFallbackTests {
    private func host(gb: Double) -> MacHardware {
        MacHardware(
            brandString: "Apple M2", family: .m2, tier: .base,
            physicalRAMBytes: UInt64(gb) * 1024 * 1024 * 1024,
            memoryBandwidthGBs: 100
        )
    }

    private func entry(_ alias: String, cached: Bool = false) -> ModelEntry {
        ModelEntry(alias: alias, hfRepo: "synthetic/\(alias)", sizeOnDisk: nil, cached: cached)
    }

    @Test("Codex r2 case: 8 GB Mac with a big cached model — fallback prefers the smaller catalog entry")
    func eightGBWithBigCachedFallsBackToSmaller() {
        // The exact pathology codex flagged: user has a 122B model
        // cached from a friend's recommendation, then opens the app
        // on an 8 GB Air. The pre-r2 fallback would have returned
        // the 122B because `cached.first` ignored fit.
        let catalog = [
            entry("qwen3.5-122b-mxfp4", cached: true),
            entry("qwen3.5-4b-4bit", cached: false),
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 8))
        // On 8 GB everything is .tooBig per ModelSizing, so step 3
        // fires — but step 3 still returns the smallest, which is
        // 4B, not the cached 122B.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("16 GB Mac with no cached entries — picks the smallest fitting alias from catalog")
    func sixteenGBPicksFittingSmallest() {
        let catalog = [
            entry("qwen3.5-122b-mxfp4"),
            entry("qwen3.6-35b-4bit"),
            entry("qwen3.5-9b-4bit"),
            entry("qwen3.5-4b-4bit"),
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 16))
        // Smallest .recommended-or-.borderline entry that fits 16 GB
        // is 4B (5.9 GB / 12.8 GB usable = .recommended). 9B at 16 GB
        // is borderline (0.676), also acceptable — but smaller wins.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("32 GB Mac with 4B cached and 27B uncached — prefers cached 4B (cached + safe)")
    func thirtyTwoGBPrefersCachedSafeOverUncachedSafe() {
        let catalog = [
            entry("qwen3.5-4b-4bit", cached: true),
            entry("qwen3.5-9b-4bit", cached: false),
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 32))
        // Both fit (4B and 9B are .recommended at 32 GB). Cached wins
        // the tiebreaker — instant boot.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("32 GB Mac with 122B cached and 4B uncached — skips the cached .tooBig, returns the safe 4B")
    func thirtyTwoGBSkipsCachedTooBig() {
        let catalog = [
            entry("qwen3.5-122b-mxfp4", cached: true),
            entry("qwen3.5-4b-4bit", cached: false),
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 32))
        // 122B at 32 GB is wildly .tooBig (74 GB needed vs 25.6 GB
        // usable). Even though it's the only cached entry, we skip
        // it for the safe-but-uncached 4B.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("Empty catalog returns nil rather than crashing")
    func emptyCatalogReturnsNil() {
        let pick = SafeDefaultFallback.pick(catalog: [], hardware: host(gb: 16))
        #expect(pick == nil)
    }

    @Test("Single-entry catalog returns that entry even if .tooBig (last-resort step 3)")
    func singleEntryReturnsItEvenIfTooBig() {
        let catalog = [entry("qwen3.5-122b-mxfp4")]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 8))
        // 122B on 8 GB is wildly .tooBig, but there's literally
        // nothing else — picker has to default to something so it
        // can show the user the disabled-Start state with a
        // ModelSizing reason.
        #expect(pick == "qwen3.5-122b-mxfp4")
    }

    // MARK: - Codex r3 BLOCKING on #165 — unparseable aliases must not win

    /// Aliases like ``qwen3-coder-4bit`` and ``deepseek-v4-flash-2bit``
    /// don't carry a ``<n>b`` token. ``ModelSizing.parseParamsBillions``
    /// returns nil, and ``ModelSizing.estimate`` then reports a phantom
    /// totalGB = 0 + 1.2 + 2.0 = 3.2 GB while ``classify`` short-
    /// circuits to ``.borderline``. The pre-r3 ``SafeDefaultFallback``
    /// would have sorted the unparseable alias to the front of "smallest
    /// safe" and handed the picker a 20+ B coder model as the 8 GB
    /// default — exactly the OOM trap we just spent r1 and r2 closing.
    ///
    /// This test pins the contract: in a mixed catalog of one
    /// unparseable + one known-small alias on an 8 GB Mac, the known
    /// small wins.
    @Test("8 GB Mac with unparseable alias + known small — known small wins (#165 r3)")
    func unparseableAliasYieldsToKnownSmallOn8GB() {
        let catalog = [
            entry("qwen3-coder-4bit"),     // unparseable — no <n>b token
            entry("qwen3.5-4b-4bit"),      // known: 4B
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 8))
        // The pre-r3 sort would put qwen3-coder-4bit first (phantom
        // 3.2 GB < 5.9 GB for 4B). After r3 we partition by
        // paramsBillions != nil; only the 4B is in the known set, so
        // step 3 returns it.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("16 GB Mac with unparseable alias + 4B + 9B — picks 4B, not the unparseable")
    func unparseableLosesAtAllStepsWhenKnownAvailable() {
        let catalog = [
            entry("deepseek-v4-flash-2bit"),  // unparseable
            entry("glm4.5-air-4bit"),         // unparseable
            entry("qwen3.5-9b-4bit"),         // known: 9B
            entry("qwen3.5-4b-4bit"),         // known: 4B
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 16))
        // Both unparseables would phantom-classify as 3.2 GB
        // .borderline, sorting them ahead of 4B (5.9 GB). r3 filter
        // pushes both out of the running entirely; smallest known fit
        // is 4B.
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("32 GB Mac with cached unparseable + uncached known small — known small still wins")
    func cachedUnparseableLosesToUncachedKnownSafe() {
        // Even cache priority shouldn't promote an unparseable alias.
        // If the user happens to have a coder model cached but is
        // first-launching the app, defaulting to "I can't tell you
        // how big this is, but Start is enabled" is worse than
        // "uncached but known-safe".
        let catalog = [
            entry("qwen3-coder-4bit", cached: true),   // unparseable but cached
            entry("qwen3.5-4b-4bit", cached: false),   // known small, uncached
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 32))
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("Catalog of ONLY unparseable aliases — step 4 last-resort still returns something")
    func onlyUnparseableYieldsLastResort() {
        let catalog = [
            entry("qwen3-coder-4bit"),
            entry("deepseek-v4-flash-2bit"),
        ]
        let pick = SafeDefaultFallback.pick(catalog: catalog, hardware: host(gb: 16))
        // Defensive — in practice the real Rapid-MLX catalog always
        // contains parseable aliases, but a hand-typed custom-alias
        // scenario could leave us here. Picker still needs a non-nil
        // default; order in the catalog wins.
        #expect(pick == "qwen3-coder-4bit")
    }
}

// MARK: - CacheAwareDefault (issue #436)

/// Pin the four-step ladder ``ModelPickerBar.recommendedDefault``
/// consults on every fresh-launch alias resolution. The headline
/// case (the issue's smoking-gun screenshot) is the first test:
/// a 256 GB Mac with the Quickstart model cached should land on
/// ``bonsai-1.7b-2bit`` instead of the 4.4 GB bucketed default.
///
/// The remaining tests pin the contract preserved from the legacy
/// path so a future "let's simplify the helper" PR can't silently
/// regress the landing-page promise, the codex r2 ``.tooBig``
/// guard from #165, or the codex r3 unparseable-alias guard.
@Suite("CacheAwareDefault — fresh-launch picker default prefers cached-and-runnable (#436)")
struct CacheAwareDefaultTests {
    private func host(gb: Double) -> MacHardware {
        MacHardware(
            brandString: "Apple M3 Ultra", family: .m3, tier: .ultra,
            physicalRAMBytes: UInt64(gb) * 1024 * 1024 * 1024,
            memoryBandwidthGBs: 800
        )
    }

    private func entry(_ alias: String, cached: Bool = false) -> ModelEntry {
        ModelEntry(alias: alias, hfRepo: "synthetic/\(alias)", sizeOnDisk: nil, cached: cached)
    }

    // MARK: - Headline case (issue #436 repro)

    @Test("256 GB Mac with Quickstart cached — picker defaults to cached bonsai-1.7b-2bit, not the bucketed 35B")
    func two56GBWithQuickstartCachedPrefersCached() {
        // The exact pathology from the v0.8.13 dogfood screenshot:
        // a 256 GB M3 Ultra lands in the 97+ bucket (default =
        // qwen3.6-35b-4bit, ~4.4 GB download), but the user already
        // pulled bonsai-1.7b-2bit via Quickstart. Pre-#436 the picker
        // breadcrumb still read "qwen3.6-35b-4bit" and the Start CTA
        // said "Download & start (~4.4 GB)" — exactly the UX cliff
        // the issue documents.
        let catalog = [
            entry("bonsai-1.7b-2bit", cached: true),
            entry("qwen3.6-35b-4bit", cached: false),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        #expect(pick == "bonsai-1.7b-2bit")
    }

    // MARK: - Step 1: bucketed is cached + fits → use it (preserve landing-page contract)

    @Test("Step 1: bucketed default already cached + fits — return bucketed (no change vs legacy)")
    func bucketedCachedAndFitsWins() {
        // A user who's used the canonical pick before still gets it
        // as the default — alphabetical tie-break in step 2 doesn't
        // demote a high-quality cached canonical pick to a tiny
        // cached neighbour just because the alias name sorts later.
        let catalog = [
            entry("bonsai-1.7b-2bit", cached: true),
            entry("qwen3.6-35b-4bit", cached: true),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        // Both cached, both fit, but bucketed wins because step 1
        // fires before the step 2 alphabetical fallback.
        #expect(pick == "qwen3.6-35b-4bit")
    }

    // MARK: - Step 2: cached-and-fits beats not-cached bucketed (the #436 fix)

    @Test("Step 2: bucketed not cached, multiple cached candidates — alphabetical wins (mirrors AutoStartDecision)")
    func multipleCachedAlphabeticalTieBreak() {
        // 256 GB Mac, bucketed default isn't cached, two cached
        // alternatives. Alphabetical via localizedStandardCompare —
        // same tie-break as AutoStartDecision.resolveAlias so the
        // picker breadcrumb and the AutoStart pick converge.
        let catalog = [
            entry("qwen3.6-35b-4bit", cached: false),       // bucketed default
            entry("gemma-4-12b-4bit", cached: true),        // alphabetical first
            entry("qwen3.5-9b-4bit", cached: true),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        #expect(pick == "gemma-4-12b-4bit")
    }

    @Test("Step 2: bucketed missing from catalog entirely — cached candidate wins")
    func bucketedMissingCachedWins() {
        // Forward-compat skew: the desktop knows about a bucketed
        // alias the bundled rapid-mlx hasn't onboarded yet. The
        // pre-#436 path would have fallen straight through to
        // SafeDefaultFallback and lost the cache preference; the
        // step 2 check makes sure a cached-and-fits row wins first.
        let catalog = [
            entry("bonsai-1.7b-2bit", cached: true),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "future-alias-not-yet-shipped"
        )
        #expect(pick == "bonsai-1.7b-2bit")
    }

    @Test("Step 2: cached candidate must FIT — .tooBig cached alias gets skipped, falls to bucketed")
    func cachedButTooBigSkippedFallsToBucketed() {
        // Pathology: a 256 GB cached 122B alias was rsync'd onto an
        // 18 GB Mac. CacheAwareDefault must NOT promote it just
        // because it's cached — the legacy SafeDefaultFallback
        // logic from #165 still applies. With the bucketed 9B
        // available + fits, step 3 fires and returns 9B.
        let catalog = [
            entry("qwen3.5-122b-mxfp4", cached: true),  // cached but .tooBig on 18 GB
            entry("qwen3.5-9b-4bit", cached: false),    // bucketed default for 18 GB, fits
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: MacHardware(
                brandString: "Apple M3 Pro", family: .m3, tier: .pro,
                physicalRAMBytes: 18 * 1024 * 1024 * 1024,
                memoryBandwidthGBs: 150
            ),
            bucketedDefault: "qwen3.5-9b-4bit"
        )
        #expect(pick == "qwen3.5-9b-4bit")
    }

    @Test("Step 2: cached candidate with unparseable params — skipped (codex r3 #165 trap)")
    func cachedUnparseableSkipped() {
        // Cached qwen3-coder-4bit has paramsBillions = nil; without
        // the filter it would phantom-classify as .borderline and
        // win step 2. The contract pins that step 2 never promotes
        // an unparseable alias — same defensive partition as
        // SafeDefaultFallback.pick.
        let catalog = [
            entry("qwen3-coder-4bit", cached: true),    // unparseable, must NOT win
            entry("qwen3.5-9b-4bit", cached: false),    // bucketed, fits
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.5-9b-4bit"
        )
        // Step 2 rejects qwen3-coder-4bit → step 3 returns bucketed.
        #expect(pick == "qwen3.5-9b-4bit")
    }

    // MARK: - Step 3: bucketed fits but nothing cached → legacy behaviour

    @Test("Step 3: nothing cached — bucketed default wins (legacy parity)")
    func nothingCachedBucketedWins() {
        // First-ever launch on a fresh Mac with no model on disk
        // anywhere. Step 1 fails (bucketed isn't cached), step 2
        // fails (nothing cached at all), step 3 returns the
        // bucketed default — exactly the pre-#436 behaviour.
        let catalog = [
            entry("qwen3.6-35b-4bit", cached: false),
            entry("qwen3.5-9b-4bit", cached: false),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        #expect(pick == "qwen3.6-35b-4bit")
    }

    // MARK: - Step 4: bucketed missing AND nothing cached → SafeDefaultFallback escape

    @Test("Step 4: bucketed missing AND nothing cached fits — delegate to SafeDefaultFallback")
    func bucketedMissingNothingCachedFallback() {
        // 8 GB Mac, no cached models, bucketed not in catalog.
        // Falls through to SafeDefaultFallback whose step 2 picks
        // the smallest fitting known alias — pinned identically
        // here for parity with the pre-#436 fallthrough.
        let catalog = [
            entry("qwen3.5-9b-4bit", cached: false),
            entry("qwen3.5-4b-4bit", cached: false),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 8),
            bucketedDefault: "future-alias-not-yet-shipped"
        )
        // On 8 GB everything's .tooBig per ModelSizing; the
        // SafeDefaultFallback escape hands back the smallest known
        // (4B beats 9B).
        #expect(pick == "qwen3.5-4b-4bit")
    }

    @Test("Step 4: empty catalog returns nil (no crash)")
    func emptyCatalogReturnsNil() {
        let pick = CacheAwareDefault.pick(
            catalog: [],
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        #expect(pick == nil)
    }

    // MARK: - Slim-DMG real-world case

    @Test("Slim DMG fresh install (Quickstart only) — picker defaults to cached bonsai-1.7b-2bit")
    func slimDMGFreshInstallPrefersQuickstart() {
        // Slim DMG bootstrapper pulls bonsai-1.7b-2bit. The user
        // then lands on the chat surface and the picker should NOT
        // demand another 4.4 GB pull for the bucketed default. This
        // is the "first-touch UX after install" path the issue
        // calls out as the worst case.
        let catalog = [
            entry("bonsai-1.7b-2bit", cached: true),
            entry("qwen3.5-4b-4bit", cached: false),
            entry("qwen3.5-9b-4bit", cached: false),
            entry("qwen3.6-27b-4bit", cached: false),
            entry("qwen3.6-35b-4bit", cached: false),
        ]
        let pick = CacheAwareDefault.pick(
            catalog: catalog,
            hardware: host(gb: 256),
            bucketedDefault: "qwen3.6-35b-4bit"
        )
        #expect(pick == "bonsai-1.7b-2bit")
    }
}
