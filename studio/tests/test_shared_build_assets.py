"""Studio side of the shared build-asset root (stage3 seed cache / distfiles / binpkg pool).

WHY THE STUDIO NEEDS ITS OWN LEG AT ALL. The builders default the root to
``<work-dir>/shared``, which is correct for a make-driven build. It is WRONG for a GUI
build: a Studio session's work dir is the per-session ``<out>/sessions/<id>``
(build_sessions.session_workdir), so the builder-side default would mint a fresh empty
root per session — every GUI build re-downloading the ~250 MB stage3 seed and
recompiling the world from an empty pool, which is exactly the gap this closes. The
driver therefore derives the root from the STABLE ``<out>`` and passes it explicitly,
which also puts it in the command PREVIEW the operator reads before dispatch.

The other half is the invariant that must NOT change: the per-entry build TREE stays
isolated at ``wl-<entry-id>``. Only the pool/seed/distfiles are shared. Both directions
are asserted here.
"""
from __future__ import annotations

import os

from hugmesh_studio.core.build_driver import (
    DOCKER_ASSET_FIELDS, BuildDriver, shared_assets_root,
)
from hugmesh_studio.core.build_sessions import session_workdir
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _host() -> HostInfo:
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def _driver(**kw) -> BuildDriver:
    return BuildDriver(GENERATOR_DIR, _host(), **kw)


def _cfg() -> ImageConfig:
    return ImageConfig(platform="rpi5", role="be", mode="mesh", env="test")


def _inner(cmd: list[str]) -> str:
    """The builder argv; docker-run carries it as one `bash -c <string>` element."""
    if cmd[-2] == "-c":
        return cmd[-1]
    return " ".join(cmd)


# ── root derivation ─────────────────────────────────────────────────────────────────────
def test_root_defaults_to_shared_under_the_out_dir():
    assert shared_assets_root("/data/out") == "/data/out/shared"


def test_root_of_a_session_workdir_climbs_back_to_the_stable_out_dir():
    """THE REGRESSION. <out>/sessions/<id>/shared would be per-session — i.e. shared with
    nobody — so every GUI build would re-download the seed and start from an empty pool."""
    wd = session_workdir("/data/out", "20260730-101010-abcdef")
    assert wd == "/data/out/sessions/20260730-101010-abcdef"
    assert shared_assets_root(wd) == "/data/out/shared"


def test_root_does_not_climb_for_a_dir_merely_named_like_a_session():
    """Only a real `<out>/sessions/<id>` shape climbs; an ordinary dir is left alone."""
    assert shared_assets_root("/data/out/mybuilds") == "/data/out/mybuilds/shared"


# ── native emission ─────────────────────────────────────────────────────────────────────
def test_native_build_passes_the_shared_root():
    cmd = _driver().command(_cfg(), backend="native")
    assert "--shared-assets" in cmd
    assert cmd[cmd.index("--shared-assets") + 1] == os.path.join(GENERATOR_DIR, "out", "shared")


def test_session_build_passes_the_STABLE_root_not_the_session_dir():
    wd = session_workdir("/data/out", "20260730-101010-abcdef")
    cmd = _driver(workdir=wd).command(_cfg(), backend="native")
    val = cmd[cmd.index("--shared-assets") + 1]
    assert val == "/data/out/shared"
    assert "sessions" not in val


def test_preview_shows_the_shared_root():
    """The operator must SEE what is being reused before dispatching (command_string is
    the preview both the GUI and --print-command render)."""
    s = _driver().command_string(_cfg(), backend="native")
    assert "--shared-assets" in s and "/out/shared" in s


def test_opt_out_emits_no_shared_assets():
    cmd = _driver(shared_assets="").command(_cfg(), backend="native")
    assert "--no-shared-assets" in cmd
    assert "--shared-assets" not in cmd


def test_explicit_root_overrides_the_derivation():
    cmd = _driver(shared_assets="/srv/fleet").command(_cfg(), backend="native")
    assert cmd[cmd.index("--shared-assets") + 1] == "/srv/fleet"


def test_shared_leg_precedes_config_args_so_extra_flags_stay_last():
    """Ordering is load-bearing, not cosmetic. `extra_flags` is the operator's raw
    escape hatch and cfg.to_cli_args() emits it LAST; the builders parse argv
    last-flag-wins, so a hand-typed `--no-shared-assets` in extra_flags must still be
    able to override the driver's own `--shared-assets`. Emitting the driver leg AFTER
    the config args would silently take that ability away."""
    cfg = _cfg()
    cfg.extra_flags = "--no-shared-assets"
    cmd = _driver().command(cfg, backend="native")
    assert cmd.index("--shared-assets") < cmd.index("--no-shared-assets")
    assert cmd[-1] == "--no-shared-assets"
    # and the same on the docker leg, where the argv is one `bash -c` string
    dcmd = _driver().command(cfg, backend="docker")
    inner = _inner(dcmd)
    assert inner.index("--shared-assets") < inner.index("--no-shared-assets")
    assert inner.endswith("--no-shared-assets")


# ── docker emission ─────────────────────────────────────────────────────────────────────
def test_docker_shared_root_gets_a_stable_container_path_on_every_layout():
    """The Studio always mounts the root at the FIXED container path `/shared`.

    A make-driven docker build needs no mount at all — `-v $(WORK_DIR):/out` already
    covers the builder's own `<work-dir>/shared` default. The Studio cannot rely on that:
    it mounts the PER-SESSION work dir at /out while the root deliberately sits at the
    stable `<out>/shared` ABOVE it. Rather than emit two different in-container spellings
    depending on whether a session override happens to be set, the driver always mounts
    at `/shared`, so the preview and the log read identically on both layouts."""
    cmd = _driver().command(_cfg(), backend="docker")
    assert "--shared-assets /shared" in _inner(cmd)
    assert f"{os.path.join(GENERATOR_DIR, 'out', 'shared')}:/shared" in cmd


def test_docker_session_root_outside_the_out_mount_gets_its_own_RW_mount():
    """A session work dir is mounted at /out, so `<out>/shared` is NOT reachable — it
    needs its own mount. Read-WRITE: the builder creates the seed cache, the pool and the
    distfiles inside it (which is why it is not a DOCKER_ASSET_FIELDS `:ro` input)."""
    wd = session_workdir("/data/out", "20260730-101010-abcdef")
    cmd = _driver(workdir=wd).command(_cfg(), backend="docker")
    assert "-v" in cmd and "/data/out/shared:/shared" in cmd
    assert "/data/out/shared:/shared:ro" not in cmd, "the shared root must be WRITABLE"
    assert "--shared-assets /shared" in _inner(cmd)
    assert "/data/out/shared" not in _inner(cmd), "raw host path leaked into the container argv"


def test_docker_opt_out_mounts_nothing():
    cmd = _driver(shared_assets="").command(_cfg(), backend="docker")
    assert "--no-shared-assets" in _inner(cmd)
    assert not any(a.endswith(":/shared") for a in cmd)


def test_shared_assets_is_not_a_read_only_docker_asset_field():
    """Sibling-list honesty: DOCKER_ASSET_FIELDS entries are `:ro` inputs that must
    pre-exist; the shared root is writable and created by the build, so it deliberately
    has its own leg. Pinning this stops someone 'fixing' it into that list, which would
    silently make the pool read-only and every build recompile."""
    assert "shared_assets" not in DOCKER_ASSET_FIELDS


# ── the invariant that must NOT have moved ──────────────────────────────────────────────
def test_shared_assets_never_leaks_into_config_emission():
    """to_cli_args() is the config->argv contract the goldens, --print-specs and the JOB
    channel pin. The shared root is DRIVER state (like the work-dir override), so config
    emission must be byte-identical to before this feature."""
    args = _cfg().to_cli_args()
    assert not [a for a in args if "shared-assets" in a]


def test_per_entry_build_tree_stays_isolated():
    """The pool is now shared per BOARD, but each worklist entry must still build in its
    OWN tree (wl-<id>) — that is what keeps two images from clobbering each other's
    sysroot and node keys."""
    e1 = WorklistEntry(role="be", platform="rpi5")
    e2 = WorklistEntry(role="fe", platform="rpi5")
    assert e1.build_subdir == f"wl-{e1.id}"
    assert e1.build_subdir != e2.build_subdir


def test_worklist_materialize_still_sets_the_isolated_build_subdir():
    wl = WorklistConfig(base=ImageConfig(mode="mesh", env="test"),
                        entries=[WorklistEntry(role="be", platform="rpi5"),
                                 WorklistEntry(role="fe", platform="rpi5")])
    subdirs = [cfg.build_subdir for _entry, cfg in wl.materialize()]
    assert len(set(subdirs)) == 2
    assert all(s.startswith("wl-") for s in subdirs)


def test_every_materialized_image_of_one_worklist_gets_the_same_shared_root():
    """The reuse claim, end to end: N images in one session must all name ONE root (that
    is what lets image #2 reuse image #1's compiled packages and the seed)."""
    wl = WorklistConfig(base=ImageConfig(mode="mesh", env="test"),
                        entries=[WorklistEntry(role="be", platform="rpi5"),
                                 WorklistEntry(role="fe", platform="rpi5")])
    wd = session_workdir("/data/out", "20260730-101010-abcdef")
    d = _driver(workdir=wd)
    roots = set()
    for _entry, cfg in wl.materialize():
        cmd = d.command(cfg, backend="native")
        roots.add(cmd[cmd.index("--shared-assets") + 1])
    assert roots == {"/data/out/shared"}
