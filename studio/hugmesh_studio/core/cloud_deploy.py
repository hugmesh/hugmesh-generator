"""CloudDeploy — the Qt-free runner behind the ModePage's sixth first-screen choice
("Cloud deploy"). It takes an already cloud-packaged x86 artifact (see
``scripts/cloud-package.sh`` / docs/CLOUD-DEPLOY.md) and drives the ONE canonical
deploy driver ``specs/usr/sbin/hugmesh-cloud-deploy`` — no image build.

Like PhoneWizard and GoLiveDriver, this front-end is DELIBERATELY THIN: it only ever
shells the bash driver (the exact same script the ncurses deploy_screen/_deploy_run
and the Makefile deploy-* delegates reach through this module's ``main()``) and
carries NO deploy logic of its own. The driver owns every gate — provider registry
(``cloud-deploy-providers.sh``), validate_inputs shape checks, the creds-present
check before ``apply``, and the TTY confirmation on the two mutating verbs (apply/
destroy; there is deliberately NO bypass flag here and this module never sets the
driver's test-only CD_ASSUME_YES) — so those live in ONE place and the GUI/ncurses/
Makefile faces stay interchangeable.

Design split (mirrors phone_wizard.py's Config/Wizard and golive_driver.py's
Options/Driver):
  - ``CloudDeployOptions`` — the non-secret knobs (provider, image, domain, region,
    creds_file, out_dir, keys_dir). ``to_cli_args()`` marshals them into the driver's
    flags in the driver's pinned order (--provider --image --domain --region
    --creds-file --out-dir --keys-dir), so the argv reads identically across every
    face. ``creds_file`` is a PATH (0600, operator custody) — the path rides argv,
    the contents never do. ``creds`` is pasted credential CONTENT held ONLY
    transiently for the life of a run (never in ``to_cli_args()``, never on argv,
    never persisted) — a run stages it into a 0600 ``--creds-file`` tempfile and
    shreds it in ``finally``, exactly the phone-wizard auth-key custody.
  - ``CloudDeploy`` — resolves the driver path (honouring the SNAP_CLOUD_DEPLOY_CMD
    env seam the ncurses + the deploy tests use), gates ``available()`` on the script
    being executable, parses the driver's ``list`` TAB table for the provider picker
    (``providers()`` — THE parseable registry API), renders a PURE text ``preview()``
    (command + knobs + BLOCKERS tail; no subprocess, no files — the live plan pane),
    streams the offline verbs line-by-line (``plan``/``status``/``apply`` via
    ``run``), and offers ``run_verb_in_terminal`` for the mutating verbs so the
    driver's own TTY confirmation runs untouched (the GUI routes ``destroy`` there;
    ``apply`` streams behind the page's explicit ack checkbox — if the driver
    demands a TTY it fails CLOSED with its own message, never bypassed).

``plan`` is the driver's DEFAULT verb: a pure offline artifact render into
--out-dir — files the operator reads and runs; nothing touches a cloud API. Only
the emitted apply.sh/destroy.sh mutate anything, and both re-confirm themselves.

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

# The env seam the ncurses deploy_screen honours and the deploy tests override:
# SNAP_CLOUD_DEPLOY_CMD wins over the in-repo specs/usr/sbin/hugmesh-cloud-deploy.
ENV_DRIVER = "SNAP_CLOUD_DEPLOY_CMD"
DRIVER_REL = ("specs", "usr", "sbin", "hugmesh-cloud-deploy")

# Read-only / offline verbs the GUI streams directly (line-by-line, stdin closed):
# list is the registry table, plan renders files into --out-dir (offline), status
# only reads emitted state hints. apply ALSO streams — but only behind the page's
# explicit ack checkbox, and the driver still owns its own confirmation (fail-closed
# without a TTY; CD_ASSUME_YES is the driver's TEST-ONLY seam, never set here).
STREAM_VERBS = ("list", "plan", "status")
# The two mutating verbs whose driver-side confirmation REQUIRES a real TTY.
MUTATING_VERBS = ("apply", "destroy")

# Terminal emulators the mutating-verb deferral can run in, most-specific first;
# each entry is (binary, exec-style args that precede the command argv). Copied from
# the phone/go-live drivers' identical terminal-hand-off contract.
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
class CloudDeployOptions:
    """Operator-provided knobs for one cloud-deploy driver invocation.

    Every field maps to a driver flag EXCEPT ``creds``: pasted credential CONTENT is
    a SECRET, so it is never emitted by ``to_cli_args()`` (it would land on the
    process table) — a run stages it into a 0600 ``--creds-file`` tempfile instead
    and shreds it afterwards. ``creds_file`` is the alternative: a PATH to the
    operator's own 0600 credentials file; only the path ever rides argv.
    """
    provider: str = ""      # registry id: aws-ec2 / azure-image / openshift-cnv / …
    image: str = ""         # the cloud-PACKAGED artifact (qcow2 / fixed VHD / raw)
    domain: str = ""
    region: str = ""
    creds_file: str = ""    # PATH to a 0600 creds file (contents never read here)
    out_dir: str = ""       # where plan renders its artifacts
    keys_dir: str = ""
    creds: str = ""         # transient secret — staged to a 0600 file, never argv
    # IdP passthrough (I7): casdoor is the native default and emits NOTHING; an
    # external choice (entra/aws/oidc) makes the plan add idp/idp.conf artifacts.
    idp: str = ""           # "" or casdoor = default; entra / aws / oidc = external
    idp_issuer: str = ""
    idp_client_id: str = ""
    idp_jwks: str = ""

    def to_cli_args(self) -> list[str]:
        """The driver flags (no verb, no secret) in the driver's pinned order:
        --provider --image --domain --region --creds-file --out-dir --keys-dir —
        the SAME order the ncurses _deploy_run and the Makefile deploy-* delegates
        marshal, so the argv reads identically across every face. Empty knobs emit
        nothing."""
        args: list[str] = []
        if self.provider.strip():
            args += ["--provider", self.provider.strip()]
        if self.image.strip():
            args += ["--image", self.image.strip()]
        if self.domain.strip():
            args += ["--domain", self.domain.strip()]
        if self.region.strip():
            args += ["--region", self.region.strip()]
        if self.creds_file.strip():
            args += ["--creds-file", self.creds_file.strip()]
        if self.out_dir.strip():
            args += ["--out-dir", self.out_dir.strip()]
        if self.keys_dir.strip():
            args += ["--keys-dir", self.keys_dir.strip()]
        # casdoor/blank emits nothing — argv stays byte-identical to pre-IdP flows.
        if self.idp.strip() and self.idp.strip() != "casdoor":
            args += ["--idp", self.idp.strip()]
            if self.idp_issuer.strip():
                args += ["--idp-issuer", self.idp_issuer.strip()]
            if self.idp_client_id.strip():
                args += ["--idp-client-id", self.idp_client_id.strip()]
            if self.idp_jwks.strip():
                args += ["--idp-jwks", self.idp_jwks.strip()]
        return args


class CloudDeploy:
    """Thin Qt-free front-end over ``specs/usr/sbin/hugmesh-cloud-deploy``. Owns
    NO gating — the bash driver re-validates and enforces everything; this only
    marshals argv, keeps pasted creds off the process table, streams output, and
    hands the TTY verbs to a terminal."""

    def __init__(self, generator_dir: str, opts: CloudDeployOptions | None = None):
        self.generator_dir = os.path.abspath(generator_dir or _REPO_ROOT)
        self.opts = opts or CloudDeployOptions()
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()

    # ── driver location ──────────────────────────────────────────────────────────
    @property
    def driver_path(self) -> str:
        """The resolved driver: ``$SNAP_CLOUD_DEPLOY_CMD`` (test seam) wins over the
        in-repo ``specs/usr/sbin/hugmesh-cloud-deploy`` — the exact resolution
        the ncurses deploy_screen uses."""
        return os.environ.get(ENV_DRIVER) or os.path.join(self.generator_dir, *DRIVER_REL)

    # ── availability + registry ──────────────────────────────────────────────────
    def available(self) -> tuple[bool, str]:
        """True when the driver exists and is executable. The actionable message
        names the resolved path (the phone_screen guard's shape)."""
        p = self.driver_path
        if not (os.path.isfile(p) and os.access(p, os.X_OK)):
            return False, (f"cloud-deploy driver not found or not executable: {p}\n"
                           "This checkout has no cloud-deploy driver "
                           "(see docs/CLOUD-DEPLOY.md).")
        return True, ""

    def providers(self) -> list[tuple[str, str, str]]:
        """Parse ``hugmesh-cloud-deploy list`` — THE parseable registry API — into
        (id, status, description) rows. The table is the go-live house shape:
        space-padded printf columns ``ID FORMAT STATE DESCRIPTION`` whose first
        three columns are single tokens, so ``split(None, 3)`` recovers the
        description verbatim (golive_driver.py precedent — NEVER tab-dependent).
        The header row, ``#`` comments, blank lines and trailing prose are dropped
        by requiring a known STATE token. Driver missing or failing → []
        (the caller shows available()'s message)."""
        ok, _why = self.available()
        if not ok:
            return []
        try:
            r = subprocess.run(
                [self.driver_path, "list"], cwd=self.generator_dir,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, timeout=30)
            lines = (r.stdout or "").splitlines()
        except (OSError, subprocess.SubprocessError):
            return []
        rows: list[tuple[str, str, str]] = []
        for line in lines:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split(None, 3)
            if len(parts) < 4:
                continue
            pid, _fmt, state, desc = parts
            # Known-STATE filter drops the header row and the epilogue prose
            # (which also split into >=4 whitespace fields).
            if pid.upper() == "ID" or state not in ("full", "stub"):
                continue
            rows.append((pid, state, desc))
        return rows

    # ── command assembly ─────────────────────────────────────────────────────────
    def command(self, verb: str) -> list[str]:
        """The base driver invocation ``[driver, verb, <flags>]`` (NO staged creds
        file: pasted creds are appended at run time from a 0600 tempfile). Run
        directly — the driver is executable, exactly as the ncurses invokes it."""
        return [self.driver_path, verb, *self.opts.to_cli_args()]

    def command_string(self, verb: str) -> str:
        return " ".join(shlex.quote(x) for x in self.command(verb))

    # ── validation (pure — the page's BLOCKERS tail) ─────────────────────────────
    def validate(self) -> list[str]:
        """Blockers only (the #387 block-vs-warn rule) — every item here makes a
        driver run pointless or unsafe, and each names its fix. PURE: reads only
        option shapes + file metadata, runs nothing."""
        o = self.opts
        problems: list[str] = []
        if not o.provider.strip():
            problems.append("no provider selected (pick one from the driver's list)")
        if not o.image.strip():
            problems.append("no image: point --image at a cloud-PACKAGED artifact "
                            "(scripts/cloud-package.sh output: .qcow2/.vhd/.img)")
        elif not os.path.isfile(o.image.strip()):
            problems.append(f"image file not found: {o.image.strip()}")
        if o.creds.strip() and o.creds_file.strip():
            problems.append("both pasted creds AND a creds file are set — use one "
                            "channel (the pasted creds would shadow the file)")
        cf = o.creds_file.strip()
        if cf:
            if not os.path.isfile(cf):
                problems.append(f"creds file not found: {cf}")
            else:
                try:
                    mode = os.stat(cf).st_mode & 0o777
                    if mode & 0o077:
                        problems.append(
                            f"creds file {cf} is group/world-readable "
                            f"({mode:03o}) — chmod 600 it (credential custody)")
                except OSError:
                    pass
        dom = o.domain.strip()
        if dom and (" " in dom or "." not in dom):
            problems.append(f"domain does not look like a DNS apex: {dom!r}")
        kd = o.keys_dir.strip()
        if kd and not os.path.isdir(kd):
            problems.append(f"keys dir is not a directory: {kd}")
        return problems

    # ── preflight (read-only host probes) ────────────────────────────────────────
    def preflight(self) -> list[str]:
        """Courtesy host probes BEFORE the operator commits — driver presence plus
        the validate() blockers. Read-only; never calls a cloud API."""
        problems: list[str] = []
        ok, why = self.available()
        if not ok:
            problems.append(why.splitlines()[0])
        problems.extend(self.validate())
        return problems

    # ── the PURE plan preview (the page's live pane) ─────────────────────────────
    def preview(self) -> str:
        """A pure text manifest of what a ``plan`` run would do — the confirm-
        before-run surface the page live-refreshes on every knob change. NO
        subprocess, NO files (the actual artifact render is the driver's ``plan``
        verb, an explicit button): header + knobs + the exact command + a BLOCKERS
        tail from validate(), the local_mesh_bootstrap.plan() house shape."""
        o = self.opts
        lines = [
            "CLOUD DEPLOY — offline plan preview",
            "=" * 56,
            f"provider:   {o.provider.strip() or '<none selected>'}",
            f"image:      {o.image.strip() or '<none — a cloud-packaged artifact>'}",
            f"domain:     {o.domain.strip() or '<unset>'}",
            f"region:     {o.region.strip() or '<unset>'}",
            "creds:      " + ("pasted (staged to a 0600 tempfile at run, then shredded)"
                              if o.creds.strip()
                              else (o.creds_file.strip() or "<unset — apply refuses without creds>")),
            f"out dir:    {o.out_dir.strip() or '<driver default>'}",
            f"keys dir:   {o.keys_dir.strip() or '<unset>'}",
            "",
            "(1) PLAN renders the provider's artifacts OFFLINE into the out dir —",
            "    readable scripts/policies/checklists; nothing touches a cloud API.",
            "(2) APPLY executes the plan's emitted apply.sh (creds required; the",
            "    driver + apply.sh each re-confirm — real resources, real cost).",
            "(3) STATUS reads emitted state hints / prints the check commands.",
            "(4) DESTROY runs the emitted destroy.sh (TTY-confirmed).",
            "",
            f"plan command: {self.command_string('plan')}",
        ]
        problems = self.validate()
        if problems:
            lines += ["", "BLOCKERS (fix before 'apply'):"]
            lines += [f"  - {p}" for p in problems]
        return "\n".join(lines)

    # ── secret staging (never persisted, never on argv) ──────────────────────────
    @staticmethod
    def _stage_creds(secret: str) -> str:
        """Write pasted creds to a fresh 0600 temp file and return its path (for
        ``--creds-file``). No trailing newline (byte-exact custody, the phone
        _stage_authkey contract). The caller shreds it in ``finally``."""
        fd, path = tempfile.mkstemp(prefix=".cloud-deploy-creds-")
        try:
            if hasattr(os, "fchmod"):        # mkstemp is already 0600; belt-and-braces
                os.fchmod(fd, 0o600)
            os.write(fd, secret.encode())
        finally:
            os.close(fd)
        return path

    @staticmethod
    def _shred(path: str) -> None:
        """Best-effort shred+remove of the staged creds file (the _phone_shred_key
        contract): shred if available, else unlink; always ensure it is gone."""
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

    # ── execution (streamed verbs — mirrors PhoneWizard.run) ─────────────────────
    def run(self, verb: str, on_line: Callable[[str], None] | None = None,
            cancel: threading.Event | None = None) -> int:
        """Run ONE verb, calling ``on_line`` per output line (stdout+stderr merged).
        stdin is /dev/null — so a driver that gates a mutating verb on a TTY fails
        CLOSED here with its own message (never bypassed; ``run_verb_in_terminal``
        is the TTY route). When pasted creds are set they ride a 0600
        ``--creds-file`` tempfile appended at the tail and shredded in the
        ``finally`` — off the argv, and gone whether the run succeeds, fails, or is
        cancelled. Blocking — callers run it on a worker thread. Returns the driver
        exit code."""
        args = self.command(verb)
        credsfile = ""
        if self.opts.creds.strip():
            credsfile = self._stage_creds(self.opts.creds.strip())
            args += ["--creds-file", credsfile]
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
            if credsfile:
                self._shred(credsfile)

    def cancel(self) -> None:
        self._cancel.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    # ── the verb faces the lane spec names (thin, uniform) ───────────────────────
    def plan(self, on_line: Callable[[str], None] | None = None,
             cancel: threading.Event | None = None) -> int:
        """Offline artifact render into --out-dir (the driver's DEFAULT verb)."""
        return self.run("plan", on_line, cancel)

    def apply(self, on_line: Callable[[str], None] | None = None,
              cancel: threading.Event | None = None) -> int:
        """Execute the plan's emitted apply.sh (driver-gated; see run())."""
        return self.run("apply", on_line, cancel)

    def status(self, on_line: Callable[[str], None] | None = None,
               cancel: threading.Event | None = None) -> int:
        """Read emitted state hints / print check commands (never a cloud call)."""
        return self.run("status", on_line, cancel)

    def destroy(self, on_line: Callable[[str], None] | None = None,
                cancel: threading.Event | None = None) -> int:
        """Run the emitted destroy.sh (driver-gated; the GUI defers to a terminal)."""
        return self.run("destroy", on_line, cancel)

    # ── the TTY verbs (apply / destroy) — deferred to a real terminal ────────────
    def terminal_command(self, inner: list[str], credsfile: str = "") -> list[str] | None:
        """Wrap ``inner`` in the first available terminal emulator (kept open at the
        end so the driver's result stays readable). When creds were staged the
        wrapper SHREDS the file as the session ends, so the secret never outlives
        the run and never reaches the terminal's own argv. None when no emulator
        exists."""
        shred = ""
        if credsfile:
            q = shlex.quote(credsfile)
            shred = (f"; command -v shred >/dev/null 2>&1 && shred -u {q} "
                     f"2>/dev/null || rm -f {q}")
        script = (shlex.join(inner) + "; rc=$?" + shred
                  + '; echo; read -r -p "press Enter to close..." _; exit "$rc"')
        for binary, exec_args in _TERMINALS:
            if shutil.which(binary):
                return [binary, *exec_args, "bash", "-c", script]
        return None

    def run_verb_in_terminal(self, verb: str) -> tuple[bool, str]:
        """Launch a mutating verb (apply/destroy) in a real terminal, where the
        driver's own confirmation prompts run untouched — deliberately NO
        CD_ASSUME_YES / --yes bypass. Pasted creds ride a 0600 ``--creds-file``
        tempfile the wrapper shreds at session end. Returns (launched, message);
        with no emulator, the exact command to run by hand is returned instead
        (the creds stay in their 0600 file)."""
        inner = self.command(verb)
        credsfile = ""
        if self.opts.creds.strip():
            credsfile = self._stage_creds(self.opts.creds.strip())
            inner = [*inner, "--creds-file", credsfile]
        cmd = self.terminal_command(inner, credsfile=credsfile)
        if cmd is None:
            hint = shlex.join(inner)
            msg = ("No terminal emulator found — run this yourself in a terminal:\n\n"
                   f"{hint}")
            if credsfile:
                msg += f"\n\n(the creds are staged 0600 at {credsfile}; remove it after)"
            return False, msg
        try:
            subprocess.Popen(cmd, cwd=self.generator_dir, start_new_session=True)
        except OSError as e:
            if credsfile:
                self._shred(credsfile)
            return False, f"could not launch {cmd[0]}: {e}"
        return True, (f"Launched '{verb}' in {cmd[0]} — complete it there. The driver "
                      "runs its own confirmation prompts on that terminal (there is "
                      "deliberately no GUI bypass).")


# ── CLI face — the ncurses/Makefile entrypoint ───────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    """``python3 -m hugmesh_studio.core.cloud_deploy VERB [flags]`` — the shared
    Qt-free entrypoint the ncurses deploy_screen and the Makefile deploy-* delegates
    shell (the local_mesh_bootstrap.main precedent). list/plan/status stream to
    stdout; apply/destroy run TERMINAL-ATTACHED (inherited stdin/stdout) so the
    driver's own TTY confirmation reaches the operator — never piped, never
    bypassed. ``preview`` prints the pure plan preview (no driver run)."""
    import argparse

    ap = argparse.ArgumentParser(
        prog="python3 -m hugmesh_studio.core.cloud_deploy",
        description="Deploy a cloud-packaged HugMesh x86 image via the canonical "
                    "hugmesh-cloud-deploy driver (see docs/CLOUD-DEPLOY.md).")
    ap.add_argument("verb",
                    choices=["list", "plan", "apply", "status", "destroy", "preview"],
                    help="driver verb (plan renders offline artifacts; apply/destroy "
                         "are TTY-confirmed by the driver; preview is a pure local "
                         "summary, no driver run)")
    ap.add_argument("--provider", default="", help="registry id (see 'list')")
    ap.add_argument("--image", default="",
                    help="cloud-PACKAGED artifact (scripts/cloud-package.sh output)")
    ap.add_argument("--domain", default="")
    ap.add_argument("--region", default="")
    ap.add_argument("--creds-file", default="",
                    help="PATH to a 0600 credentials file (only the path rides argv; "
                         "contents stay in your custody)")
    ap.add_argument("--out-dir", default="", help="where plan renders its artifacts")
    ap.add_argument("--keys-dir", default="")
    ap.add_argument("--generator-dir", default=_REPO_ROOT)
    ns = ap.parse_args(argv)

    opts = CloudDeployOptions(
        provider=ns.provider, image=ns.image, domain=ns.domain, region=ns.region,
        creds_file=ns.creds_file, out_dir=ns.out_dir, keys_dir=ns.keys_dir)
    cd = CloudDeploy(ns.generator_dir, opts)

    if ns.verb == "preview":
        print(cd.preview())
        return 0

    ok, why = cd.available()
    if not ok:
        print(why)
        return 2

    if ns.verb in MUTATING_VERBS:
        # terminal-attached: the driver's own confirmation prompts run right here.
        # (No stdin piping, no CD_ASSUME_YES — the gate is the driver's.)
        try:
            return subprocess.call(cd.command(ns.verb), cwd=cd.generator_dir)
        except OSError as e:
            print(f"cloud-deploy {ns.verb}: {e}")
            return 2
    return cd.run(ns.verb, on_line=print)


if __name__ == "__main__":                     # pragma: no cover — argparse shim
    raise SystemExit(main())
