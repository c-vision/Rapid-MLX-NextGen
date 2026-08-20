import Foundation
import Testing
@testable import Rapid

@Suite("Message tree")
struct MessageTreeTests {
    /// Build a linear chain, oldest first, with distinct timestamps so
    /// sibling ordering is unambiguous.
    private func chain(_ contents: [String], from start: Date = Date(timeIntervalSince1970: 0)) -> [ChatMessage] {
        var built: [ChatMessage] = []
        for (offset, content) in contents.enumerated() {
            built.append(
                ChatMessage(
                    role: offset.isMultiple(of: 2) ? .user : .assistant,
                    content: content,
                    parentID: built.last?.id,
                    createdAt: start.addingTimeInterval(Double(offset))
                )
            )
        }
        return built
    }

    @Test("The active path is the walk from the leaf back to the root")
    func activePathWalksToRoot() {
        let messages = chain(["q1", "a1", "q2", "a2"])
        let path = MessageTree.activePath(in: messages, activeLeafID: messages.last?.id)
        #expect(path.map(\.content) == ["q1", "a1", "q2", "a2"])
    }

    @Test("A sibling branch is excluded from the other branch's path")
    func siblingBranchesAreDisjoint() {
        let base = chain(["q1", "a1"])
        // A second answer to the same prompt — what Regenerate produces.
        let alternative = ChatMessage(
            role: .assistant,
            content: "a1-take-2",
            parentID: base[0].id,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let tree = base + [alternative]

        let first = MessageTree.activePath(in: tree, activeLeafID: base[1].id)
        let second = MessageTree.activePath(in: tree, activeLeafID: alternative.id)

        #expect(first.map(\.content) == ["q1", "a1"])
        #expect(second.map(\.content) == ["q1", "a1-take-2"])
    }

    @Test("Siblings are the alternatives at one point, in creation order")
    func siblingsAreOrderedByCreation() {
        let base = chain(["q1", "a1"])
        let second = ChatMessage(
            role: .assistant, content: "a1-take-2",
            parentID: base[0].id, createdAt: Date(timeIntervalSince1970: 10)
        )
        let third = ChatMessage(
            role: .assistant, content: "a1-take-3",
            parentID: base[0].id, createdAt: Date(timeIntervalSince1970: 20)
        )
        let tree = base + [second, third]

        let group = MessageTree.siblings(of: base[1].id, in: tree)
        #expect(group.map(\.content) == ["a1", "a1-take-2", "a1-take-3"])
    }

    @Test("A turn with no alternatives is its own only sibling")
    func lonelyTurnHasOneSibling() {
        let messages = chain(["q1", "a1"])
        #expect(MessageTree.siblings(of: messages[1].id, in: messages).count == 1)
    }

    @Test("Switching to an interior sibling resolves down to a leaf")
    func deepestLeafResolvesDownwards() {
        // q1 → a1 → q2 → a2, plus a second answer to q1 that was itself
        // continued. Selecting that answer must land on its own tip.
        let base = chain(["q1", "a1", "q2", "a2"])
        let alternative = ChatMessage(
            role: .assistant, content: "a1-take-2",
            parentID: base[0].id, createdAt: Date(timeIntervalSince1970: 10)
        )
        let continuation = ChatMessage(
            role: .user, content: "q2-on-branch",
            parentID: alternative.id, createdAt: Date(timeIntervalSince1970: 11)
        )
        let tree = base + [alternative, continuation]

        let leaf = MessageTree.deepestLeaf(from: alternative.id, in: tree)
        #expect(leaf == continuation.id)
    }

    @Test("A legacy linear transcript is rebuilt into a degenerate tree")
    func legacyChainIsRepaired() {
        // What a pre-branching conversations.json decodes to: every row
        // parentless. Left alone, its active path would be one message.
        let flat = [
            ChatMessage(role: .user, content: "q1", createdAt: Date(timeIntervalSince1970: 0)),
            ChatMessage(role: .assistant, content: "a1", createdAt: Date(timeIntervalSince1970: 1)),
            ChatMessage(role: .user, content: "q2", createdAt: Date(timeIntervalSince1970: 2)),
        ]
        let repaired = MessageTree.repairingLegacyChain(flat)

        #expect(repaired[0].parentID == nil)
        #expect(repaired[1].parentID == repaired[0].id)
        #expect(repaired[2].parentID == repaired[1].id)
        let path = MessageTree.activePath(in: repaired, activeLeafID: nil)
        #expect(path.map(\.content) == ["q1", "a1", "q2"])
    }

    @Test("An already-branched tree is left alone by the legacy repair")
    func repairSkipsRealTrees() {
        // The repair keys on "NO row has a parent". A real tree has exactly
        // one such row (its root), and re-chaining it would flatten the
        // branches into a single bogus line.
        let tree = chain(["q1", "a1"])
        #expect(MessageTree.repairingLegacyChain(tree).map(\.parentID) == tree.map(\.parentID))
    }

    @Test("A parent pointing at a missing node is promoted to a root")
    func orphansArePromoted() {
        // A hand-edited or partially-written file. Without the promotion the
        // orphan sits outside every path and its content is unreachable.
        let orphan = ChatMessage(
            role: .user, content: "stranded",
            parentID: UUID(), createdAt: Date(timeIntervalSince1970: 0)
        )
        let promoted = MessageTree.promotingOrphans([orphan])
        #expect(promoted[0].parentID == nil)
        #expect(MessageTree.activePath(in: promoted, activeLeafID: orphan.id).count == 1)
    }

    @Test("Deleting a turn takes its whole subtree")
    func subtreeCollectsDescendants() {
        let messages = chain(["q1", "a1", "q2", "a2"])
        let doomed = MessageTree.subtree(of: messages[1].id, in: messages)
        #expect(doomed == Set(messages[1...].map(\.id)))
    }

    @Test("A cyclic parent chain terminates instead of hanging")
    func cyclesDoNotHang() {
        // Only reachable from a corrupt file, but a spin here would wedge the
        // main actor — the transcript must degrade, not freeze.
        var a = ChatMessage(role: .user, content: "a", createdAt: Date(timeIntervalSince1970: 0))
        var b = ChatMessage(role: .assistant, content: "b", createdAt: Date(timeIntervalSince1970: 1))
        a.parentID = b.id
        b.parentID = a.id
        let path = MessageTree.activePath(in: [a, b], activeLeafID: a.id)
        #expect(path.count <= 2)
    }

    @Test("An unresolvable active leaf falls back to the newest branch")
    func danglingLeafFallsBack() {
        let messages = chain(["q1", "a1"])
        let path = MessageTree.activePath(in: messages, activeLeafID: UUID())
        #expect(path.map(\.content) == ["q1", "a1"])
    }
}
