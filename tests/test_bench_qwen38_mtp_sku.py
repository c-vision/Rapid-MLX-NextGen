from __future__ import annotations

import importlib.util
from pathlib import Path

_SCRIPT = Path(__file__).parents[1] / "bench" / "bench_qwen38_mtp_sku.py"
_SPEC = importlib.util.spec_from_file_location("bench_qwen38_mtp_sku", _SCRIPT)
assert _SPEC is not None and _SPEC.loader is not None
bench = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(bench)


def test_extract_mmlu_letter_and_gsm_final_answer() -> None:
    assert bench._extract_answer("mmlu-pro", "B") == "B"
    assert bench._extract_answer("mmlu-pro", "Answer: I") == "I"
    assert bench._extract_answer("gsm8k", "work\nFINAL: $1,234") == "1234"
    assert bench._extract_answer("gsm8k", "work\nFINAL: -12.5") == "-12.5"


def test_render_gsm_normalizes_gold_commas() -> None:
    prompt, gold = bench._render_item(
        "gsm8k",
        {"question": "What is it?", "answer": "reasoning\n#### 1,234"},
    )
    assert "What is it?" in prompt
    assert gold == "1234"


def test_extract_python_prefers_fenced_completion() -> None:
    text = "analysis first\n```python\ndef answer():\n    return 42\n```"
    assert bench._extract_python(text) == "def answer():\n    return 42"


def test_humaneval_defaults_match_model_card_gate() -> None:
    assert bench._task_defaults("humaneval") == (40, 640)


def test_summary_reports_paired_flips_and_hashes() -> None:
    records = [
        {
            "ar": {
                "correct": True,
                "sha256": "same",
                "generation_tps": 10.0,
                "peak_memory_gb": 14.0,
            },
            "mtp": {
                "correct": True,
                "sha256": "same",
                "generation_tps": 16.0,
                "peak_memory_gb": 15.0,
            },
        },
        {
            "ar": {
                "correct": True,
                "sha256": "ar",
                "generation_tps": 12.0,
                "peak_memory_gb": 14.2,
            },
            "mtp": {
                "correct": False,
                "sha256": "mtp",
                "generation_tps": 18.0,
                "peak_memory_gb": 15.2,
            },
        },
    ]

    summary = bench._summarize(records)

    assert summary == {
        "samples": 2,
        "ar_correct": 2,
        "mtp_correct": 1,
        "ar_only_correct": 1,
        "mtp_only_correct": 0,
        "identical_completions": 1,
        "ar_mean_tps": 11.0,
        "mtp_mean_tps": 17.0,
        "max_peak_memory_gb": 15.2,
    }
