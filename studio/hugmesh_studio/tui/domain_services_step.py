"""The Domain services step — the TUI twin of ``gui/pages/domain_services.py`` (#495).

One domain at a time, exactly as the GUI page walks them: the catalogue is
``core.domain_services.DOMAIN_CATALOGUE`` (what ``--all-services`` expands to, the only
slugs whose descriptions are ``<domain>``-scoped), plus any slug a loaded config carries
that this build's catalogue does not offer — kept, listed and pre-ticked so an older
worklist never silently loses manifest data.

REAL, not a stub, deliberately. A ``PendingStep`` here ("configure this in the GUI")
would leave every domain unconfigured, and the build/mesh-start gate refuses on exactly
that — so the TUI would have had a step it could walk but never satisfy. The whole
point of the parity lane is that both faces drive the same objects: this screen records
through ``core.domain_services.record_reviewed``, the same function the GUI page calls,
so a config walked here and one walked there gate identically.

The infra slugs (tor, egress-vpn, workloadConsole, anubis) are NOT offered: they are
node/cluster-plane scoped and a per-DOMAIN checkbox for them would be a new lie
(``gui/pages/domains.py`` has said so since #227). The screen names that rather than
leaving the operator to wonder where anubis went.

HONESTY: the selection does not yet reach the cluster — issue #496. The screen prints
``ENFORCEMENT_NOTE``, the same words the GUI page shows, because a required step that
implies otherwise is worse than the menu it replaced.
"""
from __future__ import annotations

from ..core.domain_services import (
    DOMAIN_CATALOGUE, ENFORCEMENT_NOTE, carried_over_slugs, describe,
    describe_carried_over,
    normalise_slugs, record_reviewed, reviewed_names,
)
from . import model

__all__ = ["DomainServicesScreen", "service_table"]


def _named(cfg) -> list:
    return [d for d in (getattr(cfg, "domains", None) or [])
            if (getattr(d, "name", "") or "").strip()]


def service_table(domain) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for one domain's service list — the offered catalogue plus any
    carried-over slug, each with whether it is on and what it does."""
    chosen = set(normalise_slugs(getattr(domain, "optional_services", None)))
    offered = list(DOMAIN_CATALOGUE) + carried_over_slugs(
        getattr(domain, "optional_services", None))
    rows = []
    for i, slug in enumerate(offered, 1):
        note = (describe(slug) if slug in DOMAIN_CATALOGUE
                else describe_carried_over(slug))
        rows.append([str(i), "on" if slug in chosen else "-", slug, note])
    return ["#", "on", "service", "what it does for this domain"], rows


class DomainServicesScreen:
    """One domain's services, one domain at a time (the GUI page's stepper)."""

    slug = "domain_services"
    title = "Domain services"

    def __init__(self):
        self.index = 0

    # ── the walk ────────────────────────────────────────────────────────────────
    def domains(self, j) -> list:
        return _named(j.cfg)

    def current(self, j):
        doms = self.domains(j)
        if not doms:
            return None
        self.index = max(0, min(len(doms) - 1, self.index))
        return doms[self.index]

    def enter(self, j) -> None:
        """Land on the first domain that still needs walking — the GUI page's rule."""
        doms = self.domains(j)
        done = reviewed_names(j.cfg)
        pending = [i for i, d in enumerate(doms) if d.name not in done]
        self.index = pending[0] if pending else 0
        self._mark(j)

    def _mark(self, j) -> None:
        """Being on a domain's screen IS going through it (the GUI page's rule, and the
        same function records it), so the two faces cannot disagree about what the gate
        will accept."""
        d = self.current(j)
        if d is None:
            return
        record_reviewed(j.cfg, reviewed_names(j.cfg) | {d.name})

    # ── rendering ───────────────────────────────────────────────────────────────
    def lines(self, j) -> list[str]:
        doms = self.domains(j)
        if not doms:
            return ["No domains to configure — this step has nothing to ask.",
                    "", "(Enter continues)"]
        d = self.current(j)
        done = reviewed_names(j.cfg)
        out = [f"{d.name} — domain {self.index + 1} of {len(doms)}",
               "The services THIS domain provides. They ride the mesh manifest as "
               "per-domain provisioning input; they do not change which services the "
               "image bakes.",
               "",
               ENFORCEMENT_NOTE,
               ""]
        headers, rows = service_table(d)
        out += model.format_table(headers, rows)
        out.append("")
        left = [x.name for x in doms if x.name not in done]
        if left:
            out.append(f"{len(doms) - len(left)} of {len(doms)} domains configured. "
                       "Still to go: " + ", ".join(left)
                       + " — an image build or a docker mesh start refuses while any "
                         "domain is unconfigured, and names it.")
        else:
            out.append(f"All {len(doms)} domain"
                       f"{'s' if len(doms) != 1 else ''} configured.")
        out.append("commands: NUMBER=toggle that service · n=next domain · "
                   "p=previous domain · Enter=continue")
        out.append("tor / egress-vpn / workloadConsole / anubis are NOT here on "
                   "purpose: they are node- or cluster-plane scoped, so a per-domain "
                   "choice for them would be a lie. They live on the services step "
                   "and the worklist's per-node Services column.")
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "domain-services> "

    # ── input ───────────────────────────────────────────────────────────────────
    def feed(self, j, line: str) -> None:
        line = line.strip()
        if line == "":
            j.advance()
            return
        doms = self.domains(j)
        if not doms:
            j.advance()
            return
        verb = line.lower()
        if verb in ("n", "p"):
            self.index = max(0, min(len(doms) - 1,
                                    self.index + (1 if verb == "n" else -1)))
            self._mark(j)
            return
        d = self.current(j)
        offered = list(DOMAIN_CATALOGUE) + carried_over_slugs(d.optional_services)
        try:
            n = int(line)
        except ValueError:
            j.status = f"unrecognised command: {line!r}"
            return
        if not 1 <= n <= len(offered):
            j.status = f"no such service row: {line!r}"
            return
        slug = offered[n - 1]
        chosen = set(normalise_slugs(d.optional_services))
        if slug in chosen:
            chosen.discard(slug)
        else:
            chosen.add(slug)
        # CATALOGUE order, never the order they were ticked in: the manifest key must
        # be byte-stable across a load/save round trip (core/domain_services).
        d.optional_services = normalise_slugs(chosen)
        j.status = f"{d.name}: {slug} -> {'on' if slug in chosen else 'off'}"
