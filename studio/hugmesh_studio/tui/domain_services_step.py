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

ONE EXCEPTION, BY RULING (#582, decision 68 = A): above the services, right under the
domain line (the GUI page's order, #647 — the one-row front door is laid out before the
long catalogue so a short viewport cannot push it off screen), every domain but the
mesh's own has a ‘Tor front door’ row (command ``t``) — scope "onion (per domain)",
writing ``Domain.tor`` (never ``optional_services``) — and a one-line state saying which
login its onion serves, whether Tor runs on this mesh at all, and what THIS route does
with the choice (``core.domain_services.TOR_REACH`` — only the local docker mesh acts on
it today). Same row, same words and same field as the GUI page's front-door table.

THE SELECTION COLUMN IS CALLED WHAT THE GUI CALLS IT (#647): both tables head their
on/off column ``selection``, the GUI header's word (the operator's, PR #646) in this
face's lower case. ``SELECTION_HEADER`` is the one spelling here and
studio/tests/test_domain_services_selection_column.py pins it against the live page.

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
    SCOPE_DOMAIN, SCOPE_IMAGE, SCOPE_LABELS, SCOPE_NODE, SCOPE_ONION, SCOPE_WHERE,
    TOR_OWN_DOMAIN_NOTE, TOR_ROW_DESC, TOR_ROW_LABEL,
    carried_over_slugs, describe, describe_carried_over, domain_names_for_services,
    implicit_own_domain, normalise_slugs, other_scope_rows, record_reviewed,
    reviewed_names, tor_row_state,
)
from . import brand_step, model

__all__ = ["DomainServicesScreen", "service_table", "other_scope_table",
           "scope_legend", "front_door_table", "TOR_COMMAND", "SELECTION_HEADER"]

#: The header of the column that says whether a row is ticked — the GUI page's
#: "Selection" (``gui/pages/domain_services._HEADERS``), lower-cased like every other
#: header on this face. The GUI owns the word; a parity test keeps the two alike.
SELECTION_HEADER = "selection"


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
    offered = _offered(domain)
    rows = []
    for i, slug in enumerate(offered, 1):
        note = (describe(slug) if slug in DOMAIN_CATALOGUE
                else describe_carried_over(slug))
        rows.append([str(i), "on" if slug in chosen else "-", slug,
                     SCOPE_LABELS[SCOPE_DOMAIN], note])
    return (["#", SELECTION_HEADER, "service", "scope",
             "what it does for this domain"], rows)


#: The front door's command — a letter, never a number, so the service rows' numbers
#: (catalogue + carried-over slugs) never shift under it.
TOR_COMMAND = "t"


def front_door_table(domain, own: bool = False) -> tuple[list[str], list[list[str]]]:
    """(headers, rows) for the domain's FRONT DOOR (#582, decision 68 = A): its own Tor
    onion, the ONE infra slug with a per-domain spelling, scoped "onion (per domain)"
    and written to ``Domain.tor`` — never to ``optional_services``. The GUI page's own
    table, same row, same words. ``own`` = the mesh's own domain, whose front door is
    the primary onion: data, never a toggle (no command)."""
    if own:
        row = ["", "", TOR_ROW_LABEL, SCOPE_LABELS[SCOPE_ONION], TOR_OWN_DOMAIN_NOTE]
    else:
        row = [TOR_COMMAND, "on" if getattr(domain, "tor", False) else "-",
               TOR_ROW_LABEL, SCOPE_LABELS[SCOPE_ONION], TOR_ROW_DESC]
    return (["cmd", SELECTION_HEADER, "front door", "scope",
             "what it does for this domain"], [row])


def _offered(domain) -> list[str]:
    """The numbered SERVICE rows, in order."""
    return list(DOMAIN_CATALOGUE) + carried_over_slugs(
        getattr(domain, "optional_services", None))


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
            for k in (SCOPE_DOMAIN, SCOPE_ONION, SCOPE_IMAGE, SCOPE_NODE)]


class DomainServicesScreen:
    """One domain's services, one domain at a time (the GUI page's stepper)."""

    slug = "domain_services"
    title = "Domain services"

    def __init__(self, cfg_of=None, on_continue=None, on_back=None,
                 lane_note: str = "", brand_session_of=None, route: str = "image"):
        self.index = 0
        #: the Brand settings sections (#654, D9). ``brand_session_of(j)`` gives the
        #: superbrand session of this host, or None when the host has none: then the
        #: screen is exactly what it was. ``section`` is the numbered section on
        #: screen; Services (3) is the one the step opens on, so every command that
        #: worked before still does.
        self._brand_session_of = brand_session_of
        self.route = route
        self.section = brand_step.SECTION_SERVICES
        self._look_text = None
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
        # leaving the step is where the brand record is written (an untouched session
        # writes nothing): the section on screen may hold an uncommitted look first
        view = self._brand(j) if self.domains(j) else None
        if view is not None:
            if self.section == brand_step.SECTION_LOOK:
                view.commit_look()
            problems = view.session.commit(save=True)
            if problems:
                j.status = problems[0]
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
        self.section = brand_step.SECTION_SERVICES
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

    # ── the Brand settings sections (#654, D9) ───────────────────────────────────
    def _brand(self, j):
        """The BrandView of the domain on screen, or None when this host has no
        superbrand session (the screen is then exactly what it was)."""
        if self._brand_session_of is None:
            return None
        session = self._brand_session_of(j)
        d = self.current(j)
        if session is None or d is None:
            return None
        return brand_step.brand_view(session, d.name, own=d.name == _own_name(self.cfg(j)))

    def _section_lines(self, j, view) -> list[str]:
        """Sections 1, 2 and 4 as text (3 is the services screen below)."""
        n = self.section
        if n == 1:
            out = brand_step.identity_lines(view)
        elif n == brand_step.SECTION_LOOK:
            out = brand_step.look_section_lines(view, self.route)
            if self._look_editable(view):
                out = ["2. Look — " + view.label(), ""] + self._look(view).lines()
        else:
            out = brand_step.ways_lines(view)
        return out

    def _look_editable(self, view) -> bool:
        return (view.look_model() is not None
                and self.route in brand_step.brand_look.PATHS_WITH_OWN_LOOK)

    def _look(self, view):
        from .themes import LookText
        m = view.look_model()
        if self._look_text is None or self._look_text.model is not m:
            self._look_text = LookText(m, path=self.route)
        return self._look_text

    def _open_section(self, j, view, n: int) -> None:
        if n not in dict(brand_step.SECTIONS):
            j.status = f"no such section: {n} (1 to 4)"
            return
        if self.section == brand_step.SECTION_LOOK:
            view.commit_look()
        self.section = n
        self._look_text = None

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
        is_own = bool(own)
        out = [f"{d.name}{own} — domain {self.index + 1} of {len(doms)}", ""]
        view = self._brand(j)
        if view is not None:
            out += ["Brand settings: " + "   ".join(brand_step.section_menu(self.section)),
                    "  (type ‘open N’ to switch section; n and p move between brands)", ""]
            if self.section != brand_step.SECTION_SERVICES:
                out += self._section_lines(j, view)
                out += ["", "commands: open N=another section · n=next brand · "
                        "p=previous brand"
                        + (" · look commands as listed" if self.section == 2
                           and self._look_editable(view) else "")
                        + " · Enter=continue"]
                return out
        # The front door FIRST, right under the domain line — the GUI page's order
        # (its front-door table sits above the long services catalogue so a short
        # viewport cannot push it below the fold, #647), kept alike here by decision
        # 71 = A: same screen, same order, on both faces.
        headers, rows = front_door_table(d, own=is_own)
        out += model.format_table(headers, rows)
        # the front door's live state — which login its onion serves, whether Tor
        # runs on this mesh at all (unknowable on a host with no ImageConfig), and
        # what this route does with the choice.
        scope_cfg = cfg if self._cfg_of is None else None
        out.append(f"{TOR_ROW_LABEL}: "
                   + tor_row_state(d, scope_cfg, self._entries(j), _own_name(cfg),
                                   walked=cfg, domains=doms))
        out += ["", ENFORCEMENT_NOTE, ""]
        if self.lane_note:
            out += [self.lane_note, ""]
        out += ["The services THIS domain provides. They ride the mesh manifest as "
                "per-domain provisioning input; they do not change which services the "
                "image bakes.",
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
        out.append("commands: NUMBER=toggle that service · "
                   + ("" if is_own else f"{TOR_COMMAND}=toggle the Tor front door · ")
                   + "n=next domain · "
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
        view = self._brand(j)
        if view is not None:
            word, _, arg = verb.partition(" ")
            names = {"identity": 1, "look": 2, "services": 3, "ways": 4}
            if word == "open" and arg.strip().isdigit():
                self._open_section(j, view, int(arg))
                return
            if word in names and not arg:
                self._open_section(j, view, names[word])
                return
            if self.section == brand_step.SECTION_LOOK and verb not in ("n", "p"):
                if self._look_editable(view):
                    self._look(view).feed(line)
                    view.commit_look()
                else:
                    j.status = ("This brand's own look is shown on the Docker mesh "
                                "only; it is not editable on this route.")
                return
            if self.section != brand_step.SECTION_SERVICES and verb not in ("n", "p"):
                j.status = ("Nothing to change in this section here — see the line "
                            "under it for where it is changed.")
                return
        if verb in ("n", "p"):
            if view is not None and self.section == brand_step.SECTION_LOOK:
                view.commit_look()
            self.index = max(0, min(len(doms) - 1,
                                    self.index + (1 if verb == "n" else -1)))
            self.section = brand_step.SECTION_SERVICES
            self._look_text = None
            self._mark(j)
            return
        d = self.current(j)
        if verb == TOR_COMMAND:
            # the Tor front door (#582): Domain.tor, never optional_services. The
            # mesh's own domain has none to toggle — its front door is the primary
            # onion (the GUI page shows that row as data, too).
            if d.name == _own_name(self.cfg(j)):
                j.status = (f"{d.name} is this mesh's own domain — its front door is "
                            "the mesh's own onion; nothing to toggle")
                return
            d.tor = not bool(getattr(d, "tor", False))
            j.status = f"{d.name}: {TOR_ROW_LABEL} -> {'on' if d.tor else 'off'}"
            return
        offered = _offered(d)
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
