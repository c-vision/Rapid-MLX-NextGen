import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// Cycle-10 P3 regression net: prior to ``feat/delete-session-confirm``
/// the sidebar's context-menu Delete called ``SessionStore.delete``
/// directly, with zero confirmation. A reflex right-click → Delete
/// silently lost the entire thread including pinned chats the user
/// had explicitly flagged "keep this one." The fix wraps every
/// Delete entry point in ``DeleteSessionConfirmation`` policy and
/// stages a custom ``DeleteSessionConfirmationSheet`` (sheet rather
/// than alert/confirmationDialog, because the "Don't ask again"
/// Toggle is non-button content that those macOS surfaces silently
/// drop). A "Don't ask again" checkbox in the sheet persists to
/// ``UserDefaults`` under
/// ``DeleteSessionConfirmation.UserDefaultsKey.skipDeleteConfirm``.
///
/// The non-negotiable invariant is the pinned bypass guard: a
/// pinned session ALWAYS routes through the dialog, regardless of
/// the user's "don't ask again" preference. The tests below pin
/// each branch of the policy so a future refactor of the gate
/// can't quietly let a pinned chat slip through.
@MainActor
@Suite("DeleteSessionConfirmation policy")
struct DeleteSessionConfirmationTests {
    // MARK: - shouldConfirm

    /// Default-state baseline: non-pinned session, preference not
    /// set → must confirm. This is the "out of the box" experience
    /// every new install hits on first delete; a regression would
    /// re-open the silent-delete bug verbatim.
    @Test("Non-pinned session with preference off must confirm")
    func nonPinnedDefaultMustConfirm() {
        let result = DeleteSessionConfirmation.shouldConfirm(
            isPinned: false,
            skipPreferenceEnabled: false
        )
        #expect(result == true)
    }

    /// Power-user opt-out: a non-pinned session whose deletion has
    /// been pre-authorised via "Don't ask again" must NOT re-prompt.
    /// Otherwise the preference is a no-op and the dialog becomes
    /// annoying friction the user already explicitly silenced.
    @Test("Non-pinned session with preference on must NOT confirm")
    func nonPinnedSkipOptOut() {
        let result = DeleteSessionConfirmation.shouldConfirm(
            isPinned: false,
            skipPreferenceEnabled: true
        )
        #expect(result == false)
    }

    /// The pinned-bypass guard, preference off: a pinned chat must
    /// confirm. (Trivially true under the policy, but worth pinning
    /// so the test reads as a complete truth-table.)
    @Test("Pinned session with preference off must confirm")
    func pinnedDefaultMustConfirm() {
        let result = DeleteSessionConfirmation.shouldConfirm(
            isPinned: true,
            skipPreferenceEnabled: false
        )
        #expect(result == true)
    }

    /// The non-negotiable: a pinned chat must confirm EVEN WHEN the
    /// user has ticked "Don't ask again." A pin is the user's
    /// explicit "this matters" mark; we must never let the global
    /// opt-out quietly bypass that signal. Regression here =
    /// silent data loss on the highest-value sessions.
    @Test("Pinned session ALWAYS confirms regardless of preference")
    func pinnedAlwaysConfirms() {
        let result = DeleteSessionConfirmation.shouldConfirm(
            isPinned: true,
            skipPreferenceEnabled: true
        )
        #expect(result == true)
    }

    // MARK: - decide() (actionable outcome)

    /// ``decide`` is the call-site convenience that turns the
    /// truth-table into an enum the view layer can switch on.
    /// We pin every entry of the cartesian product so a future
    /// refactor that, say, swaps the meaning of the two cases
    /// can't silently fall through.
    @Test("decide() truth table covers all four (pinned × preference) branches")
    func decideTruthTable() {
        #expect(
            DeleteSessionConfirmation.decide(
                isPinned: false,
                skipPreferenceEnabled: false
            ) == .stageConfirmation
        )
        #expect(
            DeleteSessionConfirmation.decide(
                isPinned: false,
                skipPreferenceEnabled: true
            ) == .deleteImmediately
        )
        #expect(
            DeleteSessionConfirmation.decide(
                isPinned: true,
                skipPreferenceEnabled: false
            ) == .stageConfirmation
        )
        #expect(
            DeleteSessionConfirmation.decide(
                isPinned: true,
                skipPreferenceEnabled: true
            ) == .stageConfirmation
        )
    }

    // MARK: - UserDefaults persistence

    /// Round-trip the preference through an isolated UserDefaults
    /// suite so the global ``UserDefaults.standard`` is never
    /// touched (parallel test runs share that surface; a stray
    /// write would corrupt other tests' fixtures).
    @Test("Skip preference round-trips through UserDefaults")
    func skipPreferenceRoundTrips() throws {
        let suiteName = "rapid.delete-confirm-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Fresh suite: preference defaults to false.
        #expect(
            DeleteSessionConfirmation.skipPreferenceEnabled(in: defaults) == false
        )

        // Write through the helper, read back through the helper.
        DeleteSessionConfirmation.setSkipPreference(true, in: defaults)
        #expect(
            DeleteSessionConfirmation.skipPreferenceEnabled(in: defaults) == true
        )

        // Flipping back: the helper isn't sticky.
        DeleteSessionConfirmation.setSkipPreference(false, in: defaults)
        #expect(
            DeleteSessionConfirmation.skipPreferenceEnabled(in: defaults) == false
        )
    }

    /// The key spelling is the contract surface — a typo would let
    /// future entry points (swipe / shortcut / palette) re-derive
    /// a near-miss key that doesn't honour the existing user's
    /// preference. Pin it.
    @Test("UserDefaults key is the documented v1 namespace")
    func userDefaultsKeyIsStable() {
        #expect(
            DeleteSessionConfirmation.UserDefaultsKey.skipDeleteConfirm
                == "rapid.sessions.skip_delete_confirm.v1"
        )
    }

    // MARK: - dialog copy

    /// Pinned suffix surfaces in the title — that's the visible
    /// cue telling the user why the dialog re-appeared even after
    /// they checked "Don't ask again." Without it the policy would
    /// feel like a UI bug.
    @Test("Pinned session title includes the '(Pinned)' suffix")
    func pinnedTitleSuffix() {
        let session = ChatSession(
            title: "Important interview prep",
            alias: "qwen3.5-4b",
            isPinned: true
        )
        let title = DeleteSessionConfirmation.dialogTitle(for: session)
        #expect(title.contains("(Pinned)"))
        #expect(title.contains("Important interview prep"))
    }

    /// Non-pinned title has no "(Pinned)" suffix — symmetry with
    /// the pinned branch so the two are clearly distinguishable.
    @Test("Non-pinned session title omits the '(Pinned)' suffix")
    func nonPinnedTitleNoSuffix() {
        let session = ChatSession(
            title: "Quick lookup",
            alias: "qwen3.5-4b",
            isPinned: false
        )
        let title = DeleteSessionConfirmation.dialogTitle(for: session)
        #expect(title.contains("(Pinned)") == false)
        #expect(title.contains("Quick lookup"))
    }

    /// Long titles get truncated with an ellipsis so the dialog
    /// header doesn't blow out to two lines on a tight macOS
    /// sheet.
    @Test("Long session title truncates with an ellipsis")
    func longTitleTruncates() {
        let longTitle = String(repeating: "a", count: 200)
        let session = ChatSession(title: longTitle, alias: "qwen3.5-4b")
        let title = DeleteSessionConfirmation.dialogTitle(for: session)
        #expect(title.count < longTitle.count)
        #expect(title.contains("…"))
    }

    /// Empty/whitespace titles fall back to "this chat" so the
    /// dialog never reads ``Delete ""?`` on a freshly-created
    /// session the user hadn't sent a message to yet.
    @Test("Whitespace-only title falls back to 'this chat'")
    func whitespaceTitleFallback() {
        let session = ChatSession(title: "   ", alias: "qwen3.5-4b")
        let title = DeleteSessionConfirmation.dialogTitle(for: session)
        #expect(title.contains("this chat"))
    }

    /// Message text includes the per-session message count when
    /// non-zero — a "you're about to delete 47 messages" cue is
    /// what every mature competitor surfaces on heavy threads.
    @Test("Dialog message includes the message count when non-empty")
    func dialogMessageIncludesCount() {
        var session = ChatSession(title: "Chat", alias: "qwen3.5-4b")
        session.messages = [
            ChatMessage(role: .user, content: "a"),
            ChatMessage(role: .assistant, content: "b"),
        ]
        let body = DeleteSessionConfirmation.dialogMessage(for: session)
        #expect(body.contains("2 messages"))
    }

    /// Empty session: the message body skips the count parenthetical
    /// — surfacing "(0 messages)" would feel like a typo.
    @Test("Dialog message omits the count parenthetical for empty sessions")
    func dialogMessageOmitsZeroCount() {
        let session = ChatSession(title: "Empty", alias: "qwen3.5-4b")
        let body = DeleteSessionConfirmation.dialogMessage(for: session)
        #expect(body.contains("messages)") == false)
    }

    // MARK: - sheet view

    /// The sheet hosts a "Don't ask again" toggle when the session
    /// is not pinned. ViewInspector can find the Toggle's label
    /// text inside the rendered VStack — pinning that branch
    /// proves the suppression affordance is actually wired up
    /// (codex r1 MAJOR: a Toggle inside ``.confirmationDialog`` is
    /// silently dropped on macOS, so the sheet refactor is
    /// load-bearing for this feature).
    @Test("Sheet shows 'Don't ask again' toggle for non-pinned sessions")
    func sheetShowsToggleForNonPinned() throws {
        let session = ChatSession(title: "Chat", alias: "qwen3.5-4b", isPinned: false)
        var skip = false
        let sheet = DeleteSessionConfirmationSheet(
            session: session,
            skipFutureConfirm: Binding(get: { skip }, set: { skip = $0 }),
            onCancel: {},
            onConfirm: {}
        )
        #expect(throws: Never.self) {
            try sheet.inspect().find(text: "Don't ask again for unpinned chats")
        }
    }

    /// Symmetric branch: pinned sessions DO NOT show the toggle —
    /// the policy explicitly forbids a pinned bypass, so the
    /// toggle would mislead the user. The absence test guards
    /// against a future refactor that "forgets" the branch and
    /// silently re-enables the bypass UI.
    @Test("Sheet hides 'Don't ask again' toggle for pinned sessions")
    func sheetHidesToggleForPinned() throws {
        let session = ChatSession(title: "Pinned chat", alias: "qwen3.5-4b", isPinned: true)
        var skip = false
        let sheet = DeleteSessionConfirmationSheet(
            session: session,
            skipFutureConfirm: Binding(get: { skip }, set: { skip = $0 }),
            onCancel: {},
            onConfirm: {}
        )
        #expect(throws: (any Error).self) {
            // ``inspect().find`` throws when the predicate matches
            // nothing — that's the success signal for "the toggle
            // is correctly absent from the pinned branch."
            try sheet.inspect().find(text: "Don't ask again for unpinned chats")
        }
    }

    /// The destructive ``Delete`` button is present on both
    /// branches. The cancel-role button is also present and
    /// labelled "Cancel" so a user under stress can identify the
    /// safe option at a glance.
    @Test("Sheet exposes Cancel + Delete buttons")
    func sheetButtonsPresent() throws {
        let session = ChatSession(title: "Chat", alias: "qwen3.5-4b")
        var skip = false
        let sheet = DeleteSessionConfirmationSheet(
            session: session,
            skipFutureConfirm: Binding(get: { skip }, set: { skip = $0 }),
            onCancel: {},
            onConfirm: {}
        )
        #expect(throws: Never.self) {
            try sheet.inspect().find(button: "Cancel")
            try sheet.inspect().find(button: "Delete")
        }
    }

    /// Tapping the Cancel button fires ``onCancel`` without
    /// invoking ``onConfirm`` — the safe path on the confirmation
    /// surface.
    @Test("Cancel button invokes onCancel, never onConfirm")
    func cancelInvokesCancelHandlerOnly() throws {
        let session = ChatSession(title: "Chat", alias: "qwen3.5-4b")
        var skip = false
        var cancelled = 0
        var confirmed = 0
        let sheet = DeleteSessionConfirmationSheet(
            session: session,
            skipFutureConfirm: Binding(get: { skip }, set: { skip = $0 }),
            onCancel: { cancelled += 1 },
            onConfirm: { confirmed += 1 }
        )
        let cancelButton = try sheet.inspect().find(button: "Cancel")
        try cancelButton.tap()
        #expect(cancelled == 1)
        #expect(confirmed == 0)
    }

    /// Tapping the destructive Delete button fires ``onConfirm``
    /// without invoking ``onCancel``.
    @Test("Delete button invokes onConfirm, never onCancel")
    func deleteInvokesConfirmHandlerOnly() throws {
        let session = ChatSession(title: "Chat", alias: "qwen3.5-4b")
        var skip = false
        var cancelled = 0
        var confirmed = 0
        let sheet = DeleteSessionConfirmationSheet(
            session: session,
            skipFutureConfirm: Binding(get: { skip }, set: { skip = $0 }),
            onCancel: { cancelled += 1 },
            onConfirm: { confirmed += 1 }
        )
        let deleteButton = try sheet.inspect().find(button: "Delete")
        try deleteButton.tap()
        #expect(confirmed == 1)
        #expect(cancelled == 0)
    }

    // MARK: - view-render smoke (sidebar host)

    /// The sidebar still renders after the sheet modifier was
    /// added. A modifier typo here would break the entire
    /// left-rail; the smoke check catches that class of failure
    /// before it reaches users.
    @Test("Sidebar renders with the confirmation sheet modifier attached")
    func sidebarRendersWithSheetModifier() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-delete-render-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: storeURL)
        _ = store.newSession(alias: "fake-alias")
        let sut = SessionsSidebar(store: store, defaultAlias: "fake-alias")
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "Recents")
        }
    }
}
