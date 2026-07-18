"""Per-node scope:node infra services on a mesh worklist entry (the 2026-07-18
operator ask "finish tor egress work in gui" — the per-node half).

The gap: tor/egress-vpn are scope:node in optional-services.yaml, but Studio only
carried them mesh-wide (one base ImageConfig). WorklistEntry.infra_services makes
them PER NODE. These tests PROVE the selection reaches real builder argv on each
platform (the dead-default class this repo keeps hitting: a flag that emits nothing):
  - x86 tor        -> --with-tor
  - rpi5 tor       -> --optional-services "... tor"
  - rpi5 egress-vpn-> --optional-services "... egress-vpn"
  - x86 egress-vpn -> DROPPED (x86 has no --optional-services infra slug; the
                      egress_vpn-on-node scope is a declared gap, NOT a silent flag)
  - frite/jetson   -> DROPPED (parse neither) — never a bogus flag
Plus the JSON round-trip and that it is ADDITIVE to the mesh-wide default.
"""
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from snapdragon_studio.core.config import ImageConfig            # noqa: E402
from snapdragon_studio.core.worklist import (                    # noqa: E402
    WorklistConfig, WorklistEntry, WORKLIST_INFRA_SERVICES)


def _argv_for(entry: WorklistEntry, base: ImageConfig | None = None) -> list[str]:
    base = base or ImageConfig(mode="mesh", platform="x86")
    wl = WorklistConfig(base=base, entries=[entry])
    (_e, cfg), = wl.materialize()
    return cfg.to_cli_args()


# ── x86: tor -> --with-tor ────────────────────────────────────────────────────────
def test_x86_node_tor_emits_with_tor():
    argv = _argv_for(WorklistEntry(role="be", platform="x86", infra_services=("tor",)))
    assert "--with-tor" in argv
    assert "--no-tor" not in argv


def test_x86_node_without_tor_does_not_emit_with_tor():
    argv = _argv_for(WorklistEntry(role="be", platform="x86"))
    assert "--with-tor" not in argv


# ── rpi5: tor / egress-vpn -> --optional-services <slug> ──────────────────────────
def _optional_services_value(argv: list[str]) -> str:
    assert "--optional-services" in argv, argv
    return argv[argv.index("--optional-services") + 1]


def test_rpi5_node_tor_emits_optional_services_tor():
    argv = _argv_for(WorklistEntry(role="be", platform="rpi5", infra_services=("tor",)))
    # rpi5's tor is a --optional-services node slug, NOT the x86 --with-tor flag
    assert "--with-tor" not in argv
    assert "tor" in _optional_services_value(argv).split()


def test_rpi5_node_egress_vpn_emits_optional_services_egress():
    argv = _argv_for(WorklistEntry(role="be", platform="rpi5",
                                   infra_services=("egress-vpn",)))
    assert "egress-vpn" in _optional_services_value(argv).split()


# ── the DEAD-FLAG guards: nothing the platform can't express is emitted ───────────
def test_x86_egress_vpn_on_node_is_dropped_not_a_bogus_flag():
    """x86 has no --optional-services infra slug and --egress-vpn needs a FILE, so a
    per-node egress-vpn on x86 is the DECLARED GAP — it must emit NOTHING, never a
    flag the builder ignores or an empty --egress-vpn."""
    argv = _argv_for(WorklistEntry(role="be", platform="x86",
                                   infra_services=("egress-vpn",)))
    assert "egress-vpn" not in " ".join(argv)
    assert "--egress-vpn" not in argv


def test_frite_node_infra_services_are_dropped():
    """frite parses no --optional-services and has no --with-tor — a selection there
    must vanish, not become a bogus flag that fails the build."""
    argv = _argv_for(WorklistEntry(role="be", platform="frite", board="lafrite",
                                   infra_services=("tor", "egress-vpn")))
    assert "--with-tor" not in argv
    assert "tor" not in " ".join(argv).replace("actuator", "")  # no stray tor token


def test_unknown_infra_slug_is_ignored():
    argv = _argv_for(WorklistEntry(role="be", platform="x86",
                                   infra_services=("tor", "not-a-real-service")))
    assert "--with-tor" in argv
    assert "not-a-real-service" not in " ".join(argv)


# ── ADDITIVE to the mesh-wide default + independent per node ──────────────────────
def test_infra_services_is_additive_and_independent_per_node():
    base = ImageConfig(mode="mesh", platform="x86")
    wl = WorklistConfig(base=base, entries=[
        WorklistEntry(role="be", platform="x86", infra_services=("tor",)),
        WorklistEntry(role="pki", platform="x86"),          # same mesh, NO onion
    ])
    mats = wl.materialize()
    be_argv = mats[0][1].to_cli_args()
    pki_argv = mats[1][1].to_cli_args()
    assert "--with-tor" in be_argv          # node that opted in
    assert "--with-tor" not in pki_argv     # node that did not — proves per-node


def test_mesh_wide_default_still_reaches_every_node():
    # the Network-page mesh-wide onion (base.tor_onion_service) still applies to all
    base = ImageConfig(mode="mesh", platform="x86", tor_onion_service=True)
    argv = _argv_for(WorklistEntry(role="be", platform="x86"), base=base)
    assert "--with-tor" in argv


# ── JSON round-trip ───────────────────────────────────────────────────────────────
def test_infra_services_round_trips_through_dict():
    e = WorklistEntry(role="be", platform="rpi5", infra_services=("tor", "egress-vpn"))
    d = e.to_dict()
    assert d["infra_services"] == ["tor", "egress-vpn"]      # a JSON list on disk
    back = WorklistEntry.from_dict(d)
    assert back.infra_services == ("tor", "egress-vpn")      # re-tupled on load
    assert isinstance(back.infra_services, tuple)


def test_worklist_infra_services_are_the_two_per_node_slugs():
    assert WORKLIST_INFRA_SERVICES == ("tor", "egress-vpn")
