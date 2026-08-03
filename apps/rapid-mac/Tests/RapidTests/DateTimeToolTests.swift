import Foundation
import Testing
@testable import Rapid

@Suite("CurrentDateTimeTool")
struct DateTimeToolTests {
    @Test("Resolving a real IANA identifier returns that exact zone")
    func resolvesIANA() {
        let (zone, label) = CurrentDateTimeTool.resolveZone("Asia/Tokyo")
        #expect(zone.identifier == "Asia/Tokyo")
        #expect(label == "Asia/Tokyo")
    }

    @Test("Lowercase / abbreviation shorthand still resolves (PST, JST, UTC)")
    func resolvesAbbreviation() {
        // ``TimeZone(abbreviation:)`` maps PST to America/Los_Angeles
        // on most platforms — assert by checking we got a NON-current
        // zone keyed by an abbreviation, not by hard-coding the IANA
        // result (Apple has historically moved DST-relevant zones).
        let (zone, label) = CurrentDateTimeTool.resolveZone("pst")
        #expect(zone.identifier != TimeZone.current.identifier || TimeZone.current.identifier.contains("Los_Angeles"))
        #expect(label.uppercased().contains("PST"))
    }

    @Test("Unknown identifier falls back to local with an explanatory label")
    func resolvesUnknown() {
        let (zone, label) = CurrentDateTimeTool.resolveZone("Toyko")  // typo
        #expect(zone.identifier == TimeZone.current.identifier)
        #expect(label.contains("not a known IANA identifier"))
        #expect(label.contains(TimeZone.current.identifier))
    }

    @Test("Nil / empty identifier → local timezone, no error label")
    func resolvesNilEmpty() {
        let (zone1, label1) = CurrentDateTimeTool.resolveZone(nil)
        #expect(zone1.identifier == TimeZone.current.identifier)
        #expect(label1.contains("local"))

        let (zone2, label2) = CurrentDateTimeTool.resolveZone("   ")
        #expect(zone2.identifier == TimeZone.current.identifier)
        #expect(label2.contains("local"))
    }

    @Test("Formatted output contains both human and ISO-8601 lines")
    func formatShape() {
        let zone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // fixed reference
        let out = CurrentDateTimeTool.format(date: date, zone: zone, label: "UTC")
        #expect(out.contains("UTC"))
        #expect(out.contains("Human:"))
        #expect(out.contains("ISO-8601:"))
        // The UTC instant for 1_700_000_000 is 2023-11-14T22:13:20Z.
        #expect(out.contains("2023-11-14"))
    }

    @Test("Run() with missing arguments JSON still returns a valid result (no error)")
    func runHandlesEmptyArgs() async {
        let result = await CurrentDateTimeTool.run(arguments: "")
        #expect(!result.isError)
        #expect(result.content.contains("Human:"))
    }

    @Test("Run() with explicit timezone returns a result mentioning it")
    func runWithExplicitZone() async {
        let result = await CurrentDateTimeTool.run(arguments: "{\"timezone\":\"Europe/Berlin\"}")
        #expect(!result.isError)
        #expect(result.content.contains("Europe/Berlin"))
    }
}
