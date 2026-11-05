"""Field shown <=> the hash reaches the image's first boot, for EVERY Studio image.

Operator requirement (2026-11-04): every desktop image offers a LOCAL account login
in standalone, tailnet-only and mesh-associated modes, so the Login Password must
WORK wherever HomePage shows it (``local_login_applies``) — not be hidden.

Round-1 refutation of PR #860: 24 (mode, role, platform) combinations showed the
field and emitted ``--local-pass``, but none of them set ``STANDALONE=true``, and the
first-boot finaliser applied ``@@LOCAL_PASSHASH@@`` only inside its standalone block —
so the password was hashed, baked, and thrown away at first boot.

This walks the REAL role catalogue (ROLE_CHOICES x platforms x the standalone box) and,
for every combination ``to_cli_args`` accepts and the field is shown on:

  1. the Studio argv carries ``--local-pass`` (what BuildDriver swaps for a file);
  2. the REAL builder, run with that argv and ``--print-plan``, hashes it
     (``PLAN_LOCAL_PASS=REDACTED``) and reports the STANDALONE value it renders;
  3. the REAL first-boot template, rendered with that STANDALONE value and a hash,
     and executed offline by tests/scripts/lib/firstboot-harness.sh (keyless AND with
     KEYS-provisioned users), puts exactly that hash on the local account.

The template's behaviour depends only on (STANDALONE, hash, KEYS), so step 3 runs once
per distinct tuple rather than once per combination. Nothing here prints the
throwaway password or a hash.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess

import pytest

from hugmesh_studio.core.config import (
    ROLE_CHOICES, ImageConfig, field_in_scope, local_login_applies,
    standalone_login_required,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HARNESS = os.path.join(GENERATOR_DIR, "tests", "scripts", "lib", "firstboot-harness.sh")
THROWAWAY = "throwaway-login-pw"
# A fixed SHA-512 crypt of an unrelated throwaway string: the template only has to
# carry SOME hash verbatim, and the builder's own hashing is proven by step 2.
HASH6 = "$6$Abc.def/123$" + "x" * 86

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")


def _combos():
    for mode, choices in ROLE_CHOICES.items():
        for role, platforms, _label in choices:
            for platform in platforms:
                for box in (False, True):
                    cfg = ImageConfig(mode=mode, role=role, platform=platform,
                                      standalone=box, local_user="magus",
                                      local_pass=THROWAWAY)
                    if box and not field_in_scope("standalone", cfg):
                        continue
                    try:
                        argv = cfg.to_cli_args()
                    except Exception:  # noqa: BLE001 — a config the Studio refuses
                        continue
                    yield (mode, role, platform, box), cfg, argv


COMBOS = list(_combos())
SHOWN = [(k, c, a) for k, c, a in COMBOS if local_login_applies(c)]


def _plan(cfg: ImageConfig, argv: list[str], tmp_path) -> dict[str, str]:
    work = tmp_path / "w"
    work.mkdir(exist_ok=True)
    proc = subprocess.run(
        ["bash", f"./{cfg.builder_script}", "-w", str(work), *argv, "--print-plan"],
        cwd=GENERATOR_DIR, capture_output=True, text=True, timeout=180,
        env={**os.environ, "TMPDIR": str(tmp_path)})
    plan = {}
    for line in proc.stdout.splitlines():
        m = re.match(r"PLAN_([A-Z_]+)=(.*)$", line)
        if m:
            plan[m.group(1)] = m.group(2)
    assert THROWAWAY not in proc.stdout + proc.stderr, "builder printed the password"
    return plan


def _builder_standalone(plan: dict[str, str]) -> str | None:
    if "ROLE_CLASS" in plan:                                    # x86
        return "true" if plan["ROLE_CLASS"] == "standalone" else "false"
    m = re.search(r"\bstandalone=(true|false)\b", plan.get("FLAGS_EFFECTIVE", ""))
    return m.group(1) if m else None


def _probe(standalone: str, keys: bool) -> dict[str, str]:
    out = subprocess.run(
        ["bash", HARNESS, "probe", standalone, HASH6, "true" if keys else "false", "false"],
        capture_output=True, text=True, timeout=60)
    facts = dict(kv.split("=", 1) for kv in out.stdout.split())
    assert facts, f"harness probe printed nothing (rc={out.returncode}): {out.stderr[-400:]}"
    return facts


def test_the_enumeration_is_not_vacuous():
    # The refuter's 24 shown-but-not-standalone combinations must all be walked.
    keys = {k for k, _c, _a in SHOWN}
    for need in [("cloud", "laptop", "x86", False), ("cloud", "desktop", "x86", False),
                 ("cloud", "chromebook", "x86", False), ("mesh", "laptop", "x86", False),
                 ("mesh", "desktop", "x86", False), ("mesh", "chromebook", "x86", False),
                 ("cloud", "rpi5-desktop", "rpi5", False),
                 ("mesh", "rpi5-desktop", "rpi5", False),
                 ("mesh", "jetson-desktop", "jetson", False),
                 ("standalone", "chromebook", "x86", False),
                 ("standalone", "frite", "frite", False),
                 ("standalone", "orangepi5", "orangepi5", False),
                 ("standalone", "orangepi4-lts", "orangepi4-lts", False)]:
        assert need in keys, f"{need} not walked"
    assert len(SHOWN) >= 40


def test_required_implies_shown():
    # A refusal for a field the operator cannot see would be a dead end.
    for key, cfg, _argv in COMBOS:
        if standalone_login_required(cfg):
            assert local_login_applies(cfg), f"{key}: password required but field hidden"


def test_every_shown_field_reaches_first_boot(tmp_path):
    tuples: dict[str, list] = {}
    for key, cfg, argv in SHOWN:
        assert ("--local-pass", THROWAWAY) in zip(argv, argv[1:]), \
            f"{key}: field shown but --local-pass not emitted"
        plan = _plan(cfg, argv, tmp_path)
        assert plan, f"{key}: builder printed no plan"
        assert plan.get("LOCAL_PASS") == "REDACTED", \
            f"{key}: builder did not hash the Login Password (LOCAL_PASS={plan.get('LOCAL_PASS')!r})"
        sa = _builder_standalone(plan)
        assert sa in ("true", "false"), f"{key}: cannot read the builder's STANDALONE"
        tuples.setdefault(sa, []).append(key)
    assert tuples.get("false"), "no non-standalone combination walked (the round-1 hole)"
    for sa, keys in tuples.items():
        for kp in (False, True):
            if sa == "true" and kp:
                continue          # a standalone image has no KEYS provisioning
            facts = _probe(sa, kp)
            assert facts["hash"] == "applied", (
                f"STANDALONE={sa} KEYS={kp}: first boot dropped the hash for "
                f"{len(keys)} shown combination(s), e.g. {keys[:3]}")
            assert facts["random"] == "n" and facts["keyless_banner"] == "n"
            if kp:
                assert facts["wheel"] == "n" and facts["sudoers_d"] == "n", \
                    "additional local account on a KEYS image must not be an administrator"
