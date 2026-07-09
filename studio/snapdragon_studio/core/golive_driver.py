"""GoLiveDriver — preview + stream the go-live ENGINE (scripts/go-live.sh) from Studio.

Mirrors BuildDriver's command()/run() contract: the GUI calls ``command(...)`` /
``command_string(...)`` to preview the exact engine invocation and ``run(...)`` to
stream it line-by-line into a page. It NEVER reimplements the engine — every action
is a flag spelling of scripts/go-live.sh (exactly as scripts/go-live-menu.sh
dispatches the same flags), and the provider catalog
(scripts/golive-providers.conf) is parsed for DISPLAY only (titles, deep links,
notes — the same read-only use the console menu makes of it).

The flip is deliberately different from every other action: the engine requires a
real TTY for its typed-domain confirmation (no bypass flag exists — unattended
go-live is a v1 non-goal), so the GUI cannot stream --flip through a pipe. Instead
``run_flip_in_terminal()`` launches the flip inside a real terminal emulator, where
the engine's own confirm (and sudo, when needed) run untouched.

Secret hygiene mirrors the engine + menu: token VALUES never enter argv — a masked
GUI field is staged into a 0600 temp file (``stage_token``) handed over via
--token-file / --cf-api-token-file and deleted right after the run.
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
from collections.abc import Callable
from dataclasses import dataclass, field

ENGINE_REL = "scripts/go-live.sh"
CATALOG_REL = "scripts/golive-providers.conf"

# Terminal emulators the flip can run in, most-specific first; each entry is
# (binary, exec-style args that precede the command argv).
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

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


@dataclass
class GoLiveOptions:
    """The non-secret engine inputs — one field per go-live.sh option flag.
    Token VALUES are deliberately not representable here (files only), so an
    options object can never leak a secret into argv/preview text."""
    provider: str = ""
    domain: str = ""
    record_ip: str = ""
    tunnel_id: str = ""
    ddns_service: str = "duckdns"   # duckdns | cloudflare (engine default: duckdns)
    ddns_subdomain: str = ""
    out_dir: str = ""
    keys_dir: str = ""
    token_file: str = ""            # path handed to --token-file (0600; value never argv)
    cf_api_token_file: str = ""     # path handed to --cf-api-token-file

    def to_cli_args(self, include_token_files: bool = True) -> list[str]:
        """Engine flags in the same order the console menu's base_flags() emits them,
        so preview text reads identically across the two front-ends."""
        args: list[str] = []
        if self.provider:
            args += ["--provider", self.provider]
        if self.domain:
            args += ["--domain", self.domain]
        if self.record_ip:
            args += ["--record-ip", self.record_ip]
        if self.tunnel_id:
            args += ["--tunnel-id", self.tunnel_id]
        if self.ddns_service:
            args += ["--ddns-service", self.ddns_service]
        if self.ddns_subdomain:
            args += ["--ddns-subdomain", self.ddns_subdomain]
        if self.out_dir:
            args += ["--out", self.out_dir]
        if self.keys_dir:
            args += ["--keys-dir", self.keys_dir]
        if include_token_files:
            if self.token_file:
                args += ["--token-file", self.token_file]
            if self.cf_api_token_file:
                args += ["--cf-api-token-file", self.cf_api_token_file]
        return args


@dataclass
class GoLiveProvider:
    """One [section] of scripts/golive-providers.conf, parsed for display only."""
    id: str
    title: str = ""
    model: str = ""
    summary: str = ""
    inputs: list[str] = field(default_factory=list)      # required engine inputs
    optional: list[str] = field(default_factory=list)    # optional engine inputs
    token_dest: str = ""
    emits: list[str] = field(default_factory=list)
    verify: list[str] = field(default_factory=list)
    links: list[tuple[str, str]] = field(default_factory=list)   # (url, label)
    notes: list[str] = field(default_factory=list)

    def needs(self, input_name: str) -> bool:
        return input_name in self.inputs

    def offers(self, input_name: str) -> bool:
        return input_name in self.inputs or input_name in self.optional


class GoLiveDriver:
    def __init__(self, generator_dir: str, is_root: bool | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        if is_root is None:
            is_root = getattr(os, "geteuid", lambda: -1)() == 0
        self.is_root = is_root
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()
        self._providers: list[GoLiveProvider] | None = None

    # ---- engine/catalog locations (env overrides mirror the engine's own) ----
    @property
    def engine_path(self) -> str:
        return os.path.join(self.generator_dir, *ENGINE_REL.split("/"))

    @property
    def catalog_path(self) -> str:
        return (os.environ.get("GOLIVE_CATALOG")
                or os.path.join(self.generator_dir, *CATALOG_REL.split("/")))

    @property
    def default_out_dir(self) -> str:
        # the engine's own default: GOLIVE_OUT or <repo>/out/go-live
        return os.environ.get("GOLIVE_OUT") or os.path.join(self.generator_dir, "out", "go-live")

    def autofill_domain(self) -> str:
        """The baked cluster domain the engine autofills --domain from
        (GOLIVE_CLUSTER_DOMAIN_FILE / /etc/snapdragon/cluster-domain) — read here
        only so the GUI can prefill the same value the engine would use."""
        path = os.environ.get("GOLIVE_CLUSTER_DOMAIN_FILE", "/etc/snapdragon/cluster-domain")
        try:
            with open(path, encoding="utf-8") as f:
                return "".join(f.read().split())
        except OSError:
            return ""

    # ---- catalog access (DISPLAY ONLY — the engine is the sole executor) -----
    def providers(self) -> list[GoLiveProvider]:
        if self._providers is None:
            self._providers = self._parse_catalog()
        return self._providers

    def provider(self, provider_id: str) -> GoLiveProvider | None:
        return next((p for p in self.providers() if p.id == provider_id), None)

    def models(self) -> list[str]:
        """Distinct exposure models in catalog order (the wizard's step-1 radios)."""
        seen: list[str] = []
        for p in self.providers():
            if p.model and p.model not in seen:
                seen.append(p.model)
        return seen

    def _parse_catalog(self) -> list[GoLiveProvider]:
        """Same grammar the engine's awk readers use: `[section]` at line start,
        `key = value` rows (link/note repeat), `#` comments ignored."""
        out: list[GoLiveProvider] = []
        cur: GoLiveProvider | None = None
        try:
            with open(self.catalog_path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            return out
        row = re.compile(r"^([A-Za-z0-9_-]+)\s+=(?: (.*))?$")
        for line in lines:
            if line.startswith("["):
                cur = GoLiveProvider(id=line.strip().strip("[]"))
                out.append(cur)
                continue
            if cur is None or line.lstrip().startswith("#"):
                continue
            m = row.match(line)
            if not m:
                continue
            key, value = m.group(1), (m.group(2) or "").strip()
            if key == "link":
                url, _, label = value.partition(" ")
                if url:
                    cur.links.append((url, label.strip() or url))
            elif key == "note":
                if value:
                    cur.notes.append(value)
            elif key in ("inputs", "optional", "emits", "verify"):
                setattr(cur, key, value.split())
            elif key in ("title", "model", "summary", "token_dest"):
                setattr(cur, key, value)
        return out

    # ---- command assembly ----------------------------------------------------
    def command(self, opts: GoLiveOptions, action_flags: list[str],
                include_token_files: bool = True) -> list[str]:
        """The exact engine invocation (run with cwd=generator_dir, like
        BuildDriver): ``bash ./scripts/go-live.sh <options> <action flags>``."""
        return ["bash", f"./{ENGINE_REL}",
                *opts.to_cli_args(include_token_files=include_token_files),
                *list(action_flags)]

    def command_string(self, opts: GoLiveOptions, action_flags: list[str]) -> str:
        return " ".join(shlex.quote(x) for x in self.command(opts, action_flags))

    # ---- execution (mirrors BuildDriver._stream) -------------------------------
    def run(self, opts: GoLiveOptions, action_flags: list[str],
            on_line: Callable[[str], None] | None = None) -> int:
        """Run one engine action, calling on_line per output line (stdout+stderr
        merged). Returns the exit code. Blocking — callers run it on a worker
        thread (the GUI uses a QThread)."""
        self._cancel.clear()
        self._proc = subprocess.Popen(
            self.command(opts, action_flags), cwd=self.generator_dir,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            if on_line:
                on_line(line.rstrip("\n"))
            if self._cancel.is_set():
                self._proc.terminate()
                break
        return self._proc.wait()

    def cancel(self) -> None:
        self._cancel.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def status_text(self) -> str:
        """The engine's own --status report (read-only, cheap), for display."""
        try:
            r = subprocess.run(self.command(GoLiveOptions(), ["--status"]),
                               cwd=self.generator_dir, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=30)
            return _ANSI_RE.sub("", r.stdout or "").strip()
        except (OSError, subprocess.SubprocessError) as e:
            return f"status unavailable: {e}"

    # ---- secret staging ---------------------------------------------------------
    @staticmethod
    def stage_token(secret: str) -> str:
        """Write a masked-field secret to a fresh 0600 temp file and return its
        path (for --token-file / --cf-api-token-file). The caller deletes it right
        after the run — mirroring the console menu's run_engine_with_token()."""
        fd, path = tempfile.mkstemp(prefix=".golive-tok-")
        try:
            if hasattr(os, "fchmod"):        # mkstemp is already 0600; belt-and-braces
                os.fchmod(fd, 0o600)
            os.write(fd, secret.encode() + b"\n")
        finally:
            os.close(fd)
        return path

    # ---- flip / rollback (terminal path — the engine's TTY confirm is the law) --
    def flip_command(self, opts: GoLiveOptions, persist: bool = False) -> list[str]:
        """The flip invocation: sudo (writing under /etc/snapdragon needs root)
        + the full option set (the engine's pre-flip verify gate uses them) —
        token files excluded, the flip never needs a secret."""
        inner = self.command(opts, ["--flip"] + (["--persist"] if persist else []),
                             include_token_files=False)
        return inner if self.is_root else ["sudo", *inner]

    def rollback_command(self, persist: bool = False) -> list[str]:
        inner = self.command(GoLiveOptions(ddns_service=""),
                             ["--rollback"] + (["--persist"] if persist else []))
        return inner if self.is_root else ["sudo", *inner]

    def terminal_command(self, inner: list[str]) -> list[str] | None:
        """Wrap inner in the first available terminal emulator (kept open at the
        end so the engine's result stays readable). None when no emulator exists."""
        script = shlex.join(inner) + '; rc=$?; echo; read -r -p "press Enter to close..." _; exit "$rc"'
        for binary, exec_args in _TERMINALS:
            if shutil.which(binary):
                return [binary, *exec_args, "bash", "-c", script]
        return None

    def _run_in_terminal(self, inner: list[str]) -> tuple[bool, str]:
        cmd = self.terminal_command(inner)
        if cmd is None:
            return False, ("No terminal emulator found — run this on the device "
                           f"yourself: {shlex.join(inner)}")
        try:
            subprocess.Popen(cmd, cwd=self.generator_dir, start_new_session=True)
        except OSError as e:
            return False, f"could not launch {cmd[0]}: {e}"
        return True, (f"Launched in {cmd[0]} — finish there (the engine runs its "
                      "pre-flip verify, then asks you to TYPE THE DOMAIN; "
                      "there is deliberately no way around that confirm).")

    def run_flip_in_terminal(self, opts: GoLiveOptions, persist: bool = False) -> tuple[bool, str]:
        return self._run_in_terminal(self.flip_command(opts, persist=persist))

    def run_rollback_in_terminal(self, persist: bool = False) -> tuple[bool, str]:
        return self._run_in_terminal(self.rollback_command(persist=persist))

    # ---- preflight (GUI hints only — the engine re-validates everything) --------
    def preflight(self, opts: GoLiveOptions, action_flags: list[str] = ("--emit",),
                  has_secret: bool = False, has_cf_secret: bool = False) -> list[str]:
        """Human-readable problems that would stop the action (empty = OK). Purely
        a courtesy preview: requirements are read from the provider catalog, and
        the engine independently enforces all of them."""
        problems: list[str] = []
        if not os.path.exists(self.engine_path):
            problems.append(f"go-live engine not found: {self.engine_path}")
        if not os.path.exists(self.catalog_path):
            problems.append(f"provider catalog not found: {self.catalog_path}")
        if not shutil.which("bash"):
            problems.append("bash is required to run the go-live engine.")
        acting = any(f in action_flags for f in ("--emit", "--verify", "--flip", "--create-dns"))
        if acting and not (opts.domain or self.autofill_domain()):
            problems.append("Domain is required (no /etc/snapdragon/cluster-domain bake "
                            "found to autofill from).")
        p = self.provider(opts.provider) if opts.provider else None
        if "--emit" in action_flags:
            if not opts.provider:
                problems.append("Pick a provider first (--emit needs one).")
            elif p is not None:
                if p.needs("token") and not (opts.token_file or has_secret):
                    problems.append(f"Provider '{p.id}' needs a token — paste it in the "
                                    "masked field or point at a token file.")
                if p.needs("subdomain") and not opts.ddns_subdomain:
                    problems.append(f"Provider '{p.id}' needs a DDNS subdomain label.")
                if p.needs("record-ip") and not (opts.record_ip or opts.tunnel_id):
                    problems.append(f"Provider '{p.id}' needs a public record IP "
                                    "(or a tunnel UUID for a CNAME set).")
        if "--create-dns" in action_flags:
            if not opts.tunnel_id:
                problems.append("--create-dns needs the Cloudflare tunnel UUID.")
            if not (opts.cf_api_token_file or has_cf_secret):
                problems.append("--create-dns needs a Cloudflare API token "
                                "(masked field or token file).")
        for label, path in (("token file", opts.token_file),
                            ("Cloudflare API token file", opts.cf_api_token_file)):
            if path and not os.path.exists(path):
                problems.append(f"{label} does not exist: {path}")
        return problems
