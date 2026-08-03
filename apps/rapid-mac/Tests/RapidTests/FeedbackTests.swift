import Foundation
import Testing
@testable import Rapid

/// Contract for the in-app feedback funnel (Help menu + MenuBarExtra).
///
/// Because ``machinefi/rapid-desktop`` is private, both "Report a Bug…" and
/// "Request a Feature…" deep-link into the public ``raullenchai/Rapid-MLX``
/// issue tracker with:
///   - host = ``github.com``
///   - path = ``/raullenchai/Rapid-MLX/issues/new``
///   - title prefix ``[Desktop App]`` (triage routing signal)
///   - ``desktop-app`` label + a kind-specific second label (``bug`` /
///     ``enhancement``) so the public tracker can filter Desktop issues
///   - an Environment block carrying the Desktop app version, the macOS
///     version, and the Mac hardware model — pre-populated so reporters
///     don't have to fish for it.
///
/// These tests pin the URL contract via the pure ``Feedback.issueURL(for:)``
/// constructor so they never have to launch a browser.
@Suite("Feedback — in-app bug/feature funnel into raullenchai/Rapid-MLX")
struct FeedbackTests {
    // MARK: - Helpers

    private func components(for kind: Feedback.Kind) -> URLComponents {
        guard let url = Feedback.issueURL(for: kind) else {
            Issue.record("Feedback.issueURL(for: .\(kind)) returned nil")
            return URLComponents()
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("Could not parse URLComponents from \(url)")
            return URLComponents()
        }
        return comps
    }

    private func queryValue(_ comps: URLComponents, _ name: String) -> String? {
        comps.queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - URL non-nil contract

    @Test("issueURL(for:) returns a non-nil URL for both kinds")
    func issueURLIsNonNil() {
        #expect(Feedback.issueURL(for: .bug) != nil)
        #expect(Feedback.issueURL(for: .feature) != nil)
    }

    // MARK: - Host / path contract

    @Test("Both kinds route to github.com /raullenchai/Rapid-MLX/issues/new")
    func hostAndPathArePinnedToPublicRepo() {
        for kind in [Feedback.Kind.bug, .feature] {
            let comps = components(for: kind)
            #expect(comps.scheme == "https")
            #expect(comps.host == "github.com")
            #expect(comps.path == "/raullenchai/Rapid-MLX/issues/new")
        }
    }

    // MARK: - Bug contract

    @Test("Bug title carries the [Desktop App] prefix triage relies on")
    func bugTitleHasDesktopAppPrefix() {
        let title = queryValue(components(for: .bug), "title") ?? ""
        #expect(title.hasPrefix("[Desktop App] "))
    }

    @Test("Bug labels are exactly desktop-app,bug")
    func bugLabelsAreDesktopAppAndBug() {
        let labels = queryValue(components(for: .bug), "labels")
        #expect(labels == "desktop-app,bug")
    }

    @Test("Bug body contains the full environment block and a reproduce prompt")
    func bugBodyHasEnvironmentAndReproduce() {
        let body = queryValue(components(for: .bug), "body") ?? ""
        // Pin every Environment line the contract promises. A future
        // copy-edit that drops `macOS version:` or `Hardware:` (the
        // codex r1 finding that was regressed for the feature
        // template) must fail this test for either kind.
        #expect(body.contains("Rapid-MLX version:"))
        #expect(body.contains("macOS version:"))
        #expect(body.contains("Hardware:"))
        // Triage needs reporters to walk a repro; the template must
        // surface that prompt literally so a future copy-edit doesn't
        // silently drop it.
        #expect(body.lowercased().contains("reproduce"))
    }

    // MARK: - Feature contract

    @Test("Feature title carries the [Desktop App] prefix triage relies on")
    func featureTitleHasDesktopAppPrefix() {
        let title = queryValue(components(for: .feature), "title") ?? ""
        #expect(title.hasPrefix("[Desktop App] "))
    }

    @Test("Feature labels are exactly desktop-app,enhancement")
    func featureLabelsAreDesktopAppAndEnhancement() {
        let labels = queryValue(components(for: .feature), "labels")
        #expect(labels == "desktop-app,enhancement")
    }

    @Test("Feature body leads with the problem-framing prompt and the full env block")
    func featureBodyHasProblemFramingPrompt() {
        let body = queryValue(components(for: .feature), "body") ?? ""
        #expect(body.contains("What problem would this solve?"))
        // Feature reports carry the SAME Environment block as bug
        // reports — codex r1 caught a divergence where feature
        // omitted macOS+hardware. Pin all three lines so the
        // regression can't come back.
        #expect(body.contains("Rapid-MLX version:"))
        #expect(body.contains("macOS version:"))
        #expect(body.contains("Hardware:"))
    }

    // MARK: - Environment block presence

    /// In a test bundle ``CFBundleShortVersionString`` is often missing, so
    /// the version may legitimately read "unknown". We only assert that the
    /// environment line is present — not the value — so the test is stable
    /// across test-bundle and shipped-app contexts.
    @Test("Bug body always carries an app-version line (value may be 'unknown' in test bundle)")
    func bugBodyAlwaysHasAppVersionLine() {
        let body = queryValue(components(for: .bug), "body") ?? ""
        #expect(body.contains("Rapid-MLX version:"))
    }

    @Test("Feature body always carries an app-version line (value may be 'unknown' in test bundle)")
    func featureBodyAlwaysHasAppVersionLine() {
        let body = queryValue(components(for: .feature), "body") ?? ""
        #expect(body.contains("Rapid-MLX version:"))
    }

    @Test("Sentry message carries kind, user details, and non-sensitive runtime context")
    func sentryMessageCarriesTriageContext() {
        let message = Feedback.sentryMessage(
            for: .bug,
            details: "The model picker stopped responding."
        )
        #expect(message.contains("Feedback type: bug"))
        #expect(message.contains("The model picker stopped responding."))
        #expect(message.contains("Rapid-MLX version:"))
        #expect(message.contains("macOS version:"))
        #expect(message.contains("Hardware:"))
    }

    @Test("Send re-enables after clearing and entering a new non-empty message")
    func sendReenablesAfterReplacingMessage() {
        #expect(Feedback.canSubmit(
            message: "The first feedback message",
            sentryConfigured: true
        ))
        #expect(!Feedback.canSubmit(message: "", sentryConfigured: true))
        #expect(!Feedback.canSubmit(message: "   \n", sentryConfigured: true))
        #expect(Feedback.canSubmit(message: "重新输入", sentryConfigured: true))
        #expect(!Feedback.canSubmit(message: "重新输入", sentryConfigured: false))
    }
}

@Suite("Sentry Feedback configuration")
struct SentryFeedbackConfigurationTests {
    private let validEnvironmentDSN = "https://public-key@o123.ingest.sentry.io/456"
    private let validBundleDSN = "https://bundle-key@sentry.example.com/789"

    @Test("Feedback uses one shared user label instead of a per-install identifier")
    func feedbackUserIsNonUnique() {
        #expect(SentryFeedbackClient.sharedUserID == "feedback")
    }

    @Test("Runtime environment DSN takes precedence over the bundled value")
    func environmentTakesPrecedence() {
        let dsn = SentryFeedbackConfiguration.dsn(
            environment: [SentryFeedbackConfiguration.environmentKey: validEnvironmentDSN],
            infoDictionary: [SentryFeedbackConfiguration.infoDictionaryKey: validBundleDSN]
        )
        #expect(dsn == validEnvironmentDSN)
    }

    @Test("Finder-launched builds use the Info.plist DSN")
    func bundledDSNIsSupported() {
        let dsn = SentryFeedbackConfiguration.dsn(
            environment: [:],
            infoDictionary: [SentryFeedbackConfiguration.infoDictionaryKey: validBundleDSN]
        )
        #expect(dsn == validBundleDSN)
    }

    @Test("Blank and malformed DSNs leave Sentry disabled")
    func invalidDSNsAreRejected() {
        #expect(SentryFeedbackConfiguration.dsn(
            environment: [SentryFeedbackConfiguration.environmentKey: "  "],
            infoDictionary: [SentryFeedbackConfiguration.infoDictionaryKey: "https://sentry.example.com/no-public-key"]
        ) == nil)
        #expect(!SentryFeedbackConfiguration.isValidDSN("not a URL"))
        #expect(!SentryFeedbackConfiguration.isValidDSN("http://public@sentry.example.com/1"))
        #expect(!SentryFeedbackConfiguration.isValidDSN("https://public@sentry.example.com"))
    }
}
