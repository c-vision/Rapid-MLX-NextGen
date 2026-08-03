import AppKit
import Foundation
import Testing
@testable import Rapid

/// Mechanical backstop for the v0.8.0→v0.8.2 hotfix
/// (raullenchai/Rapid-MLX#845).
///
/// Background: v0.8.0 build 117 shipped with an "optimisation" inside
/// `RapidApp.init()` that called `NSApp.setActivationPolicy(.accessory)`
/// when the persisted `HideDockChoice` was `.hideAlways`. The intent
/// was to avoid the brief "Dock icon flashes during launch" jolt for
/// users who had picked "Hide Dock icon + Don't ask again". The
/// problem: SwiftUI's `App.init()` runs BEFORE `NSApplicationMain`
/// initialises `NSApp`, so the implicitly-unwrapped optional
/// force-unwrapped `nil` → `SIGTRAP`. Every user who upgraded with
/// `hideAlways` persisted hit a 100% launch crash. The exact same
/// lesson was already documented at `RapidApp.swift:~270` for
/// `NSApp.appearance`, but a comment wasn't enough to stop the
/// regression — so this test makes the rule mechanical.
///
/// The rule: NO `NSApp.*` references between `init() {` and its
/// matching `}` inside `RapidApp.swift`. Any future "let's just
/// touch NSApp from init for X" attempt fails CI immediately.
///
/// The activation-policy flip lives in
/// `AppDelegate.applicationWillFinishLaunching` instead — `NSApp` is
/// alive by that hook and the Dock icon hasn't rendered yet, so the
/// original UX motivation is preserved without the crash.
@Suite("RapidApp.init must not touch NSApp before NSApplicationMain")
struct InitMustNotTouchNSAppTests {
    /// Locate `Sources/Rapid/RapidApp.swift` relative to this test
    /// file's compile-time path. `#filePath` resolves to
    /// `…/Tests/RapidTests/InitMustNotTouchNSAppTests.swift`, so
    /// `../..` lands at the repo root.
    private static func loadRapidAppSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // → Tests/RapidTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → repo root
        let source = repoRoot.appendingPathComponent("Sources/Rapid/RapidApp.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// Slice `RapidApp.swift` from the literal `init() {` opening of
    /// the App struct's initialiser through its matching closing
    /// brace, then strip `//`-prefixed comment lines. The remaining
    /// body is the executable code we forbid `NSApp.` inside.
    private static func executableInitBody(_ source: String) -> String {
        guard let openRange = source.range(of: "\n    init() {\n") else {
            return ""
        }
        var depth = 1
        var i = openRange.upperBound
        while depth > 0, i < source.endIndex {
            switch source[i] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            i = source.index(after: i)
        }
        let body = String(source[openRange.upperBound..<i])
        let codeLines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
        return codeLines.joined(separator: "\n")
    }

    @Test("no NSApp.* call appears inside RapidApp.init()")
    func initDoesNotTouchNSApp() throws {
        let source = try Self.loadRapidAppSource()
        let body = Self.executableInitBody(source)
        #expect(!body.isEmpty,
                "could not locate RapidApp's init() body — has the signature changed?")
        #expect(!body.contains("NSApp."), """
            RapidApp.init() must not reference NSApp.* — NSApp is nil at App.init()
            time because NSApplicationMain has not initialised it yet. The
            v0.8.0→v0.8.2 hotfix (raullenchai/Rapid-MLX#845) moved the
            activation-policy flip into AppDelegate.applicationWillFinishLaunching.
            Use that hook (or applicationDidFinishLaunching for non-Dock-visual
            setup) instead.
            """)
    }

    /// Companion functional test for the new path: with a
    /// `.hideAlways` store wired in, `applicationWillFinishLaunching`
    /// must flip the activation policy to `.accessory`. Asserts the
    /// fix actually does the thing the comment claims it does.
    /// Restores the previous policy in a `defer` so we don't poison
    /// sibling tests that observe `NSApp.activationPolicy()`.
    @Test("applicationWillFinishLaunching honours .hideAlways")
    @MainActor
    func willFinishLaunchingHonoursHideAlways() throws {
        // Force ``NSApp`` to materialise. Under ``NSApplicationMain``
        // (production launch) this is implicit; under ``swift test
        // --filter`` we have to do it ourselves or ``NSApp`` is
        // ``nil`` and the safe-unwrapped policy call in
        // ``applicationWillFinishLaunching`` no-ops. The full suite
        // previously masked this because earlier alphabetical tests
        // transitively initialised ``NSApplication.shared`` — making
        // it explicit lets ``--filter`` runs assert real behaviour.
        _ = NSApplication.shared

        let suiteName = "rapid-tests.willFinish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DockVisibilityPromptStore(initial: .hideAlways, defaults: defaults)
        let delegate = AppDelegate.shared
        let priorPolicy = NSApp?.activationPolicy() ?? .regular
        let priorStore = delegate.dockPromptStore
        defer {
            delegate.dockPromptStore = priorStore
            NSApp?.setActivationPolicy(priorPolicy)
        }
        delegate.dockPromptStore = store

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        #expect(NSApp?.activationPolicy() == .accessory)
    }

    /// Negative companion: a `.keepAlways` (or any non-`.hideAlways`)
    /// choice must NOT flip to `.accessory` inside
    /// `applicationWillFinishLaunching` — `applicationDidFinishLaunching`
    /// will set `.regular` later. This pins that
    /// `applicationWillFinishLaunching` keeps its narrow scope and
    /// doesn't over-reach.
    @Test("applicationWillFinishLaunching leaves non-hideAlways policy alone")
    @MainActor
    func willFinishLaunchingLeavesNonHideAlwaysAlone() throws {
        // See ``willFinishLaunchingHonoursHideAlways`` for why this
        // explicit ``NSApplication.shared`` reference is required to
        // run this test in isolation under ``swift test --filter``.
        _ = NSApplication.shared

        let suiteName = "rapid-tests.willFinish.keep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DockVisibilityPromptStore(initial: .keepAlways, defaults: defaults)
        let delegate = AppDelegate.shared
        let priorStore = delegate.dockPromptStore
        // Start from a known-distinguishable policy so we can assert
        // "no change happened" rather than "ended at .regular by
        // coincidence". Picking .accessory inverts the production
        // default so any spurious flip stands out.
        let priorPolicy = NSApp?.activationPolicy() ?? .regular
        NSApp?.setActivationPolicy(.accessory)
        defer {
            delegate.dockPromptStore = priorStore
            NSApp?.setActivationPolicy(priorPolicy)
        }
        delegate.dockPromptStore = store

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        #expect(NSApp?.activationPolicy() == .accessory,
                "applicationWillFinishLaunching must NOT touch the policy when choice != .hideAlways")
    }
}
