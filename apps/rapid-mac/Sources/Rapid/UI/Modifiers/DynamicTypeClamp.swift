import SwiftUI

/// Audit P1 (ChatView — no dynamic-type testing; >extraLarge may
/// overflow compose / crush bubbles): cap dynamic-type scaling for
/// the chat surface at ``xxxLarge`` so the five accessibility sizes
/// (AX1–AX5) don't blow out the parts of the layout that DO react
/// to dynamic type.
///
/// ## Scope contract — what this modifier actually clamps
///
/// The clamp sets the ``\.dynamicTypeSize`` environment value on
/// the wrapped subtree. That bounds:
///
///   * SwiftUI `Text` instances using an environment font
///     (`Text("hi")` with no `.font(...)` override — e.g. the user
///     and assistant bubble bodies, system-pill labels).
///   * SwiftUI text styles (`.font(.body)`, `.font(.headline)`)
///     wherever we use them.
///   * `@ScaledMetric` values that read the env (Rapid does not
///     currently use any, but a future reach would inherit the cap).
///
/// What it does NOT clamp — and the audit's "compose pill overflow"
/// concern was partly misdirected here — is content that bypasses
/// SwiftUI's dynamic-type system:
///
///   * The AppKit `NSTextView` compose editor (see
///     ``AutosizingTextView``). It uses
///     `NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))`
///     and answers to AppKit accessibility text scaling instead.
///   * Explicit `.font(.system(size: 13))` / `.font(.system(size: 16))`
///     callers — `system(size:)` is a fixed-pixel font; the env
///     scale doesn't reach those rails.
///
/// Net effect: env-driven labels and the user bubble Text get a
/// safe ceiling; the fixed-pixel rails (composer, fixed-size
/// assistant blocks) remain unchanged and would need a separate
/// per-call ``.font(.body)`` migration to participate. That migration
/// is out of scope here; this modifier is the env-level
/// belt-and-suspenders so the env-aware surfaces don't run away
/// while the fixed-pixel reflow lands.
///
/// ## Where it is wired
///
/// Applied at the three chat-shell view roots:
///
///   * `ChatView.body` — main transcript + compose chrome.
///   * `PoppedConversationView.body` — pinned-window mirror.
///   * `QuickAskView.body` — launcher panel.
///
/// In each case the call sits BEFORE the `.sheet(_:)` attachment so
/// modal editing surfaces (system prompt sheet, palette) keep the
/// inherited system-wide dynamic-type scale. Without that ordering,
/// a user on system Larger Text would see the editing sheets
/// regress to the chat-clamped size — a real accessibility loss.
extension View {
    func rapidChatDynamicTypeClamp() -> some View {
        self.dynamicTypeSize(chatDynamicTypeRange)
    }
}

/// Range used by ``rapidChatDynamicTypeClamp``. Lifted to module
/// scope so ``DynamicTypeClampTests`` can pin the upper bound + the
/// AX1–AX5 exclusion + the seven admitted non-accessibility sizes
/// without constructing a SwiftUI environment.
let chatDynamicTypeRange: ClosedRange<DynamicTypeSize> = DynamicTypeSize.xSmall...DynamicTypeSize.xxxLarge
