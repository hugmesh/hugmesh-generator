"""How much of this machine HugMesh is allowed to use.

ONE module owns the answer, because the Studio starts work through five different
mechanisms and every one of them expresses "use at most this much" differently:

  =====================  ==============================================================
  lane                    how a limit is expressed
  =====================  ==============================================================
  single-image build      ``docker run --cpus/--memory`` (core/build_driver.py)
  fleet build             the same flags (core/fleet.py) — the lane that caused the
                          2026-07-15 host freeze, and the only one that had NEITHER
  local compose stack     ``deploy.resources.limits`` in a compose override file
  mesh node (tray)        the same, in an overlay next to the staged node
                          (core/mesh_node.py), with the WHOLE budget on its one service
  QEMU emulation          NOT WIRED: ``-smp`` / ``-m`` on the guest, ``--cpus`` on the harness
  kind / k8s              NOT WIRED: ``docker update`` on the node container, since the cluster
                          spec is a committed file that must stay machine-independent
  =====================  ==============================================================

Without a shared owner those five drift, and the operator who sets a limit in the GUI
has no way to know which lanes actually honour it.

THE INCIDENT THIS EXISTS FOR. On 2026-07-15 a dockerized fleet build compiled llvm's
32-bit multilib pass at -j8 inside an UNBOUNDED container, on a 31 GiB desktop that was
also running a browser and an IDE, with 4 GiB of swap already full. The host froze and
rebooted. :mod:`hugmesh_studio.core.host_resources` answered the memory half of that
(a container that OOMs is an honest build failure; a host that freezes is not) and
this module answers the CPU half and extends both to the lanes that RUN a mesh rather
than build one — which is what a tray application on somebody's desktop needs, because
the whole point of the tray is that the machine stays usable while the mesh runs.

THE THREE-WAY KNOB CONTRACT, inherited verbatim from
:func:`host_resources.build_memory_flag` so an operator who knows one knob knows all
of them:

  * unset / empty  -> the AUTO formula for this host
  * ``0`` / ``off`` / ``none``  -> no limit at all, and the argv is byte-identical to
    what it was before limits existed (this is what makes the feature safe to add:
    every existing test that pins a command still passes with the knob off)
  * anything else  -> passed through VERBATIM; docker validates it, we do not
    second-guess the operator

GPU. There is no "GPU percentage" to set: the container runtimes expose GPUs as
devices, not as a share. So the GPU knob is an ALLOCATION, not a throttle — which
devices, if any, a lane may see. The honest default is NONE: a mesh running in the
background on somebody's desktop should not silently take the GPU away from what they
are actually doing. Asking for GPUs when the host has no working runtime hook is
reported, never silently dropped.
"""
from __future__ import annotations

import dataclasses
import json
import os
import shutil
import subprocess

from . import host_resources

__all__ = [
    "CPUS_ENV", "GPUS_ENV",
    "ResourceLimits", "auto_limits", "from_env", "load", "save",
    "docker_run_args", "compose_resource_block", "qemu_smp",
    "gpu_runtime_available", "gpu_warnings",
]

#: Same shape as host_resources.MEMORY_ENV. Value is a docker ``--cpus`` string:
#: a fractional count of cores ("1.5" = one and a half cores' worth of CPU time).
CPUS_ENV = "HUGMESH_CPUS"
#: Docker ``--gpus`` value: "all", "device=0", "0,1", or off. Default is OFF.
GPUS_ENV = "HUGMESH_GPUS"
#: The memory knob already existed for builds; reuse it rather than inventing a
#: second spelling.
MEMORY_ENV = host_resources.MEMORY_ENV

#: Cores kept for the desktop by the auto formula. One core is enough to keep a
#: compositor and a terminal responsive, which is the difference between "the build
#: is slow" and "I cannot move the mouse".
HOST_RESERVE_CORES = 1
#: Never hand a lane less than this, or a "limit" becomes a hang.
MIN_CPUS = 1.0

_OFF = ("0", "off", "none", "no", "false")


@dataclasses.dataclass(frozen=True)
class ResourceLimits:
    """What one lane may use. ``None`` in any field means "no limit for this".

    Frozen because these are read at command-assembly time by several lanes at once;
    a value that could be mutated between preview and dispatch would let the command
    the operator was shown differ from the command that ran.
    """

    #: Fractional cores, e.g. 6.0. None = unlimited.
    cpus: float | None = None
    #: A docker size string, e.g. "23000m". None = unlimited.
    memory: str | None = None
    #: A docker --gpus selector, e.g. "all" or "device=0". None = no GPU access.
    gpus: str | None = None

    def is_unlimited(self) -> bool:
        return self.cpus is None and self.memory is None and self.gpus is None

    def to_dict(self) -> dict:
        return {k: v for k, v in dataclasses.asdict(self).items() if v is not None}

    @classmethod
    def from_dict(cls, data: dict | None) -> "ResourceLimits":
        data = data or {}
        cpus = data.get("cpus")
        return cls(
            cpus=float(cpus) if cpus not in (None, "") else None,
            memory=(str(data["memory"]) if data.get("memory") else None),
            gpus=(str(data["gpus"]) if data.get("gpus") else None),
        )

    def describe(self) -> str:
        """A one-line, operator-readable summary for the GUI and the tray tooltip."""
        parts = []
        parts.append(f"{_trim(self.cpus)} CPU" if self.cpus else "all CPUs")
        parts.append(self.memory if self.memory else "all memory")
        parts.append(f"GPU {self.gpus}" if self.gpus else "no GPU")
        return ", ".join(parts)


def _trim(value: float) -> str:
    """Render 6.0 as "6" and 1.5 as "1.5" — a whole number should not read as a float."""
    return f"{value:g}"


def default_cpus(nproc: int | None = None) -> float:
    """The auto CPU cap for this host: every core but one, floored at 1.

    Deliberately NOT a percentage of the machine. The thing that makes a desktop feel
    broken under load is having no core left for the compositor, and that is an
    absolute shortfall, not a proportional one — reserving 25 % leaves a 16-core box
    four spare cores it does not need and a 2-core box half a core it cannot use.
    """
    cores = nproc or os.cpu_count() or 2
    return float(max(MIN_CPUS, cores - HOST_RESERVE_CORES))


def auto_limits(nproc: int | None = None,
                meminfo: dict[str, int] | None = None) -> ResourceLimits:
    """The limits this host gets when the operator has expressed no preference.

    Memory comes from :func:`host_resources.build_memory_flag`, which returns None on
    a host whose meminfo cannot be read (Windows, macOS) — there we cap CPU and leave
    memory alone rather than guessing, exactly as the memory module already does.
    GPU defaults to None: a background mesh does not take the GPU.
    """
    return ResourceLimits(
        cpus=default_cpus(nproc),
        memory=host_resources.build_memory_flag(env={}, meminfo=meminfo),
        gpus=None,
    )


def from_env(env: os._Environ | dict | None = None,
             nproc: int | None = None,
             meminfo: dict[str, int] | None = None) -> ResourceLimits:
    """Resolve limits from the environment, applying the three-way knob contract to
    each field independently — so an operator can pin CPU and leave memory automatic."""
    env = os.environ if env is None else env

    raw_cpus = (env.get(CPUS_ENV) or "").strip()
    if raw_cpus:
        cpus = None if raw_cpus.lower() in _OFF else _parse_cpus(raw_cpus)
    else:
        cpus = default_cpus(nproc)

    # build_memory_flag already implements unset/off/verbatim for memory.
    memory = host_resources.build_memory_flag(env=env, meminfo=meminfo)

    raw_gpus = (env.get(GPUS_ENV) or "").strip()
    gpus = None if (not raw_gpus or raw_gpus.lower() in _OFF) else raw_gpus

    return ResourceLimits(cpus=cpus, memory=memory, gpus=gpus)


def _parse_cpus(raw: str) -> float | None:
    """A malformed CPU knob yields NO cap rather than a wrong one.

    Silently substituting a default here would be worse than doing nothing: the
    operator set the variable precisely because they wanted a specific number, and
    quietly using a different one is the kind of thing nobody discovers until a host
    freezes anyway. Callers surface this through :func:`gpu_warnings`' sibling
    :func:`limit_warnings`.
    """
    try:
        value = float(raw)
    except ValueError:
        return None
    return value if value > 0 else None


def limit_warnings(env: os._Environ | dict | None = None) -> list[str]:
    """Advisory messages about knobs that were set but could not be honoured."""
    env = os.environ if env is None else env
    out: list[str] = []
    raw = (env.get(CPUS_ENV) or "").strip()
    if raw and raw.lower() not in _OFF and _parse_cpus(raw) is None:
        out.append(f"{CPUS_ENV}={raw!r} is not a positive number — running with no CPU limit.")
    return out


# ── Renderers: one per lane ──────────────────────────────────────────────────────

def docker_run_args(limits: ResourceLimits) -> list[str]:
    """``docker run`` flags for these limits, or ``[]`` when nothing is limited.

    Returning a plain list that the caller splats keeps the guarantee that matters
    most: with limits off the surrounding argv is BYTE-IDENTICAL to what it was
    before this module existed, so every committed command-string test still passes.

    ``--memory-swap`` is pinned equal to ``--memory`` on purpose — that means zero
    container swap, so a runaway compile OOMs promptly instead of thrashing the
    host's swap, which was the 2026-07-15 freeze signature.
    """
    args: list[str] = []
    if limits.cpus is not None:
        args += ["--cpus", _trim(limits.cpus)]
    if limits.memory is not None:
        args += ["--memory", limits.memory, "--memory-swap", limits.memory]
    if limits.gpus is not None:
        args += ["--gpus", limits.gpus]
    return args


def compose_resource_block(limits: ResourceLimits) -> dict:
    """The ``deploy.resources.limits`` mapping for a compose override, or ``{}``.

    Compose spells CPU limits as a STRING count of cores under
    ``deploy.resources.limits.cpus`` and memory with a unit suffix. GPUs are not a
    limit there at all — they are a ``device_requests`` reservation — so they are
    emitted under ``reservations.devices`` instead, which is the only place the
    compose spec accepts them.
    """
    limits_block: dict = {}
    if limits.cpus is not None:
        limits_block["cpus"] = _trim(limits.cpus)
    if limits.memory is not None:
        limits_block["memory"] = limits.memory

    resources: dict = {}
    if limits_block:
        resources["limits"] = limits_block
    if limits.gpus is not None:
        resources["reservations"] = {
            "devices": [{"driver": "nvidia", "capabilities": [["gpu"]],
                         **({"count": "all"} if limits.gpus == "all" else {"device_ids": _device_ids(limits.gpus)})}]
        }
    return resources


def _device_ids(selector: str) -> list[str]:
    """Turn a docker ``--gpus`` selector into the compose ``device_ids`` list."""
    body = selector.split("=", 1)[1] if selector.startswith("device=") else selector
    return [part.strip() for part in body.split(",") if part.strip()]


def qemu_smp(limits: ResourceLimits, *, floor: int = 1) -> int | None:
    """vCPUs for an emulated guest, or ``None`` for the caller's own default.

    QEMU has no fractional CPU: ``-smp`` is a whole number of vCPUs. A limit of 1.5
    therefore becomes 1, not 2 — rounding UP would hand the guest more of the host
    than the operator allowed, and the entire point of the setting is that it is a
    ceiling.
    """
    if limits.cpus is None:
        return None
    return max(floor, int(limits.cpus))


# ── GPU availability ─────────────────────────────────────────────────────────────

def gpu_runtime_available() -> bool:
    """Whether docker can actually hand a container a GPU on this host.

    Probed by asking docker for its registered runtimes rather than by looking for
    /dev/nvidia*: the device nodes can be present while the container toolkit is not
    installed, which is precisely the case where ``--gpus`` fails at run time with a
    message about the runtime rather than about the hardware.
    """
    if not shutil.which("docker"):
        return False
    try:
        out = subprocess.run(
            ["docker", "info", "--format", "{{json .Runtimes}}"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if out.returncode != 0:
        return False
    try:
        runtimes = json.loads(out.stdout.strip() or "{}")
    except json.JSONDecodeError:
        return False
    return any("nvidia" in name for name in runtimes)


def gpu_warnings(limits: ResourceLimits, *, probe=gpu_runtime_available) -> list[str]:
    """Advisory messages when GPUs were requested but cannot be delivered.

    Advisory, never a block: the operator may be configuring on one machine for
    another, and a preflight that refuses to let you SAVE a setting because the
    current host cannot honour it is worse than one that tells you.
    """
    if limits.gpus is None:
        return []
    if probe():
        return []
    return [
        "GPU access is requested but Docker reports no GPU runtime on this host. "
        "Containers will fail to start with a runtime error until the NVIDIA "
        "Container Toolkit is installed, or clear the GPU setting."
    ]


# ── Persistence ──────────────────────────────────────────────────────────────────

def _settings_path() -> str:
    """Where the operator's choice lives, next to the Studio's other per-user state."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    return os.path.join(base, "hugmesh-studio", "resource-limits.json")


def load(path: str | None = None) -> ResourceLimits | None:
    """The saved limits, or ``None`` when the operator has never set any.

    ``None`` and "unlimited" are deliberately different answers: None means "fall
    back to the auto formula", while a saved all-None ResourceLimits means "the
    operator explicitly asked for no limits" and must not be overridden.
    """
    p = path or _settings_path()
    try:
        with open(p, "r", encoding="utf-8") as fh:
            return ResourceLimits.from_dict(json.load(fh))
    except (OSError, ValueError):
        return None


def save(limits: ResourceLimits, path: str | None = None) -> str:
    """Persist the operator's choice; returns the path written."""
    p = path or _settings_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = f"{p}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(limits.to_dict(), fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, p)   # atomic: a crash mid-write must not leave a truncated file
    return p


def effective(env: os._Environ | dict | None = None,
              path: str | None = None,
              nproc: int | None = None,
              meminfo: dict[str, int] | None = None) -> ResourceLimits:
    """The limits every lane should actually use, resolved in precedence order:

      1. an environment knob (a one-off override for a single run)
      2. the operator's saved GUI setting
      3. the auto formula for this host

    Environment beats the saved setting so a scripted run can bound itself without
    mutating the operator's preferences, which is the same precedence the memory knob
    already had.
    """
    env = os.environ if env is None else env
    if any((env.get(k) or "").strip() for k in (CPUS_ENV, MEMORY_ENV, GPUS_ENV)):
        return from_env(env=env, nproc=nproc, meminfo=meminfo)
    saved = load(path)
    if saved is not None:
        return saved
    return auto_limits(nproc=nproc, meminfo=meminfo)
