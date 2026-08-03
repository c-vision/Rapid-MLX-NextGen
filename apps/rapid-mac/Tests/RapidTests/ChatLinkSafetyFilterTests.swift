import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// Issue #304 (security / red-team-finding) + #349 (mailto UX): the
/// chat Markdown renderer must reject every URL scheme except the
/// explicit allowlist (`http`, `https`, `mailto`). A compromised
/// model / prompt-injected tool result can emit a clickable
/// `file://` link; without this filter, one click opens an arbitrary
/// local file in TextEdit/Preview. `mailto:` is allowed because
/// the system mail client opens a compose window (no auto-send, no
/// filesystem read).
///
/// We test the pure ``ChatLinkSafety.decide(_:)`` decision function
/// rather than driving an ``OpenURLAction`` through a SwiftUI view
/// tree, because:
///   * `OpenURLAction.callAsFunction(_:)` returns `Void` — its
///     handler closure produces the `Result`, but the public surface
///     consumes it; a test that only had the action couldn't see
///     `.handled` vs `.systemAction`.
///   * The pure function IS the policy — the SwiftUI bridge is a
///     trivial 4-line switch (``chatLinkSafetyAction()``). Pinning
///     the decision keeps the test honest and fast (no MainActor,
///     no window).
///   * `chatLinkSafetyAction()` is asserted constructable in a
///     separate `@MainActor` test, so the bridge does build/run.
@Suite("ChatLinkSafetyFilter — model-emitted URL scheme allowlist (#304)")
struct ChatLinkSafetyFilterTests {

    // MARK: - Reject: dangerous schemes

    @Test("file:// links to the home directory are rejected")
    func rejectsFileURL() {
        let url = URL(string: "file:///Users/test/.ssh/id_rsa")!
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    @Test("file:// links to /etc are rejected")
    func rejectsFileURLEtc() {
        let url = URL(string: "file:///etc/hosts")!
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    @Test("javascript: URLs are rejected")
    func rejectsJavascriptURL() {
        let url = URL(string: "javascript:alert(1)")!
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    @Test("slack:// app-deeplinks are rejected")
    func rejectsSlackURL() {
        let url = URL(string: "slack://channel?team=T123&id=C456")!
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    @Test("vscode:// app-deeplinks are rejected")
    func rejectsVscodeURL() {
        let url = URL(string: "vscode://file/Users/test/.bashrc")!
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    @Test("Custom app schemes (zoomus://, ms-teams:, obsidian://, raycast://) are rejected")
    func rejectsCustomAppSchemes() {
        let cases = [
            "zoomus://zoom.us/join?confno=1",
            "ms-teams:/l/meetup-join/foo",
            "obsidian://open?vault=secret",
            "raycast://extensions/install?source=evil"
        ]
        for raw in cases {
            let url = URL(string: raw)!
            #expect(ChatLinkSafety.decide(url) == .rejected, "scheme should be rejected: \(raw)")
        }
    }

    @Test("Auto-dial / phone schemes (tel:, sms:, facetime:) stay rejected even after #349")
    func rejectsAutoDialSchemes() {
        // Issue #349 widened the allowlist to include mailto: only.
        // tel:/sms:/facetime: auto-dial app deeplinks remain rejected —
        // the cost-benefit on a desktop chat surface does not justify
        // routing an attacker-chosen number into the system handler.
        let cases = [
            "tel:+15551234567",
            "sms:+15551234567",
            "sms:+15551234567?body=urgent",
            "facetime:+15551234567",
            "facetime-audio:hello@example.com"
        ]
        for raw in cases {
            let url = URL(string: raw)!
            #expect(ChatLinkSafety.decide(url) == .rejected, "auto-dial scheme should be rejected: \(raw)")
        }
    }

    @Test("Uppercase / mixed-case dangerous schemes are still rejected")
    func rejectsCaseVariantsOfDangerousSchemes() {
        let cases = [
            "FILE:///etc/hosts",
            "File:///Users/test/.ssh/id_rsa",
            "JavaScript:alert(1)",
            "JAVASCRIPT:alert(1)"
        ]
        for raw in cases {
            let url = URL(string: raw)!
            #expect(ChatLinkSafety.decide(url) == .rejected, "case-variant scheme should be rejected: \(raw)")
        }
    }

    @Test("Scheme-less and opaque inputs are rejected (default-deny)")
    func rejectsSchemeLess() {
        // `URL(string:)` on a bare path returns a URL whose scheme
        // is nil. Default-deny is the right behaviour: nothing in a
        // chat surface should be dispatched to NSWorkspace by
        // accident.
        let url = URL(string: "/etc/hosts")!
        #expect(url.scheme == nil)
        #expect(ChatLinkSafety.decide(url) == .rejected)
    }

    // MARK: - Accept: http / https

    @Test("http:// passes through to the system handler")
    func acceptsHTTP() {
        let url = URL(string: "http://example.com/page")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    @Test("https:// passes through to the system handler")
    func acceptsHTTPS() {
        let url = URL(string: "https://example.com/page")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    @Test("Uppercase HTTPS:// is normalised on the comparison side and accepted")
    func acceptsUppercaseHTTPS() {
        let url = URL(string: "HTTPS://Example.com/Page")!
        // The original URL is forwarded verbatim — we don't rewrite
        // the host/path; we only gate on the (lowercased) scheme.
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    @Test("https URLs with query strings and fragments pass through")
    func acceptsHTTPSWithComplexPath() {
        let url = URL(string: "https://example.com/a?b=c&d=e#frag")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    // MARK: - Accept: mailto (issue #349)

    @Test("mailto: links open in the system mail client (issue #349)")
    func acceptsMailto() {
        let url = URL(string: "mailto:hello@example.com")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    @Test("mailto: with subject and body is forwarded verbatim (issue #349)")
    func acceptsMailtoWithSubjectAndBody() {
        let url = URL(string: "mailto:hello@example.com?subject=hi&body=hey")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    @Test("Mixed-case MailTo: is normalised on the scheme side and accepted")
    func acceptsUppercaseMailto() {
        let url = URL(string: "MailTo:hello@example.com")!
        #expect(ChatLinkSafety.decide(url) == .allowed(url))
    }

    // MARK: - Allowlist surface

    @Test("Allowlist is exactly {http, https, mailto}")
    func allowlistShape() {
        #expect(ChatLinkSafety.allowedSchemes == ["http", "https", "mailto"])
    }

    @Test("Allowlist entries are lower-case (so .lowercased() comparison matches)")
    func allowlistIsLowerCased() {
        for scheme in ChatLinkSafety.allowedSchemes {
            #expect(scheme == scheme.lowercased(), "allowlist entry must be lower-cased: \(scheme)")
        }
    }

    // MARK: - SwiftUI bridge constructs

    /// `chatLinkSafetyAction()` is the bridge from the pure
    /// ``decide`` function to SwiftUI's `OpenURLAction`. Pin that the
    /// bridge builds and runs on the main actor, separately from the
    /// policy tests above.
    @Test("chatLinkSafetyAction() constructs an OpenURLAction without crashing")
    @MainActor
    func bridgeConstructs() {
        let action = ChatLinkSafety.chatLinkSafetyAction()
        // Use the action in a value-binding so the compiler can't DCE
        // the construction. We never call it (the call returns Void
        // and would dispatch to NSWorkspace for an http URL in a real
        // host) — the goal is to lock that the type-level wiring
        // compiles and the value exists.
        let stored: OpenURLAction = action
        _ = stored
    }
}
