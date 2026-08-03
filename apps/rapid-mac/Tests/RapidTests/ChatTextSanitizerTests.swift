import Foundation
import Testing
@testable import Rapid

@Suite("ChatTextSanitizer")
struct ChatTextSanitizerTests {
    @Test("Removes bidi override and isolate controls")
    func removesBidiControls() {
        let raw = "invoice\u{202E}cod.exe\u{2066}safe\u{2069}"
        let sanitized = ChatTextSanitizer.sanitizeForDisplay(raw)
        #expect(sanitized == "invoicecod.exesafe")
        #expect(!sanitized.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2066 || $0.value == 0x2069 })
    }

    @Test("Removes non-printing controls but keeps transcript whitespace")
    func removesControlsButKeepsWhitespace() {
        let raw = "a\u{0000}b\u{001B}c\u{0085}d\re\n\tf"
        #expect(ChatTextSanitizer.sanitizeForDisplay(raw) == "abcd\ne\n\tf")
    }

    @Test("Pasteboard sanitization follows the display contract")
    func pasteboardSanitizationMatchesDisplay() {
        let raw = "copy\u{200F}\u{007F}me"
        #expect(ChatTextSanitizer.sanitizeForPasteboard(raw) == "copyme")
    }

    /// README "audit batch 11" promises bidi-character sanitisation on
    /// every transcript surface. The original suite covered three of
    /// the nine in-range bidi marks (U+202E, U+2066, U+2069). The
    /// production sanitiser strips them all via the codepoint ranges
    /// in ``ChatTextSanitizer.sanitizedScalar``. This test pins each
    /// codepoint individually so a refactor narrowing any range
    /// boundary (e.g. ``0x202A...0x202E`` → ``0x202B...0x202E``) goes
    /// red instead of silently re-exposing the homoglyph / "trojan
    /// source" attack vector.
    @Test("Every bidi-affecting codepoint is stripped — per-codepoint sweep")
    func everyBidiCodepointStripped() {
        let codepoints: [UInt32] = [
            0x061C,           // Arabic Letter Mark
            0x200E, 0x200F,   // Left-to-Right / Right-to-Left Mark
            0x202A, 0x202B,   // LRE / RLE (embedding)
            0x202C,           // PDF (pop directional formatting)
            0x202D, 0x202E,   // LRO / RLO (override — Trojan Source vector)
            0x2066, 0x2067,   // LRI / RLI (isolate)
            0x2068, 0x2069,   // FSI / PDI (isolate end)
        ]
        for cp in codepoints {
            guard let scalar = UnicodeScalar(cp) else {
                Issue.record("Failed to construct scalar for U+\(String(cp, radix: 16, uppercase: true))")
                continue
            }
            let raw = "a\(String(scalar))b"
            let sanitized = ChatTextSanitizer.sanitizeForDisplay(raw)
            #expect(
                sanitized == "ab",
                "Bidi codepoint U+\(String(cp, radix: 16, uppercase: true)) leaked through: \(Array(sanitized.unicodeScalars).map { String($0.value, radix: 16) })"
            )
        }
    }

    /// Pins the full C0 control-character range minus the documented
    /// allow-list (TAB U+0009, LF U+000A, CR U+000D — CR normalises to
    /// LF). U+0007 BEL, U+0008 BS, U+0019 EM etc. used to ride into
    /// the chat transcript inside LLM tool outputs and render as
    /// invisible / terminal-control side effects in pasted code
    /// blocks. README "audit batch 11" claims the sanitiser strips
    /// every transcript surface; pin the boundary explicitly so a
    /// refactor that rewrites the case as ``0x01...0x08, 0x0B...0x1F``
    /// (forgetting U+0000 NUL) doesn't silently regress.
    @Test("Every C0 control character except TAB/LF/CR is stripped")
    func c0ControlsStripped() {
        // CR (U+000D) is NOT in the stripped set — it's normalised
        // to LF. TAB (U+0009) and LF (U+000A) are kept verbatim.
        let preserved: Set<UInt32> = [0x09, 0x0A, 0x0D]
        for cp in UInt32(0x00)...UInt32(0x1F) where !preserved.contains(cp) {
            guard let scalar = UnicodeScalar(cp) else { continue }
            let raw = "a\(String(scalar))b"
            #expect(
                ChatTextSanitizer.sanitizeForDisplay(raw) == "ab",
                "C0 control U+\(String(cp, radix: 16, uppercase: true)) leaked through"
            )
        }
    }

    /// Pins the C1 / DEL range (U+007F-U+009F). These are
    /// non-printable on macOS but ride through copy-paste and JSON.
    /// We keep TAB/LF carved out one band lower; the C1 band is
    /// strip-all. The pasteboard test already covered U+007F as one
    /// case — this pins the full band so a refactor narrowing the
    /// range (e.g. ``0x7F...0x9E``) catches.
    @Test("Every C1 control character (U+007F through U+009F) is stripped")
    func c1ControlsStripped() {
        for cp in UInt32(0x7F)...UInt32(0x9F) {
            guard let scalar = UnicodeScalar(cp) else { continue }
            let raw = "a\(String(scalar))b"
            #expect(
                ChatTextSanitizer.sanitizeForDisplay(raw) == "ab",
                "C1 control U+\(String(cp, radix: 16, uppercase: true)) leaked through"
            )
        }
    }

    /// Pins the CR → LF normalisation. A lone ``\r`` (no LF
    /// following) used to render as a literal carriage return in
    /// SwiftUI ``Text`` — invisible glyph; subsequent characters
    /// would overstrike. We collapse it to LF so a Windows-style
    /// transcript paste renders as plain newlines.
    @Test("Lone CR (U+000D) becomes LF — not stripped, not preserved verbatim")
    func crNormalisesToLF() {
        #expect(ChatTextSanitizer.sanitizeForDisplay("line1\rline2") == "line1\nline2")
        // Pasteboard surface honours the same contract.
        #expect(ChatTextSanitizer.sanitizeForPasteboard("a\rb\rc") == "a\nb\nc")
        // CRLF (Windows-style paste): the per-scalar map turns
        // ``\r`` into ``\n`` and leaves the trailing ``\n``
        // verbatim, so the line ends up as a double newline. Pin
        // this explicitly so a refactor to "collapse \r\n to a
        // single \n" stays a conscious decision instead of a
        // silent behavioural change.
        #expect(ChatTextSanitizer.sanitizeForDisplay("line1\r\nline2") == "line1\n\nline2")
    }

    // MARK: - #296: Delta-safety + Memo

    /// The Memo class only works if ``sanitize`` is delta-safe:
    /// ``sanitize(a + b) == sanitize(a) + sanitize(b)`` for every
    /// (a, b). This test enumerates every shape we care about
    /// (control characters at the boundary, multi-byte UTF-8 split
    /// at the boundary, CR-LF straddle, bidi mark at the boundary)
    /// and pins the invariant. If this ever fails, the Memo class
    /// MUST be reverted — silent corruption of every streamed reply
    /// otherwise.
    @MainActor
    @Test("#296: sanitize is delta-safe — sanitize(a+b) == sanitize(a) + sanitize(b)")
    func sanitizeIsDeltaSafe() {
        let cases: [(String, String)] = [
            ("hello ", "world"),
            ("café ", "résumé"),
            ("\u{202E}flip", "ped"),
            ("line\r", "\nnext"),   // CRLF straddle
            ("control\u{0001}", "\u{0002}filtered"),
            ("a", "b"),
            ("", "anything"),
            ("anything", ""),
            ("\u{200E}", "\u{200F}"),
            ("\u{0009}\u{000A}", "kept"),
            // Emoji split mid-sequence (woman-running ZWJ sequence):
            // sanitize is per-scalar with no context, so the split
            // remains delta-safe. We don't claim "the rendered glyph
            // doesn't visually break" — only that bytes round-trip.
            ("🏃\u{200D}♀\u{FE0F}", "💨"),
        ]
        for (a, b) in cases {
            let joined = ChatTextSanitizer.sanitizeForDisplay(a + b)
            let split = ChatTextSanitizer.sanitizeForDisplay(a) + ChatTextSanitizer.sanitizeForDisplay(b)
            #expect(
                joined == split,
                "delta-safety violated for ('\(a)', '\(b)'): joined=\(joined) split=\(split)"
            )
        }
    }

    /// 256 random (a, b) pairs hammering the delta-safety invariant.
    /// Same contract as the targeted test above, but covers shapes
    /// no human curated. A failure here means the Memo class is
    /// unsound for some real-world stream.
    @MainActor
    @Test("#296: Memo delta-safety holds under 256 random splits")
    func memoDeltaSafetyRandom() {
        for seed: UInt64 in 0..<256 {
            var rng = SplitMix64(seed: 0xD17A_5AFE &+ seed)
            // Build a random raw of 0-256 bytes including control
            // characters and bidi marks so the per-scalar filter has
            // a non-trivial transform to perform.
            let n = Int(rng.next() % 256)
            var raw = ""
            for _ in 0..<n {
                let pick = rng.next() % 16
                switch pick {
                case 0: raw.append("\u{202E}")
                case 1: raw.append("\u{0001}")
                case 2: raw.append("\u{007F}")
                case 3: raw.append("\r")
                case 4: raw.append("\n")
                case 5: raw.append("\t")
                case 6: raw.append("é")
                case 7: raw.append("🎉")
                case 8: raw.append("中")
                default:
                    raw.append(Character(UnicodeScalar(UInt8((rng.next() % 95) + 32))))
                }
            }
            let splitAt = raw.utf8.count == 0 ? 0 : Int(rng.next() % UInt64(raw.utf8.count + 1))
            let bytes = Array(raw.utf8)
            // Snap to UTF-8 boundary by walking forward to the next
            // non-continuation byte so we don't split a multi-byte
            // codepoint mid-sequence (which String(decoding:) would
            // recover from but using the replacement character; the
            // delta-safety claim is at the codepoint level).
            var snap = splitAt
            while snap < bytes.count && (bytes[snap] & 0b1100_0000) == 0b1000_0000 {
                snap += 1
            }
            let aBytes = Array(bytes[..<snap])
            let bBytes = Array(bytes[snap...])
            let a = String(decoding: aBytes, as: UTF8.self)
            let b = String(decoding: bBytes, as: UTF8.self)
            let joined = ChatTextSanitizer.sanitizeForDisplay(a + b)
            let split = ChatTextSanitizer.sanitizeForDisplay(a) + ChatTextSanitizer.sanitizeForDisplay(b)
            #expect(joined == split, "delta-safety violated at seed=\(seed) snap=\(snap)")
        }
    }

    /// Per-flush sanitiser cost at a 20K-char buffer must be
    /// meaningfully cheaper through the memo than through the naive
    /// full-pass. Issue #296 measured 2.3 ms naive at 20K; the memo
    /// target is <230 µs per growing flush. On local dev the ratio
    /// runs 15-25x; the assertion below uses a conservative 5x
    /// floor (see the inline rationale).
    ///
    /// Methodology: simulate 60 coalescer flushes appending ~333
    /// chars each (typical streaming cadence — ~20 tokens/sec, each
    /// 1-4 chars, batched into a 16.67 ms flush). The naive baseline
    /// runs full-pass on every flush; the memo runs delta-pass on
    /// every flush. Compare cumulative wall.
    @MainActor
    @Test("#296: memo is >=5x cheaper than naive at 24K-char buffer (60 growing flushes)", .perfBudget)
    func memoCheaperThanNaiveAtScale() {
        // Build a representative streaming corpus: ASCII + occasional
        // control chars that exercise the filter.
        var rng = SplitMix64(seed: 0x5C0E)
        var chunks: [String] = []
        var totalLen = 0
        for _ in 0..<60 {
            let chunkLen = 400
            var chunk = ""
            for _ in 0..<chunkLen {
                let pick = rng.next() % 32
                if pick == 0 {
                    chunk.append("\u{202E}")
                } else if pick == 1 {
                    chunk.append("\r")
                } else {
                    chunk.append(Character(UnicodeScalar(UInt8((rng.next() % 95) + 32))))
                }
            }
            chunks.append(chunk)
            totalLen += chunk.count
        }
        precondition(totalLen >= 20_000, "test corpus too small to validate the perf claim")

        // Naive baseline: re-sanitise the full growing buffer per flush.
        var naiveBuffer = ""
        let naiveStart = ContinuousClock.now
        for chunk in chunks {
            naiveBuffer += chunk
            _ = ChatTextSanitizer.sanitizeForDisplay(naiveBuffer)
        }
        let naiveElapsed = ContinuousClock.now - naiveStart

        // Memo path: sanitise via Memo per flush.
        let memo = ChatTextSanitizer.Memo()
        var memoBuffer = ""
        let memoStart = ContinuousClock.now
        for chunk in chunks {
            memoBuffer += chunk
            _ = memo.sanitised(memoBuffer)
        }
        let memoElapsed = ContinuousClock.now - memoStart

        // ContinuousClock.Duration has (seconds: Int64, attoseconds: Int64).
        // Convert to nanoseconds via the rendered description rather than
        // hand-math so we don't have to reason about overflow.
        let naiveSec = Double(naiveElapsed.components.seconds)
            + Double(naiveElapsed.components.attoseconds) * 1e-18
        let memoSec = Double(memoElapsed.components.seconds)
            + Double(memoElapsed.components.attoseconds) * 1e-18
        let ratio = naiveSec / max(memoSec, 1e-12)

        // Codex r1 conservative floor: 5x in CI (the M1/M3 dev box
        // hits 15-25x; CI runners are noisier and the random byte
        // mix is harder to predict). Local dev runs should never
        // dip below 10x — if you see this ratio drop in CI, run on
        // a quieter machine first before changing the threshold.
        #expect(
            ratio >= 5.0,
            "memo not faster enough: ratio=\(ratio) naive_s=\(naiveSec) memo_s=\(memoSec)"
        )
    }

    /// Memo correctness: the streaming append path must reproduce
    /// exactly what a full sanitise produces at every step. Pins the
    /// memo's hot path (cache hit) against the naive output across a
    /// streaming sequence.
    @MainActor
    @Test("#296: Memo output matches naive sanitise at every growing step")
    func memoOutputMatchesNaiveStepwise() {
        let memo = ChatTextSanitizer.Memo()
        var buffer = ""
        let chunks = [
            "hello ",
            "wo\u{0001}rld ",
            "café ",
            "\u{202E}flipped",
            "\r\n",
            "trailing",
            "",
            "\u{0009}\u{000A}",
            "🎉",
        ]
        for chunk in chunks {
            buffer += chunk
            let memoOut = memo.sanitised(buffer)
            let naiveOut = ChatTextSanitizer.sanitizeForDisplay(buffer)
            #expect(memoOut == naiveOut, "memo drifted at buffer='\(buffer)'")
        }
    }

    /// Memo correctness on the SHRINK cold path: when the buffer
    /// shrinks (regenerate-from-here truncated), the memo MUST
    /// detect ``newCount < lastRawUtf8Count`` and run a full
    /// sanitise. Without the cold-path fallback the cached prefix
    /// would silently outweigh the new shorter raw and return
    /// stale output.
    @MainActor
    @Test("#296: Memo falls back to full sanitise when raw shrinks")
    func memoFallsBackOnShrink() {
        let memo = ChatTextSanitizer.Memo()
        _ = memo.sanitised("hello world how are you")
        let shrunk = memo.sanitised("hello")
        #expect(shrunk == "hello")
    }

    /// Caller-contract pin: when the source identity changes (the
    /// monotone-extension invariant breaks), the caller MUST call
    /// ``reset()``. The test pins both halves:
    ///   1. Calling without reset on a non-monotone shape produces
    ///      undefined output — we don't assert what (the contract
    ///      lets us trust monotonicity).
    ///   2. Calling AFTER ``reset()`` produces the correct output.
    /// In production SwiftUI usage the row tear-down on message-id
    /// change makes (2) implicit.
    @MainActor
    @Test("#296: Memo.reset is the caller affordance for non-monotonic replace")
    func memoResetIsRequiredForReplace() {
        let memo = ChatTextSanitizer.Memo()
        _ = memo.sanitised("first content")
        memo.reset()
        let replaced = memo.sanitised("goodbye\u{202E}flip")
        #expect(replaced == "goodbyeflip")
        let extended = memo.sanitised("goodbye\u{202E}flip and more")
        #expect(extended == "goodbyeflip and more")
    }

    /// Memo reset clears all internal state — used by the owning
    /// view when the underlying message id changes (regenerate,
    /// new session).
    @MainActor
    @Test("#296: Memo.reset clears the prefix cache")
    func memoResetClearsCache() {
        let memo = ChatTextSanitizer.Memo()
        _ = memo.sanitised("first message")
        memo.reset()
        let out = memo.sanitised("brand new content")
        #expect(out == "brand new content")
    }

    /// Pins that non-control, non-bidi characters pass through
    /// untouched: regular ASCII, multi-byte UTF-8, emoji, RTL script
    /// letters (Arabic / Hebrew — NOT the bidi marks). Sanitisation
    /// must NOT regress to a too-aggressive allow-list that would
    /// mangle international text.
    @Test("Sanitiser is content-preserving for legitimate Unicode")
    func legitimateUnicodePassesThrough() {
        let inputs: [String] = [
            "Hello, world!",
            "café résumé naïve",
            "你好，世界",
            "こんにちは世界",        // Japanese (Hiragana + Kanji)
            "안녕하세요 세계",        // Korean (Hangul)
            "Привет мир",             // Russian (Cyrillic)
            "नमस्ते दुनिया",            // Hindi (Devanagari)
            "مرحبا بالعالم",          // Arabic
            "שלום עולם",              // Hebrew
            "🎉🚀🌍",                // Emoji
            "x²+y²=z²",               // Math symbols
            "e\u{0301}",              // Combining acute accent (decomposed é)
            "naïve cafe\u{0301}",     // Mixed decomposed + precomposed
        ]
        for input in inputs {
            #expect(
                ChatTextSanitizer.sanitizeForDisplay(input) == input,
                "Legitimate text was mangled: \(input)"
            )
            #expect(
                ChatTextSanitizer.sanitizeForPasteboard(input) == input,
                "Pasteboard mangled: \(input)"
            )
        }
    }
}
