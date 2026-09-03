"""One read of EVERYTHING the local mesh is running — both lanes, every unit, every
address, and which of them the browser may safely be pointed at.

WHY TWO LANES (invariant I11). The local-mesh page drives two unrelated back-ends
from one screen: "Generate && start" is the docker COMPOSE project ``hugmesh-local``
(containers, no pods), and "Start DevOps lane (Kubernetes)" is the KIND cluster of
the same name (pods, no containers the compose project knows about). The page's
``_mesh_up`` answers ONLY compose (``LocalStackNode.status()`` is ``compose ps -q``),
so a monitor that greyed itself on ``_mesh_up`` would sit empty on a host running
sixty pods and no containers — exactly this host's state when this was written. A
snapshot therefore asks BOTH lanes and ``any_running`` is true when EITHER is.

THE HONESTY RULES (each pinned by a test in tests/test_mesh_monitor.py):

* READINESS COMES FROM ENDPOINTS, NOT PHASE. A pod is ready iff some Endpoints
  subset's ``addresses[].targetRef`` names it; ``notReadyAddresses`` is selected-but-
  not-ready. A Running pod with a failing readiness probe would otherwise render
  green. A pod no Service selects has no Endpoints to consult, so its own container
  readiness is used and the row SAYS so.
* Init-container waiting reasons are read too. ``Init:CreateContainerConfigError``
  lives ONLY in ``initContainerStatuses``; omitting that list renders a dead pod as
  merely "Pending".
* Unknown is never "no" (invariant I5). A lane whose answer could not be established
  — kubectl absent, the API silent, JSON garbage — is ``LaneState(running=None)``
  with the reason, never ``False``.
* "ALL pods" means all of them: a pod behind no Service (etcd, the scheduler, a Job)
  still gets a row, with an empty in-mesh address.
* THE HSTS BAN (invariant I8). ``https://localhost:8443`` and ``https://hugmesh.net:8443``
  emit ``strict-transport-security: max-age=31536000`` on EVERY response under the
  kind ingress's fake certificate; in Chrome that is a non-bypassable interstitial and
  a one-year pin per host, which then force-upgrades the compose plaintext doors.
  ``127.0.0.1`` cannot be pinned. So a browser button is offered ONLY for a LIVE
  ``make view`` door on ``https://127.0.0.1:90xx``, the compose TLS front
  (``node.web_url`` — tls-front strips HSTS itself) and plaintext compose doors on
  ``127.0.0.1``. ``unsafe_door_reason`` is the one gate every Door passes through,
  and the GUI checks it again at its own boundary.

Every subprocess read goes through ``node._probe(cmd, timeout)`` — the same runner the
DevOps preflights use, under ``_build_env()`` so ``kind``/``kubectl`` resolve via the
user-local tools dir. Each is bounded, each failure is folded into text, and nothing
here raises: an exception escaping the GUI's probe thread would leave the table frozen
on a stale snapshot with no way to say so.

The Studio NEVER spawns a ``kubectl port-forward`` of its own: ``scripts/hugmesh-view.py``
owns a session-owner guard and one ``up`` per state dir, and a second forwarder would
fight it. A ClusterIP-only service with no live door gets its address, the exact
``port-forward`` command that would make one, and no button.

Qt-free by construction (``test_module_is_qt_free``).
"""
from __future__ import annotations

import json
import os
import shutil
import time
from dataclasses import dataclass, field
from urllib.parse import urlparse

from . import devops_tools, view_doors
from .local_stack_node import _COMPOSE_PROJECT, _compose_base, _kind_cluster_name

#: Per-call ceilings. ONE ``kubectl get`` round trip for the whole cluster rather than a
#: per-namespace loop: N calls is N timeouts on a wedged API server.
KIND_CLUSTERS_TIMEOUT_S = 10
KUBECTL_GET_TIMEOUT_S = 20
DOCKER_INSPECT_TIMEOUT_S = 10
COMPOSE_PS_TIMEOUT_S = 20
#: The whole snapshot's budget; a lane that would start past it is reported as
#: unestablished rather than run.
DEFAULT_DEADLINE_S = 25

#: The kind node's HTTPS port when nothing overrides it — kind-local.yaml's
#: ``extraPortMappings`` and the view catalog's ``${KIND_HTTPS_PORT:-8443}`` agree. Read
#: from the catalog when it parses; this is only the fallback for the HSTS gate.
KIND_HTTPS_PORT_DEFAULT = 8443

#: Loopback hosts a door may carry. ``localhost`` is admitted ONLY for plaintext and for
#: the compose TLS front (which strips HSTS); the kind port is refused on it below.
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost"})

#: Container waiting/terminated reasons that mean "this unit is broken", as opposed to
#: the transient ones (ContainerCreating, PodInitializing) that mean "not yet".
_FAILURE_REASONS = frozenset({
    "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName",
    "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
    "Error", "OOMKilled", "ContainerCannotRun", "DeadlineExceeded",
})

#: Well-known HTTP(S) ports for the "is this a web page?" question when the port has no
#: telling name. Anything else — 5432, 9042, 9418, 6443 — is an address, never a button.
_HTTP_PORTS = frozenset({80, 443, 3000, 4180, 5000, 8000, 8008, 8080, 8200, 8443, 9090})
_HTTPS_PORTS = frozenset({443, 8443, 8200})
_HTTP_PORT_NAME_HINTS = ("http", "web", "ui", "portal", "console")

HSTS_REASON = ("The kind door emits HSTS under a fake certificate — open it through "
               "`make view` (button below), not directly.")


# ── the shapes ─────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Door:
    """What the Open button gets. ``url`` is EXACTLY what ``openUrl`` receives ("" when
    there is none); ``blocked`` is the reason shown as the dash's tooltip."""
    label: str = ""
    url: str = ""
    via: str = "none"             # "view" | "compose" | "none"
    blocked: str = ""             # "" = openable; else why not

    @property
    def openable(self) -> bool:
        return bool(self.url) and not self.blocked


@dataclass(frozen=True)
class MeshUnit:
    lane: str                     # "compose" | "kind"
    namespace: str
    name: str
    owner: str                    # ReplicaSet/StatefulSet/… name, or the compose service
    phase: str                    # "Running 1/1" | "ImagePullBackOff" | "Init:CreateContainerConfigError"
    ready: bool
    reason: str                   # why not ready, "" when ready
    state: str                    # progress.py _STATUS_GLYPH key: ok|failed|running|queued|stopped
    cluster_path: str = ""        # in-mesh address, "" when no Service selects it
    external: str = ""            # "hugmesh.net/ (ingress)" | "0.0.0.0:8088->8080" | ""
    door: Door = field(default_factory=Door)
    detail: str = ""              # tooltip long form: image, restarts, node, ingress rule

    @property
    def key(self) -> str:
        return f"{self.lane}/{self.namespace}/{self.name}"


@dataclass(frozen=True)
class LaneState:
    running: bool | None          # None = COULD NOT ESTABLISH (I5), never rendered as False
    detail: str = ""
    error: str = ""


@dataclass(frozen=True)
class MonitorSnapshot:
    taken_at: str
    compose: LaneState
    kind: LaneState
    units: tuple[MeshUnit, ...] = ()
    errors: tuple[str, ...] = ()
    notes: tuple[str, ...] = ()
    #: names of the `make view` doors that were LIVE at read time — carried here so
    #: the GUI never has to touch the session file or a socket on its own thread
    view_doors: tuple[str, ...] = ()

    @property
    def any_running(self) -> bool:
        """None-safe: an unestablished lane counts as neither running nor stopped."""
        return bool(self.compose.running) or bool(self.kind.running)

    @property
    def any_unknown(self) -> bool:
        return self.compose.running is None or self.kind.running is None

    @property
    def ready_counts(self) -> tuple[int, int]:
        return sum(1 for u in self.units if u.ready), len(self.units)


# ── the HSTS gate ──────────────────────────────────────────────────────────────────

def unsafe_door_reason(url: str, kind_https_ports=(KIND_HTTPS_PORT_DEFAULT,)) -> str:
    """"" when ``url`` may be handed to a browser button; otherwise why it may not.

    The rule, in full: only loopback hosts; nothing but http(s); and never HTTPS on the
    kind port under a pinnable hostname — ``localhost`` CAN be HSTS-pinned (it is a
    name), ``127.0.0.1`` cannot."""
    if not url:
        return "no address"
    try:
        p = urlparse(url)
    except ValueError:
        return "not a URL"
    host = (p.hostname or "").lower()
    if p.scheme not in ("http", "https"):
        return f"not a web URL ({p.scheme or 'no scheme'})"
    if host not in _LOOPBACK_HOSTS:
        return (f"{host or 'no host'} is a hostname-bearing address — the kind ingress "
                f"pins HSTS on it under a fake certificate")
    try:
        port = p.port
    except ValueError:
        return "bad port"
    if p.scheme == "https" and host != "127.0.0.1" and port in set(kind_https_ports):
        return HSTS_REASON
    return ""


def _gate(door: Door, kind_ports) -> Door:
    """Every Door passes through here: a URL the ban refuses becomes a blocked row."""
    if not door.url:
        return door
    why = unsafe_door_reason(door.url, kind_ports)
    if why:
        return Door(label="", url="", via=door.via, blocked=why)
    return door


# ── budget ─────────────────────────────────────────────────────────────────────────

class _Budget:
    def __init__(self, seconds: float):
        self._end = time.monotonic() + float(seconds)

    def remaining(self) -> float:
        return self._end - time.monotonic()

    def bounded(self, want: float) -> int:
        return max(1, int(min(float(want), max(self.remaining(), 0.0))))


def _probe(node, cmd: list[str], timeout: int) -> tuple[int, str]:
    """``node._probe`` with every failure folded — a stand-in node without ``_probe``
    (tests, a stub) reports as a failed read rather than an exception."""
    try:
        rc, out = node._probe(cmd, timeout=timeout)
        return int(rc), str(out or "")
    except Exception as exc:                          # noqa: BLE001 — folded on purpose
        return 1, f"{type(exc).__name__}: {exc}"


# ── kind lane ──────────────────────────────────────────────────────────────────────

def _port_is_http(name: str, number: int) -> bool:
    n = (name or "").lower()
    if any(h in n for h in _HTTP_PORT_NAME_HINTS):
        return True
    return number in _HTTP_PORTS


def _port_scheme(name: str, number: int) -> str:
    if "https" in (name or "").lower() or number in _HTTPS_PORTS:
        return "https"
    return "http"


def _parse_port_bindings(text: str) -> dict[int, tuple[str, int]]:
    """``docker inspect --format '{{json .HostConfig.PortBindings}}'`` ->
    ``{container port: (host ip, host port)}``. Never hardcode 8443: kind-local.yaml's
    ``extraPortMappings`` is the source and this is how it is read back."""
    out: dict[int, tuple[str, int]] = {}
    try:
        data = json.loads(text or "null") or {}
    except ValueError:
        return out
    if not isinstance(data, dict):
        return out
    for key, binds in data.items():
        try:
            cport = int(str(key).split("/", 1)[0])
        except ValueError:
            continue
        for b in binds or []:
            try:
                out[cport] = (str(b.get("HostIp") or "0.0.0.0"), int(b.get("HostPort")))
                break
            except (AttributeError, TypeError, ValueError):
                continue
    return out


def _bucket(objects: dict) -> dict[str, list[dict]]:
    by_kind: dict[str, list[dict]] = {}
    for item in (objects or {}).get("items") or []:
        if isinstance(item, dict):
            by_kind.setdefault(str(item.get("kind") or ""), []).append(item)
    return by_kind


def _meta(obj: dict) -> tuple[str, str]:
    m = obj.get("metadata") or {}
    return str(m.get("namespace") or ""), str(m.get("name") or "")


def _endpoint_sets(endpoints: list[dict]) -> tuple[set, set]:
    ready: set = set()
    not_ready: set = set()
    for ep in endpoints:
        ns, _ = _meta(ep)
        for subset in ep.get("subsets") or []:
            for a in subset.get("addresses") or []:
                tr = a.get("targetRef") or {}
                if tr.get("kind") == "Pod" and tr.get("name"):
                    ready.add((str(tr.get("namespace") or ns), str(tr["name"])))
            for a in subset.get("notReadyAddresses") or []:
                tr = a.get("targetRef") or {}
                if tr.get("kind") == "Pod" and tr.get("name"):
                    not_ready.add((str(tr.get("namespace") or ns), str(tr["name"])))
    return ready, not_ready


def _selects(svc: dict, pod: dict) -> bool:
    """Same namespace AND a NON-EMPTY selector that is a subset of the pod's labels.
    Selector-less services (headless, ``kubernetes``) never match anything."""
    sel = (svc.get("spec") or {}).get("selector") or {}
    if not sel:
        return False
    labels = (pod.get("metadata") or {}).get("labels") or {}
    return all(labels.get(k) == v for k, v in sel.items())


def _ingress_index(ingresses: list[dict], classes: set[str]):
    """``{(ns, service): [(host, path, class_name, served, ingress_name)]}``."""
    idx: dict[tuple[str, str], list[tuple[str, str, str, bool, str]]] = {}
    for ing in ingresses:
        ns, iname = _meta(ing)
        spec = ing.get("spec") or {}
        cls = str(spec.get("ingressClassName") or
                  ((ing.get("metadata") or {}).get("annotations") or {})
                  .get("kubernetes.io/ingress.class") or "")
        served = (cls in classes) if cls else False
        for rule in spec.get("rules") or []:
            host = str(rule.get("host") or "")
            for p in ((rule.get("http") or {}).get("paths") or []):
                svc = ((p.get("backend") or {}).get("service") or {}).get("name")
                if not svc:
                    continue
                idx.setdefault((ns, str(svc)), []).append(
                    (host, str(p.get("path") or "/"), cls, served, iname))
    return idx


def _container_summary(statuses: list[dict]) -> tuple[int, int, int, str, str]:
    """(ready, total, restarts, failure reason, transient reason) across a status list."""
    ready = total = restarts = 0
    failure = transient = ""
    for c in statuses or []:
        total += 1
        ready += 1 if c.get("ready") else 0
        try:
            restarts += int(c.get("restartCount") or 0)
        except (TypeError, ValueError):
            pass
        st = c.get("state") or {}
        waiting = st.get("waiting") or {}
        term = st.get("terminated") or {}
        reason = str(waiting.get("reason") or "")
        if reason:
            if reason in _FAILURE_REASONS and not failure:
                failure = reason
            elif reason not in _FAILURE_REASONS and not transient:
                transient = reason
        elif term:
            try:
                code = int(term.get("exitCode") or 0)
            except (TypeError, ValueError):
                code = 1
            if code != 0 and not failure:
                failure = str(term.get("reason") or "Error")
    return ready, total, restarts, failure, transient


def _pod_phase(pod: dict) -> tuple[str, str, bool]:
    """``(phase text, failure reason, all containers ready)`` — the kubectl column, with
    init-container reasons read FIRST because ``Init:CreateContainerConfigError`` lives
    only there."""
    status = pod.get("status") or {}
    phase = str(status.get("phase") or "Unknown")
    inits = status.get("initContainerStatuses") or []
    i_ready, i_total, _r, i_fail, i_trans = _container_summary(inits)
    if i_fail:
        return f"Init:{i_fail}", i_fail, False
    done_inits = sum(1 for c in inits
                     if ((c.get("state") or {}).get("terminated") or {}).get("exitCode") == 0)
    if inits and done_inits < i_total and phase not in ("Succeeded", "Failed"):
        return f"Init:{done_inits}/{i_total}", "", False
    conts = status.get("containerStatuses") or []
    c_ready, c_total, _r, c_fail, c_trans = _container_summary(conts)
    if phase == "Succeeded":
        return "Succeeded", "", False
    if c_fail:
        return c_fail, c_fail, False
    if phase == "Failed":
        return "Failed", str(status.get("reason") or "Failed"), False
    if c_trans:
        return c_trans, "", False
    if phase == "Running":
        return f"Running {c_ready}/{c_total}", "", (c_total > 0 and c_ready == c_total)
    return phase, "", False


def _join(objects: dict, host_ports: dict[int, tuple[str, int]], catalog, live: dict,
          cluster: str, *, stale_view: bool = False, kind_ports=(KIND_HTTPS_PORT_DEFAULT,)
          ) -> tuple[list[MeshUnit], list[str]]:
    """Pods x Services x Endpoints x Ingresses -> rows. Pure: no I/O, so a test can
    hand it canned JSON trimmed from a live cluster and pin every rule."""
    by_kind = _bucket(objects)
    pods = by_kind.get("Pod", [])
    services = by_kind.get("Service", [])
    endpoints = by_kind.get("Endpoints", [])
    ingresses = by_kind.get("Ingress", [])
    classes = {_meta(ic)[1] for ic in by_kind.get("IngressClass", [])}
    ready_set, not_ready_set = _endpoint_sets(endpoints)
    ing_idx = _ingress_index(ingresses, classes)
    notes: list[str] = []
    # Only the kind lanes' rows route a kind Ingress host: the compose and device
    # lanes share `hugmesh.net` (a compose-app row would otherwise claim the fe-gateway
    # pod's door and point the browser at a compose port for a kind pod).
    by_host = {d.host: d for d in (catalog or [])
               if d.host and d.lane.startswith("kind")}
    by_k8s = {}
    for d in (catalog or []):
        t = d.k8s_target
        if t:
            by_k8s[(t[1], t[2])] = d
    api_bind = host_ports.get(6443)
    units: list[MeshUnit] = []
    for pod in pods:
        ns, name = _meta(pod)
        meta = pod.get("metadata") or {}
        spec = pod.get("spec") or {}
        status = pod.get("status") or {}
        owner = ", ".join(f"{o.get('kind')}/{o.get('name')}"
                          for o in (meta.get("ownerReferences") or []) if o.get("name"))
        phase_text, failure, conts_ready = _pod_phase(pod)
        svcs = sorted((s for s in services if _meta(s)[0] == ns and _selects(s, pod)),
                      key=lambda s: _meta(s)[1])
        # readiness: Endpoints when a Service selects the pod, else its own containers
        if svcs:
            ready = (ns, name) in ready_set
            names = ", ".join(_meta(s)[1] for s in svcs)
            if ready:
                reason = ""
            elif (ns, name) in not_ready_set:
                reason = (f"selected by {names} but listed under notReadyAddresses — the "
                          f"readiness probe is failing or the pod is still starting")
            else:
                reason = f"selected by {names} but absent from its Endpoints"
        else:
            ready = phase_text.startswith("Running") and conts_ready
            reason = ("" if ready else
                      "no Service selects this pod — readiness read from its own "
                      "container status")
        if phase_text == "Succeeded":
            state = "stopped"
        elif failure:
            state = "failed"
        elif ready:
            state = "ok"
        elif phase_text.startswith("Running"):
            state = "running"
        else:
            state = "queued"
        # in-mesh address from the primary Service (one with an Ingress first, then one
        # with a web port, then the first by name)
        primary = None
        primary_port = None
        for s in svcs:
            sname = _meta(s)[1]
            ports = (s.get("spec") or {}).get("ports") or []
            if (ns, sname) in ing_idx and ports:
                primary, primary_port = s, ports[0]
                break
        if primary is None:
            for s in svcs:
                for p in (s.get("spec") or {}).get("ports") or []:
                    if _port_is_http(str(p.get("name") or ""), int(p.get("port") or 0)):
                        primary, primary_port = s, p
                        break
                if primary is not None:
                    break
        if primary is None and svcs:
            ports = (svcs[0].get("spec") or {}).get("ports") or []
            primary, primary_port = svcs[0], (ports[0] if ports else None)
        cluster_path = ""
        external_bits: list[str] = []
        door = Door()
        detail_bits = [f"owner: {owner or 'none'}",
                       f"node: {spec.get('nodeName') or '?'}",
                       f"pod IP: {status.get('podIP') or '?'}"]
        images = [str(c.get("image") or "") for c in (spec.get("containers") or [])]
        if images:
            detail_bits.append("image(s): " + ", ".join(i for i in images if i))
        _r, _t, restarts, _f, _tr = _container_summary(status.get("containerStatuses") or [])
        detail_bits.append(f"restarts: {restarts}")
        if svcs:
            detail_bits.append("service(s): " + ", ".join(_meta(s)[1] for s in svcs))
        if primary is not None:
            sname = _meta(primary)[1]
            sspec = primary.get("spec") or {}
            stype = str(sspec.get("type") or "ClusterIP")
            pnum = int((primary_port or {}).get("port") or 0)
            pname = str((primary_port or {}).get("name") or "")
            row = by_k8s.get((ns, sname))
            scheme = row.k8s_target[0] if row else _port_scheme(pname, pnum)
            cluster_path = f"{scheme}://{sname}.{ns}.svc.cluster.local:{pnum}" if pnum else \
                f"{sname}.{ns}.svc.cluster.local"
            is_http = _port_is_http(pname, pnum) or row is not None
            rules = ing_idx.get((ns, sname), [])
            if rules:
                for host, path, cls, served, iname in rules:
                    if served:
                        external_bits.append(f"{host}{path} (ingress {iname})")
                    else:
                        external_bits.append(
                            f"{host}{path} — Ingress {iname} names class "
                            f"'{cls or '<none>'}', which no IngressClass in this "
                            f"cluster serves")
                served_hosts = [h for h, _p, _c, served, _i in rules if served and h]
                chosen = None
                for h in served_hosts:
                    if h in by_host:
                        chosen = by_host[h]
                        break
                if chosen is not None and chosen.name in live:
                    door = Door(label="Open", url=live[chosen.name], via="view")
                elif chosen is not None:
                    door = Door(blocked=f"{HSTS_REASON} That serves it as {chosen.url}.")
                elif served_hosts:
                    door = Door(blocked=(
                        f"{HSTS_REASON} No scripts/hugmesh-view.tsv row routes "
                        f"'{served_hosts[0]}' yet — add one and the door appears here."))
                else:
                    door = Door(blocked="the Ingress that would expose this is not served")
            elif stype == "NodePort":
                for p in sspec.get("ports") or []:
                    np_ = p.get("nodePort")
                    if not np_:
                        continue
                    bind = host_ports.get(int(np_))
                    if bind:
                        external_bits.append(f"{bind[0]}:{bind[1]}->{np_} (NodePort)")
                        if door.url == "" and not door.blocked and is_http:
                            if _port_scheme(pname, pnum) == "https":
                                door = Door(blocked=(
                                    f"{HSTS_REASON} (NodePort {np_} serves TLS under the "
                                    f"cluster's own certificate.)"))
                            else:
                                door = Door(label="Open", via="compose",
                                            url=f"http://127.0.0.1:{bind[1]}/")
                    else:
                        external_bits.append(
                            f"NodePort {np_} — not published by this kind node")
                if not door.url and not door.blocked:
                    door = Door(blocked=(
                        f"the NodePort is not published to this host — "
                        f"kubectl --context kind-{cluster} port-forward -n {ns} "
                        f"svc/{sname} :{pnum}"))
            elif stype == "LoadBalancer":
                lb = ((primary.get("status") or {}).get("loadBalancer") or {}).get("ingress") or []
                addrs = [str(x.get("ip") or x.get("hostname") or "") for x in lb]
                addrs = [a for a in addrs if a]
                external_bits.append(", ".join(addrs) + " (LoadBalancer)" if addrs
                                     else "LoadBalancer — no address assigned")
                door = Door(blocked="a kind cluster assigns no LoadBalancer address; use "
                                    f"`make view` or kubectl --context kind-{cluster} "
                                    f"port-forward -n {ns} svc/{sname} :{pnum}")
            else:
                if row is not None and row.name in live:
                    door = Door(label="Open", url=live[row.name], via="view")
                elif row is not None:
                    door = Door(blocked=(
                        f"ClusterIP only — no live `make view` door. Press 'Open the "
                        f"browser door' with the {row.lane} lane (`make view "
                        f"LANE={row.lane}` serves it as {row.url}), or run: kubectl "
                        f"--context kind-{cluster} port-forward -n {ns} svc/{sname} "
                        f":{pnum}"))
                elif is_http:
                    door = Door(blocked=(
                        f"ClusterIP only — reach it with: kubectl --context "
                        f"kind-{cluster} port-forward -n {ns} svc/{sname} :{pnum} "
                        f"(or add a k8s+ row to scripts/hugmesh-view.tsv)"))
                else:
                    door = Door(blocked=(
                        f"port {pnum}{(' (' + pname + ')') if pname else ''} is not an "
                        f"HTTP port — address only"))
        elif name.startswith("kube-apiserver") and api_bind:
            external_bits.append(f"{api_bind[0]}:{api_bind[1]}->6443 (Kubernetes API)")
            door = Door(blocked="the Kubernetes API is not a web page — address only")
        else:
            door = Door(blocked="no Service selects this pod — nothing to open")
        if stale_view and door.blocked and not door.url:
            door = Door(blocked=door.blocked + " A previous view session left state "
                        "behind; press 'Open the browser door' to restart it.")
        door = _gate(door, kind_ports)
        units.append(MeshUnit(
            lane="kind", namespace=ns, name=name, owner=owner, phase=phase_text,
            ready=ready, reason=reason, state=state, cluster_path=cluster_path,
            external="; ".join(external_bits), door=door,
            detail="\n".join(detail_bits)))
    return units, notes


def _kind_units(node, generator_dir: str, catalog, live: dict, budget: _Budget, *,
                stale_view: bool = False, kind_ports=(KIND_HTTPS_PORT_DEFAULT,)
                ) -> tuple[LaneState, list[MeshUnit], list[str], list[str]]:
    """The kind lane: cheapest question first, then ONE round trip for everything."""
    notes: list[str] = []
    errors: list[str] = []
    cluster = _kind_cluster_name()
    kind = devops_tools.which("kind", generator_dir)
    if not kind:
        return (LaneState(None, error="kind is not installed — press 'Install DevOps "
                                      "prerequisites' to add it"), [], notes, errors)
    if budget.remaining() <= 1:
        return (LaneState(None, error="the kind lane was not read — the snapshot "
                                      "deadline was spent on the other lane"),
                [], notes, errors)
    rc, out = _probe(node, [kind, "get", "clusters"],
                     budget.bounded(KIND_CLUSTERS_TIMEOUT_S))
    if rc != 0:
        return (LaneState(None, error=f"`kind get clusters` failed: {out.strip()[:200]}"),
                [], notes, errors)
    if cluster not in out.split():
        return (LaneState(False, detail=f"no kind cluster named {cluster}"),
                [], notes, errors)
    kubectl = devops_tools.which("kubectl", generator_dir)
    if not kubectl:
        return (LaneState(None, detail=f"cluster {cluster} exists",
                          error="kubectl is not installed — press 'Install DevOps "
                                "prerequisites'"), [], notes, errors)
    if budget.remaining() <= 1:
        return (LaneState(None, detail=f"cluster {cluster} exists",
                          error="the cluster was not read — the snapshot deadline "
                                "was spent"), [], notes, errors)
    ctx = f"kind-{cluster}"
    t = budget.bounded(KUBECTL_GET_TIMEOUT_S)
    rc, out = _probe(node, [kubectl, "--context", ctx, "get",
                            "pods,services,endpoints,ingresses,ingressclasses",
                            "-A", "-o", "json"], t)
    if rc != 0:
        why = out.strip()[:200] or "no output"
        return (LaneState(None, detail=f"cluster {cluster} exists",
                          error=f"cluster exists, API did not answer in {t}s ({why})"),
                [], notes, errors)
    try:
        objects = json.loads(out)
        if not isinstance(objects, dict):
            raise ValueError("not an object")
    except ValueError as exc:
        return (LaneState(None, detail=f"cluster {cluster} exists",
                          error=f"kubectl returned unparseable JSON ({exc})"),
                [], notes, errors)
    host_ports: dict[int, tuple[str, int]] = {}
    if shutil.which("docker") and budget.remaining() > 1:
        rc, pb = _probe(node, ["docker", "inspect", f"{cluster}-control-plane",
                               "--format", "{{json .HostConfig.PortBindings}}"],
                        budget.bounded(DOCKER_INSPECT_TIMEOUT_S))
        if rc == 0:
            host_ports = _parse_port_bindings(pb)
        else:
            notes.append(f"the kind node's host port map could not be read "
                         f"({pb.strip()[:120] or 'docker inspect failed'}); published "
                         f"ports are not shown")
    else:
        notes.append("docker is not available, so the kind node's published host "
                     "ports are not shown")
    units, jnotes = _join(objects, host_ports, catalog, live, cluster,
                          stale_view=stale_view, kind_ports=kind_ports)
    notes.extend(jnotes)
    pods = len(units)
    api = host_ports.get(6443)
    detail = f"cluster {cluster} · {pods} pod(s)"
    if api:
        detail += f" · API https://{api[0]}:{api[1]}"
    if pods == 0:
        notes.append(f"the kind cluster {cluster} answered with zero pods")
    return LaneState(True, detail=detail), units, notes, errors


# ── compose lane ───────────────────────────────────────────────────────────────────

def _parse_compose_ps(text: str) -> list[dict] | None:
    """Both shapes compose v2 has emitted: a JSON array, or JSON-lines. None when
    neither parses (the caller then falls back to ``docker ps``)."""
    text = (text or "").strip()
    if not text:
        return []
    try:
        whole = json.loads(text)
        if isinstance(whole, list):
            return [r for r in whole if isinstance(r, dict)]
        if isinstance(whole, dict):
            return [whole]
    except ValueError:
        pass
    rows: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            r = json.loads(line)
        except ValueError:
            return None
        if isinstance(r, dict):
            rows.append(r)
    return rows or None


def _parse_docker_ps(text: str) -> list[dict]:
    """``docker ps --format '{{json .}}'`` (one object per line) -> compose-ish rows."""
    rows: list[dict] = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict):
            continue
        labels = {}
        for kv in str(r.get("Labels") or "").split(","):
            if "=" in kv:
                k, v = kv.split("=", 1)
                labels[k.strip()] = v.strip()
        pubs = []
        for part in str(r.get("Ports") or "").split(","):
            part = part.strip()
            if "->" not in part:
                continue
            left, right = part.split("->", 1)
            host, _, hport = left.rpartition(":")
            tport = right.split("/", 1)[0]
            proto = right.split("/", 1)[1] if "/" in right else "tcp"
            try:
                pubs.append({"URL": host, "PublishedPort": int(hport),
                             "TargetPort": int(tport), "Protocol": proto})
            except ValueError:
                continue
        rows.append({
            "Name": r.get("Names") or r.get("Name") or "",
            "Service": labels.get("com.docker.compose.service", ""),
            "State": str(r.get("State") or "").lower(),
            "Status": r.get("Status") or "",
            "Health": "",
            "Image": r.get("Image") or "",
            "Publishers": pubs,
        })
    return rows


def _compose_units(node, generator_dir: str, catalog, live: dict, budget: _Budget, *,
                   kind_ports=(KIND_HTTPS_PORT_DEFAULT,)
                   ) -> tuple[LaneState, list[MeshUnit], list[str], list[str]]:
    notes: list[str] = []
    errors: list[str] = []
    if not shutil.which("docker"):
        return (LaneState(None, error="docker is not installed — the compose lane "
                                      "cannot be read"), [], notes, errors)
    if budget.remaining() <= 1:
        return (LaneState(None, error="the compose lane was not read — the snapshot "
                                      "deadline was spent on the other lane"),
                [], notes, errors)
    try:
        st = node.status()
        running, detail = bool(st.running), str(st.detail or "")
    except Exception as exc:                          # noqa: BLE001 — folded on purpose
        return (LaneState(None, error=f"compose status failed: {type(exc).__name__}: "
                                      f"{exc}"), [], notes, errors)
    if not running:
        return LaneState(False, detail=detail or "not running"), [], notes, errors
    rows: list[dict] | None = None
    base = _compose_base()
    compose_file = str(getattr(node, "compose_file", "") or "")
    if base and compose_file and budget.remaining() > 1:
        rc, out = _probe(node, [*base, "-f", compose_file, "ps", "--format", "json"],
                         budget.bounded(COMPOSE_PS_TIMEOUT_S))
        if rc == 0:
            rows = _parse_compose_ps(out)
        if rows is None or (rc != 0):
            notes.append("`docker compose ps --format json` was rejected — rows come "
                         "from `docker ps` filtered by the compose project label")
            rows = None
    if rows is None and budget.remaining() > 1:
        rc, out = _probe(node, ["docker", "ps", "--filter",
                                f"label=com.docker.compose.project={_COMPOSE_PROJECT}",
                                "--format", "{{json .}}"],
                         budget.bounded(COMPOSE_PS_TIMEOUT_S))
        if rc != 0:
            errors.append(f"the compose lane's containers could not be listed "
                          f"({out.strip()[:160] or 'docker ps failed'})")
            return (LaneState(True, detail=detail), [], notes, errors)
        rows = _parse_docker_ps(out)
    if rows is None:
        errors.append("the compose lane's containers could not be listed within the "
                      "snapshot deadline")
        return LaneState(True, detail=detail), [], notes, errors
    https_port = int(getattr(node, "public_https_port", 0) or 0)
    plain_port = int(getattr(node, "public_host_port", 0) or 0)
    web_url = str(getattr(node, "web_url", "") or "")
    try:
        onion = str(node.onion_url() or "")
    except Exception:                                 # noqa: BLE001
        onion = ""
    by_name = {d.name: d for d in (catalog or [])}
    units: list[MeshUnit] = []
    for r in rows:
        name = str(r.get("Name") or "")
        service = str(r.get("Service") or "")
        state_s = str(r.get("State") or "").lower()
        health = str(r.get("Health") or "").lower()
        try:
            exit_code = int(r.get("ExitCode") or 0)
        except (TypeError, ValueError):
            exit_code = 0
        phase = state_s or "unknown"
        if health:
            phase += f" ({health})"
        ready = state_s == "running" and health in ("", "healthy")
        if ready:
            reason, state = "", "ok"
        elif state_s == "running":
            reason, state = f"health is {health}", ("failed" if health == "unhealthy"
                                                    else "running")
        elif state_s in ("exited", "dead"):
            reason = f"{state_s} (exit {exit_code})"
            state = "failed" if exit_code != 0 else "stopped"
        else:
            reason, state = state_s or "unknown", "queued"
        pubs = [p for p in (r.get("Publishers") or []) if isinstance(p, dict)]
        seen: set[tuple[int, int]] = set()
        external_bits: list[str] = []
        published: list[tuple[int, int]] = []
        first_target = 0
        for p in pubs:
            try:
                tport = int(p.get("TargetPort") or 0)
                pport = int(p.get("PublishedPort") or 0)
            except (TypeError, ValueError):
                continue
            if tport and not first_target:
                first_target = tport
            if not pport or (pport, tport) in seen:
                continue
            seen.add((pport, tport))
            host = str(p.get("URL") or "0.0.0.0")
            if host in ("::", "[::]"):
                continue                      # the v6 twin of a row already shown
            external_bits.append(f"{host}:{pport}->{tport}")
            published.append((pport, tport))
        cluster_path = f"{service}:{first_target}" if service and first_target else \
            (service or "")
        door = Door()
        pmap = dict(published)
        if https_port and https_port in pmap:
            d = by_name.get("compose-tls")
            if d is not None and d.name in live:
                door = Door(label="Open", url=live[d.name], via="view")
            else:
                door = Door(label="Open", url=web_url, via="compose")
        elif plain_port and plain_port in pmap:
            d = by_name.get("compose-app")
            if d is not None and d.name in live:
                door = Door(label="Open", url=live[d.name], via="view")
            else:
                door = Door(label="Open", url=f"http://127.0.0.1:{plain_port}/",
                            via="compose")
        elif onion and "tor" in (service or name).lower():
            external_bits.append(onion)
            door = Door(blocked="a normal browser cannot reach a .onion — use the "
                                "'Copy .onion address' button and Tor Browser")
        else:
            web = [(pp, tp) for pp, tp in published if _port_is_http("", tp)]
            if web:
                door = Door(label="Open", url=f"http://127.0.0.1:{web[0][0]}/",
                            via="compose")
            elif published:
                door = Door(blocked=f"published port(s) {', '.join(str(pp) for pp, _ in published)} "
                                    f"are not HTTP — address only")
            else:
                door = Door(blocked="no published port — reachable only from inside the "
                                    "compose network")
        door = _gate(door, kind_ports)
        udetail = "\n".join([
            f"service: {service or '?'}",
            f"image: {r.get('Image') or '?'}",
            f"status: {r.get('Status') or '?'}",
            f"compose network address: {cluster_path or 'none'}",
        ])
        units.append(MeshUnit(
            lane="compose", namespace=_COMPOSE_PROJECT, name=name or service,
            owner=service, phase=phase, ready=ready, reason=reason, state=state,
            cluster_path=cluster_path, external="; ".join(external_bits), door=door,
            detail=udetail))
    if not units:
        notes.append("the compose project reports running but listed zero containers")
    bits = [f"project {_COMPOSE_PROJECT}", f"{len(units)} container(s)"]
    if detail and "container" not in detail:      # status() already counts them
        bits.append(detail)
    return LaneState(True, detail=" · ".join(bits)), units, notes, errors


# ── the snapshot ───────────────────────────────────────────────────────────────────

def _catalog_and_doors(generator_dir: str, env=None):
    """The view catalog + which doors are live + the kind HTTPS port(s) to refuse.
    Every failure degrades to 'no door + why' — rows still render."""
    notes: list[str] = []
    catalog = []
    kind_ports = {KIND_HTTPS_PORT_DEFAULT}
    try:
        catalog = view_doors.load(generator_dir, env)
        for d in catalog:
            # ONLY the kind lanes' rows name the pinning port. The compose-tls row's
            # upstream is https://127.0.0.1:${PUBLIC_HTTPS_PORT:-8488} — the tls-front
            # that STRIPS HSTS — and adding its port here made the gate refuse the
            # compose TLS door (https://localhost:8488) as if it were the kind
            # ingress. Caught by the live read-only probe on 2026-09-02, not by the
            # unit tests, which bypassed this function; pinned by
            # test_snapshot_offers_the_compose_tls_front_through_the_real_catalog.
            t = d.direct_target
            if d.lane.startswith("kind") and t and t[0] == "https" and t[2]:
                kind_ports.add(int(t[2]))
    except view_doors.ViewDoorError as exc:
        notes.append(f"no browser doors: {exc}")
    except Exception as exc:                          # noqa: BLE001
        notes.append(f"no browser doors: {type(exc).__name__}: {exc}")
    try:
        live = view_doors.live_doors(generator_dir, env)
    except Exception as exc:                          # noqa: BLE001
        live = {}
        notes.append(f"the view session could not be read: {type(exc).__name__}: {exc}")
    try:
        stale = view_doors.stale_session(generator_dir, env)
    except Exception:                                 # noqa: BLE001
        stale = False
    if stale:
        notes.append("a previous view session left state behind; press 'Open the "
                     "browser door' to restart it")
    return catalog, live, stale, tuple(sorted(kind_ports)), notes


def snapshot(generator_dir: str, node, *, want_compose: bool = True,
             want_kind: bool = True, deadline_s: float = DEFAULT_DEADLINE_S,
             env=None) -> MonitorSnapshot:
    """Read both lanes. NEVER raises — every failure is a sentence in the result."""
    budget = _Budget(deadline_s)
    errors: list[str] = []
    notes: list[str] = []
    try:
        catalog, live, stale, kind_ports, cnotes = _catalog_and_doors(generator_dir, env)
        notes.extend(cnotes)
    except Exception as exc:                          # noqa: BLE001
        catalog, live, stale, kind_ports = [], {}, False, (KIND_HTTPS_PORT_DEFAULT,)
        notes.append(f"the view catalog could not be read: {type(exc).__name__}: {exc}")
    units: list[MeshUnit] = []
    kind = LaneState(None, detail="not asked")
    compose = LaneState(None, detail="not asked")
    if want_kind:
        try:
            kind, ku, kn, ke = _kind_units(node, generator_dir, catalog, live, budget,
                                           stale_view=stale, kind_ports=kind_ports)
            units.extend(ku)
            notes.extend(kn)
            errors.extend(ke)
        except Exception as exc:                      # noqa: BLE001 — never raise
            kind = LaneState(None, error=f"the kind lane read failed: "
                                         f"{type(exc).__name__}: {exc}")
    if want_compose:
        try:
            compose, cu, cn, ce = _compose_units(node, generator_dir, catalog, live,
                                                 budget, kind_ports=kind_ports)
            units.extend(cu)
            notes.extend(cn)
            errors.extend(ce)
        except Exception as exc:                      # noqa: BLE001 — never raise
            compose = LaneState(None, error=f"the compose lane read failed: "
                                            f"{type(exc).__name__}: {exc}")
    for lane_name, lane in (("kind", kind), ("compose", compose)):
        if lane.running is None and lane.error:
            errors.append(f"{lane_name}: {lane.error}")
    if live:
        notes.append("a browser door answering 401 is NOT down — a stale pre-rebuild "
                     "session cookie 401s the page while the door itself is fine; "
                     "sign out and back in")
    units.sort(key=lambda u: (u.lane, u.namespace, u.name))
    return MonitorSnapshot(
        taken_at=time.strftime("%H:%M:%S"), compose=compose, kind=kind,
        units=tuple(units), errors=tuple(errors), notes=tuple(notes),
        view_doors=tuple(sorted(live)))


def addresses_text(snap: MonitorSnapshot) -> str:
    """Every row's addresses as copyable lines — the 'Copy all addresses' button."""
    lines = []
    for u in snap.units:
        bits = [u.key, u.phase]
        if u.cluster_path:
            bits.append(u.cluster_path)
        if u.external:
            bits.append(u.external)
        if u.door.url:
            bits.append(u.door.url)
        lines.append("\t".join(bits))
    return "\n".join(lines)
