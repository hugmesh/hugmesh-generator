"""Per-domain 'own Casdoor vs superdomain Casdoor' (issue #47) — the remaining
NON-Qt surfaces: the CLI face of core/local_mesh_bootstrap + the Makefile channel.
(The schema/compose lane is pinned by test_domain_idp_schema.py, the Studio QT
Sign-in column by test_pages_domains_idp.py, and the ncurses menu threading by
tests/menu/build_menu_cmd_test.sh's owncas walk.)

  1. CLI: main() accepts a REPEATABLE --own-casdoor-domain NAME and threads it
     into LocalMeshBootstrapConfig.own_idp_domains — the SAME object graph the
     GUI dialog builds (GUI-CLI parity), and the exact projection of the wizard's
     Domains table (own_casdoor.own_domain_names over Domain.idp == 'own').
  2. plan (the flow's --print-plan): renders the choice — OWN_CASDOOR=1 on the
     stack-up knob line + one line per own domain carrying the SAME port/issuer
     the compose lane derives — asserted AGAINST own_casdoor/LocalStackNode, not
     against copied literals, so plan and stack cannot drift apart (the same
     cross-channel parity discipline as tests/build-matrix/check.sh).
  3. Byte-identity default: no flag => () => the plan mentions nothing (the
     omit-when-default rule every #47 emitter follows).
  4. validate(): a non-DNS name fails closed with the reason (raw CLI/menu input
     has no Domains table in front of it).
  5. Makefile channel: _MESH_BOOTSTRAP_ARGS carries the OWN_CASDOOR_DOMAINS
     passthrough (textual pin, the test_local_mesh_tor.py Makefile-pin idiom).
"""
import os

from hugmesh_studio.core import local_mesh_bootstrap as boot_mod
from hugmesh_studio.core import own_casdoor
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain
from hugmesh_studio.core.local_mesh_bootstrap import (
    LocalMeshBootstrap, LocalMeshBootstrapConfig, main,
)

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(GENERATOR_DIR)  # studio/tests -> studio -> repo root


def _boot(tmp_path, **kw):
    cfg = LocalMeshBootstrapConfig(out_dir=str(tmp_path), **kw)
    return LocalMeshBootstrap(GENERATOR_DIR, cfg)


# ── 1. CLI flag -> config field (the GUI-CLI parity seam) ───────────────────────
def test_cli_repeatable_flag_threads_own_idp_domains(tmp_path, capsys, monkeypatch):
    seen = {}

    class _Capture(LocalMeshBootstrap):
        def __init__(self, gen, cfg=None):
            seen["cfg"] = cfg
            super().__init__(gen, cfg)

    monkeypatch.setattr(boot_mod, "LocalMeshBootstrap", _Capture)
    rc = main(["plan",
               "--own-casdoor-domain", " team.example ",   # stripped
               "--own-casdoor-domain", "shop.example",
               "--own-casdoor-domain", "team.example",     # dupe collapses to first
               "--out", str(tmp_path), "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    capsys.readouterr()
    # order preserved (the 8001+ port sequence is allocated from it), deduped
    assert seen["cfg"].own_idp_domains == ("team.example", "shop.example")


def test_cli_absent_flag_is_the_empty_default(tmp_path, capsys):
    rc = main(["plan", "--out", str(tmp_path), "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    out = capsys.readouterr().out
    # nothing #47-shaped in a superdomain-only plan — omit-when-default
    assert "OWN_CASDOOR" not in out
    assert "OWN-Casdoor" not in out and "own-casdoor" not in out
    assert LocalMeshBootstrapConfig().own_idp_domains == ()


def test_cli_builds_the_same_config_the_gui_object_graph_builds(tmp_path):
    """GUI-CLI parity, the local_mesh.py discipline: both faces construct ONE
    LocalMeshBootstrapConfig. The CLI's parsed tuple must equal the projection the
    GUI takes off the wizard's Domains table (own_casdoor.own_domain_names over
    Domain.idp == 'own', in table order)."""
    table = [Domain(name="acme.example"),
             Domain(name="team.example", idp=DOMAIN_IDP_OWN),
             Domain(name="shop.example", idp=DOMAIN_IDP_OWN)]
    gui_cfg = LocalMeshBootstrapConfig(
        own_idp_domains=own_casdoor.own_domain_names(table))
    cli_cfg = boot_mod._parse_own_casdoor_domains(["team.example", "shop.example"])
    assert cli_cfg == gui_cfg.own_idp_domains == ("team.example", "shop.example")


# ── 2. plan renders the choice, in lock-step with the compose lane ──────────────
def test_plan_renders_own_domains_with_the_compose_lanes_ports_and_issuers(tmp_path):
    names = ("team.example", "shop.example")
    # generator_dir = tmp_path: _build_env() below writes the (gitignored) compose
    # overlay under <generator_dir>/tests/stack — keep that out of the real repo.
    b = LocalMeshBootstrap(str(tmp_path), LocalMeshBootstrapConfig(
        out_dir=str(tmp_path / "out"), own_idp_domains=names))
    p = b.plan()
    # the stack-up knob line discloses the env toggle LocalStackNode threads
    assert "OWN_CASDOOR=1" in p
    assert "`own-casdoor` profile" in p
    # per-domain: the SAME port + issuer own_casdoor.py allocates — and those are
    # exactly the issuers LocalStackNode threads into APP_TENANCY_ISSUERS, so the
    # plan, the overlay and the gateway registry all describe one stack.
    stack_env = b._stack_node()._build_env()
    assert stack_env["OWN_CASDOOR"] == "1"
    for i, name in enumerate(names):
        issuer = own_casdoor.issuer_for(name, i)
        assert f"{name}: host port {own_casdoor.port_for(i)}, issuer {issuer}" in p
        assert f"{issuer}={own_casdoor.slug(name)}" in stack_env["APP_TENANCY_ISSUERS"]
    # the default's whereabouts are said out loud
    assert "superdomain Casdoor" in p
    assert "tenant `default`" in p
    # plan is still pure — nothing minted
    assert not os.path.exists(b.secrets_json)


def test_plan_via_cli_prints_the_disclosure(tmp_path, capsys):
    rc = main(["plan", "--own-casdoor-domain", "team.example",
               "--out", str(tmp_path), "--generator-dir", GENERATOR_DIR])
    assert rc == 0
    out = capsys.readouterr().out
    assert "OWN_CASDOOR=1" in out
    assert own_casdoor.issuer_for("team.example", 0) in out


def test_superdomain_only_plan_is_byte_identical(tmp_path):
    """() (the default) must render the EXACT plan the field's absence rendered —
    the same golden rule the manifest emitters and the stack env follow."""
    assert _boot(tmp_path).plan() == _boot(tmp_path, own_idp_domains=()).plan()


# ── 4. validate(): raw names fail closed ────────────────────────────────────────
def test_validate_blocks_a_non_dns_own_domain(tmp_path):
    probs = _boot(tmp_path, own_idp_domains=("not a domain!",)).validate()
    assert any("own-Casdoor domain" in x and "not a domain!" in x for x in probs)
    assert "BLOCKERS" in _boot(tmp_path, own_idp_domains=("not a domain!",)).plan()
    # honest names pass — including an uppercase spelling slug() lowercases
    assert _boot(tmp_path,
                 own_idp_domains=("team.example", "Shop.Example")).validate() == []


# ── 5. the Makefile channel (textual pin, like test_local_mesh_tor.py's) ────────
def test_makefile_mesh_bootstrap_args_carry_the_passthrough():
    with open(os.path.join(GENERATOR_DIR, "Makefile"), encoding="utf-8") as f:
        mk = f.read()
    args = mk.split("_MESH_BOOTSTRAP_ARGS =", 1)[1].split("\nmesh-bootstrap-", 1)[0]
    assert ('$(foreach d,$(OWN_CASDOOR_DOMAINS),--own-casdoor-domain "$(d)")'
            in args)
