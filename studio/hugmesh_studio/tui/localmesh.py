"""The Local Docker mesh side-flow on the TUI — its choice screen and its DOMAINS and
DOMAIN SERVICES steps (#494; operator decision 71 = A: TUI parity in the same PR).

The GUI route (``gui/pages/localmesh_choice.py`` + ``gui/pages/localmesh.py``) is:
choice (join | generate) -> Env & brand -> **Domains** -> **Domain services** -> Repo
source -> Services -> Identity provider -> Mesh overlay -> Saved meshes & review ->
Bring-up & monitor. The TUI hosts the parts that decide WHICH DOMAINS the mesh serves
and WHAT EACH ONE PROVIDES — the two steps #494 added — over the same Qt-free state the
GUI steps write (``core.local_mesh_domains.LocalMeshDomains``), and it gates on the SAME
seam (``core.domain_services.gate_reason`` with ``ACTION_MESH_START`` and
``LOCAL_MESH_REMEDY``). It does NOT bring a mesh up: the source / services / identity /
overlay steps and the bring-up are not ported (issue #519), and the last screen says
so plainly and prints the ``hugmesh-mesh-bootstrap`` command that carries what the
steps decided — but only once the gate is clear, so the TUI can never hand out a start
command for a domain nobody configured.

THE SUPERBRAND (#654, D8). The window's Environment-and-brand step has the superbrand
drop-down (‘Create a new superbrand’ first and the default) with its design under it. The
text screens have no Environment step, so the same controls are one command on the
Domains screen: ``superbrand`` opens ``tui/superbrand_step.SuperbrandScreen`` over the
SAME session class the window drives (``session_for(j, "docker", ...)``), and the record
both faces save is written by the same call, so the same choices write the same bytes.
Leaving the Domains screen without typing it changes nothing — an untouched brand writes
no record — exactly as the window.

What is the same as the GUI, by construction:

* row 1 of the Domains table is the mesh's OWN domain — the brand-default apex on a
  test mesh (fixed), the public apex on a prod one (``p NAME`` types it); it can never
  be removed and its sign-in is the central Casdoor;
* added rows carry a Sign-in (``s N`` toggles Superdomain <-> Own), and the Own rows are
  ``LocalMeshBootstrapConfig.own_idp_domains`` (one Casdoor each, core/own_casdoor.py);
* the Domain services step is ``tui/domain_services_step.DomainServicesScreen`` — the
  image flow's own screen — walking the rows one domain at a time, own domain first,
  with one extra sentence saying the per-domain selection is RECORDED on this lane and
  does not pick the compose profiles;
* being on a domain's services screen is what records it; the gate names every domain
  never opened.

Choice default is ``join`` by id, as the GUI page's is.
"""
from __future__ import annotations

import dataclasses
import shlex

from ..core import brand_model, plain_words
from ..core.config import (DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, Domain,
                           set_domain_signin)
from ..core.domain_services import (ACTION_MESH_START, gate_reason, normalise_slugs,
                                    record_reviewed)
from ..core.local_mesh_bootstrap import LocalMeshBootstrapConfig
from ..core.local_mesh_domains import (DOCKER_SERVICES_NOTE, DOMAIN_NAME_RE,
                                       LOCAL_MESH_REMEDY,
                                       LocalMeshDomains, bootstrap_domain_records,
                                       own_idp_names)
from . import model
from .domain_services_step import DomainServicesScreen
from .domains_step import IDP_LABELS, OWN_IDP, set_github_org
from .superbrand_step import CREATE_KEY, BrandSession, SuperbrandScreen, session_for

__all__ = ["LocalMeshScreen", "LOCALMESH_CHOICES", "LOCALMESH_DEFAULT_CHOICE",
           "LANE_NOTE", "bootstrap_command", "sync_brand_session", "PUBLIC_NAME_HOME"]

#: (id, title) of the two cards — the GUI page's ``choices`` ids and titles
#: (test_tui_gui_parity pins the match).
LOCALMESH_CHOICES: tuple[tuple[str, str], ...] = (
    ("join", "Join an existing mesh with a key"),
    ("generate", "Generate a new mesh"),
)
LOCALMESH_DEFAULT_CHOICE = "join"

#: The one sentence the services step adds on this lane — the GUI widget's
#: ``lane_note`` says the same thing.
LANE_NOTE = DOCKER_SERVICES_NOTE

# the domains_step shape: a lowercase dotted hostname — ONE regex, shared with the
# GUI's local-mesh Domains step (core/local_mesh_domains.DOMAIN_NAME_RE).
_NAME_RE = DOMAIN_NAME_RE


def _test_apex() -> str:
    """Row 1 on a TEST mesh: the brand-default apex the bring-up resolves to."""
    return LocalMeshBootstrapConfig().resolved_domain()


#: Where the mesh's public name is typed on this route, said wherever the design shows
#: its box (the window disables the box with this as its tooltip; the text screen prints
#: it in the box's place). One home, so the two faces cannot disagree about it.
PUBLIC_NAME_HOME = ("set on the Domains step (the first row, on a production mesh); "
                    "a test mesh has none")


def sync_brand_session(session: BrandSession, cfg: LocalMeshBootstrapConfig, *,
                       explicit_signin: str = "") -> None:
    """Make the session's cached copies of what the PAGE owns say what the page says now:
    the public name (the domain row), the Tor way (the Tor tick or the selection) and the
    central sign-in. The record reads them when it is saved, and the start's own check
    refuses a record whose Tor way disagrees with the selection, so a copy cached when the
    session was made — before the person ticked Tor or typed the domain — must not be the
    one saved. Both faces call this before they commit (one implementation).

    The sign-in address is DERIVED (a production mesh's ``https://id.<public name>``; a
    test mesh's is the start path's own localhost address and is not stored) unless a
    saved mesh carried one of its own (``explicit_signin``, which is kept as the session
    has it). Derived means re-derived every time: the first commit writes the derived value back onto the carrier, so
    ``the key is there`` says nothing about who chose it."""
    # A test mesh has NO public name: the apex ``resolved_domain()`` falls back to is
    # the brand's placeholder, and writing it into the record made a record saved from a
    # test design look like a production mesh on that placeholder (it beat an explicit
    # --cluster-domain and satisfied "prod requires a public cluster domain"). So the
    # name and the address derived from it are kept only once a real name is typed.
    own = (cfg.cluster_domain or "").strip() if cfg.is_prod() else ""
    keep = {"public_name": own,
            "ways": {**(session.sb.ways or {}), "tor": bool(cfg.effective_with_tor())}}
    if not explicit_signin:
        keep["central_signin"] = cfg.issuer() if own else ""
    session.sb = dataclasses.replace(session.sb, **keep)


def bootstrap_command(md: LocalMeshDomains, prod: bool, *, brand: str = "",
                      record: str = "") -> list[str]:
    """The ``hugmesh-mesh-bootstrap plan`` argv that carries what the steps decided:
    env, the prod apex, one ``--own-casdoor-domain`` per Own row, and — once the person
    chose or designed a superbrand — ``--brand ID`` and ``--record FILE`` (the brand
    record both faces save, which the CLI reads as the authority for the brand, the
    designed block and the brands). The per-domain optional services have no CLI flag —
    they are recorded by the GUI's saved-mesh record — and the screen says so rather than
    inventing one."""
    argv = ["python3", "-m", "hugmesh_studio.core.local_mesh_bootstrap", "plan",
            "--env", "prod" if prod else "test"]
    if prod and md.own_name:
        argv += ["--cluster-domain", md.own_name]
    for name in own_idp_names(md.domains):
        argv += ["--own-casdoor-domain", name]
    if brand:
        argv += ["--brand", brand]
    if record:
        argv += ["--record", record]
    return argv


class _DockerSuperbrandScreen(SuperbrandScreen):
    """The shared superbrand screen with the one box this route does not edit: the public
    name has a single editing home (the Domains rows), here as in the window."""

    def lines(self, j) -> list[str]:
        out = super().lines(j)
        for i, ln in enumerate(out):
            if ln.startswith("   public"):
                out[i] = f"   {'public':<8}{'Public name':<22}{PUBLIC_NAME_HOME}"
            elif ln.startswith("commands:") and "id|title|org|public|root" in ln:
                out[i] = ln.replace("id|title|org|public|root", "id|title|org|root")
        return out

    def feed(self, j, line: str) -> None:
        if line.strip().lower().partition(" ")[0] == "public":
            j.status = f"the public name is {PUBLIC_NAME_HOME}"
            return
        super().feed(j, line)


class LocalMeshScreen:
    """The side-flow: ``choice`` -> ``domains`` -> ``services`` -> ``review``."""

    slug = "localmesh"
    title = "Local Docker mesh"
    #: ``b`` means BACK inside the flow; ``q`` still quits (not claimed).
    wants_q = False

    def __init__(self):
        self.stage = "choice"
        self.prod = False
        #: the record file the last save of this flow wrote ("" = none)
        self.saved_record = ""
        self.services = DomainServicesScreen(
            cfg_of=lambda j: self.state(j),
            on_continue=lambda j: self._goto(j, "review"),
            on_back=lambda j: self._goto(j, "domains"),
            lane_note=LANE_NOTE)

    # ── state ──────────────────────────────────────────────────────────────────
    @staticmethod
    def state(j) -> LocalMeshDomains:
        """The journey's local-mesh domain state — created on first use, never
        persisted into ``j.cfg`` (the local-mesh branch emits zero ImageConfig
        fields, as on the GUI)."""
        md = getattr(j, "localmesh_domains", None)
        if md is None:
            md = LocalMeshDomains()
            j.localmesh_domains = md
        return md

    # ── the superbrand (#654, D8) ───────────────────────────────────────────────
    def boot(self, j) -> LocalMeshBootstrapConfig:
        """The carrier the superbrand session reads and writes (the window's
        ``LocalMeshPage._brand_boot``): the brand id and the designed block live on it,
        the environment and the domain are put on it from this screen's own state every
        time. Created on first use, never persisted into ``j.cfg``."""
        cfg = getattr(j, "localmesh_boot", None)
        if cfg is None:
            cfg = LocalMeshBootstrapConfig()
            j.localmesh_boot = cfg
        md = self.state(j)
        cfg.env = "prod" if self.prod else "test"
        cfg.cluster_domain = md.own_name if self.prod else ""
        return cfg

    def brand_session(self, j) -> BrandSession:
        return session_for(j, "docker", (self.boot(j), self.state(j)),
                           getattr(j, "generator_dir", "") or "")

    def commit_brand(self, j, *, save: bool = False) -> list[str]:
        """Write the session onto the carrier and, with ``save``, the record file —
        the window's ``leave_brand``. An untouched session writes nothing. Remembers
        whether THIS call left a good record behind (``saved_record``): a file from an
        earlier mesh in the same state folder is never offered as this mesh's."""
        s = self.brand_session(j)
        sync_brand_session(s, self.boot(j))
        problems = s.commit(save=save)
        if save:
            self.saved_record = (brand_model.record_path()
                                 if s.touched and not problems else "")
        return problems

    def brand_args(self, j) -> tuple[str, str]:
        """``(brand id, record file)`` for the printed command: both empty while the
        person has not chosen or designed anything (the command is then byte-identical
        to what it was before this step existed)."""
        s = self.brand_session(j)
        if not s.touched:
            return "", ""
        return self.boot(j).brand, self.saved_record

    def _brand_line(self, j) -> str:
        s = self.brand_session(j)
        word = plain_words.term("superbrand")
        if s.choice == CREATE_KEY:
            named = s.sb.title or s.sb.id
            what = (f"a new {word}, ‘{named}’ (designing it)" if s.touched and named
                    else f"Create a new {word}" + ("" if s.touched else " (default)"))
        else:
            what = next((c.label for c in s.choices() if c.key == s.choice), s.choice)
        return (f"{word.capitalize()}: {what}. "
                f"Type ‘{word}’ to choose or design it.")

    def _open_brand(self, j) -> None:
        screen = _DockerSuperbrandScreen(session_of=self.brand_session, route="docker")
        screen.enter(j)
        j.open_overlay(screen)

    def _seed(self, j) -> None:
        """Row 1 is the own domain: seed it on first entry, rename it when the env or
        the prod apex changed (a renamed domain is one nobody reviewed under that
        name — record_reviewed prunes the stale marker)."""
        md = self.state(j)
        own = md.own_name if (self.prod and md.own_name) else (
            "" if self.prod else _test_apex())
        if not md.domains:
            md.domains = [Domain(name=own, title="")]
        elif md.domains[0].name != own:
            md.domains[0].name = own
        md.own_name = own
        record_reviewed(md, md.domain_services_reviewed)

    def _goto(self, j, stage: str) -> None:
        if stage == "services":
            # the services screen walks the named rows; a blank prod apex is not one
            self.services.enter(j)
        if stage == "review":
            # the rows are final: write the superbrand onto the carrier and the record
            # file with them (the window does the same on its way to the review step)
            problems = self.commit_brand(j, save=True)
            if problems:
                j.status = f"the superbrand record was not saved: {problems[0]}"
        self.stage = stage

    # ── screen protocol ─────────────────────────────────────────────────────────
    def enter(self, j) -> None:
        self.stage = "choice"

    def prompt(self, j) -> str:
        if self.stage == "services":
            return self.services.prompt(j)
        return f"localmesh-{self.stage}> "

    def lines(self, j) -> list[str]:
        return getattr(self, f"_lines_{self.stage}")(j)

    def feed(self, j, line: str) -> None:
        getattr(self, f"_feed_{self.stage}")(j, line.strip())

    # ── choice ──────────────────────────────────────────────────────────────────
    def _lines_choice(self, j) -> list[str]:  # noqa: ARG002
        out = ["Run a HugMesh mesh on THIS machine in Docker. Two ways in; pick one.", ""]
        for i, (cid, title) in enumerate(LOCALMESH_CHOICES, 1):
            mark = " (default)" if cid == LOCALMESH_DEFAULT_CHOICE else ""
            out.append(f"  {i}. {title}{mark}")
        out += ["", "commands: NUMBER=pick · Enter=the default"]
        return out

    def _feed_choice(self, j, line: str) -> None:
        ids = [cid for cid, _ in LOCALMESH_CHOICES]
        if line == "":
            pick = LOCALMESH_DEFAULT_CHOICE
        else:
            try:
                pick = ids[int(line) - 1] if 1 <= int(line) <= len(ids) else None
            except ValueError:
                pick = None
        if pick is None:
            j.status = f"no such choice: {line!r}"
            return
        if pick == "join":
            self.stage = "join"
            return
        self._seed(j)
        self.stage = "domains"

    def _lines_join(self, j) -> list[str]:  # noqa: ARG002
        return ["Joining an existing mesh with a key is not yet ported to the TUI — "
                "run it from the GUI (python -m hugmesh_studio).",
                "", "(Enter returns to the menu of choices)"]

    def _feed_join(self, j, line: str) -> None:  # noqa: ARG002
        j.goto("mode")

    # ── domains ─────────────────────────────────────────────────────────────────
    def table(self, j) -> tuple[list[str], list[list[str]]]:
        """(headers, rows): row 1 the own domain, then every added one."""
        md = self.state(j)
        rows = []
        for i, d in enumerate(md.domains, 1):
            org = getattr(d, "github_org", "") or "none"
            if i == 1:
                rows.append(["1 (own)", d.name or "(type it: p NAME)", d.title or "-",
                             OWN_IDP, org])
            else:
                rows.append([str(i), d.name, d.title or "-", IDP_LABELS[d.idp], org])
        return ["#", "domain", "title", "sign-in", "github org"], rows

    def _lines_domains(self, j) -> list[str]:
        env = "prod" if self.prod else "test"
        out = [self._brand_line(j), "",
               f"Every domain this mesh serves, its own domain first ({env} mesh). "
               "Each one gets its own service page on the next step, and the mesh "
               "will not start while any domain here has never been through it. A row "
               "whose sign-in is ‘Own’ brings up a Casdoor of its own beside the "
               "central one (host ports 8001, 8002, … in row order).", ""]
        out += model.format_table(*self.table(j))
        out += ["",
                "Row 1 is this mesh's OWN domain: on a test mesh the brand-default apex "
                "(fixed), on a prod mesh the public apex you type with p NAME. It is "
                "always served and cannot be removed.",
                "commands: a NAME=add a domain · d NUMBER=delete · s NUMBER=toggle its "
                "sign-in (Superdomain Casdoor <-> Own Casdoor) · o NUMBER ORG|-=set "
                "its GitHub org (row 1 too) · p NAME=prod mesh with this public apex · "
                "p -=back to a test mesh · "
                f"{plain_words.term('superbrand')}=choose or design the superbrand · "
                "Enter=continue",
                "'GitHub org' = the organisation this domain's repositories are "
                "exported to by the Go-Live ‘Export to GitHub org’ step. An org slug "
                "only, never a token; none = the default, the step does not apply."]
        return out

    def _row(self, j, arg: str) -> int | None:
        md = self.state(j)
        try:
            n = int(arg)
        except ValueError:
            n = 0
        if not 1 <= n <= len(md.domains):
            j.status = f"no such domain row: {arg!r}"
            return None
        if n == 1:
            j.status = ("row 1 is this mesh's own domain — it is always served, cannot "
                        "be removed, and signs in via the central Casdoor.")
            return None
        return n - 1

    def _feed_domains(self, j, line: str) -> None:
        md = self.state(j)
        if line == "":
            if self.prod and not md.own_name:
                j.status = ("a prod mesh needs its public apex domain in row 1 — "
                            "p NAME types it.")
                return
            self._goto(j, "services")
            return
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if verb == plain_words.term("superbrand") and not arg:
            self._open_brand(j)
            return
        if verb == "a":
            if not _NAME_RE.match(arg):
                j.status = (f"not a domain name: {arg!r} (lowercase dotted hostname, "
                            "e.g. chat.example.org)")
                return
            if arg in md.names():
                j.status = f"already listed: {arg}"
                return
            md.domains.append(Domain(name=arg, title=""))
            return
        if verb == "d":
            row = self._row(j, arg)
            if row is not None:
                removed = md.domains.pop(row)
                record_reviewed(md, md.domain_services_reviewed)
                j.status = f"removed {removed.name}"
            return
        if verb == "s":
            row = self._row(j, arg)
            if row is not None:
                d = md.domains[row]
                # through the one writer (core.config.set_domain_signin): it clears an
                # own provider's settings and its Casdoor port when the row flips
                problems = set_domain_signin(
                    d, DOMAIN_IDP_OWN if d.idp == DOMAIN_IDP_SUPERDOMAIN
                    else DOMAIN_IDP_SUPERDOMAIN)
                j.status = (problems[0] if problems
                            else f"{d.name}: sign-in -> {IDP_LABELS[d.idp]}")
            return
        if verb == "o":
            # the GitHub org (the Go-Live export step) — row 1 INCLUDED: the own
            # domain is a real Domain row on this route, and the one most worth
            # exporting; bootstrap_domain_records records it with the mesh.
            which, _, org = arg.partition(" ")
            try:
                n = int(which.strip())
            except ValueError:
                n = 0
            if not 1 <= n <= len(md.domains):
                j.status = f"no such domain row: {which.strip()!r}"
                return
            d = md.domains[n - 1]
            j.status = set_github_org((d, "github_org", d.name or "row 1"), org.strip())
            return
        if verb == "p":
            if arg == "-":
                self.prod = False
                md.own_name = ""
                self._seed(j)
                j.status = f"test mesh: row 1 is {md.own_name}"
                return
            if not _NAME_RE.match(arg):
                j.status = f"not a domain name: {arg!r}"
                return
            if arg in md.names()[1:]:
                j.status = f"{arg} is already an added row — delete it first"
                return
            self.prod = True
            md.own_name = arg
            self._seed(j)
            j.status = f"prod mesh: row 1 is {arg}"
            return
        j.status = f"unrecognised command: {line!r}"

    # ── services (the image flow's screen, re-hosted) ───────────────────────────
    def _lines_services(self, j) -> list[str]:
        return self.services.lines(j)

    def _feed_services(self, j, line: str) -> None:
        self.services.feed(j, line)

    # ── review: the gate, then what the TUI can hand over ───────────────────────
    def refusal(self, j) -> str:
        """The SAME gate both GUI start doors call, with this route's remedy."""
        return gate_reason(self.state(j), ACTION_MESH_START, remedy=LOCAL_MESH_REMEDY)

    def _lines_review(self, j) -> list[str]:
        md = self.state(j)
        refusal = self.refusal(j)
        if refusal:
            return [refusal, "",
                    "commands: b=back to the Domain services step · Enter=back to "
                    "the menu of choices"]
        out = ["Domains and their services are configured.", ""]
        headers = ["domain", "sign-in", "services (what this mesh runs)"]
        rows = [[d.name, IDP_LABELS.get(d.idp, d.idp),
                 ", ".join(normalise_slugs(d.optional_services)) or "cluster default"]
                for d in md.domains]
        out += model.format_table(headers, rows)
        brand, record = self.brand_args(j)
        out += ["", self._brand_line(j)]
        if record:
            out += [f"  record saved: {record}"]
        out += ["",
                "The rest of this route — repo source, the mesh's own "
                "infrastructure, identity provider, "
                "overlay and the bring-up itself — is not yet ported to the TUI "
                "(issue #519): finish it in the GUI (python -m hugmesh_studio), or "
                "preview the bring-up headlessly with:",
                "  " + shlex.join(bootstrap_command(md, self.prod, brand=brand,
                                                  record=record)),
                "That command carries the env, the apex, every Own sign-in and the "
                "superbrand's record; the "
                "per-domain services have no CLI flag — the GUI records them with the "
                "saved mesh.",
                "", "commands: b=back to the Domain services step · Enter=back to the "
                "menu of choices"]
        return out

    def records(self, j) -> tuple[dict, ...]:
        """What a GUI bring-up would record for these rows
        (``LocalMeshBootstrapConfig.domains``) — the same function."""
        md = self.state(j)
        return bootstrap_domain_records(md.domains, md.own_name)

    def _feed_review(self, j, line: str) -> None:
        if line.lower() == "b":
            self._goto(j, "services")
            return
        if line == "":
            j.goto("mode")
            return
        j.status = f"unrecognised command: {line!r}"
