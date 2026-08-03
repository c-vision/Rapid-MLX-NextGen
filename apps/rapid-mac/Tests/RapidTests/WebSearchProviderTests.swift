import Foundation
import Testing
@testable import Rapid

/// v0.4.41 contract pins for the multi-provider web_search rewrite.
/// Three layers tested:
///
///   1. ``WebSearchProvider`` static metadata — display names,
///      key requirement, Keychain account naming. These drive
///      the Settings UI and the dispatcher's fallback logic.
///   2. ``WebSearchConfig`` round-trips — provider preference
///      persists to UserDefaults; keys persist via the injected
///      ``KeychainStoring``. The in-memory keychain stub keeps
///      the suite hermetic.
///   3. ``BraveSearchClient`` / ``TavilySearchClient`` request
///      construction — URL, headers, body shape. Network is not
///      hit; we just inspect the URLRequest produced.
@MainActor
@Suite("WebSearchProvider — v0.4.41 multi-backend contract")
final class WebSearchProviderTests {
    /// See ``TestDefaultsScope`` + issue #139 — RAII teardown for
    /// the ``UserDefaults(suiteName:)`` plists this suite mints.
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults(
        name: String = TestDefaultsScope.mintSuiteName(prefix: "rapid-web-search-provider-test-")
    ) -> UserDefaults {
        createdSuiteNames.append(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Provider metadata

    @Test("DuckDuckGo never requires a key")
    func ddgIsKeyless() {
        #expect(!WebSearchProvider.duckduckgo.requiresKey)
        #expect(WebSearchProvider.duckduckgo.keychainAccount == nil)
        #expect(WebSearchProvider.duckduckgo.keyConsoleURL == nil)
    }

    @Test("Brave + Tavily both require a key")
    func paidProvidersRequireKey() {
        #expect(WebSearchProvider.brave.requiresKey)
        #expect(WebSearchProvider.tavily.requiresKey)
        #expect(WebSearchProvider.brave.keychainAccount != nil)
        #expect(WebSearchProvider.tavily.keychainAccount != nil)
        #expect(WebSearchProvider.brave.keychainAccount != WebSearchProvider.tavily.keychainAccount,
                "Per-provider account names must differ — a Brave key must never leak into a Tavily slot")
    }

    @Test("Console URLs are real HTTPS hosts")
    func consoleURLsAreHTTPS() {
        for p in [WebSearchProvider.brave, .tavily] {
            let url = p.keyConsoleURL
            #expect(url != nil, "\(p.displayName) must surface a key-console URL")
            #expect(url?.scheme == "https", "\(p.displayName) console must be HTTPS")
        }
    }

    // MARK: - WebSearchConfig persistence

    @Test("Default provider on a fresh defaults store is DuckDuckGo")
    func defaultProviderIsDDG() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(cfg.provider == .duckduckgo)
        #expect(cfg.currentProviderUsable, "DDG must always be usable — no key required")
    }

    @Test("Provider choice round-trips through UserDefaults")
    func providerPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let keychain = InMemoryKeychain()
        let first = WebSearchConfig(defaults: defaults, keychain: keychain)
        first.provider = .brave
        let second = WebSearchConfig(defaults: defaults, keychain: keychain)
        #expect(second.provider == .brave, "A fresh instance must read the persisted provider")
    }

    @Test("Brave key write/read/clear round-trips via the keychain stub")
    func braveKeyRoundTrip() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.provider = .brave
        #expect(cfg.apiKey(for: .brave) == nil)
        #expect(!cfg.currentProviderUsable, "Brave without a key must not be usable")
        cfg.setAPIKey("BSA-real-key-here", for: .brave)
        #expect(cfg.apiKey(for: .brave) == "BSA-real-key-here")
        #expect(cfg.currentProviderUsable, "Brave with a key must be usable")
        cfg.setAPIKey(nil, for: .brave)
        #expect(cfg.apiKey(for: .brave) == nil, "Passing nil must clear the key")
    }

    @Test("Empty / whitespace-only key clears the slot (defensive against paste fumbles)")
    func whitespaceKeyClears() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("genuine-key", for: .tavily)
        #expect(cfg.apiKey(for: .tavily) == "genuine-key")
        cfg.setAPIKey("   \n\t  ", for: .tavily)
        #expect(cfg.apiKey(for: .tavily) == nil, "Whitespace-only writes must clear, not pretend to set")
    }

    @Test("Keys do NOT cross-contaminate between providers")
    func providerKeysAreIsolated() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("brave-key", for: .brave)
        cfg.setAPIKey("tavily-key", for: .tavily)
        #expect(cfg.apiKey(for: .brave) == "brave-key")
        #expect(cfg.apiKey(for: .tavily) == "tavily-key")
        cfg.setAPIKey(nil, for: .brave)
        #expect(cfg.apiKey(for: .brave) == nil)
        #expect(cfg.apiKey(for: .tavily) == "tavily-key", "Clearing one provider's key must not touch the other")
    }

    // MARK: - Auto-promote on key paste
    //
    // Closes the silent-broken UX where a user pastes a Brave or
    // Tavily key in Settings but ``provider`` stays on the install
    // default ``.duckduckgo`` — their key is stored but the next
    // ``web_search`` call still hits DDG (which is rate-limited /
    // bot-blocked in production today). The promote ONLY fires from
    // the default DDG state; explicit user choices win.

    @Test("Pasting first Tavily key on default DDG auto-promotes to Tavily")
    func autoPromoteFromDDGToTavilyOnFirstKey() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(cfg.provider == .duckduckgo, "Precondition: fresh config starts on DDG")
        cfg.setAPIKey("tvly-real", for: .tavily)
        #expect(cfg.provider == .tavily,
                "Auto-promote from default DDG to the keyed paid backend so the pasted key actually gets used")
    }

    @Test("Pasting first Brave key on default DDG auto-promotes to Brave")
    func autoPromoteFromDDGToBraveOnFirstKey() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        #expect(cfg.provider == .duckduckgo, "Precondition: fresh config starts on DDG")
        cfg.setAPIKey("BSA-real", for: .brave)
        #expect(cfg.provider == .brave,
                "Auto-promote from default DDG to the keyed paid backend so the pasted key actually gets used")
    }

    @Test("Explicit Brave selection wins when a Tavily key is later pasted")
    func noPromoteWhenUserExplicitlyOnAnotherPaidProvider() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.provider = .brave // explicit user choice — not the install default
        cfg.setAPIKey("tvly", for: .tavily)
        #expect(cfg.provider == .brave,
                "Explicit non-DDG selection must not be silently overwritten by a key paste for the other paid backend")
    }

    @Test("Empty key does not promote (clearing is not an opt-in)")
    func noPromoteOnEmptyKey() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("", for: .tavily)
        #expect(cfg.provider == .duckduckgo,
                "An empty key is a clear, not an opt-in — must not flip the provider away from DDG")
    }

    @Test("Whitespace-only key does not promote")
    func noPromoteOnWhitespaceOnlyKey() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("   \n\t  ", for: .tavily)
        #expect(cfg.provider == .duckduckgo,
                "Whitespace trims to empty — same clear semantics, must not promote")
    }

    @Test("Clearing a key after auto-promote does NOT demote back to DDG")
    func noDemoteWhenClearingAfterPromote() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("tvly", for: .tavily)
        #expect(cfg.provider == .tavily, "Precondition: auto-promote landed")
        cfg.setAPIKey(nil, for: .tavily)
        #expect(cfg.provider == .tavily,
                "Clearing the key must not silently flip the user back to DDG — they can switch manually in Settings")
    }

    // Codex r1 P2: SystemKeychain.write returns false on a real
    // Keychain failure (entitlement / locked DB). If we promote on a
    // failed write, the user lands on a paid provider with no key —
    // ``currentProviderUsable`` is false, and on next launch defaults
    // restores a "selected Brave, getting DDG" state with nothing
    // explaining why. Gate promotion on write success.
    @Test("No promote when the keychain write itself fails")
    func noPromoteWhenKeychainWriteFails() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: FailingWriteKeychain())
        cfg.setAPIKey("tvly", for: .tavily)
        #expect(cfg.provider == .duckduckgo,
                "A failed keychain write must not silently change the provider — leaves the user on a usable backend")
        #expect(cfg.apiKey(for: .tavily) == nil,
                "On write failure the cache must also stay empty so apiKey() is honest about the on-disk state")
    }
}

/// Test double that simulates ``SystemKeychain.write`` returning
/// false (real-world: locked Keychain DB, missing entitlement,
/// item-class collision). ``delete`` still succeeds because that's
/// the documented behavior for absent-item deletes and we want the
/// failure surface to be exactly ``write``.
private final class FailingWriteKeychain: KeychainStoring, @unchecked Sendable {
    func read(account: String) -> String? { nil }
    func write(account: String, secret: String) -> Bool { false }
    func delete(account: String) -> Bool { true }
}

/// Test double for codex r2 P2 pin: simulates a Keychain that
/// has a pre-existing key on disk (returned by ``read``), but
/// whose ``write`` fails (e.g. DB locked between read and write).
/// Used to prove that a failed write does NOT negative-cache the
/// account — the still-on-disk key must remain resolvable.
private final class PreExistingKeyFailingWriteKeychain: KeychainStoring, @unchecked Sendable {
    let existing: String
    init(existing: String) { self.existing = existing }
    func read(account: String) -> String? { existing }
    func write(account: String, secret: String) -> Bool { false }
    func delete(account: String) -> Bool { true }
}

// Codex r2 P2 pin lives in the suite extension below so it can
// reach freshDefaults().
extension WebSearchProviderTests {
    @Test("Failed write does NOT negative-cache an existing on-disk key")
    func failedWriteDoesNotNegativeCacheExistingKey() {
        // A previous successful write left a real key on disk;
        // a later in-process write attempt fails (locked DB).
        // ``apiKey(for:)`` must still resolve the on-disk value
        // — short-circuiting to nil would silently disable the
        // provider until the app restarts.
        let cfg = WebSearchConfig(
            defaults: freshDefaults(),
            keychain: PreExistingKeyFailingWriteKeychain(existing: "previously-stored-tvly-key")
        )
        cfg.setAPIKey("new-tvly", for: .tavily) // write fails inside
        #expect(cfg.apiKey(for: .tavily) == "previously-stored-tvly-key",
                "A failed write must not mark the account probed — the still-on-disk key must remain readable")
    }

    // v0.6.7 Save-button feedback contract — ``setAPIKey`` returns a
    // Bool so the UI banner can render "Saved ✓" only when the write
    // actually landed in the Keychain. The previous shape silently
    // dropped failures and the banner would have lied to the user.

    @Test("setAPIKey returns true on a successful write")
    func setAPIKeyReturnsTrueOnSuccessfulWrite() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        let ok = cfg.setAPIKey("BSA-good", for: .brave)
        #expect(ok, "A successful Keychain write must surface true so the Saved-banner fires.")
    }

    @Test("setAPIKey returns true on a successful clear")
    func setAPIKeyReturnsTrueOnSuccessfulClear() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        cfg.setAPIKey("BSA-good", for: .brave)
        let ok = cfg.setAPIKey(nil, for: .brave)
        #expect(ok, "A successful Keychain delete must surface true so the Cleared-banner fires.")
        #expect(cfg.apiKey(for: .brave) == nil)
    }

    @Test("setAPIKey returns true when clearing an account that was never set")
    func setAPIKeyReturnsTrueOnRedundantClear() {
        // ``InMemoryKeychain.delete`` is idempotent — clearing a
        // never-written account must surface success so a Clear-key
        // tap on a fresh install doesn't render a misleading
        // "Couldn't save" banner.
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        let ok = cfg.setAPIKey(nil, for: .brave)
        #expect(ok, "Idempotent clears must surface true so the Cleared-banner fires.")
    }

    @Test("setAPIKey returns false when the Keychain write itself fails")
    func setAPIKeyReturnsFalseOnFailedWrite() {
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: FailingWriteKeychain())
        let ok = cfg.setAPIKey("tvly", for: .tavily)
        #expect(!ok, "A failed Keychain write must surface false so the UI shows the 'Couldn't save' banner instead of the success toast.")
        #expect(cfg.apiKey(for: .tavily) == nil)
    }

    @Test("setAPIKey returns false for a provider that requires no Keychain account (DDG)")
    func setAPIKeyReturnsFalseForDuckDuckGo() {
        // DDG has no ``keychainAccount`` so there is no write to
        // succeed. A caller asking us to set a DDG key is buggy; we
        // return false so the inline banner reflects the no-op.
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: InMemoryKeychain())
        let ok = cfg.setAPIKey("nonsense", for: .duckduckgo)
        #expect(!ok)
    }
}

/// Brave + Tavily request-shape pins. The actual upstream calls are
/// not exercised — every test inspects the URLRequest the client
/// produces so a future refactor that breaks the header name, the
/// query-param shape, or the JSON body schema fails locally rather
/// than only being caught by a billable live call.
@Suite("WebSearchClients — v0.4.41 request shapes")
struct WebSearchClientsTests {
    // MARK: - Brave

    @Test("Brave URL carries the q + count + safesearch params")
    func braveURLShape() {
        let req = BraveSearchClient.buildRequest(query: "claude code", apiKey: "k", count: 6)
        #expect(req != nil)
        let url = req?.url
        #expect(url?.host == "api.search.brave.com")
        #expect(url?.path == "/res/v1/web/search")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = components?.queryItems ?? []
        #expect(items.contains(where: { $0.name == "q" && $0.value == "claude code" }))
        #expect(items.contains(where: { $0.name == "count" && $0.value == "6" }))
        #expect(items.contains(where: { $0.name == "safesearch" && $0.value == "moderate" }))
    }

    @Test("Brave key rides in X-Subscription-Token, NEVER in the URL or body")
    func braveKeyInHeaderOnly() {
        let req = BraveSearchClient.buildRequest(query: "x", apiKey: "secret-brave", count: 6)
        #expect(req?.value(forHTTPHeaderField: "X-Subscription-Token") == "secret-brave")
        #expect(req?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req?.url?.absoluteString.contains("secret-brave") == false,
                "API key must NEVER appear in the URL — would leak into HTTP logs and Sentry breadcrumbs")
        #expect(req?.httpMethod == "GET")
        #expect(req?.httpBody == nil, "Brave is GET — no body to leak the key into")
    }

    @Test("Brave JSON envelope parses into Result rows")
    func braveResponseParse() throws {
        let payload = """
        {
          "web": {
            "results": [
              {"title": "Anthropic", "url": "https://anthropic.com", "description": "Maker of Claude"},
              {"title": "Bad scheme",  "url": "javascript:alert(1)",  "description": "Should be filtered"},
              {"title": "rapid-mlx", "url": "https://github.com/rapidmlx/rapid-mlx", "description": "Local engine"}
            ]
          }
        }
        """.data(using: .utf8)!
        let results = BraveSearchClient.parseResults(payload, cap: 6)
        #expect(results.count == 2, "javascript:// hit must be filtered out by isSafeHttpURL")
        #expect(results[0].title == "Anthropic")
        #expect(results[1].url == "https://github.com/rapidmlx/rapid-mlx")
    }

    // MARK: - Tavily

    @Test("Tavily request is POST application/json with key inside the body")
    func tavilyRequestShape() throws {
        let req = TavilySearchClient.buildRequest(query: "MLX", apiKey: "tvly-key", maxResults: 6)
        #expect(req != nil)
        #expect(req?.httpMethod == "POST")
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req?.url?.absoluteString == "https://api.tavily.com/search")
        // Tavily's documented contract is key-in-body. Headers
        // would silently succeed but leak telemetry into request
        // logs that the user didn't opt into.
        guard let body = req?.httpBody else {
            Issue.record("Tavily request must carry a JSON body")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(parsed?["api_key"] as? String == "tvly-key")
        #expect(parsed?["query"] as? String == "MLX")
        #expect(parsed?["max_results"] as? Int == 6)
        #expect(parsed?["search_depth"] as? String == "basic")
    }

    @Test("Tavily JSON envelope parses into Result rows")
    func tavilyResponseParse() throws {
        let payload = """
        {
          "results": [
            {"title": "Hello", "url": "https://example.com", "content": "First snippet"},
            {"title": "World", "url": "https://example.org", "content": "Second snippet"}
          ]
        }
        """.data(using: .utf8)!
        let results = TavilySearchClient.parseResults(payload, cap: 6)
        #expect(results.count == 2)
        #expect(results[0].title == "Hello")
        #expect(results[1].snippet == "Second snippet")
    }

    // MARK: - Codex audit batch 6 (WebSearchClients.swift:31, P2)
    //
    // Reject API keys that contain CR/LF or other ASCII control
    // bytes BEFORE they reach URLRequest.setValue. URLRequest does
    // not validate header values for CRLF on its own — a key with
    // an embedded \r\n would let the model (or a hostile clipboard)
    // inject a second HTTP header.

    @Test("Brave key with CRLF is refused (header-injection defense)")
    func braveKeyWithCRLFRefused() {
        let req = BraveSearchClient.buildRequest(
            query: "MLX",
            apiKey: "good-key\r\nX-Evil: injected",
            count: 6
        )
        #expect(req == nil)
    }

    @Test("Brave key with NUL byte is refused")
    func braveKeyWithNULRefused() {
        let req = BraveSearchClient.buildRequest(
            query: "MLX",
            apiKey: "good-key\u{0000}suffix",
            count: 6
        )
        #expect(req == nil)
    }

    @Test("Tavily key with CRLF is refused (defensive even though body-encoded)")
    func tavilyKeyWithCRLFRefused() {
        let req = TavilySearchClient.buildRequest(
            query: "MLX",
            apiKey: "good-key\r\nbreak",
            maxResults: 6
        )
        #expect(req == nil)
    }

    @Test("Whitespace-only key is refused everywhere")
    func emptyKeyRefused() {
        #expect(BraveSearchClient.buildRequest(query: "x", apiKey: "   \n  ", count: 1) == nil)
        #expect(TavilySearchClient.buildRequest(query: "x", apiKey: "\t\t", maxResults: 1) == nil)
    }
}
