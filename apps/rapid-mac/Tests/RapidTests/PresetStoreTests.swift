import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Chat presets")
struct PresetStoreTests {
    private func url() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-presets-\(UUID().uuidString).json")
    }

    @Test("Built-ins are curated, stable, and unique")
    func builtIns() {
        let presets = BuiltinPresets.all
        #expect((8 ... 12).contains(presets.count))
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.allSatisfy { $0.origin == .builtIn })
        #expect(presets.allSatisfy { !$0.name.isEmpty && !$0.icon.isEmpty && !$0.systemPrompt.isEmpty })
    }

    @Test("Create normalizes and round-trips a user preset")
    func createAndReload() throws {
        let storeURL = url()
        let store = PresetStore(customStoreURL: storeURL)
        let created = try #require(store.create(ChatPreset.user(
            name: "  My Coder  ",
            icon: "terminal",
            systemPrompt: "  Be exact.  ",
            modelAlias: "  model-a  ",
            sampling: SamplingOverrides(temperature: 0.3),
            enabledToolNames: ["read_file", "calculator", "read_file"]
        )))

        #expect(created.name == "My Coder")
        #expect(created.systemPrompt == "Be exact.")
        #expect(created.modelAlias == "model-a")
        #expect(created.enabledToolNames == ["calculator", "read_file"])

        let reloaded = PresetStore(customStoreURL: storeURL)
        #expect(reloaded.userPresets == [created])
    }

    @Test("Built-ins cannot be updated or deleted but can be duplicated")
    func builtInMutationRules() throws {
        let store = PresetStore(customStoreURL: url())
        let builtin = try #require(store.builtIns.first)
        #expect(store.update(builtin) == false)
        #expect(store.delete(id: builtin.id) == false)

        let copy = try #require(store.duplicate(id: builtin.id))
        #expect(copy.origin == .user)
        #expect(copy.id != builtin.id)
        #expect(copy.systemPrompt == builtin.systemPrompt)
    }

    @Test("Editing or deleting a source value cannot mutate an applied snapshot")
    func appliedSnapshot() throws {
        let store = PresetStore(customStoreURL: url())
        var source = try #require(store.create(ChatPreset.user(
            name: "Original",
            systemPrompt: "First prompt"
        )))
        let applied = AppliedPreset(source)
        let copiedPrompt = source.systemPrompt

        source.name = "Edited"
        source.systemPrompt = "Second prompt"
        #expect(store.update(source))
        #expect(store.delete(id: source.id))
        #expect(applied.name == "Original")
        #expect(copiedPrompt == "First prompt")
    }

    @Test("Corrupt storage is never overwritten by a mutation")
    func corruptStoreGuard() throws {
        let storeURL = url()
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: storeURL)
        let store = PresetStore(customStoreURL: storeURL)
        #expect(store.loadError != nil)
        #expect(store.create(ChatPreset.user(name: "Lost", systemPrompt: "No")) == nil)
        #expect(try Data(contentsOf: storeURL) == corrupt)
    }
}
