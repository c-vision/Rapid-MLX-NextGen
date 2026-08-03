import Foundation
import Testing
@testable import Rapid

/// PR2 craft/wayfinding polish — issues #549 (onboarding Skip/Esc),
/// #550 (Settings keyboard nav + VoiceOver), #551 (session-delete
/// Undo), #552 (recommended-card depth).
///
/// The #551 restore path and the #550 navigation step are pure logic
/// and get real behavioural coverage; the three view-only changes
/// (Skip affordance, keyboard/AX modifiers, card shadow) are pinned by
/// source guards, mirroring the repo's existing source-grep tripwires.
@Suite("PR2 — craft/wayfinding polish (#549/#550/#551/#552)")
struct CraftPolishTests {

    // MARK: - #551 session-delete Undo (SessionStore.restore)

    @MainActor
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-craft-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: url)
    }

    @Test("restore re-inserts a deleted session at its original index")
    @MainActor
    func restoreReinsertsAtIndex() {
        let store = makeStore()
        _ = store.newSession(alias: "m")
        let mid = store.newSession(alias: "m")
        _ = store.newSession(alias: "m")

        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == mid }))
        let snapshot = store.sessions[idx]
        store.delete(id: mid)
        #expect(store.sessions.count == 2)
        #expect(!store.sessions.contains(where: { $0.id == mid }))

        store.restore(snapshot, at: idx, reactivate: false)
        #expect(store.sessions.count == 3)
        #expect(store.sessions[idx].id == mid)
    }

    @Test("restore of the active session can reactivate it")
    @MainActor
    func restoreReactivatesActive() {
        let store = makeStore()
        _ = store.newSession(alias: "m")
        let active = store.newSession(alias: "m")
        store.activeID = active

        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == active }))
        let snapshot = store.sessions[idx]
        let wasActive = store.activeID == active
        store.delete(id: active)
        #expect(store.activeID != active)

        store.restore(snapshot, at: idx, reactivate: wasActive)
        #expect(store.activeID == active)
    }

    @Test("restore preserves the session's messages")
    @MainActor
    func restorePreservesMessages() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "keep me"),
            ChatMessage(role: .assistant, content: "restored intact"),
        ])
        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == id }))
        let snapshot = store.sessions[idx]
        store.delete(id: id)

        store.restore(snapshot, at: idx, reactivate: true)
        let restored = try! #require(store.sessions.first(where: { $0.id == id }))
        #expect(restored.messages.count == 2)
        #expect(restored.messages.first?.content == "keep me")
    }

    @Test("restore is idempotent — a double Undo does not duplicate")
    @MainActor
    func restoreIdempotent() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == id }))
        let snapshot = store.sessions[idx]
        store.delete(id: id)

        store.restore(snapshot, at: idx, reactivate: true)
        store.restore(snapshot, at: idx, reactivate: true)  // second Undo
        #expect(store.sessions.filter { $0.id == id }.count == 1)
    }

    @Test("restore of a mid-stream session keeps streamingCount balanced and clears orphan tool_calls")
    @MainActor
    func restoreNormalizesStreamingMessages() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        // A response caught mid-stream: partial content + a half-planned
        // tool call that never got a matching role:"tool" result.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(
                role: .assistant,
                content: "partial",
                status: .streaming,
                toolCalls: [ToolCall(id: "c1", name: "search", arguments: "{}")]
            ),
        ])
        #expect(store.streamingMessageCount == 1)

        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == id }))
        let snapshot = store.sessions[idx]
        store.delete(id: id)  // decrements streamingCount back to 0 (issue #297)
        #expect(store.streamingMessageCount == 0)

        // Undo during a live response must NOT resurrect a phantom stream:
        // the restored row settles to .complete, the counter stays 0, and
        // the orphan tool_calls are cleared (else the next turn 400s).
        store.restore(snapshot, at: idx, reactivate: true)
        #expect(store.streamingMessageCount == 0)
        let restored = try! #require(store.sessions.first(where: { $0.id == id }))
        #expect(restored.messages.allSatisfy { $0.status != .streaming })
        let last = try! #require(restored.messages.last)
        #expect(last.content.hasPrefix("partial"))
        #expect(last.toolCalls == nil, "orphan tool_calls must be cleared on Undo restore")
    }

    @Test("restore heals an interrupted tool round (orphan .complete tool_calls)")
    @MainActor
    func restoreClearsInterruptedToolRound() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        // Mid-tool-execution shape: the assistant tool-call row is ALREADY
        // .complete (finish_reason: tool_calls) with a second call's result
        // still pending — exactly the window a delete+Undo can catch.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "search please"),
            ChatMessage(
                role: .assistant,
                status: .complete,
                toolCalls: [
                    ToolCall(id: "c1", name: "search", arguments: "{}"),
                    ToolCall(id: "c2", name: "search", arguments: "{}"),
                ]
            ),
            ChatMessage(role: .tool, content: "c1 result", toolCallID: "c1"),
            // c2's result never arrived → the round is orphaned.
        ])
        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == id }))
        let snapshot = store.sessions[idx]
        store.delete(id: id)

        store.restore(snapshot, at: idx, reactivate: true)
        let restored = try! #require(store.sessions.first(where: { $0.id == id }))
        // The assistant's orphan tool_calls are cleared and its partial
        // c1 result is dropped, so no orphan (call OR result) reaches the wire.
        #expect(restored.messages.allSatisfy { $0.toolCalls == nil })
        #expect(!restored.messages.contains { $0.role == .tool })
        #expect(store.streamingMessageCount == 0)
    }

    @Test("restore leaves a fully-satisfied tool round untouched")
    @MainActor
    func restorePreservesCompletedToolRound() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        // A legitimate completed round: call → result → final prose. None of
        // it is orphaned, so restore must not strip or drop anything.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(role: .user, content: "search please"),
            ChatMessage(
                role: .assistant,
                status: .complete,
                toolCalls: [ToolCall(id: "c1", name: "search", arguments: "{}")]
            ),
            ChatMessage(role: .tool, content: "c1 result", toolCallID: "c1"),
            ChatMessage(role: .assistant, content: "Here is the answer.", status: .complete),
        ])
        let idx = try! #require(store.sessions.firstIndex(where: { $0.id == id }))
        let snapshot = store.sessions[idx]
        store.delete(id: id)

        store.restore(snapshot, at: idx, reactivate: true)
        let restored = try! #require(store.sessions.first(where: { $0.id == id }))
        #expect(restored.messages.count == 4, "a valid round must survive restore whole")
        #expect(restored.messages.contains { $0.toolCalls?.contains { $0.id == "c1" } ?? false })
        #expect(restored.messages.contains { $0.role == .tool && $0.toolCallID == "c1" })
        #expect(restored.messages.last?.content == "Here is the answer.")
    }

    @Test("restore clamps an out-of-range index instead of trapping")
    @MainActor
    func restoreClampsIndex() {
        let store = makeStore()
        let id = store.newSession(alias: "m")
        let snapshot = store.sessions[0]
        store.delete(id: id)
        // Index far past the (now shorter) list must clamp, not crash.
        store.restore(snapshot, at: 999, reactivate: false)
        #expect(store.sessions.contains(where: { $0.id == id }))
    }

    // MARK: - #550 Settings category keyboard navigation

    @Test("category(_:movedBy:) steps down and up through allCases")
    func categoryStepsThroughCases() {
        let all = SettingsView.Category.allCases
        // Down from the first lands on the second; up returns.
        let second = SettingsView.category(all[0], movedBy: 1)
        #expect(second == all[1])
        #expect(SettingsView.category(all[1], movedBy: -1) == all[0])
    }

    @Test("category(_:movedBy:) clamps at both ends (no wrap-around)")
    func categoryClampsAtEnds() {
        let all = SettingsView.Category.allCases
        #expect(SettingsView.category(all.first!, movedBy: -1) == nil)
        #expect(SettingsView.category(all.last!, movedBy: 1) == nil)
    }

    // MARK: - Source guards for the view-only changes

    private func source(_ relativePath: String) throws -> String {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("#549: onboarding hero ships a Skip affordance wired to Esc + onBrowseAll")
    func onboardingSkipPresent() throws {
        let src = try source("Sources/Rapid/UI/QuickstartView.swift")
        #expect(src.contains("\"Skip for now\""),
                "welcomeStep must render a 'Skip for now' control (#549 wayfinding exit).")
        #expect(src.contains("Quickstart.Skip"),
                "the Skip control must carry the Quickstart.Skip accessibility id.")
        #expect(src.contains(".keyboardShortcut(.cancelAction)"),
                "Skip must bind .cancelAction so Esc leaves onboarding (#549).")
    }

    @Test("#550: Settings category rail has keyboard nav + selected-row AX trait")
    func settingsKeyboardNavPresent() throws {
        let src = try source("Sources/Rapid/UI/SettingsView.swift")
        #expect(src.contains(".onKeyPress(.upArrow)") && src.contains(".onKeyPress(.downArrow)"),
                "the category List must handle ↑/↓ (#550 keyboard nav).")
        #expect(src.contains("moveCategorySelection"),
                "arrow keys must drive moveCategorySelection.")
        #expect(src.contains(".isSelected"),
                "the active category row must add the .isSelected VoiceOver trait (#550).")
    }

    @Test("Settings category rows use a full-width native button hit target")
    func settingsCategoryRowsAreFullyClickable() throws {
        let src = try source("Sources/Rapid/UI/SettingsView.swift")
        let start = try #require(src.range(of: "    private struct CategoryRail"))
        let end = try #require(src.range(
            of: "\n    private struct DetailCanvas",
            range: start.upperBound..<src.endIndex
        ))
        let rail = String(src[start.lowerBound..<end.lowerBound])

        #expect(rail.contains("Button {"),
                "category activation must use a native Button instead of a competing List tap gesture.")
        #expect(rail.contains(".frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)"),
                "the category label must fill a stable full-row hit target.")
        #expect(rail.contains("@State private var hoveredCategory: Category?"))
        #expect(rail.contains(".onHover"),
                "pointer hover must acknowledge the row before a click.")
        #expect(rail.contains(".buttonStyle(.pressable)"),
                "pointer-down must provide immediate feedback instead of feeling ignored.")
        #expect(!rail.contains(".onTapGesture { selected = cat }"),
                "the old intrinsic-label tap target must not return.")
    }

    @Test("#551: deleting the streaming session cancels its producer")
    func deleteCancelsInflightStream() throws {
        let src = try source("Sources/Rapid/UI/SessionsSidebar.swift")
        #expect(src.contains("onStopStream"),
                "the sidebar must accept an onStopStream hook wired to ChatViewModel.stop().")
        #expect(src.contains("if streamingSessionID == live.id"),
                "deleteWithUndo must cancel the producer only when the deleted row owns the stream (#551).")
    }

    @Test("#551: undo toast keeps Undo + Dismiss as actionable elements")
    func undoToastButtonsStayActionable() throws {
        let src = try source("Sources/Rapid/UI/SessionsSidebar.swift")
        // The Undo hint must ride the actionable button, not a collapsed
        // parent — the old whole-HStack combine hid both buttons from
        // VoiceOver (codex PR-#554 r2 MAJOR).
        #expect(src.contains(".accessibilityHint(\"Restore the deleted chat\")"),
                "the Undo hint must sit on the Undo button itself.")
        #expect(!src.contains(".accessibilityHint(\"Activate Undo to restore\")"),
                "the dead-parent combine hint must be gone so the buttons stay reachable.")
    }

    @Test("#551: delete confirmation copy reflects the undo window")
    func deleteConfirmationCopyMentionsUndo() throws {
        let src = try source("Sources/Rapid/UI/DeleteSessionConfirmation.swift")
        #expect(src.contains("You'll have a few seconds to undo."),
                "the confirmation must describe the new undo window (#551).")
        #expect(!src.contains("All messages in this chat will be permanently removed. This can't be undone."),
                "the stale 'can't be undone' claim must be gone now that Undo exists.")
    }

    @Test("#552: recommended role cards carry a lifting shadow")
    func recommendedCardShadowPresent() throws {
        let src = try source("Sources/Rapid/UI/SettingsModelManagementPanel.swift")
        // Pin the exact depth token so a later refactor that flattens
        // the recommended tier back onto the table's elevation trips.
        #expect(src.contains(".shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 3)"),
                "recommended role cards must keep the #552 lifting shadow above the flush table.")
    }

    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
