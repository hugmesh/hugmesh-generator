"""core/mesh_monitor — the honesty rules of the running-mesh monitor, without Qt.

The canned Kubernetes objects below are TRIMMED FROM THE LIVE `hugmesh-local` kind
cluster (2026-09-02, `kubectl get pods,services,endpoints,ingresses,ingressclasses -A
-o json`): the fe-gateway stuck in Init:0/1 behind the hugmesh.net Ingress, casdoor
selected-but-not-ready, casdoor-pg dead on Init:CreateContainerConfigError, and the
control-plane pods that no Service selects. Every subprocess goes through a scripted
``node._probe`` so nothing here shells docker or kubectl.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import mesh_monitor as mm

#: This module exercises the REAL snapshot (tests/conftest.py makes it do nothing for
#: every other suite).
pytestmark = pytest.mark.real_mesh_monitor
from hugmesh_studio.core import view_doors

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


# ── canned cluster ────────────────────────────────────────────────────────────────

def _pod(ns, name, labels, phase, *, owner=("ReplicaSet", None), containers=None,
         inits=None, node="hugmesh-local-control-plane", ip="10.244.0.9"):
    return {
        "kind": "Pod",
        "metadata": {"namespace": ns, "name": name, "labels": labels,
                     "ownerReferences": ([{"kind": owner[0],
                                           "name": owner[1] or name.rsplit("-", 1)[0]}]
                                         if owner else [])},
        "spec": {"nodeName": node,
                 "containers": [{"name": c["name"], "image": c.get("image", "img")}
                                for c in (containers or [])]},
        "status": {"phase": phase, "podIP": ip,
                   "containerStatuses": containers or [],
                   "initContainerStatuses": inits or []},
    }


def _c(name, *, ready=True, waiting=None, terminated=None, restarts=0, image="img"):
    state = {}
    if waiting:
        state["waiting"] = {"reason": waiting}
    elif terminated is not None:
        state["terminated"] = {"exitCode": terminated, "reason": "Completed"
                               if terminated == 0 else "Error"}
    else:
        state["running"] = {"startedAt": "2026-09-02T13:16:33Z"}
    return {"name": name, "ready": ready, "restartCount": restarts, "state": state,
            "image": image}


def _svc(ns, name, selector, ports, type_="ClusterIP"):
    return {"kind": "Service", "metadata": {"namespace": ns, "name": name},
            "spec": {"type": type_, "selector": selector, "ports": ports,
                     "clusterIP": "10.96.0.1"}}


def _ep(ns, name, ready=(), not_ready=(), port=80):
    subset = {"ports": [{"port": port, "protocol": "TCP"}]}
    if ready:
        subset["addresses"] = [{"ip": "10.244.0.1", "targetRef":
                                {"kind": "Pod", "name": p, "namespace": ns}} for p in ready]
    if not_ready:
        subset["notReadyAddresses"] = [{"ip": "10.244.0.2", "targetRef":
                                        {"kind": "Pod", "name": p, "namespace": ns}}
                                       for p in not_ready]
    return {"kind": "Endpoints", "metadata": {"namespace": ns, "name": name},
            "subsets": [subset]}


def _ingress(ns, name, cls, rules):
    return {"kind": "Ingress", "metadata": {"namespace": ns, "name": name},
            "spec": {"ingressClassName": cls,
                     "rules": [{"host": host, "http": {"paths": [
                         {"path": path, "pathType": "Prefix",
                          "backend": {"service": {"name": svc, "port": {"number": port}}}}
                         for path, svc, port in paths]}} for host, paths in rules]}}


FE, PKI, KS = "hugmesh-frontend", "hugmesh-pki", "kube-system"


def cluster_objects():
    items = [
        # fe-gateway: init container still running -> Init:0/1, behind the Ingress
        _pod(FE, "hugmesh-fe-gateway-586956865-mpfpp", {"app": "hugmesh-fe-gateway"},
             "Pending",
             containers=[_c("gateway", ready=False, waiting="PodInitializing")],
             inits=[_c("wait-for-casdoor", ready=False)]),
        _svc(FE, "hugmesh-fe-gateway", {"app": "hugmesh-fe-gateway"},
             [{"name": "http", "port": 8080, "targetPort": 8080}]),
        _ep(FE, "hugmesh-fe-gateway", not_ready=("hugmesh-fe-gateway-586956865-mpfpp",),
            port=8080),
        _ingress(FE, "hugmesh-fe-gateway", "nginx-internal",
                 [("hugmesh.net", [("/", "hugmesh-fe-gateway", 8080)]),
                  ("*.hugmesh.net", [("/", "hugmesh-fe-gateway", 8080)])]),
        # casdoor: phase Running and the kubelet says ready — but its Endpoints
        # list it under notReadyAddresses. Endpoints win.
        _pod(PKI, "casdoor-54777d6b7b-8m8pd", {"app": "casdoor"}, "Running",
             containers=[_c("casdoor", ready=True)]),
        _svc(PKI, "casdoor", {"app": "casdoor"},
             [{"name": "http", "port": 8000, "targetPort": "http"}]),
        _ep(PKI, "casdoor", not_ready=("casdoor-54777d6b7b-8m8pd",), port=8000),
        # casdoor-pg: dead in an INIT container — the reason lives only there
        _pod(PKI, "casdoor-pg-dc9cf6f4c-rrrsd", {"app": "casdoor-pg"}, "Pending",
             containers=[_c("pg", ready=False, waiting="PodInitializing")],
             inits=[_c("init-perms", ready=False, waiting="CreateContainerConfigError")]),
        _svc(PKI, "casdoor-pg", {"app": "casdoor-pg"},
             [{"name": "pg", "port": 5432, "targetPort": 5432}]),
        _ep(PKI, "casdoor-pg", port=5432),
        # harbor-portal: genuinely ready, behind the registry Ingress
        _pod(PKI, "harbor-portal-75dd4987d-bwmsp", {"app": "harbor-portal"}, "Running",
             containers=[_c("portal", ready=True)]),
        _svc(PKI, "harbor-portal", {"app": "harbor-portal"},
             [{"name": "http", "port": 80, "targetPort": 8080}]),
        _ep(PKI, "harbor-portal", ready=("harbor-portal-75dd4987d-bwmsp",)),
        _ingress(PKI, "harbor-ingress", "nginx-internal",
                 [("registry.hugmesh.net", [("/", "harbor-portal", 80)])]),
        # an Ingress naming a class nothing serves
        _pod(PKI, "orphan-ui-1", {"app": "orphan-ui"}, "Running",
             containers=[_c("ui", ready=True)]),
        _svc(PKI, "orphan-ui", {"app": "orphan-ui"},
             [{"name": "http", "port": 80, "targetPort": 80}]),
        _ep(PKI, "orphan-ui", ready=("orphan-ui-1",)),
        _ingress(PKI, "orphan-ingress", "nginx-public",
                 [("orphan.hugmesh.net", [("/", "orphan-ui", 80)])]),
        # a NodePort nobody published to the host
        _pod(PKI, "np-demo-1", {"app": "np-demo"}, "Running",
             containers=[_c("web", ready=True)]),
        _svc(PKI, "np-demo", {"app": "np-demo"},
             [{"name": "http", "port": 80, "targetPort": 80, "nodePort": 30080}],
             type_="NodePort"),
        _ep(PKI, "np-demo", ready=("np-demo-1",)),
        # a CrashLoop with no Service at all, and the control plane
        _pod(KS, "etcd-hugmesh-local-control-plane", {"component": "etcd"}, "Running",
             owner=("Node", "hugmesh-local-control-plane"),
             containers=[_c("etcd", ready=True)]),
        _pod(KS, "kube-apiserver-hugmesh-local-control-plane",
             {"component": "kube-apiserver"}, "Running",
             owner=("Node", "hugmesh-local-control-plane"),
             containers=[_c("kube-apiserver", ready=True)]),
        _pod(PKI, "harbor-jobservice-1", {"app": "harbor-jobservice"}, "Running",
             containers=[_c("job", ready=False, waiting="CrashLoopBackOff", restarts=41)]),
        _pod(PKI, "seed-job-abc12", {"job-name": "seed-job"}, "Succeeded",
             owner=("Job", "seed-job"),
             containers=[_c("seed", ready=False, terminated=0)]),
        # the selector-less API service must match nothing
        _svc("default", "kubernetes", {}, [{"name": "https", "port": 443}]),
        {"kind": "IngressClass", "metadata": {"name": "nginx-internal"},
         "spec": {"controller": "k8s.io/ingress-nginx-internal"}},
    ]
    return {"kind": "List", "items": items}


HOST_PORTS = {443: ("0.0.0.0", 8443), 80: ("0.0.0.0", 8080), 6443: ("127.0.0.1", 46289)}
CLUSTER = "hugmesh-local"


@pytest.fixture
def catalog():
    return view_doors.load(GENERATOR_DIR, {})


def _by_name(units):
    return {u.name: u for u in units}


# ── the join rules ────────────────────────────────────────────────────────────────

def test_kind_units_join_pods_services_endpoints_and_ingress(catalog):
    units, _notes = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    by = _by_name(units)
    fe = by["hugmesh-fe-gateway-586956865-mpfpp"]
    assert fe.cluster_path == "http://hugmesh-fe-gateway.hugmesh-frontend.svc.cluster.local:8080"
    assert "hugmesh.net/ (ingress hugmesh-fe-gateway)" in fe.external
    assert fe.phase == "Init:0/1" and not fe.ready and fe.state == "queued"
    assert fe.owner == "ReplicaSet/hugmesh-fe-gateway-586956865"
    portal = by["harbor-portal-75dd4987d-bwmsp"]
    assert portal.ready and portal.state == "ok" and portal.phase == "Running 1/1"
    assert "registry.hugmesh.net/ (ingress harbor-ingress)" in portal.external
    # the selector-less `kubernetes` Service selected nobody
    assert not any("kubernetes.default" in u.cluster_path for u in units)
    # ALL pods: every canned pod became a row, exactly once
    names = [i["metadata"]["name"] for i in cluster_objects()["items"] if i["kind"] == "Pod"]
    assert sorted(u.name for u in units) == sorted(names)


def test_readiness_comes_from_endpoints_not_phase(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    cas = _by_name(units)["casdoor-54777d6b7b-8m8pd"]
    assert cas.phase == "Running 1/1", "phase alone would have painted it green"
    assert cas.ready is False
    assert "notReadyAddresses" in cas.reason and "casdoor" in cas.reason
    assert cas.state == "running"           # blue: alive but not serving, never green


def test_init_container_waiting_reason_is_surfaced(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    pg = _by_name(units)["casdoor-pg-dc9cf6f4c-rrrsd"]
    assert pg.phase == "Init:CreateContainerConfigError"
    assert pg.state == "failed" and not pg.ready
    # and a plain container failure keeps its own reason
    js = _by_name(units)["harbor-jobservice-1"]
    assert js.phase == "CrashLoopBackOff" and js.state == "failed"
    assert "restarts: 41" in js.detail


def test_succeeded_is_done_never_failed(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    job = _by_name(units)["seed-job-abc12"]
    assert job.phase == "Succeeded" and job.state == "stopped"


def test_clusterip_only_service_has_no_browser_door(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    cas = _by_name(units)["casdoor-54777d6b7b-8m8pd"]
    assert cas.door.url == "" and not cas.door.openable
    assert "kubectl --context kind-hugmesh-local port-forward -n hugmesh-pki svc/casdoor :8000" \
        in cas.door.blocked
    assert "make view" in cas.door.blocked        # it has a k8s+ catalog row (9083)
    pg = _by_name(units)["casdoor-pg-dc9cf6f4c-rrrsd"]
    assert "not an HTTP port" in pg.door.blocked and pg.door.url == ""


def test_ingress_host_maps_to_the_view_catalog_port(catalog):
    live = {"app": "https://127.0.0.1:9080/", "registry": "https://127.0.0.1:9081/",
            "casdoor": "https://127.0.0.1:9083/"}
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, live, CLUSTER)
    by = _by_name(units)
    fe = by["hugmesh-fe-gateway-586956865-mpfpp"]
    assert fe.door.openable and fe.door.url == "https://127.0.0.1:9080/"
    assert fe.door.via == "view"
    assert by["harbor-portal-75dd4987d-bwmsp"].door.url == "https://127.0.0.1:9081/"
    assert by["casdoor-54777d6b7b-8m8pd"].door.url == "https://127.0.0.1:9083/"
    # without a live door the SAME rows are blocked with the HSTS reason
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    fe = _by_name(units)["hugmesh-fe-gateway-586956865-mpfpp"]
    assert fe.door.url == "" and "HSTS" in fe.door.blocked and "make view" in fe.door.blocked


def test_unserved_ingress_class_is_named_not_offered(catalog):
    live = {"app": "https://127.0.0.1:9080/"}
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, live, CLUSTER)
    orphan = _by_name(units)["orphan-ui-1"]
    assert "nginx-public" in orphan.external and "no IngressClass" in orphan.external
    assert orphan.door.url == ""


def test_no_door_url_contains_localhost_8443_or_any_hostname(catalog):
    """THE HSTS GUARD at the core boundary, over EVERY unit, with every door live."""
    live = {d.name: d.url for d in catalog}
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, live, CLUSTER)
    for u in units:
        if not u.door.url:
            continue
        assert mm.unsafe_door_reason(u.door.url) == "", (u.key, u.door.url)
        assert ":8443" not in u.door.url, (u.key, u.door.url)
        assert "hugmesh.net" not in u.door.url, (u.key, u.door.url)
        assert u.door.url.startswith("https://127.0.0.1:"), (u.key, u.door.url)
    # and the gate itself, spelled out
    assert mm.unsafe_door_reason("https://localhost:8443/") == mm.HSTS_REASON
    assert "hostname" in mm.unsafe_door_reason("https://hugmesh.net:8443/")
    assert "hostname" in mm.unsafe_door_reason("http://hugmesh.net/")
    assert mm.unsafe_door_reason("https://127.0.0.1:8443/") == ""
    assert mm.unsafe_door_reason("https://localhost:8488") == ""      # tls-front strips HSTS
    assert mm.unsafe_door_reason("http://127.0.0.1:8088/") == ""
    assert mm.unsafe_door_reason("") != ""
    assert mm.unsafe_door_reason("ftp://127.0.0.1/") != ""


def test_nodeport_without_a_host_binding_is_not_published(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    np_ = _by_name(units)["np-demo-1"]
    assert np_.external == "NodePort 30080 — not published by this kind node"
    assert np_.door.url == "" and "port-forward" in np_.door.blocked
    # published by the node -> a plaintext loopback door
    units, _ = mm._join(cluster_objects(), {**HOST_PORTS, 30080: ("0.0.0.0", 30080)},
                        catalog, {}, CLUSTER)
    np_ = _by_name(units)["np-demo-1"]
    assert np_.external == "0.0.0.0:30080->30080 (NodePort)"
    assert np_.door.url == "http://127.0.0.1:30080/"


def test_pods_with_no_service_still_get_a_row(catalog):
    units, _ = mm._join(cluster_objects(), HOST_PORTS, catalog, {}, CLUSTER)
    by = _by_name(units)
    etcd = by["etcd-hugmesh-local-control-plane"]
    assert etcd.cluster_path == "" and etcd.external == ""
    assert etcd.ready and etcd.state == "ok"
    assert "no Service selects" in etcd.door.blocked
    api = by["kube-apiserver-hugmesh-local-control-plane"]
    assert api.external == "127.0.0.1:46289->6443 (Kubernetes API)"
    assert api.door.url == "" and "not a web page" in api.door.blocked


def test_port_bindings_parse_the_docker_inspect_shape():
    text = ('{"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"8443"}],'
            '"6443/tcp":[{"HostIp":"127.0.0.1","HostPort":"46289"}],'
            '"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}')
    assert mm._parse_port_bindings(text) == HOST_PORTS
    assert mm._parse_port_bindings("null") == {}
    assert mm._parse_port_bindings("garbage") == {}


# ── the compose lane ──────────────────────────────────────────────────────────────

class _Node:
    """A LocalStackNode stand-in whose every subprocess is scripted."""
    compose_file = "/g/tests/stack/compose.local.yaml"
    public_https_port = 8488
    public_host_port = 8088
    web_url = "https://localhost:8488"
    plain_web_url = "http://localhost:8088"

    def __init__(self, running=True, script=None, onion=""):
        self._running = running
        self.script = script or {}
        self.calls: list[list[str]] = []
        self._onion = onion

    def status(self):
        from types import SimpleNamespace
        return SimpleNamespace(running=self._running,
                               detail="41 container(s)" if self._running else "not started")

    def onion_url(self):
        return self._onion

    def _probe(self, cmd, timeout=15):
        self.calls.append(list(cmd))
        for key, answer in self.script.items():
            if key in " ".join(cmd):
                if callable(answer):
                    return answer(cmd)
                return answer
        return 1, f"unscripted: {cmd}"


COMPOSE_ROWS = [
    {"Name": "hugmesh-local-tls-front-1", "Service": "tls-front", "State": "running",
     "Status": "Up 8 minutes", "Health": "", "Image": "nginx", "ExitCode": 0,
     "Publishers": [{"URL": "0.0.0.0", "TargetPort": 8443, "PublishedPort": 8488,
                     "Protocol": "tcp"},
                    {"URL": "::", "TargetPort": 8443, "PublishedPort": 8488,
                     "Protocol": "tcp"}]},
    {"Name": "hugmesh-local-fe-gateway-1", "Service": "hugmesh-fe-gateway",
     "State": "running", "Status": "Up 8 minutes (healthy)", "Health": "healthy",
     "Image": "hugmesh-local-hugmesh-fe-gateway", "ExitCode": 0,
     "Publishers": [{"URL": "0.0.0.0", "TargetPort": 8080, "PublishedPort": 8088,
                     "Protocol": "tcp"}]},
    {"Name": "hugmesh-local-casdoor-1", "Service": "casdoor", "State": "running",
     "Status": "Up", "Health": "", "Image": "casbin/casdoor", "ExitCode": 0,
     "Publishers": [{"URL": "0.0.0.0", "TargetPort": 8000, "PublishedPort": 8000,
                     "Protocol": "tcp"}]},
    {"Name": "hugmesh-local-wiki-bff-db-1", "Service": "wiki-bff-db", "State": "running",
     "Status": "Up (healthy)", "Health": "healthy", "Image": "postgres:16-alpine",
     "ExitCode": 0,
     "Publishers": [{"URL": "", "TargetPort": 5432, "PublishedPort": 0, "Protocol": "tcp"}]},
    {"Name": "hugmesh-local-seed-1", "Service": "seed", "State": "exited",
     "Status": "Exited (3)", "Health": "", "Image": "seed", "ExitCode": 3,
     "Publishers": []},
    {"Name": "hugmesh-local-hugmesh-tor-1", "Service": "hugmesh-tor", "State": "running",
     "Status": "Up", "Health": "", "Image": "tor", "ExitCode": 0, "Publishers": []},
    # TOR=1 also starts the e2e lane's SOCKS5 client (hugmesh-generator#576). Its
    # name contains "tor" too, and a substring match once hung the onion on it.
    {"Name": "hugmesh-local-hugmesh-tor-client-1", "Service": "hugmesh-tor-client",
     "State": "running", "Status": "Up (healthy)", "Health": "healthy", "Image": "tor",
     "ExitCode": 0,
     "Publishers": [{"URL": "127.0.0.1", "TargetPort": 9050, "PublishedPort": 9050,
                     "Protocol": "tcp"}]},
]


def _compose_snapshot(monkeypatch, rows_text, running=True, onion=""):
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    node = _Node(running=running, script={"compose -f": (0, rows_text)}, onion=onion)
    return node, mm._compose_units(node, "/g", view_doors.load(GENERATOR_DIR, {}), {},
                                   mm._Budget(25))


def test_compose_units_report_published_ports(monkeypatch):
    node, (lane, units, notes, errors) = _compose_snapshot(
        monkeypatch, json.dumps(COMPOSE_ROWS), onion="http://abc.onion/")
    assert lane.running is True and not errors
    by = {u.owner: u for u in units}
    tls = by["tls-front"]
    assert tls.external == "0.0.0.0:8488->8443"          # the v6 twin is folded
    assert tls.door.url == "https://localhost:8488" and tls.door.via == "compose"
    fe = by["hugmesh-fe-gateway"]
    assert fe.external == "0.0.0.0:8088->8080" and fe.ready and fe.state == "ok"
    assert fe.door.url == "http://127.0.0.1:8088/"        # 127.0.0.1, never a name
    assert fe.phase == "running (healthy)"
    assert by["casdoor"].door.url == "http://127.0.0.1:8000/"
    db = by["wiki-bff-db"]
    assert db.external == "" and db.door.url == "" and "no published port" in db.door.blocked
    assert db.cluster_path == "wiki-bff-db:5432"
    seed = by["seed"]
    assert seed.state == "failed" and "exit 3" in seed.reason
    tor = by["hugmesh-tor"]
    assert "abc.onion" in tor.external and tor.door.url == ""
    assert ".onion" in tor.door.blocked
    # the SOCKS client is NOT the onion: no address, no Tor Browser hint, its own door
    client = by["hugmesh-tor-client"]
    assert client.external == "127.0.0.1:9050->9050", client.external
    assert "onion" not in client.external and client.door.url == ""
    assert "SOCKS5" in client.door.blocked and "Tor Browser" not in client.door.blocked
    assert [u.owner for u in units if "abc.onion" in u.external] == ["hugmesh-tor"]
    for u in units:
        assert u.lane == "compose" and u.namespace == "hugmesh-local"
        if u.door.url:
            assert mm.unsafe_door_reason(u.door.url) == "", u.door.url
    # the compose file is the one the node names, via _probe
    assert any("-f" in c and node.compose_file in c for c in node.calls)


def test_onion_row_is_matched_exactly_never_by_substring():
    """The onion belongs to the hugmesh-tor service and to nothing else whose name
    merely CONTAINS "tor" (hugmesh-tor-client, a future *monitor*). A row with no
    compose service label is judged by compose's <project>-<service>-<n> name."""
    want = mm._COMPOSE_ONION_SERVICE
    assert mm._is_compose_service("hugmesh-tor", "", want)
    assert not mm._is_compose_service("hugmesh-tor-client", "", want)
    assert not mm._is_compose_service("mesh-monitor", "", want)
    assert mm._is_compose_service("", "hugmesh-local-hugmesh-tor-1", want)
    assert mm._is_compose_service("", "hugmesh-local_hugmesh-tor_2", want)
    assert not mm._is_compose_service("", "hugmesh-local-hugmesh-tor-client-1", want)
    assert not mm._is_compose_service("", "hugmesh-local-monitor-1", want)
    assert mm._is_compose_service("", "hugmesh-local-hugmesh-tor-client-1",
                                  mm._COMPOSE_TOR_CLIENT_SERVICE)


def test_compose_json_array_and_jsonlines_both_parse(monkeypatch):
    lines = "\n".join(json.dumps(r) for r in COMPOSE_ROWS)
    assert [r["Name"] for r in mm._parse_compose_ps(lines)] == \
        [r["Name"] for r in mm._parse_compose_ps(json.dumps(COMPOSE_ROWS))]
    assert mm._parse_compose_ps("") == []
    assert mm._parse_compose_ps("WARN: tag is not set\nnot json") is None
    # a rejected shape falls back to `docker ps` and says so
    docker_ps = json.dumps({
        "Names": "hugmesh-local-fe-1", "Image": "x", "State": "running",
        "Status": "Up", "Ports": "0.0.0.0:8088->8080/tcp, [::]:8088->8080/tcp",
        "Labels": "com.docker.compose.project=hugmesh-local,"
                  "com.docker.compose.service=hugmesh-fe-gateway"})
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    node = _Node(script={"compose -f": (0, "level=warning msg=tag unset"),
                         "docker ps": (0, docker_ps)})
    lane, units, notes, errors = mm._compose_units(node, "/g", [], {}, mm._Budget(25))
    assert lane.running and len(units) == 1
    assert units[0].owner == "hugmesh-fe-gateway"
    assert units[0].external == "0.0.0.0:8088->8080"
    assert any("docker ps" in n for n in notes)


def test_compose_down_is_false_and_docker_absent_is_none(monkeypatch):
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    lane, units, _, _ = mm._compose_units(_Node(running=False), "/g", [], {},
                                          mm._Budget(25))
    assert lane.running is False and units == []
    monkeypatch.setattr(mm.shutil, "which", lambda t: None)
    lane, units, _, _ = mm._compose_units(_Node(), "/g", [], {}, mm._Budget(25))
    assert lane.running is None and "docker" in lane.error


# ── the snapshot: tri-state, never raises ─────────────────────────────────────────

def _kind_node(objects_text, clusters="hugmesh-local", bindings=None):
    return _Node(running=False, script={
        "get clusters": (0, clusters),
        "get pods,services": (0, objects_text),
        "docker inspect": (0, bindings if bindings is not None else json.dumps(
            {"443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8443"}],
             "6443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "46289"}]})),
    })


@pytest.fixture
def tools(monkeypatch, tmp_path):
    """kind + kubectl 'installed', docker present, no view session, real catalog."""
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, gd: f"/fake/{tool}")
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.delenv("KIND_CLUSTER_NAME", raising=False)
    return {"HUGMESH_VIEW_STATE": str(tmp_path / "view-state")}


def test_snapshot_kind_running_alone_counts_as_running(tools):
    node = _kind_node(json.dumps(cluster_objects()))
    snap = mm.snapshot(GENERATOR_DIR, node, env=tools)
    assert snap.compose.running is False
    assert snap.kind.running is True and "hugmesh-local" in snap.kind.detail
    assert snap.any_running is True
    assert snap.ready_counts[1] == len([i for i in cluster_objects()["items"]
                                        if i["kind"] == "Pod"])
    assert snap.errors == ()
    # the kubectl call named the kind context explicitly — never the ambient one
    assert any("--context" in c and "kind-hugmesh-local" in c for c in node.calls)
    assert snap.view_doors == ()


def test_missing_kubectl_reports_none_not_false(tools, monkeypatch):
    monkeypatch.setattr(mm.devops_tools, "which",
                        lambda tool, gd: "/fake/kind" if tool == "kind" else None)
    snap = mm.snapshot(GENERATOR_DIR, _kind_node("{}"), env=tools)
    assert snap.kind.running is None
    assert "kubectl" in snap.kind.error and "Install DevOps prerequisites" in snap.kind.error
    assert any("kubectl" in e for e in snap.errors)
    assert snap.any_running is False and snap.any_unknown


def test_missing_kind_binary_reports_none(tools, monkeypatch):
    monkeypatch.setattr(mm.devops_tools, "which", lambda tool, gd: None)
    snap = mm.snapshot(GENERATOR_DIR, _kind_node("{}"), env=tools)
    assert snap.kind.running is None and "kind" in snap.kind.error


def test_absent_cluster_is_false_with_zero_kubectl_calls(tools):
    node = _kind_node("{}", clusters="some-other-cluster")
    snap = mm.snapshot(GENERATOR_DIR, node, env=tools)
    assert snap.kind.running is False and snap.kind.error == ""
    assert not any("get pods" in " ".join(c) for c in node.calls)


def test_snapshot_never_raises_on_garbage_output(tools):
    # not JSON
    snap = mm.snapshot(GENERATOR_DIR, _kind_node("this is not json"), env=tools)
    assert snap.kind.running is None and "unparseable" in snap.kind.error
    # rc != 0 (a silent API server)
    node = _Node(running=False, script={"get clusters": (0, "hugmesh-local"),
                                        "get pods,services": (1, "timed out")})
    snap = mm.snapshot(GENERATOR_DIR, node, env=tools)
    assert snap.kind.running is None and "did not answer" in snap.kind.error
    # _probe itself blowing up

    class _Boom(_Node):
        def _probe(self, cmd, timeout=15):
            raise RuntimeError("no subprocess for you")

        def status(self):
            raise OSError("docker socket gone")
    snap = mm.snapshot(GENERATOR_DIR, _Boom(), env=tools)
    assert snap.kind.running is None and snap.compose.running is None
    assert snap.any_running is False
    assert len(snap.errors) >= 2
    # and a node with no _probe at all (a test stub) folds the same way
    snap = mm.snapshot(GENERATOR_DIR, object(), env=tools)
    assert snap.kind.running is None and snap.compose.running is None


def test_deadline_leaves_the_slow_lane_unestablished(tools):
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())),
                       env=tools, deadline_s=0)
    assert snap.kind.running is None and "deadline" in snap.kind.error
    assert snap.compose.running is None and "deadline" in snap.compose.error


def test_dead_view_session_blocks_doors_and_is_named(tools, tmp_path, monkeypatch):
    state = tmp_path / "view-state"
    state.mkdir()
    (state / "session.json").write_text(json.dumps(
        {"pid": 1, "marker": "hugmesh-view",
         "doors": [{"name": "app", "port": 9080, "url": "https://127.0.0.1:9080/"}]}))
    monkeypatch.setattr(mm.view_doors, "pid_alive", lambda pid, marker="": False)
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())),
                       env=tools)
    assert snap.view_doors == ()
    assert any("previous view session" in n for n in snap.notes)
    fe = _by_name(snap.units)["hugmesh-fe-gateway-586956865-mpfpp"]
    assert fe.door.url == "" and "previous view session" in fe.door.blocked


def test_missing_catalog_degrades_to_no_door_with_why(tools, tmp_path):
    env = dict(tools, HUGMESH_VIEW_TSV=str(tmp_path / "nope.tsv"))
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())), env=env)
    assert snap.kind.running is True and len(snap.units) > 0     # rows still render
    assert any("no browser doors" in n for n in snap.notes)
    assert all(u.door.url == "" for u in snap.units)


def test_addresses_text_carries_every_row(tools):
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())),
                       env=tools)
    text = mm.addresses_text(snap)
    assert text.count("\n") + 1 == len(snap.units)
    assert "kind/kube-system/kube-apiserver-hugmesh-local-control-plane" in text
    assert "127.0.0.1:46289->6443" in text


def test_snapshot_offers_the_compose_tls_front_through_the_real_catalog(tools):
    """Caught LIVE on 2026-09-02, not by the tests above (which bypass
    _catalog_and_doors): the compose-tls catalog row's upstream is
    https://127.0.0.1:${PUBLIC_HTTPS_PORT:-8488}, and adding ITS port to the pinning
    set made the gate refuse the compose TLS door (https://localhost:8488 — the
    tls-front that STRIPS HSTS) as if it were the kind ingress. Only the kind lanes'
    rows name the pinning port."""
    _cat, _live, _stale, kind_ports, _notes = mm._catalog_and_doors(GENERATOR_DIR, tools)
    assert kind_ports == (8443,), kind_ports
    node = _Node(running=True, script={"get clusters": (0, ""),
                                       "compose -f": (0, json.dumps(COMPOSE_ROWS))})
    snap = mm.snapshot(GENERATOR_DIR, node, env=tools)
    assert snap.kind.running is False and snap.compose.running is True
    by = {u.owner: u for u in snap.units if u.lane == "compose"}
    tls = by["tls-front"]
    assert tls.door.url == "https://localhost:8488", tls.door
    assert tls.door.openable, tls.door.blocked
    assert by["hugmesh-fe-gateway"].door.url == "http://127.0.0.1:8088/"
    # the lane detail does not count the containers twice
    assert snap.compose.detail.count("container") == 1, snap.compose.detail
    # and the kind port is STILL refused under a name
    assert mm.unsafe_door_reason("https://localhost:8443/", kind_ports) == mm.HSTS_REASON


def test_module_is_qt_free():
    probe = (
        "import hugmesh_studio.core.mesh_monitor as m, sys;"
        "assert callable(m.snapshot);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad"
    )
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_compose_lists_every_container_including_exited_ones(monkeypatch):
    """Ask A says ALL pods. Both listings run with --all, so a one-shot init
    container that exited 0 is a 'stopped' row and a service that DIED non-zero a
    'failed' one. Without it neither row existed (live: 43 project containers, 41
    rows, the two `*-init-1` absent) and the title kept reading N/N ready after a
    service died — the exited/dead branch was unreachable."""
    rows = COMPOSE_ROWS + [
        {"Name": "hugmesh-local-cassandra-init-1", "Service": "cassandra-init",
         "State": "exited", "Status": "Exited (0)", "Health": "", "Image": "init",
         "ExitCode": 0, "Publishers": []}]
    node, (lane, units, notes, errors) = _compose_snapshot(monkeypatch, json.dumps(rows))
    ps = [c for c in node.calls if "ps" in c]
    assert ps and all("--all" in c for c in ps), node.calls
    by = {u.owner: u for u in units}
    init = by["cassandra-init"]
    assert init.state == "stopped" and init.ready is False and "exit 0" in init.reason
    assert by["seed"].state == "failed" and "exit 3" in by["seed"].reason
    # the `docker ps` fallback lists all of them too
    monkeypatch.setattr(mm.shutil, "which", lambda t: "/usr/bin/docker")
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    node2 = _Node(script={"compose -f": (0, "not json"), "docker ps": (0, "")})
    mm._compose_units(node2, "/g", [], {}, mm._Budget(25))
    fallback = [c for c in node2.calls if c[:2] == ["docker", "ps"]]
    assert fallback and "--all" in fallback[0], node2.calls


def test_snapshot_carries_the_lane_the_live_view_session_serves(tools, tmp_path,
                                                               monkeypatch):
    """The GUI names WHICH lane a live `make view` session serves (a kind-lane
    session outlives its cluster and holds the ports beside a compose mesh), and it
    must not read the session file on its own thread — the lane rides the
    snapshot with the door names."""
    state = tmp_path / "view-state"
    state.mkdir()
    (state / "session.json").write_text(json.dumps(
        {"pid": 424242, "marker": "hugmesh-view", "lane": "kind",
         "doors": [{"name": "app", "port": 9080, "url": "https://127.0.0.1:9080/"}]}))
    monkeypatch.setattr(mm.view_doors, "live_doors",
                        lambda gd, env=None: {"app": "https://127.0.0.1:9080/"})
    monkeypatch.setattr(mm.view_doors, "stale_session", lambda gd, env=None: False)
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())), env=tools)
    assert snap.view_doors == ("app",) and snap.view_lane == "kind"
    # no live session: no lane is claimed, whatever the file says
    monkeypatch.setattr(mm.view_doors, "live_doors", lambda gd, env=None: {})
    snap = mm.snapshot(GENERATOR_DIR, _kind_node(json.dumps(cluster_objects())), env=tools)
    assert snap.view_doors == () and snap.view_lane == ""
