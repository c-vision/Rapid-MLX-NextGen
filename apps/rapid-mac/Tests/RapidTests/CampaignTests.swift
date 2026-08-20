import Testing
@testable import Rapid

@Suite("Campaign MVP")
struct CampaignTests {
    @Test("preview is opt-in and carries a typed pull action")
    func previewFixture() {
        #expect(Campaign.previewFromEnvironment([:]) == nil)
        let campaign = Campaign.previewFromEnvironment(["RAPID_GUI_CAMPAIGN_PREVIEW": "1"])
        #expect(campaign?.id == "model-qwen35-35b-202608")
        #expect(campaign?.action == .pullModel(.qwen35_35B4Bit))
        #expect(Campaign.Model.qwen35_35B4Bit.alias == "qwen3.5-35b-4bit")
        #expect(Campaign.Model.qwen35_35B4Bit.hfRepo == "mlx-community/Qwen3.5-35B-A3B-4bit")
    }

    @Test("dismissal is namespaced by immutable campaign id")
    func dismissalKey() {
        #expect(Campaign.preview.dismissalKey == "Rapid.campaign.dismissed.model-qwen35-35b-202608")
    }

    @Test("campaign action copy reflects transient download state")
    func actionPresentation() {
        #expect(!Campaign.ActionState.checking.isEnabled)
        #expect(Campaign.ActionState.checking.label(fallback: "Download model") == "Checking…")
        #expect(Campaign.ActionState.idle.isEnabled)
        #expect(Campaign.ActionState.idle.label(fallback: "Download model") == "Download model")
        #expect(!Campaign.ActionState.inProgress.isEnabled)
        #expect(Campaign.ActionState.inProgress.label(fallback: "Download model") == "Downloading…")
        #expect(!Campaign.ActionState.completed.isEnabled)
        #expect(Campaign.ActionState.completed.label(fallback: "Download model") == "Downloaded")
    }

    @Test(
        "campaign action resolves download and catalog races",
        arguments: [
            (Optional(Campaign.DownloadState.running), false, true, UInt(1), UInt(1), Campaign.ActionState.inProgress),
            (Optional(.completed(cacheGeneration: 2)), false, true, UInt(1), UInt(2), .completed),
            (Optional(.completed(cacheGeneration: 1)), true, true, UInt(1), UInt(2), .checking),
            (Optional(.completed(cacheGeneration: 1)), false, true, UInt(2), UInt(2), .idle),
            (Optional(.retryable), false, true, UInt(2), UInt(2), .idle),
            (Optional<Campaign.DownloadState>.none, true, true, UInt(2), UInt(2), .completed),
            (Optional<Campaign.DownloadState>.none, false, false, UInt(0), UInt(0), .checking),
        ]
    )
    func actionResolution(
        download: Campaign.DownloadState?,
        isCached: Bool,
        catalogLoaded: Bool,
        catalogGeneration: UInt,
        currentGeneration: UInt,
        expected: Campaign.ActionState
    ) {
        #expect(Campaign.actionState(
            download: download,
            isCached: isCached,
            catalogLoaded: catalogLoaded,
            catalogGeneration: catalogGeneration,
            currentGeneration: currentGeneration
        ) == expected)
    }
}
