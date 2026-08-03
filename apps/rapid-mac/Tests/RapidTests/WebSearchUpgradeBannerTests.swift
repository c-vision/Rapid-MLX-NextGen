import Foundation
import Testing
@testable import Rapid

/// Issue #193 contract pins for the Settings → Web Search upgrade
/// banner predicate ``SettingsView.shouldShowDDGUpgradeBanner``.
/// The view itself can't be exercised without a SwiftUI host, but
/// every branch of the predicate that drives visibility is pure and
/// covered here. The predicate is the only first-use guidance gate
/// that ships in production today, so a regression that silently
/// hides (or surfaces forever) is a real UX miss.
@MainActor
@Suite("WebSearch upgrade banner predicate — issue #193")
final class WebSearchUpgradeBannerTests {
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults(
        name: String = TestDefaultsScope.mintSuiteName(prefix: "rapid-web-search-banner-test-")
    ) -> UserDefaults {
        createdSuiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Show branch

    @Test("Banner shows on fresh install — default DDG + no keys stored")
    func showsOnFreshInstall() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(cfg.provider == .duckduckgo, "Precondition: fresh config defaults to DDG")
        #expect(SettingsView.shouldShowDDGUpgradeBanner(config: cfg),
                "Fresh install on DDG with no keys must surface the upgrade nudge")
    }

    // MARK: - Hide branches

    @Test("Banner hides when provider is Brave (explicit user choice)")
    func hidesWhenProviderIsBrave() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.provider = .brave
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg),
                "An explicit non-DDG provider means the user has already engaged the picker — never re-nag")
    }

    @Test("Banner hides when provider is Tavily (explicit user choice)")
    func hidesWhenProviderIsTavily() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.provider = .tavily
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg))
    }

    @Test("Banner hides on DDG when a Brave key is stored (user has paid-backend setup in flight)")
    func hidesWhenBraveKeyStoredEvenIfBackOnDDG() {
        // Simulates the auto-promote-then-clear path: user pasted a
        // Brave key (auto-promote flipped provider to .brave), later
        // switched back to .duckduckgo explicitly. Key is still on
        // disk; the explicit return to DDG is the choice we honour
        // without renagging.
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("BSA-key", for: .brave)
        cfg.provider = .duckduckgo
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg),
                "A stored Brave key signals prior engagement — DDG is now a deliberate choice, not a default")
    }

    @Test("Banner hides on DDG when a Tavily key is stored")
    func hidesWhenTavilyKeyStoredEvenIfBackOnDDG() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("tvly-key", for: .tavily)
        cfg.provider = .duckduckgo
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg))
    }

    @Test("Banner hides when BOTH paid keys are stored on DDG")
    func hidesWhenBothPaidKeysStored() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("BSA-key", for: .brave)
        cfg.setAPIKey("tvly-key", for: .tavily)
        cfg.provider = .duckduckgo
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg))
    }

    // MARK: - Re-show after clear

    @Test("Banner reappears when paid keys are cleared and provider is back on DDG")
    func reappearsAfterPaidKeysCleared() {
        // Edge case: user pasted then cleared keys, ended back on DDG.
        // No paid keys on disk + DDG provider → re-show. The upgrade
        // nudge is the only surface that will steer them to a paid
        // backend, so hiding it would silently block recovery.
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("BSA-key", for: .brave)
        cfg.provider = .duckduckgo
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(config: cfg))
        cfg.setAPIKey(nil, for: .brave)
        #expect(SettingsView.shouldShowDDGUpgradeBanner(config: cfg),
                "After clearing the only stored paid key the banner must re-surface — it's the user's path back to a sharper backend")
    }

    // MARK: - Dashboard URL pins

    @Test("Brave dashboard URL jumps to /app/keys (one click closer than the marketing landing)")
    func braveDashboardURLPin() {
        let url = WebSearchProvider.brave.keyDashboardURL
        #expect(url?.absoluteString == "https://api.search.brave.com/app/keys",
                "Brave dashboard URL must point at the keys list, not the public docs landing")
        #expect(url?.scheme == "https")
    }

    @Test("Tavily dashboard URL points at the /home dashboard")
    func tavilyDashboardURLPin() {
        let url = WebSearchProvider.tavily.keyDashboardURL
        #expect(url?.absoluteString == "https://app.tavily.com/home")
        #expect(url?.scheme == "https")
    }

    @Test("DuckDuckGo has no dashboard URL (it doesn't issue keys)")
    func ddgHasNoDashboardURL() {
        #expect(WebSearchProvider.duckduckgo.keyDashboardURL == nil)
    }
}
