import Foundation
@testable import Rapid

// MARK: - Reproducible RNG

/// SplitMix64 — small, fast, deterministic. Seed is a UInt64; the
/// stream is reproducible across processes / Macs / Swift versions
/// (unlike ``SystemRandomNumberGenerator``). When a fuzz iteration
/// fails we want the seed so the regression can be replayed in the
/// fixed-seed suite.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the 0-state degenerate by mixing in a magic constant.
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Adversarial title corpus

/// Curated adversarial titles. Hit every category called out in the
/// fuzz brief: path traversal, ZIP-slip, markdown/HTML injection,
/// control chars, Unicode pathologies, length extremes.
enum AdversarialTitles {
    static let path: [String] = [
        "../../etc/passwd",
        "\\..\\..\\windows\\system32",
        "sessions/../../escape",
        "../../slip",
        "/absolute/slip",
        "/etc/passwd",
        "C:\\Windows\\System32\\config",
        "../../../../tmp/pwn",
    ]

    static let markdownInjection: [String] = [
        "<script>alert(1)</script>",
        "](javascript:alert(1))",
        "[click](https://attacker.example)",
        "` * _ # | [",
        "# H1\n## H2\n### H3",
        "```\ncode\n```",
        "<details open><summary>oops</summary>injected</details>",
        "> blockquote",
        "<!-- HTML comment -->",
        "<img src=x onerror=alert(1)>",
    ]

    static let controlChars: [String] = {
        // Every C0 codepoint individually + a triple-mixed string.
        var out: [String] = []
        for v in 0..<32 {
            let s = UnicodeScalar(v)!
            out.append("a\(Character(s))b")
        }
        out.append("a\u{00}b\u{0a}\u{0d}\u{08}\u{1b}c")
        out.append("null\u{00}byte\u{00}sandwich")
        return out
    }()

    static let lengthExtremes: [String] = [
        "",
        "   ",
        "\t\n",
        "\u{200b}\u{200c}", // zero-width
        String(repeating: "a", count: 64 * 1024),
        String(repeating: "Z", count: 256 * 1024),
        // Single very long Unicode-rich string.
        String(repeating: "🎉", count: 4096),
    ]

    /// Subset of length extremes safe for the bulk-zip stress runs
    /// (25 archives × 20 sessions). Drops the 256 KB title because
    /// repeating it across hundreds of sessions would push the archive
    /// into the multi-MB range for no extra coverage value — the 64 KB
    /// case + the markdown-only 256 KB case already cover the long-
    /// title regression.
    static let lengthExtremesBulkSafe: [String] = [
        "",
        "   ",
        "\t\n",
        "\u{200b}\u{200c}",
        String(repeating: "a", count: 4 * 1024),
        String(repeating: "🎉", count: 256),
    ]

    static let unicodeEdge: [String] = [
        // Lone surrogates can't appear in well-formed Swift strings
        // (the runtime replaces them with U+FFFD), but we still
        // exercise the replacement path explicitly.
        "\u{FFFD}lonely",
        "\u{202E}RTL-flip\u{202D}",  // RTL override + override pop
        "naïve",                       // combining diacritic
        "n\u{0303}aive",               // explicit decomposed form
        "👨‍👩‍👧‍👦 family ZWJ",
        "Caf\u{00E9}", // NFC
        "Cafe\u{0301}", // NFD — should hash differently from NFC
        "𝐀𝐁𝐂",   // mathematical bold
        "\u{200B}invisible\u{200B}",
        "\u{FEFF}BOM-leading",
    ]

    /// Combined corpus the per-iteration fuzz dips into.
    static let all: [String] = path
        + markdownInjection
        + controlChars
        + lengthExtremes
        + unicodeEdge

    /// Subset that's safe to use as a session title in bulk-ZIP runs
    /// (we want to push lots of these through but a 256 KB title
    /// would make 1000 sessions ≈ 256 MB on its own — keep the
    /// extreme-length entries to the smaller bulk_zip stress cases).
    static let bulkSafe: [String] = path
        + markdownInjection
        + controlChars
        + unicodeEdge
        + ["", "   ", "\t\n", "\u{200b}\u{200c}"]
}

// MARK: - Random session generator

/// Build a randomised session for the fuzz harness. Every field is
/// either drawn from an adversarial pool or a seeded random sample.
enum FuzzSessionFactory {

    static func makeSession(
        rng: inout SplitMix64,
        maxMessages: Int = 64,
        maxContentBytes: Int = 8 * 1024,
        // When true, length extremes draw from
        // ``AdversarialTitles.lengthExtremesBulkSafe`` (max 4 KB title)
        // so bulk-zip test totals stay bounded.
        bulkSafe: Bool = false
    ) -> ChatSession {
        let title = bulkSafe
            ? randomTitleBulkSafe(rng: &rng)
            : randomTitle(rng: &rng)
        let alias = randomAlias(rng: &rng)
        let count = Int(rng.next() % UInt64(maxMessages + 1))
        var messages: [ChatMessage] = []
        for _ in 0..<count {
            messages.append(makeMessage(rng: &rng, maxContentBytes: maxContentBytes))
        }
        // Millisecond-grid jitter ensures the JSON-round-trip fuzz
        // actually exercises the fractional-precision path the #289 fix
        // landed. Whole-second-only factory output was why the 1000-iter
        // fuzz didn't catch the regression in the first place. Dates
        // are snapped to the millisecond grid via
        // ``msecGridDate(rng:)`` so they survive bit-for-bit through
        // ``ISO8601DateFormatter`` with ``.withFractionalSeconds`` (3
        // decimal digits) — a sub-ms jitter would quantize on encode
        // and make the Equatable round-trip spuriously fail.
        let createdAt = msecGridDate(rng: &rng)
        let updatedAt = msecGridDate(rng: &rng, base: createdAt)
        let isPinned = (rng.next() & 1) == 1
        let systemPrompt: String? = ((rng.next() & 7) == 0)
            ? randomSystemPrompt(rng: &rng)
            : nil
        return ChatSession(
            id: UUID(),
            title: title,
            alias: alias,
            messages: messages,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            systemPrompt: systemPrompt
        )
    }

    static func makeMessage(
        rng: inout SplitMix64,
        maxContentBytes: Int = 8 * 1024
    ) -> ChatMessage {
        let role: ChatMessage.Role
        switch rng.next() % 4 {
        case 0: role = .user
        case 1: role = .assistant
        case 2: role = .system
        default: role = .tool
        }
        let contentLen = Int(rng.next() % UInt64(maxContentBytes + 1))
        let content = randomString(rng: &rng, byteCount: contentLen)
        let reasoningLen = Int(rng.next() % UInt64(min(maxContentBytes, 2048) + 1))
        let reasoning = randomString(rng: &rng, byteCount: reasoningLen)
        let status: ChatMessage.Status
        switch rng.next() % 3 {
        case 0: status = .complete
        case 1: status = .streaming
        default: status = .failed
        }
        let errorMessage: String? = ((rng.next() & 3) == 0)
            ? randomErrorMessage(rng: &rng)
            : nil
        let toolCalls: [ToolCall]? = ((rng.next() & 3) == 0)
            ? randomToolCalls(rng: &rng)
            : nil
        let toolCallID: String? = (role == .tool) ? "tc-\(rng.next() % 100)" : nil
        let attachments: [Attachment]? = (role == .user && (rng.next() & 3) == 0)
            ? randomAttachments(rng: &rng)
            : nil
        let stats: MessageStats? = ((rng.next() & 1) == 0)
            ? randomStats(rng: &rng)
            : nil
        let createdAt = msecGridDate(rng: &rng)
        return ChatMessage(
            id: UUID(),
            role: role,
            content: content,
            reasoning: reasoning,
            status: status,
            errorMessage: errorMessage,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            attachments: attachments,
            stats: stats,
            createdAt: createdAt
        )
    }

    /// Return a ``Date`` on the millisecond grid — the precision
    /// ``ISO8601DateFormatter`` with ``.withFractionalSeconds`` writes,
    /// so the round-trip is bit-for-bit lossless. Encoded as the
    /// integer count of milliseconds since the epoch and then divided
    /// by 1000 so the result is one of the finite ms-grid values the
    /// formatter can reproduce exactly.
    ///
    /// ``base`` (optional) anchors the new date a random number of
    /// hours-plus-ms from a starting point — handy for the
    /// ``updatedAt`` field whose contract is "after ``createdAt``".
    static func msecGridDate(
        rng: inout SplitMix64,
        base: Date? = nil
    ) -> Date {
        // Build an integer ms-since-epoch value then divide once at
        // the very end so the float is on the ms grid.
        let baseMs: Int64
        if let base {
            // ``Int64(_:)`` truncates toward zero; for a ms-grid
            // ``base`` whose float representation is slightly below the
            // exact ms value (IEEE 754 quantization) the truncation can
            // round down by 1 ms and silently put ``updatedAt`` AT (or
            // even before) ``createdAt`` when jitter is zero. ``rounded()``
            // snaps to the nearest representable ms first.
            baseMs = Int64((base.timeIntervalSince1970 * 1000.0).rounded())
        } else {
            baseMs = Int64(rng.next() % 2_000_000_000) * 1000
        }
        // ``updatedAt`` should land STRICTLY after ``createdAt`` when a
        // ``base`` is supplied; force at least 1 ms of separation so the
        // contract holds without leaning on the jitter draw.
        let minJitter: Int64 = (base != nil) ? 1 : 0
        let jitterMs = Int64(rng.next() % UInt64(86_400 * 1000)) + minJitter
        let total = baseMs &+ jitterMs
        return Date(timeIntervalSince1970: TimeInterval(total) / 1000.0)
    }

    static func randomTitle(rng: inout SplitMix64) -> String {
        // 50% draw from the adversarial corpus, 50% random ASCII to
        // give the encoder a healthy mix of nominal + hostile inputs.
        // Roughly 5% of the corpus draws hit a length extreme (zero-
        // width, 64 KB, 256 KB, emoji-heavy) so a regression in
        // Markdown / JSON / ZIP-stem handling for long titles
        // surfaces (codex r1 MAJOR — extremes were defined but never
        // sampled).
        let bucket = rng.next() % 100
        if bucket < 5 {
            let idx = Int(rng.next() % UInt64(AdversarialTitles.lengthExtremes.count))
            return AdversarialTitles.lengthExtremes[idx]
        }
        if bucket < 50 {
            let idx = Int(rng.next() % UInt64(AdversarialTitles.bulkSafe.count))
            return AdversarialTitles.bulkSafe[idx]
        }
        let len = Int(rng.next() % 200)
        return randomString(rng: &rng, byteCount: len)
    }

    /// Same shape as ``randomTitle`` but pulls extremes from the
    /// bulk-safe pool (max 4 KB titles) so a 25-archive × 20-session
    /// bulk-zip run doesn't blow up to hundreds of MB on title bytes
    /// alone.
    static func randomTitleBulkSafe(rng: inout SplitMix64) -> String {
        let bucket = rng.next() % 100
        if bucket < 5 {
            let idx = Int(rng.next() % UInt64(AdversarialTitles.lengthExtremesBulkSafe.count))
            return AdversarialTitles.lengthExtremesBulkSafe[idx]
        }
        if bucket < 50 {
            let idx = Int(rng.next() % UInt64(AdversarialTitles.bulkSafe.count))
            return AdversarialTitles.bulkSafe[idx]
        }
        let len = Int(rng.next() % 200)
        return randomString(rng: &rng, byteCount: len)
    }

    static func randomAlias(rng: inout SplitMix64) -> String {
        let aliases = [
            "qwen3.5-4b",
            "qwen3.6-27b",
            "gemma3-1b-qat-4bit",
            "gpt-oss-20b",
            // Hostile alias name — same metacharacters as the title corpus.
            "[evil](attacker)",
            "# alias",
            "alias\u{202E}flip",
        ]
        let idx = Int(rng.next() % UInt64(aliases.count))
        return aliases[idx]
    }

    static func randomSystemPrompt(rng: inout SplitMix64) -> String {
        let len = Int(rng.next() % 512)
        return randomString(rng: &rng, byteCount: len)
    }

    static func randomErrorMessage(rng: inout SplitMix64) -> String {
        let pool = [
            "Network error",
            "ENOSPC: disk full",
            "> error with > quote",
            "error\nwith\nmultiple\nlines",
            "error with \u{202E} bidi",
            "<details>nested</details>",
        ]
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    static func randomToolCalls(rng: inout SplitMix64) -> [ToolCall] {
        let count = Int(rng.next() % 4) + 1
        var calls: [ToolCall] = []
        let names = [
            "web_search",
            "calculator",
            "[evil](attacker)",
            "# heading",
            "name\u{202E}flip",
            "unicode\u{0000}null",
        ]
        for i in 0..<count {
            let nameIdx = Int(rng.next() % UInt64(names.count))
            // Randomly-mangled JSON-string arguments. Garbage bytes
            // are allowed — the wire shape is "opaque JSON-string".
            let argLen = Int(rng.next() % 256)
            let args = randomString(rng: &rng, byteCount: argLen)
            calls.append(ToolCall(id: "tc-\(i)", name: names[nameIdx], arguments: args))
        }
        return calls
    }

    static func randomAttachments(rng: inout SplitMix64) -> [Attachment] {
        let count = Int(rng.next() % 3) + 1
        var atts: [Attachment] = []
        let filenames = AdversarialTitles.path + AdversarialTitles.markdownInjection
        for _ in 0..<count {
            let nameIdx = Int(rng.next() % UInt64(filenames.count))
            let kind: Attachment.Kind = ((rng.next() & 1) == 0) ? .image : .textFile
            atts.append(Attachment(
                kind: kind,
                filename: filenames[nameIdx],
                mime: kind == .image ? "image/png" : "text/plain",
                body: "sha256:" + String(repeating: "ab", count: 32),
                sizeBytes: Int(rng.next() % 4_194_304)
            ))
        }
        return atts
    }

    static func randomStats(rng: inout SplitMix64) -> MessageStats {
        MessageStats(
            elapsedSeconds: Double(rng.next() % 10_000) / 100.0,
            charCount: Int(rng.next() % 50_000),
            promptTokens: ((rng.next() & 1) == 0) ? Int(rng.next() % 10_000) : nil,
            completionTokens: ((rng.next() & 1) == 0) ? Int(rng.next() % 10_000) : nil
        )
    }

    /// Build a UTF-8-safe random string of approximately ``byteCount``
    /// bytes by drawing ASCII bytes + occasional Unicode scalars. The
    /// resulting Swift String is always well-formed UTF-8 — Swift
    /// strings can't carry invalid UTF-8 — but the content is
    /// adversarial-flavoured.
    static func randomString(rng: inout SplitMix64, byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        var out = ""
        out.reserveCapacity(byteCount)
        var remaining = byteCount
        while remaining > 0 {
            let r = rng.next()
            switch r % 8 {
            case 0:
                // ASCII printable
                out.append(Character(UnicodeScalar(UInt8(33 + (r >> 8) % 94))))
                remaining -= 1
            case 1:
                // Control char (lots — these are what we want to stress)
                let v = UInt32((r >> 8) % 32)
                out.append(Character(UnicodeScalar(v)!))
                remaining -= 1
            case 2:
                // Backtick / asterisk / hash (markdown metacharacters)
                let chars: [Character] = ["`", "*", "_", "#", "[", "]", "<", ">", "\\", "|"]
                out.append(chars[Int((r >> 8) % UInt64(chars.count))])
                remaining -= 1
            case 3:
                // Newline / whitespace
                let chars: [Character] = ["\n", "\r", "\t", " "]
                out.append(chars[Int((r >> 8) % 4)])
                remaining -= 1
            case 4:
                // ZWJ / BOM / RTL family
                let scalars: [UInt32] = [
                    0x200B, 0x200C, 0x200D, 0xFEFF,
                    0x202E, 0x202D, 0x200E, 0x200F,
                    0x2066, 0x2069,
                ]
                let v = scalars[Int((r >> 8) % UInt64(scalars.count))]
                if let s = UnicodeScalar(v) { out.append(Character(s)) }
                remaining -= 3
            case 5:
                // Emoji ZWJ snippet — these stress grapheme handling.
                out.append("👨‍👩‍👧‍👦")
                remaining -= 25
            case 6:
                // Code-fence-shaped chunk.
                out.append("```")
                remaining -= 3
            default:
                // HTML-tag-shaped chunk.
                out.append("<details>")
                remaining -= 9
            }
        }
        return out
    }
}

// MARK: - Helpers

/// Wrap a try-block and report the seed on throw so a fuzz failure
/// can be reproduced from the recorded seed.
@discardableResult
func captureFailure<T>(
    seed: UInt64,
    iteration: Int,
    label: String,
    _ block: () throws -> T
) rethrows -> T {
    do {
        return try block()
    } catch {
        // Surface the seed so the regression can be reproduced.
        FileHandle.standardError.write(Data(
            "FUZZ FAILURE in \(label) at iteration \(iteration) (seed=\(seed)): \(error)\n".utf8
        ))
        throw error
    }
}
