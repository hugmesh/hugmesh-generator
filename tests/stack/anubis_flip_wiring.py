#!/usr/bin/env python3
"""anubis_flip_wiring.py — the model behind tests/stack/test-anubis-flip-wiring.sh.

Grades ONE repo root against the ANUBIS=1 inert-toggle contract and prints a
PASS/FAIL line per check.  The suite runs it against the real tree (must be all
PASS) and against staged mutants (each must fail exactly the check it breaks),
so every assertion here is exercised in both directions.

Everything that can be DERIVED is derived: which service the management URL must
name, and on which port, come out of tests/stack/compose.local.yaml itself
(the gate's own METRICS_BIND), never from a constant in this file.  A hand-written
expectation would only ever catch what someone typed into it.

Exit 0 iff every check passed; 3 if a source file needed to grade a check is
missing (INCOMPLETE is never a pass).
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from urllib.parse import urlparse

try:
    import yaml
except ImportError:  # pragma: no cover - the suite preflights this
    print("INCOMPLETE PyYAML is not importable", file=sys.stderr)
    sys.exit(3)

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
MAKEFILE = os.path.join(ROOT, "Makefile")
COMPOSE = os.path.join(ROOT, "tests", "stack", "compose.local.yaml")
CLUSTER = os.path.join(
    ROOT, "specs", "cluster", "manifests", "admin-bff-api", "deployment.yaml")

ADMIN_BFF = "hugmesh-admin-bff-api"
RESULTS: list[tuple[str, bool, str]] = []


def check(cid: str, passed: bool, detail: str) -> None:
    RESULTS.append((cid, bool(passed), detail))


def incomplete(msg: str) -> None:
    print("INCOMPLETE %s" % msg, file=sys.stderr)
    sys.exit(3)


for path in (MAKEFILE, COMPOSE):
    if not os.path.isfile(path):
        incomplete("%s is missing — nothing to grade" % path)

makefile_text = open(MAKEFILE, encoding="utf-8").read()
compose_model = yaml.safe_load(open(COMPOSE, encoding="utf-8"))
services = compose_model.get("services") or {}


def stack_env(extra_args: list[str]) -> str:
    """STACK_ENV as make itself expands it — BEHAVIOUR, not a grep of the source.

    A guard that greps for `STACK_ANUBIS_ENV` is satisfied by a definition that is
    never threaded into STACK_ENV, which is precisely the shipped-dark shape this
    file exists to catch (see tests/stack/test-mfa-flip-wiring.sh's header).
    """
    cmd = ["make", "-C", ROOT, "--no-print-directory"] + extra_args + [
        # The inner double quotes matter: STACK_ENV is a single string full of
        # `KEY='value'` pairs, and an unquoted echo lets the recipe shell strip
        # every one of those quotes — which silently turns the C3 assertion into
        # a different (weaker) string comparison.
        "--eval=__anubis_probe:; @echo \"$(STACK_ENV)\"", "__anubis_probe"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        incomplete("make could not expand STACK_ENV: %s" % proc.stderr.strip()[:400])
    return proc.stdout


# ── C1: the knob is DECLARED, not merely consumed ────────────────────────────
# `$(ANUBIS)` was already read by STACK_EGRESS_FLAGS while no `ANUBIS ?=` line
# existed. make expands an undefined variable to empty without complaint, so the
# profile worked and the knob was invisible to anyone reading the knob block.
check("C1-declared",
      re.search(r"^ANUBIS\s*\?=", makefile_text, re.M) is not None,
      "Makefile must declare `ANUBIS ?=` alongside the other stack knobs")

# ── C2: the knob selects the compose profile ─────────────────────────────────
# Only the BRING-UP selection is graded: it is a make variable definition (column
# 0).  The stack-down / stack-clean recipes (TAB-indented) pass every profile
# unconditionally ON PURPOSE, so that a teardown reaches containers whichever
# knobs the bring-up used — grading those would demand a regression.
profile_lines = [l for l in makefile_text.splitlines()
                 if "--profile anubis" in l and not l.startswith("\t")]
check("C2-profile",
      len(profile_lines) >= 1 and all("$(ANUBIS)" in l for l in profile_lines),
      "every non-teardown `--profile anubis` selection must be gated on $(ANUBIS); "
      "found %d line(s): %r" % (len(profile_lines), profile_lines))

# ── C3: ANUBIS=1 actually reaches the compose environment ────────────────────
env_on = stack_env(["ANUBIS=1"])
check("C3-env-on",
      "ANUBIS_ENABLED='true'" in env_on,
      "make ANUBIS=1 must put ANUBIS_ENABLED='true' into STACK_ENV")

# ── C4: and a plain bring-up stays byte-identical ────────────────────────────
env_off = stack_env([])
check("C4-default-off",
      "ANUBIS_ENABLED" not in env_off,
      "a plain `make stack-up` must not mention ANUBIS_ENABLED at all")

# ── C5/C6/C7: the compose side ───────────────────────────────────────────────
admin_env = (services.get(ADMIN_BFF) or {}).get("environment") or {}
if not isinstance(admin_env, dict):
    incomplete("%s environment is not a mapping — this model cannot grade it" % ADMIN_BFF)

enabled = str(admin_env.get("ANUBIS_ENABLED", ""))
check("C5-interpolated",
      enabled.startswith("${ANUBIS_ENABLED") and ":-false}" in enabled,
      "%s must read ANUBIS_ENABLED through ${ANUBIS_ENABLED:-false} interpolation "
      "(a literal disconnects the switch, or ships it ON); found %r"
      % (ADMIN_BFF, enabled))

mgmt = str(admin_env.get("ANUBIS_MANAGEMENT_URL", ""))
mgmt_default = ""
m = re.match(r"^\$\{ANUBIS_MANAGEMENT_URL:-(.*)\}$", mgmt)
if m:
    mgmt_default = m.group(1)

# DERIVE the gate: the compose service whose METRICS_BIND declares the management
# port. Nothing here is hardcoded to a name or a number.
gate_name = ""
gate_port = 0
for name, svc in services.items():
    senv = (svc or {}).get("environment") or {}
    if isinstance(senv, dict) and "METRICS_BIND" in senv:
        bind = str(senv["METRICS_BIND"])
        if bind.startswith(":") and bind[1:].isdigit():
            gate_name, gate_port = name, int(bind[1:])
            break

if not gate_name:
    incomplete("no compose service declares METRICS_BIND — the gate cannot be derived")

parsed = urlparse(mgmt_default) if mgmt_default else None
check("C6-target",
      parsed is not None
      and parsed.hostname == gate_name
      and (parsed.port or 0) == gate_port,
      "ANUBIS_MANAGEMENT_URL must default to the gate compose service "
      "(http://%s:%d, derived from its METRICS_BIND); found %r"
      % (gate_name, gate_port, mgmt_default or mgmt))

published = []
for spec in ((services.get(gate_name) or {}).get("ports") or []):
    text = spec if isinstance(spec, str) else str((spec or {}).get("target", ""))
    if re.search(r"(^|:)%d$" % gate_port, text.strip().strip('"')):
        published.append(text)
check("C7-mgmt-unpublished",
      not published,
      "the gate's :%d management listener must stay UNPUBLISHED (admin-bff-only, "
      "as in the cluster); published by %r" % (gate_port, published))

# ── C8: compose is not inventing a contract the services do not have ─────────
if os.path.isfile(CLUSTER):
    cluster_text = open(CLUSTER, encoding="utf-8").read()
    check("C8-cluster-parity",
          "ANUBIS_ENABLED" in cluster_text and "ANUBIS_MANAGEMENT_URL" in cluster_text,
          "specs/cluster/manifests/admin-bff-api/deployment.yaml must set the same "
          "two keys — compose must not invent an env contract of its own")
else:
    incomplete("%s is missing — C8 cannot be graded" % CLUSTER)

failed = 0
for cid, passed, detail in RESULTS:
    print("%s %s%s" % ("PASS" if passed else "FAIL", cid, "" if passed else " — " + detail))
    failed += 0 if passed else 1

print("-- %d check(s), %d failed" % (len(RESULTS), failed))
sys.exit(1 if failed else 0)
