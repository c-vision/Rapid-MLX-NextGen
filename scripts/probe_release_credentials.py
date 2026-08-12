#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Probe the Cloudflare credentials the mac release needs, before the tag.

``check_release_secrets.py`` proves a secret is *configured*. It cannot prove
the value still works: an expired or revoked token is a non-empty string and
passes every presence check, including the ``[[ -n ... ]]`` guard inside
``rapid-mac-release.yml``. Expiry is the realistic way #1851 comes back —
Cloudflare tokens can carry an expiry date, and nothing in the pipeline would
notice until a tag run failed with the release already published.

What is and is not blocking here matters, so it is spelled out:

  * ``/user/tokens/verify`` is BLOCKING. Every valid token can call it
    regardless of its permissions, so an authoritative "this token is not
    active" is unambiguous and cannot false-block a correctly-scoped token.

  * The R2 bucket and zone lookups are ADVISORY. The release needs R2 *write*
    and *cache purge*; neither implies the read permission these lookups use.
    A token scoped exactly to what the release needs — and nothing more — can
    legitimately 403 here. Blocking on that would stop releases to punish a
    correctly-scoped token, so a failure is surfaced and nothing more.

  * Cache-purge permission specifically cannot be verified without purging.
    There is no dry run. It is left unproven rather than exercised on every
    bump PR.

  * Transport errors, timeouts, and 5xx are ADVISORY everywhere. "We could not
    check" is not "we checked and it is bad", and a Cloudflare blip must not
    block a release.

The token is read from the environment and is never printed, returned, or
included in a message.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"
TIMEOUT = 15

BLOCKING = "blocking"
ADVISORY = "advisory"


class UnreachableError(Exception):
    """Transport-level failure — never blocking, only advisory."""


def http_get(url: str, token: str) -> tuple[int, dict]:
    """GET a Cloudflare API endpoint. Raises ``UnreachableError`` on transport error.

    An HTTP error response still carries a JSON body worth reading (Cloudflare
    puts the reason in ``errors``), so 4xx is returned rather than raised; only
    a genuine transport failure raises.
    """
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            # Explicit UA: some Cloudflare-fronted endpoints reject the urllib
            # default outright, which would read as an auth failure.
            "User-Agent": "rapid-mlx-release-preflight",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b"{}")
        except (ValueError, OSError):
            return exc.code, {}
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise UnreachableError(str(exc)) from exc


def _reason(body: dict) -> str:
    errors = body.get("errors") or []
    parts = [str(e.get("message", e)) for e in errors if isinstance(e, dict)]
    return "; ".join(parts) or "no reason given"


def check_token_active(fetch, token: str) -> list[tuple[str, str]]:
    """BLOCKING — the token exists, is not expired, and is not revoked."""
    try:
        status, body = fetch(f"{API}/user/tokens/verify", token)
    except UnreachableError as exc:
        return [(ADVISORY, f"could not reach Cloudflare to verify the token: {exc}")]
    if status >= 500:
        return [(ADVISORY, f"Cloudflare returned HTTP {status} verifying the token")]
    # Only an authoritative rejection blocks. 401/403 mean the token is
    # invalid, revoked, or expired — the #1851 failure mode. A 429 (rate
    # limit) or any other non-2xx also carries ``success: false``, but that
    # is "could not check", not "checked and it is dead"; blocking on it
    # would false-block a release on a transient Cloudflare blip, which the
    # design keeps advisory (same rule as the 5xx and transport paths above).
    if status not in (200, 401, 403):
        return [
            (
                ADVISORY,
                f"could not verify CLOUDFLARE_API_TOKEN (HTTP {status}): {_reason(body)}. "
                "A transient response is not proof the token is bad.",
            )
        ]
    if status in (401, 403) or not body.get("success"):
        return [
            (
                BLOCKING,
                f"CLOUDFLARE_API_TOKEN is not usable (HTTP {status}): {_reason(body)}. "
                "An expired or revoked token passes every presence check and then "
                "fails on the tag, with the release already published (#1851).",
            )
        ]
    state = (body.get("result") or {}).get("status")
    if state != "active":
        return [
            (BLOCKING, f"CLOUDFLARE_API_TOKEN status is '{state}', expected 'active'")
        ]
    return []


def check_bucket_visible(fetch, token: str, account: str, bucket: str):
    """ADVISORY — the expected R2 bucket is visible to this token."""
    try:
        status, body = fetch(f"{API}/accounts/{account}/r2/buckets", token)
    except UnreachableError as exc:
        return [(ADVISORY, f"could not reach Cloudflare to list R2 buckets: {exc}")]
    if not body.get("success"):
        return [
            (
                ADVISORY,
                f"could not list R2 buckets (HTTP {status}): {_reason(body)}. "
                "Expected if the token is scoped to write only — not proof of a problem.",
            )
        ]
    names = {b.get("name") for b in (body.get("result") or {}).get("buckets", [])}
    if bucket not in names:
        return [
            (
                ADVISORY,
                f"R2 bucket '{bucket}' was not in the listing this token can see",
            )
        ]
    return []


def check_zone_visible(fetch, token: str, zone: str):
    """ADVISORY — the zone id resolves for this token."""
    try:
        status, body = fetch(f"{API}/zones/{zone}", token)
    except UnreachableError as exc:
        return [(ADVISORY, f"could not reach Cloudflare to resolve the zone: {exc}")]
    if not body.get("success"):
        return [
            (
                ADVISORY,
                f"could not resolve CLOUDFLARE_ZONE_ID (HTTP {status}): {_reason(body)}. "
                "Expected if the token holds Cache Purge without Zone Read — cache-purge "
                "permission cannot be verified without purging, so it is left unproven.",
            )
        ]
    return []


def run(fetch, token: str, account: str, zone: str, bucket: str):
    findings = check_token_active(fetch, token)
    # Stop on ANY token-level finding. A dead token makes every later call fail
    # for the same reason, and an unreachable Cloudflare makes them fail for the
    # same reason too — reporting those as separate findings would bury the one
    # that matters behind two restatements of it.
    if not findings:
        findings += check_bucket_visible(fetch, token, account, bucket)
        findings += check_zone_visible(fetch, token, zone)
    # Defence in depth: a transport error carries a message we did not compose,
    # and these findings are printed straight into a public CI log. Actions
    # masks registered secrets, but that is the last line of defence, not the
    # only one.
    if token:
        findings = [(sev, msg.replace(token, "<redacted>")) for sev, msg in findings]
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True, help="expected R2 bucket name")
    args = parser.parse_args()

    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
    zone = os.environ.get("CLOUDFLARE_ZONE_ID", "")
    if not (token and account and zone):
        # Presence is PF-2's other half; this probe has nothing to say.
        print(
            "::notice::credentials absent — presence check reports that, skipping probe"
        )
        return 0

    findings = run(http_get, token, account, zone, args.bucket)
    blocking = [m for sev, m in findings if sev == BLOCKING]
    for severity, message in findings:
        stream = sys.stderr if severity == BLOCKING else sys.stdout
        print(
            f"::{'error' if severity == BLOCKING else 'warning'}::{message}",
            file=stream,
        )
    if blocking:
        return 1
    if not findings:
        print("release credentials OK — token active, R2 bucket and zone both visible")
    else:
        print("release credentials usable — token active; see warnings above")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
