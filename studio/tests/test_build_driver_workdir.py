"""The runtime-only workdir override — the golden-gate proof obligations (no Qt).

The per-session artifact dir is a DRIVER argument applied only at GUI dispatch;
every golden channel constructs its driver with no workdir, so the parameter must be
dead code there: BuildDriver(d).command(cfg) must be byte-identical to
BuildDriver(d, workdir=None).command(cfg), and a set workdir may change ONLY the
-w value (native) / the -v out-mount value (docker) — never any other token, and
never the config itself (--print-specs / save round-trip untouched).
"""
import os

import pytest

from snapdragon_studio.core.build_driver import BuildDriver
from snapdragon_studio.core.config import ImageConfig
from snapdragon_studio.core.platform_info import HostInfo
from snapdragon_studio.core.worklist import synthesize
from snapdragon_studio.core.worklist_driver import WorklistDriver


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="snapdragon-builder")


def cfg_for(tmp_path, **kw):
    return ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                       brand="acme", output_dir=str(tmp_path / "out"), jobs=4, **kw)


def test_default_workdir_is_dead_code_byte_identical(tmp_path):
    """Golden gate: no-workdir == workdir=None, for both backends."""
    cfg = cfg_for(tmp_path)
    plain = BuildDriver(str(tmp_path), host())
    explicit = BuildDriver(str(tmp_path), host(), workdir=None)
    for backend in ("native", "docker"):
        a = plain.command(cfg, backend)
        b = explicit.command(cfg, backend)
        if "--name" in a:      # container names are per-driver-instance random
            a[a.index("--name") + 1] = b[b.index("--name") + 1] = "NAME"
        assert a == b


def test_native_workdir_changes_only_the_w_token(tmp_path):
    cfg = cfg_for(tmp_path)
    base = BuildDriver(str(tmp_path), host()).command(cfg, "native")
    over = BuildDriver(str(tmp_path), host(),
                       workdir=str(tmp_path / "out" / "sessions" / "S1")
                       ).command(cfg, "native")
    assert len(base) == len(over)
    diffs = [(a, b) for a, b in zip(base, over) if a != b]
    assert diffs == [(str(tmp_path / "out"),
                      str(tmp_path / "out" / "sessions" / "S1"))]
    assert base[base.index("-w") + 1] == str(tmp_path / "out")
    assert over[over.index("-w") + 1] == str(tmp_path / "out" / "sessions" / "S1")


def test_docker_workdir_changes_only_the_out_mount(tmp_path):
    """The inner argv keeps `-w /out` verbatim; only the -v host-side value moves."""
    cfg = cfg_for(tmp_path)
    sd = str(tmp_path / "out" / "sessions" / "S1")
    base = BuildDriver(str(tmp_path), host()).command(cfg, "docker")
    over = BuildDriver(str(tmp_path), host(), workdir=sd).command(cfg, "docker")
    # container names are per-driver-instance random — normalize before comparing
    base[base.index("--name") + 1] = over[over.index("--name") + 1] = "NAME"
    assert len(base) == len(over)
    diffs = [(a, b) for a, b in zip(base, over) if a != b]
    assert diffs == [(f"{tmp_path / 'out'}:/out", f"{sd}:/out")]
    assert base[-1] == over[-1]                      # inner `bash -c` argv identical


def test_workdir_never_leaks_into_the_config(tmp_path):
    """--print-specs honesty: the session dir is driver state, not config state."""
    cfg = cfg_for(tmp_path)
    before = cfg.to_dict()
    d = BuildDriver(str(tmp_path), host(), workdir=str(tmp_path / "sess"))
    d.command(cfg, "native")
    d.command(cfg, "docker")
    assert cfg.to_dict() == before
    assert cfg.output_dir == str(tmp_path / "out")


def test_worklist_driver_threads_workdir_everywhere(tmp_path):
    sd = str(tmp_path / "out" / "sessions" / "S1")
    wl = synthesize(cfg_for(tmp_path))
    plain = WorklistDriver(str(tmp_path), wl, host=host(), backend="native")
    over = WorklistDriver(str(tmp_path), wl, host=host(), backend="native", workdir=sd)
    assert plain._output_dir() == str(tmp_path / "out")
    assert over._output_dir() == sd
    (_e, mcfg), = over.materialize()
    # command_string (the Review preview channel) must show the session -w
    assert f"-w {sd}" in over.command_string(mcfg)
    assert f"-w {tmp_path / 'out'}" in plain.command_string(mcfg)


def test_run_creates_the_session_dir_via_override(tmp_path, monkeypatch):
    """run() makedirs the OVERRIDDEN out dir (the existing makedirs, new expression)."""
    sd = tmp_path / "out" / "sessions" / "S1"
    d = BuildDriver(str(tmp_path), host(), workdir=str(sd))

    calls = {}

    def fake_stream(cmd, on_line, backend):
        calls["cmd"] = cmd
        return 0

    monkeypatch.setattr(d, "_stream", fake_stream)
    assert d.run(cfg_for(tmp_path), "native") == 0
    assert sd.is_dir()
    assert calls["cmd"][calls["cmd"].index("-w") + 1] == str(sd)
