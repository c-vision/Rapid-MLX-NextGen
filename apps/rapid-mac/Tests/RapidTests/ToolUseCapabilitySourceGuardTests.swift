import Foundation
import Testing
@testable import Rapid

/// #342 follow-up — source-grep regression guard that pins the
/// classification mechanism inside ``ToolUseCapability.swift`` to the
/// documented family-aware approach. The pre-fix string-prefix list
/// silently over-classified 74% of the catalog as ``.unknown``
/// because adding a new size sibling required editing the
/// ``knownPrefixes`` array; the new shape uses
/// ``(family-prefix, minSizeBillions)`` rows in ``knownFamilies`` so
/// one entry covers every quant of every size in a verified family.
///
/// The risk this guard mitigates: a future PR that re-introduces
/// inline ``if alias == "..."`` shortcuts inside the matcher (or
/// adds a fresh string-prefix list parallel to ``knownFamilies``)
/// silently rolls back the structural improvement without tripping
/// the catalog-coverage tests. The shape would still pass the
/// per-alias matrix today but creates an unbounded edit-as-you-go
/// surface that's exactly what #342 fixed.
///
/// Pattern follows ``CapabilityChipRenderGateSourceGuardTests`` and
/// ``ChatViewAssistantContentBidiTests`` — strip comments / whitespace
/// then scan for forbidden shapes.
@Suite("ToolUseCapability source-grep regression guard (#342 followup)")
struct ToolUseCapabilitySourceGuardTests {

    /// Repository root, derived from ``#filePath`` so the test runs
    /// from any cwd (swift test, Xcode, CI).
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func loadSource(_ relativePath: String) throws -> String {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ``ToolUseCapability.swift`` must define ``knownFamilies`` —
    /// the family-aware classification table that closes the #342
    /// over-classification hole. A refactor that drops this table
    /// (e.g. reverts to a flat string-prefix list) trips here BEFORE
    /// the catalog-coverage tests trip with a 30-entry-mismatch wall
    /// of red.
    @Test("ToolUseCapability.swift defines knownFamilies table")
    func toolUseCapabilityDefinesKnownFamilies() throws {
        let source = try loadSource("Sources/Rapid/Server/ToolUseCapability.swift")
        let stripped = Self.stripCommentsAndWhitespace(source)
        let needle = Self.stripCommentsAndWhitespace(
            "static let knownFamilies: [KnownFamily] ="
        )
        #expect(
            stripped.contains(needle),
            "ToolUseCapability.swift must define ``static let knownFamilies: [KnownFamily] = [...]``. The family-aware classification is the #342-followup fix; if it's been reverted to a flat string-prefix list, the next size sibling that ships in aliases.json falls silently to .unknown."
        )
    }

    /// ``confidence(for:)`` must consume ``knownFamilies`` (the
    /// canonical match) AND must reuse ``ModelSizing.parseParamsBillions``
    /// (so the size floor uses the SAME alias-name parser as the
    /// rest of the codebase rather than introducing a third parallel
    /// parser).
    @Test("confidence(for:) consumes knownFamilies + reuses ModelSizing.parseParamsBillions")
    func confidenceForConsumesKnownFamiliesAndReusesSizing() throws {
        let source = try loadSource("Sources/Rapid/Server/ToolUseCapability.swift")
        let stripped = Self.stripCommentsAndWhitespace(source)
        let familiesIter = Self.stripCommentsAndWhitespace("forfamilyinknownFamilies")
        let sizingCall = Self.stripCommentsAndWhitespace("ModelSizing.parseParamsBillions(needle)")
        #expect(
            stripped.contains(familiesIter),
            "ToolUseCapability.confidence(for:) must iterate ``knownFamilies`` to honour the family + size match contract."
        )
        #expect(
            stripped.contains(sizingCall),
            "ToolUseCapability.confidence(for:) must reuse ``ModelSizing.parseParamsBillions`` instead of introducing a third alias-name parser."
        )
    }

    /// Codex r1 MAJOR + r2 MAJOR — the missing-size branch must
    /// consult ``family.missingSizeAllowList`` (exact alias allow-list,
    /// per-family) rather than unconditionally promoting to ``.known``.
    /// The r1 fix introduced a prefix-wide ``allowMissingSize: Bool``
    /// flag; r2 tightened that to a per-family exact-alias allow-list
    /// because the prefix-wide flag still let
    /// ``qwen3-coder-experimental`` silently inherit ``.known``.
    /// Source-grep the branch shape so a future refactor that drops
    /// the guard surfaces here before the edge-case test surfaces it
    /// as a "qwen3-coder-experimental became .known" red.
    @Test("confidence(for:) gates missing-size aliases on family.missingSizeAllowList (codex r2 MAJOR)")
    func confidenceForGatesMissingSizeOnAllowList() throws {
        let source = try loadSource("Sources/Rapid/Server/ToolUseCapability.swift")
        let stripped = Self.stripCommentsAndWhitespace(source)
        let guardShape = Self.stripCommentsAndWhitespace("family.missingSizeAllowList.contains(needle)")
        #expect(
            stripped.contains(guardShape),
            "ToolUseCapability.confidence(for:) must gate the missing-size promotion on ``family.missingSizeAllowList.contains(needle)`` (codex r2 MAJOR). Without the exact-alias allow-list, a future user-typed alias like ``qwen3-coder-experimental`` that collides with a verified family prefix silently inherits .known without any size evidence."
        )
        // Forbid the round-1 prefix-wide ``allowMissingSize`` flag —
        // if it ever returns, codex r2 MAJOR re-opens.
        let forbidden = Self.stripCommentsAndWhitespace("family.allowMissingSize")
        #expect(
            !stripped.contains(forbidden),
            "ToolUseCapability.swift contains the round-1 prefix-wide ``family.allowMissingSize`` flag — codex r2 MAJOR tightened to per-alias allow-list. Restoring the broad flag re-opens the qwen3-coder-experimental false-positive."
        )
    }

    /// The matcher body must NOT contain inline ``if alias == "..."``
    /// or ``alias == "..."`` literal special-case shortcuts. The
    /// principled mechanism is ``brokenPrefixes`` (denylist) +
    /// ``knownFamilies`` (verified). A literal-equality shortcut is a
    /// band-aid that grows without bound — same anti-pattern as the
    /// pre-fix string-prefix list.
    ///
    /// One exception: the ``alias.isEmpty`` guard at the top is
    /// allowed (it's a defensive bedrock against the empty-alias
    /// placeholder case from ``ChatView``). Anything else trips here.
    @Test("ToolUseCapability.swift contains no literal `alias == \"...\"` special-cases")
    func toolUseCapabilityHasNoLiteralAliasEqShortcuts() throws {
        let source = try loadSource("Sources/Rapid/Server/ToolUseCapability.swift")
        let stripped = Self.stripCommentsAndWhitespace(source)
        // The only legitimate shape that survives the strip is one
        // that uses the canonical fields. Forbid these patterns
        // outright:
        //   * ``alias=="something"`` — direct literal equality
        //   * ``needle=="something"`` — same shape post-lowercase
        for forbidden in [
            "alias==\"",
            "needle==\"",
            "alias.lowercased()==\"",
        ] {
            let strippedForbidden = Self.stripCommentsAndWhitespace(forbidden)
            #expect(
                !stripped.contains(strippedForbidden),
                "ToolUseCapability.swift contains forbidden literal-equality shape '\(forbidden)'. The classification mechanism is ``brokenPrefixes`` (denylist) + ``knownFamilies`` (verified) — literal special-cases re-introduce the pre-#342 unbounded edit-as-you-go surface."
            )
        }
    }

    /// Defensive cross-file check: NO other file in ``Sources/Rapid/``
    /// should define a parallel alias-classification table that
    /// shadows ``ToolUseCapability``. The single source of truth for
    /// tool-use confidence lives in ``ToolUseCapability.swift``.
    ///
    /// Forbid the identifier ``knownFamilies`` outside the canonical
    /// file (declaration site + the catalog-coverage test that
    /// iterates it for sanity).
    @Test("No source file outside ToolUseCapability.swift defines its own knownFamilies / brokenPrefixes")
    func noParallelClassificationTable() throws {
        let sourceTreeRoot = Self.sourceRoot.appendingPathComponent("Sources/Rapid")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceTreeRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ),
            "Could not enumerate Sources/Rapid — directory missing?"
        )
        for case let url as URL in enumerator
            where url.pathExtension == "swift"
            && url.lastPathComponent != "ToolUseCapability.swift"
        {
            let body = try String(contentsOf: url, encoding: .utf8)
            let stripped = Self.stripCommentsAndWhitespace(body)
            for forbidden in [
                "staticletknownFamilies:",
                "staticletbrokenPrefixes:",
                "staticletknownPrefixes:[String]=",
            ] {
                #expect(
                    !stripped.contains(forbidden),
                    "\(url.lastPathComponent) defines a parallel '\(forbidden)' table that shadows ToolUseCapability. Single-source-of-truth: route through ToolUseCapability.confidence(for:) instead."
                )
            }
        }
    }

    // MARK: - Strip helper (mirrors CapabilityChipRenderGateSourceGuardTests)

    /// Strip ``//`` line comments, ``/*…*/`` block comments, and all
    /// whitespace so the source-grep tests can pin against a
    /// canonical form. Same shape as
    /// ``CapabilityChipRenderGateSourceGuardTests.stripCommentsAndWhitespace``;
    /// kept private to this suite so a refactor of the other helper
    /// can't drift the rules silently.
    static func stripCommentsAndWhitespace(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            // Block comment
            if c == "/", source.index(after: i) < source.endIndex,
               source[source.index(after: i)] == "*" {
                var j = source.index(i, offsetBy: 2)
                while j < source.endIndex {
                    if source[j] == "*",
                       source.index(after: j) < source.endIndex,
                       source[source.index(after: j)] == "/" {
                        j = source.index(j, offsetBy: 2)
                        break
                    }
                    j = source.index(after: j)
                }
                i = j
                continue
            }
            // Line comment
            if c == "/", source.index(after: i) < source.endIndex,
               source[source.index(after: i)] == "/" {
                var j = source.index(after: i)
                while j < source.endIndex, source[j] != "\n" {
                    j = source.index(after: j)
                }
                i = j
                continue
            }
            // Strip whitespace
            if c.isWhitespace {
                i = source.index(after: i)
                continue
            }
            out.append(c)
            i = source.index(after: i)
        }
        return out
    }
}
