"""Go-Live on the TUI — per-domain exposure (#587; operator decision 71 = A).

The GUI's Go-Live wizard (``gui/pages/golive.py``, tray / ``hugmesh_studio
--go-live``) gained two per-domain surfaces in #587: the Inputs step's picker over the
domains BAKED on the device, and the Generate step's exposure table for every one of
them. This screen (``python -m hugmesh_studio.tui --go-live``) hosts the same route
over the same objects:

* PROVIDER — ``GoLiveDriver.providers()``, i.e. the canonical driver's own ``list``
  (the registry is the source of truth, as on the GUI), each with its exposure model;
* DOMAIN — ``core.golive_domains.baked_domains`` (cluster domain first, then
  /etc/hugmesh/domains), the SAME list the GUI's picker offers; ``t NAME`` types one
  that is not baked, as the GUI's field allows;
* PLAN — ``core.golive_domains.plan_rows`` rendered by ``exposure_lines`` (the GUI's
  Generate step shows exactly these lines), then the exact ``hugmesh-go-live plan``
  command.

What it does NOT do on THIS host: run the driver. ``plan`` stages a provider token and
writes artefacts, and ``commit`` refuses anything but a real TTY on the device by design
— on the device the ncurses ``hugmesh-go-live-menu`` is the terminal face that runs
them. The screen says so and hands over the command.

TARGET (``core.golive_target``; the GUI Preflight step's picker): ``t`` lists this host
and every keep-alive emulated device of the work dir, greyed rows with their refusal
sentence, and picks one. Against an EMULATED device this host runs nothing but ssh, and
the device's own baked driver is the authority, so the screen MAY run the read-only
verbs there — ``s`` status, ``l`` list, ``p`` plan (the plan writes inside the device and
its artefacts are copied back) — and hands over the exact ``ssh -t … commit`` command to
run in a terminal, where the device asks to confirm on its TTY (no -y, ever). The Mesh
emulation screen's ``g`` opens this screen on its front door.

The plan stage takes the GUI Inputs step's fields as commands — ``ip ADDR``, ``ip6
ADDR``, ``cname HOST``, ``sub LABEL``, ``svc duckdns|cloudflare`` (``-`` clears),
offered only for a provider that takes them; an emulated target refuses an ingress
address in the emulator's own slirp / mesh-L2 range, as the GUI does. ``r`` on the
target list RE-BINDS the picked device to its record as it is now (a restart moves it
to another port and boot; a stopped device's port can be handed to another device),
and until it is re-bound the plan stage runs nothing on it and hands over no commit.
Tailscale Funnel is refused on an emulated target (its control plane is its own
headscale), on the provider list, as on the GUI's Provider step.
"""
from __future__ import annotations

import os
import shlex

from ..core import golive_target, nvd_key, org_export, qemu_devices
from ..core.golive_domains import (NO_EXPORT_DOMAINS_NOTE, NO_EXTRA_DOMAINS_NOTE,
                                   baked_domains, export_candidates,
                                   export_step_applies, exposure_lines, plan_rows)
from ..core.golive_driver import GoLiveDriver, GoLiveOptions, _NO_DOMAIN_MECHANISMS
from .nvd_step import SECRET_PROMPT, NvdCommands
from .nvd_step import HELP as NVD_HELP

__all__ = ["GoLiveScreen", "THIS_HOST", "target_title"]

#: the LOCAL row's name on both faces
THIS_HOST = "This host"

#: how many lines of a plan run the plan stage keeps on screen
PLAN_TAIL = 40

#: The plan stage's input commands — the GUI Inputs step's fields, one command each:
#: (command, GoLiveOptions attribute, the provider input that offers it (GoLiveProvider
#: .offers), the driver flag, what it takes). Offered only for a provider that takes it.
PLAN_INPUTS = (
    ("ip", "ingress_ip", "ingress-ip", "--ingress-ip", "ADDR"),
    ("ip6", "ingress_ipv6", "ingress-ipv6", "--ingress-ipv6", "ADDR"),
    ("cname", "tunnel_cname", "tunnel-cname", "--tunnel-cname", "HOST"),
    ("sub", "ddns_subdomain", "subdomain", "--ddns-subdomain", "LABEL"),
    ("svc", "ddns_service", "ddns-service", "--ddns-service", "duckdns|cloudflare"),
)
_INPUT_BY_COMMAND = {row[0]: row for row in PLAN_INPUTS}
#: the GUI's DDNS service picker's two entries
DDNS_SERVICES = ("duckdns", "cloudflare")


def target_title(t: golive_target.GoLiveTarget) -> str:
    """How a target reads in the list — the GUI picker's own words."""
    if t.is_local:
        return THIS_HOST
    lane = "QEMU for Windows" if t.kind == golive_target.KIND_WHPX else "emulated"
    what = " · ".join(x for x in (t.platform, t.role) if x)
    return f"{t.label} ({lane}{' · ' + what if what else ''})"


def same_line_heading(osname: str | None = None) -> str:
    """The heading over the export's hand-over line. On native Windows
    org_export.cli_command writes that line for PowerShell (the ``&`` call operator,
    '' quoting), which cmd.exe would not run, so the heading names the shell."""
    if (osname or os.name) == "nt":
        return "The same in PowerShell:"
    return "The same from a terminal:"


class GoLiveScreen:
    """``provider`` -> ``domain`` -> ``plan`` (-> ``export``, offered only when a domain
    names a GitHub org — the GUI's optional "Export to GitHub org" step, same engine,
    same plan text)."""

    slug = "golive"
    title = "Go-Live"
    wants_q = False

    def __init__(self):
        self.stage = "provider"
        self.driver: GoLiveDriver | None = None
        self.opts = GoLiveOptions()
        #: WHERE the verbs run (golive_target): this host until ``t`` picks a device
        self.target = golive_target.local_target()
        self.work_dir = ""                     # "" = qemu_devices.default_work_dir
        self._rows: list = []
        self.run_log: list[str] = []           # the last s / l / p output
        #: what ``b`` on the first step returns to when opened OVER another screen
        self.back_to = "Brand settings"
        # the export step's state: config files added with `c FILE`, the picked
        # candidate, the last plan / result; and the two test seams the GUI has too
        self.export_config_files: list[str] = []
        self.export_pick = 0
        self.export_plan = None
        self.export_result = None
        self.export_runner = None
        self.export_remote_base = ""
        self.export_visibility = "private"
        self.export_update = org_export.UPDATE_REFUSE
        self.export_rename_map = ""            # `r FILE`: the CLI's --rename-map
        #: the NVD API key the exported repos' SCA jobs need (the GUI step's box)
        self.nvd = NvdCommands(org_of=self._picked_org)

    def _driver(self, j) -> GoLiveDriver:
        if self.driver is None:
            t = self.target
            self.driver = GoLiveDriver(j.generator_dir,
                                       target=t if t.is_remote else None)
        return self.driver

    def domains(self, j) -> list[str]:
        """The picker's list — the driver's ``baked_domains`` (this host's files, or
        the device's own read over ssh), the GUI's call."""
        d = self._driver(j)
        if self.target.is_remote:
            return d.baked_domains()
        return baked_domains(d.autofill_domain())

    # ── the target ──────────────────────────────────────────────────────────────
    def _work(self, j) -> str:
        return os.path.abspath(self.work_dir or qemu_devices.default_work_dir(
            j.generator_dir))

    def target_rows(self, j) -> list:
        try:
            rows = golive_target.targets(self._work(j))
        except OSError:
            rows = [golive_target.local_target()]
        self._rows = rows
        return rows

    def preselect_target(self, j, target, work_dir: str = "") -> str:
        """Open on ``target`` (a GoLiveTarget or a device label) — the Mesh emulation
        screen's ``g``. Returns "" or why not (the screen then stays on this host)."""
        if work_dir:
            self.work_dir = work_dir
        if isinstance(target, str):
            found = golive_target.find_target(self.target_rows(j), target.strip())
            if found is None:
                return f"no running device '{target}' in {self._work(j)}"
            target = found
        return self.set_target(j, target)

    def set_target(self, j, target) -> str:
        """Point every verb at ``target``; "" or the sentence that refuses it (the
        record's, then the device's probe over ssh — B8). A refused device is not
        taken: the previous target stays."""
        import dataclasses
        # (the driver's blocker() is the record's refusal FIRST — a refused row is
        # turned away before anything is sent to it — then the probe over ssh)
        if target.is_remote and not target.work_dir:
            target = dataclasses.replace(target, work_dir=self._work(j))
        old = (self.target, self.driver)
        self.target, self.driver = target, None
        why = self._driver(j).blocker() if target.is_remote else ""
        if why:
            self.target, self.driver = old
            return why
        if (old[0].kind, old[0].label) != (target.kind, target.label):
            self.opts.provider = ""
        self.run_log = []
        return ""

    def fresh(self, j, target):
        """``target``'s device as the work dir says it is NOW (golive_target.rebind):
        a restart's new port and boot, or NOT running when it stopped or is gone."""
        return golive_target.rebind(target, self.target_rows(j))

    def rebind_target(self, j) -> str:
        """``r``: re-bind the picked device to its fresh record, whatever it says. A
        stopped device is KEPT, refused (unlike a pick, which keeps the previous
        target): what must never survive a re-scan is the old port. "" or why."""
        t = self.target
        if t.is_local:
            return ""
        fresh = self.fresh(j, t)
        if not golive_target.same_binding(fresh, t):
            self.target, self.driver = fresh, None
            self.run_log = []
        return golive_target.refusal(self.target) or (
            self._driver(j).blocker() if self.target.running else "")

    def stale_binding(self, j) -> str:
        """"" while the picked device is still the record it was picked as; otherwise
        what changed and how to re-pick it (the GUI's stale_binding, TUI words)."""
        if self.target.is_local:
            return ""
        why = golive_target.binding_change(self.target, self.target_rows(j))
        return (why + " (t, then r: re-scan.)") if why else ""

    def _target_line(self, j) -> str:
        t = self.target
        if t.is_local:
            b1 = golive_target.local_node_refusal()
            return (f"target: {THIS_HOST}" + (f" (plan/status preview; commit refused: {b1})"
                                           if b1 else ""))
        return (f"target: {target_title(t)} — its own {golive_target.GUEST_DRIVER}, over "
                f"ssh 127.0.0.1:{t.ssh_port}")

    def _lines_target(self, j) -> list[str]:
        rows = self.target_rows(j)
        out = ["Where does go-live run? This host, or a running emulated device (its "
               "own baked driver, over ssh — this host runs nothing but ssh).", ""]
        for i, t in enumerate(rows, 1):
            cur = "  <- picked" if (t.kind, t.label) == (self.target.kind,
                                                          self.target.label) else ""
            out.append(f"  {i}. {target_title(t)}{cur}")
            why = golive_target.refusal(t)
            if why:
                out.append(f"       ! refused: {why}")
            elif t.is_local and golive_target.local_node_refusal():
                out.append("       plan/status preview only — commit refused: "
                           + golive_target.local_node_refusal())
        out += ["", "commands: NUMBER=pick · r=re-scan (re-binds the picked device) · "
                "Enter or b=back to the providers"]
        return out

    def _feed_target(self, j, line: str) -> None:
        if line == "" or line.lower() == "b":
            self.stage = "provider"
            return
        if line.lower() == "r":
            # lines() re-reads the rows; the PICKED device is re-bound here
            why = self.rebind_target(j)
            if why:
                j.status = why
            return
        rows = self._rows or self.target_rows(j)
        try:
            n = int(line)
        except ValueError:
            n = 0
        if not 1 <= n <= len(rows):
            j.status = f"no such target: {line!r}"
            return
        # the rows were read when the list was drawn: take the record as it is NOW
        why = self.set_target(j, self.fresh(j, rows[n - 1]))
        if why:
            j.status = why
            return
        self.stage = "provider"

    # ── screen protocol ─────────────────────────────────────────────────────────
    def enter(self, j) -> None:  # noqa: ARG002
        self.stage = "provider"

    def secret_input(self, j) -> bool:  # noqa: ARG002
        return self.nvd.secret_input()

    def prompt(self, j) -> str:  # noqa: ARG002
        if self.nvd.secret_input():
            return SECRET_PROMPT
        return f"go-live-{self.stage}> "

    def lines(self, j) -> list[str]:
        return getattr(self, f"_lines_{self.stage}")(j)

    def feed(self, j, line: str) -> None:
        if self.nvd.secret_input():
            self.nvd.feed_secret(j, line)
            return
        getattr(self, f"_feed_{self.stage}")(j, line.strip())

    # ── provider ────────────────────────────────────────────────────────────────
    def _providers_or_blocker(self, j) -> tuple[list, str]:
        """The providers a pick may take, and why none may be picked ("" when one may).

        A device the driver cannot run against lists NONE: ``r`` keeps a stopped device
        (refused), and providers() would then fall back to THIS checkout's registry,
        which is not what the device offers (the GUI's Preflight shuts Next on the same
        record). On this host an empty list is the native-Windows blocker; a listed
        registry there is real, and the screen goes on."""
        d = self._driver(j)
        if self.target.is_remote:
            why = d.blocker()
            if why:
                return [], why
        providers = d.providers()
        return providers, ("" if providers else d.blocker())

    def _lines_provider(self, j) -> list[str]:
        providers, blocker = self._providers_or_blocker(j)
        out = ["Internal-only -> publicly live. Pick the provider (the driver's own "
               "registry, grouped by exposure model).", self._target_line(j), ""]
        if blocker:
            # No providers on native Windows means the driver could not list them there,
            # so asking whether the driver file is present sent the operator looking for
            # a file that is there. The GUI's Go Live page says the same sentence
            # (gui/pages/golive.py). Where providers ARE listed, the screen goes on.
            out.append(blocker)
            if self.opts.domain and self._over(j):
                out += ["", f"domain: {self.opts.domain} (picked from its Brand settings)"]
            return out + ["", "commands: t=pick the target · " + (
                f"b=back to {self.back_to}" if self._over(j) else "q=quit")]
        if not providers:
            return out + ["(the driver's registry listed no providers — is "
                          "specs/usr/sbin/hugmesh-go-live present?)", "",
                          "commands: " + (f"b=back to {self.back_to}" if self._over(j)
                                          else "q=quit")]
        for i, p in enumerate(providers, 1):
            out.append(f"  {i}. {p.id} — {p.model} ({p.mechanism}) — {p.title}")
            reach = golive_target.mechanism_reachability(p.mechanism, self.target, p.id)
            if reach:
                out.append(f"       from {self.target.label}: {reach}")
            why = golive_target.headscale_refusal(self.target, p.id, p.mechanism)
            if why:
                out.append(f"       ! refused: {why}")
        if self.opts.domain and self._over(j):
            out += ["", f"domain: {self.opts.domain} (picked from its Brand settings)"]
        out += ["", "commands: NUMBER=pick · t=pick the target" + (
            f" · b=back to {self.back_to}" if self._over(j) else "")]
        return out

    def _over(self, j) -> bool:
        """True when this screen was opened over Brand settings (its Ways section's
        ``go-live``), so b on the first step closes it again."""
        return getattr(j, "overlay", None) is self

    def _feed_provider(self, j, line: str) -> None:
        if line.lower() == "b" and self._over(j):
            j.close_overlay()
            return
        if line.lower() == "t":
            self.stage = "target"
            return
        providers, blocker = self._providers_or_blocker(j)
        if blocker:
            j.status = blocker               # not "no such provider": there are none here
            return
        try:
            n = int(line)
        except ValueError:
            n = 0
        if not 1 <= n <= len(providers):
            j.status = f"no such provider: {line!r}"
            return
        p = providers[n - 1]
        why = golive_target.headscale_refusal(self.target, p.id, p.mechanism)
        if why:                                  # the GUI's Provider step refuses it too
            j.status = why
            return
        self.opts.provider = p.id
        self.stage = "domain"

    # ── domain ──────────────────────────────────────────────────────────────────
    def _lines_domain(self, j) -> list[str]:
        doms = self.domains(j)
        p = self._driver(j).provider(self.opts.provider)
        out = ["Which domain does this run expose? One per run — the driver takes "
               "one --domain per plan.", ""]
        if p and p.mechanism in _NO_DOMAIN_MECHANISMS:
            out += ["(the onion mechanism needs no domain: the .onion is the "
                    "endpoint — Enter continues)", ""]
        for i, name in enumerate(doms, 1):
            mark = " (cluster domain)" if i == 1 else ""
            cur = "  <- picked" if name == self.opts.domain else ""
            out.append(f"  {i}. {name}{mark}{cur}")
        if not doms:
            out.append("  (no cluster domain baked on this host — type one: t NAME)")
        if len(doms) <= 1:
            out += ["", NO_EXTRA_DOMAINS_NOTE]
        out += ["", "commands: NUMBER=pick · t NAME=type a domain · b=back · "
                "Enter=continue (default: the cluster domain)"]
        return out

    def _feed_domain(self, j, line: str) -> None:
        doms = self.domains(j)
        if line == "":
            if not self.opts.domain and doms:
                self.opts.domain = doms[0]
            self.stage = "plan"
            return
        if line.lower() == "b":
            self.stage = "provider"
            return
        verb, _, arg = line.partition(" ")
        if verb.lower() == "t" and arg.strip():
            self.opts.domain = arg.strip().lower()
            return
        try:
            n = int(line)
        except ValueError:
            n = 0
        if not 1 <= n <= len(doms):
            j.status = f"no such domain: {line!r}"
            return
        self.opts.domain = doms[n - 1]

    # ── plan ────────────────────────────────────────────────────────────────────
    def plan_lines(self, j) -> list[str]:
        """The exposure lines — ``exposure_lines(plan_rows(...))``, the GUI Generate
        step's exact text."""
        return exposure_lines(plan_rows(self._driver(j), self.opts))

    # ── the plan's inputs (the GUI Inputs step's fields) ────────────────────────────
    def _offered_inputs(self, j) -> list:
        p = self._driver(j).provider(self.opts.provider)
        return [row for row in PLAN_INPUTS if p is not None and p.offers(row[2])]

    def _input_lines(self, j) -> list[str]:
        """What the plan will be given, and the commands that set it."""
        rows = self._offered_inputs(j)
        if not rows:
            return []
        said = " · ".join(f"{flag} {getattr(self.opts, attr) or '(none)'}"
                          for _cmd, attr, _name, flag, _what in rows)
        cmds = " · ".join(f"{cmd} {what}" + ("" if cmd == "svc" else "|-")
                          for cmd, _attr, _name, _flag, what in rows)
        return [f"inputs: {said}", f"  set: {cmds}"]

    def _set_input(self, j, row, arg: str) -> None:
        cmd, attr, name, flag, what = row
        p = self._driver(j).provider(self.opts.provider)
        if p is None or not p.offers(name):
            j.status = f"{self.opts.provider or 'this provider'} takes no {flag}"
            return
        if not arg:
            j.status = f"{cmd} needs {what}" + ("" if cmd == "svc" else ", or - to clear it")
            return
        value = "" if arg == "-" else arg
        if cmd == "svc" and value not in DDNS_SERVICES:
            j.status = f"svc takes one of {', '.join(DDNS_SERVICES)}"
            return
        if cmd in ("ip", "ip6") and self.target.is_remote:
            # the emulator's own addresses (slirp, mesh L2): no registrar record can
            # carry one — refused here, as the GUI's Inputs step refuses it
            why = golive_target.refuse_private_ingress(value)
            if why:
                j.status = why
                return
        setattr(self.opts, attr, value)
        self.run_log = []
        j.status = f"{flag} {value}" if value else f"{flag} cleared"

    def _lines_plan(self, j) -> list[str]:
        d = self._driver(j)
        out = [self._target_line(j), "", "Per-domain exposure (this device):", ""]
        out += ["  " + ln for ln in self.plan_lines(j)]
        inputs = self._input_lines(j)
        if inputs:
            out += [""] + inputs
        if self.target.is_remote:
            return out + self._remote_plan_lines(j)
        out += ["", "The TUI does not run the driver. The exact command (the GUI's "
                "Generate preview — from this checkout; on the device the driver is "
                "/usr/sbin/hugmesh-go-live):",
                "  " + d.command_string("plan", self.opts),
                "On the device, the terminal menu hugmesh-go-live-menu runs it too. "
                "The flip (commit) runs only on a real TTY there, by design."]
        commands = [f"{cmd} {what}{'' if cmd == 'svc' else '|-'}"
                    for cmd, _a, _n, _f, what in self._offered_inputs(j)]
        commands += ["b=back to the domain", "Enter=back to the providers"]
        cands = self.export_candidates(j)
        if export_step_applies(cands):
            commands.append(f"x=export to a GitHub org ({len(cands)} domain"
                            f"{'s' if len(cands) != 1 else ''} name one)")
        out += ["", "commands: " + " · ".join(commands)]
        return out

    # ── an EMULATED target: the read-only verbs run here, the flip is handed over ──
    def commit_command(self, j, persist: bool = False) -> str:
        """The exact ``ssh -t … sudo hugmesh-go-live commit …`` to paste into a
        terminal (the device's confirm runs on that TTY; no -y)."""
        why = self._act_refusal(j)
        if why:
            return f"!! {why}"
        try:
            return shlex.join(self._driver(j).commit_command(self.opts, persist=persist))
        except ValueError as exc:
            return f"!! {exc}"

    def rollback_command(self, j, revert: bool = False) -> str:
        why = self._act_refusal(j)
        if why:
            return f"!! {why}"
        return shlex.join(self._driver(j).rollback_command(revert_release_state=revert))

    def _act_refusal(self, j) -> str:
        """Why nothing may be run on, or handed over for, the picked device: it changed
        since it was picked (stale_binding), or it is refused (stopped, no channel, no
        driver). "" for this host — its commands are never run from here."""
        if self.target.is_local:
            return ""
        return self.stale_binding(j) or self._driver(j).commit_refusal()

    def _remote_plan_lines(self, j) -> list[str]:
        t = self.target
        p = self._driver(j).provider(self.opts.provider)
        out = [""]
        reach = golive_target.mechanism_reachability(p.mechanism if p else "", t,
                                                     self.opts.provider)
        if reach:
            out.append(f"from {t.label}: {reach}")
        out.append(f"EPHEMERAL on {t.label}: {golive_target.EPHEMERAL_NOTE}.")
        js = golive_target.journal_status(self._work(j), t)
        if js:
            out.append(js)
        tok = (f"token file (sent over ssh stdin, never argv): {self.opts.token_file}"
               if self.opts.token_file else
               "token: none (tf PATH names a HOST file whose content is sent over ssh "
               "stdin into a root-only file on the device, deleted after the run)")
        if p is not None and p.offers("token"):
            out.append(tok)
        if self.run_log:
            out += ["", "output:"] + ["  " + ln for ln in self.run_log[-PLAN_TAIL:]]
        out += ["",
                f"The flip runs on {t.label}'s own TTY — paste into a terminal (it asks "
                "you to confirm; there is no way around that):",
                "  " + self.commit_command(j),
                "rollback (back to internal; add --revert-release-state after a "
                "--persist-public flip):",
                "  " + self.rollback_command(j),
                "", "commands: p=run the plan on the device · s=status · l=list · "
                + "".join(f"{cmd} {what}{'' if cmd == 'svc' else '|-'} · "
                          for cmd, _a, _n, _f, what in self._offered_inputs(j))
                + "tf PATH|-=token file · b=back to the domain · Enter=back to the "
                "providers"]
        return out

    def _run_remote(self, j, verb: str) -> None:
        d = self._driver(j)
        lines: list[str] = []
        if verb == "status":
            lines = d.status_text().splitlines()
            js = golive_target.journal_status(self._work(j), self.target)
            if js:
                lines.append(js)
        elif verb == "list":
            for pr in d.providers():
                reach = golive_target.mechanism_reachability(pr.mechanism, self.target,
                                                             pr.id)
                lines.append(f"{pr.id} {pr.mechanism} {pr.status} {pr.title}"
                             + (f"  [{reach}]" if reach else ""))
        else:
            rc = d.run("plan", self.opts, on_line=lines.append)
            lines.append(f"=== plan exited {rc} ===")
            out = golive_target.artifacts_dir(self._work(j), self.target.label)
            if rc == 0 and os.path.isdir(out):
                lines.append(f"artifacts copied back to {out}:")
                lines += [f"  {n}" for n in sorted(os.listdir(out))]
            j.status = f"plan on {self.target.label} exited {rc}"
        self.run_log = lines

    def _feed_plan(self, j, line: str) -> None:
        if line.lower() == "b":
            self.stage = "domain"
            return
        if line == "":
            self.stage = "provider"
            return
        verb, _, arg = line.partition(" ")
        row = _INPUT_BY_COMMAND.get(verb.lower())
        if row is not None:
            self._set_input(j, row, arg.strip())
            return
        if self.target.is_remote:
            low = line.lower()
            if low in ("p", "s", "l"):
                # stale: it would land on whatever holds that port now; refused (a
                # stopped device `r` kept): `l` would list THIS checkout's registry
                why = self._act_refusal(j)
                if why:
                    j.status = why
                    return
                self._run_remote(j, {"p": "plan", "s": "status", "l": "list"}[low])
                return
            if verb.lower() == "tf" and arg.strip():
                path = arg.strip()
                if path == "-":
                    self.opts.token_file = ""
                elif not os.path.isfile(path):
                    j.status = f"token file does not exist: {path}"
                else:
                    self.opts.token_file = path
                return
        if line.lower() == "x":
            if not export_step_applies(self.export_candidates(j)):
                j.status = NO_EXPORT_DOMAINS_NOTE
                return
            self.stage = "export"
            return
        j.status = f"unrecognised command: {line!r}"

    # ── export to a GitHub org (the GUI's optional step; same engine, same text) ──
    def export_candidates(self, j) -> list:
        """The domains that name an org — ``golive_domains.export_candidates``, the
        GUI page's exact call (saved meshes on this machine + added config files)."""
        return export_candidates(j.generator_dir, self.export_config_files)

    def export_config(self, j) -> "org_export.ExportConfig | None":
        """The config `p` plans: the picked candidate's (a generic config file's own
        rules included), the `v`/`u` choices over it, and the `r FILE` rename map
        merged over its own. Raises ValueError/OSError for a rename map that cannot
        be read; the callers put that in the status line."""
        cands = self.export_candidates(j)
        if not cands:
            return None
        c = cands[min(self.export_pick, len(cands) - 1)]
        cfg = c.to_config(visibility=self.export_visibility, update=self.export_update,
                          generator_dir=c.generator_dir or j.generator_dir)
        if self.export_rename_map:
            cfg.rename_map = org_export.merge_rename_maps(
                cfg.rename_map or {}, org_export.load_rename_map(self.export_rename_map))
        if self.export_remote_base:
            cfg.remote_base = self.export_remote_base
        return cfg

    def _picked_org(self, j) -> str:
        c = self._picked_candidate(j)
        return getattr(c, "org", "") if c is not None else ""

    def _picked_candidate(self, j):
        cands = self.export_candidates(j)
        return cands[min(self.export_pick, len(cands) - 1)] if cands else None

    def _cli_command(self, j, cfg, verb: str) -> str:
        c = self._picked_candidate(j)
        return org_export.cli_command(
            cfg, verb,
            # EVERY candidate's file is handed over as --config (the GUI page's rule):
            # a saved mesh's selected services live only in its record
            config_path=c.path if c is not None else "",
            rename_map_path=self.export_rename_map)

    def export_plan_lines(self) -> list[str]:
        """``org_export.plan_lines`` of the last plan — the GUI step's plan text."""
        return org_export.plan_lines(self.export_plan) if self.export_plan else []

    def _lines_export(self, j) -> list[str]:
        cands = self.export_candidates(j)
        out = ["Export a domain's repositories to its GitHub organisation: fresh "
               "single-commit snapshots, renamed for the org, plus a <domain>.github.io "
               "site that builds them all. Plan touches nothing; apply needs the org "
               "name typed. Every git/gh call runs as you (your gh login).", ""]
        if not cands:
            return out + [NO_EXPORT_DOMAINS_NOTE, "", "commands: c FILE=add a config "
                          "file · b=back"]
        for i, c in enumerate(cands, 1):
            cur = "  <- picked" if i - 1 == min(self.export_pick, len(cands) - 1) else ""
            out.append(f"  {i}. {c.label()}{cur}")
        out.append(f"  visibility of created repositories: {self.export_visibility}; "
                   f"existing non-empty repositories: "
                   f"{'pushed to export/<stamp>' if self.export_update == org_export.UPDATE_BRANCH else 'refused unless unchanged'}")
        out.append(f"  rename map: {self.export_rename_map or '(none: the defaults)'}")
        if self.export_plan is not None:
            out += ["", *self.export_plan_lines()]
        if self.export_result is not None:
            out += ["", *org_export.result_lines(self.export_result)]
        try:
            cfg = self.export_config(j)
        except (OSError, ValueError) as exc:
            cfg = None
            out += ["", f"rename map {self.export_rename_map}: {exc}"]
        if cfg is not None:
            out += ["", same_line_heading(), "  " + self._cli_command(j, cfg, "PLAN")]
        # the GUI step's NVD block: the exported repos carry the SCA jobs
        out += ["", nvd_key.export_line(self._picked_org(j)),
                "  NVD API key: " + nvd_key.status_line(), "  " + nvd_key.ACTIVATION_WARNING]
        out += ["", "commands: NUMBER=pick · c FILE=add a config file · r FILE|-=rename "
                "map (exclude a refused file, extra rules) · v private|public|"
                "internal=visibility · u refuse|branch=existing repositories · p=plan "
                "(dry run) · apply ORG=apply (type the org name) · b=back",
                "          " + NVD_HELP]
        return out

    def _feed_export(self, j, line: str) -> None:
        cands = self.export_candidates(j)
        if line.lower() == "b":
            self.stage = "plan"
            return
        if self.nvd.handles(line):
            self.nvd.feed(j, line)
            return
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if verb == "c" and arg:
            try:
                found = org_export.candidates_from_file(arg, j.generator_dir)
            except (OSError, ValueError) as exc:
                # the engine's own messages already start with the path: say it once
                j.status = str(exc) if str(exc).startswith(arg) else f"{arg}: {exc}"
                return
            if not found:
                j.status = f"{arg}: no domain in it names a GitHub org"
                return
            if arg not in self.export_config_files:
                self.export_config_files.append(arg)
            self.export_pick = len(self.export_candidates(j)) - 1
            self.export_plan = self.export_result = None
            # a generic config file's own choices seed `v` and `u`, so `p` plans what
            # the file describes (the GUI pickers do the same)
            if found[0].config is not None:
                self.export_visibility = found[0].config.visibility
                self.export_update = found[0].config.update
            return
        if verb == "r":
            if not arg:
                j.status = "r needs a rename-map FILE, or - to drop it"
                return
            if arg == "-":
                self.export_rename_map = ""
            else:
                try:
                    org_export.load_rename_map(arg)
                except (OSError, ValueError) as exc:
                    j.status = f"{arg}: {exc}"
                    return
                self.export_rename_map = arg
            self.export_plan = self.export_result = None
            return
        if verb == "v":
            if arg not in org_export.VISIBILITY_CHOICES:
                j.status = f"visibility must be one of {', '.join(org_export.VISIBILITY_CHOICES)}"
                return
            self.export_visibility = arg
            self.export_plan = self.export_result = None
            return
        if verb == "u":
            if arg not in org_export.UPDATE_CHOICES:
                j.status = f"u needs one of {', '.join(org_export.UPDATE_CHOICES)}"
                return
            self.export_update = arg
            self.export_plan = self.export_result = None
            return
        if verb == "p":
            try:
                cfg = self.export_config(j)
            except (OSError, ValueError) as exc:          # the rename-map file
                j.status = f"{self.export_rename_map}: {exc}"
                return
            if cfg is None:
                j.status = NO_EXPORT_DOMAINS_NOTE
                return
            problems = cfg.problems()
            if problems:
                j.status = "; ".join(problems)
                return
            try:
                self.export_plan = org_export.plan(
                    cfg, self.export_runner or org_export.SubprocessRunner())
            except (ValueError, OSError, RuntimeError) as exc:
                j.status = f"plan failed: {exc}"
                return
            self.export_result = None
            j.status = ("plan blocked — see BLOCKED above" if self.export_plan.blocked
                        else "planned; nothing created or pushed. apply ORG to apply.")
            return
        if verb == "apply":
            p = self.export_plan
            if p is None:
                j.status = "plan first (p)"
                return
            if not arg or arg.lower() != p.config.org.lower():
                j.status = "type the org name: apply ORG (letter case does not matter)"  # the GUI's arming rule
                return
            if p.blocked:
                j.status = "the plan is blocked; nothing is applied until every repository is clean"
                return
            if self.export_result is not None:            # the GUI's one apply per plan
                j.status = "this plan was applied; plan again (p) to run again"
                return
            self.export_result = org_export.apply(
                p, self.export_runner or org_export.SubprocessRunner())
            j.status = (f"applied: {len(self.export_result.repos) - len(self.export_result.failures)}"
                        f" done, {len(self.export_result.failures)} skipped")
            return
        try:
            n = int(line)
        except ValueError:
            n = 0
        if 1 <= n <= len(cands):
            self.export_pick = n - 1
            self.export_plan = self.export_result = None
            return
        j.status = f"unrecognised command: {line!r}"
