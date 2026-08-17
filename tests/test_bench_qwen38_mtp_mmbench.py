from bench.bench_qwen38_mtp_mmbench import _answer, _summary


def test_answer_uses_post_thinking_option() -> None:
    assert _answer("A maybe</think>final B") == "B"
    assert _answer("no option") is None


def test_summary_reports_paired_flips_and_speedup() -> None:
    records = [
        {
            "index": 1,
            "mode": "ar",
            "correct": True,
            "generation_tps": 10.0,
            "sha256": "same",
        },
        {
            "index": 1,
            "mode": "mtp",
            "correct": True,
            "generation_tps": 15.0,
            "sha256": "same",
        },
        {
            "index": 2,
            "mode": "ar",
            "correct": False,
            "generation_tps": 10.0,
            "sha256": "ar",
        },
        {
            "index": 2,
            "mode": "mtp",
            "correct": True,
            "generation_tps": 15.0,
            "sha256": "mtp",
        },
    ]

    summary = _summary(records)

    assert summary["ar"]["accuracy"] == 0.5
    assert summary["mtp"]["accuracy"] == 1.0
    assert summary["paired"]["mtp_only_correct"] == 1
    assert summary["paired"]["ar_only_correct"] == 0
    assert summary["paired"]["identical_outputs"] == 1
    assert summary["speedup"] == 1.5
