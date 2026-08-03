import AppKit
import Foundation
import Testing
@testable import Rapid

/// Pin the shape of the dictionary handed to AppKit's
/// ``orderFrontStandardAboutPanel(options:)``. We don't actually pop
/// the panel during tests (that'd require a running NSApplication
/// event loop and a real display), but the dictionary contents are
/// the load-bearing part — version mis-formatting or a missing repo
/// link is exactly the regression we want to catch.
@MainActor
@Suite("AboutPanel options dictionary")
struct AboutPanelTests {
    @Test("App name + version use AppKit's split dict slots (no manual concat)")
    func nameAndVersion() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: "42",
            binaryPath: "/opt/homebrew/bin/rapid-mlx",
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        #expect(options[.applicationName] as? String == "Rapid-MLX")
        // .applicationVersion is the short version only. AppKit auto-
        // appends the parenthesised build from .version when it
        // renders the panel — concatenating both ourselves yielded
        // "Version 0.3.1 (42) (42)" (issue #237). Keep them split.
        #expect(options[.applicationVersion] as? String == "0.3.1")
        #expect(options[.version] as? String == "42")
    }

    @Test("Identical short-version and build-number still surfaces the build slot (codex r1 BLOCKING #238)")
    func versionEqualsBuildKeepsBuildSlot() {
        // Originally we omitted `.version` when `buildNumber ==
        // version` thinking that suppressed the parenthesised render.
        // It doesn't — AppKit falls back to CFBundleVersion from
        // Info.plist whenever `.version` is absent, and that's the
        // same value, so the parens still appear. Stop pretending we
        // can suppress what we can't; pass the build through and the
        // edge case renders as "Version 0.3.1 (0.3.1)". Better than
        // the false-suppress illusion the previous shape implied.
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: "0.3.1",
            binaryPath: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        #expect(options[.applicationVersion] as? String == "0.3.1")
        #expect(options[.version] as? String == "0.3.1")
    }

    @Test("Missing build number omits the .version slot")
    func missingBuildNumberOmitsVersionSlot() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: nil,
            binaryPath: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        #expect(options[.applicationVersion] as? String == "0.3.1")
        #expect(options[.version] == nil)
    }

    @Test("Empty build number omits the .version slot")
    func emptyBuildNumberOmitsVersionSlot() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: "",
            binaryPath: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        #expect(options[.applicationVersion] as? String == "0.3.1")
        #expect(options[.version] == nil)
    }

    @Test("Credits body includes the resolved binary path verbatim")
    func creditsIncludeBinaryPath() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: nil,
            binaryPath: "/opt/homebrew/bin/rapid-mlx",
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        let credits = try? #require(options[.credits] as? NSAttributedString)
        #expect(credits?.string.contains("/opt/homebrew/bin/rapid-mlx") == true)
    }

    @Test("Missing binary falls back to the bootstrapper-relaunch hint")
    func missingBinaryFallback() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: nil,
            binaryPath: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        let credits = try? #require(options[.credits] as? NSAttributedString)
        // The recovery hint is what tells a new user how to recover
        // from a missing binary — don't drop it silently.
        //
        // v0.8.10 cutover: brew is no longer a supported install
        // path. The hint now points users at the bootstrapper
        // (quit + reopen re-runs ``BootstrapCoordinator``) and at
        // ``RAPID_BIN`` for the dev-checkout escape hatch.
        #expect(credits?.string.contains("not detected") == true)
        #expect(credits?.string.contains("RAPID_BIN") == true)
        #expect(credits?.string.contains("Homebrew") == false,
                "Brew install hint removed in v0.8.10 — see AboutPanel.swift cutover note.")
    }

    @Test("Resolved origin label is appended to the binary path when supplied")
    func binarySourceRendersAlongsidePath() {
        // ``makeOptions`` renders whatever source string it's handed;
        // we use a live label ("App-managed override") rather than a
        // package-manager origin the locator no longer classifies.
        let options = AboutPanel.makeOptions(
            version: "0.6.0",
            buildNumber: nil,
            binaryPath: "/Users/test/Library/Application Support/Rapid/runtime-override/rapid-mlx/bin/rapid-mlx",
            binarySource: "App-managed override",
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        let credits = try? #require(options[.credits] as? NSAttributedString)
        // Render shape is "<path>  (<source>)" — two spaces so the
        // source reads as a secondary annotation rather than running
        // into the path. Bug-report screenshots get to say
        // "App-managed override" instead of forcing us to guess the
        // origin from the path alone.
        #expect(credits?.string.contains("runtime-override/rapid-mlx/bin/rapid-mlx  (App-managed override)") == true)
    }

    @Test("Empty / nil source falls back to the bare path — no '(nil)' theatre")
    func emptySourceFallsBackToBarePath() {
        let options = AboutPanel.makeOptions(
            version: "0.6.0",
            buildNumber: nil,
            binaryPath: "/opt/homebrew/bin/rapid-mlx",
            binarySource: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        let credits = try? #require(options[.credits] as? NSAttributedString)
        #expect(credits?.string.contains("/opt/homebrew/bin/rapid-mlx") == true)
        #expect(credits?.string.contains("(nil)") == false)
        #expect(credits?.string.contains("()") == false)
    }

    @Test("bundledRapidMlxVersion reads VERSION written by build.sh")
    func bundledVersionReadsFromResourceURL() throws {
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "rapid-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sidecarDir = tempDir.appendingPathComponent(
            "rapid-mlx",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sidecarDir,
            withIntermediateDirectories: true
        )
        // build.sh writes the raw `git describe` output + trailing
        // newline. The reader must strip the newline, so the
        // returned value is suitable for inline rendering.
        try "v0.7.11\n".write(
            to: sidecarDir.appendingPathComponent("VERSION"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            AboutPanel.bundledRapidMlxVersion(resourceURL: tempDir)
                == "v0.7.11"
        )
    }

    @Test("bundledRapidMlxVersion returns nil when VERSION file missing")
    func bundledVersionMissingFileReturnsNil() {
        // SKIP_SIDECAR=1 dev builds ship no rapid-mlx/ directory.
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "rapid-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        // Don't create the directory — simulating an empty
        // Contents/Resources/.
        #expect(
            AboutPanel.bundledRapidMlxVersion(resourceURL: tempDir)
                == nil
        )
    }

    @Test("bundledRapidMlxVersion returns nil for an empty VERSION file")
    func bundledVersionEmptyFileReturnsNil() throws {
        // Defensive: if build.sh ever wrote a blank file (e.g.
        // ``git describe`` errored and the fallback echoed nothing),
        // we'd rather render "Bundled with app" than "Bundled ".
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "rapid-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sidecarDir = tempDir.appendingPathComponent(
            "rapid-mlx",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sidecarDir,
            withIntermediateDirectories: true
        )
        try "  \n\n".write(
            to: sidecarDir.appendingPathComponent("VERSION"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            AboutPanel.bundledRapidMlxVersion(resourceURL: tempDir)
                == nil
        )
    }

    @Test("Repo URL becomes a clickable link attribute in the credits body")
    func repoIsClickableLink() {
        let options = AboutPanel.makeOptions(
            version: "0.3.1",
            buildNumber: nil,
            binaryPath: nil,
            repoURL: "https://github.com/machinefi/rapid-desktop"
        )
        let credits = try? #require(options[.credits] as? NSAttributedString)
        guard let attributed = credits else {
            Issue.record("credits dict slot was not NSAttributedString")
            return
        }
        // Walk the attributed string looking for a .link attribute
        // whose value matches the repo URL.
        var foundLink = false
        let range = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: range) { value, _, _ in
            if let url = value as? URL,
               url.absoluteString == "https://github.com/machinefi/rapid-desktop" {
                foundLink = true
            }
        }
        #expect(foundLink)
    }
}
