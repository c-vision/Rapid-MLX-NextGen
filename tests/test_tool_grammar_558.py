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


# --------------------------------------------------------------------------
# PR-4: reasoning-tolerant grammar (path A). A REASONING model emits a
# ``<think>...</think>`` block BEFORE the tool call. The bare ``TAG_TEXT``
# byte-regex free prefix from PR-3 CANNOT match a ``<think>`` special token, so
# path A collapses (the matcher rejects the first ``<think>`` token). PR-4
# enumerates the reasoning-boundary special tokens as RULE-level special-token
# refs in the free prefix so the grammar admits reasoning, THEN enforces the
# tool-call schema. These tests prove:
#   * the reasoning-tolerant Lark has the prefix/rtok rules (structure);
#   * the non-reasoning grammar is byte-identical to PR-3 (no regression);
#   * a ``<think>...</think>`` prefix + valid call is ACCEPTED end-to-end;
#   * a non-reasoning call STILL works under the reasoning-tolerant grammar;
#   * a schema-violating token AFTER reasoning is still MASKED (negative ctrl).
# The pure-string structure tests always run; the enforcement tests reuse the
# single-special-token ``tok``/``lltok`` fixtures above.
# --------------------------------------------------------------------------
_REASONING_SENTINELS = ("<think>", "</think>")


def test_reasoning_prefix_lark_has_balanced_block_rules():
    """With a reasoning (open, close) pair the free prefix splits into a one-time
    ``lead: opened? bal_prefix`` (single optional prefilled-close) and a
    BALANCED-only ``bal_prefix: TAG_TEXT (reasoning_block TAG_TEXT)*`` reused by
    every tag / tag_end — a BALANCED, PREFILL-tolerant, globally-at-most-one
    rule-level block, not an unordered alternation (codex #558-PR4 round-5)."""
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    lark = build_tool_lark(
        TOOLS, "required", infos, reasoning_sentinels=_REASONING_SENTINELS
    )
    # ``start`` consumes the one-time ``lead`` before the calls. ``lead`` permits
    # a SINGLE optional leading close (``opened?``) modelling a prompt-prefilled
    # ``<think>``, then a BALANCED-only ``bal_prefix`` — NOT the unordered
    # ``<think> | </think>`` alternation (which accepted an unclosed opener).
    assert "start: lead (tag_0 | tag_1)+ tag_end" in lark
    assert "lead: opened? bal_prefix" in lark
    assert "opened: TAG_TEXT </think>" in lark
    assert "bal_prefix: TAG_TEXT (reasoning_block TAG_TEXT)*" in lark
    assert "reasoning_block: <think> TAG_TEXT </think>" in lark
    assert "rtok:" not in lark  # the old unordered alternation is gone
    # Reasoning refs are bare token references, NOT quoted byte literals.
    assert '"<think>"' not in lark
    assert '"</think>"' not in lark
    # Every tag body and the trailing tag_end consume the BALANCED-ONLY
    # ``bal_prefix`` (the one-time prefilled-close tolerance lives ONLY in
    # ``lead``, so a stray close before a later call / after the final call is
    # rejected — globally at-most-one).
    assert "tag_end: bal_prefix" in lark
    assert "tag_0: bal_prefix <tool_call>" in lark
    # ``opened?`` must NOT be reused per-tag (that would allow a stray leading
    # close at every call position — codex round-5 blocking).
    assert "tag_0: prefix" not in lark
    assert "tag_0: lead" not in lark
    assert "tag_0: opened" not in lark


# The exact grammar PR-3 emits for ``TOOLS`` at ``tool_choice="required"``. This
# is a CHECKED-IN GOLDEN captured from the pre-PR-4 builder — comparing against
# it (not against another call of the same implementation) proves the
# non-reasoning path is byte-identical to PR-3 even if the whole builder drifted
# (codex #558-PR4 blocking: default==explicit_empty only proves the two paths
# agree, not that either matches PR-3).
_PR3_GOLDEN_LARK = (
    "%llguidance {}\n"
    "start: (tag_0 | tag_1)+ tag_end\n"
    "tag_end: TAG_TEXT\n"
    "TAG_TEXT: /(.|\\n)*/\n"
    "\n"
    'tag_0: TAG_TEXT <tool_call> "\\n{\\"name\\": \\"get_weather\\", '
    '\\"arguments\\": " %json {"type": "object", "properties": {"city": '
    '{"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}}, '
    '"required": ["city"], "additionalProperties": false} "}\\n" </tool_call>\n'
    "\n"
    'tag_1: TAG_TEXT <tool_call> "\\n{\\"name\\": \\"get_time\\", '
    '\\"arguments\\": " %json {"type": "object", "properties": {"tz": '
    '{"type": "string"}}, "required": ["tz"], "additionalProperties": false} '
    '"}\\n" </tool_call>\n'
)


def test_non_reasoning_lark_is_unchanged_from_pr3():
    """Empty reasoning_sentinels reproduces the PR-3 grammar BYTE-FOR-BYTE — the
    non-reasoning path carries ZERO regression. Asserts against a checked-in
    PR-3 golden (not another call of the same code), so a shared regression in
    both call paths cannot hide behind ``default == explicit_empty``."""
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    default = build_tool_lark(TOOLS, "required", infos)
    explicit_empty = build_tool_lark(TOOLS, "required", infos, reasoning_sentinels=())
    # Both no-reasoning call shapes are byte-identical to the PR-3 golden.
    assert default == _PR3_GOLDEN_LARK, "non-reasoning grammar drifted from PR-3"
    assert explicit_empty == _PR3_GOLDEN_LARK
    # No reasoning machinery leaks into the non-reasoning grammar (redundant with
    # the golden, kept as a readable intent assertion).
    assert "lead:" not in default
    assert "bal_prefix:" not in default
    assert "reasoning_block:" not in default
    assert "rtok:" not in default


def test_reasoning_sentinels_dedup_and_drop_empty():
    """Duplicate / empty reasoning markers are de-duped and dropped; the first
    two DISTINCT refs become the balanced ``(open, close)`` block."""
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    lark = build_tool_lark(
        TOOLS,
        "required",
        infos,
        reasoning_sentinels=("<think>", "", "<think>", "</think>"),
    )
    # Deduped to (open=<think>, close=</think>); no empty ref, no self-pair.
    assert "reasoning_block: <think> TAG_TEXT </think>" in lark
    assert "reasoning_block: <think> TAG_TEXT <think>" not in lark


def test_single_reasoning_marker_degrades_to_bare_prefix():
    """A single reasoning marker (no distinct close) cannot form a balanced
    block, so the prefix degrades to the bare ``TAG_TEXT`` (no reasoning
    tolerance) rather than emitting a half-open block."""
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    lark = build_tool_lark(TOOLS, "required", infos, reasoning_sentinels=("<think>",))
    assert "reasoning_block:" not in lark
    assert "lead:" not in lark
    assert "bal_prefix:" not in lark
    assert "tag_end: TAG_TEXT" in lark


def test_malformed_reasoning_sentinel_is_dropped_not_emitted():
    """A marker that is NOT a valid bare ``<...>`` special-token ref (e.g. a
    ``[THINK]`` char-class shape, or one with interior whitespace/brackets) is
    DROPPED — it must never be interpolated into Lark as syntactically-invalid
    source (codex #558-PR4 nit). The remaining well-formed pair still emits."""
    from vllm_mlx.api.tool_grammar import build_tool_lark

    infos = [_hermes_structure_info()(t["name"]) for t in TOOLS]
    # Only ``<think>``/``</think>`` are valid refs; the others are dropped, so
    # the balanced (open, close) pair is recovered from the survivors.
    lark = build_tool_lark(
        TOOLS,
        "required",
        infos,
        reasoning_sentinels=("[THINK]", "<think>", "<a b>", "<x<y>", "</think>"),
    )
    assert "reasoning_block: <think> TAG_TEXT </think>" in lark
    # None of the malformed markers leaked into the grammar source.
    assert "[THINK]" not in lark
    assert "<a b>" not in lark
    assert "<x<y>" not in lark

    # If FEWER than two valid refs survive, the prefix degrades to bare TAG_TEXT
    # (no reasoning machinery) rather than emitting broken Lark.
    lark_all_bad = build_tool_lark(
        TOOLS, "required", infos, reasoning_sentinels=("[THINK]", "<a b>")
    )
    assert "lead:" not in lark_all_bad
    assert "bal_prefix:" not in lark_all_bad
    assert "reasoning_block:" not in lark_all_bad
    assert "tag_end: TAG_TEXT" in lark_all_bad


def test_resolve_reasoning_sentinels_from_parser(tok):
    """``resolve_reasoning_sentinels`` reads the configured reasoning parser's
    boundary tokens and keeps only single-special-token markers on THIS
    tokenizer. On the Qwen3 tokenizer both ``<think>``/``</think>`` qualify."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        resolve_reasoning_sentinels,
    )

    # Guard: the fixture tokenizer must actually carry <think>/</think> as
    # single special tokens for this assertion to be meaningful. (It does on the
    # pinned Qwen3.5 tokenizer; skip only if a future revision drops them.)
    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    assert resolve_reasoning_sentinels("qwen3", tok) == _REASONING_SENTINELS
    # deepseek_r1 uses the same <think>/</think> markers.
    assert resolve_reasoning_sentinels("deepseek_r1", tok) == _REASONING_SENTINELS


def test_resolve_reasoning_sentinels_degrades_safely(tok):
    """No parser / unknown parser -> ``()`` — a missing reasoning parser must NOT
    disable tool enforcement, only omit reasoning tolerance."""
    from vllm_mlx.api.tool_grammar import resolve_reasoning_sentinels

    assert resolve_reasoning_sentinels(None, tok) == ()
    assert resolve_reasoning_sentinels("", tok) == ()
    assert resolve_reasoning_sentinels("no_such_parser", tok) == ()
    # No tokenizer -> () regardless of parser.
    assert resolve_reasoning_sentinels("qwen3", None) == ()


@_requires_llguidance
def test_reasoning_prefix_then_tool_call_is_accepted(tok, lltok):
    """PATH A PROOF: a ``<think>...</think>`` reasoning block followed by a valid
    hermes tool call is accepted IN FULL and terminates — the grammar tolerated
    the reasoning prefix, then enforced the tool-call schema."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    assert grammar is not None
    accepted, total, accepting = _consume(
        grammar,
        lltok,
        tok,
        "<think>I should check the weather in Paris.</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted == total, (
        f"reasoning-prefixed call rejected ({accepted}/{total}) — path A broken"
    )
    assert accepting, "reasoning-prefixed call is not an accepting (terminal) state"


@_requires_llguidance
def test_reasoning_tolerant_prefix_is_what_admits_the_think_token(tok, lltok):
    """The reasoning-tolerant prefix (PR-4) is what makes path A work: WITH
    reasoning sentinels the ``<think>`` special token is admitted; the bare
    PR-3 prefix does not admit it on this tokenizer.

    We assert the LOAD-BEARING direction — the reasoning-tolerant grammar
    accepts the ``<think>``-prefixed call — unconditionally. For the legacy
    grammar we only DOCUMENT that the bare byte prefix does not accept the
    ``<think>`` special token today (the exact bug PR-4 fixes); we do NOT assert
    the legacy MUST stay broken, so a future llguidance that lets byte terminals
    match special tokens would not spuriously fail this suite (codex #558-PR4
    nit) — it would just make the reasoning-tolerant prefix redundant, which the
    positive assertion still tolerates."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    call = (
        "<think>reasoning</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>"
    )

    # LOAD-BEARING: the reasoning-tolerant grammar accepts the whole call.
    tolerant = build_tool_grammar(
        TOOLS, "required", _HermesStubParser(), reasoning_sentinels=_REASONING_SENTINELS
    )
    t_accepted, t_total, t_accepting = _consume(tolerant, lltok, tok, call)
    assert t_accepted == t_total and t_accepting, (
        "reasoning-tolerant prefix did NOT admit the <think>-prefixed call — "
        "path A broken"
    )

    # DOCUMENTED (not asserted as a hard requirement): the bare PR-3 prefix does
    # not admit the leading <think> special token on this tokenizer. If a future
    # llguidance changes this, the tolerant path above still passes; we surface
    # the change via an xfail-style note rather than a hard failure.
    legacy = build_tool_grammar(TOOLS, "required", _HermesStubParser())
    l_accepted, l_total, _ = _consume(legacy, lltok, tok, call)
    if l_accepted >= l_total:
        pytest.skip(
            "bare TAG_TEXT prefix now admits the <think> special token — the "
            "reasoning-tolerant prefix is redundant here (llguidance changed); "
            "PR-4 remains correct, revisit whether it is still necessary"
        )
    # Current behavior: legacy rejects before consuming the whole call because
    # the leading <think> special token is unmatched by the byte prefix.
    assert l_accepted < l_total


@_requires_llguidance
def test_reasoning_grammar_still_accepts_non_reasoning_call(tok, lltok):
    """No regression: under the reasoning-TOLERANT grammar a plain (no-reasoning)
    tool call is STILL accepted and terminates — reasoning tolerance is additive,
    it does not require a ``<think>`` block."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    accepted, total, accepting = _consume(
        grammar,
        lltok,
        tok,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted == total, f"non-reasoning call rejected ({accepted}/{total})"
    assert accepting, "non-reasoning call is not an accepting (terminal) state"


@_requires_llguidance
def test_off_schema_argument_rejected_after_reasoning(tok, lltok):
    """NEGATIVE CONTROL: after a ``<think>...</think>`` block AND the trigger, a
    schema-violating argument (integer where the schema requires a string) is
    still MASKED — the reasoning tolerance did not weaken the post-reasoning
    schema enforcement."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    # Precise negative control (codex #558-PR4 blocking): ``accepted < total``
    # alone would also pass if some EARLIER token were rejected, which would not
    # prove the off-schema integer is what the grammar masked. So we (1) prove
    # the valid prefix — reasoning + trigger + ``"city": `` — is accepted IN
    # FULL, then (2) prove the grammar rejects at exactly the token that starts
    # the integer value. ``4`` violates the ``"city": string`` schema.
    valid_prefix = (
        "<think>reasoning</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": '
    )
    pre_accepted, pre_total, _ = _consume(grammar, lltok, tok, valid_prefix)
    assert pre_accepted == pre_total, (
        f"valid reasoning+trigger prefix was rejected ({pre_accepted}/{pre_total})"
        " — the negative control below would be meaningless"
    )
    # Now append the schema-violating integer. The grammar must accept exactly
    # the prefix tokens and reject at the first token of the ``4`` value.
    accepted, total, _ = _consume(grammar, lltok, tok, valid_prefix + "4")
    assert total > pre_total, "appending '4' did not add a token to encode"
    assert accepted == pre_total, (
        f"grammar rejected at token {accepted}, not at the off-schema integer "
        f"(prefix has {pre_total} tokens) — schema enforcement leaked or "
        "mis-fired through the reasoning-tolerant prefix"
    )


@_requires_llguidance
def test_unbalanced_think_opener_is_rejected(tok, lltok):
    """BALANCED-BLOCK PROOF (codex #558-PR4 blocking): an UNCLOSED ``<think>``
    (opener with no ``</think>``) before the trigger is rejected — the grammar
    forces the opener to be closed before the tool call, so a lenient reasoning
    parser can never swallow the whole ``<think>...<tool_call>...`` region as
    reasoning and drop the required call."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    # <think> opens but NEVER closes before the tool call -> must be rejected.
    accepted, total, _ = _consume(
        grammar,
        lltok,
        tok,
        "<think>reasoning that never closes\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted < total, (
        "unclosed <think> opener was accepted — the reasoning block is not "
        "balanced, so tool_choice=required could be swallowed into reasoning"
    )
    # Control: the SAME sequence with a </think> close IS accepted in full.
    b_accepted, b_total, b_accepting = _consume(
        grammar,
        lltok,
        tok,
        "<think>reasoning that closes</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert b_accepted == b_total and b_accepting, (
        "the balanced <think>...</think> variant should be accepted in full"
    )


@_requires_llguidance
def test_prefilled_think_leading_close_is_accepted(tok, lltok):
    """PREFILL-TOLERANCE PROOF (codex #558-PR4 round-4 blocking): reasoning chat
    templates prefill ``<think>`` at the END of the prompt (Qwen3.6, DeepSeek-R1),
    so the GENERATED stream begins already inside reasoning — reasoning text,
    then a ``</think>`` whose opener lives in the unseen prompt, then the call.
    The grammar admits ONE such leading close (``opened?``) so the required tool
    call is NOT blocked on prefilled-think models."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    # Generated stream when <think> is prompt-prefilled: reasoning text, leading
    # </think> (no generated opener), then the call. Must be accepted IN FULL.
    accepted, total, accepting = _consume(
        grammar,
        lltok,
        tok,
        "The user wants the weather.</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted == total and accepting, (
        "prefilled-<think> generated stream (leading </think>) was rejected — "
        "the required tool call would be blocked on every prefilled-think model"
    )


@_requires_llguidance
def test_two_leading_closes_are_rejected(tok, lltok):
    """``opened?`` admits AT MOST ONE leading close (the single prefilled-think
    opener). A SECOND unmatched ``</think>`` is rejected — the prefill tolerance
    does not degrade into accepting arbitrary stray closes."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    # Two leading closes with no matching opens -> the second is unmatched.
    accepted, total, _ = _consume(
        grammar,
        lltok,
        tok,
        "a</think>b</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted < total, (
        "two leading </think> closes were accepted — opened? must permit only "
        "one (the single prompt-prefilled opener)"
    )


@_requires_llguidance
def test_stray_close_after_call_is_rejected(tok, lltok):
    """GLOBALLY-AT-MOST-ONE PROOF (codex #558-PR4 round-5 blocking #2): the
    trailing ``tag_end`` consumes the BALANCED-only ``bal_prefix``, NOT the
    prefill-tolerant ``lead``. So a stray unmatched ``</think>`` AFTER the call
    (with no leading close to consume the one-time tolerance) is rejected — the
    prefilled-close tolerance is a one-time initial-prefix allowance, not a free
    stray close at every position. A prefix that reused ``opened?`` everywhere
    would wrongly accept this."""
    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_tool_grammar,
    )

    if not are_single_special_tokens(tok, _REASONING_SENTINELS):
        pytest.skip("fixture tokenizer lacks single-token <think>/</think>")
    grammar = build_tool_grammar(
        TOOLS,
        "required",
        _HermesStubParser(),
        reasoning_sentinels=_REASONING_SENTINELS,
    )
    # A balanced reasoning block + a valid call, then a STRAY unmatched </think>
    # in the tag_end region. tag_end uses bal_prefix (no leading-close tolerance),
    # so the trailing stray close must be rejected.
    accepted, total, _ = _consume(
        grammar,
        lltok,
        tok,
        "<think>reasoning</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>trailing</think>",
    )
    assert accepted < total, (
        "a stray </think> AFTER the call was accepted — tag_end must consume the "
        "balanced-only bal_prefix, not the prefill-tolerant lead (the leading-"
        "close tolerance is one-time, globally at most one)"
    )


# DeepSeek-R1 uses the ``deepseek_r1`` reasoning parser and, like Qwen3, prefills
# ``<think>`` in its chat template. Test against the ACTUAL formatted DeepSeek
# prompt (codex #558-PR4 round-4) to prove the prefill tolerance is not
# Qwen-specific.
_DEEPSEEK_MODEL = "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
# Pin the revision (codex #558-PR4 round-5 nit) so this prefill proof runs
# against an IMMUTABLE artifact, mirroring the Qwen fixture: the chat-template
# ``<think>`` prefill and the ``<tool_call>``/``<think>`` single-special-token
# layout are fixed at this commit. Combined with ``local_files_only=True`` the
# test uses ONLY the locally-cached snapshot — it never fetches from the Hub and
# a different upstream revision cannot silently change what is exercised. It
# skips (never fails) when this exact revision is not in the local cache.
_DEEPSEEK_REVISION = "4e0d3848a0ad8f9fb54638891e4928f04fcca978"


@_requires_llguidance
def test_deepseek_r1_prefilled_think_template_is_tolerated(lltok):
    """Using the REAL DeepSeek-R1 chat template (which prefills ``<think>``) and
    the ``deepseek_r1`` reasoning parser, the generated stream — reasoning text +
    a leading ``</think>`` + the tool call — is accepted in full. Proves the
    prefill tolerance holds for DeepSeek-R1's actual formatted prompt, not just
    a hand-written string (codex #558-PR4 round-4)."""
    transformers = pytest.importorskip("transformers")
    try:
        ds_tok = transformers.AutoTokenizer.from_pretrained(
            _DEEPSEEK_MODEL,
            revision=_DEEPSEEK_REVISION,
            local_files_only=True,
        )
    except _offline_skip_exc_types():  # pragma: no cover - uncached revision
        pytest.skip(
            f"{_DEEPSEEK_MODEL}@{_DEEPSEEK_REVISION[:8]} not in local cache — "
            "prefill proof requires the pinned revision cached locally"
        )

    from vllm_mlx.api.tool_grammar import (
        are_single_special_tokens,
        build_lltokenizer,
        build_tool_grammar,
        resolve_reasoning_sentinels,
    )

    if not are_single_special_tokens(ds_tok, ("<tool_call>", "</tool_call>")):
        pytest.skip("DeepSeek tokenizer lacks single-token <tool_call> sentinels")

    # The REAL template must prefill <think> at the end of the assistant turn —
    # otherwise this test would not exercise the prefill path.
    rendered = ds_tok.apply_chat_template(
        [{"role": "user", "content": "Weather in Paris? Use the tool."}],
        tokenize=False,
        add_generation_prompt=True,
    )
    if not rendered.rstrip().endswith("<think>"):
        pytest.skip("DeepSeek-R1 template revision no longer prefills <think>")

    # deepseek_r1 reasoning parser -> <think>/</think>, kept iff single tokens.
    sentinels = resolve_reasoning_sentinels("deepseek_r1", ds_tok)
    if sentinels != ("<think>", "</think>"):
        pytest.skip("DeepSeek tokenizer lacks single-token <think>/</think>")

    # Build the DeepSeek LLTokenizer via the PRODUCTION path (build_lltokenizer):
    # DeepSeek-R1's tokenizer is a ``Qwen2Tokenizer`` that raw
    # ``llguidance.hf.from_tokenizer`` rejects on some transformers revisions —
    # the candidate-3 serialized fallback in build_lltokenizer closes exactly
    # that gap, which is why the route uses it. A None here is a genuine env gap.
    ds_lltok = build_lltokenizer(ds_tok)
    if ds_lltok is None:  # pragma: no cover - conversion gap is an env issue
        pytest.skip("could not build an LLTokenizer for the DeepSeek tokenizer")

    grammar = build_tool_grammar(
        TOOLS, "required", _HermesStubParser(), reasoning_sentinels=sentinels
    )
    assert grammar is not None
    # Generated stream after the prompt-prefilled <think>: reasoning, leading
    # </think>, then the tool call.
    accepted, total, accepting = _consume(
        grammar,
        ds_lltok,
        ds_tok,
        "The user wants Paris weather.</think>\n"
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n'
        "</tool_call>",
    )
    assert accepted == total and accepting, (
        "DeepSeek-R1 prefilled-<think> generated stream was rejected — the "
        "required tool call would be blocked on DeepSeek-R1"
    )
