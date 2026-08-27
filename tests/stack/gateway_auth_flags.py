#!/usr/bin/env python3
"""gateway_auth_flags.py — resolve the EFFECTIVE gateway auth-carrier flags on
both lanes (compose and specs/cluster) so they can be compared.

Driven by tests/stack/test-gateway-auth-flag-parity.sh, which owns the assertions
and the negative controls.

WHY "EFFECTIVE" AND NOT "PRESENT". The defect this exists for is not a missing
line; it is a DIFFERENT RUNTIME BEHAVIOUR. `hugmesh.gateway.bff-exchange.enabled`
defaults to FALSE in the image while `app.bff-session.enabled` defaults to TRUE,
so "compose sets it, the cluster does not" means opposite behaviour for one key
and identical behaviour for the other. Comparing presence would flag the harmless
case and — worse — would go green the day someone sets a key to its default on one
side only. So each key's IMAGE DEFAULT is read from the gateway's OWN
application.yml and both lanes are resolved through it.

The gateway checkout is therefore part of the check, not a convenience: without it
this exits 3 INCOMPLETE, which the driver treats as a FAILURE. A green run without
it would be a lie (lint:reserved-prefixes spent months green while its most
valuable stage printed "[SKIP] … (not checked out)").

Modes:
  defaults <application.yml> <KEY> [KEY ...]
      One TSV row per key: <KEY> <default-or-@UNSET> <property-path>
      Reads the `${KEY:default}` placeholders out of the gateway's application.yml.

  compose <compose-file> <service> <KEY> [KEY ...]
      One TSV row per key: <service> <KEY> <PRESENT|ABSENT> <resolved-value>
      `${VAR:-default}` resolves as compose does with VAR unset — what
      `make stack-up` actually hands the container.

  cluster <app.yaml> <KEY> [KEY ...]
      One TSV row per key: <release> <KEY> <PRESENT|ABSENT|FROMSECRET> <value>
      Reads the Application's helm `values:` extraEnv list (the raw escape hatch
      the gateway Applications use for exactly these flags).

Exit 0 ok, 2 could-not-run, 3 incomplete. Never a silent pass.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML not available", file=sys.stderr)
    sys.exit(2)

PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)(?::([^}]*))?\}")


def mode_defaults(argv: list[str]) -> int:
    src = Path(argv[0])
    if not src.is_file():
        print(f"gateway application.yml not found: {src}", file=sys.stderr)
        return 3
    text = src.read_text(encoding="utf-8", errors="ignore")
    found: dict[str, tuple[str, str]] = {}
    for line in text.splitlines():
        stripped = line.split("#", 1)[0]
        for m in PLACEHOLDER.finditer(stripped):
            key, dflt = m.group(1), m.group(2)
            prop = stripped.split(":", 1)[0].strip()
            found.setdefault(key, ("@UNSET" if dflt is None else dflt, prop))
    rc = 0
    for key in argv[1:]:
        if key in found:
            dflt, prop = found[key]
            print(f"{key}\t{dflt}\t{prop}")
        else:
            print(f"{key}\t@NOTFOUND\t-")
            rc = 3        # the key does not exist in the image at all — not a pass
    return rc


def _resolve_compose(raw: object) -> str:
    """What the container gets when the operator sets nothing."""
    if raw is None:
        return ""
    s = str(raw)
    m = re.fullmatch(r"\$\{([A-Z0-9_]+):-(.*)\}", s)
    if m:
        return m.group(2)
    m = re.fullmatch(r"\$\{([A-Z0-9_]+)\}", s)
    if m:
        return "@UNSET"
    return s


def mode_compose(argv: list[str]) -> int:
    path, service, keys = Path(argv[0]), argv[1], argv[2:]
    if not path.is_file():
        print(f"compose file not found: {path}", file=sys.stderr)
        return 2
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    svc = (doc.get("services") or {}).get(service)
    if svc is None:
        print(f"compose service not found: {service}", file=sys.stderr)
        return 2
    env = svc.get("environment") or {}
    if isinstance(env, list):                       # `- KEY=value` form
        env = dict(e.split("=", 1) if "=" in e else (e, None) for e in env)
    for k in keys:
        if k in env:
            print(f"{service}\t{k}\tPRESENT\t{_resolve_compose(env[k])}")
        else:
            print(f"{service}\t{k}\tABSENT\t-")
    return 0


def mode_cluster(argv: list[str]) -> int:
    path, keys = Path(argv[0]), argv[1:]
    if not path.is_file():
        print(f"application not found: {path}", file=sys.stderr)
        return 2
    app = yaml.safe_load(path.read_text(encoding="utf-8"))
    src = app.get("spec", {}).get("source", {})
    helm = src.get("helm", {}) or {}
    release = helm.get("releaseName") or app.get("metadata", {}).get("name") or "?"
    values: dict = {}
    if isinstance(helm.get("values"), str):
        values = yaml.safe_load(helm["values"]) or {}
    if isinstance(helm.get("valuesObject"), dict):
        # Later inputs win, matching Helm's map coalesce for our narrow use.
        merged = dict(values)
        merged.update(helm["valuesObject"])
        values = merged
    extra = values.get("extraEnv") or []
    by_name: dict[str, dict] = {}
    for e in extra:
        if isinstance(e, dict) and "name" in e:
            by_name[e["name"]] = e
    for k in keys:
        e = by_name.get(k)
        if e is None:
            print(f"{release}\t{k}\tABSENT\t-")
        elif "value" in e:
            print(f"{release}\t{k}\tPRESENT\t{e['value']}")
        else:
            print(f"{release}\t{k}\tFROMSECRET\t-")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mode, rest = sys.argv[1], sys.argv[2:]
    if mode == "defaults":
        return mode_defaults(rest)
    if mode == "compose":
        return mode_compose(rest)
    if mode == "cluster":
        return mode_cluster(rest)
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
