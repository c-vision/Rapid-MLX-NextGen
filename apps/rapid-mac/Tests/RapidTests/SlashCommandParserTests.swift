import Foundation
import Testing
@testable import Rapid

/// Contract for the Quick Ask compose-row slash-command grammar
/// (v0.5.0). The parser is what decides whether a user's draft
/// becomes a model prompt or a Quick Ask action — getting the
/// classification wrong silently sends ``/new`` to the LLM (or
/// worse, swallows a prompt the user meant to send). Pin every
/// branch.
@MainActor
@Suite("SlashCommandParser — v0.5.0 grammar")
struct SlashCommandParserTests {

    // MARK: - Fallthrough (regular prompts)

    @Test("Empty string is not a command")
    func emptyIsNotCommand() {
        #expect(SlashCommandParser.parse("") == .notACommand)
    }

    @Test("Plain text is not a command")
    func plainTextIsNotCommand() {
        #expect(SlashCommandParser.parse("hello, what's the weather?") == .notACommand)
    }

    @Test("Starts-with-slash but unknown keyword is forwarded to model")
    func unknownKeywordFallsThrough() {
        // The user might want to discuss file paths or even the
        // ``/etc/hosts`` of a server with the model — silently
        // dispatching an unknown slash command would eat that
        // turn. Match ChatGPT / Claude desktop behaviour: unknown
        // ``/foo`` → forward to LLM as a regular prompt.
        #expect(SlashCommandParser.parse("/etc/passwd permissions?") == .notACommand)
        #expect(SlashCommandParser.parse("/yarn vs /npm") == .notACommand)
    }

    @Test("Single forward slash with no keyword is not a command")
    func bareSlashIsNotCommand() {
        // "/", " /", "/ " — none of these have a keyword to match
        // against. Forward to model.
        #expect(SlashCommandParser.parse("/") == .notACommand)
        #expect(SlashCommandParser.parse(" / ") == .notACommand)
    }

    // MARK: - No-arg commands

    @Test("/new dispatches newSession")
    func newDispatches() {
        #expect(SlashCommandParser.parse("/new") == .command(.newSession))
    }

    @Test("/new with trailing whitespace still dispatches")
    func newTrailingWhitespace() {
        #expect(SlashCommandParser.parse("/new   ") == .command(.newSession))
        #expect(SlashCommandParser.parse("  /new\n") == .command(.newSession))
    }

    @Test("/help dispatches help")
    func helpDispatches() {
        #expect(SlashCommandParser.parse("/help") == .command(.help))
    }

    @Test("/close dispatches close")
    func closeDispatches() {
        #expect(SlashCommandParser.parse("/close") == .command(.close))
    }

    @Test("Keyword matching is case-insensitive — user typing /New must dispatch")
    func keywordIsCaseInsensitive() {
        #expect(SlashCommandParser.parse("/NEW") == .command(.newSession))
        #expect(SlashCommandParser.parse("/Help") == .command(.help))
    }

    // MARK: - One-arg commands

    @Test("/model <alias> dispatches switchModel with the alias verbatim")
    func modelDispatches() {
        #expect(SlashCommandParser.parse("/model qwen3.6-27b") == .command(.switchModel(alias: "qwen3.6-27b")))
    }

    @Test("/model preserves alias hyphens / digits / quant suffix")
    func modelAliasShapeIsPreserved() {
        // Alias naming convention (project CLAUDE.md): the alias
        // is <family>-<size>-<quant>. Parser must NOT mangle the
        // hyphens (e.g. by splitting on "-" instead of " ").
        let result = SlashCommandParser.parse("/model qwen3.5-4b-8bit")
        #expect(result == .command(.switchModel(alias: "qwen3.5-4b-8bit")))
    }

    @Test("/model with extra whitespace between keyword and alias trims correctly")
    func modelExtraWhitespace() {
        #expect(SlashCommandParser.parse("/model   qwen3.6-27b") == .command(.switchModel(alias: "qwen3.6-27b")))
    }

    // MARK: - Missing argument

    @Test("/model with no alias surfaces a missingArg hint instead of empty alias")
    func modelMissingArgSurfacesHint() {
        let result = SlashCommandParser.parse("/model")
        switch result {
        case .missingArg(let keyword, let hint):
            #expect(keyword == "model")
            #expect(hint.contains("/model"))
            #expect(hint.contains("<alias>"))
        default:
            Issue.record("Expected missingArg, got \(result)")
        }
    }

    @Test("/model with only whitespace after the keyword still missingArg")
    func modelWhitespaceOnlyArg() {
        switch SlashCommandParser.parse("/model    ") {
        case .missingArg: break
        case let other: Issue.record("Expected missingArg, got \(other)")
        }
    }

    // MARK: - Catalog contract

    @Test("Catalog contains every dispatched keyword")
    func catalogIsCompleteForKeywords() {
        let keywords = Set(SlashCommandParser.catalog.map(\.keyword))
        #expect(keywords == ["new", "clear", "model", "help", "close"])
    }

    @Test("Catalog argName is set exactly when the command takes an arg")
    func catalogArgNamesPinned() {
        let specs = Dictionary(uniqueKeysWithValues: SlashCommandParser.catalog.map { ($0.keyword, $0) })
        #expect(specs["new"]?.argName == nil)
        #expect(specs["clear"]?.argName == nil)
        #expect(specs["model"]?.argName == "alias")
        #expect(specs["help"]?.argName == nil)
        #expect(specs["close"]?.argName == nil)
    }

    @Test("/clear is an alias of /new — both dispatch newSession")
    func clearIsAliasOfNew() {
        #expect(SlashCommandParser.parse("/clear") == .command(.newSession))
        #expect(SlashCommandParser.parse("/CLEAR") == .command(.newSession))
        #expect(SlashCommandParser.parse("  /clear  ") == .command(.newSession))
    }

    @Test("displayTrigger renders arg placeholder when present")
    func displayTriggerRendersArg() {
        let model = SlashCommandParser.catalog.first(where: { $0.keyword == "model" })!
        let new = SlashCommandParser.catalog.first(where: { $0.keyword == "new" })!
        #expect(model.displayTrigger == "/model <alias>")
        #expect(new.displayTrigger == "/new")
    }

    @Test("Every catalog entry has a non-empty description")
    func descriptionsArePresent() {
        for spec in SlashCommandParser.catalog {
            #expect(!spec.description.isEmpty, "Spec /\(spec.keyword) has empty description — palette row will collapse")
        }
    }
}
