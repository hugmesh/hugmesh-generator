"""SUDO_ASKPASS helper contract (issues #221 / #222).

The helper must: put ONLY the password on stdout (for the elevation program to
consume), fall back to env / operator-command / terminal so it is CLI-usable
without a Qt dialog, and return non-zero on cancel so ``sudo -A`` ABORTS the build
instead of running it un-elevated. The integration test drives the REAL
``python -m hugmesh_studio --askpass`` under a stub ``sudo -A`` and asserts the
password reaches the elevation program only, and a cancel stops the inner command.

NEVER A DIALOG BY FALLBACK (2026-09-04): the Qt dialog is reached ONLY through the
explicit opt-in (``allow_gui=True`` / ``--askpass-gui``, which the driver's generated
helper passes for a GUI-launched build), and the terminal prompt needs a terminal ON
STDIN. A helper with no credential source, no TTY and no opt-in fails fast — exit 1,
nothing on stdout, CANCEL_MARKER on stderr — even with DISPLAY set. Before this the
same shape (a pytest run, QT_QPA_PLATFORM=offscreen, on a desktop) blocked forever on
an invisible dialog, and 60 root-owned `sudo -A` launchers were found hung.
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


def test_gui_used_when_display_present_and_opted_in(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: "typed-in-dialog")
    # terminal must NOT be consulted when the dialog answered
    monkeypatch.setattr(askpass, "_from_terminal",
                        lambda *a, **k: pytest.fail("terminal used despite a dialog"))
    assert askpass.acquire_password(allow_gui=True) == "typed-in-dialog"


def test_gui_is_never_a_fallback_without_the_opt_in(monkeypatch):
    """The 2026-09-04 shape: a display exists, no credential source, no TTY, and the
    caller did NOT opt into a dialog. The old helper popped one anyway (invisible under
    offscreen) and blocked forever. Now: no dialog, decline, marker."""
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui",
                        lambda *a, **k: pytest.fail("dialog shown without the opt-in"))
    monkeypatch.setattr(askpass, "_from_terminal", lambda *a, **k: None)   # no tty
    err = io.StringIO()
    assert askpass.acquire_password(stderr=err) is None            # default: no opt-in
    assert askpass.CANCEL_MARKER in err.getvalue()


def test_gui_cancel_does_not_fall_through_to_terminal(monkeypatch):
    _no_env(monkeypatch)
    monkeypatch.setattr(askpass, "_display_available", lambda: True)
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: None)   # cancelled
    monkeypatch.setattr(askpass, "_from_terminal",
                        lambda *a, **k: pytest.fail("terminal used after a dialog cancel"))
    err = io.StringIO()
    assert askpass.acquire_password(allow_gui=True, stderr=err) is None
    assert askpass.CANCEL_MARKER in err.getvalue()


def test_no_elevation_env_refuses_before_any_source(monkeypatch):
    """HUGMESH_STUDIO_NO_ELEVATION: the process tree has been told not to elevate, so
    the helper answers nothing — not even an env password — and says why on stderr."""
    _no_env(monkeypatch)
    monkeypatch.setenv(askpass.PASSWORD_ENV, "s3cret")
    monkeypatch.setenv(askpass.NO_ELEVATION_ENV, "1")
    monkeypatch.setattr(askpass, "_from_gui", lambda *a, **k: pytest.fail("dialog"))
    monkeypatch.setattr(askpass, "_from_terminal", lambda *a, **k: pytest.fail("tty"))
    err = io.StringIO()
    assert askpass.acquire_password(allow_gui=True, stderr=err) is None
    assert askpass.NO_ELEVATION_ENV in err.getvalue()
    assert askpass.CANCEL_MARKER in err.getvalue()
    assert "s3cret" not in err.getvalue()


@pytest.mark.parametrize("raw,expected", [
    ("1", True), ("yes", True), ("true", True), (" on ", True),
    ("", False), ("0", False), ("off", False), ("false", False), ("no", False),
])
def test_no_elevation_parser(monkeypatch, raw, expected):
    monkeypatch.setenv(askpass.NO_ELEVATION_ENV, raw)
    assert askpass.no_elevation() is expected
    monkeypatch.delenv(askpass.NO_ELEVATION_ENV)
    assert askpass.no_elevation() is False


def test_from_terminal_declines_when_stdin_is_not_a_tty(monkeypatch):
    """The terminal path needs a terminal ON STDIN — /dev/tty existing somewhere is not
    enough (a helper exec'd by `sudo -A` inherits sudo's stdin: /dev/null under a
    .desktop launch, a pipe under a test runner). getpass must never be reached."""
    import getpass
    monkeypatch.setattr(askpass.sys, "stdin", io.StringIO())          # isatty() False
    monkeypatch.setattr(getpass, "getpass", lambda *a, **k: pytest.fail("prompted"))
    assert askpass._from_terminal("pw: ", io.StringIO()) is None


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
    """Only `--askpass-gui` reaches core.askpass as allow_gui=True; `--askpass` and
    `--askpass-no-gui` (#221) are both allow_gui=False, and the no-gui flag wins over an
    explicit opt-in. Pinned by assertion so the plumb is checked on a headless box too:
    the integration tests only notice a wrong allow_gui when a display is reachable
    (the offscreen dialog then blocks until the timeout)."""
    from hugmesh_studio import app

    seen: list[bool] = []
    monkeypatch.setattr(askpass, "run_askpass",
                        lambda argv=None, *, allow_gui=True: seen.append(allow_gui) or 0)
    assert app.main(["--askpass-no-gui"]) == 0
    assert app.main(["--askpass"]) == 0
    assert app.main(["--askpass-gui"]) == 0
    assert app.main(["--askpass-gui", "--askpass-no-gui"]) == 0
    assert seen == [False, False, True, False]


def test_no_gui_flag_help_says_the_terminal_prompt_needs_stdin_on_a_tty(capsys):
    """#370 (Decision 96 = A): the stricter stdin-must-be-a-TTY rule stays, so the
    `--askpass-no-gui` help text must say so (it used to read as the pre-#289 relaxed
    rule). Pinned on the rendered `--help`, whitespace-normalised: the flag's paragraph
    must carry the stdin condition, like `--askpass`'s does."""
    from hugmesh_studio import app

    with pytest.raises(SystemExit):
        app.main(["--help"])
    text = " ".join(capsys.readouterr().out.split())
    start = text.index("kept for #221 scripts")
    end = text.index("--config", start)
    para = text[start:end]
    assert "stdin is a TTY" in para or "stdin must be a TTY" in para, para


def test_run_askpass_defaults_to_no_dialog(monkeypatch):
    """run_askpass's own default is allow_gui=False — a caller that forgets the keyword
    gets the headless-safe path, never the dialog."""
    seen = {}

    def fake_acquire(**kw):
        seen.update(kw)
        return None
    monkeypatch.setattr(askpass, "acquire_password", fake_acquire)
    assert askpass.run_askpass([]) == 1
    assert seen["allow_gui"] is False


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


def _run_detached(argv, env, *, input=None, timeout=60):
    """Run ``argv`` in a NEW SESSION so it (and every child, including the helper sudo
    execs) has NO controlling terminal — /dev/tty is then unopenable and the helper's
    terminal fallback deterministically declines. Without this the outcome depends on
    the harness: under a pty (an interactive run, `script`, some CI runners) the cancel
    case falls through to getpass on the operator's real terminal and blocks until the
    timeout. stdin is closed for the same reason — nothing here may read a password
    from it.

    On timeout the WHOLE session is killed (killpg), not just the direct child: the
    regression these tests exist for is a helper blocked on an offscreen dialog, and
    subprocess.run's own timeout kill would orphan exactly that grandchild."""
    proc = subprocess.Popen(argv, env=env, text=True, start_new_session=True,
                            stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        import signal
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        raise
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def _write_helper(tmp_path, flag="--askpass-no-gui"):
    studio_root = _studio_root()
    helper = tmp_path / "studio-askpass.sh"
    helper.write_text(
        "#!/bin/sh\n"
        f'export PYTHONPATH="{studio_root}${{PYTHONPATH:+:$PYTHONPATH}}"\n'
        f"exec {sys.executable} -m hugmesh_studio {flag}\n")
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


def _headless_env(helper, **extra):
    """No credential source, no TTY (see _run_detached), and a display that LOOKS
    reachable (DISPLAY set — _display_available() is True on any box) rendered
    offscreen: the exact shape of the hung pytest launchers."""
    env = {**os.environ, "SUDO_ASKPASS": str(helper), "DISPLAY": ":99",
           "QT_QPA_PLATFORM": "offscreen", **extra}
    for k in (askpass.PASSWORD_ENV, askpass.COMMAND_ENV, askpass.NO_ELEVATION_ENV,
              "WAYLAND_DISPLAY"):
        env.pop(k, None)
    return env


def test_integration_headless_helper_fails_fast_even_with_a_display(tmp_path):
    """THE 2026-09-04 defect, end to end: the real `--askpass` helper under a stub
    `sudo -A`, no credential source, stdin not a TTY, DISPLAY set. It used to pop an
    offscreen Qt dialog and block until this test's 60 s timeout (and, under real sudo,
    forever). It must now decline at once: exit 1, nothing on stdout, the marker on
    stderr, the inner command never run."""
    import time
    helper, stub = _write_helper(tmp_path, flag="--askpass")
    t0 = time.monotonic()
    r = _run_detached([sys.executable, str(stub), "-A", "/bin/echo", "INNER-RAN"],
                      _headless_env(helper))
    elapsed = time.monotonic() - t0
    assert r.returncode == 1, (r.stdout, r.stderr)
    assert "INNER-RAN" not in r.stdout
    assert r.stdout == ""                          # nothing on the password channel
    assert askpass.CANCEL_MARKER in r.stderr
    assert elapsed < 30, f"helper took {elapsed:.1f}s — it blocked on something"


def test_integration_no_elevation_env_refuses_even_the_gui_opt_in(tmp_path):
    """Defence in depth: even the driver's own --askpass-gui helper answers nothing
    under HUGMESH_STUDIO_NO_ELEVATION (sudo hands the helper the caller's env — measured
    on the hung launchers: DISPLAY, HOME, QT_QPA_PLATFORM all reached it)."""
    helper, stub = _write_helper(tmp_path, flag="--askpass-gui")
    env = _headless_env(helper)
    env[askpass.NO_ELEVATION_ENV] = "1"
    r = _run_detached([sys.executable, str(stub), "-A", "/bin/echo", "INNER-RAN"], env)
    assert r.returncode == 1, (r.stdout, r.stderr)
    assert "INNER-RAN" not in r.stdout and r.stdout == ""
    assert askpass.NO_ELEVATION_ENV in r.stderr and askpass.CANCEL_MARKER in r.stderr


def test_integration_gui_opt_in_still_takes_an_env_credential_first(tmp_path):
    """PR #239's unattended contract survives the opt-in: a credential source answers
    before any dialog, so the --askpass-gui helper is fully scriptable too."""
    helper, stub = _write_helper(tmp_path, flag="--askpass-gui")
    env = _headless_env(helper)
    env[askpass.PASSWORD_ENV] = "corncob"
    r = _run_detached([sys.executable, str(stub), "-A", "/bin/echo", "INNER-RAN"], env)
    assert r.returncode == 0, (r.stdout, r.stderr)
    assert "INNER-RAN" in r.stdout and "corncob" not in r.stdout
    assert "got 7-char password via pipe" in r.stderr


def test_from_terminal_declines_on_a_non_tty_stdin_even_with_a_controlling_tty():
    """The stdin-isatty rule, proved where it differs from the /dev/tty probe: a child
    that HAS a controlling terminal (a pty it acquires with TIOCSCTTY) but whose stdin
    is /dev/null — a Studio launched from a terminal with `</dev/null`, a CI runner
    under `script`, `sudo -A cmd </dev/null` from a shell. Without the rule getpass
    opens /dev/tty and reads the pty (the "typed-on-pty" line waiting there); with it
    the helper declines at once. Mutation: drop the isatty check and this returns
    'typed-on-pty'."""
    import pty
    master, slave = pty.openpty()
    code = textwrap.dedent(f"""
        import fcntl, os, sys, termios
        from hugmesh_studio.core import askpass
        fd = os.open({os.ttyname(slave)!r}, os.O_RDWR)
        fcntl.ioctl(fd, termios.TIOCSCTTY, 0)      # this pty IS the controlling tty
        os.dup2(os.open(os.devnull, os.O_RDONLY), 0)   # ...but stdin is not a terminal
        print(repr(askpass._from_terminal('pw: ', sys.stderr)), flush=True)
    """)
    import time
    env = {**os.environ, "PYTHONPATH": _studio_root()}
    proc = subprocess.Popen([sys.executable, "-c", code], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)      # session leader: may take a ctty
    os.close(slave)
    # Keep the line available on the pty until the child exits: getpass flushes pending
    # input when it switches echo off (TCSAFLUSH), so a single early write is discarded
    # by the very read it is meant to feed. With the rule intact the child exits at
    # once and nothing is read; with it mutated, getpass returns this line.
    deadline = time.monotonic() + 60
    try:
        while proc.poll() is None and time.monotonic() < deadline:
            os.write(master, b"typed-on-pty\n")
            time.sleep(0.05)
        if proc.poll() is None:
            proc.kill()
        out, err = proc.communicate(timeout=10)
    finally:
        os.close(master)
    assert proc.returncode == 0, err
    assert out.strip() == "None", (out, err)


def test_from_terminal_prompts_and_returns_the_line_when_stdin_is_the_tty():
    """The POSITIVE direction of the stdin-isatty rule (#360): the interactive
    `sudo -A` shape (#221 / PR #239 contract). stdin IS a pty that is also the
    controlling tty, stdout is a PIPE (sudo's password channel), no credential env:
    the typed line must come back. Mutation: `sys.stdin` -> `sys.stdout` on the isatty
    line makes this return None while every other askpass test stays green."""
    import pty
    master, slave = pty.openpty()
    code = textwrap.dedent(f"""
        import fcntl, os, sys, termios
        from hugmesh_studio.core import askpass
        fd = os.open({os.ttyname(slave)!r}, os.O_RDWR)
        fcntl.ioctl(fd, termios.TIOCSCTTY, 0)      # this pty IS the controlling tty
        os.dup2(fd, 0)                             # ...and stdin IS that terminal
        print(repr(askpass._from_terminal('pw: ', sys.stderr)), flush=True)
    """)
    import time
    env = {k: v for k, v in os.environ.items()
           if k not in (askpass.PASSWORD_ENV, askpass.NO_ELEVATION_ENV,
                        "HUGMESH_STUDIO_ASKPASS_COMMAND")}
    env["PYTHONPATH"] = _studio_root()
    proc = subprocess.Popen([sys.executable, "-c", code], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    os.close(slave)
    # getpass flushes pending input when it turns echo off (TCSAFLUSH), so keep
    # re-typing the line until the child has read one and exited.
    deadline = time.monotonic() + 60
    try:
        while proc.poll() is None and time.monotonic() < deadline:
            os.write(master, b"typed-on-pty\n")
            time.sleep(0.05)
        if proc.poll() is None:
            proc.kill()
        out, err = proc.communicate(timeout=10)
    finally:
        os.close(master)
    assert proc.returncode == 0, err
    assert out.strip() == "'typed-on-pty'", (out, err)


def test_from_terminal_never_reads_stdin_without_a_controlling_tty():
    """The /dev/tty openability probe in _from_terminal is relied on: without a
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
