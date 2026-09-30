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

from ..core.golive_domains import (NO_EXTRA_DOMAINS_NOTE, baked_domains,
                                   exposure_lines, plan_rows)
from ..core.golive_driver import GoLiveDriver, GoLiveOptions, _NO_DOMAIN_MECHANISMS

__all__ = ["GoLiveScreen"]


class GoLiveScreen:
    """``provider`` -> ``domain`` -> ``plan``."""

    slug = "golive"
    title = "Go-Live"
    wants_q = False

    def __init__(self):
        self.stage = "provider"
        self.driver: GoLiveDriver | None = None
        self.opts = GoLiveOptions()

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
                          "commands: q=quit"]
        for i, p in enumerate(providers, 1):
            out.append(f"  {i}. {p.id} — {p.model} ({p.mechanism}) — {p.title}")
        out += ["", "commands: NUMBER=pick"]
        return out

    def _feed_provider(self, j, line: str) -> None:
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
                "The flip (commit) runs only on a real TTY there, by design.",
                "", "commands: b=back to the domain · Enter=back to the providers"]
        return out

    def _feed_plan(self, j, line: str) -> None:
        if line.lower() == "b":
            self.stage = "domain"
            return
        if line == "":
            self.stage = "provider"
            return
        j.status = f"unrecognised command: {line!r}"
