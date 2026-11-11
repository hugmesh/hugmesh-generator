"""Kernel reconfiguration for a built x86 image — the Qt-free half of "Kernel config…".

The operator ask (2026-11-11): *on the build step, after an image is done compiling the
kernel allow for a button to open menuconfig in another window and change the kernel
config and resign it and repackage the tar and images.*

The work itself is ``scripts/kernel-reconfig-x86.sh`` (root, natively or in the builder
container). This module is everything the three faces share around it:

* :func:`locate` — find one image's build tree in a session and say, in ONE sentence,
  why it cannot be reconfigured (ARM board, build files gone, no kept config, a build
  that predates the contract, still building, failed, a signed image whose key is gone);
* :func:`diff_configs` / :func:`format_diff` — the pending change, symbol by symbol,
  read straight from the files the script keeps (they are world-readable);
* :func:`edit_argv` / :func:`open_editor` — the ``edit`` verb (menuconfig) in a
  separate terminal window: the Linux TERMINALS list, Windows Terminal / a console
  under WSL, a new console on native Windows, Terminal.app on macOS — or, when none
  can be opened, the exact command to copy;
* :func:`apply_argv` / :func:`run_apply` — the non-interactive ``apply`` verb, streamed
  through the build driver's own spawn (the same elevation choke point and cancel);
* :func:`record` — append the result to the session record (``kernel_reconfigs``).

Nothing here writes under the session's work dir: every write there is root's, through
the script. Nothing here holds a secret.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, Iterable

SCRIPT_REL = ("scripts", "kernel-reconfig-x86.sh")
ENV_NAME = "kernel-reconfig.env"
ENV_KEYS = (
    "KR_FORMAT BUILD_TS BRAND BRAND_TITLE ROLE ROLE_TAG ROLE_K8S ENV UNAFFILIATED "
    "UKI_NAME ROOT_LABEL ESP_LABEL SB_ETC_DIR SB_EFI_VENDOR SECURE_BOOT UKI_SIGNED "
    "DEFAULT_USER LIVE_ROOT_MOUNTPOINTS LIVE_VOLID INSTALL_VOLID SLX_TYPE JOBS KVER "
    "KERNEL_FROM_CACHE KERNEL_CONFIG COMPRESS_IMG COMPRESS_LEVEL STAGE4 IMG FS_TAR "
    "LIVE_ISO INSTALLER_ISO").split()
ARTIFACT_KEYS = ("STAGE4", "IMG", "FS_TAR", "LIVE_ISO", "INSTALLER_ISO")

#: The progress-table stage the button waits for (core/progress-tables.json "Build kernel").
KERNEL_STAGE = "kernel"

#: Refusal sentences — one place, so the GUI, TUI, CLI and the tests read the same words.
NOT_X86 = ("Kernel reconfiguration is x86-only for now: {board} builds delete their "
           "kernel source at the clean step.")
NO_IMAGE = "This session has no x86 image to reconfigure."
NO_WORKDIR = "This session's build files are gone ({workdir}) — rebuild the image."
NO_SYSROOT = ("The build system for this image is gone ({sysroot}) — were its build "
              "files deleted? Rebuild the image.")
NO_TREE = ("The kernel source tree is not in this image's build system any more — "
           "rebuild the image.")
NO_KERNEL_YET = "This image's build has not installed a kernel yet — wait for its Build kernel step."
NO_CONFIG = ("No kernel config was kept for {kver} (this build predates kernel "
             "reconfiguration, or its kernel came from an older cache entry) — rebuild "
             "the image once.")
NO_ENV = "This build predates kernel reconfiguration — rebuild it once."
STILL_BUILDING = "This image is still building — wait for it to finish."
NOT_OK = "This image's build did not finish (status: {status}) — its artifacts are incomplete."
KEY_GONE = ("The Secure Boot key this image was signed with is gone: {key} — its kernel "
            "cannot be re-signed.")
NO_EDIT = "There is no kernel config edit to apply — open menuconfig first."
NO_CHANGE = "The kernel config edit changes nothing — there is nothing to rebuild."
NO_TERMINAL = ("No terminal window could be opened on this desktop — run this in a "
               "terminal: {cmd}")


# ── reading what the builder and the script left behind ────────────────────────────
def read_env(path: str) -> dict[str, str]:
    """The builder's no-secret contract: strict KEY=VALUE, known keys only, never
    evaluated. {} when the file is missing or is not format 1."""
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k in ENV_KEYS:
                    out[k] = v
    except OSError:
        return {}
    return out if out.get("KR_FORMAT") == "1" else {}


_SET_RE = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
_UNSET_RE = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse_config(path: str) -> dict[str, str]:
    """A kernel .config as {symbol: value}; ``is not set`` reads as ``n``."""
    out: dict[str, str] = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = _SET_RE.match(line)
            if m:
                out[m.group(1)] = m.group(2)
                continue
            m = _UNSET_RE.match(line)
            if m:
                out[m.group(1)] = "n"
    return out


@dataclass(frozen=True)
class Change:
    symbol: str
    old: str          # "" = absent from the config
    new: str

    def render(self) -> str:
        def show(v: str) -> str:
            return "(unset)" if v == "" else ("n (not set)" if v == "n" else v)
        return f"{self.symbol}: {show(self.old)} -> {show(self.new)}"


def diff_configs(before: dict[str, str], after: dict[str, str]) -> list[Change]:
    """Every symbol whose value differs, sorted — the same answer as the script's
    ``krc_config_diff`` (tests pin the two against each other)."""
    return [Change(s, before.get(s, ""), after.get(s, ""))
            for s in sorted(set(before) | set(after))
            if before.get(s, "") != after.get(s, "")]


def format_diff(changes: Iterable[Change]) -> str:
    lines = [c.render() for c in changes]
    return "\n".join(lines) if lines else "(no change)"


# ── locating one image's build tree ─────────────────────────────────────────────────
@dataclass
class KernelTarget:
    session_id: str
    image_id: str
    platform: str
    workdir: str
    build_root: str
    env: dict[str, str] = field(default_factory=dict)
    kver: str = ""
    config_path: str = ""
    building: bool = False

    @property
    def sysroot(self) -> str:
        return os.path.join(self.build_root, "sysroot")

    @property
    def pending_dir(self) -> str:
        return os.path.join(self.build_root, "kernel-reconfig", "pending")

    @property
    def signed(self) -> bool:
        return self.env.get("UKI_SIGNED") == "yes"

    @property
    def sb_key(self) -> str:
        return os.path.join(self.workdir, "secureboot", "sb.key")

    def pending_changes(self) -> list[Change]:
        """The saved, not yet applied edit ([] when there is none)."""
        before = os.path.join(self.pending_dir, "config.before")
        after = os.path.join(self.pending_dir, "config.after")
        try:
            return diff_configs(parse_config(before), parse_config(after))
        except OSError:
            return []

    def has_pending(self) -> bool:
        return os.path.isfile(os.path.join(self.pending_dir, "config.before"))

    def pending_mtime(self) -> float:
        try:
            return os.path.getmtime(os.path.join(self.pending_dir, "config.after"))
        except OSError:
            return 0.0

    def summary(self) -> str:
        """One line for the panel and the CLI: the kernel, signing, the pending edit."""
        parts = [f"kernel {self.kver or '?'}"]
        if self.env:
            parts.append("Secure Boot signed" if self.signed else "UKI not signed")
        n = len(self.pending_changes())
        parts.append(f"{n} pending change(s)" if n else
                     ("edit open, nothing saved yet" if self.has_pending() else "no pending edit"))
        return " · ".join(parts)


def build_root_for(workdir: str, image_id: str) -> str:
    """The per-image build tree a Studio dispatch uses (``--build-subdir wl-<id>``)."""
    return os.path.join(workdir, f"wl-{image_id}")


def _images(session) -> list[dict]:
    return [r for r in (getattr(session, "images", None) or []) if isinstance(r, dict)]


def _platform_of(row: dict) -> str:
    return str(row.get("platform") or "x86")


def x86_images(session) -> list[dict]:
    return [r for r in _images(session) if _platform_of(r) == "x86"]


def _current_kver(sysroot: str) -> str:
    try:
        names = os.listdir(os.path.join(sysroot, "lib", "modules"))
    except OSError:
        return ""
    def key(v: str):
        return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", v)]
    return sorted(names, key=key)[-1] if names else ""


def _tree_present(sysroot: str) -> bool:
    link = os.path.join(sysroot, "usr", "src", "linux")
    try:
        target = os.readlink(link)
    except OSError:
        return os.path.isfile(os.path.join(link, "Makefile"))
    if os.path.isabs(target):
        target = sysroot + target
    else:
        target = os.path.join(sysroot, "usr", "src", target)
    return os.path.isfile(os.path.join(target, "Makefile"))


def locate(session, image_id: str | None = None, *, for_apply: bool = False,
           image_running: bool | None = None) -> "KernelTarget | str":
    """The :class:`KernelTarget` for ``image_id`` (default: the session's first x86
    image), or the one-sentence reason it cannot be reconfigured.

    ``for_apply`` adds the rebuild's own refusals (the contract, a finished OK image, a
    signed image's key). ``image_running`` overrides the record's view of whether the
    image is still building (the Progress page knows better than a record mid-run)."""
    rows = _images(session)
    if image_id:
        row = next((r for r in rows if str(r.get("id")) == image_id), None)
        if row is None:
            return NO_IMAGE
    else:
        xs = x86_images(session)
        if not xs:
            arm = next((r for r in rows), None)
            return NOT_X86.format(board=_platform_of(arm)) if arm else NO_IMAGE
        row = xs[0]
    platform = _platform_of(row)
    if platform != "x86":
        return NOT_X86.format(board=platform)
    workdir = str(getattr(session, "workdir", "") or "")
    if not workdir or not os.path.isdir(workdir):
        return NO_WORKDIR.format(workdir=workdir or "-")
    iid = str(row.get("id"))
    br = build_root_for(workdir, iid)
    t = KernelTarget(session_id=str(getattr(session, "id", "")), image_id=iid,
                     platform=platform, workdir=workdir, build_root=br)
    if not os.path.isdir(os.path.join(t.sysroot, "usr")):
        return NO_SYSROOT.format(sysroot=t.sysroot)
    if not _tree_present(t.sysroot):
        return NO_TREE
    t.kver = _current_kver(t.sysroot)
    if not t.kver:
        return NO_KERNEL_YET
    t.config_path = os.path.join(br, "kernel", f"config-{t.kver}")
    if not os.path.isfile(t.config_path):
        return NO_CONFIG.format(kver=t.kver)
    t.env = read_env(os.path.join(br, ENV_NAME))
    status = str(row.get("status") or "")
    if image_running is not None:
        running = image_running
    else:
        from . import build_sessions
        running = (status in ("queued", "running", "")
                   and str(getattr(session, "status", "")) == "running"
                   and not build_sessions.is_stale(session))
    t.building = bool(running)
    if for_apply:
        if t.building:
            return STILL_BUILDING
        if not t.env:
            return NO_ENV
        if status and status != "ok":
            return NOT_OK.format(status=status)
        if t.signed and not os.path.exists(t.sb_key):
            return KEY_GONE.format(key=t.sb_key)
    return t


def apply_refusal(t: KernelTarget) -> str:
    """Why "Rebuild kernel + re-sign + repackage" is disabled right now ("" = it is not).
    The script re-checks all of it as root; this is the inline reason beside the button."""
    if t.building:
        return STILL_BUILDING
    if not t.env:
        return NO_ENV
    if not t.has_pending() or not os.path.isfile(os.path.join(t.pending_dir, "config.after")):
        return NO_EDIT
    if not t.pending_changes():
        return NO_CHANGE
    if t.signed and not os.path.exists(t.sb_key):
        return KEY_GONE.format(key=t.sb_key)
    return ""


# ── the machine-wide one-build gate ────────────────────────────────────────────────
_BUSY_PATTERNS = (
    (re.compile(r"^(\S*/)?qemu-system-"), "an emulated device (QEMU) is running"),
    (re.compile(r"^(\S*/)?(bash\s+)?(\./|\S*/)?build-[a-z0-9-]+-stage4\.sh\b"), "an image build is running"),
    (re.compile(r"kernel-reconfig-x86\.sh\s+apply\b"), "another kernel rebuild is running"),
)


def _proc_cmdlines() -> list[str]:
    out = []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return out
    for pid in pids:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if raw:
            out.append(raw.replace(b"\0", b" ").decode("utf-8", "replace").strip())
    return out


def busy_reason(cmdlines: Callable[[], list[str]] | None = None) -> str:
    """Builds and emulated devices run strictly one at a time on this machine: the
    reason the rebuild must wait, or "" when nothing heavy is running. Matches the
    PROGRAM a process runs, never a shell that merely mentions one in its arguments."""
    for line in (cmdlines or _proc_cmdlines)():
        for rx, why in _BUSY_PATTERNS:
            if rx.search(line):
                return f"Builds run one at a time on this machine and {why} — the rebuild waits until it finishes."
    return ""


# ── argv: edit (interactive, its own window) and apply (streamed) ──────────────────
@dataclass
class RunContext:
    """How this Studio reaches root: the build driver's own backend and plumbing."""
    backend: str                         # "docker" | "native"
    generator_dir: str
    builder_image: str = "hugmesh-builder"
    container: str = ""                  # a LIVE build container: edit mid-build via docker exec
    run_container_name: str = ""         # --name for the apply's own container (cancel)
    elevation: list[str] = field(default_factory=list)   # native, non-interactive prefix
    host_path: Callable[[str], str] | None = None       # WSL/Windows docker path mapping


def _script(ctx: RunContext) -> str:
    return os.path.join(ctx.generator_dir, *SCRIPT_REL)


def _docker_verb(t: KernelTarget, ctx: RunContext, verb: str, *, interactive: bool,
                 extra: list[str] | None = None) -> list[str]:
    hp = ctx.host_path or (lambda p: p)
    inner = ["bash", "/src/" + "/".join(SCRIPT_REL), verb,
             "--build-root", f"/out/wl-{t.image_id}", *(extra or [])]
    term = ["-e", "TERM=" + os.environ.get("TERM", "xterm-256color")] if interactive else []
    if ctx.container and verb == "edit":
        return ["docker", "exec", *(["-it"] if interactive else []), *term, ctx.container, *inner]
    # The shared asset root rides along READ-ONLY at /shared, exactly where the build saw
    # it: the build's clean step stripped the static libraries, and the script overlays
    # them from the stage3 seed cached there (scripts/kernel-reconfig-x86.sh,
    # krc_statics_prepare).
    from .build_driver import shared_assets_root
    shared = shared_assets_root(t.workdir)
    seed_mount = ["-v", f"{hp(shared)}:/shared:ro"] if os.path.isdir(shared) else []
    return ["docker", "run", *(["-it"] if interactive else []), "--rm", "--privileged",
            *(["--name", ctx.run_container_name] if ctx.run_container_name else []),
            *term,
            "-v", f"{hp(ctx.generator_dir)}:/src",
            "-v", f"{hp(t.workdir)}:/out",
            *seed_mount,
            "-w", "/src", ctx.builder_image, *inner]


def _native_seed_args(t: KernelTarget) -> list[str]:
    """Natively the script finds the seed beside the session itself; say it explicitly
    when the session uses the Studio layout, so a moved out dir still works."""
    from .build_driver import shared_assets_root
    seeds = os.path.join(shared_assets_root(t.workdir), "seed", "amd64")
    return ["--seed-dir", seeds] if os.path.isdir(seeds) else []


def edit_argv(t: KernelTarget, ctx: RunContext) -> list[str]:
    """``edit`` (menuconfig) for an operator's terminal. Native: plain ``sudo`` — it
    prompts on THAT terminal, which is exactly where a password belongs."""
    if ctx.backend == "docker":
        return _docker_verb(t, ctx, "edit", interactive=True)
    return ["sudo", "bash", _script(ctx), "edit", "--build-root", t.build_root,
            *_native_seed_args(t)]


def verb_argv(t: KernelTarget, ctx: RunContext, verb: str,
              extra: list[str] | None = None) -> list[str]:
    """A NON-interactive verb (apply / discard / set) for streaming: native goes through
    the build driver's elevation prefix (``sudo -A`` + its askpass in the GUI), docker
    runs a named container the driver's cancel() can kill."""
    if ctx.backend == "docker":
        return _docker_verb(t, ctx, verb, interactive=False, extra=extra)
    return [*ctx.elevation, "bash", _script(ctx), verb, "--build-root", t.build_root,
            *_native_seed_args(t), *(extra or [])]


def apply_argv(t: KernelTarget, ctx: RunContext) -> list[str]:
    return verb_argv(t, ctx, "apply")


def copyable(argv: list[str]) -> str:
    return shlex.join(argv)


def _host_platform() -> str:
    """``sys.platform`` — a seam, so the darwin branch is tested on every OS."""
    return sys.platform


def open_editor(t: KernelTarget, ctx: RunContext, *,
                spawner: Callable[..., object] | None = None,
                which: Callable[[str], str | None] | None = None,
                osname: str | None = None, platform: str | None = None,
                is_wsl: bool | None = None, terminals=None) -> tuple[bool, str]:
    """Open menuconfig in its own terminal window. ``(True, how)`` once spawned,
    ``(False, sentence)`` with the copyable command when no window can be opened.
    Every seam is injectable: tests never open a window on the operator's desktop."""
    from .golive_target import terminal_spec
    argv = edit_argv(t, ctx)
    spec = terminal_spec(argv, osname=osname, platform=platform, is_wsl=is_wsl,
                         which=which, terminals=terminals)
    if spec is None:
        return False, NO_TERMINAL.format(cmd=copyable(argv))
    spawn = spawner or subprocess.Popen
    kw = {"creationflags": spec.creationflags} if spec.creationflags else {}
    try:
        spawn(spec.argv, cwd=ctx.generator_dir, stdin=subprocess.DEVNULL,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, **kw)
    except OSError as e:
        return False, f"Could not open a terminal ({e}) — run this in a terminal: {copyable(argv)}"
    return True, spec.how


# ── apply: stream, then record ─────────────────────────────────────────────────────
_RESULT_RE = re.compile(r"^KRC_RESULT=(\S+)$")
_REFUSED_RE = re.compile(r"\[kernel-reconfig\] REFUSED: (.*)$")


@dataclass
class ApplyOutcome:
    rc: int
    refusal: str = ""
    result: dict = field(default_factory=dict)


def result_path_on_host(t: KernelTarget, reported: str) -> str:
    """The script prints the result path as IT sees it (``/out/...`` in the container)."""
    if reported.startswith("/out/"):
        return os.path.join(t.workdir, reported[len("/out/"):])
    return reported


def run_apply(t: KernelTarget, ctx: RunContext, stream: Callable[[list[str], Callable[[str], None]], int],
              on_line: Callable[[str], None]) -> ApplyOutcome:
    """Run ``apply`` through ``stream`` (BuildDriver.stream_command in the faces) and
    collect the refusal sentence or the result record."""
    seen: dict[str, str] = {}

    def line(s: str) -> None:
        m = _RESULT_RE.match(s.strip())
        if m:
            seen["result"] = m.group(1)
        m = _REFUSED_RE.search(s)
        if m:
            seen["refusal"] = m.group(1).strip()
        on_line(s)

    rc = stream(apply_argv(t, ctx), line)
    out = ApplyOutcome(rc=rc, refusal=seen.get("refusal", ""))
    if rc == 0 and "result" in seen:
        try:
            with open(result_path_on_host(t, seen["result"]), encoding="utf-8") as fh:
                out.result = json.load(fh)
        except (OSError, ValueError):
            out.result = {}
    return out


def record(session, t: KernelTarget, result: dict, *, save: Callable[[object], None] | None = None) -> dict:
    """Append one applied reconfiguration to the session record (never rewrites an
    earlier entry) and persist it. Returns the appended row."""
    row = {
        "image": t.image_id,
        "stamp": str(result.get("stamp", "")),
        "old_kver": str(result.get("old_kver", "")),
        "new_kver": str(result.get("new_kver", "")),
        "old_build_ts": str(result.get("old_build_ts", "")),
        "new_build_ts": str(result.get("new_build_ts", "")),
        "signed": bool(result.get("signed", False)),
        "sbverify": result.get("sbverify", {}),
        "changes": [c.get("symbol") for c in result.get("changes", []) if isinstance(c, dict)],
        "artifacts": dict(result.get("artifacts", {})),
        "superseded": str(result.get("superseded", "")),
    }
    rows = list(getattr(session, "kernel_reconfigs", None) or [])
    rows.append(row)
    session.kernel_reconfigs = rows
    if save is None:
        from . import build_sessions
        save = build_sessions.save
    save(session)
    return row


def describe_record(row: dict) -> str:
    """One human line per applied reconfiguration (``--show-session``, the TUI detail)."""
    n = len(row.get("changes") or [])
    sb = row.get("sbverify") or {}
    if row.get("signed"):
        sig = "re-signed, sbverify ok" if sb.get("sysroot") is True else "re-signed"
    else:
        sig = "unsigned UKI"
    return (f"{row.get('image', '?')}: kernel {row.get('old_kver', '?')} -> "
            f"{row.get('new_kver', '?')} at {row.get('stamp', '?')} "
            f"({n} symbol(s), {sig}; artifacts now {row.get('new_build_ts', '?')})")


def parse_target_arg(arg: str) -> tuple[str, str | None]:
    """``SESSION[:IMAGE]`` -> (session id, image id or None)."""
    sid, _, img = arg.partition(":")
    return sid.strip(), (img.strip() or None)


def which_terminal_available(which: Callable[[str], str | None] | None = None) -> bool:
    from .cloud_deploy import TERMINALS
    w = which or shutil.which
    return any(w(b) for b, _ in TERMINALS)


# ── the headless face (app.py --kernel-config*) ────────────────────────────────────
CLI_VERBS = ("edit", "set", "diff", "apply", "discard")


def cli(verb: str, target_arg: str, generator_dir: str, *, config_args: str = "",
        out=None, err=None, driver=None, run_interactive=None, find=None,
        busy: Callable[[], str] | None = None) -> int:
    """``--kernel-config`` (edit, in THIS terminal) / ``--kernel-config-set`` /
    ``--kernel-config-diff`` / ``--kernel-config-apply`` / ``--kernel-config-discard``.

    Exit codes: 0 done, 2 bad input / no such session, 3 refused (one sentence on
    stderr), anything else = the script's own failure. Every seam is injectable."""
    out = out or sys.stdout
    err = err or sys.stderr
    from . import build_sessions
    sid, image = parse_target_arg(target_arg)
    s = (find or build_sessions.find)(sid)
    if s is None:
        print(f"error: no build session {sid!r} under {build_sessions.sessions_dir()}", file=err)
        return 2
    t = locate(s, image, for_apply=(verb == "apply"))
    if isinstance(t, str):
        print(f"refused: {t}", file=err)
        return 3
    if driver is None:
        from .build_driver import BuildDriver
        driver = BuildDriver(generator_dir)
    ctx = driver.reconfig_context(getattr(s, "backend", None) or None)
    if verb == "diff":
        print(t.summary(), file=out)
        print(format_diff(t.pending_changes()), file=out)
        return 0
    if verb == "edit":
        argv = edit_argv(t, ctx)
        print(f"[studio] menuconfig for {t.image_id} ({t.kver}) — save and exit to keep the change:\n  {copyable(argv)}", file=out)
        out.flush()
        rc = (run_interactive or (lambda a: subprocess.call(a, cwd=generator_dir)))(argv)
        print(format_diff(t.pending_changes()), file=out)
        return rc
    if verb == "set":
        extra = shlex.split(config_args)
        if not extra:
            print("error: --kernel-config-set needs --kernel-config-args, e.g. "
                  "\"--set-str LOCALVERSION -hmtest\"", file=err)
            return 2
        return driver.stream_command(verb_argv(t, ctx, "set", ["--", *extra]),
                                     lambda ln: print(ln, file=out), ctx.backend)
    if verb == "discard":
        return driver.stream_command(verb_argv(t, ctx, "discard"),
                                     lambda ln: print(ln, file=out), ctx.backend)
    # apply
    why = apply_refusal(t) or (busy or busy_reason)()
    if why:
        print(f"refused: {why}", file=err)
        return 3
    res = run_apply(t, ctx, lambda a, cb: driver.stream_command(a, cb, ctx.backend),
                    lambda ln: print(ln, file=out))
    if res.refusal:
        print(f"refused: {res.refusal}", file=err)
        return 3
    if res.rc != 0:
        return res.rc
    if not res.result:
        print("error: the rebuild finished but its result record could not be read", file=err)
        return 1
    row = record(s, t, res.result)
    print(f"[studio] recorded on session {s.id}: {describe_record(row)}", file=out)
    return 0
