import Testing
import SwiftUI
@testable import Rapid

/// Audit P1 (ChatView — no dynamic-type testing; >extraLarge may
/// overflow compose / crush bubbles): the chat-surface clamp lives
/// in ``Sources/Rapid/UI/Modifiers/DynamicTypeClamp.swift``. These
/// tests pin the contract of ``chatDynamicTypeRange`` so a future
/// rename / wider-cap edit can't silently re-open the bug.
///
/// We can't introspect the SwiftUI view tree to check that ChatView
/// has actually applied the modifier (SwiftUI's ``Modifier`` types
/// aren't reflectable), so the wiring side is enforced by code-
/// review + the call-site `// Audit P1` comments. The constant
/// itself is fully unit-testable here.
@Suite("DynamicTypeClamp")
struct DynamicTypeClampTests {

    @Test("upper bound is xxxLarge — last non-accessibility size")
    func upper_bound_is_xxxLarge() {
        #expect(chatDynamicTypeRange.upperBound == .xxxLarge)
    }

    @Test("clamp admits the seven non-accessibility sizes")
    func clamp_admits_non_accessibility_sizes() {
        let allowed: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
        ]
        for size in allowed {
            #expect(
                chatDynamicTypeRange.contains(size),
                "\(size) should be inside the chat-surface range"
            )
        }
    }

    @Test("clamp excludes all five accessibility sizes (AX1–AX5)")
    func clamp_excludes_accessibility_sizes() {
        let blocked: [DynamicTypeSize] = [
            .accessibility1,
            .accessibility2,
            .accessibility3,
            .accessibility4,
            .accessibility5,
        ]
        for size in blocked {
            #expect(
                !chatDynamicTypeRange.contains(size),
                "\(size) should be outside the chat-surface range"
            )
        }
    }

    @Test("range lower bound is xSmall — system minimum")
    func range_lower_bound_is_xSmall() {
        // ClosedRange built from `...xxxLarge` starts at the type's
        // ``min``. DynamicTypeSize.allCases is ordered xSmall first,
        // so the lower bound must match that minimum — and never
        // accidentally float above it (e.g. someone editing the
        // range to `.large ... .xxxLarge` would break users on
        // smaller defaults).
        #expect(chatDynamicTypeRange.lowerBound == .xSmall)
    }

    @Test(".rapidChatDynamicTypeClamp() builds without crashing")
    @MainActor
    func modifier_applies_without_crash() {
        // SwiftUI environment modifiers can't be introspected, but we
        // can at least prove the helper is syntactically valid and
        // type-checks against an arbitrary view. A regression that
        // removed the extension on `View` would fail this build —
        // which is exactly the breakage we want surfaced loudly.
        // `View` is MainActor-isolated under Swift 6, so the wrapper
        // call has to run on the main actor too.
        let _ = Text("test").rapidChatDynamicTypeClamp()
    }

    /// Pin the wiring per call-site, not just per file. Codex r1
    /// BLOCKING-1 flagged that a per-file existence check would pass
    /// even if the critical compose/transcript clamps were deleted.
    /// Codex r2 residual: the per-file form was strengthened to
    /// per-anchor — each chat surface declares a minimum set of
    /// anchor lines that MUST carry the clamp, so deleting any of
    /// them surfaces here. The anchors track the live user-text
    /// rails (transcript, composeBar, transcriptArea) — the lines
    /// where dropping the clamp regresses the bubble/compose audit.
    @Test("clamp is wired at every required anchor on every chat surface")
    func clamp_is_wired_at_every_anchor() throws {
        let packageRoot = try Self.findPackageRoot()
        struct Anchor {
            let relativePath: String
            let requiredCallSites: [String]
        }
        let anchors: [Anchor] = [
            // ChatView's clamp must guard the message transcript, search
            // bar, and compose bar. The system-prompt action moved into
            // ContentView's fixed top toolbar and no longer renders a
            // user-authored prompt rail inside ChatView.
            Anchor(
                relativePath: "Sources/Rapid/UI/ChatView.swift",
                requiredCallSites: [
                    "searchBar\n                .rapidChatDynamicTypeClamp()",
                    "transcript\n                .rapidChatDynamicTypeClamp()",
                    // #459 follow-up: composeBar (and the banner stack) moved
                    // into a bottom `safeAreaInset` on the transcript, so the
                    // clamp now sits at the inset VStack's deeper indent. The
                    // clamp itself is unchanged — only the leading whitespace.
                    "composeBar\n                            .rapidChatDynamicTypeClamp()",
                ]
            ),
            // PoppedConversationView clamps once at the Group root
            // (no sheets attached so a body-level clamp is safe).
            Anchor(
                relativePath: "Sources/Rapid/UI/PoppedConversationView.swift",
                requiredCallSites: [".rapidChatDynamicTypeClamp()"]
            ),
            // QuickAsk: live rows (compose, transcript, footer) must
            // each carry the clamp on the line below the property
            // reference; the shortcuts sheet stays uncapped via the
            // body-chain attachment. Codex r3: assert the literal
            // `.rapidChatDynamicTypeClamp()` follows each property
            // reference, not just that the names appear somewhere.
            Anchor(
                relativePath: "Sources/Rapid/QuickAsk/QuickAskView.swift",
                requiredCallSites: [
                    "composeRow\n                .padding(.horizontal, 16)\n                .padding(.vertical, 14)\n                .rapidChatDynamicTypeClamp()",
                    "transcriptArea\n                .rapidChatDynamicTypeClamp()",
                    "footer\n                .padding(.horizontal, 16)\n                .padding(.vertical, 10)\n                .rapidChatDynamicTypeClamp()",
                ]
            ),
        ]
        for anchor in anchors {
            let url = packageRoot.appendingPathComponent(anchor.relativePath)
            let body = try String(contentsOf: url, encoding: .utf8)
            // For ChatView the anchor includes both the named property
            // AND the modifier call — the multi-line literal in the
            // anchor string asserts they're adjacent. For Quick Ask
            // we look for the property name AND that
            // `.rapidChatDynamicTypeClamp()` appears within the file;
            // line-adjacency checking would over-couple to formatting.
            #expect(
                body.contains(".rapidChatDynamicTypeClamp()"),
                "\(anchor.relativePath) must call .rapidChatDynamicTypeClamp() at least once."
            )
            for site in anchor.requiredCallSites {
                #expect(
                    body.contains(site),
                    "\(anchor.relativePath) missing required clamp anchor: \(site.prefix(80))"
                )
            }
        }
    }

    /// Walk parent directories until we find `Package.swift`. Throws
    /// if we hit the filesystem root without finding one.
    static func findPackageRoot() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
        struct PackageRootNotFound: Error {}
        throw PackageRootNotFound()
    }
}
