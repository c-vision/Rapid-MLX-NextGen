import Foundation

/// Runs the bundled `rapid-mlx bench` for the in-app "Speed on this Mac"
/// card, and drives the community-leaderboard submission.
///
/// Two paths, both delegating to the proven CLI so the app never
/// reimplements the benchmark or the submission wire format:
///   * ``run`` → `rapid-mlx bench <alias>` (freeform), parses the
///     `Throughput: N tok/s` summary line for display.
///   * ``submit`` → `rapid-mlx bench <alias> --submit` (the
///     standardized B=1 community runner that POSTs to
///     rapidmlx.com/api/benchmarks). The CLI asks for a y/N consent on
///     stdin; the app shows its OWN consent first, then pipes "y" so the
///     user only answers once.
///
/// Both paths are multi-minute for a large model — a cold model load
/// plus (for submit) a full standardized short+long workload. The CLI
/// emits little incremental output, so a plain spinner reads as "hung".
/// We stream the child's stdout to advance a coarse stage label, run a
/// one-second ticker for a live elapsed clock, and show a size-derived
/// ETA so the user knows roughly how long to wait. The elapsed clock is
/// the source of truth; the ETA is an estimate that gracefully degrades
/// to "almost there…" once a slow Mac blows past it.
@MainActor
@Observable
final class BenchmarkRunner {
    enum Phase: Equatable {
        case idle
        case running
        case done(BenchmarkResult)
        case failed(String)
    }

    enum SubmitPhase: Equatable {
        case idle
        case submitting
        case submitted
        case failed(String)
    }

    /// Live progress for the running/submitting states: a coarse stage,
    /// an elapsed clock, and a rough ETA. Drives the progress bar +
    /// caption so a multi-minute bench never looks frozen.
    struct Progress: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case benchmark, submit }

        /// Coarse, monotonically-advancing stage inferred from the
        /// child's stdout. We only ever move forward so a late stray
        /// line can't rewind the label.
        enum Stage: Int, Equatable, Sendable, Comparable {
            case starting = 0
            case loading = 1
            case measuring = 2
            case uploading = 3

            static func < (lhs: Stage, rhs: Stage) -> Bool {
                lhs.rawValue < rhs.rawValue
            }

            func label(for kind: Kind) -> String {
                switch self {
                case .starting: return "Starting…"
                case .loading: return "Loading the model…"
                case .measuring: return "Measuring throughput…"
                case .uploading: return "Publishing to the leaderboard…"
                }
            }
        }

        var kind: Kind
        var stage: Stage = .starting
        var elapsedSeconds: Int = 0
        /// Rough total-duration estimate in seconds; ``nil`` when the
        /// alias carries no parseable size (custom model) → the UI falls
        /// back to an indeterminate bar + bare elapsed clock.
        var etaSeconds: Int?

        /// Advance the stage from one streamed stdout line. Best-effort:
        /// the freeform bench prints "Loading model …" then the Results
        /// block; the standardized submit runner adds an upload phase.
        mutating func observe(_ line: String) {
            let l = line.lowercased()
            let next: Stage?
            if l.contains("uploading") || l.contains("submitting")
                || l.contains("leaderboard") || l.contains("on the board")
                || l.contains("posting") {
                next = .uploading
            } else if l.contains("running benchmark") || l.contains("throughput")
                || l.contains("tokens/second") || l.contains("results")
                || l.contains("long prompt") || l.contains("round")
                || l.contains("warm") {
                // "Running benchmark with N prompts …" is the freeform CLI's
                // marker that the measured generation has begun — it prints
                // right before the (silent) decode, so it's what actually
                // flips the card off "Loading…" during measurement. The
                // later "Results:/Throughput" lines only arrive once decode
                // is already done.
                next = .measuring
            } else if l.contains("loading model") || l.contains("loading the model") {
                next = .loading
            } else {
                next = nil
            }
            if let next, next > stage { stage = next }
        }

        var stageLabel: String { stage.label(for: kind) }

        /// `m:ss` elapsed clock.
        var elapsedClock: String {
            String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        }

        /// Determinate-bar fraction, capped below 1.0 so the bar never
        /// claims "done" before the process actually exits. ``nil`` when
        /// we have no ETA → the UI shows an indeterminate bar.
        var fraction: Double? {
            guard let eta = etaSeconds, eta > 0 else { return nil }
            return min(0.95, Double(elapsedSeconds) / Double(eta))
        }

        /// One-line caption under the bar. Answers "how many minutes?"
        /// up front, then reassures rather than lying once we pass the
        /// estimate.
        var caption: String {
            guard let eta = etaSeconds else { return "Elapsed \(elapsedClock)" }
            if elapsedSeconds >= eta - 5 {
                return "Elapsed \(elapsedClock) · almost there…"
            }
            let remaining = eta - elapsedSeconds
            let mins = max(1, Int((Double(remaining) / 60.0).rounded(.up)))
            return "Elapsed \(elapsedClock) · about \(mins) min left"
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var submitPhase: SubmitPhase = .idle
    /// Non-nil only while a bench or submit is in flight.
    private(set) var progress: Progress?

    private var ticker: Task<Void, Never>?
    /// The in-flight run/submit. Owned here (not by the view's button) so
    /// closing the sheet or starting another run can cancel it — which
    /// terminates the underlying `rapid-mlx bench` child so a closed card
    /// can't leave a GPU-bound benchmark running or overlap two runs.
    private var inFlight: Task<Void, Never>?

    /// Public leaderboard the submission lands on.
    static let boardURL = URL(string: "https://rapidmlx.com/leaderboard")!

    /// DEV-ONLY: force a phase so the snapshot harness can render the
    /// result / submitted states without a live sidecar.
    func devSeed(phase: Phase, submit: SubmitPhase = .idle, progress: Progress? = nil) {
        self.phase = phase
        self.submitPhase = submit
        self.progress = progress
    }

    // MARK: - Lifecycle / cancellation

    /// Start a benchmark, owning the task so the view can cancel it.
    /// Supersedes any in-flight run (which terminates its child process).
    /// The generation is allocated *synchronously here* (not inside the
    /// task body): a task cancelled before it starts still runs its body,
    /// so binding "who is current" at launch time — not execution time —
    /// is what lets the stale task's top guard reject it before it mutates
    /// any state (codex round-3 MAJOR).
    func launchRun(binary: URL, alias: String, chip: String) {
        inFlight?.cancel()
        // Clear a superseded submit's transient phase so it can't linger
        // as a stale "Submitting…" behind the new run (UI-gated today, but
        // keeps the "one transient phase at a time" invariant honest).
        if submitPhase == .submitting { submitPhase = .idle }
        runGeneration &+= 1
        let gen = runGeneration
        inFlight = Task { [weak self] in
            await self?.run(binary: binary, alias: alias, chip: chip, generation: gen)
        }
    }

    /// Start a community-leaderboard submit, owned the same way.
    func launchSubmit(binary: URL, alias: String) {
        inFlight?.cancel()
        if phase == .running { phase = .idle }
        runGeneration &+= 1
        let gen = runGeneration
        inFlight = Task { [weak self] in
            await self?.submit(binary: binary, alias: alias, generation: gen)
        }
    }

    /// Cancel the in-flight run/submit — terminates the `rapid-mlx bench`
    /// child. Call from the view's `.onDisappear` so a closed card never
    /// leaves a benchmark burning the GPU in the background. Bumping the
    /// generation also neutralizes any task that hasn't run its top guard
    /// yet.
    func cancelActive() {
        inFlight?.cancel()
        inFlight = nil
        // Bumping the generation neutralizes a not-yet-started task, but
        // that also makes the cancelled run's deferred endProgress(gen)
        // no-op — so tear the progress/ticker down here directly rather
        // than leave a frozen bar behind if this runner is reused. Reset
        // only the transient in-flight phases; a completed .done result
        // (with a pending submit) is preserved.
        runGeneration &+= 1
        ticker?.cancel()
        ticker = nil
        progress = nil
        if phase == .running { phase = .idle }
        if submitPhase == .submitting { submitPhase = .idle }
    }

    // MARK: - Benchmark (display)

    func run(binary: URL, alias: String, chip: String, generation gen: UInt64) async {
        // Superseded/cancelled before we even started, or another run has
        // already advanced past us: do nothing, touch no state.
        guard !Task.isCancelled, runGeneration == gen else { return }
        guard !alias.isEmpty else {
            phase = .failed("Choose a model first.")
            return
        }
        // Pre-load memory guard (#324). `rapid-mlx bench` spawns its own
        // process that loads the full model — a *second* resident copy
        // if the app's sidecar already has this alias loaded. Projecting
        // the footprint onto live `usedBytes` (which already includes the
        // first copy) catches that 2× case, so we refuse to spawn a bench
        // that would push unified memory past the kernel-panic line.
        if let snapshot = MemoryProbe.snapshot(),
           ModelSizing.memorySafety(
               footprint: ModelSizing.estimate(alias: alias),
               usedBytes: snapshot.usedBytes,
               totalBytes: snapshot.totalBytes
           ) == .unsafe {
            phase = .failed(
                "Not enough free memory to benchmark \(alias) right now — it loads a second copy of the model on top of what's already running. Close some apps or restart the model, then try again.")
            return
        }
        phase = .running
        beginProgress(gen, kind: .benchmark, alias: alias)
        defer { endProgress(gen) }

        let output = await runStreaming(
            binary: binary, args: ["bench", alias], stdinLine: nil, generation: gen)
        // Cancelled (sheet closed) or superseded (another run bumped the
        // generation): the child was terminated and the output is a
        // spurious failure — leave the UI state untouched rather than
        // flashing an error on a dead card or clobbering the newer run.
        guard !Task.isCancelled, runGeneration == gen else { return }
        switch output {
        case .failure(let msg):
            phase = .failed(msg)
        case .success(let text):
            guard let result = Self.parse(text, alias: alias, chip: chip) else {
                phase = .failed("Couldn't read the benchmark result.")
                return
            }
            // A zero/garbage throughput means the run produced no tokens
            // (e.g. the model errored mid-generation but the summary line
            // still printed "0.00 tok/s" and the process exited cleanly).
            // Never surface a confident "0 tokens / second" — and never
            // let a zero reach the community leaderboard.
            guard result.throughputTPS > 0 else {
                phase = .failed(
                    "The benchmark didn't produce a usable number — the model generated no tokens. Try again, or restart the model.")
                return
            }
            phase = .done(result)
        }
    }

    // MARK: - Submit (community leaderboard)

    func submit(binary: URL, alias: String, generation gen: UInt64) async {
        guard !Task.isCancelled, runGeneration == gen else { return }
        guard !alias.isEmpty else {
            submitPhase = .failed("Choose a model first.")
            return
        }
        // Same pre-load memory guard as ``run`` (#324). Submitting re-runs
        // the FULL standardized workload — a cold model reload on top of
        // whatever the app's sidecar already has resident — so it is the
        // heavier of the two 2x-load paths, not a lighter one. Leaving it
        // unguarded would let Publish walk straight into the near-crash
        // that ``run`` now refuses.
        if let snapshot = MemoryProbe.snapshot(),
           ModelSizing.memorySafety(
               footprint: ModelSizing.estimate(alias: alias),
               usedBytes: snapshot.usedBytes,
               totalBytes: snapshot.totalBytes
           ) == .unsafe {
            submitPhase = .failed(
                "Not enough free memory to run the submission benchmark for \(alias) right now — it reloads the model on top of what's already running. Close some apps or restart the model, then try again.")
            return
        }
        submitPhase = .submitting
        beginProgress(gen, kind: .submit, alias: alias)
        defer { endProgress(gen) }

        // The CLI prints the exact payload and asks "submit? [y/N]" on
        // stdin. The app already showed its own consent, so answer "y".
        // (The runner treats a single "y" — or even EOF — as consent.)
        let output = await runStreaming(
            binary: binary, args: ["bench", alias, "--submit"], stdinLine: "y\n", generation: gen)
        guard !Task.isCancelled, runGeneration == gen else { return }
        switch output {
        case .failure(let msg):
            submitPhase = .failed(msg)
        case .success(let text):
            // The runner prints "Your numbers are on the board at …" on
            // success. Fall back to a generic success if the wording
            // shifts but the process exited cleanly.
            if text.localizedCaseInsensitiveContains("on the board")
                || text.localizedCaseInsensitiveContains("leaderboard")
                || text.localizedCaseInsensitiveContains("submitted") {
                submitPhase = .submitted
            } else if text.localizedCaseInsensitiveContains("error")
                || text.localizedCaseInsensitiveContains("failed") {
                submitPhase = .failed(Self.firstErrorLine(text) ?? "Submission failed.")
            } else {
                submitPhase = .submitted
            }
        }
    }

    // MARK: - Progress lifecycle

    /// Monotonic id for the current run. `@MainActor` jobs are reentrant
    /// and not FIFO, so when a new run supersedes an old one the old task
    /// can resume *after* the new one has already installed its progress.
    /// Every progress mutation and teardown is gated on this token so a
    /// superseded run can only ever touch its own state — never the
    /// replacement's ticker/progress (codex round-2 MAJOR).
    private var runGeneration: UInt64 = 0

    /// Begin a run for the (already-allocated) generation `gen`: seed
    /// progress and start the one-second elapsed ticker. The generation is
    /// minted synchronously in ``launchRun``/``launchSubmit`` so it binds
    /// "who is current" at launch, not here.
    private func beginProgress(_ gen: UInt64, kind: Progress.Kind, alias: String) {
        progress = Progress(kind: kind, etaSeconds: Self.etaSeconds(alias: alias, kind: kind))
        ticker?.cancel()
        // A `Task` created in a @MainActor method inherits the main
        // actor, so the mutation below is main-actor-isolated. The
        // generation guard stops a superseded run's ticker.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.runGeneration == gen else { return }
                self.progress?.elapsedSeconds += 1
            }
        }
    }

    /// Tear down progress — but only if this run is still the current
    /// one. A superseded run's `defer` must not clobber its replacement's
    /// ticker/progress.
    private func endProgress(_ gen: UInt64) {
        guard runGeneration == gen else { return }
        ticker?.cancel()
        ticker = nil
        progress = nil
    }

    /// Coarse total-duration estimate. Load time is dominated by the
    /// weight bytes (disk read + Metal upload) and generation is a fixed
    /// token budget, so both scale roughly with parameter count. These
    /// constants are a UX ballpark calibrated against the bundled models
    /// on Apple Silicon (~4B ≈ 1 min, ~12B ≈ 2 min, ~30B ≈ 4–5 min); the
    /// live elapsed clock, not this number, is the source of truth. The
    /// submit path re-runs the full standardized short+long workload, so
    /// it takes ~1.6× the freeform pass. Returns ``nil`` for a custom
    /// alias with no parseable size.
    nonisolated static func etaSeconds(alias: String, kind: Progress.Kind) -> Int? {
        let footprint = ModelSizing.estimate(alias: alias)
        guard let params = footprint.paramsBillions else { return nil }
        let base = 20.0 + params * 8.0
        let mult = kind == .submit ? 1.6 : 1.0
        return Int((base * mult).rounded())
    }

    // MARK: - Parsing

    /// Pulls the throughput + tokens/second out of the freeform bench
    /// summary. Format (rapid-mlx bench):
    ///     Tokens/second: 781.55
    ///     Throughput: 836.26 tok/s
    static func parse(_ text: String, alias: String, chip: String) -> BenchmarkResult? {
        let throughput = firstDouble(in: text, pattern: #"Throughput:\s*([\d.]+)\s*tok"#)
        let tokensPerSec = firstDouble(in: text, pattern: #"Tokens/second:\s*([\d.]+)"#)
        // Prefer throughput (end-to-end); fall back to tokens/second.
        guard let primary = throughput ?? tokensPerSec else { return nil }
        return BenchmarkResult(
            alias: alias,
            chip: chip,
            throughputTPS: primary,
            tokensPerSecond: tokensPerSec ?? primary
        )
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private static func firstErrorLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .first(where: { $0.localizedCaseInsensitiveContains("error") })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Subprocess

    enum RunOutput: Sendable {
        case success(String)
        case failure(String)
    }

    /// Thread-safe holder for the running child so a cancellation on the
    /// consuming task (sheet closed / superseded run) can `terminate()` it
    /// from a different thread than the worker that spawned it.
    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var terminated = false

        /// Adopt the spawned process. If a cancel already arrived before
        /// the process was recorded, terminate it immediately.
        func adopt(_ p: Process) {
            lock.lock()
            let killNow = terminated
            process = p
            lock.unlock()
            if killNow, p.isRunning { p.terminate() }
        }

        func terminate() {
            lock.lock()
            terminated = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    /// Runs `binary args…`, optionally writing one line to stdin, and
    /// returns combined stdout+stderr text — streaming stdout lines
    /// through ``Progress/observe(_:)`` so the stage label advances
    /// live. Reads run off the main actor; each observed line hops back
    /// to advance ``progress``. On task cancellation the child is
    /// terminated (closing its stdout ends the stream promptly).
    private func runStreaming(binary: URL, args: [String], stdinLine: String?, generation gen: UInt64) async -> RunOutput {
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            for await event in Self.stream(handle: handle, binary: binary, args: args, stdinLine: stdinLine) {
                switch event {
                case .line(let line):
                    // Only advance the stage if this is still the current
                    // run — a superseded run's stale lines must not mutate
                    // the replacement's progress.
                    if runGeneration == gen { progress?.observe(line) }
                case .finished(let output):
                    return output
                }
            }
            // Stream ended without a terminal event (should not happen).
            return .failure("The benchmark stopped unexpectedly.")
        } onCancel: {
            handle.terminate()
        }
    }

    private enum StreamEvent: Sendable {
        case line(String)
        case finished(RunOutput)
    }

    /// Spawn `binary args…` and surface each stdout line as it arrives,
    /// then a single terminal ``.finished``. stderr is drained
    /// concurrently so its pipe buffer can't stall the child. The spawned
    /// process is handed to ``handle`` so a cancel can terminate it.
    private nonisolated static func stream(
        handle: ProcessHandle, binary: URL, args: [String], stdinLine: String?
    ) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                let task = Process()
                task.executableURL = binary
                task.arguments = args
                let out = Pipe()
                let err = Pipe()
                task.standardOutput = out
                task.standardError = err
                let inPipe = Pipe()
                if stdinLine != nil { task.standardInput = inPipe }

                do {
                    try task.run()
                } catch {
                    continuation.yield(.finished(.failure(
                        "Couldn't start the benchmark: \(error.localizedDescription)")))
                    continuation.finish()
                    return
                }
                // Hand the live process to the shared handle so a cancel
                // (onCancel / onTermination) can terminate it. If a cancel
                // already landed, adopt() kills it right away.
                handle.adopt(task)
                if let line = stdinLine {
                    // `FileHandle.write(_:)` raises an ObjC exception on EPIPE,
                    // which Swift cannot catch — it terminates the app. That is
                    // reachable here: `adopt` above kills the child immediately
                    // if a cancel already landed (Publish, then close the card),
                    // so stdin can be gone before this write. The throwing
                    // `write(contentsOf:)` surfaces the same condition as a
                    // Swift error we can ignore — a child that is no longer
                    // there does not need its "y".
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }

                // Drain stderr concurrently — the child writes framework
                // warnings there and a full pipe would block generation.
                let errHandle = err.fileHandleForReading
                let errTask = Task.detached { errHandle.readDataToEndOfFile() }

                var stdoutAccum = ""
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        stdoutAccum += line + "\n"
                        continuation.yield(.line(line))
                    }
                } catch {
                    // Read interrupted (e.g. process killed); fall through
                    // to report the exit status.
                }
                // If we were cancelled, make sure the child is dead so the
                // waitUntilExit below returns instead of blocking forever.
                if Task.isCancelled { handle.terminate() }
                task.waitUntilExit()
                let errText = String(data: await errTask.value, encoding: .utf8) ?? ""
                let combined = stdoutAccum + "\n" + errText
                if task.terminationStatus == 0 {
                    continuation.yield(.finished(.success(combined)))
                } else {
                    let tail = combined
                        .split(separator: "\n")
                        .suffix(4)
                        .joined(separator: " ")
                    continuation.yield(.finished(.failure(
                        tail.isEmpty
                            ? "Benchmark exited with code \(task.terminationStatus)."
                            : tail)))
                }
                continuation.finish()
            }
            // Consumer stopped iterating (normal finish OR cancel): kill the
            // child and stop the worker so it can't outlive the stream.
            continuation.onTermination = { _ in
                handle.terminate()
                worker.cancel()
            }
        }
    }
}

struct BenchmarkResult: Equatable {
    let alias: String
    let chip: String
    /// End-to-end throughput in tokens/second (the headline number).
    let throughputTPS: Double
    /// Decode tokens/second.
    let tokensPerSecond: Double
}
