import AppKit
import Testing
@testable import Rapid

/// #173 (formerly #169): the launch-time ``AXEnhancedUserInterface``
/// self-set returns ``-25208`` / ``kAXErrorNotImplemented`` on macOS
/// 15+/26 because the SwiftUI ``Window`` scene exposes no settable bridge
/// attribute to the in-process caller. That is EXPECTED and benign there
/// (mouse/keyboard/trackpad UI unaffected; VoiceOver flips the bridge via
/// its own path), so ``AppDelegate.shouldLogAXBridgeResult`` suppresses
/// the per-launch stderr line for it while still surfacing every OTHER
/// non-success as a canary for a genuine future contract change. These
/// pin that policy so a refactor can't silently re-introduce the noise
/// (or, worse, start swallowing real errors).
@Suite("AX bridge logging policy (#173)")
struct AXBridgeLoggingTests {

    @Test(".success is never logged")
    func successIsNotLogged() {
        #expect(AppDelegate.shouldLogAXBridgeResult(.success) == false)
    }

    @Test(".notImplemented (-25208) is suppressed — the expected macOS 15+/26 result")
    func notImplementedIsSuppressed() {
        // Pin the raw code too, so a future rename/regression that maps a
        // different case to -25208 fails loudly.
        #expect(AXError.notImplemented.rawValue == -25208)
        #expect(AppDelegate.shouldLogAXBridgeResult(.notImplemented) == false)
    }

    @Test("genuinely-unexpected non-success codes still log a canary line")
    func unexpectedCodesStillLog() {
        // -25205 / attributeUnsupported is the code the pre-#173 comment
        // confused with -25208; it is a REAL contract signal and must
        // still log if it ever appears here.
        #expect(AXError.attributeUnsupported.rawValue == -25205)
        #expect(AppDelegate.shouldLogAXBridgeResult(.attributeUnsupported))
        #expect(AppDelegate.shouldLogAXBridgeResult(.cannotComplete))
        #expect(AppDelegate.shouldLogAXBridgeResult(.apiDisabled))
        #expect(AppDelegate.shouldLogAXBridgeResult(.failure))
    }
}
