import Foundation
import Testing
@testable import Rapid

/// Contract for v0.4.12 ``MessageStats`` — the throughput caption
/// that surfaces "~84 tok/s · 2.4 s" under each completed assistant
/// turn. Pins the formatter switchover points + the
/// reported-vs-estimated precedence so a refactor can't quietly
/// drop the "~" estimate prefix or invert which branch wins when
/// both are populated.
@Suite("MessageStats + caption formatters")
struct MessageStatsTests {

    // MARK: - estimatedTokensPerSecond / reportedTokensPerSecond

    @Test("Estimate fires from char count when promptTokens / completionTokens are nil")
    func estimateFires() {
        let s = MessageStats(
            elapsedSeconds: 2.0,
            charCount: 800,
            promptTokens: nil,
            completionTokens: nil
        )
        // 800 chars / 4 chars-per-token = 200 tokens
        // 200 / 2 s = 100 tokens/s
        #expect(s.estimatedTokensPerSecond ?? 0 == 100.0)
        #expect(s.reportedTokensPerSecond == nil)
    }

    @Test("Reported overrides estimate when the server populated completionTokens")
    func reportedOverrides() {
        let s = MessageStats(
            elapsedSeconds: 2.0,
            charCount: 800,
            promptTokens: 50,
            completionTokens: 180
        )
        #expect(s.reportedTokensPerSecond ?? 0 == 90.0)
        // Estimate is still computable — the UI just prefers reported.
        #expect(s.estimatedTokensPerSecond != nil)
    }

    @Test("Sub-50ms elapsed returns nil — divide-by-near-zero would print a garbage TPS")
    func nearZeroElapsedNoTPS() {
        let s = MessageStats(
            elapsedSeconds: 0.001,
            charCount: 5,
            promptTokens: nil,
            completionTokens: nil
        )
        #expect(s.estimatedTokensPerSecond == nil)
        #expect(s.reportedTokensPerSecond == nil)
    }

    // MARK: - formatTPS

    @Test("TPS under 10 keeps one decimal so 4-bit 27B doesn't read as 9 tok/s")
    func tpsSubTen() {
        #expect(AssistantStatsFormatter.formatTPS(9.4) == "9.4")
        #expect(AssistantStatsFormatter.formatTPS(0.7) == "0.7")
    }

    @Test("TPS 10+ rounds to int because nobody cares about tenths at 80 tok/s")
    func tpsTenPlus() {
        #expect(AssistantStatsFormatter.formatTPS(10.0) == "10")
        #expect(AssistantStatsFormatter.formatTPS(83.7) == "84")
        #expect(AssistantStatsFormatter.formatTPS(120.4) == "120")
    }

    // MARK: - formatElapsed

    @Test("Sub-second elapsed renders as milliseconds")
    func elapsedMs() {
        #expect(AssistantStatsFormatter.formatElapsed(0.42) == "420 ms")
        #expect(AssistantStatsFormatter.formatElapsed(0.05) == "50 ms")
    }

    @Test("1-60s elapsed renders as 'X.Xs'")
    func elapsedSeconds() {
        #expect(AssistantStatsFormatter.formatElapsed(1.0) == "1.0 s")
        #expect(AssistantStatsFormatter.formatElapsed(8.34) == "8.3 s")
        #expect(AssistantStatsFormatter.formatElapsed(59.9) == "59.9 s")
    }

    @Test("Past 60s elapsed renders as 'Xm Ys' so tool-call rounds aren't 94.7s walls")
    func elapsedMinutes() {
        #expect(AssistantStatsFormatter.formatElapsed(60.0) == "1m 0s")
        #expect(AssistantStatsFormatter.formatElapsed(94.7) == "1m 34s")
        #expect(AssistantStatsFormatter.formatElapsed(125.0) == "2m 5s")
    }

    // MARK: - VoiceOver caption

    @Test("Accessibility caption resolves the tilde + middle-dot into plain English")
    func a11yCaption() {
        let est = MessageStats(
            elapsedSeconds: 2.4,
            charCount: 800,
            promptTokens: nil,
            completionTokens: nil
        )
        let caption = AssistantStatsFormatter.accessibilityCaption(for: est)
        #expect(caption.contains("approximately"))
        #expect(caption.contains("tokens per second"))
        #expect(caption.contains("took"))

        let reported = MessageStats(
            elapsedSeconds: 2.0,
            charCount: 800,
            promptTokens: 50,
            completionTokens: 180
        )
        let captionReported = AssistantStatsFormatter.accessibilityCaption(for: reported)
        // Reported branch drops the "approximately" prefix — the
        // number IS authoritative when usage is wired (v0.4.13).
        #expect(!captionReported.contains("approximately"))
        #expect(captionReported.contains("tokens per second"))
    }

    // MARK: - Schema compat (old sessions without stats)

    @Test("Decodes a pre-v0.4.12 message envelope that has no 'stats' key — defaults to nil")
    func decodesLegacyEnvelope() throws {
        // Hand-rolled JSON matching the v0.4.11 schema (no stats field).
        // Autosynth Codable should treat missing optional fields as nil.
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "role": "assistant",
            "content": "Hello from v0.4.11",
            "reasoning": "",
            "status": "complete",
            "createdAt": 770000000.0
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        let msg = try dec.decode(ChatMessage.self, from: legacyJSON)
        #expect(msg.stats == nil)
        #expect(msg.content == "Hello from v0.4.11")
    }

    @Test("Round-trips a populated stats field through JSON encode → decode")
    func roundTripsStats() throws {
        var msg = ChatMessage(role: .assistant, content: "Hi", status: .complete)
        msg.stats = MessageStats(
            elapsedSeconds: 2.4,
            charCount: 100,
            promptTokens: 50,
            completionTokens: 25
        )
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(back.stats?.elapsedSeconds == 2.4)
        #expect(back.stats?.charCount == 100)
        #expect(back.stats?.promptTokens == 50)
        #expect(back.stats?.completionTokens == 25)
    }
}
