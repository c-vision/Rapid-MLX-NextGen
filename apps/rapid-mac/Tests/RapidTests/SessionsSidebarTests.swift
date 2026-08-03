import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// Sidebar shape checks. ``SessionsSidebar`` switches between an
/// empty state ("No chats yet") and a ``List`` of rows — the empty
/// branch keyword and the row count are the load-bearing contract.
@MainActor
@Suite("SessionsSidebar shape")
struct SessionsSidebarTests {
    private func makeStore(sessions: Int) -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-store-\(UUID().uuidString).json")
        let store = SessionStore(customStoreURL: url)
        for i in 0..<sessions {
            _ = store.newSession(alias: "fake-alias-\(i)")
        }
        return store
    }

    @Test("Empty store renders the 'No chats yet' empty state")
    func emptyState() throws {
        let store = makeStore(sessions: 0)
        let sut = SessionsSidebar(store: store, defaultAlias: "")
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "No chats yet")
        }
    }

    @Test("Non-empty store hides the empty placeholder")
    func nonEmptyHidesPlaceholder() throws {
        let store = makeStore(sessions: 3)
        let sut = SessionsSidebar(store: store, defaultAlias: "")
        // 'No chats yet' must NOT be present once we have sessions.
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "No chats yet")
        }
    }

    @Test("'New chat' button is always visible (empty AND non-empty)")
    func newChatButtonAlwaysVisible() throws {
        for sessions in [0, 5] {
            let store = makeStore(sessions: sessions)
            let sut = SessionsSidebar(store: store, defaultAlias: "")
            #expect(throws: Never.self) {
                try sut.inspect().find(text: "New chat")
            }
        }
    }
}
