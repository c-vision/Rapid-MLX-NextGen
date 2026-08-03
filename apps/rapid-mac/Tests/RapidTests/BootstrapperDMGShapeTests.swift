import Foundation
import Testing

/// Pin the shape of ``scripts/build-bootstrapper-dmg.sh`` and the
/// release.yml workflow step that surfaces it as an artifact (P3
/// slice α — see ``.claude/loop/bootstrapper-plan.md``). The script
/// and the workflow step compose: a regression in either side (e.g.
/// a future maintainer dropping the strip step thinking it's
/// "redundant after slice ε", or removing ``continue-on-error`` and
/// letting the slim build fail the main release) is invisible until
/// the next release tag burns. These tests catch the regression in
/// CI as a unit-test failure on a PR.
///
/// Pattern mirrors ``SidecarShimHardeningTests``:
///   - Locate the source file by walking up from ``#filePath`` (works
///     for ``swift test``, Xcode, CI alike).
///   - Read the file as UTF-8.
///   - Assert canonical substrings / structural invariants.
///
/// The asserts intentionally pin the SHAPE — not byte-for-byte text —
/// so the script can be reformatted (comments / whitespace) without
/// breaking these tests. What is pinned is what we care about:
/// strict-mode shell, the strip target, the codesign re-sign, the
/// size gates, and the workflow step's release-safety invariants.
@Suite("Bootstrapper DMG slice α — script + workflow shape")
struct BootstrapperDMGShapeTests {

    /// Repository root, derived from ``#filePath`` so the test runs
    /// from any cwd.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static var scriptPath: URL {
        sourceRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("build-bootstrapper-dmg.sh")
    }

    private static var releaseYamlPath: URL {
        sourceRoot
            .appendingPathComponent(".github")
            .appendingPathComponent("workflows")
            .appendingPathComponent("release.yml")
    }

    private static func loadScript() throws -> String {
        try String(contentsOf: scriptPath, encoding: .utf8)
    }

    private static func loadReleaseYaml() throws -> String {
        try String(contentsOf: releaseYamlPath, encoding: .utf8)
    }

    /// Strip whitespace from every character so substring matches
    /// survive reformatting. Mirrors the helper in
    /// ``SidecarShimHardeningTests``.
    private static func stripWhitespace(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    // MARK: - script shape

    @Test("script enables bash strict mode (set -euo pipefail)")
    func scriptUsesStrictMode() throws {
        let body = try Self.loadScript()
        // Pin ``set -euo pipefail`` explicitly — losing any of the
        // three flags (e / u / o pipefail) silently changes failure
        // semantics. A future ``set -e`` alone would let an undefined
        // variable / mid-pipeline failure slip past.
        #expect(
            body.contains("set -euo pipefail"),
            "scripts/build-bootstrapper-dmg.sh is missing ``set -euo pipefail``. Strict mode is load-bearing: ``-u`` catches typo'd env overrides, ``-o pipefail`` catches a failing stage in ``find … | xargs file | grep -c``-style chains. Restore it at the top of the script."
        )
    }

    @Test("script has the canonical bash shebang")
    func scriptHasBashShebang() throws {
        let body = try Self.loadScript()
        // Match scripts/dmg.sh / scripts/build-sidecar-tarball.sh —
        // ``/usr/bin/env bash`` works on macOS runners and on any
        // contributor's Mac without a hard /bin/bash assumption.
        #expect(
            body.hasPrefix("#!/usr/bin/env bash\n"),
            "scripts/build-bootstrapper-dmg.sh must start with ``#!/usr/bin/env bash`` to match the rest of the build scripts."
        )
    }

    @Test("script targets Contents/Resources/rapid-mlx for the strip")
    func scriptStripsCorrectPath() throws {
        let body = try Self.loadScript()
        // The bootstrapper installs at runtime to
        // ~/Library/Application Support/Rapid/runtime-override/rapid-mlx/.
        // The .app's own slot at Contents/Resources/rapid-mlx/ is the
        // ONLY path ServerLocator's .bundled probe checks. Stripping
        // anything else (or NOT stripping this path) would either
        // ship a half-broken .app or fail to slim the build.
        #expect(
            body.contains("Contents/Resources/rapid-mlx"),
            "scripts/build-bootstrapper-dmg.sh must reference ``Contents/Resources/rapid-mlx`` (the strip target). This is the exact path ServerLocator.swift's ``.bundled`` probe checks; stripping anywhere else would either ship a stub .app or fail to slim."
        )
        // Defence-in-depth: the script must actually invoke ``rm -rf``
        // against that path (not just mention it in a comment).
        // Strip whitespace from both sides so the check survives
        // reformatting of the ``rm -rf "$SIDECAR_INSIDE_SCRATCH"``
        // expression (e.g. wrapped onto multiple lines).
        let stripped = Self.stripWhitespace(body)
        #expect(
            stripped.contains("rm-rf\"$SIDECAR_INSIDE_SCRATCH\""),
            "scripts/build-bootstrapper-dmg.sh references the sidecar path but doesn't actually ``rm -rf`` it. Restore the ``rm -rf \"$SIDECAR_INSIDE_SCRATCH\"`` strip step."
        )
    }

    @Test("script re-codesigns the stripped .app")
    func scriptReCodesigns() throws {
        let body = try Self.loadScript()
        // Stripping a sealed bundle invalidates _CodeSignature/CodeResources
        // because the sidecar's hashes were embedded into the seal.
        // ``codesign --force --sign`` (ad-hoc or Developer ID) MUST
        // run on the scratch .app before it goes into the DMG, or
        // ``codesign -v`` on the produced DMG will trip
        // "resource added that did not exist at signing time".
        #expect(
            body.contains("codesign --force --sign"),
            "scripts/build-bootstrapper-dmg.sh must re-codesign the stripped .app with ``codesign --force --sign``. Without re-signing, the stripped tree fails ``codesign -v`` because the sidecar's hashes are still in the resource envelope."
        )
        // Verify the script also verifies the new signature before
        // packing the DMG.
        #expect(
            body.contains("codesign --verify --deep --strict"),
            "scripts/build-bootstrapper-dmg.sh must run ``codesign --verify --deep --strict`` on the re-signed .app before packing the DMG, so a bad re-sign fails locally instead of on a user's Mac."
        )
    }

    @Test("script has size sanity gates (both lower and upper bound)")
    func scriptHasSizeGates() throws {
        let body = try Self.loadScript()
        // Upper bound: target shape per the plan is 5-8 MB; 50 MB
        // headroom catches a gross regression (e.g. a future
        // maintainer accidentally re-bundling site-packages into
        // Contents/Resources/). The number itself is pinned so a
        // silent bump to "500" doesn't slip through review.
        #expect(
            body.contains("BOOTSTRAPPER_DMG_MAX_MB:-50"),
            "scripts/build-bootstrapper-dmg.sh must default the upper size gate to 50 MB (``BOOTSTRAPPER_DMG_MAX_MB:-50``). Target shape per .claude/loop/bootstrapper-plan.md is 5-8 MB; 50 MB headroom catches gross regressions without false-failing on the natural 5-8 MB range."
        )
        // Lower bound: a build that produced 0 / sub-1 MB DMG almost
        // certainly means the .app got over-stripped (e.g. the .app
        // binary itself got removed by accident) and would silently
        // ship a stub. Floor at 1 MB.
        #expect(
            body.contains("BOOTSTRAPPER_DMG_MIN_MB:-1"),
            "scripts/build-bootstrapper-dmg.sh must default the lower size gate to 1 MB (``BOOTSTRAPPER_DMG_MIN_MB:-1``). A sub-1 MB DMG almost certainly means the .app was over-stripped (lost its SwiftUI binary or assets) and would ship a stub."
        )
        // Pin the exit-on-cap semantics — the gates must FAIL the
        // build, not just print a warning.
        #expect(
            body.contains("exceeds the ${MAX_MB} MB"),
            "scripts/build-bootstrapper-dmg.sh's upper size gate must FAIL the build with a clear error referencing the ceiling, not just print a warning."
        )
        #expect(
            body.contains("below the ${MIN_MB} MB"),
            "scripts/build-bootstrapper-dmg.sh's lower size gate must FAIL the build with a clear error referencing the floor, not just print a warning."
        )
    }

    @Test("size gate compares BYTES, not du -sm output (catches sub-1 MB DMGs)")
    func scriptGatesOnBytesNotDuMb() throws {
        // Codex r1 MAJOR: macOS ``du -sm`` reports whole-MiB disk-usage
        // rounded UP, so a 100 KB DMG can report `1` and silently pass
        // a ``>= 1 MB`` lower gate. The gate MUST compare bytes
        // (``stat -f%z``) against MIN_BYTES / MAX_BYTES derived from
        // the MB env vars via ``MIN_MB * 1048576``. This test pins
        // both the derivation AND the byte-comparison so a future
        // refactor that reverts to du-based comparison trips here.
        let body = try Self.loadScript()
        #expect(
            body.contains("MIN_BYTES=$(( MIN_MB * 1048576 ))"),
            "scripts/build-bootstrapper-dmg.sh must derive MIN_BYTES from MIN_MB * 1048576 (1 MiB). du -sm rounds up so byte-precise comparison is the only correct floor."
        )
        #expect(
            body.contains("MAX_BYTES=$(( MAX_MB * 1048576 ))"),
            "scripts/build-bootstrapper-dmg.sh must derive MAX_BYTES from MAX_MB * 1048576 (1 MiB). du -sm rounds up so byte-precise comparison is the only correct ceiling."
        )
        // Pin the actual comparison uses bytes, not MB. A regression
        // that reverts to ``[[ "$DMG_MB" -lt "$MIN_MB" ]]`` would
        // re-introduce the rounding bug from codex r1.
        #expect(
            body.contains("[[ \"$DMG_BYTES\" -lt \"$MIN_BYTES\" ]]"),
            "scripts/build-bootstrapper-dmg.sh's lower gate must compare DMG_BYTES against MIN_BYTES (not DMG_MB against MIN_MB). du -sm rounds up; bytes don't."
        )
        #expect(
            body.contains("[[ \"$DMG_BYTES\" -gt \"$MAX_BYTES\" ]]"),
            "scripts/build-bootstrapper-dmg.sh's upper gate must compare DMG_BYTES against MAX_BYTES (not DMG_MB against MAX_MB). du -sm rounds up; bytes don't."
        )
        // Anti-regression: explicitly assert the DMG_MB-vs-MIN_MB /
        // DMG_MB-vs-MAX_MB comparison forms are NOT present. The
        // codex r1 root cause was exactly those forms.
        #expect(
            !body.contains("\"$DMG_MB\" -lt \"$MIN_MB\"") &&
            !body.contains("\"$DMG_MB\" -gt \"$MAX_MB\""),
            "scripts/build-bootstrapper-dmg.sh appears to be comparing DMG_MB (du -sm output) against MIN_MB / MAX_MB. This was the codex r1 MAJOR root cause: du -sm rounds whole-MiB blocks UP, so a sub-1 MB DMG can report `1` and silently pass the floor. Switch to byte-precise: ``[[ \"$DMG_BYTES\" -lt \"$MIN_BYTES\" ]]`` / ``-gt \"$MAX_BYTES\"``."
        )
    }

    @Test("script documents determinism gap for slice γ to address")
    func scriptDocumentsDeterminismGap() throws {
        // Codex r1 MAJOR: re-runs of this script do NOT produce
        // byte-identical DMGs (hdiutil per-volume UUIDs, --timestamp
        // TSA stamps, etc). Slice α is artifact-only so this is
        // acceptable; slice γ will need to address it before the slim
        // DMG can become a content-hash target. Pin a documentation
        // comment so a future maintainer doesn't accidentally rely
        // on byte-equivalence without re-reading codex r1 findings.
        let body = try Self.loadScript()
        #expect(
            body.contains("Determinism") || body.contains("determinism"),
            "scripts/build-bootstrapper-dmg.sh must document its determinism gap (hdiutil per-volume UUIDs + codesign --timestamp prevent byte-identical re-runs). latest.json publishes the sha256 so byte-stability is not required, but future content-addressed callsites should know the levers."
        )
    }

    @Test("script verifies codesign inside the produced DMG")
    func scriptVerifiesDmgContents() throws {
        let body = try Self.loadScript()
        // Final defensive check — mount the produced DMG and re-verify
        // codesign on the .app inside. Catches any mid-flight
        // corruption between the scratch sign step and the hdiutil
        // pack (a 0-day in a future hdiutil that silently corrupts a
        // small fraction of files, etc).
        #expect(
            body.contains("hdiutil attach") && body.contains("-readonly"),
            "scripts/build-bootstrapper-dmg.sh must mount the produced DMG read-only and re-verify codesign on the .app inside. Without this, a corruption between sign-time and pack-time only surfaces on an end-user's Mac. Restore the ``hdiutil attach … -readonly`` + ``codesign --verify --deep --strict`` block at the end of the script."
        )
        // Pin the cleanup trap — the mountpoint MUST be detached on
        // exit (success or failure) or repeated runs leak mounts.
        #expect(
            body.contains("hdiutil detach"),
            "scripts/build-bootstrapper-dmg.sh must detach the mountpoint in its cleanup trap (``hdiutil detach``). Without this, a failure between mount and verify leaves the mount attached."
        )
        #expect(
            body.contains("trap "),
            "scripts/build-bootstrapper-dmg.sh must install a cleanup ``trap`` so a mid-flight failure doesn't leak the scratch / staging / mountpoint dirs."
        )
    }

    @Test("script output path is deterministic and disambiguated from main DMG")
    func scriptOutputNameDoesNotCollideWithMainDmg() throws {
        let body = try Self.loadScript()
        // The main DMG that scripts/dmg.sh produces is
        // ``build/rapid-mlx-desktop.dmg``. The slim DMG MUST use a
        // distinct name so a CI step that copies / globs / uploads
        // the canonical name can never accidentally pick up the slim
        // DMG (and vice versa).
        #expect(
            body.contains("rapid-mlx-desktop-bootstrapper.dmg"),
            "scripts/build-bootstrapper-dmg.sh must emit ``rapid-mlx-desktop-bootstrapper.dmg`` (lowercase-hyphenated since v0.8.11 PR #428) so it is unambiguously distinct from ``rapid-mlx-desktop.dmg`` (the canonical release DMG)."
        )
        // Negative: the script must NOT write to the canonical name —
        // that would clobber the main DMG.
        #expect(
            !body.contains("DMG=\"$BUILD/rapid-mlx-desktop.dmg\""),
            "scripts/build-bootstrapper-dmg.sh must not write to ``$BUILD/rapid-mlx-desktop.dmg`` — that's the canonical release DMG that scripts/dmg.sh owns."
        )
    }

    // MARK: - release.yml workflow shape

    @Test("release.yml has the new bootstrapper DMG build step")
    func releaseYamlHasBuildStep() throws {
        let body = try Self.loadReleaseYaml()
        // Name pinned so a future re-name doesn't silently drop the
        // step from the workflow summary (where ops look for it).
        #expect(
            body.contains("name: Build bootstrapper DMG (artifact-only)"),
            ".github/workflows/release.yml is missing the ``Build bootstrapper DMG (artifact-only)`` step. This step is the P3 slice α artifact path; without it the slim DMG never gets built in CI."
        )
        // The step must invoke the script with the canonical .app
        // path so re-runs of release.yml on the same tag produce a
        // deterministic input.
        #expect(
            body.contains("bash scripts/build-bootstrapper-dmg.sh \"build/Rapid-MLX Desktop.app\""),
            ".github/workflows/release.yml's bootstrapper DMG step must invoke ``bash scripts/build-bootstrapper-dmg.sh \"build/Rapid-MLX Desktop.app\"`` so the slim build keys off the same .app the canonical DMG ships from."
        )
    }

    @Test("release.yml's bootstrapper DMG step is continue-on-error (cannot block release)")
    func releaseYamlBuildStepIsNonBlocking() throws {
        let body = try Self.loadReleaseYaml()
        // The whole point of slice α: the slim DMG is an artifact
        // path that MUST NEVER fail the canonical release. If a
        // future maintainer drops ``continue-on-error: true`` (or
        // sets it to ``false``), a transient hdiutil / signing
        // failure tanks the main DMG release too. Pin both the
        // build step AND the upload step.
        let lines = body.split(separator: "\n").map { String($0) }
        // Find the index of the build step's ``name:`` line, then
        // search forward through that step's block for the
        // ``continue-on-error: true`` line. The step boundary is
        // the next ``- name:`` line (or end of file).
        guard let buildNameIdx = lines.firstIndex(where: {
            $0.contains("name: Build bootstrapper DMG (artifact-only)")
        }) else {
            Issue.record("release.yml has no ``Build bootstrapper DMG (artifact-only)`` step — see the buildStepIsPresent test for the canonical fix.")
            return
        }
        var stepEndIdx = lines.count
        for i in (buildNameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[buildNameIdx..<stepEndIdx].joined(separator: "\n")
        #expect(
            stepBlock.contains("continue-on-error: true"),
            "release.yml's ``Build bootstrapper DMG`` step must carry ``continue-on-error: true`` so a slim-build failure cannot block the canonical release. This is the load-bearing invariant of slice α."
        )
    }

    @Test("release.yml uploads bootstrapper DMG as a workflow artifact (not a release asset)")
    func releaseYamlUploadsAsWorkflowArtifact() throws {
        let body = try Self.loadReleaseYaml()
        // Pin the artifact name so slice β/γ (which will consume this
        // artifact from a follow-up job) has a stable handle.
        #expect(
            body.contains("name: rapid-mlx-desktop-bootstrapper-dmg"),
            "release.yml must upload the slim DMG as a workflow artifact named ``rapid-mlx-desktop-bootstrapper-dmg``. Slice β/γ keys off this exact name."
        )
        // Pin the file path so the artifact actually contains the
        // slim DMG bytes (not, e.g., the canonical DMG by accident).
        #expect(
            body.contains("path: build/rapid-mlx-desktop-bootstrapper.dmg"),
            "release.yml's bootstrapper DMG artifact must upload ``build/rapid-mlx-desktop-bootstrapper.dmg`` (lowercase-hyphenated since v0.8.11 PR #428) — the exact path the script writes to."
        )
    }

    @Test("release.yml runs slim build AFTER scripts/dmg.sh (cannot reorder)")
    func releaseYamlOrdersBuildAfterDmgSh() throws {
        let body = try Self.loadReleaseYaml()
        // The slim build strips Contents/Resources/rapid-mlx/ from
        // the .app — if it ran BEFORE scripts/dmg.sh, the canonical
        // DMG would also ship without the bundled sidecar (the .app
        // bytes are shared). Pin the ordering: scripts/dmg.sh's
        // invocation index < bootstrapper DMG step's invocation
        // index. Both are checked via raw substring index because
        // YAML order = workflow execution order.
        guard let dmgShIdx = body.range(of: "bash scripts/dmg.sh") else {
            Issue.record("release.yml has no ``bash scripts/dmg.sh`` invocation — the canonical DMG step was renamed or removed; investigate before merging slice α.")
            return
        }
        guard let bootstrapperIdx = body.range(of: "bash scripts/build-bootstrapper-dmg.sh") else {
            Issue.record("release.yml has no ``bash scripts/build-bootstrapper-dmg.sh`` invocation — the slim build step was renamed or removed.")
            return
        }
        #expect(
            dmgShIdx.lowerBound < bootstrapperIdx.lowerBound,
            "release.yml runs ``scripts/build-bootstrapper-dmg.sh`` BEFORE ``scripts/dmg.sh``. Keep the slim build strictly AFTER ``scripts/dmg.sh`` so the canonical DMG is produced from the un-stripped .app first."
        )
    }

    @Test("release.yml notarises the bootstrapper DMG (slice ε.1 — invokes notarize.sh on the slim DMG)")
    func releaseYamlNotarisesBootstrapperDmg() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.1 (.claude/loop/bootstrapper-plan.md): the slim DMG
        // produced by slice α must be notarised + stapled so the next
        // slice (ε.2) can flip ``latest.json.dmg_url`` without
        // inheriting a broken-Gatekeeper asset on day 1. notarize.sh
        // accepts ``<submit-file> <staple-target>`` argv and for a
        // .dmg the two are the same path (see the script header).
        // Pin the canonical invocation form so a reformat that swaps
        // the staple-target by accident trips here.
        #expect(
            body.contains("bash scripts/notarize.sh \"$SLIM_DMG\" \"$SLIM_DMG\""),
            "release.yml's slice ε.1 step must invoke ``bash scripts/notarize.sh \"$SLIM_DMG\" \"$SLIM_DMG\"`` (submit-target = staple-target for a .dmg per notarize.sh's header). Without this, the slim DMG never gets a notary ticket stapled and the R2 mirror step's stapler-validate gate silently skips publication on every release."
        )
    }

    @Test("release.yml's bootstrapper notarise step is continue-on-error (cannot block release)")
    func releaseYamlNotarizeBootstrapperIsNonBlocking() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.1's load-bearing invariant: if the slim DMG
        // notarisation fails (Apple Notary 403, transient backoff,
        // agreement re-sign needed — see memory note
        // ``project_rapid_desktop_v083_shipped``), the canonical
        // release MUST still ship. ``continue-on-error: true`` on
        // the notarise step + a stapler-validate gate on the R2
        // mirror step is the dual-belt that delivers that.
        let lines = body.split(separator: "\n").map { String($0) }
        guard let notariseNameIdx = lines.firstIndex(where: {
            $0.contains("name: Notarise + staple bootstrapper DMG")
        }) else {
            Issue.record("release.yml has no ``Notarise + staple bootstrapper DMG`` step — slice ε.1 is missing entirely.")
            return
        }
        var stepEndIdx = lines.count
        for i in (notariseNameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[notariseNameIdx..<stepEndIdx].joined(separator: "\n")
        #expect(
            stepBlock.contains("continue-on-error: true"),
            "release.yml's ``Notarise + staple bootstrapper DMG`` step must carry ``continue-on-error: true`` so an Apple Notary outage / 403 / agreement re-sign cannot block the canonical release. This is the load-bearing invariant of slice ε.1."
        )
    }

    @Test("release.yml mirrors bootstrapper DMG to dl.rapidmlx.com R2 (slice ε.1 — versioned + alias keys)")
    func releaseYamlMirrorsBootstrapperDmgToR2() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.1 (.claude/loop/bootstrapper-plan.md) publishes the
        // slim DMG to two R2 keys, mirroring the canonical-DMG
        // versioned + unversioned-alias pattern (#1 + #2 in the R2
        // mirror block's docstring): rapid-mlx-desktop-bootstrapper-
        // ${VERSION}.dmg and rapid-mlx-desktop-bootstrapper.dmg. The
        // versioned key is the slice ε.2 flip target; the alias is
        // for symmetry with the canonical-DMG download CTA pattern.
        // Both must be ``--remote`` so wrangler talks to the live
        // bucket (not the local simulator).
        #expect(
            body.contains("rapid-desktop-dist/${SLIM_VERSIONED_KEY}"),
            "release.yml must publish the slim DMG under ``rapid-desktop-dist/${SLIM_VERSIONED_KEY}`` (versioned, immutable per-tag). This is the key slice ε.2 will flip ``latest.json.dmg_url`` to."
        )
        #expect(
            body.contains("rapid-desktop-dist/${SLIM_ALIAS_KEY}"),
            "release.yml must publish the slim DMG under ``rapid-desktop-dist/${SLIM_ALIAS_KEY}`` (unversioned alias, never goes stale across tags). Matches the canonical DMG's #1+#2 pattern for symmetry."
        )
        #expect(
            body.contains("SLIM_VERSIONED_KEY=\"rapid-mlx-desktop-bootstrapper-${VERSION}.dmg\""),
            "release.yml's SLIM_VERSIONED_KEY must be ``rapid-mlx-desktop-bootstrapper-${VERSION}.dmg`` — pin the canonical naming so slice ε.2's dmg_url flip lands on a known key."
        )
        #expect(
            body.contains("SLIM_ALIAS_KEY=\"rapid-mlx-desktop-bootstrapper.dmg\""),
            "release.yml's SLIM_ALIAS_KEY must be ``rapid-mlx-desktop-bootstrapper.dmg`` — pin the unversioned alias naming for symmetry with the canonical-DMG #2 alias."
        )
    }

    @Test("release.yml gates slim-DMG R2 publish behind ``xcrun stapler validate`` (cannot publish un-stapled DMG)")
    func releaseYamlGatesSlimR2PublishOnStaplerValidate() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.1's other load-bearing invariant: an un-notarised
        // or un-stapled slim DMG MUST NEVER reach dl.rapidmlx.com.
        // Without the gate, a notarise failure (continue-on-error)
        // would silently publish a slim DMG that triggers Gatekeeper
        // on first launch. Pin the gate shape.
        let strip = Self.stripWhitespace(body)
        #expect(
            strip.contains("xcrunstaplervalidate\"$SLIM_DMG\""),
            "release.yml must gate every slim-DMG R2 put behind ``xcrun stapler validate \"$SLIM_DMG\"``. Without the gate, a notarise failure (continue-on-error) would silently publish an un-stapled DMG that triggers Gatekeeper on first launch."
        )
        // The gate must combine the file-existence probe AND the
        // stapler-validate check — both are required.
        #expect(
            body.contains("[[ -f \"$SLIM_DMG\" ]] && xcrun stapler validate \"$SLIM_DMG\""),
            "release.yml's R2 slim-DMG gate must check BOTH ``[[ -f \"$SLIM_DMG\" ]]`` AND ``xcrun stapler validate \"$SLIM_DMG\"`` in a single guard. Splitting these or relaxing to one alone re-opens the un-stapled-publish window."
        )
    }

    @Test("release.yml runs slim-DMG notarise AFTER the slim-DMG build step (cannot reorder)")
    func releaseYamlOrdersNotariseAfterBuild() throws {
        let body = try Self.loadReleaseYaml()
        // The notarise step submits the bytes produced by the
        // ``Build bootstrapper DMG`` step. A reorder that put the
        // notarise step BEFORE the build would always fail with
        // "submit-file not found" and never publish. Pin the YAML
        // ordering (= GHA execution ordering).
        guard let buildIdx = body.range(of: "name: Build bootstrapper DMG (artifact-only)") else {
            Issue.record("release.yml has no ``Build bootstrapper DMG (artifact-only)`` step — investigate before merging slice ε.1.")
            return
        }
        guard let notariseIdx = body.range(of: "name: Notarise + staple bootstrapper DMG") else {
            Issue.record("release.yml has no ``Notarise + staple bootstrapper DMG`` step — slice ε.1 is missing entirely.")
            return
        }
        #expect(
            buildIdx.lowerBound < notariseIdx.lowerBound,
            "release.yml runs the slim-DMG notarise step BEFORE the slim-DMG build step. Keep notarise strictly AFTER build so the submit-target bytes actually exist on disk."
        )
    }

    @Test("release.yml pre-publishes slim-DMG R2 mirror BEFORE canonical latest.json publish (slice ε.2 atomicity invariant)")
    func releaseYamlOrdersSlimPrepublishBeforeCanonicalLatestJson() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.2 cutover flipped the ordering: ``latest.json.dmg_url``
        // now references the slim bootstrapper DMG, so the slim DMG
        // MUST be on R2 BEFORE the canonical mirror step composes +
        // publishes latest.json. The pre-publish step has its own
        // ``timeout-minutes: 5`` + ``continue-on-error: true`` +
        // ``slim_available`` step output so a wrangler stall on the
        // slim leg cannot delay / block the canonical latest.json
        // publish (the canonical step falls back to writing dmg_url
        // for the full DMG when slim_available != 'true' — the
        // ``releaseYamlFlipsLatestJsonDmgUrlToSlimWithCanonicalFallback``
        // test pins that fallback shape).
        guard let notariseIdx = body.range(of: "name: Notarise + staple bootstrapper DMG") else {
            Issue.record("release.yml has no ``Notarise + staple bootstrapper DMG`` step — slice ε.1 is missing.")
            return
        }
        guard let canonicalMirrorIdx = body.range(of: "name: Mirror DMG + publish latest.json to dl.rapidmlx.com") else {
            Issue.record("release.yml has no ``Mirror DMG + publish latest.json to dl.rapidmlx.com`` step — the canonical R2 mirror block was renamed or removed.")
            return
        }
        guard let slimPrepublishIdx = body.range(of: "name: Pre-publish slim bootstrapper DMG to dl.rapidmlx.com (R2) (P3 slice ε.2") else {
            Issue.record("release.yml has no ``Pre-publish slim bootstrapper DMG to dl.rapidmlx.com (R2) (P3 slice ε.2`` step — slice ε.2 R2 pre-publish is missing or rewritten in an unrecognised shape.")
            return
        }
        #expect(
            notariseIdx.lowerBound < slimPrepublishIdx.lowerBound,
            "release.yml runs the slim-DMG pre-publish step BEFORE the slim-DMG notarise step. Keep it AFTER notarise so the stapler-validate gate finds a stapled ticket."
        )
        #expect(
            slimPrepublishIdx.lowerBound < canonicalMirrorIdx.lowerBound,
            "release.yml runs the slim-DMG pre-publish step AFTER the canonical ``Mirror DMG + publish latest.json`` step. Slice ε.2 requires the slim DMG to be on R2 BEFORE latest.json composes dmg_url — otherwise the manifest points at a URL that doesn't exist yet (atomicity violation, same invariant the sidecar / model legs honour). Move ``Pre-publish slim bootstrapper DMG`` strictly BEFORE ``Mirror DMG + publish latest.json``."
        )
    }

    @Test("release.yml flips latest.json.dmg_url to slim DMG with canonical fallback (P3 slice ε.2 LIVE)")
    func releaseYamlFlipsLatestJsonDmgUrlToSlimWithCanonicalFallback() throws {
        let body = try Self.loadReleaseYaml()
        // The slice ε.2 invariant: ``latest.json.dmg_url`` now points
        // at the slim bootstrapper DMG when the pre-publish step
        // succeeded (``slim_available=true``), with a canonical
        // (full) DMG fallback when it didn't. The jq composition
        // block builds dmg_url / dmg_sha256 / dmg_size from
        // ``${LATEST_DMG_KEY}`` / ``${LATEST_DMG_SHA256}`` /
        // ``${LATEST_DMG_SIZE}`` — three shell vars that the
        // canonical mirror step assigns from the pre-publish step's
        // outputs (slim when available) or the canonical-DMG locals
        // (fall-back).
        //
        // Positive: the jq invocation drives dmg_url from
        // ``${LATEST_DMG_KEY}`` (the conditional shell var).
        #expect(
            body.contains("--arg dmg_url \"https://dl.rapidmlx.com/${LATEST_DMG_KEY}\""),
            "release.yml's jq composition must feed dmg_url from ``https://dl.rapidmlx.com/${LATEST_DMG_KEY}`` — the conditional shell var the canonical mirror step assigns from either the pre-publish step's slim_versioned_key output (slice ε.2 LIVE) or the canonical-DMG VERSIONED_KEY (fall-back). Slice ε.2 cutover requires this shape."
        )
        #expect(
            body.contains("--arg dmg_sha256 \"$LATEST_DMG_SHA256\""),
            "release.yml's jq composition must feed dmg_sha256 from ``$LATEST_DMG_SHA256`` (the conditional shell var)."
        )
        #expect(
            body.contains("--argjson dmg_size \"$LATEST_DMG_SIZE\""),
            "release.yml's jq composition must feed dmg_size from ``$LATEST_DMG_SIZE`` (the conditional shell var)."
        )
        // Positive: the conditional assignment exists — when
        // slim_available=true, LATEST_DMG_KEY is the slim versioned
        // key (the load-bearing slice ε.2 surface).
        #expect(
            body.contains("steps.slim_prepublish.outputs.slim_available") &&
            body.contains("steps.slim_prepublish.outputs.slim_versioned_key") &&
            body.contains("steps.slim_prepublish.outputs.slim_sha256") &&
            body.contains("steps.slim_prepublish.outputs.slim_size"),
            "release.yml's canonical mirror step must read all four ``steps.slim_prepublish.outputs.*`` outputs (slim_available / slim_versioned_key / slim_sha256 / slim_size) to set LATEST_DMG_* shell vars. The pre-publish step's outputs are how slice ε.2 atomically passes the slim DMG's URL / sha256 / size to the manifest."
        )
        // Positive: the fallback branch exists — when slim_available
        // != 'true', LATEST_DMG_KEY = VERSIONED_KEY (canonical DMG).
        // This is the release-pipeline-safety invariant: a slim DMG
        // build / notarise / R2 publish failure NEVER breaks the
        // canonical release.
        #expect(
            body.contains("LATEST_DMG_KEY=\"$VERSIONED_KEY\"") &&
            body.contains("LATEST_DMG_SHA256=\"$SHA256\"") &&
            body.contains("LATEST_DMG_SIZE=\"$SIZE\""),
            "release.yml's canonical mirror step must fall back to canonical DMG values (LATEST_DMG_KEY=\"$VERSIONED_KEY\" + LATEST_DMG_SHA256=\"$SHA256\" + LATEST_DMG_SIZE=\"$SIZE\") when slim_available != 'true'. Without this, a slim DMG build / notarise / R2 publish failure would either publish a broken manifest (404 dmg_url) or crash the release pipeline."
        )
        // Negative: the old canonical-only dmg_url shape MUST be
        // gone — a regression that reverted to ``${VERSIONED_KEY}``
        // would silently un-flip slice ε.2 and ship the full DMG
        // again without changing user-visible behaviour at install
        // time (just a 30× larger download). Hard-pin the new shape.
        #expect(
            !body.contains("--arg dmg_url \"https://dl.rapidmlx.com/${VERSIONED_KEY}\""),
            "release.yml's jq composition is feeding dmg_url from ${VERSIONED_KEY} directly — this un-flips slice ε.2 and silently reverts to shipping the full DMG. Use ``${LATEST_DMG_KEY}`` (the conditional shell var) so the slim DMG ships when available + the full DMG falls back when it isn't."
        )
    }

    @Test("canonical mirror step's ``run:`` block contains NO ``${{ }}`` interpolations (v0.8.9-release-fail forensic)")
    func canonicalMirrorRunBlockHasNoExpressionInterpolations() throws {
        let body = try Self.loadReleaseYaml()
        // v0.8.9 release-fail forensic: the inline form
        // ``if [[ "${{ steps.slim_prepublish.outputs.slim_available }}" == "true" ]]``
        // inside the canonical mirror step's ~25 KB run: block
        // tripped GHA's per-expression-template 21,000-char cap —
        // GHA treats any ``run:`` script that contains ``${{ }}``
        // as a single template expression and applies the cap to
        // the whole block. The release.yml workflow was rejected
        // at parse time with HTTP 422 "Exceeded max expression
        // length 21000" before any job started, and the v0.8.9
        // tag had to be retracted. The fix is to pass step outputs
        // via the step's ``env:`` block (which evaluates one
        // expression per env entry, independently of the run-block
        // cap) and read them as plain shell vars (``$SLIM_AVAILABLE``
        // etc.) inside bash. This test pins the no-``${{ }}``
        // invariant so a future refactor that re-inlines the
        // expressions cannot ship without tripping a local test.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let nameIdx = lines.firstIndex(where: {
            $0.contains("name: Mirror DMG + publish latest.json to dl.rapidmlx.com")
        }) else {
            Issue.record("release.yml has no canonical ``Mirror DMG + publish latest.json`` step.")
            return
        }
        // Find the step's run: block by locating the first ``run: |``
        // line at-or-after the name and reading until the next
        // step-level ``- name:`` (or end-of-file).
        guard let runIdx = (nameIdx..<lines.count).first(where: {
            lines[$0].contains("run: |") || lines[$0].contains("run:|")
        }) else {
            Issue.record("release.yml's canonical mirror step has no ``run:`` block — it must be a script step.")
            return
        }
        var endIdx = lines.count
        for i in (runIdx + 1)..<lines.count where lines[i].contains("- name:") {
            endIdx = i
            break
        }
        let runBlock = lines[(runIdx + 1)..<endIdx].joined(separator: "\n")
        #expect(
            !runBlock.contains("${{"),
            "release.yml's canonical mirror step's run: block contains a ``${{ }}`` interpolation. GHA treats any run: block with ``${{ }}`` as a single template expression and applies its 21,000-char per-expression cap to the whole block — this step's body is ~25 KB, so any inline expression trips workflow-parse at \"Exceeded max expression length 21000\" (v0.8.9 release-fail). Pass step outputs via the step's ``env:`` block (one expression per env entry, independently capped) and read as plain shell vars inside bash."
        )
        // Positive: the env: block must declare the four SLIM_*
        // env vars that the bash script reads. Pin the names so a
        // future env-var rename leaves both surfaces in lockstep.
        // The env: declarations themselves carry the ``${{ }}``
        // interpolations — that's the load-bearing form.
        let stepBody = lines[nameIdx..<endIdx].joined(separator: "\n")
        #expect(
            stepBody.contains("SLIM_AVAILABLE: ${{ steps.slim_prepublish.outputs.slim_available }}") &&
            stepBody.contains("SLIM_VERSIONED_KEY_FROM_PREP: ${{ steps.slim_prepublish.outputs.slim_versioned_key }}") &&
            stepBody.contains("SLIM_SHA256_FROM_PREP: ${{ steps.slim_prepublish.outputs.slim_sha256 }}") &&
            stepBody.contains("SLIM_SIZE_FROM_PREP: ${{ steps.slim_prepublish.outputs.slim_size }}"),
            "release.yml's canonical mirror step must declare four SLIM_* env vars (SLIM_AVAILABLE / SLIM_VERSIONED_KEY_FROM_PREP / SLIM_SHA256_FROM_PREP / SLIM_SIZE_FROM_PREP) each interpolating from the matching steps.slim_prepublish.outputs.* output. Without these, the bash script reads empty strings and the conditional defaults to the fallback (full DMG) branch every release — silently un-flipping slice ε.2."
        )
    }
}
