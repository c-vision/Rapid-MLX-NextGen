import Foundation
import Testing
@testable import Rapid

/// Pin the structural invariants of the new Settings →
/// Model Management tab (issue #210). The view is intentionally
/// thin — every truth table lives in ``ModelCacheActions`` —
/// so these tests cover the integration points: the sidebar
/// surfaces the new tab, the title/icon copy is what the
/// design spec calls for, and the panel re-uses the shared
/// confirmation copy contract.
@MainActor
@Suite("Settings Model Management panel — integration (#210)")
struct SettingsModelManagementPanelTests {

    // MARK: - Category enum

    @Test("Category enum includes a Model Management case")
    func categoryIncludesModelManagement() {
        let names = SettingsView.Category.allCases.map { $0.rawValue }
        #expect(names.contains("modelManagement"))
    }

    @Test("Model Management tab is placed adjacent to Models")
    func categoryPlacement() {
        let order = SettingsView.Category.allCases.map { $0.rawValue }
        let modelsIdx = order.firstIndex(of: "models")
        let mgmtIdx = order.firstIndex(of: "modelManagement")
        #expect(modelsIdx != nil)
        #expect(mgmtIdx != nil)
        if let m = modelsIdx, let mm = mgmtIdx {
            #expect(mm == m + 1)
        }
    }

    @Test("Model Management title matches the spec copy")
    func categoryTitle() {
        #expect(SettingsView.Category.modelManagement.title == "Model Management")
    }

    @Test("Model Management icon is a drive glyph")
    func categoryIcon() {
        // The spec lets us pick between externaldrive.fill and
        // internaldrive.fill. We ship with externaldrive.fill so
        // it visually distinguishes from the Storage tab's
        // internaldrive.fill. Pin the choice so a future drive-by
        // edit can't drift the two tabs back into the same glyph.
        #expect(SettingsView.Category.modelManagement.iconName == "externaldrive.fill")
        #expect(SettingsView.Category.storage.iconName == "internaldrive.fill")
        #expect(
            SettingsView.Category.modelManagement.iconName
                != SettingsView.Category.storage.iconName
        )
    }

    // MARK: - Shared confirmation copy (parity vs picker)

    // MARK: - Job-transition refresh (codex r1 P2)

    @Test("shouldRefreshCatalog: running → completed triggers refresh")
    func refreshOnCompletion() {
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .running]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .completed]
        #expect(SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("shouldRefreshCatalog: running → failed also triggers refresh (Retry needs row reset)")
    func refreshOnFailure() {
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .running]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .failed]
        #expect(SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("shouldRefreshCatalog: running → cancelled also triggers refresh")
    func refreshOnCancel() {
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .running]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .cancelled]
        #expect(SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("shouldRefreshCatalog: still-running doesn't trigger refresh")
    func refreshSkipsOngoing() {
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .running]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .running]
        #expect(!SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("shouldRefreshCatalog: terminal-on-first-sight doesn't trigger refresh")
    func refreshSkipsCompletedFromBlank() {
        // Coming back to the tab after a previous .completed job
        // is already in the dictionary shouldn't refire a refresh —
        // we only react to the running → terminal edge.
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = [:]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = ["q": .completed]
        #expect(!SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("shouldRefreshCatalog: multi-alias — refresh fires if ANY alias transitioned")
    func refreshMultiAlias() {
        let previous: [String: SettingsModelManagementPanel.ObservedJobStatus] = [
            "a": .running, "b": .running
        ]
        let current: [String: SettingsModelManagementPanel.ObservedJobStatus] = [
            "a": .running, "b": .completed
        ]
        #expect(SettingsModelManagementPanel.shouldRefreshCatalog(previous: previous, current: current))
    }

    @Test("Confirmation copy is sourced from ModelCacheActions for both surfaces")
    func sharedConfirmationCopy() {
        // The management panel's ``.confirmationDialog`` reads
        // ``ModelCacheActions.deletionConfirmation``; the picker
        // (post-#210) routes ``runDeletion`` through
        // ``ModelCacheActions.runDeletion``. Both produce the same
        // deletion-title shape — pin parity here so a future copy
        // tweak to one helper hits both surfaces or fails CI.
        let cases: [(String, String?)] = [
            ("qwen3.5-4b-4bit", "2.3 GB"),
            ("phi-4-4bit", nil),
        ]
        for (alias, size) in cases {
            let e = ModelEntry(alias: alias, hfRepo: nil, sizeOnDisk: size, cached: true)
            let pickerTitle = ModelPickerBar.deletionTitle(for: e)
            let panelTitle = ModelCacheActions.deletionConfirmation(for: e).title
            #expect(pickerTitle == panelTitle)
        }
    }
}
