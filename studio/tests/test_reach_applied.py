"""A domain's own VPN and egress on the start paths (2026-10-21 round 2, operator ask
"tor/vpn + egress config" per domain): core/reach_apply.

What these pin, each against the bytes a start hands to `make stack-up`:

* the egress the domains that run the mesh's one Mastodon choose IS what reaches the
  stack env (EGRESS_VPN / EGRESS_VPN_CONF) and, through the real Makefile, the
  compose flags (-f compose.egress-vpn.yaml --profile egress-vpn) — on, off, the
  mesh's default, the VPN-wins rule, and the refusal for two provider files;
* a config where no such domain chose for itself starts byte-identically to before;
* every choice a route cannot apply is labelled: a domain that runs no Mastodon, any
  per-domain VPN choice, and the image, fleet and kind routes;
* the claim the labels rest on — the egress overlay carries mastodon-sidekiq and
  nothing else — is read off the compose file, so a change there turns this red.
"""
import os
import subprocess
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import plain_words, reach_apply
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
from hugmesh_studio.tui import brand_step
from hugmesh_studio.tui.superbrand_step import session_for

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
OWN = "mesh.example"

_WG = ("[Interface]\nPrivateKey = x=\nAddress = 10.2.0.2/32\n"
       "[Peer]\nPublicKey = y=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n")


@pytest.fixture
def confs(tmp_path):
    out = {}
    for n in ("mesh", "b", "c"):
        p = tmp_path / f"{n}-wg0.conf"
        p.write_text(_WG)
        out[n] = str(p)
    return out


def _row(name, services=(), egress=None, tailnet=None):
    ways = {}
    if egress is not None:
        ways["egress"] = egress
    if tailnet is not None:
        ways["tailnet"] = tailnet
    r = {"name": name, "optional_services": list(services)}
    if ways:
        r["ways"] = ways
    return r


def _cfg(rows, mesh_conf="", mesh_tick=False, **kw):
    return LocalMeshBootstrapConfig(
        cluster_domain=OWN, domains=tuple(rows),
        services=(("egress-vpn",) if mesh_tick else ()),
        egress_vpn_conf=mesh_conf, **kw)


def _env(cfg):
    boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    return boot, boot._stack_node()._build_env(write_overlays=False)


def _make_flags(env):
    """What the real Makefile makes of the env a start passes: the compose flags it
    adds and the provider file it mounts. A parse-only target: nothing runs."""
    probe = ('zz-reach-probe: ; @echo "FLAGS=$(strip $(STACK_EGRESS_FLAGS))'
             '|CONF=$(abspath $(EGRESS_VPN_CONF))"')
    env = {k: v for k, v in env.items() if not k.startswith("MAKE")}
    r = subprocess.run(["make", "-s", "--no-print-directory", "--eval", probe,
                        "zz-reach-probe"], cwd=GENERATOR_DIR, env=env,
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    line = [x for x in r.stdout.splitlines() if x.startswith("FLAGS=")][-1]
    flags, conf = line[len("FLAGS="):].split("|CONF=")
    return flags, conf


EGRESS_FLAGS = "-f tests/stack/compose.egress-vpn.yaml --profile egress-vpn"


# ── 1. the claim the labels rest on ───────────────────────────────────────────────
def test_the_egress_overlay_carries_mastodon_sidekiq_and_nothing_else():
    yaml = pytest.importorskip("yaml")
    with open(os.path.join(GENERATOR_DIR, "tests", "stack", "compose.egress-vpn.yaml"),
              encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    attached = sorted(n for n, s in doc["services"].items()
                      if (s or {}).get("network_mode") == "service:hugmesh-egress-vpn")
    assert attached == ["mastodon-sidekiq"], (
        "the egress VPN now carries more than Mastodon's delivery: update "
        "core/reach_apply (its rules and every sentence that says 'Mastodon only')")
    with open(os.path.join(GENERATOR_DIR, "tests", "stack",
                           "compose.social-profile.yaml"), encoding="utf-8") as fh:
        social = yaml.safe_load(fh)
    assert social["services"]["mastodon-sidekiq"]["profiles"] == ["social"]
    from hugmesh_studio.core.local_services import PROFILE_SOCIAL, by_slug
    assert by_slug(reach_apply.MASTODON_SLUG).profile == PROFILE_SOCIAL


# ── 2. no domain chose: byte-identical ────────────────────────────────────────────
@pytest.mark.parametrize("tick", [False, True])
def test_with_no_domain_choice_the_meshs_own_egress_reaches_the_stack(confs, tick):
    cfg = _cfg([_row(OWN), _row("b.example", ["tuwunel"])],
               mesh_conf=confs["mesh"] if tick else "", mesh_tick=tick)
    eg = cfg.applied_egress()
    assert not eg.from_domains
    assert (eg.on, eg.conf) == (cfg.effective_egress_vpn(),
                                cfg.egress_vpn_conf if tick else "")
    boot, env = _env(cfg)
    assert env["EGRESS_VPN"] == ("1" if tick else "")
    assert env.get("EGRESS_VPN_CONF") == (os.path.abspath(confs["mesh"]) if tick else None)
    assert "PER-DOMAIN" not in boot.plan()
    flags, _conf = _make_flags(env)
    assert flags == (EGRESS_FLAGS if tick else "")


# ── 3. a domain that runs Mastodon decides ────────────────────────────────────────
def test_a_mastodon_domains_own_vpn_turns_the_egress_on_with_its_file(confs):
    cfg = _cfg([_row(OWN), _row("b.example", ["tuwunel"],
                                {"mode": "vpn", "conf": confs["b"]})])
    assert not cfg.effective_egress_vpn(), "the Mesh infrastructure tick is off"
    boot, env = _env(cfg)
    assert env["EGRESS_VPN"] == "1"
    assert env["EGRESS_VPN_CONF"] == os.path.abspath(confs["b"])
    flags, conf = _make_flags(env)
    assert flags == EGRESS_FLAGS and conf == os.path.abspath(confs["b"])
    assert boot.validate() == []
    plan = boot.plan()
    assert "PER-DOMAIN EGRESS" in plan
    assert f"EGRESS_VPN=1, EGRESS_VPN_CONF={os.path.abspath(confs['b'])}" in plan
    assert "the domains' own choices win" in plan


def test_a_mastodon_domains_direct_turns_the_meshs_tick_off(confs):
    cfg = _cfg([_row(OWN), _row("b.example", ["tuwunel"], {"mode": "direct"})],
               mesh_conf=confs["mesh"], mesh_tick=True)
    boot, env = _env(cfg)
    assert env["EGRESS_VPN"] == ""
    assert "EGRESS_VPN_CONF" not in env
    assert _make_flags(env)[0] == ""
    assert any("every domain that runs Mastodon chose direct" in w
               for w in boot.warnings())


def test_the_meshs_file_is_checked_only_when_the_start_uses_it(confs, tmp_path):
    """The Mesh infrastructure tick is on with a bad (or no) provider file, but the
    domains that run the mesh's one Mastodon chose for themselves: the start never
    mounts the mesh's file, so it must not refuse over it."""
    bad = tmp_path / "not-a-vpn.conf"
    bad.write_text("hello\n")

    def mesh_refusals(cfg):
        return [p for p in LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
                if p.startswith("Egress VPN is selected")]

    for mesh_conf in (str(bad), ""):
        own_file = _cfg([_row("b.example", ["tuwunel"],
                              {"mode": "vpn", "conf": confs["b"]})],
                        mesh_conf=mesh_conf, mesh_tick=True)
        assert own_file.applied_egress().conf == os.path.abspath(confs["b"])
        assert mesh_refusals(own_file) == [], mesh_conf
        all_direct = _cfg([_row("b.example", ["tuwunel"], {"mode": "direct"})],
                          mesh_conf=mesh_conf, mesh_tick=True)
        assert not all_direct.applied_egress().on
        assert mesh_refusals(all_direct) == [], mesh_conf
        # still refused wherever the mesh's file IS what the start mounts: no domain
        # choice, or a domain VPN with no file of its own (it inherits the mesh's)
        for rows in ([_row("b.example", ["tuwunel"])],
                     [_row("b.example", ["tuwunel"], {"mode": "vpn"})]):
            cfg = _cfg(rows, mesh_conf=mesh_conf, mesh_tick=True)
            assert mesh_refusals(cfg), (mesh_conf, rows)


def test_a_domain_vpn_without_a_file_uses_the_meshs_file(confs):
    cfg = _cfg([_row("b.example", ["tuwunel"], {"mode": "vpn"})],
               mesh_conf=confs["mesh"], mesh_tick=True)
    _boot, env = _env(cfg)
    assert env["EGRESS_VPN_CONF"] == os.path.abspath(confs["mesh"])


def test_a_home_relative_provider_file_reaches_the_stack_expanded(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "wg.conf").write_text(_WG)
    cfg = _cfg([_row("b.example", ["tuwunel"], {"mode": "vpn", "conf": "~/wg.conf"})])
    boot, env = _env(cfg)
    assert env["EGRESS_VPN_CONF"] == str(tmp_path / "wg.conf")
    assert boot.validate() == []


def test_the_vpn_wins_over_direct_on_the_one_shared_mastodon(confs):
    # the mesh's own domain also runs Mastodon and inherits the mesh's VPN
    cfg = _cfg([_row(OWN, ["tuwunel"]), _row("b.example", ["tuwunel"], {"mode": "direct"})],
               mesh_conf=confs["mesh"], mesh_tick=True)
    eg = cfg.applied_egress()
    assert eg.on and eg.conf == os.path.abspath(confs["mesh"])
    boot, env = _env(cfg)
    assert env["EGRESS_VPN"] == "1"
    assert any("b.example chose direct egress but shares" in w for w in boot.warnings())
    note = reach_apply.docker_egress_note("b.example", eg)
    assert "direct was chosen" in note and OWN in note


def test_two_provider_files_for_the_one_tunnel_are_refused(confs):
    cfg = _cfg([_row("b.example", ["tuwunel"], {"mode": "vpn", "conf": confs["b"]}),
                _row("c.example", ["tuwunel"], {"mode": "vpn", "conf": confs["c"]})])
    boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    problems = boot.validate()
    hit = [p for p in problems if p.startswith("Egress VPN: ")]
    assert hit and "b-wg0.conf" in hit[0] and "c-wg0.conf" in hit[0]
    assert "REFUSED" in boot.plan()
    # the same file twice is one tunnel, not a conflict
    same = _cfg([_row("b.example", ["tuwunel"], {"mode": "vpn", "conf": confs["b"]}),
                 _row("c.example", ["tuwunel"], {"mode": "vpn", "conf": confs["b"]})])
    assert same.applied_egress().conflict == ""


def test_no_mastodon_means_the_meshs_tick_rules(confs):
    cfg = _cfg([_row("b.example", ["phpbb"], {"mode": "vpn", "conf": confs["b"]})],
               mesh_tick=False)
    assert not cfg.effective_social()
    eg = cfg.applied_egress()
    assert not eg.on and not eg.from_domains and eg.not_applied == ("b.example",)
    assert eg.carried == (), "no Mastodon runs, so nobody's egress is carried"
    boot, env = _env(cfg)
    assert env["EGRESS_VPN"] == ""
    assert "no domain runs Mastodon: the mesh's own egress choice stands" in boot.plan()


# ── 4. what cannot be applied is labelled ─────────────────────────────────────────
def test_a_domain_that_runs_no_mastodon_is_told_its_egress_is_not_applied(confs):
    cfg = _cfg([_row("b.example", ["tuwunel"]),
                _row("c.example", ["phpbb"], {"mode": "vpn", "conf": confs["c"]})])
    boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    eg = cfg.applied_egress()
    assert eg.not_applied == ("c.example",)
    assert reach_apply.docker_egress_note("c.example", eg).startswith(
        "Egress: not applied for this domain")
    assert any(w.startswith("c.example has an egress of its own") for w in boot.warnings())
    assert "c.example: its own egress is NOT applied" in boot.plan()


@pytest.mark.parametrize("prod,on,word", [(False, True, "joins none"),
                                          (True, False, "joins anyway")])
def test_a_domains_vpn_choice_is_labelled_not_applied(prod, on, word):
    cfg = _cfg([_row("b.example", tailnet=on)],
               env=("prod" if prod else "test"), auth_key=("tskey-x" if prod else ""))
    boot = LocalMeshBootstrap(GENERATOR_DIR, cfg)
    note = reach_apply.docker_tailnet_note(cfg.domains[0], cfg)
    assert note.startswith(reach_apply.DOCKER_TAILNET_NOT_APPLIED) and word in note
    assert "PER-DOMAIN VPN: NOT applied" in boot.plan()
    assert any("does not apply a per-domain VPN choice" in w for w in boot.warnings())
    # a VPN choice moves no stack byte: the overlay attaches on prod + key only
    assert boot.overlay_will_attach() is prod


def test_the_path_sentences_say_applied_only_where_it_is():
    eff = plain_words.WAY_EFFECT
    assert eff[("egress", "docker")].startswith("applied for Mastodon only")
    for key in (("tailnet", "docker"), ("tailnet", "kind"), ("tailnet", "image"),
                ("egress", "kind"), ("egress", "image")):
        assert eff[key].startswith("not applied"), key


# ── 5. the Ways section's sentence, per route (the window shows the same text) ────
def _docker_view(rows, mesh_cfg):
    state = LocalMeshDomains(domains=rows, own_name=OWN)
    owner = SimpleNamespace()
    s = session_for(owner, "docker", (mesh_cfg, state), GENERATOR_DIR)
    return s


def test_the_docker_ways_section_says_what_the_start_applies(confs):
    rows = [Domain(name=OWN), Domain(name="b.example", optional_services=["tuwunel"],
                                     ways={"egress": {"mode": "vpn", "conf": confs["b"]}}),
            Domain(name="c.example", optional_services=["phpbb"],
                   ways={"egress": {"mode": "direct"}, "tailnet": True})]
    s = _docker_view(rows, LocalMeshBootstrapConfig(cluster_domain=OWN))
    b = brand_step.brand_view(s, "b.example").reach_effect()
    c = brand_step.brand_view(s, "c.example").reach_effect()
    assert b.startswith("Egress: applied") and "b-wg0.conf" in b
    assert c.startswith("Egress: not applied for this domain")
    assert reach_apply.DOCKER_TAILNET_NOT_APPLIED in c and "joins none" in c
    for text in (b, c):
        assert reach_apply.KIND_NOT_APPLIED in text
        assert reach_apply.DOCKER_EGRESS_SCOPE in text
        assert brand_step.REACH_RECORDED_ONLY not in text
    # the text screen prints the same sentence the window shows
    lines = "\n".join(brand_step.ways_lines(brand_step.brand_view(s, "b.example")))
    for part in b.split("\n"):
        assert part in lines
    # a choice made on ANOTHER domain's tab shows here at once: c now runs Mastodon
    # with direct egress, so b's VPN wins over it
    rows[2].optional_services = ["tuwunel"]
    c2 = brand_step.brand_view(s, "c.example").reach_effect()
    assert c2.startswith("Egress: direct was chosen") and "b.example" in c2


def test_the_image_and_fleet_routes_say_they_apply_neither():
    cfg = ImageConfig()
    cfg.mode = "mesh"
    cfg.domains = [Domain(name="b.example", ways={"egress": {"mode": "direct"}})]
    s = session_for(SimpleNamespace(), "image", cfg, GENERATOR_DIR)
    assert (brand_step.brand_view(s, "b.example").reach_effect()
            == reach_apply.ROUTE_NOT_APPLIED["image"])
    assert reach_apply.ROUTE_NOT_APPLIED["image"].startswith("Not applied")
    assert reach_apply.ROUTE_NOT_APPLIED["fleet"].startswith("Not applied")
    lines = "\n".join(brand_step.ways_lines(brand_step.brand_view(s, "b.example")))
    assert reach_apply.ROUTE_NOT_APPLIED["image"] in lines
