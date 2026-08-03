import Foundation
import Testing
@testable import Rapid

/// Issue #17 desktop-half contract:
/// - Each call returns a fresh 64-char hex string (32 random bytes).
/// - No two consecutive calls return the same secret in a
///   non-pathological RNG state.
/// - Output is strictly ``[0-9a-f]`` so it can be embedded in env
///   without quoting / escaping and round-trips through an
///   ``Authorization: Bearer`` header byte-for-byte.
@Suite("BearerSecret (issue #17)")
struct BearerSecretTests {

    @Test("generate() returns a 64-character lowercase-hex string")
    func generateShape() throws {
        let s = try #require(BearerSecret.generate(),
                             "SecRandomCopyBytes must succeed on a healthy macOS install")
        #expect(s.count == 64, "32 bytes hex-encoded is 64 chars; got \(s.count)")
        let hexChars: Set<Character> = Set("0123456789abcdef")
        for c in s {
            #expect(hexChars.contains(c), "non-hex character \(c) in secret \(s)")
        }
    }

    @Test("consecutive generate() calls return distinct values")
    func generateNonRepeating() throws {
        // 32 random bytes = 256 bits of entropy; collision in two
        // consecutive calls would require a broken RNG, not bad
        // luck. We sample a few to guard against a trivial
        // "constant string" regression.
        let a = try #require(BearerSecret.generate())
        let b = try #require(BearerSecret.generate())
        let c = try #require(BearerSecret.generate())
        #expect(a != b, "generate must vary between calls; got \(a) twice")
        #expect(b != c, "generate must vary between calls; got \(b) twice")
        #expect(a != c, "generate must vary between calls; got \(a) twice")
    }

    @Test("generate() is suitable for an Authorization: Bearer header byte-for-byte")
    func generateIsHeaderSafe() throws {
        let s = try #require(BearerSecret.generate())
        // RFC 7235 token68 grammar: a Bearer credential must be
        // limited to ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" /
        // "/" / "=" (optional padding). Lowercase hex sits inside
        // ALPHA + DIGIT so we can drop the secret straight into the
        // header value without any escaping.
        let allowed: Set<Character> = Set("0123456789abcdefABCDEF")
        for c in s {
            #expect(allowed.contains(c),
                    "secret must stay inside header-safe token68 alphabet; got \(c)")
        }
    }

    /// Issue #305 regression pin. The pre-v0.7.19 doc comment claimed
    /// env-vs-argv delivery defeats the threat model the bearer was
    /// supposed to address. That is false on macOS: ``ps eww <pid>``
    /// reads env of any same-UID process, and the same-UID processes
    /// the bearer is supposed to defend against (sandbox-escaped
    /// browser tab, helper script, curious Python script) can read
    /// either channel trivially. The corrected comment lives inline
    /// in ``BearerSecret.swift``; this test pins it stays corrected
    /// so a future doc-comment shuffle does not silently restore the
    /// misleading "would leak in ps" framing.
    ///
    /// We grep the source file rather than asserting on any runtime
    /// behaviour: the comment change is doc-only (PR #305 #224 does
    /// NOT change the env-vs-argv delivery mechanism — the full
    /// hardening is gated on issue #303).
    @Test("BearerSecret.swift no longer claims env-vs-argv defeats same-UID readers (issue #305)")
    func bearerSecretDocCommentIsHonest() throws {
        // ``#filePath`` resolves to this test file's absolute path.
        // Walk up to the repo root and reach into the source tree;
        // ``Bundle.module`` would copy the source at build time which
        // is wrong here (we want the live source, not a snapshot).
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent() // RapidTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("Sources/Rapid/Server/BearerSecret.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // The single load-bearing string the corrected comment must
        // never contain again. Kept narrow so this test fires on the
        // specific regression (someone re-adding the false "argv
        // would leak in ps" framing) and not on every nearby edit.
        #expect(!source.contains("would leak in ps"),
                "Issue #305: doc comment must not claim env-vs-argv beats ps; ps eww <pid> reads env of any same-UID process on macOS")

        // Positive pins covering the corrected semantics. These three
        // facts about ``ps`` on macOS are what the SECURITY NOTE has
        // to convey for the bearer's real risk profile to read
        // correctly:
        //   1. argv is exposed to ANY user via ``ps -axww`` (no UID
        //      check before adv_cmds prints kp_proc.p_args).
        //   2. env is gated by ``ps eww`` to ``root`` or same-UID
        //      readers only. This is the asymmetry that makes
        //      env-vs-argv a real (narrow) win cross-UID — and
        //      simultaneously useless against same-UID attackers.
        //   3. The bearer's stated threat model — a same-UID
        //      sandbox-escape / helper script / Python script — is
        //      still NOT defeated by env delivery alone.
        // We assert that the SECURITY NOTE block exists and names
        // both ``ps -axww`` (argv) and ``ps eww`` (env). The previous
        // version of this test only pinned ``ps eww``, which would
        // have let a future doc shuffle silently delete the argv
        // half of the asymmetry.
        #expect(source.contains("SECURITY NOTE"),
                "Issue #305: BearerSecret.swift must keep the SECURITY NOTE block so future readers see the env-vs-argv caveat")
        #expect(source.contains("ps eww"),
                "Issue #305: SECURITY NOTE must name `ps eww` — that's the concrete same-UID env reader users need to be warned about, and the gating call that makes env beat argv cross-UID")
        #expect(source.contains("ps -axww"),
                "Issue #305: SECURITY NOTE must name `ps -axww` — the asymmetry between `ps -axww` (argv, any user) and `ps eww` (env, same-UID/root) is the WHOLE reason env delivery has a narrow security benefit; dropping the argv half regresses the comment to a vague claim")
        // Pin the load-bearing same-UID caveat phrasing in either
        // direction so a future rewrite cannot quietly delete the
        // "same-UID readers still win" warning that the prior comment
        // was missing.
        #expect(source.localizedCaseInsensitiveContains("same-uid"),
                "Issue #305: SECURITY NOTE must spell out that env-vs-argv does NOT defeat same-UID readers — that caveat is the actual fix for the previous misleading comment")
    }
}
