import Testing
@testable import Rapid

@Suite("About candidate identity")
struct AboutPanelCandidateIdentityTests {
    @Test("release build keeps the stable version line")
    func releaseVersionLine() {
        #expect(
            AboutPanel.versionLine(
                version: "0.13.1",
                build: "166",
                candidateIdentity: nil
            ) == "Version 0.13.1 (166)"
        )
    }

    @Test("candidate build exposes its exact source identity")
    func candidateVersionLine() {
        #expect(
            AboutPanel.versionLine(
                version: "0.13.1",
                build: "166",
                candidateIdentity: "candidate-a6b820cf"
            ) == "Version 0.13.1 (166) · candidate-a6b820cf"
        )
    }
}
