"""The superbrand step — which superbrand governs this mesh, and how to design a new one
(hugmesh-generator#654, decisions D8, D20 and D6; operator decision 71 = A: the window
and the text screens offer the same controls).

THE MODEL IS HERE, NOT IN THE WINDOW. The window's drop-down and design step
(``gui/pages/brand_picker.py``, ``gui/pages/superbrand.py``) and this text screen both
drive one Qt-free object, :class:`BrandSession`, so a choice made in either face is the
same call and writes the same record. The session sits over a :class:`BrandHost`, the
small adapter that says where the three routes keep a mesh's brand:

* the IMAGE route keeps it on the wizard's ``ImageConfig`` (``brand``, ``brand_title``,
  ``org``, ``cluster_domain``, ``superdomain``, the ``login_*`` look and ``domains``);
* the DOCKER route keeps it on the bootstrap configuration (``brand``, ``superbrand``,
  ``domains``);
* the FLEET window keeps it on its own state (the pass-through ``--cluster-domain`` and
  the fleet's domain rows).

THE DROP-DOWN (D8). ``Create a new superbrand`` is the FIRST item on every route and is
the item selected when nothing has been chosen yet; then the saved designs of the
Studio's store, then the ``brands/*.conf`` profiles. Choosing an existing design or
profile skips the design and shows a read-only summary with a ``Change it`` click. A
configuration that already carries a superbrand of its own is selected as THAT, so a
person who loads a saved config is not asked to design over it.

THE UNAFFILIATED RULE (D20), kept. An unaffiliated image has no brand identity, so the
drop-down offers nothing to choose and says why inline; the LOOK is still its own (the
look editor stays). The record writer is the fourth enforcement site and refuses the
identity too (``brand_model.record_problems``); this screen reaches it and shows the
reason.

WHAT THE RECORD CANNOT HOLD YET. The brand record's look carries eight fields
(``brand_model.LOOK_KEYS``); the look editor offers more (the two web pictures, the
header and footer). The session says exactly which choices are not in the record
(:meth:`BrandSession.not_in_record`) and every screen prints that sentence beside the
design, rather than dropping them without a word. The day ``LOOK_KEYS`` grows, the
sentence disappears by itself.

NO MODAL. Every refusal is a sentence in :attr:`BrandSession.message` or a list from
:meth:`BrandSession.problems`; nothing here opens a dialog.
"""
from __future__ import annotations

import dataclasses
import datetime
import os
from typing import Any

from ..core import brand_look, brand_model, plain_words, validate as validators
from ..core.config import DOMAIN_FIELDS, Domain, ImageConfig, unaffiliated_image

__all__ = ["CREATE_KEY", "CREATE_LABEL", "UNAFFILIATED_REASON", "Choice", "BrandHost",
           "ImageHost", "BootstrapHost", "FleetHost", "BrandSession", "SuperbrandScreen",
           "session_for", "IDENTITY_FIELDS", "IDENTITY_LABELS"]

CREATE_KEY = "create"
#: The word every screen uses for the mesh's governing brand: the table's, never a copy.
SUPERBRAND = plain_words.term("superbrand")
CREATE_LABEL = f"Create a new {SUPERBRAND}"

#: Shown inline where the drop-down would be on an unaffiliated image (D20).
UNAFFILIATED_REASON = (
    f"An unaffiliated image has no brand identity, so there is no {plain_words.term('superbrand')} to create "
    "or choose: the builder refuses a brand id, title, organisation and logo for it. "
    "Its look is still yours.")

#: The five identity fields of the superbrand block the design step edits, with the
#: record field each one writes. (The superbrand's id is the first.)
IDENTITY_FIELDS: tuple[str, ...] = ("id", "title", "org", "public_name", "internal_root")
IDENTITY_LABELS: dict[str, str] = {
    "id": f"{SUPERBRAND.capitalize()} id", "title": "Title", "org": "Organisation",
    "public_name": "Public name",
    "internal_root": plain_words.term("internal_root").capitalize(),
}

#: What an untouched configuration carries in the three identity fields: no choice yet.
_SHIPPED = {
    "id": ("", ImageConfig.__dataclass_fields__["brand"].default),
    "title": ("", ImageConfig.__dataclass_fields__["brand_title"].default),
    "org": ("", ImageConfig.__dataclass_fields__["org"].default),
}

_KIND_NOTE = {"create": "", "design": "a saved design", "profile": "a brands/ profile",
              "current": "this configuration"}


@dataclasses.dataclass(frozen=True)
class Choice:
    """One item of the drop-down. ``kind`` is create, design, profile or current."""
    key: str
    label: str
    kind: str


# ── the hosts ────────────────────────────────────────────────────────────────────────
class BrandHost:
    """Where one route keeps a mesh's brand. A host reads a record out of its
    configuration and writes the superbrand block (and a brand's row fields) back; it
    never saves the record file — the session does, through brand_model.save_record."""

    route = ""
    generator_dir = ""
    #: True when the route's mesh START accepts more than the record FILE does (the
    #: Docker mesh: no title rule, 63-character labels). The session then checks the
    #: design the way the start does and leaves the strict rules to the file's own write.
    docker_start = False

    def unaffiliated(self) -> bool:
        return False

    def read(self) -> brand_model.BrandRecord:
        raise NotImplementedError

    def write_superbrand(self, sb: brand_model.Superbrand) -> None:
        raise NotImplementedError

    def row(self, name: str):
        """The LIVE row named ``name`` (a Domain), or None."""
        raise NotImplementedError

    def update_row(self, name: str, **fields: Any) -> None:
        raise NotImplementedError

    def look(self, sb: brand_model.Superbrand) -> brand_look.Look:
        """The superbrand's look as a design-mode model, bound to wherever the route
        keeps it."""
        return brand_look.Look(sb.look)

    def profile_chosen(self, name: str) -> None:
        """An existing brands/<name>.conf was chosen: the route may point its profile
        field at it."""

    def profile_dropped(self) -> None:
        """A new design or a saved one was chosen instead: a profile file chosen
        earlier no longer describes the mesh, and a builder reading it beside the
        design would take its identity from the wrong place."""

    def base_ca(self, name: str) -> str | None:
        """The certificate authority recorded for brand ``name`` (its file's name, "" =
        the mesh default), or None when this route has no such choice (the Docker mesh
        and the fleet have no Secrets-store step)."""
        return None

    # the rows, as fresh Domain objects (a snapshot the record can hold)
    def rows(self) -> list[Domain]:
        return [Domain(**dataclasses.asdict(d)) for d in self._live_rows()]

    def _live_rows(self) -> list[Domain]:
        return []


class ImageHost(BrandHost):
    """The image wizard's ``ImageConfig``."""

    route = "image"

    def __init__(self, cfg: ImageConfig, generator_dir: str = ""):
        self.cfg = cfg
        self.generator_dir = generator_dir

    def unaffiliated(self) -> bool:
        return unaffiliated_image(self.cfg)

    def read(self) -> brand_model.BrandRecord:
        return brand_model.record_from_image_config(self.cfg)

    def write_superbrand(self, sb: brand_model.Superbrand) -> None:
        # apply_record_to_image_config also REPLACES cfg.domains; the rows are not this
        # call's to touch (the Domains and Domain services steps own them), so the
        # live list is put back untouched.
        keep_rows, keep_flag = self.cfg.domains, self.cfg.additional_domains
        brand_model.apply_record_to_image_config(
            brand_model.BrandRecord(superbrand=sb, brands=[]), self.cfg)
        self.cfg.domains, self.cfg.additional_domains = keep_rows, keep_flag
        # A blank title or organisation reaching here was left blank by a PICK (the
        # session fills a blank with the configuration's own value until the person
        # picks; after a pick the blank is the answer). apply_ leaves a field the
        # record does not carry alone, which kept an abandoned design's title and
        # organisation under the pick, and the builder takes a flag over a profile.
        shipped = ImageConfig()
        if not sb.title:
            self.cfg.brand_title = shipped.brand_title
        if not sb.org:
            self.cfg.org = shipped.org

    def _live_rows(self) -> list[Domain]:
        return list(self.cfg.domains or [])

    def base_ca(self, name: str) -> str | None:
        return os.path.basename((getattr(self.cfg, "domain_ca", None) or {}).get(
            (name or "").strip(), ""))

    def row(self, name: str):
        for d in self.cfg.domains or []:
            if (d.name or "").strip() == (name or "").strip():
                return d
        return None

    def update_row(self, name: str, **fields: Any) -> None:
        d = self.row(name)
        if d is not None:
            for k, v in fields.items():
                setattr(d, k, v)

    def look(self, sb: brand_model.Superbrand) -> brand_look.Look:
        # the config is the store for the fields it carries, so the edit reaches the
        # Docker start that reads cfg.login_theme_css() at once
        return brand_look.CfgLook(self.cfg)

    def profile_chosen(self, name: str) -> None:
        path = os.path.join(self.generator_dir, "brands", f"{name}.conf")
        if self.generator_dir and os.path.isfile(path):
            self.cfg.brand_profile = path

    def profile_dropped(self) -> None:
        self.cfg.brand_profile = ""


class BootstrapHost(BrandHost):
    """The Docker route's ``LocalMeshBootstrapConfig`` for the superbrand block, and —
    while the Domains steps are open — the step state (``LocalMeshDomains``) for the
    rows: the steps edit THAT, and the bootstrap configuration's own ``domains`` are
    rebuilt from it when a step is left, so a brand edit written to the configuration's
    copy would be overwritten by the next commit. Without a state the rows are the
    configuration's own recorded ones."""

    route = "docker"
    docker_start = True

    def __init__(self, cfg, generator_dir: str = "", state=None):
        self.cfg = cfg
        self.generator_dir = generator_dir
        self.state = state

    def read(self) -> brand_model.BrandRecord:
        rec = brand_model.record_from_bootstrap(self.cfg)
        rec.brands = self.rows()
        return rec

    def write_superbrand(self, sb: brand_model.Superbrand) -> None:
        rec = brand_model.BrandRecord(superbrand=sb, brands=self.rows())
        brand_model.apply_record_to_bootstrap(rec, self.cfg, typed_flags=False)

    def _live_rows(self) -> list[Domain]:
        if self.state is not None:
            own = (self.state.own_name or "").strip()
            return [d for d in (self.state.domains or [])
                    if (d.name or "").strip() != own]
        return [Domain(**{k: r[k] for k in DOMAIN_FIELDS if k in r})
                for r in (self.cfg.domains or ()) if isinstance(r, dict)]

    def row(self, name: str):
        if self.state is not None:
            return self.state.by_name(name)
        for d in self._live_rows():
            if (d.name or "").strip() == (name or "").strip():
                return d
        return None

    def update_row(self, name: str, **fields: Any) -> None:
        if self.state is not None:
            d = self.state.by_name(name)
            if d is not None:
                for k, v in fields.items():
                    setattr(d, k, v)
            return
        out = []
        for r in (self.cfg.domains or ()):
            if isinstance(r, dict) and (r.get("name") or "").strip() == (name or "").strip():
                r = {**r, **fields}
            out.append(r)
        self.cfg.domains = tuple(out)


class FleetHost(BrandHost):
    """The fleet window's state: its ``FleetConfig`` knobs and its ``FleetDomains``
    rows (row 0 is the fleet's own domain, which is the superbrand, not a brand)."""

    route = "fleet"

    def __init__(self, options, state, generator_dir: str = ""):
        self.options = options        # FleetConfig (cluster_domain, brand_profile)
        self.state = state            # FleetDomains
        self.generator_dir = generator_dir
        self.block: dict[str, Any] = {}

    def _own(self) -> str:
        from ..core.fleet import fleet_own_domain
        return (self.state.own_name or "").strip() or fleet_own_domain(
            self.options.cluster_domain)

    def read(self) -> brand_model.BrandRecord:
        prof = os.path.basename(self.options.brand_profile or "")
        shipped = ImageConfig()          # what the builders default to when told nothing
        sb = brand_model.Superbrand.from_dict({
            "title": shipped.brand_title, "org": shipped.org,
            **self.block, "id": self.block.get("id") or (
                prof[:-5] if prof.endswith(".conf") else shipped.brand),
            "public_name": self._own()})
        return brand_model.BrandRecord(superbrand=sb, brands=self.rows())

    def write_superbrand(self, sb: brand_model.Superbrand) -> None:
        self.block = dict(sb.to_dict())
        if sb.public_name and sb.public_name != self._own():
            self.options.cluster_domain = sb.public_name

    def _live_rows(self) -> list[Domain]:
        own = self._own()
        return [d for d in (self.state.domains or []) if (d.name or "").strip() != own]

    def row(self, name: str):
        return self.state.by_name(name)

    def update_row(self, name: str, **fields: Any) -> None:
        d = self.state.by_name(name)
        if d is not None:
            for k, v in fields.items():
                setattr(d, k, v)

    def look(self, sb: brand_model.Superbrand) -> brand_look.Look:
        return brand_look.Look(sb.look)

    def profile_chosen(self, name: str) -> None:
        path = os.path.join(self.generator_dir, "brands", f"{name}.conf")
        if self.generator_dir and os.path.isfile(path):
            self.options.brand_profile = path

    def profile_dropped(self) -> None:
        self.options.brand_profile = ""


# ── the session ──────────────────────────────────────────────────────────────────────
class BrandSession:
    """One person's work on the superbrand and its brands, over one host.

    Both faces create it through :func:`session_for` and read and write ONLY through it.
    ``record()`` is the record the host's configuration describes right now plus what the
    session holds that no configuration has a field for (the superbrand's ways, a copied
    design's note, the pictures); ``commit()`` writes the superbrand block back and, when
    asked, saves the record file."""

    def __init__(self, host: BrandHost, *, today=None):
        self.host = host
        self.today = today or (lambda: datetime.date.today().isoformat())
        self.message = ""
        #: nothing is written to the record file until the person changed something
        self.touched = False
        #: True once the person PICKED an item in this session: from then on a field the
        #: pick left blank is blank (or the shipped id), never what the configuration
        #: held from an earlier pick (see :meth:`record`)
        self.picked = False
        rec = host.read()
        self.sb: brand_model.Superbrand = rec.superbrand
        self.copied_from: dict[str, str] = dict(rec.copied_from)
        self.look: brand_look.Look = host.look(self.sb)
        self._allow_look_identity()
        #: the open design: True while the design step is the thing on screen
        self.designing = False
        self.choice = self._initial_choice()
        self.designing = self.choice == CREATE_KEY and not self.unaffiliated
        if self.designing:
            # a design nobody has started is BLANK: the shipped HugMesh values an
            # untouched configuration carries are not a choice. A field left blank keeps
            # the configuration's own value (record()), so nothing is lost by this.
            self.sb = dataclasses.replace(self.sb, id="", title="", org="")

    # ── what is chosen ────────────────────────────────────────────────────────────
    @property
    def unaffiliated(self) -> bool:
        return bool(self.host.unaffiliated())

    def _has_superbrand(self) -> bool:
        """Has this configuration a superbrand of its own — anything but the shipped
        HugMesh defaults an untouched ImageConfig carries?"""
        sb = self.sb
        shipped = _SHIPPED
        return bool((sb.title and sb.title not in shipped["title"])
                    or (sb.org and sb.org not in shipped["org"])
                    or (sb.id and sb.id not in shipped["id"]))

    def _current_key(self) -> str:
        return f"current:{self.sb.id}"

    def _initial_choice(self) -> str:
        if self.unaffiliated:
            return ""
        if self._has_superbrand():
            return self._current_key()
        return CREATE_KEY

    def choices(self) -> list[Choice]:
        """The drop-down, in order: Create first, then this configuration's own
        superbrand when it has one, then the saved designs, then the profiles. Empty
        on an unaffiliated image (D20): the screen shows :data:`UNAFFILIATED_REASON`."""
        if self.unaffiliated:
            return []
        out = [Choice(CREATE_KEY, CREATE_LABEL, "create")]
        seen = set()
        if self._has_superbrand():
            label = f"{self.sb.title or self.sb.id} ({_KIND_NOTE['current']})"
            out.append(Choice(self._current_key(), label, "current"))
        for name in brand_model.list_designs():
            out.append(Choice(f"design:{name}", f"{name} ({_KIND_NOTE['design']})",
                              "design"))
            seen.add(name)
        for name in brand_model.profile_names(self.host.generator_dir):
            out.append(Choice(f"profile:{name}", f"{name} ({_KIND_NOTE['profile']})",
                              "profile"))
        return out

    def default_key(self) -> str:
        return self._initial_choice()

    def choose(self, key: str) -> str:
        """Pick an item. Returns the sentence the screen shows ('' when nothing to
        say). Create opens a blank design (the mesh's own naming is kept); a design is
        COPIED in (D5); a profile names the superbrand's id; the current one reopens
        nothing. A pick that is not offered is refused with the reason."""
        if self.unaffiliated:
            return self._say(UNAFFILIATED_REASON)
        keys = {c.key: c for c in self.choices()}
        if key not in keys:
            return self._say(f"‘{key}’ is not one of the choices")
        kind = keys[key].kind
        if kind == "create":
            self.sb = brand_model.Superbrand(
                public_name=self.sb.public_name, internal_root=self.sb.internal_root,
                central_signin=self.sb.central_signin, ways=dict(self.sb.ways))
            self.copied_from = {}
            self.look = self._fresh_look()
            self.host.profile_dropped()
            self.designing = True
        elif kind == "design":
            name = key.split(":", 1)[1]
            rec = brand_model.BrandRecord(superbrand=self.sb)
            try:
                brand_model.choose_design(rec, name, self.today())
            except (OSError, ValueError, brand_model.RecordRefused) as exc:
                return self._say(f"The design ‘{name}’ cannot be used: {exc}")
            self.sb, self.copied_from = rec.superbrand, dict(rec.copied_from)
            self.look = self._fresh_look()
            self.host.profile_dropped()
            self.designing = False
        elif kind == "profile":
            name = key.split(":", 1)[1]
            # the profile IS the superbrand: nothing of a design abandoned a moment ago
            # (its title, organisation, look) goes with it; the mesh's own naming stays
            self.sb = brand_model.Superbrand(
                id=name, public_name=self.sb.public_name, internal_root=self.sb.internal_root,
                central_signin=self.sb.central_signin, ways=dict(self.sb.ways))
            self.copied_from = {}
            self.look = self._fresh_look()
            self.host.profile_chosen(name)
            self.designing = False
        else:
            self.designing = False
        self.choice = key
        self.touched = True
        self.picked = True
        return self._say("")

    def change(self) -> str:
        """The 'Change it' click on an existing choice: open the design."""
        if self.unaffiliated:
            return self._say(UNAFFILIATED_REASON)
        self.designing = True
        return self._say("")

    def _fresh_look(self) -> brand_look.Look:
        look = self.host.look(self.sb)
        self.look = look
        self._allow_look_identity()
        return look

    def _allow_look_identity(self) -> None:
        """Wire a look model to this session (every look the session makes goes through
        here): an unaffiliated image keeps the look and loses the desktop logo (D20), and
        a design edit is checked against every brand's finished stylesheet (the
        superbrand's look plus the brand's own overrides) as the rows stand NOW, read at
        each edit, not only against the superbrand's own budget."""
        host = self.host                 # the closure holds the host, never the session
        self.look.dependents = lambda: {
            brand_model.brand_id(d): dict(d.look or {}) for d in host.rows()}
        self.look.identity_allowed = not self.unaffiliated
        self.look.identity_reason = UNAFFILIATED_REASON if self.unaffiliated else ""

    def _say(self, text: str) -> str:
        self.message = text
        return text

    # ── the design: identity ──────────────────────────────────────────────────────
    def identity(self) -> dict[str, str]:
        return {f: str(getattr(self.sb, f) or "") for f in IDENTITY_FIELDS}

    def set_identity(self, field: str, value: str) -> str:
        """Set one identity field. Returns the refusal ('' = accepted); a refused value
        changes nothing. The id is checked by the record's id rule (D4)."""
        if self.unaffiliated:
            return self._say(UNAFFILIATED_REASON)
        if field not in IDENTITY_FIELDS:
            return self._say(f"‘{field}’ is not a superbrand setting")
        value = (value or "").strip()
        old = getattr(self.sb, field)
        setattr(self.sb, field, value)
        problems = self.identity_problems(only=field)
        if problems:
            setattr(self.sb, field, old)
            return self._say(problems[0])
        self.touched = True
        return self._say("")

    def identity_problems(self, only: str = "") -> list[str]:
        """Why the identity cannot be saved (D4 and the record's own checks), each
        with its reason. ``only`` checks one field."""
        out: list[str] = []
        sb = self.sb
        checks = (
            ("id", lambda v: brand_model.brand_id_problem(
                v, profiles=(), max_len=brand_model.BRAND_ID_MAX)),
            ("title", lambda v: _raises(validators.validate_brand_title, v)),
            ("org", lambda v: _raises(validators.validate_org, v)),
            ("public_name", lambda v: _raises(validators.validate_domain_name, v)),
            ("internal_root", lambda v: _raises(validators.validate_domain_name, v)),
        )
        for field, check in checks:
            value = getattr(sb, field)
            if (only and only != field) or not value:
                continue
            problem = check(value)
            if problem:
                out.append(f"{IDENTITY_LABELS[field].lower()}: {problem}")
        return out

    # ── the design: look ──────────────────────────────────────────────────────────
    def not_in_record(self) -> list[str]:
        """The look choices made that the brand record cannot hold yet (its look keeps
        ``brand_model.LOOK_KEYS`` only). Empty when everything is held."""
        return sorted(k for k, v in self.look.record().items()
                      if v and k not in brand_model.LOOK_KEYS)

    def not_in_record_sentence(self) -> str:
        names = [_LOOK_NAMES.get(k, k) for k in self.not_in_record()]
        if not names:
            return ""
        return ("Not saved in the brand record yet: " + ", ".join(names)
                + ". The record's look holds colours, font, shape, decoration and "
                  "background effect only; these stay in this window's choices and "
                  "are left out of the saved file.")

    def record_look(self) -> dict[str, Any]:
        return {k: v for k, v in self.look.record().items()
                if v and k in brand_model.LOOK_KEYS}

    # ── the whole record ──────────────────────────────────────────────────────────
    def record(self) -> brand_model.BrandRecord:
        # a blank id, title or organisation keeps what the configuration already has
        # (the shipped values on an untouched one), so a design that only chose colours
        # is still a complete superbrand
        # An untouched configuration's own values are the blanks' answer; after a pick
        # they are not: the host holds what the LAST commit wrote, which is the design or
        # profile the person just left, and keeping its title under the new pick (or its
        # id under Create) made the record say something the drop-down no longer did.
        keep = (brand_model.Superbrand(id=_SHIPPED["id"][1]) if self.picked
                else self.host.read().superbrand)
        sb = dataclasses.replace(
            self.sb, look=self.record_look(), id=self.sb.id or keep.id,
            title=self.sb.title or keep.title, org=self.sb.org or keep.org)
        return brand_model.BrandRecord(superbrand=sb, brands=self.host.rows(),
                                       copied_from=dict(self.copied_from))

    def problems(self) -> list[str]:
        """Everything that stops the record being saved ([] = it can). Never raises."""
        rec = self.record()
        # The Docker route checks what the Docker start checks (docker_start): a brand
        # row titled "Bob's Shop" starts a mesh, so it must not stop the design of the
        # superbrand either. The strict rules run where the record FILE is written.
        out = brand_model.record_problems(
            rec, unaffiliated=self.unaffiliated, docker_start=self.host.docker_start,
            profiles=brand_model.profile_names(self.host.generator_dir)
            if self.host.generator_dir else ())
        out += brand_model.secret_problems(rec.to_dict(), "record")
        return out

    def commit(self, *, save: bool = False) -> list[str]:
        """Write the superbrand block back to the host's configuration and, with
        ``save``, the record file. Returns the problems ([] = written). Nothing is
        written while there is one, and an untouched session writes nothing at all."""
        if not self.touched:
            return []
        if self.unaffiliated:
            # an unaffiliated image has no brand record to write (D20: identity refused,
            # look allowed): the look already reached the configuration through the
            # look model, and the record writer refuses the identity if asked
            return []
        problems = self.problems()
        if problems:
            self._say(problems[0])
            return problems
        try:
            self.host.write_superbrand(self.record().superbrand)
        except ValueError as exc:
            self._say(str(exc))
            return [str(exc)]
        if save:
            try:
                brand_model.save_record(
                    self.record(), unaffiliated=self.unaffiliated,
                    profiles=brand_model.profile_names(self.host.generator_dir)
                    if self.host.generator_dir else ())
            except brand_model.RecordRefused as exc:
                # say WHICH side refused: the mesh itself took the design, the file did not
                self._say(
                    "The brand record file was not written: " + str(exc.problems[0])
                    + (". The mesh itself still starts; the file is what the builders "
                       "and the record commands read." if self.host.docker_start else ""))
                return list(exc.problems)
        return []

    def keep_design(self, name: str) -> str:
        """Keep the superbrand's design in the Studio's store under ``name``, so a later
        mesh can start from it. Returns the refusal ('' = kept)."""
        try:
            brand_model.save_design(name, dataclasses.replace(
                self.sb, look=self.record_look()))
        except (ValueError, brand_model.RecordRefused) as exc:
            return self._say(str(exc))
        return self._say("")

    # ── the read-only summary ─────────────────────────────────────────────────────
    def summary_rows(self) -> list[tuple[str, str]]:
        """``(label, value)`` rows of the read-only summary an existing choice shows —
        the window draws them as a two-column table, the text screen as aligned lines."""
        sb = self.sb
        rows: list[tuple[str, str]] = []
        for f in IDENTITY_FIELDS:
            v = getattr(sb, f) or (
                f"({sb.effective_internal_root()})" if f == "internal_root"
                else "(not set — the shipped value is kept)")
            rows.append((IDENTITY_LABELS[f], v))
        eff = brand_model.effective_look(brand_model.BrandRecord(superbrand=sb))
        shown = [f"{k} {v}" for k, (v, _src) in eff.items() if v]
        rows.append(("Look", ", ".join(shown) or "the shipped page"))
        if self.copied_from:
            rows.append(("Copied from", f"design ‘{self.copied_from.get('design', '')}’ on "
                                        f"{self.copied_from.get('date', '')}"))
        return rows

    def summary_title(self) -> str:
        return f"Superbrand: {self.sb.title or self.sb.id or '(not named yet)'}"

    def summary_lines(self) -> list[str]:
        out = [self.summary_title()]
        out += [f"  {label:<20}{value}" for label, value in self.summary_rows()]
        return out


def _raises(fn, value: str) -> str:
    """The text of the identity error ``fn`` raises for ``value``, '' when it accepts."""
    try:
        fn(value)
    except validators.IdentityValidationError as exc:
        return str(exc)
    return ""


#: look field -> the words a person reads (the picture fields have no short name)
_LOOK_NAMES = {"logo_image": "logo", "login_bg_image": "login background",
               "header_hidden": "header", "header_size": "header size",
               "header_bg": "header background", "header_text": "header text",
               "footer_hidden": "footer", "footer_size": "footer size",
               "footer_bg": "footer background", "footer_text": "footer text",
               "font_file": "font file", "font_licence": "font licence",
               "font_source": "font source", "theme": "desktop theme",
               "wallpaper": "wallpaper", "boot_background": "boot background",
               "boot_theme": "boot theme", "login_screen_background": "login-screen "
               "background", "desktop_logo": "desktop logo", "accent_color": "accent colour",
               "color_scheme": "colour scheme"}


def session_for(owner, route: str, source, generator_dir: str = "", **kw) -> BrandSession:
    """The session a face works with, kept on ``owner`` (the wizard, the journey, a page)
    so every step of one run shares it. ``source`` is the route's configuration: the
    ImageConfig; the bootstrap configuration, or a ``(bootstrap configuration,
    LocalMeshDomains)`` pair while the Docker route's Domains steps are open; or for
    the fleet a ``(FleetConfig, FleetDomains)`` pair. A session is rebuilt when the configuration object changes
    (Load config replaces it wholesale): a session belongs to the config it was made for."""
    slot = f"_brand_session_{route}"
    key = tuple(source) if isinstance(source, tuple) else (source,)
    cur = getattr(owner, slot, None)
    # identity, never equality: two configurations can be equal and still be different
    # sessions (the Domain services page's rule), and the owner holds the references so
    # no id can be reused by another object while this session is remembered
    have = getattr(owner, slot + "_for", None)
    if (cur is not None and have is not None and len(have) == len(key)
            and all(a is b for a, b in zip(have, key))):
        return cur
    if route == "image":
        host: BrandHost = ImageHost(source, generator_dir)
    elif route == "docker":
        host = (BootstrapHost(source[0], generator_dir, state=source[1])
                if isinstance(source, tuple) else BootstrapHost(source, generator_dir))
    elif route == "fleet":
        host = FleetHost(source[0], source[1], generator_dir)
    else:
        raise ValueError(f"unknown route {route!r}")
    sess = BrandSession(host, **kw)
    setattr(owner, slot, sess)
    setattr(owner, slot + "_for", key)
    return sess


# ── the text screen ──────────────────────────────────────────────────────────────────
class SuperbrandScreen:
    """The superbrand step as text: the drop-down, the read-only summary with ``change``,
    and the design with its numbered sections (1 Identity, 2 Look). The look is the look
    screen (``tui/themes.LookText``) over the session's look model — the same checked
    verbs the window's editor calls."""

    slug = "superbrand"
    title = "Superbrand"
    wants_q = True

    def __init__(self, session_of=None, on_continue=None, route: str = "image",
                 on_back=None):
        self._session_of = session_of
        self._on_continue = on_continue
        #: where ``b`` goes when the host is a step of a longer flow (the fleet's
        #: options); without it ``b`` and ``q`` close the screen like Enter without a save
        self._on_back = on_back
        self.route = route
        self.sub = "main"        # main | look
        self._look_text = None

    def session(self, j) -> BrandSession:
        if self._session_of is not None:
            return self._session_of(j)
        return session_for(j, "image", j.cfg, getattr(j, "generator_dir", ""))

    def enter(self, j) -> None:  # noqa: ARG002
        self.sub = "main"
        self._look_text = None

    def _look(self, j):
        from .themes import LookText
        s = self.session(j)
        if self._look_text is None or self._look_text.model is not s.look:
            self._look_text = LookText(s.look, path=self.route)
        return self._look_text

    # ── rendering ─────────────────────────────────────────────────────────────────
    def lines(self, j) -> list[str]:
        s = self.session(j)
        if self.sub == "look":
            return (["The superbrand's look (type 'back' to return):", ""]
                    + self._look(j).lines())
        if s.unaffiliated:
            return [UNAFFILIATED_REASON, "",
                    "  look         set the look (colours, font, shape, pictures)", "",
                    "commands: look · Enter=continue · "
                    + ("b=back" if self._on_back else "q=back")]
        out = ["Which superbrand governs this mesh?  (a NUMBER picks)", ""]
        cur = s.choice
        for i, c in enumerate(s.choices(), 1):
            out.append(f" {'*' if c.key == cur else ' '}{i}. {c.label}")
        out.append("")
        if s.designing:
            out += self._design_lines(s)
        else:
            out += s.summary_lines()
            out += ["", "  change       open the design to change it"]
        if s.message:
            out += ["", s.message]
        out += ["", "commands: NUMBER=choose · "
                + ("id|title|org|public|root VALUE · look · keep NAME · "
                   if s.designing else "change · ")
                + "Enter=continue · " + ("b=back" if self._on_back else "q=back")]
        return out

    def _design_lines(self, s: BrandSession) -> list[str]:
        out = ["Design your superbrand", "", "1. Identity"]
        ident = s.identity()
        for cmd, f in (("id", "id"), ("title", "title"), ("org", "org"),
                       ("public", "public_name"), ("root", "internal_root")):
            out.append(f"   {cmd:<8}{IDENTITY_LABELS[f]:<22}"
                       f"{ident[f] or '(not set — the shipped value is kept)'}")
        out.append("")
        out.append("2. Look — colours, font, shape, decoration, pictures (type 'look')")
        eff = s.look.effective()
        out.append("   " + ", ".join(f"{k} {eff[k]}" for k in ("preset", "primary",
                                                               "secondary", "font",
                                                               "style", "decor")
                                     if eff.get(k)) or "   the shipped page")
        sentence = s.not_in_record_sentence()
        if sentence:
            out += ["", sentence]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002
        return "superbrand-look> " if self.sub == "look" else "superbrand> "

    # ── input ─────────────────────────────────────────────────────────────────────
    def feed(self, j, line: str) -> None:
        s = self.session(j)
        line = line.strip()
        verb, _, arg = line.partition(" ")
        verb = verb.lower()
        if self.sub == "look":
            if verb in ("back", "b", "q"):
                self.sub = "main"
                s.touched = True
                return
            self._look(j).feed(line)
            s.touched = True
            return
        if line == "":
            problems = s.commit()
            if problems:
                j.status = problems[0]
                return
            self._finish(j)
            return
        if verb == "b" and self._on_back is not None:
            self._on_back(j)
            return
        if verb in ("q", "b"):
            self._finish(j)
            return
        if s.unaffiliated and verb == "look":
            self.sub = "look"                    # the look is the person's (D20)
            return
        if s.unaffiliated:
            j.status = UNAFFILIATED_REASON
            return
        if verb == "change":
            s.change()
        elif verb == "look":
            s.designing = True
            self.sub = "look"
        elif verb in ("id", "title", "org", "public", "root"):
            f = {"public": "public_name", "root": "internal_root"}.get(verb, verb)
            j.status = s.set_identity(f, arg)
        elif verb == "keep":
            j.status = s.keep_design(arg) or f"kept as ‘{arg}’"
        elif line.isdigit():
            ch = s.choices()
            n = int(line)
            j.status = (s.choose(ch[n - 1].key) if 1 <= n <= len(ch)
                        else f"no such choice: {line!r}")
        else:
            j.status = f"unrecognised command: {line!r}"

    def _finish(self, j) -> None:
        if self._on_continue:
            self._on_continue(j)
        elif getattr(j, "overlay", None) is self:
            j.close_overlay()
        else:
            j.advance()
