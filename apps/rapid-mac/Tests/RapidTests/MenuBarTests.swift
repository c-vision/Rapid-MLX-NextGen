import Foundation
import Testing
@testable import Rapid

/// Issue #502 — SwiftUI's ``MenuBarExtra`` glyph does not render on
/// macOS 26 (Darwin 25.x / Tahoe), so the menu-bar (tray) icon — the
/// primary affordance for reopen / new chat / model status / settings /
/// quit — silently vanished for those users. The tray is now an AppKit
/// ``NSStatusItem`` (``MenuBarController``), which renders reliably on
/// every macOS version, and the ``MenuBarExtra`` scene was removed
/// entirely so the two surfaces can never both exist (the #475
/// double-icon bug).
///
/// The rendered ``NSMenu`` is NOT AX-introspectable (see the "SwiftUI AX
/// tree invisible" gotcha — the same invisibility applies to an AppKit
/// menu opened programmatically), so we can't assert the rendered rows
/// directly. The strongest available guards are:
///   1. the pure status-line truth table,
///   2. the pure ordered menu model (``menuItems``) that
///      ``MenuBarController`` renders verbatim, including its dynamic
///      branches (update row, installer label, disabled-while-checking),
///   3. the pure glyph-template mapping, and
///   4. a source-grep structural guard pinning EXACTLY ONE tray surface:
///      one AppKit ``NSStatusItem`` creation, zero ``MenuBarExtra`` scenes.
@Suite("MenuBar — single NSStatusItem tray (#502)")
struct MenuBarTests {

    // MARK: - Status-line truth table

    @Test("statusLine: idle + stopped both read 'Idle'")
    func statusLineIdleAndStopped() {
        #expect(MenuBarStatus.statusLine(state: .idle) == "Idle")
        #expect(MenuBarStatus.statusLine(state: .stopped) == "Idle")
    }

    @Test("statusLine: missing reads 'Setup needed'")
    func statusLineMissing() {
        #expect(MenuBarStatus.statusLine(state: .missing) == "Setup needed")
    }

    @Test("statusLine: starting with an alias prefixes the model")
    func statusLineStartingWithAlias() {
        #expect(
            MenuBarStatus.statusLine(state: .starting(alias: "qwen3.5-4b"))
                == "qwen3.5-4b · Starting…"
        )
    }

    @Test("statusLine: starting with empty alias falls back to bare state")
    func statusLineStartingEmptyAlias() {
        #expect(MenuBarStatus.statusLine(state: .starting(alias: "")) == "Starting…")
    }

    @Test("statusLine: ready with an alias prefixes the model")
    func statusLineReadyWithAlias() {
        #expect(
            MenuBarStatus.statusLine(state: .ready(alias: "qwen3.5-4b"))
                == "qwen3.5-4b · Ready"
        )
    }

    @Test("statusLine: ready with empty alias falls back to bare state")
    func statusLineReadyEmptyAlias() {
        #expect(MenuBarStatus.statusLine(state: .ready(alias: "")) == "Ready")
    }

    @Test("statusLine: crashed with an alias prefixes the model (message ignored)")
    func statusLineCrashedWithAlias() {
        #expect(
            MenuBarStatus.statusLine(state: .crashed(alias: "qwen3.5-4b", message: "boom"))
                == "qwen3.5-4b · Crashed"
        )
    }

    @Test("statusLine: crashed with empty alias falls back to bare state")
    func statusLineCrashedEmptyAlias() {
        #expect(
            MenuBarStatus.statusLine(state: .crashed(alias: "", message: "boom")) == "Crashed"
        )
    }

    // MARK: - Glyph template mapping

    @Test("glyph: no update renders a monochrome template that adopts the bar colour")
    func glyphTemplateWithoutUpdate() {
        #expect(MenuBarStatus.glyphIsTemplate(hasUpdate: false) == true)
    }

    @Test("glyph: an available update keeps the amber fill (non-template)")
    func glyphTemplateWithUpdate() {
        #expect(MenuBarStatus.glyphIsTemplate(hasUpdate: true) == false)
    }

    // MARK: - Menu model (ordered items + dynamic branches)

    /// Actions in display order, dropping separators / status rows.
    private func actions(_ items: [MenuBarStatus.MenuBarItem]) -> [MenuBarStatus.MenuBarAction] {
        items.compactMap { item in
            if case .button(let action, _, _, _) = item { return action }
            return nil
        }
    }

    /// The whole button for an action, if present.
    private func button(
        _ action: MenuBarStatus.MenuBarAction,
        in items: [MenuBarStatus.MenuBarItem]
    ) -> (title: String, enabled: Bool, shortcut: MenuBarStatus.MenuShortcut?)? {
        for item in items {
            if case .button(let a, let title, let enabled, let shortcut) = item, a == action {
                return (title, enabled, shortcut)
            }
        }
        return nil
    }

    @Test("menu: no update — full action list in order, no update row")
    func menuOrderWithoutUpdate() {
        let items = MenuBarStatus.menuItems(
            state: .idle,
            hasUpdate: false,
            updateVersion: "",
            installerRunning: false,
            checking: false
        )
        #expect(
            actions(items) == [
                .open, .newChat, .checkForUpdates, .about,
                .quickAsk, .reportBug, .requestFeature, .settings, .quit,
            ]
        )
    }

    @Test("menu: an available update inserts the update row after the status line")
    func menuOrderWithUpdate() {
        let items = MenuBarStatus.menuItems(
            state: .ready(alias: "qwen3.5-4b"),
            hasUpdate: true,
            updateVersion: "1.2.3",
            installerRunning: false,
            checking: false
        )
        #expect(
            actions(items) == [
                .open, .newChat, .update, .checkForUpdates, .about,
                .quickAsk, .reportBug, .requestFeature, .settings, .quit,
            ]
        )
        #expect(button(.update, in: items)?.title == "Update available — v1.2.3")
    }

    @Test("menu: the update row flips to the in-progress label while the installer runs")
    func menuUpdateLabelWhileInstalling() {
        let items = MenuBarStatus.menuItems(
            state: .idle,
            hasUpdate: true,
            updateVersion: "1.2.3",
            installerRunning: true,
            checking: false
        )
        #expect(button(.update, in: items)?.title == "Updating Rapid-MLX…")
    }

    @Test("menu: 'Check for updates…' is disabled mid-check")
    func menuCheckDisabledWhileChecking() {
        let checking = MenuBarStatus.menuItems(
            state: .idle, hasUpdate: false, updateVersion: "",
            installerRunning: false, checking: true
        )
        let idle = MenuBarStatus.menuItems(
            state: .idle, hasUpdate: false, updateVersion: "",
            installerRunning: false, checking: false
        )
        #expect(button(.checkForUpdates, in: checking)?.enabled == false)
        #expect(button(.checkForUpdates, in: idle)?.enabled == true)
    }

    @Test("menu: the live status line is rendered as a disabled informational row")
    func menuStatusRow() {
        let items = MenuBarStatus.menuItems(
            state: .ready(alias: "qwen3.5-4b"),
            hasUpdate: false,
            updateVersion: "",
            installerRunning: false,
            checking: false
        )
        // Exactly one status row, carrying the truth-table string.
        let statusRows = items.filter { if case .status = $0 { return true } else { return false } }
        #expect(statusRows == [.status("qwen3.5-4b · Ready")])
    }

    @Test("menu: keyboard chords match the pre-#502 tray (⌘N, ⌘⌥K, ⌘comma, ⌘Q)")
    func menuShortcuts() {
        let items = MenuBarStatus.menuItems(
            state: .idle, hasUpdate: false, updateVersion: "",
            installerRunning: false, checking: false
        )
        #expect(button(.newChat, in: items)?.shortcut == .init(key: "n", modifiers: [.command]))
        #expect(
            button(.quickAsk, in: items)?.shortcut == .init(key: "k", modifiers: [.command, .option])
        )
        #expect(button(.settings, in: items)?.shortcut == .init(key: ",", modifiers: [.command]))
        #expect(button(.quit, in: items)?.shortcut == .init(key: "q", modifiers: [.command]))
        // "Open Rapid-MLX" intentionally carries no chord (⌘N is New Chat).
        #expect(button(.open, in: items)?.shortcut == nil)
    }

    // MARK: - Structural regression guard (exactly one tray surface)

    /// Repository root, derived from ``#filePath`` so the test runs from
    /// any cwd (swift test, Xcode, CI).
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static func swiftSources() throws -> [(name: String, stripped: String)] {
        let root = sourceRoot.appendingPathComponent("Sources/Rapid")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ),
            "Could not enumerate Sources/Rapid — directory missing?"
        )
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let body = try String(contentsOf: url, encoding: .utf8)
            out.append((url.lastPathComponent, stripCommentsAndWhitespace(body)))
        }
        return out
    }

    private static func count(of needle: String) throws -> Int {
        let stripped = stripCommentsAndWhitespace(needle)
        var total = 0
        for (_, body) in try swiftSources() {
            total += body.components(separatedBy: stripped).count - 1
        }
        return total
    }

    /// EXACTLY ONE AppKit status item may be created. Zero would mean no
    /// tray at all; two would be the #475 double-icon. This is the
    /// AppKit half of the "one tray surface" invariant.
    @Test("Exactly one NSStatusItem is created across Sources")
    func exactlyOneStatusItem() throws {
        let total = try Self.count(of: "NSStatusBar.system.statusItem")
        #expect(
            total == 1,
            "Expected exactly one NSStatusBar.system.statusItem creation (the single AppKit tray, #502); found \(total). Two re-opens the #475 double-icon bug; zero drops the tray entirely."
        )
    }

    /// NO ``MenuBarExtra`` scene may exist. Its glyph does not render on
    /// macOS 26 (#502), so the tray moved to the AppKit ``NSStatusItem``
    /// above; re-adding a ``MenuBarExtra`` alongside it re-opens the #475
    /// double-icon bug. Count the token (comments stripped first) so any
    /// init overload (``MenuBarExtra("Rapid") { … }``,
    /// ``MenuBarExtra(isInserted:) …``) still trips the guard.
    @Test("No MenuBarExtra scene anywhere in Sources")
    func noMenuBarExtraScene() throws {
        let total = try Self.count(of: "MenuBarExtra")
        #expect(
            total == 0,
            "Found \(total) MenuBarExtra reference(s) in code (comments excluded). MenuBarExtra's glyph does not render on macOS 26 (#502) — the tray is the AppKit MenuBarController.NSStatusItem. A MenuBarExtra alongside it re-opens the #475 double-icon bug."
        )
    }

    // MARK: - Strip helper (mirrors ToolUseCapabilitySourceGuardTests)

    /// Strip ``//`` line comments, ``/*…*/`` block comments, and all
    /// whitespace so the source-grep tests pin against a canonical form.
    /// Kept private to this suite so a refactor of the sibling helper
    /// can't drift the rules silently.
    static func stripCommentsAndWhitespace(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "/", source.index(after: i) < source.endIndex,
               source[source.index(after: i)] == "*" {
                var j = source.index(i, offsetBy: 2)
                while j < source.endIndex {
                    if source[j] == "*",
                       source.index(after: j) < source.endIndex,
                       source[source.index(after: j)] == "/" {
                        j = source.index(j, offsetBy: 2)
                        break
                    }
                    j = source.index(after: j)
                }
                i = j
                continue
            }
            if c == "/", source.index(after: i) < source.endIndex,
               source[source.index(after: i)] == "/" {
                var j = source.index(after: i)
                while j < source.endIndex, source[j] != "\n" {
                    j = source.index(after: j)
                }
                i = j
                continue
            }
            if c.isWhitespace {
                i = source.index(after: i)
                continue
            }
            out.append(c)
            i = source.index(after: i)
        }
        return out
    }
}
