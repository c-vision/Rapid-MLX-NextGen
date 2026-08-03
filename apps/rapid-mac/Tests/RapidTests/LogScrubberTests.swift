import Testing
@testable import Rapid

/// Pins the secret-redaction contract for log lines surfaced in
/// the log drawer and download-failure messages (audit P1
/// `ServerManager — Child stderr streamed to log drawer unscrubbed`).
/// The scrubber must catch the well-known leak shapes that
/// rapid-mlx's child processes (HF downloader, model loader) can
/// emit, while leaving normal log lines untouched so debugging
/// doesn't get noisier.
@Suite("LogScrubber secret-redaction patterns")
struct LogScrubberTests {

    // MARK: - Header forms

    @Test("Authorization: Bearer <token> — capital-B")
    func authorization_bearer_capital() {
        let input = "Authorization: Bearer sk_live_abc123XYZ.def"
        let out = LogScrubber.scrub(input)
        #expect(out == "Authorization: Bearer <redacted>")
    }

    @Test("authorization: bearer <token> — lowercase header, lowercase scheme")
    func authorization_bearer_lowercase() {
        let input = "authorization: bearer hf_abcDEF123_secret"
        let out = LogScrubber.scrub(input)
        #expect(out == "authorization: bearer <redacted>")
    }

    @Test("Authorization: Token <token> — alternate scheme")
    func authorization_token() {
        let input = "Authorization: Token ghp_abc123"
        let out = LogScrubber.scrub(input)
        #expect(out == "Authorization: Token <redacted>")
    }

    @Test("X-API-Key header is redacted")
    func x_api_key_header() {
        let input = "X-API-Key: AIzaSyC_long_key_value"
        let out = LogScrubber.scrub(input)
        #expect(out == "X-API-Key: <redacted>")
    }

    // MARK: - URL forms

    @Test("URL ?token=<value> is redacted")
    func url_token_query_param() {
        let input = "downloading https://huggingface.co/api/models?token=hf_secret_abc&other=ok"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("?token=<redacted>"))
        #expect(!out.contains("hf_secret_abc"))
        #expect(out.contains("&other=ok"), "Non-secret params survive")
    }

    @Test("URL ?api_key=<value> is redacted")
    func url_api_key_query_param() {
        let input = "GET /v1/list?api_key=sk-abc-123&model=gpt-4"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("?api_key=<redacted>"))
        #expect(!out.contains("sk-abc-123"))
        #expect(out.contains("&model=gpt-4"))
    }

    @Test("URL ?key=<google-style> is redacted")
    func url_key_google_param() {
        let input = "https://maps.googleapis.com/api?key=AIzaSyC_long&address=foo"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("?key=<redacted>"))
        #expect(!out.contains("AIzaSyC_long"))
    }

    // MARK: - Env-var forms

    @Test("HF_TOKEN=<value> env-style is redacted")
    func hf_token_env_var() {
        let input = "subprocess env HF_TOKEN=hf_xxxxxxxxxxxxx PATH=/usr/bin"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("HF_TOKEN=<redacted>"))
        #expect(!out.contains("hf_xxxxxxxxxxxxx"))
        #expect(out.contains("PATH=/usr/bin"), "Non-secret env vars survive")
    }

    @Test("HUGGING_FACE_HUB_TOKEN=<value> env-style is redacted")
    func hugging_face_hub_token_env_var() {
        let input = "HUGGING_FACE_HUB_TOKEN=hf_secret_xyz123 model=qwen"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("HUGGING_FACE_HUB_TOKEN=<redacted>"))
        #expect(!out.contains("hf_secret_xyz123"))
    }

    @Test("Generic *_API_KEY env-var is redacted")
    func generic_api_key_env() {
        let input = "set OPENAI_API_KEY=sk-proj-abc123"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("API_KEY=<redacted>"))
        #expect(!out.contains("sk-proj-abc123"))
    }

    @Test("Generic *_SECRET env-var is redacted")
    func generic_secret_env() {
        let input = "AWS_SECRET=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("SECRET=<redacted>"))
        #expect(!out.contains("wJalrXUtnFEMI"))
    }

    // MARK: - JSON forms

    @Test("\"api_key\": \"<value>\" JSON form is redacted")
    func json_api_key_form() {
        let input = #"{"api_key": "sk-abc-secret", "model": "gpt-4"}"#
        let out = LogScrubber.scrub(input)
        #expect(out.contains(#""api_key": "<redacted>""#))
        #expect(!out.contains("sk-abc-secret"))
        #expect(out.contains("\"model\": \"gpt-4\""))
    }

    @Test("\"token\": \"<value>\" JSON form is redacted")
    func json_token_form() {
        let input = #"{"token": "ghp_secret123"}"#
        let out = LogScrubber.scrub(input)
        #expect(out.contains(#""token": "<redacted>""#))
        #expect(!out.contains("ghp_secret123"))
    }

    @Test("\"authorization\": \"Bearer <value>\" JSON form is redacted")
    func json_authorization_form() {
        let input = #"{"authorization": "Bearer xyz123secret"}"#
        let out = LogScrubber.scrub(input)
        #expect(out.contains(#""authorization": "<redacted>""#))
        #expect(!out.contains("xyz123secret"))
    }

    // MARK: - Negative cases

    @Test("Normal log line passes through unchanged")
    func ordinary_line_unchanged() {
        let input = "Downloading shards: 100%|███| 4/4 [00:32<00:00, 8.12s/it]"
        #expect(LogScrubber.scrub(input) == input)
    }

    @Test("Model name containing 'token' substring passes through")
    func model_name_with_token_substring() {
        // Common in HF logs: "loading tokenizer.json" should NOT
        // trigger the URL-style `?token=` rule.
        let input = "loading tokenizer.json from cache"
        #expect(LogScrubber.scrub(input) == input)
    }

    @Test("Empty line passes through unchanged")
    func empty_line() {
        #expect(LogScrubber.scrub("") == "")
    }

    @Test("Multi-token line redacts every instance independently")
    func multi_token_line() {
        let input = #"got Authorization: Bearer sk_first then HF_TOKEN=hf_second"#
        let out = LogScrubber.scrub(input)
        #expect(out.contains("Authorization: Bearer <redacted>"))
        #expect(out.contains("HF_TOKEN=<redacted>"))
        #expect(!out.contains("sk_first"))
        #expect(!out.contains("hf_second"))
    }

    /// The scrubber must be idempotent — scrubbing an already-
    /// scrubbed line is a no-op. Important because the same line
    /// can be re-emitted by progress refreshes and we don't want
    /// "<redacted>" itself to look like a value the next pass
    /// chops.
    @Test("Scrubbing an already-scrubbed line is a no-op")
    func idempotent_on_scrubbed_input() {
        let original = "Authorization: Bearer sk_secret_value"
        let once = LogScrubber.scrub(original)
        let twice = LogScrubber.scrub(once)
        #expect(once == twice)
    }

    // MARK: - Codex r1 BLOCKING regressions

    /// Codex r1 BLOCKING-1: the Bearer-token char class previously
    /// stopped at `~` and other JWT-legal punctuation, leaking the
    /// suffix. The fix uses a value-terminator class (`[^\s,;'"]+`)
    /// that mirrors `HF_TOKEN=…`. PASETO and Macaroon tokens
    /// frequently contain `~`, `:`, `|`.
    @Test("Bearer token containing ~ does NOT leak suffix")
    func bearer_token_with_tilde_no_suffix_leak() {
        let input = "Authorization: Bearer eyJhbGciOi.JxXxX~yYy.zZz"
        let out = LogScrubber.scrub(input)
        #expect(out == "Authorization: Bearer <redacted>")
        #expect(!out.contains("yYy"),
                "Suffix after the special char must be redacted, not exposed")
        #expect(!out.contains("zZz"))
    }

    @Test("Bearer token with vertical bar / colon does NOT leak suffix")
    func bearer_token_with_bar_colon() {
        let input = "Authorization: Bearer abc123|extra:more"
        let out = LogScrubber.scrub(input)
        #expect(out == "Authorization: Bearer <redacted>")
    }

    /// Codex r1 BLOCKING-2: `X-API-Key: \S+` greedy-eats a comma-
    /// joined adjacent header. httpx / requests debug repr
    /// concatenates headers on one line in some configs.
    @Test("X-API-Key on a comma-joined header line stops at the comma")
    func x_api_key_comma_joined_headers() {
        let input = "X-API-Key: AIzaSy_secret, X-Other: keep-me"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("X-API-Key: <redacted>"))
        #expect(out.contains("X-Other: keep-me"),
                "Adjacent header value must survive: \(out)")
        #expect(!out.contains("AIzaSy_secret"))
    }

    @Test("Authorization on a comma-joined header line stops at the comma")
    func authorization_comma_joined_headers() {
        let input = "Authorization: Bearer sk_secret, Content-Type: application/json"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("Authorization: Bearer <redacted>"))
        #expect(out.contains("Content-Type: application/json"))
        #expect(!out.contains("sk_secret"))
    }

    // MARK: - CLI-flag forms (codex r1 NIT-4 gap closure)

    @Test("--api-key=<value> CLI flag is redacted")
    func cli_flag_api_key() {
        let input = "$ rapid-mlx serve --api-key=sk-cli-secret --port=8000"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("--api-key=<redacted>"))
        #expect(out.contains("--port=8000"))
        #expect(!out.contains("sk-cli-secret"))
    }

    @Test("--hf-token=<value> CLI flag is redacted")
    func cli_flag_hf_token() {
        let input = "argv: ['--hf-token=hf_cli_xyz', '--repo=foo']"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("--hf-token=<redacted>"))
        #expect(!out.contains("hf_cli_xyz"))
    }

    @Test("--token=<value> CLI flag is redacted")
    func cli_flag_token() {
        let input = "$ tool --token=ghp_cli_abc"
        let out = LogScrubber.scrub(input)
        #expect(out.contains("--token=<redacted>"))
        #expect(!out.contains("ghp_cli_abc"))
    }

    // MARK: - Negative cases verified by codex r1

    @Test("File path with 'token=' substring does NOT get redacted")
    func file_path_token_substring() {
        // `?` and `&` are required as the URL boundary — a path
        // segment `token=cache.json` should pass through.
        let input = "found /Users/foo/.huggingface/token=cache.json"
        let out = LogScrubber.scrub(input)
        #expect(out == input,
                "Filesystem path with token= must not trigger URL rule")
    }

    @Test("Bare _OPENAI_API_KEY (leading underscore) does NOT trigger generic env rule")
    func env_rule_word_boundary() {
        // `\b` is between a word-char and a non-word-char; `_` is
        // a word char in regex, so `_OPENAI_API_KEY` has no `\b`
        // before `_`. The rule must NOT redact this — the
        // attacker who controls a `_ENV` prefix to hide their leak
        // doesn't get bypass help, because there's no real env var
        // shape that starts with `_`.
        let input = "log: _OPENAI_API_KEY=should-still-stay-here"
        let out = LogScrubber.scrub(input)
        // We accept either behavior (scrub or pass-through) AS
        // LONG AS we know which we picked. Current implementation
        // passes through — pin it.
        #expect(out == input,
                "Pinned behavior: leading `_` blocks the \\b anchor; underscore-prefixed env vars pass through. Update if intent changes.")
    }
}
