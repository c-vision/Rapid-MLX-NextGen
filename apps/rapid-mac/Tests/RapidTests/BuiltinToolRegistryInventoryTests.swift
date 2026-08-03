import Foundation
import Testing
@testable import Rapid

/// Coverage for the tools-inventory contract that the ChatView tools
/// chip reads from. The chip surfaces the count + names that
/// ``BuiltinToolRegistry`` exposes — if a tool is added or removed
/// without updating this test, the chip silently changes too, which
/// would be surprising for a user who relies on it to know exactly
/// which tools the model has right now.
@MainActor
@Suite("BuiltinToolRegistry inventory")
struct BuiltinToolRegistryInventoryTests {
    @Test("Ships exactly the built-in tool set (incl. write_file + edit_file + run_command + browse)")
    func shipsExpectedTools() {
        let names = BuiltinToolRegistry().definitions.map(\.function.name)
        #expect(
            Set(names) == Set([
                "read_file",
                "list_directory",
                "write_file",
                "edit_file",
                "run_command",
                "browse",
                "web_search",
                "calculator",
                "weather",
                "current_datetime",
            ])
        )
    }

    @Test("Each tool ships a non-empty description (model needs it for prompting)")
    func everyToolHasDescription() {
        for def in BuiltinToolRegistry().definitions {
            #expect(
                !def.function.description.isEmpty,
                "Tool \(def.function.name) ships an empty description — the model can't reason about when to call it."
            )
        }
    }

    @Test("Tool names are unique (popover would otherwise duplicate rows)")
    func toolNamesAreUnique() {
        let names = BuiltinToolRegistry().definitions.map(\.function.name)
        #expect(Set(names).count == names.count)
    }
}
