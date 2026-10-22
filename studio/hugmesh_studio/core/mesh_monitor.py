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

SCALING (2026-09-09). The table is no longer read-only: every row carries the
CONTROLLER behind it (``ScaleTarget``) and ``scale()`` runs one ``kubectl scale`` or
one ``docker compose up --scale``. The row is never the target — a pod and a container
are instances, and asking for more of an instance is meaningless — so the target is
derived once, from the pod's own ``pod-template-hash`` label (see ``ScaleTarget``) or
from the compose service label, and a row whose controller cannot be scaled says which
kind it is and why instead of offering a control that reverts.

Qt-free by construction (``test_module_is_qt_free``).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import time
from dataclasses import dataclass, field, replace
from urllib.parse import urlparse

from . import devops_tools, view_doors
from .local_stack_node import _COMPOSE_PROJECT, _compose_base, _kind_cluster_name

#: Per-call ceilings. ONE ``kubectl get`` round trip for the whole cluster rather than a
#: per-namespace loop: N calls is N timeouts on a hung API server.
KIND_CLUSTERS_TIMEOUT_S = 10
#: Where scripts/kind-halt.sh keeps its record, and how long to wait for it. Kept
#: in step with that script's own defaults (ARGOCD_NS / STATE_CM / STATE_KEY); it is
#: one small read, so it gets a short ceiling and never eats the snapshot deadline.
ARGOCD_NS = "devops"
KIND_HALT_STATE_CM = "hugmesh-kind-halt"
KIND_HALT_STATE_KEY = "halt.json"
KIND_HALT_READ_TIMEOUT_S = 10
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


#: What ONE scale press may ask for. Not a Kubernetes limit and not a compose limit
#: — a fat-finger guard on a control whose "+" is one pixel from "Apply". A mesh that
#: genuinely wants 40 replicas of something is not asking for it from this table.
MAX_REPLICAS = 20

#: A scale verb's ceiling. `docker compose up --scale` PULLS and STARTS containers and
#: `kubectl scale` returns as soon as the spec is written, so the two ends of this are
#: far apart; the long one is what the budget has to cover.
SCALE_TIMEOUT_S = 180


@dataclass(frozen=True)
class ScaleTarget:
    """The WORKLOAD behind a row, which is what scales — never the row itself.

    A monitor row is one POD or one CONTAINER, and neither of those is a thing you can
    ask for more of: you ask its controller. So every row carries the controller it
    belongs to, or the sentence saying why it has none. ``refused`` is what the dash's
    tooltip shows, and it is deliberately the DEFAULT: a row that was never given a
    target must read as "not scalable", never as "scalable to nothing".

    THE DEPLOYMENT IS DERIVED FROM THE POD'S OWN LABEL, not from a name pattern.
    A pod's ``ownerReferences`` names its ReplicaSet, and scaling a ReplicaSet that a
    Deployment owns is undone by the Deployment controller within seconds — a control
    that appears to work and silently reverts. The Deployment's name is the ReplicaSet
    name minus its ``pod-template-hash``, and that hash is on the POD as a label, so the
    strip is exact rather than a guess at how many trailing characters are a hash. A
    ReplicaSet with no such label is refused rather than scaled directly.
    """
    kind: str = ""                # "deployment" | "statefulset" | "compose-service"
    name: str = ""
    namespace: str = ""
    refused: str = "this row carries no scalable workload"

    @property
    def scalable(self) -> bool:
        return bool(self.kind and self.name) and not self.refused

    @property
    def key(self) -> str:
        """Rows sharing this key are replicas OF EACH OTHER — how "how many are there
        now?" is counted without asking the API a second question."""
        return f"{self.kind}/{self.namespace}/{self.name}"

    def describe(self) -> str:
        if self.kind == "compose-service":
            return f"compose service {self.name}"
        return f"{self.kind}/{self.name} in {self.namespace}"


#: The label a container or pod carries when it serves ONE domain. The Studio writes
#: it on every service of the per-domain own-Casdoor overlay (core/own_casdoor.py) and
#: the casdoor-domains ApplicationSet writes it on its pods
#: (specs/cluster/apps/05b-casdoor-domains.yaml). Its value is the domain's name on
#: the Docker mesh and its slug on the kind lane (``DomainHints.names`` maps it back).
DOMAIN_LABEL = "hugmesh.net/domain"
#: The pod ANNOTATION that carries the domain's real name beside the slug label (a
#: label value cannot hold every DNS name — 63 characters at most — an annotation
#: can). The casdoor-domains ApplicationSet writes it from the element's
#: clusterDomain. When a pod has it, the row shows that name on every mount, with or
#: without the Studio's own config.
DOMAIN_NAME_ANNOTATION = "hugmesh.net/domain-name"
#: What a shared unit is labelled — the gateway, Casdoor, the databases every domain
#: reads, the one tor container that carries every onion.
ALL_DOMAINS = "All domains"

#: The four per-domain verbs, in button order.
CONTROL_VERBS = ("start", "stop", "restart", "logs")


@dataclass(frozen=True)
class UnitControl:
    """What the per-domain Start / Stop / Restart / Logs buttons act on for ONE row.

    ``kind`` is "container" (a compose container, driven by name with the docker CLI)
    or "pod" (a kind pod). ``refusals`` holds ``(verb, sentence)`` pairs for every
    verb this row will not run — a refusal is a sentence, never a silent skip."""
    kind: str = ""
    name: str = ""
    namespace: str = ""
    refusals: tuple[tuple[str, str], ...] = ()
    #: compose only: the row's service, and the services it waits for (compose's
    #: own depends_on label) — a domain's Start starts those first, Stop stops
    #: them last, so its Casdoor never starts ahead of its database.
    service: str = ""
    depends_on: tuple[str, ...] = ()

    def refusal(self, verb: str) -> str:
        if not (self.kind and self.name):
            return "this row carries nothing to start, stop or read logs from"
        for v, why in self.refusals:
            if v == verb:
                return why
        return ""

    def allows(self, verb: str) -> bool:
        return not self.refusal(verb)


@dataclass(frozen=True)
class DomainHints:
    """What the Studio's OWN configuration says about domains, for the rows no label
    names. Built by :func:`domain_hints` from a LocalMeshBootstrapConfig; empty (the
    default) on every mount that has no config — the emulation pages — where only real
    labels name a domain.

    ``service_domains``: local-service slug -> the domain names whose Domain services
    chose it, for slugs NOT also chosen mesh-wide. ``names``: brand id / slug ->
    domain name (a kind pod's label carries the slug). ``own_domain``: the mesh's own
    domain, the one the primary onion serves."""
    service_domains: dict = field(default_factory=dict)
    names: dict = field(default_factory=dict)
    own_domain: str = ""


@dataclass(frozen=True)
class OnionDoor:
    """One Tor address the running mesh publishes: the mesh's own (``primary``) or
    one domain's own. ``login`` is what Tor Browser is handed; ``url`` the bare
    onion. Never a browser button — a normal browser cannot reach a .onion."""
    domain: str
    url: str
    login: str
    primary: bool = False


@dataclass(frozen=True)
class MeshUnit:
    lane: str                     # "compose" | "kind"
    namespace: str
    name: str
    owner: str                    # ReplicaSet/StatefulSet/… name, or the compose service
    phase: str                    # "Running 1/1" | "ImagePullBackOff" | "Init:CreateContainerConfigError"
    ready: bool
    reason: str                   # why not ready, "" when ready
    #: progress.py _STATUS_GLYPH key: ok|failed|running|queued|stopped|completed.
    #: ``completed`` (Decision 99 = A, #378) is a one-shot that ran to completion — a
    #: Succeeded pod owned by a Job, or an exit-0 compose service whose file says
    #: ``restart: "no"``. It keeps its row but is outside the ``N/N ready`` headline and
    #: is not a running replica; a service that merely stopped (exit 0) stays ``stopped``.
    state: str
    cluster_path: str = ""        # in-mesh address, "" when no Service selects it
    external: str = ""            # "hugmesh.net/ (ingress)" | "0.0.0.0:8088->8080" | ""
    door: Door = field(default_factory=Door)
    detail: str = ""              # tooltip long form: image, restarts, node, ingress rule
    #: The controller the row's Replicas control drives, or a refusal. Defaulted, so a
    #: MeshUnit built anywhere that predates scaling reads as "not scalable" rather
    #: than raising.
    scale: ScaleTarget = field(default_factory=ScaleTarget)
    #: THE ONE DOMAIN this unit serves (2026-10-21, pod controls per domain), or ""
    #: when it is shared. Read from a real label (``DOMAIN_LABEL`` on the container
    #: or pod), from the onion key directory a per-domain onion row was minted
    #: under, or from the Studio's own per-domain service choice — never guessed
    #: from a name. ``domain_why`` says which of those it was.
    domain: str = ""
    #: A SHARED unit that the Studio's config says only these domains chose (one
    #: tuwunel two domains picked). Empty with ``domain`` empty = every domain.
    shared_by: tuple[str, ...] = ()
    domain_why: str = ""
    #: What the Start / Stop / Restart / Logs controls act on, or why they refuse.
    control: "UnitControl" = field(default_factory=lambda: UnitControl())

    @property
    def key(self) -> str:
        return f"{self.lane}/{self.namespace}/{self.name}"

    @property
    def domain_text(self) -> str:
        """What the Domain column shows."""
        if self.domain:
            return self.domain
        if self.shared_by:
            return "Shared: " + ", ".join(self.shared_by)
        return ALL_DOMAINS


@dataclass(frozen=True)
class LaneState:
    running: bool | None          # None = COULD NOT ESTABLISH (I5), never rendered as False
    detail: str = ""
    error: str = ""
    #: kind lane only (#356): has `make kind-halt` halted this lane? TRI-STATE for
    #: the same reason ``running`` is — True halted, False not halted, **None** the
    #: question could not be answered. A halted lane still reads running=True (the
    #: halt KEEPS the cluster), so without this the GUI offers Halt on an already
    #: halted lane and Resume on one that was never halted, with no way to tell.
    halted: bool | None = None


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
    #: the lane that live session serves (session.json `lane`: "kind" / "compose"),
    #: "" when no session is live — so the GUI can say WHICH lane's doors are taken
    view_lane: str = ""
    #: Every onion the running tor container published — the mesh's own first, then
    #: one per Tor domain — each with its own Open / Copy in the GUI.
    onions: tuple[OnionDoor, ...] = ()

    def domains(self) -> tuple[str, ...]:
        """Every domain at least one row serves on its own, sorted."""
        return tuple(sorted({u.domain for u in self.units if u.domain}))

    @property
    def any_running(self) -> bool:
        """None-safe: an unestablished lane counts as neither running nor stopped."""
        return bool(self.compose.running) or bool(self.kind.running)

    @property
    def any_unknown(self) -> bool:
        return self.compose.running is None or self.kind.running is None

    @property
    def ready_counts(self) -> tuple[int, int]:
        """``(ready, total)`` for the headline. ``completed`` one-shots (finished work)
        keep their table rows but are left out of BOTH numbers, so a healthy mesh reads
        N/N instead of 41/43 (#378)."""
        counted = [u for u in self.units if u.state != "completed"]
        return sum(1 for u in counted if u.ready), len(counted)


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


#: Controller kinds `kubectl scale` drives, and what a row owned by one of the others
#: says instead. Each refusal is a FACT about that controller, not a shrug: a DaemonSet
#: has exactly one pod per node by definition, a Job's parallelism is fixed when it is
#: created, and a static pod has no controller in the API at all.
_UNSCALABLE_OWNERS = {
    "DaemonSet": ("a DaemonSet runs exactly one pod per node — add or remove nodes, "
                  "there is no replica count to set"),
    "Job": ("a Job's parallelism is fixed when it is created — scaling it in place is "
            "not a thing kubectl can do"),
    "CronJob": ("a CronJob creates a Job per schedule tick — there is no standing "
                "replica count"),
    "Node": ("a static pod, run directly by this node's kubelet from a manifest on "
             "disk — the API server has no workload object to scale"),
}


def _pod_scale_target(pod: dict, ns: str) -> ScaleTarget:
    """Which controller a pod's Replicas control would drive. See ScaleTarget."""
    meta = pod.get("metadata") or {}
    refs = [r for r in (meta.get("ownerReferences") or []) if (r or {}).get("name")]
    if not refs:
        return ScaleTarget(refused="a bare pod — nothing created it, so nothing can "
                                   "be asked for more of it")
    ref = refs[0]
    kind = str(ref.get("kind") or "")
    name = str(ref.get("name") or "")
    if kind == "StatefulSet":
        return ScaleTarget("statefulset", name, ns, refused="")
    if kind == "ReplicaSet":
        h = str(((meta.get("labels") or {}).get("pod-template-hash") or ""))
        if h and name.endswith("-" + h) and len(name) > len(h) + 1:
            return ScaleTarget("deployment", name[: -(len(h) + 1)], ns, refused="")
        return ScaleTarget(refused=(
            f"owned by ReplicaSet/{name}, which carries no pod-template-hash — the "
            f"Deployment behind it cannot be named, and scaling the ReplicaSet "
            f"directly is undone by its controller within seconds"))
    if kind == "ReplicationController":
        return ScaleTarget("replicationcontroller", name, ns, refused="")
    why = _UNSCALABLE_OWNERS.get(kind)
    if why:
        return ScaleTarget(refused=why)
    return ScaleTarget(refused=f"owned by {kind}/{name}, which `kubectl scale` does "
                               f"not drive")


#: Why Start and Stop are not offered on a kind pod. Measured, not assumed: every
#: Application the kind lane syncs runs ``automated: {prune: true, selfHeal: true}``
#: (specs/cluster/apps/05b-casdoor-domains.yaml for the per-domain Casdoors), and
#: self-heal puts a Deployment's replica count back within seconds of a scale to 0.
KIND_STOP_REFUSAL = (
    "on the kind lane ArgoCD self-heal owns every workload's replica count, so a stop "
    "from here would be undone within seconds and a start has nothing to start. "
    "`Halt DevOps lane` stops the whole lane without deleting it; Restart below "
    "replaces this domain's pods.")


def _pod_control(pod: dict, ns: str, name: str) -> UnitControl:
    """Restart = delete the pod and let its controller make a new one (no spec edit
    for ArgoCD to revert); Logs = ``kubectl logs``. A pod nothing would re-create is
    refused Restart, because deleting it would be a stop that cannot be undone."""
    refs = [r for r in ((pod.get("metadata") or {}).get("ownerReferences") or [])
            if (r or {}).get("name")]
    owner = str((refs[0] if refs else {}).get("kind") or "")
    refusals = [("start", KIND_STOP_REFUSAL), ("stop", KIND_STOP_REFUSAL)]
    if not owner:
        refusals.append(("restart", "a bare pod — nothing would create it again, so "
                                    "deleting it is a stop, not a restart"))
    elif owner == "Node":
        refusals.append(("restart", "a static pod run by the node's kubelet from a "
                                    "manifest on disk — deleting it through the API "
                                    "does not restart it"))
    elif owner in ("Job", "CronJob"):
        refusals.append(("restart", "a Job's pod — deleting it re-runs the Job's work "
                                    "rather than restarting a service"))
    return UnitControl("pod", name, ns, tuple(refusals))


def _join(objects: dict, host_ports: dict[int, tuple[str, int]], catalog, live: dict,
          cluster: str, *, stale_view: bool = False, kind_ports=(KIND_HTTPS_PORT_DEFAULT,),
          hints: DomainHints | None = None
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
            # finished work is `completed` only when a JOB made it (what it IS, not how
            # it ended): a bare / ReplicaSet-owned pod that exited cleanly is down.
            job_owned = any((o or {}).get("kind") == "Job"
                            for o in (meta.get("ownerReferences") or []))
            state = "completed" if job_owned else "stopped"
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
        label_dom = str(((meta.get("labels") or {}).get(DOMAIN_LABEL) or "")).strip()
        domain = ""
        domain_why = "no hugmesh.net/domain label: shared by every domain"
        if label_dom:
            # The name, in order of trust: the pod's own annotation (the cluster
            # wrote it from the same element as the label), then the Studio's own
            # domain list, then — nothing names it — the slug itself, which
            # snapshot()'s last pass may still name from the compose rows.
            ann_name = str(((meta.get("annotations") or {})
                            .get(DOMAIN_NAME_ANNOTATION) or "")).strip()
            hint_name = str(((hints.names if hints else {}) or {}).get(label_dom) or "")
            domain = ann_name or hint_name or label_dom
            domain_why = f"pod label {DOMAIN_LABEL}={label_dom}"
            if ann_name and ann_name != label_dom:
                domain_why += (f" (the domain {domain}, from its "
                               f"{DOMAIN_NAME_ANNOTATION} annotation)")
            elif domain != label_dom:
                domain_why += f" (the domain {domain})"
            detail_bits.append(f"domain: {domain} ({domain_why})")
        units.append(MeshUnit(
            lane="kind", namespace=ns, name=name, owner=owner, phase=phase_text,
            ready=ready, reason=reason, state=state, cluster_path=cluster_path,
            external="; ".join(external_bits), door=door,
            detail="\n".join(detail_bits), scale=_pod_scale_target(pod, ns),
            domain=domain, domain_why=domain_why,
            control=_pod_control(pod, ns, name)))
    return units, notes


def _kind_units(node, generator_dir: str, catalog, live: dict, budget: _Budget, *,
                stale_view: bool = False, kind_ports=(KIND_HTTPS_PORT_DEFAULT,),
                hints: DomainHints | None = None
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
                          stale_view=stale_view, kind_ports=kind_ports, hints=hints)
    notes.extend(jnotes)
    pods = len(units)
    api = host_ports.get(6443)
    detail = f"cluster {cluster} · {pods} pod(s)"
    if api:
        detail += f" · API https://{api[0]}:{api[1]}"
    if pods == 0:
        notes.append(f"the kind cluster {cluster} answered with zero pods")
    halted = _halt_record_present(node, kubectl, ctx, budget)
    if halted is True:
        detail += " · HALTED"
        notes.append(f"the kind lane is HALTED: {KIND_HALT_STATE_CM} exists in "
                     f"{ARGOCD_NS}. Its workloads are at 0 and ArgoCD auto-sync is "
                     f"suspended on the Applications the halt recorded. "
                     f"`make kind-resume` (or Resume DevOps lane) puts them back.")
    elif halted is None:
        notes.append("whether the kind lane is HALTED could not be read, so Halt "
                     "and Resume are both offered; `make kind-halt-status` is the "
                     "authority. Unknown is not 'not halted'.")
    return LaneState(True, detail=detail, halted=halted), units, notes, errors


def _halt_record_present(node, kubectl: str, ctx: str, budget: _Budget) -> bool | None:
    """Is `make kind-halt`'s record on the cluster? True / False / **None**.

    None is not a formality. kind-halt.sh refuses (exit 5) when it cannot READ its
    own record, precisely because "the ConfigMap is absent" and "the API would not
    answer" are different answers and conflating them let a second halt overwrite a
    good record with an all-zero one. The GUI makes the same distinction: a read it
    could not take greys nothing and says so, rather than reporting 'not halted'.
    """
    if budget.remaining() <= 1:
        return None
    rc, out = _probe(node, [kubectl, "--context", ctx, "-n", ARGOCD_NS, "get",
                            "configmap", KIND_HALT_STATE_CM, "-o",
                            f"jsonpath={{.data.{KIND_HALT_STATE_KEY}}}"],
                     budget.bounded(KIND_HALT_READ_TIMEOUT_S))
    if rc == 0:
        return bool((out or "").strip())
    # NotFound is the ONE failure that means "there is no halt record".
    if "notfound" in (out or "").lower() or "not found" in (out or "").lower():
        return False
    return None


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


# The compose services TOR=1 starts (tests/stack/compose.local.yaml). Matched
# EXACTLY: a substring test for "tor" also caught hugmesh-tor-client (and would
# catch any future "*tor*" service, e.g. a "monitor"), and hung the onion on it.
_COMPOSE_ONION_SERVICE = "hugmesh-tor"
_COMPOSE_TOR_CLIENT_SERVICE = "hugmesh-tor-client"


def _domain_onions(node) -> list[tuple[str, str, str]]:
    """``[(domain label, slug, "https://<onion>/"), ...]`` — the PER-DOMAIN onions the
    running hugmesh-tor published (#582, decision 68 = A; ``LocalStackNode.
    onion_urls`` applies the #581 freshness rule). The label is the domain's NAME when
    the node knows it (``tor_domains``), else its slug. Never raises: a node object
    with no ``onion_urls`` (older callers, test doubles) has none."""
    try:
        urls = dict(node.onion_urls() or {})
    except Exception:                                 # noqa: BLE001
        return []
    names = {}
    for entry in (getattr(node, "tor_domains", None) or ()):
        try:
            names[str(entry[1])] = str(entry[0])
        except (IndexError, TypeError):
            continue
    return [(names.get(slug, slug), slug, str(url))
            for slug, url in sorted(urls.items()) if url]


#: Why a per-domain onion row will not start, stop or restart on its own.
_SHARED_TOR_REFUSAL = (
    "every onion is one HiddenService stanza in the SAME hugmesh-tor container, so "
    "stopping or restarting it here would take down every domain's onion, not just "
    "this one. Logs are that shared container's.")


def _domain_onion_units(tor_unit: "MeshUnit", onions) -> list["MeshUnit"]:
    """ONE row — one Door — per (domain, onion), each carrying THAT domain's login URL
    ``https://<onion>/login``. They are the SAME container as the hugmesh-tor row (one
    tor process, one HiddenService stanza per domain), so they share its phase and
    readiness and scale with it, never on their own.

    HTTPS, like the primary onion's door (``LocalStackNode.onion_url``): the onion's
    :443 is the door — a secure context, a Secure session cookie on a production-
    configured mesh, and the node agent's own port (docs/TOR-HIDDEN-SERVICE.md "Why
    :443"; the older CSP reason was false, #628). The Door has no URL for the same reason the primary has none — a
    normal browser cannot reach a .onion — and says where to open it instead."""
    out: list[MeshUnit] = []
    for label, slug, url in onions:
        login = url.rstrip("/") + "/login"
        out.append(MeshUnit(
            domain=label,
            domain_why=(f"its own onion, minted under the key directory {slug} "
                        f"(TOR_ONION_DOMAINS)"),
            control=UnitControl("container", tor_unit.control.name or tor_unit.name,
                                tor_unit.namespace, tuple(
                (v, _SHARED_TOR_REFUSAL) for v in ("start", "stop", "restart"))),
            lane=tor_unit.lane, namespace=tor_unit.namespace,
            name=f"{tor_unit.name} · {label} onion", owner=tor_unit.owner,
            phase=tor_unit.phase, ready=tor_unit.ready, reason=tor_unit.reason,
            state=tor_unit.state, cluster_path=tor_unit.cluster_path, external=login,
            door=Door(blocked=f"a normal browser cannot reach a .onion — open {login} "
                              f"in Tor Browser (the {label} sign-in)"),
            detail="\n".join([f"domain: {label}", f"onion key directory: {slug}",
                              f"login: {login}",
                              f"served by: the {tor_unit.owner or 'hugmesh-tor'} "
                              "container (one tor, one stanza per domain)"]),
            scale=ScaleTarget(refused=f"one onion of the {tor_unit.owner or 'tor'} "
                                      "container — it is not a workload of its own")))
    return out


def _is_compose_service(service: str, name: str, want: str) -> bool:
    """True when this row IS compose service ``want``: its service label, or — for
    a row that carries no label — a container name of compose's
    ``<project>-<service>-<n>`` shape."""
    if service:
        return service == want
    return re.fullmatch(r"(?:.+[-_])?%s[-_]\d+" % re.escape(want), name or "") is not None


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
        labels = _row_labels({"Labels": r.get("Labels")})
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
        status = r.get("Status") or ""
        row = {
            "Name": r.get("Names") or r.get("Name") or "",
            "Labels": labels,
            "Service": labels.get("com.docker.compose.service", ""),
            "State": str(r.get("State") or "").lower(),
            "Status": status,
            "Health": "",
            "Image": r.get("Image") or "",
            "Publishers": pubs,
        }
        # `docker ps --format {{json .}}` has no exit-code field of its own: it lives
        # only in the Status text ("Exited (137) 5 minutes ago"). Without it
        # _compose_units read 0 and showed a container that died non-zero as a clean
        # 'stopped (exit 0)' (#377).
        m = re.match(r"\s*Exited \((\d+)\)", str(status))
        if m:
            row["ExitCode"] = int(m.group(1))
        rows.append(row)
    return rows


_COMPOSE_SERVICES_HEAD = re.compile(r"^services:\s*(?:#.*)?$")
_COMPOSE_SERVICE_KEY = re.compile(r"^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*(?:#.*)?$")
_COMPOSE_RESTART_NO = re.compile(r"""^    restart:\s*(?:"no"|'no'|no)\s*(?:#.*)?$""")


def _compose_oneshot_services(compose_file: str) -> frozenset[str]:
    """Compose services the file itself declares as one-shots: ``restart: "no"``.

    Identified by what the service IS rather than by exit code, so a service that
    merely stopped cleanly (exit 0) still reads as down (Decision 99 = A, #378). A text
    scan, deliberately: Studio carries no YAML parser and ``tests/stack/compose.local.yaml``
    is generated and uniformly formatted (a test pins the scan against the real file).
    Any read failure is an EMPTY set, i.e. the conservative reading — nothing is
    hidden from the headline. ``services:`` children sit at two spaces, their keys at
    four."""
    if not compose_file:
        return frozenset()
    try:
        with open(compose_file, encoding="utf-8", errors="replace") as fh:
            lines = fh.read(2_000_000).splitlines()
    except OSError:
        return frozenset()
    out: set[str] = set()
    in_services = False
    current = ""
    for line in lines:
        if _COMPOSE_SERVICES_HEAD.match(line):
            in_services, current = True, ""
            continue
        if in_services and line and not line[0].isspace() and not line.startswith("#"):
            in_services, current = False, ""          # the next top-level key
        if not in_services:
            continue
        m = _COMPOSE_SERVICE_KEY.match(line)
        if m:
            current = m.group(1)
        elif current and _COMPOSE_RESTART_NO.match(line):
            out.add(current)
    return frozenset(out)


def _row_labels(row: dict) -> dict[str, str]:
    """A container's labels from either listing: ``docker compose ps --format json``
    carries them as ONE comma-joined ``k=v`` string, the ``docker ps`` fallback is
    already a dict. A label value holding a comma is cut there — no label this module
    reads (a compose service, a domain name) can hold one."""
    raw = row.get("Labels")
    if isinstance(raw, dict):
        return {str(k): str(v) for k, v in raw.items()}
    out: dict[str, str] = {}
    last = ""
    for kv in str(raw or "").split(","):
        if "=" in kv:
            k, v = kv.split("=", 1)
            last = k.strip()
            out[last] = v.strip()
        elif last and kv.strip():
            # compose's own multi-valued label (depends_on=a:…,b:…) was cut at its
            # commas by the join: the piece belongs to the label before it
            out[last] += "," + kv.strip()
    return out


def _depends_on(labels: dict[str, str]) -> tuple[str, ...]:
    """The compose services this container waits for, from compose's own
    ``com.docker.compose.depends_on`` label (``svc:condition:restart,…``)."""
    raw = labels.get("com.docker.compose.depends_on") or ""
    return tuple(p.split(":", 1)[0].strip() for p in raw.split(",")
                 if p.split(":", 1)[0].strip())


_COMPOSE_PROFILES_LINE = re.compile(r"^    profiles:\s*\[([^\]]*)\]\s*(?:#.*)?$")


def _compose_service_profiles(compose_file: str) -> dict[str, tuple[str, ...]]:
    """``{compose service: (profile, ...)}`` read from the compose file's directory:
    ``compose.local.yaml`` and every file it includes (``compose*.yaml``) plus the
    Studio's generated own-Casdoor overlay. The same uniformly formatted text scan as
    :func:`_compose_oneshot_services` (a test pins it against the real files); a read
    failure is an empty map, i.e. "no domain from config" — never a guess."""
    if not compose_file:
        return {}
    folder = os.path.dirname(compose_file)
    try:
        names = sorted(n for n in os.listdir(folder)
                       if (n.startswith("compose") or n.startswith(".compose"))
                       and n.endswith(".yaml"))
    except OSError:
        return {}
    out: dict[str, tuple[str, ...]] = {}
    for fn in names:
        try:
            with open(os.path.join(folder, fn), encoding="utf-8",
                      errors="replace") as fh:
                lines = fh.read(2_000_000).splitlines()
        except OSError:
            continue
        in_services = False
        current = ""
        for line in lines:
            if _COMPOSE_SERVICES_HEAD.match(line):
                in_services, current = True, ""
                continue
            if in_services and line and not line[0].isspace() and not line.startswith("#"):
                in_services, current = False, ""
            if not in_services:
                continue
            m = _COMPOSE_SERVICE_KEY.match(line)
            if m:
                current = m.group(1)
                continue
            m = _COMPOSE_PROFILES_LINE.match(line)
            if current and m:
                profs = tuple(p.strip().strip("'\"") for p in m.group(1).split(",")
                              if p.strip().strip("'\""))
                if profs:
                    out[current] = tuple(dict.fromkeys(out.get(current, ()) + profs))
    return out


def _profile_slugs() -> dict[str, tuple[str, ...]]:
    """``{compose profile: (local-service slug, ...)}`` from the services catalogue."""
    from . import local_services
    out: dict[str, tuple[str, ...]] = {}
    for slug in local_services.catalogue_slugs():
        svc = local_services.by_slug(slug)
        if svc is not None and svc.is_profile() and svc.profile:
            out[svc.profile] = out.get(svc.profile, ()) + (slug,)
    return out


#: WHICH services of a compose profile belong to the per-domain choice that brings
#: the profile up, for a profile that carries more than that choice's own
#: containers. ``{profile: {compose service: owning slug, or None}}``. None is a
#: COMPANION: it comes up with the profile but no domain chooses it, so it serves
#: every domain and no domain's Start / Stop / Restart touches it.
#:
#: The social profile is the one such profile today (tests/stack/compose.social-
#: profile.yaml + the two one-shots in compose.real.yaml): a domain ticks Matrix
#: (``tuwunel``), and the profile that ticks also starts the whole Mastodon tier.
#: Mastodon is NOT on any domain's Services tab — the per-domain ActivityPub choice
#: is ``akkoma``, which has its own profile and its own two containers — and the
#: Mastodon micro-frontend is one federation row every domain's shell shows. So the
#: Mastodon containers are shared, and a domain's Stop stops its Matrix only.
#: tests/test_mesh_pod_domains_attribution.py pins this table against the real
#: compose files: a service added to the profile goes red until it is placed here.
_PROFILE_SERVICE_OWNERS: dict[str, dict[str, str | None]] = {
    "social": {
        "tuwunel": "tuwunel",
        "mastodon-db": None, "mastodon-redis": None, "mastodon-web": None,
        "mastodon-sidekiq": None, "mastodon-streaming": None,
        "mastodon-init": None, "mastodon-autoconfirm": None,
    },
}


def _config_domain(service: str, profiles: dict, hints: DomainHints | None
                   ) -> tuple[str, tuple[str, ...], str]:
    """``(domain, shared_by, why)`` for a compose service no label names, from the
    Studio's own per-domain service choice. ("", (), "") when the config says nothing
    — the row is then shared by every domain. A profile COMPANION
    (``_PROFILE_SERVICE_OWNERS``) is shared with a reason saying which domains'
    choice brought it up."""
    if hints is None or not hints.service_domains or not service:
        return "", (), ""
    by_profile = _profile_slugs()
    chosen: list[str] = []
    slugs: list[str] = []
    companion_of: list[tuple[str, str]] = []          # (profile, slug)
    for prof in profiles.get(service, ()):
        owners = _PROFILE_SERVICE_OWNERS.get(prof)
        prof_slugs = by_profile.get(prof, ())
        if owners is not None and service in owners:
            owner = owners[service]
            if owner is None:
                companion_of.extend((prof, s) for s in prof_slugs
                                    if (prof, s) not in companion_of)
                continue
            prof_slugs = tuple(s for s in prof_slugs if s == owner)
        for slug in prof_slugs:
            if slug not in hints.service_domains:
                return "", (), ""         # chosen mesh-wide (or unknown): shared
            slugs.append(slug)
            for name in hints.service_domains.get(slug) or ():
                if name not in chosen:
                    chosen.append(name)
    if not slugs and companion_of:
        if any(s not in hints.service_domains for _p, s in companion_of):
            return "", (), ""             # the profile came up mesh-wide: shared
        by = list(dict.fromkeys(n for _p, s in companion_of
                                for n in (hints.service_domains.get(s) or ())))
        if not by:
            return "", (), ""
        profs = "/".join(dict.fromkeys(p for p, _s in companion_of))
        picks = "/".join(dict.fromkeys(s for _p, s in companion_of))
        return "", (), (f"part of the {profs} profile, which {', '.join(by)} turned on "
                        f"by choosing {picks}; no domain chooses {service} itself, so "
                        f"it is shared by every domain and no domain's Stop touches it")
    if not slugs or not chosen:
        return "", (), ""
    what = "/".join(dict.fromkeys(slugs))
    if len(chosen) == 1:
        return chosen[0], (), (f"started for {what}, which only {chosen[0]} chose on "
                               f"its Domain services step")
    return "", tuple(chosen), (f"started for {what}, which {', '.join(chosen)} chose "
                               f"on their Domain services steps — shared by them")


def _compose_units(node, generator_dir: str, catalog, live: dict, budget: _Budget, *,
                   kind_ports=(KIND_HTTPS_PORT_DEFAULT,),
                   hints: DomainHints | None = None,
                   onions_out: list | None = None
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
        # --all: EVERY container of the project (ask A), not only the running ones.
        # Without it the two one-shot `*-init-1` containers (exited 0) were missing
        # from a 43-container mesh, and — the part that matters — a service that
        # DIED non-zero vanished from the table while the title kept reading N/N
        # ready; the exited/dead branch below was unreachable.
        rc, out = _probe(node, [*base, "-f", compose_file, "ps", "--all",
                                "--format", "json"],
                         budget.bounded(COMPOSE_PS_TIMEOUT_S))
        if rc == 0:
            rows = _parse_compose_ps(out)
        if rows is None or (rc != 0):
            notes.append("`docker compose ps --format json` was rejected — rows come "
                         "from `docker ps` filtered by the compose project label")
            rows = None
    if rows is None and budget.remaining() > 1:
        rc, out = _probe(node, ["docker", "ps", "--all", "--filter",
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
    oneshots = (_compose_oneshot_services(compose_file)
                if any(str(r.get("State") or "").lower() in ("exited", "dead")
                       for r in rows) else frozenset())
    try:
        onion = str(node.onion_url() or "")
    except Exception:                                 # noqa: BLE001
        onion = ""
    domain_onions = _domain_onions(node)
    if onions_out is not None:
        if onion:
            own = (hints.own_domain if hints else "") or "this mesh's own domain"
            onions_out.append(OnionDoor(own, onion, onion.rstrip("/") + "/login",
                                        primary=True))
        for label, _slug, url in domain_onions:
            onions_out.append(OnionDoor(label, url, url.rstrip("/") + "/login"))
    profiles = (_compose_service_profiles(compose_file)
                if hints is not None and hints.service_domains else {})
    by_name = {d.name: d for d in (catalog or [])}
    units: list[MeshUnit] = []
    # Counted apart from the rows: a per-domain onion Door is a row of the same
    # hugmesh-tor container, not a container of its own.
    containers = 0
    for r in rows:
        containers += 1
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
            if state == "stopped" and service in oneshots:
                # a declared one-shot (`restart: "no"`) that ran to completion
                state = "completed"
                phase = f"completed (exit {exit_code})"
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
        elif onion and _is_compose_service(service, name, _COMPOSE_ONION_SERVICE):
            external_bits.append(onion)
            door = Door(blocked="a normal browser cannot reach a .onion — use the "
                                "'Copy .onion address' button and Tor Browser")
        elif _is_compose_service(service, name, _COMPOSE_TOR_CLIENT_SERVICE):
            # The SOCKS5 client the Tor e2e lane dials the onion through. It is
            # NOT the onion: attributing the .onion (or the Tor Browser hint) to
            # this row would point a person at a proxy port as if it were the door.
            door = Door(blocked="a SOCKS5 proxy into Tor for the e2e lane "
                                "(make stack-e2e-tor), not a web page — the onion "
                                f"itself is the {_COMPOSE_ONION_SERVICE} row")
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
        labels = _row_labels(r)
        label_dom = str(labels.get(DOMAIN_LABEL) or "").strip()
        shared_by: tuple[str, ...] = ()
        if label_dom:
            domain = label_dom
            domain_why = f"container label {DOMAIN_LABEL}={label_dom}"
        else:
            domain, shared_by, domain_why = _config_domain(service, profiles, hints)
            if not domain_why:
                domain_why = ("no hugmesh.net/domain label and no single domain chose "
                              "it: shared by every domain")
        if domain or shared_by:
            udetail += "\ndomain: " + (domain or ", ".join(shared_by)) + \
                f" ({domain_why})"
        if name:
            refusals: tuple[tuple[str, str], ...] = ()
            if _is_compose_service(service, name, _COMPOSE_ONION_SERVICE) and \
                    domain_onions:
                refusals = tuple((v, _SHARED_TOR_REFUSAL)
                                 for v in ("start", "stop", "restart"))
            control = UnitControl("container", name, _COMPOSE_PROJECT, refusals,
                                  service=service, depends_on=_depends_on(labels))
        else:
            control = UnitControl()
        units.append(MeshUnit(
            domain=domain, shared_by=shared_by, domain_why=domain_why,
            control=control,
            lane="compose", namespace=_COMPOSE_PROJECT, name=name or service,
            owner=service, phase=phase, ready=ready, reason=reason, state=state,
            cluster_path=cluster_path, external="; ".join(external_bits), door=door,
            detail=udetail,
            # The compose SERVICE is the scalable thing; a container is one instance
            # of it. A row with no service label came from `docker ps` on the project
            # label alone and there is nothing to name in `--scale`.
            scale=(ScaleTarget("compose-service", service, _COMPOSE_PROJECT, refused="")
                   if service else
                   ScaleTarget(refused="this container carries no compose service "
                                       "label, so there is no service to scale"))))
        if domain_onions and _is_compose_service(service, name, _COMPOSE_ONION_SERVICE):
            units.extend(_domain_onion_units(units[-1], domain_onions))
    if not units:
        notes.append("the compose project reports running but listed zero containers")
    bits = [f"project {_COMPOSE_PROJECT}", f"{containers} container(s)"]
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
        catalog = view_doors.load_with_generated(generator_dir, env)
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
             env=None, hints: DomainHints | None = None) -> MonitorSnapshot:
    """Read both lanes. NEVER raises — every failure is a sentence in the result.
    ``hints`` (:func:`domain_hints`) lets rows no label names take a domain from the
    Studio's own per-domain choices; None leaves them to their labels."""
    onions: list[OnionDoor] = []
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
                                           stale_view=stale, kind_ports=kind_ports,
                                           hints=hints)
            units.extend(ku)
            notes.extend(kn)
            errors.extend(ke)
        except Exception as exc:                      # noqa: BLE001 — never raise
            kind = LaneState(None, error=f"the kind lane read failed: "
                                         f"{type(exc).__name__}: {exc}")
    if want_compose:
        try:
            compose, cu, cn, ce = _compose_units(node, generator_dir, catalog, live,
                                                 budget, kind_ports=kind_ports,
                                                 hints=hints, onions_out=onions)
            units.extend(cu)
            notes.extend(cn)
            errors.extend(ce)
        except Exception as exc:                      # noqa: BLE001 — never raise
            compose = LaneState(None, error=f"the compose lane read failed: "
                                            f"{type(exc).__name__}: {exc}")
    for lane_name, lane in (("kind", kind), ("compose", compose)):
        if lane.running is None and lane.error:
            errors.append(f"{lane_name}: {lane.error}")
    view_lane = ""
    if live:
        notes.append("a browser door answering 401 is NOT down — a stale pre-rebuild "
                     "session cookie 401s the page while the door itself is fine; "
                     "sign out and back in")
        try:
            view_lane = str(view_doors.live_session(generator_dir, env).get("lane")
                            or "")
        except Exception:                             # noqa: BLE001 — a name, not a fact
            view_lane = ""
    units = _name_kind_slugs(units, hints)
    units.sort(key=lambda u: (u.lane, u.namespace, u.name))
    return MonitorSnapshot(
        taken_at=time.strftime("%H:%M:%S"), compose=compose, kind=kind,
        units=tuple(units), errors=tuple(errors), notes=tuple(notes),
        view_doors=tuple(sorted(live)), view_lane=view_lane, onions=tuple(onions))


def _name_kind_slugs(units: list[MeshUnit], hints: DomainHints | None
                     ) -> list[MeshUnit]:
    """Give a kind pod that is still labelled with its domain's SLUG the domain's
    NAME, when anything else in the same read names it.

    Why a last pass: the kind lane is read first, and a mount with no Studio config
    (the qemu and mesh-emulation pages pass no hints) then left ``acme-example`` on
    the pod while the compose rows read ``acme.example`` — one domain, two entries in
    the domain picker, and each entry's buttons acting on half of its rows. The names
    come from what was actually read: a compose row's domain (its own
    ``hugmesh.net/domain`` label or the Studio's choice), a per-domain onion's label,
    and ``hints.names``. The slug of a name is ``own_casdoor.slug`` — the same rule
    the per-domain overlay and the ApplicationSet element use. Never raises."""
    try:
        from .own_casdoor import slug as _slug
        named: dict[str, tuple[str, str]] = {}
        for key, name in ((hints.names if hints else {}) or {}).items():
            if key and name and key != name:
                named.setdefault(str(key), (str(name), "the Studio's domain list"))
        for u in units:
            if u.lane == "kind" or not u.domain:
                continue
            s = _slug(u.domain)
            if s and s != u.domain:
                named.setdefault(s, (u.domain, f"the {u.lane} row {u.name}"))
        if not named:
            return units
        out: list[MeshUnit] = []
        for u in units:
            hit = named.get(u.domain) if u.lane == "kind" and u.domain else None
            if hit is None or hit[0] == u.domain:
                out.append(u)
                continue
            name, source = hit
            why = f"{u.domain_why} (the domain {name}, named by {source})"
            out.append(replace(u, domain=name, domain_why=why,
                               detail=(u.detail + "\n" if u.detail else "")
                               + f"domain name: {name} (slug {u.domain}, named by "
                                 f"{source})"))
        return out
    except Exception:                                 # noqa: BLE001 — a label, not a fact
        return units


def domain_hints(cfg) -> DomainHints:
    """The Studio config's half of "which domain does this row serve" — see
    :class:`DomainHints`. ``cfg`` is a LocalMeshBootstrapConfig (or anything with its
    ``domains`` / ``services`` / ``cluster_domain`` fields). NEVER raises: a config it
    cannot read gives empty hints, and rows then fall back to their labels."""
    if cfg is None:
        return DomainHints()
    try:
        from . import local_services, own_casdoor, brand_model
        mesh_wide = set(local_services.split_selection(
            getattr(cfg, "services", None))[0])
        if getattr(cfg, "services", None) is None and getattr(cfg, "social", False):
            mesh_wide.add("tuwunel")      # the legacy SOCIAL flag runs it mesh-wide
        rows = [r for r in (getattr(cfg, "domains", None) or ()) if isinstance(r, dict)]
        service_domains: dict[str, tuple[str, ...]] = {}
        for slug in local_services.domain_local_slugs():
            if slug in mesh_wide:
                continue                  # a mesh-wide pick runs for every domain
            names = tuple(str(r.get("name") or "").strip() for r in rows
                          if slug in (r.get("optional_services") or ())
                          and str(r.get("name") or "").strip())
            if names:                     # nobody chose it: nothing to say
                service_domains[slug] = names
        names: dict[str, str] = {}
        for r in rows:
            n = str(r.get("name") or "").strip()
            if not n:
                continue
            names.setdefault(own_casdoor.slug(n), n)
            names[brand_model.brand_id(r)] = n
        own = ""
        try:
            own = (str(getattr(cfg, "cluster_domain", "") or "").strip()
                   or str(cfg.resolved_domain() or ""))
        except Exception:                             # noqa: BLE001
            own = ""
        return DomainHints(service_domains=service_domains, names=names,
                           own_domain=own)
    except Exception:                                 # noqa: BLE001 — hints, not facts
        return DomainHints()


def wizard_hints(local_cfg=None, domains=()) -> DomainHints:
    """Hints for a mount that has no local-mesh config of its own — the qemu and
    mesh-emulation pages, which read the SAME compose project and kind cluster as the
    local-mesh page. ``local_cfg`` is that page's LocalMeshBootstrapConfig when the
    window has one (so both mounts of one table say the same thing); ``domains`` are
    the wizard's own Domains rows (``Domain`` objects or dicts), which add their
    names so a kind pod's slug reads as its domain. NEVER raises."""
    base = domain_hints(local_cfg) if local_cfg is not None else DomainHints()
    names = dict(base.names)
    try:
        from .own_casdoor import slug as _slug
        for d in domains or ():
            n = d.get("name") if isinstance(d, dict) else getattr(d, "name", "")
            n = str(n or "").strip()
            if n:
                names.setdefault(_slug(n), n)
    except Exception:                                 # noqa: BLE001 — hints, not facts
        pass
    return DomainHints(service_domains=dict(base.service_domains), names=names,
                       own_domain=base.own_domain)


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


# ── scaling ────────────────────────────────────────────────────────────────────────
# The monitor stopped being read-only here, and the rules that keeps are the ones the
# rest of this module already lives by:
#
#   * NOTHING is derived twice. The workload a press drives is the ScaleTarget the
#     snapshot already carries (``_pod_scale_target`` / the compose service label), so
#     the row an operator is looking at and the object the verb touches cannot drift
#     apart between the paint and the press.
#   * A REFUSAL IS A SENTENCE, never a silent no-op. Every path that cannot run returns
#     the reason, and the GUI shows it on the row.
#   * NOTHING HERE RAISES. This is called from a worker thread whose only contract is
#     to emit (ok, text); an exception escaping it would leave the busy guard latched.
#
# The two lanes differ in a way worth stating: ``kubectl scale`` writes a spec and
# returns, so its "ok" means the ASK landed, not that the pods are up. ``docker compose
# up --scale`` actually starts (or stops) containers before it returns. Both answers go
# to the same status line, so the line says which verb ran.

def replicas_now(units, target: ScaleTarget) -> int:
    """How many rows in this snapshot are instances of ``target``.

    Counted from the rows themselves rather than by asking the API a second question.
    That answers a subtly different question than "what does the spec say", and the
    difference is the honest one to show beside a live table: a Deployment scaled to 3
    whose third pod is still Pending reads 3 here, and one scaled to 3 whose pod was
    just deleted reads 2 for the seconds in between — which is what the table is
    showing anyway.

    Rows in the terminal ``stopped`` / ``completed`` states are NOT counted: a Succeeded pod and an
    exited compose one-shot are finished work, not running replicas, and counting them
    would make a "+1" from the GUI hand compose a number it would immediately undo.
    """
    if not target.scalable:
        return 0
    rows = getattr(units, "units", units) or ()
    return sum(1 for u in rows
               if u.scale.key == target.key and u.state not in ("stopped", "completed"))


def scale_argv(unit: MeshUnit, replicas: int, *, generator_dir: str,
               node=None) -> tuple[list[str], str]:
    """``(argv, refusal)`` for scaling ``unit`` to ``replicas``. One of the two is
    always empty. Pure — builds a command, runs nothing."""
    try:
        n = int(replicas)
    except (TypeError, ValueError):
        return [], f"{replicas!r} is not a replica count"
    if n < 0:
        return [], "a replica count cannot be negative"
    if n > MAX_REPLICAS:
        return [], (f"{n} is past this table's ceiling of {MAX_REPLICAS} — the "
                    f"control guards against a mis-click, not against your judgement; "
                    f"use kubectl or compose directly for more")
    target = unit.scale
    if not target.scalable:
        return [], (target.refused or "this row carries no scalable workload")
    if target.kind == "compose-service":
        base = _compose_base()
        if not base:
            return [], ("neither `docker compose` nor `docker-compose` is available — "
                        "the compose lane cannot be scaled from here")
        compose_file = str(getattr(node, "compose_file", "") or "")
        if not compose_file:
            return [], ("the stack node does not name a compose file, so a scale would "
                        "have to guess which project it is talking to")
        # -p PINS the project: the same name the rows were listed under
        # (com.docker.compose.project), so a scale can never land in a second project
        # that happens to share a compose file. --no-recreate leaves the containers
        # that are already up alone — without it, `up` re-creates every listed
        # container, which restarts a healthy mesh to change one service's count.
        # --no-deps keeps the blast radius to the named service.
        #
        # A stack with Tor domains was brought up with one more compose file (#582:
        # ``LocalStackNode.tor_domains_overlay``). A replica created WITHOUT it would
        # be an fe-gateway with no onion host map — it would serve every onion as the
        # default brand while its siblings refuse the unregistered ones — so the scale
        # loads the same file. "" (every stack with no Tor domain) adds nothing.
        overlay = str(getattr(node, "tor_domains_overlay", "") or "")
        return ([*base, "-p", _COMPOSE_PROJECT, "-f", compose_file,
                 *(("-f", overlay) if overlay else ()), "up", "-d",
                 "--no-deps", "--no-recreate", "--scale", f"{target.name}={n}",
                 target.name], "")
    kubectl = devops_tools.which("kubectl", generator_dir)
    if not kubectl:
        return [], ("kubectl is not installed — press 'Install DevOps prerequisites' "
                    "on the local-mesh page")
    cluster = _kind_cluster_name()
    return ([kubectl, "--context", f"kind-{cluster}", "scale",
             f"{target.kind}/{target.name}", "-n", target.namespace,
             f"--replicas={n}"], "")


def scale(generator_dir: str, node, unit: MeshUnit, replicas: int, *,
          timeout_s: int = SCALE_TIMEOUT_S) -> tuple[bool, str]:
    """Run one scale. ``(ok, one line of text)`` — NEVER raises, never blocks the
    caller's thread for longer than ``timeout_s``.

    ``ok`` is the verb's exit status and nothing more. On the kind lane that means the
    Deployment's spec now says ``replicas: n``; whether n pods reach Ready is the
    monitor's next refresh to answer, and the text says so rather than claiming it.
    """
    argv, refused = scale_argv(unit, replicas, generator_dir=generator_dir, node=node)
    if refused:
        return False, refused
    rc, out = _probe(node, argv, max(1, int(timeout_s)))
    what = unit.scale.describe()
    text = (out or "").strip()
    if rc != 0:
        why = f"scaling {what} to {replicas} failed: {text[:400] or 'no output'}"
        # A TIMEOUT ON THE COMPOSE LANE IS USUALLY A BUILD, NOT A HANG. Every
        # first-party service in tests/stack/compose.local.yaml is `build:`-ed from
        # ${STACK_SRC}, so `up --scale` on a service whose image is not present
        # BUILDS it first, which can far exceed SCALE_TIMEOUT_S. Left as the bare
        # TimeoutExpired string, that reads as a broken daemon. Say the likelier thing
        # — and say that the build is still going, because it is: the timeout killed
        # this wait, not that work.
        if unit.scale.kind == "compose-service" and "Timeout" in text:
            why += (f" — this waited {int(timeout_s)}s. If this service's image is not "
                    f"built yet, `up` is BUILDING it and is still running in the "
                    f"background; watch `docker compose -p {_COMPOSE_PROJECT} logs` "
                    f"or bring the stack up first, then scale.")
        return False, why
    if unit.scale.kind == "compose-service":
        return True, (f"compose scaled {what} to {replicas}"
                      + (f" — {text.splitlines()[-1][:200]}" if text else ""))
    return True, (f"asked for {replicas} replica(s) of {what}; the table shows how "
                  f"many are actually up on the next refresh"
                  + (f" ({text.splitlines()[-1][:200]})" if text else ""))
