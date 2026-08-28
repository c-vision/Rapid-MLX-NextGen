import Foundation
import Testing
@testable import Rapid

@Suite("Lane-owned session model restore", .serialized)
struct SessionModelRestoreTests {
    private actor SequencedCatalogLoader {
        private var responses: [[ModelEntry]]

        init(_ responses: [[ModelEntry]]) {
            self.responses = responses
        }

        func load() -> [ModelEntry] {
            guard !responses.isEmpty else { return [] }
            return responses.removeFirst()
        }
    }

    private let chat = ModelEntry(
        alias: "qwen3.5-4b-4bit",
        hfRepo: "mlx-community/Qwen3.5-4B-MLX-4bit",
        sizeOnDisk: "2.5 GB",
        cached: true,
        kind: .chat
    )
    private let stt = ModelEntry(
        alias: "speech-input",
        hfRepo: "example/speech-input",
        sizeOnDisk: "500 MB",
        cached: true,
        kind: .audio,
        audioCapability: .transcription
    )
    private let tts = ModelEntry(
        alias: "speech-output",
        hfRepo: "example/speech-output",
        sizeOnDisk: "1 GB",
        cached: true,
        kind: .audio,
        audioCapability: .speech
    )

    @Test("Dictation cannot replace the restored chat alias")
    func dictationThenRelaunch() {
        let restored = SessionModelRestore.resolve(
            legacyLastAlias: chat.alias,
            dictationAlias: stt.alias,
            speechAlias: nil,
            catalog: [chat, stt]
        )

        #expect(restored.chatAlias == chat.alias)
        #expect(restored.dictationAlias == stt.alias)
    }

    @Test("Dictation and speech retain independent audio selections")
    func dictationAndSpeechThenRelaunch() {
        let restored = SessionModelRestore.resolve(
            legacyLastAlias: chat.alias,
            dictationAlias: stt.alias,
            speechAlias: tts.alias,
            catalog: [chat, stt, tts]
        )

        #expect(restored == SessionModelRestore(
            chatAlias: chat.alias,
            dictationAlias: stt.alias,
            speechAlias: tts.alias
        ))
    }

    @Test("Audio-only history does not invent a chat model")
    func audioOnlyHistory() {
        let restored = SessionModelRestore.resolve(
            legacyLastAlias: stt.alias,
            dictationAlias: stt.alias,
            speechAlias: tts.alias,
            catalog: [chat, stt, tts]
        )

        #expect(restored.chatAlias == nil)
        #expect(restored.dictationAlias == stt.alias)
        #expect(restored.speechAlias == tts.alias)
    }

    @Test("An rc2 chat alias migrates through chat capability metadata")
    func rc2ChatAliasUpgrade() {
        let restored = SessionModelRestore.resolve(
            legacyLastAlias: "  \(chat.alias)  ",
            dictationAlias: nil,
            speechAlias: nil,
            catalog: [chat, stt]
        )

        #expect(restored.chatAlias == chat.alias)
    }

    @Test("Legacy aliases use catalog casing after a case-insensitive lane match")
    func legacyAliasCasingIsCanonicalized() {
        let restored = SessionModelRestore.resolve(
            legacyLastAlias: chat.alias.uppercased(),
            dictationAlias: stt.alias.uppercased(),
            speechAlias: nil,
            catalog: [chat, stt]
        )

        #expect(restored.chatAlias == chat.alias)
        #expect(restored.dictationAlias == stt.alias)
    }

    @Test("A failed catalog probe preserves pending legacy chat ownership")
    func failedCatalogProbeDoesNotRejectLegacyAlias() {
        let plan = SessionModelRestore.launchPlan(
            legacyLastAlias: chat.alias,
            dictationAlias: nil,
            speechAlias: nil,
            catalog: [],
            autoStartEnabled: true
        )

        #expect(!plan.chatAliasResolved)
        #expect(plan.models.chatAlias == nil)
        #expect(!plan.shouldAutoStart)

        let retry = SessionModelRestore.launchPlan(
            legacyLastAlias: chat.alias,
            dictationAlias: nil,
            speechAlias: nil,
            catalog: [chat, stt],
            autoStartEnabled: true
        )
        #expect(retry.chatAliasResolved)
        #expect(retry.models.chatAlias == chat.alias)
        #expect(retry.shouldAutoStart)
    }

    @Test("Exhausting the bounded catalog retry rejects an unverified legacy alias")
    @MainActor
    func exhaustedCatalogRetryFailsClosed() {
        let plan = SessionModelRestore.launchPlan(
            legacyLastAlias: chat.alias,
            dictationAlias: stt.alias,
            speechAlias: nil,
            catalog: [],
            autoStartEnabled: true,
            emptyCatalogIsAuthoritative: true
        )

        #expect(plan.chatAliasResolved)
        #expect(plan.models.chatAlias == nil)
        #expect(!plan.shouldAutoStart)
        let quickstartAlias = ContentView.quickstartChatAlias(for: .unresolved)
        #expect(quickstartAlias != nil)
        #expect(quickstartAlias! == nil)
        #expect(QuickstartCoordinator.isEligible(
            done: false,
            legacyDone: false,
            lastServedAlias: quickstartAlias!,
            serverState: .idle
        ))
    }

    @Test("Only catalog-proven chat readiness may rewrite chat persistence")
    func chatPersistenceOwnership() {
        #expect(SessionModelRestore.shouldPersistChatAlias(catalogEntry: chat))
        #expect(!SessionModelRestore.shouldPersistChatAlias(catalogEntry: stt))
        #expect(!SessionModelRestore.shouldPersistChatAlias(catalogEntry: tts))
        #expect(!SessionModelRestore.shouldPersistChatAlias(catalogEntry: nil))
    }

    @Test(
        "ensureVoiceLane audio ready never overwrites the chat-lane key",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func audioOnlyReadyPreservesPersistedChat() async throws {
        let suite = "SessionModelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(chat.alias, forKey: SessionModelRestore.chatAliasStorageKey)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fakeServer = packageRoot.appendingPathComponent("scripts/fake-rapid-mlx.sh")
        let server = ServerManager(
            testingState: .idle,
            binaryPath: fakeServer,
            sessionDefaults: defaults
        )
        server.memorySnapshotProvider = { Self.safeMemorySnapshot }

        // Drive the exact production regression vector through the fake
        // sidecar: ensureVoiceLane → ensureServing(residencyEligible: false)
        // → start(audio alias) → /healthz → .ready(audio alias).
        let ready = await server.ensureVoiceLane(
            alias: stt.alias,
            hfPath: stt.hfRepo
        )

        #expect(ready)
        #expect(server.servingAlias == stt.alias)
        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == chat.alias)
        await server.stop()
    }

    @Test(
        "ensureServing rejects a UI hint contradicted by the authoritative catalog",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func ensureServingRejectsHintMissingFromCatalog() async throws {
        let suite = "SessionModelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("previous-chat", forKey: SessionModelRestore.chatAliasStorageKey)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fakeServer = packageRoot.appendingPathComponent("scripts/fake-rapid-mlx.sh")
        let server = ServerManager(
            testingState: .idle,
            binaryPath: fakeServer,
            sessionDefaults: defaults
        )
        server.memorySnapshotProvider = { Self.safeMemorySnapshot }

        let ready = await server.ensureServing(
            alias: chat.alias,
            hfPath: chat.hfRepo,
            estimatedMemoryGB: nil,
            replacementGroup: .assistant,
            catalogEntryHint: ServerManager.CatalogEntryHint(
                entry: chat,
                generation: 0
            )
        )

        #expect(ready)
        #expect(server.servingAlias == chat.alias)
        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == "previous-chat")
        await server.stop()
    }

    private static var safeMemorySnapshot: MemoryProbe.Snapshot {
        MemoryProbe.Snapshot(
            totalBytes: 64 * 1_024 * 1_024 * 1_024,
            usedBytes: 0
        )
    }

    @Test(
        "Cat 2364: removing the alias in a newer authoritative catalog invalidates its retained chat fallback"
    )
    func provenanceInvalidatedWhenAuthoritativeCatalogRemovesAlias() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )
        let retained = [chat.alias.lowercased(): fallback]

        // A newer authoritative snapshot no longer lists the alias at all.
        let reconciled = ServerManager.reconcilingProvenance(
            retained,
            against: [stt, tts],
            generation: 7
        )

        #expect(reconciled.isEmpty)
    }

    @Test(
        "Cat 2364: reclassifying the alias to audio in a newer authoritative catalog invalidates its retained chat fallback"
    )
    func provenanceInvalidatedWhenAuthoritativeCatalogReclassifiesLane() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )
        let retained = [chat.alias.lowercased(): fallback]

        // Same generation — the engine moved the alias from the chat section to
        // the audio registry without any on-disk change, so cacheGeneration
        // never bumped. Content reconciliation must still drop the fallback.
        let audioOnly = ModelEntry(
            alias: chat.alias,
            hfRepo: chat.hfRepo,
            sizeOnDisk: chat.sizeOnDisk,
            cached: true,
            kind: .audio,
            audioCapability: .transcription
        )
        let reconciled = ServerManager.reconcilingProvenance(
            retained,
            against: [audioOnly, stt],
            generation: 7
        )

        #expect(reconciled.isEmpty)
    }

    @Test(
        "Cat 2364: a chat fallback survives while the authoritative catalog still classifies it as chat"
    )
    func provenanceSurvivesUnchangedAuthoritativeCatalog() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )
        let retained = [chat.alias.lowercased(): fallback]

        // No on-disk change and the alias is still chat: the retained proof the
        // memory-confirmation re-entry relies on must survive.
        let reconciled = ServerManager.reconcilingProvenance(
            retained,
            against: [chat, stt],
            generation: 7
        )

        #expect(reconciled[chat.alias.lowercased()]?.entry == chat)
        #expect(reconciled[chat.alias.lowercased()]?.generation == 7)
    }

    @Test("Cat 2364: surviving provenance refreshes capability metadata from the current row")
    func provenanceRefreshesCurrentCatalogMetadata() {
        let stale = ModelEntry(
            alias: chat.alias,
            hfRepo: chat.hfRepo,
            sizeOnDisk: chat.sizeOnDisk,
            cached: true,
            kind: .chat,
            isBuiltinProfile: true,
            isTextOnly: false
        )
        let current = ModelEntry(
            alias: chat.alias,
            hfRepo: chat.hfRepo,
            sizeOnDisk: chat.sizeOnDisk,
            cached: true,
            kind: .chat,
            isBuiltinProfile: true,
            isTextOnly: true
        )

        let reconciled = ServerManager.reconcilingProvenance(
            [
                chat.alias.lowercased(): ServerManager.CatalogEntryHint(
                    entry: stale,
                    generation: 7
                ),
            ],
            against: [current],
            generation: 7
        )

        #expect(reconciled[chat.alias.lowercased()]?.entry == current)
    }

    @Test(
        "Cat 2364: a catalog-epoch change bounds the fallback lifecycle even when the alias stays chat"
    )
    func provenanceIsBoundedToItsCatalogEpoch() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )
        let retained = [chat.alias.lowercased(): fallback]

        // The authoritative catalog advanced to generation 8 (e.g. a download
        // finished). A fallback derived from generation 7 is stale by
        // definition and must be re-derived before it is trusted.
        let reconciled = ServerManager.reconcilingProvenance(
            retained,
            against: [chat, stt],
            generation: 8
        )

        #expect(reconciled.isEmpty)
    }

    @Test(
        "Cat 2364: an epoch advance invalidates retained provenance even when the refreshed probe fails"
    )
    func provenanceDoesNotCrossEpochOnEmptyProbe() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )

        let reconciled = ServerManager.reconcilingProvenance(
            [chat.alias.lowercased(): fallback],
            against: [],
            generation: 8
        )

        #expect(reconciled.isEmpty)
    }

    @Test("Cat 2364: a UI hint is accepted only in its source catalog epoch")
    func catalogHintCarriesItsSourceEpoch() {
        let hint = ServerManager.CatalogEntryHint(entry: chat, generation: 7)

        #expect(
            ServerManager.validatedCatalogHint(
                alias: chat.alias,
                hint: hint,
                generation: 7
            ) == hint
        )
        #expect(
            ServerManager.validatedCatalogHint(
                alias: chat.alias,
                hint: hint,
                generation: 8
            ) == nil
        )
    }

    @Test(
        "Cat 2364: a failed (empty) catalog probe preserves same-epoch provenance"
    )
    func provenanceSurvivesEmptyProbe() {
        let fallback = ServerManager.CatalogEntryHint(
            entry: chat, generation: 7
        )
        let retained = [chat.alias.lowercased(): fallback]

        // An empty array is ModelCatalog's subprocess-failure sentinel — no
        // authority, so the retained proof must not be cancelled by it.
        let reconciled = ServerManager.reconcilingProvenance(
            retained,
            against: [],
            generation: 7
        )

        #expect(reconciled.count == 1)
    }

    @Test(
        "Cat 2364: after a reclassified authoritative snapshot, a later failed probe cannot rewrite the chat key",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func chatSelectionKeyIsSafeAfterReclassificationThenFailedProbe() async throws {
        let suite = "SessionModelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The user's chat choice is already on disk.
        defaults.set(chat.alias, forKey: SessionModelRestore.chatAliasStorageKey)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fakeServer = packageRoot.appendingPathComponent("scripts/fake-rapid-mlx.sh")
        let server = ServerManager(
            testingState: .idle,
            binaryPath: fakeServer,
            sessionDefaults: defaults
        )

        // A chat-proven start was retained under catalog generation 7.
        server._testSetCatalogProvenStart([
            chat.alias.lowercased(): ServerManager.CatalogEntryHint(
                entry: chat, generation: 7
            ),
        ])

        // A newer authoritative snapshot reclassifies the alias to audio.
        let audioOnly = ModelEntry(
            alias: chat.alias,
            hfRepo: chat.hfRepo,
            sizeOnDisk: chat.sizeOnDisk,
            cached: true,
            kind: .audio,
            audioCapability: .transcription
        )
        server._testReconcileCatalogProvenStart(
            against: [audioOnly, stt],
            generation: 7
        )

        // The stale chat fallback is gone.
        #expect(server._testCatalogProvenStartEntries[chat.alias.lowercased()] == nil)

        // A later start's catalog probe fails (no hint, no retained fallback):
        // the ready decision is nil, so the audio-only model cannot rewrite the
        // user's chat selection.
        let readyEntry = ServerManager.readyCatalogEntry(
            alias: chat.alias,
            probed: nil,
            hint: server._testCatalogProvenStartEntries[chat.alias.lowercased()]?.entry
        )
        #expect(readyEntry == nil)

        server.recordReadySelection(alias: chat.alias, catalogEntry: readyEntry)
        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == chat.alias)
        await server.stop()
    }

    @Test("A catalog-proven chat ready transition owns the chat-lane key")
    @MainActor
    func chatReadyUpdatesPersistedChat() throws {
        let suite = "SessionModelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let server = ServerManager(
            testingState: .ready(alias: chat.alias),
            sessionDefaults: defaults
        )
        server.recordReadySelection(
            alias: chat.alias,
            catalogEntry: chat
        )

        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == chat.alias)
    }

    @Test("A catalog-proven start hint survives a transient ready-time probe failure")
    @MainActor
    func chatHintPersistsAfterProbeFailure() throws {
        let suite = "SessionModelRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerManager(
            testingState: .ready(alias: chat.alias),
            sessionDefaults: defaults
        )

        let readyEntry = ServerManager.readyCatalogEntry(
            alias: chat.alias,
            probed: nil,
            hint: chat
        )
        server.recordReadySelection(alias: chat.alias, catalogEntry: readyEntry)

        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == chat.alias)
        #expect(ServerManager.readyCatalogEntry(
            alias: chat.alias,
            probed: nil,
            hint: stt
        ) == nil)
    }

    @Test("A failed shared catalog snapshot can be invalidated for one authoritative restore retry")
    func failedCatalogSnapshotRetriesThroughRealCache() async {
        let loader = SequencedCatalogLoader([[], [chat, stt]])
        let cache = ModelCatalogCache { _, _ in await loader.load() }
        let binary = URL(fileURLWithPath: "/tmp/rapid-session-restore-test")

        let failed = await cache.entries(binary: binary, generation: 0)
        let joinedFailure = await cache.entries(binary: binary, generation: 0)
        #expect(failed.isEmpty)
        #expect(joinedFailure.isEmpty)

        await cache.invalidate()
        let retried = await cache.entries(binary: binary, generation: 0)
        let plan = SessionModelRestore.launchPlan(
            legacyLastAlias: chat.alias,
            dictationAlias: nil,
            speechAlias: nil,
            catalog: retried,
            autoStartEnabled: true
        )

        #expect(retried.map(\.alias) == [chat.alias, stt.alias])
        #expect(plan.chatAliasResolved)
        #expect(plan.models.chatAlias == chat.alias)
        #expect(plan.shouldAutoStart)
    }

    @Test("Lifecycle catalog reads await fresh metadata instead of stale presentation rows")
    func lifecycleCatalogReadBypassesStaleWhileRevalidate() async {
        let audioOnly = ModelEntry(
            alias: chat.alias,
            hfRepo: chat.hfRepo,
            sizeOnDisk: chat.sizeOnDisk,
            cached: true,
            kind: .audio,
            audioCapability: .transcription
        )
        let loader = SequencedCatalogLoader([[chat], [audioOnly]])
        let cache = ModelCatalogCache(
            loader: { _, _ in await loader.load() },
            ttl: 0
        )
        let binary = URL(fileURLWithPath: "/tmp/rapid-session-fresh-catalog-test")

        let presented = await cache.entries(binary: binary, generation: 0)
        let authoritative = await cache.freshEntries(binary: binary, generation: 0)

        #expect(presented == [chat])
        #expect(authoritative == [audioOnly])
    }

    @Test("Lifecycle catalog reads reuse an unexpired snapshot")
    func lifecycleCatalogReadKeepsTheFastPath() async {
        let loader = SequencedCatalogLoader([[chat], [stt]])
        let cache = ModelCatalogCache { _, _ in await loader.load() }
        let binary = URL(fileURLWithPath: "/tmp/rapid-session-fresh-cache-test")

        let first = await cache.entries(binary: binary, generation: 0)
        let authoritative = await cache.freshEntries(binary: binary, generation: 0)
        await cache.invalidate()
        let nextLoaderValue = await cache.entries(binary: binary, generation: 0)

        #expect(first == [chat])
        #expect(authoritative == [chat])
        #expect(nextLoaderValue == [stt])
    }
}
