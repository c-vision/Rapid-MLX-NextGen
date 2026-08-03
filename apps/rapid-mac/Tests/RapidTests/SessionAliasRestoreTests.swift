import Foundation
import Testing
@testable import Rapid

/// Issue #451: pin the session-alias restore decision contract so a
/// future refactor of the picker / session-switch path can't
/// silently regress the "session's alias wins over picker default"
/// rule. Six cases:
///
///   1. Cached alias (in catalog) AND different from picker →
///      .useSessionAlias(alias) → caller aligns picker.
///   2. Cached alias (in catalog) AND same as picker → .noChange
///      → caller bails (no redundant SwiftUI re-render cycle).
///   3. Uncached alias (NOT in catalog) → .staleSessionAlias(alias)
///      → caller surfaces banner, leaves picker alone.
///   4. Empty session alias → .noChange (legacy / no preference).
///   5. Whitespace-only session alias → .noChange (treat as empty).
///   6. Empty catalog snapshot → .noChange (cold-start guard
///      against false-flagging every alias as stale before the
///      catalog populates).
@Suite("SessionAliasRestore.resolve outcomes (issue #451)")
struct SessionAliasRestoreTests {

    private let catalog: Set<String> = [
        "qwen3.6-27b-8bit",
        "qwen3.5-35b-4bit",
        "gemma-4-12b-4bit",
        "gemma3-1b-qat-4bit",
    ]

    @Test("Session alias is in catalog AND differs from picker → useSessionAlias")
    func sessionAliasInCatalogDifferentFromPicker() {
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "qwen3.6-27b-8bit",
            currentPickerAlias: "gemma-4-12b-4bit",
            catalogAliases: catalog
        )
        #expect(outcome == .useSessionAlias("qwen3.6-27b-8bit"))
    }

    @Test("Session alias is in catalog AND matches picker → noChange (no SwiftUI cycle)")
    func sessionAliasInCatalogMatchesPicker() {
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "qwen3.6-27b-8bit",
            currentPickerAlias: "qwen3.6-27b-8bit",
            catalogAliases: catalog
        )
        #expect(outcome == .noChange)
    }

    @Test("Session alias NOT in catalog → staleSessionAlias (banner fires)")
    func sessionAliasNotInCatalogStale() {
        // The exact scenario from issue #451: qwen3.5-4b and
        // gpt-oss-20b sessions saved by an older build but the
        // current catalog dropped both aliases.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "qwen3.5-4b",
            currentPickerAlias: "qwen3.6-27b-8bit",
            catalogAliases: catalog
        )
        #expect(outcome == .staleSessionAlias("qwen3.5-4b"))
    }

    @Test("Session alias is empty → noChange (legacy session, no preference)")
    func emptySessionAlias() {
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "",
            currentPickerAlias: "qwen3.6-27b-8bit",
            catalogAliases: catalog
        )
        #expect(outcome == .noChange)
    }

    @Test("Session alias is whitespace-only → noChange (treat as empty)")
    func whitespaceOnlySessionAlias() {
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "   \n\t",
            currentPickerAlias: "qwen3.6-27b-8bit",
            catalogAliases: catalog
        )
        #expect(outcome == .noChange)
    }

    @Test("Empty catalog snapshot → noChange (cold-start guard, no false-stale)")
    func emptyCatalogSnapshot() {
        // Before the catalog probe lands the snapshot is empty;
        // resolve MUST bail rather than flag every session as
        // stale. Otherwise every cold-start would noisy-banner
        // every restored session for the few hundred ms before
        // the catalog populates.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "qwen3.6-27b-8bit",
            currentPickerAlias: "",
            catalogAliases: []
        )
        #expect(outcome == .noChange)
    }

    @Test("Session alias resolves but picker is empty → useSessionAlias (cold-start picker)")
    func sessionAliasInCatalogPickerEmpty() {
        // Common cold-start case: picker hasn't been seeded yet
        // (no last-served alias, no auto-start). The user clicks
        // a restored session — we should align the picker to the
        // session's alias so the next send goes to the recorded
        // model rather than the picker's default.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "gemma-4-12b-4bit",
            currentPickerAlias: "",
            catalogAliases: catalog
        )
        #expect(outcome == .useSessionAlias("gemma-4-12b-4bit"))
    }

    @Test("Trim whitespace on session alias before catalog lookup")
    func trimWhitespaceOnSessionAlias() {
        // A session alias with stray whitespace (legacy on-disk
        // shape, manual edit) should resolve cleanly against the
        // trimmed value rather than false-staling.
        let outcome = SessionAliasRestore.resolve(
            sessionAlias: "  qwen3.6-27b-8bit  ",
            currentPickerAlias: "gemma-4-12b-4bit",
            catalogAliases: catalog
        )
        #expect(outcome == .useSessionAlias("qwen3.6-27b-8bit"))
    }

    @Test("Issue #451 acceptance: pre-seed stale alias → banner; cached alias → picker swap")
    func issueAcceptanceMatrix() {
        // The four sessions named in #451 against v0.8.14's
        // catalog (qwen3.5-4b + gpt-oss-20b retired;
        // qwen3.6-27b-8bit + qwen3.5-35b-4bit still present).
        let v0814Catalog: Set<String> = ["qwen3.6-27b-8bit", "qwen3.5-35b-4bit"]
        let cases: [(session: String, expected: SessionAliasRestore.Outcome)] = [
            ("qwen3.6-27b-8bit", .useSessionAlias("qwen3.6-27b-8bit")),
            ("qwen3.5-4b", .staleSessionAlias("qwen3.5-4b")),
            ("gpt-oss-20b", .staleSessionAlias("gpt-oss-20b")),
            ("qwen3.5-35b-4bit", .useSessionAlias("qwen3.5-35b-4bit")),
        ]
        for c in cases {
            let outcome = SessionAliasRestore.resolve(
                sessionAlias: c.session,
                currentPickerAlias: "gemma3-1b-qat-4bit",
                catalogAliases: v0814Catalog
            )
            #expect(outcome == c.expected,
                    "session \(c.session) expected \(c.expected) got \(outcome)")
        }
    }
}
