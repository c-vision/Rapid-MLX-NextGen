import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.26 first-launch welcome tour. Pins:
///   - Fresh defaults → hasSeen == false (so brand-new installs see the tour)
///   - markSeen() flips to true and persists across instances
///   - resetForRetour() flips back to false (used by a future
///     "Show welcome again" Settings affordance)
///   - Setting `hasSeen` directly persists via the `didSet` writer
///   - Storage key is the versioned `rapid.onboarding.v1.seen` so a
///     future v2 tour can re-show without clobbering the flag
@MainActor
@Suite("OnboardingState — v0.4.26")
struct OnboardingStateTests {
    /// Wipe the live UserDefaults key before each test so writes from
    /// one test don't leak into the next.
    private func freshDefaults() {
        UserDefaults.standard.removeObject(forKey: OnboardingState.storageKey)
    }

    @Test("Storage key is versioned for future tour bumps")
    func storageKey() {
        #expect(OnboardingState.storageKey == "rapid.onboarding.v1.seen")
    }

    @Test("Fresh install — hasSeen defaults to false")
    func defaultIsFalse() {
        freshDefaults()
        let state = OnboardingState()
        #expect(state.hasSeen == false)
    }

    @Test("markSeen() flips to true")
    func markSeenFlipsToTrue() {
        freshDefaults()
        let state = OnboardingState()
        state.markSeen()
        #expect(state.hasSeen == true)
    }

    @Test("markSeen() is idempotent")
    func markSeenIdempotent() {
        freshDefaults()
        let state = OnboardingState()
        state.markSeen()
        state.markSeen()
        state.markSeen()
        #expect(state.hasSeen == true)
    }

    @Test("resetForRetour() flips back to false")
    func resetForRetourFlipsToFalse() {
        freshDefaults()
        let state = OnboardingState()
        state.markSeen()
        state.resetForRetour()
        #expect(state.hasSeen == false)
    }

    @Test("Persisted value survives across instances")
    func roundTrips() {
        freshDefaults()
        let writer = OnboardingState()
        writer.markSeen()
        let reader = OnboardingState()
        #expect(reader.hasSeen == true)
    }

    @Test("Direct hasSeen mutation persists via didSet")
    func directMutationPersists() {
        freshDefaults()
        let state = OnboardingState()
        state.hasSeen = true
        #expect(UserDefaults.standard.bool(forKey: OnboardingState.storageKey) == true)
        state.hasSeen = false
        #expect(UserDefaults.standard.bool(forKey: OnboardingState.storageKey) == false)
    }
}
