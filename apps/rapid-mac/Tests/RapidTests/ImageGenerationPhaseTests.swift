import Testing
@testable import Rapid

@Suite("Image generation phase semantics")
@MainActor
struct ImageGenerationPhaseTests {
    @Test("The final denoise step becomes finalizing until the response lands")
    func completedDenoiseFinalizes() {
        let final = ImageClient.ImageProgress(
            running: false, step: 4, total: 4, elapsedMs: 1_000
        )
        #expect(ImageGenViewModel.nextPhase(from: .denoising, progress: final) == .finalizing)
        #expect(ImageGenViewModel.nextPhase(from: .finalizing, progress: final) == .finalizing)
        #expect(ImageGenViewModel.nextPhase(from: .preparing, progress: final) == .finalizing)
        let finalStillRunning = ImageClient.ImageProgress(
            running: true, step: 4, total: 4, elapsedMs: 1_000
        )
        #expect(
            ImageGenViewModel.nextPhase(from: .denoising, progress: finalStillRunning)
                == .finalizing
        )
    }

    @Test("Idle progress before sampling remains preparation")
    func idleProgressPrepares() {
        let idle = ImageClient.ImageProgress(
            running: false, step: 0, total: 0, elapsedMs: 0
        )
        #expect(ImageGenViewModel.nextPhase(from: .preparing, progress: idle) == .preparing)
    }

    @Test("Progress-bar seed steps match each family's engine default")
    func seedStepsMatchEngineDefaults() {
        // The bar is scaled from these before the server reports a live
        // total; a turbo-sized seed on a 20-step model makes the bar slam to
        // full and sit there. Values mirror _DEFAULT_STEPS_BY_FAMILY in
        // vllm_mlx/image/engine.py.
        #expect(ImageGenViewModel.seedSteps(for: "qwen-image") == 20)
        #expect(ImageGenViewModel.seedSteps(for: "qwen-image-edit") == 20)
        #expect(ImageGenViewModel.seedSteps(for: "z-image-turbo") == 8)
        #expect(ImageGenViewModel.seedSteps(for: "flux2-klein-4b") == 4)
    }
}
