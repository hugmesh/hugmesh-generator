"""The domains of a GENERATED local Docker mesh — the Qt-free half (issue #494).

The operator's ask (2026-09-17): "a service page per domain you make you have to go
through before building or starting a mesh in docker or nodes". On the generate-a-new-
mesh route the Studio had ONE domain field (``boot_domain``, on the prod-only overlay
step) and no per-domain services at all, so the per-domain gate ``localmesh.py``
calls (``domain_services.gate_reason``) could never bite there: it reads
``wiz.cfg.domains``, a table that route never fills (reported 2026-09-23: "no gui
based multidomain config in the studio for the generate new mesh path").

This module is the state the two new local-mesh steps (Domains, Domain services)
write, kept OFF ``ImageConfig`` on purpose:

* the whole local-mesh branch "emits ZERO ImageConfig fields" (``wizard.py``
  ``_LOCALMESH_STEPS``), and ``test_the_choice_screen_commits_nothing_to_cfg`` pins
  it — a docker mesh is not an image, and every saved config and builder argv must
  stay ignorant of it;
* ``wiz.cfg.mode`` on this route is whatever IMAGE mode the operator last committed
  (the local-mesh card never sets it — ``ModePage.validatePage`` returns before
  ``cfg.mode = mid``), and ``ImageConfig()``'s default is ``standalone``, for which
  ``domain_services.gate_applies`` is False. Writing the rows into ``wiz.cfg`` would
  therefore leave the gate a no-op on exactly the route it is meant to guard.

So :class:`LocalMeshDomains` is a small stand-in shaped so the ONE gate seam,
``domain_services.gate_reason``, reads it through the same ``getattr`` calls it uses
on an ``ImageConfig``: ``mode``, ``domains``, ``domain_services_reviewed``. Its
``mode`` is the class constant ``"mesh"`` because that is the gate's real question
("do these domains reach anything?") and on a local mesh they do: a row with
sign-in=own stands up its own Casdoor (``core/own_casdoor.py``).

What the rows turn into on the bring-up (``LocalMeshBootstrapConfig``):

* ``own_idp_domains`` — the names whose sign-in is ``own`` (already consumed by
  ``LocalStackNode`` / the compose overlay; the GUI just never sent them);
* ``domains`` — the rows RECORDED with the mesh (:func:`bootstrap_domain_records`),
  omitting the mesh's own domain while it is default-shaped, so an untouched flow
  keeps the empty tuple it always had (emission neutrality, pinned by test).

The per-domain optional services are recorded and NOT enforced on this lane: the
compose profiles come from the mesh-wide Services step (``services=``), exactly as
the cluster lane's #496 note says for ArgoCD. The page says so in one sentence.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import ClassVar

from .config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain
from .domain_services import normalise_slugs

__all__ = ["LocalMeshDomains", "bootstrap_domain_records", "own_idp_names",
           "added_row_problems", "domains_from_bootstrap", "reviewed_record_names",
           "record_walk",
           "DOMAIN_NAME_RE", "LOCAL_MESH_REMEDY", "SAVED_MESH_REMEDY"]

#: A domain row's name: a lowercase dotted hostname (the TUI Domains steps' shape).
DOMAIN_NAME_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")

#: The remedy the local-mesh gate refusal carries. ``domain_services.ACTION_REMEDY``'s
#: sentence for ACTION_MESH_START points at the IMAGE flow's step, which is the wrong
#: route here — this route has its own two steps, and the refusal must name them.
LOCAL_MESH_REMEDY = (
    "Go back to the ‘Domains’ and ‘Domain services’ steps of this local-mesh setup "
    "— every domain there has its own service page, and opening it is what records "
    "it — or remove the domain from the Domains table.")


#: The remedy a SAVED-mesh Start/Restore refusal carries: the record's rows are what
#: is gated, and the form is where a domain is walked — so the way out is to load the
#: record into the form, walk the named domains, and start the record again.
SAVED_MESH_REMEDY = (
    "Load this saved mesh into the form (Saved meshes → ‘Load into the form’), go "
    "through the ‘Domain services’ step for the domains named, then Start it again.")


@dataclass
class LocalMeshDomains:
    """The domain rows of a generated local mesh plus the gate's bookkeeping.

    Empty until the Domains step is first visited: the step seeds the mesh's own
    domain on that visit, never the controller's constructor, so a host with no
    steps (``LocalMeshDialog``) and a saved-mesh Start on a flow that never opened
    the step keep passing the gate exactly as they did before this existed."""
    #: ``domain_services.gate_applies`` reads it: the domains of a local mesh reach
    #: the compose lane (own Casdoors), so the gate must be able to bite.
    mode: ClassVar[str] = "mesh"
    domains: list[Domain] = field(default_factory=list)
    domain_services_reviewed: list[str] = field(default_factory=list)
    #: The name of row 0 — the mesh's own domain — once the Domains step seeded it
    #: ("" before). A REAL row here (unlike ImageConfig's implicit own domain): the
    #: services stepper walks it like any other, and ``bootstrap_domain_records``
    #: is what keeps it out of the record while it is default-shaped.
    own_name: str = ""

    def names(self) -> list[str]:
        return [(d.name or "").strip() for d in self.domains if (d.name or "").strip()]

    def by_name(self, name: str) -> Domain | None:
        name = (name or "").strip()
        for d in self.domains:
            if (d.name or "").strip() == name:
                return d
        return None


def own_idp_names(domains) -> tuple[str, ...]:
    """The names whose sign-in is ``own``, in table order, DUPLICATES COLLAPSED to
    the first occurrence — what ``LocalMeshBootstrapConfig.own_idp_domains`` (and so
    the compose overlay's port sequence) is derived from. The collapse is the CLI's
    ``_parse_own_casdoor_domains`` rule: own_casdoor emits one compose service per
    name, so a repeated name would otherwise emit the same service key twice."""
    out: list[str] = []
    for d in domains:
        name = (d.name or "").strip()
        if name and getattr(d, "idp", "") == DOMAIN_IDP_OWN and name not in out:
            out.append(name)
    return tuple(out)


def added_row_problems(names, own_name: str) -> list[str]:
    """Why the ADDED domain rows ``names`` (table order, row 0 — the own domain —
    excluded) cannot be recorded; [] when they can.

    The TUI's Domains step refuses the same three cases at entry time with the same
    words ("not a domain name", "already listed"); the GUI table accepts free text,
    so its step refuses on Next with these instead (inline, never a modal). A blank
    row is not a problem — it is ignored, as it always was."""
    own = (own_name or "").strip()
    problems: list[str] = []
    seen: set[str] = set()
    for raw in names:
        name = (raw or "").strip()
        if not name:
            continue
        if not DOMAIN_NAME_RE.match(name):
            problems.append(f"not a domain name: {name!r} (lowercase dotted "
                            "hostname, e.g. chat.example.org)")
        elif own and name == own:
            problems.append(f"{name} is this mesh's own domain (row 0) — it is "
                            "already listed and cannot be added again")
        elif name in seen:
            problems.append(f"already listed: {name}")
        seen.add(name)
    return problems


def _default_shaped(d: Domain) -> bool:
    return (not (d.title or "").strip()
            and getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN) == DOMAIN_IDP_SUPERDOMAIN
            and not normalise_slugs(d.optional_services)
            and not getattr(d, "tor", False))


def bootstrap_domain_records(domains, own_name: str) -> tuple[dict, ...]:
    """The rows to RECORD on the bootstrap config, JSON-shaped.

    Every added domain always; the mesh's OWN domain (``own_name`` — the resolved
    cluster domain) only when it says something the rest of the config does not
    already carry (a title, an own sign-in, a per-domain selection). A flow that never
    touched the new steps therefore records ``()`` — byte-identical to a config from
    before the field existed."""
    own = (own_name or "").strip()
    out: list[dict] = []
    for d in domains:
        name = (d.name or "").strip()
        if not name:
            continue
        if name == own and _default_shaped(d):
            continue
        rec = {"name": name, "title": (d.title or "").strip(),
               "idp": getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN)
               or DOMAIN_IDP_SUPERDOMAIN,
               "optional_services": normalise_slugs(d.optional_services)}
        # the domain's own Tor front door (#582): OMIT-WHEN-FALSE, so every record
        # without one keeps its bytes. Unlike optional_services this one RUNS on the
        # compose lane — LocalStackNode threads it as TOR_ONION_DOMAINS when TOR=1.
        if getattr(d, "tor", False) and name != own:
            rec["tor"] = True
        out.append(rec)
    return tuple(out)


def reviewed_record_names(md: "LocalMeshDomains", records) -> tuple[str, ...]:
    """The reviewed markers to RECORD with ``records`` (``bootstrap_domain_records``
    output): exactly the recorded names that have been through the Domain services
    step, in record order. Never a name that is not recorded, so a flow whose
    recorded rows are () records () here too (emission neutrality)."""
    done = set(md.domain_services_reviewed)
    return tuple(r["name"] for r in records if r.get("name") in done)


def domains_from_bootstrap(cfg) -> "LocalMeshDomains | None":
    """The domain state a ``LocalMeshBootstrapConfig`` (a saved-mesh record) carries,
    or None when it carries none (a pre-#494 record: no ``domains``, no
    ``own_idp_domains``).

    Row 0 is the record's own domain (``cluster_domain`` or the brand default); then
    every recorded row, then every own-IdP name without a row (a CLI-made record
    carries those alone). REVIEWED = the record's own ``domain_services_reviewed``
    markers — never "every row in the record" (PR #595 skeptics: that let a CLI-made
    record's own-IdP domains start without any services page) — plus the own domain
    when the record does not list it as a row (it is then the implicit cluster
    default, which no saved start has ever asked about)."""
    rec_rows = [r for r in (getattr(cfg, "domains", None) or ())
                if (r.get("name") or "").strip()]
    idp_names = [n.strip() for n in (getattr(cfg, "own_idp_domains", None) or ())
                 if n.strip()]
    if not rec_rows and not idp_names:
        return None
    own = (cfg.cluster_domain or "").strip() or cfg.resolved_domain()
    rows: list[Domain] = [Domain(name=own, title="")]
    for rec in rec_rows:
        name = rec["name"].strip()
        row = next((r for r in rows if r.name == name), None)
        if row is None:
            row = Domain(name=name)
            rows.append(row)
        row.title = (rec.get("title") or "").strip()
        row.idp = rec.get("idp") or DOMAIN_IDP_SUPERDOMAIN
        row.optional_services = list(rec.get("optional_services") or [])
        row.tor = rec.get("tor") is True and name != own
    for name in idp_names:
        row = next((r for r in rows if r.name == name), None)
        if row is None:
            row = Domain(name=name)
            rows.append(row)
        if name != own:
            row.idp = DOMAIN_IDP_OWN
    rows[0].idp = DOMAIN_IDP_SUPERDOMAIN
    recorded = {r["name"].strip() for r in rec_rows}
    marks = set(getattr(cfg, "domain_services_reviewed", None) or ())
    reviewed = [r.name for r in rows
                if r.name in marks or (r.name == own and own not in recorded)]
    return LocalMeshDomains(domains=rows, domain_services_reviewed=reviewed,
                            own_name=own)


def record_walk(cfg, md: "LocalMeshDomains", names) -> None:
    """Write the Domain services walk of ``names`` — done in the FORM while it held
    a saved mesh — INTO that mesh's bootstrap config ``cfg`` (in place).

    The saved-mesh refusal's remedy is "load it, walk the named domains, Start it
    again"; the walk lives in the form, and the next Start re-applies the RECORD to
    the form (``_apply_domains``), so a walk that is not written into the record
    counts for exactly one Start (PR #595 robustness skeptic, round 2). So, for each
    name: its reviewed marker is appended, and its per-domain selection (the ticks
    the walk recorded) is written onto its recorded row — a new row for a name the
    record carried only as an own-IdP name (a CLI-made record), with sign-in
    ``own`` exactly as ``domains_from_bootstrap`` read it.

    Nothing that RUNS changes: ``own_idp_domains``, ``cluster_domain`` and every
    other field are untouched, and a recorded row's title and sign-in stay the
    record's — only the record-only fields (``domains[].optional_services``,
    ``domain_services_reviewed``) grow."""
    rows = [dict(r) for r in (getattr(cfg, "domains", None) or ())]
    by_name = {(r.get("name") or "").strip(): r for r in rows}
    own_idp = {n.strip() for n in (getattr(cfg, "own_idp_domains", None) or ())}
    marks = list(getattr(cfg, "domain_services_reviewed", None) or ())
    for raw in names:
        name = (raw or "").strip()
        if not name:
            continue
        form_row = md.by_name(name)
        picked = normalise_slugs(form_row.optional_services) if form_row else []
        # the walk's Tor front door (#582) travels with its ticks; OMIT-WHEN-FALSE.
        tor = bool(form_row is not None and getattr(form_row, "tor", False)
                   and name != (md.own_name or "").strip())
        row = by_name.get(name)
        if row is None:
            row = {"name": name,
                   "title": (form_row.title or "").strip() if form_row else "",
                   "idp": DOMAIN_IDP_OWN if name in own_idp else DOMAIN_IDP_SUPERDOMAIN,
                   "optional_services": picked}
            rows.append(row)
            by_name[name] = row
        else:
            row["optional_services"] = picked
        if tor:
            row["tor"] = True
        else:
            row.pop("tor", None)
        if name not in marks:
            marks.append(name)
    cfg.domains = tuple(rows)
    cfg.domain_services_reviewed = tuple(marks)
