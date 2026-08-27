import Foundation
import RapidDesktopTestWatchdog

/// CLI entry for the Desktop test-suite hang watchdog, launched by
/// `scripts/desktop-test-timeout.sh`. It watches a wrapped process and, when
/// the run outlives the deadline while still alive, captures the stack +
/// system-state artifact and exits non-zero so the CI wrapper fails fast.
///
/// Usage:
///   RapidDesktopTestWatchdogRun <pid> <deadline-seconds> <artifact-dir> [artifact-name]
///
/// Exit codes:
///   0  the wrapped process exited before the deadline (healthy run / normal fail)
///   1  the deadline elapsed while the wrapped process was still alive (hang)
///   2  usage / argument error

let args = CommandLine.arguments

func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: RapidDesktopTestWatchdogRun <pid> <deadline-seconds> <artifact-dir> [artifact-name]\n".utf8))
    exit(2)
}

guard args.count >= 4, let pid = pid_t(args[1]), let deadlineSeconds = Int(args[2]) else {
    usage()
}

let artifactDir = URL(fileURLWithPath: args[3])
let artifactName = args.count >= 5 ? args[4] : "desktop-hang"

let config = WatchdogConfig(
    deadline: .seconds(deadlineSeconds),
    sampleDurationSeconds: 1,
    artifactDir: artifactDir,
    artifactName: artifactName
)

let watchdog = HangWatchdog(
    config: config,
    seams: .makeLive(pid: pid, config: config)
)

let result = watchdog.run(watchedPID: pid)

switch result {
case .completed:
    exit(0)
case .hung(let artifactURL, let reason):
    let message = "::error::Rapid desktop-test watchdog: \(reason)\n"
        + "sample artifact: \(artifactURL.path)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
