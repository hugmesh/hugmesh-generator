"""PhoneWizard — the Qt-free runner behind the ModePage's fifth first-screen choice
("MDM phone"). It flashes a USB-connected Google Pixel with VERIFIED GrapheneOS and
enrolls it as an MDM-managed mesh device — no image build.

Like GoLiveDriver and the Local Docker mesh runner, this front-end is DELIBERATELY
THIN: it only ever shells the ONE canonical driver ``scripts/phone-wizard.sh`` (the
exact same script the ncurses menu's phone_screen/_phone_run drive) and carries NO
wizard logic of its own. The bash driver owns every gate — the fail-closed device
catalog (exit 4 on an unknown codename), the sshsig supply-chain verify, the
typed-serial flash confirmation, the fresh-device device-owner precondition and the
vault-seed escrow — so those live in ONE place and the GUI/ncurses faces stay
interchangeable.

Design split (mirrors local_mesh.py's Config/Node and golive_driver.py's
Options/Driver):
  - ``PhoneWizardConfig`` — the non-secret knobs the operator provides (codename,
    channel, serial, keys-dir, login-server, role, work-dir, out). ``to_cli_args()``
    marshals them into the driver's flags in the SAME order the ncurses _phone_run
    emits, so the plan/argv reads identically across the ncurses and Studio faces.
    ``auth_key`` is held ONLY transiently for the life of a run (never in
    ``to_cli_args()``, never on argv, never persisted to ImageConfig/QSettings) — a
    run stages it into a 0600 ``--authkey-file`` and shreds it afterwards, exactly as
    _phone_run does.
  - ``PhoneWizard`` — resolves the driver path (honouring the ``SNAP_PHONE_WIZARD``
    env seam the ncurses + the phone tests use), gates ``available()`` on the script
    being executable, reads the driver's own vetted device catalog
    (``phone-devices.tsv``) for the codename picker, streams a read-only/non-
    interactive verb line-by-line into a page (``run``), and defers the two verbs
    that REQUIRE a TTY — ``flash`` (destructive typed-serial confirm) and ``wizard``
    (the guided full flow) — to a real terminal emulator (``run_verb_in_terminal``),
    never injecting a --yes bypass and never piping /dev/null at a confirmation gate.

This module imports only os/shutil/subprocess/tempfile/threading/shlex/dataclasses —
NO Qt — so it runs in the Qt-free/system-python environment CI uses, and is unit-
testable against a stub driver through the env seam.
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
import threading
from collections.abc import Callable
from dataclasses import dataclass

# The env seam the ncurses phone_screen honours (build-menu.sh:1745) and the phone
# tests override: SNAP_PHONE_WIZARD wins over the in-repo scripts/phone-wizard.sh.
ENV_DRIVER = "SNAP_PHONE_WIZARD"
DRIVER_REL = ("scripts", "phone-wizard.sh")
DEVICES_TSV = "phone-devices.tsv"
# The quest catalog SITS NEXT TO the driver too (scripts/quest-devices.tsv). The
# split is deliberate driver policy: `panther` is BOTH the Pixel 7 (phone catalog)
# and the Quest 3S (quest catalog) — --device-class picks WHICH catalog a codename
# resolves against, and the driver's manufacturer probe pins the device.
QUEST_DEVICES_TSV = "quest-devices.tsv"

# Read-only / non-interactive verbs the GUI drives directly (streamed line-by-line).
# flash + wizard are DELIBERATELY absent — they need a TTY and go to a terminal.
STREAM_VERBS = ("plan", "detect", "fetch", "enroll", "profile", "ingest", "status")
# The two verbs whose confirmation/guided prompts REQUIRE a real TTY the GUI has no
# stdin for (phone-wizard.sh:924 flash typed-serial, :1820 wizard `[ -t 0 ] || die`).
TERMINAL_VERBS = ("flash", "wizard")
# The quest device class is the 4-verb onboarding subset (fetch/flash/attest/profile
# are UNSUPPORTED for quest — the driver refuses them fail-closed with the rationale,
# see require_class_supports in phone-wizard.sh). mdm-enroll IS streamable on quest:
# the phone fresh-device gates become non-interactive ADVISORIES there (Horizon OS
# setup requires a Meta account, so `dpm set-device-owner` is the real arbiter).
QUEST_STREAM_VERBS = ("plan", "detect", "mdm-enroll", "enroll", "ingest", "status")
QUEST_TERMINAL_VERBS = ("wizard",)

# Terminal emulators the flash/wizard deferral can run in, most-specific first; each
# entry is (binary, exec-style args that precede the command argv). Copied from the
# go-live driver's identical terminal-hand-off contract.
_TERMINALS = (
    ("x-terminal-emulator", ("-e",)),
    ("konsole", ("-e",)),
    ("gnome-terminal", ("--",)),
    ("xfce4-terminal", ("-x",)),
    ("alacritty", ("-e",)),
    ("kitty", ("--",)),
    ("foot", ()),
    ("xterm", ("-e",)),
)

_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))


@dataclass
class PhoneWizardConfig:
    """Operator-provided knobs for one MDM-phone driver invocation.

    Every field maps to a driver flag EXCEPT ``auth_key``: the one-time tailnet/
    headscale pre-auth key is a SECRET, so it is never emitted by ``to_cli_args()``
    (it would land on the process table) — a run stages it into a 0600
    ``--authkey-file`` instead. ``channel`` defaults to the driver's own ``stable``.
    """
    codename: str = ""
    channel: str = "stable"
    serial: str = ""
    keys_dir: str = ""
    login_server: str = ""
    role: str = ""
    work_dir: str = ""
    out: str = ""
    auth_key: str = ""      # transient secret — staged to a 0600 file, never argv
    # ── device class + the quest management-plane knobs ──────────────────────────
    # device_class="" means the driver's phone default (NO flag emitted, so every
    # existing phone argv stays byte-identical); "quest" selects the quest catalog +
    # verb subset. The headwind/XR knobs are paths/URLs/names — never secrets — and
    # map 1:1 onto driver flags (the Makefile HEADWIND_CONFIG=/XR_CHAT_URL= knobs).
    device_class: str = ""
    headwind_apk: str = ""
    headwind_signer: str = ""
    headwind_url: str = ""
    headwind_config: str = ""
    xr_chat_url: str = ""

    def to_cli_args(self) -> list[str]:
        """The driver flags (no verb, no secret). --device-class rides FIRST when set
        (mirroring the Makefile's ``_QUEST_ARGS = --device-class quest $(_PHONE_ARGS)``
        shape); then the shared subset the ncurses sets (codename, channel, serial,
        keys-dir, login-server, role) in the SAME order _phone_run marshals it
        (build-menu.sh:1841-1846), so the argv reads identically across the faces;
        --work-dir/--out and the headwind/XR management-plane flags (real driver
        flags) are appended after and only when non-empty. Empty knobs emit
        nothing."""
        args: list[str] = []
        if self.device_class.strip():
            args += ["--device-class", self.device_class.strip()]
        if self.codename.strip():
            args += ["--codename", self.codename.strip()]
        if self.channel.strip():
            args += ["--channel", self.channel.strip()]
        if self.serial.strip():
            args += ["--serial", self.serial.strip()]
        if self.keys_dir.strip():
            args += ["--keys-dir", self.keys_dir.strip()]
        if self.login_server.strip():
            args += ["--login-server", self.login_server.strip()]
        if self.role.strip():
            args += ["--role", self.role.strip()]
        if self.work_dir.strip():
            args += ["--work-dir", self.work_dir.strip()]
        if self.out.strip():
            args += ["--out", self.out.strip()]
        if self.headwind_apk.strip():
            args += ["--headwind-apk", self.headwind_apk.strip()]
        if self.headwind_signer.strip():
            args += ["--headwind-signer-sha256", self.headwind_signer.strip()]
        if self.headwind_url.strip():
            args += ["--headwind-url", self.headwind_url.strip()]
        if self.headwind_config.strip():
            args += ["--headwind-config", self.headwind_config.strip()]
        if self.xr_chat_url.strip():
            args += ["--xr-chat-url", self.xr_chat_url.strip()]
        return args


class PhoneWizard:
    """Thin Qt-free front-end over ``scripts/phone-wizard.sh``. Owns NO gating — the
    bash driver re-validates and enforces everything; this only marshals argv, keeps
    the auth key off the process table, streams output, and hands the TTY verbs to a
    terminal."""

    def __init__(self, generator_dir: str, cfg: PhoneWizardConfig | None = None):
        self.generator_dir = os.path.abspath(generator_dir or _REPO_ROOT)
        self.cfg = cfg or PhoneWizardConfig()
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()

    # ── driver / catalog locations ───────────────────────────────────────────────
    @property
    def driver_path(self) -> str:
        """The resolved driver: ``$SNAP_PHONE_WIZARD`` (test seam) wins over the
        in-repo ``scripts/phone-wizard.sh`` — the exact resolution the ncurses uses
        (build-menu.sh:1745)."""
        return os.environ.get(ENV_DRIVER) or os.path.join(self.generator_dir, *DRIVER_REL)

    @property
    def devices_tsv(self) -> str:
        """The device catalog SITS NEXT TO the driver (the ncurses reads
        ``$(dirname "${wiz}")/phone-devices.tsv``, build-menu.sh:1778) so a stubbed
        driver can ship its own catalog through the same env seam. CLASS-SCOPED,
        exactly like the driver (main() switches DEVICES_TSV on --device-class):
        quest resolves quest-devices.tsv — `panther` is BOTH the Pixel 7 and the
        Quest 3S, so the class must pick the catalog."""
        name = QUEST_DEVICES_TSV if self.cfg.device_class.strip() == "quest" else DEVICES_TSV
        return os.path.join(os.path.dirname(self.driver_path), name)

    # ── availability + catalog ───────────────────────────────────────────────────
    def available(self) -> tuple[bool, str]:
        """True when the driver exists and is executable (the phone_screen guard,
        build-menu.sh:1746-1749). The actionable message names the resolved path."""
        p = self.driver_path
        if not (os.path.isfile(p) and os.access(p, os.X_OK)):
            return False, (f"MDM phone driver not found or not executable: {p}\n"
                           "This checkout has no MDM phone wizard (see docs/MDM.md).")
        return True, ""

    def device_catalog(self) -> list[tuple[str, str]]:
        """Parse the driver's fail-closed device catalog into (codename, name) rows —
        the SAME source the ncurses picker reads (build-menu.sh:1780-1783): two
        TAB-separated columns; ``#`` and blank lines skipped. Missing file → []."""
        rows: list[tuple[str, str]] = []
        try:
            with open(self.devices_tsv, encoding="utf-8") as fh:
                for line in fh:
                    s = line.rstrip("\n")
                    if not s.strip() or s.lstrip().startswith("#"):
                        continue
                    parts = s.split("\t")
                    if len(parts) < 2 or not parts[0].strip() or not parts[1].strip():
                        continue
                    rows.append((parts[0].strip(), parts[1].strip()))
        except OSError:
            pass
        return rows

    # ── command assembly ─────────────────────────────────────────────────────────
    def command(self, verb: str) -> list[str]:
        """The base driver invocation ``[driver, verb, <flags>]`` (NO --authkey-file:
        the secret is appended at run time from a staged 0600 file). Run directly —
        the driver is executable, exactly as the ncurses invokes it."""
        return [self.driver_path, verb, *self.cfg.to_cli_args()]

    def command_string(self, verb: str) -> str:
        return " ".join(shlex.quote(x) for x in self.command(verb))

    # ── secret staging (never persisted, never on argv) ──────────────────────────
    @staticmethod
    def _stage_authkey(secret: str) -> str:
        """Write the auth key to a fresh 0600 temp file and return its path (for
        ``--authkey-file``). No trailing newline — byte-identical to _phone_run's
        ``printf '%s'`` (build-menu.sh:1851). The caller shreds it after the run."""
        fd, path = tempfile.mkstemp(prefix=".phone-authkey-")
        try:
            if hasattr(os, "fchmod"):        # mkstemp is already 0600; belt-and-braces
                os.fchmod(fd, 0o600)
            os.write(fd, secret.encode())
        finally:
            os.close(fd)
        return path

    @staticmethod
    def _shred(path: str) -> None:
        """Best-effort shred+remove of the staged key file (the _phone_shred_key
        contract, build-menu.sh:1824-1827): shred if available, else unlink; always
        ensure it is gone."""
        try:
            if shutil.which("shred"):
                subprocess.run(["shred", "-u", path], check=False,
                               stderr=subprocess.DEVNULL)
        except OSError:
            pass
        try:
            if os.path.exists(path):
                os.unlink(path)
        except OSError:
            pass

    # ── execution (streamed verbs — mirrors GoLiveDriver.run) ────────────────────
    def run(self, verb: str, on_line: Callable[[str], None] | None = None,
            cancel: threading.Event | None = None) -> int:
        """Run ONE read-only/non-interactive verb, calling ``on_line`` per output
        line (stdout+stderr merged). stdin is /dev/null: these verbs never gate on a
        TTY (flash/wizard, which do, go through ``run_verb_in_terminal``). When an
        auth key is set it rides a 0600 ``--authkey-file`` appended at the tail and
        shredded in the ``finally`` — off the argv, and gone whether the run
        succeeds, fails, or is cancelled. Blocking — callers run it on a worker
        thread. Returns the driver exit code."""
        args = self.command(verb)
        keyfile = ""
        if self.cfg.auth_key.strip():
            keyfile = self._stage_authkey(self.cfg.auth_key.strip())
            args += ["--authkey-file", keyfile]
        self._cancel.clear()
        try:
            self._proc = subprocess.Popen(
                args, cwd=self.generator_dir, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            assert self._proc.stdout is not None
            for line in self._proc.stdout:
                if on_line:
                    on_line(line.rstrip("\n"))
                if (cancel is not None and cancel.is_set()) or self._cancel.is_set():
                    self._proc.terminate()
                    break
            return self._proc.wait()
        finally:
            if keyfile:
                self._shred(keyfile)

    def cancel(self) -> None:
        self._cancel.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ── the TTY verbs (flash / wizard) — deferred to a real terminal ─────────────
    def terminal_command(self, inner: list[str], keyfile: str = "") -> list[str] | None:
        """Wrap ``inner`` in the first available terminal emulator (kept open at the
        end so the driver's result stays readable). When a key file was staged the
        wrapper SHREDS it as the session ends, so the secret never outlives the run
        and never reaches the terminal's own argv. None when no emulator exists."""
        shred = ""
        if keyfile:
            q = shlex.quote(keyfile)
            shred = (f"; command -v shred >/dev/null 2>&1 && shred -u {q} "
                     f"2>/dev/null || rm -f {q}")
        script = (shlex.join(inner) + "; rc=$?" + shred
                  + '; echo; read -r -p "press Enter to close..." _; exit "$rc"')
        for binary, exec_args in _TERMINALS:
            if shutil.which(binary):
                return [binary, *exec_args, "bash", "-c", script]
        return None

    def run_verb_in_terminal(self, verb: str) -> tuple[bool, str]:
        """Launch a TTY verb (flash/wizard) in a real terminal, where the driver's own
        typed-serial / guided prompts run untouched — deliberately NO -y/--yes bypass.
        ``flash`` never consumes the auth key; ``wizard`` (which runs enroll) does, so
        for it the key rides a 0600 ``--authkey-file`` the wrapper shreds at session
        end. Returns (launched, message); with no emulator, the exact command to run
        by hand is returned instead (the key stays in its 0600 file)."""
        inner = self.command(verb)
        keyfile = ""
        if verb != "flash" and self.cfg.auth_key.strip():
            keyfile = self._stage_authkey(self.cfg.auth_key.strip())
            inner = [*inner, "--authkey-file", keyfile]
        cmd = self.terminal_command(inner, keyfile=keyfile)
        if cmd is None:
            hint = shlex.join(inner)
            msg = ("No terminal emulator found — run this yourself in a terminal:\n\n"
                   f"{hint}")
            if keyfile:
                msg += f"\n\n(the auth key is staged 0600 at {keyfile}; remove it after)"
            return False, msg
        try:
            subprocess.Popen(cmd, cwd=self.generator_dir, start_new_session=True)
        except OSError as e:
            if keyfile:
                self._shred(keyfile)
            return False, f"could not launch {cmd[0]}: {e}"
        return True, (f"Launched '{verb}' in {cmd[0]} — complete it there. The driver "
                      "runs its own confirmation / guided prompts on that terminal "
                      "(there is deliberately no GUI bypass).")
