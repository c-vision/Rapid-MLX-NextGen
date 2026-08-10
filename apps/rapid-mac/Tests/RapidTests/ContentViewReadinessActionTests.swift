import Foundation
import Testing
@testable import Rapid

@Suite("ContentView readiness action wiring")
struct ContentViewReadinessActionTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RapidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    @Test("Chat readiness replaces a different resident model")
    func readinessUsesEnsureServing() throws {
        let url = Self.packageRoot
            .appendingPathComponent("Sources/Rapid/UI/ContentView.swift")
        let body = try String(contentsOf: url, encoding: .utf8)
        let source = CapabilityChipRenderGateSourceGuardTests
            .stripCommentsAndWhitespace(body)

        guard let signature = source.range(
            of: "privatefuncstartModel(_target:String){"
        ) else {
            Issue.record("ContentView.startModel could not be found")
            return
        }
        // Balance braces from the function's opening ``{`` — a plain
        // ``firstIndex(of: "}")`` stops at the ``}`` of the
        // ``catalogEntries.first(where: { $0.alias == target })`` closure,
        // truncating the body before the ``ensureServing`` call and failing
        // the assertion on correct code.
        var depth = 1
        var index = signature.upperBound
        var functionEnd: String.Index?
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    functionEnd = index
                }
            default: break
            }
            if functionEnd != nil { break }
            index = source.index(after: index)
        }
        guard let functionEnd else {
            Issue.record("ContentView.startModel has no closing brace")
            return
        }
        let function = String(source[signature.lowerBound...functionEnd])

        #expect(
            function.contains("server.ensureServing(alias:target,hfPath:hfPath)"),
            "The Chat readiness button must switch away from a resident Images model."
        )
        #expect(
            !function.contains("server.start(alias:target,hfPath:hfPath)"),
            "ServerManager.start is cold-start only and silently no-ops while Images is resident."
        )
    }
}
