import Foundation
import Testing
@testable import Rapid

/// Issue #23: ``WebSearchConfig.apiKey(for:)`` used to hit the
/// keychain on every ``web_search`` tool dispatch, blocking the
/// main actor across the securityd XPC hop. PR introduces a
/// per-account cache so the keychain is hit at most once per
/// account lifetime (plus once per ``setAPIKey`` write).
@Suite("WebSearchConfig keychain cache (issue #23)")
final class WebSearchKeyCacheTests {

    /// Test double that counts every ``read`` call so we can assert
    /// the cache short-circuits subsequent reads.
    final class CountingKeychain: KeychainStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        private(set) var readCount = 0
        private let queue = DispatchQueue(label: "rapid.test.counting-keychain")

        func read(account: String) -> String? {
            queue.sync {
                readCount += 1
                return storage[account]
            }
        }

        @discardableResult
        func write(account: String, secret: String) -> Bool {
            queue.sync { storage[account] = secret }
            return true
        }

        @discardableResult
        func delete(account: String) -> Bool {
            queue.sync { _ = storage.removeValue(forKey: account) }
            return true
        }
    }

    /// See ``TestDefaultsScope`` + issue #139 — RAII teardown for
    /// the ``UserDefaults(suiteName:)`` plists this suite mints.
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults() -> UserDefaults {
        let suite = TestDefaultsScope.mintSuiteName(prefix: "rapid-web-search-keycache-test-")
        createdSuiteNames.append(suite)
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @MainActor
    @Test("repeated apiKey reads after a single populated keychain hit only one read")
    func cacheShortCircuitsPopulatedKey() {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "bravo-key")

        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)
        // First read hits the keychain.
        #expect(cfg.apiKey(for: .brave) == "bravo-key")
        #expect(keychain.readCount == 1)
        // Subsequent reads short-circuit.
        for _ in 0..<10 {
            #expect(cfg.apiKey(for: .brave) == "bravo-key")
        }
        #expect(keychain.readCount == 1, "expected 10 cache hits, got \(keychain.readCount - 1) extra reads")
    }

    @MainActor
    @Test("repeated apiKey reads when keychain has NO secret only one read (negative cache)")
    func cacheShortCircuitsAbsentKey() {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.apiKey(for: .brave) == nil)
        #expect(keychain.readCount == 1)
        // Negative cache must also short-circuit — the issue called
        // out that even "no key configured yet" was paying the
        // keychain RTT on every dispatch.
        for _ in 0..<10 {
            #expect(cfg.apiKey(for: .brave) == nil)
        }
        #expect(keychain.readCount == 1, "absent-key cache failed; got \(keychain.readCount - 1) extra reads")
    }

    @MainActor
    @Test("setAPIKey populates the cache so the following apiKey read does NOT hit the keychain")
    func setKeyPrimesTheCache() {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        cfg.setAPIKey("tavily-secret-42", for: .tavily)
        // setAPIKey is a write — it should NOT have triggered a
        // read on the keychain. (The user just told us the value,
        // re-fetching it would be redundant.)
        #expect(keychain.readCount == 0)

        #expect(cfg.apiKey(for: .tavily) == "tavily-secret-42")
        #expect(keychain.readCount == 0, "setAPIKey should have primed the cache")
    }

    @MainActor
    @Test("clearing a key (setAPIKey(nil)) updates the cache so subsequent read returns nil without keychain hit")
    func clearKeyInvalidatesCache() {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "old-key")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.apiKey(for: .brave) == "old-key")
        let readsAfterFirstFetch = keychain.readCount

        cfg.setAPIKey(nil, for: .brave)
        #expect(cfg.apiKey(for: .brave) == nil)
        #expect(keychain.readCount == readsAfterFirstFetch, "clear should hit cache, not re-read keychain")
    }

    @MainActor
    @Test("trailing whitespace on cached key is still trimmed at read time")
    func cachedKeyTrimsWhitespace() {
        let keychain = CountingKeychain()
        keychain.write(
            account: WebSearchProvider.brave.keychainAccount!,
            secret: "  bravo-key-with-trail\n"
        )
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.apiKey(for: .brave) == "bravo-key-with-trail")
        #expect(cfg.apiKey(for: .brave) == "bravo-key-with-trail")
        #expect(keychain.readCount == 1)
    }

    @MainActor
    @Test("per-account cache: a brave read does not prevent a tavily read from hitting the keychain")
    func cacheIsPerAccount() {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "B")
        keychain.write(account: WebSearchProvider.tavily.keychainAccount!, secret: "T")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.apiKey(for: .brave) == "B")
        #expect(keychain.readCount == 1)
        #expect(cfg.apiKey(for: .tavily) == "T")
        #expect(keychain.readCount == 2, "tavily slot must miss the brave cache and trigger a fresh read")
        // Subsequent reads of both short-circuit.
        #expect(cfg.apiKey(for: .brave) == "B")
        #expect(cfg.apiKey(for: .tavily) == "T")
        #expect(keychain.readCount == 2)
    }
}
