import Foundation
import Testing
@testable import Rapid

/// Pins the v0.7.6 SIGTERM grace bump (5 s → 30 s) so a future
/// "feels too long, knock it back to 5" PR fires a loud failure
/// instead of silently re-introducing the truncated prefix-cache
/// bug.
///
/// Background: rapid-mlx's FastAPI lifespan ``shutdown`` hook
/// flushes the prefix cache one safetensors file per KV entry,
/// each 200–260 MB on a 27 B/4-bit model. The 5 s grace this
/// constant replaced got SIGKILL'd ~mid-flush in a real user
/// trace (PID 57809, 18:30:11), leaving
/// ``prefix_cache/<rev>.new/`` orphaned. 30 s covers the
/// steady-state flush on the largest aliases we ship.
///
/// The upstream rapid-mlx side (raullenchai/Rapid-MLX) is moving
/// the persist to a background / interruptible writer so the
/// flush time drops back to near-zero; once that lands, the
/// constant can come back down, but only after a fresh
/// measurement and only with a deliberate PR — not as a
/// drive-by.
@MainActor
@Suite("ServerManager — SIGTERM grace period")
struct SigtermGracePeriodTests {

    @Test("sigtermGracePeriod is 30 s — guards against the v0.7.6 regression")
    func grace_is_30s() {
        let manager = ServerManager()
        #expect(manager.sigtermGracePeriod == 30.0)
    }

    @Test("sigtermGracePeriod is at least 15 s — minimum for a realistic prefix-cache flush")
    func grace_is_above_min_floor() {
        // Looser bound than the exact-value pin above so a deliberate
        // future tightening to e.g. 20 s (post upstream rapid-mlx fix)
        // doesn't fail this assertion — but a slip back to the old
        // 5 s definitely does.
        let manager = ServerManager()
        #expect(manager.sigtermGracePeriod >= 15.0)
    }
}
