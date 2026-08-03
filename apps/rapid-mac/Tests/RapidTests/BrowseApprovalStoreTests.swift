import Foundation
import Testing
@testable import Rapid

/// Coverage for ``BrowseApprovalStore`` — the per-invocation gate behind
/// `browse`. Same two contracts as the command gate: (1) ``ask`` suspends until
/// answered, (2) ``autoApproveAll`` short-circuits and persists.
@MainActor
@Suite("BrowseApprovalStore")
struct BrowseApprovalStoreTests {

    private func freshStore() -> (BrowseApprovalStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "rapid.test.browseapproval.\(UUID().uuidString)")!
        return (BrowseApprovalStore(defaults: suite), suite)
    }

    @Test("Default mode is ask")
    func defaultModeIsAsk() {
        let (store, _) = freshStore()
        #expect(store.mode == .ask)
    }

    @Test("Ask mode suspends until answered, then returns the decision")
    func askSuspendsThenResolves() async {
        let (store, _) = freshStore()
        let task = Task { @MainActor in
            await store.requestApproval(url: "https://example.com/x", host: "example.com")
        }
        while store.pendingRequest == nil { await Task.yield() }
        #expect(store.pendingRequest?.host == "example.com")
        #expect(store.pendingRequest?.fullURL == "https://example.com/x")
        store.answer(.allowOnce)
        #expect(await task.value == .allowOnce)
        #expect(store.pendingRequest == nil)
    }

    @Test("The full URL is retained untruncated for the sheet")
    func fullURLRetained() async {
        let (store, _) = freshStore()
        let long = "https://example.com/?" + String(repeating: "a=1&", count: 200) + "leak=secret"
        let task = Task { @MainActor in
            await store.requestApproval(url: long, host: "example.com")
        }
        while store.pendingRequest == nil { await Task.yield() }
        #expect(store.pendingRequest?.fullURL == long)
        #expect((store.pendingRequest?.url.count ?? .max) < long.count)
        store.answer(.deny)
        _ = await task.value
    }

    @Test("A deny answer resolves to .deny")
    func denyResolves() async {
        let (store, _) = freshStore()
        let task = Task { @MainActor in
            await store.requestApproval(url: "https://evil.example/leak", host: "evil.example")
        }
        while store.pendingRequest == nil { await Task.yield() }
        store.answer(.deny)
        #expect(await task.value == .deny)
    }

    @Test("Auto-approve returns allowOnce without prompting, and persists")
    func autoApprovePersists() async {
        let (store, defaults) = freshStore()
        store.mode = .autoApproveAll
        let decision = await store.requestApproval(url: "https://example.com", host: "example.com")
        #expect(decision == .allowOnce)
        #expect(store.pendingRequest == nil)
        // A store re-created against the same defaults keeps the yolo mode.
        let reloaded = BrowseApprovalStore(defaults: defaults)
        #expect(reloaded.mode == .autoApproveAll)
    }

    @Test("A second concurrent request is denied rather than hanging")
    func reentrancyDenied() async {
        let (store, _) = freshStore()
        let first = Task { @MainActor in
            await store.requestApproval(url: "https://a.example", host: "a.example")
        }
        while store.pendingRequest == nil { await Task.yield() }
        let second = await store.requestApproval(url: "https://b.example", host: "b.example")
        #expect(second == .deny)
        store.answer(.allowOnce)
        _ = await first.value
    }
}
