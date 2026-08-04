# SPDX-License-Identifier: Apache-2.0
"""Regression tests for #1254 — Kokoro TTS first ``/v1/audio/speech`` request
returns HTTP 500 when the spaCy G2P model (``en_core_web_sm``) is missing and
gets auto-downloaded by ``misaki`` under a launcher with no active venv
(uv-tool / bare console script).

Root cause: ``misaki/en.py`` calls ``spacy.cli.download("en_core_web_sm")`` on
first generate; spaCy's installer is ``sys.executable -m pip`` when ``pip`` is
importable, else ``uv pip`` (the uv-tool case). ``uv pip`` aborts with
``SystemExit`` — "No virtual environment found" — which is NOT caught by the
route's ``except Exception`` → an opaque 500.

Fix: the Kokoro route-boundary gate (``require_kokoro_runtime``) pre-resolves
the model in a contained subprocess with a launcher-independent env, and on
failure raises a clean ``HTTPException(503)`` the route re-raises verbatim —
never a ``RuntimeError`` (→ generic 500) nor a ``SystemExit``.

Two properties these tests pin, both codex-caught:
  * BLOCKING — the failure surfaces as ``HTTPException(status_code=503)``, so
    the user actually sees the actionable 503, not the route's catch-all 500.
  * MAJOR — the installer always targets THIS interpreter (``VIRTUAL_ENV`` is
    forced to ``sys.prefix``, overriding an inherited outer-shell value), and a
    post-install re-check verifies the model is importable here — otherwise a
    child ``uv pip`` could "succeed" into the wrong env and leave misaki's
    SystemExit-y runtime download reachable.

Hermetic: spaCy and the subprocess are faked, so these run without the
``[audio]`` extra installed.
"""

import importlib.util
import subprocess
import sys
import types

import pytest

from vllm_mlx.audio import probe
from vllm_mlx.audio.probe import (
    _KOKORO_G2P_SPACY_MODEL,
    _ensure_kokoro_g2p_model_ready,
    _g2p_installer_env,
    _kokoro_voice_needs_en_g2p,
    _probe_kokoro_g2p_model,
    _reset_g2p_model_state,
    require_kokoro_runtime,
)


@pytest.fixture(autouse=True)
def _fresh_verdict():
    # The readiness verdict is cached per-process; reset it around every test
    # so caching-specific tests start clean and don't leak into their peers.
    _reset_g2p_model_state()
    yield
    _reset_g2p_model_state()


# --- MAJOR fix: the installer must target the RUNNING interpreter's env ------


def test_env_forces_virtualenv_over_inherited_mismatch():
    # The #1254 MAJOR: an outer activated shell exports VIRTUAL_ENV=/other, but
    # the model must land in THIS interpreter's env (/opt/venv). Force it.
    env = _g2p_installer_env(
        {"VIRTUAL_ENV": "/other", "PATH": "/bin"}, "/opt/venv", prefix_is_venv=True
    )
    assert env["VIRTUAL_ENV"] == "/opt/venv"
    assert env["PATH"] == "/bin"  # unrelated keys preserved


def test_env_sets_virtualenv_when_venv_and_unset():
    env = _g2p_installer_env({"PATH": "/bin"}, "/opt/venv", prefix_is_venv=True)
    assert env["VIRTUAL_ENV"] == "/opt/venv"


def test_env_skips_non_venv_prefix():
    env = _g2p_installer_env({}, "/usr", prefix_is_venv=False)
    assert "VIRTUAL_ENV" not in env  # system Python → don't fabricate a venv


def test_env_non_venv_drops_inherited_virtualenv():
    # Not a venv interpreter → DROP an inherited VIRTUAL_ENV so a child `uv pip`
    # can't install the model into that unrelated outer env (with no venv it
    # errors cleanly → our caught failure → 503, instead of silent pollution).
    env = _g2p_installer_env(
        {"VIRTUAL_ENV": "/outer", "PATH": "/bin"}, "/usr", prefix_is_venv=False
    )
    assert "VIRTUAL_ENV" not in env
    assert env["PATH"] == "/bin"  # unrelated keys preserved


def test_env_does_not_mutate_input():
    src = {"A": "1"}
    _g2p_installer_env(src, "/opt/venv", prefix_is_venv=True)
    assert src == {"A": "1"}


# --- the probe (fake spaCy so no [audio] extra is required) ------------------


def _fake_spacy(monkeypatch, state):
    """Install a fake ``spacy.util`` whose ``is_package`` reflects a mutable
    ``state['installed']`` flag, so the pre-check and the post-install re-check
    can observe different values within one probe run."""
    util = types.ModuleType("spacy.util")
    util.is_package = lambda name: bool(state.get("installed"))
    spacy = types.ModuleType("spacy")
    spacy.util = util
    monkeypatch.setitem(sys.modules, "spacy", spacy)
    monkeypatch.setitem(sys.modules, "spacy.util", util)


def test_probe_noop_when_model_present(monkeypatch):
    _fake_spacy(monkeypatch, {"installed": True})
    calls = []
    monkeypatch.setattr(probe, "_spacy_download_subprocess", lambda *a: calls.append(a))
    assert _probe_kokoro_g2p_model() == (True, None)
    assert calls == []  # already installed → never shells out (fast happy path)


def test_probe_installs_absent_model_then_verifies(monkeypatch):
    state = {"installed": False}
    _fake_spacy(monkeypatch, state)
    seen = {}

    def fake_install(cmd, env, timeout):
        seen["cmd"] = cmd
        seen["env"] = env
        seen["timeout"] = timeout
        state["installed"] = True  # the install makes the model importable

    monkeypatch.setattr(probe, "_spacy_download_subprocess", fake_install)
    assert _probe_kokoro_g2p_model() == (True, None)
    # runs spaCy's OWN resolver via THIS interpreter (not a bare `spacy`/`uv`)
    assert seen["cmd"][:3] == [sys.executable, "-m", "spacy"]
    assert seen["cmd"][-1] == _KOKORO_G2P_SPACY_MODEL
    assert seen["timeout"] == 300
    # a launcher-independent env dict was built (its exact VIRTUAL_ENV logic is
    # pinned by the _g2p_installer_env branch-table tests above)
    assert seen["env"] is not None


def test_probe_reports_failure_on_subprocess_error(monkeypatch, caplog):
    _fake_spacy(monkeypatch, {"installed": False})
    secret = "https://user:token@internal.pkgs.example/simple  (host=build-07)"

    def boom(cmd, env, timeout):
        raise subprocess.CalledProcessError(1, cmd, stderr=secret)

    monkeypatch.setattr(probe, "_spacy_download_subprocess", boom)
    with caplog.at_level("ERROR"):
        ready, reason = _probe_kokoro_g2p_model()
    assert ready is False
    # actionable hint (model + a recovery command), but NO raw installer stderr
    assert _KOKORO_G2P_SPACY_MODEL in reason
    assert "spacy download" in reason
    # pr_validate BLOCKING: the raw stderr (index URLs / hosts / creds) must
    # NEVER reach the client-facing 503 body OR the server log (secret-in-logs).
    for sink in (reason, caplog.text):
        assert secret not in sink
        assert "internal.pkgs.example" not in sink
    # the log still records the failure SHAPE for the operator
    assert "CalledProcessError" in caplog.text


def test_probe_fails_when_install_succeeds_but_model_invisible(monkeypatch):
    # A child `uv pip` honouring a mismatched VIRTUAL_ENV can exit 0 while the
    # wheel lands in the WRONG env — the model is still not importable here.
    # Fail closed (503), don't declare ready.
    _fake_spacy(monkeypatch, {"installed": False})  # stays False after "install"
    monkeypatch.setattr(probe, "_spacy_download_subprocess", lambda cmd, env, t: None)
    ready, reason = _probe_kokoro_g2p_model()
    assert ready is False
    assert _KOKORO_G2P_SPACY_MODEL in reason


def test_probe_contains_missing_executable(monkeypatch):
    _fake_spacy(monkeypatch, {"installed": False})

    def missing(cmd, env, timeout):
        raise FileNotFoundError()

    monkeypatch.setattr(probe, "_spacy_download_subprocess", missing)
    ready, reason = _probe_kokoro_g2p_model()
    assert ready is False and _KOKORO_G2P_SPACY_MODEL in reason


def test_probe_never_raises_when_is_package_errors(monkeypatch):
    # pr_validate BLOCKING: the probe's contract is "never raise" — even if
    # spacy.util.is_package itself throws (corrupt dist metadata), the outer
    # guard converts it to a (False, hint) verdict, not an opaque route 500.
    util = types.ModuleType("spacy.util")

    def _boom(name):
        raise RuntimeError("corrupt en_core_web_sm-*.dist-info METADATA")

    util.is_package = _boom
    spacy = types.ModuleType("spacy")
    spacy.util = util
    monkeypatch.setitem(sys.modules, "spacy", spacy)
    monkeypatch.setitem(sys.modules, "spacy.util", util)
    ready, reason = _probe_kokoro_g2p_model()
    assert ready is False
    assert _KOKORO_G2P_SPACY_MODEL in reason


# --- unimportable spaCy fails CLOSED (past the misaki gate, spaCy is required) -


def test_probe_unimportable_spacy_fails_closed(monkeypatch):
    # Reached only past the misaki-present gate, and misaki hard-depends on
    # spaCy — so an unimportable spaCy (here a torn ``spacy.util``) is a broken
    # install: fail closed (503), never shell out, never claim ready. Masking
    # it as ready would resurface as the opaque 500 this fix prevents.
    monkeypatch.setitem(sys.modules, "spacy", None)  # → ModuleNotFoundError(spacy.util)
    called = []
    monkeypatch.setattr(
        probe, "_spacy_download_subprocess", lambda *a: called.append(a)
    )
    ready, reason = _probe_kokoro_g2p_model()
    assert ready is False
    assert _KOKORO_G2P_SPACY_MODEL in reason
    assert called == []  # never attempts an install on a broken interpreter


# --- BLOCKING fix: failure surfaces as HTTPException(503), never 500 ----------


def test_ensure_raises_503_httpexception_not_500(monkeypatch):
    from fastapi import HTTPException

    monkeypatch.setattr(
        probe, "_probe_kokoro_g2p_model", lambda: (False, "boom, install me")
    )
    with pytest.raises(HTTPException) as excinfo:
        _ensure_kokoro_g2p_model_ready()
    # the whole point of #1254: the caller (route) sees a 503, not the
    # catch-all 500 a bare RuntimeError would collapse into.
    assert excinfo.value.status_code == 503
    assert excinfo.value.detail == "boom, install me"


def test_ensure_noop_when_ready(monkeypatch):
    monkeypatch.setattr(probe, "_probe_kokoro_g2p_model", lambda: (True, None))
    _ensure_kokoro_g2p_model_ready()  # must not raise


def test_ensure_caches_verdict(monkeypatch):
    calls = []

    def counting_probe():
        calls.append(1)
        return (True, None)

    monkeypatch.setattr(probe, "_probe_kokoro_g2p_model", counting_probe)
    _ensure_kokoro_g2p_model_ready()
    _ensure_kokoro_g2p_model_ready()
    assert len(calls) == 1  # one-time install, coalesced across requests


def test_ensure_transient_503_when_install_in_flight(monkeypatch):
    # pr_validate BLOCKING: a request that finds the install already in flight
    # must NOT block a worker thread on the lock for the whole 300 s window —
    # it returns a transient, retryable 503 and never runs the probe itself.
    from fastapi import HTTPException

    ran = []
    monkeypatch.setattr(
        probe, "_probe_kokoro_g2p_model", lambda: ran.append(1) or (True, None)
    )
    # simulate another request mid-install by holding the single-flight lock
    assert probe._G2P_MODEL_LOCK.acquire(blocking=False)
    try:
        with pytest.raises(HTTPException) as excinfo:
            _ensure_kokoro_g2p_model_ready()
        assert excinfo.value.status_code == 503
        assert "retry" in excinfo.value.detail.lower()
        assert ran == []  # never contended on the probe under lock pressure
    finally:
        probe._G2P_MODEL_LOCK.release()


def test_ensure_retries_failed_verdict_after_cooldown(monkeypatch):
    # pr_validate BLOCKING: a FAILED verdict is cached only for a cooldown, so a
    # transient outage doesn't disable Kokoro until restart — after the window
    # we re-probe, and a now-present dependency caches success (no restart).
    import time

    from fastapi import HTTPException

    clock = {"t": 1000.0}
    monkeypatch.setattr(time, "monotonic", lambda: clock["t"])

    calls = []

    def probe_fn():
        calls.append(1)
        return (False, "install boom") if len(calls) == 1 else (True, None)

    monkeypatch.setattr(probe, "_probe_kokoro_g2p_model", probe_fn)

    # 1st attempt fails → 503, cached with a cooldown
    with pytest.raises(HTTPException) as e1:
        _ensure_kokoro_g2p_model_ready()
    assert e1.value.status_code == 503 and e1.value.detail == "install boom"
    assert len(calls) == 1

    # within the cooldown → served from cache, probe NOT re-run
    with pytest.raises(HTTPException):
        _ensure_kokoro_g2p_model_ready()
    assert len(calls) == 1

    # after the cooldown → re-probe; dependency now present → ready (no restart)
    clock["t"] += probe._G2P_MODEL_RETRY_COOLDOWN_S + 1
    _ensure_kokoro_g2p_model_ready()  # must not raise
    assert len(calls) == 2


# --- route-boundary wiring: the gate propagates the 503, doesn't swallow it --


def test_require_kokoro_runtime_propagates_model_503(monkeypatch):
    from fastapi import HTTPException

    # misaki present (extra installed), espeak fine — but the spaCy model can't
    # be resolved. require_kokoro_runtime must let that 503 out untouched.
    monkeypatch.setattr(importlib.util, "find_spec", lambda name: object())
    monkeypatch.setattr(probe, "_ensure_kokoro_g2p_ready", lambda: None)
    monkeypatch.setattr(
        probe,
        "_ensure_kokoro_g2p_model_ready",
        lambda: (_ for _ in ()).throw(
            HTTPException(status_code=503, detail="model missing")
        ),
    )
    with pytest.raises(HTTPException) as excinfo:
        require_kokoro_runtime()
    assert excinfo.value.status_code == 503
    assert excinfo.value.detail == "model missing"


# --- gate COVERAGE: the route must gate every model the engine treats as -----
# --- Kokoro, not just names containing "kokoro" (the engine defaults unknown --
# --- names to Kokoro, so a substring gate would miss them → SystemExit 500). --


def test_is_kokoro_family_covers_explicit_and_default():
    from vllm_mlx.audio.tts import is_kokoro_family_model

    # registered kokoro model → gated
    assert is_kokoro_family_model("mlx-community/Kokoro-82M-bf16") is True
    # unregistered / renamed repo → name default is kokoro → still gated (so a
    # renamed Kokoro repo not in the registry keeps the readiness check)
    assert is_kokoro_family_model("acme/MysteryTTS-v2") is True


def test_gate_matches_engine_family_for_every_registered_tts_model():
    # The route gate MUST agree with the family the ENGINE actually loads /
    # generates with — otherwise the route could skip the Kokoro runtime check
    # for a model the engine still runs through the Kokoro path (or vice-versa).
    # This includes Dia, which the engine's name fallthrough runs as Kokoro
    # (there is no separate 'dia' generate branch), so the gate treats it as
    # Kokoro too. Consistency > cleverness.
    from vllm_mlx.audio.registry import tts_aliases
    from vllm_mlx.audio.tts import TTSEngine, is_kokoro_family_model

    for alias, hf_id in tts_aliases().items():
        engine_family = TTSEngine(hf_id)._detect_family(hf_id)
        expect_gated = engine_family == "kokoro"
        # both the resolved HF id AND the short alias must classify the same
        assert is_kokoro_family_model(hf_id) is expect_gated, (
            alias,
            hf_id,
            engine_family,
        )
        assert is_kokoro_family_model(alias) is expect_gated, (alias, engine_family)


def test_detect_family_method_matches_module_ssot():
    from vllm_mlx.audio.tts import TTSEngine, detect_tts_family

    for name in (
        "mlx-community/Kokoro-82M-bf16",
        "acme/MysteryTTS-v2",
        "mlx-community/chatterbox-turbo-fp16",
    ):
        assert TTSEngine(name)._detect_family(name) == detect_tts_family(name)


# --- startup deep probe must CONTAIN misaki's SystemExit, never abort boot ----


def test_dry_run_tts_contains_systemexit(monkeypatch):
    # #1254: misaki's spaCy download shells out to `uv pip`, which sys.exit()s
    # under a uv-tool launcher. That SystemExit (a BaseException) must NOT abort
    # a RAPID_MLX_AUDIO_DEEP_PROBE startup — the dry-run reports degraded.
    from vllm_mlx.audio import tts as tts_mod

    class _FakeEngine:
        def __init__(self, name):
            pass

        def load(self):
            pass

        def generate(self, *a, **k):
            raise SystemExit("No virtual environment found")

    monkeypatch.setattr(tts_mod, "TTSEngine", _FakeEngine)
    ok, reason = probe._dry_run_tts("mlx-community/Kokoro-82M-bf16")
    assert ok is False
    assert "SystemExit" in reason  # contained + reported, not propagated


# --- the English-only en_core_web_sm gate is gated by VOICE language ----------


def test_voice_language_gate_classifies():
    # American / British English voices use misaki.en → need en_core_web_sm.
    assert _kokoro_voice_needs_en_g2p("af_heart") is True
    assert _kokoro_voice_needs_en_g2p("bm_george") is True
    # other languages use their own tokenizers, NOT spaCy-English.
    for v in ("jf_alpha", "zf_xiaobei", "ef_dora", "ff_siwis", "if_sara", "pf_dora"):
        assert _kokoro_voice_needs_en_g2p(v) is False
    # omitted/unknown → default English (canonical default af_heart is English)
    assert _kokoro_voice_needs_en_g2p(None) is True
    assert _kokoro_voice_needs_en_g2p("") is True


def test_require_kokoro_runtime_skips_en_model_for_non_english_voice(monkeypatch):
    # pr_validate BLOCKING: a Japanese Kokoro voice must NOT be forced through
    # the spaCy-English gate (misaki.ja doesn't use en_core_web_sm).
    monkeypatch.setattr(importlib.util, "find_spec", lambda name: object())
    monkeypatch.setattr(probe, "_ensure_kokoro_g2p_ready", lambda: None)
    ran = []
    monkeypatch.setattr(probe, "_ensure_kokoro_g2p_model_ready", lambda: ran.append(1))

    require_kokoro_runtime("jf_alpha")  # Japanese → skip the en gate
    assert ran == []
    require_kokoro_runtime("af_heart")  # English → run the en gate
    assert ran == [1]


# --- installer runs in its own process group; timeout reaps the WHOLE tree ----


def test_spacy_download_kills_process_group_on_timeout(monkeypatch):
    import os
    import signal
    import subprocess as _sp

    killed = {}

    class _FakeProc:
        pid = 4321
        returncode = None
        stdout = stderr = stdin = None

        def communicate(self, timeout=None):
            raise _sp.TimeoutExpired(cmd="spacy", timeout=timeout)

        def kill(self):
            killed["direct"] = True

        def wait(self, timeout=None):
            return 0

    popen_kwargs = {}

    def _fake_popen(*a, **k):
        popen_kwargs.update(k)
        return _FakeProc()

    monkeypatch.setattr(_sp, "Popen", _fake_popen)
    monkeypatch.setattr(os, "getpgid", lambda pid: pid)
    monkeypatch.setattr(
        os, "killpg", lambda pgid, sig: killed.__setitem__("pgid", (pgid, sig))
    )
    with pytest.raises(_sp.TimeoutExpired):
        probe._spacy_download_subprocess(["x"], {}, timeout=1)
    # MUST start its own session/group — otherwise killpg(getpgid(child)) would
    # signal the SERVER's own process group. This assertion is what makes the
    # killpg check below meaningful (it fails if start_new_session is dropped).
    assert popen_kwargs.get("start_new_session") is True
    # the WHOLE group is SIGKILLed, not just the direct child (no orphaned pip)
    assert killed["pgid"] == (4321, signal.SIGKILL)
    assert "direct" not in killed  # killpg succeeded → no single-child fallback


def test_spacy_download_raises_calledprocesserror_on_nonzero_exit(monkeypatch):
    import subprocess as _sp

    class _FakeProc:
        pid = 1
        returncode = 7

        def communicate(self, timeout=None):
            return ("", "boom stderr")

    monkeypatch.setattr(_sp, "Popen", lambda *a, **k: _FakeProc())
    with pytest.raises(_sp.CalledProcessError) as e:
        probe._spacy_download_subprocess(["x"], {}, timeout=1)
    assert e.value.returncode == 7
