import SwiftUI

/// Runs IOKit and Mach host probes away from SwiftUI's main actor.
enum SystemProbeSampler {
    nonisolated static func sample<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: .utility) {
            operation()
        }.value
    }
}

/// CPU-load pill. Same visual contract as ``MemoryPill`` — coloured
/// dot + monospaced label — so the three system-metric chips in the
/// footer read as a coherent row instead of a grab-bag of styles.
///
/// CPU usage is a derivative, so we hold the previous tick snapshot
/// in ``@State`` and compute the delta after each background sample.
///
/// #546: like ``MemoryPill``, every pill in this file keeps its
/// numeric readout on the fixed `.font(.system(size:))` rail rather
/// than `.scaledSystemFont`. These are ambient live-telemetry chips in
/// the fixed-height bottom status bar (CPU / GPU / tok-s), the same
/// platform convention Activity Monitor's menu-bar readout follows —
/// growing them with Dynamic Type would clip the bar without aiding a
/// reading task. The Dynamic-Type source guard allowlists this file.
struct CPUPill: View {
    var refreshInterval: TimeInterval = 3
    @State private var previousSnapshot: CPUProbe.Snapshot?
    @State private var displayedPercent: Double = 0

    var body: some View {
        content
            .task(id: refreshInterval) {
                await refreshLoop()
            }
    }

    @ViewBuilder
    private var content: some View {
        let pressure = CPUProbe.Pressure.classify(percent: displayedPercent)
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: pressure))
                .frame(width: 6, height: 6)
            Text("CPU \(CPUProbe.formatLabel(percent: displayedPercent))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(Self.tooltip(percent: displayedPercent, pressure: pressure))
        // Collapse the HStack into a single VoiceOver element so the
        // override label below replaces the children's text — without
        // this, VoiceOver reads "CPU 45 percent" (override) followed by
        // "CPU 45%" (the child Text), double-announcing the number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(Int(displayedPercent.rounded())) percent")
    }

    @MainActor
    private func refreshLoop() async {
        while !Task.isCancelled {
            let current = await SystemProbeSampler.sample {
                CPUProbe.snapshot()
            }
            guard !Task.isCancelled else { return }
            if let current {
                displayedPercent = CPUProbe.percentBusy(
                    previous: previousSnapshot,
                    current: current
                )
                previousSnapshot = current
            }
            do {
                try await Task.sleep(for: .seconds(max(0.1, refreshInterval)))
            } catch {
                return
            }
        }
    }

    static func color(for pressure: CPUProbe.Pressure) -> Color {
        switch pressure {
        case .normal:   return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private func color(for pressure: CPUProbe.Pressure) -> Color {
        Self.color(for: pressure)
    }

    static func tooltip(percent: Double, pressure: CPUProbe.Pressure) -> String {
        let header: String
        switch pressure {
        case .normal:   header = "CPU: light load"
        case .warning:  header = "CPU: heavy load"
        case .critical: header = "CPU: pegged — other apps may stutter"
        }
        return "\(header)\n\(Int(percent.rounded()))% busy across all cores."
    }
}

/// Tokens-per-second pill. Shares the visual contract with the
/// CPU / GPU / Memory chips so the footer reads as one coherent row
/// of inference-relevant numbers.
///
/// Reads the most recent assistant message in the active session and
/// surfaces its end-of-stream ``MessageStats``. Prefers the server-
/// reported ``reportedTokensPerSecond`` (populated when rapid-mlx
/// emits the ``stream_options.include_usage`` final chunk); falls
/// back to the char-count-derived ``estimatedTokensPerSecond`` for
/// older transcripts / non-conforming servers, prefixed with ``~``
/// to flag the estimate.
///
/// Idle state — no assistant turn streamed yet — renders "TPS —"
/// (em-dash) with a tertiary foreground so the pill reads as
/// "no data yet" rather than a failure state. Hiding the pill
/// entirely would leave a flickering gap in the always-on
/// CPU/GPU/RAM/TPS row when the first turn lands, so we keep it
/// present and dim it instead.
///
/// We deliberately don't try to compute a live mid-stream TPS here:
/// during streaming the placeholder row has no ``stats`` yet, and
/// computing one from a streaming partial overstates the rate (the
/// first chunk arrives milliseconds after dispatch, dividing by a
/// tiny elapsed). The user wants "how fast did my last answer
/// arrive" — a clean post-stream measurement.
struct TokensPerSecondPill: View {
    /// The current conversation's messages, passed in by ``ContentView``
    /// so the pill can read the most recent assistant turn's stats.
    let messages: [ChatMessage]

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            // Idle (no resolved value) drops to .tertiary so the chip
            // visibly recedes from the "live data" CPU/GPU/RAM chips
            // next to it — same treatment GPUPill uses for its own
            // "GPU n/a" Intel-Mac fallback. Active rows keep
            // .secondary to match CPU/GPU/RAM weight.
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(resolvedTokensPerSecond == nil ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .help(tooltip)
        // See CPUPill — collapse children to suppress double-read.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Pressure thresholds chosen for the local-LLM context where this
    /// app runs. M-series machines on small-to-medium models comfortably
    /// land above 30 tok/s; below 10 is the "user notices waiting"
    /// floor and usually means a too-big model for the GPU or memory
    /// pressure forcing swap. Thresholds intentionally do not match
    /// the CPU/GPU pressure thresholds — "fast inference" and "fast
    /// CPU" mean different things.
    private enum Pressure {
        case fast
        case moderate
        case slow
        case unknown
    }

    private var lastAssistantStats: MessageStats? {
        for message in messages.reversed()
        where message.role == .assistant {
            if let stats = message.stats { return stats }
        }
        return nil
    }

    private var resolvedTokensPerSecond: (value: Double, isEstimated: Bool)? {
        guard let stats = lastAssistantStats else { return nil }
        // > 0 guard: a mid-stream cancel + late usage chunk can leave
        // ``completionTokens=0`` with non-empty content, which makes
        // ``reportedTokensPerSecond`` return 0.0. Showing red "TPS 0"
        // misleads — fall through to the char-count estimate, which at
        // least reflects what the user actually saw arrive.
        if let reported = stats.reportedTokensPerSecond, reported > 0 {
            return (reported, false)
        }
        if let estimated = stats.estimatedTokensPerSecond {
            return (estimated, true)
        }
        return nil
    }

    private var pressure: Pressure {
        guard let resolved = resolvedTokensPerSecond else { return .unknown }
        switch resolved.value {
        case ..<10:  return .slow
        case ..<30:  return .moderate
        default:     return .fast
        }
    }

    private var label: String {
        // #461: the pill reads "tok/s", not "TPS". "TPS" is an
        // ML-engineer abbreviation a normal user won't decode; "tok/s"
        // is the LM-Studio convention and already what ChatView's
        // per-message caption uses — this just makes the footer pill
        // consistent. Em-dash (U+2014) is the canonical "no data yet"
        // glyph in dashboard UI — reads as neutral / pending rather
        // than "n/a → broken".
        guard let resolved = resolvedTokensPerSecond else { return "— tok/s" }
        let rounded = Int(resolved.value.rounded())
        return "\(resolved.isEstimated ? "~" : "")\(rounded) tok/s"
    }

    private var dotColor: Color {
        switch pressure {
        case .fast:     return .green
        case .moderate: return .yellow
        case .slow:     return .red
        case .unknown:  return Color.secondary.opacity(0.4)
        }
    }

    private var tooltip: String {
        guard let resolved = resolvedTokensPerSecond else {
            return "Inference throughput\n\nNo completed assistant turn in this session yet — send a message to see tok/s."
        }
        let header: String
        switch pressure {
        case .fast:     header = "Inference: fast"
        case .moderate: header = "Inference: moderate"
        case .slow:     header = "Inference: slow — model may be too big for this GPU or memory pressure is forcing swap"
        case .unknown:  header = "Inference throughput"
        }
        let detail: String
        let formatted = String(format: "%.1f tok/s", resolved.value)
        if resolved.isEstimated {
            detail = "~\(formatted) (estimated from char count — server did not emit usage)"
        } else {
            detail = formatted
        }
        return "\(header)\n\nLast assistant turn: \(detail)"
    }

    private var accessibilityLabel: String {
        guard let resolved = resolvedTokensPerSecond else {
            // "not available" reads as a failure to VoiceOver users;
            // "no data yet" matches the visual em-dash and the
            // tooltip's "send a message to see tok/s" phrasing.
            return "Tokens per second: no data yet"
        }
        return "Tokens per second: \(Int(resolved.value.rounded()))"
    }
}

/// GPU-load pill. Apple Silicon only; renders "GPU n/a" on Intel.
/// Single snapshot per refresh — ``GPUProbe`` reads a one-shot
/// instantaneous utilisation number, no delta math required.
struct GPUPill: View {
    var refreshInterval: TimeInterval
    private let sample: @Sendable () -> GPUProbe.Snapshot?
    @State private var snapshot: GPUProbe.Snapshot?

    init(
        refreshInterval: TimeInterval = 3,
        sample: @escaping @Sendable () -> GPUProbe.Snapshot? = {
            GPUProbe.snapshot()
        }
    ) {
        self.refreshInterval = refreshInterval
        self.sample = sample
        _snapshot = State(initialValue: sample())
    }

    var body: some View {
        content
            .task(id: refreshInterval) {
                await refreshLoop()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snap = snapshot {
            let pressure = GPUProbe.Pressure.classify(percent: snap.percent)
            HStack(spacing: 5) {
                Circle()
                    .fill(color(for: pressure))
                    .frame(width: 6, height: 6)
                Text("GPU \(GPUProbe.formatLabel(percent: snap.percent))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(Self.tooltip(percent: snap.percent, pressure: pressure))
            // See CPUPill — collapse children to suppress double-read.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("GPU \(Int(snap.percent.rounded())) percent")
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text("GPU n/a")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .help("GPU probe unavailable — Intel Macs and sandboxed apps don't expose AGXAccelerator utilisation.")
        }
    }

    static func color(for pressure: GPUProbe.Pressure) -> Color {
        switch pressure {
        case .normal:   return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private func color(for pressure: GPUProbe.Pressure) -> Color {
        Self.color(for: pressure)
    }

    @MainActor
    private func refreshLoop() async {
        while !Task.isCancelled {
            let next = await SystemProbeSampler.sample(sample)
            guard !Task.isCancelled else { return }
            snapshot = next
            do {
                try await Task.sleep(for: .seconds(max(0.1, refreshInterval)))
            } catch {
                return
            }
        }
    }

    static func tooltip(percent: Double, pressure: GPUProbe.Pressure) -> String {
        let header: String
        switch pressure {
        case .normal:   header = "GPU: idle / light"
        case .warning:  header = "GPU: heavy load"
        case .critical: header = "GPU: pegged — model is fully saturating the GPU"
        }
        return "\(header)\n\(Int(percent.rounded()))% utilisation."
    }
}
