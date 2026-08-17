# Qwen3.8-27B compact MTP SKU gate

Date: 2026-08-16

## Product decision

Ship the existing mixed-precision backbone plus the official Q4 MTP sidecar,
rather than publishing a larger MTPLX-specific requantization:

- backbone: `rapid-mlx/Qwen3.8-27B-mixed-3.5bpw-MLX`
  (`d8b68e21eab505332d4a456dacec6d4125c96d73`)
- sidecar: `mlx-community/Qwen3.8-27B-MTP-4bit`
  (`b643c01b6d3b094e325edb6ebd832e16c486c575`)
- combined payload: 13,872,252 KiB (about 13.23 GiB)
- sidecar `model.safetensors` SHA-256:
  `76663c101e7e8ea9c0ae17bcb95183cd7f733ce424c912b8b264a7b1c48e4cc6`

This composition is smaller and faster on the target Studio than the tested
15 GiB MTPLX-specific candidate. Rapid exposes it through the explicit
`mtp-fast` single-user lane and leaves the existing lossless batched MTP path
unchanged.

## Speed and memory

M3 Ultra Studio, mlx-vlm MTP, block size 3:

| workload | AR | MTP | speedup | peak |
|---|---:|---:|---:|---:|
| short text | 39.7 tok/s | 62.4 tok/s | 1.57x | about 15.3 GB |
| 1K prompt + 256 output | 38.67 tok/s | 58.44 tok/s | 1.51x | 17.09 GB |
| 2K prompt + 256 output | 38.36 tok/s | 59.78 tok/s | 1.56x | 18.76 GB |
| 4K prompt + 256 output | 38.28 tok/s | 57.50 tok/s | 1.50x | not used for the low-memory gate |

Rapid OpenAI-server dogfood on the same Studio produced 256 tokens in 4.05 s
(about 63 tok/s end-to-end), returned valid SSE termination, parsed a Hermes
tool call, and processed a real image payload.

M2 Pro Mini is not an MTP-fast target: the same mlx-vlm path measured 11.06
tok/s AR versus 10.67 tok/s MTP. Keep the lane opt-in until hardware-aware
autotuning can prove a win on the current machine. Short outputs are always
routed to AR (default threshold: `max_tokens <= 64`).

An 18 GB Mac is a constrained tier, not the default claim. A 1K-context run
stayed at 17.09 decimal GB peak; 2K reached 18.76 GB before OS/application
headroom. Recommend a 1K context cap and AR fallback on that tier. The 24 GB
tier has adequate headroom for the normal MTP path.

## Capability gates

All comparisons use the same backbone and paired prompts, greedy decoding:

| gate | AR | MTP | paired result |
|---|---:|---:|---|
| MMLU-Pro 500 | 224/500 | 224/500 | 500/500 byte-identical |
| GSM8K 150 | 143/150 | 144/150 | MTP +1, AR +0 |
| HumanEval 40 | 22/40 adjusted | 22/40 adjusted | four apparent flips vanished at 1280-token rerun |
| MMBench-EN 300 | 260/300 | 260/300 | 300/300 byte-identical |

The HumanEval absolute number is from the local paired harness, not the
model-card EvalPlus harness. The paired conclusion is the gate being used.
MMBench is a one-letter, image-prefill-dominated workload: MTP measured 0.999x,
which validates the production decision to route `max_tokens <= 64` to AR.

Raw Studio artifacts live under
`/Users/raullenstudio/qwen38-mtp-24gb/results/`; Mini MTPLX artifacts live
under `/Volumes/mac-storage/qwen38-mtp-mixed/`.

## Rejected artifact experiments

MTPLX 2.7.2 verify kernels specialize 4/8-bit operations; the mixed backbone
contains many 2/3-bit modules. A direct MTP graft reached only 1.17x on Mini.
Promoting every linear-attention output projection to Q8 produced a roughly
15 GiB candidate and recovered a 1.65x multiplier on Mini (13.81 tok/s), but
only 44.62 tok/s on Studio versus the 62.4 tok/s mlx-vlm composition. Promoting
only the last 16 layers reached 1.07x. Neither candidate beats the smaller
unchanged backbone plus Q4 sidecar, so neither should be published.

## Reproduction

- `bench/bench_qwen38_mtp_sku.py`: paired MMLU-Pro, GSM8K, HumanEval
- `bench/bench_qwen38_mtp_context.py`: controlled context/memory gate
- `bench/bench_qwen38_mtp_mmbench.py`: paired multimodal MMBench gate
- `bench/build_qwen38_mtplx_candidate.py`: rejected precision-allocation
  experiments

Server invocation:

```bash
rapid-mlx serve rapid-mlx/Qwen3.8-27B-mixed-3.5bpw-MLX \
  --speculative-config \
  '{"method":"mtp-fast","model":"mlx-community/Qwen3.8-27B-MTP-4bit","min_output_tokens":64}'
```
