import AppKit
import Testing
@testable import Rapid

/// Bug 3-A residual P2: AppleScript / cliclick / VoiceOver target
/// NSTextView by ``accessibilityIdentifier``. NSTextView itself ships
/// with no label or identifier so external tooling can't tell the
/// compose field apart from the system-prompt editor or search bar.
///
/// These tests pin the three attributes ``applyComposeAccessibility``
/// sets so a future refactor that drops the call (or rewrites the
/// IDs) can't silently break the cliclick integration that powers
/// external automation scripts.
@MainActor
@Suite("ChatCompose accessibility shape")
struct ChatComposeAccessibilityTests {
    @Test("Compose configurator sets label, identifier, role description")
    func applyComposeAccessibilitySetsAllThreeAttributes() {
        let tv = AutosizingTextView()
        // Sanity: NSTextView ships with no compose-specific attrs.
        #expect(tv.accessibilityLabel() == nil || tv.accessibilityLabel()!.isEmpty)
        #expect(tv.accessibilityIdentifier().isEmpty)

        AutosizingTextView.applyComposeAccessibility(tv)

        #expect(tv.accessibilityLabel() == AutosizingTextView.composeAccessibilityLabel)
        #expect(tv.accessibilityIdentifier() == AutosizingTextView.composeAccessibilityIdentifier)
        #expect(tv.accessibilityRoleDescription() == AutosizingTextView.composeAccessibilityRoleDescription)
    }

    @Test("Accessibility identifier is stable for external tooling")
    func identifierMatchesPublishedContract() {
        // External cliclick / AppleScript snippets reference the literal
        // string "rapid.chat.compose". If someone renames the constant
        // without updating those scripts, the renamer needs to see this
        // test fail and decide whether to coordinate the rename.
        #expect(AutosizingTextView.composeAccessibilityIdentifier == "rapid.chat.compose")
    }

    @Test("NSTextView role stays at AXTextArea after configurator runs")
    func textAreaRolePreserved() {
        // Pin AppKit's NSTextView default so VoiceOver still narrates
        // "text area". The configurator only touches label /
        // identifier / roleDescription — never role — so if a future
        // edit adds a setAccessibilityRole(...) call this test fires.
        let tv = AutosizingTextView()
        AutosizingTextView.applyComposeAccessibility(tv)
        #expect(tv.accessibilityRole() == .textArea)
    }
}
