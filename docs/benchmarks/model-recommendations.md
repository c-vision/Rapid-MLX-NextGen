# Measured model recommendations

Release recommendations use two slots per RAM tier:

- **Faster:** the fastest model that remains useful for its stated scope.
- **Smarter:** the highest-capability model that clears the interaction and safety gates.

A recommendation must decode at **10 tok/s or faster**, complete the standard
8K prefill at **100 prompt tok/s or faster**, stay below **75% of physical RAM**
at the tier floor, and add **no swap**. A model that misses a gate may remain in
the catalog, but belongs under “Runs, but slow or tight”, not Recommended.

The benchmark is reproducible with:

```bash
python scripts/benchmark_model_recommendations.py \
  --output /tmp/model-recommendations.json
```

It starts one cached model at a time through `rapid-mlx serve`, uses macOS
`footprint` so Metal unified memory is counted, runs short and ~8K-token
prompts, records `/v1/status` throughput, and stops between models. Raw reviewed
rows live in [`model-recommendation-measurements.json`](model-recommendation-measurements.json).

## Table 1 — chip × RAM × model × engine

First release sweep: Mac mini Mac14,12, Apple M2 Pro (10-core), 32 GB, macOS
26.5.2; Rapid-MLX 0.12.5 at `1bc6244b`; MLX 0.31.2; mlx-lm 0.31.3. `Peak` is
the process-lifetime `phys_footprint_peak`. Throughput columns show short / 8K.

| Model | Load | Idle | 8K peak | Prefill tok/s | Decode tok/s | New swap | Decision |
|---|---:|---:|---:|---:|---:|---:|---|
| `lfm2.5-1b-4bit` | 5.1s | 0.97 GB | 2.05 GB | 1,122 | 214 / 127 | 0 MB | Very fast; basic chat only |
| `lfm2.5-2.6b-4bit` | 4.1s | 1.91 GB | 3.21 GB | 488 | 94.2 / 52.0 | 0 MB | Smarter small-model option; not for coding |
| `lfm2.5-8b-a1b-4bit` | 7.1s | 4.87 GB | 6.07 GB | 632 | 120 / 83.5 | 0 MB | Fast chat specialist |
| `qwen3.5-4b-4bit` | 5.1s | 2.76 GB | 5.82 GB | 313 | 62.2 / 39.1 | 0 MB | Fast general-purpose |
| `qwen3.5-9b-4bit` | 6.1s | 5.26 GB | 8.68 GB | 172 | 36.2 / 31.8 | 0 MB | Strong laptop default |
| `gemma-4-12b-4bit` | 14.1s | 7.32 GB | 11.0 GB | 52 | 23.4 / 22.0 | 0 MB | Fails 8K prefill gate |
| `bonsai-27b-2bit` | 8.1s | 7.81 GB | 13.0 GB | 170 | 17.8 / 15.8 | 0 MB | Smart 24 GB candidate |
| `gemma-4-26b-4bit`¹ | 12.1s | 14.0 GB | 20.0 GB | 227 | 50.1 / 23.6 | 0 MB | Floor at 32 GB, not 24 GB |
| `qwen3.5-35b-4bit` | 17.1s | 19.0 GB | 22.0 GB | 336 | 60.3 / 50.3 | **989 MB** | Floor above 32 GB |
| `qwen3.6-27b-4bit` | 13.5s | 15.0 GB | 21.0 GB | 48.9 | 11.3 / 10.7 | 0 MB | Fails 8K prefill gate |

¹ Text-only launch flags: `--no-mllm --kv-cache-dtype bf16 --cache-memory-mb 512`.

The 32 GB Qwen 35B swap regression is tracked in #1634. The unsafe 24 GB
Gemma 26B floor is tracked in #1636.

## Table 2 — two choices per RAM tier

“Smarter” is the primary pick. “Faster” deliberately trades capability for
latency. Rows above the measured 32 GB host retain the existing reviewed
large-memory picks and must gain host-specific measurements before their next
release change.

| Physical RAM | Faster | Smarter | Rationale |
|---|---|---|---|
| 8–15 GB | `lfm2.5-1b-4bit` | `lfm2.5-2.6b-4bit` | Smallest safe pair; neither is for serious coding |
| 16–17 GB | `lfm2.5-1b-4bit` | `qwen3.5-4b-4bit` | Instant basic chat vs reliable general use |
| 18–23 GB | `qwen3.5-4b-4bit` | `qwen3.5-9b-4bit` | Both tool-capable and comfortably above 10 tok/s |
| 24–31 GB | `qwen3.5-4b-4bit` | `bonsai-27b-2bit` | 13 GB measured peak; Gemma 26B is too large at 24 GB |
| 32–47 GB | `qwen3.5-4b-4bit` | `gemma-4-26b-4bit` | 20 GB 8K peak with no new swap on the 32 GB floor |
| 48–63 GB | `qwen3.6-35b-4bit` | `gemma-4-26b-4bit` | Retains the existing reviewed fast pick pending a 48 GB host measurement |
| 64–95 GB | `qwen3.6-35b-4bit` | `qwen3.6-35b-8bit` | Same family: speed vs quantization fidelity |
| 96 GB+ | `qwen3.6-35b-4bit` | `qwen3.5-122b-mxfp4` | Workhorse speed vs maximum local capability |

Recommendation data is hardware-specific. A result from one chip/RAM pair must
not be silently copied to another; missing rows are estimates and should be
replaced by measurements before changing a tier.
