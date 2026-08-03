import Foundation
import Testing
@testable import Rapid

/// Contract for the streaming tool-call accumulator. The OpenAI spec
/// splits a single tool call across many SSE chunks — first chunk
/// carries ``id`` + ``name``, every subsequent chunk only appends a
/// fragment of ``arguments``. ``index`` is the only stable key across
/// chunks. Get this wrong and either (a) every other token in the
/// argument JSON gets dropped, or (b) call IDs from different turns
/// collide.
@Suite("ToolCallAccumulator")
struct ToolCallAccumulatorTests {
    @Test("Single call assembled from 3 streamed deltas")
    func singleCallStreaming() {
        var acc = ToolCallAccumulator()
        acc.accept(.init(
            index: 0,
            id: "call_abc",
            type: "function",
            function: .init(name: "get_weather", arguments: "")
        ))
        acc.accept(.init(
            index: 0, id: nil, type: nil,
            function: .init(name: nil, arguments: "{\"city\"")
        ))
        acc.accept(.init(
            index: 0, id: nil, type: nil,
            function: .init(name: nil, arguments: ":\"Tokyo\"}")
        ))
        let calls = acc.finalize()
        #expect(calls.count == 1)
        let c = calls[0]
        #expect(c.id == "call_abc")
        #expect(c.function.name == "get_weather")
        #expect(c.function.arguments == "{\"city\":\"Tokyo\"}")
    }

    @Test("Parallel calls assembled in index order")
    func parallelCallsByIndex() {
        var acc = ToolCallAccumulator()
        // Server emits two calls interleaved across chunks.
        acc.accept(.init(index: 0, id: "call_a", type: "function",
                         function: .init(name: "read_file", arguments: "{")))
        acc.accept(.init(index: 1, id: "call_b", type: "function",
                         function: .init(name: "list_dir", arguments: "{")))
        acc.accept(.init(index: 0, id: nil, type: nil,
                         function: .init(name: nil, arguments: "\"path\":\"/etc\"}")))
        acc.accept(.init(index: 1, id: nil, type: nil,
                         function: .init(name: nil, arguments: "\"path\":\"/tmp\"}")))
        let calls = acc.finalize()
        #expect(calls.count == 2)
        // Sorted by index ascending — that's the stable ordering
        // the chat loop and ``tool_call_id`` round-trip depend on.
        #expect(calls[0].id == "call_a")
        #expect(calls[1].id == "call_b")
        #expect(calls[0].function.arguments == "{\"path\":\"/etc\"}")
        #expect(calls[1].function.arguments == "{\"path\":\"/tmp\"}")
    }

    @Test("Empty arguments survive intact (no-arg tools)")
    func noArgTool() {
        var acc = ToolCallAccumulator()
        acc.accept(.init(index: 0, id: "call_now", type: "function",
                         function: .init(name: "current_time", arguments: "")))
        let calls = acc.finalize()
        #expect(calls.count == 1)
        #expect(calls[0].function.arguments == "")
    }

    @Test("Delta without an id is dropped from the final output")
    func droppedWithoutID() {
        // A pathological server that emits an arguments fragment
        // before sending the id chunk would leave an unkeyable call.
        // We drop it rather than ship a half-formed call back to the
        // chat loop where it would fail to round-trip.
        var acc = ToolCallAccumulator()
        acc.accept(.init(index: 0, id: nil, type: nil,
                         function: .init(name: nil, arguments: "leaked args")))
        let calls = acc.finalize()
        #expect(calls.isEmpty)
    }

    /// Codex audit r1 (ToolKit.swift:122): a call with a non-empty
    /// id but empty function name was previously emitted — the
    /// executor would then route the call to nowhere and the user
    /// would see a silent failure instead of a clean banner. The
    /// corrected contract requires BOTH id and name to be present.
    @Test("Delta with id but empty function name is dropped")
    func droppedWithEmptyName() {
        var acc = ToolCallAccumulator()
        acc.accept(.init(
            index: 0,
            id: "call_xyz",
            type: "function",
            function: .init(name: "", arguments: "{}")
        ))
        let calls = acc.finalize()
        #expect(calls.isEmpty)
    }

    /// Same shape but the function field is entirely absent on every
    /// delta — Builder.name stays as its default empty string.
    @Test("Delta with id but no function payload at all is dropped")
    func droppedWithMissingFunction() {
        var acc = ToolCallAccumulator()
        acc.accept(.init(
            index: 0,
            id: "call_xyz",
            type: "function",
            function: nil
        ))
        let calls = acc.finalize()
        #expect(calls.isEmpty)
    }
}

/// Pin the JSON-blob codec — used for tool ``parameters`` JSON
/// Schemas. A regression here silently produces tool definitions
/// the model can't read.
@Suite("CodableJSON round-trip")
struct CodableJSONTests {
    @Test("Nested object survives encode → decode")
    func roundtrip() throws {
        let original: CodableJSON = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to read")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodableJSON.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Decodes booleans, numbers, nulls in the same blob")
    func mixedLeaves() throws {
        let raw = #"""
        {"a": true, "b": 42, "c": null, "d": [1, 2.5, "x"]}
        """#
        let decoded = try JSONDecoder().decode(CodableJSON.self, from: Data(raw.utf8))
        guard case .object(let pairs) = decoded else {
            Issue.record("expected object")
            return
        }
        #expect(pairs["a"] == .bool(true))
        #expect(pairs["b"] == .number(42))
        #expect(pairs["c"] == .null)
        guard case .array(let items) = pairs["d"]! else {
            Issue.record("expected array")
            return
        }
        #expect(items.count == 3)
    }
}
