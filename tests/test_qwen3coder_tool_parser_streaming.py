# SPDX-License-Identifier: Apache-2.0
"""Incremental-delta streaming for ``Qwen3CoderToolParser``.

Closes the bug surfaced in #479 (kenizhou): the parser used to buffer the
entire string-typed parameter value until ``</parameter>`` arrived, then
dump it as a single ``function.arguments`` delta. CopilotKit / LangChain
inspectors that render argument values live stalled for multiple seconds
on long summaries / key-points.

The three tests below pin the new behavior:

* ``test_long_string_param_emits_multiple_deltas`` — granularity guard.
* ``test_close_tag_never_leaks_into_emitted_fragment`` — the
  ``len("</parameter>")`` tail-buffer guarantees no half-tag escapes
  into a JSON fragment.
* ``test_streaming_json_matches_non_streaming`` — concatenating all
  streamed argument fragments and parsing the result yields the same
  Python object as ``extract_tool_calls`` returns for the full text.
"""

from __future__ import annotations

import json

import pytest

from vllm_mlx.tool_parsers.qwen3coder_tool_parser import Qwen3CoderToolParser

_LONG_SUMMARY = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do "
    "eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut "
    "enim ad minim veniam, quis nostrud exercitation ullamco laboris "
    "nisi ut aliquip ex ea commodo consequat."
)


def _request_with_tool(name: str, properties: dict) -> dict:
    return {
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": name,
                    "parameters": {"type": "object", "properties": properties},
                },
            }
        ]
    }


def _feed(parser: Qwen3CoderToolParser, chunks: list[str], request: dict | None):
    """Stream ``chunks`` through the parser; return non-None delta dicts."""
    parser.reset()
    deltas: list[dict] = []
    previous = ""
    for chunk in chunks:
        if not chunk:
            continue
        current = previous + chunk
        delta = parser.extract_tool_calls_streaming(
            previous_text=previous,
            current_text=current,
            delta_text=chunk,
            request=request,
        )
        if delta is not None:
            deltas.append(delta)
        previous = current
    return deltas


def _argument_fragments(deltas: list[dict]) -> list[str]:
    """Flatten ``function.arguments`` strings out of streamed tool_call deltas."""
    out: list[str] = []
    for d in deltas:
        for tc in d.get("tool_calls") or []:
            fn = tc.get("function") or {}
            args = fn.get("arguments")
            if args:
                out.append(args)
    return out


def test_long_string_param_emits_multiple_deltas():
    """For a long string param, at least 2 ``function.arguments`` deltas with
    non-empty content must arrive BEFORE the ``</parameter>`` close.

    Without #479's incremental emit the parser only produced a single
    delta containing the whole value once the close tag arrived.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool(
        "summarize",
        {"summary": {"type": "string"}},
    )

    head = [
        "<tool_call>\n",
        "<function=summarize>\n",
        "<parameter=summary>\n",
    ]
    # Split the long summary into 32-char body chunks so the in-flight
    # branch fires several times before the close tag arrives.
    value_chunks = [_LONG_SUMMARY[i : i + 32] for i in range(0, len(_LONG_SUMMARY), 32)]
    pre_close_chunks = head + value_chunks

    parser.reset()
    deltas_before_close: list[dict] = []
    previous = ""
    for chunk in pre_close_chunks:
        current = previous + chunk
        d = parser.extract_tool_calls_streaming(
            previous_text=previous,
            current_text=current,
            delta_text=chunk,
            request=request,
        )
        if d is not None:
            deltas_before_close.append(d)
        previous = current

    arg_fragments = [
        f
        for f in _argument_fragments(deltas_before_close)
        # Skip the structural openers ("{", "") so we only count real
        # value-bearing fragments — those are what the UI renders live.
        if f not in ("{", "")
    ]

    assert len(arg_fragments) >= 2, (
        "#479 regression: long string params should stream incrementally; "
        f"got {len(arg_fragments)} value-bearing argument deltas before "
        f"</parameter>. fragments={arg_fragments!r}"
    )


def test_close_tag_never_leaks_into_emitted_fragment():
    """Feeding ``...value</par`` then ``ameter>`` across two chunks must
    never produce a ``function.arguments`` fragment containing the literal
    substring ``</par`` or ``</parameter>``.

    Guards the tail-buffer: the parser must hold back the last
    ``len("</parameter>")`` chars of unread tail so a partial close tag
    straddling a chunk boundary can't be flushed prematurely.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("echo", {"value": {"type": "string"}})

    # Long enough that incremental emission will fire before the close.
    value = "A" * 200
    # Split mid-close-tag (``</par`` | ``ameter>``) to exercise the
    # tail-buffer guard at a chunk boundary.
    chunks = [
        "<tool_call>\n",
        "<function=echo>\n",
        "<parameter=value>\n",
        value[:80],
        value[80:160],
        value[160:] + "\n</par",
        "ameter>\n",
        "</function>\n",
        "</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    fragments = _argument_fragments(deltas)
    for frag in fragments:
        assert "</par" not in frag, f"close-tag leaked into streamed fragment: {frag!r}"
        assert "</parameter>" not in frag, (
            f"close-tag leaked into streamed fragment: {frag!r}"
        )

    # Belt + braces: concatenate everything, parse the JSON, and assert
    # the decoded value is exactly the original — catches escaped /
    # split-across-fragments leaks that a substring scan alone would miss.
    combined = "".join(fragments)
    decoded = json.loads(combined)
    assert decoded == {"value": value}, (
        f"streamed args decoded to {decoded!r}, expected {{'value': {value!r}}}"
    )


def test_json_encoded_string_preserves_embedded_xml_closers():
    """The constrained #1542 wire must keep every XML marker as string data."""
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write", {"content": {"type": "string"}})
    value = 'before </parameter> </function> </tool_call> after "quoted"'
    encoded = json.dumps(value, ensure_ascii=False)
    chunks = [
        "<tool_call>\n",
        "<function=write>\n",
        "<parameter=content>\n",
        encoded[:17],
        encoded[17:38],
        encoded[38:] + "\n</parameter>\n",
        "</function>\n",
        "</tool_call>",
    ]

    fragments = _argument_fragments(_feed(parser, chunks, request))
    assert json.loads("".join(fragments)) == {"content": value}


@pytest.mark.parametrize(
    "value",
    [
        "A tool call block ends with </tool_call> on its own.",
        "A parameter block ends with </parameter> here.",
        "A function block ends with </function> here.",
        (
            "Parameter </parameter>, function </function>, and tool "
            "</tool_call> are all payload."
        ),
    ],
)
@pytest.mark.parametrize("chunking", ["after-marker", "one-byte"])
def test_legacy_raw_string_preserves_embedded_xml_closers(value: str, chunking: str):
    """#1515: an early closer in a raw string is payload, not structure."""
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    marker = next(
        token
        for token in ("</tool_call>", "</parameter>", "</function>")
        if token in value
    )
    cut = value.index(marker) + len(marker)
    value_chunks = (
        [value[:cut], value[cut:] + "\n"]
        if chunking == "after-marker"
        else [*value, "\n"]
    )
    chunks = [
        "<tool_call>\n",
        "<function=write_file>\n",
        "<parameter=content>\n",
        *value_chunks,
        "</parameter>\n",
        "</function>\n",
        "</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": value}
    assert "".join(delta.get("content", "") for delta in deltas) == ""


def test_one_character_raw_string_round_trips():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    chunks = [
        "<tool_call>\n<function=write_file>\n<parameter=content>\n",
        "x",
        "\n</parameter>\n</function>\n</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": "x"}


def test_wrapped_raw_call_recovers_when_outer_close_is_truncated():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    chunks = [
        "<tool_call>\n<function=write_file>\n<parameter=content>\nhello",
        "\n</parameter>\n",
        "</function>",
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": "hello"}


@pytest.mark.parametrize(
    "wrapper_chunks",
    [
        pytest.param(["</tool_call>"[:cut], "</tool_call>"[cut:]], id=f"cut-{cut}")
        for cut in range(1, len("</tool_call>"))
    ]
    + [pytest.param(list("</tool_call>"), id="one-byte")],
)
def test_trailing_wrapper_never_leaks_across_chunk_boundaries(wrapper_chunks):
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    chunks = [
        "<tool_call>\n",
        "<function=write_file>\n",
        "<parameter=content>\nhello\n</parameter>\n",
        "</function>\n",
        *wrapper_chunks,
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": "hello"}
    assert "".join(delta.get("content", "") for delta in deltas) == ""


@pytest.mark.parametrize(
    "wrapper_chunks",
    [
        ["</tool_call>after"],
        ["</tool_", "call>after"],
        [*"</tool_call>", "after"],
        ["</tool_call> \n", "after"],
    ],
)
def test_content_after_trailing_wrapper_is_preserved(wrapper_chunks):
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    chunks = [
        "<tool_call>\n",
        "<function=write_file>\n",
        "<parameter=content>\nhello\n</parameter>\n",
        "</function>\n",
        *wrapper_chunks,
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": "hello"}
    expected = " \nafter" if wrapper_chunks[0].endswith(" \n") else "after"
    assert "".join(delta.get("content", "") for delta in deltas) == expected


def test_raw_second_parameter_uses_last_function_closer():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool(
        "write_file",
        {"path": {"type": "string"}, "content": {"type": "string"}},
    )
    value = "payload </parameter> then </function> still payload"
    chunks = [
        "<tool_call>\n<function=write_file>\n",
        '<parameter=path>\n"a.md"\n</parameter>\n',
        "<parameter=content>\n",
        *value,
        "\n</parameter>\n</function>\n</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {
        "path": "a.md",
        "content": value,
    }


def test_bare_raw_call_uses_last_function_closer():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    value = "payload </parameter> then </function> still payload"
    chunks = [
        "<function=write_file>\n<parameter=content>\n",
        *value,
        "\n</parameter>\n",
        "</function>",
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": value}
    assert "".join(delta.get("content", "") for delta in deltas) == ""


def test_raw_call_does_not_consume_a_later_call():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    first = (
        "<tool_call>\n<function=write_file>\n<parameter=content>first\n"
        "</parameter>\n</function>\n</tool_call>"
    )
    second = (
        "<tool_call>\n<function=write_file>\n<parameter=content>second\n"
        "</parameter>\n</function>\n</tool_call>"
    )

    deltas = _feed(
        parser,
        ["<tool_call>", first[len("<tool_call>") :] + second, "\n", "\n"],
        request,
    )
    argument_documents = [
        tc["function"]["arguments"]
        for delta in deltas
        for tc in delta.get("tool_calls", [])
        if tc.get("function", {}).get("arguments") not in (None, "", "{", "}")
    ]
    assert [json.loads(document) for document in argument_documents] == [
        {"content": "first"},
        {"content": "second"},
    ]
    streamed_content = "".join(delta.get("content", "") for delta in deltas)
    assert "<tool_call>" not in streamed_content
    assert "<function=" not in streamed_content


def test_consecutive_bare_raw_calls_remain_tool_calls():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    first = "<function=write_file>\n<parameter=content>first\n</parameter>\n</function>"
    second = (
        "<function=write_file>\n<parameter=content>second\n</parameter>\n</function>"
    )

    deltas = _feed(parser, [first + second, "\n", "\n"], request)
    argument_documents = [
        tc["function"]["arguments"]
        for delta in deltas
        for tc in delta.get("tool_calls", [])
        if tc.get("function", {}).get("arguments") not in (None, "", "{", "}")
    ]
    assert [json.loads(document) for document in argument_documents] == [
        {"content": "first"},
        {"content": "second"},
    ]
    streamed_content = "".join(delta.get("content", "") for delta in deltas)
    assert "<function=" not in streamed_content


def test_content_closer_after_raw_call_is_not_used_as_wrapper():
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write_file", {"content": {"type": "string"}})
    chunks = [
        "<tool_call>\n<function=write_file>\n<parameter=content>hello\n</parameter>\n"
        "</function>\n</tool_call>after </tool_call> prose"
    ]

    deltas = _feed(parser, chunks, request)
    assert json.loads("".join(_argument_fragments(deltas))) == {"content": "hello"}
    assert "".join(delta.get("content", "") for delta in deltas) == (
        "after </tool_call> prose"
    )


@pytest.mark.parametrize(
    ("tool_name", "param_name", "value"),
    [
        (
            "read_file",
            "path",
            "/tmp/.hermes-read-0123456789abcdef0123456789abcdef.txt",
        ),
        ("browse", "url", "https://example.com"),
    ],
)
def test_json_string_after_split_formatting_space_drops_wrapper_quotes(
    tool_name: str, param_name: str, value: str
):
    """Formatting whitespace arriving before a JSON quote stays wire-only.

    Real Qwen3.6 streams can split ``<parameter>\n \"value\"`` after the
    space.  The parser must not enter legacy raw-string streaming at that
    boundary and turn the JSON wrapper quotes into literal argument bytes.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool(tool_name, {param_name: {"type": "string"}})
    encoded = json.dumps(value)
    chunks = [
        "<tool_call>\n",
        f"<function={tool_name}>\n",
        f"<parameter={param_name}>\n ",
        encoded[:16],
        encoded[16:] + "\n</parameter>\n",
        "</function>\n",
        "</tool_call>",
    ]

    fragments = _argument_fragments(_feed(parser, chunks, request))
    assert json.loads("".join(fragments)) == {param_name: value}


def test_streaming_json_matches_non_streaming():
    """Concatenating all streamed ``function.arguments`` fragments and
    ``json.loads``-ing the result must equal the arguments dict
    ``extract_tool_calls`` returns for the same complete input.

    Covers mixed param types — string (mid-flight emit), int (buffered
    emit), and a second short string (back-to-back string).
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool(
        "report",
        {
            "summary": {"type": "string"},
            "score": {"type": "integer"},
            "owner": {"type": "string"},
        },
    )

    full_text = (
        "<tool_call>\n"
        "<function=report>\n"
        f"<parameter=summary>\n{_LONG_SUMMARY}\n</parameter>\n"
        "<parameter=score>\n42\n</parameter>\n"
        "<parameter=owner>\nken\n</parameter>\n"
        "</function>\n"
        "</tool_call>"
    )

    # Non-streaming reference
    ns_result = parser.extract_tool_calls(full_text, request=request)
    assert ns_result.tools_called, "non-stream extract should detect tool call"
    expected_args = json.loads(ns_result.tool_calls[0]["arguments"])

    # Streaming run with small body chunks so the in-flight emit fires
    # repeatedly and back-to-back string params exercise param-separator
    # logic in ``_close_string_increment``.
    chunks = [
        "<tool_call>\n",
        "<function=report>\n",
        "<parameter=summary>\n",
    ]
    summary_body = _LONG_SUMMARY + "\n"
    chunks.extend(summary_body[i : i + 24] for i in range(0, len(summary_body), 24))
    chunks.extend(
        [
            "</parameter>\n",
            "<parameter=score>\n42\n</parameter>\n",
            "<parameter=owner>\nken\n</parameter>\n",
            "</function>\n",
            "</tool_call>",
        ]
    )
    deltas = _feed(parser, chunks, request)
    fragments = _argument_fragments(deltas)
    combined = "".join(fragments)

    streamed_args = json.loads(combined)
    assert streamed_args == expected_args, (
        f"streamed JSON does not match non-streamed JSON.\n"
        f"  combined raw    = {combined!r}\n"
        f"  streamed parsed = {streamed_args!r}\n"
        f"  expected        = {expected_args!r}"
    )


def test_same_chunk_close_and_trailing_param_not_dropped():
    """When one chunk batches ``...tail</parameter><parameter=other>val</parameter>``
    the parser must emit BOTH the closing tail of the in-flight string
    AND the complete trailing param in the same call — and finalize.

    Without resuming the complete-param loop after closing the in-flight
    string, the trailing ``other`` param would be silently dropped (a
    regression caught by adversarial review on PR #648).
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool(
        "report",
        {
            "summary": {"type": "string"},
            "score": {"type": "integer"},
        },
    )

    # Multi-chunk stream where the FINAL chunk batches
    # ``<rest_of_summary></parameter><parameter=score>42</parameter></function></tool_call>``
    # so the in-flight close and the trailing complete param land in
    # the same parser call.
    head_value = _LONG_SUMMARY[:120]
    tail_value = _LONG_SUMMARY[120:]
    chunks = [
        "<tool_call>\n",
        "<function=report>\n",
        "<parameter=summary>\n",
        head_value,
        tail_value
        + "\n</parameter>\n<parameter=score>\n42\n</parameter>\n</function>\n</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    fragments = _argument_fragments(deltas)
    combined = "".join(fragments)
    # Must be valid JSON exactly as emitted — when the final chunk batches
    # the close + trailing param + ``</function>``, the parser is required
    # to fold the closing ``}`` into the same delta so consumers get a
    # self-contained document, not a half-open one that needs a follow-up
    # call that may never arrive (max_tokens truncation, stream cancel).
    decoded = json.loads(combined)
    assert decoded == {"summary": _LONG_SUMMARY, "score": 42}, (
        f"trailing param dropped on same-chunk close. decoded={decoded!r}"
    )


def test_truncated_tool_call_closes_in_flight_string_at_tool_call_end():
    """If the model truncates without ``</parameter>`` but reaches
    ``</tool_call>``, the in-flight string must still finalize — not hang
    with ``in_param=True``.

    Mirrors the existing complete-param fallback that already treats
    ``</tool_call>`` as a defensive close boundary.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("echo", {"value": {"type": "string"}})

    # Multi-chunk feed: first chunks open the in-flight string; the final
    # chunk arrives with ``</tool_call>`` directly, NO </parameter> and NO
    # </function> at all (a malformed / truncated stream).
    value_head = "A" * 80
    value_tail = "B" * 80
    chunks = [
        "<tool_call>\n",
        "<function=echo>\n",
        "<parameter=value>\n",
        value_head,
        value_tail + "\n</tool_call>",
    ]

    deltas = _feed(parser, chunks, request)
    fragments = _argument_fragments(deltas)
    assert fragments, "no fragments emitted — parser hung in incremental mode"
    # We don't require the truncated stream to produce strictly-valid JSON
    # (the original buffered path also doesn't close ``}`` here); but the
    # parser MUST have closed the string and emitted the buffered value.
    assert any('"value"' in f for f in fragments), (
        f"in-flight string never closed; fragments={fragments!r}"
    )
    assert not parser.in_param, (
        "parser left in_param=True after </tool_call> truncation"
    )


@pytest.mark.parametrize(
    "param_type",
    ["string", "str", "text", "enum"],
)
def test_string_aliases_all_stream_incrementally(param_type):
    """Schema ``type`` aliases that the parser treats as strings (per
    ``_convert_param_value``) must all trigger incremental emission.
    Prevents drift if the alias set changes.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("echo", {"value": {"type": param_type}})
    head = [
        "<tool_call>\n",
        "<function=echo>\n",
        "<parameter=value>\n",
    ]
    value_chunks = [_LONG_SUMMARY[i : i + 32] for i in range(0, len(_LONG_SUMMARY), 32)]
    pre_close_chunks = head + value_chunks

    parser.reset()
    deltas: list[dict] = []
    previous = ""
    for chunk in pre_close_chunks:
        current = previous + chunk
        d = parser.extract_tool_calls_streaming(
            previous_text=previous,
            current_text=current,
            delta_text=chunk,
            request=request,
        )
        if d is not None:
            deltas.append(d)
        previous = current

    value_frags = [f for f in _argument_fragments(deltas) if f not in ("{", "")]
    assert len(value_frags) >= 2, (
        f"type={param_type!r}: expected incremental emission, got "
        f"{len(value_frags)} value-bearing fragments"
    )


# ``(value, ensure_ascii settings worth running)``. Escaping is what this
# exercises, so a value is only run under both settings when the two produce
# different wires — for pure ASCII they are byte-identical and the second run
# would assert nothing the first did not.
_QUOTE_FIDELITY_VALUES = [
    # the shape #1600 fixes — controls that must come out clean
    ("https://example.com", (False,)),
    ("https://example.com/a-b.c?q=1&r=2", (False,)),
    ("/tmp/.hermes-read-0123456789abcdef0123456789abcdef.txt", (False,)),
    # the mirror risk: content that GENUINELY carries the quotes
    ('"hello world"', (False,)),
    ('"opening only', (False,)),
    ('closing only"', (False,)),
    ('""', (False,)),
    ('"</parameter> inside"', (False,)),
    ('"trailing backslash \\"', (False,)),
    # non-ASCII: the two settings differ, and with escaping on the mid-value
    # cut lands inside a \uXXXX sequence
    ('"天气预报 北京"', (True, False)),
]


def _quote_fidelity_cases():
    for value, ascii_modes in _QUOTE_FIDELITY_VALUES:
        for ensure_ascii in ascii_modes:
            for cut in ("mid-value", "before-closing-quote"):
                for lead in ("", " ", "\n "):
                    yield pytest.param(value, ensure_ascii, cut, lead)


@pytest.mark.parametrize(
    ("value", "ensure_ascii", "cut", "lead"), _quote_fidelity_cases()
)
def test_wrapper_quotes_dropped_without_eating_real_quotes(
    value: str, ensure_ascii: bool, cut: str, lead: str
):
    """Dropping the JSON wrapper quotes must not drop the value's own.

    #1600 stops the wrapper quotes reaching the caller when formatting
    whitespace splits the chunk before the opening quote. The failure mode
    on the other side is a value whose real first and last bytes are ``"``
    losing them as well — indistinguishable from the wrapper to anything
    that strips by position rather than by JSON structure.

    A live model cannot settle this: asked for a quoted phrase it usually
    just omits the quotes. Drive the parser instead, and require the
    streamed fragments to agree with non-streaming on the same wire.

    Two body splits per value, because they ask different questions.
    ``mid-value`` lands inside the content — inside a ``\\uXXXX`` escape for
    the CJK case with ``ensure_ascii`` on, which is a shape real token
    boundaries produce. ``before-closing-quote`` puts the wrapper's closing
    quote alone in its own chunk, which is where a positional strip would
    take the value's own trailing quote with it.
    """
    parser = Qwen3CoderToolParser(tokenizer=None)
    request = _request_with_tool("write", {"content": {"type": "string"}})
    encoded = json.dumps(value, ensure_ascii=ensure_ascii)
    at = len(encoded) // 2 if cut == "mid-value" else len(encoded) - 1
    chunks = [
        "<tool_call>\n",
        "<function=write>\n",
        f"<parameter=content>\n{lead}",
        encoded[:at],
        encoded[at:] + "\n</parameter>\n",
        "</function>\n",
        "</tool_call>",
    ]

    streamed = json.loads("".join(_argument_fragments(_feed(parser, chunks, request))))
    assert streamed == {"content": value}

    parser.reset()
    non_streaming = parser.extract_tool_calls("".join(chunks), request=request)
    assert non_streaming.tools_called
    assert json.loads(non_streaming.tool_calls[0]["arguments"]) == {"content": value}
