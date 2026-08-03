import Foundation
import Testing
@testable import Rapid

/// Cycle-12 P3 regression pins for the Settings → Web Search panel's
/// Keychain access pattern.
///
/// **The bug.** Opening the Settings → Web Search tab used to call
/// ``WebSearchConfig.apiKey(for:)`` synchronously for both Brave and
/// Tavily from inside the view-builder (one read for the upgrade-
/// banner predicate, two more for the per-row "stored?" indicator).
/// Each call crosses the securityd XPC hop and on a fresh app session
/// the first cross-process access against
/// ``kSecAttrAccessibleWhenUnlockedThisDeviceOnly`` can surface a
/// system "allow access" modal — so the user clicks the tab and gets
/// a permission dialog (or a multi-second stall) before they've
/// touched anything.
///
/// **The fix.** ``WebSearchConfig`` gained an async ``prefetchAPIKey
/// (for:)`` / ``prefetchAllAPIKeys()`` surface plus a cache-only
/// ``cachedKeyState(for:)`` peek. The Settings view warms the cache
/// in a ``.task`` (detached read off-actor), mirrors the result into a
/// ``@State`` snapshot, and renders against the snapshot. The panel
/// now never calls ``apiKey(for:)`` from the view-builder.
///
/// These tests pin the new surface so a future refactor that re-
/// introduces a synchronous read on tab open fails the suite.
@MainActor
@Suite("Settings → Web Search async Keychain (cycle-12 P3)")
final class SettingsWebSearchAsyncKeychainTests {

    /// Counts every ``read`` call so we can assert the prefetch path
    /// hits each account exactly once and ``cachedKeyState`` never
    /// hits Keychain at all.
    final class CountingKeychain: KeychainStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        private(set) var readCount = 0
        private let queue = DispatchQueue(label: "rapid.test.settings-async-keychain")

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

    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }

    private func freshDefaults() -> UserDefaults {
        let suite = TestDefaultsScope.mintSuiteName(prefix: "rapid-settings-web-search-async-")
        createdSuiteNames.append(suite)
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - cachedKeyState pre-prefetch contract

    @Test("cachedKeyState returns .unknown before any prefetch / read")
    func cachedStateUnknownPrePrefetch() {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "BSA")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.cachedKeyState(for: .brave) == .unknown,
                "Before prefetch the Settings view must see .unknown so it renders a neutral placeholder, not a flash of 'no key'")
        #expect(keychain.readCount == 0,
                "cachedKeyState must NEVER touch Keychain — it's the view-builder's safe peek")
    }

    @Test("cachedKeyState for DuckDuckGo is .absent without touching Keychain")
    func ddgIsAlwaysAbsent() {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        #expect(cfg.cachedKeyState(for: .duckduckgo) == .absent,
                "DuckDuckGo has no keychain account; cachedKeyState must short-circuit")
        #expect(keychain.readCount == 0)
    }

    // MARK: - prefetchAPIKey

    @Test("prefetchAPIKey populates cachedKeyState with .present for a populated slot")
    func prefetchPopulatesPresent() async {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "BSA-key")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        await cfg.prefetchAPIKey(for: .brave)
        #expect(cfg.cachedKeyState(for: .brave) == .present("BSA-key"))
        #expect(keychain.readCount == 1)
    }

    @Test("prefetchAPIKey populates cachedKeyState with .absent for an empty slot")
    func prefetchPopulatesAbsent() async {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        await cfg.prefetchAPIKey(for: .tavily)
        #expect(cfg.cachedKeyState(for: .tavily) == .absent)
        #expect(keychain.readCount == 1)
    }

    @Test("prefetchAPIKey is idempotent — second call short-circuits without a Keychain hit")
    func prefetchIsIdempotent() async {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "X")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        await cfg.prefetchAPIKey(for: .brave)
        await cfg.prefetchAPIKey(for: .brave)
        await cfg.prefetchAPIKey(for: .brave)
        #expect(keychain.readCount == 1,
                "Repeat prefetch must not re-cross XPC — the probed set short-circuits")
    }

    @Test("prefetchAPIKey for DuckDuckGo is a no-op (no Keychain hit)")
    func prefetchDDGIsNoop() async {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        await cfg.prefetchAPIKey(for: .duckduckgo)
        #expect(keychain.readCount == 0,
                "DuckDuckGo never keys to Keychain; prefetch must reflect that contract")
        #expect(cfg.cachedKeyState(for: .duckduckgo) == .absent)
    }

    @Test("prefetchAllAPIKeys covers every keyed provider with exactly one Keychain read per slot")
    func prefetchAllCoversEveryKeyedProvider() async {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "B")
        keychain.write(account: WebSearchProvider.tavily.keychainAccount!, secret: "T")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        await cfg.prefetchAllAPIKeys()
        // One read per keyed slot (Brave + Tavily). DuckDuckGo must
        // not contribute because it has no Keychain account.
        #expect(keychain.readCount == 2)
        #expect(cfg.cachedKeyState(for: .brave) == .present("B"))
        #expect(cfg.cachedKeyState(for: .tavily) == .present("T"))
    }

    // MARK: - The headline regression pin

    /// **Structural test against the original bug.** Constructing a
    /// fresh ``WebSearchConfig`` must not hit Keychain. This is the
    /// contract that lets the Settings view defer reads to a ``.task``
    /// without a synchronous read sneaking in via the @State
    /// initializer (the exact path the cycle-12 P3 finding described).
    @Test("WebSearchConfig.init does NOT touch Keychain — defer to async prefetch")
    func initDoesNotTouchKeychain() {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "should-not-be-read")
        keychain.write(account: WebSearchProvider.tavily.keychainAccount!, secret: "should-not-be-read")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        // Reading cachedKeyState is still a peek-only operation; the
        // construction itself was the load-bearing assertion.
        _ = cfg.cachedKeyState(for: .brave)
        _ = cfg.cachedKeyState(for: .tavily)

        #expect(keychain.readCount == 0,
                "Re-introducing a synchronous read in init would re-introduce the freeze-on-tab-open bug — view-state warm-up MUST happen in an async .task hop, not during config construction.")
    }

    /// Mirrors the new view-state-driven banner predicate. Pins the
    /// branch logic so the panel can drive the upgrade banner off the
    /// post-prefetch snapshot without ever calling ``apiKey(for:)``.
    @Test("View-state banner predicate hides for explicit non-DDG provider")
    func bannerPredicateHidesForExplicitProvider() {
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(
            provider: .brave,
            braveHasKey: false,
            tavilyHasKey: false
        ))
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(
            provider: .tavily,
            braveHasKey: false,
            tavilyHasKey: false
        ))
    }

    @Test("View-state banner predicate hides when ANY paid key is on disk")
    func bannerPredicateHidesWhenPaidKeyStored() {
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(
            provider: .duckduckgo,
            braveHasKey: true,
            tavilyHasKey: false
        ))
        #expect(!SettingsView.shouldShowDDGUpgradeBanner(
            provider: .duckduckgo,
            braveHasKey: false,
            tavilyHasKey: true
        ))
    }

    @Test("View-state banner predicate shows on fresh DDG-with-no-keys install")
    func bannerPredicateShowsOnFreshInstall() {
        #expect(SettingsView.shouldShowDDGUpgradeBanner(
            provider: .duckduckgo,
            braveHasKey: false,
            tavilyHasKey: false
        ))
    }

    // MARK: - setAPIKey still primes cachedKeyState (no Keychain re-read)

    @Test("setAPIKey primes cachedKeyState so the view-builder sees the new value without a Keychain hit")
    func setAPIKeyPrimesCachedState() {
        let keychain = CountingKeychain()
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        cfg.setAPIKey("new-key", for: .brave)
        #expect(cfg.cachedKeyState(for: .brave) == .present("new-key"))
        #expect(keychain.readCount == 0,
                "setAPIKey is a write — the post-write cachedKeyState peek must NOT re-issue a Keychain read")
    }

    @Test("Clearing via setAPIKey(nil) collapses cachedKeyState to .absent")
    func clearCollapsesCachedState() async {
        let keychain = CountingKeychain()
        keychain.write(account: WebSearchProvider.brave.keychainAccount!, secret: "old")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        // Warm via prefetch so cachedKeyState is .present before we clear.
        // codex r1 NIT: prefer awaiting the prefetch directly rather
        // than spinning a fire-and-forget Task and racing it with
        // apiKey — the test then pins the post-prefetch state
        // unambiguously without leaning on an implementation detail of
        // the in-line read.
        await cfg.prefetchAPIKey(for: .brave)
        #expect(cfg.cachedKeyState(for: .brave) == .present("old"))

        cfg.setAPIKey(nil, for: .brave)
        #expect(cfg.cachedKeyState(for: .brave) == .absent)
    }

    // MARK: - Race coverage (codex r1 MAJOR)
    //
    // ``prefetchAPIKey`` does its Keychain read on a detached task,
    // which means another caller can race through ``setAPIKey`` /
    // ``apiKey(for:)`` while we're still blocked across XPC. The
    // implementation's re-check of ``probedAccounts`` after the
    // detached read returns is the contract that keeps the in-line
    // writer authoritative — these tests pin that contract.

    /// A keychain stub whose ``read`` blocks until the test releases
    /// ``gate``. Lets us deterministically interleave a prefetch in
    /// flight with a concurrent ``setAPIKey`` write.
    ///
    /// All sync surface (``read`` blocks on a ``DispatchSemaphore``;
    /// ``readEntered`` polls a lock-protected counter) is safe to call
    /// from the detached task that ``prefetchAPIKey`` spawns. The
    /// async test helpers below stay off the main actor by hopping to
    /// ``Task.detached`` for any operation that needs to wait on the
    /// semaphore — otherwise the main actor stays parked on the
    /// blocking wait and the @MainActor prefetch can't make progress.
    final class GatedKeychain: KeychainStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        private let storageQueue = DispatchQueue(label: "rapid.test.gated-keychain")
        private let gate = DispatchSemaphore(value: 0)
        private let readEnteredLock = NSLock()
        private var _readEnteredCount: Int = 0

        var readEnteredCount: Int {
            readEnteredLock.lock(); defer { readEnteredLock.unlock() }
            return _readEnteredCount
        }

        func read(account: String) -> String? {
            // Codex r2 MAJOR: snapshot the storage value BEFORE we
            // block on ``gate.wait()`` so a concurrent ``write`` that
            // races through during the wait can't make the post-wait
            // return value indistinguishable from the writer's new
            // value. If we read after the wait the in-flight prefetch
            // would silently observe "new" and the test couldn't
            // prove the post-XPC ``probedAccounts`` re-check dropped
            // a stale value vs. just landing the same value twice.
            let snapshot = storageQueue.sync { storage[account] }
            readEnteredLock.lock()
            _readEnteredCount += 1
            readEnteredLock.unlock()
            gate.wait()
            return snapshot
        }

        /// Release one queued ``read`` caller. Test-only.
        func release() { gate.signal() }

        /// Await (via polling) until at least ``count`` ``read`` calls
        /// have entered the gate. Lives in the structured-concurrency
        /// world (``Task.sleep``), which suspends the caller's actor
        /// instead of parking it — that lets the @MainActor prefetch
        /// (driven via ``runDetachedPrefetch``) progress on the main
        /// actor in between polls.
        func waitForReads(_ count: Int) async {
            while readEnteredCount < count {
                try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            }
        }

        @discardableResult
        func write(account: String, secret: String) -> Bool {
            storageQueue.sync { storage[account] = secret }
            return true
        }

        @discardableResult
        func delete(account: String) -> Bool {
            storageQueue.sync { _ = storage.removeValue(forKey: account) }
            return true
        }

        /// Convenience: seed storage outside the gate so the test can
        /// assert what an in-flight ``read`` WOULD have observed.
        func seed(account: String, value: String) {
            storageQueue.sync { storage[account] = value }
        }
    }

    /// Wrapper helper: spawn the prefetch on a *detached* task so the
    /// @MainActor test body and the @MainActor prefetch interleave
    /// instead of contending for the same actor (and so the test
    /// doesn't deadlock waiting for a Task it scheduled onto its own
    /// actor while ALSO holding that actor in a polling loop).
    nonisolated private static func runDetachedPrefetch(
        cfg: WebSearchConfig,
        provider: WebSearchProvider
    ) -> Task<Void, Never> {
        Task.detached {
            await cfg.prefetchAPIKey(for: provider)
        }
    }

    @Test("prefetchAPIKey in flight loses to a concurrent setAPIKey write — stale read does NOT clobber the new key")
    func prefetchInFlightLosesToConcurrentWrite() async {
        let keychain = GatedKeychain()
        keychain.seed(account: WebSearchProvider.brave.keychainAccount!, value: "old")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        // Kick off the prefetch on a detached task so it doesn't
        // contend with the @MainActor test body for the main actor.
        let prefetchTask = Self.runDetachedPrefetch(cfg: cfg, provider: .brave)

        // Wait until the detached read has entered the stub so we know
        // we're racing the post-read mutation, not the pre-read probed
        // check.
        await keychain.waitForReads(1)

        // While the prefetch is blocked across XPC, the user pastes a
        // new key via Save. setAPIKey is the in-line authoritative
        // writer — it must prime the cache to "new".
        cfg.setAPIKey("new", for: .brave)
        #expect(cfg.cachedKeyState(for: .brave) == .present("new"))

        // Release the prefetch. Its read returns "old"; the
        // probedAccounts re-check must then drop the snapshot.
        keychain.release()
        await prefetchTask.value

        #expect(cfg.cachedKeyState(for: .brave) == .present("new"),
                "Stale prefetch result must not overwrite the in-line writer's value — the post-XPC probedAccounts re-check is the load-bearing contract.")
    }

    @Test("Cancelled prefetch task discards its Keychain read without touching the cache")
    func cancelledPrefetchDiscardsResult() async {
        let keychain = GatedKeychain()
        keychain.seed(account: WebSearchProvider.brave.keychainAccount!, value: "should-not-land")
        let cfg = WebSearchConfig(defaults: freshDefaults(), keychain: keychain)

        let prefetchTask = Self.runDetachedPrefetch(cfg: cfg, provider: .brave)
        await keychain.waitForReads(1)
        prefetchTask.cancel()
        keychain.release()
        await prefetchTask.value

        #expect(cfg.cachedKeyState(for: .brave) == .unknown,
                "A cancelled prefetch must not publish a result — the parent view that triggered it is gone, and writing into the @Observable cache would push an out-of-band refresh onto an unrelated panel.")
    }
}
