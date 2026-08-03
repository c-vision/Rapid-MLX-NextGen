import Testing
@testable import Rapid

/// The master "Auto-approve everything" switch has no state — it reflects the
/// five per-category flags and is on only when all five are. These pin that
/// all-or-nothing contract so a future refactor can't quietly make the master
/// read on while a category still prompts.
@Suite("PermissionsMaster")
struct PermissionsMasterTests {

    @Test("On only when every axis is on")
    func onlyWhenAllOn() {
        #expect(PermissionsMaster.allEnabled(read: true, write: true, run: true, browse: true, mcp: true))
    }

    @Test("Off when any single axis is off")
    func offWhenAnyOff() {
        #expect(!PermissionsMaster.allEnabled(read: false, write: true, run: true, browse: true, mcp: true))
        #expect(!PermissionsMaster.allEnabled(read: true, write: false, run: true, browse: true, mcp: true))
        #expect(!PermissionsMaster.allEnabled(read: true, write: true, run: false, browse: true, mcp: true))
        #expect(!PermissionsMaster.allEnabled(read: true, write: true, run: true, browse: false, mcp: true))
        #expect(!PermissionsMaster.allEnabled(read: true, write: true, run: true, browse: true, mcp: false))
    }

    @Test("Off when everything is off")
    func offWhenAllOff() {
        #expect(!PermissionsMaster.allEnabled(read: false, write: false, run: false, browse: false, mcp: false))
    }
}
