import Foundation
import Testing
@testable import Rapid

@Suite("Sparkle update configuration")
struct SparkleUpdateControllerTests {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test("HTTPS feed plus 32-byte EdDSA public key enables Sparkle")
    func validConfiguration() {
        #expect(SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ]))
    }

    @MainActor
    @Test("enabled controller remains actionable before Sparkle starts")
    func enabledBeforeStart() {
        let controller = SparkleUpdateController(infoDictionary: [
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ])

        #expect(controller.isEnabled)
        #expect(!controller.isStarted)
        #expect(controller.canCheckForUpdates)
    }

    @Test("local build without injected public key keeps Sparkle disabled")
    func missingPublicKey() {
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
        ]))
    }

    @Test("configuration rejects insecure feeds and malformed public keys")
    func invalidConfiguration() {
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "http://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ]))
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 31).base64EncodedString(),
        ]))
    }

    @MainActor
    @Test("existing update-check opt-out also disables Sparkle")
    func updateCheckOptOut() {
        let controller = SparkleUpdateController(
            infoDictionary: [
                "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
                "SUPublicEDKey": publicKey,
            ],
            checksEnabled: false
        )
        #expect(!controller.isEnabled)
    }

    @MainActor
    @Test("golden busy fixture mirrors a background Sparkle session without starting Sparkle")
    func busyFixture() {
        let controller = SparkleUpdateController(
            infoDictionary: [:],
            checksEnabled: false,
            fixtureState: .busy
        )

        #expect(controller.isEnabled)
        #expect(!controller.canCheckForUpdates)
        controller.start()
        #expect(controller.isStarted)
        #expect(!controller.canCheckForUpdates)
    }
}
