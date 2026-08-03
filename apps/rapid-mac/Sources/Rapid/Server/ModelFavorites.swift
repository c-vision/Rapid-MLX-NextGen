import Foundation

/// User-pinned "favorite" models. Issue #507. Favorites float to the top
/// of the "All models" table regardless of the active sort, so a user
/// with 128 aliases keeps their handful of daily drivers one glance away.
///
/// Storage is a plain `UserDefaults` string array (stable, tiny, synced
/// with nothing external). The persistence surface is deliberately thin;
/// the orderings that the table depends on are **pure functions** so
/// they're unit-testable without a defaults store or a SwiftUI host.
enum ModelFavorites {
    /// UserDefaults key. Namespaced like ``ModelsFolderPreference``'s
    /// `rapid.models.folderOverride` so all model prefs share a prefix.
    static let defaultsKey = "rapid.models.favorites"

    // MARK: - Persistence (thin)

    /// The current favorite alias set.
    static func load(defaults: UserDefaults = .standard) -> Set<String> {
        let raw = defaults.array(forKey: defaultsKey) as? [String] ?? []
        return Set(raw)
    }

    static func isFavorite(_ alias: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains(alias)
    }

    /// Flip an alias's favorite state and persist. Returns the NEW state
    /// (`true` = now a favorite) so the caller can update its `@State`
    /// without a re-read.
    @discardableResult
    static func toggle(_ alias: String, defaults: UserDefaults = .standard) -> Bool {
        var set = load(defaults: defaults)
        let nowFavorite: Bool
        if set.contains(alias) {
            set.remove(alias)
            nowFavorite = false
        } else {
            set.insert(alias)
            nowFavorite = true
        }
        persist(set, defaults: defaults)
        return nowFavorite
    }

    private static func persist(_ set: Set<String>, defaults: UserDefaults) {
        // Sort on write so the stored array is deterministic (nicer for
        // debugging / diffing defaults); read order doesn't matter since
        // callers treat it as a Set.
        defaults.set(set.sorted(), forKey: defaultsKey)
    }

    // MARK: - Ordering (pure)

    /// Stable partition of an already-sorted list: favorites first (in
    /// their existing relative order), then everything else (in its
    /// existing relative order). Pure — the caller passes the sorted
    /// entries and the favorite set; no defaults read here so tests pin
    /// every branch with plain values.
    static func favoritesFirst(_ entries: [ModelEntry], favorites: Set<String>) -> [ModelEntry] {
        guard !favorites.isEmpty else { return entries }
        var pinned: [ModelEntry] = []
        var rest: [ModelEntry] = []
        pinned.reserveCapacity(favorites.count)
        rest.reserveCapacity(entries.count)
        for entry in entries {
            if favorites.contains(entry.alias) {
                pinned.append(entry)
            } else {
                rest.append(entry)
            }
        }
        return pinned + rest
    }
}
