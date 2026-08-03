import Foundation
import Testing
@testable import Rapid

/// Contract for the slash-command palette filter (v0.5.0). Drives
/// the compose-row autocomplete popover — the filter result is
/// the popover row list, so wrong matches mean the user sees
/// suggestions that vanish on Enter (or worse, the autocomplete
/// stays empty when they typed something valid).
@MainActor
@Suite("SlashCommandPalette — v0.5.0 autocomplete filter")
struct SlashCommandPaletteTests {

    // MARK: - Hide-the-palette inputs

    @Test("Empty draft → empty list")
    func emptyHides() {
        #expect(SlashCommandPalette.filter("") == [])
    }

    @Test("Plain text → empty list")
    func plainTextHides() {
        #expect(SlashCommandPalette.filter("hello world") == [])
    }

    @Test("Whitespace-only draft → empty list")
    func whitespaceHides() {
        #expect(SlashCommandPalette.filter("   \n") == [])
    }

    // MARK: - Full-catalog cases

    @Test("Bare \"/\" shows every catalog entry in catalog order")
    func bareSlashShowsAll() {
        let matches = SlashCommandPalette.filter("/")
        let keywords = matches.map(\.keyword)
        #expect(keywords == ["new", "clear", "model", "help", "close"])
    }

    @Test("\"/c\" narrows to both /clear and /close (shared prefix)")
    func prefixCMatchesBothCommands() {
        let matches = SlashCommandPalette.filter("/c")
        #expect(matches.map(\.keyword) == ["clear", "close"])
    }

    @Test("\"/cle\" disambiguates to /clear only")
    func prefixCleNarrowsToClear() {
        let matches = SlashCommandPalette.filter("/cle")
        #expect(matches.map(\.keyword) == ["clear"])
    }

    @Test("\"/clo\" disambiguates to /close only")
    func prefixCloNarrowsToClose() {
        let matches = SlashCommandPalette.filter("/clo")
        #expect(matches.map(\.keyword) == ["close"])
    }

    // MARK: - Prefix narrowing

    @Test("\"/m\" narrows to /model only")
    func prefixMNarrows() {
        let matches = SlashCommandPalette.filter("/m")
        #expect(matches.map(\.keyword) == ["model"])
    }

    @Test("\"/h\" narrows to /help only")
    func prefixHNarrows() {
        let matches = SlashCommandPalette.filter("/h")
        #expect(matches.map(\.keyword) == ["help"])
    }

    @Test("Prefix matching is case-insensitive — \"/N\" still matches /new")
    func prefixCaseInsensitive() {
        let matches = SlashCommandPalette.filter("/N")
        #expect(matches.map(\.keyword) == ["new"])
    }

    @Test("Unknown prefix → empty list")
    func unknownPrefixHides() {
        #expect(SlashCommandPalette.filter("/xyz") == [])
    }

    @Test("Complete keyword still visible until user types a space")
    func completeKeywordStillShown() {
        // Once "/new" is typed (no trailing space), the palette
        // should still show /new so the user can see what's
        // about to happen on Enter.
        let matches = SlashCommandPalette.filter("/new")
        #expect(matches.map(\.keyword) == ["new"])
    }

    // MARK: - Arg-region rules

    @Test("\"/model \" (trailing space, no alias) → /model row only")
    func argRegionShowsArgEntry() {
        // The user has committed to /model and is typing the
        // alias. We want a single contextual row showing what
        // they're filling in, NOT every prefix-matching command.
        let matches = SlashCommandPalette.filter("/model ")
        #expect(matches.map(\.keyword) == ["model"])
    }

    @Test("\"/model qwen3.6-27b\" (alias entered) → still /model row")
    func argRegionWithAlias() {
        let matches = SlashCommandPalette.filter("/model qwen3.6-27b")
        #expect(matches.map(\.keyword) == ["model"])
    }

    @Test("\"/new \" (trailing space on no-arg cmd) → empty — palette hides")
    func argRegionOnNoArgCmd() {
        // /new takes no arg, so a space after it means the
        // palette has done its job. Hide so we don't dangle a
        // suggestion under the composer while the user is
        // mid-typing whatever comes next.
        let matches = SlashCommandPalette.filter("/new ")
        #expect(matches == [])
    }

    @Test("\"/foo arg\" (unknown keyword with arg region) → empty")
    func argRegionOnUnknownCmd() {
        #expect(SlashCommandPalette.filter("/foo something") == [])
    }

    // MARK: - completion()

    @Test("completion() of /model returns \"/model \" with trailing space")
    func completionModelHasTrailingSpace() {
        let model = SlashCommandParser.catalog.first(where: { $0.keyword == "model" })
        #expect(SlashCommandPalette.completion(for: model) == "/model ")
    }

    @Test("completion() of /new returns \"/new \" with trailing space")
    func completionNewHasTrailingSpace() {
        // Even no-arg commands get a trailing space so the
        // caller can distinguish "still composing" from "ready
        // to dispatch" by checking whether the draft ends in a
        // space-after-keyword.
        let new = SlashCommandParser.catalog.first(where: { $0.keyword == "new" })
        #expect(SlashCommandPalette.completion(for: new) == "/new ")
    }

    @Test("completion(nil) returns nil")
    func completionNilIsNil() {
        #expect(SlashCommandPalette.completion(for: nil) == nil)
    }

    // MARK: - clamped() — selection wrap

    @Test("clamped wraps positive overflow back to 0")
    func clampedWrapsPositive() {
        #expect(SlashCommandPalette.clamped(4, count: 4) == 0)
        #expect(SlashCommandPalette.clamped(5, count: 4) == 1)
    }

    @Test("clamped wraps negative underflow to count - 1")
    func clampedWrapsNegative() {
        #expect(SlashCommandPalette.clamped(-1, count: 4) == 3)
        #expect(SlashCommandPalette.clamped(-5, count: 4) == 3)
    }

    @Test("clamped with count == 0 is safe (returns 0)")
    func clampedZeroCountIsSafe() {
        #expect(SlashCommandPalette.clamped(7, count: 0) == 0)
    }

    @Test("clamped within range returns the input verbatim")
    func clampedInRangeIsIdentity() {
        #expect(SlashCommandPalette.clamped(2, count: 4) == 2)
    }
}
