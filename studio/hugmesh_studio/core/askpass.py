"""SUDO_ASKPASS password acquisition — Qt-free, testable, contract-honoring.

Issues #221 / #222. The SUDO_ASKPASS contract is precise: the elevation program
(``sudo -A``, or an operator-supplied askpass) *execs* this helper, reads the
password from the helper's **stdout**, and feeds it to the privileged command.
Nothing else may touch that stdout. So this module obeys three rules:

* **Only the password reaches stdout** — one line, then EOF. Every prompt,
  diagnostic, and error goes to **stderr**. Under a GUI-launched native build the
  helper's stderr is folded into the build log (``stderr=STDOUT`` on the build
  Popen), so the password must never appear on stderr either — it is returned to
  the ``--askpass`` entry point, which writes it to stdout and nowhere else.
* **A cancel / no-password returns ``None``** so the entry point exits non-zero
  and the elevation program ABORTS. The old GUI-only helper had no non-graphical
  path at all: run without a reachable display it blocks forever (``sudo -A``
  then hangs), and run directly from a terminal for CLI automation it merely
  printed the password to that terminal with nothing to consume it (#221). Both
  are fixed by the ordered acquisition below.
* **It is CLI-usable** (#221): an operator or a test harness can drive elevation
  without the Qt dialog — via an env-supplied password, an operator's own askpass
  program, or a plain terminal prompt.

Acquisition order (first that can answer wins):

1. ``HUGMESH_STUDIO_SUDO_PASSWORD`` — a literal password in the environment
   (unattended CLI automation). Presence, not truthiness, selects it.
2. ``HUGMESH_STUDIO_ASKPASS_COMMAND`` — a command whose stdout is the password
   (relay an operator-supplied external askpass / secret manager).
3. The **Qt dialog**, when ``allow_gui`` and a display is reachable — the
   behaviour a GUI-launched build was designed around.
4. A **terminal prompt** (``getpass``), when a controlling tty is available —
   the interactive CLI path.
5. ``None`` — nothing could answer; the caller exits non-zero and elevation
   aborts cleanly.

``--askpass-no-gui`` (``allow_gui=False``) skips step 3 so a CLI/automation run
never pops a dialog even on a desktop with a live display.
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import TextIO

#: A literal admin password for unattended elevation (CLI test automation, #221).
PASSWORD_ENV = "HUGMESH_STUDIO_SUDO_PASSWORD"
#: A command whose stdout is the admin password (operator-supplied askpass relay).
COMMAND_ENV = "HUGMESH_STUDIO_ASKPASS_COMMAND"

#: Stable stderr marker written on cancel/failure. The build driver watches for it
#: (folded into the build log) to attribute a non-zero build to a cancelled prompt
#: rather than a real build failure. Keep the text stable — it is a contract.
CANCEL_MARKER = "hugmesh-studio askpass: no password provided (elevation cancelled)"


def _display_available() -> bool:
    """True iff a Qt dialog could plausibly render (a Wayland or X11 display)."""
    from . import platform_info
    return platform_info.detect_session() != platform_info.SESSION_NONE


def _from_env_password() -> str | None:
    """The literal ``HUGMESH_STUDIO_SUDO_PASSWORD`` if set, else ``None``.

    Presence selects it, so an intentionally empty value is honoured (and will be
    rejected by sudo like any wrong password) instead of silently falling through
    to a dialog an unattended run cannot answer."""
    return os.environ.get(PASSWORD_ENV) if PASSWORD_ENV in os.environ else None


def _from_env_command(stderr: TextIO) -> str | None:
    """Run ``HUGMESH_STUDIO_ASKPASS_COMMAND`` and return the first stdout line, or
    ``None`` if it is unset, fails, or yields nothing. Its own stderr is inherited
    (never our stdout), so a chained askpass keeps its diagnostics off the password
    channel."""
    cmd = os.environ.get(COMMAND_ENV)
    if not cmd:
        return None
    try:
        proc = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, text=True)
    except OSError as e:
        stderr.write(f"hugmesh-studio askpass: {COMMAND_ENV} could not run: {e}\n")
        return None
    if proc.returncode != 0:
        stderr.write(f"hugmesh-studio askpass: {COMMAND_ENV} exited "
                     f"{proc.returncode}\n")
        return None
    # First line only — a trailing newline from the helper is not part of the secret.
    out = proc.stdout
    return out.split("\n", 1)[0] if out else None


def _from_terminal(prompt: str, stderr: TextIO) -> str | None:
    """Prompt on the controlling terminal with echo off (``getpass``). Returns the
    entry (possibly empty) or ``None`` when there is no usable tty / on EOF or
    interrupt. The prompt is written to ``stderr`` (or /dev/tty by getpass), never
    stdout, so it can never contaminate the password channel."""
    import getpass

    # A controlling terminal is REQUIRED — and it must be one getpass can read with
    # echo OFF. Probe /dev/tty by actually opening it: the device node exists even
    # when the process has no controlling terminal (so os.path.exists is not enough),
    # and if getpass cannot open it, its fallback reads sys.stdin WITH ECHO — never an
    # acceptable place to type a password. If /dev/tty is not openable, do not prompt.
    try:
        os.close(os.open("/dev/tty", os.O_RDWR))
    except OSError:
        return None
    try:
        return getpass.getpass(prompt, stream=stderr)
    except (EOFError, KeyboardInterrupt):
        stderr.write("\n")
        return None
    except OSError:
        return None


def _from_gui(prompt: str, argv: list[str] | None) -> str | None:
    """The Qt password dialog. ``None`` on cancel or when Qt/display is unavailable.
    Imported lazily so every non-GUI path (and every unit test) stays Qt-free."""
    try:
        from ..gui.qt import QtWidgets
    except Exception:                                   # Qt not installed
        return None
    # A minimal QApplication (no wizard/tray). The helper is normally its own
    # short-lived process, so there is no pre-existing instance to reuse; construct
    # one exactly as the old inline branch did.
    app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    pw, ok = QtWidgets.QInputDialog.getText(
        None, "HugMesh Image Studio — Administrator access", prompt,
        QtWidgets.QLineEdit.EchoMode.Password)
    del app
    return pw if ok else None


def acquire_password(*, allow_gui: bool = True, prompt: str | None = None,
                     argv: list[str] | None = None,
                     stderr: TextIO | None = None) -> str | None:
    """Obtain the admin password by the first method that can answer, or ``None``.

    ``None`` means the caller MUST exit non-zero so the elevation program aborts
    rather than run the build un-elevated. Never writes to stdout — the caller owns
    the password channel."""
    err = stderr if stderr is not None else sys.stderr
    prompt = prompt or os.environ.get("SUDO_PROMPT") \
        or "Administrator password required to build the image: "

    pw = _from_env_password()
    if pw is not None:
        return pw

    pw = _from_env_command(err)
    if pw is not None:
        return pw

    if allow_gui and _display_available():
        pw = _from_gui(prompt, argv)
        if pw is not None:
            return pw
        # A dialog was shown and cancelled -> honour the cancel; do not silently
        # fall through to a terminal prompt the operator did not ask for.
        err.write(CANCEL_MARKER + "\n")
        return None

    pw = _from_terminal(prompt, err)
    if pw is not None:
        return pw

    err.write(CANCEL_MARKER + "\n")
    return None


#: sudo's own auth-failure signatures (C/POSIX-locale English). The build runs
#: under sudo -A, whose stderr is folded into the build log; the driver scans for
#: these plus CANCEL_MARKER to tell a cancelled prompt from a real build failure.
SUDO_AUTH_FAILURE_MARKERS = (
    CANCEL_MARKER,
    "incorrect password attempt",
    "a password is required",
    "no password was provided",
    "a terminal is required to read the password",
    "no askpass program specified",
    "sudo: no tty present",
)


def looks_like_auth_failure(text: str) -> bool:
    """True iff ``text`` (a build log line, or accumulated tail) carries a sudo
    elevation-auth-failure / cancel signature."""
    low = text.lower()
    return any(m in low for m in SUDO_AUTH_FAILURE_MARKERS)


def run_askpass(argv: list[str] | None = None, *, allow_gui: bool = True) -> int:
    """The ``--askpass`` entry point. Acquire the password and write ONLY it to
    stdout (one line), returning 0; on cancel/failure write nothing to stdout and
    return 1 so ``sudo -A`` aborts elevation. This is the sole writer of the
    password channel."""
    pw = acquire_password(allow_gui=allow_gui, argv=argv)
    if pw is None:
        return 1
    sys.stdout.write(pw + "\n")
    sys.stdout.flush()
    return 0
