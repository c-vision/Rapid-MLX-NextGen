# SPDX-License-Identifier: Apache-2.0
"""F-K-KOKORO-ESPEAK regression tests — espeak G2P readiness gate.

``misaki`` being importable is necessary but not sufficient for Kokoro:
its English G2P falls back to espeak-ng for out-of-dictionary words, and
on a fresh ``pip install 'rapid-mlx[audio]'`` the bundled ``espeakng-loader``
dylib can fail to find its data — a C-level abort inside
``espeak_Initialize`` that takes down the whole uvicorn worker and cannot
be caught from Python.

``require_kokoro_runtime`` therefore (1) self-tests espeak in a SUBPROCESS
so the abort kills a throwaway child instead of the server, and (2) repairs
the worker to a system espeak-ng (e.g. ``brew install espeak-ng``) when the
bundled one is broken — only 503'ing when neither can initialize.

These tests mock at the helper-function boundary so they are hermetic: no
real subprocess is spawned and no espeak install is required, so they run
in the base (no ``[audio]``) environment too.
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from vllm_mlx.audio import probe


@pytest.fixture(autouse=True)
def _reset_espeak():
    """Drop the cached espeak verdict around every test."""
    probe._reset_probe_cache()
    yield
    probe._reset_probe_cache()


def test_bundled_espeak_ok_no_repair(monkeypatch):
    """Bundled espeak self-test passes → ready, no system fallback tried."""
    calls: list[tuple] = []

    def _selftest(lib=None, data=None, timeout=30.0):
        calls.append((lib, data))
        return True  # bundled works

    def _discover():
        raise AssertionError("system discovery must not run when bundled OK")

    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", _selftest)
    monkeypatch.setattr(probe, "_discover_system_espeak", _discover)

    probe._ensure_kokoro_g2p_ready()  # must not raise
    assert probe._ESPEAK_READY is True
    assert calls == [(None, None)]  # bundled probe only


def test_bundled_broken_system_repairs(monkeypatch):
    """Bundled broken + system espeak works → repair applied, no raise."""
    applied: list[tuple] = []

    def _selftest(lib=None, data=None, timeout=30.0):
        # Bundled (no lib) fails; system (lib given) succeeds.
        return lib is not None

    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", _selftest)
    monkeypatch.setattr(
        probe,
        "_discover_system_espeak",
        lambda: [("/opt/homebrew/lib/libespeak-ng.1.dylib", "/opt/homebrew/share")],
    )
    monkeypatch.setattr(
        probe, "_apply_system_espeak", lambda lib, data: applied.append((lib, data))
    )

    probe._ensure_kokoro_g2p_ready()  # must not raise
    assert probe._ESPEAK_READY is True
    assert applied == [
        ("/opt/homebrew/lib/libespeak-ng.1.dylib", "/opt/homebrew/share")
    ]


def test_bundled_broken_no_system_503(monkeypatch):
    """Bundled broken + no system espeak → clean 503, worker survives."""
    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", lambda *a, **k: False)
    monkeypatch.setattr(probe, "_discover_system_espeak", lambda: [])

    with pytest.raises(HTTPException) as exc:
        probe._ensure_kokoro_g2p_ready()
    assert exc.value.status_code == 503
    assert "espeak-ng" in str(exc.value.detail)
    assert probe._ESPEAK_READY is False


def test_bundled_broken_system_also_broken_503(monkeypatch):
    """A discovered system espeak that also fails its self-test → 503."""
    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", lambda *a, **k: False)
    monkeypatch.setattr(
        probe, "_discover_system_espeak", lambda: [("/x/lib.dylib", "/x/share")]
    )
    apply_calls: list = []
    monkeypatch.setattr(
        probe, "_apply_system_espeak", lambda lib, data: apply_calls.append(1)
    )

    with pytest.raises(HTTPException) as exc:
        probe._ensure_kokoro_g2p_ready()
    assert exc.value.status_code == 503
    assert apply_calls == []  # never repair with an unverified system install


def test_ready_verdict_is_cached(monkeypatch):
    """Once ready, subsequent calls short-circuit without re-probing."""
    probe_calls = {"n": 0}

    def _selftest(lib=None, data=None, timeout=30.0):
        probe_calls["n"] += 1
        return True

    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", _selftest)
    probe._ensure_kokoro_g2p_ready()
    probe._ensure_kokoro_g2p_ready()
    probe._ensure_kokoro_g2p_ready()
    assert probe_calls["n"] == 1  # probed once, cached thereafter


def test_broken_verdict_is_cached(monkeypatch):
    """A 503 verdict is cached too — no repeated subprocess storms."""
    probe_calls = {"n": 0}

    def _selftest(lib=None, data=None, timeout=30.0):
        probe_calls["n"] += 1
        return False

    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", _selftest)
    monkeypatch.setattr(probe, "_discover_system_espeak", lambda: [])

    for _ in range(3):
        with pytest.raises(HTTPException):
            probe._ensure_kokoro_g2p_ready()
    assert probe_calls["n"] == 1  # first call probed; rest hit cached False


def test_concurrent_first_requests_probe_once(monkeypatch):
    """Concurrent cold-worker requests coalesce to a single probe (lock)."""
    import threading

    probe_calls = {"n": 0}
    counter_lock = threading.Lock()
    release = threading.Event()

    def _selftest(lib=None, data=None, timeout=30.0):
        with counter_lock:
            probe_calls["n"] += 1
        release.wait(1.0)  # hold the espeak lock so peers pile up behind it
        return True

    monkeypatch.setattr(probe, "_espeak_selftest_subprocess", _selftest)

    threads = [
        threading.Thread(target=probe._ensure_kokoro_g2p_ready) for _ in range(5)
    ]
    for th in threads:
        th.start()
    release.set()
    for th in threads:
        th.join(2.0)

    assert probe._ESPEAK_READY is True
    assert probe_calls["n"] == 1  # the lock coalesced 5 requests into 1 probe


def test_require_kokoro_runtime_missing_misaki_503(monkeypatch):
    """Missing misaki still 503s with the extra-install hint (unchanged)."""
    import importlib.util as _ilu

    real = _ilu.find_spec

    def _fake(name, *a, **k):
        if name == "misaki":
            return None
        return real(name, *a, **k)

    monkeypatch.setattr(_ilu, "find_spec", _fake)

    def _guard():
        raise AssertionError("g2p readiness must not run when misaki missing")

    monkeypatch.setattr(probe, "_ensure_kokoro_g2p_ready", _guard)

    with pytest.raises(HTTPException) as exc:
        probe.require_kokoro_runtime()
    assert exc.value.status_code == 503
    assert "misaki" in str(exc.value.detail)


def test_require_kokoro_runtime_present_misaki_runs_g2p_check(monkeypatch):
    """misaki present → the espeak readiness gate is exercised."""
    import importlib.util as _ilu

    real = _ilu.find_spec
    monkeypatch.setattr(
        _ilu,
        "find_spec",
        lambda name, *a, **k: object() if name == "misaki" else real(name, *a, **k),
    )
    ran = {"n": 0}
    monkeypatch.setattr(
        probe, "_ensure_kokoro_g2p_ready", lambda: ran.__setitem__("n", ran["n"] + 1)
    )

    probe.require_kokoro_runtime()
    assert ran["n"] == 1


def test_discover_system_espeak_empty_when_absent(monkeypatch):
    """No espeak-ng anywhere (PATH, prefixes, loader) → empty candidate list."""
    import ctypes.util
    import os
    import shutil

    monkeypatch.setattr(shutil, "which", lambda name: None)
    monkeypatch.setattr(os.path, "exists", lambda p: False)
    monkeypatch.setattr(ctypes.util, "find_library", lambda name: None)
    assert probe._discover_system_espeak() == []


def test_resolve_lib_path_soname_to_multiarch(monkeypatch):
    """A bare Linux soname resolves to its multiarch absolute path."""
    import os
    import sysconfig

    target = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1"
    monkeypatch.setattr(os.path, "exists", lambda p: p == target)
    monkeypatch.setattr(
        sysconfig,
        "get_config_var",
        lambda k: "x86_64-linux-gnu" if k == "MULTIARCH" else None,
    )
    assert probe._resolve_lib_path("libespeak-ng.so.1") == target


def test_resolve_lib_path_absolute_passthrough(monkeypatch):
    """An absolute existing path is returned as-is; a missing one → None."""
    import os

    monkeypatch.setattr(os.path, "exists", lambda p: p == "/opt/x/lib.dylib")
    assert probe._resolve_lib_path("/opt/x/lib.dylib") == "/opt/x/lib.dylib"
    assert probe._resolve_lib_path("/opt/missing/lib.dylib") is None


def test_discover_resolves_find_library_soname(monkeypatch):
    """find_library soname + a valid data dir → an absolute-path candidate."""
    import ctypes.util
    import os
    import shutil

    lib = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1"
    phontab = "/usr/share/espeak-ng-data/phontab"
    monkeypatch.setattr(shutil, "which", lambda name: None)
    monkeypatch.setattr(ctypes.util, "find_library", lambda name: "libespeak-ng.so.1")
    monkeypatch.setattr(os.path, "exists", lambda p: p in (lib, phontab))
    monkeypatch.setattr(
        probe, "_resolve_lib_path", lambda n: lib if n == "libespeak-ng.so.1" else None
    )
    pairs = probe._discover_system_espeak()
    assert (lib, "/usr/share") in pairs


def test_discover_system_espeak_finds_real_install():
    """On a host with espeak-ng installed, discovery yields usable pairs.

    Skipped when no espeak-ng is present so CI without it still passes.
    Each returned pair must have an existing library file and a data dir
    that actually contains ``espeak-ng-data/phontab``.
    """
    import os
    import shutil

    if not (shutil.which("espeak-ng") or shutil.which("espeak")):
        pytest.skip("no system espeak-ng installed")
    pairs = probe._discover_system_espeak()
    assert pairs, "espeak-ng is installed but discovery found no candidates"
    for lib, data in pairs:
        assert os.path.exists(lib), lib
        assert os.path.exists(os.path.join(data, "espeak-ng-data", "phontab")), data
