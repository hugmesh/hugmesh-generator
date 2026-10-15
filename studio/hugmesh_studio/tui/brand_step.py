"""The Brand settings screen — one brand, four numbered sections (hugmesh-generator#654,
decision D9; operator decision 71 = A: the window's four tabs and these four sections
are the same four things, in the same order).

    1. Identity        public name, title, id, sign-in, applies-to, certificate authority
    2. Look            the brand's override of the superbrand's look, field by field
    3. Services        the per-domain service catalogue (the existing step, unchanged)
    4. Ways to reach it  internal name, Tor address, public name through a provider

EACH SETTING HAS EXACTLY ONE EDITING HOME. This is the rule the screen is built on, and
what each section does about it:

* IDENTITY is a read-only mirror of the Domains table, which stays the home of a brand's
  public name, title, sign-in, images and certificate authority (and of adding and
  removing a brand). The brand's id has no editing home at all today: the Docker mesh
  still derives it from the public name, so the record accepts only that id
  (``brand_model.STORED_ID_MUST_MATCH``) — it is shown, made from the public name.
* LOOK is edited here (the look screen over an override-mode ``brand_look.Look``) and
  nowhere else. Where nothing can show a brand's own look (every route but the Docker
  mesh, D18) the section says so and shows the inherited values.
* SERVICES is the existing screen, untouched, and stays what is on screen when the step
  opens, so every command that worked before still does.
* WAYS is a read-only summary with one button in the window; the Go-Live wizard
  (``--go-live``) is the one place a way is chosen, and it writes through
  ``brand_model.set_ways``.

THE SUPERBRAND'S OWN ROW (the mesh's own domain) gets the same screen, labelled as the
superbrand: its identity and look are read-only mirrors of the superbrand step.

Qt-free, like everything in this package; the window's tabs call the same functions.
"""
from __future__ import annotations

from ..core import brand_look, brand_model, plain_words
from ..core.config import DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN
from .superbrand_step import BrandSession

__all__ = ["SECTIONS", "SECTION_LOOK", "SECTION_SERVICES", "BrandView", "brand_view",
           "section_menu", "identity_lines", "ways_lines", "summary_line",
           "IDENTITY_HOME", "WAYS_BUTTON", "LOOK_HOME"]

#: (number, title) — the window's four tabs, in the window's order.
SECTIONS: tuple[tuple[int, str], ...] = (
    (1, "Identity"), (2, "Look"), (3, "Services"), (4, "Ways to reach it"))
SECTION_LOOK = 2
SECTION_SERVICES = 3

#: Where each read-only mirror says the setting is changed.
IDENTITY_HOME = "change it in the brands table (the Domains step)"
SUPERBRAND_HOME = "change it in the superbrand step"
LOOK_HOME = "change it in the superbrand step"
WAYS_BUTTON = "Set up ways to reach this brand"
WAYS_HOME = ("the Go-Live wizard is where these are chosen: run it with the "
             "--go-live option, or press ‘" + WAYS_BUTTON + "’ in the window")


class BrandView:
    """One brand (or the superbrand's own row) as the four sections read it."""

    def __init__(self, session: BrandSession, name: str, own: bool):
        self.session = session
        self.name = (name or "").strip()
        self.own = own

    # ── the row ───────────────────────────────────────────────────────────────────
    @property
    def row(self):
        return None if self.own else self.session.host.row(self.name)

    @property
    def brand_id(self) -> str:
        if self.own:
            return self.session.sb.id or "(made from the public name)"
        return brand_model.brand_id(self.row) if self.row is not None else ""

    def label(self) -> str:
        return f"{self.name} (the superbrand)" if self.own else self.name

    # ── 1. Identity: a read-only mirror ───────────────────────────────────────────
    def identity(self) -> list[tuple[str, str]]:
        sb = self.session.sb
        if self.own:
            return [("Public name", self.name or sb.public_name or "(not set)"),
                    ("Title", sb.title or "(not set)"),
                    ("Id", self.brand_id),
                    ("Sign-in", "this is the superbrand: its people are the mesh's "
                                "own, signing in through the mesh's central sign-in")]
        r = self.row
        if r is None:
            return []
        idp = plain_words.SIGN_IN.get(
            r.idp if r.idp in (DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN)
            else DOMAIN_IDP_SUPERDOMAIN, "")
        rows = [("Public name", r.name or "(not set)"),
                ("Title", r.title or "(not set)"),
                ("Id", self.brand_id),
                ("Sign-in", idp),
                ("Applies to", ", ".join(r.images) if r.images
                 else "every eligible image")]
        ca = self.session.host.base_ca(self.name)
        if ca is not None:             # only a route with a Secrets-store step has one
            rows.append(("Certificate authority", ca or "none (the mesh default)"))
        return rows

    def identity_home(self) -> str:
        return SUPERBRAND_HOME if self.own else IDENTITY_HOME

    # ── 2. Look ───────────────────────────────────────────────────────────────────
    def look_model(self) -> brand_look.Look | None:
        """The brand's override model (None for the superbrand's own row: its look is
        the superbrand step's). One model per brand for the session, so the window and
        the text screen edit the same object."""
        if self.own:
            return None
        s = self.session
        cache = s.__dict__.setdefault("_brand_looks", {})
        have = cache.get(self.name)
        base = s.look.effective()
        if have is None:
            r = self.row
            have = brand_look.Look(dict((r.look or {}) if r is not None else {}),
                                   base=base)
            cache[self.name] = have
        else:
            # the superbrand's look may have changed since: the brand's own fields stay,
            # every inherited one follows the new default
            have.base = brand_look.effective_look(brand_look.normalise(base))
        return have

    def commit_look(self) -> None:
        """Write the brand's overrides to its row (only what the record holds)."""
        m = self.look_model()
        if m is None or self.row is None:
            return
        own = {k: v for k, v in m.record().items()
               if v != "" and k in brand_model.LOOK_KEYS}
        if own != dict(self.row.look or {}):
            self.session.host.update_row(self.name, look=own)
            self.session.touched = True

    def look_not_in_record(self) -> list[str]:
        m = self.look_model()
        if m is None:
            return []
        return sorted(k for k, v in m.record().items()
                      if v not in ("", None) and k not in brand_model.LOOK_KEYS)

    def look_lines(self, route: str) -> list[str]:
        if self.own:
            eff = brand_model.effective_look(
                brand_model.BrandRecord(superbrand=self.session.record().superbrand))
            out = ["The superbrand's own look — every brand starts from it.", ""]
            for k, (v, _src) in eff.items():
                out.append(f"   {k:<12}{v or '(shipped)'}")
            out += ["", LOOK_HOME]
            return out
        out = []
        if route not in brand_look.PATHS_WITH_OWN_LOOK:
            out += [brand_look.DOCKER_ONLY_SENTENCE, ""]
        eff = brand_model.effective_look(self.session.record(), self.row)
        for k, (v, src) in eff.items():
            out.append(f"   {k:<12}{v or '(shipped)':<24}{src}")
        return out

    # ── 4. Ways ───────────────────────────────────────────────────────────────────
    def ways(self) -> list[tuple[str, str, str, str]]:
        """(way, value, path, effect) for every way on every start path."""
        return brand_model.way_effects(self.session.record(),
                                       None if self.own else self.row)

    # ── the one-line summary a table row shows ────────────────────────────────────
    def summary(self) -> str:
        return summary_line(self.session, self.name, self.own)


def brand_view(session: BrandSession, name: str, own: bool = False) -> BrandView:
    return BrandView(session, name, own)


def summary_line(session: BrandSession, name: str, own: bool = False,
                 idp: str | None = None) -> str:
    """One read-only line per brand for the brands table: sign-in, how many look fields
    are its own, how it is reached — each in the model's words. ``idp`` overrides the
    row's sign-in with the one the table's cell shows right now (the table is the
    editing home of the sign-in and has not been committed yet)."""
    v = BrandView(session, name, own)
    if own:
        return "the superbrand — " + SUPERBRAND_HOME
    r = v.row
    if r is None:
        return "a new brand — it has no look or ways of its own yet"
    signs = ("has its own sign-in" if (idp or r.idp) == DOMAIN_IDP_OWN
             else "signs in through the superbrand")
    n = len([k for k, val in (r.look or {}).items() if val])
    look = f"{n} look setting{'s' if n != 1 else ''} of its own" if n else "inherits the look"
    ways = []
    if r.tor:
        ways.append("Tor")
    if (r.ways or {}).get("public", {}).get("provider"):
        ways.append("public name")
    ways_text = ("reached by " + " and ".join(ways)) if ways else "no extra ways to reach it"
    return f"{signs}; {look}; {ways_text}"


def section_menu(current: int) -> list[str]:
    """The numbered section line, the current one starred."""
    return ["  ".join(f"{'*' if n == current else ' '}{n}. {t}" for n, t in SECTIONS)]


def identity_lines(view: BrandView) -> list[str]:
    out = [f"1. Identity — {view.label()}", ""]
    for k, v in view.identity():
        out.append(f"   {k:<14}{v}")
    out += ["", view.identity_home()]
    return out


def ways_lines(view: BrandView) -> list[str]:
    out = [f"4. Ways to reach it — {view.label()}", ""]
    last = ""
    for way, value, path, effect in view.ways():
        if way != last:
            out.append(f"   {way}: {value}")
            last = way
        out.append(f"      {path}: {effect}")
    out += ["", WAYS_HOME]
    return out


def look_section_lines(view: BrandView, route: str) -> list[str]:
    """Section 2 as text: the look screen for a brand that can be edited, the read-only
    values where it cannot."""
    out = [f"2. Look — {view.label()}", ""]
    out += view.look_lines(route)
    return out
