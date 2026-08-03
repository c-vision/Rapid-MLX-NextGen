import Foundation
import Testing
@testable import Rapid

/// Pins the SSE per-line byte cap (audit P1 `ChatStreamClient.send():150`).
/// A misbehaving or malicious server can write bytes without ever
/// emitting a newline; the default `URLSession.AsyncBytes.lines`
/// buffers them unbounded into a String — gigabyte response → OOM.
/// `BoundedLinesSequence` throws once the per-line buffer exceeds
/// `maxLineBytes`, so the renderer's allocation is bounded by what
/// we choose, not by what the peer chooses.
@Suite("SSE bounded-lines reader")
struct BoundedLinesSequenceTests {
    /// Synthesise an async byte stream from a `[UInt8]` so tests
    /// don't need a real socket.
    private func stream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream<UInt8> { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
    }

    @Test("Single newline-terminated line yields one chunk and stops")
    func single_line() async throws {
        let bytes = stream(Array("data: hello\n".utf8))
        var out: [String] = []
        for try await line in bytes.boundedLines(maxLineBytes: 1024) {
            out.append(line)
        }
        #expect(out == ["data: hello"])
    }

    @Test("Multiple short lines yield in order")
    func multiple_lines() async throws {
        let bytes = stream(Array("a\nbb\nccc\n".utf8))
        var out: [String] = []
        for try await line in bytes.boundedLines(maxLineBytes: 1024) {
            out.append(line)
        }
        #expect(out == ["a", "bb", "ccc"])
    }

    @Test("CRLF terminators are normalised — trailing \\r stripped before yield")
    func crlf_normalisation() async throws {
        let bytes = stream(Array("data: 1\r\ndata: 2\r\n".utf8))
        var out: [String] = []
        for try await line in bytes.boundedLines(maxLineBytes: 1024) {
            out.append(line)
        }
        #expect(out == ["data: 1", "data: 2"])
    }

    @Test("Tail without trailing newline still yields once at EOF")
    func tail_without_newline() async throws {
        let bytes = stream(Array("first\nlast-no-newline".utf8))
        var out: [String] = []
        for try await line in bytes.boundedLines(maxLineBytes: 1024) {
            out.append(line)
        }
        #expect(out == ["first", "last-no-newline"])
    }

    @Test("Empty stream yields nothing and does not throw")
    func empty_stream() async throws {
        let bytes = stream([])
        var out: [String] = []
        for try await line in bytes.boundedLines(maxLineBytes: 1024) {
            out.append(line)
        }
        #expect(out.isEmpty)
    }

    @Test("Line exceeding the cap throws transport error")
    func line_over_cap_throws() async throws {
        // 100 bytes of `x` followed by a `\n` — cap is 50, so we
        // should throw on the 51st byte (before any newline).
        var raw = Array(repeating: UInt8(ascii: "x"), count: 100)
        raw.append(UInt8(ascii: "\n"))
        let bytes = stream(raw)

        var threw = false
        do {
            for try await _ in bytes.boundedLines(maxLineBytes: 50) {
                // unreachable
            }
        } catch let error as ChatStreamError {
            threw = true
            if case .transport(let msg) = error {
                #expect(msg.contains("50"),
                        "Error message should mention the cap: \(msg)")
                #expect(msg.localizedCaseInsensitiveContains("oom") ||
                        msg.localizedCaseInsensitiveContains("cap"),
                        "Error message should explain the cap: \(msg)")
            } else {
                Issue.record("Expected ChatStreamError.transport, got \(error)")
            }
        }
        #expect(threw, "Oversized line must throw, not silently drop")
    }

    /// Codex r1 NIT-1: pin the EXACT boundary. A future refactor of
    /// the `>` guard to `>=` would silently chop legitimate 50-byte
    /// lines; without this test the regression slips by because the
    /// other "throws" cases all feed 100 bytes.
    @Test("Boundary: exactly cap bytes passes, cap+1 bytes throws")
    func boundary_exactly_at_cap() async throws {
        // Exactly 50 bytes of payload + `\n`: must yield "x"*50.
        var atCap = Array(repeating: UInt8(ascii: "x"), count: 50)
        atCap.append(UInt8(ascii: "\n"))
        var passed: [String] = []
        for try await line in stream(atCap).boundedLines(maxLineBytes: 50) {
            passed.append(line)
        }
        #expect(passed.count == 1)
        #expect(passed.first?.count == 50)

        // 51 bytes of payload (one over): must throw.
        var overCap = Array(repeating: UInt8(ascii: "x"), count: 51)
        overCap.append(UInt8(ascii: "\n"))
        var threw = false
        do {
            for try await _ in stream(overCap).boundedLines(maxLineBytes: 50) {}
        } catch let error as ChatStreamError {
            if case .transport = error { threw = true }
        }
        #expect(threw, "buffer.count > maxLineBytes must fire at cap+1")
    }

    /// Tail-without-newline path: the in-loop cap is the invariant.
    /// The dedicated EOF-tail cap check was removed as dead code in
    /// codex r1; this test now proves the EOF tail throw fires from
    /// the in-loop guard (byte 51), not from a separate tail check.
    @Test("Tail without newline exceeding cap throws — caught by in-loop guard")
    func tail_over_cap_throws() async throws {
        let raw = Array(repeating: UInt8(ascii: "x"), count: 100)
        let bytes = stream(raw)

        var threw = false
        do {
            for try await _ in bytes.boundedLines(maxLineBytes: 50) {}
        } catch let error as ChatStreamError {
            threw = true
            if case .transport(let msg) = error {
                // The in-loop guard's wording — proves the tail path
                // routes through it, not through a now-deleted tail-
                // specific check.
                #expect(msg.contains("SSE line exceeded"),
                        "Expected in-loop-guard message, got: \(msg)")
            } else {
                Issue.record("Expected ChatStreamError.transport, got \(error)")
            }
        }
        #expect(threw)
    }

    @Test("Short first line then oversized second — first yields, second throws")
    func first_yields_then_second_throws() async throws {
        var raw = Array("ok\n".utf8)
        raw.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: 100))
        raw.append(UInt8(ascii: "\n"))
        let bytes = stream(raw)

        var out: [String] = []
        var threw = false
        do {
            for try await line in bytes.boundedLines(maxLineBytes: 50) {
                out.append(line)
            }
        } catch let error as ChatStreamError {
            threw = true
            if case .transport = error {
                // expected
            } else {
                Issue.record("Expected ChatStreamError.transport, got \(error)")
            }
        }
        #expect(out == ["ok"])
        #expect(threw)
    }

    /// Pin the production cap so a future refactor doesn't silently
    /// shrink it below realistic chunk sizes — a 50K-token completion
    /// can JSON-wrap to ~150 KB on one chunk.
    @Test("Production cap is generous (≥ 256 KiB) but bounded")
    func production_cap_is_sensible() {
        #expect(ChatStreamClient.maxSSELineBytes >= (1 << 18))
        #expect(ChatStreamClient.maxSSELineBytes <= (1 << 24))
    }
}
