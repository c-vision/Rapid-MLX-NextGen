import Testing
import ServiceManagement
@testable import Rapid

/// Coverage for ``LaunchAtLogin`` — the SMAppService wrapper that
/// powers the Settings → Quick Ask "Launch Rapid at login" toggle.
/// All paths use an in-process fake of ``LaunchAtLoginService`` so
/// the tests never touch the real Login Items list.
@MainActor
@Suite("LaunchAtLogin")
struct LaunchAtLoginTests {
    /// Programmable fake of ``LaunchAtLoginService``. Tests preload
    /// a status, a register/unregister error, and inspect the call
    /// log after driving the model.
    final class FakeService: LaunchAtLoginService {
        var status: SMAppService.Status
        var registerError: Error?
        var unregisterError: Error?
        var registerCalls = 0
        var unregisterCalls = 0
        /// codex r3: when set, a successful ``register()`` resolves to
        /// this status instead of the default ``.enabled``. Lets the
        /// ``.requiresApproval`` path (register succeeded, OS reports
        /// the helper as awaiting user approval) be exercised end-to-
        /// end through ``setEnabled`` without forcing the test to
        /// mutate ``status`` after the fact.
        var registerSuccessStatus: SMAppService.Status?

        init(status: SMAppService.Status) {
            self.status = status
        }

        func register() throws {
            registerCalls += 1
            if let err = registerError { throw err }
            status = registerSuccessStatus ?? .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            if let err = unregisterError { throw err }
            status = .notRegistered
        }
    }

    @Test("isEnabled mirrors initial service status")
    func initial_status_mirrored() {
        let svc = FakeService(status: .enabled)
        let model = LaunchAtLogin(service: svc)
        #expect(model.isEnabled)
        #expect(model.status == .enabled)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("flipping isEnabled true → register() is called and status updates")
    func enable_calls_register() {
        let svc = FakeService(status: .notRegistered)
        let model = LaunchAtLogin(service: svc)
        #expect(!model.isEnabled)

        model.isEnabled = true

        #expect(svc.registerCalls == 1)
        #expect(svc.unregisterCalls == 0)
        #expect(model.isEnabled)
        #expect(model.status == .enabled)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("flipping isEnabled false → unregister() is called and status updates")
    func disable_calls_unregister() {
        let svc = FakeService(status: .enabled)
        let model = LaunchAtLogin(service: svc)
        #expect(model.isEnabled)

        model.isEnabled = false

        #expect(svc.registerCalls == 0)
        #expect(svc.unregisterCalls == 1)
        #expect(!model.isEnabled)
        #expect(model.status == .notRegistered)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("kSMErrorLaunchDeniedByUser (code 11) → 'enable in Login Items' copy")
    func register_error_approval_required() throws {
        let svc = FakeService(status: .notRegistered)
        // ``kSMErrorLaunchDeniedByUser`` per SMErrors.h.
        svc.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "denied"]
        )
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        #expect(svc.registerCalls == 1)
        #expect(!model.isEnabled, "status stayed .notRegistered because register() threw")
        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("Login Items"), "approval-required copy directs the user at the right surface")
    }

    @Test("kSMErrorInvalidSignature (code 3) → '/Applications + signed' copy, NOT Login Items")
    func register_error_invalid_signature() throws {
        let svc = FakeService(status: .notRegistered)
        // ``kSMErrorInvalidSignature`` — typical for ``swift run`` dev builds.
        svc.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "unsigned"]
        )
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("/Applications"), "code 3 copy names the real fix (install location / signing)")
        #expect(!msg.contains("Login Items"), "code 3 must NOT send the user on a Login-Items goose chase")
    }

    @Test("kSMErrorAlreadyRegistered (code 12) during register → message is cleared because intent already met")
    func register_error_already_registered_clears_message() {
        // Real-world: user flips toggle ON; SMAppService refuses
        // because the helper is already enrolled. status post-refresh
        // shows .enabled → user's intent satisfied → no sticky warning
        // beside an ON toggle that would invite them to flip it back.
        let svc = FakeService(status: .enabled)
        svc.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 12, userInfo: nil)
        let model = LaunchAtLogin(service: svc)
        #expect(model.isEnabled, "fixture pre-condition: starts enabled")

        model.isEnabled = true

        #expect(svc.registerCalls == 1)
        #expect(model.isEnabled, "status remains .enabled after the throw")
        #expect(
            model.lastErrorMessage == nil,
            "codex r2 BLOCKING: setEnabled clears the warning because the user's intent (enabled) is already met"
        )
    }

    @Test("kSMErrorJobNotFound (code 6) during unregister → message is cleared because intent already met")
    func unregister_error_job_not_found_clears_message() {
        // Symmetric case: user flips toggle OFF; SMAppService refuses
        // because there is nothing to unregister. status stays
        // .notRegistered → intent satisfied → no warning.
        let svc = FakeService(status: .notRegistered)
        svc.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: 6, userInfo: nil)
        let model = LaunchAtLogin(service: svc)
        #expect(!model.isEnabled, "fixture pre-condition: starts disabled")

        model.isEnabled = false

        #expect(svc.unregisterCalls == 1)
        #expect(!model.isEnabled)
        #expect(
            model.lastErrorMessage == nil,
            "codex r2 BLOCKING (symmetric): setEnabled clears the warning when unregister intent is already met"
        )
    }

    @Test("kSMErrorInvalidPlist (code 9) → packaging-bug copy, NOT Login Items")
    func register_error_invalid_plist() throws {
        // Code 9 is a packaging-time bug; no amount of user-side
        // action fixes it. Copy should name reinstall / file-a-bug.
        let svc = FakeService(status: .notRegistered)
        svc.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 9, userInfo: nil)
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("Reinstall") || msg.contains("file a bug"), "names a real corrective action")
        #expect(!msg.contains("Login Items"), "packaging bug must NOT send user to Login Items")
    }

    @Test("kSMErrorJobNotFound (code 6) → transient state mismatch copy")
    func register_error_job_not_found_transient() throws {
        let svc = FakeService(status: .notRegistered)
        svc.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 6, userInfo: nil)
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("transient"), "transient copy invites the user to retry rather than reach for Settings")
        #expect(msg.contains("6"), "surface the code so the next hop (us / a logfile) can act on it")
    }

    @Test("unknown SMAppService code falls through to generic-with-code copy")
    func register_error_unknown_code_fallthrough() throws {
        let svc = FakeService(status: .notRegistered)
        // 99 is not in SMErrors.h — the default branch must surface
        // the code so a logfile reader can act on a future framework
        // addition without us shipping a fix first.
        svc.registerError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "future code"]
        )
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("99"), "default branch surfaces the unmapped code numerically")
        #expect(!msg.contains("Login Items"), "fall-through must NOT pretend to be the approval-required branch")
    }

    @Test("unregister error keeps lastErrorMessage populated")
    func unregister_error_surfaces() {
        let svc = FakeService(status: .enabled)
        svc.unregisterError = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 11,
            userInfo: nil
        )
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = false

        #expect(svc.unregisterCalls == 1)
        #expect(model.isEnabled, "register state held because unregister() threw")
        #expect(model.lastErrorMessage != nil)
    }

    @Test("non-SMAppServiceErrorDomain errors fall back to generic copy")
    func unknown_error_domain_generic_copy() throws {
        let svc = FakeService(status: .notRegistered)
        svc.registerError = NSError(
            domain: "SomeOtherDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "weird problem"]
        )
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        let msg = try #require(model.lastErrorMessage)
        #expect(msg.contains("weird problem"), "generic branch surfaces underlying localizedDescription")
        #expect(!msg.contains("System Settings"), "generic branch does not lie about where to fix it")
    }

    @Test("successful flip clears a prior error message")
    func successful_flip_clears_error() {
        let svc = FakeService(status: .notRegistered)
        svc.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 11, userInfo: nil)
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true
        #expect(model.lastErrorMessage != nil)

        // Recover: drop the canned error and try again.
        svc.registerError = nil
        model.isEnabled = true

        #expect(model.lastErrorMessage == nil, "second success wipes the stale failure note")
        #expect(model.isEnabled)
    }

    @Test("refresh() re-reads service status without mutating")
    func refresh_re_reads_status() {
        let svc = FakeService(status: .notRegistered)
        let model = LaunchAtLogin(service: svc)
        #expect(!model.isEnabled)

        // Simulate the user enabling Rapid in System Settings →
        // Login Items while the Settings sheet is open in Rapid.
        svc.status = .enabled
        model.refresh()

        #expect(model.isEnabled)
        #expect(svc.registerCalls == 0, "refresh did not call register()")
        #expect(svc.unregisterCalls == 0, "refresh did not call unregister()")
    }

    @Test("register success → .requiresApproval surfaces approval guidance")
    func register_requires_approval_surfaces_hint() throws {
        // codex r3 BLOCKING: register() can succeed (no throw) and
        // still leave status at .requiresApproval — the OS recorded
        // the helper but the user must enable it in System Settings.
        // Without a hint the toggle silently drifts back to OFF.
        let svc = FakeService(status: .notRegistered)
        svc.registerSuccessStatus = .requiresApproval
        let model = LaunchAtLogin(service: svc)

        model.isEnabled = true

        #expect(svc.registerCalls == 1)
        #expect(!model.isEnabled, "status is .requiresApproval, not .enabled, so isEnabled is false")
        let msg = try #require(model.lastErrorMessage, "approval-required success path must surface guidance")
        #expect(msg.contains("Login Items"), "directs the user at the right surface")
        #expect(msg.contains("approval") || msg.contains("approve"), "names the missing action")
    }

    @Test("refresh() clears stale warning when out-of-band approval lands user at .enabled")
    func refresh_clears_stale_warning_after_external_approval() {
        // codex r3 BLOCKING: user hits code 11, sees the "enable in
        // Login Items" hint, opens System Settings, approves Rapid,
        // returns to Rapid's Settings tab. SettingsView.onAppear
        // calls refresh(). Toggle should now show ON and the orange
        // triangle warning should be gone — not paired with a stale
        // hint telling the user to do the thing they already did.
        let svc = FakeService(status: .notRegistered)
        svc.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 11, userInfo: nil)
        let model = LaunchAtLogin(service: svc)
        model.isEnabled = true
        #expect(model.lastErrorMessage != nil, "fixture pre-condition: code 11 populated the warning")
        #expect(!model.isEnabled, "fixture pre-condition: register threw, toggle is OFF")

        // User approves Rapid in System Settings → Login Items
        // out-of-band. status now reports .enabled on next read.
        svc.status = .enabled
        model.refresh()

        #expect(model.isEnabled, "refresh picked up the external approval")
        #expect(
            model.lastErrorMessage == nil,
            "codex r3 BLOCKING: refresh clears stale warning once the OS reports .enabled"
        )
    }
}
