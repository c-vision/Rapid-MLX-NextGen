import Foundation
import Testing
@testable import Rapid

/// Pin contract for ``ChatView.capabilityChipKinds``.
///
/// Pre-2026-06-14 the empty-state hero rendered four "capability"
/// chips (Search the web / Calculate / Weather / Read files) with the
/// same rounded-card affordance as the prompt-seed chips immediately
/// below — but with NO action wired. Clicking any of them on the
/// FIRST screen a new user touches did nothing, silently breaking
/// trust at the worst possible moment. Caught 2026-06-14 during the
/// manual cliclick-driven user-flow tree-walk against v0.5.16.
///
/// The fix lifts the chip catalog into a static array on ``ChatView``
/// so the production view binds each chip to ``draft = kind.promptSeed``
/// AND a unit test can pin that:
///   - All four canonical kinds are present (no regression that
///     drops a chip silently).
///   - Each seed is non-empty (no future refactor that re-introduces
///     the no-op state under a different shape).
///   - The order is stable: Search → Calculate → Weather → Read
///     files. Reorders would shuffle the chip row at runtime; pin so
///     a "tidied alphabetical" PR has to justify the change.
@Suite("ChatView.capabilityChipKinds — empty-state chip catalog contract")
struct CapabilityChipKindsTests {

    @Test("All four canonical chip kinds are present, in canonical order")
    func canonicalOrder() {
        let titles = ChatView.capabilityChipKinds.map(\.title)
        #expect(titles == ["Search the web", "Calculate", "Weather", "Read files"])
    }

    @Test("Every chip kind carries a non-empty promptSeed (no no-op chips)")
    func everySeedIsNonEmpty() {
        for kind in ChatView.capabilityChipKinds {
            #expect(
                !kind.promptSeed.isEmpty,
                "Chip \"\(kind.title)\" has an empty promptSeed — would render as a no-op CTA on the empty-state hero (FIND-005 regression)."
            )
        }
    }

    @Test("Every chip kind carries a non-empty SF Symbol icon")
    func everyIconIsNonEmpty() {
        for kind in ChatView.capabilityChipKinds {
            #expect(
                !kind.icon.isEmpty,
                "Chip \"\(kind.title)\" has an empty icon name — would render blank-with-text on the empty-state hero."
            )
        }
    }

    @Test("Seeds end with trailing space or punctuation so user can extend in place")
    func seedsTerminatedForInlineExtension() {
        // The Search / Weather / Read files seeds are partial — they
        // end with a trailing space so the user's typed completion
        // continues the sentence cleanly ("Search the web for
        // golden retrievers"). The Calculate seed is a complete
        // sentence — it ends with a question mark. Pin both shapes
        // so a refactor that strips trailing whitespace doesn't
        // collapse the inline-extension contract.
        let seeds = Dictionary(uniqueKeysWithValues:
            ChatView.capabilityChipKinds.map { ($0.title, $0.promptSeed) }
        )
        #expect(seeds["Search the web"]?.hasSuffix(" ") == true)
        #expect(seeds["Weather"]?.hasSuffix(" ") == true)
        #expect(seeds["Read files"]?.hasSuffix(" ") == true)
        #expect(seeds["Calculate"]?.hasSuffix("?") == true)
    }

    @Test("Titles are unique — chip-row ForEach uses title as id")
    func titlesAreUnique() {
        let titles = ChatView.capabilityChipKinds.map(\.title)
        #expect(Set(titles).count == titles.count, "Duplicate title would crash ForEach(id: \\.title).")
    }
}
