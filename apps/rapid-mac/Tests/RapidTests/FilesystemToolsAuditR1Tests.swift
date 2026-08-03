import Foundation
import Testing
@testable import Rapid

/// Contracts added by the codex audit batch 6 sweep of
/// ``FilesystemTools``. Two security-sensitive surfaces:
///
///   * ``isPathBlocked`` must catch every spelling of the
///     sensitive paths it documents (codex finding P2: ``/dev``
///     vs ``/dev/`` trailing-slash bypass, ``/private/etc/passwd``
///     missed because canonical equals lexical when there's no
///     symlink to resolve).
///   * ``utf8SafePrefix`` must trim at a valid UTF-8 boundary so
///     a hard cap on the file-read window does not cause a clean
///     multi-byte file to fail UTF-8 decode (codex finding P3).
@Suite("FilesystemTools audit r1 contracts")
struct FilesystemToolsAuditR1Tests {

    // MARK: - Blocklist (codex finding P2)

    @Test("Blocklist catches /dev and /dev/zero (trailing-slash bypass closed)")
    func blocklistCatchesDev() {
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/dev")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/dev/zero")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/dev/random")))
    }

    @Test("Blocklist catches /Library/Keychains and a child file")
    func blocklistCatchesUserKeychains() {
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/Library/Keychains")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/Library/Keychains/System.keychain")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/System/Library/Keychains")))
    }

    @Test("Blocklist catches both /etc/passwd AND direct /private/etc/passwd")
    func blocklistCatchesPasswdSpellings() {
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/etc/passwd")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/etc/sudoers")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/etc/master.passwd")))
        // Pre-audit gap: a model that asked for /private/etc/passwd
        // directly bypassed the lexical/canonical comparison because
        // no symlink resolution was needed.
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/private/etc/passwd")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/private/etc/sudoers")))
        #expect(FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/private/etc/master.passwd")))
    }

    @Test("Blocklist does NOT block a sibling whose name shares a prefix")
    func blocklistDoesNotOverreach() {
        // /Library/Keychainsabc must not match /Library/Keychains —
        // the hasPrefix("/Library/Keychains/") check guards against
        // this exact spelling.
        #expect(!FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/Library/KeychainsExtra")))
        #expect(!FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/dev0")))
        #expect(!FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/etc/passwd_backup")))
    }

    @Test("Blocklist passes ordinary user paths")
    func blocklistAllowsUserPaths() {
        #expect(!FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/Users/raullen/Documents/notes.md")))
        #expect(!FilesystemTools.isPathBlocked(URL(fileURLWithPath: "/tmp/scratch.txt")))
    }

    // MARK: - utf8SafePrefix (codex finding P3)

    @Test("Pure ASCII input returns the first maxBytes bytes")
    func utf8SafePrefixASCII() {
        let data = Data("hello world".utf8)
        let result = FilesystemTools.utf8SafePrefix(of: data, maxBytes: 5)
        #expect(String(data: result, encoding: .utf8) == "hello")
    }

    @Test("Cutting mid-codepoint backs up to the boundary so UTF-8 decode succeeds")
    func utf8SafePrefixBacksUpToBoundary() {
        // "héllo" — "é" is 0xC3 0xA9 in UTF-8. Cap at 2 bytes
        // would land MID-codepoint without the helper.
        let data = Data("héllo".utf8)
        // Total bytes: h(1) + é(2) + l(1) + l(1) + o(1) = 6
        // Cap at 2: pre-audit shape would return "h" + 0xC3
        //   → String(data:encoding:.utf8) == nil → "file is not UTF-8".
        // With the helper, we back off to just "h" (1 byte).
        let result = FilesystemTools.utf8SafePrefix(of: data, maxBytes: 2)
        let decoded = String(data: result, encoding: .utf8)
        #expect(decoded != nil, "trimmed prefix must be valid UTF-8")
        #expect(decoded == "h")
    }

    @Test("4-byte emoji codepoint cut mid-sequence backs up cleanly")
    func utf8SafePrefixHandlesEmoji() {
        // "a😀" — 😀 is 0xF0 0x9F 0x98 0x80 (4 bytes).
        let data = Data("a😀".utf8)
        // Cap at 3: pre-audit shape would return "a" + 0xF0 + 0x9F
        //   → not valid UTF-8.
        let result = FilesystemTools.utf8SafePrefix(of: data, maxBytes: 3)
        let decoded = String(data: result, encoding: .utf8)
        #expect(decoded != nil)
        #expect(decoded == "a")
    }

    @Test("Cap exactly on codepoint boundary doesn't lose the codepoint")
    func utf8SafePrefixCapOnBoundary() {
        let data = Data("héllo".utf8) // bytes: h é(2) l l o
        // Cap at 3 lands right after "é" — both bytes inside.
        let result = FilesystemTools.utf8SafePrefix(of: data, maxBytes: 3)
        let decoded = String(data: result, encoding: .utf8)
        #expect(decoded == "hé")
    }

    @Test("Input smaller than maxBytes returns the full data unchanged")
    func utf8SafePrefixSmallerThanCap() {
        let data = Data("hi".utf8)
        let result = FilesystemTools.utf8SafePrefix(of: data, maxBytes: 64)
        #expect(result == data)
    }
}
