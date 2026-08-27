import Foundation

/// Real-host process-liveness probe. A PID can be detected as
/// "not alive" even while it is technically a zombie; for our purpose
/// (is the run still making progress?) a live-or-zombie distinction is
/// handled by treating only an explicit "no such PID" as dead.
public enum ProcessAlive {

    /// True if a process with `pid` exists right now.
    ///
    /// Uses `kill(pid, 0)` (the standard "does this pid exist" probe), which
    /// requires no child relationship and triggers no signal delivery. A
    /// ``errno`` of ``ESRCH`` (no such process) → false; permission-denied
    /// (``EPERM``) still means the process exists → true.
    public static func isAlive(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
