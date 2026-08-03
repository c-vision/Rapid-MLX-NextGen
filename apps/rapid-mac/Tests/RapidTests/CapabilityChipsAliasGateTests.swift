import Foundation
import Testing
@testable import Rapid

/// #133 contract — the empty-state capability chips MUST gate on the
/// active alias's ``ToolUseCapability``. The pre-fix surface advertised
/// four tool-promising chips (Search the web / Calculate / Weather /
/// Read files) on EVERY render, regardless of whether the active
/// rapid-mlx alias actually emits well-formed ``tool_calls``. Issue
/// #133 caught the cliff: a user picks ``phi-4-mini-reasoning-4bit``
/// (or any ``.broken`` alias), clicks "Weather", and gets back an empty
/// assistant bubble — the model spends all of its completion budget
/// inside ``reasoning_content`` that never terminates into a function
/// call. Pure over-promise on the first interactive surface a new user
/// touches.
///
/// The fix routes the chip set through a pure helper
/// (``ChatView.capabilityChipKinds(forAlias:)``) that consults
/// ``ToolUseCapability.confidence(for:)`` and:
///
///   * ``.known``   → render the full canonical chip set.
///   * ``.broken``  → render NO chips (empty array).
///   * ``.unknown`` → render NO chips (conservative default — don't
///     over-promise on aliases the loop hasn't benched).
///
/// The picker also surfaces a one-word badge on rows for which
/// ``ToolUseConfidence != .known`` so the user knows what they're
/// picking BEFORE they click a chip.
///
/// **Test design**: parameterised against the live
/// ``ToolUseCapability.brokenPrefixes`` / ``knownPrefixes`` arrays
/// rather than hard-coded alias strings. A future PR that renames a
/// model alias still exercises the gate semantics.
@Suite("#133 — empty-state chips gate on ToolUseCapability(forAlias:)")
struct CapabilityChipsAliasGateTests {

    // MARK: - .known aliases get the full chip set

    @Test("Every .known prefix renders the full canonical chip set")
    func knownPrefixesRenderFullChipSet() {
        // Pull from the live capability map so a future ``.known``
        // addition is automatically covered.
        for alias in ToolUseCapability.knownPrefixes {
            let chips = ChatView.capabilityChipKinds(forAlias: alias)
            let titles = chips.map(\.title)
            let canonicalTitles = ChatView.capabilityChipKinds.map(\.title)
            #expect(
                titles == canonicalTitles,
                ".known alias '\(alias)' produced \(titles); expected canonical \(canonicalTitles)."
            )
        }
    }

    @Test("First .known prefix renders all 4 chips (representative)")
    func firstKnownPrefixRendersFullChipSet() {
        // Pull the representative .known alias from the live capability
        // map so a future PR that renames or reorders the prefix list
        // doesn't strand this test on a stale string. The contract we
        // pin here is independent of which alias happens to be first:
        // ANY .known alias renders the 4-chip canonical catalog.
        let alias = try? #require(ToolUseCapability.knownPrefixes.first)
        let chips = ChatView.capabilityChipKinds(forAlias: alias ?? "")
        #expect(chips.count == 4)
        let titles = chips.map(\.title)
        #expect(titles == ["Search the web", "Calculate", "Weather", "Read files"])
    }

    // MARK: - .broken aliases render NO chips (THIS IS THE #133 REPRO)

    /// #133 REPRO: at HEAD this fails because ``capabilityChipKinds``
    /// is a static array independent of alias — the chip row is
    /// rendered for every alias, including the ones empirically proven
    /// to silently fail at tool-calling.
    @Test("Every .broken prefix renders NO chips (#133 repro)")
    func brokenPrefixesRenderNoChips() {
        for alias in ToolUseCapability.brokenPrefixes {
            let chips = ChatView.capabilityChipKinds(forAlias: alias)
            #expect(
                chips.isEmpty,
                ".broken alias '\(alias)' still surfaces \(chips.map(\.title)) — must be empty."
            )
        }
    }

    /// Quant-sibling pin: a hypothetical 8-bit variant of an existing
    /// .broken prefix must ALSO collapse the chip row, because the
    /// prefix-match in ToolUseCapability covers any future quant. We
    /// build the alias dynamically from the live broken list so a
    /// future model rename doesn't strand the test.
    @Test("Quant-sibling of every .broken prefix renders zero chips")
    func brokenQuantSiblingsRenderNoChips() {
        for prefix in ToolUseCapability.brokenPrefixes {
            let quantSibling = "\(prefix)-8bit"
            let chips = ChatView.capabilityChipKinds(forAlias: quantSibling)
            #expect(
                chips.isEmpty,
                "Quant sibling '\(quantSibling)' of .broken prefix '\(prefix)' must render zero chips (prefix-match covers all future quants)."
            )
        }
    }

    // MARK: - .unknown aliases render NO chips (conservative default)

    @Test("Brand-new unbenched alias defaults to NO chips (conservative)")
    func unknownAliasRendersNoChips() {
        // A hypothetical future alias the bench loop hasn't covered.
        // We do NOT over-promise — if the desktop has no signal that
        // tools work, the chip-row stays off. Less surprise than the
        // opposite default (render chips → user clicks → empty bubble).
        let chips = ChatView.capabilityChipKinds(forAlias: "future-model-7b-mxfp4")
        #expect(chips.isEmpty)
    }

    @Test("Empty alias renders NO chips (don't promise tools before a model is picked)")
    func emptyAliasRendersNoChips() {
        let chips = ChatView.capabilityChipKinds(forAlias: "")
        #expect(chips.isEmpty)
    }

    @Test("Sub-1B .unknown alias renders NO chips (no over-promise)")
    func sub1BUnknownRendersNoChips() {
        // ``qwen3-0.6b-4bit`` is a sub-1B, .unknown alias (still in the
        // catalog as a downloadable, no longer the bundled starter). It
        // must render no tool chips — treat .unknown like .broken on the
        // chip-row side: no tool promise we can't back up.
        let chips = ChatView.capabilityChipKinds(forAlias: "qwen3-0.6b-4bit")
        #expect(chips.isEmpty)
    }

    @Test("Bundled starter (bonsai-1.7b-2bit, .known) DOES render chips")
    func bundledStarterRendersChips() {
        // 2026-07-10: the bundled/first-run alias moved from the sub-1B
        // qwen3-0.6b-4bit to bonsai-1.7b-2bit, which is .known (6/6 tool
        // calls, rapid-mlx PR #1092). Unlike the old starter it is
        // ALLOWED to advertise the agentic surface on the first-launch
        // hero — the whole point of the swap. This pins that inversion:
        // if the bundled alias ever changes again, re-verify the new
        // one's chip behaviour matches its ToolUseCapability bucket.
        let chips = ChatView.capabilityChipKinds(forAlias: BundledModel.bundledAlias)
        #expect(!chips.isEmpty)
        #expect(chips.count == ChatView.capabilityChipKinds.count)
    }

    // MARK: - parameterised matrix across the three confidence states

    /// Walk the live capability map: every .known prefix yields the
    /// canonical 4-chip catalog; every .broken prefix yields 0. Driven
    /// from the live arrays so a future map edit auto-updates the
    /// coverage. Two synthetic literals (.unknown and empty) round
    /// out the third bucket.
    @Test("Live prefix arrays + synthetics: chip set adapts to ToolUseConfidence")
    func chipSetAdaptsToConfidenceMatrix() {
        let canonicalCount = ChatView.capabilityChipKinds.count
        for alias in ToolUseCapability.knownPrefixes {
            let chips = ChatView.capabilityChipKinds(forAlias: alias)
            #expect(
                chips.count == canonicalCount,
                ".known alias '\(alias)' produced \(chips.count) chips, expected \(canonicalCount)."
            )
        }
        for alias in ToolUseCapability.brokenPrefixes {
            let chips = ChatView.capabilityChipKinds(forAlias: alias)
            #expect(
                chips.isEmpty,
                ".broken alias '\(alias)' produced \(chips.count) chips, expected 0."
            )
        }
        // .unknown coverage: synthetic literals only (the map intentionally
        // has no .unknown "list" — anything not in known/broken IS unknown).
        for syntheticUnknown in ["future-model-9b-mxfp4", "wholly-new-family-13b"] {
            let chips = ChatView.capabilityChipKinds(forAlias: syntheticUnknown)
            #expect(
                chips.isEmpty,
                ".unknown synthetic '\(syntheticUnknown)' produced \(chips.count) chips, expected 0."
            )
        }
        // empty alias degrades to .unknown by confidence(for:) — must
        // also render zero chips.
        #expect(ChatView.capabilityChipKinds(forAlias: "").isEmpty)
    }

    // MARK: - chip-set ordering & identity preserved for .known path

    @Test("Gated chip set for .known preserves canonical order + identity")
    func knownChipSetPreservesCanonical() {
        // Don't just check count — check the chip-row is bit-for-bit
        // the same as the un-gated catalog so the gate doesn't silently
        // reorder or remove a chip on the .known path. Representative
        // alias drawn from the live .known prefix array.
        guard let alias = ToolUseCapability.knownPrefixes.last else {
            Issue.record("knownPrefixes is empty — capability map shape changed")
            return
        }
        let chips = ChatView.capabilityChipKinds(forAlias: alias)
        #expect(chips == ChatView.capabilityChipKinds)
    }

    // MARK: - picker badge for non-.known aliases

    @Test("Picker badge fires for every .broken alias")
    func pickerBadgeFiresForBroken() {
        for alias in ToolUseCapability.brokenPrefixes {
            #expect(
                ChatView.shouldBadgeAliasForToolUse(alias: alias),
                "Picker must badge .broken alias '\(alias)'."
            )
        }
    }

    @Test("Picker badge does NOT fire for .known aliases")
    func pickerBadgeSilentForKnown() {
        for alias in ToolUseCapability.knownPrefixes {
            #expect(
                !ChatView.shouldBadgeAliasForToolUse(alias: alias),
                ".known alias '\(alias)' must NOT be badged."
            )
        }
    }

    @Test("Picker badge fires for .unknown aliases (conservative default)")
    func pickerBadgeFiresForUnknown() {
        #expect(ChatView.shouldBadgeAliasForToolUse(alias: "future-model-7b-mxfp4"))
    }

    @Test("Picker badge does NOT fire for empty alias (defensive)")
    func pickerBadgeSilentForEmpty() {
        // Empty alias resolves to .unknown by ``confidence(for:)`` but
        // the badge is for a CONCRETE row in the picker, never the
        // placeholder. Suppress so the picker top-bar doesn't bake
        // "no tools" copy into the "no model selected" state.
        #expect(!ChatView.shouldBadgeAliasForToolUse(alias: ""))
    }

    @Test("Picker badge labels are non-empty English copy per-state (FU-9 split)")
    func badgeLabelShape() {
        // FU-9: ``aliasToolUseBadgeLabel`` is now per-state. Pin BOTH
        // .broken and .unknown copies — empty alias / .known returns
        // nil (no badge), which is exercised by the dedicated tests
        // above. We also pin the literal split so a future rename of
        // either constant is a forced reviewer call (the wording is
        // the user-visible contract of FU-9).
        let brokenLabel = ToolUseCapability.badgeLabel(for: .broken)
        let unknownLabel = ToolUseCapability.badgeLabel(for: .unknown)
        let knownLabel = ToolUseCapability.badgeLabel(for: .known)
        #expect(brokenLabel == "no tools", "FU-9: .broken label MUST remain 'no tools' — empirical evidence earned the strong wording.")
        #expect(unknownLabel == "tools unverified", "FU-9: .unknown label MUST be 'tools unverified' — softer copy so unbenched aliases don't read as broken.")
        #expect(knownLabel == nil, ".known aliases must render no badge at all.")
        // Repo-hygiene rule (MEMORY.md): English-only UI copy. Walk
        // every per-state label to catch a CJK regression on either
        // branch.
        let cjkRanges: [ClosedRange<Unicode.Scalar>] = [
            Unicode.Scalar(0x3040)!...Unicode.Scalar(0x309F)!,
            Unicode.Scalar(0x30A0)!...Unicode.Scalar(0x30FF)!,
            Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!,
        ]
        for label in [brokenLabel, unknownLabel].compactMap({ $0 }) {
            #expect(!label.isEmpty, "badge label is the in-row signal; empty would render the badge invisible.")
            for scalar in label.unicodeScalars {
                for range in cjkRanges {
                    #expect(
                        !range.contains(scalar),
                        "badge label '\(label)' contains CJK codepoint U+\(String(scalar.value, radix: 16, uppercase: true))."
                    )
                }
            }
        }
    }

    // MARK: - FU-9: per-state label split (.broken vs .unknown)

    /// FU-9 contract — picker badge label MUST differ between
    /// ``.broken`` and ``.unknown`` so an unbenched alias doesn't get
    /// the same alarmist sticker as an empirically-broken one. The
    /// chip-row gate (above) continues to suppress chips for BOTH;
    /// only the visible/audible label diverges.
    @Test(".broken aliases keep 'no tools' label (FU-9 — strong copy preserved)")
    func brokenAliasesKeepStrongLabel() {
        for alias in ToolUseCapability.brokenPrefixes {
            #expect(
                ChatView.aliasToolUseBadgeLabel(forAlias: alias) == "no tools",
                ".broken alias '\(alias)' must render the strong 'no tools' label (empirical bench earned the wording)."
            )
        }
    }

    @Test(".unknown aliases render the softer 'tools unverified' label (FU-9)")
    func unknownAliasesRenderSofterLabel() {
        // Synthetic .unknown — not in known/broken prefix arrays.
        // (Note: ``bonsai-`` is now a .known prefix — the first-run
        // starter, rapid-mlx #1092 — so a bonsai-* alias no longer
        // works as a synthetic unknown here.)
        for syntheticUnknown in ["future-model-9b-mxfp4", "wholly-new-family-13b", "unlisted-family-11b-4bit"] {
            #expect(
                ChatView.aliasToolUseBadgeLabel(forAlias: syntheticUnknown) == "tools unverified",
                ".unknown alias '\(syntheticUnknown)' must render the softer 'tools unverified' label — pre-FU-9 it read 'no tools' which conflated unverified with broken."
            )
        }
    }

    @Test(".known aliases render NO label (FU-9 — clean row preserved)")
    func knownAliasesRenderNoLabel() {
        for alias in ToolUseCapability.knownPrefixes {
            #expect(
                ChatView.aliasToolUseBadgeLabel(forAlias: alias) == nil,
                ".known alias '\(alias)' must NOT render any badge."
            )
        }
    }

    @Test("Empty alias renders NO label (defensive — placeholder row)")
    func emptyAliasRendersNoLabel() {
        #expect(ChatView.aliasToolUseBadgeLabel(forAlias: "") == nil)
    }

    // MARK: - case-insensitive routing (defensive)

    @Test("Gated chip set matches case-insensitively (defensive against upstream casing change)")
    func gateIsCaseInsensitive() {
        // ``ToolUseCapability.confidence`` already lowercases the
        // needle; pin the chip-row consumer to the same contract so
        // a mixed-case alias surfaced by the picker still routes
        // correctly. Build the upper-case alias from the live prefix
        // arrays so a future rename doesn't strand the test.
        if let broken = ToolUseCapability.brokenPrefixes.first {
            let upper = ChatView.capabilityChipKinds(forAlias: broken.uppercased())
            #expect(upper.isEmpty, "case-insensitive .broken match for '\(broken.uppercased())' must zero the chip set")
        } else {
            Issue.record("brokenPrefixes is empty — capability map shape changed")
        }
        if let known = ToolUseCapability.knownPrefixes.first {
            let upperKnown = ChatView.capabilityChipKinds(forAlias: known.uppercased())
            #expect(upperKnown == ChatView.capabilityChipKinds, "case-insensitive .known match for '\(known.uppercased())' must keep the full chip set")
        } else {
            Issue.record("knownPrefixes is empty — capability map shape changed")
        }
    }
}
