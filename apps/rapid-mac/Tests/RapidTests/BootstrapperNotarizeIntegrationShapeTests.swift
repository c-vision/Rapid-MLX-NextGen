import Foundation
import Testing

/// Pin the shape of the slice ε.1 release.yml additions (slim DMG
/// notarise + R2 publish + GH Release preview-asset attach) AND of
/// the ``scripts/notarize.sh`` interface they depend on. Slice ε.1
/// is DORMANT: ``latest.json.dmg_url`` STILL points at the canonical
/// (full) DMG. The slim asset is published-and-discoverable on R2
/// and on the GH Release, but the in-app UpdateChecker on v0.8.x is
/// unaffected. Slice ε.2 is the 1-line PR that flips ``dmg_url``;
/// these tests are the structural moat that keeps ε.1 dormant +
/// keeps ε.2 a 1-line flip.
///
/// Pattern mirrors ``BootstrapperDMGShapeTests``:
///   - Locate source files via ``#filePath`` walk so the test runs
///     under ``swift test``, Xcode, and CI.
///   - Read each file as UTF-8.
///   - Assert canonical substrings / structural invariants.
///
/// The asserts pin SHAPE, not byte-for-byte text — reformatting
/// comments / whitespace should not trip these tests. What is pinned
/// is what we care about: continue-on-error guards (so notarise
/// failures cannot block the canonical release), stapler-validate
/// gates (so an un-stapled DMG never reaches dl.rapidmlx.com or the
/// GH Release), the additive GH Release upload, and the explicit
/// dormancy invariant on latest.json composition.
@Suite("Bootstrapper notarize integration slice ε.1 — release.yml + notarize.sh shape")
struct BootstrapperNotarizeIntegrationShapeTests {

    /// Repository root, derived from ``#filePath`` so the test runs
    /// from any cwd.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static var notarizeScriptPath: URL {
        sourceRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("notarize.sh")
    }

    private static var releaseYamlPath: URL {
        sourceRoot
            .appendingPathComponent(".github")
            .appendingPathComponent("workflows")
            .appendingPathComponent("release.yml")
    }

    private static func loadNotarizeScript() throws -> String {
        try String(contentsOf: notarizeScriptPath, encoding: .utf8)
    }

    private static func loadReleaseYaml() throws -> String {
        try String(contentsOf: releaseYamlPath, encoding: .utf8)
    }

    /// Strip whitespace from every character so substring matches
    /// survive reformatting. Mirrors the helper in
    /// ``BootstrapperDMGShapeTests`` / ``SidecarShimHardeningTests``.
    private static func stripWhitespace(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    /// Extract the *actual* ``if:`` clause from the given step's
    /// block. Returns the substring after ``if:`` (trimmed of
    /// leading/trailing whitespace) so callers can assert against
    /// the real conditional rather than relying on substring
    /// matches across the whole step (which would match comments
    /// and pass when the actual ``if:`` line is wrong — codex r4
    /// NIT). Returns nil if the step has no ``if:`` line (which is
    /// itself a regression for steps that REQUIRE one — callers
    /// should fail the test loudly).
    private static func extractIfClause(stepBlock: String) -> String? {
        // Walk lines, pick the first one whose trimmed form starts
        // with ``if:``. GHA permits a single ``if:`` per step.
        for line in stepBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("if:") {
                let after = String(trimmed.dropFirst("if:".count))
                return after.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - notarize.sh interface (parametrized, accepts arbitrary DMG)

    @Test("notarize.sh accepts <submit-file> <staple-target> argv pair (slice ε.1 reuses without refactor)")
    func notarizeScriptAcceptsArbitraryDmgArgs() throws {
        let body = try Self.loadNotarizeScript()
        // The script's documented signature is ``notarize.sh
        // <submit-file> <staple-target>``. Slice ε.1's release.yml
        // step relies on this — a regression that hardcodes the
        // canonical DMG path would break the slim-DMG submission
        // silently (the slim invocation would notarise the canonical
        // DMG twice and skip the slim entirely). Pin the parametric
        // argv assignment.
        #expect(
            body.contains("SUBMIT_FILE=\"${1:?usage: notarize.sh <submit-file> <staple-target>}\""),
            "scripts/notarize.sh must accept SUBMIT_FILE as ``${1:?...}`` (positional argv). Slice ε.1 calls this twice (once for the canonical DMG, once for the slim DMG) so any hardcoded path here regresses both call sites."
        )
        #expect(
            body.contains("STAPLE_TARGET=\"${2:?usage: notarize.sh <submit-file> <staple-target>}\""),
            "scripts/notarize.sh must accept STAPLE_TARGET as ``${2:?...}`` (positional argv). Required for slice ε.1's slim-DMG call (which passes the slim DMG as both submit AND staple targets)."
        )
    }

    @Test("notarize.sh skips cleanly when AC_API_* are unset (local-dev + fork-dry-run path)")
    func notarizeScriptSkipsWhenCredsMissing() throws {
        let body = try Self.loadNotarizeScript()
        // The canonical-DMG step relies on this skip path so a local
        // ``build.sh && dmg.sh`` flow without Apple creds still
        // succeeds. Slice ε.1's release.yml step inherits the same
        // expectation — a regression that started exiting non-zero
        // here would tank fork dry-runs even with continue-on-error
        // (the step would log a confusing failure rather than the
        // clean ``skipping notarisation`` notice).
        #expect(
            body.contains("AC_API_* not set — skipping notarisation"),
            "scripts/notarize.sh must skip cleanly (exit 0 with a notice) when AC_API_KEY_ID / AC_API_ISSUER_ID / AC_API_KEY_PATH are unset. Slice ε.1 relies on this for fork-dry-run + local-dev paths."
        )
    }

    // MARK: - release.yml: slim DMG notarise step

    @Test("release.yml has the slim-DMG notarise step (positioned after slim-DMG build, before R2 mirror)")
    func releaseYamlHasNotariseStep() throws {
        let body = try Self.loadReleaseYaml()
        #expect(
            body.contains("name: Notarise + staple bootstrapper DMG (P3 slice ε.1 — dormant)"),
            "release.yml is missing the ``Notarise + staple bootstrapper DMG (P3 slice ε.1 — dormant)`` step. This is the slice ε.1 entry point; without it the slim DMG never gets a notary ticket and the R2 mirror's stapler-validate gate silently skips publication on every release."
        )
        // The step submits the exact slim-DMG path the slice-α
        // build step writes to. notarize.sh's <submit> = <staple>
        // pair for a .dmg per its header.
        #expect(
            body.contains("SLIM_DMG=\"build/rapid-mlx-desktop-bootstrapper.dmg\""),
            "release.yml's slice ε.1 step must reference the slim DMG path ``build/rapid-mlx-desktop-bootstrapper.dmg`` (the path slice α's build script writes to — renamed to lowercase-hyphenated in v0.8.11 PR #428). Any drift here uncouples the build + notarise pair."
        )
        #expect(
            body.contains("bash scripts/notarize.sh \"$SLIM_DMG\" \"$SLIM_DMG\""),
            "release.yml's slice ε.1 step must invoke ``bash scripts/notarize.sh \"$SLIM_DMG\" \"$SLIM_DMG\"`` (submit = staple for a .dmg per notarize.sh's header)."
        )
    }

    @Test("slim-DMG notarise step has if: !cancelled() so missing-bytes guard runs even if upstream failed (codex r3 MINOR)")
    func notariseStepRunsEvenAfterUpstreamFailure() throws {
        let body = try Self.loadReleaseYaml()
        // The slice-α build step is continue-on-error: true; on a
        // failure GHA marks the step "failed" but the workflow
        // stays green. Without an explicit status function here,
        // the notarise step would be SKIPPED on an upstream
        // failure (implicit ``success()``) rather than running the
        // explicit "no bytes — clean skip" branch.
        // codex r3 MINOR: prefer ``!cancelled()`` over ``always()``
        // so a user-cancelled workflow run skips the Apple Notary
        // submission (we don't want notary credits burned on
        // cancelled runs, and an in-flight notarytool submission
        // would otherwise outlast the workflow's SIGTERM).
        let lines = body.split(separator: "\n").map { String($0) }
        guard let nameIdx = lines.firstIndex(where: {
            $0.contains("name: Notarise + staple bootstrapper DMG")
        }) else {
            Issue.record("release.yml has no slice ε.1 notarise step — see the releaseYamlHasNotariseStep test for the canonical fix.")
            return
        }
        var stepEndIdx = lines.count
        for i in (nameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[nameIdx..<stepEndIdx].joined(separator: "\n")
        // codex r4 NIT: assert against the ACTUAL ``if:`` line, not
        // a substring search of the whole step block. A comment in
        // the block could otherwise satisfy ``contains("!cancelled()")``
        // even if the real ``if:`` line was wrong.
        guard let ifClause = Self.extractIfClause(stepBlock: stepBlock) else {
            Issue.record("release.yml's slice ε.1 notarise step has no ``if:`` clause — it must carry ``if: ${{ !cancelled() }}`` so it runs after upstream failures while still cleanly skipping on user-cancel.")
            return
        }
        #expect(
            ifClause.contains("!cancelled()"),
            "release.yml's slice ε.1 notarise step's ``if:`` clause is ``\(ifClause)`` — must contain ``!cancelled()`` so it runs even when the upstream slice-α build step (continue-on-error) was marked failed, AND so a user-cancelled workflow run cleanly skips the Apple Notary submission. ``always()`` would burn notary credits on cancellation (codex r3 MINOR)."
        )
        // Negative: neither ``always()`` nor ``success()`` (the
        // default) may appear in the if-clause. ``always()`` was
        // the r3 MINOR root cause; ``success()`` would silently
        // skip the step on any upstream failure (defeating the
        // purpose of the explicit gate).
        #expect(
            !ifClause.contains("always()") && !ifClause.contains("success()"),
            "release.yml's slice ε.1 notarise step's ``if:`` clause is ``\(ifClause)`` — must not contain ``always()`` (codex r3 MINOR — burns notary credits on cancellation) nor ``success()`` (defeats the explicit upstream-failure-tolerance gate). Use ``if: ${{ !cancelled() }}``."
        )
        #expect(
            stepBlock.contains("continue-on-error: true"),
            "release.yml's slice ε.1 notarise step must carry ``continue-on-error: true``. Apple Notary 403 / agreement re-sign / transient backoff must NEVER tank the canonical release path."
        )
    }

    @Test("slim-DMG notarise step surfaces outcome via $GITHUB_STEP_SUMMARY (visible in workflow UI)")
    func notariseStepWritesGithubStepSummary() throws {
        let body = try Self.loadReleaseYaml()
        // continue-on-error makes the step invisible in the
        // workflow's pass/fail badge. Without an explicit
        // $GITHUB_STEP_SUMMARY line, an operator debugging "why
        // isn't the slim DMG on R2?" has to scroll the entire
        // workflow log to find the reason. Pin that the step writes
        // a summary line for at least one of the outcomes.
        let lines = body.split(separator: "\n").map { String($0) }
        guard let nameIdx = lines.firstIndex(where: {
            $0.contains("name: Notarise + staple bootstrapper DMG")
        }) else {
            Issue.record("release.yml has no slice ε.1 notarise step.")
            return
        }
        var stepEndIdx = lines.count
        for i in (nameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[nameIdx..<stepEndIdx].joined(separator: "\n")
        #expect(
            stepBlock.contains("$GITHUB_STEP_SUMMARY"),
            "release.yml's slice ε.1 notarise step must write to ``$GITHUB_STEP_SUMMARY`` so success / skip / fail outcomes are visible in the workflow UI without scrolling the log. continue-on-error makes the step's exit code invisible otherwise."
        )
        // Pin all three outcome strings so a regression that drops
        // one branch's summary write (e.g. only the success branch
        // logs) trips here.
        #expect(
            stepBlock.contains("bootstrapper_notarize_outcome=skipped-missing") &&
            stepBlock.contains("bootstrapper_notarize_outcome=skipped-no-creds") &&
            stepBlock.contains("bootstrapper_notarize_outcome=success") &&
            stepBlock.contains("bootstrapper_notarize_outcome=failed"),
            "release.yml's slice ε.1 notarise step must emit all four outcome values (skipped-missing / skipped-no-creds / success / failed) to GITHUB_OUTPUT. Dropping a branch's outcome line hides the skip reason from anyone debugging \"why isn't there a slim DMG on R2?\"."
        )
    }

    // MARK: - release.yml: GH Release preview-asset attach

    @Test("release.yml attaches slim DMG as a GH Release preview asset (additive, slice ε.1)")
    func releaseYamlAttachesSlimDmgToGitHubRelease() throws {
        let body = try Self.loadReleaseYaml()
        #expect(
            body.contains("name: Attach bootstrapper DMG to GitHub Release"),
            "release.yml is missing the slice ε.1 ``Attach bootstrapper DMG to GitHub Release`` step. The slim DMG should be a GH Release preview asset (additive to the canonical-DMG asset uploaded by the earlier ``Attach to GitHub Release`` step) so reviewers + future-you can grab it before slice ε.2's dmg_url flip."
        )
        // Pin the additive nature: the canonical-DMG asset upload
        // is upstream and intact; this step adds the slim DMG
        // alongside it. The canonical step uses ``gh release upload
        // ... build/rapid-mlx-desktop.dmg`` — slice ε.1's slim step
        // uses a renamed temp copy to give the slim asset a
        // distinct, descriptive name in the GH Release UI.
        #expect(
            body.contains("SLIM_DMG_VERSIONED=\"build/rapid-mlx-desktop-bootstrapper-${VERSION}.dmg\""),
            "release.yml's slice ε.1 GH Release attach must rename the slim DMG to ``build/rapid-mlx-desktop-bootstrapper-${VERSION}.dmg`` so the GH Release asset list visibly distinguishes \"preview bootstrapper\" from the canonical DMG. Matches the R2 versioned-key naming for cross-checking sha256."
        )
        #expect(
            body.contains("gh release upload \"$TAG\" \"$SLIM_DMG_VERSIONED\" --clobber"),
            "release.yml's slice ε.1 GH Release attach must invoke ``gh release upload \"$TAG\" \"$SLIM_DMG_VERSIONED\" --clobber`` so a workflow re-run on the same tag overwrites a stale slim asset."
        )
    }

    @Test("GH Release attach is gated on tag-push AND stapler validate (no un-stapled preview asset)")
    func releaseYamlGhAttachGatedOnTagAndStaplerValidate() throws {
        let body = try Self.loadReleaseYaml()
        let lines = body.split(separator: "\n").map { String($0) }
        guard let nameIdx = lines.firstIndex(where: {
            $0.contains("name: Attach bootstrapper DMG to GitHub Release")
        }) else {
            Issue.record("release.yml has no slice ε.1 GH Release attach step.")
            return
        }
        var stepEndIdx = lines.count
        for i in (nameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[nameIdx..<stepEndIdx].joined(separator: "\n")
        // codex r4 NIT: assert against the ACTUAL ``if:`` line so
        // a comment that mentions the conditional token doesn't
        // satisfy the test while the real ``if:`` is wrong.
        guard let ifClause = Self.extractIfClause(stepBlock: stepBlock) else {
            Issue.record("release.yml's slice ε.1 GH Release attach step has no ``if:`` clause — it must carry ``if: startsWith(github.ref, 'refs/tags/') && !cancelled()`` so it's tag-gated AND cleanly skips on user-cancel.")
            return
        }
        // Tag-push gate: the canonical-DMG attach is also
        // tag-gated; the slim DMG follows the same rule so PR
        // dry-runs don't attempt to upload to a non-existent
        // release.
        #expect(
            ifClause.contains("startsWith(github.ref, 'refs/tags/')"),
            "release.yml's slice ε.1 GH Release attach step's ``if:`` clause is ``\(ifClause)`` — must contain ``startsWith(github.ref, 'refs/tags/')`` so PR dry-runs don't try to upload to a release that doesn't exist."
        )
        // Stapler-validate gate: same invariant as the R2 mirror —
        // never publish an un-stapled DMG. (The stapler-validate
        // check lives inside the step's run-block, not the if-line.)
        #expect(
            stepBlock.contains("xcrun stapler validate \"$SLIM_DMG_SRC\""),
            "release.yml's slice ε.1 GH Release attach must gate the upload behind ``xcrun stapler validate \"$SLIM_DMG_SRC\"``. Without this, a notarise failure (continue-on-error) silently uploads an un-stapled DMG to the GH Release."
        )
        // continue-on-error: a transient GH upload hiccup must not
        // tank the canonical release.
        #expect(
            stepBlock.contains("continue-on-error: true"),
            "release.yml's slice ε.1 GH Release attach must carry ``continue-on-error: true``. A transient GH upload hiccup on the slim DMG must not block the canonical release."
        )
        // codex r3 MINOR: ``!cancelled()`` (not ``always()``) so a
        // user-cancelled workflow run skips the GH Release upload.
        // Otherwise an in-flight ``gh release upload`` would
        // outlast the SIGTERM and partial-publish to GitHub.
        #expect(
            ifClause.contains("!cancelled()"),
            "release.yml's slice ε.1 GH Release attach step's ``if:`` clause is ``\(ifClause)`` — must contain ``!cancelled()`` (in combination with the tag gate) so user-cancellation cleanly skips the upload. ``always()`` would let an in-flight ``gh release upload`` outlast the workflow's SIGTERM and partial-publish to the release."
        )
        #expect(
            !ifClause.contains("always()") && !ifClause.contains("success()"),
            "release.yml's slice ε.1 GH Release attach step's ``if:`` clause is ``\(ifClause)`` — must not contain ``always()`` (codex r3 MINOR — partial-publish on cancel) nor ``success()`` (the implicit default would skip the step on any prior failure, defeating the always-attach semantic). Use ``startsWith(github.ref, 'refs/tags/') && !cancelled()``."
        )
    }

    // MARK: - slice ε.2 cutover invariants (slim DMG is load-bearing, schema unchanged)

    @Test("slice ε.2 keeps latest.json schema unchanged (dmg_url flips to slim; no new model_ or sidecar_ keys)")
    func sliceEpsilon2KeepsLatestJsonSchemaUnchanged() throws {
        let body = try Self.loadReleaseYaml()
        // Slice ε.2 cutover changes WHICH bytes dmg_url references
        // (slim bootstrapper DMG vs canonical full DMG) but does NOT
        // introduce new top-level fields. ``dmg_url`` / ``dmg_sha256``
        // / ``dmg_size`` are existing schema_version=1 fields; the
        // value change is wire-compatible with every UpdateChecker
        // version from v0.5.x onwards.
        #expect(
            body.contains("schema_version: 1"),
            "release.yml's latest.json composition must keep ``schema_version: 1``. Slice ε.2 flips an existing field's value; a schema bump would belong to a future change that adds new fields."
        )
        // The canonical jq invocation now drives dmg_url from the
        // conditional ``${LATEST_DMG_KEY}`` shell var — slim when
        // the pre-publish step succeeded, canonical otherwise.
        // ``releaseYamlFlipsLatestJsonDmgUrlToSlimWithCanonicalFallback``
        // in BootstrapperDMGShapeTests pins the conditional shape;
        // here we just pin that the dmg_url field still exists in
        // both jq invocations (positive + sidecar-only-fallback).
        #expect(
            body.contains("--arg dmg_url \"https://dl.rapidmlx.com/${LATEST_DMG_KEY}\""),
            "release.yml's jq must feed dmg_url from ``https://dl.rapidmlx.com/${LATEST_DMG_KEY}`` (the conditional shell var). Slice ε.2 flipped this from the unconditional ``${VERSIONED_KEY}`` so the slim DMG ships when available with a canonical fallback."
        )
        // Negative pin: no NEW latest.json keys leaked in alongside
        // the dmg_url value flip (e.g. bootstrapper_dmg_url,
        // slim_dmg_url, dmg_kind, etc). The cutover is value-change-
        // only; a new field would force a schema_version bump +
        // coordinated UpdateChecker release.
        #expect(
            !body.contains("bootstrapper_dmg_url:") &&
            !body.contains("slim_dmg_url:") &&
            !body.contains("--arg bootstrapper_dmg_url"),
            "release.yml's latest.json composition contains a new bootstrapper_* / slim_* key. Slice ε.2 is a VALUE flip (dmg_url's URL changes) NOT a schema change. Any new field belongs to a future schema_version bump coordinated with the desktop UpdateChecker client."
        )
    }

    @Test("R2 publish block has both versioned + alias slim-DMG puts inside the stapler-validate gate")
    func r2BlockPutsAreInsideStaplerGate() throws {
        let body = try Self.loadReleaseYaml()
        // Both ``wrangler r2 object put`` calls for the slim DMG
        // MUST be inside the ``if [[ -f ... ]] && xcrun stapler
        // validate ... ; then ... ; fi`` gate. A regression that
        // moved either put outside the gate (e.g. as an "alias is
        // best-effort, push it even on failure" rationalisation)
        // re-opens the un-stapled-publish window.
        let strip = Self.stripWhitespace(body)
        #expect(
            strip.contains("rapid-desktop-dist/${SLIM_VERSIONED_KEY}"),
            "release.yml must contain a wrangler put for ``rapid-desktop-dist/${SLIM_VERSIONED_KEY}`` (the versioned slim-DMG key)."
        )
        #expect(
            strip.contains("rapid-desktop-dist/${SLIM_ALIAS_KEY}"),
            "release.yml must contain a wrangler put for ``rapid-desktop-dist/${SLIM_ALIAS_KEY}`` (the unversioned slim-DMG alias)."
        )
        // Slice gate's then-branch by matching ``fi`` at the gate's
        // OWN indentation (the nested per-leg ``if wrangler ... ; then
        // ... else ... fi`` blocks live at a deeper indent so a naive
        // ``range(of: "else")`` would match the inner else and truncate
        // before the alias put). This works regardless of how many
        // nested wrangler invocations the gate contains in the future.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let gateOpenIdx = lines.firstIndex(where: {
            $0.contains("if [[ -f \"$SLIM_DMG\" ]] && xcrun stapler validate \"$SLIM_DMG\"")
        }) else {
            Issue.record("release.yml has no slim-DMG stapler-validate gate — slice ε.1 R2 block is missing or rewritten in an unrecognised shape.")
            return
        }
        let gateIndent = String(lines[gateOpenIdx].prefix(while: { $0 == " " }))
        let expectedFi = gateIndent + "fi"
        var gateCloseIdx: Int? = nil
        for i in (gateOpenIdx + 1)..<lines.count {
            if lines[i] == expectedFi { gateCloseIdx = i; break }
        }
        guard let closeIdx = gateCloseIdx else {
            Issue.record("release.yml's slim-DMG stapler-validate gate has no matching ``fi`` at its own indentation — gate's structural shape is broken.")
            return
        }
        let gateBlock = lines[gateOpenIdx...closeIdx].joined(separator: "\n")
        #expect(
            gateBlock.contains("rapid-desktop-dist/${SLIM_VERSIONED_KEY}"),
            "release.yml's stapler-validate gate is missing the ``rapid-desktop-dist/${SLIM_VERSIONED_KEY}`` wrangler put inside it. A versioned slim-DMG put outside the gate would publish un-stapled bytes on a notarise failure."
        )
        #expect(
            gateBlock.contains("rapid-desktop-dist/${SLIM_ALIAS_KEY}"),
            "release.yml's stapler-validate gate is missing the ``rapid-desktop-dist/${SLIM_ALIAS_KEY}`` wrangler put inside it. An alias-key put outside the gate would publish un-stapled bytes under the never-stale URL on a notarise failure."
        )
    }

    @Test("EVERY slim-DMG R2 key reference under a wrangler put line lives inside the stapler-validate gate (codex r1 MINOR + r2 NIT)")
    func everySlimWranglerPutIsGated() throws {
        // codex r1 MINOR: the gate-content test above could miss a
        // DUPLICATE wrangler put added OUTSIDE the gate (e.g. a
        // future maintainer adding a "third leg" for a Sparkle
        // appcast URL and forgetting to put it inside the gate).
        // codex r2 NIT: refine the matcher to require nearby
        // ``wrangler r2 object put`` context so harmless comments
        // / log lines that mention a slim key don't false-positive.
        //
        // Strategy: locate every line that contains a slim-DMG R2
        // key token AND check whether the line is part of a
        // ``wrangler r2 object put`` invocation (the key appears
        // on a continuation line of the wrangler call, so we look
        // at the preceding non-blank line for the wrangler marker).
        // Any such "live" wrangler put MUST sit inside the gate.
        let body = try Self.loadReleaseYaml()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        // Locate gate open. The slim block now lives in its own
        // dedicated step (codex r2 MAJOR) so we look for the gate's
        // canonical form. The gate's matching ``fi`` is at the same
        // indentation as its ``if``.
        var gateOpenLine: Int? = nil
        for (i, l) in lines.enumerated() {
            if l.contains("if [[ -f \"$SLIM_DMG\" ]] && xcrun stapler validate \"$SLIM_DMG\"") {
                gateOpenLine = i
                break
            }
        }
        guard let openIdx = gateOpenLine else {
            Issue.record("release.yml has no slim-DMG stapler-validate gate — slice ε.1 R2 block is missing or rewritten in an unrecognised shape.")
            return
        }
        let gateOpenLineText = lines[openIdx]
        let gateIndent = String(gateOpenLineText.prefix(while: { $0 == " " }))
        let expectedFi = gateIndent + "fi"
        var gateCloseLine: Int? = nil
        for i in (openIdx + 1)..<lines.count {
            if lines[i] == expectedFi {
                gateCloseLine = i
                break
            }
        }
        guard let closeIdx = gateCloseLine else {
            Issue.record("release.yml's slim-DMG stapler-validate gate has no matching ``fi`` at the gate's indentation — the gate's structural shape is broken.")
            return
        }
        // Enumerate every line that mentions a slim-DMG R2 key
        // AND looks like a live wrangler put argument. wrangler
        // puts take the key on a continuation line — we treat a
        // line as "live wrangler context" if scanning up to ~8
        // lines back finds an ``npx ... wrangler@4 r2 object put``
        // invocation with no intervening blank line or comment
        // breaking the continuation. Comments-mentioning-the-key
        // lines fall out naturally because the preceding lines
        // are themselves comments (lead with ``#``).
        let slimPutKeyPatterns = [
            "rapid-desktop-dist/${SLIM_VERSIONED_KEY}",
            "rapid-desktop-dist/${SLIM_ALIAS_KEY}",
            "rapid-desktop-dist/rapid-mlx-desktop-bootstrapper-",
            "rapid-desktop-dist/rapid-mlx-desktop-bootstrapper.dmg",
        ]
        for (i, l) in lines.enumerated() {
            // Skip comment lines outright — codex r2 NIT.
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            // Skip echo/log lines — they mention keys but aren't
            // wrangler puts.
            if trimmed.hasPrefix("echo ") { continue }
            let mentionsSlimKey = slimPutKeyPatterns.contains { l.contains($0) }
            if !mentionsSlimKey { continue }
            // Verify this looks like a live wrangler put. Two
            // shapes:
            //   (a) single-line invocation: the key appears on the
            //       SAME line as ``wrangler@4 r2 object put``.
            //       Defends against a future single-liner refactor
            //       (codex r3 NIT: the previous backscan-only
            //       matcher would have missed this).
            //   (b) multi-line continuation: the key appears on a
            //       continuation line; scan back up to 8 lines for
            //       the ``wrangler@4 r2 object put`` marker on a
            //       continuation chain (trailing-backslash lines).
            var isLiveWranglerPut = l.contains("wrangler@4 r2 object put")
            if !isLiveWranglerPut {
                let scanStart = max(0, i - 8)
                for j in stride(from: i - 1, through: scanStart, by: -1) {
                    let prev = lines[j].trimmingCharacters(in: .whitespaces)
                    if prev.contains("wrangler@4 r2 object put") {
                        isLiveWranglerPut = true
                        break
                    }
                    // Continuation lines end with backslash; once
                    // we hit a non-continuation, non-blank line
                    // that isn't the wrangler marker, give up.
                    if !prev.hasSuffix("\\") && !prev.isEmpty { break }
                }
            }
            if !isLiveWranglerPut { continue }
            #expect(
                i > openIdx && i < closeIdx,
                "release.yml line \(i + 1) (``\(trimmed)``) is the key argument to a live ``wrangler r2 object put`` call but sits OUTSIDE the stapler-validate gate at lines \(openIdx + 1)..\(closeIdx + 1). Every slim-DMG wrangler put MUST live inside the gate or the un-stapled-publish window re-opens."
            )
        }
    }

    @Test("slim-DMG R2 pre-publish is a DEDICATED step with timeout + continue-on-error (slice ε.2 isolation invariant)")
    func slimR2PrepublishIsADedicatedStepWithTimeoutAndContinueOnError() throws {
        // Slice ε.2 cutover moved the slim DMG R2 publish from a
        // post-canonical-mirror "dormant best-effort" step into a
        // PRE-canonical-mirror LOAD-BEARING step (so latest.json
        // can reference the slim DMG atomically). The isolation
        // shape (timeout-minutes + continue-on-error + !cancelled())
        // is preserved so a wrangler stall on the slim leg still
        // cannot delay or block the canonical latest.json publish —
        // the difference is that on failure the canonical step now
        // falls back to writing dmg_url for the full DMG instead of
        // dropping the slim publish silently.
        let body = try Self.loadReleaseYaml()
        let lines = body.split(separator: "\n").map { String($0) }
        guard let nameIdx = lines.firstIndex(where: {
            $0.contains("name: Pre-publish slim bootstrapper DMG to dl.rapidmlx.com (R2) (P3 slice ε.2")
        }) else {
            Issue.record("release.yml has no dedicated slice ε.2 R2 pre-publish step — slice ε.2 cutover is missing. The slim R2 publish must live in its OWN step BEFORE the canonical mirror (see the ``Pre-publish slim bootstrapper DMG`` step body).")
            return
        }
        var stepEndIdx = lines.count
        for i in (nameIdx + 1)..<lines.count where lines[i].contains("- name:") {
            stepEndIdx = i
            break
        }
        let stepBlock = lines[nameIdx..<stepEndIdx].joined(separator: "\n")
        // timeout-minutes is load-bearing — without it a wrangler
        // stall waits indefinitely for GHA's job-level 360-min cap.
        // Slice ε.2 keeps this invariant from the original ε.1 step.
        #expect(
            stepBlock.contains("timeout-minutes:"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step is missing ``timeout-minutes:``. Without an explicit timeout, a wrangler stall on the slim leg waits indefinitely (up to GHA's 360-min job-level cap), delaying the downstream canonical mirror step. The bounded timeout converts a stall to slim_available=false + fall-back to canonical."
        )
        #expect(
            stepBlock.contains("continue-on-error: true"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step is missing ``continue-on-error: true``. Without this, a wrangler exit non-zero OR a timeout-minutes-triggered SIGTERM tanks the entire release. The fallback semantics depend on the step exiting cleanly (slim_available unset → canonical mirror reads as 'not true' → fall back to full DMG)."
        )
        // Step output declarations are required so the canonical
        // mirror step can read steps.slim_prepublish.outputs.* to
        // decide dmg_url / dmg_sha256 / dmg_size.
        #expect(
            stepBlock.contains("id: slim_prepublish"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step must carry ``id: slim_prepublish`` so the canonical mirror step's ``${{ steps.slim_prepublish.outputs.* }}`` reads resolve. Without this id, the conditional dmg_url shell var defaults to the canonical (full) DMG every release."
        )
        guard let ifClause = Self.extractIfClause(stepBlock: stepBlock) else {
            Issue.record("release.yml's dedicated slice ε.2 R2 pre-publish step has no ``if:`` clause — it must carry ``if: startsWith(github.ref, 'refs/tags/') && !cancelled()`` so it's tag-gated AND cleanly skips on user-cancel.")
            return
        }
        // Tag gate: PR dry-runs don't publish to R2.
        #expect(
            ifClause.contains("startsWith(github.ref, 'refs/tags/')"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step's ``if:`` clause is ``\(ifClause)`` — must contain ``startsWith(github.ref, 'refs/tags/')`` so PR dry-runs don't publish to R2."
        )
        // !cancelled() — user-cancellation cleanly skips the
        // wrangler puts (an in-flight put would otherwise outlast
        // the SIGTERM and half-publish to R2).
        #expect(
            ifClause.contains("!cancelled()"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step's ``if:`` clause is ``\(ifClause)`` — must contain ``!cancelled()`` so user-cancellation cleanly skips the wrangler puts."
        )
        #expect(
            !ifClause.contains("always()") && !ifClause.contains("success()"),
            "release.yml's dedicated slice ε.2 R2 pre-publish step's ``if:`` clause is ``\(ifClause)`` — must not contain ``always()`` (half-publish on cancel) nor ``success()`` (the implicit default would skip the step on any prior failure, forcing fallback to canonical every release after any earlier transient failure). Use ``startsWith(github.ref, 'refs/tags/') && !cancelled()``."
        )
    }

    @Test("dedicated slice ε.2 R2 pre-publish step lives BEFORE the canonical latest.json publish (atomicity invariant)")
    func slimR2PrepublishStepLivesBeforeCanonicalLatestJson() throws {
        // Sibling pin to
        // ``slimR2PrepublishIsADedicatedStepWith...``: verify the
        // pre-canonical-mirror ordering. Slice ε.2 cutover flipped
        // this from "slim AFTER canonical" (dormant ε.1) to "slim
        // BEFORE canonical" (load-bearing ε.2) so the latest.json
        // publish can reference the freshly-mirrored slim DMG
        // atomically — same invariant the sidecar + model legs
        // honour. A refactor that puts the slim step AFTER the
        // canonical mirror would publish a latest.json that
        // references a URL not yet on R2.
        let body = try Self.loadReleaseYaml()
        guard let canonicalIdx = body.range(of: "name: Mirror DMG + publish latest.json to dl.rapidmlx.com") else {
            Issue.record("release.yml has no canonical ``Mirror DMG + publish latest.json`` step — the mirror block was renamed or removed.")
            return
        }
        guard let slimIdx = body.range(of: "name: Pre-publish slim bootstrapper DMG to dl.rapidmlx.com (R2) (P3 slice ε.2") else {
            Issue.record("release.yml has no dedicated slice ε.2 R2 pre-publish step.")
            return
        }
        #expect(
            slimIdx.lowerBound < canonicalIdx.lowerBound,
            "release.yml's dedicated slice ε.2 R2 pre-publish step appears AFTER the canonical ``Mirror DMG + publish latest.json`` step. Slice ε.2 requires the slim DMG to be on R2 BEFORE latest.json composes dmg_url — otherwise the manifest references a URL that doesn't exist yet (atomicity violation). Keep the slim pre-publish step strictly BEFORE the canonical mirror."
        )
    }
}
