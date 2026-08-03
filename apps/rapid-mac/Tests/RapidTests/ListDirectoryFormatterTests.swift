import Foundation
import Testing
@testable import Rapid

/// Pins the `list_directory` tool's listing format (audit P1
/// `FilesystemTools.swift:200`). Pre-fix, hidden files were
/// silently dropped via `.skipsHiddenFiles` and a model
/// reasoning about a project saw a sparse listing that hid
/// `.gitignore`, `.env`, etc. — wrong answers followed. The
/// fix shows hidden files, sorts directories-first then files
/// (both alpha), and reports both truncation count AND hidden
/// count when relevant.
@Suite("list_directory formatter")
struct ListDirectoryFormatterTests {
    /// Build an isolated tmpdir, populate it from a `[name: isDir]`
    /// fixture, and return the path. Names with a leading `.` are
    /// treated as hidden by the FS regardless of the `isHidden`
    /// flag macOS keeps per-entry.
    private func makeFixtureDir(_ entries: [(name: String, isDir: Bool)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-listdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            let url = dir.appendingPathComponent(entry.name)
            if entry.isDir {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
            }
        }
        return dir
    }

    @Test("Empty directory yields empty content, no suffix")
    func empty_dir() throws {
        let dir = try makeFixtureDir([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 200)
        #expect(out == "")
    }

    @Test("Directories sort to the top, then files, both alpha")
    func sort_dirs_first_then_files_alpha() throws {
        let dir = try makeFixtureDir([
            ("zebra.txt", false),
            ("apple.txt", false),
            ("Zoo", true),
            ("ant", true),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 200) ?? ""
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == ["ant/", "Zoo/", "apple.txt", "zebra.txt"])
    }

    /// The headline regression: hidden files used to vanish.
    /// They must now show up in the listing, and the trailing
    /// summary must say how many of the visible total are hidden.
    @Test("Hidden files are now included AND counted in summary")
    func hidden_files_included() throws {
        let dir = try makeFixtureDir([
            ("README.md", false),
            (".gitignore", false),
            (".env", false),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 200) ?? ""
        #expect(out.contains(".gitignore"),
                "Dotfile must appear in the listing")
        #expect(out.contains(".env"),
                "Dotfile must appear in the listing")
        #expect(out.contains("README.md"),
                "Non-hidden file must still appear")
        #expect(out.contains("2 of 3 entries are hidden"),
                "Summary must call out hidden count when > 0")
    }

    @Test("No hidden summary line when no hidden files exist")
    func no_hidden_summary_when_empty() throws {
        let dir = try makeFixtureDir([
            ("a.txt", false),
            ("b.txt", false),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 200) ?? ""
        #expect(!out.contains("hidden"),
                "No hidden files → no hidden summary line. Got: \(out)")
    }

    @Test("Truncation reports total count and surfaces hidden count")
    func truncated_listing_reports_both_counts() throws {
        var entries: [(name: String, isDir: Bool)] = []
        // 5 hidden + 10 visible = 15 total; cap at 8 forces truncation.
        for i in 0..<5 {
            entries.append((name: ".secret\(i)", isDir: false))
        }
        for i in 0..<10 {
            entries.append((name: "file\(i).txt", isDir: false))
        }
        let dir = try makeFixtureDir(entries)
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 8) ?? ""
        #expect(out.contains("truncated; 15 entries total"),
                "Truncation summary missing total count. Got: \(out)")
        #expect(out.contains("showing first 8"),
                "Truncation summary missing cap. Got: \(out)")
        #expect(out.contains("5 entries are hidden"),
                "Truncation summary missing hidden count. Got: \(out)")
    }

    @Test("Non-truncated listing under cap reports no truncation suffix")
    func no_truncation_summary_when_under_cap() throws {
        let dir = try makeFixtureDir([
            ("a.txt", false),
            ("b.txt", false),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = FilesystemTools.formatDirectoryListing(at: dir, entryCap: 200) ?? ""
        #expect(!out.contains("truncated"))
    }

    @Test("Missing / inaccessible directory returns nil — caller can surface as a tool error")
    func nil_for_bad_path() {
        let bogus = URL(fileURLWithPath: "/var/empty/does-not-exist-\(UUID().uuidString)")
        let out = FilesystemTools.formatDirectoryListing(at: bogus, entryCap: 200)
        #expect(out == nil)
    }
}
