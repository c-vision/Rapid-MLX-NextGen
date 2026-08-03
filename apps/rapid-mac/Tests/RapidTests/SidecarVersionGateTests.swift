import Foundation
import Testing

/// Pin the four-layer SemVer regex gate that prevents a non-dotted-
/// digit ``sidecar_version`` from reaching ``latest.json`` and bricking
/// every slim-DMG install. Background: v0.8.6 shipped
/// ``sidecar_version: "26ac5b4"`` (a 7-character git short SHA)
/// because (a) ``actions/checkout``'s submodule pull doesn't bring
/// tags, (b) ``git describe --tags --always`` in ``scripts/build.sh``
/// silently fell back to ``--always`` and produced the SHA, (c) the
/// SHA propagated through ``scripts/build-sidecar-tarball.sh`` into the
/// manifest unchecked, and (d) ``release.yml`` only screened the
/// ``(unknown)`` sentinel. The bootstrapper's defensive validator at
/// ``BootstrapCoordinator.swift``'s ``isValidVersionString`` correctly
/// rejected the value but only at install-time on every user's Mac —
/// 100% of slim-DMG installs hit the unrecoverable "Setup didn't
/// finish" splash. See issue #411 for the dogfood transcript.
///
/// The defence is four layers (all four below):
///   1. release.yml fetches submodule tags so derivation can succeed
///   2. scripts/build.sh prefers ``git tag --points-at HEAD`` and
///      hard-fails if neither tag nor describe yields SemVer
///   3. scripts/build-sidecar-tarball.sh refuses to emit a manifest
///      with a non-SemVer ``sidecar_version`` (floor under upstream)
///   4. release.yml regex-gates the value before AND after publish to
///      ``latest.json`` (fail-on-mismatch, not warn-on-mismatch)
///
/// These tests pin the SHAPE of each layer so a future maintainer
/// can't quietly delete any one of them. The bug class is too
/// expensive (100% slim-DMG install failure rate; only caught by
/// release-day dogfood) to rely on a single point of defence.
@Suite("Sidecar version SemVer gate (#411) — four-layer regression pins")
struct SidecarVersionGateTests {

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var buildScriptPath: URL {
        sourceRoot.appendingPathComponent("scripts").appendingPathComponent("build.sh")
    }

    private static var tarballScriptPath: URL {
        sourceRoot.appendingPathComponent("scripts").appendingPathComponent("build-sidecar-tarball.sh")
    }

    private static var releaseYamlPath: URL {
        sourceRoot
            .appendingPathComponent(".github")
            .appendingPathComponent("workflows")
            .appendingPathComponent("release.yml")
    }

    private static func load(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - layer 1: release.yml fetches submodule tags

    @Test("release.yml explicitly fetches submodule tags after checkout (#411 layer 1)")
    func releaseYamlFetchesSubmoduleTags() throws {
        let yaml = try Self.load(Self.releaseYamlPath)
        #expect(
            yaml.contains("Fetch submodule tags"),
            "release.yml must contain a step that fetches third_party/rapid-mlx tags after actions/checkout. Without it, scripts/build.sh's git-tag-based version derivation finds nothing and falls back to a short SHA — which bricks slim-DMG installs (#411)."
        )
        #expect(
            yaml.contains("git -C third_party/rapid-mlx fetch --tags"),
            "release.yml must invoke ``git -C third_party/rapid-mlx fetch --tags`` to populate the submodule's tag list (#411). actions/checkout's submodule pull only fetches the pinned SHA, not refs/tags."
        )
    }

    // MARK: - layer 2: scripts/build.sh derives SemVer from git tags

    @Test("scripts/build.sh prefers git tag --points-at HEAD for SemVer derivation (#411 layer 2)")
    func buildScriptPrefersTagPointsAt() throws {
        let body = try Self.load(Self.buildScriptPath)
        #expect(
            body.contains("git tag --points-at HEAD"),
            "scripts/build.sh must use ``git tag --points-at HEAD`` to find an exact tag on the submodule's HEAD commit. ``git describe`` walks past lightweight tags (rapid-mlx's v0.8.15/16/18 are lightweight); ``--points-at`` returns them directly (#411)."
        )
        #expect(
            body.contains("--list 'v[0-9]*'"),
            "scripts/build.sh's tag query must filter on ``v[0-9]*`` so non-release tags (e.g. ``staging-*`` / ``rc-*``) can't pollute the SemVer derivation (#411)."
        )
    }

    @Test("scripts/build.sh hard-fails if no SemVer-shaped version can be derived (#411 layer 2)")
    func buildScriptHardFailsOnNonSemVer() throws {
        let body = try Self.load(Self.buildScriptPath)
        // Codex #412 r1 BLOCKING: the regex MUST stay strictly
        // dotted-digit (no ``[-+][0-9A-Za-z.-]+`` suffix) to match
        // BootstrapCoordinator.isValidVersionString exactly. Assert
        // the FULL pinned regex literal — accepting a looser variant
        // here would re-create #411 for a value like ``0.8.19-rc.1``.
        #expect(
            body.contains("^[0-9]+(\\.[0-9]+)+$"),
            "scripts/build.sh must validate against the strict dotted-digit regex ``^[0-9]+(\\.[0-9]+)+$`` (no pre-release / build suffix). Loosening to accept ``-rc.1`` etc. re-creates the #411 bricking bug because the Swift validator does NOT accept suffixes (codex r1 BLOCKING)."
        )
        #expect(
            body.contains("Could not derive a SemVer-shaped sidecar version"),
            "scripts/build.sh must emit a discoverable error message when the derivation fails. ``::error::`` prefix lets the GitHub Actions log surface it as a release-blocker (#411)."
        )
    }

    @Test("scripts/build.sh's bash regex empirically accepts dotted-digit + rejects SHA / pre-release (#411 layer 2 — empirical)")
    func buildScriptRegexEmpiricalBehaviour() throws {
        // Codex #412 r2 MINOR: source-substring assertions catch
        // accidental deletions but not subtle regex breakage (e.g. a
        // future edit that over-escapes the dot, or accidentally
        // anchors only one end). Empirically verify the regex against
        // known good and known bad inputs by extracting it from the
        // file and executing the same ``[[ =~ ]]`` check the script
        // uses. This catches a regex regression on the PR rather than
        // at release time.
        let body = try Self.load(Self.buildScriptPath)
        // Pull the regex literal from the SIDECAR_SEMVER_RE='…'
        // assignment. Pinning the assignment SHAPE keeps the test
        // robust against unrelated edits to the surrounding script.
        guard let assignRange = body.range(of: "SIDECAR_SEMVER_RE='"),
              let endQuoteRange = body.range(of: "'", range: assignRange.upperBound..<body.endIndex) else {
            Issue.record("Could not locate ``SIDECAR_SEMVER_RE='…'`` assignment in scripts/build.sh; the test extractor needs updating (#411).")
            return
        }
        let regex = String(body[assignRange.upperBound..<endQuoteRange.lowerBound])
        for (input, shouldMatch) in [
            ("0.8.18", true),         // canonical sidecar release
            ("1.2.3", true),          // generic semver
            ("0.8", true),            // two-segment also acceptable to validator
            ("26ac5b4", false),       // the v0.8.6 bug
            ("0.8.19-rc.1", false),   // codex r1 BLOCKING — must reject
            ("0.8.18+build.7", false),// build suffix — must reject
            ("v0.8.18", false),       // leading ``v`` not allowed at this layer (bootstrapper strips it ITSELF; we hand off the bare form)
            ("0.8.", false),          // trailing dot
            (".8.18", false),         // leading dot
            ("", false),              // empty
            ("0.8.18\n", false),      // trailing newline (defends against caller forgetting to ``tr -d``)
        ] {
            let bash = "/bin/bash"
            let script = "re=\(Self.shellSingleQuote(regex)); if [[ \"$1\" =~ $re ]]; then exit 0; else exit 1; fi"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bash)
            proc.arguments = ["-c", script, "_test", input]
            try proc.run()
            proc.waitUntilExit()
            let matched = proc.terminationStatus == 0
            #expect(
                matched == shouldMatch,
                "scripts/build.sh's SIDECAR_SEMVER_RE='\(regex)' should \(shouldMatch ? "MATCH" : "REJECT") '\(input)' but bash =~ returned exit=\(proc.terminationStatus). Empirical regression of the regex behaviour (#411 layer 2)."
            )
        }
    }

    /// Wrap ``s`` in bash single quotes so any embedded ``'`` is safe.
    /// Bash single-quoted strings cannot contain ``'``; the standard
    /// trick is to close, insert an escaped ``\\'``, and re-open.
    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - layer 3: scripts/build-sidecar-tarball.sh defensive gate

    @Test("scripts/build-sidecar-tarball.sh refuses to emit a non-SemVer sidecar_version (#411 layer 3)")
    func tarballScriptHasDefenseInDepth() throws {
        let body = try Self.load(Self.tarballScriptPath)
        #expect(
            body.contains("^[0-9]+(\\.[0-9]+)+$"),
            "scripts/build-sidecar-tarball.sh must SemVer-regex-gate ``$SIDECAR_VERSION`` against the strict dotted-digit form ``^[0-9]+(\\.[0-9]+)+$`` (no pre-release suffix). Codex #412 r1 BLOCKING: a looser suffix regex would accept ``0.8.19-rc.1`` here while the bootstrapper validator rejects it at runtime — re-creating #411."
        )
        #expect(
            body.contains("Bootstrapper validator (BootstrapCoordinator.isValidVersionString) would reject"),
            "scripts/build-sidecar-tarball.sh's regex-gate error message must name the specific Swift function (``BootstrapCoordinator.isValidVersionString``) so a future maintainer reading the CI log can grep straight to the validator and confirm the two regexes are in lockstep (#411)."
        )
    }

    // MARK: - layer 4: release.yml gates both compose-time and post-publish

    @Test("release.yml SemVer-gates sidecar_version at latest.json compose-time (#411 layer 4a)")
    func releaseYamlGatesAtComposeTime() throws {
        let yaml = try Self.load(Self.releaseYamlPath)
        // Codex #412 r1 MINOR: the compose-time gate (4a) and the
        // post-publish gate (4b) share the same SemVer regex string,
        // so a substring search alone cannot distinguish them — a
        // deletion of 4a would pass any assertion that "the regex
        // appears". Pin BOTH the layer-4a-specific error message AND
        // the count of regex occurrences (must be at least 2: one per
        // layer; if a future refactor extracts the regex into a
        // shared bash function, update this assertion explicitly).
        #expect(
            yaml.contains("Issue #411 layer 4a"),
            "release.yml must keep an explicit ``Issue #411 layer 4a`` marker comment alongside the compose-time gate so a future maintainer searching for the layer-4a defence finds it. Without the marker, codex r1's BLOCKING regression (a non-SemVer value reaching latest.json) cannot be caught by code review."
        )
        #expect(
            yaml.contains("Fix scripts/build.sh tag derivation"),
            "release.yml's compose-time gate must surface a specific remediation hint (``Fix scripts/build.sh tag derivation``) in its error message so an operator triaging a failed release step is pointed at the right file. Generic ``not SemVer'' alone forces the operator to re-read this file to find the root cause."
        )
        let regexOccurrences = yaml.components(separatedBy: "v?[0-9]+(\\.[0-9]+)+").count - 1
        #expect(
            regexOccurrences >= 2,
            "release.yml must contain the SemVer regex at LEAST twice (compose-time gate 4a + post-publish gate 4b). Found \(regexOccurrences). If you refactored the regex into a shared bash function, that's fine but update this test to assert the function call count instead (#411)."
        )
    }

    @Test("release.yml SemVer-gates sidecar_version POST-PUBLISH against R2 origin, not CDN (#411 layer 4b)")
    func releaseYamlGatesPostPublishViaR2() throws {
        let yaml = try Self.load(Self.releaseYamlPath)
        // Codex #412 r1 MAJOR: the original draft curled
        // dl.rapidmlx.com/latest.json after a 5-second sleep, but the
        // CDN has a 300-second ``max-age`` and can legitimately serve
        // the previous release's manifest for up to 5 minutes after a
        // fresh PUT. That would fail a GOOD release. The authoritative
        // check must go to the R2 origin via ``wrangler r2 object
        // get``, which reflects the post-PUT state with no propagation
        // lag. The CDN curl is kept as warning-only for visibility.
        #expect(
            yaml.contains("wrangler@4 r2 object get") && yaml.contains("rapid-desktop-dist/latest.json"),
            "release.yml's post-publish authoritative check must use ``wrangler r2 object get rapid-desktop-dist/latest.json`` (R2 origin), NOT a curl against the CDN URL. The CDN has a 300s cache TTL and would false-fail a good release for up to 5 minutes after PUT (codex #412 r1 MAJOR)."
        )
        #expect(
            yaml.contains("R2 origin object rapid-desktop-dist/latest.json"),
            "release.yml's post-publish hard-fail error message must reference ``R2 origin`` explicitly so an operator triaging the failure knows whether the bytes-on-R2 are bad (real problem) vs CDN-cache-stale (no action needed). Generic ``not SemVer'' loses this distinction (#411)."
        )
        #expect(
            yaml.contains("100% of slim-DMG installs will fail"),
            "release.yml's post-publish error must spell out the consequence (100% slim-DMG install failure) so the on-call operator understands urgency. Don't soften to a warning at this layer — bytes-on-R2 wrong = every install brick (#411)."
        )
        #expect(
            yaml.contains("CDN may serve stale for up to 5 min"),
            "release.yml's post-publish notice must document the R2-vs-CDN distinction so a future maintainer reading the workflow output understands why the authoritative check went to R2 instead of the user-visible URL (#411)."
        )
        #expect(
            yaml.contains("::warning::CDN edge served"),
            "release.yml must keep a CDN curl as WARNING-only for visibility into edge warm-up. A future maintainer reading the release log needs to know whether the user-visible URL is fresh — but NEVER fail the release on it (codex r1 MAJOR)."
        )
    }
}
