import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// Structural tests for ``SlashCommandPaletteView`` (v0.5.0). Pins
/// the user-visible content that ``QuickAskView`` relies on so a
/// refactor of the row layout doesn't silently drop the trigger
/// text or the description copy that the user scans while typing.
@MainActor
@Suite("SlashCommandPaletteView — v0.5.0 row rendering")
struct SlashCommandPaletteViewTests {

    private func makeView(
        specs: [SlashCommandSpec],
        selection: Binding<Int> = .constant(0),
        onCommit: @escaping (SlashCommandSpec) -> Void = { _ in }
    ) -> some View {
        SlashCommandPaletteView(
            specs: specs,
            selection: selection,
            onCommit: onCommit
        )
    }

    @Test("Renders the trigger string for every spec passed in")
    func rendersEveryTrigger() throws {
        let view = makeView(specs: SlashCommandParser.catalog)
        for spec in SlashCommandParser.catalog {
            #expect(throws: Never.self) {
                try view.inspect().find(text: spec.displayTrigger)
            }
        }
    }

    @Test("Renders the description copy for every spec passed in")
    func rendersEveryDescription() throws {
        let view = makeView(specs: SlashCommandParser.catalog)
        for spec in SlashCommandParser.catalog {
            #expect(throws: Never.self) {
                try view.inspect().find(text: spec.description)
            }
        }
    }

    @Test("Filtered specs only — palette doesn't leak unrequested rows")
    func filteredSpecsOnly() throws {
        let modelOnly = SlashCommandParser.catalog.filter { $0.keyword == "model" }
        let view = makeView(specs: modelOnly)
        // /model row IS present
        #expect(throws: Never.self) {
            try view.inspect().find(text: "/model <alias>")
        }
        // /new row IS NOT — the caller (QuickAskView) filtered it
        // out and the view must not add catalog rows on its own.
        do {
            _ = try view.inspect().find(text: "/new")
            Issue.record("Found /new in a palette that was passed only /model — view leaked extra rows")
        } catch {
            // Expected — inspect throws when not found.
        }
    }

    @Test("Empty specs list still renders without crashing")
    func emptyListIsSafe() {
        let view = makeView(specs: [])
        // Caller (QuickAskView) gates the palette on
        // ``paletteSpecs.isEmpty``, but the view itself must
        // still be safe to construct with no rows. SwiftUI
        // doesn't always honour the caller's gate during
        // animation cycles.
        #expect(throws: Never.self) {
            _ = try view.inspect()
        }
    }
}
