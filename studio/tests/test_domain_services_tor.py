"""Per-domain Tor front doors — the Qt-free pins (hugmesh-generator#582).

Operator decision 68 = A on #347 (2026-09-23): "a Tor domain = its own HiddenService
stanza fronting the SAME gateway, distinguished by the onion Host". ``tor`` becomes
the ONE per-domain infra slug; egress-vpn, workloadConsole and anubis stay node- or
cluster-plane. This file pins every seam of that rule that runs without Qt, a stack
or docker:

1. the model — ``Domain.tor``, its load rules (and the legacy slot's migration), and
   the manifest key ``domains[].tor`` in BOTH emitters, omitted when false;
2. the naming rule — slug (the node contract's shape), TENANT (what the gateway
   host map maps the onion to: the domain's own brand only when it runs its own
   Casdoor, else ``default``), two names that would share one key directory, and what
   each ROUTE does with a tick (only the local docker mesh acts on it today);
3. the local docker mesh — records, saved-record round trip, the import into node
   images, and the ``TOR_ONION_DOMAINS`` env LocalStackNode passes ONLY for a TOR=1
   stack that has a Tor domain;
4. the readouts — ``LocalStackNode.onion_urls`` with #581's freshness rule, and the
   monitor's ONE Door per (domain, onion) carrying that domain's login URL;
5. Go-Live — onion accepts a domain, names one that has no front door, and both
   faces' plan shows the run's domain's own onion;
6. the compose writer — tests/stack/tor/entrypoint.sh EXECUTED against a stub tor:
   N stanzas, N readouts, the gateway host map (primary as ``default``, temp-then-
   rename, written only where its directory is mounted), refusals, and nothing
   surviving a stop;
7. the compose overlay + Makefile wiring that carries it to the fe-gateway, loaded
   only for a TOR=1 stack with a Tor domain.

Named ``test_domain_services*.py`` so tests/scripts/test-studio-tor-domain-pins.sh
(the #591 pre-merge suite) runs it by its family glob.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import time
from types import SimpleNamespace

import pytest
import yaml

from hugmesh_studio.core import domain_services as ds
from hugmesh_studio.core import mesh_monitor as mm
from hugmesh_studio.core.config import (DOMAIN_IDP_OWN, INFRA_SERVICES_CHOICES,
                                        Domain, ImageConfig)
from hugmesh_studio.core.golive_driver import GoLiveDriver, GoLiveOptions, GoLiveProvider
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.fleet import FleetDomains
from hugmesh_studio.core.golive_domains import exposure_lines, plan_rows
from hugmesh_studio.core.local_mesh_domains import (LocalMeshDomains,
                                                    apply_imported_domains,
                                                    bootstrap_domain_records,
                                                    domains_from_bootstrap,
                                                    imported_domains_lines,
                                                    imported_mesh_domains,
                                                    record_walk)
from hugmesh_studio.core.local_stack_node import LocalStackNode
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.core.worklist_driver import WorklistDriver

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
ENTRY = os.path.join(GENERATOR_DIR, "tests", "stack", "tor", "entrypoint.sh")
COMPOSE = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.local.yaml")
OVERLAY = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.tor-domains.yaml")

ONION_A = "a" * 56 + ".onion"
ONION_B = "b" * 56 + ".onion"
ONION_P = "p" * 56 + ".onion"


# ── 1. the model ──────────────────────────────────────────────────────────────────
def test_domain_tor_defaults_off_and_loads_both_spellings():
    assert Domain(name="acme.example").tor is False
    for raw, want in ((True, True), (False, False), ("true", True), ("false", False),
                      (None, False)):
        cfg = ImageConfig.from_dict({"domains": [{"name": "acme.example", "tor": raw}]})
        assert cfg.domains[0].tor is want, raw


@pytest.mark.parametrize("junk", ["yes", 1, "on", [True]])
def test_domain_tor_junk_fails_loudly_at_load(junk):
    with pytest.raises(ValueError, match="tor must be true or false"):
        ImageConfig.from_dict({"domains": [{"name": "acme.example", "tor": junk}]})


def test_a_legacy_tor_slug_on_a_domain_migrates_to_the_front_door():
    # The #580 addendum's trap: `tor` on a domain row was an INERT slot (the manifest
    # carried it, no builder read it). Decision 68 made it a mechanism, so the intent
    # moves to Domain.tor and the slug leaves the allow-list (the `games` precedent).
    cfg = ImageConfig.from_dict({"domains": [
        {"name": "acme.example", "optional_services": ["tor", "tuwunel"]}]})
    assert cfg.domains[0].tor is True
    assert cfg.domains[0].optional_services == ["tuwunel"]
    assert ds.carried_over_slugs(cfg.domains[0].optional_services) == []


def _cfg_with(*domains):
    return ImageConfig(mode="mesh", role="omnibus", cluster_domain="mesh.example",
                       brand="hugmesh", domains=list(domains))


def test_manifest_v1_carries_tor_only_when_true():
    doms = _cfg_with(Domain(name="a.example"),
                     Domain(name="b.example", tor=True)).mesh_manifest()["domains"]
    assert "tor" not in doms[0]                     # pre-#582 bytes kept
    assert doms[1]["tor"] is True


def test_manifest_v2_carries_tor_only_when_true(tmp_path):
    base = _cfg_with(Domain(name="a.example"), Domain(name="b.example", tor=True))
    base.output_dir = str(tmp_path / "out")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(role="pki", platform="x86")])
    host = HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")
    doms = WorklistDriver(str(tmp_path), wl, host=host).manifest_v2()["domains"]
    assert list(doms[0]) == ["name", "title", "optional_services", "images"]
    assert doms[1]["tor"] is True


def test_a_saved_config_round_trips_the_front_door():
    cfg = _cfg_with(Domain(name="b.example", tor=True))
    again = ImageConfig.from_dict(cfg.to_dict())
    assert again.domains[0].tor is True


# ── 2. slug + tenant ──────────────────────────────────────────────────────────────
def test_the_slug_is_the_node_contracts_shape():
    assert ds.onion_slug("acme.example") == "acme-example"
    assert ds.onion_slug("Chat.Acme.Example") == "chat-acme-example"
    assert ds.onion_slug("") == ""
    # 64 once slugged: the node refuses it, so the Studio never emits it (no
    # truncation — two long names could collide onto one key)
    assert ds.onion_slug("a" * 30 + "." + "b" * 33) == ""
    assert ds.TOR_SLUG_RE.pattern == r"^[a-z0-9][a-z0-9-]{0,62}$"


def test_the_tenant_is_the_brand_the_https_door_already_serves():
    # own Casdoor -> its own brand key (own_casdoor.tenancy_env's APP_TENANCY_HOSTS
    # value); superdomain sign-in -> `default`, because that domain has NO issuer of
    # its own and a slug tenant would 403 every signed-in user on its onion.
    from hugmesh_studio.core import own_casdoor
    own = Domain(name="shop.example", idp=DOMAIN_IDP_OWN, tor=True)
    sup = Domain(name="blog.example", tor=True)
    assert ds.onion_tenant(own) == "shop-example"
    assert own_casdoor.tenancy_env(["shop.example"], "http://x")["APP_TENANCY_HOSTS"] \
        == "shop.example=" + ds.onion_tenant(own)
    assert ds.onion_tenant(sup) == ds.TOR_DEFAULT_TENANT == "default"


def test_entries_skip_the_own_domain_off_rows_bad_names_and_collisions():
    rows = [Domain(name="mesh.example", tor=True),              # the own domain
            Domain(name="off.example"),                          # no front door
            Domain(name="shop.example", idp=DOMAIN_IDP_OWN, tor=True),
            Domain(name="blog.example", tor=True),
            Domain(name="blog-example", tor=True),               # same slug
            Domain(name="x" * 70 + ".example", tor=True)]        # no valid slug
    got = ds.tor_domain_entries(rows, own_name="mesh.example")
    assert got == [("shop.example", "shop-example", "shop-example"),
                   ("blog.example", "blog-example", "default")]
    assert ds.tor_onion_domains_env(got) == "shop-example=shop-example blog-example=default"
    assert ds.tor_onion_domains_env([]) == ""
    # record dicts (the local-mesh shape) read the same; only a real True counts
    recs = [{"name": "a.example", "tor": True}, {"name": "b.example", "tor": "true"}]
    assert [e[0] for e in ds.tor_domain_entries(recs)] == ["a.example"]


def test_only_tor_is_a_per_domain_infra_slug():
    assert ds.PER_DOMAIN_INFRA == ("tor",)
    assert ds.scope_of("tor") == ds.SCOPE_NODE          # the node daemon stays node-scoped
    assert ds.SCOPE_LABELS[ds.SCOPE_ONION] == "onion (per domain)"
    for slug in INFRA_SERVICES_CHOICES:
        if slug != "tor":
            assert slug not in ds.PER_DOMAIN_INFRA
    # the read-only table still shows all four infra slugs, tor included (the node
    # must RUN tor for any onion), and says where the per-domain half lives
    assert [r[0] for r in ds.other_scope_rows(ImageConfig())][:4] == list(INFRA_SERVICES_CHOICES)
    assert "Tor front door" in ds.INFRA_WHERE["tor"]


def _mesh(*rows):
    """A local docker mesh's domain rows — the route that ACTS on a tick."""
    return LocalMeshDomains(domains=[Domain(name="mesh.example"), *rows],
                            own_name="mesh.example")


def test_row_state_names_the_login_and_the_missing_daemon():
    sup = Domain(name="blog.example", tor=True)
    own = Domain(name="shop.example", idp=DOMAIN_IDP_OWN, tor=True)
    off = ImageConfig(mode="mesh")
    on = ImageConfig(mode="mesh", optional_services=["tor"])
    assert "DEFAULT brand" in ds.tor_row_state(sup, on)
    assert "own login" in ds.tor_row_state(own, on)
    assert "Tor is off" in ds.tor_row_state(own, off)
    assert "Tor is off" not in ds.tor_row_state(own, on)
    # per-node opt-in counts as Tor on the mesh
    node = SimpleNamespace(id="omnibus.x86", infra_services=("tor",))
    assert "Tor is off" not in ds.tor_row_state(own, off, [node])
    # a host that cannot know (the local docker mesh's step, cfg None) says so
    assert "must be on for the mesh" in ds.tor_row_state(own, None, walked=_mesh(own))
    assert ds.tor_row_state(Domain(name="x.example"), on).startswith("off")
    assert ds.tor_row_state(Domain(name="mesh.example", tor=True), on,
                            own_name="mesh.example") == ds.TOR_OWN_DOMAIN_NOTE
    assert "too long" in ds.tor_row_state(Domain(name="x" * 70 + ".example", tor=True), on)


def test_each_route_says_what_a_tick_does_there():
    # The row must never let the operator believe a node image will mint the onion:
    # only the local docker mesh acts on the tick today (TOR_REACH).
    own = Domain(name="shop.example", idp=DOMAIN_IDP_OWN, tor=True)
    image = ImageConfig(mode="mesh", optional_services=["tor"])
    client = ImageConfig(mode="cloud", role="desktop")
    fleet = FleetDomains(domains=[Domain(name="mesh.example"), own],
                         own_name="mesh.example")
    assert [ds.tor_route(x) for x in (_mesh(own), image, client, fleet)] == \
        [ds.TOR_ROUTE_COMPOSE, ds.TOR_ROUTE_IMAGE, ds.TOR_ROUTE_CLIENT,
         ds.TOR_ROUTE_FLEET]
    assert ds.tor_route(object()) == ds.TOR_ROUTE_IMAGE    # unknown: claim the least
    compose = ds.tor_row_state(own, None, walked=_mesh(own))
    assert compose.startswith("on — its own onion") and "takes effect" in compose
    assert not ds.tor_row_warns(own, None, walked=_mesh(own))
    for cfg, scope, words in ((image, image, "NOT YET BUILT INTO A NODE"),
                              (client, client, "RECORDED ONLY"),
                              (fleet, None, "RECORDED ONLY")):
        line = ds.tor_row_state(own, scope, walked=cfg)
        # "ticked", never "on — its own onion": this route mints nothing
        assert line.startswith("ticked — it would be") and words in line, line
        assert "on — its own onion" not in line
        assert ds.tor_row_warns(own, scope, walked=cfg)
        # and the operator is told BEFORE ticking, too
        assert words in ds.tor_row_state(Domain(name="x.example"), scope, walked=cfg)
    assert not ds.tor_row_warns(Domain(name="x.example"), image, walked=image)


def test_no_builder_writes_a_nodes_tor_domains_file_yet():
    # TOR_REACH's image sentence ("no image builder reads it") is a claim about the
    # builders. This is that claim, measured: nothing under the build scripts writes
    # /etc/hugmesh/tor/domains or reads a manifest's domains[]. The day a builder
    # does, this fails — and the sentence on the page has to change with it.
    import glob
    builders = (glob.glob(os.path.join(GENERATOR_DIR, "build-*-stage4.sh"))
                + glob.glob(os.path.join(GENERATOR_DIR, "scripts", "*.sh")))
    assert len(builders) > 10
    for path in builders:
        text = open(path, encoding="utf-8", errors="replace").read()
        assert "hugmesh/tor/domains" not in text, path
    assert "no image builder reads it" in ds.TOR_REACH[ds.TOR_ROUTE_IMAGE]


def test_two_names_with_one_key_directory_name_are_told_apart_on_the_row():
    # "a-b.example" and "a.b.example" slug alike. Only the first in table order is
    # minted (tor_domain_entries) — and the SECOND one's row has to say so, not claim
    # an onion it will not get.
    a = Domain(name="a-b.example", tor=True)
    b = Domain(name="a.b.example", tor=True)
    rows = [Domain(name="mesh.example"), a, b]
    assert [e[0] for e in ds.tor_domain_entries(rows, "mesh.example")] == ["a-b.example"]
    assert ds.tor_slug_clash(b, rows, "mesh.example") == "a-b.example"
    assert ds.tor_slug_clash(a, rows, "mesh.example") == ""
    line = ds.tor_row_state(b, None, walked=_mesh(a, b), domains=rows)
    assert line.startswith("on, but") and "a-b.example comes first" in line
    assert ds.tor_row_warns(b, None, walked=_mesh(a, b), domains=rows)
    assert not ds.tor_row_warns(a, None, walked=_mesh(a, b), domains=rows)
    # an earlier domain that is NOT a Tor domain claims nothing
    a.tor = False
    assert ds.tor_slug_clash(b, rows, "mesh.example") == ""


# ── 3. the local docker mesh ──────────────────────────────────────────────────────
def test_records_carry_tor_only_when_true_and_never_for_the_own_domain():
    rows = [Domain(name="mesh.example", tor=True),
            Domain(name="a.example"), Domain(name="b.example", tor=True)]
    recs = bootstrap_domain_records(rows, own_name="mesh.example")
    by = {r["name"]: r for r in recs}
    assert "tor" not in by["a.example"]
    assert by["b.example"]["tor"] is True
    assert "tor" not in by.get("mesh.example", {})
    # an untouched own domain stays unrecorded (emission neutrality) — a tor on it
    # is not "something the rest of the config does not carry"... except it is not
    # a front door either; the row is recorded only for its OTHER fields.
    assert bootstrap_domain_records([Domain(name="mesh.example")], "mesh.example") == ()


def test_a_saved_record_round_trips_the_front_door():
    rows = [Domain(name="mesh.example"), Domain(name="b.example", tor=True)]
    cfg = LocalMeshBootstrapConfig(cluster_domain="mesh.example",
                                   domains=bootstrap_domain_records(rows, "mesh.example"))
    again = LocalMeshBootstrapConfig.from_dict(cfg.to_dict())
    md = domains_from_bootstrap(again)
    assert md.by_name("b.example").tor is True
    assert md.by_name("mesh.example").tor is False
    # a hand-edited "yes" is not an onion
    junk = LocalMeshBootstrapConfig.from_dict(
        {"domains": [{"name": "c.example", "tor": "yes"}]})
    assert "tor" not in junk.domains[0]


def test_record_walk_writes_the_walks_front_door_into_the_record():
    rec = LocalMeshBootstrapConfig(cluster_domain="mesh.example",
                                   domains=({"name": "b.example", "title": "",
                                             "idp": "superdomain",
                                             "optional_services": []},))
    md = LocalMeshDomains(domains=[Domain(name="mesh.example"),
                                   Domain(name="b.example", tor=True)],
                          own_name="mesh.example")
    record_walk(rec, md, ["b.example"])
    assert rec.domains[0]["tor"] is True
    md.by_name("b.example").tor = False
    record_walk(rec, md, ["b.example"])
    assert "tor" not in rec.domains[0]


def test_the_import_into_node_images_keeps_the_front_door():
    # #636's "Create nodes for local cloud" import copies each saved domain's title,
    # sign-in and services onto the image flow's rows. It landed without Domain.tor,
    # so merged as-is it dropped the front door the local mesh was run with.
    rows = [Domain(name="mesh.example"), Domain(name="b.example", tor=True),
            Domain(name="c.example")]
    saved = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example",
        domains=bootstrap_domain_records(rows, "mesh.example"))
    md = imported_mesh_domains(saved)
    cfg = ImageConfig(mode="mesh", cluster_domain="mesh.example")
    assert apply_imported_domains(cfg, md) == ["b.example", "c.example"]
    by = {d.name: d for d in cfg.domains}
    assert by["b.example"].tor is True and by["c.example"].tor is False
    assert cfg.mesh_manifest()["domains"][0]["tor"] is True
    # an existing row of the same name takes the record's answer, either way
    cfg.domains[1].tor = True
    apply_imported_domains(cfg, md)
    assert {d.name: d.tor for d in cfg.domains} == {"b.example": True,
                                                    "c.example": False}
    lines = imported_domains_lines(md)
    assert lines[0].endswith("; its own Tor front door")
    assert "Tor" not in lines[1]


def _boot(tmp_path, with_tor, own_idp=(), tor_rows=True):
    cfg = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example", with_tor=with_tor, own_idp_domains=own_idp,
        domains=tuple(dict(r, **({"tor": True} if tor_rows else {})) for r in (
            {"name": "shop.example", "title": "", "idp": "own",
             "optional_services": []},
            {"name": "blog.example", "title": "", "idp": "superdomain",
             "optional_services": []},
            {"name": "mesh.example", "title": "T", "idp": "superdomain",
             "optional_services": []})))
    return LocalMeshBootstrap(str(tmp_path), cfg)


def test_a_tor_stack_threads_one_entry_per_tor_domain(tmp_path, monkeypatch):
    monkeypatch.setenv("TOR_ONION_DOMAINS", "inherited=default")
    node = _boot(tmp_path, True, own_idp=("shop.example",))._stack_node()
    env = node._build_env(write_overlays=False)
    # the own domain is the primary onion, never an entry; the tenant follows what
    # the stack REGISTERS (own_idp_domains), and the inherited value is overridden
    assert env["TOR_ONION_DOMAINS"] == "shop-example=shop-example blog-example=default"
    assert env["TOR"] == "1"


def test_the_tenant_follows_own_idp_domains_not_the_rows_label(tmp_path):
    # a row labelled idp=own that the stack does not stand a Casdoor up for has no
    # issuer in APP_TENANCY_*, so its onion must map to `default`
    node = _boot(tmp_path, True, own_idp=())._stack_node()
    assert node._build_env(write_overlays=False)["TOR_ONION_DOMAINS"] == \
        "shop-example=default blog-example=default"


def test_a_tor_off_stack_threads_nothing(tmp_path, monkeypatch):
    monkeypatch.setenv("TOR_ONION_DOMAINS", "inherited=default")
    node = _boot(tmp_path, False)._stack_node()
    env = node._build_env(write_overlays=False)
    assert "TOR_ONION_DOMAINS" not in env
    assert env["TOR"] == ""
    assert node.tor_domains_overlay == ""


def test_a_tor_stack_with_no_tor_domain_passes_nothing_new(tmp_path, monkeypatch):
    # TOR=1 and no Tor domain is the one-onion stack it always was: the variable is
    # ABSENT (never set empty), so the env equals the one from before this existed —
    # and an inherited value still cannot mint onions this mesh never chose.
    monkeypatch.delenv("TOR_ONION_DOMAINS", raising=False)
    node = _boot(tmp_path, True, tor_rows=False)._stack_node()
    plain = node._build_env(write_overlays=False)
    assert plain["TOR"] == "1" and "TOR_ONION_DOMAINS" not in plain
    assert node.tor_domains_overlay == ""
    monkeypatch.setenv("TOR_ONION_DOMAINS", "inherited=default")
    assert node._build_env(write_overlays=False) == plain


def test_a_scale_loads_the_overlay_the_stack_was_brought_up_with(tmp_path, monkeypatch):
    # A replica created without the overlay would be an fe-gateway with no onion host
    # map: it would serve every onion as the default brand while its siblings refuse
    # the unregistered ones.
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    unit = SimpleNamespace(scale=mm.ScaleTarget("compose-service", "hugmesh-fe-gateway",
                                                "hugmesh-local", refused=""))
    with_doms = _boot(tmp_path, True)._stack_node()
    overlay = os.path.join(str(tmp_path), "tests", "stack", "compose.tor-domains.yaml")
    assert with_doms.tor_domains_overlay == overlay
    argv, refused = mm.scale_argv(unit, 2, generator_dir=str(tmp_path), node=with_doms)
    assert not refused
    assert argv[:9] == ["docker", "compose", "-p", "hugmesh-local",
                        "-f", with_doms.compose_file, "-f", overlay, "up"]
    # no Tor domain: exactly the command from before
    plain = _boot(tmp_path, True, tor_rows=False)._stack_node()
    argv, _ = mm.scale_argv(unit, 2, generator_dir=str(tmp_path), node=plain)
    assert argv == ["docker", "compose", "-p", "hugmesh-local", "-f", plain.compose_file,
                    "up", "-d", "--no-deps", "--no-recreate", "--scale",
                    "hugmesh-fe-gateway=2", "hugmesh-fe-gateway"]


# ── 4. the readouts ───────────────────────────────────────────────────────────────
def _onion_dir(tmp_path):
    d = tmp_path / "tests" / "stack" / "tor-onion"
    d.mkdir(parents=True)
    return d


def test_onion_urls_are_fresh_valid_and_per_slug(tmp_path, monkeypatch):
    d = _onion_dir(tmp_path)
    (d / "hostname").write_text(ONION_P + "\n")
    (d / "brandb.hostname").write_text(ONION_B + "\n")
    (d / "acme-example.hostname").write_text(ONION_A + "\n")
    (d / "Bad_Slug.hostname").write_text(ONION_A + "\n")       # slug the node refuses
    (d / "junk.hostname").write_text("not-an-onion\n")          # not a v3 onion
    stale = d / "gone.hostname"
    stale.write_text(ONION_A + "\n")
    old = time.time() - 3600
    os.utime(stale, (old, old))                                 # a previous container's
    node = LocalStackNode(str(tmp_path))
    monkeypatch.setattr(node, "_tor_started_at", lambda: time.time() - 60)
    assert node.onion_urls() == {"acme-example": f"https://{ONION_A}/",
                                 "brandb": f"https://{ONION_B}/"}
    assert node.onion_url("brandb") == f"https://{ONION_B}/"
    # by the domain's NAME as well as by its key directory name
    assert node.onion_url("acme.example") == f"https://{ONION_A}/"
    assert node.onion_url("acme-example") == f"https://{ONION_A}/"
    assert node.onion_url("other.example") == ""
    assert node.onion_url("gone") == ""
    assert node.onion_url() == f"https://{ONION_P}/"            # the primary unchanged
    # nothing running -> nothing handed out (#581's rule, per-domain half)
    monkeypatch.setattr(node, "_tor_started_at", lambda: None)
    assert node.onion_urls() == {} and node.onion_url("brandb") == ""


class _MonNode:
    """A LocalStackNode stand-in: scripted compose ps, a primary onion, and the
    per-domain readouts ``onion_urls`` would hand out."""
    compose_file = "/g/tests/stack/compose.local.yaml"
    public_https_port = 8488
    public_host_port = 8088
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, rows_text, onion="", domains=None, names=()):
        self._rows, self._onion = rows_text, onion
        self._domains = dict(domains or {})
        self.tor_domains = names

    def status(self):
        return SimpleNamespace(running=True, detail="2 container(s)")

    def onion_url(self):
        return self._onion

    def onion_urls(self):
        return dict(self._domains)

    def _probe(self, cmd, timeout=15):
        if "compose -f" in " ".join(cmd):
            return 0, self._rows
        return 1, f"unscripted: {cmd}"


_TOR_ROWS = [
    {"Name": "hugmesh-local-hugmesh-tor-1", "Service": "hugmesh-tor", "State": "running",
     "Status": "Up (healthy)", "Health": "healthy", "Image": "tor", "ExitCode": 0,
     "Publishers": []},
    {"Name": "hugmesh-local-hugmesh-tor-client-1", "Service": "hugmesh-tor-client",
     "State": "running", "Status": "Up (healthy)", "Health": "healthy", "Image": "tor",
     "ExitCode": 0,
     "Publishers": [{"URL": "127.0.0.1", "TargetPort": 9050, "PublishedPort": 9050,
                     "Protocol": "tcp"}]},
]


def _monitor_units(monkeypatch, **kw):
    import json
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    node = _MonNode(json.dumps(_TOR_ROWS), **kw)
    lane, units, _notes, errors = mm._compose_units(node, "/g", [], {}, mm._Budget(25))
    assert lane.running is True and not errors
    return units


def test_the_monitor_shows_one_door_per_domain_onion(monkeypatch):
    units = _monitor_units(
        monkeypatch, onion=f"https://{ONION_P}/",
        domains={"brandb": f"https://{ONION_B}/", "acme-example": f"https://{ONION_A}/"},
        names=(("acme.example", "acme-example", "default"),))
    tor = [u for u in units if u.owner == "hugmesh-tor"]
    assert len(tor) == 3                                 # the container + two onions
    primary, *doors = tor
    assert ONION_P in primary.external                   # the primary row is unchanged
    by = {u.name: u for u in doors}
    assert sorted(by) == ["hugmesh-local-hugmesh-tor-1 · acme.example onion",
                          "hugmesh-local-hugmesh-tor-1 · brandb onion"]
    a = by["hugmesh-local-hugmesh-tor-1 · acme.example onion"]
    b = by["hugmesh-local-hugmesh-tor-1 · brandb onion"]
    # THAT domain's login URL, over https — the primary door's scheme (#598/#600/#628)
    assert a.external == f"https://{ONION_A}/login"
    assert b.external == f"https://{ONION_B}/login"
    for u in (a, b):
        assert u.door.url == "" and u.external in u.door.blocked
        assert "Tor Browser" in u.door.blocked
        assert u.ready == primary.ready and u.phase == primary.phase
        assert u.scale.refused                           # one tor, not a workload
    # the SOCKS client never carries an onion
    client = [u for u in units if u.owner == "hugmesh-tor-client"]
    assert len(client) == 1 and ".onion" not in client[0].external


def test_no_domain_onions_means_no_extra_rows(monkeypatch):
    units = _monitor_units(monkeypatch, onion=f"https://{ONION_P}/")
    assert len([u for u in units if u.owner == "hugmesh-tor"]) == 1


def test_a_node_without_the_seam_still_renders(monkeypatch):
    class _Old(_MonNode):
        def onion_urls(self):
            raise RuntimeError("no such seam")
    import json
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    lane, units, _n, errors = mm._compose_units(_Old(json.dumps(_TOR_ROWS)), "/g", [],
                                                {}, mm._Budget(25))
    assert not errors and len([u for u in units if u.owner == "hugmesh-tor"]) == 1


# ── 5. Go-Live ────────────────────────────────────────────────────────────────────
def _golive(tmp_path, monkeypatch, cluster_domain="mesh.example"):
    exp = tmp_path / "export"
    exp.mkdir()
    (exp / "hostname").write_text(ONION_P + "\n")
    (exp / "shop-example.hostname").write_text(ONION_A + "\n")
    (exp / "half-written.hostname").write_text("not-an-onion\n")
    cd = tmp_path / "cluster-domain"
    cd.write_text(cluster_domain + "\n" if cluster_domain else "")
    monkeypatch.setenv("GL_ONION_EXPORT_DIR", str(exp))
    monkeypatch.setenv("GOLIVE_CLUSTER_DOMAIN_FILE", str(cd))
    monkeypatch.setenv("GOLIVE_DOMAINS_FILE", str(tmp_path / "no-domains-file"))
    drv = GoLiveDriver(GENERATOR_DIR)
    drv._providers = [GoLiveProvider(id="tor-onion", mechanism="onion", model="onion"),
                      GoLiveProvider(id="byo-domain", mechanism="files", model="dns")]
    return drv


def test_golive_onion_accepts_a_tor_domain_and_names_one_without_a_front_door(
        tmp_path, monkeypatch):
    drv = _golive(tmp_path, monkeypatch)
    # ONE reader of the export directory (the plan's), so only a well-formed v3
    # address under a well-formed name counts
    assert drv.tor_domain_onions() == {"shop-example": ONION_A}
    assert drv.domain_onion("shop.example") == ONION_A
    assert drv.domain_onion("blog.example") == ""
    assert drv.domain_onion("") == ""

    def probs(domain):
        return [p for p in drv.preflight(GoLiveOptions(provider="tor-onion", domain=domain))
                if "Tor front door" in p]
    assert probs("") == []                              # onion still needs no domain
    assert probs("mesh.example") == []                  # the node's own = the primary
    assert probs("shop.example") == []                  # a Tor domain here
    miss = probs("blog.example")
    assert len(miss) == 1 and "blog.example" in miss[0] and "shop-example" in miss[0]


def test_golive_says_nothing_about_a_front_door_where_the_own_domain_is_unknown(
        tmp_path, monkeypatch):
    # No baked cluster domain (the Studio on a workstation): the typed domain may
    # well be the node's own, which the node's onion opens — so nothing is claimed.
    drv = _golive(tmp_path, monkeypatch, cluster_domain="")
    opts = GoLiveOptions(provider="tor-onion", domain="blog.example")
    assert [p for p in drv.preflight(opts) if "Tor front door" in p] == []
    assert not [w for w, _h in plan_rows(drv, opts) if "this run's domain" in w]


def test_the_golive_plan_names_the_runs_domain_onion_on_both_faces(tmp_path, monkeypatch):
    # plan_rows is the ONE call the GUI's Generate step and the TUI's go-live screen
    # both render, so a row here IS on both faces.
    drv = _golive(tmp_path, monkeypatch)

    def run_row(domain, provider="tor-onion"):
        rows = plan_rows(drv, GoLiveOptions(provider=provider, domain=domain))
        return [h for w, h in rows if w == f"Tor: {domain} (this run's domain)"]
    assert run_row("shop.example") == [
        f"https://{ONION_A}/ — this domain's own onion, the same gateway"]
    none = run_row("blog.example")
    assert len(none) == 1 and none[0].startswith("no onion of its own on this node")
    # nothing is added for the cluster domain, for no domain, or another mechanism
    assert run_row("mesh.example") == [] and run_row("") == []
    assert run_row("shop.example", provider="byo-domain") == []
    # the TUI screen prints exactly these lines
    from hugmesh_studio.tui.golive import GoLiveScreen
    screen = GoLiveScreen()
    screen.driver = drv
    screen.opts = GoLiveOptions(provider="tor-onion", domain="shop.example")
    text = "\n".join(screen.plan_lines(SimpleNamespace(generator_dir=GENERATOR_DIR)))
    assert text == "\n".join(exposure_lines(plan_rows(drv, screen.opts)))
    assert f"Tor: shop.example (this run's domain)  https://{ONION_A}/" in text


# ── 6. the compose writer, EXECUTED ───────────────────────────────────────────────
_STUB_TOR = r'''#!/bin/sh
# stub tor: honour -f, mint EVERY configured onion (one per HiddenServiceDir, named
# after the directory), record what was published when it started, then idle or die.
[ "$1" = "-f" ] || { echo "stub tor: expected -f <torrc>, got $*" >&2; exit 64; }
torrc="$2"
if [ -n "${STUB_SEEN:-}" ]; then
  ls -a "$STUB_OUT" "$STUB_MAP" > "$STUB_SEEN" 2>/dev/null || true
fi
sleep 0.3
sed -n 's/^HiddenServiceDir //p' "$torrc" | while read -r hs; do
  base="$(basename "$hs")"
  case "$base" in
    hugmesh-onion) c=p ;;
    brandb) c=b ;;
    acme-example) c=a ;;
    *) c=z ;;
  esac
  if [ "${STUB_BAD:-}" = "$base" ]; then
    echo "evil.example" > "$hs/hostname"
  else
    printf '%s.onion\n' "$(printf "%056d" 0 | tr 0 "$c")" > "$hs/hostname"
  fi
done
log="$(sed -n 's/^Log notice file //p' "$torrc")"
[ -n "$log" ] && echo "[notice] Bootstrapped 100% (done): Done" >> "$log"
if [ -n "${STUB_DIE:-}" ]; then sleep 1.5; exit "$STUB_DIE"; fi
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
'''


def _exe(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _sandbox(tmp_path, domains, map_dir=True):
    # ``map_dir`` False = the host map's directory is NOT mounted, which is every
    # stack with no Tor domain (compose mounts it through the overlay only).
    for sub in ("bin", "data", "out") + (("map",) if map_dir else ()):
        (tmp_path / sub).mkdir()
    _exe(tmp_path / "bin" / "tor", _STUB_TOR)
    _exe(tmp_path / "bin" / "chown", "#!/bin/sh\nexit 0\n")
    # A SLOW cp for the per-domain readouts only: if the primary were published
    # before them, the moment it appears would find them missing — deterministically,
    # not by a millisecond race.
    real_cp = shutil.which("cp")
    _exe(tmp_path / "bin" / "cp",
         "#!/bin/sh\n"
         "for last; do :; done\n"
         'case "$last" in */hostname) ;; *.hostname) sleep 0.4 ;; esac\n'
         f'exec "{real_cp}" "$@"\n')
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("TOR_", "HUGMESH_TOR_"))}
    env.update({
        "PATH": str(tmp_path / "bin") + os.pathsep + env.get("PATH", ""),
        "HUGMESH_TOR_DATA_DIR": str(tmp_path / "data"),
        "HUGMESH_TOR_OUT_DIR": str(tmp_path / "out"),
        "HUGMESH_TOR_TORRC": str(tmp_path / "torrc"),
        "HUGMESH_TOR_BIN": str(tmp_path / "bin" / "tor"),
        "HUGMESH_TOR_MAP_DIR": str(tmp_path / "map"),
        "STUB_OUT": str(tmp_path / "out"), "STUB_MAP": str(tmp_path / "map"),
        "STUB_SEEN": str(tmp_path / "seen"),
        "TOR_ONION_UPSTREAM": "up80.test:8080",
        "TOR_ONION_TLS_UPSTREAM": "up443.test:8443",
    })
    if domains is not None:
        env["TOR_ONION_DOMAINS"] = domains
    return env


def _wait(pred, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def _run_until_published(tmp_path, domains, map_dir=True, extra_env=None):
    env = _sandbox(tmp_path, domains, map_dir=map_dir)
    env.update(extra_env or {})
    proc = subprocess.Popen(["sh", ENTRY], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    primary = tmp_path / "out" / "hostname"
    ok = _wait(lambda: primary.exists() and primary.read_text().strip())
    # captured THE MOMENT the primary appears: the primary is published LAST, so the
    # map and every domain readout must already be there
    snap = {p.name: p.read_text() for p in (tmp_path / "out").iterdir()}
    mp = tmp_path / "map" / "onion-hosts.map"
    snap_map = mp.read_text() if mp.exists() else None
    return proc, ok, snap, snap_map


def _stop(proc):
    proc.terminate()
    try:
        return proc.wait(timeout=10), proc.stdout.read()
    except subprocess.TimeoutExpired:
        proc.kill()
        return -999, ""


def _hs_dirs(torrc_text):
    return re.findall(r"^HiddenServiceDir (.+)$", torrc_text, re.M)


def test_n_domains_mint_n_stanzas_n_readouts_and_one_host_map(tmp_path):
    proc, ok, snap, snap_map = _run_until_published(
        tmp_path, "brandb=brandb, acme-example=default BAD=x brandb ok=Not_Valid")
    try:
        assert ok, "the primary onion was never published"
        torrc = (tmp_path / "torrc").read_text()
        data = str(tmp_path / "data")
        assert _hs_dirs(torrc) == [f"{data}/hugmesh-onion",
                                   f"{data}/hugmesh-onion.d/brandb",
                                   f"{data}/hugmesh-onion.d/acme-example"]
        # every stanza fronts the SAME two upstreams
        assert torrc.count("HiddenServicePort 80 up80.test:8080") == 3
        assert torrc.count("HiddenServicePort 443 up443.test:8443") == 3
        assert torrc.count("HiddenServiceVersion 3") == 3
        # readouts: already in place when the primary appeared
        assert snap.get("brandb.hostname", "").strip() == ONION_B
        assert snap.get("acme-example.hostname", "").strip() == ONION_A
        assert snap_map is not None, "the host map was not written before the primary"
        lines = [ln for ln in snap_map.splitlines() if ln and not ln.startswith("#")]
        # the mesh's own onion FIRST, as `default` (#39 writer contract point 1)
        assert lines == [f"{ONION_P}=default", f"{ONION_B}=brandb",
                         f"{ONION_A}=default"]
        # temp-then-rename: no temp file left beside it
        assert sorted(os.listdir(tmp_path / "map")) == ["onion-hosts.map"]
    finally:
        rc, log = _stop(proc)
    assert rc == 0
    assert "REFUSED TOR_ONION_DOMAINS entry 'BAD=x'" in log
    assert "REFUSED TOR_ONION_DOMAINS entry 'ok=Not_Valid'" in log
    assert "skipped a repeated TOR_ONION_DOMAINS slug 'brandb'" in log
    # nothing outlives the container: readouts AND the map
    assert os.listdir(tmp_path / "out") == []
    assert not (tmp_path / "map" / "onion-hosts.map").exists()


def test_a_bare_slug_is_its_own_tenant(tmp_path):
    proc, ok, snap, snap_map = _run_until_published(tmp_path, "solo")
    try:
        assert ok
        lines = [ln for ln in snap_map.splitlines() if not ln.startswith("#")]
        assert lines == [f"{ONION_P}=default", "z" * 56 + ".onion=solo"]
        assert "solo.hostname" in snap
    finally:
        _stop(proc)


def test_no_domains_keeps_the_torrc_to_one_stanza_and_maps_the_primary(tmp_path):
    proc, ok, snap, snap_map = _run_until_published(tmp_path, "")
    try:
        assert ok
        torrc = (tmp_path / "torrc").read_text()
        assert _hs_dirs(torrc) == [str(tmp_path / "data") + "/hugmesh-onion"]
        assert "hugmesh-onion.d" not in torrc and "#582" not in torrc
        assert sorted(snap) == ["hostname"]
        assert [ln for ln in snap_map.splitlines() if not ln.startswith("#")] == \
            [f"{ONION_P}=default"]
    finally:
        _stop(proc)


# What the script wrote as its torrc BEFORE per-domain onions existed, for the same
# inputs. A stack with no Tor domain must get exactly these bytes.
_TORRC_BEFORE_582 = """DataDirectory {data}
User tor
# We SERVE an onion — we are not a SOCKS proxy and not a relay.
SocksPort 0
HiddenServiceDir {data}/hugmesh-onion
HiddenServiceVersion 3
HiddenServicePort 80 up80.test:8080
HiddenServicePort 443 up443.test:8443
Log notice stdout
Log notice file {data}/notice.log
"""


def test_a_stack_with_no_tor_domain_gets_no_map_and_the_old_torrc(tmp_path):
    # The map directory is mounted only by the overlay (a TOR=1 stack WITH a Tor
    # domain). Without it this script must do what it always did: no map, no new
    # directory, the same torrc byte for byte, the one readout, no new log line.
    proc, ok, snap, snap_map = _run_until_published(tmp_path, None, map_dir=False)
    try:
        assert ok
        assert (tmp_path / "torrc").read_text() == \
            _TORRC_BEFORE_582.format(data=str(tmp_path / "data"))
        assert sorted(snap) == ["hostname"] and snap_map is None
        assert not (tmp_path / "map").exists()
        assert not (tmp_path / "data" / "hugmesh-onion.d").exists()
    finally:
        rc, log = _stop(proc)
    assert rc == 0
    assert "host map" not in log and "NOTE" not in log and "WARNING" not in log


def test_domains_without_the_map_directory_are_minted_and_say_so(tmp_path):
    # TOR_ONION_DOMAINS given by hand without the overlay: the onions are minted and
    # read out, no map is written, and the log says every onion is the default brand.
    proc, ok, snap, snap_map = _run_until_published(tmp_path, "brandb=brandb",
                                                    map_dir=False)
    try:
        assert ok and snap.get("brandb.hostname", "").strip() == ONION_B
        assert snap_map is None and not (tmp_path / "map").exists()
    finally:
        _rc, log = _stop(proc)
    assert "NOTE: Tor domains are listed but" in log
    assert "served as the default brand" in log


def test_only_a_well_formed_onion_name_reaches_the_map(tmp_path):
    # The map decides which brand a Host is served as, so nothing but a v3 onion
    # name is ever written into it. STUB_BAD makes the stub tor mint a malformed
    # name for one domain; a malformed PRIMARY writes no map at all (the gateway then
    # refuses every onion, which is the closed state).
    proc, ok, _snap, snap_map = _run_until_published(
        tmp_path, "brandb=brandb acme-example=default",
        extra_env={"STUB_BAD": "brandb"})
    try:
        assert ok
        assert [ln for ln in snap_map.splitlines() if not ln.startswith("#")] == \
            [f"{ONION_P}=default", f"{ONION_A}=default"]
    finally:
        _stop(proc)


def test_a_malformed_primary_writes_no_map_at_all(tmp_path):
    proc, ok, _snap, snap_map = _run_until_published(
        tmp_path, "brandb=brandb", extra_env={"STUB_BAD": "hugmesh-onion"})
    try:
        assert ok and snap_map is None
    finally:
        _rc, log = _stop(proc)
    assert "the gateway host map could not be written" in log


def test_a_previous_runs_readouts_and_map_are_gone_before_tor_starts(tmp_path):
    env = _sandbox(tmp_path, "brandb=brandb")
    (tmp_path / "out" / "brandb.hostname").write_text(ONION_A + "\n")
    (tmp_path / "out" / "dropped.hostname").write_text(ONION_A + "\n")
    (tmp_path / "map" / "onion-hosts.map").write_text(f"{ONION_A}=brandb\n")
    proc = subprocess.Popen(["sh", ENTRY], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    try:
        assert _wait(lambda: (tmp_path / "out" / "hostname").exists())
        seen = (tmp_path / "seen").read_text()
        assert "brandb.hostname" not in seen and "dropped.hostname" not in seen
        assert "onion-hosts.map" not in seen
        assert not (tmp_path / "out" / "dropped.hostname").exists()
    finally:
        _stop(proc)


def test_a_tor_crash_takes_the_domain_readouts_and_map_down(tmp_path):
    env = _sandbox(tmp_path, "brandb=brandb")
    env["STUB_DIE"] = "7"
    p = subprocess.run(["sh", ENTRY], env=env, capture_output=True, text=True,
                       timeout=60)
    assert p.returncode == 7
    assert os.listdir(tmp_path / "out") == []
    assert not (tmp_path / "map" / "onion-hosts.map").exists()


# ── 7. the compose overlay + Makefile ─────────────────────────────────────────────
def _entry_default(var):
    m = re.search(r'^%s="\$\{[A-Z_]+:-([^}]*)\}' % var, open(ENTRY).read(), re.M)
    return m.group(1) if m else ""


def test_the_base_compose_file_carries_nothing_of_this():
    # Every stack with no Tor domain runs compose.local.yaml alone, so nothing of the
    # per-domain wiring may live there: not the variable, not the map, not a volume.
    text = open(COMPOSE).read()
    for needle in ("TOR_ONION_DOMAINS", "APP_TENANCY_HOSTS_FILE", "tor-tenancy-map",
                   "tor-onion-domain-keys", "hugmesh-onion.d"):
        assert needle not in text, needle


def test_the_overlay_carries_the_domains_the_keys_and_the_map():
    base = yaml.safe_load(open(COMPOSE))
    over = yaml.safe_load(open(OVERLAY))
    assert over["name"] == base["name"]                       # the SAME project
    # it only ADDS to the two services it names; it declares no service of its own
    assert sorted(over["services"]) == ["hugmesh-fe-gateway", "hugmesh-tor"]
    assert set(over["services"]) <= set(base["services"])
    tor, fe = over["services"]["hugmesh-tor"], over["services"]["hugmesh-fe-gateway"]
    vols = over["volumes"]
    assert tor["environment"] == {"TOR_ONION_DOMAINS": "${TOR_ONION_DOMAINS:-}"}
    data_dir, map_dir = _entry_default("DATA_DIR"), _entry_default("MAP_DIR")
    assert data_dir == "/var/lib/tor" and map_dir == "/tenancy"
    mounts = {v.split(":")[1]: v.split(":")[0] for v in tor["volumes"]}
    # each domain key persists in its OWN named volume, beside the primary's
    base_mounts = {v.split(":")[1]: v.split(":")[0]
                   for v in base["services"]["hugmesh-tor"]["volumes"]}
    dk = mounts.get(data_dir + "/hugmesh-onion.d")
    assert dk and dk in vols and dk != base_mounts.get(data_dir + "/hugmesh-onion")
    mv = mounts.get(map_dir)
    assert mv and mv in vols
    # the gateway reads the file hugmesh-tor writes: the SAME volume, read-only, and
    # a LITERAL path (an exported variable must not be able to point it elsewhere)
    assert fe["volumes"] == [f"{mv}:{map_dir}:ro"]
    assert fe["environment"] == {"APP_TENANCY_HOSTS_FILE": map_dir + "/onion-hosts.map"}
    # an EMPTY refresh value stops the gateway context (#39) — never set anywhere
    for path in (COMPOSE, OVERLAY):
        assert "APP_TENANCY_HOSTS_FILE_REFRESH_MS" not in open(path).read(), path
    # the Studio names the same file the Makefile loads
    from hugmesh_studio.core import local_stack_node as lsn
    assert os.path.join(GENERATOR_DIR, lsn._TOR_DOMAINS_COMPOSE_FILE) == OVERLAY
    assert _make_var("STACK_TOR_DOMAINS_COMPOSE") == lsn._TOR_DOMAINS_COMPOSE_FILE


_KNOBS = ("TOR", "BRAND_B", "TOR_ONION_DOMAINS", "ANUBIS", "TOR_ONION_UPSTREAM",
          "APP_TENANCY_HOSTS_FILE", "MAKEFLAGS", "MFLAGS")


def _make_var(name, *args):
    """The expansion of one Makefile variable (no recipe runs)."""
    env = {k: v for k, v in os.environ.items() if k not in _KNOBS}
    p = subprocess.run(["make", "-s", "--no-print-directory", "-C", GENERATOR_DIR,
                        *args, "-E", f"__pin: ; @echo \"$({name})\"", "__pin"],
                       env=env, capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, p.stderr
    return p.stdout.rstrip("\n")


def _make_env(*args):
    return _make_var("STACK_ENV", *args)


def test_make_passes_the_domains_and_the_overlay_only_for_a_tor_domain():
    flag = " -f tests/stack/compose.tor-domains.yaml"
    # no Tor domain — TOR=1 alone included — adds NOTHING: not the variable, not the
    # overlay. The stack env is the one from before this existed.
    for args in ((), ("TOR=1",), ("BRAND_B=1",), ("TOR=1", "ANUBIS=1"),
                 ("TOR_ONION_DOMAINS=acme-example=default",)):
        env = _make_env(*args)
        assert "TOR_ONION_DOMAINS" not in env, args
        assert "APP_TENANCY_HOSTS_FILE" not in env, args
        assert _make_var("STACK_TOR_DOMAINS_FLAGS", *args) == "", args
    both = _make_env("TOR=1", "BRAND_B=1")
    # brand B's onion maps to the SAME tenant key its HTTPS door does
    m = re.search(r"APP_TENANCY_HOSTS='brandb\.localtest\.me=(\w+)'", both)
    assert m, both
    assert f"TOR_ONION_DOMAINS='brandb={m.group(1)}'" in both
    assert _make_var("STACK_TOR_DOMAINS_FLAGS", "TOR=1", "BRAND_B=1") == flag
    caller = _make_env("TOR=1", "TOR_ONION_DOMAINS=acme-example=default")
    assert "TOR_ONION_DOMAINS='acme-example=default'" in caller
    assert _make_var("STACK_TOR_DOMAINS_FLAGS", "TOR=1",
                     "TOR_ONION_DOMAINS=acme-example=default") == flag
    # the gateway's map path is the overlay's literal, never an env var make passes
    assert "APP_TENANCY_HOSTS_FILE" not in both and "APP_TENANCY_HOSTS_FILE" not in caller


def test_the_up_loads_the_overlay_and_the_teardowns_drop_its_volumes():
    mk = open(os.path.join(GENERATOR_DIR, "Makefile")).read()
    lines = mk.splitlines()
    up = [ln for ln in lines if ln.startswith("\t") and ln.rstrip().endswith(" up -d")]
    assert len(up) == 1
    # joined to the tor profile with no space, so an empty value adds no byte at all
    assert "$(STACK_TOR_PROFILE)$(STACK_TOR_DOMAINS_FLAGS) " in up[0]
    # `down -v` removes only the volumes of the files it loads: stack-down and
    # stack-clean load the overlay ALWAYS, so a per-domain key never outlives a
    # stack-down (the #581 rule the mesh's own onion already follows)
    for target in ("stack-down", "stack-clean"):
        block = mk.split(f"\n{target}:", 1)[1].split("\n\n", 1)[0]
        down = [ln for ln in block.splitlines() if " down -v" in ln and "COMPOSE_CMD" in ln]
        assert len(down) == 1, target
        assert " -f $(STACK_TOR_DOMAINS_COMPOSE) " in down[0], target
    # stack-halt keeps every volume, so it has nothing of the overlay's to drop
    halt = mk.split("\nstack-halt:", 1)[1].split("\n\n", 1)[0]
    assert "STACK_TOR_DOMAINS_COMPOSE" not in halt
