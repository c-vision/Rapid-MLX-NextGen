import Foundation
import Testing
@testable import Rapid

/// Truth-table for ``DesktopVersionPill.resolve``. Three-state pure
/// derivation: never paints red (a transient worker blip should not
/// look like a fault), never claims "up to date" without a confirmed
/// release lookup, never claims "up to date" when the installed
/// build is ahead of the manifest (the v0.7.4 bug).
@MainActor
@Suite("DesktopVersionPill state resolution")
struct DesktopVersionPillTests {
    private func release(_ version: String) -> UpdateChecker.Release {
        UpdateChecker.Release(
            schemaVersion: 1,
            version: version,
            tagName: "v\(version)",
            htmlURL: "https://github.com/machinefi/rapid-desktop/releases/tag/v\(version)",
            notes: "",
            publishedAt: "2026-06-16T00:00:00Z",
            dmgURL: nil
        )
    }

    @Test("availableUpdate non-nil → .updateAvailable carries both versions")
    func updateAvailableWins() {
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.6.8",
            availableUpdate: release("0.6.9"),
            latest: release("0.6.9")
        )
        #expect(state == .updateAvailable(current: "0.6.8", latest: "0.6.9"))
    }

    @Test("latest resolved + no availableUpdate → .upToDate")
    func latestResolvedNoUpgrade() {
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.6.9",
            availableUpdate: nil,
            latest: release("0.6.9")
        )
        #expect(state == .upToDate(version: "0.6.9"))
    }

    @Test("First check still in flight (latest nil) → .unknown, never claims up-to-date")
    func unknownBeforeFirstCheck() {
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.6.8",
            availableUpdate: nil,
            latest: nil
        )
        #expect(state == .unknown(version: "0.6.8"))
    }

    @Test("Transient worker failure (latest nil after error) → .unknown, not .upToDate")
    func unknownAfterTransientFailure() {
        // ``UpdateChecker.lastError`` is non-nil here but ``latest``
        // is still nil — pin that we don't paint "up to date" until
        // a release payload actually lands.
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.6.8",
            availableUpdate: nil,
            latest: nil
        )
        #expect(state == .unknown(version: "0.6.8"))
    }

    @Test("availableUpdate is the decisive signal — even if latest is also set")
    func availableUpdateWinsOverLatest() {
        // Belt-and-braces: ``availableUpdate`` is just ``latest`` filtered
        // through "is this strictly newer than us." Pin that the pill
        // routes off the filtered field, not the raw one, so a stale
        // ``latest`` cached from a prior run can't drown out a fresh
        // "you're behind" verdict.
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.6.8",
            availableUpdate: release("0.7.0"),
            latest: release("0.7.0")
        )
        #expect(state == .updateAvailable(current: "0.6.8", latest: "0.7.0"))
    }

    /// Regression for the v0.7.4 status-bar bug.
    ///
    /// Repro: ``Resources/Info.plist`` is bumped to 0.7.4 ahead of the
    /// publish-desktop-release.sh run that regenerates
    /// ``https://dl.rapidmlx.com/latest.json``. While the regeneration is
    /// in flight the manifest still advertises 0.6.14. The previous
    /// ``resolve`` returned ``.upToDate`` because ``availableUpdate``
    /// was nil and ``latest != nil``, so the chip read "Rapid Desktop
    /// 0.7.4 · up to date" — a lie that hides genuine "an even newer
    /// build is now public" cases from QA. The fix routes this through
    /// ``.unknown``.
    @Test("Installed build ahead of the manifest → .unknown, never .upToDate")
    func installedAheadOfManifestIsUnknown() {
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.7.4",
            availableUpdate: nil,
            latest: release("0.6.14")
        )
        #expect(state == .unknown(version: "0.7.4"))
    }

    /// Multi-segment / 10+ patch-number cousin of the regression above
    /// — pins that the strictly-newer check uses ``UpdateChecker.isNewer``
    /// (numeric, not lexicographic), so an installed build at 0.7.10
    /// against a manifest at 0.7.9 still routes to ``.unknown`` and not
    /// the misleading ``.upToDate``.
    @Test("Installed 0.7.10 ahead of manifest 0.7.9 → .unknown (numeric semver, not lexicographic)")
    func installedAheadNumericComparison() {
        let state = DesktopVersionPill.resolve(
            currentVersion: "0.7.10",
            availableUpdate: nil,
            latest: release("0.7.9")
        )
        #expect(state == .unknown(version: "0.7.10"))
    }
}
