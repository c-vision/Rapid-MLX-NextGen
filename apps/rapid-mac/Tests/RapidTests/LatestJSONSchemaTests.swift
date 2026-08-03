import Foundation
import Testing
@testable import Rapid

/// Cross-decoder schema tests for the static ``latest.json`` manifest
/// published to ``https://dl.rapidmlx.com/latest.json`` by the
/// ``Mirror DMG + publish latest.json to dl.rapidmlx.com (R2)`` step
/// in ``.github/workflows/release.yml``.
///
/// Two decoders consume the same payload:
///
///   * ``UpdateChecker.Release`` (Sources/Rapid/Updater/UpdateChecker.swift)
///     — the in-app self-update poller. v0.8.x users always hit this
///     decoder, never the bootstrapper one (they take the
///     `.installed(.bundled)` short-circuit).
///   * ``BootstrapManifest`` (Sources/Rapid/Bootstrapper/BootstrapCoordinator.swift)
///     — the first-install bootstrapper coordinator. Only reached on
///     bootstrapper-DMG installs (slice ε onwards).
///
/// Slice δ extends the manifest with four optional ``model_*`` fields
/// (model_url / model_sha256 / model_size / model_alias). Both
/// decoders MUST:
///
///   1. Continue to decode a pre-slice-δ payload (no ``model_*``
///      fields) without failure — that's today's production shape,
///      and is what every v0.8.x client polls.
///   2. Decode a post-slice-δ payload (all four ``model_*`` fields
///      populated) with the fields surfaced to their respective
///      typed properties, and ``schema_version`` STILL == 1.
///
/// These tests are the regression net that catches a schema-version
/// bump (forbidden — schema_version stays at 1), a typo in a Coding
/// Key (e.g. ``model_alais``), or a Codable contract change that
/// silently flips a field from Optional to required.
@Suite("latest.json schema — cross-decoder contract (slice δ)")
struct LatestJSONSchemaTests {

    // MARK: - Fixtures

    /// Today's production latest.json shape (sidecar fields present;
    /// no model_* fields). Verbatim except for value redaction so the
    /// test stays stable across release cuts.
    ///
    /// Matches the curl of dl.rapidmlx.com/latest.json on 2026-06-24
    /// (post-v0.8.5, pre-slice-δ deploy).
    private static let productionShapePreSliceDelta: String = """
    {
      "schema_version": 1,
      "version": "0.8.5",
      "tag_name": "v0.8.5",
      "html_url": "https://rapidmlx.com/desktop",
      "notes": "test notes — markdown body redacted for the unit test",
      "published_at": "2026-06-24T19:25:12Z",
      "dmg_url": "https://dl.rapidmlx.com/rapid-mlx-desktop-0.8.5.dmg",
      "dmg_sha256": "7e1d98ba345fddf970f8d8ce59c3cd371a03f1c399f1a5d4fbe1b61772c2a4dc",
      "dmg_size": 156053699,
      "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz",
      "sidecar_sha256": "6e7ad75c945993a23101b2c0ae98a8079f2719ebb54bada8fcd185f0d9fdca12",
      "sidecar_size": 125969942,
      "sidecar_version": "0.8.18"
    }
    """

    /// Synthetic post-slice-δ payload: the production shape plus the
    /// four ``model_*`` fields the slice δ release.yml composes when
    /// the Quickstart pack succeeded. SHA256 / size redacted to a
    /// stable lowercase-hex / positive-integer pair; alias is the
    /// constant ``release.yml`` pins (``bonsai-1.7b-2bit``).
    private static let productionShapePostSliceDelta: String = """
    {
      "schema_version": 1,
      "version": "0.9.0",
      "tag_name": "v0.9.0",
      "html_url": "https://rapidmlx.com/desktop",
      "notes": "test notes — markdown body redacted for the unit test",
      "published_at": "2026-06-25T00:00:00Z",
      "dmg_url": "https://dl.rapidmlx.com/rapid-mlx-desktop-0.9.0.dmg",
      "dmg_sha256": "7e1d98ba345fddf970f8d8ce59c3cd371a03f1c399f1a5d4fbe1b61772c2a4dc",
      "dmg_size": 156053699,
      "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz",
      "sidecar_sha256": "6e7ad75c945993a23101b2c0ae98a8079f2719ebb54bada8fcd185f0d9fdca12",
      "sidecar_size": 125969942,
      "sidecar_version": "0.8.18",
      "model_url": "https://dl.rapidmlx.com/quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz",
      "model_sha256": "6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a22",
      "model_size": 303104000,
      "model_alias": "bonsai-1.7b-2bit"
    }
    """

    // MARK: - UpdateChecker decoder (v0.8.x in-app)

    @Test("UpdateChecker decodes pre-slice-δ payload (today's production shape)")
    func updateCheckerDecodesPreSliceDelta() throws {
        // v0.8.x production: no model_* fields. The Codable type
        // defaults the four to nil; schema_version stays at 1.
        let data = Self.productionShapePreSliceDelta.data(using: .utf8)!
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: data)
        // Core fields surface correctly.
        #expect(release.schemaVersion == 1)
        #expect(release.version == "0.8.5")
        #expect(release.tagName == "v0.8.5")
        #expect(release.dmgURL == "https://dl.rapidmlx.com/rapid-mlx-desktop-0.8.5.dmg")
        // Sidecar fields populated (they're already on the wire today).
        #expect(release.sidecarURL == "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.8.5.tar.gz")
        #expect(release.sidecarVersion == "0.8.18")
        #expect(release.sidecarSize == 125969942)
        // The four slice δ fields default to nil on absence —
        // that's the load-bearing backward-compat invariant.
        #expect(release.modelURL == nil)
        #expect(release.modelSHA256 == nil)
        #expect(release.modelSize == nil)
        #expect(release.modelAlias == nil)
    }

    @Test("UpdateChecker decodes post-slice-δ payload (with model_* fields)")
    func updateCheckerDecodesPostSliceDelta() throws {
        // Forward-compat: a future client decoding tomorrow's wire
        // shape surfaces all four model_* fields.
        let data = Self.productionShapePostSliceDelta.data(using: .utf8)!
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: data)
        #expect(release.schemaVersion == 1, "schema_version MUST stay at 1 across slice δ — additive optional fields don't require a bump (and a bump would break v0.8.x clients hard).")
        #expect(release.modelURL == "https://dl.rapidmlx.com/quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz")
        #expect(release.modelSHA256 == "6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a22")
        #expect(release.modelSize == 303104000)
        #expect(release.modelAlias == "bonsai-1.7b-2bit")
    }

    // MARK: - BootstrapManifest decoder (bootstrapper-DMG users)

    @Test("BootstrapManifest decodes pre-slice-δ payload — hasModelArtifact == false (sidecar-only)")
    func bootstrapManifestDecodesPreSliceDelta() throws {
        // Slice γ's invariant: pre-slice-δ manifest decodes cleanly,
        // ``hasModelArtifact`` is false, ``validate(_:)`` accepts.
        // That's how the bootstrapper falls back to sidecar-only
        // install on a publisher run where slice β's pack failed
        // (continue-on-error left no bytes; R2 mirror omitted the
        // model_* block).
        let data = Self.productionShapePreSliceDelta.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.version == "0.8.5")
        #expect(manifest.sidecarVersion == "0.8.18")
        #expect(manifest.modelURL == nil)
        #expect(manifest.modelSHA256 == nil)
        #expect(manifest.modelSize == nil)
        #expect(manifest.modelAlias == nil)
        #expect(manifest.hasModelArtifact == false, "pre-slice-δ manifest must surface hasModelArtifact == false so the bootstrapper falls back to sidecar-only install")
        // ``validate`` must not reject this shape — it's today's
        // production manifest. Treat a throw as a hard failure.
        do {
            try BootstrapCoordinator.validate(manifest)
        } catch {
            Issue.record("BootstrapCoordinator.validate rejected today's production latest.json shape: \(error). Slice δ must not change validate's acceptance of a manifest with no model_* fields.")
        }
    }

    @Test("BootstrapManifest decodes post-slice-δ payload — hasModelArtifact == true (concurrent install)")
    func bootstrapManifestDecodesPostSliceDelta() throws {
        // Slice γ's other invariant: post-slice-δ manifest decodes
        // cleanly, surfaces all four model_* fields, ``validate(_:)``
        // accepts them as a valid bootstrapper install spec.
        let data = Self.productionShapePostSliceDelta.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.hasModelArtifact == true, "post-slice-δ manifest with all four model_* fields must surface hasModelArtifact == true so the bootstrapper triggers concurrent sidecar + model install")
        #expect(manifest.modelURL?.absoluteString == "https://dl.rapidmlx.com/quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz")
        #expect(manifest.modelSHA256 == "6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a2254795d6a22")
        #expect(manifest.modelSize == 303104000)
        #expect(manifest.modelAlias == "bonsai-1.7b-2bit")
        do {
            try BootstrapCoordinator.validate(manifest)
        } catch {
            Issue.record("BootstrapCoordinator.validate rejected synthetic post-slice-δ latest.json shape: \(error). Slice δ's wire payload MUST be a valid bootstrap manifest.")
        }
    }

    // MARK: - Both decoders agree on the schema_version pin

    @Test("schema_version stays at 1 on both pre- and post-slice-δ payloads (both decoders)")
    func schemaVersionStaysAtOne() throws {
        // Anti-regression: a publisher-side typo or a future "let's
        // bump the schema while we're at it" mistake would break
        // v0.8.x UpdateChecker's validateReleasePayload (which
        // enforces schema_version == 1 exactly). Pin the literal
        // here so a wire-format experiment can't silently land.
        for payload in [Self.productionShapePreSliceDelta, Self.productionShapePostSliceDelta] {
            let data = payload.data(using: .utf8)!
            let updateRelease = try JSONDecoder().decode(UpdateChecker.Release.self, from: data)
            let bootstrap = try JSONDecoder().decode(BootstrapManifest.self, from: data)
            #expect(updateRelease.schemaVersion == 1, "UpdateChecker decode flipped schema_version off 1 on payload: \(payload)")
            #expect(bootstrap.schemaVersion == 1, "BootstrapManifest decode flipped schema_version off 1 on payload: \(payload)")
        }
    }

    // MARK: - Partial model_* payload (all-or-nothing invariant)

    @Test("partial model_* payload (e.g. model_url only) — validate REJECTS for BootstrapManifest")
    func partialModelFieldsRejectedByValidate() throws {
        // Slice γ's validateModelFields contract: all four fields
        // present OR all four absent. A wire payload with a partial
        // set MUST be rejected by validate so the install pipeline
        // doesn't half-install a model. UpdateChecker doesn't apply
        // this gate (it's a bootstrapper concern), but the
        // BootstrapManifest path MUST.
        let partial = """
        {
          "schema_version": 1,
          "version": "0.9.0",
          "sidecar_url": "https://dl.rapidmlx.com/rapid-mlx-sidecar-0.9.0.tar.gz",
          "sidecar_sha256": "6e7ad75c945993a23101b2c0ae98a8079f2719ebb54bada8fcd185f0d9fdca12",
          "sidecar_size": 125969942,
          "sidecar_version": "0.8.18",
          "model_url": "https://dl.rapidmlx.com/quickstart-bonsai-1.7b-2bit-0.9.0.tar.gz"
        }
        """
        let data = partial.data(using: .utf8)!
        // Decoding itself succeeds — the missing fields default to nil.
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: data)
        // But validate must reject — partial set is a publisher bug.
        do {
            try BootstrapCoordinator.validate(manifest)
            Issue.record("BootstrapCoordinator.validate accepted a partial model_* set (only model_url present). Slice γ's all-or-nothing invariant was bypassed — that would let a hostile or buggy publisher half-install the model leg.")
        } catch let error as BootstrapCoordinator.ManifestError {
            // Expected. Surface the message for diagnostic value.
            let s = "\(error)"
            #expect(s.contains("partial model artifact") || s.contains("partial"),
                    "validate rejected the partial set but the message doesn't mention 'partial' — error: \(s). The error message is user-facing diagnostic; keep the wording so a publisher debugging a 'why didn't my model_* fields publish' trail can grep for it.")
        } catch {
            Issue.record("validate threw an unexpected error type on the partial set: \(error)")
        }
    }
}
