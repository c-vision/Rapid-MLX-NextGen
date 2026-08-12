#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail a release bump PR when a release workflow needs a secret that is absent.

A workflow can reference ``secrets.FOO`` that was never configured. Actions
does not warn: the expression simply evaluates to the empty string, and the
failure surfaces wherever that value is finally used — which, for a release
pipeline, is on a tag, after the notarised build, once the GitHub Release is
already published.

That is how #1851 happened. #1747 added two new credential requirements
(``CLOUDFLARE_API_TOKEN``, ``CLOUDFLARE_ZONE_ID``); neither was ever added to
the repo. The guard inside ``rapid-mac-release.yml`` caught it correctly, but
only at tag time, three releases in a row, each time leaving a shipped release
whose updater fallback pointer had to be published by hand.

This check moves that discovery to the ``chore: bump version to X.Y.Z`` PR,
before the tag exists. The required set is derived from the workflow file
rather than hand-maintained here, so a future step that needs a new secret
extends the gate on its own — a hand-written list would have drifted exactly
the way the credential did.

Scope: presence only. An expired or under-scoped token is a non-empty string
and passes this check just as it passes the ``[[ -n ... ]]`` guard in the
release workflow. Catching that needs an authenticated probe, which needs a
working token to write against first (see #1852).

Available names arrive through the environment as the JSON of the ``secrets``
and ``vars`` contexts, because Actions offers no way to enumerate them
otherwise. Only the KEYS are ever read, and no value is printed or returned.

Usage::

    AVAILABLE_SECRETS_JSON='{"FOO":"..."}' AVAILABLE_VARS_JSON='{"BAR":"..."}' \\
        scripts/check_release_secrets.py .github/workflows/rapid-mac-release.yml
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

import yaml

# Contents of every ``${{ ... }}`` expression. References are only read from
# inside these, so prose in a ``run:`` block that happens to say "secrets.FOO"
# is not mistaken for a requirement.
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
# A ``secrets.NAME`` / ``vars.NAME`` reference in either GitHub Actions form:
# dot notation (``secrets.FOO``) or the equivalent index form
# (``secrets['FOO']`` / ``secrets["FOO"]``). Both resolve identically, so a
# workflow edit that switches to brackets must not silently drop out of the
# derived required set — that would reopen the exact drift this gate closes.
_NAME = r"[A-Za-z_][A-Za-z0-9_]*"
SECRET_REF = re.compile(rf"""\bsecrets(?:\.({_NAME})|\[\s*['"]({_NAME})['"]\s*\])""")
VARS_REF = re.compile(rf"""\bvars(?:\.({_NAME})|\[\s*['"]({_NAME})['"]\s*\])""")

# Injected by Actions into every workflow; never a configured repo secret, so
# its absence from the secrets context proves nothing.
ALWAYS_PROVIDED = frozenset({"GITHUB_TOKEN"})


def _names(pattern: re.Pattern, expr: str) -> set[str]:
    """Names captured by *pattern* in *expr*.

    Each match carries the name in exactly one group — group 1 for the dot
    form, group 2 for the bracket form — so pick whichever is non-empty.
    """
    return {m.group(1) or m.group(2) for m in pattern.finditer(expr)}


def walk(node):
    """Yield every string scalar in a parsed YAML document."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from walk(k)
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def referenced_names(text: str) -> tuple[set[str], set[str]]:
    """Return ``(secrets, vars)`` referenced by a workflow's expressions.

    Parses YAML and walks values, so names appearing in genuine YAML comments
    are ignored — the parser drops those before Actions ever sees them, and a
    header comment documenting "requires CLOUDFLARE_API_TOKEN" must not count
    as a reference.
    """
    doc = yaml.safe_load(text)
    secrets: set[str] = set()
    variables: set[str] = set()
    for scalar in walk(doc):
        for expr in EXPR.findall(scalar):
            secrets.update(_names(SECRET_REF, expr))
            variables.update(_names(VARS_REF, expr))
    return secrets - ALWAYS_PROVIDED, variables


def load_available(env_var: str) -> set[str]:
    """Read the KEYS of a JSON context passed through the environment.

    Values are never returned, printed, or logged.
    """
    raw = os.environ.get(env_var)
    if raw is None:
        raise SystemExit(
            f"::error::{env_var} is not set. Pass the context as JSON, e.g. "
            f"`{env_var}: ${{{{ toJSON(secrets) }}}}`."
        )
    try:
        parsed = json.loads(raw or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"::error::{env_var} is not valid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise SystemExit(f"::error::{env_var} must be a JSON object")
    return set(parsed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "workflows",
        nargs="+",
        type=Path,
        help="workflow files whose secret/var references must all exist",
    )
    args = parser.parse_args()

    available_secrets = load_available("AVAILABLE_SECRETS_JSON")
    available_vars = load_available("AVAILABLE_VARS_JSON")

    # file -> missing names, so the error names the workflow to fix.
    missing_secrets: dict[Path, set[str]] = {}
    missing_vars: dict[Path, set[str]] = {}
    total_refs = 0

    for path in args.workflows:
        if not path.is_file():
            print(f"::error::no such workflow: {path}", file=sys.stderr)
            return 1
        secrets, variables = referenced_names(path.read_text(encoding="utf-8"))
        total_refs += len(secrets) + len(variables)
        if gap := secrets - available_secrets:
            missing_secrets[path] = gap
        if gap := variables - available_vars:
            missing_vars[path] = gap

    if not missing_secrets and not missing_vars:
        print(
            f"release secrets OK — {total_refs} reference(s) across "
            f"{len(args.workflows)} workflow(s), all configured"
        )
        return 0

    for path, names in sorted(missing_secrets.items()):
        for name in sorted(names):
            print(
                f"::error::{path} references secrets.{name}, which is not "
                f"configured. Add it with `gh secret set {name}`.",
                file=sys.stderr,
            )
    for path, names in sorted(missing_vars.items()):
        for name in sorted(names):
            print(
                f"::error::{path} references vars.{name}, which is not "
                f"configured. Add it with `gh variable set {name}`.",
                file=sys.stderr,
            )
    print(
        "\nA release cut now would fail after the notarised build, on the tag, "
        "with the GitHub Release already published — see #1851. Configure the "
        "names above before merging the bump.",
        file=sys.stderr,
    )
    if not available_secrets:
        print(
            "Note: the secrets context is empty. Besides genuinely having no "
            "secrets, that is what a fork PR looks like — Actions withholds "
            "them by design, and this gate should skip rather than fail there.",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
