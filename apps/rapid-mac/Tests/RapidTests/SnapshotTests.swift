import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// Visual regression tests for the three primary panels in their
/// load-bearing states.
///
/// Why snapshot tests on top of ViewInspector + branch-routing tests:
///   * View-tree assertions verify "the right text is in the tree."
///   * Snapshot tests verify "and it looks roughly the same as it did
///     yesterday." Catches spacing, font, color, alignment drifts
///     that ``find(text:)`` is blind to.
///
/// We deliberately do NOT snapshot ``ContentView`` itself — it pulls
/// observables out of the SwiftUI environment via the modern
/// Observation pattern, which means rendering through
/// ``NSHostingView`` either crashes ("No Observable object of type
/// X found") or silently renders an unbranched fallback. The
/// state-routing logic is covered by ``ContentViewTests`` instead.
///
/// PNGs land in ``Tests/RapidTests/__Snapshots__/`` and are
/// committed to the repo. On a regression the test fails with a
/// diff path; eyeball the new image, decide whether the change is
/// intentional, and re-run with ``SNAPSHOT_RECORD=1`` to rebaseline
/// (or delete the specific baseline PNG and re-run).
@MainActor
@Suite("Primary panel snapshots", .uiSnapshot)
struct SnapshotTests {
    private func tmpStore(seedSessions: Int = 0) -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: url)
        for i in 0..<seedSessions {
            _ = store.newSession(alias: "fake-alias-\(i)")
        }
        return store
    }

    // MARK: - SessionsSidebar

    @Test("SessionsSidebar empty state")
    func sessionsSidebarEmpty() {
        let store = tmpStore(seedSessions: 0)
        let sut = SessionsSidebar(store: store, defaultAlias: "")
        assertSnapshot(
            of: sut,
            size: CGSize(width: 240, height: 480),
            name: "sessions-sidebar-empty"
        )
    }

    // Note: the populated SessionsSidebar case is intentionally
    // ViewInspector-only (see ``SessionsSidebarTests``). SwiftUI's
    // ``List`` defers row rendering to the underlying NSTableView,
    // which requires a live NSWindow for measurement — a bare
    // NSHostingView captures the chrome (New chat button + divider)
    // but the row area is blank. Snapshot regression of the *rows*
    // would need either a real window (XCUITest, blocked here) or a
    // refactor to a VStack+ForEach layout — neither worth doing for
    // a single test slot.

    // MARK: - ModelPickerBar

    @Test("ModelPickerBar idle state — Start enabled, secondary badge")
    func modelPickerBarIdle() {
        let server = ServerManager(
            testingState: .idle,
            binaryPath: URL(fileURLWithPath: "/dev/null")
        )
        let sut = ModelPickerBar(server: server, downloads: DownloadManager(), alias: .constant("fake-alias"))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 880, height: 56),
            name: "model-picker-bar-idle"
        )
    }

    @Test("ModelPickerBar starting state — Stop visible, yellow badge")
    func modelPickerBarStarting() {
        let server = ServerManager(
            testingState: .starting(alias: "fake-alias"),
            binaryPath: URL(fileURLWithPath: "/dev/null")
        )
        let sut = ModelPickerBar(server: server, downloads: DownloadManager(), alias: .constant("fake-alias"))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 880, height: 56),
            name: "model-picker-bar-starting"
        )
    }

    @Test("ModelPickerBar ready state — green badge + Stop")
    func modelPickerBarReady() {
        let server = ServerManager(
            testingState: .ready(alias: "qwen3.6-27b"),
            binaryPath: URL(fileURLWithPath: "/dev/null")
        )
        let sut = ModelPickerBar(server: server, downloads: DownloadManager(), alias: .constant("qwen3.6-27b"))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 880, height: 56),
            name: "model-picker-bar-ready"
        )
    }

    @Test("ModelPickerBar missing — disabled start + grey badge")
    func modelPickerBarMissing() {
        let server = ServerManager(testingState: .missing, binaryPath: nil)
        let sut = ModelPickerBar(server: server, downloads: DownloadManager(), alias: .constant(""))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 880, height: 56),
            name: "model-picker-bar-missing"
        )
    }

    // MARK: - CheetahLogo

    // v0.5.9: pin both render-size branches of ``CheetahLogo`` so a
    // future Resources/ rename or a Package.swift ``resources:``
    // misconfiguration can't silently slide the chat hero back to
    // the SF Symbol fallback. The 28pt case hits ``cheetah-sm.png``;
    // the 96pt case hits ``cheetah.png``. If ``Bundle.module``
    // returns nil, both snapshots flip to a ``hare.fill`` glyph and
    // the test fails — same canary the SessionsSidebar empty-state
    // snapshot gives us but framed against the asset directly.

    @Test("CheetahLogo small — sidebar header size")
    func cheetahLogoSmall() {
        assertSnapshot(
            of: CheetahLogo(size: 28),
            size: CGSize(width: 56, height: 56),
            name: "cheetah-logo-28"
        )
    }

    @Test("CheetahLogo large — empty-state hero size")
    func cheetahLogoLarge() {
        assertSnapshot(
            of: CheetahLogo(size: 96),
            size: CGSize(width: 140, height: 140),
            name: "cheetah-logo-96"
        )
    }
}
