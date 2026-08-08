import AppKit
import SwiftUI

/// "Speed on this Mac" — measures the current model's throughput and
/// offers to add it to the community leaderboard.
///
/// The differentiation the plan calls for: not just "it's fast" but a
/// real, honest number for *your* Mac, and a board that answers "what
/// makes a Mac fast". Submission is ask-first — this sheet shows exactly
/// what becomes public (model / RAM / chip / tok-s) and nothing else.
struct BenchmarkView: View {
    @State private var runner: BenchmarkRunner
    @State private var showSubmitConsent = false
    /// Collapsed by default — raw child output is diagnostic detail,
    /// not the primary error surface.
    @State private var showFailureDetails = false

    let binary: URL?
    let baseURL: URL
    let bearer: String
    let alias: String
    let hardware: MacHardware
    var onClose: () -> Void

    init(
        binary: URL?, baseURL: URL = ChatStreamClient.defaultBaseURL,
        bearer: String = "", alias: String, hardware: MacHardware,
        onClose: @escaping () -> Void, runner: BenchmarkRunner = BenchmarkRunner()
    ) {
        self.binary = binary
        self.baseURL = baseURL
        self.bearer = bearer
        self.alias = alias
        self.hardware = hardware
        self.onClose = onClose
        _runner = State(initialValue: runner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20) }
        }
        .frame(width: 440, height: 480)
        .background(RapidTheme.canvas)
        // Closing the card cancels any in-flight bench/submit so it can't
        // keep burning the GPU in the background after the sheet is gone.
        .onDisappear { runner.cancelActive() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speed on this Mac")
                    .font(.title3.weight(.semibold))
                Text("Measure how fast \(displayAlias) runs, honestly, right here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            SheetCloseButton(action: onClose)
        }
        .padding(20)
    }

    /// The phase-switched body. Internal so the snapshot harness can
    /// render it in a fixed frame (``ImageRenderer`` collapses
    /// ``ScrollView`` content to zero height).
    @ViewBuilder
    var content: some View {
        switch runner.phase {
        case .idle:
            idleState
        case .running:
            runningState
        case .done(let result):
            resultState(result)
        case .failed(let msg):
            failedState(msg)
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 40))
                .foregroundStyle(RapidTheme.brandAmber)
                .padding(.top, 24)
            Text("Test the \(displayAlias) model already running on your \(hardware.brandString) — no second copy is loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                runner.launchRun(
                    baseURL: baseURL, bearer: bearer,
                    alias: alias, chip: hardware.brandString)
            } label: {
                Label("Benchmark this Mac", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(RapidTheme.amber)
            .disabled(alias.isEmpty)
            .accessibilityIdentifier("Benchmark.RunLoadedModel")
        }
        .frame(maxWidth: .infinity)
    }

    private var runningState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 34))
                .foregroundStyle(RapidTheme.brandAmber)
                .padding(.top, 28)
            Text("Benchmarking \(displayAlias)")
                .font(.callout.weight(.semibold))
            benchProgress(
                runner.progress,
                fallback: "Running a standardized short + long workload.")
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Live progress used by both the loaded-model benchmark and the submit
    /// re-bench: a determinate bar toward the ETA (indeterminate when the
    /// model size is unknown), the current stage, and an elapsed + ETA
    /// caption so a multi-minute run never reads as frozen.
    @ViewBuilder
    private func benchProgress(_ progress: BenchmarkRunner.Progress?, fallback: String) -> some View {
        VStack(spacing: 10) {
            if let p = progress {
                Group {
                    if let fraction = p.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(RapidTheme.amber)
                Text(p.stageLabel)
                    .font(.callout.weight(.medium))
                Text(p.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(RapidTheme.amber)
                Text(fallback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func resultState(_ result: BenchmarkResult) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(String(format: "%.0f", result.throughputTPS))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(RapidTheme.brandAmber)
                Text("tokens / second")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("Benchmark.LoadedModelResult")
            .padding(.top, 12)
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                statRow("Model", result.alias)
                statRow("Chip", result.chip)
                statRow("Memory", String(format: "%.0f GB", hardware.physicalRAMGB))
            }
            .padding(14)
            .background(RapidTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RapidTheme.hairline))

            submitArea(result)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func submitArea(_ result: BenchmarkResult) -> some View {
        switch runner.submitPhase {
        case .idle:
            VStack(spacing: 8) {
                Button {
                    showSubmitConsent = true
                } label: {
                    Label("Add to community leaderboard", systemImage: "chart.bar.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(RapidTheme.brand)
                Button("Run again") {
                    runner.launchRun(
                        baseURL: baseURL, bearer: bearer,
                        alias: alias, chip: hardware.brandString)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showSubmitConsent) {
                consentSheet(result)
            }
        case .submitting:
            benchProgress(runner.progress, fallback: "Submitting…")
                .padding(.top, 4)
        case .submitted:
            VStack(spacing: 8) {
                Label("On the board", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(RapidTheme.green)
                Link("See where your Mac ranks →", destination: BenchmarkRunner.boardURL)
                    .font(.callout)
            }
        case .failed(let msg):
            VStack(spacing: 6) {
                Text(msg).font(.footnote).foregroundStyle(RapidTheme.amberDeep)
                    .multilineTextAlignment(.center)
                Button("Try again") { showSubmitConsent = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func consentSheet(_ result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to the leaderboard?")
                .font(.title3.weight(.semibold))
            Text("This publishes only the numbers below — no prompts, no files, no IP address, no hardware ID.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                statRow("Model", result.alias)
                statRow("Chip", result.chip)
                statRow("Memory", String(format: "%.0f GB", hardware.physicalRAMGB))
                statRow("Throughput", String(format: "%.0f tok/s", result.throughputTPS))
            }
            .padding(12)
            .background(RapidTheme.sidebarSurface, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Not now") { showSubmitConsent = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Publish") {
                    showSubmitConsent = false
                    runner.launchSubmit(binary: binary ?? URL(fileURLWithPath: "/"), alias: alias)
                }
                .buttonStyle(.borderedProminent)
                .tint(RapidTheme.brand)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Failure state.
    ///
    /// Runner details can be a local HTTP error or (for leaderboard publish)
    /// a child-process traceback tail. Rendering either as the primary message
    /// tells the user little, so raw text stays behind a disclosure and a
    /// classified sentence takes the front.
    private func failedState(_ msg: String) -> some View {
        let diagnosis = BenchmarkView.classifyFailure(msg)
        return VStack(spacing: RapidTheme.Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(RapidTheme.brandPrimaryDeep)
                .padding(.top, RapidTheme.Space.xl)
                .accessibilityHidden(true)

            Text(diagnosis.headline)
                .font(RapidFont.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try again") {
                runner.launchRun(
                    baseURL: baseURL,
                    bearer: bearer,
                    alias: alias,
                    chip: hardware.brandString
                )
            }
            .buttonStyle(.rapidSecondary)

            if diagnosis.showsDetails {
                DisclosureGroup(isExpanded: $showFailureDetails) {
                    ScrollView {
                        Text(msg)
                            .font(RapidFont.code)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(RapidTheme.Space.sm)
                    }
                    .frame(maxHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: RapidTheme.Radius.code, style: .continuous)
                            .fill(RapidTheme.surfaceCode)
                    )
                } label: {
                    Text("Show details")
                        .font(RapidFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, RapidTheme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Maps a raw runner failure onto user-facing copy.
    ///
    /// Pure + `static` so the mapping can be unit-tested without
    /// standing up the sheet, and so adding a case is a one-line change
    /// in one place rather than a new branch in the view.
    ///
    /// ``showsDetails`` is false for messages we authored ourselves
    /// (they are already the explanation) and true for raw transport/process
    /// details.
    static func classifyFailure(_ raw: String) -> (headline: String, showsDetails: Bool) {
        let lowered = raw.lowercased()

        if lowered.contains("address already in use")
            || lowered.contains("errno 48")
            || lowered.contains("eaddrinuse") {
            return ("Couldn't start the benchmark because its local port is already in use.", true)
        }
        if lowered.contains("out of memory")
            || lowered.contains("insufficient memory")
            || lowered.contains("metal-cap") {
            return ("Not enough memory to benchmark this model. Try a smaller model.", true)
        }
        if lowered.contains("no such file") || lowered.contains("not found") {
            return ("Couldn't find the model files for this benchmark.", true)
        }
        if lowered.contains("connection") || lowered.contains("timed out") || lowered.contains("timeout") {
            return ("The benchmark couldn't reach the local server. Try again.", true)
        }
        // Messages the runner authors itself are already plain English
        // ("Choose a model first.", "Couldn't read the benchmark result.").
        // Anything short and traceback-free is treated as one of those.
        let looksLikeOurCopy = raw.count < 120
            && !raw.contains("Traceback")
            && !lowered.contains("error:")
            && !raw.contains("  File \"")
        if looksLikeOurCopy {
            return (raw, false)
        }
        return ("The benchmark didn't finish. Try again.", true)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    /// Never renders an internal placeholder as a model name.
    private var displayAlias: String {
        ModelDisplayName.configValue(alias: alias) ?? "your local model"
    }
}
