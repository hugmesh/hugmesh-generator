"""Which domain a running row serves — the two points round 1 left open (2026-10-21).

1. A kind pod carries its domain's SLUG (``hugmesh.net/domain=acme-example``). On the
   qemu and mesh-emulation pages, which pass no Studio config, it used to keep that
   slug while the compose rows read ``acme.example`` — one domain, two entries in the
   domain picker. ``snapshot()`` now names the slug from what the same read saw (and a
   pod's ``hugmesh.net/domain-name`` annotation names it outright).
2. The social compose profile starts tuwunel AND the whole Mastodon tier. Only
   tuwunel (Matrix) is a per-domain choice, so only tuwunel is that domain's; the
   Mastodon containers are shared, and a domain's Stop never stops them.

Rows come from the RECORDED fixtures test_mesh_pod_controls.py describes.
"""
from __future__ import annotations

import copy
import json
import os

import pytest

from hugmesh_studio.core import mesh_controls as mc
from hugmesh_studio.core import mesh_monitor as mm

from test_mesh_pod_controls import (GENERATOR_DIR, STACK_COMPOSE, _compose, _read,
                                    _Node)

pytestmark = pytest.mark.real_mesh_monitor


# ── 1. the kind pod's slug becomes the domain's name ─────────────────────────────

def _kind(objects=None, hints=None):
    objects = objects or json.loads(_read("podctl-kind-objects.json"))
    units, _notes = mm._join(objects, {}, [], {}, "hugmesh-local", hints=hints)
    return units


def test_snapshot_names_a_kind_slug_from_the_compose_rows_without_any_config(
        monkeypatch):
    """The emulation pages' read: hints=None. The compose rows name acme.example, so
    the kind pod labelled acme-example must read acme.example too, and the picker
    must list the domain ONCE."""
    _by, cunits = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    kunits = _kind()
    assert "acme-example" in {u.domain for u in kunits}       # the raw label
    monkeypatch.setattr(mm, "_catalog_and_doors",
                        lambda g, e: ([], {}, False, (mm.KIND_HTTPS_PORT_DEFAULT,), []))
    monkeypatch.setattr(mm, "_kind_units", lambda *a, **k: (
        mm.LaneState(True, "cluster hugmesh-local"), list(kunits), [], []))
    monkeypatch.setattr(mm, "_compose_units", lambda *a, **k: (
        mm.LaneState(True, "compose up"), list(cunits), [], []))
    snap = mm.snapshot(GENERATOR_DIR, _Node("[]"), hints=None)
    pod = next(u for u in snap.units if u.name == "casdoor-domain-7c9d6b5f4-q8x2m")
    assert pod.domain == "acme.example"
    assert pod.domain_text == "acme.example"
    assert "pod label hugmesh.net/domain=acme-example" in pod.domain_why
    assert "named by the compose row" in pod.domain_why
    assert "domain name: acme.example (slug acme-example" in pod.detail
    assert snap.domains() == ("acme.example",)
    # and the domain's buttons now reach the pod and the two containers together
    plan = mc.domain_plan(snap.units, "acme.example", "logs")
    assert {u.name for u in plan.targets} == {
        "casdoor-domain-7c9d6b5f4-q8x2m",
        "hugmesh-local-casdoor-acme-example-1",
        "hugmesh-local-casdoor-acme-example-db-1"}
    # a shared kind pod is never renamed into a domain
    etcd = next(u for u in snap.units if u.name.startswith("etcd-"))
    assert etcd.domain == "" and etcd.domain_text == mm.ALL_DOMAINS


def test_a_slug_nothing_names_stays_the_slug():
    """No compose row, no config, no annotation: the slug is all there is, and it is
    shown rather than guessed at."""
    units = mm._name_kind_slugs(_kind(), None)
    assert [u.domain for u in units if u.domain] == ["acme-example"]


def test_the_config_names_it_when_no_compose_row_does():
    units = mm._name_kind_slugs(
        _kind(), mm.DomainHints(names={"acme-example": "acme.example"}))
    assert [u.domain for u in units if u.domain] == ["acme.example"]


def test_the_pods_own_annotation_names_it_with_no_other_source():
    objects = json.loads(_read("podctl-kind-objects.json"))
    objects = copy.deepcopy(objects)
    for it in objects["items"]:
        if it["metadata"]["name"] == "casdoor-domain-7c9d6b5f4-q8x2m":
            it["metadata"].setdefault("annotations", {})[
                mm.DOMAIN_NAME_ANNOTATION] = "acme.example"
    pod = next(u for u in _kind(objects) if u.domain)
    assert pod.domain == "acme.example"
    assert "hugmesh.net/domain-name annotation" in pod.domain_why


def test_the_appset_writes_the_name_annotation_on_both_pod_templates():
    yaml = pytest.importorskip("yaml")
    path = os.path.join(GENERATOR_DIR, "specs", "cluster", "apps",
                        "05b-casdoor-domains.yaml")
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    patches = doc["spec"]["template"]["spec"]["source"]["kustomize"]["patches"]
    annotated = set()
    for p in patches:
        for op in yaml.safe_load(p["patch"]) or []:
            if op.get("path") == "/spec/template/metadata/annotations":
                assert op["op"] == "add"
                assert op["value"] == {mm.DOMAIN_NAME_ANNOTATION: "{{ .clusterDomain }}"}
                annotated.add(p["target"]["name"])
    assert annotated == {"casdoor-domain", "casdoor-domain-pg"}
    # that add CREATES the annotations map: a base pod template that gained one would
    # have it silently replaced, so the base must carry none
    base = os.path.join(GENERATOR_DIR, "specs", "cluster", "manifests", "casdoor-domain")
    seen = set()
    for fn in ("deployment.yaml", "pg.yaml"):
        with open(os.path.join(base, fn), encoding="utf-8") as fh:
            for d in yaml.safe_load_all(fh):
                if d and d.get("kind") == "Deployment":
                    seen.add(d["metadata"]["name"])
                    assert "annotations" not in d["spec"]["template"]["metadata"], fn
    assert seen == {"casdoor-domain", "casdoor-domain-pg"}


# ── 2. the social profile: Matrix is the domain's, Mastodon is shared by the domains
#       that turned it on (never one domain's: a domain's Stop never touches it) ───

def _row(service, state="running", status="Up"):
    return {"Name": f"hugmesh-local-{service}-1", "Service": service, "State": state,
            "Status": status, "Health": "", "Image": service, "Publishers": []}


def _social_tier():
    return json.dumps([_row("tuwunel"), _row("mastodon-db"), _row("mastodon-redis"),
                       _row("mastodon-web"), _row("mastodon-sidekiq"),
                       _row("mastodon-streaming"),
                       _row("mastodon-init", "exited", "Exited (0) 1 minute ago"),
                       _row("hugmesh-fe-gateway")])


MASTODON = ("mastodon-db", "mastodon-redis", "mastodon-web", "mastodon-sidekiq",
            "mastodon-streaming", "mastodon-init")


def test_one_domains_matrix_is_its_own_and_the_mastodon_tier_is_shared(monkeypatch):
    hints = mm.DomainHints(service_domains={"tuwunel": ("shop.example",)})
    by, units = _compose(monkeypatch, _social_tier(), hints=hints)
    assert by["tuwunel"].domain == "shop.example"
    for svc in MASTODON:
        u = by[svc]
        # it serves the domain whose tuwunel brought it up (reach_apply's answer),
        # so it is labelled with that domain, not "All domains" — but it is still
        # not that domain's own row: domain stays "" and no domain's verb touches it
        assert u.domain == "" and u.shared_by == ("shop.example",), svc
        assert u.domain_text == "Shared: shop.example", svc
        assert "social profile, which shop.example turned on by choosing tuwunel" \
            in u.domain_why, (svc, u.domain_why)
        assert f"no domain chooses {svc} itself" in u.domain_why
    snap = mm.MonitorSnapshot("t", mm.LaneState(True), mm.LaneState(False), tuple(units))
    assert snap.domains() == ("shop.example",)
    for verb in ("stop", "restart", "logs"):
        plan = mc.domain_plan(units, "shop.example", verb)
        assert [u.owner for u in plan.targets] == ["tuwunel"], verb


def test_two_domains_share_matrix_and_their_mastodon(monkeypatch):
    hints = mm.DomainHints(service_domains={"tuwunel": ("a.example", "b.example")})
    by, _units = _compose(monkeypatch, _social_tier(), hints=hints)
    assert by["tuwunel"].shared_by == ("a.example", "b.example")
    for svc in MASTODON:
        assert by[svc].shared_by == ("a.example", "b.example") \
            and by[svc].domain == "", svc
        assert by[svc].domain_text == "Shared: a.example, b.example", svc
        assert "a.example, b.example turned on" in by[svc].domain_why


@pytest.mark.parametrize("ticked", [("b.example",), ("mesh.example", "b.example"),
                                     ("b.example", "c.example")])
def test_the_mastodon_rows_name_the_domains_reach_apply_says_it_serves(monkeypatch,
                                                                      ticked):
    """One config, two readers: the monitor's Mastodon label and the egress code's
    list of the domains the mesh's one Mastodon serves must name the same domains."""
    from hugmesh_studio.core import reach_apply
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    rows = tuple({"name": n, "optional_services": (["tuwunel"] if n in ticked else [])}
                 for n in ("mesh.example", "b.example", "c.example"))
    cfg = LocalMeshBootstrapConfig(cluster_domain="mesh.example", domains=rows,
                                   services=())
    serves = tuple(n for n, _r, _own in reach_apply.mastodon_domains(cfg))
    assert set(serves) == set(ticked)
    by, _units = _compose(monkeypatch, _social_tier(), hints=mm.domain_hints(cfg))
    for svc in MASTODON:
        assert set(by[svc].shared_by) == set(serves), svc
        assert by[svc].domain == "", svc


def test_matrix_chosen_for_the_whole_mesh_leaves_everything_shared(monkeypatch):
    """tuwunel picked mesh-wide (absent from service_domains) while another domain
    chose phpBB: the social tier is the mesh's, with the plain shared reason."""
    hints = mm.DomainHints(service_domains={"phpbb": ("shop.example",)})
    by, _units = _compose(monkeypatch, _social_tier(), hints=hints)
    for svc in ("tuwunel",) + MASTODON:
        assert by[svc].domain == "" and by[svc].shared_by == (), svc
        assert "no single domain chose it" in by[svc].domain_why, svc


def test_the_owner_table_covers_every_service_the_social_profile_starts():
    """A service added to the social profile in the compose files goes red here until
    someone decides whose it is."""
    profiles = mm._compose_service_profiles(STACK_COMPOSE)
    social = {svc for svc, profs in profiles.items() if "social" in profs}
    assert social, "the profile scan found no social service at all"
    assert social == set(mm._PROFILE_SERVICE_OWNERS["social"]), \
        sorted(social ^ set(mm._PROFILE_SERVICE_OWNERS["social"]))
    owners = {o for o in mm._PROFILE_SERVICE_OWNERS["social"].values() if o}
    assert owners == {"tuwunel"}
    assert owners <= set(mm._profile_slugs()["social"])


# ── the plan never runs one container twice ──────────────────────────────────────

def test_two_rows_of_one_container_are_acted_on_once(monkeypatch):
    """M11: the tor row and its per-domain onion row are the SAME container; a
    domain's Logs must read it once and say why the second row was skipped."""
    by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    casdoor = by["casdoor-acme-example"]
    twin = mm.MeshUnit(**{**casdoor.__dict__, "name": casdoor.name + " · twin"})
    plan = mc.domain_plan([casdoor, twin], "acme.example", "logs")
    assert [u.name for u in plan.targets] == [casdoor.name]
    assert [(u.name, why) for u, why in plan.skipped] == \
        [(twin.name, "the same container as a row above")]
    ran = []
    monkeypatch.setattr(mc, "_run", lambda node, argv, t: ran.append(argv) or (0, "x"))
    res = mc.run_domain_action(GENERATOR_DIR, None, [casdoor, twin], "acme.example",
                               "logs")
    assert res.ok and len(ran) == 1


def test_a_refused_plan_reads_as_one_sentence():
    """Seen live on kind: the Stop tooltip ended "…replaces this domain's pods..",
    the refusal's own full stop plus the summary's."""
    units = mm._name_kind_slugs(
        _kind(), mm.DomainHints(names={"acme-example": "acme.example"}))
    text = mc.domain_plan(units, "acme.example", "stop").summary()
    assert mm.KIND_STOP_REFUSAL.endswith(".")
    assert text.endswith("pods.") and not text.endswith(".."), text
