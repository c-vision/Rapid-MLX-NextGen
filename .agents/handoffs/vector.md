# Vector handoff

- Status: in progress; PR #2199 is technically complete and awaiting Atlas or
  human review after the automated review loop reached its three-round cap
- Active task: benchmark the 16--64 GB Mac model matrix against mlx-vlm,
  oMLX, and applicable MLXFast/MTPLX implementations; optimize material
  Rapid-MLX deficits and re-run the controlled matrix.
- Branch or PR: `raullenchai/vector-desk`; https://github.com/raullenchai/Rapid-MLX/pull/2199
- Host: final 16--32 GB claims must run on the M2 Pro 32 GB Mac mini at SSH
  alias `mini`; large-model preflight and 48--64 GB-class experiments can run
  on the M3 Ultra 256 GB Studio but must be labelled as Studio results.
- Verified facts:
  - Google Chrome was closed with explicit human authorization before the run.
  - The mini returned `No route to host` on 2026-08-21. A Wake-on-LAN packet
    was sent to its known interface and six SSH retries still failed. It later
    became reachable again (confirmed `MINI_OK` this campaign), so the final
    16--32 GB claims are running through the controlled mini harness.
  - The reusable local workspace is `~/mac-model-matrix`; raw preflight JSON
    is under `results/` and is intentionally outside Git.
  - Busy-Studio preflight, Qwen3.5-4B 4-bit: Rapid 175.2 decode tok/s and
    2.65 GB peak MLX memory; mlx-vlm 165.9 tok/s and 3.73 GB. These are not
    publication-grade numbers.
  - Busy-Studio preflight, Gemma4-26B-A4B 4-bit: Rapid 116.6 decode tok/s and
    14.40 GB peak MLX memory; mlx-vlm 113.4 tok/s and 15.55 GB. These are not
    publication-grade numbers.
  - On both preflights Rapid's reported short-prompt prefill rate was about
    20% below mlx-vlm. The controlled Qwen3.5-4B cross-over subsequently found
    the cause: keeping mlx-lm 0.31.3 and moving MLX/Metal 0.31.2 to 0.32.1
    improved 1K/4K prefill by 22.3% (326.9/324.6 to 399.9/397.1 tok/s), closing
    the mlx-vlm gap. Shipping this requires the #1248 full-family coherence gate
    and Atlas approval because the dependency ceiling is deliberate.
  - PyPI's latest mlx-lm remains 0.31.3. Official upstream main at `dfb5da1`
    reports version 0.32.0 and removes MTP-presence as a sufficient reason to
    shift Qwen3.5/3.6 RMSNorm weights. On Studio with Qwen3.6-35B-A3B-8bit and
    MLX 0.32.1, main was exact on 8/8 64-token prompts versus 0.31.3, with
    300.1 vs 277.4 prompt tok/s and 2.79 vs 7.53 seconds cached load. Upstream
    VLM-MTP issue #1197 is still open, so its exact checkpoint layout was a
    required coherence case for this dependency move.
  - The exact #1197 layout subsequently passed 6/6 through Rapid's forced text
    lane on MLX 0.32.1 + mlx-lm 0.31.3: Qwen3.6-35B-A3B-8bit snapshot
    `e06a74e6236a60c8367e1a3214e83d8b61b637b0` contains a vision config, all
    333 `vision_tower.*` tensors, `mtp_num_hidden_layers=1`, and
    `model-mtp.safetensors`. Result SHA-256:
    `58aa10fccb3d96de92d5fccb9b9ba084ff4b823211d43e6154977d39d8feaa68`.
  - Issue #2165 follow-up on Qwen3.5-4B: mlx-lm main + MLX 0.32.1 improves
    exact-token prefill over production by 21.8% at 8K (388.1 vs 318.6) and
    20.8% at 16K (369.5 vs 306.0), with essentially unchanged peak memory.
    The 8K-to-16K scaling loss remains. At 16K, increasing prefill step from
    2K to 4K/8K/16K reduced throughput from 369.4 to 364.6/355.9/336.2 tok/s
    and raised peak memory from 5.62 to 7.28/11.02/18.63 GB. Hybrid/GDN must
    keep an architecture-specific smaller-step policy; do not promote a generic
    largest-chunk-that-fits rule.
  - Shipping candidate keeps released mlx-lm 0.31.3 and changes core to
    `mlx>=0.32.1,<0.33`. Fresh resolver probes select MLX 0.32.1 for core.
    Because mflux 0.18.1 requires `mlx<0.32`, `[image]` moves to
    `mflux>=0.19.0,<0.20`; its metadata requires `mlx>=0.32,<0.33`, the image
    resolver succeeds, and 88 image-lane plus 67 alias/dependency tests pass.
  - Controlled mini prefill crossover extended to the two other large models.
    Identical harness and stacks to the Qwen3.5 crossover (mlx-lm 0.31.3,
    transformers 5.15.1, numpy 2.4.6, tokenizers 0.22.2; only
    mlx/mlx-metal 0.31.2 -> 0.32.1). Gemma4-26B-A4B: 1K 294.4->394.9
    (+34.1%) and 4K 288.3->379.3 (+31.6%) prompt tok/s, 15.05/15.96 GB peak.
    Qwen3.8-27B (MTP checkpoint, plain AR prefill path): 1K 49.9->61.8
    (+23.8%) and 4K 49.8->61.6 (+23.7%), 17.02/18.55 GB peak. Peak memory
    unchanged in both. Added baseline venv `mlxlm-on-mlx0312` (mlx 0.31.2);
    `mlxlm-on-mlx032` (mlx 0.32.1) already existed. Raw JSON and SHA-256 are
    recorded in the mini performance report; publication-grade for this host.
  - The MLX 0.32.1 candidate passed 6/6 blocking golden coherence cases for
    every ordinary release family: Qwen3.5 4B, Qwen3.5 35B-A3B, Qwen3.6 27B,
    Gemma4 12B, DeepSeek-R1-Distill 32B, and GPT-OSS 20B. The sweep now forces
    `--disable-prefix-cache`: persisted KV tensors are not keyed by MLX runtime
    and a stale DeepSeek cache initially caused a false failure; both its cold
    rerun and the complete cold-cache release sweep passed. Hy3 snapshot
    `8e4d56f18efd912b8c7581a8ccfa8b2a79ba3469` was staged on an external
    1.8 TiB SSD and passed 6/6 on the M3 Ultra with only 13.69 MB swap used.
    Artifact SHA-256:
    `817969d4c78df19594d7c464990fa0b4e16beda3b8346e423161735ab8b9db72`.
    The complete seven-family toolchain fleet therefore passed 42/42.
  - Extra M2 Pro spot checks under the PR wheel: Qwen3.5-9B passed 6/6. LFM2.5
    1.2B and Nemotron Diffusion 3B each scored 5/6, but repeated identically on
    MLX 0.31.2 (same wrong LFM arithmetic token; same correct-but-verbose
    Nemotron answer), ruling out an MLX 0.32.1 regression. An explicit Qwen9
    `--ar-only` rerun produced 37.4165 median / 37.4258 pooled tok/s, 8/8 exact.
  - Existing unarchived Qwen3.6-35B experiments under `~/qwen38-perf` suggest
    Rapid AR around 91 tok/s, mlx-vlm AR around 83 tok/s, and Rapid MTP up to
    120.9 tok/s on one coding prompt. Re-run with the common harness before
    making claims.
- Remaining matrix: Qwen3.5-4B, LFM2.5-8B-A1B, GPT-OSS-20B, Mistral Small
  24B, Qwen3-Coder-30B-A3B, Nemotron 30B-A3B, Qwen3.6-35B-A3B,
  Qwen3-Coder-Next-80B, plus Llama 8B, Phi-4 14B, Bonsai, and DeepSeek-Coder
  compatibility baselines. Qwen3.8-27B and Gemma4-26B-A4B now have controlled
  MLX 0.32.1 prefill crossovers on the mini (recorded above and in the report).
- Risks: Studio currently has other CPU-active desktop processes; its
  preflight data must not be published. Only about 137 GiB was available on
  the Studio system volume, so uncached checkpoints need staged downloads or
  explicit cache cleanup.
- Next action: Atlas or a human reviewer should verify the round-3 AR-only
  reproduction fix in `c7984227` and land PR #2199 after final CI. The automated
  review loop stopped at its hard cap of three rounds without a post-fix LGTM;
  its round-3 finding is addressed in the branch. The complete toolchain
  coherence fleet, Hy3 Ultra, exact Qwen3.6 VLM+MTP layout, and extra mini spot
  checks are complete. Continue the remaining performance matrix independently.
