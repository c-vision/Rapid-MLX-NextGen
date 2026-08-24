import AppKit
import Darwin
import XCTest

@MainActor
final class RapidUITestHarness {
    let app: XCUIApplication
    let eventLog: URL
    let rapidMacRoot: URL

    private let testHome: URL
    private let sidecarAlias: String
    private let sidecarPIDFile: URL

    init(testName: String, fakeSettings: [String: String], port: Int) throws {
        testHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-xcui-\(testName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testHome, withIntermediateDirectories: true)

        rapidMacRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RapidUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // rapid-mac
        let fakeSidecar = rapidMacRoot.appendingPathComponent("scripts/fake-rapid-mlx.sh").path
        let appURL = rapidMacRoot.appendingPathComponent("build/Rapid-MLX Desktop.app")
        eventLog = testHome.appendingPathComponent("fake-events.jsonl")
        sidecarPIDFile = testHome.appendingPathComponent("fake-sidecar.pid")
        sidecarAlias = fakeSettings["FAKE_VISION_CHAT"] == "1"
            ? "qwen3-vl-2b-4bit"
            : "fake-alias"

        var config = fakeSettings
        config["FAKE_EVENT_LOG"] = eventLog.path
        config["FAKE_PID_FILE"] = sidecarPIDFile.path
        let configData = try JSONSerialization.data(withJSONObject: config)
        try configData.write(to: testHome.appendingPathComponent(".rapid-golden-fake.json"))

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fakeSidecar))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        app = XCUIApplication(url: appURL)
        app.launchEnvironment = [
            "HOME": testHome.path,
            "CFFIXED_USER_HOME": testHome.path,
            "RAPID_BIN": fakeSidecar,
            "FAKE_EVENT_LOG": eventLog.path,
            "RAPID_DESKTOP_PORT": String(port),
            "RAPID_DESKTOP_NO_PORT_SWEEP": "1",
        ].merging(fakeSettings) { _, fixture in fixture }
    }

    func launch() {
        app.launch()
        XCTAssertTrue(app.windows["Rapid-MLX"].waitForExistence(timeout: 20))
        dismissFirstRunIfNeeded()
    }

    func shutDown() {
        app.terminate()
        terminateFakeSidecars()
        try? FileManager.default.removeItem(at: testHome)
    }

    func startModel() {
        let readiness = element("Readiness.Action")
        XCTAssertTrue(readiness.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { readiness.isEnabled })
        readiness.click()
        let memoryConfirmation = element("MemoryWarning.Confirm")
        var confirmedMemoryWarning = false
        XCTAssertTrue(waitUntil(timeout: 60) {
            if !confirmedMemoryWarning,
               memoryConfirmation.exists,
               memoryConfirmation.isEnabled {
                memoryConfirmation.click()
                confirmedMemoryWarning = true
            }
            return self.events().contains { $0["event"] as? String == "server_started" }
        })
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func conversationRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier MATCHES %@",
                #"^Sidebar\.Conversation\.[0-9A-Fa-f-]{36}$"#
            )
        )
    }

    func chooseFile(_ url: URL, actionIdentifier: String) {
        let add = element("ChatView.AddAttachments")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let action = element(actionIdentifier)
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(action.isEnabled)
        action.click()

        // NSOpenPanel has no stable product-owned identifiers. “Go to Folder”
        // is the native keyboard path and avoids coordinate clicks entirely.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.dialogs["open-panel"].buttons["OKButton"]
        XCTAssertTrue(waitUntil(timeout: 10) { open.isHittable })
        open.click()
    }

    func send(_ text: String, expectedRequestCount: Int) {
        let composer = element("rapid.chat.compose")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText(text)
        let send = element("ChatView.SendOrStopButton")
        XCTAssertTrue(waitUntil(timeout: 10) { send.isEnabled })
        send.click()
        XCTAssertTrue(waitUntil(timeout: 30) { self.chatRequests().count == expectedRequestCount })
        XCTAssertTrue(waitUntil(timeout: 30) {
            self.element("ChatView.SendOrStopButton").label == "Send message"
        })
    }

    func chatRequests() -> [[String: Any]] {
        events().filter { $0["event"] as? String == "chat_request" }
    }

    @discardableResult
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    private func dismissFirstRunIfNeeded() {
        let decline = element("TelemetryConsent.DontShare")
        if decline.waitForExistence(timeout: 5) { decline.click() }
        let skip = element("Quickstart.Skip")
        if skip.waitForExistence(timeout: 10) { skip.click() }
    }

    private func events() -> [[String: Any]] {
        guard let text = try? String(contentsOf: eventLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func terminateFakeSidecars() {
        var pids: Set<Int32> = Set(events().compactMap { event in
            guard event["event"] as? String == "server_started",
                  event["alias"] as? String == sidecarAlias,
                  let pid = event["pid"] as? NSNumber else { return nil }
            return pid.int32Value
        })
        if let text = try? String(contentsOf: sidecarPIDFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            pids.insert(pid)
        }
        for pid in pids where processCommand(pid: pid).contains("serve \(sidecarAlias)") {
            Darwin.kill(pid, SIGTERM)
            for _ in 0..<20 where Darwin.kill(pid, 0) == 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if Darwin.kill(pid, 0) == 0,
               processCommand(pid: pid).contains("serve \(sidecarAlias)") {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private func processCommand(pid: Int32) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}
