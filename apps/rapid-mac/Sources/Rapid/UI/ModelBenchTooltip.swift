import SwiftUI

/// Hover popover content for one row in the picker's "Recommended for
/// your N GB Mac" section. Renders five horizontal bars, top → bottom:
///
///   1. General & Reasoning (`通识和推理`) — mean of MMLU-Pro + GPQA Diamond.
///   2. Code — LiveCodeBench v6 pass@1.
///   3. Tool — BFCL composite.
///   4. Instruction Following — IFEval prompt-strict accuracy.
///   5. Speed — community-bench long decode tok/s on Apple M3 Ultra.
///
/// The order is the user-signed-off spec — Speed sits LAST because
/// although it's a key purchase signal it shares the bar shape with
/// the four LLM benches, and putting it at the top would visually
/// imply "speed is what we optimise for". Quality-first, speed-last
/// matches the rest of the picker copy.
///
/// Cells without a published number render a dashed track + literal
/// em-dash value. We never fabricate a score to fill a gap; the
/// dashed bar is the honest signal that "the model author doesn't
/// publish this dimension."
///
/// Color rules per `/tmp/recs-hover-ux.md`:
///   * great (`≥ great` threshold) → ``Color.accentColor``.
///   * good (`≥ good`, < great)    → ``Color.yellow.opacity(0.85)``.
///   * below good                   → ``Color.secondary``.
///   * n/a (`nil`)                  → invisible bar, dashed track.
struct ModelBenchTooltip: View {
    /// rapid-mlx alias driving the lookup. Empty string disables
    /// the lookup and renders five dashed rows so a transient
    /// "no row selected" state doesn't crash the hover.
    let alias: String
    /// Role tagline shown beneath the alias name. Inherited from
    /// ``RAMBucketedDefault.Role.blurb`` at the call site so the
    /// tooltip echoes the picker row instead of duplicating the
    /// role label.
    let roleTagline: String

    /// Resolved score record. ``nil`` → five dashed bars. Tooltip
    /// stays useful even on uncatalogued aliases by surfacing the
    /// name + tagline + footer hint.
    private var scores: BenchScores? { BenchScoresCatalog.lookup(alias: alias) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: alias on the left, role tagline as caption
            // beneath. No size badge — sizing details live in the
            // existing (i) popover, this surface focuses on quality
            // signals.
            VStack(alignment: .leading, spacing: 2) {
                Text(alias)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !roleTagline.isEmpty {
                    Text(roleTagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Five bars, top → bottom in the locked order.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BenchScores.Axis.allCases, id: \.self) { axis in
                    BenchBarRow(axis: axis, value: scores?.value(for: axis))
                }
            }

            // Surface the General-&-Reasoning basis (mmlu / gpqa
            // split) and the speed-chip caveat once at the bottom.
            if let scores = scores {
                let footer = Self.footerLines(for: scores)
                if !footer.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(footer, id: \.self) { line in
                            Text(line)
                                .scaledSystemFont(11, relativeTo: .caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                // No score record at all — be explicit so the
                // tooltip never looks broken on uncatalogued
                // aliases.
                Divider()
                Text("Benchmark scores not yet recorded for this model.")
                    .scaledSystemFont(11, relativeTo: .caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(alias: alias, tagline: roleTagline, scores: scores))
    }

    /// Pure helper so tests can pin the footer copy without standing
    /// up an NSHostingView. Returns the lines in display order; an
    /// empty array means "no footer / no divider".
    static func footerLines(for scores: BenchScores) -> [String] {
        var lines: [String] = []
        if let mmlu = scores.mmluPro, let gpqa = scores.gpqaDiamond {
            lines.append(String(
                format: "General & Reasoning = mean(MMLU-Pro %.1f, GPQA %.1f)",
                mmlu, gpqa
            ))
        } else if scores.generalReasoningSource == "mmlu_pro only", let mmlu = scores.mmluPro {
            lines.append(String(format: "General & Reasoning = MMLU-Pro %.1f only", mmlu))
        } else if scores.generalReasoningSource == "gpqa_diamond only", let gpqa = scores.gpqaDiamond {
            lines.append(String(format: "General & Reasoning = GPQA %.1f only", gpqa))
        }
        if scores.speedTps != nil {
            lines.append("Speed measured on Apple M3 Ultra.")
        }
        return lines
    }

    /// VoiceOver / accessibility composed label. Reads the alias,
    /// role tagline, and each axis's status so a screen-reader user
    /// gets the same information sighted users glean from the bars.
    static func accessibilityLabel(
        alias: String,
        tagline: String,
        scores: BenchScores?
    ) -> String {
        var parts: [String] = []
        if !alias.isEmpty { parts.append(alias) }
        if !tagline.isEmpty { parts.append(tagline) }
        guard let scores = scores else {
            parts.append("Benchmark scores not yet recorded.")
            return parts.joined(separator: ". ")
        }
        for axis in BenchScores.Axis.allCases {
            if let value = scores.value(for: axis) {
                let t = axis.thresholds
                let rating: String
                if value >= t.great { rating = "great" }
                else if value >= t.good { rating = "good" }
                else { rating = "below average" }
                let formatted = axis == .speed
                    ? "\(Int(value.rounded())) tokens per second"
                    : String(format: "%.1f", value)
                parts.append("\(axis.label) \(formatted), \(rating)")
            } else {
                parts.append("\(axis.label) not measured")
            }
        }
        return parts.joined(separator: ". ")
    }
}

/// One bar row inside the tooltip. Renders the label, bar capsule,
/// and right-aligned value. Pulled out as its own view so the
/// tooltip body stays scannable.
struct BenchBarRow: View {
    let axis: BenchScores.Axis
    let value: Double?

    /// Layout constants — pinned tight so the 280pt tooltip width
    /// breaks down predictably: 96pt label + 8pt gap + bar +
    /// 8pt gap + 48pt value = 280 total (with the surrounding
    /// 12pt padding on either side accounted for by the parent
    /// `.padding`).
    private let labelWidth: CGFloat = 96
    private let valueWidth: CGFloat = 48
    private let barHeight: CGFloat = 6

    var body: some View {
        HStack(spacing: 8) {
            Text(axis.label)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)

            barBody
                .frame(height: barHeight)

            Text(Self.formattedValue(axis: axis, value: value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var barBody: some View {
        if let value = value {
            let t = axis.thresholds
            let pct = min(1.0, max(0.0, value / t.normalizer))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    Capsule(style: .continuous)
                        .fill(Self.color(for: value, thresholds: t))
                        .frame(width: max(2, geo.size.width * pct))
                }
            }
        } else {
            // dashed n/a track — empty foreground so the row reads as
            // "we don't have a number" without a coloured fill.
            Capsule(style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                .foregroundStyle(Color.secondary.opacity(0.4))
        }
    }

    /// Pure formatter so tests can pin the right-aligned column copy
    /// without standing up a SwiftUI host. Speed reads as "262 t/s";
    /// the four LLM bars read as "82.5" (one decimal). ``nil`` →
    /// em-dash.
    static func formattedValue(axis: BenchScores.Axis, value: Double?) -> String {
        guard let value = value else { return "—" }
        switch axis {
        case .speed:
            return "\(Int(value.rounded()))\(axis.thresholds.suffix)"
        default:
            return String(format: "%.1f", value)
        }
    }

    /// Pure colour classifier so tests can pin "great vs good vs
    /// below" without rendering. Returns a SwiftUI ``Color`` so the
    /// view layer stays a one-liner.
    static func color(
        for value: Double,
        thresholds: (good: Double, great: Double, normalizer: Double, suffix: String)
    ) -> Color {
        if value >= thresholds.great { return Color.accentColor }
        if value >= thresholds.good  { return Color.yellow.opacity(0.85) }
        return Color.secondary
    }

    /// Discrete classification — `great` / `good` / `below`. Helper
    /// so tests can express the colour rule without a SwiftUI host.
    enum Rating: String, Equatable {
        case great
        case good
        case below
    }

    static func rating(
        for value: Double,
        thresholds: (good: Double, great: Double, normalizer: Double, suffix: String)
    ) -> Rating {
        if value >= thresholds.great { return .great }
        if value >= thresholds.good  { return .good }
        return .below
    }
}
