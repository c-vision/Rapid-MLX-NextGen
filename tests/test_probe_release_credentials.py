# SPDX-License-Identifier: Apache-2.0
"""Unit tests for ``scripts/probe_release_credentials.py``.

Pure stdlib — no network. The probe takes its HTTP primitive as an argument
precisely so the blocking/advisory split can be pinned here, since that split
is the whole design: a false block stops releases to punish a token that is
scoped correctly.
"""

from __future__ import annotations

import importlib.util
import pathlib

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "probe_release_credentials.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("probe_release_credentials", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def prc():
    return _load_module()


def _fetch_map(responses):
    """Build a fetch callable from a {url-substring: (status, body)} map.

    A value that is an Exception is raised instead of returned.
    """

    def fetch(url, token):
        for key, value in responses.items():
            if key in url:
                if isinstance(value, Exception):
                    raise value
                return value
        raise AssertionError(f"unexpected URL: {url}")

    return fetch


_OK_TOKEN = (200, {"success": True, "result": {"status": "active"}})
_OK_BUCKETS = (
    200,
    {"success": True, "result": {"buckets": [{"name": "rapid-desktop-dist"}]}},
)
_OK_ZONE = (200, {"success": True, "result": {"id": "z"}})


def _run(prc, prcfetch):
    return prc.run(prcfetch, "tok", "acct", "zone", "rapid-desktop-dist")


def _severities(findings):
    return {sev for sev, _ in findings}


# ---------- the happy path ---------------------------------------------


def test_all_green_reports_nothing(prc):
    findings = _run(
        prc,
        _fetch_map(
            {"tokens/verify": _OK_TOKEN, "r2/buckets": _OK_BUCKETS, "/zones/": _OK_ZONE}
        ),
    )
    assert findings == []


# ---------- blocking: the token itself is dead -------------------------


@pytest.mark.parametrize(
    "response",
    [
        (401, {"success": False, "errors": [{"message": "Invalid API Token"}]}),
        (403, {"success": False, "errors": [{"message": "Forbidden"}]}),
        (200, {"success": False, "errors": [{"message": "expired"}]}),
    ],
)
def test_unusable_token_blocks(prc, response):
    findings = _run(prc, _fetch_map({"tokens/verify": response}))
    assert prc.BLOCKING in _severities(findings)


def test_non_active_status_blocks(prc):
    findings = _run(
        prc,
        _fetch_map(
            {"tokens/verify": (200, {"success": True, "result": {"status": "expired"}})}
        ),
    )
    assert prc.BLOCKING in _severities(findings)


def test_dead_token_does_not_also_report_downstream_noise(prc):
    """One finding, not three — the later calls fail for the same reason."""
    findings = _run(prc, _fetch_map({"tokens/verify": (401, {"success": False})}))
    assert len(findings) == 1


def test_unreachable_cloudflare_reports_once_not_three_times(prc):
    """Same reasoning for a transport failure: one root cause, one finding."""
    findings = _run(prc, _fetch_map({"tokens/verify": prc.UnreachableError("dns")}))
    assert len(findings) == 1


# ---------- advisory: scope gaps must never block ----------------------


def test_r2_list_denied_is_advisory_not_blocking(prc):
    """A write-only R2 token legitimately cannot list buckets."""
    findings = _run(
        prc,
        _fetch_map(
            {
                "tokens/verify": _OK_TOKEN,
                "r2/buckets": (
                    403,
                    {"success": False, "errors": [{"message": "denied"}]},
                ),
                "/zones/": _OK_ZONE,
            }
        ),
    )
    assert _severities(findings) == {prc.ADVISORY}


def test_zone_read_denied_is_advisory_not_blocking(prc):
    """Cache Purge without Zone Read is a correctly-scoped token."""
    findings = _run(
        prc,
        _fetch_map(
            {
                "tokens/verify": _OK_TOKEN,
                "r2/buckets": _OK_BUCKETS,
                "/zones/": (403, {"success": False, "errors": [{"message": "denied"}]}),
            }
        ),
    )
    assert _severities(findings) == {prc.ADVISORY}


def test_missing_bucket_is_advisory(prc):
    findings = _run(
        prc,
        _fetch_map(
            {
                "tokens/verify": _OK_TOKEN,
                "r2/buckets": (
                    200,
                    {"success": True, "result": {"buckets": [{"name": "other"}]}},
                ),
                "/zones/": _OK_ZONE,
            }
        ),
    )
    assert _severities(findings) == {prc.ADVISORY}


# ---------- advisory: "could not check" is not "it is bad" -------------


def test_transport_failure_on_token_verify_is_advisory(prc):
    findings = _run(prc, _fetch_map({"tokens/verify": prc.UnreachableError("dns")}))
    assert _severities(findings) == {prc.ADVISORY}


def test_cloudflare_5xx_is_advisory(prc):
    findings = _run(prc, _fetch_map({"tokens/verify": (503, {})}))
    assert _severities(findings) == {prc.ADVISORY}


def test_rate_limit_on_token_verify_is_advisory_not_blocking(prc):
    """A 429 carries ``success: false`` but is transient, not authoritative.

    Blocking on it would false-block a legitimate bump PR on a Cloudflare
    rate-limit blip, which the design keeps advisory alongside 5xx/transport.
    """
    findings = _run(
        prc,
        _fetch_map(
            {
                "tokens/verify": (
                    429,
                    {"success": False, "errors": [{"message": "rate limited"}]},
                )
            }
        ),
    )
    assert _severities(findings) == {prc.ADVISORY}


# ---------- the token must never leak ----------------------------------


def test_no_finding_message_contains_the_token(prc):
    def fetch(url, token):
        raise prc.UnreachableError(f"connection to host failed while sending {token}")

    findings = prc.run(fetch, "SUPERSECRET", "acct", "zone", "bucket")
    assert findings
    assert all("SUPERSECRET" not in message for _, message in findings)
