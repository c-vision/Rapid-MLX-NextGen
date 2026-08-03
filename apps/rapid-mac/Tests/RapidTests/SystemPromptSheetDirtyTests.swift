import Testing
@testable import Rapid

/// v0.6 P1: SystemPromptSheet must show a discard-confirm dialog on
/// Cancel/Esc when the draft diverges from the snapshot captured at
/// sheet-open. The sheet's Cancel-button branch reads
/// `SystemPromptSheet.isDirty(draft:initialDraft:)` directly, so this
/// suite pins the production contract instead of mirroring it (codex
/// r1 NIT-2). Any future change to the predicate fails here.
///
/// The expensive part of the fix (confirmationDialog wiring +
/// .interactiveDismissDisabled) is enforced visually + by cliclick
/// smoke; the data-loss footgun lives entirely in this predicate.
@Suite("SystemPromptSheet dirty-detection contract")
struct SystemPromptSheetDirtyTests {

    @Test("Untouched draft is not dirty")
    func untouchedNotDirty() {
        #expect(SystemPromptSheet.isDirty(draft: "", initialDraft: "") == false)
        #expect(SystemPromptSheet.isDirty(draft: "You are a tutor.", initialDraft: "You are a tutor.") == false)
    }

    @Test("Any divergence flips dirty=true")
    func divergenceIsDirty() {
        #expect(SystemPromptSheet.isDirty(draft: "You are a tutor.", initialDraft: "") == true)
        #expect(SystemPromptSheet.isDirty(draft: "", initialDraft: "You are a tutor.") == true)
        #expect(SystemPromptSheet.isDirty(draft: "You are a tutor!", initialDraft: "You are a tutor.") == true)
    }

    @Test("Whitespace-only edits still count as dirty")
    func whitespaceCountsAsDirty() {
        // The store trims on persist (covered by setSystemPrompt
        // tests) but the *sheet* shouldn't pre-trim — a user adding
        // a trailing newline as a stylistic choice still has unsaved
        // changes that should be confirmed-before-discard.
        #expect(SystemPromptSheet.isDirty(draft: "hi ", initialDraft: "hi") == true)
        #expect(SystemPromptSheet.isDirty(draft: "hi\n", initialDraft: "hi") == true)
    }

    @Test("Empty draft against empty initial — common open-and-close")
    func openCloseNoNag() {
        // The most common "false alarm" case: user opens the sheet
        // on a session with no prompt, looks around, hits Cancel.
        // Must NOT show the confirm dialog.
        #expect(SystemPromptSheet.isDirty(draft: "", initialDraft: "") == false)
    }
}
