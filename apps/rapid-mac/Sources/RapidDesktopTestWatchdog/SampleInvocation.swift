import Foundation

/// Real-host sampler: captures a hung process's stack with `/usr/bin/sample`
/// plus a snapshot of process state (`ps`) and memory pressure (`vm_stat`),
/// all written into a single `.txt` artifact for CI to upload.
///
/// The invocation pattern mirrors the existing in-process
/// `CIHangWatchdog.sample(pid:)` (Tests/RapidTests/Support/CIHangWatchdog.swift)
/// so a developer who has read one recognizes the other; the addition here is
/// that the whole set is redirected into a named artifact file rather than
/// `/dev/stdout`, plus `ps`/`vm_stat` give the RAM/memory-pressure context that
/// lets a reader tell a "stuck waiting on memory" hang from a pure deadlock.
public enum SampleInvocation {

    /// Capture the stack + system state for `pid` into `artifactURL`.
    public static func capture(
        pid: pid_t,
        config: WatchdogConfig = WatchdogConfig(),
        artifactURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Fresh materialize the artifact (FileHandle(forWritingTo:) alone
        // fails when the file doesn't yet exist), then write the sections.
        if !FileManager.default.fileExists(atPath: artifactURL.path) {
            try Data().write(to: artifactURL)
        }
        let handle = try FileHandle(forWritingTo: artifactURL)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try writeSections(into: handle, pid: pid, config: config)
        try handle.close()
    }

    private static func writeSections(into handle: FileHandle, pid: pid_t, config: WatchdogConfig) throws {
        func write(_ s: String) throws {
            try handle.write(contentsOf: Data(s.utf8))
        }

        try write("Rapid Desktop test-suite hang capture\n")
        try write("captured at: \(Date())\n")
        try write("wrapped PID: \(pid)\n")
        try write("sample duration: \(config.sampleDurationSeconds)s\n\n")

        // Process state + RAM context first, so a reader sees memory pressure
        // even if the stack sample below is truncated.
        try write("===== ps -p \(pid) -o pid,ppid,state,%cpu,%mem,rss,etime,comm =====\n")
        try write(shellOutput("/bin/ps", ["-p", String(pid), "-o", "pid,ppid,state,%cpu,%mem,rss,etime,comm"]))
        try write("\n===== vm_stat =====\n")
        try write(shellOutput("/usr/bin/vm_stat", []))
        try write("\n===== memory pressure -Q =====\n")
        try write(shellOutput("/usr/bin/memory_pressure", ["-Q"]))

        // The stack capture proper.
        try write("\n===== /usr/bin/sample \(pid) \(config.sampleDurationSeconds) -file ... =====\n")
        try write(streamingSample(pid: pid, seconds: config.sampleDurationSeconds))
        try write("===== end capture \(pid) =====\n")
    }

    /// `/usr/bin/sample` streams to stdout; capture it into the artifact.
    private static func streamingSample(pid: pid_t, seconds: Int) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), String(seconds)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "<sample failed: \(error)>"
        }
    }

    /// Run a command and return its combined stdout (best-effort, non-fatal).
    private static func shellOutput(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "<'\(executable)' failed: \(error)>"
        }
    }
}
