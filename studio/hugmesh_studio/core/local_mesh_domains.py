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

from .config import (DOMAIN_IDP_CHOICES, DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain,
                     domain_from_record_row, domain_rows_to_dict)
from .domain_services import normalise_slugs, record_reviewed, reviewed_names

__all__ = ["LocalMeshDomains", "bootstrap_domain_records", "own_idp_names",
           "added_row_problems", "domains_from_bootstrap", "reviewed_record_names",
           "record_walk", "imported_mesh_domains", "apply_imported_domains",
           "imported_domains_lines",
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
        if not DOMAIN_NAME_RE.fullmatch(name):
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
    """Whether the mesh's OWN row says nothing the config does not already carry.
    Asked only about the own row, whose front door is the mesh's primary onion — so a
    ``tor`` flag on it (a hand-made object; no page sets one) is not a front door and
    does not make the row worth recording (``bootstrap_domain_records`` would not
    write it anyway)."""
    return (not (d.title or "").strip()
            and getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN) == DOMAIN_IDP_SUPERDOMAIN
            and not normalise_slugs(d.optional_services)
            # an export org on the own row IS something to record: the Go-Live
            # export step reads it off the saved-mesh record
            and not (getattr(d, "github_org", "") or "").strip())


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
        # COPY SITE (brand_model.COPY_SITES): the row's saved shape comes from the
        # field list, so a Domain field added later is recorded here without a change
        # (#654); only the values this route normalises are touched.
        rec = domain_rows_to_dict([d])[0]
        rec["name"] = name
        rec["title"] = (d.title or "").strip()
        rec["idp"] = getattr(d, "idp", DOMAIN_IDP_SUPERDOMAIN) or DOMAIN_IDP_SUPERDOMAIN
        rec["optional_services"] = normalise_slugs(d.optional_services)
        # a docker mesh builds no image, so an empty worklist-entry list says nothing
        # here and is left out (the pre-#654 record never carried the key)
        if not rec.get("images"):
            rec.pop("images", None)
        # the domain's own Tor front door (#582): OMIT-WHEN-FALSE, so every record
        # without one keeps its bytes. Unlike optional_services this one RUNS on the
        # local docker mesh — LocalStackNode passes it as TOR_ONION_DOMAINS when TOR=1.
        # The mesh's own row never has one: its front door is the primary onion.
        if name == own:
            rec.pop("tor", None)
        # the GitHub org this domain exports to (the Go-Live export step) travels by the
        # field list too, OMIT-WHEN-EMPTY, and is recorded for the own row as well: the
        # mesh's own domain is the one most worth exporting
        if "github_org" in rec:
            rec["github_org"] = str(rec["github_org"]).strip()
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
        # COPY SITE (brand_model.COPY_SITES): rebuild the row through the ONE lenient
        # loader (every field by the field list; a junk sign-in kept as text for
        # _import_problem to name), so a field the record carries is never left at
        # its default here (#654); then apply this route's own-row rules.
        loaded = domain_from_record_row(dict(rec, name=name))
        row = next((r for r in rows if r.name == name), None)
        if row is None:
            row = loaded
            rows.append(row)
        else:
            for k in Domain.__dataclass_fields__:
                if k != "name":
                    setattr(row, k, getattr(loaded, k))
        row.title = (rec.get("title") or "").strip()
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
        # the export org travels with the walk the same way (OMIT-WHEN-EMPTY)
        org = ((getattr(form_row, "github_org", "") or "").strip()
               if form_row is not None else "")
        row = by_name.get(name)
        if row is None:
            # COPY SITE (brand_model.COPY_SITES): a new row starts from the form row's
            # full saved shape (every field, #654), not a hand-listed subset; the
            # sign-in is what the record said (own-IdP name), as domains_from_bootstrap
            # read it.
            row = domain_rows_to_dict([form_row])[0] if form_row else {}
            row["name"] = name
            row["title"] = (form_row.title or "").strip() if form_row else ""
            row["idp"] = DOMAIN_IDP_OWN if name in own_idp else DOMAIN_IDP_SUPERDOMAIN
            row["optional_services"] = picked
            rows.append(row)
            by_name[name] = row
        else:
            row["optional_services"] = picked
        if tor:
            row["tor"] = True
        else:
            row.pop("tor", None)
        if org:
            row["github_org"] = org
        else:
            row.pop("github_org", None)
        if name not in marks:
            marks.append(name)
    cfg.domains = tuple(rows)
    cfg.domain_services_reviewed = tuple(marks)


# ── the saved mesh -> node images import (#636) ──────────────────────────────────────
def imported_mesh_domains(boot_cfg) -> "LocalMeshDomains | None":
    """The domain rows a saved local mesh (``boot_cfg``, its
    ``LocalMeshBootstrapConfig``) hands to "Create nodes for local cloud", or None when
    it carries none (a pre-#494 record, or a one-domain mesh: nothing to import, and the
    import stays exactly what it was before #636).

    ``domains_from_bootstrap`` with ONE difference: its reviewed list also marks the
    record's own domain when the record does not list it as a row — a leniency for
    STARTING that saved mesh ("the implicit cluster default, which no saved start has
    ever asked about"). An IMPORT must not turn that into a walk nobody made, so here the
    markers are only the record's own ``domain_services_reviewed``."""
    md = domains_from_bootstrap(boot_cfg)
    if md is None:
        return None
    marks = {str(n).strip()
             for n in (getattr(boot_cfg, "domain_services_reviewed", None) or ())}
    md.domain_services_reviewed = [n for n in md.names() if n in marks]
    return md


def _import_problem(row) -> str:
    """Why a saved ADDED row cannot become a domain row of the node-image flow; "" when
    it can. ONE rule for the import and for the summary that promises it, so the page
    never lists a domain the images will not carry (and the other way round).

    A sign-in the configuration does not know is refused rather than read as the
    default: ``config._domain_from_dict`` fails loudly on one at load time ("never
    silently coerced into either real choice"), and quietly handing a domain the
    central sign-in when the record said something else would be an identity-provider
    change nobody asked for. Only a hand-edited record can carry either problem — the
    local-mesh Domains step refuses both when the row is typed."""
    name = (getattr(row, "name", "") or "").strip()
    if not DOMAIN_NAME_RE.fullmatch(name):
        return "not a domain name"
    idp = getattr(row, "idp", "") or DOMAIN_IDP_SUPERDOMAIN
    if idp not in DOMAIN_IDP_CHOICES:
        return f"sign-in {idp!r} is not one of {', '.join(DOMAIN_IDP_CHOICES)}"
    return ""


def apply_imported_domains(cfg, md: "LocalMeshDomains | None") -> list[str]:
    """Write a saved local mesh's domains (``md`` — :func:`imported_mesh_domains`) onto
    the node-image flow's ImageConfig ``cfg``, in place; returns the ADDED rows' names
    in record order. Called ONCE per import (the localcloud gate's one-shot latch in the
    GUI, ``apply_gate`` in the TUI), AFTER ``cfg.cluster_domain`` is set to the mesh's.

    Before #636 the import carried the apex only, so a local mesh generated with N
    domains lost every other row — its title, its Sign-in = Own choice and its
    per-domain services — on the way into the node images that are meant to JOIN it.

    THE RECORD IS AUTHORITATIVE. The node images join THIS mesh, so its recorded
    domain set is the whole answer: ``cfg.domains`` is REPLACED (a new list) by the
    record's added rows, never merged with what an earlier flow of the same Studio
    session left in ``cfg`` (the post-merge review of PR #644 found such a row — one
    hand-added on a plain "Mesh node" walk — built into the local cloud's images, and
    a re-import after the mesh gained a domain keeping the first import's rows).

    * The OWN domain (the row named ``cfg.cluster_domain``) is NOT a table row: the
      image flow's own domain is IMPLICIT (``domain_services.implicit_own_domain``), and a
      row named after it would turn that off. Its per-domain selection goes to
      ``cfg.cluster_domain_services``, written only when the record SAYS something (a
      selection, or a reviewed "cluster default") — never invented, and an earlier pick
      of the operator's is kept when the record is silent (the walk ahead shows it as
      unconfirmed and the build gate asks for it).
    * Every ADDED row lands in ``cfg.domains`` with the record's title, sign-in,
      services and Tor front door (#582: the image flow would otherwise drop the front
      door the local mesh was run with), and ``cfg.additional_domains`` turns on —
      otherwise the "Just this mesh's own domain" card, preselected from that flag,
      would clear the rows on the next page. A record row the configuration cannot
      hold — a name that is not a lowercase dotted hostname, or a sign-in it does not
      know (``_import_problem``) — is not imported, and the summary
      (``imported_domains_lines``) says so by name.
    * REVIEWED markers: an imported name is reviewed exactly when the RECORD says it was
      walked. ``record_reviewed`` rebuilds the list from the rows that now exist, so no
      marker survives for a row the import dropped; the own domain's marker is the
      record's too (it is asked about, on the walk ahead, exactly when the record did
      not answer for it).

    None (nothing recorded: a pre-#494 record, or a one-domain mesh) means the mesh
    serves its own domain only — so the rows and the opt-in are cleared as well, for
    the same reason: a row from an earlier flow is not one of this mesh's domains. A
    fresh flow has none to clear, so its emission stays what it was."""
    own = (getattr(cfg, "cluster_domain", "") or "").strip()
    marks = {str(n).strip() for n in (md.domain_services_reviewed if md else ())}
    rows: list[Domain] = []
    seen: set[str] = set()
    own_reviewed = False
    for row in (md.domains if md is not None else ()):
        name = (row.name or "").strip()
        if not name or name in seen:
            continue
        seen.add(name)
        picked = normalise_slugs(row.optional_services)
        if name == own:
            if picked or name in marks:
                cfg.cluster_domain_services = list(picked)
            own_reviewed = name in marks
            continue
        if _import_problem(row):
            continue                        # imported_domains_lines says so, by name
        # COPY SITE (brand_model.COPY_SITES): the image row is the saved row's full
        # shape re-loaded (#654) — the title, sign-in, services and Tor front door as
        # before, and every later field with them.
        dom = domain_from_record_row(domain_rows_to_dict([row])[0])
        dom.name = name
        dom.title = (row.title or "").strip()
        dom.idp = getattr(row, "idp", "") or DOMAIN_IDP_SUPERDOMAIN
        dom.optional_services = list(picked)
        dom.tor = bool(getattr(row, "tor", False))
        dom.github_org = (getattr(row, "github_org", "") or "").strip()
        rows.append(dom)
    cfg.domains = rows                      # replaced, never merged (see above)
    cfg.additional_domains = bool(rows)
    reviewed = {d.name for d in rows if d.name in marks}
    if own and own_reviewed:
        reviewed.add(own)
    record_reviewed(cfg, reviewed)
    return [d.name for d in rows]


def imported_domains_lines(md: "LocalMeshDomains | None") -> list[str]:
    """What the import will carry, one plain line per ADDED domain — the GUI summary
    and the TUI screen render these same strings (escaped by the GUI). A saved row the
    import will not take (``_import_problem``) gets a "NOT imported: <why>" line rather
    than a quiet omission. [] when the mesh carries no domain rows beyond its own."""
    if md is None:
        return []
    own = (md.own_name or "").strip()
    marks = set(md.domain_services_reviewed)
    out: list[str] = []
    for row in md.domains:
        name = (row.name or "").strip()
        if not name or name == own:
            continue
        problem = _import_problem(row)
        if problem:                  # the import will not take it: say so, never list it
            out.append(f"{name} — NOT imported: {problem}")
            continue
        signin = ("own Casdoor" if getattr(row, "idp", "") == DOMAIN_IDP_OWN
                  else "superdomain sign-in")
        slugs = normalise_slugs(row.optional_services)
        svc = ", ".join(slugs) if slugs else "cluster default"
        state = "" if name in marks else " (services not confirmed yet)"
        # the domain's own Tor front door (#582) — said only when it has one, so a
        # mesh without Tor domains reads exactly as before
        door = "; its own Tor front door" if getattr(row, "tor", False) else ""
        # the export org — said only when the row names one, so a mesh with no
        # exported domain reads exactly as before
        org = (getattr(row, "github_org", "") or "").strip()
        exported = f"; exports to GitHub org {org}" if org else ""
        out.append(f"{name} — {signin}; services: {svc}{state}{door}{exported}")
    return out
