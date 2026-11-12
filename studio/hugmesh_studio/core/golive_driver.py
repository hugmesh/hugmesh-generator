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

TARGETS (core.golive_target): with ``target=None`` (or a LOCAL target) every verb runs
the checkout's driver on THIS host, as it always has. With an EMULATED target every
verb is an ``ssh`` into that device and its own baked /usr/sbin/hugmesh-go-live answers
— status, list, the probe that feeds the domain/onion tables, plan (token over ssh
stdin), and commit/rollback in a terminal on the ssh pty. This host then runs no bash
at all, which is what lets a WHPX device on native Windows go live too.

Secret hygiene: token VALUES never enter argv — a masked GUI field is staged into
a 0600 temp file (``stage_token``) handed over via --token-file and deleted right
after the run. GoLiveOptions has no field for a secret value at all.
"""
from __future__ import annotations

import dataclasses
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading

from . import golive_target, platform_info, proc_text
from .cloud_deploy import TERMINALS
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
# mechanism names WHICH onion — GoLiveDriver.domain_onion answers it, preflight says
# when the domain has none, and core.golive_domains.plan_rows shows it on both faces.
_NO_DOMAIN_MECHANISMS = frozenset({"onion"})

# Terminal emulators the commit/rollback can run in: the ONE shared list,
# cloud_deploy.TERMINALS — imported, not copied, so ptyxis/kgx and any later addition
# reach this page too.

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
    def __init__(self, generator_dir: str, is_root: bool | None = None,
                 target: golive_target.GoLiveTarget | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        if is_root is None:
            is_root = getattr(os, "geteuid", lambda: -1)() == 0
        self.is_root = is_root
        self.target = target or golive_target.local_target()
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()
        self._providers: list[GoLiveProvider] | None = None
        self._probe: golive_target.Probe | None = None

    # ---- the target ------------------------------------------------------------
    @property
    def remote(self) -> bool:
        """True when every verb is an ssh into an emulated device."""
        return self.target.is_remote

    def probe(self, refresh: bool = False) -> golive_target.Probe:
        """The device's one read-only probe (cached; ``refresh`` re-reads it)."""
        if self._probe is None or refresh:
            self._probe = golive_target.probe(self.target)
        return self._probe

    @property
    def work_dir(self) -> str:
        from .qemu_devices import default_work_dir
        return self.target.work_dir or default_work_dir(self.generator_dir)

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
        only so the GUI can prefill the same value the driver would use. For an
        emulated target it is the DEVICE's file, read by the probe."""
        if self.remote:
            return self.probe().cluster_domain
        path = os.environ.get("GOLIVE_CLUSTER_DOMAIN_FILE", "/etc/hugmesh/cluster-domain")
        try:
            with open(path, encoding="utf-8") as f:
                return "".join(f.read().split())
        except OSError:
            return ""

    def tor_domain_onions(self) -> dict[str, str]:
        """``{key directory name: "<hash>.onion"}`` — the per-domain onions this node
        exports (#582). ONE reader for the export directory: the go-live plan's own
        (``core.golive_domains.onion_exports`` — ``$GL_ONION_EXPORT_DIR``, only
        well-formed names and v3 addresses). {} when none."""
        from .golive_domains import onion_exports       # lazy: it has no need of us
        if self.remote:
            return dict(onion_exports(files=self.probe().onion_files)[1])
        return dict(onion_exports()[1])

    def onion_scan(self):
        """``golive_domains.onion_export_scan`` for this target: the host's export
        directory for LOCAL, the device's files (from the probe) for an emulated one."""
        from .golive_domains import onion_export_scan
        if self.remote:
            return onion_export_scan(files=self.probe().onion_files)
        return onion_export_scan()

    def baked_domains(self) -> list[str]:
        """``golive_domains.baked_domains`` for this target (primary first)."""
        from .golive_domains import baked_domains
        if self.remote:
            return baked_domains(self.autofill_domain(), text=self.probe().domains_text)
        return baked_domains(self.autofill_domain())

    def domain_onion(self, domain: str) -> str:
        """The onion a Go-Live for ``domain`` exposes over Tor: that domain's OWN onion
        when it is a Tor domain here, else "" — the primary onion serves the node's
        own (cluster) domain and needs no lookup.

        A domain is matched to its export by the key directory name the Studio gave it
        when its ‘Tor front door’ was ticked (``core.domain_services.onion_slug``) —
        a rule, not a guess: docs/TOR-HIDDEN-SERVICE.md spells it, and it is the only
        name under which a node is ever told to mint that domain's onion."""
        from .domain_services import onion_slug
        slug = onion_slug((domain or "").strip())
        return self.tor_domain_onions().get(slug, "") if slug else ""

    # ---- provider registry (via the driver's `list` — the source of truth) ----
    def blocker(self) -> str:
        """WHY the driver cannot run against this target, "" when it can.

        LOCAL: native Windows only — every verb is ``bash ./specs/usr/sbin/
        hugmesh-go-live``, and the bash found there is the WSL launcher, so `list`
        printed nothing and the wizard offered no provider at all instead of saying
        why. EMULATED: the target's own refusal (not running, no ssh channel, a client
        or non-go-live platform), then the probe's (unreachable, or no driver baked —
        B8). The native-Windows blocker does NOT apply: this host runs only ssh."""
        if self.remote:
            why = golive_target.refusal(self.target)
            if why:
                return why
            return golive_target.probe_refusal(self.target, self.probe())
        return platform_info.native_windows_blocker("Go Live", runs="bash scripts")

    def commit_refusal(self) -> str:
        """Why a COMMIT cannot be launched against this target, "" when it can. On
        LOCAL this is B1: a host that is not a HugMesh node has no reconciler to act on
        the marker (``golive_target.local_node_refusal``)."""
        if self.remote:
            return self.blocker()
        return self.blocker() or golive_target.local_node_refusal()

    def providers(self) -> list[GoLiveProvider]:
        if self._providers is None:
            # Where the driver cannot run (native Windows), read the SAME registry
            # file its `list` prints, so the wizard still offers the real providers and
            # previews a plan; only the verbs that execute it are refused.
            self._providers = (self._registry_providers() if self.blocker()
                               else self._load_providers())
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
            if self.remote:
                r = subprocess.run(
                    golive_target.remote_verb_argv(self.target, "list"),
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True, timeout=45)
            else:
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

    def _registry_providers(self) -> list[GoLiveProvider]:
        """The providers `hugmesh-go-live list` would print, read straight from the
        registry (specs/usr/lib/hugmesh/go-live-providers.sh) without bash.

        The registry is declarative: ``GO_LIVE_PROVIDER_IDS=(…)`` in listing order and
        ``declare -gA GO_LIVE_{LABEL,MECH,STATUS}=( [id]="value" … )``. ``cmd_list``
        prints exactly id, ``glp_mechanism`` (default ``instructions``), ``full``/``stub``
        and ``glp_label`` (default the id) — the same defaults are applied here, and the
        same row filter as :meth:`_load_providers`. A test pins this reader to the
        driver's own `list` on a host that can run it."""
        try:
            with open(self.registry_path, encoding="utf-8") as f:
                text = f.read()
        except OSError:
            return []
        ids_m = re.search(r"^GO_LIVE_PROVIDER_IDS=\(([^)]*)\)", text, re.M)
        if not ids_m:
            return []

        def table(name: str) -> dict[str, str]:
            m = re.search(rf"^declare -gA {name}=\((.*?)^\)", text, re.M | re.S)
            if not m:
                return {}
            return dict(re.findall(r'^\s*\[([^\]]+)\]="([^"]*)"', m.group(1), re.M))

        label, mech, status = (table("GO_LIVE_LABEL"), table("GO_LIVE_MECH"),
                               table("GO_LIVE_STATUS"))
        out: list[GoLiveProvider] = []
        for pid in ids_m.group(1).split():
            m = mech.get(pid, "instructions")
            state = "full" if status.get(pid, "stub") == "full" else "stub"
            if m not in _MECH_MODEL:
                continue
            req, opt = _MECH_INPUTS.get(m, ([], []))
            out.append(GoLiveProvider(
                id=pid, title=label.get(pid, pid), mechanism=m, status=state,
                model=_MECH_MODEL[m], inputs=list(req), optional=list(opt)))
        return out

    # ---- command assembly ----------------------------------------------------
    def command(self, subcommand: str, opts: GoLiveOptions,
                include_token_file: bool = True) -> list[str]:
        """The exact driver invocation (run with cwd=generator_dir, like
        BuildDriver): ``bash ./<driver> <subcommand> <flags>`` — or, for an emulated
        target, ``ssh … sudo -n hugmesh-go-live <subcommand> <flags>``."""
        if self.remote:
            return golive_target.remote_verb_argv(
                self.target, subcommand,
                opts if include_token_file else
                dataclasses.replace(opts, token_file=""))
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
        blocker = self.blocker()
        if blocker:
            if on_line:
                on_line(f"!! {blocker}")
            return 2
        self._cancel.clear()
        if self.remote:
            if subcommand in ("commit", "rollback"):
                if on_line:
                    on_line(f"!! {subcommand} needs a terminal (the device's confirm "
                            "runs on a TTY) — use the terminal path")
                return 2
            if subcommand == "plan":
                return golive_target.run_plan(
                    self.target, opts, on_line=on_line, work_dir=self.work_dir,
                    cancel=self._cancel, on_proc=self._set_proc)
            self._proc = subprocess.Popen(
                golive_target.remote_verb_argv(self.target, subcommand, opts),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1, **proc_text.TEXT_IO)
            return self._stream(on_line)
        self._proc = subprocess.Popen(
            self.command(subcommand, opts), cwd=self.generator_dir,
            env=self._driver_env(), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1, **proc_text.TEXT_IO)
        return self._stream(on_line)

    def _set_proc(self, proc) -> None:
        self._proc = proc

    def _stream(self, on_line) -> int:
        assert self._proc is not None and self._proc.stdout is not None
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
        blocker = self.blocker()
        if blocker:
            return blocker
        try:
            if self.remote:
                r = subprocess.run(golive_target.remote_verb_argv(self.target, "status"),
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=45)
            else:
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
    def _local_driver(self, absolute: bool) -> str:
        """The checkout's driver as ``bash`` is given it: ``./specs/…`` for a run whose
        cwd is generator_dir (the GUI terminal), or the absolute path when the caller's
        cwd is wherever the operator typed the command (the CLI)."""
        return self.driver_path if absolute else f"./{DRIVER_REL}"

    def commit_command(self, opts: GoLiveOptions, persist: bool = False,
                       absolute: bool = False) -> list[str]:
        """The commit invocation: sudo (writing /etc/hugmesh/go-live needs root)
        + only the flags `commit` consumes. NO -y/--yes: the driver's confirmation
        gate MUST run on the real TTY (adding -y here would be the bypass this
        front-end refuses to add). NO token files: commit never needs a secret.
        For an emulated target: ``ssh -t … sudo hugmesh-go-live commit …``.
        ``absolute`` names the LOCAL driver by its absolute path (the CLI)."""
        if self.remote:
            return golive_target.commit_argv(self.target, opts.provider, opts.domain,
                                             persist_public=persist)
        inner = ["bash", self._local_driver(absolute), "commit"]
        if opts.provider:
            inner += ["--provider", opts.provider]
        if opts.domain:
            inner += ["--domain", opts.domain]
        if persist:
            inner += ["--persist-public"]
        return inner if self.is_root else ["sudo", *inner]

    def rollback_command(self, revert_release_state: bool = False,
                         absolute: bool = False) -> list[str]:
        """rollback deletes the marker (root). Like commit, NO -y/--yes — the
        driver's confirm runs on the TTY."""
        if self.remote:
            return golive_target.rollback_argv(self.target,
                                               revert_release_state=revert_release_state)
        inner = ["bash", self._local_driver(absolute), "rollback"]
        if revert_release_state:
            inner += ["--revert-release-state"]
        return inner if self.is_root else ["sudo", *inner]

    def terminal_command(self, inner: list[str]) -> list[str] | None:
        """Wrap inner in the first available terminal emulator (kept open at the
        end so the driver's result stays readable). The in-repo registry path is
        exported into the shell so the driver finds it even if the emulator scrubs
        the environment. None when no emulator exists.

        For an emulated target the inner argv is an ``ssh -t …`` and the wrapping is
        ``golive_target.terminal_spec`` (Linux TERMINALS, WSL2 interop, or a new
        console on native Windows)."""
        if self.remote:
            spec = golive_target.terminal_spec(inner)
            return spec.argv if spec else None
        prefix = ""
        env = self._driver_env()
        if "GL_PROVIDERS_LIB" in env:
            prefix = f"export GL_PROVIDERS_LIB={shlex.quote(env['GL_PROVIDERS_LIB'])}; "
        script = (prefix + shlex.join(inner)
                  + '; rc=$?; echo; read -r -p "press Enter to close..." _; exit "$rc"')
        for binary, exec_args in TERMINALS:
            if shutil.which(binary):
                return [binary, *exec_args, "bash", "-c", script]
        return None

    def _run_in_terminal(self, inner: list[str]) -> tuple[bool, str]:
        if self.remote:
            spec = golive_target.terminal_spec(inner)
            if spec is None:
                return False, ("No terminal could be opened here — run this yourself in "
                               f"a terminal: {shlex.join(inner)}")
            try:
                if spec.creationflags:
                    subprocess.Popen(spec.argv, creationflags=spec.creationflags)
                else:
                    subprocess.Popen(spec.argv, start_new_session=True)
            except OSError as e:
                return False, (f"could not launch {spec.argv[0]}: {e} — run this "
                               f"yourself: {shlex.join(inner)}")
            return True, (f"Launched in {spec.argv[0]} — finish there: {self.target.label} "
                          "prints the posture change, then asks you to CONFIRM on the "
                          "ssh TTY; there is deliberately no way around that confirm.")
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
        why = self.commit_refusal()
        if why:
            return False, why
        try:
            inner = self.commit_command(opts, persist=persist)
        except ValueError as e:
            return False, str(e)
        ok, said = self._run_in_terminal(inner)
        if ok and self.remote:
            # Launched, not confirmed: the operator answers on the device's TTY. The
            # journal is what lets Status say what this host asked, and of which boot
            # (the posture itself is always read from the device).
            golive_target.write_journal(
                dataclasses.replace(self.target, work_dir=self.work_dir), "commit",
                opts.provider, opts.domain)
        return ok, said

    def run_rollback_in_terminal(self, revert_release_state: bool = False) -> tuple[bool, str]:
        why = self.blocker()
        if why:
            return False, why
        ok, said = self._run_in_terminal(
            self.rollback_command(revert_release_state=revert_release_state))
        if ok and self.remote:
            golive_target.write_journal(
                dataclasses.replace(self.target, work_dir=self.work_dir), "rollback")
        return ok, said

    # ---- preflight (GUI hints only — the driver re-validates everything) --------
    def preflight(self, opts: GoLiveOptions, has_secret: bool = False) -> list[str]:
        """Human-readable problems that would stop `plan`/commit (empty = OK).
        Purely a courtesy preview: input needs come from the mechanism taxonomy,
        and the driver independently enforces (and shape-checks) all of them."""
        problems: list[str] = []
        if self.remote:
            why = self.blocker()
            if why:
                problems.append(why)
        else:
            if not os.path.exists(self.driver_path):
                problems.append(f"go-live driver not found: {self.driver_path}")
            if not os.path.exists(self.registry_path):
                problems.append(f"provider registry not found: {self.registry_path}")
            if not shutil.which("bash"):
                problems.append("bash is required to run the go-live driver.")
        p = self.provider(opts.provider) if opts.provider else None
        if self.remote:
            why = golive_target.headscale_refusal(self.target, opts.provider,
                                                  p.mechanism if p else "")
            if why:
                problems.append(why)
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
                # Said only when this host KNOWS its own domain: on a host with no
                # baked cluster domain the typed one may well be the node's own.
                # Compared the way plan_rows compares (golive_domains.norm_domain), so
                # ‘Example.ORG’, ‘example.org.’ and ‘ example.org’ are the node's own
                # domain here too, not a Tor domain with no front door.
                from .golive_domains import norm_domain     # lazy, like tor_domain_onions
                own = self.autofill_domain()
                if (own and norm_domain(opts.domain) != norm_domain(own)
                        and not self.domain_onion(opts.domain)):
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
        private = golive_target.refuse_private_ingress(opts.ingress_ip)
        if private:
            problems.append(private)
        if opts.token_file and not os.path.exists(opts.token_file):
            problems.append(f"token file does not exist: {opts.token_file}")
        return problems
