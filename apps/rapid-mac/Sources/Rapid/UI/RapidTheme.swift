import SwiftUI

/// Centralised colour + dimension tokens for the v0.4 refresh.
///
/// The pre-v0.4 surface composed colours ad-hoc at the call site
/// (``Color.accentColor.opacity(0.22)`` on the user bubble,
/// ``Color.secondary.opacity(0.12)`` on the tools chip, system
/// material on the sidebar, etc.). That made it impossible to keep
/// the chrome cohesive — the surfaces drifted apart visually as
/// individual call sites tweaked their opacity values.
///
/// This file exists so every chat-surface paint goes through a
/// single token. When we want to dial the canvas darker or warm
/// the user bubble, we change one constant here instead of
/// chasing the literal across four views.
///
/// All tokens are dark/light aware via ``Color(nsColor:)`` and
/// ``NSColor(name:dynamicProvider:)``. Snapshot tests pin
/// ``NSAppearance.aqua`` so the light variants are what get
/// asserted; manual launch verifies the dark variants by eye.
enum RapidTheme {
    // MARK: - Brand accent
    //
    // The single source of truth for "Rapid blue." Before this token
    // the app leaned on ``Color.accentColor`` everywhere, which is
    // whatever accent the user picked in macOS System Settings — so
    // the product could render pink, graphite, or orange and never
    // reliably showed the Rapid-MLX identity. This is a *softer
    // azure* than the indigo wordmark on the GitHub banner: calmer in
    // a large light UI, friendlier, and still unmistakably "Rapid."
    //
    // Applied app-wide via ``.tint(RapidTheme.brand)`` at the scene
    // root (so every button / link / selection inherits it) AND used
    // directly wherever a literal ``Color.accentColor`` used to paint
    // a brand surface (the empty-state disc, capability glyphs, the
    // compose focus ring). The dark variant lifts toward a brighter
    // sky-blue so the accent keeps its punch against a dark canvas.
    //
    // v0.5: shifted from azure (#2F75EC) toward a softer blue-violet
    // (#5E7CFF) — the Rapid-MLX brand hue. It reads as friendlier and
    // less "default macOS system blue" in a large light UI, matching
    // the ChatGPT / Linear / Apple-desktop feel the refresh targets.
    // v0.6: realigned to the rapidmlx.com design system. ``brand`` is
    // now the website's muted *steel blue* (`--accent` #3A5C86), NOT
    // the old saturated blue-violet and NOT macOS system blue. Paired
    // with a warm amber-gold (the cheetah hue) defined below.
    static let brand = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x6E/255.0, green: 0x96/255.0, blue: 0xC8/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0x3A/255.0, green: 0x5C/255.0, blue: 0x86/255.0, alpha: 1.0)
    }))

    /// Bright blue highlight (`--accent-hi` #7EA8FF) — focus rings and
    /// "live"/hover accents that want a little more pop than ``brand``.
    static let brandHi = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x9C/255.0, green: 0xBE/255.0, blue: 0xFF/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0x7E/255.0, green: 0xA8/255.0, blue: 0xFF/255.0, alpha: 1.0)
    }))

    /// Soft blue wash (`--accent-tint` #EEF2F7) — the calm tinted fill
    /// behind brand-adjacent surfaces that should NOT be a saturated
    /// block: the active sidebar row, status pills, the setup-card icon
    /// halo. Dark mode is the site's deep blue tint.
    static let brandTint = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x1E/255.0, green: 0x2A/255.0, blue: 0x3A/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xEE/255.0, green: 0xF2/255.0, blue: 0xF7/255.0, alpha: 1.0)
    }))

    // MARK: - Brand amber (the cheetah-fur hue)

    /// Brand amber-gold (#EFA23A) — energy accents, the primary CTAs
    /// (New chat / Start), the mascot glow, loading states, leopard
    /// spots. This is the warm "yellow" of the Rapid brand.
    static let amber = Color(nsColor: .init(name: nil, dynamicProvider: { _ in
        NSColor(deviceRed: 0xEF/255.0, green: 0xA2/255.0, blue: 0x3A/255.0, alpha: 1.0)
    }))

    /// Deeper amber — amber text / glyphs that need more contrast on a
    /// light surface (raw ``amber`` is a touch light for small text).
    /// A darker shade of the same #EFA23A hue; dark mode uses the
    /// lighter ``amber``.
    static let amberDeep = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0xEF/255.0, green: 0xA2/255.0, blue: 0x3A/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xC9/255.0, green: 0x82/255.0, blue: 0x1F/255.0, alpha: 1.0)
    }))

    /// Soft amber wash (`--amber-tint` #FBF1E2) — warm cream fill
    /// behind mascot / setup / energy surfaces.
    static let amberTint = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x2A/255.0, green: 0x21/255.0, blue: 0x13/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xFB/255.0, green: 0xF1/255.0, blue: 0xE2/255.0, alpha: 1.0)
    }))

    /// Speed / success green (`--green` #2E7D55). Reserved for the
    /// "ready" server state — part of the existing status semantics.
    static let green = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x5F/255.0, green: 0xC7/255.0, blue: 0xA0/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0x2E/255.0, green: 0x7D/255.0, blue: 0x55/255.0, alpha: 1.0)
    }))

    // MARK: - Surfaces
    //
    // Card + hairline tokens introduced for the v0.5 light-first pass.
    // The refresh leans on rounded "cards" (settings sections, the
    // setup panel) floating on the window canvas; these two tokens
    // keep every card visually consistent instead of each call site
    // hand-rolling ``Color.secondary.opacity(0.x)``.

    /// App canvas — the off-white surface the chat sits on. A hair
    /// cooler and darker than pure white in light mode so white
    /// ``card`` surfaces and the compose pill read as gently raised
    /// above it (the ChatGPT / Linear "soft gray canvas, white
    /// content" separation). Dark mode is a near-black that's a touch
    /// lifted off pure black for depth.
    static let canvas = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        // v0.6: warm off-white (was cool #F7F7FA) so the canvas pairs
        // with the amber/cheetah accents; dark = the site's `--bg`.
        appearance.isDark ? NSColor(deviceRed: 0x15/255.0, green: 0x17/255.0, blue: 0x1B/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xF8/255.0, green: 0xF7/255.0, blue: 0xF4/255.0, alpha: 1.0)
    }))

    /// Elevated card fill — a hair lighter than the window canvas in
    /// light mode (near-white), a hair lighter than black in dark
    /// mode. Reads as a raised surface without a heavy drop shadow.
    static let card = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x1A/255.0, green: 0x1D/255.0, blue: 0x21/255.0, alpha: 1.0)
                          : NSColor.white
    }))

    /// Sidebar surface — a faintly blue-tinted off-white that reads as
    /// a distinct, calm rail next to the warm chat ``canvas`` (subtle
    /// separation without a hard divider). Dark mode is a hair off the
    /// canvas so the rail still reads as its own plane.
    static let sidebarSurface = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x18/255.0, green: 0x1A/255.0, blue: 0x1F/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xF3/255.0, green: 0xF5/255.0, blue: 0xF9/255.0, alpha: 1.0)
    }))

    /// Hairline border around cards / inputs (`--line-soft`). A defined
    /// but quiet warm-gray edge in light mode (pairs with the warm
    /// canvas); the site's soft line in dark mode.
    static let hairline = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x26/255.0, green: 0x2B/255.0, blue: 0x31/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xE7/255.0, green: 0xE6/255.0, blue: 0xE1/255.0, alpha: 1.0)
    }))

    /// Standard corner radius for the refresh's rounded cards.
    static let cardRadius: CGFloat = 12

    // MARK: - Message paint
    // The v0.4 scope deliberately limits theme tokens to surfaces the
    // refresh actually repaints — the user pill and the compose pill.
    // A canvas / sidebar / divider token was drafted alongside but
    // dropped before merge: leaving tokens defined-but-unused was
    // worse than no token at all (codex round 1 P1). When the v0.5
    // pass extends the refresh to the window canvas + sidebar
    // material, reintroduce them with the same dark/light dynamic
    // provider pattern below.

    /// Right-aligned user pill background. Warm gray in both
    /// modes — NOT the accent colour, which the v0.3 build leaned
    /// on. ChatGPT-Desktop's user bubble is purely a neutral
    /// container; the accent is reserved for actions.
    static let userBubble = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x33/255.0, green: 0x31/255.0, blue: 0x3D/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xEC/255.0, green: 0xEC/255.0, blue: 0xEE/255.0, alpha: 1.0)
    }))

    /// Foreground text on the user bubble. Auto-flips to white in
    /// dark mode; the system ``.primary`` already does this but
    /// being explicit lets snapshot tests assert a known value.
    static let userBubbleText = Color.primary

    // MARK: - Compose pill

    /// Compose pill background — a warm off-white surface that
    /// reads as actionable. Sits one step elevated above whatever
    /// the system window background paints behind it; the chosen
    /// hex pair is calibrated so the pill is visually distinct
    /// even when the window canvas inherits a neutral system
    /// colour.
    static let composePill = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x2A/255.0, green: 0x28/255.0, blue: 0x33/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xEF/255.0, green: 0xEE/255.0, blue: 0xEC/255.0, alpha: 1.0)
    }))

    /// Subtle outline around the compose pill. A 1-pt hairline is
    /// enough to lift it off the canvas without competing with
    /// the focus ring.
    static let composePillStroke = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(white: 1.0, alpha: 0.06)
                          : NSColor(white: 0.0, alpha: 0.08)
    }))

    /// Send/stop circle fill — high-contrast inverse of the
    /// canvas (black in light mode, near-white in dark mode).
    /// Matches ChatGPT-Desktop's compose-row CTA which uses a
    /// solid neutral so the send action reads as the primary
    /// affordance regardless of the user's system accent.
    static let sendButton = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(white: 0.94, alpha: 1.0)
                          : NSColor(white: 0.08, alpha: 1.0)
    }))

    /// Icon foreground on the send button. Inverse of
    /// ``sendButton`` so the arrow/stop glyph always reads at
    /// AAA contrast.
    static let sendButtonIcon = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(white: 0.08, alpha: 1.0)
                          : NSColor(white: 1.0, alpha: 1.0)
    }))

    /// Disabled-state fill for the send button — the same hue
    /// at ~30% opacity. Keeps the affordance visible (so the
    /// user can see WHERE the button is) without inviting a
    /// click that won't fire.
    static let sendButtonDisabled = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(white: 0.94, alpha: 0.28)
                          : NSColor(white: 0.08, alpha: 0.28)
    }))

    // MARK: - Brand (v0.5.6 — rapidmlx.com alignment)
    //
    // The site's brand spec (PR #1 on raullenchai/rapidmlx.com,
    // landed 2026-06-12) standardises on amber for speed / live /
    // selected accents and forbids blue → amber gradients (solid
    // colours only). Steel-blue remains the engineering/data accent
    // but lives off the chat surface. The desktop empty-state hero
    // previously used ``Color.accentColor`` which falls back to the
    // user's system accent — a saturated blue on most machines —
    // and read as "default SwiftUI sample." These tokens pull the
    // chrome into the brand the user sees in the browser.

    /// Amber-tint background for the hero disc. Mirrors the site's
    /// ``--amber-tint`` (#FBF1E2 / #2A2113). Solid fill, no gradient
    /// — per the site spec, no two-stop blends on the brand axis.
    static let brandAmberTint = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0x2A/255.0, green: 0x21/255.0, blue: 0x13/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xFB/255.0, green: 0xF1/255.0, blue: 0xE2/255.0, alpha: 1.0)
    }))

    /// Deep amber for the cheetah silhouette on the hero disc.
    /// Site's ``--amber`` (#CC8730 light) lifts to ``--amber #E0A95A``
    /// in dark mode for legibility against the dark-tint surface.
    static let brandAmber = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
        appearance.isDark ? NSColor(deviceRed: 0xE0/255.0, green: 0xA9/255.0, blue: 0x5A/255.0, alpha: 1.0)
                          : NSColor(deviceRed: 0xCC/255.0, green: 0x87/255.0, blue: 0x30/255.0, alpha: 1.0)
    }))

    // MARK: - Dimensions

    /// Corner radius for the user bubble. 18 reads as a true
    /// pill at the 2-line common case — anything smaller looks
    /// like a square-with-rounded-corners chip.
    static let userBubbleRadius: CGFloat = 18

    /// Compose pill corner radius. v0.5: tightened 22 → 18 to match
    /// the user bubble exactly — the larger radius read as a bubbly,
    /// oversized field; 18 is calmer and more "modern AI input."
    static let composePillRadius: CGFloat = 18
}

private extension NSAppearance {
    /// True if this appearance asks for a dark surface. Covers
    /// the two macOS dark names (aqua-dark and accessibility
    /// high-contrast dark). ``bestMatch`` returns the first
    /// matching name so we can ask "is this aqua-light or
    /// aqua-dark?" without enumerating every variant.
    var isDark: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastDarkAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }
}
