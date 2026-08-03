import Foundation
import IOKit

/// Live Apple-Silicon GPU utilisation probe. macOS doesn't ship a
/// public framework for "how busy is my GPU right now" — Activity
/// Monitor reads it via the private IOReport API. Same place
/// ``asitop`` / ``mactop`` get the number from.
///
/// Cheaper route, and the one used here: walk the IOKit registry
/// for the ``AGXAccelerator`` service (the Apple GPU's IOService),
/// read its ``PerformanceStatistics`` property, and pull out
/// ``Device Utilization %``. The key is documented in passing in
/// Apple's GPU performance bug reports; the property has been
/// stable since macOS 11 on every M-series machine. Intel Macs
/// have no ``AGXAccelerator`` and ``snapshot()`` returns nil — the
/// pill then renders "GPU n/a" rather than zeros.
///
/// Same shape as ``MemoryProbe`` / ``CPUProbe`` so the footer view
/// can wire all three pills the same way.
enum GPUProbe {
    struct Snapshot: Equatable, Sendable {
        /// 0…100. Single GPU on every supported Mac, no per-engine
        /// breakdown surfaced (the Activity-Monitor-equivalent
        /// number is the aggregate).
        let percent: Double
    }

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

    /// Read the current GPU utilisation. Returns nil on Intel
    /// (no ``AGXAccelerator`` service) or when the property isn't
    /// readable (sandbox / SIP edge case).
    static func snapshot(
        executionObserver: (@Sendable (Bool) -> Void)? = nil
    ) -> Snapshot? {
        executionObserver?(Thread.isMainThread)
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var found: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = readPerformanceStatistics(service: service) else { continue }
            // "Device Utilization %" is the per-frame aggregate
            // number Activity Monitor renders. Some macOS versions
            // also expose "GPU Activity(%)" or "Renderer
            // Utilization %" — fall back through the variants
            // because the key name has shifted across releases.
            if let pct = stats["Device Utilization %"] as? NSNumber {
                found = pct.doubleValue
                break
            }
            if let pct = stats["GPU Activity(%)"] as? NSNumber {
                found = pct.doubleValue
                break
            }
            if let pct = stats["Renderer Utilization %"] as? NSNumber {
                found = pct.doubleValue
                break
            }
        }
        guard let pct = found else { return nil }
        return Snapshot(percent: min(100.0, max(0.0, pct)))
    }

    /// Format the pill label — "62%". Stable across the various
    /// percent key variants because the formatter only sees the
    /// resolved number.
    static func formatLabel(percent: Double) -> String {
        String(format: "%d%%", Int(percent.rounded()))
    }

    private static func readPerformanceStatistics(service: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS, let propsRef = properties else { return nil }
        defer { propsRef.release() }
        let props = propsRef.takeUnretainedValue() as NSDictionary
        return props["PerformanceStatistics"] as? [String: Any]
    }
}
