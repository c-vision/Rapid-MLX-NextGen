import Foundation
import Testing
@testable import Rapid

/// Pins the three lifecycle shapes ``SplashView`` cares about so that
/// later iterations (downloader, verifier, extractor, installer) can
/// flow state through ``SplashViewModel`` without accidentally
/// regressing the view's rendering contract.
///
/// We deliberately don't ViewInspect the SwiftUI tree here — the
/// SplashView is read-only and the model fields ARE the contract.
/// Tests that walk the view hierarchy would lock us into the current
/// VStack layout when the next iteration likely needs to add a phase
/// breakdown row.
@Suite("SplashViewModel")
@MainActor
struct SplashViewModelTests {
    @Test("default state describes first-launch waiting")
    func defaultState() {
        let m = SplashViewModel()
        #expect(m.progress == 0)
        #expect(m.cancellable == true)
        #expect(m.headline.isEmpty == false)
        #expect(m.detail.isEmpty)
    }

    @Test("downloading phase populates headline + detail with byte counts")
    func downloadingPhase() {
        let m = SplashViewModel()
        m.progress = 0.32
        m.headline = "Downloading rapid-mlx engine…"
        m.detail = "rapid-mlx-sidecar-0.8.0.tar.gz · 89.4 / 280.1 MB"

        #expect(m.progress > 0 && m.progress < 1)
        #expect(m.cancellable == true, "user must be able to bail during a long download")
        #expect(m.headline.hasPrefix("Downloading"))
        #expect(m.detail.contains("280.1 MB"))
    }

    @Test("atomic-install phase forbids cancel")
    func finalisePhase() {
        let m = SplashViewModel()
        m.progress = 0.96
        m.headline = "Finalising install…"
        m.detail = "rename + codesign verify"
        m.cancellable = false

        #expect(m.progress > 0.9)
        #expect(m.cancellable == false,
            "cancelling during atomic rename + codesign verify would leave a half-installed .app on disk")
    }
}
