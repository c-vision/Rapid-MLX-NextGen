import Foundation
import Testing
@testable import Rapid

@Suite("GitHub star onboarding prompt")
struct GitHubStarPromptTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Rapid/UI/\(name)"),
            encoding: .utf8
        )
    }

    @Test("Repository link targets the canonical Rapid-MLX project")
    func canonicalRepositoryURL() {
        #expect(GitHubCommunity.repositoryURL.absoluteString ==
                "https://github.com/raullenchai/Rapid-MLX")
    }

    @Test("First-run prompt owns a stable persistence key")
    func stablePromptPersistenceKey() {
        #expect(GitHubCommunity.didShowOnboardingPromptKey ==
                "Rapid.didShowOnboardingGitHubStarPrompt")
    }

    @Test("Completion prompt presents once and records that presentation")
    func oneShotCompletionTransition() {
        let first = GitHubStarPromptCompletion.completingOnboarding(hasShown: false)
        #expect(first == GitHubStarPromptCompletion(
            hasShown: true,
            shouldPresent: true
        ))

        let repeated = GitHubStarPromptCompletion.completingOnboarding(
            hasShown: first.hasShown
        )
        #expect(repeated == GitHubStarPromptCompletion(
            hasShown: true,
            shouldPresent: false
        ))
    }

    @Test("Star entry is mounted in Chat and the completion overlay")
    func productionWiring() throws {
        let chat = try Self.source("ChatView.swift")
        let content = try Self.source("ContentView.swift")

        #expect(chat.contains("GitHubStarButton()"))
        #expect(content.contains("OnboardingCompletePrompt"))
        #expect(content.contains("GitHubStarPromptCompletion.completingOnboarding"))
    }
}
