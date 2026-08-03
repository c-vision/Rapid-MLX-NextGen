import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// v0.4.27 #932 — dark-mode regression baseline for the polish surfaces
/// added in v0.4.25 / v0.4.26. The existing primary-panel snapshots pin
/// only Aqua (Light) renders; this suite pins the dark counterparts so a
/// future colour-scheme drift (e.g. accidentally hard-coding a light hue
/// in a refactor) fails CI instead of slipping into a release.
///
/// We deliberately do NOT snapshot every surface in both modes — the
/// existing primary-panel tests cover the bulk of the chrome. This suite
/// scopes itself to the *new* polish surfaces from the v0.4.25-26 batch
/// because those are the ones whose colour palettes haven't been
/// previously battle-tested:
///   * ``OnboardingTour`` — new in v0.4.26.
///   * Appearance picker inside ``SettingsView`` — new in v0.4.25.
@MainActor
@Suite("Dark-mode polish-surface snapshots — #932", .uiSnapshot)
struct DarkModeSnapshotTests {
    /// SwiftUI's ``.primary`` foreground resolves to white in dark mode
    /// — when an ``NSHostingView`` has no explicit background the host
    /// canvas paints clear/white, so dark-mode text renders invisible
    /// against the snapshot bitmap. We wrap the SUT in a system window
    /// background so the rendered colour-pair is actually exercised.
    private func onCanvas<V: View>(_ view: V) -> some View {
        view.background(Color(nsColor: .windowBackgroundColor))
    }

    /// Snapshot frame matches the live tour size in ``OnboardingTour.body``.
    /// Bumped from 380 → 420 in #193 to fit the web-search-backend
    /// step's two CTA buttons under the body copy; v0.7.19 (#224)
    /// dropped that step but the 420-high frame is retained as headroom
    /// for future per-page affordances. Keep these in sync when
    /// adjusting tour frame dimensions; otherwise the snapshot will
    /// appear letterboxed and the regression bait will look like a
    /// colour drift even though only the layout changed.
    ///
    /// PNG baselines under ``__Snapshots__/onboarding-tour-{dark,light}.png``
    /// were re-recorded in v0.7.19 (#224) because dropping the
    /// web-search page removes one page-indicator dot from the rendered
    /// bitmap.
    @Test("OnboardingTour renders in dark mode without forcing a light hue")
    func onboardingTourDark() {
        let sut = onCanvas(OnboardingTour(onDone: {}))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 540, height: 420),
            name: "onboarding-tour-dark",
            appearance: .darkAqua
        )
    }

    @Test("OnboardingTour renders in light mode (baseline parity with dark)")
    func onboardingTourLight() {
        let sut = onCanvas(OnboardingTour(onDone: {}))
        assertSnapshot(
            of: sut,
            size: CGSize(width: 540, height: 420),
            name: "onboarding-tour-light",
            appearance: .aqua
        )
    }
}
