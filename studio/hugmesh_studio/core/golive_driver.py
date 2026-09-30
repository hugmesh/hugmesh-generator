"""GoLiveDriver — preview + stream the CANONICAL go-live driver from Studio.

The Studio GUI is a THIN front-end: exactly like hugmesh-go-live-cli and the
ncurses hugmesh-go-live-menu, it only ever calls the shared driver
``specs/usr/sbin/hugmesh-go-live`` and its subcommands
(status | list | plan | commit | rollback). It carries NO wizard logic and NEVER
reimplements posture — the driver owns the provider registry, the emit, and the
commit gate. (It used to shell out to the #286 engine scripts/go-live.sh; that
engine was superseded by this driver during the go-live consolidation and is being
removed, so this front-end was repointed onto the driver subcommands.)

Mirrors BuildDriver's command()/run() contract: the GUI calls ``command(...)`` /
``command_string(...)`` to preview the exact driver invocation and ``run(...)`` to
stream ``plan`` line-by-line into a page.

The commit is deliberately different from every other action: the driver requires
a real TTY for its confirmation prompt (there is NO bypass flag — passing
-y/--yes would be a bypass and the GUI must not add one; unattended go-live is a
v1 non-goal), so the GUI cannot stream ``commit`` through a pipe. Instead
``run_commit_in_terminal()`` launches it inside a real terminal emulator, where the
driver's own confirm (and sudo, when writing under /etc/hugmesh) run untouched.

Secret hygiene: token VALUES never enter argv — a masked GUI field is staged into
a 0600 temp file (``stage_token``) handed over via --token-file and deleted right
after the run. GoLiveOptions has no field for a secret value at all.
"""
from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading

from . import proc_text
from collections.abc import Callable
from dataclasses import dataclass, field

# The CANONICAL shared driver + its provider registry (repo-relative). The driver
# is invoked as `bash ./<DRIVER_REL> <subcommand> [flags]`, run with
# cwd=generator_dir (mirrors BuildDriver). The registry lib is sourced by the
# driver; we point GL_PROVIDERS_LIB at the in-repo copy so the dev Studio finds it
# without the on-image /usr/lib bake.
DRIVER_REL = "specs/usr/sbin/hugmesh-go-live"
REGISTRY_REL = "specs/usr/lib/hugmesh/go-live-providers.sh"

# The driver's subcommands the front-end may call.
SUBCOMMANDS = ("status", "list", "plan", "commit", "rollback")

# mechanism (from the registry / `list`) -> exposure model (the wizard's step-1
# radios). The driver never hard-codes a provider; the front-end only maps the
# registry's mechanism taxonomy onto UI groupings.
_MECH_MODEL = {
    "deeplink": "tunnel",
    "files": "public-dns",
    "ddns": "ddns",
    "funnel": "funnel",
    "instructions": "router",
    # onion — its own exposure model: no public DNS/IP/ports, reachable only over
    # Tor (docs/TOR-HIDDEN-SERVICE.md). Takes NO inputs (not even a domain — the
    # .onion address IS the endpoint, minted on the node).
    "onion": "onion",
}
# Which inputs each mechanism (required, optional) drives on the inputs page. This
# is derived purely from the mechanism taxonomy the registry publishes — the
# driver re-validates everything, so this is a UI courtesy only.
_MECH_INPUTS = {
    "ddns":         (["subdomain", "token"], ["ddns-service"]),
    "deeplink":     (["token"],              ["tunnel-cname"]),
    "files":        ([],                     ["ingress-ip", "ingress-ipv6", "tunnel-cname"]),
    "funnel":       ([],                     []),
    "instructions": ([],                     []),
    "onion":        ([],                     []),   # no inputs — the .onion is the endpoint
}

# Mechanisms that need NO public domain (the endpoint is not a DNS name). For these
# the front-end must not DEMAND one. Onion still ACCEPTS a domain since #582
# (decision 68 = A): a Tor domain has its own onion, so a domain given with the onion
# mechanism names WHICH onion — see GoLiveDriver.domain_onion / preflight.
_NO_DOMAIN_MECHANISMS = frozenset({"onion"})

# Where the node agent exports the onions (specs/usr/sbin/hugmesh-tor-reconcile, #599;
# go-live-providers.sh's _GLP_ONION_EXPORT_DIR): ``hostname`` for the primary and
# ``<slug>.hostname`` per Tor domain. GL_ONION_EXPORT_DIR overrides it, as it does for
# the driver.
_ONION_EXPORT_DIR_DEFAULT = "/var/lib/hugmesh/tor"
_ONION_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")

# Terminal emulators the commit/rollback can run in, most-specific first; each
# entry is (binary, exec-style args that precede the command argv).
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
# Same shapes the driver's validate_inputs() enforces (mirrored here as a courtesy
# preflight — the driver is the sole authority and re-checks these).
_DNS_LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_IPV4_RE = re.compile(r"^([0-9]{1,3}\.){3}[0-9]{1,3}$")


@dataclass
class GoLiveOptions:
    """The non-secret driver inputs — one field per driver flag. Token VALUES are
    deliberately not representable here (files only), so an options object can
    never leak a secret into argv/preview text."""
    provider: str = ""
    domain: str = ""                # --domain
    ingress_ip: str = ""            # --ingress-ip
    ingress_ipv6: str = ""          # --ingress-ipv6
    tunnel_cname: str = ""          # --tunnel-cname
    ddns_service: str = "duckdns"   # --ddns-service (driver default: duckdns)
    ddns_subdomain: str = ""        # --ddns-subdomain
    ttl: str = ""                   # --ttl (driver default 300 when omitted)
    out_dir: str = ""               # --out-dir
    keys_dir: str = ""              # --keys-dir
    token_file: str = ""            # --token-file (0600; value never argv)

    def to_cli_args(self, include_token_file: bool = True) -> list[str]:
        """Driver flags (no subcommand) in a stable order — so the plan preview
        reads identically across the CLI/ncurses/Studio front-ends."""
        args: list[str] = []
        if self.provider:
            args += ["--provider", self.provider]
        if self.domain:
            args += ["--domain", self.domain]
        if self.ingress_ip:
            args += ["--ingress-ip", self.ingress_ip]
        if self.ingress_ipv6:
            args += ["--ingress-ipv6", self.ingress_ipv6]
        if self.tunnel_cname:
            args += ["--tunnel-cname", self.tunnel_cname]
        if self.ddns_service:
            args += ["--ddns-service", self.ddns_service]
        if self.ddns_subdomain:
            args += ["--ddns-subdomain", self.ddns_subdomain]
        if self.ttl:
            args += ["--ttl", self.ttl]
        if self.out_dir:
            args += ["--out-dir", self.out_dir]
        if self.keys_dir:
            args += ["--keys-dir", self.keys_dir]
        if include_token_file and self.token_file:
            args += ["--token-file", self.token_file]
        return args


@dataclass
class GoLiveProvider:
    """One provider row, as reported by `hugmesh-go-live list`. Its input needs
    are derived from the registry's mechanism taxonomy (not a per-provider catalog
    — the canonical registry does not expose one), so the driver stays the single
    source of provider truth."""
    id: str
    title: str = ""            # the driver's DESCRIPTION column (registry label)
    mechanism: str = ""        # deeplink | files | ddns | funnel | instructions
    status: str = "full"       # full | stub
    model: str = ""            # exposure model (mechanism -> model)
    inputs: list[str] = field(default_factory=list)      # hard-required inputs
    optional: list[str] = field(default_factory=list)    # optional inputs

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

    # ---- driver/registry locations -------------------------------------------
    @property
    def driver_path(self) -> str:
        return os.path.join(self.generator_dir, *DRIVER_REL.split("/"))

    @property
    def registry_path(self) -> str:
        return os.path.join(self.generator_dir, *REGISTRY_REL.split("/"))

    @property
    def default_out_dir(self) -> str:
        # the driver's own default is /var/lib/hugmesh/go-live/out (GL_OUT_DIR);
        # for the dev Studio we prefer a repo-local dir unless GL_OUT_DIR is set.
        return os.environ.get("GL_OUT_DIR") or os.path.join(self.generator_dir, "out", "go-live")

    def _driver_env(self) -> dict[str, str]:
        """Environment for every driver invocation: point GL_PROVIDERS_LIB at the
        in-repo registry (so the dev Studio finds it without the /usr/lib bake),
        unless the caller already set it (test override point). Deliberately never sets
        GL_ASSUME_YES — that would bypass the commit gate."""
        env = dict(os.environ)
        if "GL_PROVIDERS_LIB" not in env and os.path.exists(self.registry_path):
            env["GL_PROVIDERS_LIB"] = self.registry_path
        return env

    def autofill_domain(self) -> str:
        """The baked cluster domain the driver reads --domain from
        (GOLIVE_CLUSTER_DOMAIN_FILE / /etc/hugmesh/cluster-domain) — read here
        only so the GUI can prefill the same value the driver would use."""
        path = os.environ.get("GOLIVE_CLUSTER_DOMAIN_FILE", "/etc/hugmesh/cluster-domain")
        try:
            with open(path, encoding="utf-8") as f:
                return "".join(f.read().split())
        except OSError:
            return ""

    def tor_domain_onions(self) -> dict[str, str]:
        """``{slug: "<hash>.onion"}`` — the per-domain onions this node exports (#582),
        read the way the driver's ``_glp_onion_domains`` reads them. {} when none."""
        d = os.environ.get("GL_ONION_EXPORT_DIR", _ONION_EXPORT_DIR_DEFAULT)
        try:
            names = sorted(os.listdir(d))
        except OSError:
            return {}
        out: dict[str, str] = {}
        for fn in names:
            slug = fn[:-len(".hostname")] if fn.endswith(".hostname") else ""
            if not slug or not _ONION_SLUG_RE.match(slug):
                continue
            try:
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    addr = "".join(f.read().split())
            except OSError:
                continue
            if addr:
                out[slug] = addr
        return out

    def domain_onion(self, domain: str) -> str:
        """The onion a Go-Live for ``domain`` exposes over Tor: that domain's OWN onion
        when it is a Tor domain here (its slug is exported), else "" — the primary
        onion serves the node's own (cluster) domain and needs no lookup."""
        from .own_casdoor import slug as _slug
        return self.tor_domain_onions().get(_slug((domain or "").strip()), "")

    # ---- provider registry (via the driver's `list` — the source of truth) ----
    def providers(self) -> list[GoLiveProvider]:
        if self._providers is None:
            self._providers = self._load_providers()
        return self._providers

    def provider(self, provider_id: str) -> GoLiveProvider | None:
        return next((p for p in self.providers() if p.id == provider_id), None)

    def models(self) -> list[str]:
        """Distinct exposure models in registry order (the wizard's step-1 radios)."""
        seen: list[str] = []
        for p in self.providers():
            if p.model and p.model not in seen:
                seen.append(p.model)
        return seen

    def _load_providers(self) -> list[GoLiveProvider]:
        """Parse `hugmesh-go-live list`. Its table is
        ``ID  MECHANISM  STATE  DESCRIPTION`` — the id/mechanism/state columns are
        single tokens, so split(maxsplit=3) recovers the description verbatim. Rows
        whose mechanism is not a known taxonomy value (the header + trailing prose)
        are ignored."""
        out: list[GoLiveProvider] = []
        try:
            r = subprocess.run(
                ["bash", f"./{DRIVER_REL}", "list"], cwd=self.generator_dir,
                env=self._driver_env(), stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, timeout=30)
            lines = (r.stdout or "").splitlines()
        except (OSError, subprocess.SubprocessError):
            return out
        for line in lines:
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            pid, mech, state, desc = parts
            if mech not in _MECH_MODEL or state not in ("full", "stub"):
                continue
            req, opt = _MECH_INPUTS.get(mech, ([], []))
            out.append(GoLiveProvider(
                id=pid, title=desc, mechanism=mech, status=state,
                model=_MECH_MODEL[mech], inputs=list(req), optional=list(opt)))
        return out

    # ---- command assembly ----------------------------------------------------
    def command(self, subcommand: str, opts: GoLiveOptions,
                include_token_file: bool = True) -> list[str]:
        """The exact driver invocation (run with cwd=generator_dir, like
        BuildDriver): ``bash ./<driver> <subcommand> <flags>``."""
        return ["bash", f"./{DRIVER_REL}", subcommand,
                *opts.to_cli_args(include_token_file=include_token_file)]

    def command_string(self, subcommand: str, opts: GoLiveOptions) -> str:
        return " ".join(shlex.quote(x) for x in self.command(subcommand, opts))

    # ---- execution (mirrors BuildDriver._stream) -------------------------------
    def run(self, subcommand: str, opts: GoLiveOptions,
            on_line: Callable[[str], None] | None = None) -> int:
        """Run one driver subcommand (the GUI uses this only for ``plan`` — the
        read-only, posture-safe emit), calling on_line per output line
        (stdout+stderr merged). Returns the exit code. Blocking — callers run it on
        a worker thread (the GUI uses a QThread)."""
        self._cancel.clear()
        self._proc = subprocess.Popen(
            self.command(subcommand, opts), cwd=self.generator_dir,
            env=self._driver_env(), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1, **proc_text.TEXT_IO)
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
        """The driver's own `status` report (read-only, cheap), for display."""
        try:
            r = subprocess.run(["bash", f"./{DRIVER_REL}", "status"],
                               cwd=self.generator_dir, env=self._driver_env(),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=30)
            return _ANSI_RE.sub("", r.stdout or "").strip()
        except (OSError, subprocess.SubprocessError) as e:
            return f"status unavailable: {e}"

    # ---- secret staging ---------------------------------------------------------
    @staticmethod
    def stage_token(secret: str) -> str:
        """Write a masked-field secret to a fresh 0600 temp file and return its
        path (for --token-file). The caller deletes it right after the run —
        mirroring the console front-ends' token handling."""
        fd, path = tempfile.mkstemp(prefix=".golive-tok-")
        try:
            if hasattr(os, "fchmod"):        # mkstemp is already 0600; belt-and-braces
                os.fchmod(fd, 0o600)
            os.write(fd, secret.encode() + b"\n")
        finally:
            os.close(fd)
        return path

    # ---- commit / rollback (terminal path — the driver's TTY confirm is the law) -
    def commit_command(self, opts: GoLiveOptions, persist: bool = False) -> list[str]:
        """The commit invocation: sudo (writing /etc/hugmesh/go-live needs root)
        + only the flags `commit` consumes. NO -y/--yes: the driver's confirmation
        gate MUST run on the real TTY (adding -y here would be the bypass this
        front-end refuses to add). NO token files: commit never needs a secret."""
        inner = ["bash", f"./{DRIVER_REL}", "commit"]
        if opts.provider:
            inner += ["--provider", opts.provider]
        if opts.domain:
            inner += ["--domain", opts.domain]
        if persist:
            inner += ["--persist-public"]
        return inner if self.is_root else ["sudo", *inner]

    def rollback_command(self, revert_release_state: bool = False) -> list[str]:
        """rollback deletes the marker (root). Like commit, NO -y/--yes — the
        driver's confirm runs on the TTY."""
        inner = ["bash", f"./{DRIVER_REL}", "rollback"]
        if revert_release_state:
            inner += ["--revert-release-state"]
        return inner if self.is_root else ["sudo", *inner]

    def terminal_command(self, inner: list[str]) -> list[str] | None:
        """Wrap inner in the first available terminal emulator (kept open at the
        end so the driver's result stays readable). The in-repo registry path is
        exported into the shell so the driver finds it even if the emulator scrubs
        the environment. None when no emulator exists."""
        prefix = ""
        env = self._driver_env()
        if "GL_PROVIDERS_LIB" in env:
            prefix = f"export GL_PROVIDERS_LIB={shlex.quote(env['GL_PROVIDERS_LIB'])}; "
        script = (prefix + shlex.join(inner)
                  + '; rc=$?; echo; read -r -p "press Enter to close..." _; exit "$rc"')
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
            subprocess.Popen(cmd, cwd=self.generator_dir, env=self._driver_env(),
                             start_new_session=True)
        except OSError as e:
            return False, f"could not launch {cmd[0]}: {e}"
        return True, (f"Launched in {cmd[0]} — finish there (the driver prints the "
                      "posture change, then asks you to CONFIRM on the TTY; there is "
                      "deliberately no way around that confirm).")

    def run_commit_in_terminal(self, opts: GoLiveOptions, persist: bool = False) -> tuple[bool, str]:
        return self._run_in_terminal(self.commit_command(opts, persist=persist))

    def run_rollback_in_terminal(self, revert_release_state: bool = False) -> tuple[bool, str]:
        return self._run_in_terminal(self.rollback_command(revert_release_state=revert_release_state))

    # ---- preflight (GUI hints only — the driver re-validates everything) --------
    def preflight(self, opts: GoLiveOptions, has_secret: bool = False) -> list[str]:
        """Human-readable problems that would stop `plan`/commit (empty = OK).
        Purely a courtesy preview: input needs come from the mechanism taxonomy,
        and the driver independently enforces (and shape-checks) all of them."""
        problems: list[str] = []
        if not os.path.exists(self.driver_path):
            problems.append(f"go-live driver not found: {self.driver_path}")
        if not os.path.exists(self.registry_path):
            problems.append(f"provider registry not found: {self.registry_path}")
        if not shutil.which("bash"):
            problems.append("bash is required to run the go-live driver.")
        p = self.provider(opts.provider) if opts.provider else None
        # Onion (and any future no-domain mechanism) has no public DNS name — the
        # .onion address IS the endpoint, so don't demand a domain for it.
        needs_domain = not (p and p.mechanism in _NO_DOMAIN_MECHANISMS)
        if needs_domain and not (opts.domain or self.autofill_domain()):
            problems.append("Domain is required (no /etc/hugmesh/cluster-domain bake "
                            "found to autofill from).")
        if not opts.provider:
            problems.append("Pick a provider first (plan needs one).")
        elif p is None:
            problems.append(f"Unknown provider '{opts.provider}' (see the provider list).")
        else:
            if p.needs("token") and not (opts.token_file or has_secret):
                problems.append(f"Provider '{p.id}' needs a token — paste it in the "
                                "masked field or point at a token file.")
            if p.needs("subdomain"):
                if not opts.ddns_subdomain:
                    problems.append(f"Provider '{p.id}' needs a DDNS subdomain label.")
                elif not _DNS_LABEL_RE.match(opts.ddns_subdomain):
                    problems.append("DDNS subdomain must be a single lowercase DNS label "
                                    "([a-z0-9-], 1-63 chars, no dots) — the driver rejects "
                                    "anything else (root-cron injection guard).")
            if p.mechanism == "onion" and opts.domain:
                # #582: onion ACCEPTS a domain. The node's own domain is the primary
                # onion; any other must be a Tor domain on this node, or the plan
                # would list no onion for it.
                own = self.autofill_domain()
                if opts.domain != own and not self.domain_onion(opts.domain):
                    served = ", ".join(sorted(self.tor_domain_onions())) or "none"
                    problems.append(
                        f"{opts.domain} has no Tor front door on this node — the "
                        "onion plan lists the primary onion"
                        + (f" ({own})" if own else "")
                        + f" and the Tor domains exported here ({served}). Give the "
                        "domain its ‘Tor front door’ in the Studio's Domain services "
                        "step, or clear the domain.")
            if p.mechanism == "files" and not (opts.ingress_ip or opts.tunnel_cname):
                problems.append(f"Provider '{p.id}': no ingress IP / tunnel CNAME — emitted "
                                "records will be PLACEHOLDERS (re-run with --ingress-ip or "
                                "--tunnel-cname to autofill the real targets).")
        if opts.ingress_ip and not _IPV4_RE.match(opts.ingress_ip):
            problems.append("Record IP is not a valid IPv4 address (the driver rejects it).")
        if opts.token_file and not os.path.exists(opts.token_file):
            problems.append(f"token file does not exist: {opts.token_file}")
        return problems
