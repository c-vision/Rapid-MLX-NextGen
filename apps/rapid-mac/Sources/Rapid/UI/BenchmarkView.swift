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

    let binary: URL?
    let alias: String
    let hardware: MacHardware
    var onClose: () -> Void

    init(
        binary: URL?, alias: String, hardware: MacHardware,
        onClose: @escaping () -> Void, runner: BenchmarkRunner = BenchmarkRunner()
    ) {
        self.binary = binary
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
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
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
            Text("Run a quick benchmark to see \(displayAlias)'s tokens per second on your \(hardware.brandString).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await runner.run(binary: binary ?? URL(fileURLWithPath: "/"), alias: alias, chip: hardware.brandString) }
            } label: {
                Label("Benchmark this Mac", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(RapidTheme.amber)
            .disabled(binary == nil || alias.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private var runningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).padding(.top, 40)
            Text("Benchmarking \(displayAlias)…")
                .font(.callout.weight(.medium))
            Text("Running a standardized short + long workload. This takes a moment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                    Task { await runner.run(binary: binary ?? URL(fileURLWithPath: "/"), alias: alias, chip: hardware.brandString) }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showSubmitConsent) {
                consentSheet(result)
            }
        case .submitting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Submitting…").font(.callout).foregroundStyle(.secondary)
            }
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
                    Task { await runner.submit(binary: binary ?? URL(fileURLWithPath: "/"), alias: alias) }
                }
                .buttonStyle(.borderedProminent)
                .tint(RapidTheme.brand)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func failedState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32)).foregroundStyle(RapidTheme.amberDeep)
                .padding(.top, 36)
            Text(msg).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                Task { await runner.run(binary: binary ?? URL(fileURLWithPath: "/"), alias: alias, chip: hardware.brandString) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
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

    private var displayAlias: String {
        alias.isEmpty ? "your model" : alias
    }
}
