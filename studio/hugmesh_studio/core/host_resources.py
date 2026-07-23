"""Host memory/CPU facts for build sizing — the 2026-07-15 host-freeze guard.

On 2026-07-15 a dockerized fleet build compiled llvm's 32-bit multilib pass at -j8
inside an UNBOUNDED builder container on a 31 GiB desktop that was also running a
browser/IDE (and whose 4 GiB of swap was already full); the HOST froze and rebooted.
This module supplies the three defenses:

* a default **container memory cap** for docker builder runs (:func:`build_memory_flag`)
  so a runaway compile OOMs the CONTAINER — an honest build failure — instead of
  freezing the host;
* a **host-aware default for parallel jobs** (:func:`default_jobs`) so a fresh config
  on a memory-tight host does not start at the flat historical 8;
* **low-memory preflight warnings** (:func:`low_memory_warnings`) surfaced by the
  Review/Progress pages — advisory only, never a block and never a silent throttle,
  and computed from a FRESH ``/proc/meminfo`` read every time (the incident was
  memory filling up DURING a session, so "low at dispatch" must mean NOW, not the
  snapshot from Studio launch).

Everything reads ``/proc/meminfo`` (Linux). Windows/macOS have no ``/proc/meminfo``,
so :func:`read_meminfo` returns ``{}`` there and every consumer degrades honestly:
no cap, the historical flat-8 jobs contract, no warnings (never guess).
"""
from __future__ import annotations

import functools
import os

MIB = 1024 ** 2
GIB = 1024 ** 3

# Hard host reserve for the cap formula AND the preflight "low available memory"
# threshold (one constant, one meaning: what the desktop needs to stay alive —
# the incident box had ~4 GiB of swap already full when the builder ate the rest).
HOST_RESERVE_BYTES = 4 * GIB
LOW_MEM_AVAILABLE_BYTES = HOST_RESERVE_BYTES
# Floor for the cap: a tiny host still gets a bounded (honestly-OOMing) build
# rather than an un-runnable one.
MIN_CAP_BYTES = 2 * GIB
# Preflight also warns when swap is nearly exhausted (< 10 % free), the other
# half of the incident signature.
SWAP_FREE_WARN_FRACTION = 0.10

MEMORY_ENV = "HUGMESH_BUILD_MEMORY"   # ""/unset = auto; 0/off/none = no cap; else verbatim
JOBS_ENV = "HUGMESH_BUILD_JOBS"       # explicit override for the default-jobs formula

_MEMINFO_KEYS = ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree")


def read_meminfo(path: str = "/proc/meminfo") -> dict[str, int]:
    """MemTotal/MemAvailable/SwapTotal/SwapFree in BYTES (the file reports kB).

    ``{}`` on any OSError — Windows/macOS have no /proc/meminfo — so callers can
    degrade to "memory unknown" behavior instead of guessing."""
    try:
        with open(path, encoding="ascii", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return {}
    out: dict[str, int] = {}
    for line in lines:
        key, _, rest = line.partition(":")
        if key in _MEMINFO_KEYS:
            parts = rest.split()
            if parts and parts[0].isdigit():
                out[key] = int(parts[0]) * 1024
    return out


@functools.lru_cache(maxsize=1)
def _meminfo_cached() -> dict[str, int]:
    """One /proc/meminfo read per process, so a wizard session is self-consistent —
    for the JOBS DEFAULT and the CAP only (both key on facts that are stable across
    a session: MemTotal is constant, and a fresh config's jobs is pinned once at
    creation anyway). The low-memory WARNINGS deliberately do NOT use this cache:
    they must reflect the host AT DISPATCH — see :func:`_meminfo_fresh`. Callers
    treat the returned dict as read-only."""
    return read_meminfo()


def _meminfo_fresh() -> dict[str, int]:
    """A FRESH /proc/meminfo read for every call — the dispatch-time seam for
    :func:`low_memory_warnings` (and the tests' monkeypatch point). Never cached:
    the 2026-07-15 incident signature is memory filling up DURING a session
    (browser + IDE + another build), so a warning computed from a launch-time
    snapshot would stay silent exactly when it matters (and cry wolf in the
    inverse case). One cheap file read per preflight is the whole cost."""
    return read_meminfo()


def default_build_memory_bytes(mem_total: int) -> int:
    """The default container memory cap for a host with ``mem_total`` bytes of RAM:
    ``max(2 GiB, min(mem_total - 4 GiB, mem_total * 3 // 4))``, rounded down to a
    whole MiB for a clean docker flag value.

    Reserve a hard 4 GiB for the host (browser/IDE/desktop), never exceed 75 % of
    RAM, floor 2 GiB. Incident box (31 GiB): min(27, 23.25) -> ~23 GiB cap, host
    keeps ~8 GiB. 8 GiB host -> 4 GiB; 128 GiB -> 96 GiB."""
    cap = max(MIN_CAP_BYTES, min(mem_total - HOST_RESERVE_BYTES, mem_total * 3 // 4))
    return (cap // MIB) * MIB


def build_memory_flag(env: os._Environ | dict | None = None,
                      meminfo: dict[str, int] | None = None) -> str | None:
    """The docker ``--memory`` value for a builder run, or ``None`` for no cap.

    * :data:`MEMORY_ENV` unset/empty -> the auto formula, rendered ``"<mib>m"``;
    * ``"0"``/``"off"``/``"none"`` (case-insensitive) -> ``None`` (cap disabled —
      the pre-guard argv, byte-identical);
    * any other value -> passed through VERBATIM as a docker size string
      (``"16g"``, ``"8192m"`` — docker validates it, we do not second-guess);
    * meminfo unreadable and no env override -> ``None`` (no cap; never guess)."""
    env = os.environ if env is None else env
    raw = (env.get(MEMORY_ENV) or "").strip()
    if raw:
        if raw.lower() in ("0", "off", "none"):
            return None
        return raw
    mi = _meminfo_cached() if meminfo is None else meminfo
    total = mi.get("MemTotal", 0)
    if total <= 0:
        return None
    return f"{default_build_memory_bytes(total) // MIB}m"


def default_jobs(nproc: int | None = None, meminfo: dict[str, int] | None = None,
                 env: os._Environ | dict | None = None) -> int:
    """Host-aware default for ImageConfig.jobs (fresh configs ONLY — a config whose
    JSON carries a "jobs" key keeps that value verbatim; see config.from_dict).

    :data:`JOBS_ENV`, when a valid int >= 1, wins outright. Otherwise
    ``max(2, min(nproc, MemAvailable_GiB // 2))`` — roughly 2 GiB of headroom per
    compile job (falling back to ``(MemTotal - 4 GiB)`` when MemAvailable is
    missing). When meminfo is unreadable entirely (Windows/macOS), the OLD contract
    exactly: ``min(nproc, 8)`` — never exceed the historical flat 8 when memory is
    unknown. Incident box at freeze time (8 cores, ~5 GiB avail): 2, not 8; the
    same box healthy (24 GiB avail): 8 — unchanged."""
    env = os.environ if env is None else env
    raw = (env.get(JOBS_ENV) or "").strip()
    if raw:
        try:
            j = int(raw)
        except ValueError:
            j = 0
        if j >= 1:
            return j
    cores = nproc or os.cpu_count() or 8
    mi = _meminfo_cached() if meminfo is None else meminfo
    if not mi:
        return min(cores, 8)   # memory unknown -> the historical flat-8 contract
    if "MemAvailable" in mi:
        headroom = mi["MemAvailable"]
    else:
        headroom = max(0, mi.get("MemTotal", 0) - HOST_RESERVE_BYTES)
    return max(2, min(cores, (headroom // GIB) // 2))


def low_memory_warnings(meminfo: dict[str, int] | None = None,
                        backend: str = "docker") -> list[str]:
    """Advisory preflight warnings (0 or 1 message) when the host looks memory-tight
    at dispatch: MemAvailable < 4 GiB, or swap > 90 % full. NEVER a block, NEVER a
    throttle — callers display the text and change nothing else. Unreadable meminfo
    -> ``[]`` (never guess). The native backend gets the honesty suffix: the Studio
    cannot cgroup-cap a native build, only a docker one.

    Unlike the jobs default and the cap, this reads /proc/meminfo FRESH on every
    call (:func:`_meminfo_fresh`, not the process-lifetime :func:`_meminfo_cached`):
    "low at dispatch" means the host state NOW — a Studio launched on a healthy
    host that got tight during 15 minutes of configuring must still warn."""
    mi = _meminfo_fresh() if meminfo is None else meminfo
    if not mi:
        return []
    avail = mi.get("MemAvailable")
    low_avail = avail is not None and avail < LOW_MEM_AVAILABLE_BYTES
    swap_total = mi.get("SwapTotal", 0)
    swap_free = mi.get("SwapFree", 0)
    swap_tight = swap_total > 0 and swap_free < swap_total * SWAP_FREE_WARN_FRACTION
    if not (low_avail or swap_tight):
        return []
    avail_gib = (avail if avail is not None else 0) / GIB
    swap_pct = (100 - swap_free * 100 // swap_total) if swap_total else 0
    msg = (f"Low host memory: {avail_gib:.1f} GiB available, swap {swap_pct}% full — "
           "a heavy compile can freeze the host; consider lowering parallel jobs "
           "or closing apps.")
    if backend == "native":
        msg += (" Native builds cannot be memory-capped by the Studio; on a tight "
                "host prefer the Docker backend (its builds run under a container "
                "memory cap).")
    return [msg]
