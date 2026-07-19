# SPDX-License-Identifier: Apache-2.0
"""Offline tests for the grammar-constrained tool-calling builder (#558 PR-1).

These validate the grammar BUILDER and the ``ToolParser.structure_info()``
ABC contract WITHOUT a model or a decode loop. They exercise:

  * the non-breaking ABC default (``structure_info() -> None``);
  * ``build_tool_lark`` structural output (``<tool_call>`` trigger + a
    ``%json`` schema-constraint region);
  * grammar ENFORCEMENT via llguidance ``LLMatcher.validate_tokens`` — a
    well-formed hermes tool call is accepted in full while a hallucinated
    tool name, an off-schema argument, and a bad enum value are rejected
    mid-stream. This is the load-bearing #558 proof that the constraint is
    grammar-enforced, not merely post-parsed.

No routing, no scheduler, no ``GrammarLogitsProcessor`` (those are PR-3). The
per-family concrete overrides are PR-2; here we drive the builder with a
test-local hermes-style parser stub so PR-1 ships zero behavior change while
still proving the builder against a realistic hermes wire format.

The negative-control tests need a fast (Rust) tokenizer whose
``<tool_call>``/``</tool_call>`` are single special tokens — the pilot
verified this on ``mlx-community/Qwen3.5-4B-MLX-4bit``. Those tests skip ONLY
on genuine unavailability (llguidance extra absent, or the tokenizer neither
cached nor reachable); any other failure is surfaced, not swallowed. The
pure-Python ABC and Lark-structure tests never skip — they carry no optional
dependency and always run.
"""

import importlib.util

import pytest

# NOTE: llguidance is only needed by the grammar-BUILD and enforcement tests
# below (they compile a Lark grammar / build an LLTokenizer). The ABC-contract
# and pure-Lark-string tests need NOTHING optional, so we do NOT skip at module
# level — a repo without the [guided] extra still exercises the ABC change and
# the builder's string output. Tests that need llguidance guard themselves via
# ``_requires_llguidance``.
_HAS_LLGUIDANCE = importlib.util.find_spec("llguidance") is not None
_requires_llguidance = pytest.mark.skipif(
    not _HAS_LLGUIDANCE, reason="llguidance ([guided] extra) not installed"
)

_TOKENIZER_MODEL = "mlx-community/Qwen3.5-4B-MLX-4bit"
# Pin the revision so the enforcement proof runs against an IMMUTABLE artifact
# (codex: an unpinned Hub revision is a mutable third-party dependency). The
# tokenizer's <tool_call>/</tool_call> single-special-token layout is fixed at
# this commit; a different upstream revision must not silently change what the
# enforcement tests exercise.
_TOKENIZER_REVISION = "32f3e8ecf65426fc3306969496342d504bfa13f3"

TOOLS = [
    {
        "name": "get_weather",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string"},
                "unit": {"type": "string", "enum": ["c", "f"]},
            },
            "required": ["city"],
            "additionalProperties": False,
        },
    },
    {
        "name": "get_time",
        "parameters": {
            "type": "object",
            "properties": {"tz": {"type": "string"}},
            "required": ["tz"],
            "additionalProperties": False,
        },
    },
]


def _hermes_structure_info():
    """A hermes ``<tool_call>`` JSON-body wire triple, as PR-2 will ship it.

    Declared here (not on the concrete parser) so PR-1 leaves every shipped
    parser's behavior untouched while still exercising the builder against a
    realistic family. ``<tool_call>``/``</tool_call>`` are single special
    tokens in Qwen3/Hermes tokenizers, hence the ``sentinels`` entries.
    """
    from vllm_mlx.api.tool_grammar import StructureInfo

    def _info(name: str):
        return StructureInfo(
            begin=f'<tool_call>\n{{"name": "{name}", "arguments": ',
            end="}\n</tool_call>",
            trigger="<tool_call>",
            sentinels=("<tool_call>", "</tool_call>"),
        )

    return _info


class _HermesStubParser:
    """Minimal parser exposing only ``structure_info`` for builder tests."""

    def structure_info(self):
        return _hermes_structure_info()


# --------------------------------------------------------------------------
# ABC contract (pure Python, always runs).
# --------------------------------------------------------------------------
def test_abc_structure_info_defaults_to_none():
    # PR-1 non-breaking contract: a parser that does not override
    # ``structure_info`` returns None, so callers fall back to today's
    # free-form-then-parse behavior.
    from vllm_mlx.tool_parsers.abstract_tool_parser import ToolParser

    class _Dummy(ToolParser):
        def extract_tool_calls(self, model_output, request=None):  # noqa: D401
            raise NotImplementedError

    assert _Dummy(tokenizer=None).structure_info() is None


@_requires_llguidance
def test_build_tool_grammar_none_when_parser_opts_out():
    # A parser whose structure_info() returns None -> builder returns None
    # (free-form fallback), NOT a grammar. Requires llguidance so the opt-out
    # branch is reached rather than the ``HAS_LLGUIDANCE`` short-circuit
    # (which would make this pass for the wrong reason).
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    class _OptOut:
        def structure_info(self):
            return None

    assert build_tool_grammar(TOOLS, "required", _OptOut()) is None


@_requires_llguidance
def test_build_tool_grammar_none_on_empty_tools():
    # Empty tools -> None. Requires llguidance so the empty-tools guard is the
    # reason for None, not the availability short-circuit.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    assert build_tool_grammar([], "required", _HermesStubParser()) is None


@_requires_llguidance
def test_build_tool_grammar_none_for_tool_choice_none():
    # tool_choice="none" -> no grammar at all (design §4), never a forced call.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    assert build_tool_grammar(TOOLS, "none", _HermesStubParser()) is None


@_requires_llguidance
def test_build_tool_grammar_named_choice_narrows_to_requested_tool():
    # A NAMED tool_choice (a concrete function name) must constrain to ONLY
    # that tool even when the full multi-tool list is passed — the builder
    # narrows internally, so a named call can never emit a different tool.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "get_weather", _HermesStubParser())
    assert grammar is not None
    # Only the requested tool's tag survives — get_time is not reachable.
    assert "get_weather" in grammar
    assert "get_time" not in grammar
    # Single forced alternative (named => exactly one tag, forced).
    assert "start: (tag_0)+ tag_end" in grammar


@_requires_llguidance
def test_build_tool_grammar_named_choice_unknown_name_degrades():
    # An unknown named function degrades to free-form (None), not a crash.
    # Requires llguidance so execution reaches the named-choice narrowing
    # branch rather than returning None via the HAS_LLGUIDANCE short-circuit
    # (which would keep this green even if the named validation were deleted).
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    assert build_tool_grammar(TOOLS, "does_not_exist", _HermesStubParser()) is None


@_requires_llguidance
def test_build_tool_grammar_openai_request_shape_degrades_safely():
    # The builder's input contract is the NORMALIZED shape
    # ({"name","parameters"}). A raw OpenAI request-shaped tool
    # ({"type":"function","function":{...}}) has no top-level "name", so the
    # builder degrades to free-form (None) — safely, not a crash. Un-wrapping
    # request shapes is the PR-3 routing caller's job, not this builder's.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    openai_shaped = [
        {"type": "function", "function": {"name": "get_weather", "parameters": {}}}
    ]
    assert build_tool_grammar(openai_shaped, "required", _HermesStubParser()) is None


@_requires_llguidance
def test_build_tool_grammar_degrades_when_factory_raises():
    # A per-family structure_info() factory that raises on a tool name must
    # degrade to free-form (None), not crash the request.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    class _Raises:
        def structure_info(self):
            def _boom(name):
                raise RuntimeError("boom")

            return _boom

    assert build_tool_grammar(TOOLS, "required", _Raises()) is None


# --------------------------------------------------------------------------
# Lark structural output (pure Python, always runs).
# --------------------------------------------------------------------------
def test_lark_contains_trigger_and_schema_region():
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    lark = build_tool_lark(TOOLS, "required", infos)

    # The sentinels MUST be emitted as BARE special-token references (llguidance
    # renders a bare ``<name>`` as a special token), NOT as quoted byte-string
    # literals — a quoted ``"<tool_call>"`` would be a multi-byte string the
    # model's single ``<tool_call>`` token could never satisfy (the ground-truth
    # correction this PR ports). Assert the exact production shape.
    assert " <tool_call> " in lark  # space-delimited bare token ref
    assert lark.rstrip().endswith("</tool_call>")  # bare closing token ref
    assert '"<tool_call>"' not in lark  # NOT a quoted literal
    assert '"</tool_call>"' not in lark  # NOT a quoted literal
    # a %json schema-constraint region is present for the arguments object
    assert "%json" in lark
    # the concrete tool names are substituted into the begin bodies
    assert "get_weather" in lark
    assert "get_time" in lark


def test_lark_quantifier_tracks_tool_choice():
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    # auto -> may emit zero calls -> (...)*
    assert "start: (tag_0 | tag_1)* tag_end" in build_tool_lark(TOOLS, "auto", infos)
    # required (and any non-auto choice) -> at least one call -> (...)+
    assert "start: (tag_0 | tag_1)+ tag_end" in build_tool_lark(
        TOOLS, "required", infos
    )


def test_lark_single_call_forces_exactly_one_tag():
    # parallel_tool_calls=False -> single_call -> EXACTLY ONE call (no
    # quantifier). Overrides the ``required`` ``+`` so the grammar can't emit
    # multiple calls (codex #558-PR3 blocking).
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    lark = build_tool_lark(TOOLS, "required", infos, single_call=True)
    # No trailing repetition quantifier on the alternation -> exactly one tag.
    assert "start: (tag_0 | tag_1) tag_end" in lark
    assert "start: (tag_0 | tag_1)+ tag_end" not in lark
    assert "start: (tag_0 | tag_1)* tag_end" not in lark
    # single_call does not override auto's zero-or-more (auto never sets it, but
    # be explicit that auto stays ``*`` even if single_call were passed).
    assert "start: (tag_0 | tag_1)* tag_end" in build_tool_lark(
        TOOLS, "auto", infos, single_call=True
    )


def test_named_choice_narrows_to_single_forced_tag():
    # A NAMED tool_choice is expressed by the caller narrowing ``tools`` to the
    # single requested function before calling the builder (design §4). The
    # builder then emits exactly one forced tag — it never leaks the other
    # tools' alternatives into a named request.
    from vllm_mlx.api.tool_grammar import build_tool_lark

    only = [TOOLS[0]]  # caller pre-filtered to the requested function
    info = [_hermes_structure_info()(only[0]["name"])]
    lark = build_tool_lark(only, "get_weather", info)
    assert "start: (tag_0)+ tag_end" in lark
    assert "tag_1" not in lark  # no other tool's alternative present
    assert "get_time" not in lark


def test_text_trigger_is_rejected_at_build_time():
    # PR-1's guard against the auto-path fake-trigger risk (design §7 open-Q1;
    # full auto text-trigger handling is PR-5): the builder REFUSES to emit a
    # grammar whose trigger is a plain text (multi-token) string not declared
    # as a special-token sentinel — because the lazy ``TAG_TEXT`` prefix could
    # then swallow bytes that reassemble the trigger, producing an
    # unenforceable ``auto`` grammar. A special-token trigger cannot be
    # reassembled from ordinary token pieces, so we require one here.
    from vllm_mlx.api.tool_grammar import StructureInfo, build_tool_lark

    text_trigger = StructureInfo(
        begin="TOOL_CALL args:", end="", trigger="TOOL_CALL", sentinels=()
    )
    with pytest.raises(ValueError, match="sentinel"):
        build_tool_lark([TOOLS[0]], "auto", [text_trigger])


def test_build_tool_lark_rejects_bad_inputs():
    # Public-ish input validation raises ValueError (survives ``python -O``),
    # rather than asserting.
    from vllm_mlx.api.tool_grammar import StructureInfo, build_tool_lark

    good = _hermes_structure_info()("get_weather")
    with pytest.raises(ValueError):
        build_tool_lark([], "required", [])
    with pytest.raises(ValueError):
        # length mismatch
        build_tool_lark(TOOLS, "required", [good])
    with pytest.raises(ValueError):
        # tool_choice="none" must never build a grammar
        build_tool_lark([TOOLS[0]], "none", [good])
    with pytest.raises(ValueError):
        # begin does not start with trigger -> invariant violation
        bad = StructureInfo(
            begin="oops", end="", trigger="<tool_call>", sentinels=("<tool_call>",)
        )
        build_tool_lark([TOOLS[0]], "required", [bad])
    with pytest.raises(ValueError):
        # trigger not declared as a special-token sentinel -> rejected
        bad = StructureInfo(begin="<x>go", end="", trigger="<x>", sentinels=())
        build_tool_lark([TOOLS[0]], "required", [bad])
    with pytest.raises(ValueError):
        # empty trigger -> rejected (StructureInfo contract requires one)
        bad = StructureInfo(begin="anything", end="", trigger="", sentinels=())
        build_tool_lark([TOOLS[0]], "required", [bad])


def test_build_tool_lark_preserves_falsy_schemas():
    # A present-but-falsy JSON Schema ({} = allow-any, false = allow-none) is
    # meaningful and must be embedded verbatim, NOT replaced by the permissive
    # default (the ``... or default`` bug codex flagged).
    from vllm_mlx.api.tool_grammar import build_tool_lark

    info = _hermes_structure_info()("get_weather")
    tool_empty = {"name": "get_weather", "parameters": {}}
    lark = build_tool_lark([tool_empty], "required", [info])
    assert "%json {}" in lark  # empty schema preserved, not defaulted

    tool_false = {"name": "get_weather", "parameters": False}
    lark = build_tool_lark([tool_false], "required", [info])
    assert "%json false" in lark  # false schema preserved verbatim


def test_build_tool_lark_defaults_only_when_parameters_absent():
    from vllm_mlx.api.tool_grammar import build_tool_lark

    info = _hermes_structure_info()("get_weather")
    tool_missing = {"name": "get_weather"}  # no "parameters" key
    lark = build_tool_lark([tool_missing], "required", [info])
    # The default for an omitted schema is CLOSED — a no-parameter tool must
    # accept NO arguments (additionalProperties: false), not arbitrary keys.
    assert (
        '%json {"type": "object", "properties": {}, "additionalProperties": false}'
        in lark
    )


# --------------------------------------------------------------------------
# Grammar ENFORCEMENT via offline validate_tokens (the #558 proof).
#
# These need a fast (Rust) tokenizer whose <tool_call>/</tool_call> are single
# special tokens. The ONLY sanctioned skip is genuine tokenizer/llguidance
# UNAVAILABILITY (no network + not cached, or the optional extra absent) — any
# OTHER failure (a real grammar regression, a matcher error, an unexpected
# tokenizer exception) propagates and FAILS the test, so a green run of these
# tests always means enforcement was actually exercised.
# --------------------------------------------------------------------------
def _offline_skip_exc_types():
    """Only genuine network/cache-miss errors are a sanctioned skip.

    A corrupt tokenizer artifact, an invalid revision, or a
    tokenizer/config incompatibility must FAIL the enforcement test, not
    silently skip it (codex round-5 #2). So we skip ONLY on the specific
    huggingface_hub offline/cache-miss signals (and a raw connection error),
    letting every other exception — including generic ``OSError`` from a
    corrupt local file — propagate as a real failure.
    """
    types: list[type[BaseException]] = []
    try:
        from huggingface_hub.errors import (
            LocalEntryNotFoundError,
            OfflineModeIsEnabled,
        )

        types += [LocalEntryNotFoundError, OfflineModeIsEnabled]
    except Exception:  # pragma: no cover - old hub without these names
        pass
    try:
        from requests.exceptions import ConnectionError as _ReqConnErr

        types.append(_ReqConnErr)
    except Exception:  # pragma: no cover - requests not present
        pass
    return tuple(types) or (OSError,)


@pytest.fixture(scope="module")
def tok():
    transformers = pytest.importorskip("transformers")
    try:
        return transformers.AutoTokenizer.from_pretrained(
            _TOKENIZER_MODEL, revision=_TOKENIZER_REVISION
        )
    except _offline_skip_exc_types():  # pragma: no cover - offline & uncached
        pytest.skip(
            f"tokenizer {_TOKENIZER_MODEL}@{_TOKENIZER_REVISION[:8]} not "
            "cached and no network — enforcement tests require it"
        )


@pytest.fixture(scope="module")
def lltok(tok):
    """Build an llguidance LLTokenizer from the fast (Rust) tokenizer.

    Mirrors ``guided.py``'s tokenizer resolution: try the wrapper's inner
    fast tokenizer, then the object itself (transformers 5.x exposes a
    ``TokenizersBackend`` that IS the fast tokenizer llguidance wants). A
    slow tokenizer is the one sanctioned skip; a genuine ``from_tokenizer``
    regression is NOT swallowed — it fails the test.
    """
    import llguidance.hf as llg_hf

    candidates = []
    inner = getattr(tok, "_tokenizer", None)
    if inner is not None:
        candidates.append(inner)
    candidates.append(tok)
    fast_candidates = [
        c for c in candidates if getattr(c, "is_fast", True) is not False
    ]
    if not fast_candidates:
        pytest.skip("tokenizer is not a fast tokenizer — llguidance needs one")
    last_exc = None
    for cand in fast_candidates:
        try:
            return llg_hf.from_tokenizer(cand)
        except Exception as exc:  # noqa: BLE001 - re-raised below if all fail
            last_exc = exc
    # Every fast candidate raised — that is a real regression, not an
    # environment gap. Surface it rather than skipping.
    raise AssertionError(
        f"llguidance could not build an LLTokenizer from any fast candidate: "
        f"{last_exc!r}"
    )


def _consume(grammar, lltok, tok, text):
    """Offline enforcement probe. Returns ``(accepted, total, is_accepting)``.

    Advances real grammar state one token at a time via
    ``LLMatcher.consume_tokens`` (which returns a bool per batch), counting how
    many tokens the grammar actually accepts before it rejects one. Unlike
    ``validate_tokens`` this ADVANCES matcher state, so afterwards
    ``is_accepting()`` reports whether the grammar can TERMINATE there — a
    "fully accepted" positive test therefore proves the string is a COMPLETE
    valid derivation, not merely an accepted prefix of one.
    """
    from llguidance.mlx import LLMatcher

    ids = tok.encode(text, add_special_tokens=False)
    matcher = LLMatcher(lltok, grammar)
    assert not matcher.get_error(), matcher.get_error()
    accepted = 0
    for tid in ids:
        if not matcher.consume_tokens([tid]):
            break
        accepted += 1
    return accepted, len(ids), matcher.is_accepting()


@_requires_llguidance
def test_valid_hermes_call_is_accepted_and_terminates(tok, lltok):
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    assert grammar is not None
    accepted, total, accepting = _consume(
        grammar,
        lltok,
        tok,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>',
    )
    assert accepted == total, f"valid hermes call rejected ({accepted}/{total})"
    # Stronger than accepted-prefix: the complete call is a terminal state.
    assert accepting, "valid complete hermes call is not an accepting (terminal) state"


@_requires_llguidance
def test_valid_enum_value_is_accepted(tok, lltok):
    # Positive enum control (paired with the rejection test below): a VALID
    # enum value is accepted and terminates — so the rejection test cannot pass
    # merely because the grammar forbids the optional `unit` property entirely.
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    accepted, total, accepting = _consume(
        grammar,
        lltok,
        tok,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "P", "unit": "c"}}\n</tool_call>',
    )
    assert accepted == total, f"valid enum value rejected ({accepted}/{total})"
    assert accepting, "valid enum call is not an accepting (terminal) state"


@_requires_llguidance
def test_hallucinated_tool_name_is_rejected(tok, lltok):
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    accepted, total, _ = _consume(
        grammar, lltok, tok, '<tool_call>\n{"name": "get_stockquote'
    )
    assert accepted < total, "hallucinated tool name was NOT rejected by the grammar"


@_requires_llguidance
def test_off_schema_argument_is_rejected(tok, lltok):
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    # `city` must be a string; an integer must be forbidden.
    accepted, total, _ = _consume(
        grammar,
        lltok,
        tok,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": 4',
    )
    assert accepted < total, "off-schema integer argument was NOT rejected"


@_requires_llguidance
def test_bad_enum_value_is_rejected(tok, lltok):
    from vllm_mlx.api.tool_grammar import build_tool_grammar

    grammar = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    # `unit` enum is {c, f}; "kelvin" must be forbidden.
    accepted, total, _ = _consume(
        grammar,
        lltok,
        tok,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "P", "unit": "kelvin',
    )
    assert accepted < total, "invalid enum value was NOT rejected by the grammar"
