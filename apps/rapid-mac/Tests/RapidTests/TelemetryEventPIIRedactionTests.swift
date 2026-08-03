import Foundation
import Testing
@testable import Rapid

/// Pins the PII-redaction contract for telemetry events (audit P1
/// `TelemetryEvent — verify error events don't include full paths,
/// model aliases, message snippets`). Telemetry rides over HTTPS
/// to the Cloudflare Worker but R2 storage retention + Worker
/// logs both mean a leaked PII field has a long tail; redact at
/// build time so the on-disk crash marker AND the wire envelope
/// share the same scrubbed shape.
@Suite("TelemetryEvent PII redaction")
struct TelemetryEventPIIRedactionTests {

    // MARK: - Path scrubbing

    @Test("/Users/<name>/ is redacted")
    func users_path_redacted() {
        let input = "frame at /Users/raullen/work/rapid-desktop/Sources/foo.swift:42"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("/Users/<redacted>/"))
        #expect(!out.contains("/Users/raullen/"))
        #expect(out.contains("/work/rapid-desktop/"),
                "Path AFTER the username segment survives — needed for actionable telemetry")
    }

    @Test("/home/<name>/ is redacted")
    func home_path_redacted() {
        let input = "trace /home/ubuntu/code/foo.py"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("/home/<redacted>/"))
        #expect(!out.contains("/home/ubuntu/"))
    }

    /// macOS sandbox temp dirs contain a per-Apple-ID hash that
    /// can be cross-referenced — pre-fix it leaked verbatim in
    /// stack frames touching `URL(fileURLWithPath:)` of
    /// `FileManager.default.temporaryDirectory`.
    @Test("/private/var/folders/<x>/<y>/ container ID is redacted (trailing slash)")
    func private_var_folders_redacted() {
        let input = "wrote /private/var/folders/yj/abcd1234efgh5678/T/foo.tmp"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("/private/var/folders/<redacted>/<redacted>/"))
        #expect(!out.contains("yj/abcd1234efgh5678"),
                "Container ID hash must not survive")
    }

    @Test("/var/folders/<x>/<y>/ (canonical, non-private) is redacted")
    func var_folders_canonical_redacted() {
        let input = "/var/folders/yj/xxxx/T/cache.db"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("/var/folders/<redacted>/<redacted>/"))
        #expect(!out.contains("yj/xxxx"))
    }

    /// Codex r1 BLOCKING-2: pre-fix the trailing `/` was required,
    /// so an `NSException.reason` that terminated AT the segment
    /// boundary (no path continuation) leaked the container ID
    /// verbatim. Test EOL, whitespace boundary, and a punctuation
    /// boundary that's neither.
    @Test("/private/var/folders/<x>/<y> at end-of-string IS redacted")
    func private_var_folders_redacted_at_eol() {
        let input = "exited in /private/var/folders/yj/abcd1234efgh5678"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(!out.contains("yj/abcd1234efgh5678"),
                "Container ID at EOL must not survive: \(out)")
        #expect(out.contains("/private/var/folders/<redacted>/<redacted>"))
    }

    @Test("/private/var/folders/<x>/<y> before whitespace IS redacted")
    func private_var_folders_redacted_before_whitespace() {
        let input = "exited in /private/var/folders/yj/abcd1234efgh5678 then crashed"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(!out.contains("yj/abcd1234efgh5678"))
        #expect(out.contains("/private/var/folders/<redacted>/<redacted> then crashed"))
    }

    @Test("/var/folders/<x>/<y> at end-of-string IS redacted")
    func var_folders_redacted_at_eol() {
        let input = "path: /var/folders/yj/abcd1234efgh5678"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(!out.contains("yj/abcd1234efgh5678"))
        #expect(out.contains("/var/folders/<redacted>/<redacted>"))
    }

    // MARK: - Token scrubbing (delegated to LogScrubber)

    @Test("Authorization Bearer in a stack frame is redacted")
    func bearer_in_stack_frame() {
        let input = "URLSession threw with header Authorization: Bearer sk_secret_xyz"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("Authorization: Bearer <redacted>"))
        #expect(!out.contains("sk_secret_xyz"))
    }

    @Test("HF_TOKEN env var in an error message is redacted")
    func hf_token_in_message() {
        let input = "child failed: env HF_TOKEN=hf_secret_token123 model=qwen"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("HF_TOKEN=<redacted>"))
        #expect(!out.contains("hf_secret_token123"))
    }

    @Test("URL with ?token= in a context label is redacted")
    func url_token_in_context() {
        let input = "request to https://api.example.com/v1/list?token=ghp_abc&model=foo"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out.contains("?token=<redacted>"))
        #expect(!out.contains("ghp_abc"))
    }

    // MARK: - Length cap

    @Test("Length cap fires AFTER redaction so <redacted> isn't sliced mid-token")
    func length_cap_runs_last() {
        let input = "/Users/foo/" + String(repeating: "a", count: 1000)
        let out = TelemetryEvent.redact(input, cap: 100)
        #expect(out.contains("/Users/<redacted>/"),
                "Redaction must complete before length cap chops")
        #expect(out.count <= 101,  // +1 for the ellipsis
                "Length cap enforced: \(out.count) chars")
        #expect(out.hasSuffix("…"))
    }

    @Test("Input shorter than cap is untouched at the tail")
    func short_input_no_ellipsis() {
        let input = "short error message"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out == input)
        #expect(!out.hasSuffix("…"))
    }

    // MARK: - error_type closed-set guarantee

    /// `error_type` is dashboard-faceted; a future codepath
    /// passing a user-controlled string here both creates
    /// cardinality explosion AND can leak PII (an exception name
    /// carrying a path). Pin the closed set so any new error
    /// type forces a deliberate audit + addition.
    @Test("error_type closed set is the documented 3 values")
    func error_type_closed_set_pinned() {
        #expect(TelemetryEvent.allowedErrorTypes == [
            "unclean_shutdown",
            "uncaught_exception",
            "signal",
        ])
    }

    /// Build a real event and verify the error_type lands in the
    /// allowed set — round-trips through the static constructor.
    @Test("error() with an allowed error_type round-trips through the closed set")
    func error_constructor_emits_allowed_type() {
        let platform = TelemetryEvent.Platform(
            app: "rapid-desktop", os: "macOS", os_version: "14.0", arch: "arm64"
        )
        for kind in TelemetryEvent.allowedErrorTypes {
            let event = TelemetryEvent.error(
                version: "1.0.0",
                platform: platform,
                errorType: kind,
                errorMessage: "test",
                stackFrames: [],
                context: nil,
                sessionID: "test-session"
            )
            #expect(TelemetryEvent.allowedErrorTypes.contains(event.error_type ?? ""))
        }
    }

    /// Codex r1 BLOCKING-1: pre-fix the constructor accepted any
    /// string and stored it verbatim. A future caller passing a
    /// raw `NSException.name` could leak a path in the error_type
    /// field. The clamp must rewrite anything outside the closed
    /// set to `"unknown"` so the operator sees a louder failure
    /// mode than silent PII leak.
    @Test("error() clamps an out-of-set errorType to 'unknown'")
    func error_constructor_clamps_unknown_type() {
        let platform = TelemetryEvent.Platform(
            app: "rapid-desktop", os: "macOS", os_version: "14.0", arch: "arm64"
        )
        // A realistic leak shape: an exception name carrying a
        // path. Pre-fix this would have ridden verbatim into
        // telemetry's `error_type` field.
        let event = TelemetryEvent.error(
            version: "1.0.0",
            platform: platform,
            errorType: "/Users/raullen/proj/CrashedHere",
            errorMessage: "test",
            stackFrames: [],
            context: nil,
            sessionID: "test-session"
        )
        #expect(event.error_type == "unknown",
                "Out-of-set errorType must clamp to 'unknown', got: \(String(describing: event.error_type))")
    }

    // MARK: - Negative cases

    @Test("Ordinary error message with no PII passes through unchanged")
    func ordinary_message_unchanged() {
        let input = "Failed to decode response: invalid UTF-8"
        let out = TelemetryEvent.redact(input, cap: 4096)
        #expect(out == input)
    }

    @Test("Empty string redacts to empty string")
    func empty_string() {
        #expect(TelemetryEvent.redact("", cap: 4096) == "")
    }

    /// Redaction must be idempotent — same field-set used both
    /// at marker-write time AND at send time, so applying twice
    /// (current shape: write redacted, then redact-on-send) must
    /// be a no-op.
    @Test("redact is idempotent")
    func redact_idempotent() {
        let input = "from /Users/raullen/proj — Authorization: Bearer abc123"
        let once = TelemetryEvent.redact(input, cap: 4096)
        let twice = TelemetryEvent.redact(once, cap: 4096)
        #expect(once == twice)
    }
}
