"""Per-domain 'own Casdoor vs superdomain Casdoor' choice (issue #47) — schema +
compose-lane half (Qt-free; the DomainsPage combo is pinned by
test_pages_domains_idp.py):

  1. SCHEMA: Domain.idp round-trips through save/load; ABSENT in a pre-#47 config
     == superdomain (the regression proof old manifests keep provisioning
     identically); junk fails loudly at load.
  2. MANIFEST GOLDEN: a superdomain-only config's mesh_manifest() is BYTE-IDENTICAL
     to what the pre-#47 code emitted (literal golden captured from it); an 'own'
     domain adds exactly the one "idp" key. Same omit-when-default rule in the v2
     envelope.
  3. COMPOSE LANE: core/own_casdoor.py renders one Casdoor(+postgres) per own-idp
     domain the way tests/stack/compose.brand-b.yaml proves (ports 8001+, issuer
     http://casdoor-<slug>.localtest.me:<port>, listen port pinned 8000);
     LocalStackNode threads OWN_CASDOOR/APP_TENANCY_* and writes the overlay —
     and the superdomain-only env is byte-identical to before (golden).
  4. TEXTUAL pins on the real Makefile / .gitignore so a refactor cannot silently
     drop the -f include, the profile gating, or commit the generated overlay.
"""
import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import own_casdoor  # noqa: E402
from hugmesh_studio.core.config import (  # noqa: E402
    DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain, ImageConfig, User)
from hugmesh_studio.core.local_mesh_bootstrap import (  # noqa: E402
    LocalMeshBootstrap, LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_stack_node import LocalStackNode  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry  # noqa: E402
from hugmesh_studio.core.worklist_driver import WorklistDriver  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _cfg():
    c = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal")
    c.domains = [Domain(name="acme.example", title="Acme"),
                 Domain(name="team.acme.example", title="Team", images=["backend.rpi5"],
                        optional_services=["akkoma"])]
    c.users = [User(username="root-admin", domain="core.acme.internal",
                    role="superadmin")]
    return c


# ── 1. schema: default / round-trip / absent==superdomain / fail-closed ─────────
def test_default_is_superdomain_and_own_round_trips():
    assert Domain(name="a.example").idp == DOMAIN_IDP_SUPERDOMAIN
    c = _cfg()
    c.domains[1].idp = DOMAIN_IDP_OWN
    back = ImageConfig.from_dict(c.to_dict())
    assert [d.idp for d in back.domains] == [DOMAIN_IDP_SUPERDOMAIN, DOMAIN_IDP_OWN]
    assert c.own_idp_domains() == ("team.acme.example",)


def test_pre47_config_without_idp_loads_as_superdomain():
    """The backward-compat contract: a saved config from before the field existed
    (its domain dicts carry NO idp key) loads as superdomain — today's behavior —
    and re-emits a manifest with NO idp key (see the golden below), so provisioning
    consumes exactly what it always did."""
    old = {"mode": "mesh", "brand": "acme",
           "domains": [{"name": "acme.example", "title": "Acme"},
                       {"name": "team.acme.example", "title": "Team",
                        "images": ["backend.rpi5"], "optional_services": ["akkoma"]}]}
    c = ImageConfig.from_dict(old)
    assert [d.idp for d in c.domains] == [DOMAIN_IDP_SUPERDOMAIN] * 2
    assert c.own_idp_domains() == ()
    assert all("idp" not in d for d in c.mesh_manifest()["domains"])


def test_junk_idp_fails_closed_at_load():
    with pytest.raises(ValueError, match="idp must be one of"):
        ImageConfig.from_dict(
            {"domains": [{"name": "a.example", "idp": "casdoorish"}]})
    # empty/None normalize to the default rather than failing — they are what a
    # hand-written "idp": "" (or a null) honestly means.
    c = ImageConfig.from_dict({"domains": [{"name": "a.example", "idp": ""}]})
    assert c.domains[0].idp == DOMAIN_IDP_SUPERDOMAIN


# ── 2. manifest emission: golden byte-identity + omit-when-default ──────────────
# Captured VERBATIM from the pre-#47 code (config.py mesh_manifest before this
# change) for the exact _cfg() above — the regression proof that a superdomain-only
# config provisions byte-identically.
_PRE47_MANIFEST_GOLDEN = """\
{
  "brand": "acme",
  "brand_title": "Acme",
  "org": "Acme-Inc",
  "cluster_domain": "acme.example",
  "superdomain": "core.acme.internal",
  "domains": [
    {
      "name": "acme.example",
      "title": "Acme",
      "images": [],
      "optional_services": []
    },
    {
      "name": "team.acme.example",
      "title": "Team",
      "images": [
        "backend.rpi5"
      ],
      "optional_services": [
        "akkoma"
      ]
    }
  ],
  "users": [
    {
      "username": "root-admin",
      "domain": "core.acme.internal",
      "role": "superadmin",
      "email": "",
      "registration": ""
    }
  ]
}"""


def test_superdomain_only_manifest_is_byte_identical_to_pre47_golden():
    assert json.dumps(_cfg().mesh_manifest(), indent=2) == _PRE47_MANIFEST_GOLDEN


def test_own_domain_adds_exactly_the_idp_key_to_the_manifest():
    c = _cfg()
    c.domains[1].idp = DOMAIN_IDP_OWN
    doms = c.mesh_manifest()["domains"]
    assert "idp" not in doms[0]                      # default stays absent
    assert doms[1]["idp"] == DOMAIN_IDP_OWN
    # nothing else moved: dropping the one key restores the default emission.
    del doms[1]["idp"]
    assert doms == _cfg().mesh_manifest()["domains"]


def _host():
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def test_manifest_v2_omits_default_and_carries_own(tmp_path):
    base = _cfg()
    base.output_dir = str(tmp_path / "out")
    base.domains[1].idp = DOMAIN_IDP_OWN
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86")])
    doms = WorklistDriver(str(tmp_path), wl, host=_host()).manifest_v2()["domains"]
    assert "idp" not in doms[0]
    assert doms[1]["idp"] == DOMAIN_IDP_OWN
    # #654: v2 writes the SAME row shape as the v1 shim (config.manifest_domain_rows),
    # so the two emitters agree key for key — v2's own historical order is gone.
    assert list(doms[0]) == ["name", "title", "images", "optional_services"]
    assert doms == base.mesh_manifest()["domains"]


# ── 3. the compose lane: renderer + LocalStackNode threading ────────────────────
def test_renderer_derives_brand_b_shaped_ports_slugs_and_issuers():
    names = ("acme.example", "team.acme.example")
    assert own_casdoor.slug("acme.example") == "acme-example"
    assert [own_casdoor.port_for(i) for i in range(2)] == [8001, 8002]
    assert own_casdoor.issuer_for("acme.example", 0) == \
        "http://casdoor-acme-example.localtest.me:8001"
    env = own_casdoor.tenancy_env(names, "http://localhost:8000")
    assert env["APP_TENANCY_ISSUERS"] == (
        "http://localhost:8000=default,"
        "http://casdoor-acme-example.localtest.me:8001=acme-example,"
        "http://casdoor-team-acme-example.localtest.me:8002=team-acme-example")
    assert env["APP_TENANCY_HOSTS"] == \
        "acme.example=acme-example,team.acme.example=team-acme-example"
    assert own_casdoor.tenancy_env((), "http://localhost:8000") == {}


def test_overlay_renders_a_casdoor_per_own_domain_behind_the_profile():
    txt = own_casdoor.compose_overlay(("acme.example", "team.acme.example"))
    # the compose.brand-b.yaml wiring, per domain: db + casdoor + alias + volume
    for s in ("casdoor-acme-example-db:", "casdoor-acme-example:",
              "casdoor-team-acme-example:", "postgres:16-alpine",
              "casbin/casdoor:latest",
              'origin: "http://casdoor-acme-example.localtest.me:8001"',
              '- "8001:8000"', '- "8002:8000"',
              "aliases: [casdoor-acme-example.localtest.me]",
              "casdoor-acme-example-pg:", "casdoor-team-acme-example-pg:",
              "name: hugmesh-local"):
        assert s in txt, s
    # EVERY service is profile-gated (a stale overlay must change nothing)
    assert txt.count('profiles: ["own-casdoor"]') == 4
    assert own_casdoor.compose_overlay(()) == ""


def test_superdomain_only_stack_env_is_byte_identical_and_writes_nothing(tmp_path):
    gen = tmp_path / "gen"
    (gen / "tests" / "stack").mkdir(parents=True)
    plain = LocalStackNode(str(gen))._build_env()
    empty = LocalStackNode(str(gen), own_idp_domains=())._build_env()
    assert empty == plain                    # default is byte-identical (golden)
    assert plain["OWN_CASDOOR"] == ""        # explicit off — neutralises inherited env
    assert "APP_TENANCY_ISSUERS" not in plain and "APP_TENANCY_HOSTS" not in plain
    assert not os.path.exists(own_casdoor.overlay_path(str(gen)))


def test_own_domain_threads_env_and_writes_the_overlay(tmp_path):
    gen = tmp_path / "gen"
    gen.mkdir()
    node = LocalStackNode(str(gen), own_idp_domains=("acme.example",))
    env = node._build_env()
    assert env["OWN_CASDOOR"] == "1"
    assert env["APP_TENANCY_ISSUERS"] == (
        "http://localhost:8000=default,"
        "http://casdoor-acme-example.localtest.me:8001=acme-example")
    assert env["APP_TENANCY_HOSTS"] == "acme.example=acme-example"
    with open(own_casdoor.overlay_path(str(gen)), encoding="utf-8") as fh:
        assert "casdoor-acme-example:" in fh.read()


def test_prod_central_issuer_matches_the_makefile_derivation(tmp_path):
    gen = tmp_path / "gen"
    gen.mkdir()
    env = LocalStackNode(str(gen), env="prod", domain="acme.example",
                         own_idp_domains=("team.acme.example",))._build_env()
    assert env["APP_TENANCY_ISSUERS"].startswith("https://id.acme.example=default,")


def test_bootstrap_threads_own_domains_into_the_stack_node():
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig(
        own_idp_domains=("acme.example",)))
    assert boot._stack_node().own_idp_domains == ("acme.example",)


# ── 4. textual pins on the REAL Makefile / .gitignore ───────────────────────────
def _read(*parts):
    with open(os.path.join(GENERATOR_DIR, *parts), encoding="utf-8") as f:
        return f.read()


def test_makefile_wildcard_includes_the_overlay_and_gates_the_profile():
    mk = _read("Makefile")
    assert "STACK_OWN_CASDOOR_COMPOSE := tests/stack/.compose.own-domains.yaml" in mk
    assert ("STACK_OWN_CASDOOR_FLAGS := $(if $(wildcard $(STACK_OWN_CASDOOR_COMPOSE))"
            ",-f $(STACK_OWN_CASDOOR_COMPOSE),) "
            "$(if $(strip $(OWN_CASDOOR)),--profile own-casdoor,)") in mk
    # stack-up carries it on BOTH the build and the up lines
    up = mk.split("stack-up:", 1)[1].split("\nstack-", 1)[0]
    assert up.count("$(STACK_OWN_CASDOOR_FLAGS)") >= 2
    # halt/down/clean must reap the profiled services too (the reap rule)
    for target in ("stack-halt:", "stack-down:", "stack-clean:"):
        section = mk.split(target, 1)[1].split("\nstack-", 1)[0]
        assert "$(STACK_OWN_CASDOOR_DOWN_FLAGS)" in section, target
    assert "--profile own-casdoor" in \
        mk.split("STACK_OWN_CASDOOR_DOWN_FLAGS :=", 1)[1].split("\n", 1)[0]


def test_generated_overlay_is_gitignored():
    assert "tests/stack/.compose.own-domains.yaml" in _read(".gitignore")
