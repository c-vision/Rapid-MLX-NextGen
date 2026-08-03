from scripts.progressive_context_soak import _extract_usage, repetition_period


def test_repetition_period_detects_exact_tail_loop():
    assert repetition_period("prefix" + "abcdef" * 3) == 6


def test_repetition_period_ignores_normal_text():
    assert repetition_period("a normal non-repeating model response") is None


def test_extract_usage_accepts_responses_completed_shape():
    assert _extract_usage(
        {"response": {"usage": {"input_tokens": 123, "output_tokens": 7}}}
    ) == (123, 7)


def test_extract_usage_accepts_chat_compat_names():
    assert _extract_usage({"usage": {"prompt_tokens": 9, "completion_tokens": 2}}) == (
        9,
        2,
    )
