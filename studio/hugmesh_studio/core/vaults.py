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
  all. So on the docker lane the honest answer is not an empty list (which reads as
  "vault is empty, add something") but "vault is not running here, and here is how to
  start it" — the same informational-row idiom local_services.py uses for the DevOps-lane
  services, for the same reason: a control that cannot act must say so rather than
  pretend.

SECRET HANDLING. Listing returns key NAMES and metadata only; a value is fetched solely
on an explicit, per-entry request. No value is ever logged, and no token or value is ever
passed on a COMMAND LINE — argv is world-readable via /proc on a shared box — so the
Vault token travels in the child's environment and a written value travels on stdin.

BLOCKING BY CONTRACT. Every function here shells out to docker with a timeout and must
therefore be called OFF the GUI thread (see the _StatusProbe/own_probe idiom in
gui/pages/_widgets.py). `docker volume` calls are fast, but a wedged daemon blocks each
for its full timeout, and this module is reached from a dialog the operator opened.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field

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
    an honest Capability rather than a traceback in a dialog."""
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout,
            input=stdin, env={**os.environ, **(env or {})},
        )
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


def list_volumes(project: str = DEFAULT_PROJECT) -> list[ManagedVolume]:
    """Every volume the mesh's compose project owns, newest-name-order stable.

    Selected by compose LABEL, not by name prefix: this module offers a delete, and a
    name-prefix match would happily sweep in an unrelated volume someone named similarly.
    """
    r = _run(["docker", "volume", "ls", "--filter", f"label={_LBL_PROJECT}={project}",
              "--format", "{{.Name}}"])
    if r.returncode != 0:
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
def vault_capability(project: str = DEFAULT_PROJECT) -> Capability:
    """Can we manage Vault entries from here?

    On the docker lane the answer is NO and that is not a defect: Vault is a cluster app
    (specs/cluster/apps/02-vault.yaml) on the DevOps/Kubernetes lane, so a local compose
    mesh has no vault container to talk to. Returning an empty entry list instead would
    read as "vault is running and empty", which invites the operator to add an entry that
    would go nowhere — the exact inert-control trap this codebase has hit repeatedly.
    """
    addr = os.environ.get("VAULT_ADDR", "").strip()
    r = _run(["docker", "ps", "--filter", f"label={_LBL_PROJECT}={project}",
              "--filter", "name=vault", "--format", "{{.Names}}"])
    running = [n for n in r.stdout.splitlines() if n.strip()] if r.returncode == 0 else []
    if not running and not addr:
        return Capability(
            False,
            detail="Vault is not running on this mesh.",
            remedy="Vault is a DevOps-lane (Kubernetes) service, not part of the docker "
                   "mesh — start that lane ('Start DevOps lane' on the local-mesh page, "
                   "or `make kind-up`), or point VAULT_ADDR at an existing Vault.")
    if not os.environ.get("VAULT_TOKEN", "").strip():
        return Capability(
            False,
            detail="Vault is reachable but this Studio holds no token.",
            remedy="Export VAULT_TOKEN (it is read from the environment and never "
                   "written to disk, logged, or passed on a command line).")
    return Capability(True, detail=f"vault at {addr or running[0]}")


def list_entries(mount: str = "secret", path: str = "") -> tuple[list[VaultEntry], Capability]:
    """(entries, capability). Entries carry KEY NAMES only — never values.

    Returns the capability alongside so a caller cannot mistake "cannot reach vault" for
    "vault is empty": the two render completely differently and only one of them invites
    the operator to add something.
    """
    cap = vault_capability()
    if not cap.available:
        return [], cap
    r = _run(["vault", "kv", "list", "-format=json", f"{mount}/{path}".rstrip("/")],
             env={"VAULT_TOKEN": os.environ.get("VAULT_TOKEN", "")})
    if r.returncode != 0:
        return [], Capability(False, detail=(r.stderr or "vault kv list failed").strip(),
                              remedy="Check VAULT_ADDR/VAULT_TOKEN and the mount name.")
    try:
        names = json.loads(r.stdout or "[]")
    except ValueError:
        return [], Capability(False, detail="vault returned unparseable JSON")
    base = f"{mount}/{path}".rstrip("/")
    return [VaultEntry(path=f"{base}/{n}".rstrip("/")) for n in names], cap


def put_entry(path: str, key: str, value: str) -> Capability:
    """Write ONE key. The value goes in on STDIN, never argv.

    argv is world-readable through /proc on a shared machine, so a secret passed as an
    argument is disclosed to every local user for the lifetime of the call — and would
    also land in any shell history or process-accounting log.
    """
    cap = vault_capability()
    if not cap.available:
        return cap
    r = _run(["vault", "kv", "put", path, f"{key}=-"],
             env={"VAULT_TOKEN": os.environ.get("VAULT_TOKEN", "")},
             stdin=value)
    if r.returncode == 0:
        return Capability(True, detail=f"wrote {key} to {path}")
    # stderr can echo the submitted data, so it is NOT surfaced verbatim here.
    return Capability(False, detail=f"vault kv put {path} failed",
                      remedy="Check the token's policy allows writes to that path.")
