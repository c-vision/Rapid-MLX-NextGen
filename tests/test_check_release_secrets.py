# SPDX-License-Identifier: Apache-2.0
"""Unit tests for ``scripts/check_release_secrets.py``.

Pure stdlib + PyYAML — runs on Linux CI without MLX. Tests synthesize tiny
workflow YAMLs in tmp dirs so the production workflow files don't affect the
assertions.
"""

from __future__ import annotations

import importlib.util
import pathlib
import textwrap

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check_release_secrets.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_release_secrets", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def crs():
    return _load_module()


def _make_workflow(tmp_path: pathlib.Path, body: str) -> pathlib.Path:
    wf = tmp_path / "test.yml"
    wf.write_text(textwrap.dedent(body))
    return wf


# ---------- reference extraction --------------------------------------


def test_collects_secret_and_var_references(crs, tmp_path):
    wf = _make_workflow(
        tmp_path,
        """
        jobs:
          x:
            steps:
              - env:
                  TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
                  ZONE: ${{ secrets.CLOUDFLARE_ZONE_ID }}
                  BUCKET: ${{ vars.RAPID_MAC_DIST_R2_BUCKET }}
                run: echo hi
        """,
    )
    secrets, variables = crs.referenced_names(wf.read_text())
    assert secrets == {"CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ZONE_ID"}
    assert variables == {"RAPID_MAC_DIST_R2_BUCKET"}


def test_collects_bracket_notation_references(crs, tmp_path):
    """``secrets['FOO']`` / ``vars["BAR"]`` resolve exactly like the dot form.

    A future edit to the release workflow that uses index syntax must not
    silently drop out of the derived required set — that would reopen the
    #1851 drift the gate exists to close.
    """
    wf = _make_workflow(
        tmp_path,
        """
        jobs:
          x:
            steps:
              - env:
                  TOKEN: ${{ secrets['CLOUDFLARE_API_TOKEN'] }}
                  ZONE: ${{ secrets["CLOUDFLARE_ZONE_ID"] }}
                  BUCKET: ${{ vars['RAPID_MAC_DIST_R2_BUCKET'] }}
                run: echo hi
        """,
    )
    secrets, variables = crs.referenced_names(wf.read_text())
    assert secrets == {"CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ZONE_ID"}
    assert variables == {"RAPID_MAC_DIST_R2_BUCKET"}


def test_github_token_is_not_a_requirement(crs, tmp_path):
    """Actions injects it; its absence from the context proves nothing."""
    wf = _make_workflow(
        tmp_path,
        """
        jobs:
          x:
            steps:
              - env:
                  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                run: echo hi
        """,
    )
    secrets, _ = crs.referenced_names(wf.read_text())
    assert secrets == set()


def test_yaml_comment_is_not_a_reference(crs, tmp_path):
    """A header documenting a credential must not count as using it.

    ``rapid-mac-release.yml`` has exactly this shape — a comment block naming
    the secrets the release needs. Counting those would make the gate assert
    on documentation rather than on wiring.
    """
    wf = _make_workflow(
        tmp_path,
        """
        # Required for tagged releases: secrets.LEGACY_DOCUMENTED_ONLY
        jobs:
          x:
            steps:
              - env:
                  TOKEN: ${{ secrets.REAL_ONE }}
                run: echo hi
        """,
    )
    secrets, _ = crs.referenced_names(wf.read_text())
    assert secrets == {"REAL_ONE"}


def test_prose_outside_an_expression_is_not_a_reference(crs, tmp_path):
    """Only ``${{ }}`` contents count — a run script may mention a name."""
    wf = _make_workflow(
        tmp_path,
        """
        jobs:
          x:
            steps:
              - run: echo "set secrets.NOT_A_REF to enable mirroring"
        """,
    )
    secrets, _ = crs.referenced_names(wf.read_text())
    assert secrets == set()


# ---------- available-context parsing ---------------------------------


def test_load_available_reads_keys_only(crs, monkeypatch):
    monkeypatch.setenv("AVAILABLE_SECRETS_JSON", '{"A":"supersecret","B":"x"}')
    assert crs.load_available("AVAILABLE_SECRETS_JSON") == {"A", "B"}


def test_load_available_rejects_unset(crs, monkeypatch):
    monkeypatch.delenv("AVAILABLE_SECRETS_JSON", raising=False)
    with pytest.raises(SystemExit):
        crs.load_available("AVAILABLE_SECRETS_JSON")


def test_load_available_rejects_non_json(crs, monkeypatch):
    monkeypatch.setenv("AVAILABLE_SECRETS_JSON", "not json")
    with pytest.raises(SystemExit):
        crs.load_available("AVAILABLE_SECRETS_JSON")


# ---------- end to end -------------------------------------------------


def _run_main(crs, monkeypatch, wf, secrets_json, vars_json) -> int:
    monkeypatch.setenv("AVAILABLE_SECRETS_JSON", secrets_json)
    monkeypatch.setenv("AVAILABLE_VARS_JSON", vars_json)
    monkeypatch.setattr("sys.argv", ["check_release_secrets.py", str(wf)])
    return crs.main()


_WORKFLOW = """
jobs:
  x:
    steps:
      - env:
          TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          BUCKET: ${{ vars.R2_BUCKET }}
        run: echo hi
"""


def test_main_passes_when_everything_is_configured(crs, tmp_path, monkeypatch):
    wf = _make_workflow(tmp_path, _WORKFLOW)
    rc = _run_main(
        crs, monkeypatch, wf, '{"CLOUDFLARE_API_TOKEN":"v"}', '{"R2_BUCKET":"v"}'
    )
    assert rc == 0


def test_main_fails_on_the_missing_secret_that_caused_1851(
    crs, tmp_path, monkeypatch, capsys
):
    wf = _make_workflow(tmp_path, _WORKFLOW)
    rc = _run_main(
        crs, monkeypatch, wf, '{"CLOUDFLARE_ACCOUNT_ID":"v"}', '{"R2_BUCKET":"v"}'
    )
    assert rc == 1
    assert "CLOUDFLARE_API_TOKEN" in capsys.readouterr().err


def test_main_fails_on_a_missing_var(crs, tmp_path, monkeypatch, capsys):
    wf = _make_workflow(tmp_path, _WORKFLOW)
    rc = _run_main(crs, monkeypatch, wf, '{"CLOUDFLARE_API_TOKEN":"v"}', "{}")
    assert rc == 1
    assert "vars.R2_BUCKET" in capsys.readouterr().err


def test_main_never_prints_a_secret_value(crs, tmp_path, monkeypatch, capsys):
    wf = _make_workflow(tmp_path, _WORKFLOW)
    _run_main(crs, monkeypatch, wf, '{"UNUSED":"supersecret"}', '{"R2_BUCKET":"v"}')
    captured = capsys.readouterr()
    assert "supersecret" not in captured.out + captured.err


def test_main_reports_a_missing_workflow_file(crs, tmp_path, monkeypatch, capsys):
    rc = _run_main(crs, monkeypatch, tmp_path / "nope.yml", "{}", "{}")
    assert rc == 1
    assert "no such workflow" in capsys.readouterr().err
