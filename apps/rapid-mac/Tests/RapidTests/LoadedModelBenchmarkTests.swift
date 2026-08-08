import Foundation
import Testing
@testable import Rapid

@Suite("Loaded-model speed test")
struct LoadedModelBenchmarkTests {
    @Test("Speed test targets the current authenticated server without a model-loader command")
    func currentServerRequest() throws {
        let request = try BenchmarkRunner.loadedBenchmarkRequest(
            baseURL: URL(string: "http://127.0.0.1:8123/v1")!,
            bearer: "test-secret",
            alias: "lfm2.5-8b-a1b-4bit",
            maxTokens: 128,
            prompt: "measure me"
        )

        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "lfm2.5-8b-a1b-4bit")
        #expect(body["max_tokens"] as? Int == 128)
        #expect(body["stream"] as? Bool == false)
    }

    @Test("Displayed speed uses completion tokens over measured wall time")
    func completionSpeed() {
        let measurement = BenchmarkRunner.LoadedMeasurement(
            completionTokens: 120, elapsedSeconds: 4)
        #expect(measurement.tokensPerSecond == 30)
    }

    @Test("OpenAI usage supplies the measured completion count")
    func usageParsing() throws {
        let data = Data(#"{"usage":{"prompt_tokens":12,"completion_tokens":96,"total_tokens":108}}"#.utf8)
        #expect(try BenchmarkRunner.loadedCompletionTokens(from: data) == 96)
    }

    @Test("Missing completion usage is rejected instead of showing zero")
    func missingUsageRejected() {
        let data = Data(#"{"choices":[]}"#.utf8)
        #expect(throws: Error.self) {
            _ = try BenchmarkRunner.loadedCompletionTokens(from: data)
        }
    }
}
