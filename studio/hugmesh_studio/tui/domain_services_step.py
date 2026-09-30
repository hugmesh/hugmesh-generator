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
(``gui/pages/domains.py`` has said so since #227). Since #497 the screen does not merely
SAY so — it prints them, read-only, with the scope they really have, where each one IS
set and what it is doing right now, plus a legend naming all three scopes. Both halves
of that issue: reachable from the same flow, and visibly not domain-scoped.

HONESTY: the selection does not yet reach the cluster — issue #496. The screen prints
``ENFORCEMENT_NOTE``, the same words the GUI page shows, because a required step that
implies otherwise is worse than the menu it replaced.

THE MESH'S OWN DOMAIN GETS A PAGE TOO (#494; #589, operator decision 69 = A). The walk
is ``core.domain_services.domain_names_for_services`` — the GUI page's list — so on a
mesh flow it opens with the cluster domain (``implicit_own_domain``) even on the default
"just this mesh's own domain" path, and its selection lands on
``cfg.cluster_domain_services`` (never a ``cfg.domains`` row, so the ASK-8 guard holds),
exactly where the GUI page writes it. Whether the step is walked at all is core's
``services_page_applies`` — the GUI page's ``applies_to`` — so the faces cannot differ.

ONE SCREEN, TWO HOSTS (#494, decision 71 = A): ``cfg_of`` picks the object walked — the
journey's ImageConfig on the image flow, or the local-mesh route's
``core.local_mesh_domains.LocalMeshDomains`` (``tui/localmesh.py``) — and
``on_continue`` / ``on_back`` let a host that is not a positional journey step decide
where Enter and ``b`` go. Same catalogue, same recording, same gate.
"""
from __future__ import annotations

from ..core.domain_services import (
    DOMAIN_CATALOGUE, ENFORCEMENT_NOTE, OTHER_SCOPE_HEADERS, SCOPE_BINDS,
    SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_LABELS, SCOPE_NODE, SCOPE_WHERE,
    carried_over_slugs, describe, describe_carried_over, domain_names_for_services,
    implicit_own_domain, normalise_slugs, other_scope_rows, record_reviewed,
    reviewed_names,
)
from . import model

__all__ = ["DomainServicesScreen", "service_table", "other_scope_table",
           "scope_legend"]


class _OwnDomainView:
    """The mesh's IMPLICIT own domain as a row-shaped object: ``name`` is the cluster
    domain and ``optional_services`` reads and writes ``cfg.cluster_domain_services``
    — the field the GUI page records it into — so every function below that takes a
    domain row works on it unchanged."""

    def __init__(self, cfg, name: str):
        self._cfg = cfg
        self.name = name

    @property
    def optional_services(self) -> list[str]:
        return list(getattr(self._cfg, "cluster_domain_services", None) or [])

    @optional_services.setter
    def optional_services(self, value) -> None:
        self._cfg.cluster_domain_services = list(value or [])


def _named(cfg) -> list:
    """Every domain the walk visits, in the GUI page's order: the implicit own domain
    first (a view onto ``cluster_domain_services``), then the named table rows."""
    rows = {(getattr(d, "name", "") or "").strip(): d
            for d in (getattr(cfg, "domains", None) or [])}
    own = implicit_own_domain(cfg)
    out = []
    for name in domain_names_for_services(cfg):
        if name == own and name not in rows:
            out.append(_OwnDomainView(cfg, name))
        elif name in rows:
            out.append(rows[name])
    return out


def _own_name(cfg) -> str:
    """The domain the header calls "this mesh's own domain": the implicit one on an
    ImageConfig, row 0 of a LocalMeshDomains (``own_name``)."""
    return implicit_own_domain(cfg) or (getattr(cfg, "own_name", "") or "").strip()


def service_table(domain) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for one domain's service list — the offered catalogue plus any
    carried-over slug, each with whether it is on, WHAT IT BINDS (#497) and what it
    does. Every row here is domain-scoped by construction; the column exists so the
    read-only table below reads as "and these are not"."""
    chosen = set(normalise_slugs(getattr(domain, "optional_services", None)))
    offered = list(DOMAIN_CATALOGUE) + carried_over_slugs(
        getattr(domain, "optional_services", None))
    rows = []
    for i, slug in enumerate(offered, 1):
        note = (describe(slug) if slug in DOMAIN_CATALOGUE
                else describe_carried_over(slug))
        rows.append([str(i), "on" if slug in chosen else "-", slug,
                     SCOPE_LABELS[SCOPE_DOMAIN], note])
    return (["#", "on", "service", "scope", "what it does for this domain"], rows)


def other_scope_table(cfg, entries=()) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for the choices this step SHOWS but does not own (#497) — the
    GUI page's read-only table, same data, same source."""
    return (list(OTHER_SCOPE_HEADERS),
            [[slug, SCOPE_LABELS[scope], where, state or "off"]
             for slug, scope, where, state in other_scope_rows(cfg, entries)])


def scope_legend() -> list[str]:
    """One line per scope: where it is chosen, and what it binds. Built from core so a
    wording change cannot leave a stale sentence behind on either face."""
    return [f"{SCOPE_LABELS[k]}: set {SCOPE_WHERE[k]}, binds {SCOPE_BINDS[k]}"
            for k in (SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_NODE)]


class DomainServicesScreen:
    """One domain's services, one domain at a time (the GUI page's stepper)."""

    slug = "domain_services"
    title = "Domain services"

    def __init__(self, cfg_of=None, on_continue=None, on_back=None,
                 lane_note: str = ""):
        self.index = 0
        self._cfg_of = cfg_of
        self._on_continue = on_continue
        self._on_back = on_back
        #: one sentence on what THIS host's lane does with the selection (the local
        #: docker mesh: recorded, not what picks the compose profiles).
        self.lane_note = lane_note

    def cfg(self, j):
        """The object this walk reads and records onto (see the module doc)."""
        return self._cfg_of(j) if self._cfg_of else j.cfg

    def _continue(self, j) -> None:
        if self._on_continue:
            self._on_continue(j)
        else:
            j.advance()

    # ── the walk ────────────────────────────────────────────────────────────────
    def domains(self, j) -> list:
        return _named(self.cfg(j))

    def current(self, j):
        doms = self.domains(j)
        if not doms:
            return None
        self.index = max(0, min(len(doms) - 1, self.index))
        return doms[self.index]

    def enter(self, j) -> None:
        """Land on the first domain that still needs walking — the GUI page's rule."""
        doms = self.domains(j)
        done = reviewed_names(self.cfg(j))
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
        cfg = self.cfg(j)
        record_reviewed(cfg, reviewed_names(cfg) | {d.name})

    # ── rendering ───────────────────────────────────────────────────────────────
    def lines(self, j) -> list[str]:
        doms = self.domains(j)
        if not doms:
            return ["No domains to configure — this step has nothing to ask.",
                    "", "(Enter continues)"]
        d = self.current(j)
        cfg = self.cfg(j)
        done = reviewed_names(cfg)
        own = " (this mesh's own domain)" if d.name == _own_name(cfg) else ""
        out = [f"{d.name}{own} — domain {self.index + 1} of {len(doms)}",
               "The services THIS domain provides. They ride the mesh manifest as "
               "per-domain provisioning input; they do not change which services the "
               "image bakes.",
               "",
               ENFORCEMENT_NOTE,
               ""]
        if self.lane_note:
            out += [self.lane_note, ""]
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
                   "p=previous domain · "
                   + ("b=back · " if self._on_back else "") + "Enter=continue")
        out.append("")
        # #497: the choices this step SHOWS but does not own. Listed as DATA, never as
        # toggles — a per-DOMAIN choice for any of them would be a lie — so that the
        # operator does not have to hunt for where anubis is configured.
        out.append("NOT domain-scoped (shown, not offered — none of these binds one "
                   "domain):")
        # the mesh-wide state column reads an ImageConfig; a host walking something
        # else (the local docker mesh) has none, and the column reads "off".
        scope_cfg = cfg if self._cfg_of is None else None
        headers, rows = other_scope_table(scope_cfg, self._entries(j))
        out += model.format_table(headers, rows)
        out.append("")
        out += scope_legend()
        return out

    @staticmethod
    def _entries(j):
        """The worklist rows this journey carries, or () — the per-node half of the
        state column. A cloud walk has no worklist at all."""
        wl = getattr(j, "worklist", None)
        return list(getattr(wl, "entries", None) or ())

    def prompt(self, j) -> str:  # noqa: ARG002
        return "domain-services> "

    # ── input ───────────────────────────────────────────────────────────────────
    def feed(self, j, line: str) -> None:
        line = line.strip()
        if line == "":
            self._continue(j)
            return
        verb = line.lower()
        if verb == "b" and self._on_back:
            self._on_back(j)
            return
        doms = self.domains(j)
        if not doms:
            self._continue(j)
            return
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
