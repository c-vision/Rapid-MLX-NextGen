import Foundation
import Testing
@testable import Rapid

/// Issues #451 / #415 (already fixed) sync guard: after a session is
/// restored and the picker aligns to the session's alias
/// (``SessionAliasRestore.resolve`` → ``.useSessionAlias``), the empty-
/// state welcome caption (``ChatView.emptyStatePoweredByCopy``) must name
/// the SAME alias the picker switched to. The two surfaces reading the
/// alias from different sources was the original drift bug; this pins that
/// they stay in sync so a future refactor of either surface can't silently
/// reintroduce a picker-says-X / caption-says-Y mismatch.
@Suite("Restore: welcome caption stays in sync with picker alias (#451/#415)")
struct SessionRestoreWelcomeCaptionSyncTests {

    private let catalog: Set<String> = [
        "qwen3.6-27b-8bit",
        "qwen3.5-35b-4bit",
        "gemma-4-12b-4bit",
    ]

    @Test("Restored session aligns the picker; the welcome caption names that same alias")
    func captionMatchesAlignedPickerAlias() throws {
        let restored = "qwen3.6-27b-8bit"
        // Picker starts on a DIFFERENT model, so restore must move it.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: restored,
            currentPickerAlias: "gemma-4-12b-4bit",
            catalogAliases: catalog
        )
        // The restore path aligns the picker to the session's alias.
        guard case .useSessionAlias(let pickerAlias) = outcome else {
            Issue.record("restore of an in-catalog alias must align the picker")
            return
        }
        #expect(pickerAlias == restored)

        // The welcome caption is fed the picker's (now aligned) alias.
        let caption = ChatView.emptyStatePoweredByCopy(alias: pickerAlias)
        #expect(caption == "\(restored) · running privately on your Mac")
        // Load-bearing invariant: the caption names EXACTLY the alias the
        // picker holds — no drift between the two surfaces (#451/#415).
        #expect(caption.hasPrefix(restored))
    }

    @Test("Restore that leaves the picker unchanged still keeps caption == picker")
    func captionMatchesWhenNoChange() {
        let alias = "qwen3.5-35b-4bit"
        // Session alias already equals the picker → .noChange; the picker
        // keeps `alias`, and the caption must name that same alias.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: alias,
            currentPickerAlias: alias,
            catalogAliases: catalog
        )
        #expect(outcome == .noChange)
        let pickerAliasAfter = alias  // unchanged
        let caption = ChatView.emptyStatePoweredByCopy(alias: pickerAliasAfter)
        #expect(caption == "\(alias) · running privately on your Mac")
        #expect(caption.hasPrefix(pickerAliasAfter))
    }
}
