"""#579 — the mesh-wide Tor default reaches every node that can carry it, and a
per-node infra slug is ADDED to a node's services, never swapped in for them.

Two latent defects in ``WorklistConfig._apply_infra_services`` that the saved-mesh
bridge would otherwise have inherited:

* the mesh-wide onion (``base.tor_onion_service`` — the Network step's x86 flag, and
  what LocalCloudNodesPage imports from a saved mesh that ran TOR=1) was cleared on an
  rpi5 entry by step 5's ``strip_platform_unsupported`` (the field is x86-only) and
  emitted NOTHING there;
* ``--optional-services`` REPLACES the builder default, so appending a slug to an
  EMPTY list emitted ``--optional-services tor`` and dropped akkoma/tuwunel/phpbb from
  the node, ``[none]`` became the literal slug ``none``, and ``[all]`` kept
  ``--all-services`` — whose expansion excludes every infra slug — so the slug was lost.
"""
import os

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest  # noqa: E402

from hugmesh_studio.core.config import (  # noqa: E402
    BUILTIN_DEFAULT_SERVICES, SERVICES_ALL, SERVICES_NONE, USER_LEVEL_SERVICES,
    ImageConfig,
)
from hugmesh_studio.core.worklist import (  # noqa: E402
    WorklistConfig, WorklistEntry, with_service_slug,
)


def _mat(base, *entries):
    return {e.id: c for e, c in WorklistConfig(base=base, entries=list(entries)).materialize()}


def _svcs(cfg):
    argv = cfg.to_cli_args()
    if "--optional-services" not in argv:
        return None
    return argv[argv.index("--optional-services") + 1].split()


# ── the mesh-wide onion reaches rpi5 as the node slug ─────────────────────────────
@pytest.mark.parametrize("flag", [True, "on"])
def test_mesh_wide_tor_reaches_an_rpi5_node(flag):
    got = _mat(ImageConfig(mode="mesh", platform="x86", tor_onion_service=flag),
               WorklistEntry(role="backend", platform="x86"),
               WorklistEntry(role="backend", platform="rpi5"))
    assert "--with-tor" in got["backend.x86"].to_cli_args()
    rpi = got["backend.rpi5"]
    assert "--with-tor" not in rpi.to_cli_args()      # rpi5 has no such flag
    assert "tor" in _svcs(rpi)
    assert set(BUILTIN_DEFAULT_SERVICES) <= set(_svcs(rpi))


@pytest.mark.parametrize("flag", [False, "", "off"])
def test_no_mesh_wide_tor_adds_nothing_to_rpi5(flag):
    got = _mat(ImageConfig(mode="mesh", platform="x86", tor_onion_service=flag),
               WorklistEntry(role="backend", platform="rpi5"))
    assert _svcs(got["backend.rpi5"]) is None           # builder default, untouched


def test_mesh_wide_tor_is_dropped_where_no_builder_can_bake_it():
    got = _mat(ImageConfig(mode="mesh", platform="x86", tor_onion_service=True),
               WorklistEntry(role="edge-ai", platform="jetson"))
    argv = got["edge-ai.jetson"].to_cli_args()
    assert "--with-tor" not in argv and "--optional-services" not in argv


def test_mesh_wide_tor_and_a_per_node_tor_do_not_double_up():
    got = _mat(ImageConfig(mode="mesh", platform="x86", tor_onion_service=True),
               WorklistEntry(role="backend", platform="rpi5", infra_services=("tor",)))
    assert _svcs(got["backend.rpi5"]).count("tor") == 1


# ── a per-node slug is ADDED, never swapped in ────────────────────────────────────
def test_per_node_tor_on_rpi5_keeps_the_default_services():
    got = _mat(ImageConfig(mode="mesh", platform="x86"),
               WorklistEntry(role="backend", platform="rpi5", infra_services=("tor",)))
    assert _svcs(got["backend.rpi5"]) == [*BUILTIN_DEFAULT_SERVICES, "tor"]


def test_per_node_egress_on_x86_keeps_the_default_services():
    got = _mat(ImageConfig(mode="mesh", platform="x86"),
               WorklistEntry(role="backend", platform="x86",
                             infra_services=("egress-vpn",)))
    assert _svcs(got["backend.x86"]) == [*BUILTIN_DEFAULT_SERVICES, "egress-vpn"]


def test_with_service_slug_shapes():
    assert with_service_slug([], "tor") == [*BUILTIN_DEFAULT_SERVICES, "tor"]
    assert with_service_slug(None, "tor") == [*BUILTIN_DEFAULT_SERVICES, "tor"]
    assert with_service_slug([SERVICES_NONE], "tor") == ["tor"]
    assert with_service_slug(["akkoma"], "tor") == ["akkoma", "tor"]
    assert with_service_slug(["akkoma", "tor"], "tor") == ["akkoma", "tor"]
    allx = with_service_slug([SERVICES_ALL], "tor")
    assert allx == [*USER_LEVEL_SERVICES, "tor"]
    assert SERVICES_ALL not in allx                      # no --all-services swallowing it


def test_all_sentinel_plus_tor_emits_tor_on_rpi5():
    got = _mat(ImageConfig(mode="mesh", platform="x86", optional_services=[SERVICES_ALL]),
               WorklistEntry(role="backend", platform="rpi5", infra_services=("tor",)))
    rpi = got["backend.rpi5"]
    assert "--all-services" not in rpi.to_cli_args()
    assert set(USER_LEVEL_SERVICES) | {"tor"} == set(_svcs(rpi))


def test_none_sentinel_plus_tor_emits_just_tor():
    got = _mat(ImageConfig(mode="mesh", platform="x86", optional_services=[SERVICES_NONE]),
               WorklistEntry(role="backend", platform="rpi5", infra_services=("tor",)))
    assert _svcs(got["backend.rpi5"]) == ["tor"]
