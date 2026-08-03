import Darwin
import Foundation

/// Live CPU-load probe for the bottom-status row. Same shape as
/// ``MemoryProbe`` — stateless syscall pair, no inter-call state, the
/// caller (``CPUPill``) holds the previous tick snapshot in SwiftUI
/// state so the view can compute a delta on each refresh.
///
/// macOS exposes host-wide CPU ticks via ``host_processor_info`` /
/// ``processor_cpu_load_info_t`` — the same source ``top(1)`` and
/// Activity Monitor read. We sum across cores (M3 Ultra has 28 of
/// them and a per-core pill would be unreadable in the footer), and
/// compute the user + system + nice share as "busy."
enum CPUProbe {
    /// Raw tick snapshot. Useful → useless without a second reading
    /// to subtract; the pill view stores the previous snapshot in
    /// ``@State`` and feeds the pair to ``percentBusy(previous:current:)``
    /// each refresh.
    struct Snapshot: Equatable, Sendable {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var totalTicks: UInt64 { user &+ system &+ idle &+ nice }
        var busyTicks: UInt64 { user &+ system &+ nice }
    }

    /// Same Activity-Monitor-style pressure bucket pattern that the
    /// memory pill uses. Numbers are calibrated for sustained
    /// background load on M-series — a 10-second average above 70 %
    /// during a model load is "tight"; above 90 % means the user is
    /// pegged and other apps will feel sluggish.
    enum Pressure: Equatable, Sendable {
        case normal
        case warning
        case critical

        static func classify(percent: Double) -> Pressure {
            if percent >= 90 { return .critical }
            if percent >= 70 { return .warning }
            return .normal
        }
    }

    /// Single tick read across all logical CPUs. Returns nil if the
    /// Mach call fails — the pill renders a hyphen in that case.
    static func snapshot(
        executionObserver: (@Sendable (Bool) -> Void)? = nil
    ) -> Snapshot? {
        executionObserver?(Thread.isMainThread)
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var msgCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &msgCount
        )
        guard result == KERN_SUCCESS, cpuCount > 0, let cpuInfo else { return nil }
        defer {
            // ``host_processor_info`` allocates a fresh vm region we
            // own; ``vm_deallocate`` is the documented release.
            // Leaking it here would gradually starve the kernel
            // allocator over thousands of refreshes.
            let size = vm_size_t(MemoryLayout<integer_t>.size * Int(msgCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            user &+= UInt64(cpuInfo[base + Int(CPU_STATE_USER)])
            system &+= UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            idle &+= UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)])
            nice &+= UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
        }
        return Snapshot(user: user, system: system, idle: idle, nice: nice)
    }

    /// Compute the busy % across the delta between two snapshots.
    /// First-ever call (no ``previous`` baseline) returns 0 — the UI
    /// reads "0%" for one cycle then settles into truthful numbers.
    /// We don't return nil because a missing-baseline state isn't
    /// meaningfully different from "load is currently zero" for the
    /// pill's purpose.
    static func percentBusy(previous: Snapshot?, current: Snapshot) -> Double {
        guard let prev = previous else { return 0 }
        let totalDelta = current.totalTicks &- prev.totalTicks
        let busyDelta = current.busyTicks &- prev.busyTicks
        guard totalDelta > 0 else { return 0 }
        return min(100.0, Double(busyDelta) / Double(totalDelta) * 100.0)
    }

    /// Format the pill label — "38%" — kept out of the view so the
    /// rendering contract can be unit-tested.
    static func formatLabel(percent: Double) -> String {
        String(format: "%d%%", Int(percent.rounded()))
    }
}
