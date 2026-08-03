import Foundation
import Testing
@testable import Rapid

/// Contract for the CPU + GPU probe formatting / pressure-bucket
/// layers. The syscall surface itself (``host_processor_info`` /
/// ``AGXAccelerator`` IORegistry walk) is exercised at runtime by
/// the footer pills — no test stand here because we can't mock the
/// kernel — but the predicate / format math is pure and is what
/// would silently regress if a future refactor reordered the
/// thresholds.
@Suite("CPUProbe — pressure + format")
struct CPUProbeTests {

    @Test("Pressure bucket thresholds match the memory-pill convention")
    func pressureThresholds() {
        // Normal: < 70 %
        #expect(CPUProbe.Pressure.classify(percent: 0) == .normal)
        #expect(CPUProbe.Pressure.classify(percent: 35) == .normal)
        #expect(CPUProbe.Pressure.classify(percent: 69.99) == .normal)
        // Warning: 70 ≤ pct < 90
        #expect(CPUProbe.Pressure.classify(percent: 70) == .warning)
        #expect(CPUProbe.Pressure.classify(percent: 85) == .warning)
        #expect(CPUProbe.Pressure.classify(percent: 89.99) == .warning)
        // Critical: ≥ 90
        #expect(CPUProbe.Pressure.classify(percent: 90) == .critical)
        #expect(CPUProbe.Pressure.classify(percent: 100) == .critical)
    }

    @Test("First-call (nil baseline) returns 0 — UI shows 0% for one cycle then settles")
    func firstCallReturnsZero() {
        let snap = CPUProbe.Snapshot(user: 100, system: 50, idle: 850, nice: 0)
        #expect(CPUProbe.percentBusy(previous: nil, current: snap) == 0)
    }

    @Test("Half busy, half idle → 50%")
    func halfBusy() {
        let prev = CPUProbe.Snapshot(user: 100, system: 0, idle: 100, nice: 0)
        let curr = CPUProbe.Snapshot(user: 200, system: 0, idle: 200, nice: 0)
        let pct = CPUProbe.percentBusy(previous: prev, current: curr)
        #expect(abs(pct - 50.0) < 0.1)
    }

    @Test("Pure idle window → 0%")
    func pureIdle() {
        let prev = CPUProbe.Snapshot(user: 100, system: 50, idle: 1000, nice: 0)
        let curr = CPUProbe.Snapshot(user: 100, system: 50, idle: 1500, nice: 0)
        let pct = CPUProbe.percentBusy(previous: prev, current: curr)
        #expect(abs(pct - 0.0) < 0.1)
    }

    @Test("Fully pegged window → 100%")
    func fullyPegged() {
        let prev = CPUProbe.Snapshot(user: 100, system: 0, idle: 1000, nice: 0)
        let curr = CPUProbe.Snapshot(user: 600, system: 0, idle: 1000, nice: 0)
        let pct = CPUProbe.percentBusy(previous: prev, current: curr)
        #expect(abs(pct - 100.0) < 0.1)
    }

    @Test("Equal snapshots (zero delta) gracefully returns 0 — no divide-by-zero")
    func equalSnapshotsNoDivByZero() {
        let snap = CPUProbe.Snapshot(user: 500, system: 100, idle: 400, nice: 0)
        let pct = CPUProbe.percentBusy(previous: snap, current: snap)
        #expect(pct == 0)
    }

    @Test("Nice ticks count as busy (matches Activity Monitor's bucket)")
    func niceIsBusy() {
        let prev = CPUProbe.Snapshot(user: 0, system: 0, idle: 0, nice: 0)
        let curr = CPUProbe.Snapshot(user: 0, system: 0, idle: 100, nice: 100)
        let pct = CPUProbe.percentBusy(previous: prev, current: curr)
        #expect(abs(pct - 50.0) < 0.1)
    }

    @Test("Format: rounds half-up, integer percent, single-line")
    func formatRoundsCleanly() {
        #expect(CPUProbe.formatLabel(percent: 0) == "0%")
        #expect(CPUProbe.formatLabel(percent: 38.4) == "38%")
        #expect(CPUProbe.formatLabel(percent: 38.5) == "39%")
        #expect(CPUProbe.formatLabel(percent: 100) == "100%")
    }

    @Test("Snapshot tick math: totalTicks + busyTicks accessors")
    func snapshotAccessors() {
        let s = CPUProbe.Snapshot(user: 10, system: 20, idle: 100, nice: 5)
        #expect(s.totalTicks == 135)
        #expect(s.busyTicks == 35)
    }
}

@Suite("GPUProbe — pressure + format")
struct GPUProbeTests {

    @Test("Pressure thresholds mirror CPU + memory pills")
    func pressureThresholds() {
        #expect(GPUProbe.Pressure.classify(percent: 0) == .normal)
        #expect(GPUProbe.Pressure.classify(percent: 69.99) == .normal)
        #expect(GPUProbe.Pressure.classify(percent: 70) == .warning)
        #expect(GPUProbe.Pressure.classify(percent: 89.99) == .warning)
        #expect(GPUProbe.Pressure.classify(percent: 90) == .critical)
        #expect(GPUProbe.Pressure.classify(percent: 100) == .critical)
    }

    @Test("Format: rounds half-up, integer percent")
    func formatRoundsCleanly() {
        #expect(GPUProbe.formatLabel(percent: 0) == "0%")
        #expect(GPUProbe.formatLabel(percent: 62.4) == "62%")
        #expect(GPUProbe.formatLabel(percent: 62.5) == "63%")
        #expect(GPUProbe.formatLabel(percent: 100) == "100%")
    }
}
