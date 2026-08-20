import SwiftUI

enum GitHubCommunity {
    static let repositoryURL = URL(string: "https://github.com/raullenchai/Rapid-MLX")!
    static let didShowOnboardingPromptKey = "Rapid.didShowOnboardingGitHubStarPrompt"
}

struct GitHubStarPromptCompletion: Equatable {
    let hasShown: Bool
    let shouldPresent: Bool

    static func completingOnboarding(hasShown: Bool) -> Self {
        Self(hasShown: true, shouldPresent: !hasShown)
    }
}

struct GitHubStarButton: View {
    var onOpen: () -> Void = {}
    var accessibilityIdentifier = "GitHub.Star.EmptyState"

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            onOpen()
            openURL(GitHubCommunity.repositoryURL)
        } label: {
            Label("Star on GitHub", systemImage: "star")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RapidTheme.brandPrimaryDeep)
        .background(
            Capsule(style: .continuous)
                .fill(RapidTheme.brandPrimaryTint)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(RapidTheme.brandPrimary.opacity(0.55), lineWidth: 1)
        )
        .contentShape(Capsule(style: .continuous))
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityHint("Opens the Rapid-MLX repository in your browser")
    }
}

struct OnboardingCompletePrompt: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Onboarding complete")
                        .font(.system(size: 14, weight: .semibold))
                    Text("You’re ready to chat locally with Rapid-MLX.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss onboarding completion")
                .accessibilityIdentifier("OnboardingComplete.Close")
            }

            HStack(spacing: 8) {
                GitHubStarButton(
                    onOpen: onDismiss,
                    accessibilityIdentifier: "OnboardingComplete.Star"
                )
                Spacer(minLength: 0)
                Button("Later", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("OnboardingComplete.Later")
            }
        }
        .padding(16)
        .frame(width: 342)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("OnboardingComplete.Prompt")
    }
}
