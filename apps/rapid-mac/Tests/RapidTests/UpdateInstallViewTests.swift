import Testing
@testable import Rapid

@Suite("UpdateInstallView progress display")
struct UpdateInstallViewTests {
    @Test("Progress display is clamped to ProgressView's 0...1 range")
    func progressClamps() {
        #expect(UpdateInstallView.displayProgress(-0.25) == 0)
        #expect(UpdateInstallView.displayProgress(0.42) == 0.42)
        #expect(UpdateInstallView.displayProgress(1.25) == 1)
        #expect(UpdateInstallView.displayProgress(Double.nan) == 0)
    }
}
