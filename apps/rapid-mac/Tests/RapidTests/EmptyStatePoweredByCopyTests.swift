import Foundation
import Testing
@testable import Rapid

/// Pin contract for ``ChatView.emptyStatePoweredByCopy(alias:)``.
///
/// Pre-#125 the empty-state hero rendered "Powered by <alias>" once a
/// user had picked a model, conflating runtime + model in the user's
/// head. The user-facing copy sweep then dropped the engine name
/// entirely (principle: no internal engine jargon in user UI). The
/// caption now names the model plus the thing the user actually cares
/// about — that it runs locally: "<alias> · running privately on your
/// Mac".
///
/// Engine version is likewise NOT rendered: the engine ships bundled
/// inside the .app and users can't upgrade it independently — naming a
/// version they can't act on is engine trivia.
@Suite("ChatView.emptyStatePoweredByCopy — empty-state runtime caption contract")
struct EmptyStatePoweredByCopyTests {

    @Test("No alias selected → prompts the user to pick one")
    func noAliasPromptsModelPicker() {
        #expect(
            ChatView.emptyStatePoweredByCopy(alias: "")
                == "Pick a model from the top bar to begin."
        )
    }

    @Test("Alias set → model named with the local-privacy caption, no engine name, no version")
    func aliasRendersRuntimeAndAlias() {
        let copy = ChatView.emptyStatePoweredByCopy(alias: "qwen3.6-35b-4bit")
        #expect(copy == "qwen3.6-35b-4bit · running privately on your Mac")
        // No-jargon contract: the engine name never reaches this caption.
        #expect(!copy.contains("rapid-mlx"))
        #expect(!copy.contains("Powered by"))
    }

    /// #223 launch-time auto-start: when ``AutoStartDecision`` resolves
    /// an alias whose weights aren't on disk, the empty-state caption
    /// must swap to the download-aware CTA so the user knows clicking
    /// Start will kick off a multi-GB pull. Wins over both the
    /// "Pick a model" and "Powered by" branches because it's the
    /// load-bearing signal the user needs first.
    @Test("#223: pendingDownload with size renders the actionable download CTA, overriding both other branches")
    func pendingDownloadCaptionWithSize() {
        let copy = ChatView.emptyStatePoweredByCopy(
            alias: "qwen3.6-35b-4bit",
            pendingDownload: (alias: "qwen3.5-122b-8bit", sizeText: "~65 GB")
        )
        #expect(copy == "Click Start to download qwen3.5-122b-8bit (~65 GB).")
    }

    @Test("#223: pendingDownload with no size still produces an actionable CTA")
    func pendingDownloadCaptionWithoutSize() {
        let copy = ChatView.emptyStatePoweredByCopy(
            alias: "",
            pendingDownload: (alias: "qwen3.5-4b-4bit", sizeText: nil)
        )
        #expect(copy == "Click Start to download qwen3.5-4b-4bit.")
    }

    @Test("#223: pendingDownload nil leaves the legacy two-branch behaviour intact")
    func pendingDownloadNilFallsThrough() {
        // Empty alias keeps the pick-a-model copy when no
        // download is pending — the launch hook returns
        // ``.skip`` for fresh-install-no-cached-no-binary state,
        // and the existing onboarding flow still owns the frame.
        #expect(
            ChatView.emptyStatePoweredByCopy(alias: "", pendingDownload: nil)
                == "Pick a model from the top bar to begin."
        )
        #expect(
            ChatView.emptyStatePoweredByCopy(alias: "qwen3-0.6b-4bit", pendingDownload: nil)
                == "qwen3-0.6b-4bit · running privately on your Mac"
        )
    }
}
