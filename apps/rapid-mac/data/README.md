# Benchmark ground truth

`benchmark-ground-truth.json` is the collected, fully-sourced set of
**published** benchmark numbers for every model alias the app ships.
It is the upstream source-of-truth that
`Sources/Rapid/Resources/benchmark-scores.json` (the picker-tooltip
sidecar) is reconciled against.

## What it is

Published numbers only — scraped from official model cards, technical
reports, and recognised leaderboards. **We do not self-run evals**, and
we never fabricate a number to fill a gap. Every cell carries:

- `benchmark` — the exact benchmark + version actually found
  (e.g. `LiveCodeBench v6`, `BFCL-V4`, `SWE-bench Verified`)
- `metric`, `scale`
- `source_type` — `official_card` | `paper` | `leaderboard` | `third_party`
- `source_url`
- `confidence` — `high` | `med` | `low`
  - `med` is the default for post-cutoff model cards read via fetch
  - `low` flags shaky reads (e.g. numbers transcribed from a chart
    image, or community/third-party figures with unverified scaffolding)
- `notes` — caveats (variant, window, fallback used)
- `score` — `null` when no credible published number exists

## Axes

| axis | primary benchmark | fallback |
|------|-------------------|----------|
| `general_reasoning` | MMLU-Pro | GPQA-Diamond, then MMLU |
| `code` | LiveCodeBench v6 | HumanEval / SWE-bench Verified |
| `tool` | BFCL | tau-bench family (tau-bench / Tau2 / TAU3) |
| `ifeval` | IFEval | — |

> **Code-axis comparability caveat (issue #468).** No single coding
> benchmark is published for all 22 models: the Qwen3.5/3.6/VL + Gemma
> families report LiveCodeBench, while the coders (Devstral, Qwen3-Coder,
> DeepSeek-Coder) and several base models only publish HumanEval or
> SWE-bench. These are **not** directly comparable on one 0–100 scale
> (HumanEval is far easier than LiveCodeBench). The per-row
> `code_source` records which benchmark each number came from. A truly
> comparable code column would require running one harness across all
> models in-house — explicitly out of scope for this published-data
> pipeline.

## How `benchmark-scores.json` was reconciled (2026-06-30, conservative policy)

37 cell changes total:

1. **FILL** (22 cells) — where the shipping value was `null` and ground
   truth has a `high`/`med`-confidence number, fill it (Llama-3.x, the
   Qwen3-VL trio's reasoning, the Qwen3.5-122B flagships, gpt-oss
   tool/ifeval, the Gemma-4 MoE/dense tool scores, …).
2. **FIX** (8 cells) — two mismaps had every axis replaced:
   - `qwen3.5-4b-4bit` was carrying **Qwen3-4B-Instruct-2507** numbers.
   - `gemma-4-12b-4bit` was a **Gemma-3-12B floor placeholder** (its
     IFEval becomes an honest gap — Gemma 4 12B publishes none).
3. **NULLIFY** (5 cells) — the no-fabrication rule **overrides** PRESERVE
   for cells the ground truth proves are unpublished: a borrowed
   base-model number or an unsourced value is removed in favour of an
   honest gap. `qwen3-coder-30b-4bit` reasoning/IFEval (borrowed from the
   base Qwen3-30B-A3B general model), `devstral-v2-24b-4bit`
   reasoning/IFEval (not on the 2512 card), `gemma3-1b-qat-4bit` code
   (no coding eval published). Each carries a `*_null_reason`.
4. **PRESERVE** — every other existing non-null value is left untouched,
   so a comparable LiveCodeBench code score is never swapped for an
   easier HumanEval one. (PRESERVE protects *comparability*, not
   *fabrications* — those are handled by NULLIFY above.)
5. **HOLD** — `low`-confidence ground-truth values (chiefly the
   Qwen3-VL chart-image reads) are not filled; the cell stays `null`.
6. **SOURCE-CANON** (2 cells) — pre-existing decorated
   `general_reasoning_source` strings (gpt-oss, qwen3.6-35b-8bit) are
   canonicalized; the qualifier moves to `general_reasoning_note`.
7. `speed_tps` is locally measured and out of scope — untouched.

`general_reasoning` follows the spec-locked merge:
`mean(mmlu_pro, gpqa_diamond)` when both are present, otherwise the
single available bench. The full source URL + confidence for a filled
reasoning cell lives in `general_reasoning_provenance` (the loader's
strict `general_reasoning_source` string stays one of
`mean(mmlu_pro, gpqa_diamond)` / `mmlu_pro only` / `gpqa_diamond only`).
