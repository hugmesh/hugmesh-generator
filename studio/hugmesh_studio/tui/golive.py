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

What it does NOT do: run the driver. ``plan`` stages a provider token and writes
artefacts, and ``commit`` refuses anything but a real TTY on the device by design —
on the device the ncurses ``hugmesh-go-live-menu`` is the terminal face that runs
them. The screen says so and hands over the command.
"""
from __future__ import annotations

import os

from ..core import org_export
from ..core.golive_domains import (NO_EXPORT_DOMAINS_NOTE, NO_EXTRA_DOMAINS_NOTE,
                                   baked_domains, export_candidates,
                                   export_step_applies, exposure_lines, plan_rows)
from ..core.golive_driver import GoLiveDriver, GoLiveOptions, _NO_DOMAIN_MECHANISMS

__all__ = ["GoLiveScreen"]


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

    def _driver(self, j) -> GoLiveDriver:
        if self.driver is None:
            self.driver = GoLiveDriver(j.generator_dir)
        return self.driver

    def domains(self, j) -> list[str]:
        """The picker's list — ``baked_domains`` of the driver's own autofill, the
        GUI's call."""
        return baked_domains(self._driver(j).autofill_domain())

    # ── screen protocol ─────────────────────────────────────────────────────────
    def enter(self, j) -> None:  # noqa: ARG002
        self.stage = "provider"

    def prompt(self, j) -> str:  # noqa: ARG002
        return f"go-live-{self.stage}> "

    def lines(self, j) -> list[str]:
        return getattr(self, f"_lines_{self.stage}")(j)

    def feed(self, j, line: str) -> None:
        getattr(self, f"_feed_{self.stage}")(j, line.strip())

    # ── provider ────────────────────────────────────────────────────────────────
    def _lines_provider(self, j) -> list[str]:
        providers = self._driver(j).providers()
        out = ["Internal-only -> publicly live. Pick the provider (the driver's own "
               "registry, grouped by exposure model).", ""]
        if not providers:
            return out + ["(the driver's registry listed no providers — is "
                          "specs/usr/sbin/hugmesh-go-live present?)", "",
                          "commands: " + ("b=back to Brand settings" if self._over(j)
                                          else "q=quit")]
        for i, p in enumerate(providers, 1):
            out.append(f"  {i}. {p.id} — {p.model} ({p.mechanism}) — {p.title}")
        if self.opts.domain and self._over(j):
            out += ["", f"domain: {self.opts.domain} (picked from its Brand settings)"]
        out += ["", "commands: NUMBER=pick" + (" · b=back to Brand settings"
                                              if self._over(j) else "")]
        return out

    def _over(self, j) -> bool:
        """True when this screen was opened over Brand settings (its Ways section's
        ``go-live``), so b on the first step closes it again."""
        return getattr(j, "overlay", None) is self

    def _feed_provider(self, j, line: str) -> None:
        if line.lower() == "b" and self._over(j):
            j.close_overlay()
            return
        providers = self._driver(j).providers()
        try:
            n = int(line)
        except ValueError:
            n = 0
        if not 1 <= n <= len(providers):
            j.status = f"no such provider: {line!r}"
            return
        self.opts.provider = providers[n - 1].id
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

    def _lines_plan(self, j) -> list[str]:
        d = self._driver(j)
        out = ["Per-domain exposure (this device):", ""]
        out += ["  " + ln for ln in self.plan_lines(j)]
        out += ["", "The TUI does not run the driver. The exact command (the GUI's "
                "Generate preview — from this checkout; on the device the driver is "
                "/usr/sbin/hugmesh-go-live):",
                "  " + d.command_string("plan", self.opts),
                "On the device, the terminal menu hugmesh-go-live-menu runs it too. "
                "The flip (commit) runs only on a real TTY there, by design."]
        commands = ["b=back to the domain", "Enter=back to the providers"]
        cands = self.export_candidates(j)
        if export_step_applies(cands):
            commands.append(f"x=export to a GitHub org ({len(cands)} domain"
                            f"{'s' if len(cands) != 1 else ''} name one)")
        out += ["", "commands: " + " · ".join(commands)]
        return out

    def _feed_plan(self, j, line: str) -> None:
        if line.lower() == "b":
            self.stage = "domain"
            return
        if line == "":
            self.stage = "provider"
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
        out += ["", "commands: NUMBER=pick · c FILE=add a config file · r FILE|-=rename "
                "map (exclude a refused file, extra rules) · v private|public|"
                "internal=visibility · u refuse|branch=existing repositories · p=plan "
                "(dry run) · apply ORG=apply (type the org name) · b=back"]
        return out

    def _feed_export(self, j, line: str) -> None:
        cands = self.export_candidates(j)
        if line.lower() == "b":
            self.stage = "plan"
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
