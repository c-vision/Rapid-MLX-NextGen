import Foundation

/// Shared teardown utility for ``@Suite`` test classes that mint
/// per-test ``UserDefaults(suiteName:)`` stores.
///
/// ## Why
///
/// ``UserDefaults(suiteName:)`` registers an in-memory domain AND
/// flushes the empty domain to ``~/Library/Preferences/<name>.plist``
/// on first write. Neither half is automatically reclaimed when the
/// test finishes — over a few weeks of ``swift test`` runs the
/// preferences directory accumulated 600+ ``[0-9A-F]{8}-...`` plists
/// from tests that minted suites named with a bare ``UUID().uuidString``
/// (see issue #139 follow-up to PR #138's ``SamplingConfigTests`` fix).
///
/// ## Pattern
///
/// Reshape the ``@Suite`` from ``struct`` to ``final class`` so each
/// ``@Test`` instance can carry a ``deinit``, then:
///
/// ```swift
/// @Suite("…")
/// final class FooTests {
///     nonisolated(unsafe) private var createdSuiteNames: [String] = []
///     deinit { TestDefaultsScope.cleanup(suiteNames: createdSuiteNames) }
///
///     private func freshDefaults() -> UserDefaults {
///         let name = TestDefaultsScope.mintSuiteName(prefix: "rapid-foo-test-")
///         createdSuiteNames.append(name)
///         let d = UserDefaults(suiteName: name)!
///         d.removePersistentDomain(forName: name)
///         return d
///     }
/// }
/// ```
///
/// The ``prefix:`` lets a salvage script sweep any future stragglers
/// (e.g. left behind by a ``swift test`` run that crashed before
/// ``deinit`` could fire):
///
/// ```sh
/// find ~/Library/Preferences -maxdepth 1 -name 'rapid-foo-test-*.plist' -delete
/// ```
///
/// Naming a suite ``UUID().uuidString`` alone (no prefix) makes the
/// straggler indistinguishable from other apps' anonymous plists and
/// effectively un-sweepable, so every caller MUST pass a real
/// ``prefix``.
enum TestDefaultsScope {
    /// Mint a fresh suite name with the given test-file-specific
    /// prefix appended with a UUID. The prefix is required (no
    /// default) so a salvage glob can target this suite without
    /// risking unrelated apps' plists.
    ///
    /// When used as a default-argument expression
    /// (``freshDefaults(name: String = …mintSuiteName(prefix:))``)
    /// Swift evaluates the default at EACH call site, so every
    /// ``freshDefaults()`` invocation gets a distinct UUID — it is
    /// NOT memoised across calls. A reviewer who "fixes" this into
    /// a stored property would silently collapse every test's
    /// suite onto the same name, so prefer leaving the default-arg
    /// callable as-is.
    static func mintSuiteName(prefix: String) -> String {
        // ``assert`` (test-only) rather than ``precondition`` (active
        // in release builds too) — this helper is test-only code and
        // a release-build trap would be heavier than warranted if the
        // helper ever leaks into non-test code by mistake.
        assert(
            !prefix.isEmpty,
            "TestDefaultsScope.mintSuiteName requires a non-empty prefix so straggler plists can be swept by glob"
        )
        return prefix + UUID().uuidString
    }

    /// Drop every ``UserDefaults`` suite name from both the in-memory
    /// registry AND the on-disk ``~/Library/Preferences/<name>.plist``.
    ///
    /// Idempotent. Safe to call on names that were never written.
    /// ``nonisolated`` so ``deinit`` (always non-isolated) can call
    /// without an actor hop.
    ///
    /// Steps per name:
    /// 1. ``removePersistentDomain`` — clears the in-memory dict
    /// 2. ``removeSuite`` — drops the suite from the registry
    /// 3. ``synchronize`` — forces ``cfprefsd`` to flush the empty
    ///    in-memory state BEFORE we unlink, otherwise the daemon
    ///    races our ``removeItem`` and re-writes the file post-unlink
    /// 4. ``FileManager.removeItem`` against
    ///    ``~/Library/Preferences/<name>.plist`` — actually unlinks
    ///    the file (steps 1-3 alone leave a 42-byte empty plist).
    static func cleanup(suiteNames: [String]) {
        let store = UserDefaults()
        let prefsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in suiteNames {
            store.removePersistentDomain(forName: name)
            store.removeSuite(named: name)
            store.synchronize()
            let path = prefsDir.appendingPathComponent("\(name).plist")
            try? FileManager.default.removeItem(at: path)
        }
    }
}
