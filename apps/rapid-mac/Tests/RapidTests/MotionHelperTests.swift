import Foundation
import SwiftUI
import Testing
@testable import Rapid

/// PR3 (#547) — shared interruptible-spring + Reduce-Motion motion helper.
///
/// The reduce-motion resolution is pure and gets real behavioural coverage;
/// the view adoptions (springs on the onboarding/model-browser transitions,
/// spring autoscroll, panel cross-fade, and the Reduce-Motion-suppressed
/// looping dots) are pinned by source guards mirroring the repo's existing
/// source-grep tripwires.
@Suite("PR3 — interruptible springs + Reduce Motion (#547)")
struct MotionHelperTests {

    // MARK: - RapidMotion.resolve (pure Reduce-Motion seam)

    @Test("resolve passes the animation through when Reduce Motion is off")
    func resolvePassesThroughNormally() {
        #expect(RapidMotion.resolve(RapidMotion.standard, reduceMotion: false) == RapidMotion.standard)
        #expect(RapidMotion.resolve(RapidMotion.scroll, reduceMotion: false) == RapidMotion.scroll)
    }

    @Test("resolve collapses to nil (instant) when Reduce Motion is on")
    func resolveNilsUnderReduceMotion() {
        #expect(RapidMotion.resolve(RapidMotion.standard, reduceMotion: true) == nil)
        #expect(RapidMotion.resolve(RapidMotion.scroll, reduceMotion: true) == nil)
        #expect(RapidMotion.resolve(RapidMotion.quick, reduceMotion: true) == nil)
    }

    @Test("resolve preserves a nil input regardless of Reduce Motion")
    func resolveNilInputStaysNil() {
        #expect(RapidMotion.resolve(nil, reduceMotion: false) == nil)
        #expect(RapidMotion.resolve(nil, reduceMotion: true) == nil)
    }

    // MARK: - RapidMotion.shouldPulse (looping-dot start/stop contract)

    @Test("shouldPulse loops only when active AND Reduce Motion is off")
    func shouldPulseGatesOnBothConditions() {
        #expect(RapidMotion.shouldPulse(isAnimating: true, reduceMotion: false) == true)
        #expect(RapidMotion.shouldPulse(isAnimating: true, reduceMotion: true) == false)
        #expect(RapidMotion.shouldPulse(isAnimating: false, reduceMotion: false) == false)
        #expect(RapidMotion.shouldPulse(isAnimating: false, reduceMotion: true) == false)
    }

    @Test("shouldPulse flips off the moment Reduce Motion turns on mid-pulse")
    func shouldPulseStopsWhenReduceMotionEngages() {
        // The runtime bug this guards: a dot pulsing (isAnimating true) must
        // stop — not freeze dimmed — when the user enables Reduce Motion.
        let before = RapidMotion.shouldPulse(isAnimating: true, reduceMotion: false)
        let after = RapidMotion.shouldPulse(isAnimating: true, reduceMotion: true)
        #expect(before == true && after == false)
    }

    // MARK: - Source guards for the view adoptions

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("§3/§4: the shared motion vocabulary is springs, not fixed-duration easing")
    func motionVocabularyUsesSprings() throws {
        let src = try source("Sources/Rapid/UI/Modifiers/RapidMotion.swift")
        #expect(src.contains(".snappy(") || src.contains(".spring("),
                "RapidMotion must expose spring-based curves (interruptible, §3).")
        #expect(src.contains("func rapidAnimation"),
                "a reduce-motion-aware rapidAnimation(_:value:) modifier must exist.")
        #expect(src.contains("accessibilityReduceMotion"),
                "the modifier must consult accessibilityReduceMotion (§14).")
    }

    @Test("§14: the looping status dots suppress their loop under Reduce Motion")
    func loopingDotsHonorReduceMotion() throws {
        let sidebar = try source("Sources/Rapid/UI/SessionsSidebar.swift")
        #expect(sidebar.contains("accessibilityReduceMotion"),
                "StreamingDot must read accessibilityReduceMotion to stop its perpetual pulse.")
        let picker = try source("Sources/Rapid/UI/ModelPickerBar.swift")
        #expect(picker.contains("accessibilityReduceMotion"),
                "PulsingStateDot must read accessibilityReduceMotion to stop its breathing loop.")
    }

    @Test("§3/§4: onboarding step indicators spring instead of snapping")
    func onboardingIndicatorsSpring() throws {
        let dots = try source("Sources/Rapid/UI/OnboardingComponents.swift")
        #expect(dots.contains(".rapidAnimation("),
                "OnboardingStepDots must animate the active capsule via the shared helper.")
        let tour = try source("Sources/Rapid/UI/OnboardingTour.swift")
        #expect(tour.contains(".rapidAnimation("),
                "OnboardingTour page indicator must animate via the shared helper.")
    }

    @Test("§3: chat autoscroll jumps go through the Reduce-Motion spring seam")
    func chatAutoscrollUsesSpringSeam() throws {
        let chat = try source("Sources/Rapid/UI/ChatView.swift")
        #expect(chat.contains("RapidMotion.resolve(RapidMotion.scroll"),
                "autoscroll withAnimation blocks must route through RapidMotion.resolve.")
        #expect(!chat.contains(".easeOut(duration: 0.15)"),
                "the pre-#547 fixed-duration autoscroll easing must be gone.")
    }

    @Test("Settings and model loading swaps stay exclusive instead of cross-fading trees")
    func settingsAndBrowserAvoidOverlappingContent() throws {
        let settings = try source("Sources/Rapid/UI/SettingsView.swift")
        let detailStart = try #require(settings.range(of: "    private struct DetailCanvas"))
        let detailEnd = try #require(settings.range(
            of: "\n    enum WebSearchKeyCommit",
            range: detailStart.upperBound..<settings.endIndex
        ))
        let detail = String(settings[detailStart.lowerBound..<detailEnd.lowerBound])
        #expect(!detail.contains(".rapidAnimation("),
                "conditional Settings panels must replace exclusively; animating the container overlaps old and new trees.")
        #expect(!settings.contains(".id(selected)\n                    .transition(.opacity)"),
                "the risky .id(selected)+transition scroll-child rebuild must be gone.")

        let browser = try source("Sources/Rapid/UI/SettingsModelManagementPanel.swift")
        #expect(!browser.contains(".rapidAnimation(RapidMotion.standard, value: catalog.isEmpty)"))
        #expect(!browser.contains(".rapidAnimation(RapidMotion.standard, value: loading)"),
                "loading and loaded model trees must never be visible in the same transition.")
        #expect(!browser.contains(".rapidAnimation(RapidMotion.standard, value: showRecommendedSection)"))

        let models = try source("Sources/Rapid/UI/SettingsModelsPanel.swift")
        #expect(models.contains("@State private var loading: Bool = true"),
                "Models must render its loading state on frame one instead of flashing the empty/error state.")
        #expect(browser.contains("@State private var loading: Bool = true"),
                "Model Management must render its loading state on frame one.")
    }

    @Test("§4/§14: the remaining app-wide animation sites route through the helper")
    func appWideSitesAdoptHelper() throws {
        // Every withAnimation / .animation site the audit flagged must now be
        // Reduce-Motion-aware via the shared helper (§14 was honored in ONE
        // view before this PR).
        let content = try source("Sources/Rapid/UI/ContentView.swift")
        #expect(content.contains("RapidMotion.resolve(RapidMotion.standard"),
                "the logs drawer toggle must route through the Reduce-Motion seam.")
        let quickAsk = try source("Sources/Rapid/QuickAsk/QuickAskView.swift")
        #expect(quickAsk.contains("RapidMotion.resolve(RapidMotion.scroll"),
                "Quick Ask autoscroll must route through the Reduce-Motion spring seam.")
        let picker = try source("Sources/Rapid/UI/ModelPickerBar.swift")
        #expect(picker.contains(".rapidAnimation(RapidMotion.standard, value: deletionToast)"),
                "the picker deletion toast must animate via the shared helper.")
        let splash = try source("Sources/Rapid/Bootstrapper/SplashView.swift")
        #expect(splash.contains(".rapidAnimation("),
                "the Splash progress bar must be Reduce-Motion aware.")
    }

    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
