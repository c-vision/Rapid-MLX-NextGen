# SPDX-License-Identifier: Apache-2.0
"""Runtime tests for grammar-constrained tool calling (#558 PR-3).

PR-1 shipped the pure grammar BUILDER and PR-2 the per-family
``structure_info`` overrides (both covered by ``test_tool_grammar_558.py`` /
``test_structure_info_hermes_qwen_558.py``). PR-3 adds the RUNTIME half:

  * ``GrammarLogitsProcessor`` — the per-token mask applied to logits each
    decode step, including the CUMULATIVE-BASELINE fix (mlx-lm hands the full
    ``prompt + generated`` sequence each step; the matcher must be advanced
    ONLY over generated tokens);
  * ``build_lltokenizer`` — the ``LLTokenizer`` factory with the ``to_str()``
    fallback for the transformers ``from_tokenizer`` isinstance gotcha;
  * ``routes.chat._normalize_tool_choice_for_grammar`` — the collision-safe
    ``tool_choice`` normalization (a tool literally named ``"required"`` must
    never be misread as the ``required`` enum).

The processor / enforcement tests need a fast (Rust) tokenizer whose
``<tool_call>``/``</tool_call>`` are single special tokens — verified on
``mlx-community/Qwen3.5-4B-MLX-4bit`` (the pilot wire model). They skip ONLY
on genuine unavailability (the ``[guided]`` extra absent, or the tokenizer
neither cached nor reachable). The pure-Python normalization tests carry no
optional dependency and always run.
"""

import importlib.util

import pytest

_HAS_LLGUIDANCE = importlib.util.find_spec("llguidance") is not None
_requires_llguidance = pytest.mark.skipif(
    not _HAS_LLGUIDANCE, reason="llguidance ([guided] extra) not installed"
)


@pytest.fixture(autouse=True)
def _opt_in_constrain_tools(monkeypatch):
    """PR-3a ships the constraint OPT-IN (``RAPID_MLX_CONSTRAIN_TOOLS`` defaults
    to off). These runtime tests exercise the ENABLED path, so turn it on for
    the module. The explicit kill-switch test overrides this back to ``"0"``.
    """
    monkeypatch.setenv("RAPID_MLX_CONSTRAIN_TOOLS", "1")


_TOKENIZER_MODEL = "mlx-community/Qwen3.5-4B-MLX-4bit"
# Pin the revision so the enforcement proof runs against an IMMUTABLE artifact
# (mirrors test_tool_grammar_558.py). The tokenizer's
# ``<tool_call>``/``</tool_call>`` single-special-token layout is fixed here.
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


# --------------------------------------------------------------------------
# Lightweight stand-ins mirroring the ToolDefinition / request / engine / cfg
# shapes the chat route reads, so tests can drive the REAL
# ``_maybe_build_tool_grammar_processor`` without a live server.
# --------------------------------------------------------------------------
class _FunctionTool:
    """Mirrors ``ToolDefinition`` (``.function`` is a dict). ``parameters`` is
    OMITTED from the dict entirely when not passed, so ``"parameters" in fn``
    is False (the absent case)."""

    _SENTINEL = object()

    def __init__(self, name, parameters=_SENTINEL):
        self.function = {"name": name}
        if parameters is not _FunctionTool._SENTINEL:
            self.function["parameters"] = parameters


class _RequestStub:
    def __init__(self, tools, tool_choice):
        self.tools = tools
        self.tool_choice = tool_choice


class _EngineStub:
    def __init__(self, tokenizer):
        self.tokenizer = tokenizer


class _CfgStub:
    def __init__(self, tool_call_parser):
        self.tool_call_parser = tool_call_parser


def _http_status_of(exc):
    """Best-effort HTTP status code for a hub/requests/httpx error, else None."""
    resp = getattr(exc, "response", None)
    code = getattr(resp, "status_code", None)
    if isinstance(code, int):
        return code
    # huggingface_hub sometimes carries the code directly.
    code = getattr(exc, "status_code", None)
    return code if isinstance(code, int) else None


def _is_offline_skippable(exc) -> bool:
    """True iff ``exc`` is a TRANSIENT network/cache-miss error worth skipping.

    Skip ONLY genuine transient signals: offline/cache-miss, a raw
    connection/timeout error, or a rate-limit (429) / transient server (5xx)
    HTTP response. A PERMANENT 4xx (401/403 bad creds, 404 deleted artifact,
    422 invalid pinned revision) must FAIL — it means the test is misconfigured
    or the artifact changed, not that the network blipped (codex #558-PR3). A
    corrupt local file, a programming/API error, etc. also propagate.
    """
    # Cache-miss / explicit offline: always skippable.
    try:
        from huggingface_hub.errors import (
            LocalEntryNotFoundError,
            OfflineModeIsEnabled,
        )

        if isinstance(exc, (LocalEntryNotFoundError, OfflineModeIsEnabled)):
            return True
    except Exception:  # pragma: no cover - old hub without these names
        pass
    # Raw connection / timeout (requests + httpx): transport failure, skippable.
    transient_types: list[type[BaseException]] = []
    try:
        from requests.exceptions import ConnectionError as _ReqConnErr
        from requests.exceptions import Timeout as _ReqTimeout

        transient_types += [_ReqConnErr, _ReqTimeout]
    except Exception:  # pragma: no cover - requests not present
        pass
    try:
        # ``TransportError`` is the base for ALL httpx transport-layer failures
        # — ConnectError, TimeoutException, ReadError, RemoteProtocolError, etc.
        # (codex #558-PR3 nit): an interrupted response mid-download is transient
        # and must skip, not spuriously fail the network-dependent suite. HTTP
        # STATUS errors are ``HTTPStatusError`` (NOT a TransportError), so they
        # still fall through to the 4xx-fails / 429+5xx-skips branch below.
        from httpx import TransportError as _HxTransport

        transient_types += [_HxTransport]
    except Exception:  # pragma: no cover - httpx not present
        pass
    if transient_types and isinstance(exc, tuple(transient_types)):
        return True
    # HTTP-status-bearing errors (HfHubHTTPError / requests.HTTPError / httpx):
    # skip ONLY 429 + 5xx (transient); permanent 4xx must fail.
    status = _http_status_of(exc)
    if status is not None:
        return status == 429 or 500 <= status < 600
    return False


@pytest.fixture(scope="module")
def tok():
    transformers = pytest.importorskip("transformers")
    try:
        return transformers.AutoTokenizer.from_pretrained(
            _TOKENIZER_MODEL, revision=_TOKENIZER_REVISION
        )
    except Exception as exc:  # pragma: no cover - offline & uncached
        # Skip ONLY on a transient network/cache-miss signal; a permanent 4xx
        # (bad creds / deleted artifact / invalid revision) or any other error
        # must FAIL, not silently green the enforcement suite (codex #558-PR3).
        if not _is_offline_skippable(exc):
            raise
        pytest.skip(
            f"tokenizer {_TOKENIZER_MODEL}@{_TOKENIZER_REVISION[:8]} not "
            "cached and no network — runtime enforcement tests require it"
        )


@pytest.fixture(scope="module")
def hermes_grammar(tok):
    # We reach here only with llguidance present (the enforcement tests are
    # ``@_requires_llguidance``) AND the pinned tokenizer available (``tok``
    # succeeded). Under those conditions the hermes parser DOES declare a
    # ``structure_info`` (proven in test_structure_info_hermes_qwen_558.py), so
    # ``build_tool_grammar`` returning ``None`` means the production builder
    # REGRESSED and the enforcement suite must FAIL — not silently skip and go
    # green while the feature is broken (codex #558-PR3).
    pytest.importorskip("llguidance")
    from vllm_mlx.api.tool_grammar import build_tool_grammar
    from vllm_mlx.tool_parsers.hermes_tool_parser import HermesToolParser

    parser = HermesToolParser(tokenizer=tok)
    grammar = build_tool_grammar(TOOLS, "required", parser)
    assert grammar is not None, (
        "build_tool_grammar returned None with llguidance present and the "
        "hermes structure_info available — the grammar builder regressed"
    )
    return grammar


@pytest.fixture(scope="module")
def lltok(tok):
    # Same contract as ``hermes_grammar``: with llguidance present and the
    # pinned fast tokenizer available, ``build_lltokenizer`` MUST succeed. A
    # ``None`` here is a regression in the LLTokenizer factory, not a sanctioned
    # skip (codex #558-PR3).
    pytest.importorskip("llguidance")
    from vllm_mlx.api.tool_grammar import build_lltokenizer

    llt = build_lltokenizer(tok)
    assert llt is not None, (
        "build_lltokenizer returned None for the pinned fast wire tokenizer "
        "with llguidance present — the LLTokenizer factory regressed"
    )
    return llt


# --------------------------------------------------------------------------
# tool_choice normalization — collision fix (pure Python, always runs).
# --------------------------------------------------------------------------
def test_normalize_required_is_enum_not_named():
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    assert _normalize_tool_choice_for_grammar("required") == {"mode": "required"}


@pytest.mark.parametrize("value", ["auto", "none", None])
def test_normalize_auto_none_unconstrained(value):
    # PR-3 scope: auto (PR-5-owned) and none both fall through to free-form.
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    assert _normalize_tool_choice_for_grammar(value) is None


def test_normalize_named_object_form():
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    choice = {"type": "function", "function": {"name": "get_time"}}
    assert _normalize_tool_choice_for_grammar(choice) == {
        "mode": "named",
        "name": "get_time",
    }


def test_normalize_bare_tool_name_string_is_never_named():
    # Deferred codex #2: a bare string that happens to equal a tool name is
    # an INVALID tool_choice enum, not a named selection. It must NOT be read
    # as a named choice (that requires the object form). -> unconstrained.
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    assert _normalize_tool_choice_for_grammar("get_time") is None


def test_normalize_tool_named_required_only_via_object_form():
    # A tool literally named "required": under a bare string it's the enum
    # (mode=required, forces one of ANY tool); it is selectable as a NAMED
    # single tool ONLY via the object form. The two paths can never collide.
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    assert _normalize_tool_choice_for_grammar("required") == {"mode": "required"}
    assert _normalize_tool_choice_for_grammar(
        {"type": "function", "function": {"name": "required"}}
    ) == {"mode": "named", "name": "required"}


@pytest.mark.parametrize(
    "bad_function",
    [
        "get_weather",  # truthy string, not a dict
        ["get_weather"],  # truthy list
        123,  # truthy int
        {"name": 42},  # dict but name is not a str
        {"name": ""},  # dict but empty name
        {},  # empty dict (no name)
    ],
)
def test_normalize_malformed_function_degrades_to_none(bad_function):
    # codex #558-PR3 blocking: a dict-shaped tool_choice whose ``function`` is
    # truthy-but-not-a-dict (or a dict without a usable name) must degrade to
    # None (free-form), NOT reach ``.get`` on a non-dict and raise -> HTTP 500.
    from vllm_mlx.routes.chat import _normalize_tool_choice_for_grammar

    assert (
        _normalize_tool_choice_for_grammar(
            {"type": "function", "function": bad_function}
        )
        is None
    )


# --------------------------------------------------------------------------
# Cheap synchronous eligibility gate — must short-circuit the offload for the
# common no-tools / auto / none traffic (codex #558-PR3). Pure Python, always
# runs (no llguidance, no tokenizer).
# --------------------------------------------------------------------------
def test_eligible_false_when_no_tools():
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    cfg = _CfgStub("hermes")
    req = _RequestStub(tools=None, tool_choice="required")
    assert _tool_grammar_eligible(cfg, req) is False


def test_eligible_false_when_no_parser():
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    cfg = _CfgStub(None)  # no family parser configured
    req = _RequestStub(tools=[_FunctionTool("get_time")], tool_choice="required")
    assert _tool_grammar_eligible(cfg, req) is False


@pytest.mark.parametrize("choice", ["auto", "none", None])
def test_eligible_false_for_auto_none(choice):
    # auto (PR-5-owned) and none must NOT enter the thread-pool offload.
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    cfg = _CfgStub("hermes")
    req = _RequestStub(tools=[_FunctionTool("get_time")], tool_choice=choice)
    assert _tool_grammar_eligible(cfg, req) is False


def test_eligible_true_for_required_and_named():
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    cfg = _CfgStub("hermes")
    tools = [_FunctionTool("get_time")]
    assert _tool_grammar_eligible(cfg, _RequestStub(tools, "required")) is True
    named = {"type": "function", "function": {"name": "get_time"}}
    assert _tool_grammar_eligible(cfg, _RequestStub(tools, named)) is True


@pytest.mark.parametrize("value", ["0", "off", "false", "no", "", "2"])
def test_eligible_false_when_env_not_opted_in(monkeypatch, value):
    # PR-3a is OPT-IN: only the exact ``1``/``on``/``true`` values enable the
    # constraint. Anything else (including an unrecognized value) leaves it off.
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    monkeypatch.setenv("RAPID_MLX_CONSTRAIN_TOOLS", value)
    cfg = _CfgStub("hermes")
    req = _RequestStub(tools=[_FunctionTool("get_time")], tool_choice="required")
    assert _tool_grammar_eligible(cfg, req) is False


def test_eligible_false_by_default_when_env_unset(monkeypatch):
    # PR-3a ships OFF by default: with the env var ABSENT the constraint does
    # not activate (client-schema DoS-hardening is PR-3b; default-on is gated
    # on it). Overrides the module autouse opt-in fixture by deleting the var.
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    monkeypatch.delenv("RAPID_MLX_CONSTRAIN_TOOLS", raising=False)
    cfg = _CfgStub("hermes")
    req = _RequestStub(tools=[_FunctionTool("get_time")], tool_choice="required")
    assert _tool_grammar_eligible(cfg, req) is False


def test_eligible_true_for_reasonable_schema():
    # A normal-sized, shallow schema is eligible (opt-in enabled by the module
    # autouse fixture). PR-3a applies no size/depth cap (that is PR-3b).
    from vllm_mlx.routes.chat import _tool_grammar_eligible

    ok = _FunctionTool(
        "get_weather",
        parameters={
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    )
    cfg = _CfgStub("hermes")
    req = _RequestStub(tools=[ok], tool_choice="required")
    assert _tool_grammar_eligible(cfg, req) is True


def test_offline_skip_classifies_http_status():
    # codex #558-PR3 blocking: only TRANSIENT signals skip; a permanent 4xx
    # (bad creds / deleted artifact / invalid revision) must FAIL, not silently
    # green the suite.
    from vllm_mlx.routes import chat  # noqa: F401  (ensure module import order)

    class _Resp:
        def __init__(self, code):
            self.status_code = code

    class _HTTPError(Exception):
        def __init__(self, code):
            self.response = _Resp(code)

    # 429 + 5xx -> transient -> skippable.
    assert _is_offline_skippable(_HTTPError(429)) is True
    assert _is_offline_skippable(_HTTPError(500)) is True
    assert _is_offline_skippable(_HTTPError(503)) is True
    # permanent 4xx -> must FAIL (not skip).
    assert _is_offline_skippable(_HTTPError(401)) is False
    assert _is_offline_skippable(_HTTPError(403)) is False
    assert _is_offline_skippable(_HTTPError(404)) is False
    assert _is_offline_skippable(_HTTPError(422)) is False
    # a non-HTTP programming error is not skippable either.
    assert _is_offline_skippable(ValueError("boom")) is False

    # httpx transport-layer failures (interrupted response mid-download) are
    # transient -> skippable, but an httpx HTTP-STATUS error still classifies by
    # code (codex #558-PR3 nit).
    httpx = pytest.importorskip("httpx")
    assert _is_offline_skippable(httpx.ReadError("peer reset")) is True
    assert _is_offline_skippable(httpx.RemoteProtocolError("truncated")) is True
    assert _is_offline_skippable(httpx.ConnectError("refused")) is True
    req = httpx.Request("GET", "https://example.invalid")
    resp_404 = httpx.Response(404, request=req)
    resp_503 = httpx.Response(503, request=req)
    assert (
        _is_offline_skippable(
            httpx.HTTPStatusError("nf", request=req, response=resp_404)
        )
        is False
    )
    assert (
        _is_offline_skippable(
            httpx.HTTPStatusError("busy", request=req, response=resp_503)
        )
        is True
    )


def test_route_offload_gated_on_eligibility_in_source():
    # The route must run the cheap gate SYNCHRONOUSLY before the off-loop
    # compile, so no-tools / auto traffic never enters the thread offload
    # (codex #558-PR3). Source-position tripwire — the BEHAVIORAL guarantee is
    # proven by ``test_ineligible_request_never_enters_heavy_build_path``.
    # PR-3a uses a simple ``asyncio.to_thread`` offload (the bounded compile
    # pool is PR-3b).
    import inspect

    from vllm_mlx.routes import chat as chat_mod

    src = inspect.getsource(chat_mod._create_chat_completion_impl)
    gate = src.find("_tool_grammar_eligible(cfg, request)")
    offload = src.find("asyncio.to_thread(")
    assert gate != -1, "route must gate the offload on _tool_grammar_eligible"
    assert offload != -1, "route must offload the build via asyncio.to_thread"
    assert gate < offload, "the eligibility gate must precede the off-loop compile"


@pytest.mark.parametrize(
    "tools, tool_choice, env",
    [
        ([_FunctionTool("get_time")], "required", "0"),  # opted out
        ([], "required", "1"),  # no tools
        ([_FunctionTool("get_time")], "auto", "1"),  # unconstrained choice
        ([_FunctionTool("get_time")], "none", "1"),  # unconstrained choice
    ],
)
def test_ineligible_request_never_enters_heavy_build_path(
    monkeypatch, tools, tool_choice, env
):
    # codex #558-PR3 blocking (behavioral, not source-string): an INELIGIBLE
    # request (opted out, no tools, or auto/none) must NEVER reach the
    # client-schema grammar compile. ``_maybe_build_tool_grammar_processor``
    # re-runs the gate, so booby-trap ``build_tool_grammar`` to explode — if the
    # gate short-circuits (as it must), it's never called and we get ``None``;
    # if the gate were bypassed, the RuntimeError would surface. This proves the
    # gate behaviorally, independent of any source-position check.
    from vllm_mlx.api import tool_grammar as tg_mod
    from vllm_mlx.routes import chat as chat_mod

    monkeypatch.setenv("RAPID_MLX_CONSTRAIN_TOOLS", env)

    def _boom(*a, **k):  # pragma: no cover - must never be reached
        raise RuntimeError("heavy grammar compile reached for an ineligible request")

    monkeypatch.setattr(tg_mod, "build_tool_grammar", _boom)

    cfg = _CfgStub("hermes")
    engine = _EngineStub(tokenizer=object())
    request = _RequestStub(tools, tool_choice)
    assert chat_mod._tool_grammar_eligible(cfg, request) is False, (
        "fixture inputs must be ineligible"
    )
    assert chat_mod._maybe_build_tool_grammar_processor(engine, cfg, request) is None, (
        "ineligible request must fall back to free-form without compiling"
    )


# --------------------------------------------------------------------------
# build_lltokenizer.
# --------------------------------------------------------------------------
@_requires_llguidance
def test_build_lltokenizer_from_wire_tokenizer(tok):
    from vllm_mlx.api.tool_grammar import build_lltokenizer

    llt = build_lltokenizer(tok)
    assert llt is not None
    assert llt.vocab_size > 0


@_requires_llguidance
def test_build_lltokenizer_none_on_junk_tokenizer():
    # A tokenizer with no fast internals and no backend_tokenizer -> None
    # (caller degrades to free-form), never an exception.
    from vllm_mlx.api.tool_grammar import build_lltokenizer

    class _Junk:
        is_fast = False

    assert build_lltokenizer(_Junk()) is None


# --------------------------------------------------------------------------
# GrammarLogitsProcessor — enforcement + cumulative-baseline fix.
# --------------------------------------------------------------------------
def _feed_cumulative(proc, lltok, tok, prompt_ids, gen_text):
    """Drive the processor the way mlx-lm does: full cumulative sequence each
    step (prompt + generated-so-far). Returns (blocked, blocked_gen_idx).
    """
    import mlx.core as mx
    import numpy as np

    vocab = lltok.vocab_size
    gen_ids = tok.encode(gen_text, add_special_tokens=False)
    cumulative = list(prompt_ids)
    masked = proc(mx.array(cumulative), mx.zeros((1, vocab)))
    for k, tid in enumerate(gen_ids):
        row = np.array(masked[0])
        allowed = bool(np.isfinite(row[tid]) and row[tid] > -1e30)
        if not allowed:
            return True, k
        cumulative.append(tid)
        masked = proc(mx.array(cumulative), mx.zeros((1, vocab)))
    return False, len(gen_ids)


@_requires_llguidance
def test_processor_baselines_past_prompt(tok, hermes_grammar, lltok):
    # MUST-FIX #1: the matcher must NOT be fed prompt tokens. mlx-lm hands the
    # full cumulative sequence each step; on the first call the processor must
    # baseline ``_prompt_len`` to the prompt length so only generated tokens
    # ever reach the matcher. A valid call over a non-empty prompt must pass.
    import mlx.core as mx

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    prompt_ids = tok.encode(
        "You are a helpful assistant. What's the weather in Paris?",
        add_special_tokens=False,
    )
    assert prompt_ids, "expected a non-empty prompt for the baseline test"

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
    # First call: everything present is the prompt (no token sampled yet).
    proc(mx.array(prompt_ids), mx.zeros((1, lltok.vocab_size)))
    assert proc._prompt_len == len(prompt_ids), (
        "processor did not baseline the matcher past the prompt — it would "
        "feed prompt tokens into the grammar matcher and break enforcement"
    )
    # And the matcher has consumed nothing yet (prompt is not committed to it).
    assert proc._committed == len(prompt_ids)

    # A valid hermes call over that same prompt baseline is fully allowed.
    blocked, _ = _feed_cumulative(
        proc,
        lltok,
        tok,
        prompt_ids,
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>',
    )
    assert not blocked, "valid call over a non-empty prompt was wrongly blocked"


@_requires_llguidance
def test_processor_consumes_only_new_tail_each_step(tok, hermes_grammar, lltok):
    """PERF/CORRECTNESS: each decode step feeds the matcher ONLY the newly
    generated token(s), never the already-committed prefix.

    mlx-lm hands the FULL cumulative ``prompt + generated`` sequence every
    step. A naive processor would ``consume_token`` the whole sequence each
    call — O(n^2) total consumes AND a double-consume that the matcher would
    reject. The ``_committed`` offset must gate consumption so that (a) the
    prompt baseline is never consumed and (b) exactly ONE consume happens per
    NEW generated token per step. We spy on the real matcher's
    ``consume_token`` to assert the exact call schedule.
    """
    import mlx.core as mx

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    prompt_ids = tok.encode("Weather please.", add_special_tokens=False)
    assert prompt_ids, "expected a non-empty prompt for the tail-consume test"

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)

    # Spy on the matcher's consume_token: record the (call_index -> token) log.
    # ``LLMatcher.consume_token`` is a read-only Rust attribute, so we cannot
    # patch the method in place — instead wrap the whole matcher in a thin proxy
    # that delegates every attribute to the real matcher but records each
    # ``consume_token`` call.
    consumed: list[int] = []
    real_matcher = proc._matcher

    class _SpyMatcher:
        def consume_token(self, tok_id):
            consumed.append(int(tok_id))
            return real_matcher.consume_token(tok_id)

        def __getattr__(self, name):
            return getattr(real_matcher, name)

    proc._matcher = _SpyMatcher()

    vocab = lltok.vocab_size
    gen_ids = tok.encode(
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>',
        add_special_tokens=False,
    )

    # First call: only the prompt is present — NOTHING must be consumed.
    proc(mx.array(list(prompt_ids)), mx.zeros((1, vocab)))
    assert consumed == [], (
        "processor consumed prompt tokens into the matcher — the baseline "
        "gate is broken and the grammar would reject the prompt"
    )

    # Then feed one new token per step over the full cumulative sequence.
    cumulative = list(prompt_ids)
    for k, tid in enumerate(gen_ids):
        cumulative.append(tid)
        before = len(consumed)
        proc(mx.array(cumulative), mx.zeros((1, vocab)))
        # Exactly ONE new consume per step (the new tail token), never a
        # re-consume of the already-committed prefix.
        assert len(consumed) - before == 1, (
            f"step {k}: expected exactly 1 new consume (the new tail token), "
            f"got {len(consumed) - before} — the processor is re-consuming "
            "the committed prefix (O(n^2))"
        )
        assert consumed[-1] == tid, (
            f"step {k}: consumed token {consumed[-1]} != the new tail token {tid}"
        )

    # Total consumes == number of generated tokens (linear, not quadratic).
    assert consumed == list(gen_ids), (
        "the full consume log must equal exactly the generated tokens in order "
        f"({len(consumed)} consumes for {len(gen_ids)} generated tokens)"
    )
    # ``_committed`` advanced exactly over prompt + generated.
    assert proc._committed == len(prompt_ids) + len(gen_ids)


@_requires_llguidance
def test_processor_negative_controls_over_prompt(tok, hermes_grammar, lltok):
    # The load-bearing #558 proof, exercised through the cumulative-baseline
    # path (non-empty prompt). A hallucinated tool name, an off-schema
    # argument, and a bad enum are all grammar-blocked mid-stream.
    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    prompt_ids = tok.encode("Weather please.", add_special_tokens=False)

    def _run(gen_text):
        proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
        return _feed_cumulative(proc, lltok, tok, prompt_ids, gen_text)[0]

    assert _run('<tool_call>\n{"name": "get_stockquote'), (
        "hallucinated tool name was NOT blocked"
    )
    assert _run('<tool_call>\n{"name": "get_weather", "arguments": {"city": 4'), (
        "off-schema integer argument was NOT blocked"
    )
    assert _run(
        '<tool_call>\n{"name": "get_weather", "arguments": {"city": "P", "unit": "kelvin'
    ), "invalid enum value was NOT blocked"


@_requires_llguidance
def test_named_grammar_constrains_to_single_tool(tok, lltok):
    # A NAMED choice narrows to one tool. Building the grammar over a
    # 1-element list with "required" forces exactly that tool; a call naming a
    # DIFFERENT (also-provided) tool is rejected.
    from vllm_mlx.api.tool_grammar import (
        GrammarLogitsProcessor,
        build_tool_grammar,
    )
    from vllm_mlx.tool_parsers.hermes_tool_parser import HermesToolParser

    parser = HermesToolParser(tokenizer=tok)
    only_time = [t for t in TOOLS if t["name"] == "get_time"]
    grammar = build_tool_grammar(only_time, "required", parser)
    # llguidance is present (test is @_requires_llguidance) and the hermes
    # structure_info is available -> None means a builder regression, fail hard.
    assert grammar is not None, (
        "build_tool_grammar returned None for a single-tool named narrow — "
        "the grammar builder regressed"
    )

    prompt_ids = tok.encode("time?", add_special_tokens=False)

    # get_time is allowed.
    proc = GrammarLogitsProcessor(lltok, grammar, tokenizer=tok)
    blocked, _ = _feed_cumulative(
        proc,
        lltok,
        tok,
        prompt_ids,
        '<tool_call>\n{"name": "get_time", "arguments": {"tz": "UTC"}}\n</tool_call>',
    )
    assert not blocked, "the named tool get_time was wrongly blocked"

    # get_weather (not the named target) is rejected.
    proc2 = GrammarLogitsProcessor(lltok, grammar, tokenizer=tok)
    blocked2, _ = _feed_cumulative(
        proc2, lltok, tok, prompt_ids, '<tool_call>\n{"name": "get_weather'
    )
    assert blocked2, "a non-named tool was NOT blocked under a named choice"


@_requires_llguidance
def test_tool_named_required_collision_end_to_end(tok, lltok):
    # Deferred codex #2, end-to-end: a tool literally named "required" is
    # constrainable as a single named tool (via the object form) WITHOUT the
    # grammar collapsing to the "required" enum over all tools. We build the
    # named grammar the way chat.py routing does: pre-narrow to the target +
    # "required" quantifier.
    from vllm_mlx.api.tool_grammar import (
        GrammarLogitsProcessor,
        build_tool_grammar,
    )
    from vllm_mlx.tool_parsers.hermes_tool_parser import HermesToolParser

    collide_tools = [
        {
            "name": "required",  # a tool whose name collides with the enum
            "parameters": {
                "type": "object",
                "properties": {"x": {"type": "string"}},
                "required": ["x"],
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
    parser = HermesToolParser(tokenizer=tok)
    # Named choice on the "required"-named tool: narrow then "required" quant.
    narrowed = [t for t in collide_tools if t["name"] == "required"]
    grammar = build_tool_grammar(narrowed, "required", parser)
    # llguidance present (test is @_requires_llguidance) + hermes structure_info
    # available -> None is a REGRESSION that would let the exact collision this
    # test guards ship green while production falls back to unconstrained
    # generation (codex #558-PR3). Assert, don't skip.
    assert grammar is not None, (
        "build_tool_grammar returned None for the 'required'-named collision "
        "case — the grammar builder regressed"
    )

    prompt_ids = tok.encode("go", add_special_tokens=False)

    # The "required"-named tool is allowed.
    proc = GrammarLogitsProcessor(lltok, grammar, tokenizer=tok)
    blocked, _ = _feed_cumulative(
        proc,
        lltok,
        tok,
        prompt_ids,
        '<tool_call>\n{"name": "required", "arguments": {"x": "y"}}\n</tool_call>',
    )
    assert not blocked, "the tool literally named 'required' was wrongly blocked"

    # The OTHER provided tool (get_time) is rejected — the named grammar is
    # single-tool, proving it did not collapse to a force-any-tool enum.
    proc2 = GrammarLogitsProcessor(lltok, grammar, tokenizer=tok)
    blocked2, _ = _feed_cumulative(
        proc2, lltok, tok, prompt_ids, '<tool_call>\n{"name": "get_time'
    )
    assert blocked2, (
        "named choice on the 'required'-named tool leaked another tool — "
        "the string collision was not contained"
    )


@_requires_llguidance
def test_processor_reset_clears_baseline(tok, hermes_grammar, lltok):
    # reset() must clear the prompt baseline and committed counter so the
    # processor can be reused for a fresh sequence.
    import mlx.core as mx

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
    prompt_ids = tok.encode("hi", add_special_tokens=False)
    proc(mx.array(prompt_ids), mx.zeros((1, lltok.vocab_size)))
    assert proc._prompt_len == len(prompt_ids)
    proc.reset()
    assert proc._prompt_len is None
    assert proc._committed == 0


@_requires_llguidance
def test_processor_preserves_padded_vocab_shape(tok, hermes_grammar, lltok):
    # codex #558-PR3: when the model head is WIDER than the tokenizer vocab
    # (padded embedding), the processor must return logits of the SAME final
    # dimension — mlx-lm concatenates every row's processed logits, so a
    # narrower return breaks batched decode. Verify shape is preserved and the
    # padded tail is -inf (never sampled).
    import mlx.core as mx
    import numpy as np

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
    prompt_ids = tok.encode("hi", add_special_tokens=False)
    pad = 128
    wide_vocab = lltok.vocab_size + pad
    out = proc(mx.array(prompt_ids), mx.zeros((1, wide_vocab)))
    assert out.shape[-1] == wide_vocab, "padded-vocab shape not preserved"
    tail = np.array(out[0, lltok.vocab_size :])
    assert np.all(tail == -np.inf), "padded tail must be -inf (never sampleable)"


@_requires_llguidance
def test_processor_equal_vocab_shape_unchanged(tok, hermes_grammar, lltok):
    # When model vocab == tokenizer vocab, the mask is applied in place and the
    # shape is unchanged (no concat path).
    import mlx.core as mx

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
    prompt_ids = tok.encode("hi", add_special_tokens=False)
    out = proc(mx.array(prompt_ids), mx.zeros((1, lltok.vocab_size)))
    assert out.shape[-1] == lltok.vocab_size


@_requires_llguidance
def test_processor_narrower_model_head_than_tokenizer(tok, hermes_grammar, lltok):
    # codex #558-PR3 blocking: the INVERSE of the padded case — the TOKENIZER
    # carries added tokens beyond a NARROWER model output head
    # (``model_vocab < tokenizer_vocab``). The full-vocab bitmask must not be
    # applied whole to the narrower logits (would over-cover); the processor
    # slices the packed bitmask to the model-width word count and masks cleanly,
    # returning the SAME narrow shape. Assert MASKING BEHAVIOR, not just shape:
    # the grammar must still forbid in-range tokens (some become ``-inf``) while
    # keeping at least one allowed — a shape-only check would stay green even if
    # the branch returned UNMASKED logits and silently disabled enforcement.
    import mlx.core as mx
    import numpy as np

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    proc = GrammarLogitsProcessor(lltok, hermes_grammar, tokenizer=tok)
    prompt_ids = tok.encode("hi", add_special_tokens=False)
    # Trim only a few ids off the top (not on a word boundary, to exercise the
    # ceil-division word count) so the constrained opener is still in range.
    narrow_vocab = lltok.vocab_size - 5
    out = proc(mx.array(prompt_ids), mx.zeros((1, narrow_vocab)))
    assert out.shape[-1] == narrow_vocab, "narrow-head shape not preserved"

    row = np.array(out[0])
    n_blocked = int(np.count_nonzero(~np.isfinite(row)))
    n_allowed = int(np.count_nonzero(np.isfinite(row)))
    # The mask MUST have been applied to the narrow logits: the input is
    # all-zeros (finite), so any ``-inf`` entry can only come from the grammar
    # mask. ``n_blocked > 0`` therefore proves enforcement is live on this path
    # (an unmasked passthrough would leave every entry finite). ``n_allowed > 0``
    # confirms the grammar still permits progress (not a broken all-mask). At
    # grammar position 0 the hermes lazy free-prefix allows most tokens, so we
    # do NOT assert a majority are blocked — only that masking demonstrably
    # occurred and left a valid, non-empty allowed set.
    assert n_blocked > 0, "narrow-head path returned UNMASKED logits (no enforcement)"
    assert n_allowed > 0, "narrow-head path masked EVERYTHING (grammar broken)"


@_requires_llguidance
def test_get_lltokenizer_caches(tok):
    # codex #558-PR3 (nit): the ~1s LLTokenizer build must be cached per
    # tokenizer, not rebuilt on every request.
    from vllm_mlx.api.tool_grammar import get_lltokenizer

    a = get_lltokenizer(tok)
    b = get_lltokenizer(tok)
    assert a is not None
    assert a is b, "get_lltokenizer must return the same cached instance"


@_requires_llguidance
def test_get_lltokenizer_transient_failure_is_retried(monkeypatch):
    # codex #558-PR3 nit: a TRANSIENT build failure must NOT permanently disable
    # grammar enforcement — it's retried up to the budget, and a subsequent
    # success is cached. A distinct dummy tokenizer avoids poisoning the shared
    # module-scoped ``tok`` fixture's cache.
    import vllm_mlx.api.tool_grammar as tg_mod

    class _DummyTok:
        pass

    dummy = _DummyTok()
    sentinel = object()
    calls = {"n": 0}

    def _flaky_build(_tokenizer):
        calls["n"] += 1
        # Fail the first two attempts (transient), succeed on the third.
        if calls["n"] < 3:
            return None
        return sentinel

    monkeypatch.setattr(tg_mod, "build_lltokenizer", _flaky_build)

    # First two calls hit transient failures and must NOT seal the cache.
    assert tg_mod.get_lltokenizer(dummy) is None
    assert tg_mod.get_lltokenizer(dummy) is None
    # Third call succeeds and is cached.
    assert tg_mod.get_lltokenizer(dummy) is sentinel
    # Cached: no further build calls.
    assert tg_mod.get_lltokenizer(dummy) is sentinel
    assert calls["n"] == 3, "success must be cached; no rebuild after it"


@_requires_llguidance
def test_get_lltokenizer_seals_after_budget(monkeypatch):
    # codex #558-PR3 nit: a PERSISTENT failure is eventually sealed as
    # unavailable (bounded retries) so we don't rebuild-and-fail forever.
    import vllm_mlx.api.tool_grammar as tg_mod

    class _DummyTok:
        pass

    dummy = _DummyTok()
    calls = {"n": 0}

    def _always_fail(_tokenizer):
        calls["n"] += 1
        return None

    monkeypatch.setattr(tg_mod, "build_lltokenizer", _always_fail)

    budget = tg_mod._LLTOKENIZER_MAX_BUILD_ATTEMPTS
    # Each call up to the budget retries the build.
    for _ in range(budget):
        assert tg_mod.get_lltokenizer(dummy) is None
    assert calls["n"] == budget, "must retry up to the budget"
    # Now sealed: further calls short-circuit without rebuilding.
    assert tg_mod.get_lltokenizer(dummy) is None
    assert calls["n"] == budget, "sealed after budget — no further rebuilds"


@_requires_llguidance
def test_missing_parameters_flattens_to_closed_schema_in_production_path(
    tok, monkeypatch
):
    # codex #558-PR3: drive the REAL ``_maybe_build_tool_grammar_processor`` and
    # capture the schema it flattens a no-``parameters`` tool into. Absent /
    # null ``parameters`` must become a CLOSED empty-object schema; an explicit
    # ``{}`` (allow-any) and an explicit schema must pass through verbatim.
    from vllm_mlx.api import tool_grammar as tg_mod
    from vllm_mlx.routes import chat as chat_mod

    captured = {}

    def _spy_build(flat_tools, mode, parser, *, single_call=False):
        captured["flat_tools"] = flat_tools
        captured["mode"] = mode
        captured["single_call"] = single_call
        return None  # short-circuit: we only need the flattened tools

    # ``build_tool_grammar`` is imported inside the route function, so patch it
    # at its defining module (the name the local import resolves to).
    monkeypatch.setattr(tg_mod, "build_tool_grammar", _spy_build)

    Fn = _FunctionTool
    engine = _EngineStub(tok)
    cfg = _CfgStub("hermes")

    def _run(tools, tool_choice):
        captured.clear()
        request = _RequestStub(tools=tools, tool_choice=tool_choice)
        # Returns None (build stub returns None) but populates ``captured``.
        chat_mod._maybe_build_tool_grammar_processor(engine, cfg, request)
        return {t["name"]: t["parameters"] for t in captured.get("flat_tools", [])}

    # Absent parameters -> closed empty-object schema.
    got = _run([Fn("noargs")], "required")
    assert got["noargs"] == {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    }
    # Explicit null -> closed.
    assert (
        _run([Fn("n", parameters=None)], "required")["n"]["additionalProperties"]
        is False
    )
    # Explicit {} -> preserved verbatim (allow-any).
    assert _run([Fn("n", parameters={})], "required")["n"] == {}
    # Explicit schema -> preserved verbatim.
    schema = {"type": "object", "properties": {"x": {"type": "string"}}}
    assert _run([Fn("n", parameters=schema)], "required")["n"] == schema


@_requires_llguidance
def test_parallel_tool_calls_false_threads_single_call(tok, monkeypatch):
    # codex #558-PR3 blocking: ``parallel_tool_calls=False`` must build an
    # exactly-one-call grammar (``single_call=True`` to the builder); ``True`` /
    # unset keep the one-or-more ``required`` grammar.
    from vllm_mlx.api import tool_grammar as tg_mod
    from vllm_mlx.routes import chat as chat_mod

    captured = {}

    def _spy_build(flat_tools, mode, parser, *, single_call=False):
        captured["single_call"] = single_call
        return None

    monkeypatch.setattr(tg_mod, "build_tool_grammar", _spy_build)

    engine = _EngineStub(tok)
    cfg = _CfgStub("hermes")

    class _Req:
        def __init__(self, ptc):
            self.tools = [_FunctionTool("get_time")]
            self.tool_choice = "required"
            self.parallel_tool_calls = ptc

    def _single_call_for(ptc):
        captured.clear()
        chat_mod._maybe_build_tool_grammar_processor(engine, cfg, _Req(ptc))
        return captured.get("single_call")

    assert _single_call_for(False) is True, "parallel_tool_calls=False -> single"
    assert _single_call_for(True) is False, "parallel_tool_calls=True -> one-or-more"
    assert _single_call_for(None) is False, "unset -> one-or-more (OpenAI default)"


@_requires_llguidance
def test_broken_grammar_yields_none_so_fallback_stays_active(tok, monkeypatch):
    # codex #558-PR3: a matcher that fails to compile is ``_broken`` and masks
    # NOTHING. ``_maybe_build_tool_grammar_processor`` must return ``None`` for
    # a broken processor so the route keeps the forced-prefix / free-form
    # fallback active — never set an inert ``grammar_logits_processor`` that
    # both disables the fallback AND leaves output unconstrained.
    from vllm_mlx.api import tool_grammar as tg_mod
    from vllm_mlx.routes import chat as chat_mod

    # Real builder path, but force the processor to report itself broken.
    class _BrokenProc:
        def __init__(self, *a, **k):
            pass

        def is_broken(self):
            return True

    monkeypatch.setattr(tg_mod, "build_tool_grammar", lambda *a, **k: "GRAMMAR")
    monkeypatch.setattr(tg_mod, "GrammarLogitsProcessor", _BrokenProc)

    engine = _EngineStub(tok)
    cfg = _CfgStub("hermes")
    request = _RequestStub(tools=[_FunctionTool("get_time")], tool_choice="required")

    result = chat_mod._maybe_build_tool_grammar_processor(engine, cfg, request)
    assert result is None, (
        "a broken (non-compiling) grammar must yield None so the established "
        "fallback stays active — an inert processor would disable the fallback "
        "AND leave output unconstrained"
    )


def test_broken_processor_reports_is_broken_and_masks_nothing():
    # Unit-level guarantee behind the fallback: a GrammarLogitsProcessor built
    # on an invalid grammar sets ``is_broken()`` and returns logits unchanged.
    import importlib.util

    if importlib.util.find_spec("llguidance") is None:
        pytest.skip("llguidance ([guided] extra) not installed")

    import mlx.core as mx

    from vllm_mlx.api.tool_grammar import GrammarLogitsProcessor

    class _FakeMatcher:
        def __init__(self, *a, **k):
            pass

        def get_error(self):
            return "unterminated grammar: deliberately invalid"

    class _FakeLLTok:
        vocab_size = 8

    import vllm_mlx.api.tool_grammar as tg

    # Patch the matcher + bitmask allocation so we don't need real llguidance
    # internals for this pure broken-path assertion.
    orig_matcher = tg.LLMatcher
    orig_alloc = tg.allocate_token_bitmask
    tg.LLMatcher = _FakeMatcher
    tg.allocate_token_bitmask = lambda n, v: None
    try:
        proc = GrammarLogitsProcessor(_FakeLLTok(), "bad-grammar")
        assert proc.is_broken() is True
        logits = mx.zeros((1, 8))
        out = proc(mx.array([1, 2, 3]), logits)
        # Broken -> logits returned unchanged (no mask), same object/shape.
        assert out.shape == logits.shape
        import numpy as np

        assert np.array_equal(np.array(out), np.array(logits))
    finally:
        tg.LLMatcher = orig_matcher
        tg.allocate_token_bitmask = orig_alloc


def test_forced_prefix_block_is_gated_on_grammar_absence():
    # codex #558-PR3: the forced assistant prefix and the grammar are mutually
    # exclusive — combining them baselines the injected prefix away and
    # bypasses schema enforcement. The route builds ``_glp`` FIRST and gates
    # the ``_forced_prefix`` block on ``_glp is None``. Assert that structural
    # guarantee in the route source so a future edit that re-enables both
    # together fails CI (a pure behavioral test would need to drive the whole
    # ~600-line ``_create_chat_completion_impl``).
    import inspect

    from vllm_mlx.routes import chat as chat_mod

    src = inspect.getsource(chat_mod._create_chat_completion_impl)
    glp_pos = src.find("_maybe_build_tool_grammar_processor")
    prefix_gate = src.find("if _glp is None and request.tools")
    assert glp_pos != -1, "grammar processor build call not found in route"
    assert prefix_gate != -1, (
        "forced-prefix block must be gated on '_glp is None' — the two are "
        "mutually exclusive (codex #558-PR3)"
    )
    assert glp_pos < prefix_gate, (
        "the grammar processor must be built BEFORE the forced-prefix gate"
    )
