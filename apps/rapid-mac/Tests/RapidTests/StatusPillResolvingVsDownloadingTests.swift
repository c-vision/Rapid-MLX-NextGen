import Foundation
import Testing
@testable import Rapid

/// Pin contract for ``ModelPickerBar.stateLabel(state:activity:)`` and
/// ``ModelPickerBar.progressSubtitle(state:activity:fraction:eta:)``.
///
/// This word has flip-flopped twice, and the history is the contract:
///
/// * #130 split `.fetching` off as "Resolving" — cache-hit relaunches
///   flash that phase with zero bytes moving, and "Downloading" there
///   was a lie.
/// * #150 collapsed it back to "Downloading" — a tqdm parser bug
///   parked REAL multi-minute downloads on `.fetching`, and
///   "Resolving" read as a stalled network handshake.
///
/// Both attempts failed the same way: they keyed a NETWORK claim off a
/// tqdm PHASE. The 2026-07 redesign keys the word off
/// ``DownloadProgress.startupActivity`` — measured byte growth over a
/// pre-spawn disk baseline — so "Downloading" appears iff bytes
/// provably move. A cached start reads "Loading" for the whole
/// mmap/Metal window (the dogfood report was the pill claiming
/// "Downloading 5.6 GB / 5.6 GB · 100%" while switching to an
/// already-downloaded model), and a future tqdm parser regression
/// degrades to "Loading" (safe) instead of a false "Downloading".
///
/// The pill is also demoted to a SUMMARY: one word + "12% · 4 min
/// left". The full byte / speed / ETA read-out lives in the chat's
/// startup banner only — the dedup half of the same dogfood report,
/// which showed identical numbers rendered top and bottom at once.
@MainActor
@Suite("ModelPickerBar status pill — activity-keyed word + summary subtitle")
struct StatusPillResolvingVsDownloadingTests {

    /// Upstream #591 pinned this via ``DownloadProgress.Phase``; the
    /// activity-keyed relabel (same dogfood cycle) retired the
    /// phase-keyed derivation because phases can lie about the
    /// network (see suite doc). The titlebar-stability contract is
    /// unchanged — every in-flight signal collapses to one stable
    /// word — but it now quantifies over the truthful signal.
    @Test("Native titlebar keeps every model-start activity to one 'Starting' label")
    func titlebarStartingLabelIsStable() {
        let activities: [DownloadProgress.StartupActivity] = [
            .starting, .downloading, .loading, .warmingUp,
        ]

        for activity in activities {
            #expect(
                ModelPickerBar.displayedStateLabel(
                    state: .starting(alias: "qwen3-1.7b"),
                    activity: activity,
                    titlebarStyle: true
                ) == "Starting"
            )
        }

        #expect(
            ModelPickerBar.displayedStateLabel(
                state: .ready(alias: "qwen3-1.7b"),
                activity: .starting,
                titlebarStyle: true
            ) == "Ready"
        )
    }

    // MARK: - Pill state label

    @Test("bytes provably moving → 'Downloading'")
    func activityDownloadingSaysDownloading() {
        let label = ModelPickerBar.stateLabel(
            state: .starting(alias: "qwen3.6-35b-4bit"),
            activity: .downloading
        )
        #expect(label == "Downloading")
    }

    @Test("cached start (bytes on disk, nothing growing) → 'Loading', never 'Downloading'")
    func cachedFetchSaysLoading() {
        let label = ModelPickerBar.stateLabel(
            state: .starting(alias: "qwen3.5-9b-4bit"),
            activity: .loading
        )
        #expect(label == "Loading")
    }

    @Test("remaining states keep their copy")
    func otherStatesUnchanged() {
        #expect(ModelPickerBar.stateLabel(state: .starting(alias: "x"), activity: .starting) == "Starting")
        #expect(ModelPickerBar.stateLabel(state: .starting(alias: "x"), activity: .warmingUp) == "Warming up")
        #expect(ModelPickerBar.stateLabel(state: .ready(alias: "x"), activity: .starting) == "Ready")
        #expect(ModelPickerBar.stateLabel(state: .idle, activity: .starting) == "Idle")
        // #129: ``.stopped`` collapses to "Idle".
        #expect(ModelPickerBar.stateLabel(state: .stopped, activity: .starting) == "Idle")
        #expect(ModelPickerBar.stateLabel(state: .missing, activity: .starting) == "Not installed")
        #expect(ModelPickerBar.stateLabel(state: .crashed(alias: "x", message: "boom"), activity: .starting) == "Crashed")
    }

    // MARK: - Pill subtitle (summary form)

    @Test("downloading subtitle is the percent + ETA summary, not a byte read-out")
    func pctEtaSummarySubtitle() {
        let sub = ModelPickerBar.progressSubtitle(
            state: .starting(alias: "x"),
            activity: .downloading,
            fraction: 0.12,
            eta: "4 min left"
        )
        #expect(sub == "12% · 4 min left")
        // ETA unknown → percent alone.
        #expect(
            ModelPickerBar.progressSubtitle(
                state: .starting(alias: "x"),
                activity: .downloading,
                fraction: 0.12,
                eta: nil
            ) == "12%"
        )
        // Nothing measured yet → the bare word, no numbers invented.
        #expect(
            ModelPickerBar.progressSubtitle(
                state: .starting(alias: "x"),
                activity: .downloading,
                fraction: nil,
                eta: nil
            ) == "Downloading…"
        )
    }

    @Test("loading / warming subtitles say what is happening in plain words")
    func loadingSubtitle() {
        #expect(
            ModelPickerBar.progressSubtitle(
                state: .starting(alias: "x"),
                activity: .loading,
                fraction: 1.0,   // cached: fraction is ~1.0 and must NOT leak a percent
                eta: nil
            ) == "Loading into memory…"
        )
        #expect(
            ModelPickerBar.progressSubtitle(
                state: .starting(alias: "x"),
                activity: .warmingUp,
                fraction: 1.0,
                eta: nil
            ) == "Warming up…"
        )
    }

    @Test("no signal yet during .starting still surfaces the shim (v0.4.36)")
    func idlePhaseDuringStartingHasShim() {
        let sub = ModelPickerBar.progressSubtitle(
            state: .starting(alias: "x"),
            activity: .starting,
            fraction: nil,
            eta: nil
        )
        #expect(sub == "Starting the model…")
    }

    @Test("subtitle returns nil outside .starting — pill stands on its own")
    func subtitleNilOutsideStarting() {
        #expect(ModelPickerBar.progressSubtitle(state: .ready(alias: "x"), activity: .starting, fraction: nil, eta: nil) == nil)
        #expect(ModelPickerBar.progressSubtitle(state: .idle, activity: .starting, fraction: nil, eta: nil) == nil)
        #expect(ModelPickerBar.progressSubtitle(state: .stopped, activity: .starting, fraction: nil, eta: nil) == nil)
    }

    // MARK: - Word-discipline cross-check

    @Test("word discipline: no 'Resolving' anywhere, and no 'Downloading' without growth")
    func wordDiscipline() {
        // Belt-and-suspenders walk. A future refactor that reintroduces
        // "Resolving", or paints "Downloading" for a non-downloading
        // activity, has to silence this explicitly — and read the
        // #130 → #150 → growth-baseline history in the suite docstring
        // first.
        let nonDownloading: [DownloadProgress.StartupActivity] = [.starting, .loading, .warmingUp]
        for activity in nonDownloading {
            let pill = ModelPickerBar.stateLabel(state: .starting(alias: "x"), activity: activity)
            let sub = ModelPickerBar.progressSubtitle(
                state: .starting(alias: "x"), activity: activity, fraction: 1.0, eta: nil
            ) ?? ""
            #expect(!pill.contains("Downloading"), "pill claims a download during \(activity): \(pill)")
            #expect(!sub.contains("Downloading"), "subtitle claims a download during \(activity): \(sub)")
            #expect(!pill.contains("Resolving") && !sub.contains("Resolving"))
        }
        let downloading = ModelPickerBar.stateLabel(state: .starting(alias: "x"), activity: .downloading)
        #expect(!downloading.contains("Resolving"))
    }
}
