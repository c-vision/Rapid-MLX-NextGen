import Foundation

/// Tree arithmetic over a flat ``ChatMessage`` array.
///
/// A conversation persists EVERY branch it has ever grown as one unsorted
/// bag of nodes; the transcript on screen is the single root-to-leaf path
/// derived here. Keeping the maths in one namespace — rather than spread
/// across the view model and the view — is what lets the sibling switcher,
/// the wire body, export, and search all agree on what "the conversation"
/// means at any moment.
///
/// Edges are single-direction (``ChatMessage/parentID`` only). Everything a
/// `childrenIDs` array would have given us is recomputed here instead, which
/// trades a linear scan per query for the guarantee that the two halves of a
/// bidirectional link can never disagree. Transcripts are small (hundreds of
/// nodes at the very top end) and every one of these runs off a user gesture,
/// never per streamed token, so the scan does not show up.
///
/// Every entry point is total: cycles, orphans, and dangling leaf pointers
/// are all absorbed into a sensible answer rather than trapping. A corrupt
/// or hand-edited ``conversations.json`` must degrade to a readable
/// transcript, never to a crash — the same principle behind
/// ``ChatMessage/Role/unknown``.
enum MessageTree {
    /// Sibling order. ``createdAt`` is the real signal — branches are grown
    /// one at a time by a user gesture — with the id as a tie-break so two
    /// nodes stamped inside the same clock tick still order deterministically
    /// across launches (an unstable order would make the `‹ 2/3 ›` index jump
    /// around under the user).
    static func precedes(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// First occurrence of each id wins; later duplicates are dropped.
    ///
    /// Duplicate ids can only come from a corrupt or hand-merged file, but
    /// they must be resolved ONCE, up front: `activePath`'s index already
    /// keeps the first copy, while the sibling and subtree scans would count
    /// every copy — so navigation and deletion could disagree about what a
    /// node even is. Every consumer of a whole tree runs its input through
    /// this first.
    static func deduplicatingByID(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen: Set<UUID> = []
        return messages.filter { seen.insert($0.id).inserted }
    }

    /// Children of ``parentID`` in sibling order. Pass ``nil`` for the roots.
    static func children(of parentID: UUID?, in messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { $0.parentID == parentID }.sorted(by: precedes)
    }

    /// The sibling group containing ``id`` — i.e. every alternative answer at
    /// that point in the conversation, including ``id`` itself. A node with
    /// no alternatives returns a single-element array, which is the signal the
    /// UI uses to hide the switcher.
    static func siblings(of id: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        guard let node = messages.first(where: { $0.id == id }) else { return [] }
        return children(of: node.parentID, in: messages)
    }

    /// Walk down from ``id`` and return the leaf that terminates the walk.
    ///
    /// Used when the user switches to a sibling: they pick a turn, and the
    /// transcript below it has to resolve to some concrete continuation.
    ///
    /// At each step ``preferredChildren`` decides which way to go, falling
    /// back to the newest child when it has no opinion. That map is what
    /// makes returning to a branch land where the user left it: without it, a
    /// branch carrying a long continuation would always jump to its deepest
    /// tip, so a user who stepped back three turns and then looked at a
    /// sibling would find their position silently discarded on the way back.
    static func deepestLeaf(
        from id: UUID,
        in messages: [ChatMessage],
        preferring preferredChildren: [UUID: UUID] = [:]
    ) -> UUID {
        var current = id
        var seen: Set<UUID> = [id]
        while true {
            let options = children(of: current, in: messages)
            guard !options.isEmpty else { break }
            // A remembered choice only counts while it is still a child of
            // this node — a stale entry (branch deleted, file hand-edited)
            // degrades to the newest child rather than stranding the walk.
            let remembered = preferredChildren[current].flatMap { wanted in
                options.first { $0.id == wanted }
            }
            guard let next = (remembered ?? options.last)?.id else { break }
            // A cycle can only come from a corrupt file, but walking one
            // would hang the main actor — bail and treat the current node
            // as the leaf.
            guard seen.insert(next).inserted else { break }
            current = next
        }
        return current
    }

    /// The leaf to show when a conversation carries no ``activeLeafID`` —
    /// either because it predates branching or because the stored pointer
    /// no longer resolves. Picks the newest node overall, then resolves
    /// downwards, which lands on the tip of the branch most recently worked
    /// in and reduces to "the last message" for a linear transcript.
    static func defaultLeaf(
        in messages: [ChatMessage],
        preferring preferredChildren: [UUID: UUID] = [:]
    ) -> UUID? {
        guard let newest = messages.max(by: precedes) else { return nil }
        return deepestLeaf(from: newest.id, in: messages, preferring: preferredChildren)
    }

    /// The parent → chosen-child edges of ``path``.
    ///
    /// Recorded every time a path becomes the visible one, so each fork
    /// remembers which way the user last went. Only the edges actually on the
    /// path are produced; callers merge this over what they already hold
    /// rather than replacing it, so a branch the user has not visited this
    /// session keeps the position it had.
    static func choices(along path: [ChatMessage]) -> [UUID: UUID] {
        var edges: [UUID: UUID] = [:]
        for node in path {
            guard let parent = node.parentID else { continue }
            edges[parent] = node.id
        }
        return edges
    }

    /// The visible transcript: the root-to-leaf path ending at
    /// ``activeLeafID``, oldest turn first.
    ///
    /// This is what the user sees, what gets sent to the model, and what
    /// export writes. An unresolvable ``activeLeafID`` falls back to
    /// ``defaultLeaf(in:)`` rather than rendering an empty conversation.
    static func activePath(
        in messages: [ChatMessage],
        activeLeafID: UUID?,
        preferring preferredChildren: [UUID: UUID] = [:]
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        let index = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var leaf = activeLeafID.flatMap { index[$0] != nil ? $0 : nil }
        if leaf == nil { leaf = defaultLeaf(in: messages, preferring: preferredChildren) }
        guard var cursor = leaf else { return [] }

        var path: [ChatMessage] = []
        var seen: Set<UUID> = []
        while let node = index[cursor] {
            // Same cycle guard as ``deepestLeaf`` — a corrupt parent chain
            // must not spin forever.
            guard seen.insert(node.id).inserted else { break }
            path.append(node)
            guard let parent = node.parentID else { break }
            cursor = parent
        }
        return path.reversed()
    }

    /// ``id`` plus every node beneath it.
    ///
    /// Deleting a turn takes its whole subtree with it (the alternative —
    /// re-parenting the orphans onto the deleted node's parent — silently
    /// rewrites what the user actually said and answered into a conversation
    /// that never happened).
    static func subtree(of id: UUID, in messages: [ChatMessage]) -> Set<UUID> {
        var collected: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for child in children(of: current, in: messages) where collected.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return collected
    }

    /// Reconnect a transcript that carries no parent links into a degenerate
    /// tree — each row parented to the one before it.
    ///
    /// Runs on decode for every conversation written before branching
    /// shipped. The result renders identically to how it always did, and the
    /// first Regenerate on it grows a real branch from there.
    ///
    /// Deliberately keyed on "NO row has a parent" rather than "SOME row
    /// lacks one": in the new model every conversation has exactly one
    /// parentless root, so a partially-linked tree is already a real tree and
    /// must be left alone.
    static func repairingLegacyChain(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > 1 else { return messages }
        guard messages.allSatisfy({ $0.parentID == nil }) else { return messages }
        var repaired = messages
        for index in 1..<repaired.count {
            repaired[index].parentID = repaired[index - 1].id
        }
        return repaired
    }

    /// Drop parent links that point at a node which is not present.
    ///
    /// A dangling parent would strand its whole subtree outside every path,
    /// making those turns unreachable in the UI. Promoting the orphan to a
    /// root keeps the content visible. Applied on decode, after the legacy
    /// repair.
    static func promotingOrphans(_ messages: [ChatMessage]) -> [ChatMessage] {
        let present = Set(messages.map(\.id))
        return messages.map { message in
            guard let parent = message.parentID, !present.contains(parent) else { return message }
            var promoted = message
            promoted.parentID = nil
            return promoted
        }
    }
}
