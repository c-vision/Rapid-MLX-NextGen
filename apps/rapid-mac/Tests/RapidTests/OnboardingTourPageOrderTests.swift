import Foundation
import Testing
@testable import Rapid

/// Welcome-tour page-lineup contract pins.
///
/// ``OnboardingTour.pageOrder`` is exposed at the type level so the
/// page-set is testable without a SwiftUI host — the rendering body
/// closes over this constant.
///
/// Why pin order: existing users (``OnboardingState.hasSeen == true``)
/// never see the tour again, so a quietly-renamed slug or a missing
/// step would leave only fresh installs without the new guidance — a
/// regression no smoke test would catch.
///
/// History:
///   * v0.4.26 — initial 4-page tour (model / system-prompt / tools /
///     quick-ask).
///   * #193 — added a 5th "Pick a search backend" page between Tools
///     and Quick Ask.
///   * v0.7.19 (#224) — dropped that 5th page. Asking first-run users
///     to choose a search backend before they've sent a single message
///     broke the "first 60 seconds feel impressive, not configurable"
///     promise. DDG default works without setup; the Brave / Tavily
///     upgrade CTAs still live in Settings → Web Search.
@Suite("OnboardingTour page lineup — issues #193 + #224")
struct OnboardingTourPageOrderTests {

    @Test("Tour ships exactly 4 pages after #224 dropped the search-backend step")
    func pageCount() {
        #expect(OnboardingTour.pageOrder.count == 4)
    }

    @Test("Slug lineup is stable: model → system-prompt → tools → quick-ask")
    func slugOrderPinned() {
        let slugs = OnboardingTour.pageOrder.map(\.slug)
        #expect(slugs == ["model", "system-prompt", "tools", "quick-ask"],
                "Slug order is part of the contract — tests, analytics, and future deep-links rely on it")
    }

    @Test("#224 regression pin: the dropped 'web-search' / 'Pick a search backend' step must NOT come back as a tour page")
    func searchBackendStepStaysDropped() {
        let slugs = OnboardingTour.pageOrder.map(\.slug)
        #expect(!slugs.contains("web-search"),
                "Issue #224: the 'Pick a search backend' tour step asked first-run users to pick a 3rd-party API key before sending a single message; reintroducing it regresses the first-60-seconds UX. If a future tour really needs a search-backend page, file a fresh design issue first.")
        // Belt-and-braces: also guard the user-facing title in case a
        // future contributor preserves the title under a renamed slug.
        for page in OnboardingTour.pageOrder {
            #expect(page.title != "Pick a search backend",
                    "Issue #224: tour page titled 'Pick a search backend' must not reappear; route users to Settings → Web Search instead")
        }
    }

    @Test("Quick Ask page still concludes the tour — it's the only flow-changing chord")
    func quickAskRemainsLastPage() {
        let slugs = OnboardingTour.pageOrder.map(\.slug)
        #expect(slugs.last == "quick-ask",
                "Quick Ask must remain the final page — finishing on a 'try this now' chord is the tour's payoff moment")
    }

    @Test("Every page has a non-empty title and body — guards against an empty page slipping through")
    func everyPageIsRendered() {
        for page in OnboardingTour.pageOrder {
            #expect(!page.title.isEmpty, "page \(page.slug) has an empty title")
            #expect(!page.body.isEmpty, "page \(page.slug) has an empty body")
            #expect(!page.icon.isEmpty, "page \(page.slug) has no SF Symbol")
        }
    }

    @Test("All page slugs are unique — guards against a copy-paste duplicating an entry")
    func slugsAreUnique() {
        let slugs = OnboardingTour.pageOrder.map(\.slug)
        #expect(Set(slugs).count == slugs.count, "duplicate slug detected — slug must uniquely identify a page for dispatch + analytics")
    }

    /// Issue #439 wiring pin. The tour's ``onDone`` closure is the
    /// single dismiss path — both Skip (Esc / button) and Get started
    /// (Return / button on the last page) route through it. A future
    /// refactor that swapped the stored closure for an environment-
    /// keyed callback, a Combine subject, or "do nothing for now" would
    /// silently re-introduce the user-hostile state that prompted the
    /// bug report (post-Quickstart relaunch, fresh-install user has no
    /// way to advance past the welcome modal).
    ///
    /// The body cannot be hosted in a Swift Testing harness without
    /// pulling in ViewInspector, so this pin verifies the wiring at
    /// the closure level: construct the tour, fire the callback the
    /// way the footer buttons fire it, observe the bound side effect.
    /// If a future contributor stops calling ``onDone`` from inside
    /// the Skip / Get started actions (the actual bug shape from #439
    /// was that the actions never ran at all — clicks dropped on the
    /// non-key window), the body-level fix sites are now flagged on
    /// the OnboardingTour root via ``.background(WindowAccessor)`` —
    /// that closure-level test couldn't catch it, but the comment on
    /// the body modifier is the second line of defence.
    @MainActor
    @Test("Tour onDone callback fires the bound side effect — issue #439 wiring pin")
    func onDoneFiresCallback() {
        var fired = 0
        let tour = OnboardingTour(onDone: { fired += 1 })
        tour.onDone()
        #expect(fired == 1, "onDone callback must invoke the bound side effect — this is the only Skip / Get started dismiss path")
        tour.onDone()
        #expect(fired == 2, "onDone must be safely re-callable — guards against a one-shot dispatch_once-style wrapper sneaking into the call site")
    }

    /// Issue #439 behaviour pin for the focus / activation seam.
    /// Without this fix, the OnboardingTour sheet appeared on a non-
    /// key NSWindow whenever the parent window wasn't the active app's
    /// keyWindow (the canonical case is the post-Quickstart relaunch
    /// where the user's foreground app is still Chrome / Finder /
    /// Slack). In that state Skip / Next / Get-started clicks AND the
    /// Esc / Return keyboard shortcuts ALL silently dropped because
    /// SwiftUI views default to ``acceptsFirstMouse=false`` and key
    /// events route to the keyWindow's first responder.
    ///
    /// ``OnboardingTour.activateForInitialInput`` is the testable seam
    /// extracted from the WindowAccessor closure in ``body``. The
    /// production call site passes the real ``NSApp`` + ``NSWindow``
    /// hooks; here we inject counters so a future contributor who
    /// reorders / drops a step gets a red test instead of a silently
    /// re-introduced stuck-tour bug.
    @Test("activateForInitialInput unconditionally activates the app — issue #439 keyboard-shortcut fix")
    func activateForInitialInputAlwaysActivatesApp() {
        var activateCalls = 0
        var makeKeyCalls = 0
        // Already-key window: makeKey should be skipped, but activate
        // must still fire so we steal the keyboard-event delivery from
        // whatever app was the active app at present-time.
        OnboardingTour.activateForInitialInput(
            window: "stub",
            isKeyWindow: { _ in true },
            activateApp: { activateCalls += 1 },
            makeKey: { _ in makeKeyCalls += 1 }
        )
        #expect(activateCalls == 1, "NSApp.activate must always fire — key-window status doesn't tell us whether we own the active-app slot")
        #expect(makeKeyCalls == 0, "makeKeyAndOrderFront must NOT run when the window is already key — avoids redundant orderFront thrash")
    }

    @Test("activateForInitialInput keys the window only when needed — issue #439 click-drop fix")
    func activateForInitialInputKeysInactiveWindow() {
        var activateCalls = 0
        var makeKeyCalls = 0
        OnboardingTour.activateForInitialInput(
            window: "stub",
            isKeyWindow: { _ in false },
            activateApp: { activateCalls += 1 },
            makeKey: { _ in makeKeyCalls += 1 }
        )
        #expect(activateCalls == 1, "NSApp.activate must run on the click-drop path too — both fixes are paired")
        #expect(makeKeyCalls == 1, "makeKeyAndOrderFront must run when the window isn't already key — addresses the acceptsFirstMouse=false click drop the user reported")
    }
}
