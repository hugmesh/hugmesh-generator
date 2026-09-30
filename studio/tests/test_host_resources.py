"""core/host_resources — the 2026-07-15 host-freeze guard formulas, pure and mocked.

No docker, no Qt, no /proc dependence: every reading is passed explicitly, so these
run identically on Linux/Windows CI. The conftest autouse fixture pins the process-
level snapshot; tests that need the auto path override env/meminfo per-call.
"""
import pytest

from hugmesh_studio.core import host_resources as hr
from hugmesh_studio.core.host_resources import (
    GIB, MIB, build_memory_flag, default_build_memory_bytes, default_jobs,
    low_memory_warnings, read_meminfo,
)

# The incident box: 31 GiB desktop, 8 cores, 4 GiB swap (full at freeze time).
INCIDENT_TOTAL = 31 * GIB


def mi(total=None, avail=None, swap_total=None, swap_free=None):
    d = {}
    if total is not None:
        d["MemTotal"] = total
    if avail is not None:
        d["MemAvailable"] = avail
    if swap_total is not None:
        d["SwapTotal"] = swap_total
    if swap_free is not None:
        d["SwapFree"] = swap_free
    return d


# ---- read_meminfo ------------------------------------------------------------------

def test_read_meminfo_parses_kb_to_bytes(tmp_path):
    p = tmp_path / "meminfo"
    p.write_text("MemTotal:       32499064 kB\n"
                 "MemFree:         1035196 kB\n"          # not a tracked key
                 "MemAvailable:   24500000 kB\n"
                 "Buffers:          500000 kB\n"
                 "SwapTotal:       4194300 kB\n"
                 "SwapFree:         419430 kB\n")
    got = read_meminfo(str(p))
    assert got == {"MemTotal": 32499064 * 1024, "MemAvailable": 24500000 * 1024,
                   "SwapTotal": 4194300 * 1024, "SwapFree": 419430 * 1024}


def test_read_meminfo_unreadable_returns_empty(tmp_path):
    # Windows/macOS have no /proc/meminfo — the documented degrade-to-no-cap path.
    assert read_meminfo(str(tmp_path / "nope")) == {}


def test_read_meminfo_ignores_garbage_lines(tmp_path):
    p = tmp_path / "meminfo"
    p.write_text("MemTotal: notanumber kB\nSwapTotal:\nMemAvailable: 1024 kB\n")
    assert read_meminfo(str(p)) == {"MemAvailable": 1024 * 1024}


# ---- the cap formula ----------------------------------------------------------------

@pytest.mark.parametrize("total,expected", [
    # incident box: min(31-4, 31*3/4) = 23.25 GiB — the 75% leg wins
    (INCIDENT_TOTAL, 23808 * MIB),
    # 8 GiB host: min(4, 6) = 4 GiB — the host-reserve leg wins
    (8 * GIB, 4 * GIB),
    # 128 GiB host: min(124, 96) = 96 GiB
    (128 * GIB, 96 * GIB),
    # tiny 2 GiB host: both legs go below the floor -> 2 GiB (bounded, honestly-OOMing)
    (2 * GIB, 2 * GIB),
])
def test_default_build_memory_bytes(total, expected):
    assert default_build_memory_bytes(total) == expected


def test_default_build_memory_rounds_down_to_whole_mib():
    got = default_build_memory_bytes(31 * GIB + 12345)
    assert got % MIB == 0
    assert got <= (31 * GIB + 12345) * 3 // 4


# ---- build_memory_flag --------------------------------------------------------------

def test_flag_auto_from_meminfo():
    assert build_memory_flag(env={}, meminfo=mi(total=INCIDENT_TOTAL)) == "23808m"
    assert build_memory_flag(env={}, meminfo=mi(total=8 * GIB)) == "4096m"


@pytest.mark.parametrize("off", ["0", "off", "OFF", "none", "None"])
def test_flag_disabled_by_env(off):
    assert build_memory_flag(env={"HUGMESH_BUILD_MEMORY": off},
                             meminfo=mi(total=INCIDENT_TOTAL)) is None


def test_flag_env_value_passes_through_verbatim():
    assert build_memory_flag(env={"HUGMESH_BUILD_MEMORY": "16g"},
                             meminfo=mi(total=INCIDENT_TOTAL)) == "16g"
    assert build_memory_flag(env={"HUGMESH_BUILD_MEMORY": "8192m"},
                             meminfo={}) == "8192m"


def test_flag_none_when_meminfo_unreadable_and_no_env():
    assert build_memory_flag(env={}, meminfo={}) is None


# ---- default_jobs -------------------------------------------------------------------

def test_jobs_incident_box_at_freeze_time_is_2_not_8():
    # 8 cores, ~5 GiB available: max(2, min(8, 5//2)) = 2
    assert default_jobs(nproc=8, meminfo=mi(total=INCIDENT_TOTAL, avail=5 * GIB),
                        env={}) == 2


def test_jobs_healthy_incident_box_keeps_8():
    # same box healthy (24 GiB available): min(8, 12) = 8 — unchanged from the flat 8
    assert default_jobs(nproc=8, meminfo=mi(total=INCIDENT_TOTAL, avail=24 * GIB),
                        env={}) == 8


def test_jobs_env_override_wins():
    assert default_jobs(nproc=8, meminfo=mi(total=INCIDENT_TOTAL, avail=24 * GIB),
                        env={"HUGMESH_BUILD_JOBS": "3"}) == 3


@pytest.mark.parametrize("bad", ["abc", "0", "-4", ""])
def test_jobs_invalid_env_override_falls_through(bad):
    assert default_jobs(nproc=8, meminfo=mi(total=INCIDENT_TOTAL, avail=24 * GIB),
                        env={"HUGMESH_BUILD_JOBS": bad}) == 8


def test_jobs_unknown_memory_is_the_old_flat8_contract():
    # unreadable meminfo (Windows) -> min(nproc, 8): never exceed the historical 8
    assert default_jobs(nproc=32, meminfo={}, env={}) == 8
    assert default_jobs(nproc=4, meminfo={}, env={}) == 4


def test_jobs_memavailable_missing_falls_back_to_total_minus_reserve():
    # MemTotal 20 GiB, no MemAvailable: headroom (20-4)=16 GiB -> min(nproc, 8)
    assert default_jobs(nproc=16, meminfo=mi(total=20 * GIB), env={}) == 8
    assert default_jobs(nproc=16, meminfo=mi(total=10 * GIB), env={}) == 3


def test_jobs_floor_is_2():
    assert default_jobs(nproc=8, meminfo=mi(total=8 * GIB, avail=1 * GIB), env={}) == 2


# ---- low_memory_warnings ------------------------------------------------------------

def test_warns_on_low_available_memory():
    w = low_memory_warnings(mi(total=INCIDENT_TOTAL, avail=2 * GIB,
                               swap_total=4 * GIB, swap_free=4 * GIB), backend="docker")
    assert len(w) == 1
    assert "2.0 GiB available" in w[0]
    assert "a heavy compile can freeze the host" in w[0]
    assert "lowering parallel jobs or closing apps" in w[0]


def test_warns_on_nearly_full_swap_even_with_memory_free():
    # the incident signature's other half: swap 95% full, plenty of RAM free
    w = low_memory_warnings(mi(total=INCIDENT_TOTAL, avail=16 * GIB,
                               swap_total=10 * GIB, swap_free=GIB // 2),
                            backend="docker")
    assert len(w) == 1
    assert "swap 95% full" in w[0]


def test_no_warning_on_a_healthy_host():
    w = low_memory_warnings(mi(total=INCIDENT_TOTAL, avail=24 * GIB,
                               swap_total=4 * GIB, swap_free=(4 * GIB) * 60 // 100),
                            backend="docker")
    assert w == []


def test_no_warning_when_meminfo_unreadable():
    # never guess: an unreadable /proc/meminfo produces silence, not a scare
    assert low_memory_warnings({}, backend="docker") == []
    assert low_memory_warnings({}, backend="native") == []


def test_native_backend_gets_the_asymmetry_suffix_docker_does_not():
    reading = mi(total=INCIDENT_TOTAL, avail=2 * GIB, swap_total=4 * GIB, swap_free=0)
    native = low_memory_warnings(reading, backend="native")
    docker = low_memory_warnings(reading, backend="docker")
    assert "Native builds cannot be memory-capped" in native[0]
    assert "prefer the Docker backend" in native[0]
    assert "cannot be memory-capped" not in docker[0]


def test_swapless_host_still_warns_on_low_available():
    w = low_memory_warnings(mi(total=8 * GIB, avail=1 * GIB, swap_total=0, swap_free=0),
                            backend="docker")
    assert len(w) == 1 and "1.0 GiB available" in w[0]


# ---- meminfo override points: cached snapshot (jobs/cap) vs fresh read (warnings) -------------

# Captured at module-import time (collection), BEFORE the conftest autouse fixture
# swaps both override points for canned lambdas — these are the real functions.
_REAL_MEMINFO_CACHED = hr._meminfo_cached
_REAL_MEMINFO_FRESH = hr._meminfo_fresh


def test_process_snapshot_is_cached_once(monkeypatch):
    # the jobs-default/cap override point: ONE /proc read per process (session-self-consistent —
    # MemTotal is constant, and a fresh config's jobs is pinned once at creation)
    calls = []
    _REAL_MEMINFO_CACHED.cache_clear()
    monkeypatch.setattr(hr, "read_meminfo",
                        lambda *a, **k: calls.append(1) or {"MemTotal": 1 * GIB})
    try:
        a = _REAL_MEMINFO_CACHED()
        b = _REAL_MEMINFO_CACHED()
        assert a == b == {"MemTotal": 1 * GIB}
        assert len(calls) == 1     # one /proc read per process: self-consistent wizard
    finally:
        _REAL_MEMINFO_CACHED.cache_clear()


def test_warnings_reflect_dispatch_time_state_not_a_launch_snapshot(monkeypatch):
    """The 2026-07-15 signature is memory filling up DURING a session: a Studio
    launched healthy must warn when the host is tight AT DISPATCH (and fall silent
    again if it recovers). Proven against the REAL fresh override point with a mutating
    read_meminfo — no lru_cache anywhere on this path."""
    monkeypatch.setattr(hr, "_meminfo_fresh", _REAL_MEMINFO_FRESH)  # undo the conftest pin
    readings = [
        mi(total=INCIDENT_TOTAL, avail=24 * GIB, swap_total=4 * GIB, swap_free=4 * GIB),
        mi(total=INCIDENT_TOTAL, avail=1 * GIB, swap_total=4 * GIB, swap_free=0),
        mi(total=INCIDENT_TOTAL, avail=24 * GIB, swap_total=4 * GIB, swap_free=4 * GIB),
    ]
    monkeypatch.setattr(hr, "read_meminfo", lambda *a, **k: dict(readings.pop(0)))
    assert low_memory_warnings() == []               # launch: healthy -> quiet
    assert len(low_memory_warnings()) == 1           # 15 min later, tight -> WARNS
    assert low_memory_warnings() == []               # recovered -> quiet again (no cry-wolf)
    assert readings == []                            # every call really read the host


def test_warnings_never_consult_the_process_snapshot(monkeypatch):
    # mutation guard: reverting low_memory_warnings to _meminfo_cached must fail here —
    # the (stale) snapshot says tight, the host NOW is healthy -> silence is correct
    tight = mi(total=INCIDENT_TOTAL, avail=1 * GIB, swap_total=4 * GIB, swap_free=0)
    healthy = mi(total=INCIDENT_TOTAL, avail=24 * GIB, swap_total=4 * GIB, swap_free=4 * GIB)
    monkeypatch.setattr(hr, "_meminfo_cached", lambda: dict(tight))
    monkeypatch.setattr(hr, "_meminfo_fresh", lambda: dict(healthy))
    assert low_memory_warnings() == []
    # and the inverse: healthy snapshot, tight NOW -> the warning fires
    monkeypatch.setattr(hr, "_meminfo_cached", lambda: dict(healthy))
    monkeypatch.setattr(hr, "_meminfo_fresh", lambda: dict(tight))
    assert len(low_memory_warnings()) == 1
