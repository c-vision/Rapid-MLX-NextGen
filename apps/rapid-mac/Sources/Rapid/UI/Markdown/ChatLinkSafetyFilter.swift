import SwiftUI

/// Issue #304 (security / red-team-finding): the chat surface renders
/// LLM-emitted Markdown via `MarkdownUI`. Without a custom
/// `OpenURLAction`, SwiftUI falls back to `NSWorkspace.shared.open(url)`,
/// which honours **any** URL scheme the OS has a handler for —
/// including `file://`. A compromised model, prompt-injected tool
/// result, or attacker-controlled pasted context can emit a clickable
/// link like `[click here](file:///Users/$USER/.ssh/id_rsa)`; one user
/// click opens the target in TextEdit / Preview / Finder, exposing
/// arbitrary file contents.
///
/// This filter restricts model-emitted Markdown link clicks to a
/// short, explicit allowlist: `http://`, `https://`, and `mailto:`.
/// All other schemes (`file:`, `javascript:`, `slack:`, `vscode:`,
/// `zoomus:`, `obsidian:`, `raycast:`, …) are silently dropped — the
/// text remains rendered, selectable, and copyable, but the click is
/// a no-op. Default-deny matches the threat model: the user trusts
/// the model's prose, not its filesystem side-effects.
///
/// ## Where this is applied
///
/// Every chat-surface Markdown render site that displays
/// model-emitted content:
///   * ``LaTeXMarkdownView`` (the main chat row — hot path +
///     segmented math path; the filter sits on the outer Group so
///     both branches inherit it via the environment)
///   * ``PoppedConversationView``'s message body (the "pop conversation
///     into its own window" surface)
///   * ``QuickAskView/messageRow`` (Quick Ask reuses the same
///     ``ChatViewModel``, so assistant turns flow through the same
///     model-emitted-Markdown path)
///
/// Each call site wraps its `Markdown(...)` (or, in
/// ``LaTeXMarkdownView``, the outer `Group` wrapping both rendering
/// branches) with ``View/chatLinkSafetyFilter()``. Note: the filter
/// only propagates to **descendants** of the modified view via the
/// environment — a sibling `Markdown(...)` added to the surrounding
/// `VStack` will NOT inherit it. When adding a new chat Markdown
/// render site, apply ``chatLinkSafetyFilter()`` directly to the
/// `Markdown(...)` (or to a container that wraps it).
///
/// ## Why a `View` extension (not a wrapper view)
///
/// `OpenURLAction` is propagated through `EnvironmentValues.openURL`,
/// which any descendant `Link` / Markdown-rendered link will read.
/// Installing it on the outer container is the lowest-friction
/// pattern: future contributors adding `Markdown(...)` inside a
/// chat-content subtree get the filter for free, with no per-site
/// edit required.
///
/// ## Mailto: allowed (issue #349)
///
/// `mailto:` is on the allowlist. The system mail client opens a
/// pre-populated *compose* window — it does not read local files or
/// auto-send. The user still has to click Send. Worst case is a
/// pre-filled draft to an attacker-chosen address with attacker
/// chosen subject/body, which is strictly less dangerous than
/// `file://` (arbitrary disclosure) or `javascript:` (script
/// execution). Markdown rendering of email links as no-ops surprises
/// users more than it protects them, so we widen the allowlist by
/// exactly one scheme.
///
/// `tel:`, `sms:`, `facetime:`, and other auto-dial / app-deeplink
/// schemes remain rejected: the cost-benefit on a desktop chat
/// surface does not justify the surface area today.
///
/// ## Testing
///
/// The decision function ``decide(_:)`` is exposed as a pure value
/// transform so unit tests can pin scheme-handling without standing
/// up a SwiftUI view tree. ``chatLinkSafetyAction()`` wraps it in the
/// `OpenURLAction` that's actually wired into the environment.
/// `OpenURLAction.callAsFunction(_:)` returns `Void` (the underlying
/// handler is consumed by SwiftUI), so a test that wrapped only the
/// action couldn't observe `.handled` vs `.systemAction` — the
/// pure-function seam is the right abstraction.
enum ChatLinkSafety {
    /// Schemes that pass through to the system handler. Lower-cased.
    /// Kept tight on purpose: every entry here is a new attack surface
    /// the user did not opt into. Policy: web navigation + email
    /// compose only. `tel:`, `sms:`, `facetime:`, `slack:`, `vscode:`,
    /// `file:`, `javascript:`, etc. are intentionally excluded.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Outcome a chat-surface Markdown link click should produce.
    /// Mirrors `OpenURLAction.Result` 1:1 but is `Equatable` and
    /// independent of SwiftUI so the test suite can compare directly.
    enum Decision: Equatable {
        /// Drop the click silently (rendered text stays selectable
        /// and copyable, but the click is a no-op).
        case rejected
        /// Forward the URL to the system handler (`NSWorkspace`).
        case allowed(URL)
    }

    /// Pure decision function. Public seam for ``chatLinkSafetyAction``
    /// and the test suite. Scheme comparison is case-insensitive.
    static func decide(_ url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            // Silently drop. Rationale: a confirm-sheet ("open
            // this file:// URL?") trains users to click "yes" on
            // suspicious prompts — worse than a silent no-op
            // when the rendered text is still visible and
            // copyable. We can iterate to a sheet later if the
            // muscle-memory cost outweighs the safety win.
            return .rejected
        }
        return .allowed(url)
    }

    /// Build the `OpenURLAction` used by ``View/chatLinkSafetyFilter()``.
    /// Bridges ``decide(_:)`` to SwiftUI's `OpenURLAction.Result` enum.
    @MainActor
    static func chatLinkSafetyAction() -> OpenURLAction {
        OpenURLAction { url in
            switch decide(url) {
            case .allowed(let safe):
                return .systemAction(safe)
            case .rejected:
                return .handled
            }
        }
    }
}

extension View {
    /// Restrict model-emitted Markdown link clicks rendered by this
    /// view (and any descendants) to the ``ChatLinkSafety``
    /// allowlist (`http`, `https`, `mailto`). All other schemes are
    /// silently dropped. See ``ChatLinkSafety``.
    func chatLinkSafetyFilter() -> some View {
        self.environment(\.openURL, ChatLinkSafety.chatLinkSafetyAction())
    }
}
