import Foundation
import Testing
@testable import Rapid

/// Pin the chip-classification rules so a future "support M5" change
/// can't silently regress M1/M2/M3/M4 detection.
@Suite("MacHardware chip classifier")
struct MacHardwareTests {
    @Test("Recognises every Apple Silicon family/tier combination")
    func classifyAllShipped() {
        let cases: [(brand: String, family: MacHardware.ChipFamily, tier: MacHardware.ChipTier)] = [
            ("Apple M1",       .m1, .base),
            ("Apple M1 Pro",   .m1, .pro),
            ("Apple M1 Max",   .m1, .max),
            ("Apple M1 Ultra", .m1, .ultra),
            ("Apple M2",       .m2, .base),
            ("Apple M2 Pro",   .m2, .pro),
            ("Apple M2 Max",   .m2, .max),
            ("Apple M2 Ultra", .m2, .ultra),
            ("Apple M3",       .m3, .base),
            ("Apple M3 Pro",   .m3, .pro),
            ("Apple M3 Max",   .m3, .max),
            ("Apple M3 Ultra", .m3, .ultra),
            ("Apple M4",       .m4, .base),
            ("Apple M4 Pro",   .m4, .pro),
            ("Apple M4 Max",   .m4, .max),
            ("Apple M4 Ultra", .m4, .ultra),
        ]
        for c in cases {
            let (fam, tier) = MacHardware.classify(c.brand)
            #expect(fam == c.family, "family mismatch for \(c.brand): got \(fam)")
            #expect(tier == c.tier, "tier mismatch for \(c.brand): got \(tier)")
        }
    }

    @Test("Falls through to mUnknown/unknown rather than crashing on a forward-compat chip")
    func unknownChipDoesNotCrash() {
        let (fam, tier) = MacHardware.classify("Apple M9 Quantum")
        #expect(fam == .mUnknown)
        #expect(tier == .unknown)
    }

    @Test("Bandwidth table is monotonic within a family")
    func bandwidthMonotonic() {
        // Within each generation, Ultra >= Max >= Pro >= base — both for
        // Apple's actual chips and as a sanity bound for our table.
        for fam: MacHardware.ChipFamily in [.m1, .m2, .m3, .m4] {
            let base = MacHardware.bandwidthGBs(family: fam, tier: .base)
            let pro = MacHardware.bandwidthGBs(family: fam, tier: .pro)
            let max = MacHardware.bandwidthGBs(family: fam, tier: .max)
            let ultra = MacHardware.bandwidthGBs(family: fam, tier: .ultra)
            #expect(ultra >= max, "\(fam) ultra (\(ultra)) < max (\(max))")
            #expect(max >= pro, "\(fam) max (\(max)) < pro (\(pro))")
            #expect(pro >= base, "\(fam) pro (\(pro)) < base (\(base))")
        }
    }

    @Test("Usable RAM is 80% of physical")
    func usable80Percent() {
        let hw = MacHardware(
            brandString: "Apple M3",
            family: .m3,
            tier: .base,
            physicalRAMBytes: 24 * UInt64(1 << 30),
            memoryBandwidthGBs: 100
        )
        #expect(abs(hw.physicalRAMGB - 24.0) < 0.05)
        // 24 × 0.8 = 19.2
        #expect(abs(hw.usableRAMGB - 19.2) < 0.05)
    }

    @Test("shortDescription strips the Apple prefix")
    func shortDescriptionShape() {
        let hw = MacHardware(
            brandString: "Apple M3 Pro",
            family: .m3,
            tier: .pro,
            physicalRAMBytes: 18 * UInt64(1 << 30),
            memoryBandwidthGBs: 150
        )
        #expect(hw.shortDescription == "18 GB · M3 Pro")
    }

    @Test("Live probe runs without throwing")
    func liveProbeRuns() {
        // We can't assert specific values (depends on the test
        // machine), but the probe MUST return a non-zero RAM number
        // on any real Mac — if hw.memsize ever comes back zero
        // something is badly wrong.
        let hw = MacHardware.detect()
        #expect(hw.physicalRAMBytes > 0)
    }
}
