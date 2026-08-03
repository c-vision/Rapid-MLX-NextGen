import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

/// Footer chip surfaces last-completed-assistant tok/s alongside CPU /
/// GPU / RAM. Contract: prefer server-reported usage, fall back to
/// char-count estimate with a ``~`` prefix, render a neutral em-dash
/// (``— tok/s``) when no assistant turn has produced stats yet.
///
/// #461: the pill reads "<n> tok/s", never the "TPS" abbreviation —
/// matching ChatView's per-message caption and the LM Studio
/// convention. The negative guards below pin that we don't regress to
/// the old "TPS" prefix.
@MainActor
@Suite("TokensPerSecondPill shape")
struct TokensPerSecondPillTests {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-tps-\(UUID().uuidString).json")
        return SessionStore(customStoreURL: url)
    }

    @Test("Brand-new session with no assistant turn renders neutral em-dash")
    func emptySession() throws {
        let store = makeStore()
        _ = store.newSession(alias: "qwen3.5-4b-4bit")
        let sut = TokensPerSecondPill(store: store)

        // Idle copy: "— tok/s" (U+2014 em-dash) — neutral "no data yet"
        // glyph that doesn't read as a failure state.
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "— tok/s")
        }
        // #461: guard against regression back to the "TPS" abbreviation.
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "TPS —")
        }
    }

    @Test("Idle pill exposes a no-data-yet accessibility label, not 'not available'")
    func idleAccessibilityLabel() throws {
        // VoiceOver users hit the same "broken?" perception as sighted
        // users when the label reads "not available". The fix swaps in
        // "no data yet" to match the visual em-dash + tooltip wording.
        let store = makeStore()
        _ = store.newSession(alias: "qwen3.5-4b-4bit")
        let sut = TokensPerSecondPill(store: store)

        let inspected = try sut.inspect()
        // The accessibility label is applied to the outer HStack via
        // .accessibilityElement(children: .ignore).
        let label = try inspected.hStack().accessibilityLabel().string()
        #expect(label == "Tokens per second: no data yet")
    }

    @Test("Active pill keeps the numeric accessibility label")
    func activeAccessibilityLabel() throws {
        // Once a real turn lands, the label switches back to the
        // concrete number so screen-reader users get the same info
        // sighted users do from the pill text.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "x",
                stats: MessageStats(
                    elapsedSeconds: 2.0,
                    charCount: 200,
                    promptTokens: 50,
                    completionTokens: 84
                )
            ),
        ])
        let sut = TokensPerSecondPill(store: store)

        let label = try sut.inspect().hStack().accessibilityLabel().string()
        #expect(label == "Tokens per second: 42")
    }

    @Test("Server-reported tokens/sec render without the ~ prefix")
    func reportedTokensRenderClean() throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "x",
                stats: MessageStats(
                    elapsedSeconds: 2.0,
                    charCount: 200,
                    promptTokens: 50,
                    completionTokens: 84
                )
            ),
        ])
        let sut = TokensPerSecondPill(store: store)

        // 84 completion / 2.0 s = 42 tok/s. Reported → no tilde.
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "42 tok/s")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "~42 tok/s")
        }
    }

    @Test("Estimated tokens/sec (no usage chunk) render with the ~ prefix")
    func estimatedTokensRenderTilde() throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        // 800 chars / 4 chars-per-token / 5 s = 40 tok/s estimated.
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: String(repeating: "abcdefgh", count: 100),
                stats: MessageStats(
                    elapsedSeconds: 5.0,
                    charCount: 800,
                    promptTokens: nil,
                    completionTokens: nil
                )
            ),
        ])
        let sut = TokensPerSecondPill(store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "~40 tok/s")
        }
    }

    @Test("Most recent assistant turn wins when a session has many")
    func mostRecentWins() throws {
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "early",
                stats: MessageStats(elapsedSeconds: 2.0, charCount: 200, promptTokens: 0, completionTokens: 10)
            ),
            ChatMessage(role: .user, content: "follow-up"),
            ChatMessage(
                role: .assistant,
                content: "late",
                stats: MessageStats(elapsedSeconds: 1.0, charCount: 100, promptTokens: 0, completionTokens: 99)
            ),
        ])
        let sut = TokensPerSecondPill(store: store)

        // Late turn = 99 tok/s, not the early 5 tok/s.
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "99 tok/s")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "5 tok/s")
        }
    }

    @Test("Streaming placeholder doesn't shadow the previous turn's stats")
    func streamingPlaceholderFallsThroughToPrevious() throws {
        // ChatViewModel only attaches stats when status == .complete,
        // so an in-flight assistant row carries stats=nil. The pill
        // must walk past it to the previous complete turn instead of
        // rendering n/a mid-stream.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "first answer",
                stats: MessageStats(elapsedSeconds: 1.0, charCount: 50, promptTokens: 0, completionTokens: 27)
            ),
            ChatMessage(role: .user, content: "follow-up while streaming"),
            ChatMessage(role: .assistant, content: "", status: .streaming),
        ])
        let sut = TokensPerSecondPill(store: store)

        #expect(throws: Never.self) {
            try sut.inspect().find(text: "27 tok/s")
        }
    }

    @Test("completionTokens == 0 falls back to the char-count estimate")
    func zeroCompletionTokensFallsBack() throws {
        // Mid-stream cancellation + late usage chunk can leave a
        // completed turn with completion_tokens=0 yet non-empty
        // content. Rendering red "0 tok/s" misleads; fall through to
        // the estimate which at least reflects what arrived.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: String(repeating: "x", count: 800),
                stats: MessageStats(
                    elapsedSeconds: 5.0,
                    charCount: 800,
                    promptTokens: 50,
                    completionTokens: 0
                )
            ),
        ])
        let sut = TokensPerSecondPill(store: store)

        // 800 / 4 / 5 = 40 estimated.
        #expect(throws: Never.self) {
            try sut.inspect().find(text: "~40 tok/s")
        }
        #expect(throws: (any Error).self) {
            _ = try sut.inspect().find(text: "0 tok/s")
        }
    }

    @Test("Threshold boundaries: exactly 10 = moderate, exactly 30 = fast")
    func thresholdBoundaries() throws {
        // Spec: <10 slow, <30 moderate, >=30 fast. Lock the boundaries
        // so a future refactor can't silently shift them.
        let store = makeStore()
        let id = store.newSession(alias: "qwen3.5-4b-4bit")
        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "boundary at 30",
                stats: MessageStats(elapsedSeconds: 1.0, charCount: 100, promptTokens: 0, completionTokens: 30)
            ),
        ])
        let fastSUT = TokensPerSecondPill(store: store)
        #expect(throws: Never.self) {
            try fastSUT.inspect().find(text: "30 tok/s")
        }

        store.replaceMessages(sessionID: id, with: [
            ChatMessage(
                role: .assistant,
                content: "boundary at 10",
                stats: MessageStats(elapsedSeconds: 1.0, charCount: 100, promptTokens: 0, completionTokens: 10)
            ),
        ])
        let moderateSUT = TokensPerSecondPill(store: store)
        #expect(throws: Never.self) {
            try moderateSUT.inspect().find(text: "10 tok/s")
        }
    }

    @Test("Switching activeID re-resolves which session's stats the pill reads")
    func switchingSessions() throws {
        let store = makeStore()
        let slow = store.newSession(alias: "fixture-1b-4bit")
        store.replaceMessages(sessionID: slow, with: [
            ChatMessage(
                role: .assistant,
                content: "slow",
                stats: MessageStats(elapsedSeconds: 4.0, charCount: 200, promptTokens: 0, completionTokens: 8)
            ),
        ])
        let fast = store.newSession(alias: "fixture-7b-4bit")
        store.replaceMessages(sessionID: fast, with: [
            ChatMessage(
                role: .assistant,
                content: "fast",
                stats: MessageStats(elapsedSeconds: 1.0, charCount: 200, promptTokens: 0, completionTokens: 55)
            ),
        ])

        store.activeID = slow
        let slowSUT = TokensPerSecondPill(store: store)
        #expect(throws: Never.self) {
            try slowSUT.inspect().find(text: "2 tok/s")
        }

        store.activeID = fast
        let fastSUT = TokensPerSecondPill(store: store)
        #expect(throws: Never.self) {
            try fastSUT.inspect().find(text: "55 tok/s")
        }
    }
}
