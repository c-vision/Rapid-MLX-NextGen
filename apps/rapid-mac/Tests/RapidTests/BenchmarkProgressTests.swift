import Foundation
import Testing
@testable import Rapid

/// Contract for the live-progress model behind "Speed on this Mac" —
/// the fix for the two dogfood reports: a freeform bench with no
/// progress/ETA (#1) and a Submit button that "loads forever" while the
/// standardized re-bench runs silently (#4).
@Suite("BenchmarkRunner.Progress — live stage + ETA")
struct BenchmarkProgressTests {
    typealias Progress = BenchmarkRunner.Progress

    // MARK: - Stage inference from streamed stdout

    @Test("Advances loading → measuring → uploading as lines stream in")
    func stageAdvances() {
        var p = Progress(kind: .submit)
        #expect(p.stage == .starting)
        p.observe("Loading model qwen3.5-4b (mlx-community/…)…")
        #expect(p.stage == .loading)
        p.observe("  Long prompt target: ~2048 tokens")
        #expect(p.stage == .measuring)
        p.observe("Throughput: 120.4 tok/s")
        #expect(p.stage == .measuring)
        p.observe("Uploading to the leaderboard…")
        #expect(p.stage == .uploading)
    }

    @Test("Stage only moves forward — a late stray line can't rewind it")
    func stageMonotonic() {
        var p = Progress(kind: .benchmark)
        p.observe("Uploading…")
        #expect(p.stage == .uploading)
        // A trailing framework log mentioning "loading" must not drag the
        // label back to an earlier phase.
        p.observe("loading model weights cache warm")
        #expect(p.stage == .uploading)
    }

    @Test("The freeform CLI's 'Running benchmark with …' line flips off Loading")
    func measuringMarkerIsTheRealProgressLine() {
        // The freeform bench prints "Running benchmark with N prompts …"
        // right before the (silent) decode; the Results/Throughput lines
        // only land after decode. Without this the card is stuck on
        // "Loading…" for the whole measurement (codex MINOR).
        var p = Progress(kind: .benchmark)
        p.observe("Loading model: qwen3.5-4b")
        #expect(p.stage == .loading)
        p.observe("Running benchmark with 3 prompts, max_tokens=256")
        #expect(p.stage == .measuring)
    }

    @Test("Unrecognised lines leave the stage untouched")
    func stageIgnoresNoise() {
        var p = Progress(kind: .benchmark)
        p.observe("Loading model foo")
        p.observe("some unrelated framework chatter")
        #expect(p.stage == .loading)
    }

    // MARK: - ETA estimate

    @Test("ETA scales with model size and is larger for submit")
    func etaScalesWithSize() {
        let small = BenchmarkRunner.etaSeconds(alias: "qwen3.5-4b", kind: .benchmark)
        let big = BenchmarkRunner.etaSeconds(alias: "qwen3.6-27b-8bit", kind: .benchmark)
        #expect(small != nil && big != nil)
        #expect((big ?? 0) > (small ?? 0), "a 27B should take longer than a 4B")

        let free = BenchmarkRunner.etaSeconds(alias: "gemma-4-12b", kind: .benchmark)!
        let submit = BenchmarkRunner.etaSeconds(alias: "gemma-4-12b", kind: .submit)!
        #expect(submit > free, "submit re-runs the full standardized workload")
    }

    @Test("ETA is nil for a custom alias with no parseable size")
    func etaNilForUnknown() {
        #expect(BenchmarkRunner.etaSeconds(alias: "my-custom-model", kind: .benchmark) == nil)
    }

    // MARK: - Caption + bar fraction

    @Test("Caption answers 'how many minutes' up front, then reassures")
    func captionCountsDownThenReassures() {
        var p = Progress(kind: .benchmark, etaSeconds: 120)
        p.elapsedSeconds = 10
        #expect(p.caption.contains("min left"))
        #expect(p.caption.contains("0:10"))
        // Past the estimate we stop lying and switch to reassurance.
        p.elapsedSeconds = 130
        #expect(p.caption.contains("almost there"))
    }

    @Test("Caption falls back to a bare elapsed clock when ETA is unknown")
    func captionWithoutETA() {
        var p = Progress(kind: .benchmark, etaSeconds: nil)
        p.elapsedSeconds = 65
        #expect(p.caption == "Elapsed 1:05")
    }

    @Test("Bar fraction tracks elapsed/ETA but never claims 100% early")
    func fractionCappedBelowOne() {
        var p = Progress(kind: .benchmark, etaSeconds: 100)
        p.elapsedSeconds = 50
        #expect(abs((p.fraction ?? 0) - 0.5) < 0.001)
        // Even long past the ETA the determinate bar stays < 1.0 so it
        // can't flash "done" before the process actually exits.
        p.elapsedSeconds = 1000
        #expect((p.fraction ?? 0) <= 0.95)
        // No ETA → no determinate fraction (UI shows an indeterminate bar).
        let unknown = Progress(kind: .benchmark, etaSeconds: nil)
        #expect(unknown.fraction == nil)
    }
}
