import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import Rapid

@Suite("Unified failure diagnosis")
struct FailureDiagnosisTests {
    @Test("Every diagnosis is one actionable line without internal jargon")
    func safeDiagnosisCopy() {
        let forbidden = [
            "HTTP", "Traceback", "NSURLErrorDomain", "sandbox-exec", "rapid-mlx",
            "exit code", "status code", "signal 9",
        ]
        for kind in FailureDiagnosis.Kind.allCases {
            let diagnosis = FailureDiagnoser.diagnosis(
                for: kind,
                modelAlias: "qwen3.5-4b-4bit"
            )
            #expect(!diagnosis.message.contains("\n"))
            #expect(!diagnosis.message.isEmpty)
            for token in forbidden {
                #expect(!diagnosis.message.localizedCaseInsensitiveContains(token))
            }
        }
    }

    @Test("OOM diagnosis includes the model estimate and model-management action")
    func oomEstimate() {
        let diagnosis = FailureDiagnoser.diagnosis(
            for: .modelOutOfMemory,
            modelAlias: "qwen3.5-4b-4bit"
        )
        #expect(diagnosis.message.contains("GB free"))
        #expect(diagnosis.action == .openModelManagement)
    }

    @Test("Chat classification distinguishes request, engine, and memory failures")
    func chatFailureKinds() {
        #expect(
            FailureDiagnoser.chatFailureKind(
                error: ChatStreamError.httpStatus(500, "temporary request failure")
            ) == .requestFailed
        )
        #expect(
            FailureDiagnoser.chatFailureKind(error: ChatStreamError.streamTruncated)
                == .engineNotRunning
        )
        #expect(
            FailureDiagnoser.chatFailureKind(
                error: ChatStreamError.transport("insufficient memory for projected KV")
            ) == .modelOutOfMemory
        )
    }

    @Test("Model load and running-engine failures use different recovery actions")
    func lifecycleFailureKinds() {
        let load = FailureDiagnoser.modelLoadFailureKind(raw: "model initialization failed")
        #expect(load == .modelLoadFailed)
        #expect(FailureDiagnoser.diagnosis(for: load).action == .openModelManagement)

        let crash = FailureDiagnoser.engineFailureKind(raw: "process exited unexpectedly")
        #expect(crash == .engineNotRunning)
        #expect(FailureDiagnoser.diagnosis(for: crash).action == .restart)

        let startup = FailureDiagnoser.engineFailureKind(raw: "Couldn't start the model")
        #expect(startup == .modelLoadFailed)
        #expect(FailureDiagnoser.diagnosis(for: startup).action == .openModelManagement)

        #expect(
            FailureDiagnoser.modelLoadFailureKind(raw: "Metal out of memory")
                == .modelOutOfMemory
        )
    }

    @Test(arguments: [
        ("web_search", "web_search error: NSURLErrorDomain -1009 not connected to the internet", true, FailureDiagnosis.Kind.webSearchOffline),
        ("read_file", "read_file error: /tmp/missing is missing", true, FailureDiagnosis.Kind.fileNotFound),
        ("write_file", "write_file error: permission denied", true, FailureDiagnosis.Kind.filePermissionDenied),
    ])
    func toolCaseTable(
        toolName: String,
        content: String,
        isError: Bool,
        expected: FailureDiagnosis.Kind
    ) {
        #expect(
            FailureDiagnoser.toolFailureKind(
                toolName: toolName,
                content: content,
                isError: isError
            ) == expected
        )
    }

    @Test("run_command sandbox denial is failed even when its structured result is not")
    func commandSandboxDenial() {
        let raw = #"{"exit_code":1,"stdout":"","stderr":"sandbox-exec: deny file-write-create /private/tmp/x","sandboxed":true}"#
        let kind = FailureDiagnoser.toolFailureKind(
            toolName: "run_command",
            content: raw,
            isError: false
        )
        #expect(kind == .commandPermissionDenied)
        #expect(FailureDiagnoser.diagnosis(for: kind!).action == .openPermissions)
    }

    @MainActor
    @Test("Builtin registry marks a non-zero command result as a diagnosed failure")
    func registryClassifiesCommandExit() async {
        let defaults = UserDefaults(
            suiteName: "rapid.test.failure-diagnosis.\(UUID().uuidString)"
        )!
        let approval = CommandApprovalStore(defaults: defaults)
        approval.mode = .autoApproveAll
        let registry = BuiltinToolRegistry(
            commandApproval: approval
        )
        let result = await registry.run(
            ToolCall(
                id: "command-1",
                name: "run_command",
                arguments: #"{"command":"exit 7"}"#
            )
        )
        #expect(result.isError)
        #expect(
            result.failureKind == .commandFailed
                || result.failureKind == .commandPermissionDenied
        )
        let payload = try? JSONSerialization.jsonObject(
            with: Data(result.content.utf8)
        ) as? [String: Any]
        #expect((payload?["exit_code"] as? Int ?? 0) != 0)
    }

    @Test("Raw tool details remain model-facing while display copy stays safe")
    func rawToolContentPreserved() {
        let raw = "web_search error: HTTP 503\nTraceback: NSURLErrorDomain"
        let kind = FailureDiagnoser.toolFailureKind(
            toolName: "web_search",
            content: raw,
            isError: true
        )!
        let result = ToolCallResult(
            toolCallID: "call-1",
            content: raw,
            isError: true,
            failureKind: kind
        )
        #expect(result.content == raw)
        let display = FailureDiagnoser.diagnosis(for: kind).message
        #expect(!display.contains("HTTP"))
        #expect(!display.contains("Traceback"))
        #expect(!display.contains("NSURLErrorDomain"))
    }

    @Test("ChatMessage diagnosis round-trips and remains optional for old sessions")
    func chatMessageCodableCompatibility() throws {
        let current = ChatMessage(
            role: .tool,
            content: "raw detail",
            status: .failed,
            failureKind: .fileNotFound,
            toolCallID: "call-1"
        )
        let data = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.failureKind == .fileNotFound)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "failureKind")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
        #expect(legacy.failureKind == nil)
    }

    @MainActor
    @Test("FailureDiagnosisView supports copy-only and actionable forms")
    func reusableViewAction() throws {
        let diagnosis = FailureDiagnoser.diagnosis(for: .downloadFailed)
        let copyOnly = FailureDiagnosisView(diagnosis: diagnosis)
        #expect(throws: Error.self) {
            try copyOnly.inspect().find(button: "Retry")
        }

        let actionable = FailureDiagnosisView(diagnosis: diagnosis, onAction: { _ in })
        #expect(throws: Never.self) {
            try actionable.inspect().find(button: "Retry")
        }
    }

    @MainActor
    @Test("Mirror failures offer source switching; direct-source failures retry")
    func downloadSourceClassification() {
        let mirror = DownloadManager()
        _ = mirror._testingSeedJob(alias: "model-a", source: .mirror)
        mirror._testingIngestStderr(
            alias: "model-a",
            line: "models.rapidmlx.com returned status 503"
        )
        mirror._testingFinish(alias: "model-a", status: 1, reason: .exit)
        #expect(mirror.job(for: "model-a")?.failureKind == .downloadSourceUnavailable)

        let direct = DownloadManager()
        _ = direct._testingSeedJob(alias: "model-b", source: .huggingFace)
        direct._testingIngestStderr(alias: "model-b", line: "connection reset")
        direct._testingFinish(alias: "model-b", status: 1, reason: .exit)
        #expect(direct.job(for: "model-b")?.failureKind == .downloadFailed)
    }

    @MainActor
    @Test("Download retry preserves progress metadata and the selected source")
    func downloadRetryMetadata() {
        let downloads = DownloadManager()
        _ = downloads._testingSeedJob(
            alias: "model-c",
            hfPath: "example/model-c",
            totalBytes: 42,
            source: .huggingFace
        )
        downloads._testingFinish(alias: "model-c", status: 1, reason: .exit)

        #expect(!downloads.retryDownload(alias: "model-c"))
        let retried = downloads.job(for: "model-c")
        #expect(retried?.hfPath == "example/model-c")
        #expect(retried?.totalBytes == 42)
        #expect(retried?.source == .huggingFace)
    }

    @Test("Direct Hugging Face choice changes only the supplied child environment")
    func childLocalDownloadSource() {
        var child = ["RAPID_MLX_MODEL_MIRROR": "https://custom.example"]
        DownloadManager.applyDownloadSource(.huggingFace, env: &child)
        #expect(child["RAPID_MLX_MODEL_MIRROR"] == "")

        var mirrorChild: [String: String] = [:]
        DownloadManager.applyDownloadSource(.mirror, env: &mirrorChild)
        #expect(mirrorChild["RAPID_MLX_MODEL_MIRROR"] == "https://models.rapidmlx.com")
    }

    @Test("Info.plist explains removable and network volume prompts")
    func volumeUsageDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        for key in ["NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription"] {
            let value = try #require(plist[key] as? String)
            #expect(value.contains("Click Allow"))
            #expect(value.contains("model storage") || value.contains("file tool"))
        }
    }
}
