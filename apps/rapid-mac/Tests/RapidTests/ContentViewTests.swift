import Foundation
import Testing
@testable import Rapid

/// State-machine routing checks for ``ContentView.mainAreaBranch``.
///
/// This is a pure-logic test, deliberately not going through
/// SwiftUI: ``ContentView`` reads its observables via the modern
/// ``@Environment(T.self)`` Observation-framework injection, which
/// ViewInspector's ``EnvironmentInjection`` does NOT support (its
/// reflection path keys on the legacy ``SwiftUI.EnvironmentObject<T>``
/// type-name prefix only). Trying to host a real ``ContentView``
/// crashes at body-evaluation with "No Observable object of type X
/// found."
///
/// The branching logic in ``mainArea`` was the regression risk
/// anyway — the visual rendering of the four overlay variants is a
/// snapshot-test concern (Step 3). Lifting ``mainAreaBranch`` into a
/// static function gives us a testable seam without dragging
/// SwiftUI in.
@Suite("ContentView main-area branch routing")
struct ContentViewTests {
    @Test("rapid-mlx missing → .missing branch")
    func missingBranch() {
        let branch = ContentView.mainAreaBranch(for: .missing)
        #expect(branch == .missing)
    }

    @Test("crashed state routes to chat (transcript stays visible, ChatView owns the inline restart banner — #896)")
    func crashedBranch() {
        let branch = ContentView.mainAreaBranch(
            for: .crashed(alias: "fake-alias", message: "boom — simulated")
        )
        // Was: .crashed(message:) → full-screen overlay
        // Is:  .chat(serverReady: false) → transcript preserved,
        //      ChatView.crashBanner handles the Restart affordance.
        #expect(branch == .chat(serverReady: false))
    }

    @Test("starting state → .chat, so the draft and transcript survive the load")
    func startingBranch() {
        // Was `.starting`, a full-screen overlay in a SIBLING
        // ViewBuilder branch — so entering this state unmounted
        // ChatView and destroyed the user's typed draft and staged
        // attachments. Taking the composer's own advice ("start it from
        // the picker above") therefore ate the message they had just
        // written, and blanked the transcript for the whole 15-60 s
        // load. ChatView now stays mounted and shows the progress
        // inline. Same fix `.crashed` got in #896.
        let branch = ContentView.mainAreaBranch(for: .starting(alias: "any-alias"))
        #expect(branch == .chat(serverReady: false))
    }

    @Test("ready state → .chat with serverReady = true")
    func readyBranch() {
        let branch = ContentView.mainAreaBranch(for: .ready(alias: "fake-alias"))
        #expect(branch == .chat(serverReady: true))
    }

    @Test("idle state → .chat with serverReady = false")
    func idleBranch() {
        let branch = ContentView.mainAreaBranch(for: .idle)
        #expect(branch == .chat(serverReady: false))
    }

    @Test("stopped state → .chat with serverReady = false (same as idle)")
    func stoppedBranch() {
        let branch = ContentView.mainAreaBranch(for: .stopped)
        #expect(branch == .chat(serverReady: false))
    }
}

/// #432: pins ``ContentView.missingOverlayDownloadURL(for:)`` so the
/// "Setup didn't finish" sheet's primary CTA correctly swaps to a
/// "Download update vX.Y.Z" button whenever the in-app updater has
/// already resolved a newer release. The v0.8.12 → v0.8.13 incident
/// (every fresh slim-DMG user hit ``missingOverlay`` with only Quit /
/// Recheck and no in-app recovery) is the specific shape we're
/// preventing the next time around. Tested as a pure helper because
/// ``ContentView`` uses Observation-framework injection that
/// ViewInspector doesn't introspect (see notes on
/// ``ContentViewTests``).
///
/// Codex r1 BLOCKING (#433) — defense-in-depth: the helper now
/// re-validates scheme=https + ``updateReleaseHostAllowlist`` host
/// even though ``UpdateChecker.checkRelease`` already enforces the
/// same gate when populating ``availableUpdate``. The sink calls
/// ``NSWorkspace.shared.open(_:)`` directly with whatever the helper
/// returns; without this re-gate, a future refactor that loosens
/// ``checkRelease`` (or a test fixture that bypasses it) could
/// launch ``javascript:`` / ``file://`` URLs into the user's default
/// browser. Table-driven below.
@Suite("missingOverlay #432 download URL helper")
struct MissingOverlayDownloadCTATests {
    private func makeRelease(version: String, htmlURL: String) -> UpdateChecker.Release {
        UpdateChecker.Release(
            schemaVersion: 1,
            version: version,
            tagName: "v\(version)",
            htmlURL: htmlURL,
            notes: "",
            publishedAt: "2026-06-25T21:50:12Z",
            dmgURL: nil
        )
    }

    // MARK: — happy path

    @Test("no update available → nil (CTA stays as Quit)")
    func noUpdateAvailable() {
        #expect(ContentView.missingOverlayDownloadURL(for: nil) == nil)
    }

    @Test("rapidmlx.com release URL (the canonical happy path) → returns URL")
    func validRapidmlxComURL() {
        let release = makeRelease(version: "0.8.13", htmlURL: "https://rapidmlx.com/desktop")
        let url = ContentView.missingOverlayDownloadURL(for: release)
        #expect(url?.absoluteString == "https://rapidmlx.com/desktop")
    }

    @Test("github.com release URL (fallback when rapidmlx.com is down) → returns URL")
    func validGitHubURL() {
        let release = makeRelease(
            version: "0.8.13",
            htmlURL: "https://github.com/machinefi/rapid-desktop/releases/tag/v0.8.13"
        )
        let url = ContentView.missingOverlayDownloadURL(for: release)
        #expect(url?.host == "github.com")
        #expect(url?.path == "/machinefi/rapid-desktop/releases/tag/v0.8.13")
    }

    @Test("www.rapidmlx.com → returns URL (allowlist includes www variant)")
    func validWwwRapidmlxComURL() {
        let release = makeRelease(version: "0.8.13", htmlURL: "https://www.rapidmlx.com/desktop")
        #expect(ContentView.missingOverlayDownloadURL(for: release)?.host == "www.rapidmlx.com")
    }

    @Test("Mixed-case host is normalized (HTTPS://RAPIDMLX.COM/...) → returns URL")
    func mixedCaseHostNormalized() {
        let release = makeRelease(version: "0.8.13", htmlURL: "HTTPS://RAPIDMLX.COM/desktop")
        let url = ContentView.missingOverlayDownloadURL(for: release)
        // The helper accepts mixed-case scheme + host because the
        // ``checkRelease`` validator (and Apple's URL parser) both
        // lowercase before comparing — a JSON manifest typo
        // shouldn't break the recovery path.
        #expect(url != nil)
    }

    // MARK: — defense-in-depth: REJECTED schemes

    @Test("javascript: scheme → nil (rejected; never let the OS open arbitrary JS)")
    func rejectsJavascriptScheme() {
        let release = makeRelease(version: "0.8.13", htmlURL: "javascript:alert(1)")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    @Test("file:// scheme → nil (rejected; never let the OS open a local-file URL)")
    func rejectsFileScheme() {
        let release = makeRelease(version: "0.8.13", htmlURL: "file:///etc/passwd")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    @Test("http:// (insecure) on an otherwise-allowed host → nil")
    func rejectsInsecureHTTP() {
        let release = makeRelease(version: "0.8.13", htmlURL: "http://rapidmlx.com/desktop")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    @Test("custom scheme → nil")
    func rejectsCustomScheme() {
        let release = makeRelease(version: "0.8.13", htmlURL: "rapidmlx://open")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    // MARK: — defense-in-depth: REJECTED hosts

    @Test("HTTPS to an unknown host → nil (only allowlisted hosts pass)")
    func rejectsUnknownHost() {
        let release = makeRelease(version: "0.8.13", htmlURL: "https://evil.example.com/desktop")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    @Test("HTTPS with embedded user:password → nil (no credentials in URL)")
    func rejectsURLWithCredentials() {
        let release = makeRelease(
            version: "0.8.13",
            htmlURL: "https://attacker:secret@rapidmlx.com/desktop"
        )
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    // MARK: — malformed input

    @Test("empty htmlURL → nil")
    func rejectsEmptyString() {
        let release = makeRelease(version: "0.8.13", htmlURL: "")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }

    @Test("scheme-only URL (https://) → nil (no host present)")
    func rejectsSchemeOnly() {
        let release = makeRelease(version: "0.8.13", htmlURL: "https://")
        #expect(ContentView.missingOverlayDownloadURL(for: release) == nil)
    }
}
