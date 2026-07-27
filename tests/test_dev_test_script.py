# SPDX-License-Identifier: Apache-2.0
"""Regression coverage for the local developer test wrapper."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def test_unit_suite_timeout_covers_current_three_minute_runtime(monkeypatch):
    script = Path(__file__).parents[1] / "scripts" / "dev_test.py"
    spec = importlib.util.spec_from_file_location("rapid_mlx_dev_test", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    observed: dict[str, object] = {}

    def fake_run(cmd, label, timeout=600):
        observed.update(cmd=cmd, label=label, timeout=timeout)
        return True

    monkeypatch.setattr(module, "run", fake_run)

    assert module.run_unit() is True
    assert observed["timeout"] == 300
