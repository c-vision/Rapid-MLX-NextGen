import AppKit
import Testing
@testable import Rapid

/// Contract for v0.4.22 sidebar-width persistence. The autosaveName
/// install path itself is exercised against a live `NSWindow` only
/// at runtime (the WindowAccessor callback fires after a real
/// SwiftUI layout pass); these tests pin the pure view-tree
/// descent that the install path depends on.
@MainActor
@Suite("SplitViewAutosaver — v0.4.22")
struct SplitViewAutosaverTests {
    @Test("Empty tree (nil view) returns nil — never crashes")
    func nilTreeIsSafe() {
        #expect(SplitViewAutosaver.findSplitView(in: nil) == nil)
    }

    @Test("A bare view with no split children returns nil")
    func plainTreeIsNil() {
        let root = NSView(frame: .zero)
        root.addSubview(NSView(frame: .zero))
        root.addSubview(NSView(frame: .zero))
        #expect(SplitViewAutosaver.findSplitView(in: root) == nil)
    }

    @Test("A direct NSSplitView is returned as-is")
    func directSplitView() {
        let split = NSSplitView(frame: .zero)
        let found = SplitViewAutosaver.findSplitView(in: split)
        #expect(found === split)
    }

    @Test("A nested NSSplitView is found via depth-first descent")
    func nestedSplitView() {
        let root = NSView(frame: .zero)
        let mid = NSView(frame: .zero)
        let inner = NSView(frame: .zero)
        let split = NSSplitView(frame: .zero)
        root.addSubview(mid)
        mid.addSubview(inner)
        inner.addSubview(split)
        let found = SplitViewAutosaver.findSplitView(in: root)
        #expect(found === split)
    }

    @Test("The first NSSplitView in depth-first order wins — leftmost subtree")
    func firstSplitViewWins() {
        let root = NSView(frame: .zero)
        // Two split views; the one inside the LEFT subtree should win.
        let leftSubtree = NSView(frame: .zero)
        let leftSplit = NSSplitView(frame: .zero)
        leftSubtree.addSubview(leftSplit)
        let rightSubtree = NSView(frame: .zero)
        let rightSplit = NSSplitView(frame: .zero)
        rightSubtree.addSubview(rightSplit)
        root.addSubview(leftSubtree)
        root.addSubview(rightSubtree)
        let found = SplitViewAutosaver.findSplitView(in: root)
        #expect(found === leftSplit)
        #expect(found !== rightSplit)
    }

    @Test("install() sets autosaveName on the wrapped NSSplitView when the window has one")
    func installSetsAutosaveName() {
        let split = NSSplitView(frame: .zero)
        let container = NSView(frame: .zero)
        container.addSubview(split)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentView = container
        SplitViewAutosaver.install("Test.Split.v1", in: window)
        #expect(split.autosaveName == "Test.Split.v1")
    }

    @Test("install() is idempotent — does not re-write the autosaveName once it matches")
    func installIsIdempotent() {
        let split = NSSplitView(frame: .zero)
        let container = NSView(frame: .zero)
        container.addSubview(split)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentView = container
        SplitViewAutosaver.install("Test.Split.idempotent", in: window)
        // Sanity: applied.
        #expect(split.autosaveName == "Test.Split.idempotent")
        // Second call with the same name is a no-op (no observable
        // change). We can't trivially intercept the AppKit setter,
        // but a second install must not break the wired name.
        SplitViewAutosaver.install("Test.Split.idempotent", in: window)
        #expect(split.autosaveName == "Test.Split.idempotent")
    }
}
