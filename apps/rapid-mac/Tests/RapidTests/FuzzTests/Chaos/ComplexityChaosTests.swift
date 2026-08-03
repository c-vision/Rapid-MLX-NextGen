import Foundation
import Testing
@testable import Rapid

/// Angle E — Algorithmic-complexity hunting via timing.
///
/// The export helpers are linear-by-design — each session walked
/// once, each message rendered once. But "linear by design" only
/// holds if every nested helper is O(1) per character. Two
/// historical pitfalls show up frequently in Markdown emitters:
///
///   1. String concatenation in a loop. Swift's ``String`` is COW;
///      ``out += chunk`` can be O(n) when the buffer needs to grow
///      to a new capacity, making N concatenations O(n²) overall.
///      The standard mitigation is to ``reserveCapacity`` or to
///      build the result through an explicit ``[Substring]`` and
///      join at the end. Verify the realised cost is sub-quadratic.
///   2. Per-message rescans of the whole conversation. Easy to slip
///      into when computing "turn count" or "context window" inside
///      a per-message loop — turns the render from O(n) into O(n²).
///
/// We measure wall-clock time at increasing N and fit the slope on
/// a log-log scale. A slope of 1.0 = linear; 2.0 = quadratic. Flag
/// anything > 1.5 (allows some constant-factor noise on short runs)
/// as a potential O(n²) regression.
///
/// We use minimum-of-3 runs at each N so transient scheduler hiccups
/// don't push a near-linear path over the 1.5 threshold.
@Suite("Chaos — algorithmic complexity hunting", .serialized)
struct ComplexityChaosTests {

    // MARK: - SessionMarkdownExporter.render
    //
    // Codex round 1 MAJOR: fixture build moved OUT of the timed
    // block. With buildSession + UUIDs + arrays + dates inside
    // ``bestOfThree``, linear setup cost mixed in with the render
    // cost and flattened the slope — a real quadratic could look
    // healthy. Now we pre-build the session once per size point
    // and only the render call is timed.
    //
    // Also widened: we now sweep TWO axes — message count AND
    // per-message body size — and take the worst slope of the two.
    // Pure message-count scaling can hide a hot loop that scales
    // with body bytes (the SessionMarkdownExporter.render body is
    // ``content.count``-bound on the inline-image regex).

    @Test("SessionMarkdownExporter.render: scaling is sub-quadratic (slope < 1.5) up to N=4096 messages")
    func renderMarkdownScalingIsSubQuadratic() {
        let sizes: [Int] = [32, 128, 512, 2048, 4096]
        var samples: [(n: Int, t: Double)] = []
        for n in sizes {
            let session = buildSession(messageCount: n, bodyBytes: 256)
            let t = bestOfThree {
                let rendered = SessionMarkdownExporter.render(session)
                blackHole(rendered.count)
            }
            samples.append((n: n, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): SessionMarkdownExporter.render N-message slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (n: $0.n, us: Int($0.t * 1_000_000)) })
            """)
        }
    }

    @Test("SessionMarkdownExporter.render: scaling is sub-quadratic on body-bytes axis up to 256 KB per message")
    func renderMarkdownBodyBytesIsSubQuadratic() {
        // Fix message count at 32; sweep body bytes.
        let sizes: [Int] = [256, 2048, 16_384, 131_072, 262_144]
        var samples: [(n: Int, t: Double)] = []
        for bytes in sizes {
            let session = buildSession(messageCount: 32, bodyBytes: bytes)
            let t = bestOfThree {
                let rendered = SessionMarkdownExporter.render(session)
                blackHole(rendered.count)
            }
            samples.append((n: bytes, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): SessionMarkdownExporter.render body-byte slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (bytes: $0.n, us: Int($0.t * 1_000_000)) })
            """)
        }
    }

    // MARK: - ChatExporter.json

    @Test("ChatExporter.json: scaling is sub-quadratic up to N=4096 messages")
    func jsonScalingIsSubQuadratic() throws {
        let sizes: [Int] = [32, 128, 512, 2048, 4096]
        var samples: [(n: Int, t: Double)] = []
        for n in sizes {
            let session = buildSession(messageCount: n, bodyBytes: 256)
            let t = bestOfThree {
                let bytes = (try? ChatExporter.json(session)) ?? Data()
                blackHole(bytes.count)
            }
            samples.append((n: n, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): ChatExporter.json slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (n: $0.n, us: Int($0.t * 1_000_000)) })
            """)
        }
    }

    // MARK: - ChatExporter.bulkZip

    @Test("ChatExporter.bulkZip: scaling is sub-quadratic up to N=512 sessions")
    func bulkZipScalingIsSubQuadratic() throws {
        // Smaller cap than the per-message tests — every session is
        // a separate render + 2 ZIP entries, so 2048 sessions would
        // push past the 60-second budget on slower CI.
        let sizes: [Int] = [4, 16, 64, 256, 512]
        var samples: [(n: Int, t: Double)] = []
        for n in sizes {
            // Build the input ONCE outside the timed block — we're
            // measuring bulkZip, not session generation.
            let sessions = (0..<n).map { _ in buildSession(messageCount: 4, bodyBytes: 256) }
            let t = bestOfThree {
                let bytes = (try? ChatExporter.bulkZip(sessions)) ?? Data()
                blackHole(bytes.count)
            }
            samples.append((n: n, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): ChatExporter.bulkZip scaling slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (n: $0.n, ms: Int($0.t * 1000)) })
            """)
        }
    }

    // MARK: - ChatTextSanitizer

    /// ChatTextSanitizer walks every Unicode scalar via
    /// ``compactMap`` — should be O(n). Verify a pathological
    /// input (mixed C0 + bidi + emoji) doesn't degrade.
    @Test("ChatTextSanitizer.sanitizeForPasteboard: scaling is linear up to N=1 MB")
    func sanitizerScalingIsLinear() {
        let sizes: [Int] = [1024, 16 * 1024, 256 * 1024, 1024 * 1024]
        var samples: [(n: Int, t: Double)] = []
        for n in sizes {
            // Mix of allowed (tab, LF), stripped (C0, bidi), and
            // emoji so every code path in the scalar walker hits.
            var s = ""
            s.reserveCapacity(n)
            let pattern = "a\t\u{0001}b\n\u{202E}c\u{2069}d👋e"
            while s.utf8.count < n {
                s += pattern
            }
            let t = bestOfThree {
                let cleaned = ChatTextSanitizer.sanitizeForPasteboard(s)
                blackHole(cleaned.count)
            }
            samples.append((n: n, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): ChatTextSanitizer scaling slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (n: $0.n, ms: Int($0.t * 1000)) })
            """)
        }
    }

    // MARK: - bulkZip stem-collision pathology

    /// Worst case for the per-session collision counter: every
    /// session has the SAME title, so usedStems[baseStem] grows
    /// to N and the counter walks 1..N. Sub-quadratic if the
    /// dictionary lookup is O(1); quadratic if collision-handling
    /// degrades.
    @Test("ChatExporter.bulkZip: every session same title (all collisions) is still sub-quadratic")
    func bulkZipAllCollisionsIsSubQuadratic() {
        let sizes: [Int] = [4, 16, 64, 256, 512]
        var samples: [(n: Int, t: Double)] = []
        for n in sizes {
            // Identical title across all sessions.
            let sessions = (0..<n).map { _ in
                ChatSession(
                    id: UUID(),
                    title: "Same Title Every Session",
                    alias: "qwen3.5-4b",
                    messages: [],
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isPinned: false,
                    systemPrompt: nil
                )
            }
            let t = bestOfThree {
                let bytes = (try? ChatExporter.bulkZip(sessions)) ?? Data()
                blackHole(bytes.count)
            }
            samples.append((n: n, t: t))
        }
        let slope = logLogSlope(points: samples)
        if slope > 1.5 {
            Issue.record("""
            BUG (P3, perf): bulkZip-all-collisions slope=\(String(format: "%.2f", slope)) > 1.5.
              timings=\(samples.map { (n: $0.n, ms: Int($0.t * 1000)) })
            """)
        }
    }

    // MARK: - Helpers

    private func buildSession(messageCount: Int, bodyBytes: Int = 32) -> ChatSession {
        var msgs: [ChatMessage] = []
        msgs.reserveCapacity(messageCount)
        // ``bodyBytes``-controlled padding so the per-message-size
        // axis pushes past the inline-image-detect regex threshold
        // (~4 KB) and the markdown-block growth thresholds.
        let padding = String(repeating: "x", count: max(0, bodyBytes - 16))
        for i in 0..<messageCount {
            msgs.append(
                ChatMessage(
                    id: UUID(),
                    role: (i % 2 == 0) ? .user : .assistant,
                    content: "msg \(i): " + padding,
                    reasoning: (i % 2 == 1) ? "trace \(i)" : "",
                    status: .complete,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
                )
            )
        }
        return ChatSession(
            id: UUID(),
            title: "complexity-test",
            alias: "qwen3.5-4b",
            messages: msgs,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            isPinned: false,
            systemPrompt: nil
        )
    }

    /// Run ``op`` three times and return the minimum wall-clock
    /// duration in seconds. Minimum is the most stable estimator
    /// for "how long does this code take when the OS isn't
    /// stealing cycles" — average would be skewed upward by GC /
    /// scheduler hiccups.
    private func bestOfThree(_ op: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now()
            op()
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) * 1e-9
            if elapsed < best { best = elapsed }
        }
        return best
    }

    /// Fit a line through log(n) → log(t) via linear regression
    /// and return the slope (∂log(t)/∂log(n)). A linear algorithm
    /// has slope 1; quadratic has 2; log-linear (sort) has 1+small.
    private func logLogSlope(points: [(n: Int, t: Double)]) -> Double {
        let logs = points.map { (x: log(Double($0.n)), y: log(max($0.t, 1e-9))) }
        let n = Double(logs.count)
        let sumX = logs.map(\.x).reduce(0, +)
        let sumY = logs.map(\.y).reduce(0, +)
        let sumXY = logs.map { $0.x * $0.y }.reduce(0, +)
        let sumX2 = logs.map { $0.x * $0.x }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denom
    }

    /// Sink for results that would otherwise be optimised out by
    /// the compiler — ``@inline(never)`` ensures the read happens.
    /// Stored into ``ChaosBlackHole.value`` (a nonisolated(unsafe)
    /// atomic-ish int) so the read crosses an opaque boundary and
    /// the compiler can't DCE it.
    @inline(never)
    private func blackHole<T>(_ x: T) {
        ChaosBlackHole.write(String(describing: x).count)
    }
}

/// Sendable sink so the test fits Swift 6's strict concurrency
/// model. We don't care about the value beyond keeping the
/// compiler from elimating the timed call's result.
enum ChaosBlackHole {
    nonisolated(unsafe) private static var _value: Int = 0
    static func write(_ v: Int) { _value &+= v }
}
