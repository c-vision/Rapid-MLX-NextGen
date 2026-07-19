# SPDX-License-Identifier: Apache-2.0
"""Grammar-constrained tool calling (#558) — grammar builder (PR-1).

This module turns a chat request's ``tools`` + ``tool_choice`` into an
llguidance grammar that STRUCTURALLY GUARANTEES every emitted tool call
(a) names a tool that actually exists in the list, (b) whose ``arguments``
satisfy that tool's JSON Schema, and (c) uses the model family's tool-call
wire format. It constrains only the FORM of a call, never the decision of
whether/which to call.

Scope of this PR-1: the pure, side-effect-free grammar BUILDER plus the
``StructureInfo`` wire-triple dataclass and a compiled-grammar LRU cache.
**Nothing here is wired into the request path** — no logits processor, no
scheduler/chat.py routing. ``build_tool_grammar`` has no call sites yet, so
this file is no-behavior-change scaffolding. The runtime
``GrammarLogitsProcessor`` and its wiring land in PR-3; the per-family
``ToolParser.structure_info()`` overrides land in PR-2.

Design + prior-art: ``design-558-constrained-tool-calling.md``. The
mechanism is the "structural tags with triggers" pattern that vLLM
(``TriggeredTagsFormat``), SGLang (``LegacyStructuralTagResponseFormat`` +
``BaseFormatDetector.structure_info``) and llguidance (``StructTag``) all
converge on. We PORT llguidance's ``StructTag.to_grammar`` Lark-assembly
algorithm (``llguidance/_struct_tag.py``) rather than inventing our own,
per the charter guardrail. ``StructureInfo`` mirrors SGLang's per-detector
``structure_info() -> (begin, end, trigger)`` contract.

Ground-truth correction to the design doc (verified on the real Qwen3.5
tokenizer, 2026-07): the ``<tool_call>`` / ``</tool_call>`` sentinels are
SINGLE SPECIAL TOKENS (ids 248058 / 248059), not multi-byte text. So we
must reference them as Lark special-token literals on BOTH the
trigger/begin AND the ``end`` — ``StructTag.to_grammar`` only special-cases
the trigger, leaving ``</tool_call>`` in ``end`` as a byte string the
model's single ``</tool_call>`` token can never satisfy. We therefore build
the Lark directly (still following StructTag's algorithm) with a per-family
list of "sentinel" substrings that must render as special-token refs.
"""

import json
import logging
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any

logger = logging.getLogger(__name__)

# Reuse the exact llguidance surface the guided-decoding path already imports
# (proves availability + shares the native MLX mask kernel). Only the
# compile-side factory (``LLMatcher.grammar_from_lark``) is used here; the
# per-token mask kernel is a PR-3 concern and is deliberately not imported.
try:
    from llguidance.mlx import LLMatcher

    HAS_LLGUIDANCE = True
except ImportError:  # pragma: no cover - mirrors guided.py degrade path
    HAS_LLGUIDANCE = False
    LLMatcher = None


@dataclass(frozen=True)
class StructureInfo:
    """Per-tool wire triple, mirroring SGLang's ``StructureInfo``.

    ``begin`` MUST start with ``trigger`` (StructTag invariant). ``{name}``
    in ``begin`` is already substituted with the concrete tool name by
    ``ToolParser.structure_info()``. ``sentinels`` lists literal substrings
    inside ``begin``/``end`` that are single special tokens for this family
    and must be emitted as Lark special-token refs, not byte strings.
    """

    begin: str
    end: str
    trigger: str
    sentinels: tuple[str, ...] = field(default=())


def _lark_escape(s: str) -> str:
    """Render ``s`` as a Lark double-quoted string literal (JSON-escaped)."""
    if not s:
        return ""
    return json.dumps(s)


def _emit_literal_with_sentinels(text: str, sentinels: tuple[str, ...]) -> str:
    """Split ``text`` on sentinel substrings, emitting sentinels as special
    tokens and the rest as quoted byte-string literals.

    E.g. ``"}\\n</tool_call>"`` with sentinel ``"</tool_call>"`` renders to
    ``"}\\n" </tool_call>`` — the trailing sentinel becomes a special-token
    ref so the model's single ``</tool_call>`` token satisfies the grammar.
    """
    if not text:
        return ""
    ordered = sorted((s for s in sentinels if s), key=len, reverse=True)
    parts: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        matched = None
        for sent in ordered:
            if text.startswith(sent, i):
                matched = sent
                break
        if matched is not None:
            # Sentinels are already in ``<...>`` special-token form (e.g.
            # ``<tool_call>``). Emit verbatim — llguidance Lark treats a
            # bare ``<name>`` as a special-token reference. Wrapping it
            # again would yield ``<<tool_call>>`` (a lexer error).
            parts.append(matched)
            i += len(matched)
        else:
            j = i + 1
            while j < n and not any(text.startswith(s, j) for s in ordered):
                j += 1
            parts.append(_lark_escape(text[i:j]))
            i = j
    return " ".join(p for p in parts if p)


def build_tool_lark(
    tools: list[dict[str, Any]],
    tool_choice: str,
    structure_infos: list["StructureInfo"],
) -> str:
    """Assemble the Lark grammar for a set of per-tool structure triples.

    Ports the ``StructTag.to_grammar`` layout (``start: (tag_0|...)*
    tag_end``) but with special-token-aware begin/end rendering (see module
    docstring). ``tool_choice`` selects the repetition quantifier:

      * ``auto``                        -> ``(...)*``  (may emit zero calls)
      * ``required`` / a function name  -> ``(...)+``  (design R1: ≥1 forced)

    ``"none"`` must NOT reach this function — ``none`` produces no grammar at
    all (the model sees no tools, design §4); passing it here is a caller
    bug and raises ``ValueError`` rather than silently forcing a call.

    The grammar is built over exactly the ``tools`` passed in — one ``tag_i``
    alternative per tool. For a NAMED ``tool_choice`` the caller narrows
    ``tools`` to the single requested function BEFORE calling the builder
    (design §4 / chat.py named routing), so the alternation naturally
    collapses to a single forced tag. The builder does not itself resolve a
    function name out of a multi-tool list — that routing lands in PR-3.

    Every tag is: ``TAG_TEXT <trigger-and-begin> %json <schema> <end>``.
    ``TAG_TEXT`` is the lazy free prefix that swallows reasoning/prose until
    the trigger — this is also the reasoning-aware delay (design §5 path A).
    REQUIREMENT (applies to ALL modes, not just ``auto``): the trigger MUST be
    a single special token, declared in ``sentinels``. This is enforced
    UNCONDITIONALLY because the lazy ``TAG_TEXT`` prefix can reassemble a
    multi-byte *text* trigger from ordinary token pieces in any mode — a
    text trigger is unenforceable regardless of the ``*``/``+`` quantifier, so
    the builder rejects it (raises ``ValueError``) rather than silently
    producing an unenforceable grammar. Full text-trigger support (excluding
    the trigger byte sequence from ``TAG_TEXT`` across token boundaries) is
    design §7 open-Q1, deferred to the PR-5 auto path.
    """
    if not tools:
        raise ValueError("build_tool_lark: tools must not be empty")
    if len(tools) != len(structure_infos):
        raise ValueError(
            "build_tool_lark: tools and structure_infos length mismatch "
            f"({len(tools)} != {len(structure_infos)})"
        )
    if tool_choice == "none":
        raise ValueError(
            "build_tool_lark: tool_choice='none' must not build a grammar "
            "(none produces no constraint at all — caller bug)"
        )
    for si in structure_infos:
        # A trigger is mandatory (StructureInfo contract) — an empty trigger
        # would produce a triggerless grammar the lazy TAG_TEXT prefix could
        # never gate.
        if not si.trigger:
            raise ValueError("build_tool_lark: StructureInfo.trigger must be non-empty")
        # StructTag invariant: begin must start with trigger. Enforce it so a
        # malformed per-family structure_info() is caught at build time rather
        # than silently producing a grammar whose trigger prefix is unused.
        if not si.begin.startswith(si.trigger):
            raise ValueError(
                "build_tool_lark: StructureInfo.begin must start with its "
                f"trigger (trigger={si.trigger!r}, begin={si.begin!r})"
            )
        # The trigger must be a special-token sentinel (see REQUIREMENT above)
        # in EVERY mode — the lazy TAG_TEXT prefix could otherwise reassemble a
        # text trigger from ordinary token pieces and bypass enforcement.
        if si.trigger not in si.sentinels:
            raise ValueError(
                "build_tool_lark: trigger must be declared as a special-token "
                f"sentinel (trigger={si.trigger!r}, sentinels={si.sentinels!r})"
            )

    # auto -> zero-or-more (may emit no call); everything else forces ≥1.
    quant = "*" if tool_choice == "auto" else "+"
    tag_names = " | ".join(f"tag_{i}" for i in range(len(tools)))
    lark = (
        "%llguidance {}\n"
        f"start: ({tag_names}){quant} tag_end\n"
        "tag_end: TAG_TEXT\n"
        r"TAG_TEXT: /(.|\n)*/"
        "\n"
    )
    for i, (tool, si) in enumerate(zip(tools, structure_infos)):
        # Only substitute the default when ``parameters`` is ABSENT. A
        # falsy-but-present schema ({} = allow-any, false = allow-none) is a
        # deliberate, meaningful JSON Schema and must be preserved verbatim —
        # ``tool.get("parameters") or default`` would silently clobber it. The
        # default itself is CLOSED (``additionalProperties: false``): a tool
        # that documents no parameters must accept NO arguments, otherwise the
        # grammar would let the model hallucinate arbitrary keys into a
        # no-arg call.
        if "parameters" in tool and tool["parameters"] is not None:
            params = tool["parameters"]
        else:
            params = {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            }
        schema = json.dumps(params)
        begin_body = _emit_literal_with_sentinels(si.begin, si.sentinels)
        end_body = _emit_literal_with_sentinels(si.end, si.sentinels)
        lark += f"\ntag_{i}: TAG_TEXT {begin_body} %json {schema}"
        if end_body:
            lark += f" {end_body}"
        lark += "\n"
    return lark


# --------------------------------------------------------------------------
# Compiled-grammar cache (design R5).
# --------------------------------------------------------------------------
@lru_cache(maxsize=128)
def _compile_lark_cached(lark: str) -> str | None:
    if not HAS_LLGUIDANCE:
        return None
    try:
        return LLMatcher.grammar_from_lark(lark)
    except Exception:
        logger.exception("tool-grammar: failed to compile Lark")
        return None


def build_tool_grammar(
    tools: list[dict[str, Any]],
    tool_choice: str,
    parser: Any,
) -> str | None:
    """Public entry: (tools, tool_choice, parser) -> compiled llguidance grammar.

    INPUT CONTRACT (NORMALIZED — not raw OpenAI request shapes): ``tools`` is
    a list of ``{"name": str, "parameters": <json-schema>}`` dicts and
    ``tool_choice`` is a resolved string — ``"auto"`` / ``"required"`` /
    ``"none"`` / a concrete function name. Un-wrapping the OpenAI request
    shapes (``{"type":"function","function":{"name":...,"parameters":...}}``
    for tools; ``{"type":"function","function":{"name":...}}`` for a named
    choice) is the CALLER's job — it happens in the PR-3 chat.py routing that
    wires this builder in. This function deliberately does NOT normalize
    request objects; that responsibility lives with the routing PR so the
    builder stays a small, pure, request-shape-agnostic unit. An unexpected
    shape degrades safely to ``None`` (free-form) rather than crashing.

    Returns ``None`` when ``tool_choice`` is ``"none"`` (no constraint at
    all), when the parser declares no ``structure_info`` (family not yet
    supported -> caller falls back to today's free-form behavior), or when
    llguidance is unavailable / a per-family factory raises / compilation
    fails. Any of these paths degrades safely to today's free-form behavior.
    (PR-3 note: this collapses "constraint unavailable" and "requested
    constraint malformed" into the same ``None``; the routing PR that adds a
    real caller decides whether a malformed *required/named* constraint
    should hard-fail instead of falling open — PR-1 has no caller to make
    that policy call, so it uniformly fails open.)

    NOTE (PR-1): this function has NO call sites in the request path yet.
    ``chat.py`` / ``scheduler.py`` routing is deliberately not wired here —
    it lands with the runtime processor in PR-3. Until then this is inert
    scaffolding and cannot change tool-call behavior.
    """
    if not HAS_LLGUIDANCE or not tools:
        return None
    if tool_choice == "none":
        # ``none`` means the model sees no tools -> no grammar (design §4).
        return None
    info_fn = getattr(parser, "structure_info", None)
    if info_fn is None:
        return None
    try:
        get_info = info_fn()
    except Exception:
        logger.exception("tool-grammar: parser.structure_info() raised")
        return None
    if get_info is None:
        return None  # family opted out (default ABC behavior)

    # NAMED tool_choice: any value other than the reserved ``auto``/``required``
    # (``none`` already returned above) names a specific function. Narrow
    # ``tools`` to just that function INSIDE the builder so a named choice can
    # only ever emit the requested tool — never one of the other supplied
    # tools — regardless of how the caller passed ``tools`` (design §4). An
    # unknown name degrades to free-form rather than silently constraining.
    if tool_choice not in ("auto", "required"):
        named = [t for t in tools if t.get("name") == tool_choice]
        if not named:
            logger.warning(
                "tool-grammar: named tool_choice %r not in tools; free-form",
                tool_choice,
            )
            return None
        tools = named

    structure_infos: list[StructureInfo] = []
    for tool in tools:
        name = tool.get("name")
        if not name:
            return None
        # Mirror the structure_info() guard: a per-family factory that raises
        # on a specific tool name must degrade to free-form, not crash the
        # request (codex round-2 nit — consistent fallback policy).
        try:
            si = get_info(name)
        except Exception:
            logger.exception("tool-grammar: structure_info factory raised")
            return None
        if si is None:
            return None
        structure_infos.append(si)

    try:
        lark = build_tool_lark(tools, tool_choice, structure_infos)
    except ValueError:
        # Malformed structure_info / unsupported tool_choice -> free-form.
        logger.exception("tool-grammar: build_tool_lark rejected inputs")
        return None
    return _compile_lark_cached(lark)
