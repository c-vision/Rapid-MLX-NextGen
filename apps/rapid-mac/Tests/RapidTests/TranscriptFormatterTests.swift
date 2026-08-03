import Foundation
import Testing
@testable import Rapid

/// Contract for ``TranscriptFormatter`` — the pure function that
/// builds the Cmd+Shift+C clipboard payload for Quick Ask (v0.5.0).
///
/// We pin the output shape because the formatter is the entire
/// "share my chat" surface: the user pastes this string into Slack /
/// Notion / a GitHub issue and expects it to read as a transcript.
/// A regression that silently bolds the wrong role label or leaks
/// reasoning trace is invisible to the unit suite unless we lock
/// the format here.
@MainActor
@Suite("TranscriptFormatter — v0.5.0 Quick Ask copy")
struct TranscriptFormatterTests {

    // MARK: - Helpers

    private func session(
        alias: String = "qwen3.6-27b",
        messages: [ChatMessage]
    ) -> ChatSession {
        ChatSession(
            id: UUID(),
            title: "test",
            alias: alias,
            messages: messages,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    private func assistant(_ content: String, reasoning: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: content, reasoning: reasoning)
    }

    // MARK: - Empty-state contracts

    @Test("Empty session returns nil — caller should disable Copy")
    func emptyReturnsNil() {
        let s = session(messages: [])
        #expect(TranscriptFormatter.format(s) == nil)
    }

    @Test("Whitespace-only messages return nil — no empty paste")
    func whitespaceOnlyReturnsNil() {
        let s = session(messages: [
            user("   "),
            assistant("\n\n   \t")
        ])
        #expect(TranscriptFormatter.format(s) == nil)
    }

    @Test("Tool-only / system-only sessions return nil")
    func toolAndSystemOnlyReturnsNil() {
        let sys = ChatMessage(role: .system, content: "you are helpful")
        var tool = ChatMessage(role: .tool, content: "{\"result\": 42}")
        tool.toolCallID = "call_1"
        let s = session(messages: [sys, tool])
        #expect(TranscriptFormatter.format(s) == nil)
    }

    // MARK: - Happy path

    @Test("Single user + assistant turn — bold-role pairs")
    func singleTurnIsTwoBoldBlocks() {
        let s = session(messages: [
            user("What's 2+2?"),
            assistant("4.")
        ])
        let out = TranscriptFormatter.format(s)
        #expect(out == "**You**\nWhat's 2+2?\n\n**qwen3.6-27b**\n4.")
    }

    @Test("Assistant label uses the session's alias, not the word 'Assistant'")
    func assistantLabelIsAlias() {
        let s = session(alias: "qwen3.5-35b-8bit", messages: [
            user("hi"),
            assistant("hello")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(out.contains("**qwen3.5-35b-8bit**"))
        #expect(!out.contains("**Assistant**"))  // would mean alias drop-out
    }

    @Test("Empty-alias session falls back to literal 'Assistant'")
    func emptyAliasFallback() {
        let s = session(alias: "", messages: [
            user("hi"),
            assistant("hello")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(out.contains("**Assistant**"))
    }

    @Test("Multi-turn transcript — every block separated by a blank line")
    func multiTurnSeparators() {
        let s = session(messages: [
            user("hi"),
            assistant("hello"),
            user("how are you"),
            assistant("good")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        // Four blocks, three separators of "\n\n".
        let separators = out.components(separatedBy: "\n\n").count - 1
        #expect(separators == 3)
    }

    // MARK: - Edge cases

    @Test("In-flight (empty) assistant placeholder is skipped, user prompt remains")
    func emptyAssistantPlaceholderSkipped() {
        // Reproduces the mid-stream state where the user has sent
        // a prompt but the assistant placeholder hasn't accumulated
        // any content yet — pressing Copy at that moment should
        // give us just the user line, not "**model**\n" with a
        // trailing dangling label.
        let s = session(messages: [
            user("what's up"),
            assistant("")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(out == "**You**\nwhat's up")
    }

    @Test("Reasoning content is NOT leaked to clipboard")
    func reasoningTraceOmitted() {
        // Hybrid models like Qwen 3.6 emit a long ``reasoning``
        // trace alongside ``content``. The user copying for share
        // should NOT have that trace appear in their paste — it's
        // debugging context, not the answer. (Slack paste with a
        // 2-KB <think> dump was an explicit regression vector
        // we're guarding against.)
        let secret = "<think>Let me figure out the user's intent then plan tools</think>"
        let s = session(messages: [
            user("hi"),
            assistant("hello", reasoning: secret)
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(!out.contains(secret))
        #expect(!out.lowercased().contains("<think>"))
    }

    @Test("System messages stripped — they're prompt scaffolding, not conversation")
    func systemMessageStripped() {
        let s = session(messages: [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            user("hi"),
            assistant("hello")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(!out.contains("You are a helpful assistant"))
        #expect(!out.contains("**System**"))
    }

    @Test("Tool role messages stripped — protocol noise, not prose")
    func toolMessageStripped() {
        var toolResp = ChatMessage(role: .tool, content: "{\"weather\": \"sunny\"}")
        toolResp.toolCallID = "call_1"
        let s = session(messages: [
            user("weather?"),
            toolResp,
            assistant("It's sunny.")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(!out.contains("weather\": \"sunny"))
        #expect(out.contains("It's sunny."))
    }

    @Test("Leading / trailing whitespace per message is trimmed but inline newlines preserved")
    func whitespaceTrimming() {
        let s = session(messages: [
            user("\n  hello\nworld  \n"),
            assistant("\n\nresponse\n")
        ])
        let out = TranscriptFormatter.format(s) ?? ""
        #expect(out.contains("hello\nworld"))
        // Should NOT start with whitespace on either block.
        #expect(out.contains("**You**\nhello\nworld"))
        #expect(out.contains("**qwen3.6-27b**\nresponse"))
    }
}
