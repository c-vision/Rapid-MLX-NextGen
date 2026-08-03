import Foundation
import Testing

/// Pin the asset-selection grammar of release.yml's "Bundle size
/// delta gate" so a future regression to the old endswith-only
/// filter can't reach CI again.
///
/// Background: from v0.8.6 onward, GH Releases carry TWO ``.dmg``
/// assets — the canonical full DMG (``rapid-mlx-desktop.dmg``,
/// ~157 MB) and the slim bootstrapper DMG (``rapid-mlx-desktop-
/// bootstrapper-X.Y.Z.dmg``, ~5.6 MB) added by slice ε.1 as a
/// preview asset. The old gate logic
/// ``select(.name | endswith(".dmg")) | head -1`` picked whichever
/// asset the GH API returned first, which on v0.8.6 happened to be
/// the slim bootstrapper DMG — making v0.8.7's full DMG (166 MB)
/// look like it grew by +160 MB and failing the +50 MB delta cap.
/// The fix pins the filter to exact name ``rapid-mlx-desktop.dmg``
/// so any future preview / variant DMG cannot be picked by mistake.
@Suite("Bundle size delta gate asset selection — v0.8.7 release-fail regression pin")
struct DeltaGateAssetSelectionTests {

    private static var releaseYamlPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github")
            .appendingPathComponent("workflows")
            .appendingPathComponent("release.yml")
    }

    private static func loadYaml() throws -> String {
        try String(contentsOf: Self.releaseYamlPath, encoding: .utf8)
    }

    @Test("Delta gate filters previous-release DMG by EXACT canonical name, not endswith")
    func deltaGatePinsExactCanonicalName() throws {
        let yaml = try Self.loadYaml()
        #expect(
            yaml.contains("CANONICAL_DMG_NAME=\"rapid-mlx-desktop.dmg\""),
            "release.yml's delta gate must pin the canonical DMG name to ``rapid-mlx-desktop.dmg`` (no version infix, no ``-bootstrapper-`` infix). v0.8.6 added a second ``.dmg`` preview asset and the endswith-only filter started picking it non-deterministically — failed v0.8.7 release with a phantom +160 MB delta."
        )
        #expect(
            yaml.contains("select(.name == \\\"${CANONICAL_DMG_NAME}\\\")"),
            "Delta gate must use an EXACT name match (``select(.name == \"…\")``), not endswith. v0.8.7 release failed precisely because endswith caught the bootstrapper preview DMG too. If you refactor the filter to read from an env var or a list constant, update this assertion explicitly — substring-greppability matters more than DRY here."
        )
        #expect(
            !yaml.contains("select(.name | endswith(\".dmg\")) | .size"),
            "Delta gate MUST NOT use the legacy ``select(.name | endswith(\".dmg\"))`` filter. That filter picks the first ``.dmg`` asset returned by the GH API, which from v0.8.6 onward is non-deterministically the slim bootstrapper preview DMG → false +160 MB delta → release fails. The canonical-name pin is the fix."
        )
    }
}
