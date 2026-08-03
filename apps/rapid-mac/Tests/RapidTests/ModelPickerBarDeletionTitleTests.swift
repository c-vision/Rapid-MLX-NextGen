import Testing
@testable import Rapid

/// v0.6 P1: Model deletion confirmation title contract.
///
/// The audit (v1-prod-readiness-gaps.md) flagged the model delete UI
/// for accidental data loss: an Alert with Delete as the default
/// (Return-bound) button can wipe out multi-GB weights from a stray
/// keystroke. The fix (1) migrates to `.confirmationDialog` so the
/// cancel-role button gets the default binding and (2) front-loads
/// the on-disk size into the title so the cost is visible at a
/// glance — *not* buried in the body where it's easy to skim past.
///
/// These tests pin the title string shape so a future copy-rewrite
/// can't accidentally drop the size or alias.
@Suite("ModelPickerBar deletion-title contract")
struct ModelPickerBarDeletionTitleTests {

    /// Build a synthetic entry without standing up ModelCatalog.
    private func entry(_ alias: String, size: String? = nil) -> ModelEntry {
        ModelEntry(alias: alias, hfRepo: nil, sizeOnDisk: size, cached: true)
    }

    @Test("Nil entry yields a fallback title (no alias / size leak)")
    func nilEntryFallback() {
        #expect(ModelPickerBar.deletionTitle(for: nil) == "Delete this model?")
    }

    @Test("Sized entry names the model and surfaces the freed size")
    func sizedEntry() {
        let e = entry("qwen3.5-4b-4bit", size: "2.3 GB")
        // Plain, competitor-style copy (LM Studio idiom): name the
        // model in the title and call out the reclaimed disk so a
        // glance is enough to gauge the cost. No "cached weights"
        // jargon. Exact equality is the contract.
        #expect(ModelPickerBar.deletionTitle(for: e) == "Delete \"qwen3.5-4b-4bit\"? This frees 2.3 GB.")
    }

    @Test("Unsized entry still names the alias")
    func unsizedEntry() {
        // `ls` may omit size for partial / corrupt cache entries; the
        // title should still tell the user WHAT they're deleting even
        // when we can't show how much they'll get back.
        let e = entry("phi-4-4bit")
        #expect(ModelPickerBar.deletionTitle(for: e) == "Delete \"phi-4-4bit\"?")
    }

    @Test("Alias with quotes is rendered as-is (no double-quoting)")
    func aliasWithQuotes() {
        // Defensive: aliases.json should never contain quote chars,
        // but a future migration could. We don't escape — we just
        // verify the title formatter doesn't crash and produces a
        // recognizable string.
        let e = entry(#"weird"alias"#, size: "1 GB")
        let title = ModelPickerBar.deletionTitle(for: e)
        #expect(title.contains(#"weird"alias"#))
        #expect(title.contains("1 GB"))
    }
}
