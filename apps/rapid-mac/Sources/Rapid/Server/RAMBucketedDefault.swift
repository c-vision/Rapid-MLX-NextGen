import Foundation

/// Pure RAM bracket → curated role-based alias mapping for the
/// first-launch "what model should this Mac default to" decision
/// (issue #163) plus the "what should we recommend across roles"
/// expansion (v0.6.7).
///
/// This intentionally lives next to ``MacHardware`` and ``ModelSizing``
/// but does NOT consult them — the mapping is policy, expressed in
/// gibibytes only, so it stays trivially unit-testable without a
/// sysctl probe.
///
/// ## Why a hard bracket table instead of "largest fitting model"
///
/// The picker used to surface a ranked-by-fit list with 🔴/🟡/🟢
/// warning icons (``ModelSizing.classify``). That worked, but it had
/// two failure modes the v0.6.7 UX walk surfaced:
///
/// 1. **Decision fatigue.** "Here are 47 aliases; you can probably
///    only run 12 of them; pick one" is a worse first-touch than
///    "here are 5 hand-picked models, one per role".
/// 2. **Warning-icon noise.** The 🔴 / 🟡 / 🟢 dots on every row
///    read as "danger / caution / safe" — but the table beneath
///    promised the user "we've picked these for your Mac". Mixing
///    a recommendation with a per-row hazard pictogram on the same
///    surface gave conflicting signals.
///
/// v0.6.7 replaces both with **five role-specific recommendations
/// per RAM bucket**: ``default``, ``speed``, ``quality``, ``coding``,
/// ``multimodal``. The user sees one row per role, all hand-curated
/// to fit, no warnings. The "All aliases" section is still there for
/// power users but without the noisy per-row fit warnings — an alias
/// that exceeds usable RAM gets dimmed text and an inline "may not
/// fit on your Mac" tooltip instead.
///
/// ## Brackets
///
/// This is a 6-bucket × 5-role matrix and is the **source of truth
/// for the in-app picker**. The marketing site (rapidmlx.com) has
/// **no role/Speed table** — it publishes only a single
/// best-model-per-RAM table (the `fits-table` in
/// `landing/public/index.html` plus the identical "Pick by Mac RAM"
/// widget in `models-worker`). That table is the same *axis* as the
/// ``default`` role here (one best model per RAM), not the per-role
/// picks — but its exact values are curated separately and can drift
/// from this file's ``default`` column. So a change to a
/// non-``default`` role (e.g. the v0.8.18 Speed demotion) has
/// nothing to mirror on the site, and even the ``default`` values
/// are not guaranteed to be identical: the site currently leans
/// *aspirational* on the largest buckets (Qwen3.5-122B at 96 GB, a
/// day-0 frontier MoE at 128 GB, and a larger 35B-A3B already at
/// 48 GB) while the app's first-touch default prefers a
/// faster-to-download Qwen3.6 27B / 35B-A3B. Treat THIS file as the
/// source of truth for the in-app picker and reconcile the site
/// deliberately rather than assuming they are locked together
/// (see rapid-desktop #469).
///
/// | RAM (GB)   | Default               | Speed                | Quality               | Coding                              | Multimodal           |
/// | ---------- | --------------------- | -------------------- | --------------------- | ----------------------------------- | -------------------- |
/// | ≤ 16       | qwen3.5-4b-4bit       | phi-4-mini-4bit      | qwen3.5-9b-4bit       | qwen3.5-4b-4bit                     | qwen3-vl-4b-4bit     |
/// | 17 – 24    | qwen3.5-9b-4bit       | qwen3.5-4b-4bit      | gemma-4-12b-4bit      | devstral-v2-24b-4bit                | qwen3-vl-8b-4bit     |
/// | 25 – 36    | gpt-oss-20b-mxfp4-q8  | qwen3.5-4b-4bit      | gemma-4-26b-4bit      | deepseek-coder-v2-lite-16b-4bit     | qwen3-vl-8b-4bit     |
/// | 37 – 48    | qwen3.6-27b-4bit      | qwen3.5-4b-4bit      | gemma-4-31b-4bit      | qwen3-coder-30b-4bit                | qwen3-vl-30b-4bit    |
/// | 49 – 96    | qwen3.6-35b-4bit      | qwen3.5-4b-4bit      | qwen3.6-35b-8bit      | qwen3-coder-30b-4bit                | qwen3-vl-30b-4bit    |
/// | 97+        | qwen3.6-35b-4bit      | qwen3.5-4b-4bit      | qwen3.5-122b-8bit     | qwen3-coder-30b-4bit                | qwen3-vl-30b-4bit    |
///
/// Boundaries were tuned against ``ModelSizing.classify`` so the
/// bucketed alias on the BOTTOM of each bracket is at most
/// ``.borderline`` (will run, won't OOM). The thresholds are
/// inclusive at the top and exclusive at the bottom
/// (`> previous && ≤ current`).
///
/// **Note on duplicates inside a bucket:** at ≤ 16 GB the
/// ``coding`` slot intentionally reuses the ``default`` alias —
/// there's no purpose-built code model small enough to fit a 16 GB
/// Mac safely. The 17–24 GB ``coding`` slot graduated to
/// ``devstral-v2-24b-4bit`` in the v0.7.16 rework: borderline-fit
/// at the bucket floor but the audit (`/tmp/model-recs-audit.md`)
/// explicitly chose distinctiveness over duplication, so all five
/// recommended rows now read as different aliases on the user's
/// 18 GB MBP.
///
/// **Speed slot rework (v0.8.18):** the ``speed`` pick is now the
/// fastest alias that is STILL COHERENT in multi-turn chat —
/// ``qwen3.5-4b-4bit`` (~158 t/s, MMLU-Pro+GPQA 65.8) on every
/// bucket except ≤ 16 GB, where it would duplicate the ``default``
/// so we use the near-identical-speed ``phi-4-mini-4bit`` (~159 t/s,
/// 44.9) instead.
///
/// The previous pick, ``gemma3-1b-qat-4bit`` (~262 t/s, 0.7 GB),
/// was demoted out of every recommendation. It is genuinely fast
/// but its benchmark scores (general reasoning 17.0, code 1.9 — at
/// or below random-guess on GPQA) make it incoherent for real chat:
/// the v0.8.17 dogfood caught it hallucinating tool responses and
/// repeating boilerplate to every follow-up. Trading 100 t/s for a
/// model that 4× the reasoning score is the right call; "Speed" must
/// still mean a usable model. ``gemma3-1b-qat-4bit`` remains in the
/// "All aliases" list for power users who explicitly want it.
///
/// The capability drop relative to ``default`` is still acknowledged
/// in ``Role.blurb`` so the user knows what they're picking.
///
/// ## Why the default slot collapses 49+ GB into 35B-A3B
///
/// v0.5.22 / v0.6.0 had a fifth bucket at 128+ GB → ``qwen3.5-
/// 122b-mxfp4`` (~65 GB download). The v0.6.0 N2N walk surfaced this
/// as the dominant first-touch UX failure: a fresh M3 Ultra user
/// gets handed a 65 GB download and either waits 30+ minutes or
/// quits before the chat surface responds.
///
/// 35B-A3B (~18 GB, A3B = 3B active params at decode) runs at
/// near-122B quality on Apple Silicon and finishes downloading in
/// 3–5 minutes on most home connections. 122B stays selectable —
/// it's the ``quality`` slot in the 97+ GB bucket — but it's no
/// longer the first-touch default for any bucket.
enum RAMBucketedDefault {
    /// Roles the picker recommends one alias per. ``default`` is the
    /// best all-around starter; the others answer specific user
    /// questions ("what's fastest?", "what's best?", etc.).
    enum Role: String, CaseIterable, Sendable {
        case `default`
        case speed
        case quality
        case coding
        case multimodal

        /// Short label shown next to the alias in the picker.
        var label: String {
            switch self {
            case .default:     return "Default"
            case .speed:       return "Speed"
            case .quality:     return "Quality"
            case .coding:      return "Coding"
            case .multimodal:  return "Vision"
            }
        }

        /// One-line description shown beneath the label.
        ///
        /// v0.7.16 tightened the speed / quality / coding blurbs to
        /// be honest about the tradeoff each pick makes. v0.8.18
        /// dropped the "Tiny" wording from the speed blurb: the speed
        /// pick is now a ~4B model (``qwen3.5-4b-4bit`` /
        /// ``phi-4-mini-4bit``) rather than a 1B, so it's "light +
        /// fast" but no longer "tiny", and — unlike the demoted
        /// ``gemma3-1b-qat-4bit`` — actually coherent in chat.
        var blurb: String {
            switch self {
            case .default:    return "Best balance for your Mac — what we'd pick first"
            case .speed:      return "Light + fast. Trades some depth for snappiness."
            case .quality:    return "Highest-scoring model that fits on your Mac — slower, smarter."
            case .coding:     return "Best coding-bench score that fits — picks like a code reviewer."
            case .multimodal: return "Accepts text + image input"
            }
        }

        /// Blurb augmented with the per-bucket speed pick's measured
        /// long-decode tok/s (Apple M3 Ultra) — surfaces on the speed
        /// row's subtitle so a 18 GB MBP user (speed pick
        /// ``qwen3.5-4b-4bit``) sees
        ///   "Light + fast (~158 t/s). Trades some depth for snappiness."
        /// rather than the generic blurb. Returns the un-augmented
        /// ``blurb`` for any role other than ``.speed`` or when the
        /// bench JSON has no measured tok/s for the alias yet.
        ///
        /// Lives next to ``blurb`` so a future contributor adding a
        /// new role can wire it in one place.
        func blurb(forSpeedAlias alias: String) -> String {
            if self == .speed,
               let scores = BenchScoresCatalog.lookup(alias: alias),
               let tps = scores.speedTps {
                return "Light + fast (~\(Int(tps.rounded())) t/s). Trades some depth for snappiness."
            }
            return blurb
        }
    }

    /// One curated recommendation per role, anchored to a RAM bracket.
    /// ``upperGB`` is the inclusive upper bound (a Mac at exactly that
    /// RAM lands in this bucket). Every alias key must exist in the
    /// rapid-mlx ``aliases.json`` — verified by
    /// ``ModelRecommendationsTests`` against the bundled submodule.
    struct Bucket: Sendable, Equatable {
        let upperGB: Double
        let `default`: String
        let speed: String
        let quality: String
        let coding: String
        let multimodal: String

        /// Lookup by role — keeps callers from having to switch on
        /// every role themselves.
        func alias(for role: Role) -> String {
            switch role {
            case .default:    return self.default
            case .speed:      return self.speed
            case .quality:    return self.quality
            case .coding:     return self.coding
            case .multimodal: return self.multimodal
            }
        }
    }

    /// Source of truth — kept tiny so a recommendation change is a
    /// one-line edit here, verified by ``RAMBucketedDefaultTests``
    /// + ``ModelRecommendationsTests`` in one PR. (The marketing
    /// site tracks only the ``default`` axis, not this whole matrix,
    /// and can drift even there — see the type docstring +
    /// rapid-desktop #469.)
    ///
    /// Coding role reuses the bucket ``default`` on ≤ 24 GB: there is
    /// no purpose-built coder that both fits safely at the bucket floor
    /// AND emits well-formed ``tool_calls``. ≤ 16 GB has no small coder
    /// at all; the 17–24 GB slot USED to graduate to
    /// ``devstral-v2-24b-4bit`` (v0.7.16) but the 2026-07-09
    /// recommended-model tool-usability sweep found every Mistral-family
    /// alias mis-parses its ``[TOOL_CALLS]…[ARGS]{…}`` output (the alias
    /// ships ``tool_call_parser=hermes`` in the bundled engine; the model
    /// is fine, the config is wrong) → 6/6 schema-leak on a tools-on
    /// prompt. Until the engine parser is fixed (tracked upstream), the
    /// slot falls back to the verified ``qwen3.5-9b-4bit`` default.
    /// 25 GB+ fits ``qwen3-coder-30b-4bit`` (the headline coder,
    /// swept 6/6). The 25–36 GB slot previously pointed at
    /// ``deepseek-coder-v2-lite-16b-4bit`` which the same sweep found
    /// invents ad-hoc tool names with no parser wired up (6/6 leak).
    ///
    /// Speed role points at the fastest alias that is still coherent in
    /// chat AND tool-capable: ``qwen3.5-4b-4bit`` (~158 t/s) on EVERY
    /// bucket. ≤ 16 GB previously used ``phi-4-mini-4bit`` (~159 t/s)
    /// for a distinct-from-Default row, but the 2026-07-09 sweep found
    /// phi-4-mini flatly refuses tool-eligible prompts ("I'm sorry, but
    /// I can't assist with that", 6/6) — and at ~1 t/s faster it bought
    /// no real speed. Dropped in favour of the verified
    /// ``qwen3.5-4b-4bit`` even though it now duplicates the Default row
    /// on ≤ 16 GB — a tool-capable duplicate beats a distinct model that
    /// breaks the Tools flow. v0.8.18 had already demoted
    /// ``gemma3-1b-qat-4bit`` (~262 t/s but benchmark reasoning 17.0 /
    /// code 1.9 — incoherent in real chat) out of every recommendation;
    /// it stays in the "All aliases" list for power users. The
    /// capability drop relative to Default is acknowledged in
    /// ``Role.blurb``.
    ///
    /// Every alias in this table was run end-to-end (2-turn plain chat +
    /// 6 tool-eligible prompts through the real desktop wire —
    /// ``toolGuidancePreamble`` + ``web_search`` schema +
    /// ``tool_choice: auto``) on the 2026-07-09 sweep; only aliases that
    /// emitted well-formed ``tool_calls`` (no schema-leak, no refusal)
    /// are surfaced here. ``qwen3.5-122b-8bit`` is family-inferred from
    /// its verified 4B/9B hermes siblings.
    static let buckets: [Bucket] = [
        // ≤ 16 GB
        Bucket(
            upperGB: 16,
            default:    "qwen3.5-4b-4bit",
            speed:      "qwen3.5-4b-4bit",   // reuse default — no faster tool-capable alias fits (was phi-4-mini, dropped: refuses tools)
            quality:    "qwen3.5-9b-4bit",
            coding:     "qwen3.5-4b-4bit",   // intentional reuse — no small coder fits
            multimodal: "qwen3-vl-4b-4bit"
        ),
        // 17 – 24 GB
        Bucket(
            upperGB: 24,
            default:    "qwen3.5-9b-4bit",
            speed:      "qwen3.5-4b-4bit",
            quality:    "gemma-4-12b-4bit",
            coding:     "qwen3.5-9b-4bit",   // reuse default — no dedicated coder both fits ≤24 GB AND tool-calls (was devstral-v2-24b, dropped: engine parser misconfig leaks)
            multimodal: "qwen3-vl-8b-4bit"
        ),
        // 25 – 36 GB
        Bucket(
            upperGB: 36,
            default:    "gpt-oss-20b-mxfp4-q8",
            speed:      "qwen3.5-4b-4bit",
            quality:    "gemma-4-26b-4bit",
            coding:     "qwen3-coder-30b-4bit",   // was deepseek-coder-v2-lite-16b, dropped: invents tool names + parser=None → 6/6 leak
            multimodal: "qwen3-vl-8b-4bit"
        ),
        // 37 – 48 GB
        Bucket(
            upperGB: 48,
            default:    "qwen3.6-27b-4bit",
            speed:      "qwen3.5-4b-4bit",
            quality:    "gemma-4-31b-4bit",
            coding:     "qwen3-coder-30b-4bit",
            multimodal: "qwen3-vl-30b-4bit"
        ),
        // 49 – 96 GB
        Bucket(
            upperGB: 96,
            default:    "qwen3.6-35b-4bit",
            speed:      "qwen3.5-4b-4bit",
            quality:    "qwen3.6-35b-8bit",
            coding:     "qwen3-coder-30b-4bit",
            multimodal: "qwen3-vl-30b-4bit"
        ),
        // 97+ GB
        Bucket(
            upperGB: .infinity,
            default:    "qwen3.6-35b-4bit",
            speed:      "qwen3.5-4b-4bit",
            quality:    "qwen3.5-122b-8bit",
            coding:     "qwen3-coder-30b-4bit",
            multimodal: "qwen3-vl-30b-4bit"
        ),
    ]

    /// The bracket a Mac with ``physicalRAMGB`` lands in. Always
    /// returns something — the last bucket has an infinite upper
    /// bound. Negative inputs (impossible in practice) fall into the
    /// smallest bucket.
    static func bucket(forPhysicalRAMGB physicalRAMGB: Double) -> Bucket {
        for bucket in buckets where physicalRAMGB <= bucket.upperGB {
            return bucket
        }
        // Unreachable because the last bucket's upperGB is .infinity,
        // but Swift's type system can't prove that — return the
        // largest bracket explicitly so adding a finite-cap bucket
        // at the end of the table doesn't silently change behaviour.
        return buckets.last ?? buckets[0]
    }

    /// Bracketed default alias for a Mac with ``physicalRAMGB`` —
    /// kept for ``ServerManager`` / first-launch callers that only
    /// need the ``.default`` slot. Internally just looks up the
    /// bucket and reads the default role.
    static func alias(forPhysicalRAMGB physicalRAMGB: Double) -> String {
        bucket(forPhysicalRAMGB: physicalRAMGB).default
    }

    /// Full role → alias map for a Mac with ``physicalRAMGB``. Drives
    /// the picker's "Recommended for your N GB Mac" five-row section.
    /// Every role is populated; some roles intentionally share an
    /// alias on smaller buckets (see ``buckets`` docstring).
    static func recommendations(forPhysicalRAMGB physicalRAMGB: Double) -> [Role: String] {
        let b = bucket(forPhysicalRAMGB: physicalRAMGB)
        return [
            .default:    b.default,
            .speed:      b.speed,
            .quality:    b.quality,
            .coding:     b.coding,
            .multimodal: b.multimodal,
        ]
    }

    /// Ordered version of ``recommendations`` — preserves the role
    /// display order (default → speed → quality → coding → multimodal)
    /// for callers that need to render the rows top-to-bottom.
    static func orderedRecommendations(forPhysicalRAMGB physicalRAMGB: Double) -> [(Role, String)] {
        let b = bucket(forPhysicalRAMGB: physicalRAMGB)
        return Role.allCases.map { ($0, b.alias(for: $0)) }
    }
}

extension MacHardware {
    /// Convenience pass-through so ``ModelPickerBar`` doesn't have to
    /// know that the alias decision is RAM-only. Lets a future
    /// refinement also consider chip generation / bandwidth without
    /// touching the call site.
    var bucketedDefaultAlias: String {
        RAMBucketedDefault.alias(forPhysicalRAMGB: physicalRAMGB)
    }

    /// Role-anchored recommendations shown as cards/rows in the
    /// "Recommended for your N GB Mac" section (picker + Model
    /// Management). Vision (``.multimodal``) is intentionally excluded:
    /// first-party vision support is weak, so it was dropped as a
    /// recommended role in the v0.10 Model Management redesign. VL
    /// models stay downloadable via the full catalog (they carry a
    /// VISION badge in "All models"); only the *recommendation* is
    /// suppressed. The ``.multimodal`` slot remains populated in
    /// ``RAMBucketedDefault/recommendations(forPhysicalRAMGB:)`` as
    /// data. This is the single source of truth for the four-role
    /// recommendation set (Default / Speed / Quality / Coding) — both
    /// the picker and the Model Management panel consume it, so they can
    /// never drift on which roles show. Callers may still dedupe by
    /// alias (a ≤16 GB bucket reuses the Default alias for Coding), so
    /// the rendered row count can be fewer than four.
    var bucketedRecommendations: [(RAMBucketedDefault.Role, String)] {
        RAMBucketedDefault.orderedRecommendations(forPhysicalRAMGB: physicalRAMGB)
            .filter { $0.0 != .multimodal }
    }
}

/// Codex r2 BLOCKING on PR #165. When the bucketed alias is rejected
/// as ``.tooBig`` AND ``sortedRecommended`` is empty (the hardware-
/// floor case: 8 GB Mac, or a future ultra-low-RAM iPad-class
/// device), the picker's original "cached.first ?? catalog.first"
/// fallback could silently re-pick a ``.tooBig`` alias if the user
/// happened to have a large model cached from a previous session.
/// That reintroduces the OOM the codex r1 fix was supposed to close.
///
/// This helper walks the catalog in three priority steps:
///
///   1. **Cached + not-`.tooBig`.** Instant boot, safe to run.
///   2. **Not-`.tooBig` by smallest footprint.** May not be cached
///      but is at least within the ModelSizing budget.
///   3. **Smallest catalog entry overall.** Hardware-floor escape —
///      every alias is `.tooBig` on this Mac, so we hand back the
///      smallest one so the picker still has SOMETHING to default
///      to. The UI will mark the row borderline/warning per its
///      existing per-row classification; this helper just avoids
///      handing back a 122B alias when a 4B alias is sitting next
///      to it.
///
/// Tested directly in ``RAMBucketedDefaultTests`` via a synthetic
/// catalog + hardware fixture; the private ``recommendedDefault``
/// in ``ModelPickerBar`` would otherwise be impossible to unit test
/// without a SwiftUI driver.
enum SafeDefaultFallback {
    static func pick(catalog: [ModelEntry], hardware: MacHardware) -> String? {
        // Codex r3 BLOCKING on #165: ``ModelSizing.estimate`` returns
        // ``paramsBillions == nil`` for aliases like
        // ``qwen3-coder-4bit`` / ``deepseek-v4-flash-2bit`` /
        // ``glm4.5-air-4bit`` where the parameter count isn't a
        // ``<number>b`` token. Those nil-param footprints come out
        // at totalGB = 0 + 1.2 + 2.0 = 3.2 GB and ``classify`` short-
        // circuits to ``.borderline`` — so a naive "sort by total
        // footprint" would float a 20 B coder model ABOVE the known
        // 5.9 GB 4B as the safest default on an 8 GB Mac. The picker
        // would then offer Start on an alias whose real footprint
        // could be 12+ GB, OOMing the Mac.
        //
        // Partition into "known params" and "unknown params" up front
        // and rank known first. Unknown-params aliases are only the
        // absolute last resort (catalog contains nothing else).
        let known = catalog.filter {
            ModelSizing.estimate(alias: $0.alias).paramsBillions != nil
        }
        let unknown = catalog.filter {
            ModelSizing.estimate(alias: $0.alias).paramsBillions == nil
        }

        // Step 1: cached + safe (only over the known-params subset).
        if let safeCached = known.filter(\.cached)
            .first(where: { isSafe($0, on: hardware) }) {
            return safeCached.alias
        }
        // Step 2: smallest known-params alias that fits.
        let knownBySize = known.sorted { lhs, rhs in
            ModelSizing.estimate(alias: lhs.alias).totalGB
                < ModelSizing.estimate(alias: rhs.alias).totalGB
        }
        if let safe = knownBySize.first(where: { isSafe($0, on: hardware) }) {
            return safe.alias
        }
        // Step 3: smallest known-params alias overall (.tooBig but
        // we know what we're getting).
        if let smallestKnown = knownBySize.first {
            return smallestKnown.alias
        }
        // Step 4: catalog has zero parseable aliases. Last resort —
        // hand back the first unknown-params row so the picker has
        // SOMETHING. In practice this branch is unreachable on the
        // real Rapid-MLX catalog (every alias carries a `<n>b` token
        // somewhere) but we keep it for forward-compat with future
        // custom-alias entries the user types in by hand.
        return unknown.first?.alias
    }

    private static func isSafe(_ entry: ModelEntry, on hardware: MacHardware) -> Bool {
        ModelSizing.classify(ModelSizing.estimate(alias: entry.alias), on: hardware) != .tooBig
    }
}

/// Issue #436: pick a fresh-launch picker default that prefers a
/// cached-and-fits alias when the RAM-bucketed default isn't on
/// disk yet. Closes the post-Quickstart UX cliff where a 256 GB
/// M3 Ultra user with ``bonsai-1.7b-2bit`` already pulled to the
/// HF cache still saw a 4.4 GB "Download & start qwen3.6-35b-4bit"
/// CTA — the Quickstart promise ("5-second time-to-first-token")
/// silently lost to the RAM-bucketed default because
/// ``ModelPickerBar.recommendedDefault`` consulted the bucket
/// table without ever checking ``ModelEntry.cached``.
///
/// ## Decision ladder
///
/// 1. **Bucketed default is in catalog AND cached AND fits.** Use it.
///    No surprise — when the high-quality canonical pick is already
///    on disk, the user gets it with zero download (the Quickstart
///    "5-second time-to-first-token" instant-start experience). This
///    is about download cost, not about matching any site table —
///    the canonical pick is defined by this file (see type docstring).
/// 2. **Bucketed isn't cached but ≥1 cached-and-fits alias exists.**
///    Prefer the cached alternative. The user paid for those bytes
///    already; surfacing the 4.4 GB CTA when a runnable model is
///    sitting two clicks away (open picker → pick row → start) is
///    the exact UX cliff the issue documents.
/// 3. **Bucketed default is in catalog AND fits.** Use it. Nothing
///    cached fits, but the canonical pick still runs on this Mac —
///    legacy behaviour preserved.
/// 4. **Bucketed default is ``.tooBig`` OR missing from catalog.**
///    Delegate to ``SafeDefaultFallback`` (the codex r2/r3 hardware-
///    floor escape from #165 — never returns a ``.tooBig`` alias
///    when a smaller one is available, and partitions out
///    unparseable aliases so a coder/flash quant doesn't phantom-
///    classify as small).
///
/// ## Why alphabetical tie-break inside the cached set
///
/// ``localizedStandardCompare`` mirrors ``ModelCatalog.load``'s
/// post-cached sort and ``AutoStartDecision.resolveAlias``'s
/// first-cached fallback — three surfaces, one tie-break. A
/// 256 GB Mac with both ``bonsai-1.7b-2bit`` and ``qwen3.6-35b-4bit``
/// cached would land on ``bonsai-1.7b-2bit`` (alphabetically first),
/// instant-boot. The user swaps via the picker the moment they
/// want the larger model — same affordance as today, but
/// without paying a multi-GB download just to swap back to a
/// model that was already on disk.
///
/// "Smallest by footprint" was considered and rejected — on a
/// catalog where every cached alias has a real ``<n>b`` token the
/// two heuristics converge for the dominant Quickstart case
/// (bonsai-1.7b-2bit wins on both), and alphabetical avoids the
/// estimator-overhead the picker doesn't otherwise need on the
/// hot path.
///
/// ## Why we filter out unparseable-params aliases for step 2
///
/// ``ModelSizing.estimate(alias:).paramsBillions == nil`` (e.g.
/// ``qwen3-coder-4bit`` / ``deepseek-v4-flash-2bit``) phantom-
/// classifies as ``.borderline`` everywhere — see the codex r3
/// rationale on ``SafeDefaultFallback``. If we let those into the
/// cached-and-fits set, a 16 GB Mac with a stray cached coder
/// quant would default to it and silently OOM on Start. The
/// partition mirrors ``SafeDefaultFallback.pick``'s own
/// known-params filter so both helpers refuse the same trap.
///
/// ## Pure-function contract
///
/// Inputs are values, no FS / sysctl / catalog probes. Caller
/// (``ModelPickerBar``) computes ``catalog`` from
/// ``ModelCatalog.load`` and ``hardware`` from ``MacHardware.detect``
/// once and threads the snapshot in. Tested directly in
/// ``CacheAwareDefaultTests``.
enum CacheAwareDefault {
    static func pick(
        catalog: [ModelEntry],
        hardware: MacHardware,
        bucketedDefault: String
    ) -> String? {
        let bucketedEntry = catalog.first(where: { $0.alias == bucketedDefault })
        let bucketedFits = bucketedEntry.map { isSafe($0, on: hardware) } ?? false

        // Step 1: bucketed default is on disk AND runnable. No
        // surprise — high-quality canonical pick wins.
        if let entry = bucketedEntry, entry.cached, bucketedFits {
            return bucketedDefault
        }

        // Step 2: any cached + fits alternative — prefer it over a
        // bucketed alias that would trigger a multi-GB pull. Filter
        // out unparseable-params aliases so a cached coder/flash
        // quant doesn't phantom-classify as small and land us in an
        // OOM (codex r3 on #165).
        let cachedCandidates = catalog
            .filter { $0.cached }
            .filter { ModelSizing.estimate(alias: $0.alias).paramsBillions != nil }
            .filter { isSafe($0, on: hardware) }
        if let pick = firstAlphabetical(cachedCandidates) {
            return pick
        }

        // Step 3: nothing cached fits, but the canonical pick still
        // runs on this Mac → legacy bucketed-default branch.
        if bucketedEntry != nil, bucketedFits {
            return bucketedDefault
        }

        // Step 4: bucketed is .tooBig OR missing — hand off to the
        // existing hardware-floor escape so we never silently
        // promote a .tooBig cached alias above a safe one.
        return SafeDefaultFallback.pick(catalog: catalog, hardware: hardware)
    }

    private static func isSafe(_ entry: ModelEntry, on hardware: MacHardware) -> Bool {
        ModelSizing.classify(
            ModelSizing.estimate(alias: entry.alias),
            on: hardware
        ) != .tooBig
    }

    private static func firstAlphabetical(_ entries: [ModelEntry]) -> String? {
        entries
            .map(\.alias)
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            .first
    }
}
