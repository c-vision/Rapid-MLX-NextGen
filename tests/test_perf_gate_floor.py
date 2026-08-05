# SPDX-License-Identifier: Apache-2.0
"""Perf-gate floor resolution — the reviewed-floor layer that lets
``evals/perf_gate.py`` actually BLOCK a release when decode throughput
regresses (previously the gate was never wired into the M3 gauntlet, so its
floor mechanism was unreachable; see docs/development/releasing.md G8b).

Hermetic: no server, no model — every case exercises the pure resolution /
file-parsing helpers against ``tmp_path`` fixtures and monkeypatched env.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

from evals import perf_gate
from evals.perf_gate import FloorsFileError, _load_floor_from_file, resolve_floor

REPO_ROOT = Path(__file__).resolve().parent.parent


def _write_floors(tmp_path: Path, floors: object) -> str:
    p = tmp_path / "perf_floors.json"
    p.write_text(json.dumps({"schema": 1, "floors": floors}))
    return str(p)


# --------------------------- resolve_floor precedence ---------------------


def test_cli_beats_env_and_file(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"m": 10.0})
    got = resolve_floor(
        cli_min_tps=99.0, env_min_tps=50.0, floors_file=floors_file, alias="m"
    )
    assert got == 99.0


def test_env_beats_file(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"m": 10.0})
    got = resolve_floor(
        cli_min_tps=None, env_min_tps=50.0, floors_file=floors_file, alias="m"
    )
    assert got == 50.0


def test_file_used_when_no_cli_or_env(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"m": 12.5})
    got = resolve_floor(
        cli_min_tps=None, env_min_tps=None, floors_file=floors_file, alias="m"
    )
    assert got == 12.5


def test_advisory_when_nothing_supplies_a_floor() -> None:
    assert (
        resolve_floor(cli_min_tps=None, env_min_tps=None, floors_file=None, alias="m")
        is None
    )


def test_advisory_when_alias_absent_from_file(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"other": 10.0})
    assert (
        resolve_floor(
            cli_min_tps=None, env_min_tps=None, floors_file=floors_file, alias="m"
        )
        is None
    )


# --------------------------- _load_floor_from_file ------------------------


def test_load_present_alias(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"qwen3.5-9b-4bit": 29.5})
    assert _load_floor_from_file(floors_file, "qwen3.5-9b-4bit") == 29.5


def test_load_absent_alias_is_none(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": 1.0})
    assert _load_floor_from_file(floors_file, "b") is None


def test_load_blank_alias_is_none(tmp_path: Path) -> None:
    # No alias to look up → no file floor (caller passes the file
    # unconditionally and lets the alias decide whether it matters).
    floors_file = _write_floors(tmp_path, {"a": 1.0})
    assert _load_floor_from_file(floors_file, "") is None


def test_load_empty_floors_object(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {})
    assert _load_floor_from_file(floors_file, "a") is None


def test_load_missing_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FloorsFileError, match="cannot read"):
        _load_floor_from_file(str(tmp_path / "nope.json"), "a")


def test_load_malformed_json_raises(tmp_path: Path) -> None:
    p = tmp_path / "bad.json"
    p.write_text("{not json")
    with pytest.raises(FloorsFileError, match="not valid JSON"):
        _load_floor_from_file(str(p), "a")


def test_load_non_object_top_level_raises(tmp_path: Path) -> None:
    p = tmp_path / "arr.json"
    p.write_text("[1, 2, 3]")
    with pytest.raises(FloorsFileError, match="must be a JSON object"):
        _load_floor_from_file(str(p), "a")


def test_load_missing_schema_raises(tmp_path: Path) -> None:
    # A missing schema must fail loudly, NOT be read as an empty registry —
    # otherwise a future format change silently disables enforcement.
    p = tmp_path / "noschema.json"
    p.write_text(json.dumps({"floors": {"a": 10.0}}))
    with pytest.raises(FloorsFileError, match="unsupported schema"):
        _load_floor_from_file(str(p), "a")


def test_load_wrong_schema_raises(tmp_path: Path) -> None:
    p = tmp_path / "v2.json"
    p.write_text(json.dumps({"schema": 2, "floors": {"a": 10.0}}))
    with pytest.raises(FloorsFileError, match="unsupported schema"):
        _load_floor_from_file(str(p), "a")


def test_load_bool_schema_raises(tmp_path: Path) -> None:
    # `true` == 1 in Python, so a naive `!= 1` check would accept it. The
    # strict `type(schema) is int` guard must reject the bool.
    p = tmp_path / "boolschema.json"
    p.write_text(json.dumps({"schema": True, "floors": {"a": 10.0}}))
    with pytest.raises(FloorsFileError, match="unsupported schema"):
        _load_floor_from_file(str(p), "a")


def test_load_float_schema_raises(tmp_path: Path) -> None:
    # `1.0 == 1` too — the strict integer-type guard must reject a float schema.
    p = tmp_path / "floatschema.json"
    p.write_text(json.dumps({"schema": 1.0, "floors": {"a": 10.0}}))
    with pytest.raises(FloorsFileError, match="unsupported schema"):
        _load_floor_from_file(str(p), "a")


def test_load_missing_floors_key_raises(tmp_path: Path) -> None:
    # Missing 'floors' key is a broken file (not an empty registry); an empty
    # {} object is separately valid — see test_load_empty_floors_object.
    p = tmp_path / "nofloors.json"
    p.write_text(json.dumps({"schema": 1}))
    with pytest.raises(FloorsFileError, match="missing required 'floors'"):
        _load_floor_from_file(str(p), "a")


def test_load_floors_not_object_raises(tmp_path: Path) -> None:
    p = tmp_path / "f.json"
    p.write_text(json.dumps({"schema": 1, "floors": [1, 2]}))
    with pytest.raises(FloorsFileError, match="'floors' must be an object"):
        _load_floor_from_file(str(p), "a")


def test_load_infinity_value_raises(tmp_path: Path) -> None:
    # Python's json decoder parses the JS literal ``Infinity``; a committed
    # +inf floor would make every model fail, so it is a config error, not a
    # floor. (json.dumps(float("inf")) emits the literal ``Infinity``.)
    floors_file = _write_floors(tmp_path, {"a": float("inf")})
    with pytest.raises(FloorsFileError, match="finite number"):
        _load_floor_from_file(floors_file, "a")


def test_load_nan_value_raises(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": float("nan")})
    with pytest.raises(FloorsFileError, match="finite number"):
        _load_floor_from_file(floors_file, "a")


def test_load_zero_value_raises(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": 0})
    with pytest.raises(FloorsFileError, match="finite number"):
        _load_floor_from_file(floors_file, "a")


def test_load_negative_value_raises(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": -5.0})
    with pytest.raises(FloorsFileError, match="finite number"):
        _load_floor_from_file(floors_file, "a")


def test_load_non_numeric_value_raises(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": "fast"})
    with pytest.raises(FloorsFileError, match="must be a number"):
        _load_floor_from_file(floors_file, "a")


def test_load_bool_value_raises(tmp_path: Path) -> None:
    # bool is an int subclass — a stray `true` must not be read as 1.0.
    floors_file = _write_floors(tmp_path, {"a": True})
    with pytest.raises(FloorsFileError, match="must be a number"):
        _load_floor_from_file(floors_file, "a")


def test_load_int_value_coerced_to_float(tmp_path: Path) -> None:
    floors_file = _write_floors(tmp_path, {"a": 30})
    got = _load_floor_from_file(floors_file, "a")
    assert got == 30.0
    assert isinstance(got, float)


# --------------------------- committed registry ---------------------------


def test_committed_perf_floors_is_valid() -> None:
    """The committed harness/perf_floors.json must be parseable and shaped as
    the gate expects — a broken commit here would fail every release run at
    the G8b gate (return code 2)."""
    path = REPO_ROOT / "harness" / "perf_floors.json"
    data = json.loads(path.read_text())
    assert isinstance(data, dict)
    # Schema must be exactly the integer the loader accepts — assert it here so
    # a registry schema bump can't silently leave this test green while every
    # release fails at G8b. (bool is an int subclass; exclude it explicitly.)
    assert type(data.get("schema")) is int and data["schema"] == 1
    assert isinstance(data.get("floors"), dict)
    # Every committed floor must be a real, enforceable number (finite > 0) so
    # the gate never trips its own "floor that cannot enforce anything" guard.
    for alias, floor in data["floors"].items():
        assert isinstance(alias, str) and alias
        assert isinstance(floor, (int, float)) and not isinstance(floor, bool)
        # finite AND > 0 — a committed +Infinity (which json parses) or 0 would
        # pass ``> 0`` alone yet be rejected by the loader at release time.
        assert math.isfinite(floor)
        assert floor > 0
    # Drive the loader through its FULL validation path (schema + floors-shape
    # checks) even when the registry is empty — a lookup of an absent alias
    # still runs every guard and must return None, not raise. This is what
    # catches a schema/shape regression regardless of how many floors exist.
    assert _load_floor_from_file(str(path), "definitely-not-a-real-alias") is None
    # And for any committed alias the loader agrees with a straight parse.
    for alias in data["floors"]:
        assert _load_floor_from_file(str(path), alias) == float(data["floors"][alias])


def test_module_exposes_resolution_api() -> None:
    # Pins the public surface the gauntlet + tests depend on.
    assert callable(perf_gate.resolve_floor)
    assert callable(perf_gate._load_floor_from_file)
    assert issubclass(perf_gate.FloorsFileError, RuntimeError)


# --------------------------- main() argument guards -----------------------


def test_main_rejects_floors_file_without_alias(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A --floors-file with no --alias and no CLI/env floor silently defeats the
    # gate — main() must reject it (exit 2) BEFORE any server contact. Force
    # server-reachability False so that even if the guard regressed, the test
    # can't accidentally reach a real endpoint.
    floors_file = _write_floors(tmp_path, {"a": 10.0})
    monkeypatch.delenv("RAPID_MLX_PERF_MIN_TPS", raising=False)
    monkeypatch.setattr(perf_gate, "_server_reachable", lambda _url: False)
    monkeypatch.setattr("sys.argv", ["perf_gate.py", "--floors-file", floors_file])
    assert perf_gate.main() == 2


def test_main_allows_floors_file_without_alias_when_env_floor_set(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # With a higher-precedence env floor active the file is moot, so the
    # missing-alias guard must NOT fire. Both that guard and the downstream
    # "no server" path return 2, so distinguish them by stderr: the arg-guard
    # message must be ABSENT (the run reached the measurement path instead).
    # Hermetic: stub server-reachability to a deterministic False rather than
    # relying on a real localhost port being closed.
    floors_file = _write_floors(tmp_path, {"a": 10.0})
    monkeypatch.setenv("RAPID_MLX_PERF_MIN_TPS", "12.5")
    monkeypatch.setattr(perf_gate, "_server_reachable", lambda _url: False)
    monkeypatch.setattr("sys.argv", ["perf_gate.py", "--floors-file", floors_file])
    rc = perf_gate.main()
    err = capsys.readouterr().err
    assert "--floors-file was given without --alias" not in err
    # It failed for the RIGHT reason (no server), not the arg guard.
    assert rc == 2
    assert "no rapid-mlx server reachable" in err


def test_main_valid_cli_floor_ignores_malformed_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # CLI-over-env precedence must cover ERRORS too: a garbage
    # $RAPID_MLX_PERF_MIN_TPS must not abort a run whose --min-tps is valid.
    # (_env_float SystemExits on garbage; if main parsed env unconditionally
    # this would raise instead of proceeding.) With a valid CLI floor and no
    # server, main returns 2 for "no server" — never SystemExit on the env.
    monkeypatch.setenv("RAPID_MLX_PERF_MIN_TPS", "not-a-number")
    monkeypatch.setattr(perf_gate, "_server_reachable", lambda _url: False)
    monkeypatch.setattr("sys.argv", ["perf_gate.py", "--min-tps", "30"])
    assert perf_gate.main() == 2


def test_main_malformed_env_aborts_when_no_cli_floor(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # But when there is NO CLI floor, a garbage env value is the operator's
    # intended-but-broken floor and must fail loudly (SystemExit from
    # _env_float), not silently run advisory.
    monkeypatch.setenv("RAPID_MLX_PERF_MIN_TPS", "not-a-number")
    monkeypatch.setattr(perf_gate, "_server_reachable", lambda _url: False)
    monkeypatch.setattr("sys.argv", ["perf_gate.py"])
    with pytest.raises(SystemExit):
        perf_gate.main()
