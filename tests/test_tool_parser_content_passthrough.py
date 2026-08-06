# SPDX-License-Identifier: Apache-2.0
"""Cross-parser invariant: no extraction => content is returned uncut.

Every ``ToolParser.extract_tool_calls`` implementation has the same
contract on the miss path. When it reports ``tools_called=False`` it has
decided the text was NOT a tool call, so it has no licence to have
rewritten that text — the caller will surface it to the user verbatim.

``qwen3_coder_xml`` violated this: its candidate scanner matches
``<function=(.*)$`` to end-of-string, so any answer merely *mentioning*
``<function=`` was cut at that point even though the candidate was then
rejected and ``tools_called`` came back ``False``. It is the parser for
22 aliases including ``qwen3.6-35b-4bit`` and every Qwen3-Coder build,
so that is the default path for local coding agents.

The tool-extraction path also runs when the request declared no tools at
all (``vllm_mlx/service/helpers.py`` does not gate on ``request.tools``),
which is why these cases pass ``request=None`` — a plain chat turn must
not be able to lose text to the tool layer.
"""

import pytest

from vllm_mlx.tool_parsers.abstract_tool_parser import ToolParserManager

# Registered parser names, one per wire family. Aliases of the same class
# are intentionally omitted — the invariant is per implementation.
PARSERS = [
    "hermes",
    "qwen3_coder_xml",
    "qwen",
    "glm47",
    "minimax",
    "harmony",
    "mistral",
    "llama",
    "deepseek_v3",
    "deepseek_v31",
    "deepseek_v4_0731",
    "kimi",
    "seed_oss",
    "gemma4",
    "nemotron",
    "granite",
    "minicpm",
    "functionary",
    "xlam",
    "lfm",
    "hy_v3",
    "auto",
]

# Ordinary assistant prose that happens to name tool-wire tokens. This is
# exactly what a coding agent produces when asked about the tool-calling
# protocol, or when writing tests/docs for a parser.
PROSE = [
    "A tool call block ends with </tool_call> on its own.",
    "The marker is <function=f> here.",
    "Docs mention </tool_call> and <function=name> together.",
    "Use <parameter=path> for the path argument.",
    "Close the invoke with </invoke> and the arg with </arg_value>.",
    'The value was "quoted" and also 中文引号"用户关注数".',
    "Plain prose, nothing special at all.",
]


@pytest.mark.parametrize("parser_name", PARSERS)
@pytest.mark.parametrize("text", PROSE)
def test_miss_path_returns_content_uncut(parser_name, text):
    parser = ToolParserManager.get_tool_parser(parser_name)(None)
    parser.reset()
    result = parser.extract_tool_calls(text, None)

    if result.tools_called:
        pytest.skip(
            f"{parser_name} claims a tool call in this prose — a different "
            f"bug, not the content-passthrough invariant"
        )

    assert result.content == text, (
        f"{parser_name} rewrote content on the miss path: "
        f"{text!r} -> {result.content!r}"
    )


def test_qwen3coder_regression_bare_function_mention():
    """The exact measured regression, pinned on its own.

    ``<function=`` in prose used to truncate the answer at that offset
    because the candidate span matched to end-of-string and was then
    rejected.
    """
    parser = ToolParserManager.get_tool_parser("qwen3_coder_xml")(None)
    text = "Docs mention </tool_call> and <function=name> together."
    result = parser.extract_tool_calls(text, None)
    assert result.tools_called is False
    assert result.content == text
    assert not result.content.endswith("and ")


def test_qwen3coder_still_parses_a_real_call():
    """The fix must not cost the parser its actual job."""
    parser = ToolParserManager.get_tool_parser("qwen3_coder_xml")(None)
    wire = (
        "<tool_call>\n<function=read_file>\n"
        "<parameter=path>\nsrc/main.py\n</parameter>\n"
        "</function>\n</tool_call>"
    )
    tools = [
        {
            "type": "function",
            "function": {
                "name": "read_file",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                },
            },
        }
    ]
    result = parser.extract_tool_calls(wire, {"tools": tools})
    assert result.tools_called is True
    assert result.tool_calls[0]["name"] == "read_file"
