"""SUDO_ASKPASS helper contract (issues #221 / #222).

The helper must: put ONLY the password on stdout (for the elevation program to
consume), fall back to env / operator-command / terminal so it is CLI-usable
without a Qt dialog, and return non-zero on cancel so ``sudo -A`` ABORTS the build
instead of running it un-elevated. The integration test drives the REAL
``python -m hugmesh_studio --askpass`` under a stub ``sudo -A`` and asserts the
password reaches the elevation program only, and a cancel stops the inner command.
"""
import io
import os
import subprocess
import sys
import textwrap

import pytest

from hugmesh_studio.core import askpass
from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo


# ── acquisition order ────────────────────────────────────────────────────────────────
def _no_env(monkeypatch):
    monkeypatch.delenv(askpass.PASSWORD_ENV, raising=False)
    monkeypatch.delenv(askpass.COMMAND_ENV, raising=False)
    monkeypatch.delenv("SUDO_PROMPT", raising=False)


def test_env_password_wins_and_is_returned_verbatim(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setenv(askpass.PASSWORD_ENV, "s3cret")
    # even with a display + gui available, the explicit env password takes precedence
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: "DIALOG-SHOULD-NOT-WIN")
    assert askpass.acquire_password() == "s3cret"


def test_empty_env_password_is_honoured_not_skipped(monkeypatch):
    """Presence, not truthiness, selects the env password — so an unattended run never
    silently falls through to a dialog it cannot answer."""
    _no_env(monkeypatch)
    monkeypatch.setenv(askpass.PASSWORD_ENV, "")
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: "NOPE")
    assert askpass.acquire_password() == ""


def test_env_command_relays_first_line_only(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setenv(askpass.COMMAND_ENV, "printf 'pw-line\\nignored-second-line\\n'")
    monkeypatch.setattr(askpass, "_display_available", lambda: False)
    assert askpass.acquire_password(stderr=io.StringIO()) == "pw-line"


def test_env_command_failure_falls_through_to_none(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setenv(askpass.COMMAND_ENV, "exit 7")
    monkeypatch.setattr(askpass, "_display_available", lambda: False)
    monkeypatch.setattr(askpass, "_from_terminal", lambda *a, **k: None)
    err = io.StringIO()
    assert askpass.acquire_password(stderr=err) is None
    assert askpass.CANCEL_MARKER in err.getvalue()


def test_gui_used_when_display_present(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: "typed-in-dialog")
    # terminal must NOT be consulted when the dialog answered
    monkeypatch.setattr(askpass, "_from_terminal",
                        lambda *a, **k: pytest.fail("terminal used despite a dialog"))
    assert askpass.acquire_password() == "typed-in-dialog"


def test_gui_cancel_does_not_fall_through_to_terminal(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: None)   # cancelled
    monkeypatch.setattr(askpass, "_from_terminal",
                        lambda *a, **k: pytest.fail("terminal used after a dialog cancel"))
    err = io.StringIO()
    assert askpass.acquire_password(stderr=err) is None
    assert askpass.CANCEL_MARKER in err.getvalue()


def test_no_gui_flag_skips_dialog_even_with_display(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui",
                        lambda *a, **k: pytest.fail("dialog shown under allow_gui=False"))
    monkeypatch.setattr(askpass, "_from_terminal", lambda *a, **k: "from-tty")
    assert askpass.acquire_password(allow_gui=False) == "from-tty"


def test_terminal_used_when_no_display(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: False)
    monkeypatch.setattr(askpass, "_from_terminal", lambda *a, **k: "typed-on-tty")
    assert askpass.acquire_password() == "typed-on-tty"


# ── run_askpass: the password channel ────────────────────────────────────────────────
def test_run_askpass_writes_only_password_to_stdout(monkeypatch, capsys):
    monkeypatch.setattr(askpass, "acquire_password", lambda **k: "the-pass")
    rc = askpass.run_askpass([])
    out = capsys.readouterr()
    assert rc == 0
    assert out.out == "the-pass\n"        # EXACTLY the password + newline, nothing else
    assert "the-pass" not in out.err      # never leaks onto stderr (folded into build log)


def test_run_askpass_cancel_returns_nonzero_and_writes_no_stdout(monkeypatch, capsys):
    monkeypatch.setattr(askpass, "acquire_password", lambda **k: None)
    rc = askpass.run_askpass([])
    out = capsys.readouterr()
    assert rc == 1
    assert out.out == ""                  # nothing on the password channel -> sudo aborts


def test_cli_flags_plumb_allow_gui_to_the_helper(monkeypatch):
    """`--askpass-no-gui` reaches core.askpass as allow_gui=False and plain `--askpass`
    as allow_gui=True — pinned by assertion here so the plumb is checked on a headless
    box too: the integration test below only notices a lost `allow_gui=False` when a
    display is reachable (the offscreen dialog then blocks until the 60s timeout)."""
    from hugmesh_studio import app

    seen: list[bool] = []
    monkeypatch.setattr(askpass, "run_askpass",
                        lambda argv=None, *, allow_gui=True: seen.append(allow_gui) or 0)
    assert app.main(["--askpass-no-gui"]) == 0
    assert app.main(["--askpass"]) == 0
    assert seen == [False, True]


# ── auth-failure signature scan ──────────────────────────────────────────────────────
@pytest.mark.parametrize("line", [
    askpass.CANCEL_MARKER,
    "sudo: 3 incorrect password attempts",
    "sudo: a password is required",
    "sudo: no askpass program specified",
])
def test_looks_like_auth_failure_matches_known_markers(line):
    assert askpass.looks_like_auth_failure(line)


def test_looks_like_auth_failure_ignores_ordinary_build_lines():
    assert not askpass.looks_like_auth_failure(
        "[build-x86] ERROR: stage4 payload incomplete — missing: grub-install")


# ── driver: operator-supplied SUDO_ASKPASS is honoured (#221) ────────────────────────
def _host(is_root=False):
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def _cfg(tmp_path):
    return ImageConfig(mode="mesh", role="pki", platform="rpi5", tailscale=True,
                       output_dir=str(tmp_path / "out"), jobs=4)


def test_operator_askpass_is_honoured_over_generated_helper(monkeypatch, tmp_path):
    op = tmp_path / "corp-askpass"
    op.write_text("#!/bin/sh\necho hunter2\n")
    op.chmod(0o755)
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    monkeypatch.setenv("SUDO_ASKPASS", str(op))
    # the driver must NOT generate/overwrite the helper — it defers to the operator's
    monkeypatch.setattr(bd, "_askpass_helper_path",
                        lambda: bd._operator_askpass() or pytest.fail("generated a helper"))
    d = BuildDriver(str(tmp_path), _host(), graphical=True)
    cmd = d.command(_cfg(tmp_path), "native")
    assert cmd[:3] == ["sudo", "-A", "bash"]
    env = d._elevation_env()
    assert env is not None and env["SUDO_ASKPASS"] == str(op)


def test_operator_askpass_deferral_is_live_in_the_real_helper_path(monkeypatch, tmp_path):
    """PRODUCTION wiring, not a stand-in: the test above monkeypatches
    _askpass_helper_path itself, so it exercises _operator_askpass() but can never notice
    the real _askpass_helper_path dropping its deferral (adversarial finding: deleting
    `op = _operator_askpass(); if op is not None: return op` left every test green).
    Here nothing in build_driver is patched except the module cache and `which`; the env
    is prepared and the REAL function chain (_elevation_prefix -> _askpass_helper_path ->
    _operator_askpass, then _elevation_env) must hand sudo the operator's program and
    generate nothing of its own — a generated helper would land in XDG_CACHE_HOME and
    set the module cache, both of which are pinned empty."""
    op = tmp_path / "corp-askpass"
    op.write_text("#!/bin/sh\necho hunter2\n")
    op.chmod(0o755)
    cache = tmp_path / "xdg-cache"                    # where OUR helper would be written
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
    monkeypatch.setenv("SUDO_ASKPASS", str(op))
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")

    assert bd._askpass_helper_path() == str(op)      # the real function defers
    assert bd._ASKPASS_PATH_CACHE is None            # ...and generated nothing
    assert not (cache / "hugmesh-studio" / "studio-askpass.sh").exists()

    d = BuildDriver(str(tmp_path), _host(), graphical=True)
    assert d.command(_cfg(tmp_path), "native")[:3] == ["sudo", "-A", "bash"]
    env = d._elevation_env()
    assert env is not None and env["SUDO_ASKPASS"] == str(op)
    assert bd._ASKPASS_PATH_CACHE is None            # still nothing generated end-to-end


def test_operator_askpass_ignored_when_not_executable(monkeypatch, tmp_path):
    """A stale/non-executable SUDO_ASKPASS never wins — the driver falls back to its
    own generated helper rather than pointing sudo at a dud."""
    monkeypatch.setenv("SUDO_ASKPASS", str(tmp_path / "does-not-exist"))
    monkeypatch.setattr(bd, "_ASKPASS_PATH_CACHE", None)
    assert bd._operator_askpass() is None


# ── driver: a cancelled build is attributed clearly, not left to a later failure (#222)
class _StubStreamProc:
    """Minimal driver test double: run() calls self._stream, which we replace to emit a
    sudo auth-failure line and return sudo's exit code."""


def test_run_attributes_elevation_cancel_when_native_graphical(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: str(tmp_path / "ap.sh"))
    d = BuildDriver(str(tmp_path), _host(), graphical=True)

    def fake_stream(cmd, on_line, backend):
        # sudo -A with a cancelled askpass prints this to stderr (folded into the stream)
        on_line("sudo: a password is required")
        return 1

    monkeypatch.setattr(d, "_stream", fake_stream)
    lines = []
    code = d.run(_cfg(tmp_path), "native", on_line=lines.append)
    assert code == 1
    assert any("authentication was cancelled or failed" in ln for ln in lines), lines


def test_run_does_not_misattribute_a_real_build_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(bd.shutil, "which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr(bd, "_askpass_helper_path", lambda: str(tmp_path / "ap.sh"))
    d = BuildDriver(str(tmp_path), _host(), graphical=True)

    def fake_stream(cmd, on_line, backend):
        on_line("[build-x86] ERROR: stage4 payload incomplete")   # a genuine build error
        return 1

    monkeypatch.setattr(d, "_stream", fake_stream)
    lines = []
    d.run(_cfg(tmp_path), "native", on_line=lines.append)
    assert not any("authentication was cancelled" in ln for ln in lines), lines


# ── INTEGRATION: the real helper under a stub `sudo -A` ───────────────────────────────
_STUB_SUDO = textwrap.dedent("""
    import os, subprocess, sys
    argv = sys.argv[1:]
    assert argv[0] == "-A", argv
    inner = argv[1:]
    helper = os.environ["SUDO_ASKPASS"]
    # sudo captures the helper's STDOUT via a pipe; its stderr is inherited (our stderr).
    proc = subprocess.run([helper], stdout=subprocess.PIPE)
    if proc.returncode != 0:
        sys.stderr.write("stub-sudo: askpass failed -> command NOT run\\n")
        sys.exit(1)
    pw = proc.stdout.decode().rstrip("\\n")
    sys.stderr.write("stub-sudo: got %d-char password via pipe\\n" % len(pw))
    sys.exit(subprocess.call(inner))
""")


def _studio_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(bd.__file__)))


def _run_detached(argv, env, *, input=None):
    """Run ``argv`` in a NEW SESSION so it (and every child, including the helper sudo
    execs) has NO controlling terminal — /dev/tty is then unopenable and the helper's
    terminal fallback deterministically declines. Without this the outcome depends on
    the harness: under a pty (an interactive run, `script`, some CI runners) the cancel
    case falls through to getpass on the operator's real terminal and blocks until the
    timeout. stdin is closed for the same reason — nothing here may read a password
    from it."""
    return subprocess.run(argv, capture_output=True, text=True, env=env, timeout=60,
                          start_new_session=True,
                          input=input, stdin=None if input is not None else subprocess.DEVNULL)


def _write_helper(tmp_path):
    studio_root = _studio_root()
    helper = tmp_path / "studio-askpass.sh"
    helper.write_text(
        "#!/bin/sh\n"
        f'export PYTHONPATH="{studio_root}${{PYTHONPATH:+:$PYTHONPATH}}"\n'
        f"exec {sys.executable} -m hugmesh_studio --askpass-no-gui\n")
    helper.chmod(0o755)
    stub = tmp_path / "stub_sudo.py"
    stub.write_text(_STUB_SUDO)
    return helper, stub


def test_integration_password_reaches_elevation_only_never_the_terminal(tmp_path):
    helper, stub = _write_helper(tmp_path)
    env = {**os.environ, "SUDO_ASKPASS": str(helper),
           askpass.PASSWORD_ENV: "corncob", "QT_QPA_PLATFORM": "offscreen"}
    r = _run_detached([sys.executable, str(stub), "-A", "/bin/echo", "INNER-RAN"], env)
    assert r.returncode == 0
    assert "INNER-RAN" in r.stdout            # elevation succeeded, inner command ran
    assert "corncob" not in r.stdout          # password NEVER on the parent terminal stdout
    assert "corncob" not in r.stderr          # nor stderr (which folds into the build log)
    assert "got 7-char password via pipe" in r.stderr   # sudo consumed it via the pipe


def test_integration_cancel_aborts_the_inner_command(tmp_path):
    helper, stub = _write_helper(tmp_path)
    env = {**os.environ, "SUDO_ASKPASS": str(helper),
           askpass.COMMAND_ENV: "exit 4", "QT_QPA_PLATFORM": "offscreen"}
    env.pop(askpass.PASSWORD_ENV, None)
    r = _run_detached([sys.executable, str(stub), "-A", "/bin/echo", "INNER-RAN"], env)
    assert r.returncode == 1
    assert "INNER-RAN" not in r.stdout        # build did NOT run un-elevated
    assert askpass.CANCEL_MARKER in r.stderr  # the driver's attribution scan can see this


def test_from_terminal_never_reads_stdin_without_a_controlling_tty():
    """The /dev/tty openability probe in _from_terminal is load-bearing: without a
    controlling terminal, getpass's own fallback reads sys.stdin WITH ECHO — never an
    acceptable place for a password. Run the real function in a fresh session (no
    ctty) with a line waiting on stdin and pin that it declines (None) instead of
    consuming that line. Removing the probe makes this return the stdin line."""
    code = ("import sys\nfrom hugmesh_studio.core import askpass\n"
            "print(repr(askpass._from_terminal('pw: ', sys.stderr)))\n")
    env = {**os.environ, "PYTHONPATH": _studio_root()}
    r = _run_detached([sys.executable, "-c", code], env, input="typed-on-stdin\n")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "None"
    assert "typed-on-stdin" not in r.stdout
