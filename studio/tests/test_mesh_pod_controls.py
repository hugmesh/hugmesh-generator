"""Pod controls per domain (2026-10-21): every row of the running-mesh monitor says
which domain it serves, a domain's own rows get Start / Stop / Restart / Logs, and
every onion the mesh publishes gets its own Open / Copy.

THE FIXTURES ARE RECORDED, NOT TYPED (tests/fixtures/mesh_monitor/podctl-*):

* ``podctl-compose-ps.json`` / ``podctl-compose-ps-after.json`` / ``podctl-docker-ps.jsonl``
  — ``docker compose ps --all --format json`` and ``docker ps -a --format '{{json .}}'``
  (Docker Compose v5.1.4) of a THROWAWAY compose project built from the overlay
  ``own_casdoor.compose_overlay(["acme.example"])`` really renders (image swapped to
  the locally present ``casbin/casdoor:3.80.0``) plus two unlabelled services named
  like the shared ones. ``-after`` is the same project after a real ``docker start``
  of the domain's two containers (the Casdoor died waiting for its database, which is
  why Start now orders by compose's own depends_on label). Recorded 2026-10-21; the
  project name and the scratch path were replaced with ``hugmesh-local`` and
  ``/fixture/podfix`` — nothing else was edited.
* ``podctl-kind-objects.json`` — ``kubectl get pods,services,endpoints,ingresses,
  ingressclasses -A -o json`` from the live ``hugmesh-local`` kind cluster, trimmed to
  one pod per owner kind (StatefulSet, ReplicaSet, Node, DaemonSet, Job), plus ONE
  per-domain pod: the argocd-server pod's live status shape carrying the labels the
  casdoor-domains ApplicationSet renders after this change (``kubectl kustomize`` of
  its patch: ``app: casdoor-domain`` + ``hugmesh.net/domain: acme-example``). The
  live cluster runs no per-domain Casdoor, so that one pod is assembled, and says so.
"""
from __future__ import annotations

import json
import os
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import mesh_controls as mc
from hugmesh_studio.core import mesh_monitor as mm
from hugmesh_studio.core import own_casdoor

pytestmark = pytest.mark.real_mesh_monitor

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
FIX = os.path.join(STUDIO_ROOT, "tests", "fixtures", "mesh_monitor")
STACK_COMPOSE = os.path.join(GENERATOR_DIR, "tests", "stack", "compose.local.yaml")


def _read(name: str) -> str:
    with open(os.path.join(FIX, name), encoding="utf-8") as fh:
        return fh.read()


class _Node:
    """A LocalStackNode stand-in: scripted reads, no docker."""
    public_https_port = 8488
    public_host_port = 8088
    web_url = "https://localhost:8488"

    def __init__(self, text: str, *, compose_file: str = STACK_COMPOSE, onion="",
                 onions=None, tor_domains=()):
        self.compose_file = compose_file
        self._text = text
        self._onion = onion
        self._onions = dict(onions or {})
        self.tor_domains = tuple(tor_domains)

    def status(self):
        return SimpleNamespace(running=True, detail="")

    def onion_url(self):
        return self._onion

    def onion_urls(self):
        return dict(self._onions)

    def _probe(self, cmd, timeout=15):
        return 0, self._text


def _compose(monkeypatch, text, **kw):
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/" + t)
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    hints = kw.pop("hints", None)
    onions = kw.pop("onions_out", None)
    node = _Node(text, **kw)
    lane, units, notes, errors = mm._compose_units(
        node, GENERATOR_DIR, [], {}, mm._Budget(25), hints=hints, onions_out=onions)
    assert lane.running is True and not errors
    return {u.owner: u for u in units}, units


# ── the compose lane: the domain comes from the container's own label ─────────────

def test_recorded_compose_ps_labels_the_domain_rows_and_shares_the_rest(monkeypatch):
    by, _units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    for svc in ("casdoor-acme-example", "casdoor-acme-example-db"):
        u = by[svc]
        assert u.domain == "acme.example", (svc, u.domain, u.domain_why)
        assert u.domain_text == "acme.example"
        assert "hugmesh.net/domain=acme.example" in u.domain_why
        assert u.control.kind == "container"
        assert u.control.name == f"hugmesh-local-{svc}-1"
        assert "domain: acme.example" in u.detail
    for svc in ("casdoor", "hugmesh-tor"):
        assert by[svc].domain == "" and by[svc].shared_by == ()
        assert by[svc].domain_text == mm.ALL_DOMAINS
    # compose's own depends_on label is carried, so Start can order by it
    assert by["casdoor-acme-example"].control.depends_on == ("casdoor-acme-example-db",)


def test_the_docker_ps_fallback_reads_the_same_label(monkeypatch):
    rows = mm._parse_docker_ps(_read("podctl-docker-ps.jsonl"))
    by = {r["Service"]: r for r in rows}
    assert by["casdoor-acme-example"]["Labels"][mm.DOMAIN_LABEL] == "acme.example"
    # the multi-valued compose label survives the comma split
    assert mm._depends_on(mm._row_labels(by["casdoor-acme-example"])) == \
        ("casdoor-acme-example-db",)
    assert mm.DOMAIN_LABEL not in by["casdoor"]["Labels"]


def test_a_multi_valued_label_is_not_cut_at_its_commas():
    labels = mm._row_labels({"Labels": "a=1,com.docker.compose.depends_on=db:service_"
                                       "healthy:false,cache:service_started:false,"
                                       "hugmesh.net/domain=shop.example"})
    assert labels["hugmesh.net/domain"] == "shop.example"
    assert mm._depends_on(labels) == ("db", "cache")


def test_snapshot_lists_only_domains_some_row_serves_alone(monkeypatch):
    _by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    snap = mm.MonitorSnapshot("t", mm.LaneState(True), mm.LaneState(False), tuple(units))
    assert snap.domains() == ("acme.example",)


# ── the per-domain verbs ─────────────────────────────────────────────────────────

def test_start_runs_the_database_first_and_stop_runs_it_last(monkeypatch):
    _by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    start = mc.domain_plan(units, "acme.example", "start")
    assert [u.owner for u in start.targets] == ["casdoor-acme-example-db",
                                                "casdoor-acme-example"]
    # shared rows are never in a domain's plan, not even as "skipped"
    assert all(u.domain == "acme.example" for u in start.targets)
    assert not start.skipped
    _by2, after = _compose(monkeypatch, _read("podctl-compose-ps-after.json"))
    stop = mc.domain_plan(after, "acme.example", "stop")
    # both exited in the recording: nothing to stop, and each says why
    assert stop.targets == ()
    assert {why for _u, why in stop.skipped} == {"already stopped"}
    running = [mm.MeshUnit(**{**u.__dict__, "state": "ok", "phase": "running"})
               for u in after]
    stop = mc.domain_plan(running, "acme.example", "stop")
    assert [u.owner for u in stop.targets] == ["casdoor-acme-example",
                                               "casdoor-acme-example-db"]


def test_container_verbs_are_docker_by_container_name(monkeypatch):
    by, _units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    u = by["casdoor-acme-example-db"]
    name = "hugmesh-local-casdoor-acme-example-db-1"
    assert mc.control_argv(u, "start") == (["docker", "start", name], "")
    assert mc.control_argv(u, "stop") == (["docker", "stop", name], "")
    assert mc.control_argv(u, "restart") == (["docker", "restart", name], "")
    assert mc.control_argv(u, "logs") == (
        ["docker", "logs", "--tail", str(mc.LOG_TAIL), "--timestamps", name], "")
    assert mc.control_argv(u, "delete")[0] == []


def test_run_domain_action_runs_each_target_and_reports_each(monkeypatch):
    _by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    ran = []

    def fake_run(node, argv, timeout):
        ran.append(argv)
        if argv[-1].endswith("acme-example-1"):
            return 1, "Error response from daemon: boom"
        return 0, "ok\n"

    monkeypatch.setattr(mc, "_run", fake_run)
    res = mc.run_domain_action(GENERATOR_DIR, None, units, "acme.example", "start")
    assert [a[-1] for a in ran] == ["hugmesh-local-casdoor-acme-example-db-1",
                                    "hugmesh-local-casdoor-acme-example-1"]
    assert res.ok is False and res.domain == "acme.example" and res.verb == "start"
    assert "hugmesh-local-casdoor-acme-example-db-1: done" in res.text
    assert "failed (exit 1) — Error response from daemon: boom" in res.text
    # no shared container was ever touched
    assert "hugmesh-local-casdoor-1" not in [a[-1] for a in ran]
    assert all("acme-example" in a[-1] for a in ran)


def test_logs_are_gathered_per_container_with_both_streams(monkeypatch):
    _by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    monkeypatch.setattr(mc, "_run", lambda n, argv, t: (0, f"line from {argv[-1]}\n"))
    res = mc.run_domain_action(GENERATOR_DIR, None, units, "acme.example", "logs")
    assert res.ok
    assert "── hugmesh-local-casdoor-acme-example-1 (compose) ──" in res.logs
    assert "line from hugmesh-local-casdoor-acme-example-db-1" in res.logs


def test_the_runner_keeps_stderr(monkeypatch):
    """`docker logs` replays a container's stderr on stderr: the runner must keep it,
    or a crash's panic never reaches the Logs box (measured live: casdoor's panic is
    on stderr)."""
    rc, out = mc._run(None, ["sh", "-c", "echo out; echo err >&2"], 10)
    assert rc == 0 and "out" in out and "err" in out


def test_nothing_to_do_is_said_not_run(monkeypatch):
    _by, units = _compose(monkeypatch, _read("podctl-compose-ps.json"))
    monkeypatch.setattr(mc, "_run", lambda *a: pytest.fail("ran something"))
    res = mc.run_domain_action(GENERATOR_DIR, None, units, "other.example", "stop")
    assert res.ok is False and res.text.startswith("Nothing run.")


# ── the domain from the Studio's own per-domain choice ───────────────────────────

def test_profile_scan_reads_the_real_compose_files():
    profiles = mm._compose_service_profiles(STACK_COMPOSE)
    assert profiles["tuwunel"] == ("social",)
    assert profiles["mastodon-web"] == ("social",)
    assert profiles["phpbb"] == ("phpbb",)
    assert profiles["akkoma"] == ("akkoma",)
    assert profiles["hugmesh-tor"] == ("tor",)
    assert "hugmesh-fe-gateway" not in profiles         # core: no profile, shared


def _social_rows():
    return json.dumps([
        {"Name": "hugmesh-local-tuwunel-1", "Service": "tuwunel", "State": "running",
         "Status": "Up", "Health": "", "Image": "tuwunel", "Publishers": []},
        {"Name": "hugmesh-local-hugmesh-fe-gateway-1", "Service": "hugmesh-fe-gateway",
         "State": "running", "Status": "Up", "Health": "", "Image": "gw",
         "Publishers": []},
        {"Name": "hugmesh-local-hugmesh-tor-1", "Service": "hugmesh-tor",
         "State": "running", "Status": "Up", "Health": "", "Image": "tor",
         "Publishers": []},
    ])


def test_a_service_only_one_domain_chose_is_that_domains(monkeypatch):
    hints = mm.DomainHints(service_domains={"tuwunel": ("shop.example",)})
    by, _ = _compose(monkeypatch, _social_rows(), hints=hints)
    assert by["tuwunel"].domain == "shop.example"
    assert "only shop.example chose" in by["tuwunel"].domain_why
    assert by["hugmesh-fe-gateway"].domain == ""
    assert by["hugmesh-tor"].domain == ""      # tor is a mesh-plane slug: shared


def test_a_service_two_domains_chose_is_shared_by_them(monkeypatch):
    hints = mm.DomainHints(service_domains={"tuwunel": ("a.example", "b.example")})
    by, _ = _compose(monkeypatch, _social_rows(), hints=hints)
    assert by["tuwunel"].domain == ""
    assert by["tuwunel"].shared_by == ("a.example", "b.example")
    assert by["tuwunel"].domain_text == "Shared: a.example, b.example"


def test_no_hints_means_labels_only(monkeypatch):
    by, _ = _compose(monkeypatch, _social_rows())
    assert by["tuwunel"].domain == "" and by["tuwunel"].domain_text == mm.ALL_DOMAINS


def test_domain_hints_come_from_the_recorded_rows():
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    cfg = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example", services=("tor",),
        domains=({"name": "shop.example", "optional_services": ["tuwunel", "phpbb"]},
                 {"name": "team.example", "optional_services": ["phpbb"]}))
    h = mm.domain_hints(cfg)
    assert h.service_domains["tuwunel"] == ("shop.example",)
    assert h.service_domains["phpbb"] == ("shop.example", "team.example")
    assert h.own_domain == "mesh.example"
    assert h.names["shop-example"] == "shop.example"
    # a domain slug ALSO chosen mesh-wide runs for every domain: no entry
    cfg2 = LocalMeshBootstrapConfig(services=("tuwunel",),
                                    domains=({"name": "shop.example",
                                              "optional_services": ["tuwunel"]},))
    assert "tuwunel" not in mm.domain_hints(cfg2).service_domains
    # a config it cannot read gives empty hints, never an exception
    assert mm.domain_hints(None).service_domains == {}


# ── onions: one row and one door per domain ──────────────────────────────────────

ONION_A = "https://" + "a" * 56 + ".onion/"
ONION_B = "https://" + "b" * 56 + ".onion/"
ONION_P = "https://" + "p" * 56 + ".onion/"


def test_every_onion_is_a_door_and_its_row_names_its_domain(monkeypatch):
    onions: list = []
    by_rows = json.dumps([{"Name": "hugmesh-local-hugmesh-tor-1",
                           "Service": "hugmesh-tor", "State": "running", "Status": "Up",
                           "Health": "", "Image": "tor", "Publishers": []}])
    _by, units = _compose(
        monkeypatch, by_rows, onion=ONION_P,
        onions={"shop-example": ONION_A, "team-example": ONION_B},
        tor_domains=(("shop.example", "shop-example", "default"),
                     ("team.example", "team-example", "team-example")),
        hints=mm.DomainHints(own_domain="mesh.example"), onions_out=onions)
    assert [(o.domain, o.login, o.primary) for o in onions] == [
        ("mesh.example", ONION_P + "login", True),
        ("shop.example", ONION_A + "login", False),
        ("team.example", ONION_B + "login", False)]
    rows = {u.domain: u for u in units if u.domain}
    assert set(rows) == {"shop.example", "team.example"}
    shop = rows["shop.example"]
    assert "shop-example" in shop.domain_why
    # one tor carries every onion: a domain's buttons must not stop it
    for verb in ("start", "stop", "restart"):
        assert "SAME hugmesh-tor container" in shop.control.refusal(verb)
    assert shop.control.allows("logs")
    tor = [u for u in units if u.owner == "hugmesh-tor" and not u.domain][0]
    assert tor.domain_text == mm.ALL_DOMAINS
    assert not tor.control.allows("stop")       # domain onions ride on it
    plan = mc.domain_plan(units, "shop.example", "stop")
    assert plan.targets == () and plan.skipped


def test_tor_browser_argv(monkeypatch):
    found = {"torbrowser-launcher": "/usr/bin/torbrowser-launcher"}
    assert mc.tor_browser_argv(ONION_A + "login", which=found.get) == \
        ["/usr/bin/torbrowser-launcher", ONION_A + "login"]
    assert mc.tor_browser_argv(ONION_A, which=lambda c: None) == []
    # never a way to hand an arbitrary URL to a program
    assert mc.tor_browser_argv("https://example.com/", which=found.get) == []
    assert mc.tor_browser_argv("file:///etc/passwd.onion", which=found.get) == []
    assert "torbrowser-launcher" in mc.tor_browser_missing_reason()


# ── the kind lane: the pod's own label ───────────────────────────────────────────

def _kind_units(hints=None):
    objects = json.loads(_read("podctl-kind-objects.json"))
    units, _notes = mm._join(objects, {}, [], {}, "hugmesh-local", hints=hints)
    return {u.name.rsplit("-", 2)[0] if u.name.count("-") > 2 else u.name: u
            for u in units}, units


def test_recorded_kind_pods_take_their_domain_from_the_label():
    _by, units = _kind_units(mm.DomainHints(names={"acme-example": "acme.example"}))
    dom = [u for u in units if u.domain]
    assert [u.name for u in dom] == ["casdoor-domain-7c9d6b5f4-q8x2m"]
    assert dom[0].domain == "acme.example"
    assert "pod label hugmesh.net/domain=acme-example" in dom[0].domain_why
    for u in units:
        if u is not dom[0]:
            assert u.domain_text == mm.ALL_DOMAINS, u.name
    # without the config's name map the slug itself is the label
    _b, raw = _kind_units()
    assert [u.domain for u in raw if u.domain] == ["acme-example"]


def test_kind_controls_refuse_stop_and_start_and_restart_only_what_comes_back(
        monkeypatch):
    monkeypatch.setattr(mc.devops_tools, "which", lambda t, d=None: "/x/kubectl")
    _by, units = _kind_units()
    by = {u.name: u for u in units}
    pod = by["casdoor-domain-7c9d6b5f4-q8x2m"]
    for verb in ("start", "stop"):
        assert mc.control_argv(pod, verb, generator_dir=GENERATOR_DIR) == \
            ([], mm.KIND_STOP_REFUSAL)
    argv, why = mc.control_argv(pod, "restart", generator_dir=GENERATOR_DIR)
    assert why == "" and argv == ["/x/kubectl", "--context", "kind-hugmesh-local",
                                  "delete", "pod", "-n", "acme-pki", pod.name,
                                  "--wait=false"]
    argv, why = mc.control_argv(pod, "logs", generator_dir=GENERATOR_DIR)
    assert why == "" and argv[3:7] == ["logs", "-n", "acme-pki", pod.name]
    etcd = by["etcd-hugmesh-local-control-plane"]
    assert "static pod" in etcd.control.refusal("restart")
    job = [u for u in units if u.name.startswith("kyverno-cleanup")][0]
    assert "Job" in job.control.refusal("restart")
    plan = mc.domain_plan(units, "acme-example", "restart")
    assert [u.name for u in plan.targets] == [pod.name]


# ── the label is really written ──────────────────────────────────────────────────

def test_the_own_casdoor_overlay_labels_both_services_with_the_domain():
    yaml = pytest.importorskip("yaml")
    doc = yaml.safe_load(own_casdoor.compose_overlay(["acme.example", "shop.example"]))
    got = {name: (svc.get("labels") or {}).get(mm.DOMAIN_LABEL)
           for name, svc in doc["services"].items()}
    assert got == {"casdoor-acme-example-db": "acme.example",
                   "casdoor-acme-example": "acme.example",
                   "casdoor-shop-example-db": "shop.example",
                   "casdoor-shop-example": "shop.example"}


def test_the_casdoor_domains_appset_labels_both_pod_templates():
    yaml = pytest.importorskip("yaml")
    path = os.path.join(GENERATOR_DIR, "specs", "cluster", "apps",
                        "05b-casdoor-domains.yaml")
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    patches = doc["spec"]["template"]["spec"]["source"]["kustomize"]["patches"]
    labelled = set()
    for p in patches:
        for op in yaml.safe_load(p["patch"]) or []:
            if op.get("path") == "/spec/template/metadata/labels/hugmesh.net~1domain":
                assert op["op"] == "add" and op["value"] == "{{ .slug }}"
                labelled.add(p["target"]["name"])
    assert labelled == {"casdoor-domain", "casdoor-domain-pg"}


def test_core_modules_stay_qt_free():
    import ast
    for mod in (mc, mm):
        tree = ast.parse(open(mod.__file__, encoding="utf-8").read())
        names = {n.module or "" for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        names |= {a.name for n in ast.walk(tree) if isinstance(n, ast.Import)
                  for a in n.names}
        assert not any("Qt" in n or "PySide" in n for n in names), mod.__name__
