import Foundation

/// Best-effort secret redaction for log lines surfaced in the UI's
/// log drawer.
///
/// `rapid-mlx` spawns subprocesses (HuggingFace downloader, model
/// loader) whose stderr can echo URLs, headers, and config blobs
/// that carry tokens. Examples that show up in real installs:
///
/// ```
/// downloading https://huggingface.co/api/models?token=hf_abc...
/// Authorization: Bearer sk_live_xyz...
/// {"api_key": "AIza..."}
/// HF_TOKEN=hf_long_secret_here
/// ```
///
/// The log drawer is a power-user surface but it's also what a user
/// copy-pastes into a support ticket — so a token glued to the
/// rapid-mlx server's stderr ends up in a public GitHub issue. We
/// scrub before storage (not at display time) so a memory dump or
/// "Copy Logs" CTA also yields the redacted text.
///
/// Audit P1 (ServerManager — child stderr streamed to log drawer
/// unscrubbed). Scope is deliberately narrow:
///
///   * We pattern-match the well-known leak shapes; we do NOT try
///     to be a generic high-entropy scanner (false-positive prone
///     and rapid-mlx's progress bars are full of hex-like content).
///   * Replacement is `<redacted>` so the surrounding context
///     (which header, which key, which env var) stays readable for
///     debugging — only the value is lost. A log reader can tell
///     the difference between "no Authorization header" and
///     "Authorization: Bearer was sent but redacted".
///   * The scrubber is a pure function: `String -> String`. No
///     dependency on `ServerManager`, no shared state, no logging
///     about what was scrubbed (the redaction itself is the
///     signal).
enum LogScrubber {
    /// Patterns to redact. Each entry is `(regex, replacement)`. The
    /// replacement keeps the leading context (`token=`, `Bearer `,
    /// etc.) so a log reader knows WHAT was scrubbed without seeing
    /// the value.
    ///
    /// Order matters slightly: longer / more-specific patterns
    /// first, so a generic `token=…` doesn't shadow a specific
    /// `HF_TOKEN=…` capture that wants its own debug-friendly
    /// replacement.
    static let patterns: [(regex: NSRegularExpression, template: String)] = {
        // Header / env / URL value terminator class. Stops at any
        // character that ENDS a logical value: whitespace, comma
        // (header continuation), semicolon (header param), and
        // both flavours of quote. Using `\S+` was the codex r1
        // BLOCKING — comma-joined headers on a single line
        // (`X-API-Key: abc, X-Other: def`) got greedy-eaten.
        // Tokens themselves (RFC 6750 token68, AWS, JWT base64url)
        // never contain these separators.
        let valTerm = #"[^\s,;'"]+"#
        // CLI flag forms (`--api-key=...`, `--token=...`) sometimes
        // surface in argv dumps; mirror the env-var pattern shape.
        let raw: [(String, String)] = [
            // HF_TOKEN=value (env-style, no quote)
            (#"\bHF_TOKEN="# + valTerm, "HF_TOKEN=<redacted>"),
            // HUGGING_FACE_HUB_TOKEN=value
            (#"\bHUGGING_FACE_HUB_TOKEN="# + valTerm, "HUGGING_FACE_HUB_TOKEN=<redacted>"),
            // OPENAI_API_KEY=value etc. Capture the FULL var name in
            // group 1 (non-capturing inner alternation) so the
            // template restores `OPENAI_API_KEY=<redacted>` instead
            // of chopping the prefix to `API_KEY=<redacted>`. The
            // chop pattern also caused the regex to re-fire on its
            // own output (`HF_TOKEN=<redacted>` got re-matched and
            // became `TOKEN=<redacted>`), so this also fixes the
            // pre-fix specific HF_TOKEN/HUGGING_FACE_HUB_TOKEN
            // shadow.
            (#"\b([A-Z][A-Z0-9_]*(?:API_KEY|SECRET|TOKEN))="# + valTerm, "$1=<redacted>"),
            // CLI flag forms: --api-key=... / --token=... / --hf-token=...
            // Shape: `--<optional-prefix>-(api-key|token|secret)=`.
            // The prefix is optional, so `--token=…` matches with no
            // prefix; `--hf-token=…` matches with prefix `hf`.
            (#"(--(?:[a-z][a-z0-9]*-)?(?:api-key|token|secret))="# + valTerm,
             "$1=<redacted>"),
            // Authorization: Bearer xyz (case-insensitive; "Bearer ",
            // "Token "). Codex r1 BLOCKING — char class
            // `[A-Za-z0-9._\-+/=]+` truncated JWT-with-`~` and
            // PASETO/Macaroon tokens at unsupported chars, leaving
            // the suffix exposed. `valTerm` stops only at logical
            // value boundaries.
            (#"(?i)(authorization:\s*)(bearer|token)\s+"# + valTerm, "$1$2 <redacted>"),
            // X-API-Key: xyz (case-insensitive). Same r1 fix —
            // `\S+` was greedy across comma-joined headers.
            (#"(?i)(x-api-key:\s*)"# + valTerm, "$1<redacted>"),
            // ?token=xyz or &token=xyz in URLs
            (#"([?&])token=[^&\s'"]+"#, "$1token=<redacted>"),
            // ?api_key=xyz or &api_key=xyz in URLs
            (#"([?&])api_key=[^&\s'"]+"#, "$1api_key=<redacted>"),
            // ?key=AIza... Google-style URL key
            (#"([?&])key=[^&\s'"]+"#, "$1key=<redacted>"),
            // "api_key": "xyz" — JSON form, double-quoted
            (#""api_key"\s*:\s*"[^"]+""#, #""api_key": "<redacted>""#),
            // "token": "xyz" — JSON form
            (#""token"\s*:\s*"[^"]+""#, #""token": "<redacted>""#),
            // "authorization": "Bearer xyz" — JSON form
            (#"(?i)"authorization"\s*:\s*"[^"]+""#, #""authorization": "<redacted>""#),
        ]
        // Codex r1 BLOCKING — `try?` swallowed compile failures
        // silently, so a typo'd pattern would let leaks pass with
        // zero signal. These patterns are static literals; a
        // failure is a programmer error and a hard crash on
        // startup is the right failure mode (caught immediately
        // by any smoke run, never reaches a user with secrets in
        // the log).
        return raw.map { (pattern, template) in
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                return (regex, template)
            } catch {
                preconditionFailure(
                    "LogScrubber regex failed to compile: \(pattern) — \(error)"
                )
            }
        }
    }()

    /// Apply every pattern in order. Returns the scrubbed string;
    /// returns the input unchanged when no pattern matches.
    static func scrub(_ line: String) -> String {
        var result = line
        for (regex, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result
    }
}
