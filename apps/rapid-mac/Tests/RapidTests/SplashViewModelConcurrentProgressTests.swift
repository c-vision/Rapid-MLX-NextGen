import Foundation
import Testing
@testable import Rapid

/// P3 slice γ — combined-progress weighting tests for the splash UI.
///
/// These tests live alongside ``SplashViewModelTests`` (which pins
/// the per-phase shapes) and focus on the new pure-function
/// ``CombinedProgress`` arithmetic + the dual-line detail string the
/// concurrent install path produces. The view itself (``SplashView``)
/// has no slice-γ-specific layout change — both legs feed into the
/// same single ``progress`` + ``detail`` fields the view already
/// renders.
@Suite("SplashViewModelConcurrentProgress")
struct SplashViewModelConcurrentProgressTests {

    // MARK: - Weighting arithmetic

    @Test("aggregate: equal-sized legs at 50% each → 50% combined")
    func equalSizedLegs() {
        let s = CombinedProgress.Component(bytesDone: 50, bytesTotal: 100)
        let m = CombinedProgress.Component(bytesDone: 50, bytesTotal: 100)
        #expect(abs(CombinedProgress.aggregate(sidecar: s, model: m) - 0.5) < 1e-9)
    }

    @Test("aggregate: weighted by byte counts — large model dominates")
    func largeModelDominates() {
        // Sidecar 100% done, model 0% done. Sidecar = 100 bytes,
        // model = 900 bytes. Combined = 100/1000 = 0.1.
        let s = CombinedProgress.Component(bytesDone: 100, bytesTotal: 100)
        let m = CombinedProgress.Component(bytesDone: 0, bytesTotal: 900)
        let combined = CombinedProgress.aggregate(sidecar: s, model: m)
        #expect(abs(combined - 0.1) < 1e-9,
                "weighted aggregate should reflect byte dominance, not arithmetic average; saw \(combined)")
    }

    @Test("aggregate: both fully downloaded → 1.0")
    func bothFullyDownloaded() {
        let s = CombinedProgress.Component(bytesDone: 100, bytesTotal: 100)
        let m = CombinedProgress.Component(bytesDone: 200, bytesTotal: 200)
        #expect(abs(CombinedProgress.aggregate(sidecar: s, model: m) - 1.0) < 1e-9)
    }

    @Test("aggregate: clamps at 1.0 even with over-reported bytes")
    func clampsAtOne() {
        // Some delegate callbacks can over-report (e.g. when a server
        // sends Content-Length=N but actually streams N+padding).
        // The per-leg ``fraction`` clamps at 1.0; aggregate inherits
        // this via `min(bytesDone, bytesTotal)`.
        let s = CombinedProgress.Component(bytesDone: 150, bytesTotal: 100)
        let m = CombinedProgress.Component(bytesDone: 300, bytesTotal: 200)
        let combined = CombinedProgress.aggregate(sidecar: s, model: m)
        #expect(combined <= 1.0,
                "aggregate must clamp; saw \(combined)")
        #expect(combined == 1.0,
                "fully-saturated combined progress must be exactly 1.0; saw \(combined)")
    }

    @Test("aggregate: zero total bytes → 0.0 (degenerate safeguard)")
    func zeroTotalIsSafe() {
        let s = CombinedProgress.Component(bytesDone: 0, bytesTotal: 0)
        let m = CombinedProgress.Component(bytesDone: 0, bytesTotal: 0)
        #expect(CombinedProgress.aggregate(sidecar: s, model: m) == 0.0)
    }

    @Test("aggregate: sidecar-only path is identical to per-leg fraction")
    func sidecarOnlyPath() {
        let s = CombinedProgress.Component(bytesDone: 30, bytesTotal: 100)
        let combined = CombinedProgress.aggregate(sidecar: s, model: nil)
        #expect(abs(combined - s.fraction) < 1e-9,
                "sidecar-only aggregate must equal per-leg fraction; saw \(combined)")
    }

    // MARK: - Detail string

    @Test("detail: two concurrent legs fold into one combined total (no artifact labels)")
    func detailDualLine() {
        // 88 + 134 = 222 MB done, 126 + 293 = 419 MB total.
        let s = CombinedProgress.Component(bytesDone: 88 * 1024 * 1024,
                                            bytesTotal: 126 * 1024 * 1024)
        let m = CombinedProgress.Component(bytesDone: 134 * 1024 * 1024,
                                            bytesTotal: 293 * 1024 * 1024)
        let detail = CombinedProgress.detail(sidecar: s, model: m)
        // #461(c): one honest combined total, not a dual-artifact line.
        #expect(detail == "222 / 419 MB",
                "combined total should sum both legs into one 'done / total'; saw \(detail)")
        // #461(a): no per-artifact jargon labels leak into the copy.
        #expect(!detail.contains("Engine"))
        #expect(!detail.contains("Sidecar"))
        #expect(!detail.contains("Model"))
        // #461(b): short enough to never middle-truncate inside the
        // 320 pt @ 11 pt monospaced frame (SF Mono advance ≈ 6.7 pt/char,
        // so the char budget is ~47).
        #expect(Double(detail.count) * 6.7 < 320,
                "combined detail must fit the 320 pt frame; \(detail.count) chars is too wide")
    }

    @Test("detail: single-leg path emits the same combined-total shape")
    func detailSingleLegLegacy() {
        let s = CombinedProgress.Component(bytesDone: 50 * 1024 * 1024,
                                            bytesTotal: 100 * 1024 * 1024)
        let detail = CombinedProgress.detail(sidecar: s, model: nil)
        // Sidecar-only path collapses the shared unit ("50.0 / 100 MB");
        // formatBytes drops the decimal at ≥ 100 of a unit.
        #expect(detail == "50.0 / 100 MB",
                "single-leg detail must be the collapsed 'done / total UNIT' shape; saw \(detail)")
        // Sentinel: never leak an artifact label.
        #expect(!detail.contains("Sidecar"))
        #expect(!detail.contains("Engine"))
        #expect(!detail.contains("Model"))
    }

    @Test("detail: GB-range total auto-switches unit via formatBytes")
    func detailGigabyteRange() {
        // Small engine leg + a 4.2 GB model → the total crosses into GB.
        let s = CombinedProgress.Component(bytesDone: 0,
                                            bytesTotal: 126 * 1024 * 1024)
        let fourPointTwoGB = UInt64(4.2 * 1024 * 1024 * 1024)
        let m = CombinedProgress.Component(bytesDone: fourPointTwoGB / 2,
                                            bytesTotal: fourPointTwoGB)
        let detail = CombinedProgress.detail(sidecar: s, model: m)
        #expect(detail.contains("GB"),
                "GB-range total must render GB, not an overflowing MB count; saw \(detail)")
        #expect(!detail.contains("Engine") && !detail.contains("Model"))
        #expect(Double(detail.count) * 6.7 < 320,
                "GB-range detail must still fit the 320 pt frame; saw \(detail)")
    }

    @Test("jargon: user-facing install/download copy carries no forbidden tokens")
    func jargonScan() {
        // Codifies the no-internal-jargon category rule (#461a) for the
        // copy this surface owns: the combined-total formatter output
        // plus the literals swept in this fix. Whole-word match so
        // "Quantization" (industry-standard, allowed) never false-positives
        // and product tokens like "Rapid-MLX" are untouched.
        let forbidden = ["sidecar", "engine", "parser", "quant",
                         "alias", "tier", "bootstrapper"]
        let userFacingCopy: [String] = [
            CombinedProgress.detail(
                sidecar: .init(bytesDone: 88 * 1024 * 1024, bytesTotal: 126 * 1024 * 1024),
                model: .init(bytesDone: 134 * 1024 * 1024, bytesTotal: 293 * 1024 * 1024)),
            CombinedProgress.detail(
                sidecar: .init(bytesDone: 50 * 1024 * 1024, bytesTotal: 100 * 1024 * 1024),
                model: nil),
            CombinedProgress.formattedTotal(done: 172 * 1024 * 1024, total: 413 * 1024 * 1024),
            "Type a model name…",
            "Search models",
            "Benchmark scores not yet recorded for this model.",
            "Available to download",
        ]
        for copy in userFacingCopy {
            let words = copy.lowercased().split { !$0.isLetter }.map(String.init)
            for token in forbidden {
                #expect(!words.contains(token),
                        "user-facing copy must not contain the '\(token)' jargon: \"\(copy)\"")
            }
        }
    }

    @Test("status pills: CPU/GPU labels render as a percentage, never core counts")
    func statusPillsPercentFormat() {
        // Guard for #461's status-bar half: the pills must read "38%",
        // never "16N"/"4 cores". A regression to a non-"%" shape here
        // is exactly what the issue flagged.
        #expect(CPUProbe.formatLabel(percent: 37.6) == "38%")
        #expect(GPUProbe.formatLabel(percent: 61.4) == "61%")
        #expect(CPUProbe.formatLabel(percent: 0) == "0%")
        #expect(GPUProbe.formatLabel(percent: 100) == "100%")
    }

    // MARK: - SplashViewModel integration

    @MainActor
    @Test("splash model can render combined progress + combined-total detail")
    func splashConsumesDualLine() {
        let m = SplashViewModel()
        let sidecar = CombinedProgress.Component(bytesDone: 50, bytesTotal: 100)
        let model = CombinedProgress.Component(bytesDone: 100, bytesTotal: 400)
        let combined = CombinedProgress.aggregate(sidecar: sidecar, model: model)
        let detail = CombinedProgress.detail(sidecar: sidecar, model: model)
        m.progress = combined
        m.detail = detail
        m.headline = "Downloading Rapid-MLX + Quickstart model…"
        #expect(m.progress > 0.29 && m.progress < 0.31,
                "150/500 should be ~0.30; saw \(m.progress)")
        #expect(m.headline.contains("Quickstart"),
                "headline should call out the model leg on the concurrent path")
    }

    // MARK: - ProgressAggregator (actor)

    @Test("aggregator: snapshot reflects updates from both legs")
    func aggregatorBothLegs() async {
        let agg = ProgressAggregator(sidecarTotalBytes: 100, modelTotalBytes: 400)
        await agg.updateSidecar(bytesDone: 50)
        await agg.updateModel(bytesDone: 100)
        let snap = await agg.snapshot()
        #expect(snap.sidecar.bytesDone == 50)
        #expect(snap.sidecar.bytesTotal == 100)
        #expect(snap.model?.bytesDone == 100)
        #expect(snap.model?.bytesTotal == 400)
        let combined = CombinedProgress.aggregate(sidecar: snap.sidecar, model: snap.model)
        #expect(abs(combined - 0.3) < 1e-9,
                "150/500 = 0.3; saw \(combined)")
    }

    @Test("aggregator: sidecar-only snapshot omits model component")
    func aggregatorSidecarOnly() async {
        let agg = ProgressAggregator(sidecarTotalBytes: 100, modelTotalBytes: nil)
        await agg.updateSidecar(bytesDone: 75)
        let snap = await agg.snapshot()
        #expect(snap.model == nil,
                "model component must be nil on sidecar-only path")
        #expect(snap.sidecar.bytesDone == 75)
        let combined = CombinedProgress.aggregate(sidecar: snap.sidecar, model: snap.model)
        #expect(abs(combined - 0.75) < 1e-9)
    }

    @Test("aggregator: late out-of-order callbacks cannot regress")
    func aggregatorMonotonic() async {
        let agg = ProgressAggregator(sidecarTotalBytes: 100, modelTotalBytes: 100)
        await agg.updateSidecar(bytesDone: 80)
        // Out-of-order callback (real-world: chunked downloader fires
        // progress from arbitrary threads, occasionally reorders).
        await agg.updateSidecar(bytesDone: 20)
        let snap = await agg.snapshot()
        #expect(snap.sidecar.bytesDone == 80,
                "max-guard must clamp; saw \(snap.sidecar.bytesDone)")
    }
}
