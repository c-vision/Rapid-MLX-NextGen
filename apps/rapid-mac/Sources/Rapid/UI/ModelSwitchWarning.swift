import Foundation

/// Pure-data inputs the warning predicate depends on. Extracted from
/// ``ChatView`` so the visibility rule is testable without standing
/// up SwiftUI / a real ``SessionStore`` / a live server.
struct ModelSwitchWarningInputs: Equatable {
    /// The active session's stable identity, or ``nil`` when there
    /// is no active session (empty store / no selection).
    let activeSessionID: UUID?
    /// The alias the session was first sent to — historical metadata
    /// stamped at session creation, never overwritten by subsequent
    /// sends (v0.5.1 contract — see ``ChatViewModel.send``).
    let sessionAlias: String
    /// What the picker currently shows — the alias the next outgoing
    /// turn will be served by.
    let pickerAlias: String
    /// How many user turns the session already contains. We only warn
    /// after the user has actually committed messages under
    /// ``sessionAlias``; on a brand-new session a mismatch is just
    /// "you haven't sent anything yet."
    let userMessageCount: Int
    /// Sessions the user has actively dismissed the warning for in
    /// this app launch. Per-session, in-memory only — we don't burn
    /// the dismissal to disk because the warning has to come back if
    /// the user closes the window and re-opens it (their intent may
    /// have changed by then).
    let dismissedSessionIDs: Set<UUID>
}

enum ModelSwitchWarning {
    /// Canonical quant suffixes documented in the project-local
    /// `CLAUDE.md` alias-naming convention. Ordered longest-first so
    /// compound suffixes (`-mxfp4-q8`) strip cleanly before the simple
    /// `-mxfp4` would over-match.
    static let knownQuantSuffixes: [String] = [
        // Longest-first ordering is load-bearing: a shorter suffix
        // that's a substring of a longer one (`-4bit` inside
        // `-qat-4bit`, `-mxfp4` inside `-mxfp4-q8`) MUST come after
        // its longer relative or the longer alias gets the shorter
        // strip and silently false-fires.
        //
        // Naming policy (codex r4): this list covers ANY suffix that
        // selects a packaging / precision / training variant of the
        // SAME family+size — chat template, context formatting, and
        // tool support are unchanged across the variants. It does NOT
        // cover behavioral axes (base/instruct, thinking/no-thinking,
        // dated revisions); those should fire the banner because the
        // chat template or system-prompt expectations do shift.
        "-qat-4bit",
        "-qat-8bit",
        "-mxfp4-q8",
        "-unpacked",
        "-mxfp4",
        "-2bit",
        "-3bit",
        "-4bit",
        "-6bit",
        "-8bit",
        "-ud",
        "-dwq",
    ]

    /// Strip a known quant suffix from a normalized (trimmed +
    /// lowercased) alias. Quant changes IN ISOLATION (`qwen3.6-35b-4bit`
    /// → `qwen3.6-35b-8bit`) do not warrant the banner copy — chat
    /// template, context formatting, and tool support are identical
    /// across precision variants of the same family+size. Codex r1
    /// BLOCKING.
    private static func stripQuantSuffix(_ alias: String) -> String {
        for suffix in knownQuantSuffixes where alias.hasSuffix(suffix) {
            return String(alias.dropLast(suffix.count))
        }
        return alias
    }

    /// Banner visibility predicate. The four conditions must all hold:
    ///
    ///   1. There is an active session (banner has no anchor otherwise).
    ///   2. The session has at least one user-authored turn — earlier
    ///      turns set the context the picker change would diverge from.
    ///   3. The picker alias differs from the session alias in a way
    ///      that crosses **family or size** (not just quant precision).
    ///      Comparison is case-insensitive + trimmed so capitalization
    ///      and stray whitespace in stored history don't false-alarm;
    ///      quant suffixes (`-4bit`, `-8bit`, `-mxfp4`, etc.) are
    ///      stripped before comparison so swapping precision on the
    ///      same family+size doesn't trip the warning.
    ///   4. The user hasn't already dismissed the warning for *this*
    ///      session in this app launch.
    ///
    /// Empty / whitespace-only aliases count as "no preference" and
    /// silently suppress the warning rather than producing
    /// "earlier turns were sent to **(empty)**" copy.
    static func shouldShow(_ input: ModelSwitchWarningInputs) -> Bool {
        guard let id = input.activeSessionID else { return false }
        guard input.userMessageCount > 0 else { return false }
        guard !input.dismissedSessionIDs.contains(id) else { return false }
        let session = input.sessionAlias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let picker = input.pickerAlias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !session.isEmpty, !picker.isEmpty else { return false }
        let sessionFamily = stripQuantSuffix(session)
        let pickerFamily = stripQuantSuffix(picker)
        return sessionFamily != pickerFamily
    }
}
