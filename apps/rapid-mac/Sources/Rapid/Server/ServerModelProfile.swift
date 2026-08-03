import Foundation

/// Per-alias profile data returned by Rapid-MLX `/v1/models/{id}` as
/// vendor-extension fields on top of the OpenAI-canonical shape.
/// Mirrors the server's ``vllm_mlx.api.models.ModelInfo`` extension
/// surface so a curated sampling profile (``recommended_sampling``)
/// flows straight from ``aliases.json`` to the user's first chat —
/// no hand-tuning sliders, no per-model docs to read.
///
/// All extension fields are optional. A profile that resolves a
/// known alias (``qwen3.5-9b-4bit``) carries them populated; a
/// profile that resolves an unknown id (raw HF path the operator
/// supplied, or a custom model not yet in the registry) returns
/// only the OpenAI baseline (``id``/``object``/``created``/``owned_by``)
/// and the extension fields stay nil.
///
/// Wire shape (rapid-mlx ≥0.7.4 onwards; older servers omit the
/// vendor fields and we degrade gracefully — the decoder treats
/// missing keys as nil):
/// ```json
/// {
///   "id": "qwen3.5-9b-4bit",
///   "object": "model",
///   "owned_by": "rapid-mlx",
///   "recommended_sampling": { "temperature": 0.3, "top_p": 0.9 },
///   "is_hybrid": true,
///   "is_moe": false,
///   "tool_call_parser": "hermes",
///   "reasoning_parser": "qwen3",
///   "modality": "text"
/// }
/// ```
struct ServerModelProfile: Codable, Sendable, Equatable {
    let id: String
    /// Curated sampling overrides that beat the model's
    /// ``generation_config.json`` baseline on the canonical eval
    /// suite. Keys are a subset of {temperature, top_p, top_k,
    /// min_p, repetition_penalty, presence_penalty,
    /// frequency_penalty}. Applied by ``SamplingConfig`` only when
    /// the user hasn't manually overridden the sliders — see
    /// ``SamplingConfig.applyServerProfile``.
    let recommendedSampling: [String: Double]?
    /// Hybrid-thinking architecture flag (Qwen 3 / 3.5 / 3.6, GLM
    /// 4.7, Qwopus). When true the Settings → Sampling panel
    /// shows the "Show reasoning" toggle; when false the toggle
    /// stays hidden so a non-hybrid alias doesn't render UI for a
    /// kwarg its chat template silently ignores.
    let isHybrid: Bool?
    /// MoE / sparse-expert architecture. Informational — surfaced
    /// in the Settings → Models tab.
    let isMoe: Bool?
    /// Parser pair — diagnostics only, surfaced in Settings →
    /// Models so an operator can confirm which parser handles
    /// the alias without grepping server logs.
    let toolCallParser: String?
    let reasoningParser: String?
    /// Inference modality from ``AliasProfile.modality``. Today
    /// only ``"text"`` and ``"text-diffusion"`` are populated by
    /// the server; ``"vision"`` / ``"image-gen"`` are reserved
    /// for upcoming integrations.
    let modality: String?
    /// FU-3 (post-v0.7.19) — optional per-alias override for the
    /// chat-mode ``reasoning_content`` ``max_tokens`` floor that
    /// ``SamplingConfig.effectiveMaxTokens(toolsEnabled: false)``
    /// applies when the user hasn't manually dragged the slider.
    /// ``nil`` (the only value rapid-mlx ≤ 0.7.19 emits) falls back
    /// to ``SamplingConfig.defaultReasoningChatFloor`` (2,048) so
    /// every alias today gets identical behaviour. The plumbing
    /// is in place so a future ``aliases.json`` entry for a heavy
    /// reasoning model (e.g. 70B-class with an 8 KB median trace)
    /// can lift the floor without a desktop code change — keeps
    /// the per-alias SSOT pattern (PR #283/#281 lineage) intact.
    let reasoningChatFloor: Int?
    /// FU-3 — optional per-alias override for the tools-mode
    /// ``reasoning_content`` ``max_tokens`` floor. Mirrors
    /// ``reasoningChatFloor`` semantics but routes through
    /// ``effectiveMaxTokens(toolsEnabled: true)``. ``nil`` →
    /// ``SamplingConfig.defaultReasoningToolsFloor`` (4,096).
    let reasoningToolsFloor: Int?
    /// Issue #363 — max prompt-token context window the loaded
    /// rapid-mlx engine advertises for this id. Populated only by
    /// rapid-mlx ≥ 0.8.4 (the cross-repo fix that closed #363).
    /// Older sidecars omit the field entirely, in which case the
    /// catalog falls back to a per-family heuristic via
    /// ``ModelInfoCatalog.contextWindowFallback(forAlias:)``.
    /// Sourced from ``service.helpers.get_model_max_context`` on
    /// the server, so the value the desktop trusts for sliders
    /// lines up with the cap the server will actually enforce.
    let contextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case recommendedSampling = "recommended_sampling"
        case isHybrid = "is_hybrid"
        case isMoe = "is_moe"
        case toolCallParser = "tool_call_parser"
        case reasoningParser = "reasoning_parser"
        case modality
        // FU-3 — snake_case wire shape matches the rapid-mlx
        // ``AliasProfile`` JSON contract (per-alias SSOT).
        case reasoningChatFloor = "reasoning_chat_floor"
        case reasoningToolsFloor = "reasoning_tools_floor"
        // Issue #363 — snake_case mirrors the rapid-mlx
        // ``ModelInfo.context_window`` wire shape.
        case contextWindow = "context_window"
    }

    /// Explicit memberwise init with defaults for the FU-3 floor
    /// overrides. Swift only synthesises a memberwise init when
    /// EVERY stored property has either an explicit ``init`` arg
    /// or an inline default; spelling this out lets older call sites
    /// (every ``ServerModelProfile(id:..., modality:)`` site that
    /// pre-dates FU-3) keep compiling without touching them.
    init(
        id: String,
        recommendedSampling: [String: Double]? = nil,
        isHybrid: Bool? = nil,
        isMoe: Bool? = nil,
        toolCallParser: String? = nil,
        reasoningParser: String? = nil,
        modality: String? = nil,
        reasoningChatFloor: Int? = nil,
        reasoningToolsFloor: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.recommendedSampling = recommendedSampling
        self.isHybrid = isHybrid
        self.isMoe = isMoe
        self.toolCallParser = toolCallParser
        self.reasoningParser = reasoningParser
        self.modality = modality
        self.reasoningChatFloor = reasoningChatFloor
        self.reasoningToolsFloor = reasoningToolsFloor
        self.contextWindow = contextWindow
    }
}

/// Fetcher for ``ServerModelProfile`` against a Rapid-MLX server.
/// Single static entry point so callers don't need a stateful
/// client; ``URLSession.shared`` is reused (HTTP/2 keep-alive
/// across consecutive calls within a session).
///
/// Failure modes deliberately silent — a 4xx/5xx, decode error,
/// or transport timeout returns ``nil`` rather than throwing.
/// The caller (``SamplingConfig.applyServerProfile``) treats nil
/// as "no curated profile available; keep the v0.4.12 defaults"
/// which is the same code path an older Rapid-MLX server (pre
/// vendor-extension landing in 0.7.4) takes. There's no UI
/// affordance for "profile fetch failed" because there's nothing
/// the user can do about it — the chat still works, just with
/// hard-coded defaults instead of curated ones.
enum ServerProfileFetcher {
    /// Per-request timeout. Generous because the cold-start chat
    /// completion already takes ~10 s on a small model; a profile
    /// fetch that takes 5 s wouldn't be noticed. Bounded so a hung
    /// rapid-mlx (rare — only seen during model-swap races) doesn't
    /// indefinitely block the first chat send.
    static let requestTimeout: TimeInterval = 5.0

    /// Fetch ``/v1/models/{alias}``. Returns the decoded profile
    /// or ``nil`` on any failure (404, decode mismatch, timeout).
    ///
    /// ``baseURL`` is the loopback URL the chat surface already
    /// targets; ``alias`` is the rapid-mlx alias (or raw HF path)
    /// the server reports as serving; ``bearer`` is the per-launch
    /// secret from ``ServerManager.activeBearer``.
    static func fetch(
        baseURL: URL,
        alias: String,
        bearer: String?,
        session: URLSession = .shared
    ) async -> ServerModelProfile? {
        let encoded = alias.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? alias
        let url = baseURL.appendingPathComponent("v1/models/\(encoded)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(ServerModelProfile.self, from: data)
        } catch {
            return nil
        }
    }
}
