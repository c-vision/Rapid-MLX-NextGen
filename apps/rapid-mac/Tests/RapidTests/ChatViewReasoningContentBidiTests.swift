import Foundation
import Testing
@testable import Rapid

/// Pins that every ``reasoning_content`` (`message.reasoning`)
/// render site routes through ``ChatTextSanitizer`` before reaching
/// SwiftUI ``Text(...)`` / ``Markdown(...)``.
///
/// ## Why this file exists alongside ``ChatViewAssistantContentBidiTests``
///
/// PR #324 plugged the assistant-content render-site sanitiser holes
/// for QuickAsk; PR #329 added the matching source-grep pins for the
/// main ``ChatView.assistantBlock`` ``message.content`` paths. Neither
/// PR pinned the **reasoning** lane: a hybrid-thinking model that
/// echoes a tool result containing ``U+202E`` into ``reasoning_content``
/// (instead of into ``content``) would slip past every existing pin
/// because they all key on ``message.content`` / ``r.content``.
///
/// Cycle-11 finding ``F-11-3`` (bidi override ``U+202E`` round-trips
/// into ``reasoning_content`` on phi-4-mini-reasoning-4bit — the
/// reasoning bubble renderer must apply the same ``ChatTextSanitizer``
/// treatment) is closed by the production code today — verified by
/// reading the render sites:
///
///   * Streaming reasoning bubble (`ChatView.assistantBlock`,
///     ``Text(memoisedSanitisedReasoning)``) routes through
///     ``streamingReasoningMemo.sanitised(...)`` which delegates to
///     ``ChatTextSanitizer.sanitize`` (computed-property shape pinned
///     by ``ChatViewAssistantContentBidiTests
///     .streamingReasoningMemoComputedPropertyShape``).
///   * Popped-out conversation window (`PoppedConversationView.block`)
///     wraps ``message.reasoning`` in
///     ``ChatTextSanitizer.sanitizeForDisplay(...)`` inline.
///
/// This test file pins **the reasoning lane** of those call sites so
/// the F-11-3 closure does not silently regress when a future
/// refactor edits either renderer.
///
/// ## Why source-grep instead of a SwiftUI snapshot test
///
/// Same rationale as ``ChatViewAssistantContentBidiTests``: this repo
/// has no SnapshotTesting / pixel-diff dep and the rest of its
/// regression pins are source-grep style (see
/// ``QuickAskBidiSanitizationTests`` and
/// ``ChatViewAssistantContentBidiTests`` for the canonical pattern).
/// The risk we're pinning is *behavioural*: a refactor that drops the
/// sanitiser wrap from the reasoning render site silently reopens the
/// F-11-3 bidi-control bubble-reordering hole.
///
/// ## Helper reuse
///
/// The lexer / slicer / walker / alias-rebinding helpers are static
/// members of ``ChatViewAssistantContentBidiTests``. They're parameter-
/// ised on the raw token (e.g. ``message.content`` vs
/// ``message.reasoning``) so we reuse them here verbatim — the bug
/// shape is identical, only the token under test differs.
@Suite("ChatView reasoning-content bidi sanitisation — render-site coverage")
struct ChatViewReasoningContentBidiTests {

    /// Resolve the source tree root from the test file path. Same
    /// anchor invariant as the assistant-content / Quick-Ask suites.
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

    // MARK: - Streaming-path memo plumbing (positive shape pin)

    /// Belt-and-braces: the streaming reasoning bubble's render call
    /// site itself must pass ``memoisedSanitisedReasoning`` (NOT
    /// ``message.reasoning``) to ``Text(...)``. Even with the
    /// computed property correctly wired (separately pinned by
    /// ``ChatViewAssistantContentBidiTests
    /// .streamingReasoningMemoComputedPropertyShape``), a refactor
    /// that "inlines" the property back to
    /// ``Text(message.reasoning)`` for "perf" would re-open the F-11-3
    /// leak. This test pins the call-site form.
    @Test("Streaming reasoning Text(...) call uses memoisedSanitisedReasoning, not message.reasoning")
    func streamingReasoningTextCallSitePinned() throws {
        let source = try loadSource("Sources/Rapid/UI/ChatView.swift")
        let block = try ChatViewAssistantContentBidiTests.assistantBlockSlice(source)
        // The reasoning disclosure renders inside ``if !message
        // .reasoning.isEmpty { DisclosureGroup { ... } }``. We grep
        // for every bad shape:
        let forbiddenShapes = [
            "Text(message.reasoning)",
            "Text( message.reasoning )",
        ]
        let compact = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(block)
        for shape in forbiddenShapes {
            let compactShape = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(shape)
            // Mirrors PR #329 round-4 MAJOR: ``Issue.record`` (not
            // ``#expect``) inside a loop body so swift-testing 0.99
            // cannot silently drop a per-shape failure.
            if compact.contains(compactShape) {
                Issue.record(
                    """
                    ChatView.assistantBlock contains a raw \
                    Text(message.reasoning) shape that bypasses \
                    memoisedSanitisedReasoning. Even one such call site \
                    re-opens the cycle-11 F-11-3 bidi-control echo hole \
                    in the thinking-bubble disclosure. Use \
                    Text(memoisedSanitisedReasoning) for the streaming \
                    branch (which delegates to the \
                    streamingReasoningMemo.sanitised(...) memo, see \
                    ChatTextSanitizer.Memo).
                    """
                )
            }
        }
        // Positive shape: at least one Text(memoisedSanitisedReasoning)
        // call must exist in the assistantBlock slice — if a refactor
        // moves the reasoning disclosure into a separate computed
        // property or sibling view we want this pin to surface that
        // structural change so the new render site can be re-pinned.
        #expect(
            compact.contains("Text(memoisedSanitisedReasoning)"),
            """
            ChatView.assistantBlock no longer contains a \
            Text(memoisedSanitisedReasoning) call. The streaming \
            reasoning render path may have been rewritten — verify it \
            still routes message.reasoning through \
            ChatTextSanitizer.Memo / ChatTextSanitizer.sanitize and \
            update this pin (and \
            ChatViewAssistantContentBidiTests \
            .streamingReasoningMemoComputedPropertyShape) to match.
            """
        )
        // PR #329 round-1 MAJOR carryover: catch the
        //
        //     let leaked = message.reasoning
        //     Text(leaked)
        //
        // bypass shape that defeats the literal-shape grep above. The
        // assertNoLocalAliasRebinding helper detects both the bare
        // and the wrapped ``let leaked = (message.reasoning)`` /
        // ``let leaked = String(message.reasoning)`` forms — see the
        // PR #329 round-5/6 commentary in that helper.
        ChatViewAssistantContentBidiTests.assertNoLocalAliasRebinding(
            inCompactArg: compact,
            rawTokens: ["message.reasoning"],
            callShape: "ChatView.assistantBlock (streaming reasoning branch)"
        )

        // Codex PR-#331 round-1 MAJOR-2: walk every ``message.reasoning``
        // value-use inside ``assistantBlock``. The literal-shape
        // ``Text(message.reasoning)`` ban only catches the direct
        // ``Text(...)`` render site, but reasoning text can also reach
        // the user through view modifiers — e.g. ``.accessibilityLabel
        // (message.reasoning)``, ``.help(message.reasoning)``, a
        // ``.contextMenu`` "Copy reasoning" item built from raw text, or
        // a sibling ``ToolTip(message.reasoning)``. Every such value-use
        // must either be a whitelisted length/identity probe or be
        // immediately preceded by ``ChatTextSanitizer.sanitizeForDisplay(``.
        //
        // Today the only non-probe ``message.reasoning`` use in
        // ``assistantBlock`` is the ``streamingReasoningMemo.sanitised
        // (message.reasoning)`` reference inside the memo computed
        // property, which lives OUTSIDE the assistantBlock slice
        // (assistantBlock is a computed View; the memo property is a
        // sibling). Inside the slice itself, the only mentions of
        // ``message.reasoning`` are ``.isEmpty`` probes. Pin that
        // contract so a refactor adding ``.accessibilityLabel
        // (message.reasoning)`` etc. without a safe-wrap fails red.
        ChatViewAssistantContentBidiTests.assertEveryRawValueUseIsSanitised(
            inCompactArg: compact,
            rawToken: "message.reasoning",
            callIdx: 0,
            callShape: "ChatView.assistantBlock (streaming reasoning branch — every value use)"
        )
    }

    // MARK: - Popped-conversation render site

    /// ``PoppedConversationView.block(message:role:isAssistant:)``
    /// renders the reasoning disclosure for popped-out chat windows
    /// (v0.5.14 NIT closure: hybrid-thinking trace must mirror the
    /// main chat view). The render call today is:
    ///
    /// ```swift
    /// Text(ChatTextSanitizer.sanitizeForDisplay(message.reasoning))
    /// ```
    ///
    /// — direct safe-wrap, no memo (popped view is a snapshot,
    /// not a streaming surface). Pin both that the sanitiser is
    /// mentioned in the slice AND that every ``message.reasoning``
    /// value-use is preceded by ``ChatTextSanitizer
    /// .sanitizeForDisplay(`` (with the standard probe whitelist
    /// permitting ``.isEmpty`` etc.).
    @Test("PoppedConversationView.block Text(...) wraps message.reasoning via ChatTextSanitizer")
    func poppedConversationReasoningTextWrappedBySanitizer() throws {
        let source = try loadSource("Sources/Rapid/UI/PoppedConversationView.swift")
        // Codex PR-#331 round-1 MAJOR-1: scope the positive sanitiser
        // grep to the reasoning-disclosure sub-slice, NOT the whole
        // ``block`` body. The block contains the ``message.content``
        // render path too — that path also calls
        // ``ChatTextSanitizer.sanitizeForDisplay``, so a refactor that
        // moves the reasoning disclosure into a sibling helper while
        // keeping the message.content wrap in place would leave the
        // sanitiser mention satisfied by the unrelated content sanitise
        // and silently bypass this pin.
        //
        // The reasoning disclosure today is bounded by
        //
        //     if !message.reasoning.isEmpty {
        //         DisclosureGroup {
        //             Text(ChatTextSanitizer.sanitizeForDisplay(message.reasoning))
        //             ...
        //         } label: { ... }
        //     }
        //
        // We slice from ``if !message.reasoning.isEmpty {`` to the
        // matching close-brace and run the positive assertion + the
        // per-occurrence walker + the alias-rebinding catch INSIDE
        // that narrower span. A refactor like
        //
        //     reasoningDisclosure(message: message)
        //
        // (which moves the renderer out of ``block`` entirely) will
        // make the slicer's anchor miss, surfacing as a build failure
        // here — the helper requires the anchor and explicitly errors
        // when the gate condition is gone.
        let reasoningSlice = try Self.poppedReasoningDisclosureSlice(source)
        let reasoningCompact = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(reasoningSlice)

        // Positive assertion (scoped to the reasoning-only slice).
        // A refactor like ``Text(message.reasoning ?? "")`` would drop
        // the safe-wrap AND skip the per-occurrence walker below (the
        // walker only fires on ``message.reasoning`` matches that
        // AREN'T whitelisted probes — a refactor that wraps the value
        // in a function call before reaching ``Text(...)`` would
        // silently pass without this gate).
        #expect(
            reasoningCompact.contains("ChatTextSanitizer.sanitizeForDisplay"),
            """
            PoppedConversationView reasoning disclosure no longer \
            mentions ChatTextSanitizer.sanitizeForDisplay inside the \
            ``if !message.reasoning.isEmpty {...}`` gate. The reasoning \
            render site has been refactored in a way that does not \
            route through the bidi-control sanitiser. See \
            bug_report.md cycle-11 F-11-3.
            """
        )

        // Walk every ``message.reasoning`` value-use inside the
        // reasoning disclosure. Each must either be a whitelisted
        // probe (``.isEmpty`` etc.) or be preceded by
        // ``ChatTextSanitizer.sanitizeForDisplay(``.
        ChatViewAssistantContentBidiTests.assertEveryRawValueUseIsSanitised(
            inCompactArg: reasoningCompact,
            rawToken: "message.reasoning",
            callIdx: 0,
            callShape: "PoppedConversationView.block (reasoning disclosure slice)"
        )

        // Alias-rebinding catch — covers ``let leaked = message
        // .reasoning`` (bare) AND ``let leaked = (message.reasoning)``
        // / ``let leaked = String(message.reasoning)`` (wrapped). See
        // ``ChatViewAssistantContentBidiTests.assertNoLocalAliasRebinding``
        // for the PR #329 round-1/5/6 rationale. Run this against the
        // wider ``block`` slice too — the alias-rebinding shape might
        // sit OUTSIDE the reasoning-gate region if a refactor hoists
        // the alias up to the block prelude.
        let block = try Self.poppedBlockSlice(source)
        let blockCompact = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(block)
        ChatViewAssistantContentBidiTests.assertNoLocalAliasRebinding(
            inCompactArg: blockCompact,
            rawTokens: ["message.reasoning"],
            callShape: "PoppedConversationView.block"
        )
    }

    // MARK: - Helper self-tests (parity with the assistant-content suite)

    /// The reasoning lane shares the alias-rebinding detection helper
    /// with the assistant-content suite (parameterised on the raw
    /// token). PR #329 invests heavily in pinning the detector on
    /// six source-grep categories that previously round-tripped past
    /// the literal-shape grep. The same six categories ALL surface
    /// against ``message.reasoning`` if a refactor introduces a
    /// reasoning-side alias. Self-test that the detector behaves
    /// correctly on the reasoning token so a parser-level regression
    /// in the helper is caught here too.
    ///
    /// The detector primitives we exercise:
    ///
    ///   * ``stripCommentsAndWhitespace`` — compactor that normalises
    ///     a raw source slice into the form the matchers walk.
    ///     Categories (1) and (5) below test it directly.
    ///   * ``isLetOrVarBindingBefore`` — pure ``Bool`` predicate that
    ///     decides whether a ``=`` offset in the compacted form is
    ///     preceded by a real binding LHS. Categories (2), (4), (6).
    ///   * Tuple-destructure binding (3) is not a direct-neighbour
    ///     shape (the ``=`` sits after ``)``, not the binding name);
    ///     the wrapped-RHS scanner inside ``assertNoWrappedAliasRebinding``
    ///     handles it. We pin its prerequisite — the LHS regex shape
    ///     that scanner enumerates — by checking ``isLetOrVarBindingBefore``
    ///     returns ``false`` here (a positive signal that it is
    ///     genuinely NOT a direct-neighbour case and must be caught
    ///     by the wrapped pass instead).
    @Test("Six source-grep regression cases against message.reasoning (PR #329 carryover)")
    func aliasRebindingDetectorRegressionAgainstReasoningToken() {
        // ── (1) Nested block comments — compactor must handle ────
        // The compactor must strip a nested ``/* outer /* inner */
        // outer-tail */`` block; a real binding hidden inside must
        // survive into the compacted form so the binding detector
        // can see it. Failure modes the assertion below catches:
        //
        //   * compactor stops at the first ``*/`` and leaks
        //     ``outertail*/`` into the output (would surface as a
        //     prefix on the compact string);
        //   * compactor mishandles the nested ``/*`` and treats it
        //     as code, leaving ``nestedinner*/outertail*/`` in the
        //     output.
        //
        // The unique noise tokens ``OUTERHEAD``, ``NESTED_INNER``,
        // ``OUTER_TAIL`` give us specific substrings to assert
        // absence of so the test exercises the comment stripper's
        // nesting behaviour, NOT just the direct-binding detector.
        let nestedCommentSource =
            "/* OUTERHEAD /* NESTED_INNER */ OUTER_TAIL */let leaked = message.reasoning"
        let nestedCompact = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(nestedCommentSource)
        #expect(
            nestedCompact == "letleaked=message.reasoning",
            """
            (1) nested block comments: stripCommentsAndWhitespace did \
            not normalise nested /* ... /* ... */ ... */ correctly. \
            Got: '\(nestedCompact)'. The compactor MUST descend into \
            nested block comments or a bidi-control bypass hidden \
            inside a nested comment region survives.
            """
        )
        // Specific failure-mode assertions: none of the noise tokens
        // from the nested comment should appear in the compact form.
        #expect(
            !nestedCompact.contains("OUTERHEAD"),
            "(1) nested block comments: outer-comment head leaked into compact form."
        )
        #expect(
            !nestedCompact.contains("NESTED_INNER"),
            "(1) nested block comments: inner-comment body leaked into compact form."
        )
        #expect(
            !nestedCompact.contains("OUTER_TAIL"),
            """
            (1) nested block comments: outer-comment tail leaked into \
            compact form. The most likely cause is that \
            stripCommentsAndWhitespace closes the outer comment on the \
            FIRST ``*/`` (i.e. the inner close) instead of tracking \
            nesting depth. Re-read the compactor's depth counter.
            """
        )
        // Now verify the detector flags the surviving binding.
        if let eq1 = nestedCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: nestedCompact,
                    equalsIdx: eq1
                ),
                "(1) nested block comments: detector failed to flag the binding."
            )
        }

        // ── (2) ``.description`` exemption guard ─────────────────
        // A member assignment whose LHS starts with a ``.`` (member
        // access) is NOT a binding. The detector must return
        // ``false`` so legitimate property mutations involving
        // ``message.reasoning`` on the RHS do not trip a false
        // positive (PR #329 round 2 NIT).
        let memberAccessCompact = "obj.description=message.reasoning"
        if let eq2 = memberAccessCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: memberAccessCompact,
                    equalsIdx: eq2
                ) == false,
                "(2) .description exemption guard: member-access LHS misclassified as binding."
            )
        }

        // ── (3) Tuple-destructure binding LHS ────────────────────
        // ``let (a, b) = (x, message.reasoning)`` compacts to
        // ``let(a,b)=(x,message.reasoning)``. The ``=`` sits between
        // the tuple LHS and the tuple RHS, so the direct-neighbour
        // detector ``isLetOrVarBindingBefore`` returns ``false`` (the
        // immediate left of ``=`` is ``)``, not the binding name).
        // The wrapped-RHS scanner inside
        // ``assertNoWrappedAliasRebinding`` is responsible for
        // catching this shape — see PR #329 round 6 MAJOR.
        //
        // Codex PR-#331 round-1 MAJOR-3: assert BOTH halves of the
        // contract so this category is genuinely orthogonal to the
        // direct-neighbour cases above:
        //
        //   (a) ``isLetOrVarBindingBefore`` returns false (the
        //       prerequisite — confirms the tuple shape does NOT
        //       short-circuit the direct detector).
        //   (b) ``assertNoWrappedAliasRebinding`` DOES record an
        //       issue for this exact compact form. We wrap the call
        //       in ``withKnownIssue`` so the recorded issue is
        //       expected (not a real failure) and the test goes red
        //       if a future refactor weakens the wrapped scanner so
        //       it stops catching the tuple-destructure shape.
        let tupleCompact = "let(a,b)=(x,message.reasoning)"
        if let eq3 = tupleCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: tupleCompact,
                    equalsIdx: eq3
                ) == false,
                """
                (3a) tuple-destructure binding LHS: \
                isLetOrVarBindingBefore must return false here so the \
                wrapped-RHS scanner handles tuples (PR #329 round 6 \
                MAJOR). A 'true' result would imply the direct \
                detector now claims tuple coverage AND the wrapped \
                scanner's tuple regex would be redundant — that's a \
                semantic change that needs re-validating against the \
                whole alias-rebinding test matrix.
                """
            )
        }
        // (3b) The wrapped scanner MUST record an issue for the
        // tuple-destructure shape. ``withKnownIssue`` succeeds iff at
        // least one issue is recorded inside the closure; if the
        // scanner is silently weakened so it stops flagging tuples,
        // the no-issue-recorded branch causes the test to fail.
        withKnownIssue(
            """
            (3b) tuple-destructure binding LHS: \
            assertNoWrappedAliasRebinding must record at least one \
            issue for ``let(a,b)=(x,message.reasoning)``. If this \
            test fails because no issue was recorded, the wrapped- \
            RHS scanner has regressed and a tuple-destructure alias \
            rebinding of message.reasoning would slip past every \
            pin in this suite.
            """
        ) {
            ChatViewAssistantContentBidiTests.assertNoWrappedAliasRebinding(
                inCompactArg: tupleCompact,
                rawTokens: ["message.reasoning"],
                callShape: "(self-test) tuple-destructure binding LHS"
            )
        }

        // ── (4) Property LHS ``self.someLet = message.reasoning`` ─
        // Stored-property assignment whose LHS identifier happens to
        // contain ``Let`` (camel-case keyword embedding). The
        // detector's hard-boundary rules (PR #329 round 3 BLOCKING)
        // require ``let``/``var`` to follow ``^|;|{|}|,`` or a
        // conditional keyword — never ``.``. Must return ``false``.
        let propertyLHSCompact = "self.someLet=message.reasoning"
        if let eq4 = propertyLHSCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: propertyLHSCompact,
                    equalsIdx: eq4
                ) == false,
                "(4) property LHS member assignment misclassified as a binding."
            )
        }

        // ── (5) Whitespace-around-dot in the raw source ──────────
        // ``message . reasoning`` with mixed whitespace (spaces,
        // tabs, newlines, ``\r\n``) inside the member-access chain
        // must collapse to ``message.reasoning`` so the value-token
        // grep catches it. A regression in the compactor that handles
        // ASCII space but not tabs / CRs would let an attacker
        // re-arrange the chain to bypass the grep.
        //
        // This category exercises a DIFFERENT compactor surface than
        // category (1): (1) tests block-comment NESTING depth, (5)
        // tests WHITESPACE-CLASS coverage. Both feed into the same
        // direct-binding detector but the failure modes are
        // orthogonal — a compactor that handles nested comments but
        // misses tab/CR whitespace passes (1) and fails (5), and
        // vice versa.
        let spacedSource = "let leaked = message  \t.\r\n  reasoning"
        let spacedCompact = ChatViewAssistantContentBidiTests.stripCommentsAndWhitespace(spacedSource)
        #expect(
            spacedCompact == "letleaked=message.reasoning",
            """
            (5) whitespace-around-dot: compactor failed to collapse \
            mixed whitespace (space, tab, CRLF) inside a member-access \
            chain. Got: '\(spacedCompact)'. The compactor MUST treat \
            every Unicode-whitespace scalar (not just ASCII space) as \
            droppable so a tab/CR sneak-in cannot bypass the grep.
            """
        )
        // Specific failure-mode pins for the unicode-whitespace
        // classes we care about — these would also surface a
        // compactor that handles ``isASCII`` but not the wider
        // ``properties.isWhitespace`` Unicode predicate.
        #expect(
            !spacedCompact.unicodeScalars.contains(where: { $0.value == 0x09 }),
            "(5) compactor leaked TAB (U+0009) into the compact form."
        )
        #expect(
            !spacedCompact.unicodeScalars.contains(where: { $0.value == 0x0D }),
            "(5) compactor leaked CR (U+000D) into the compact form."
        )
        #expect(
            !spacedCompact.unicodeScalars.contains(where: { $0.value == 0x0A }),
            "(5) compactor leaked LF (U+000A) into the compact form."
        )
        if let eq5 = spacedCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: spacedCompact,
                    equalsIdx: eq5
                ),
                "(5) whitespace-around-dot: post-compaction binding not flagged."
            )
        }

        // ── (6) Compound conditional ``else if let leaked = ...`` ─
        // PR #329 round 5 MAJOR-2 added support for compound
        // conditional binding keywords. The compacted shape
        // ``elseifletleaked=message.reasoning`` must be flagged as a
        // binding so an alias rebinding hidden inside an
        // ``else if let`` arm cannot bypass the grep.
        let compoundCondCompact = "elseifletleaked=message.reasoning"
        if let eq6 = compoundCondCompact.firstIndex(of: "=") {
            #expect(
                ChatViewAssistantContentBidiTests.isLetOrVarBindingBefore(
                    compactArg: compoundCondCompact,
                    equalsIdx: eq6
                ),
                "(6) compound conditional 'else if let': detector missed PR #329 round 5 MAJOR-2 shape."
            )
        }
    }

    // MARK: - Behavioural pins (cycle-11 F-11-3 payload)

    /// Cycle-11 F-11-3 payload: a phi-4-mini-reasoning prompt
    /// ``Please echo back this string exactly: hello‮world`` lands
    /// ``hello\u{202E}world`` inside ``reasoning_content``. Without
    /// the sanitiser the SwiftUI reasoning bubble layout would render
    /// the text mirrored starting at the override. After sanitisation
    /// the override is stripped and the rendered string is the
    /// literal byte order.
    @Test("Cycle-11 F-11-3 payload: reasoning_content with U+202E echo is neutralised")
    func cycle11F113PayloadNeutralised() {
        // The exact payload from the cycle-11 finding repro: a user
        // prompt that asks the model to echo a bidi-override
        // character, the model parrots it into the thinking bubble.
        let echoed = "hello\u{202E}world"
        let cleaned = ChatTextSanitizer.sanitizeForDisplay(echoed)
        #expect(cleaned == "helloworld")
        #expect(!cleaned.unicodeScalars.contains { $0.value == 0x202E })
    }

    /// Isolate-bracket variant: an attacker who can no longer use
    /// ``U+202E`` (because the strip list covers it) might fall back
    /// to the isolate brackets ``U+2066`` LRI, ``U+2067`` RLI,
    /// ``U+2068`` FSI, ``U+2069`` PDI. The reasoning render path's
    /// sanitiser must strip all four so the F-11-3 closure is
    /// codepoint-class-complete.
    @Test("Cycle-11 F-11-3 isolate-bracket variants U+2066-9 are neutralised")
    func cycle11F113IsolateBracketsNeutralised() {
        let isolateCodepoints: [UInt32] = [0x2066, 0x2067, 0x2068, 0x2069]
        for cp in isolateCodepoints {
            let scalar = UnicodeScalar(cp)!
            let payload = "thinking\(scalar)trace"
            let cleaned = ChatTextSanitizer.sanitizeForDisplay(payload)
            // Loop-body ``Issue.record`` so swift-testing 0.99 cannot
            // drop a per-codepoint failure — same swift-testing 0.99
            // workaround as PR #329 round-4 MAJOR.
            if cleaned != "thinkingtrace" {
                Issue.record(
                    "Isolate U+\(String(cp, radix: 16, uppercase: true)) leaked through reasoning-content sanitiser. Got: '\(cleaned)'"
                )
            }
            if cleaned.unicodeScalars.contains(where: { $0.value == cp }) {
                Issue.record(
                    "Isolate U+\(String(cp, radix: 16, uppercase: true)) survived reasoning-content sanitiser."
                )
            }
        }
    }

    /// Preservation case: a reasoning trace in genuinely
    /// right-to-left Arabic prose (with NO bidi controls) MUST
    /// round-trip unchanged. The sanitiser strips only the explicit
    /// bidi-affecting controls — it must not over-reach into RTL
    /// scripts that derive direction from the codepoint's own
    /// Unicode bidi class. This pins that an Arabic-script thinking
    /// trace renders identically pre- and post-sanitisation.
    @Test("Arabic reasoning trace with no bidi controls is preserved verbatim")
    func arabicReasoningTracePreserved() {
        // "أفكر في إجابة" — Arabic for "I am thinking about an
        // answer" — the kind of phrase a hypothetical Arabic-trained
        // reasoning model might emit. Pure script content, no bidi
        // controls.
        let arabicTrace = "أفكر في إجابة"
        let cleaned = ChatTextSanitizer.sanitizeForDisplay(arabicTrace)
        #expect(cleaned == arabicTrace)
        // Sanity: the sanitiser must not have stripped any Arabic
        // letters (Unicode block U+0600..U+06FF). The output must
        // contain the SAME unicode scalars (modulo nothing-stripped).
        let inputScalars = Array(arabicTrace.unicodeScalars)
        let outputScalars = Array(cleaned.unicodeScalars)
        #expect(inputScalars == outputScalars)
    }

    /// Edge case: an empty reasoning trace round-trips to an empty
    /// string. The reasoning disclosure is only shown when
    /// ``message.reasoning.isEmpty`` is false (see
    /// ``ChatView.assistantBlock`` line 2430 — `if !message
    /// .reasoning.isEmpty {`), so in production the sanitiser is
    /// never called on the empty string. Pin the behaviour anyway —
    /// defence in depth against a future refactor that drops the
    /// emptiness gate or memoises across a clear-out.
    @Test("Empty reasoning trace sanitises to empty (no crash, no spurious chars)")
    func emptyReasoningTracePreserved() {
        let cleaned = ChatTextSanitizer.sanitizeForDisplay("")
        #expect(cleaned == "")
        #expect(cleaned.isEmpty)
    }

    // MARK: - Slicing helpers (PoppedConversationView only — the
    // ChatView slicers are reused from ChatViewAssistantContentBidiTests)

    /// Slice the ``PoppedConversationView.block(message:role:isAssistant:)``
    /// method body out of ``PoppedConversationView.swift``. Same
    /// approach as ``ChatViewAssistantContentBidiTests
    /// .assistantBlockSlice`` — anchor on the signature line and walk
    /// forward to the next sibling declaration.
    ///
    /// The ``block`` function is private and short (~70 lines today),
    /// and it is the ONLY render site in this file that touches
    /// ``message.reasoning``. A future refactor that moves the
    /// reasoning disclosure out of ``block`` (e.g. into a sibling
    /// computed property) would make this slicer's signature anchor
    /// miss — the suite-level positive grep for the sanitiser inside
    /// the slice would catch the structural change immediately.
    static func poppedBlockSlice(_ source: String) throws -> String {
        let signature = "private func block("
        let start = try #require(
            source.range(of: signature),
            "PoppedConversationView.block(...) not found — has it been renamed?"
        )
        let rest = source[start.upperBound...]
        // The next sibling declaration is ``private func`` or
        // ``private var`` (PoppedConversationView is a struct with
        // mixed members). Fall back to the file-level ``}`` if no
        // sibling exists below.
        let endMarkers = [
            "\n    private func ",
            "\n    private var ",
            "\n    var body:",
            "\n}",
        ]
        let endIndex: String.Index = endMarkers
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[..<endIndex])
    }

    /// Slice ONLY the ``if !message.reasoning.isEmpty { ... }``
    /// disclosure region out of ``PoppedConversationView.block``. The
    /// brace-counting walker is comment / string-literal aware so a
    /// ``}`` inside a comment or a string doesn't confuse the depth
    /// tracker.
    ///
    /// **Why we need this narrower slice** (codex PR-#331 round-1
    /// MAJOR-1): the full ``block`` body also renders ``message
    /// .content`` and that render path also calls
    /// ``ChatTextSanitizer.sanitizeForDisplay``. A bare
    /// "the sanitiser is mentioned anywhere in ``block``" positive
    /// assertion is satisfied by the content-side wrap and would not
    /// surface a refactor that moves the reasoning disclosure into a
    /// sibling helper with a raw ``Text(message.reasoning)`` body.
    /// Pinning the sanitiser inside the reasoning-gate region closes
    /// that gap.
    static func poppedReasoningDisclosureSlice(_ source: String) throws -> String {
        let gate = "if !message.reasoning.isEmpty {"
        let start = try #require(
            source.range(of: gate),
            """
            PoppedConversationView.block no longer contains the \
            ``if !message.reasoning.isEmpty {`` gate. The reasoning \
            disclosure may have been hoisted into a sibling helper — \
            update the slicer anchor to the new gate / signature and \
            re-pin the positive sanitiser assertion against the new \
            renderer.
            """
        )
        // We're positioned just past the gate's ``{``. Run the same
        // comment/string-aware brace walker the assistant-content
        // suite uses for ``ToolCallChip``.
        let rest = source[start.upperBound...]
        let scalars = Array(rest.unicodeScalars)
        var depth = 1
        var i = 0
        var inLineComment = false
        var blockCommentDepth = 0
        var inStringLit = false
        var inMultilineStringLit = false
        while i < scalars.count && depth > 0 {
            let c = scalars[i]
            if inMultilineStringLit {
                if i + 2 < scalars.count
                    && scalars[i].value == 0x22
                    && scalars[i + 1].value == 0x22
                    && scalars[i + 2].value == 0x22
                {
                    inMultilineStringLit = false
                    i += 3
                    continue
                }
                i += 1
                continue
            }
            if inStringLit {
                if c.value == 0x5C /* '\' */ && i + 1 < scalars.count {
                    i += 2
                    continue
                }
                if c.value == 0x22 {
                    inStringLit = false
                }
                i += 1
                continue
            }
            if inLineComment {
                if c.value == 0x0A {
                    inLineComment = false
                }
                i += 1
                continue
            }
            if blockCommentDepth > 0 {
                if c.value == 0x2F && i + 1 < scalars.count && scalars[i + 1].value == 0x2A {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c.value == 0x2A && i + 1 < scalars.count && scalars[i + 1].value == 0x2F {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if c.value == 0x2F && i + 1 < scalars.count && scalars[i + 1].value == 0x2F {
                inLineComment = true
                i += 2
                continue
            }
            if c.value == 0x2F && i + 1 < scalars.count && scalars[i + 1].value == 0x2A {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if i + 2 < scalars.count
                && c.value == 0x22
                && scalars[i + 1].value == 0x22
                && scalars[i + 2].value == 0x22
            {
                inMultilineStringLit = true
                i += 3
                continue
            }
            if c.value == 0x22 {
                inStringLit = true
                i += 1
                continue
            }
            if c.value == 0x7B {
                depth += 1
            } else if c.value == 0x7D {
                depth -= 1
                if depth == 0 {
                    let endScalarIdx = i + 1
                    let endIdx = rest.unicodeScalars.index(
                        rest.unicodeScalars.startIndex,
                        offsetBy: endScalarIdx
                    )
                    return String(rest[..<endIdx])
                }
            }
            i += 1
        }
        // Unbalanced — return everything we walked so the test
        // surfaces a clear failure downstream rather than silently
        // skipping checks.
        return String(rest)
    }
}
