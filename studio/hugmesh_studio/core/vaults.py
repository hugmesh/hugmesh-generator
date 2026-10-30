"""Vault entries + managed volumes for a mesh the Studio started.

OPERATOR ASK (2026-08-14): "add a vaults management menu button and modal display menu
which lets a studio user who started a mesh locally or with qemu emulation manage
entries in vault and managed volumes".

TWO SUBJECTS, ONE DIALOG, AND THEY DO NOT LIVE IN THE SAME PLACE — which is the whole
reason this module exists instead of a couple of inline docker calls:

* MANAGED VOLUMES are the docker volumes the compose project owns. They exist the moment
  a local mesh is up, they are enumerable without any credential, and they are where the
  mesh's DURABLE state actually sits (16 of them on the shipped stack: every BFF's
  postgres, cassandra, the mastodon/akkoma uploads, the federation bundles). Deleting one
  destroys data that no rebuild restores, so this module never deletes an IN-USE volume
  and makes the caller pass an explicit confirmation for the rest.

* VAULT ENTRIES come from HashiCorp Vault, which on this platform is a CLUSTER app
  (specs/cluster/apps/02-vault.yaml) on the DevOps/Kubernetes lane. It is NOT part of the
  docker compose stack — `docker ps` on a running local mesh shows no vault container at
  all. So the entries are read from the kind lane's vault-0 (through `kubectl exec`)
  when that lane is up, and when it is not — or is halted, or Vault is sealed — the
  answer is never an empty list (which reads as "vault is empty, add something") but
  the exact reason and how to fix it: the same informational-row idiom
  local_services.py uses for the DevOps-lane services, for the same reason: a control
  that cannot act must say so rather than pretend. See the "vault entries" section.

SECRET HANDLING. Listing returns key NAMES and metadata only; a value is fetched solely
on an explicit, per-entry request. No value is ever logged, and no token or value is ever
passed on a COMMAND LINE — argv is world-readable via /proc on a shared box — so the
Vault token travels in the child's environment and a written value travels on stdin.

BLOCKING BY CONTRACT. Every function here shells out to docker with a timeout and must
therefore be called OFF the GUI thread (see the _StatusProbe/own_probe idiom in
gui/pages/_widgets.py). `docker volume` calls are fast, but a hung daemon blocks each
for its full timeout, and this module is reached from a dialog the operator opened.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
from dataclasses import dataclass, field

from . import proc_text

#: The compose project a Studio-started local mesh uses.
DEFAULT_PROJECT = "hugmesh-local"

#: Per-call docker timeout. Matches the local_stack_node convention.
_DOCKER_TIMEOUT = 30

#: Compose's own labels — the authoritative way to tell a mesh volume from any other
#: volume on the machine. Matching on the NAME PREFIX instead would sweep in anything a
#: user happened to name similarly, and this module offers a delete.
_LBL_PROJECT = "com.docker.compose.project"
_LBL_VOLUME = "com.docker.compose.volume"


@dataclass(frozen=True)
class ManagedVolume:
    """One docker volume owned by the mesh's compose project."""

    name: str                      # hugmesh-local_admin-bff-pg
    short: str                     # admin-bff-pg (the compose volume key)
    mountpoint: str
    driver: str = "local"
    size_bytes: int | None = None  # None = not reported by this docker
    in_use_by: tuple[str, ...] = ()

    @property
    def in_use(self) -> bool:
        return bool(self.in_use_by)

    def human_size(self) -> str:
        if self.size_bytes is None:
            return "—"
        n = float(self.size_bytes)
        for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
            if n < 1024 or unit == "TiB":
                return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
            n /= 1024
        return f"{n:.1f} TiB"


@dataclass(frozen=True)
class VaultEntry:
    """One Vault KV path. ``keys`` are NAMES only — values are fetched on demand."""

    path: str
    keys: tuple[str, ...] = ()


@dataclass(frozen=True)
class Capability:
    """Whether a subject can be managed here, and if not, WHAT TO DO — never a bare
    'unavailable'. Mirrors platform_info.HostInfo.flash_blocker()'s contract, because the
    failure mode is identical: a control that silently does nothing sends the operator
    looking for a fault that is not there."""

    available: bool
    detail: str = ""
    remedy: str = ""


def _run(args: list[str], *, env: dict[str, str] | None = None,
         stdin: str | None = None, timeout: int = _DOCKER_TIMEOUT):
    """One docker/CLI call. Never raises on a non-zero exit — callers turn a failure into
    an honest Capability rather than a traceback in a dialog.

    BYTES on the pipes, decoded here: a text-mode stdin on Windows writes every "\\n" as
    "\\r\\n", so the token line the in-pod shell reads ended in "\\r" and every Vault call
    over the kind route was refused as a bad token."""
    try:
        r = subprocess.run(
            args, capture_output=True, timeout=timeout,
            input=None if stdin is None else stdin.encode("utf-8"),
            env={**os.environ, **(env or {})},
        )
        def text(b: bytes) -> str:        # what text=True's universal newlines did
            return b.decode(**proc_text.TEXT_IO).replace("\r\n", "\n").replace("\r", "\n")
        return subprocess.CompletedProcess(args, r.returncode, text(r.stdout),
                                           text(r.stderr))
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(args, 1, "", f"{type(e).__name__}: {e}")


# ── managed volumes ────────────────────────────────────────────────────────────────
def docker_available() -> Capability:
    r = _run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=8)
    if r.returncode == 0:
        return Capability(True)
    return Capability(
        False,
        detail="the docker daemon is not reachable",
        remedy="Start Docker (or, under WSL, enable Docker Desktop's WSL integration "
               "for this distro) and reopen this dialog.")


class DockerDidNotAnswer(RuntimeError):
    """``docker volume ls`` exited non-zero / timed out / could not be run: the volume
    list is UNKNOWN, which is not the same thing as EMPTY (#361)."""


def list_volumes(project: str = DEFAULT_PROJECT, *, strict: bool = False
                 ) -> list[ManagedVolume]:
    """Every volume the mesh's compose project owns, newest-name-order stable.

    Selected by compose LABEL, not by name prefix: this module offers a delete, and a
    name-prefix match would happily sweep in an unrelated volume someone named similarly.

    A failed ``docker volume ls`` returns ``[]`` (the dialogs render "none") unless
    ``strict`` — then it raises :class:`DockerDidNotAnswer`, for a caller whose answer
    is a claim about the operator's data and must tell "docker said none" from "docker
    could not say" (the saved-mesh probe).
    """
    r = _run(["docker", "volume", "ls", "--filter", f"label={_LBL_PROJECT}={project}",
              "--format", "{{.Name}}"])
    if r.returncode != 0:
        if strict:
            raise DockerDidNotAnswer((r.stderr or "docker volume ls failed").strip()[:200])
        return []
    names = [n.strip() for n in r.stdout.splitlines() if n.strip()]
    if not names:
        return []

    sizes = _volume_sizes()
    users = _volume_users()
    out: list[ManagedVolume] = []
    for name in sorted(names):
        insp = _run(["docker", "volume", "inspect", name, "--format",
                     "{{json .}}"])
        short, mount, driver = name, "", "local"
        if insp.returncode == 0 and insp.stdout.strip():
            try:
                d = json.loads(insp.stdout.strip())
                mount = d.get("Mountpoint") or ""
                driver = d.get("Driver") or "local"
                short = (d.get("Labels") or {}).get(_LBL_VOLUME) or name
            except (ValueError, AttributeError):
                pass
        out.append(ManagedVolume(
            name=name, short=short, mountpoint=mount, driver=driver,
            size_bytes=sizes.get(name), in_use_by=tuple(users.get(name, ())),
        ))
    return out


def _volume_sizes() -> dict[str, int]:
    """Volume -> bytes, from `docker system df -v`.

    Best-effort ON PURPOSE: the size field is absent on some docker versions and the
    whole call is slow on a large install, so a missing entry becomes None ("—") rather
    than a hard failure. Never `du` the mountpoint as a fallback — it lives under the
    docker data-root, which is root-owned, and a PermissionError there would read as
    "the volume is empty"."""
    r = _run(["docker", "system", "df", "-v", "--format", "{{json .}}"], timeout=60)
    if r.returncode != 0 or not r.stdout.strip():
        return {}
    try:
        doc = json.loads(r.stdout.strip().splitlines()[0])
    except (ValueError, IndexError):
        return {}
    sizes: dict[str, int] = {}
    for v in doc.get("Volumes") or []:
        name = v.get("Name")
        raw = v.get("Size")
        if not name or not raw:
            continue
        parsed = _parse_size(str(raw))
        if parsed is not None:
            sizes[name] = parsed
    return sizes


_UNITS = {"B": 1, "KB": 10**3, "MB": 10**6, "GB": 10**9, "TB": 10**12,
          "KIB": 1 << 10, "MIB": 1 << 20, "GIB": 1 << 30, "TIB": 1 << 40}


def _parse_size(raw: str) -> int | None:
    """docker prints human sizes ("1.234GB", "0B", "N/A"). Return bytes, or None."""
    s = raw.strip().upper().replace(" ", "")
    if not s or s in ("N/A", "-"):
        return None
    for unit in sorted(_UNITS, key=len, reverse=True):
        if s.endswith(unit):
            try:
                return int(float(s[: -len(unit)]) * _UNITS[unit])
            except ValueError:
                return None
    try:
        return int(float(s))
    except ValueError:
        return None


def _volume_users() -> dict[str, list[str]]:
    """Volume -> the containers mounting it, INCLUDING stopped ones.

    Stopped containers count: a stopped mesh still owns its data, and deleting a volume
    because nothing is currently running would destroy exactly the state the operator
    intends to start again."""
    r = _run(["docker", "ps", "-a", "--format", "{{.Names}}"])
    if r.returncode != 0:
        return {}
    users: dict[str, list[str]] = {}
    for cname in [c.strip() for c in r.stdout.splitlines() if c.strip()]:
        m = _run(["docker", "inspect", cname, "--format",
                  "{{range .Mounts}}{{if eq .Type \"volume\"}}{{.Name}}\n{{end}}{{end}}"])
        if m.returncode != 0:
            continue
        for vol in [v.strip() for v in m.stdout.splitlines() if v.strip()]:
            users.setdefault(vol, []).append(cname)
    return users


def remove_volume(volume: ManagedVolume, *, confirm: bool = False) -> Capability:
    """Delete a managed volume. DESTRUCTIVE and deliberately awkward.

    Two independent guards, because the two failure modes are different:
      * IN USE -> refused outright. Docker would refuse anyway, but refusing here lets
        the dialog say WHICH containers hold it instead of surfacing a daemon error.
      * confirm=False -> refused. The caller must have actually asked. A volume here is
        a BFF's postgres or the mastodon uploads; no rebuild restores it, and there is no
        undo.
    """
    if volume.in_use:
        return Capability(
            False,
            detail=f"{volume.short} is in use by {', '.join(volume.in_use_by)}",
            remedy="Stop the mesh first — deleting a volume out from under a running "
                   "container is refused by docker and would corrupt its state anyway.")
    if not confirm:
        return Capability(False, detail="deletion needs an explicit confirmation",
                          remedy="Re-issue with confirm=True once the operator has "
                                 "acknowledged the data loss.")
    r = _run(["docker", "volume", "rm", volume.name])
    if r.returncode == 0:
        return Capability(True, detail=f"removed {volume.name}")
    return Capability(False, detail=(r.stderr or "docker volume rm failed").strip(),
                      remedy="Check that no container still references it.")


# ── vault entries ──────────────────────────────────────────────────────────────────
#
# WHERE VAULT IS, AND HOW THIS STUDIO REACHES IT (2026-10-21).
#
# Operator report: "the vaults can never be viewed even when the kind lane is up". Two
# stacked causes, both measured that day:
#
# 1. This module only ever asked `docker ps` for a compose vault container and looked at
#    $VAULT_ADDR. Vault does not live in the compose stack — it is vault-0 in namespace
#    `vault` on the kind cluster — so the kind lane was never consulted and the tab said
#    "Vault is not running on this mesh" whatever the cluster was doing.
# 2. Even past that check, every read ran a bare host `vault` binary, which this kind of
#    host does not have; the kind lane's own tooling (bootstrap-kind.sh's exec shim,
#    kind_seed.casdoor_admin_password) talks to Vault through `kubectl exec` into
#    vault-0 instead.
#
# So there are now TWO ROUTES, picked in this order:
#
#   host  $VAULT_ADDR is set, or a compose vault container is running: the host `vault`
#         CLI with $VAULT_TOKEN from the environment (the previous behaviour, unchanged).
#   kind  otherwise: the kind lane's vault-0, reached with `kubectl exec`, using the
#         lane's own bootstrap token from Secret vault/vault-bootstrap.
#
# The kind route answers with the EXACT reason when it cannot be used — lane not up,
# lane halted (and since when), Vault not deployed, vault-0 sealed or crash-looping, no
# token — because an empty table reads as "vault is running and empty".
#
# READ-ONLY TOWARDS THE CLUSTER while probing: only `get` calls, and the token Secret is
# read LAST, after vault-0 is known to be Ready, so a halted or sealed lane never has its
# token pulled into this process at all.
#
# THE TOKEN NEVER TRAVELS ON A COMMAND LINE. The repo's earlier exec pattern put
# `VAULT_TOKEN=<token>` into kubectl's argv, which is world-readable through /proc on the
# host. Here the token is the FIRST LINE OF STDIN and a tiny in-pod shell reads it into
# the environment before exec'ing vault; a written value follows it on stdin.

#: KV v2 mount bootstrap-kind.sh enables (`vault secrets enable -path=secret -version=2 kv`).
KV_MOUNT = "secret"
VAULT_NS = "vault"
VAULT_POD = "vault-0"
VAULT_STS = "vault"
VAULT_CONTAINER = "vault"
#: The Secret bootstrap-kind.sh stores the lane's Vault token in (key ``token``).
VAULT_TOKEN_SECRET = "vault-bootstrap"
VAULT_TOKEN_KEY = "token"
#: Where scripts/kind-halt.sh records a halt (ARGOCD_NS / STATE_CM / STATE_KEY there).
HALT_NS = "devops"
HALT_CM = "hugmesh-kind-halt"
HALT_KEY = "halt.json"

#: Bounds for one kubectl read. --request-timeout makes a dead API server fail fast
#: instead of waiting out the subprocess timeout.
_KUBE_TIMEOUT = 25
_KUBE_REQUEST_TIMEOUT = "--request-timeout=15s"
#: The recursive listing stops after this many `kv list` calls and says so.
MAX_LIST_CALLS = 40

#: The in-pod shell for the kind route: token from the first stdin line into the
#: environment, then vault with the caller's args ("$@" — never interpolated, so a path
#: cannot inject shell). VAULT_ADDR/VAULT_CACERT are already set in the vault
#: container's own env (https://127.0.0.1:8200, a cert with IP:127.0.0.1 in its SAN), so
#: TLS is verified rather than skipped.
_EXEC_SH = 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"'

ROUTE_HOST = "host"
ROUTE_KIND = "kind"

_REMEDY_START_LANE = (
    "Vault runs on the DevOps (kind) lane, not in the docker mesh. Start that lane "
    "('Start DevOps lane' on the local-mesh page, or `make kind-up`), or point "
    "VAULT_ADDR at an existing Vault.")


@dataclass(frozen=True)
class VaultRoute:
    """How this Studio reaches Vault right now, or exactly why it cannot.

    ``token`` is excluded from repr so a route printed into a log or a test failure does
    not carry it."""

    route: str                     # ROUTE_HOST | ROUTE_KIND | "" (none usable)
    cap: Capability
    context: str = ""              # kube context (kind route)
    kubectl: str = ""
    token: str = field(default="", repr=False)


def kind_cluster_name() -> str:
    """The kind cluster the DevOps lane drives — the same KIND_CLUSTER_NAME override
    bootstrap-kind.sh and local_stack_node read, with the same default."""
    return os.environ.get("KIND_CLUSTER_NAME", "").strip() or "hugmesh-local"


def _kubectl_path() -> str:
    try:
        from . import devops_tools
        return devops_tools.which("kubectl", "") or ""
    except Exception:                                    # noqa: BLE001
        import shutil
        return shutil.which("kubectl") or ""


def _first_line(text: str, limit: int = 200) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:limit]
    return ""


def _not_found(stderr: str) -> bool:
    s = (stderr or "")
    return "NotFound" in s or "not found" in s


def _host_route(project: str) -> VaultRoute | None:
    """The previous behaviour: $VAULT_ADDR or a compose vault container + $VAULT_TOKEN.
    None when neither is there, so the caller falls through to the kind lane."""
    addr = os.environ.get("VAULT_ADDR", "").strip()
    r = _run(["docker", "ps", "--filter", f"label={_LBL_PROJECT}={project}",
              "--filter", "name=vault", "--format", "{{.Names}}"])
    running = [n for n in r.stdout.splitlines() if n.strip()] if r.returncode == 0 else []
    if not running and not addr:
        return None
    token = os.environ.get("VAULT_TOKEN", "").strip()
    if not token:
        return VaultRoute("", Capability(
            False,
            detail="Vault is reachable but this Studio holds no token.",
            remedy="Export VAULT_TOKEN (it is read from the environment and never "
                   "written to disk, logged, or passed on a command line)."))
    return VaultRoute(ROUTE_HOST, Capability(True, detail=f"vault at {addr or running[0]}"),
                      token=token)


def _halt_reason(kubectl: str, ctx: str) -> str:
    """Why vault's StatefulSet is at 0, from kind-halt.sh's own record. '' = no record."""
    r = _run([kubectl, "--context", ctx, _KUBE_REQUEST_TIMEOUT, "-n", HALT_NS, "get",
              "configmap", HALT_CM, "-o",
              "jsonpath={.data." + HALT_KEY.replace(".", "\\.") + "}"],
             timeout=_KUBE_TIMEOUT)
    if r.returncode != 0 or not (r.stdout or "").strip():
        return ""
    try:
        rec = json.loads(r.stdout)
    except ValueError:
        return f"a halt record exists ({HALT_NS}/{HALT_CM}) but could not be parsed"
    when = rec.get("halted_at") or "an unrecorded time"
    if rec.get("completed") is False:
        return (f"a DevOps-lane halt started at {when} and was interrupted "
                f"(record {HALT_NS}/{HALT_CM}, completed: false)")
    return f"the DevOps lane is HALTED (since {when}, record {HALT_NS}/{HALT_CM})"


def _kind_route() -> VaultRoute:
    """vault-0 on the kind lane — each step a read, each failure its own reason."""
    cluster = kind_cluster_name()
    ctx = f"kind-{cluster}"

    up = _run(["docker", "ps", "--filter", f"name=^{cluster}-control-plane$",
               "--format", "{{.Names}}"], timeout=8)
    if up.returncode != 0:
        return VaultRoute("", Capability(
            False,
            detail=("Docker did not answer, so whether the DevOps lane is up is unknown "
                    f"({_first_line(up.stderr) or 'docker ps failed'})."),
            remedy="Start Docker and press Refresh."))
    if not (up.stdout or "").strip():
        return VaultRoute("", Capability(
            False,
            detail=(f"Vault is not running: the DevOps (kind) lane is not up — there is "
                    f"no '{cluster}-control-plane' container."),
            remedy=_REMEDY_START_LANE))

    kubectl = _kubectl_path()
    if not kubectl:
        return VaultRoute("", Capability(
            False,
            detail="The DevOps lane is up, but kubectl is not installed, so this Studio "
                   "cannot reach Vault on it.",
            remedy="Press 'Install DevOps prerequisites' on the local-mesh page."))

    base = [kubectl, "--context", ctx, _KUBE_REQUEST_TIMEOUT, "-n", VAULT_NS]
    sts = _run(base + ["get", "statefulset", VAULT_STS, "-o", "jsonpath={.spec.replicas}"],
               timeout=_KUBE_TIMEOUT)
    if sts.returncode != 0:
        if _not_found(sts.stderr):
            return VaultRoute("", Capability(
                False,
                detail=(f"Vault is not deployed on {ctx}: there is no '{VAULT_STS}' "
                        f"StatefulSet in namespace '{VAULT_NS}'."),
                remedy=(f"Check the ArgoCD 'vault' Application: `kubectl --context {ctx} "
                        f"-n {HALT_NS} get application vault`.")), context=ctx,
                kubectl=kubectl)
        return VaultRoute("", Capability(
            False,
            detail=(f"The kind cluster's API server did not answer on context {ctx} "
                    f"({_first_line(sts.stderr) or 'kubectl failed'})."),
            remedy="Run `make kind-doctor`, or restart the lane from the local-mesh page."),
            context=ctx, kubectl=kubectl)

    if (sts.stdout or "").strip() == "0":
        why = _halt_reason(kubectl, ctx)
        if why:
            return VaultRoute("", Capability(
                False,
                detail=(f"Vault is not running: {why}, so its StatefulSet "
                        f"{VAULT_NS}/{VAULT_STS} is scaled to 0 and {VAULT_POD} does not "
                        f"exist. Its data is kept."),
                remedy=("Press 'Resume DevOps lane' on the local-mesh page's monitor (or "
                        "run `make kind-resume`), then press Refresh here.")),
                context=ctx, kubectl=kubectl)
        return VaultRoute("", Capability(
            False,
            detail=(f"Vault is not running: its StatefulSet {VAULT_NS}/{VAULT_STS} is "
                    f"scaled to 0, and NOT by the halt control (there is no "
                    f"{HALT_NS}/{HALT_CM} record)."),
            remedy=(f"See who scaled it: `kubectl --context {ctx} -n {VAULT_NS} get "
                    f"statefulset {VAULT_STS} --show-managed-fields -o yaml`.")),
            context=ctx, kubectl=kubectl)

    pod = _run(base + ["get", "pod", VAULT_POD, "-o", "json"], timeout=_KUBE_TIMEOUT)
    if pod.returncode != 0:
        if _not_found(pod.stderr):
            return VaultRoute("", Capability(
                False,
                detail=(f"Vault is not running yet: {VAULT_NS}/{VAULT_STS} wants "
                        f"{(sts.stdout or '?').strip()} replica(s) but {VAULT_POD} does "
                        f"not exist."),
                remedy=(f"See why: `kubectl --context {ctx} -n {VAULT_NS} describe "
                        f"statefulset {VAULT_STS}`.")), context=ctx, kubectl=kubectl)
        return VaultRoute("", Capability(
            False, detail=f"Could not read {VAULT_POD}: {_first_line(pod.stderr)}",
            remedy="Press Refresh; if it persists run `make kind-doctor`."),
            context=ctx, kubectl=kubectl)
    try:
        doc = json.loads(pod.stdout or "{}")
    except ValueError:
        doc = {}
    status = doc.get("status") or {}
    cs = next((c for c in status.get("containerStatuses") or []
               if c.get("name") == VAULT_CONTAINER), None)
    if not cs or not cs.get("ready"):
        waiting = ((cs or {}).get("state") or {}).get("waiting") or {}
        if waiting.get("reason"):
            detail = (f"{VAULT_POD} is not running: its vault container is waiting "
                      f"({waiting['reason']}).")
        else:
            detail = (f"{VAULT_POD} is {status.get('phase') or 'present'} but not ready: "
                      f"Vault is sealed, uninitialised, or still starting (its readiness "
                      f"check is /v1/sys/health, which fails while sealed).")
        return VaultRoute("", Capability(
            False, detail=detail,
            remedy=(f"The vault-unseal sidecar unseals it on start; see `kubectl --context "
                    f"{ctx} -n {VAULT_NS} logs {VAULT_POD} -c vault-unseal` and "
                    f"`... logs {VAULT_POD} -c {VAULT_CONTAINER}`.")),
            context=ctx, kubectl=kubectl)

    # Only now — Vault known up and unsealed — is the token read.
    tok = _run(base + ["get", "secret", VAULT_TOKEN_SECRET, "-o",
                       "jsonpath={.data." + VAULT_TOKEN_KEY + "}"], timeout=_KUBE_TIMEOUT)
    token = ""
    if tok.returncode == 0 and (tok.stdout or "").strip():
        try:
            token = base64.b64decode(tok.stdout.strip()).decode("utf-8").strip()
        except (ValueError, UnicodeDecodeError):
            token = ""
    if not token:
        # stderr only: on success stdout IS the (encoded) token.
        why = _first_line(tok.stderr) if tok.returncode != 0 else "it is empty or not base64"
        return VaultRoute("", Capability(
            False,
            detail=(f"Vault is running and unsealed on {ctx}, but its token Secret "
                    f"{VAULT_NS}/{VAULT_TOKEN_SECRET} is not readable ({why})."),
            remedy=("That Secret is written by bootstrap-kind.sh when it initialises "
                    "Vault; without it nothing can authenticate. Re-run the lane's "
                    "bootstrap, or restore it from the KEYS custody.")),
            context=ctx, kubectl=kubectl)
    return VaultRoute(ROUTE_KIND, Capability(
        True, detail=(f"{VAULT_POD} on {ctx} (running, unsealed; token from Secret "
                      f"{VAULT_NS}/{VAULT_TOKEN_SECRET})")),
        context=ctx, kubectl=kubectl, token=token)


def vault_route(project: str = DEFAULT_PROJECT) -> VaultRoute:
    """Pick the route (host first, then the kind lane). Blocking — call off the GUI
    thread."""
    host = _host_route(project)
    return host if host is not None else _kind_route()


def vault_capability(project: str = DEFAULT_PROJECT) -> Capability:
    """Can we manage Vault entries from here — and if not, the exact reason and remedy.

    An unavailable answer is never "empty": an empty entry list would read as "vault is
    running and empty", which invites the operator to add an entry that goes nowhere —
    the do-nothing-control trap this codebase has hit repeatedly."""
    return vault_route(project).cap


def _vault_cmd(route: VaultRoute, args: list[str], *, stdin: str | None = None):
    """Run ``vault <args>`` over the chosen route. The token is never in argv: env for
    the host CLI, first stdin line for the in-pod shell."""
    if route.route == ROUTE_KIND:
        payload = route.token + "\n" + (stdin or "")
        return _run([route.kubectl, "--context", route.context, "-n", VAULT_NS, "exec",
                     "-i", VAULT_POD, "-c", VAULT_CONTAINER, "--", "/bin/sh", "-c",
                     _EXEC_SH, "vault-exec", *args], stdin=payload)
    r = _run(["vault", *args], env={"VAULT_TOKEN": route.token}, stdin=stdin)
    if r.returncode != 0 and (r.stderr or "").startswith("FileNotFoundError"):
        return subprocess.CompletedProcess(
            r.args, r.returncode, "",
            "the `vault` CLI is not installed on this machine (VAULT_ADDR names a Vault, "
            "but there is no client to talk to it)")
    return r


def _empty_listing(r) -> bool:
    """`vault kv list` on a path with nothing under it exits 2 — that is an EMPTY
    answer, not a failure. Measured against hashicorp/vault:1.21.4 (the kind lane's
    image): with -format=json it prints `{}` on stdout and NOTHING on stderr; the table
    format prints 'No value found at <mount>/metadata' on stderr instead."""
    if "No value found at" in (r.stderr or ""):
        return True
    return r.returncode == 2 and (r.stdout or "").strip() == "{}" \
        and not (r.stderr or "").strip()


def _vault_reason(stderr: str) -> str:
    """One readable line out of vault's multi-line API error. Its first line is always
    'Error making API request.', which says nothing; the HTTP code and the '* reason'
    bullets are what an operator can act on (403 + 'invalid token', for instance)."""
    text = stderr or ""
    code = next((ln.strip().split(". Errors:")[0]
                 for ln in text.splitlines() if ln.strip().startswith("Code:")), "")
    bullets = [ln.strip()[2:].strip() for ln in text.splitlines()
               if ln.strip().startswith("* ") and "errors occurred" not in ln]
    if code or bullets:
        return "; ".join(x for x in [code.replace("Code: ", "HTTP "), *bullets] if x)[:200]
    return _first_line(text)


def list_entries(mount: str = KV_MOUNT, path: str = "", *,
                 project: str = DEFAULT_PROJECT,
                 route: VaultRoute | None = None) -> tuple[list[VaultEntry], Capability]:
    """(entries, capability). Every leaf KV path under ``mount/path``, walked folder by
    folder (at most MAX_LIST_CALLS listings). Entries carry PATHS only — never values,
    and not even key names, since those can only be had by reading the secret.

    Returns the capability alongside so a caller cannot mistake "cannot reach vault" for
    "vault is empty": the two render completely differently and only one of them invites
    the operator to add something.
    """
    route = route if route is not None else vault_route(project)
    if not route.cap.available:
        return [], route.cap
    root = f"{mount}/{path}".rstrip("/")
    entries: list[VaultEntry] = []
    pending = [root]
    calls = 0
    skipped: list[str] = []
    while pending:
        if calls >= MAX_LIST_CALLS:
            skipped.append(f"listing stopped after {MAX_LIST_CALLS} folders; "
                           f"{len(pending)} not opened")
            break
        folder = pending.pop(0)
        calls += 1
        r = _vault_cmd(route, ["kv", "list", "-format=json", folder])
        if r.returncode != 0:
            if _empty_listing(r):
                continue
            reason = _vault_reason(r.stderr) or "vault kv list failed"
            if folder == root:
                return [], Capability(
                    False, detail=f"Vault answered, but listing {root}/ failed: {reason}",
                    remedy="Check the mount name and that the token may list it.")
            skipped.append(f"{folder}/: {reason}")
            continue
        try:
            names = json.loads(r.stdout or "[]") or []
        except ValueError:
            if folder == root:
                return [], Capability(False, detail="vault returned unparseable JSON")
            skipped.append(f"{folder}/: unparseable answer")
            continue
        for n in names:
            n = str(n)
            if n.endswith("/"):
                pending.append(f"{folder}/{n.rstrip('/')}")
            else:
                entries.append(VaultEntry(path=f"{folder}/{n}"))
    entries.sort(key=lambda e: e.path)
    detail = route.cap.detail
    if skipped:
        detail += " — NOT everything was listed: " + "; ".join(skipped)
    return entries, Capability(True, detail=detail)


def get_entry(path: str, key: str, *,
              project: str = DEFAULT_PROJECT) -> tuple[str | None, Capability]:
    """Read ONE key's value. ``(value, capability)`` — value is ``None`` unless available.

    The value comes back on STDOUT, which is the safe direction: unlike argv it is not
    world-readable through ``/proc``, and unlike an env var it is not inherited by every
    child this process later spawns.

    ``-field=`` is what keeps it a bare value rather than a JSON envelope, so nothing has
    to parse (and therefore nothing has to log) a structure that contains the secret.

    NOTHING HERE EVER LOGS OR RETURNS THE VALUE IN AN ERROR. On failure the value is
    dropped and only the reason survives, because the obvious debugging aid — echoing what
    came back — is exactly how a token ends up in a screenshot or a bug report.
    """
    route = vault_route(project)
    if not route.cap.available:
        return None, route.cap
    r = _vault_cmd(route, ["kv", "get", f"-field={key}", path])
    if r.returncode != 0:
        # stderr is the reason, never the payload; -field= prints only the value to stdout.
        return None, Capability(
            False, detail=_vault_reason(r.stderr) or f"vault kv get {path} failed",
            remedy=f"Check that {path} exists and holds a '{key}' key, and that the "
                   f"token's policy allows reads there.")
    value = (r.stdout or "").strip()
    if not value:
        return None, Capability(
            False, detail=f"{path} has no value for '{key}'",
            remedy=f"Write it first (the Vaults dialog, or `vault kv put {path} {key}=-`).")
    return value, Capability(True, detail=f"read {key} from {path}")


def put_entry(path: str, key: str, value: str, *,
              project: str = DEFAULT_PROJECT) -> Capability:
    """Write ONE key. The value goes in on STDIN, never argv.

    argv is world-readable through /proc on a shared machine, so a secret passed as an
    argument is disclosed to every local user for the lifetime of the call — and would
    also land in any shell history or process-accounting log. On the kind route the
    token is stdin's first line and the value follows it (`key=-` reads the rest).
    """
    route = vault_route(project)
    if not route.cap.available:
        return route.cap
    r = _vault_cmd(route, ["kv", "put", path, f"{key}=-"], stdin=value)
    if r.returncode == 0:
        return Capability(True, detail=f"wrote {key} to {path}")
    # stderr can echo the submitted data, so it is NOT surfaced verbatim here.
    return Capability(False, detail=f"vault kv put {path} failed",
                      remedy="Check the token's policy allows writes to that path.")
