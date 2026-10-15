"""BuildDriver privilege-elevation path (bug B: GUI-launched native builds).

A GUI-launched non-root native build must NOT prepend a bare `sudo` — its password
prompt goes to an invisible terminal and the build hangs. When ``graphical=True`` the
driver elevates through a GRAPHICAL auth path (``sudo -A`` with a Qt SUDO_ASKPASS helper,
else ``pkexec``); a terminal/headless launch (``graphical=False``, the default) keeps the
plain terminal `sudo` so the printed command stays copy-pasteable and the sudo-prefix
strippers (test_headless / build-matrix check.sh) keep matching. The kill-tree wrap must
reuse the SAME prefix (root-owned tree) and keep the negative-pgid session semantics.

NEVER ELEVATE (2026-09-04): under pytest, or with HUGMESH_STUDIO_NO_ELEVATION set, the
driver must REFUSE to spawn any of those prefixes — ElevationRefused, raised before
subprocess is touched — instead of launching a `sudo -A` that wedges on a password
prompt nobody can answer. The tests here that DO want to see a sudo argv fake the
process layer and say so with HUGMESH_STUDIO_ALLOW_ELEVATION_UNDER_TEST=1
(_allow_under_test); tests/conftest.py's spy on the real Popen backs that opt-out.
"""
import os
import subprocess

import pytest

from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo


def host(is_root=False, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def _cfg(tmp_path, platform="rpi5", role="pki"):
    return ImageConfig(mode="mesh", role=role, platform=platform, tailscale=True,
                       output_dir=str(tmp_path / "out"), jobs=4)


def _force_sudo_a(monkeypatch, askpass="/run/studio-askpass.sh"):
    """sudo present + askpass helper available -> the sudo -A primary path."""
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: askpass)


def _allow_under_test(monkeypatch):
    """This test's SUBJECT is the sudo/pkexec argv or its env plumbing: it fakes
    subprocess and needs the driver to reach the fake. Declared, never implicit."""
    monkeypatch.setenv(bd.ALLOW_ELEVATION_UNDER_TEST_ENV, "1")


def _force_pkexec(monkeypatch):
    """No askpass helper writable, pkexec present -> the pkexec fallback path."""
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: None)
    monkeypatch.setattr(bd.shutil, "which",
                        lambda name: "/usr/bin/pkexec" if name == "pkexec" else None)


# ── prefix selection ─────────────────────────────────────────────────────────────────
def test_terminal_launch_keeps_plain_sudo(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=False)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:2] == ["sudo", "bash"]            # unchanged terminal path
    assert d._elevation_prefix() == ["sudo"]
    assert d._elevation_env() is None             # inherit ambient env untouched


def test_root_never_elevates_even_graphical(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:1] == ["bash"]                    # no wrapper at all
    assert d._elevation_prefix() == []
    assert d._elevation_env() is None


def test_gui_launch_uses_sudo_dash_A_with_askpass(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:3] == ["sudo", "-A", "bash"]      # graphical auth, not a bare sudo
    env = d._elevation_env()
    assert env is not None and env["SUDO_ASKPASS"] == "/run/ap.sh"


def test_gui_launch_falls_back_to_pkexec(monkeypatch, tmp_path):
    _force_pkexec(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:2] == ["pkexec", "bash"]
    assert d._elevation_env() is None             # pkexec needs no SUDO_ASKPASS


def test_gui_env_wrapper_stays_inside_elevation_boundary(monkeypatch, tmp_path):
    """HEADSCALE_URL's `env K=V` wrapper must sit AFTER the graphical prefix (sudo -A /
    pkexec both env_reset), exactly as it did after a plain sudo."""
    _force_sudo_a(monkeypatch)
    cfg = _cfg(tmp_path, "x86", "omnibus")
    cfg.headscale_url = "https://hs.acme.example"
    cmd = BuildDriver(str(tmp_path), host(is_root=False), graphical=True).command(cfg, "native")
    assert cmd[:4] == ["sudo", "-A", "env", "HEADSCALE_URL=https://hs.acme.example"]
    assert cmd[4] == "bash"


# ── kill-tree ────────────────────────────────────────────────────────────────────────
class _GracefulProc:
    pid = 4321

    def wait(self, timeout=None):
        return 0            # exits on TERM -> no KILL escalation

    def poll(self):
        return None


def _capture_run(monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append((list(cmd), kwargs.get("env")))
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(bd.subprocess, "run", fake_run)
    return calls


def test_kill_tree_reuses_graphical_prefix_and_negative_pgid(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _allow_under_test(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 4321, _GracefulProc()
    d.cancel()
    cmd, env = calls[0]
    assert cmd == ["sudo", "-A", "kill", "-TERM", "-4321"]   # SAME prefix, negative pgid
    assert env["SUDO_ASKPASS"] == "/run/ap.sh"


def test_kill_tree_terminal_launch_still_plain_sudo(monkeypatch, tmp_path):
    """Regression guard: a NON-graphical non-root cancel keeps the plain sudo kill (the
    existing test_build_driver_cancel invariant) with no SUDO_ASKPASS env."""
    _allow_under_test(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=False)
    calls = _capture_run(monkeypatch)
    d._backend, d._pgid, d._proc = "native", 7777, _GracefulProc()
    d.cancel()
    cmd, env = calls[0]
    assert cmd == ["sudo", "kill", "-TERM", "-7777"]
    assert env is None


# ── env plumbing into Popen ──────────────────────────────────────────────────────────
class _FakeProc:
    def __init__(self, pid=999):
        self.pid = pid
        self.stdout = iter([])

    def wait(self, timeout=None):
        return 0


def _capture_popen(monkeypatch):
    seen = {}

    def fake_popen(cmd, **kwargs):
        seen.update(kwargs)
        seen["cmd"] = list(cmd)
        return _FakeProc()

    monkeypatch.setattr(bd.subprocess, "Popen", fake_popen)
    return seen


def test_spawn_native_graphical_plumbs_askpass_env(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _allow_under_test(monkeypatch)
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d.run(_cfg(tmp_path), "native")
    assert seen["env"]["SUDO_ASKPASS"] == "/run/ap.sh"   # caller env carries it for sudo
    assert seen["start_new_session"] is True             # kill-tree session preserved


def test_spawn_docker_inherits_env_even_when_graphical(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch)
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d.run(_cfg(tmp_path, "x86", "omnibus"), "docker")
    assert seen["env"] is None                           # docker never elevates -> inherit
    assert seen["start_new_session"] is False


# ── the askpass helper file itself ───────────────────────────────────────────────────
def test_askpass_helper_is_written_executable_and_self_contained(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    p = bd._askpass_helper_path()
    assert p and os.access(p, os.X_OK)
    body = open(p, encoding="utf-8").read()
    assert "--askpass-gui" in body and "hugmesh_studio" in body
    assert body.startswith("#!")


def test_generated_helper_opts_into_the_dialog_explicitly(monkeypatch, tmp_path):
    """The dialog is an OPT-IN the driver makes on the GUI's behalf — the generated
    helper passes --askpass-gui, never the bare --askpass (which fails fast without a
    TTY). A helper that dropped the flag would turn every GUI-launched build into a
    cancelled elevation; one that used --askpass-no-gui would do the same."""
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    body = open(bd._askpass_helper_path(), encoding="utf-8").read()
    exec_line = [ln for ln in body.splitlines() if ln.startswith("exec ")]
    assert len(exec_line) == 1 and exec_line[0].endswith("-m hugmesh_studio --askpass-gui")


# ── NEVER ELEVATE: the refusal, before subprocess is touched ─────────────────────────
# The 2026-09-04 hang at the driver: a GUI-launched native build dispatched under
# pytest used to Popen `sudo -A bash ./build-x86-host-stage4.sh` for real, with the Qt
# askpass as SUDO_ASKPASS; under QT_QPA_PLATFORM=offscreen the dialog was invisible and
# the root-owned sudo waited forever (60 found, some two days old). The driver now
# raises ElevationRefused instead — a clear error a test can assert — under pytest or
# HUGMESH_STUDIO_NO_ELEVATION, for every elevation prefix and for the kill-tree too.
def _popen_must_not_be_reached(monkeypatch):
    monkeypatch.setattr(bd.subprocess, "Popen", lambda *a, **k: pytest.fail(
        "subprocess.Popen was reached — the refusal must come first"))


def _run_must_not_be_reached(monkeypatch):
    monkeypatch.setattr(bd.subprocess, "run", lambda *a, **k: pytest.fail(
        "subprocess.run was reached — the refusal must come first"))


def test_under_pytest_a_graphical_native_build_is_refused_before_any_spawn(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _popen_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    with pytest.raises(bd.ElevationRefused, match=r"refusing to spawn sudo \(pytest"):
        d.run(_cfg(tmp_path), "native")


def test_under_pytest_a_terminal_launch_is_refused_too(monkeypatch, tmp_path):
    """Plain `sudo` (graphical=False) blocks on the controlling tty instead — under a
    test runner that is just as unanswerable."""
    _popen_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=False)
    with pytest.raises(bd.ElevationRefused, match="refusing to spawn sudo"):
        d.run(_cfg(tmp_path), "native")


def test_under_pytest_pkexec_is_refused_too(monkeypatch, tmp_path):
    _force_pkexec(monkeypatch)
    _popen_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    with pytest.raises(bd.ElevationRefused, match="refusing to spawn pkexec"):
        d.run(_cfg(tmp_path), "native")


def test_under_pytest_the_kill_tree_is_refused_too(monkeypatch, tmp_path):
    """cancel() elevates through the same prefix — a `sudo -A kill` would hang on the
    same askpass. Refused the same way."""
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _run_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d._backend, d._pgid, d._proc = "native", 4321, _GracefulProc()
    with pytest.raises(bd.ElevationRefused, match="refusing to spawn sudo"):
        d.cancel()


def test_refusal_message_never_carries_the_builder_argv_secrets(monkeypatch, tmp_path):
    """A builder argv can carry --user-password / --root-password. The error names
    the leading tokens only."""
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _popen_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    with pytest.raises(bd.ElevationRefused) as ei:
        d.run(_cfg(tmp_path, "x86", "pki"), "native")
    msg = str(ei.value)
    assert "sudo -A bash ./build-x86-host-stage4.sh" in msg
    assert "--role" not in msg and "--with-tailscale" not in msg   # argv is cut short


def test_root_native_is_not_refused(monkeypatch, tmp_path):
    """No elevation program in the argv -> nothing to refuse: the spawn proceeds."""
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=True), graphical=True)
    d.run(_cfg(tmp_path), "native")
    assert seen["cmd"][0] == "bash"


def test_docker_is_not_refused(monkeypatch, tmp_path):
    _force_sudo_a(monkeypatch)
    seen = _capture_popen(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    d.run(_cfg(tmp_path, "x86", "omnibus"), "docker")
    assert seen["cmd"][0] == "docker"


def test_the_declared_opt_out_reaches_the_fake(monkeypatch, tmp_path):
    """HUGMESH_STUDIO_ALLOW_ELEVATION_UNDER_TEST=1 is what the argv-asserting tests
    above rely on; pinned here so a refusal that ignored it is noticed."""
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _allow_under_test(monkeypatch)
    seen = _capture_popen(monkeypatch)
    BuildDriver(str(tmp_path), host(is_root=False), graphical=True).run(_cfg(tmp_path), "native")
    assert seen["cmd"][:2] == ["sudo", "-A"]


def test_no_elevation_env_refuses_outside_pytest(monkeypatch, tmp_path):
    """The production knob: with pytest out of the picture, HUGMESH_STUDIO_NO_ELEVATION
    alone refuses — headless automation / CI / a box with no admin password."""
    monkeypatch.setattr(bd.state_paths, "under_pytest", lambda: False)
    monkeypatch.setenv(bd.NO_ELEVATION_ENV, "1")
    _force_sudo_a(monkeypatch, askpass="/run/ap.sh")
    _popen_must_not_be_reached(monkeypatch)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    with pytest.raises(bd.ElevationRefused, match=bd.NO_ELEVATION_ENV):
        d.run(_cfg(tmp_path), "native")


def test_no_elevation_env_wins_over_the_test_opt_out(monkeypatch):
    monkeypatch.setenv(bd.NO_ELEVATION_ENV, "yes")
    _allow_under_test(monkeypatch)
    assert bd.NO_ELEVATION_ENV in (bd.elevation_refusal() or "")


@pytest.mark.parametrize("off", ["", "0", "off", "false", "no", " No "])
def test_no_elevation_env_off_values_do_not_refuse(monkeypatch, off):
    monkeypatch.setattr(bd.state_paths, "under_pytest", lambda: False)
    monkeypatch.setenv(bd.NO_ELEVATION_ENV, off)
    assert bd.elevation_refusal() is None


def test_outside_pytest_with_nothing_set_elevation_is_allowed(monkeypatch):
    """PR #239's contract, kept: a real operator run (no pytest, no env knob) elevates
    exactly as before — the refusal is silent absence, not a new prompt."""
    monkeypatch.setattr(bd.state_paths, "under_pytest", lambda: False)
    monkeypatch.delenv(bd.NO_ELEVATION_ENV, raising=False)
    monkeypatch.delenv(bd.ALLOW_ELEVATION_UNDER_TEST_ENV, raising=False)
    assert bd.elevation_refusal() is None
    bd.guard_elevation(["sudo", "-A", "bash", "./build-x86-host-stage4.sh"])   # no raise


def test_guard_ignores_commands_that_do_not_elevate():
    for cmd in (["bash", "./build.sh"], ["docker", "run"], ["env", "X=1", "bash"], []):
        bd.guard_elevation(cmd)


# ── preflight must NOT block a native build the driver can elevate ───────────────────
# Regression: preflight() appended a BLOCKING problem ("Native build needs root (the
# Studio will prepend sudo)") whenever the Studio was not root. Since a GUI Studio is
# NEVER root, that made every native build permanently undispatchable — blocked by a
# check whose own text said the driver handles it. Real report 2026-07-17: "native
# builds are also failing". Problems BLOCK (Review isComplete / ProgressPage dispatch);
# elevation is an ADVISORY, so it belongs in preflight_warnings().
def test_preflight_does_not_block_native_when_sudo_is_available(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda n: "/usr/bin/sudo" if n == "sudo" else None)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    probs = d.preflight(_cfg(tmp_path, "x86", "pki"), "native")
    assert not [p for p in probs if "elevation helper" in p or "needs root" in p], probs


def test_preflight_does_not_block_native_when_only_pkexec_is_available(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda n: "/usr/bin/pkexec" if n == "pkexec" else None)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    probs = d.preflight(_cfg(tmp_path, "x86", "pki"), "native")
    assert not [p for p in probs if "elevation helper" in p or "needs root" in p], probs


def test_preflight_DOES_block_native_when_no_elevation_helper_exists(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda n: None)   # no sudo, no pkexec
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    probs = d.preflight(_cfg(tmp_path, "x86", "pki"), "native")
    assert [p for p in probs if "no elevation helper" in p], probs


def test_native_elevation_is_surfaced_as_a_warning_not_a_problem(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda n: "/usr/bin/sudo" if n == "sudo" else None)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    warns = d.preflight_warnings(_cfg(tmp_path, "x86", "pki"), "native")
    assert [w for w in warns if "authentication prompt" in w], warns


def test_root_native_neither_blocks_nor_warns_about_elevation(tmp_path):
    d = BuildDriver(str(tmp_path), host(is_root=True), graphical=True)
    assert not [p for p in d.preflight(_cfg(tmp_path, "x86", "pki"), "native")
                if "elevation helper" in p or "needs root" in p]
    assert not [w for w in d.preflight_warnings(_cfg(tmp_path, "x86", "pki"), "native")
                if "authentication prompt" in w]


def test_docker_backend_never_gets_an_elevation_warning(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda n: "/usr/bin/sudo" if n == "sudo" else None)
    d = BuildDriver(str(tmp_path), host(is_root=False), graphical=True)
    assert not [w for w in d.preflight_warnings(_cfg(tmp_path, "x86", "pki"), "docker")
                if "authentication prompt" in w]


# ── #304 item 2: a NON-pytest headless driver must set the knob ────────────────────────
def test_headless_harnesses_and_docs_carry_the_no_elevation_requirement():
    """A GUI-launched build's askpass helper passes --askpass-gui by design, so nothing
    but HUGMESH_STUDIO_NO_ELEVATION protects a non-pytest harness that walks the real
    wizard offscreen. Pin that the one in-tree headless harness exports it (subprocess
    env AND its in-process legs) and that the headless docs state the requirement."""
    import pathlib
    repo = pathlib.Path(__file__).resolve().parents[2]
    harness = (repo / "scripts" / "render-all-images.py").read_text(encoding="utf-8")
    assert harness.count("HUGMESH_STUDIO_NO_ELEVATION") >= 2, (
        "render-all-images.py must set HUGMESH_STUDIO_NO_ELEVATION for its subprocess "
        "env and its in-process legs")
    readme = (repo / "studio" / "README.md").read_text(encoding="utf-8")
    i = readme.index("HUGMESH_STUDIO_NO_ELEVATION")
    assert "offscreen" in readme[max(0, i - 300):i + 600]
