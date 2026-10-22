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
  mesh, D18) the section says so and shows the inherited values. THE MESH'S OWN ROW
  (row 0) edits the superbrand's look itself, in design mode (2026-10-21, the
  operator: "the theme selection should be there instead of where it is now"): this is
  the ONLY place a theme is chosen. The old mesh-wide theme panels (the Docker route's
  "Themes" group, the Branding page's "Web login theme" and the TUI's "t. Themes") are
  gone; a saved configuration's ``login_*`` values still load, because the look model
  reads them.
* SERVICES is the existing screen, untouched, and stays what is on screen when the step
  opens, so every command that worked before still does.
* WAYS is a read-only summary with one button in the window; the Go-Live wizard
  (``--go-live``) is the one place a way is chosen, and it writes through
  ``brand_model.set_ways``.

THE SUPERBRAND'S OWN ROW (the mesh's own domain) gets the same screen, labelled as the
superbrand: its identity is a read-only mirror of the superbrand step, and its look is
the superbrand's own look, edited here.

Qt-free, like everything in this package; the window's tabs call the same functions.
"""
from __future__ import annotations

import dataclasses

from ..core import brand_look, brand_model, domain_reach, plain_words, reach_apply
from ..core.config import (DOMAIN_IDP_OWN, DOMAIN_IDP_SUPERDOMAIN, SIGNIN_FROM_MESH,
                           SIGNIN_SOURCE_WORDS, Domain, effective_signin,
                           set_domain_signin)
from .superbrand_step import MESH_SIGNIN_CHOICES, BrandSession

__all__ = ["SECTIONS", "SECTION_LOOK", "SECTION_SERVICES", "BrandView", "brand_view",
           "section_menu", "identity_lines", "ways_lines", "summary_line",
           "IDENTITY_HOME", "WAYS_BUTTON", "LOOK_HOME", "LOOK_POINTER",
           "SIGNIN_CHOICES", "SIGNIN_EXTERNAL", "SIGNIN_MESH_HOME", "PROVIDER_WORDS",
           "TAILNET_CHOICES", "EGRESS_CHOICES", "REACH_RECORDED_ONLY", "OWN_REACH_HOME",
           "feed_identity", "feed_ways", "CLIENT_SIGNIN_NOTE", "CLIENT_LOOK_NOTE",
           "CLIENT_SERVICES_NOTE",
           "CLIENT_WAYS_NOTE", "CLIENT_REACH_EFFECT", "WAYS_HOME", "WAYS_HOME_NO_BUTTON",
           "WAYS_GO_LIVE_COMMAND", "WAYS_TUI_LINE"]

#: (number, title) — the window's four tabs, in the window's order.
SECTIONS: tuple[tuple[int, str], ...] = (
    (1, "Identity"), (2, "Look"), (3, "Services"), (4, "Ways to reach it"))
SECTION_LOOK = 2
SECTION_SERVICES = 3

#: Where each read-only mirror says the setting is changed.
IDENTITY_HOME = "change it in the brands table (the Domains step)"
SUPERBRAND_HOME = "change it in the superbrand step"
LOOK_HOME = ("this is the mesh's own look: every domain starts from it, and this tab is "
             "the one place it is chosen")
#: Where the superbrand step points for the look (it no longer edits it).
LOOK_POINTER = ("the look (colours, font, shape, pictures, header and footer) is set on "
                "the ‘Look’ tab of this mesh's own domain, on the ‘Domain services’ "
                "step")
WAYS_BUTTON = "Set up ways to reach this brand"

# ── per-domain sign-in (2026-10-21, the operator: "Make sure the identity provider
# step is also added per domain") ─────────────────────────────────────────────────────
#: (key, the words a screen shows) — how ONE domain's people sign in. "mesh" is the
#: inherited default (the row's ``superdomain``); the rest are ``own``: its own Casdoor,
#: or its own external provider (core.config.set_domain_signin is the one writer).
SIGNIN_CHOICES: tuple[tuple[str, str], ...] = (
    ("mesh", "Through the mesh's sign-in (inherited)"),
    ("casdoor", "Its own Casdoor"),
    ("entra", "Its own Azure Entra ID"),
    ("aws", "Its own AWS Cognito"),
    ("oidc", "Its own other OIDC provider"),
)
SIGNIN_EXTERNAL = ("entra", "aws", "oidc")
PROVIDER_WORDS = {"casdoor": "Casdoor", "entra": "Azure Entra ID", "aws": "AWS Cognito",
                  "oidc": "an OIDC provider"}
#: Where the mesh's own sign-in (what every 'through the mesh' domain inherits) is set.
SIGNIN_MESH_HOME = ("the mesh's own sign-in is the default every domain inherits; it is "
                    "chosen on the ‘Identity provider’ step")
#: Row 0 (the mesh's own domain) EDITS that sign-in in place: the same value as the
#: Identity provider step, written where that step keeps it (one home, two doors).
SIGNIN_MESH_EDIT = ("this is the mesh's own sign-in: every domain that signs in through "
                    "the mesh inherits it. Changing it here changes the ‘Identity "
                    "provider’ step's choice too — they are the same setting")

# ── per-domain reach (VPN and egress; Tor is the row's own onion) ───────────────────
TAILNET_CHOICES: tuple[tuple[str, str], ...] = (
    (domain_reach.REACH_INHERIT, "The mesh's choice (inherited)"),
    ("on", "On the mesh's VPN"),
    ("off", "Not on the mesh's VPN"),
)
EGRESS_CHOICES: tuple[tuple[str, str], ...] = (
    (domain_reach.REACH_INHERIT, "The mesh's choice (inherited)"),
    (domain_reach.EGRESS_VPN, "Through an egress VPN"),
    (domain_reach.EGRESS_DIRECT, "Direct (no egress VPN)"),
)
#: What a route with no start of its own says about a domain's own VPN and egress
#: (BrandView.reach_effect gives each route its own sentence: the Docker mesh APPLIES
#: the egress of a domain that runs Mastodon, nothing applies a per-domain VPN, and
#: the image and fleet routes apply neither — core/reach_apply).
REACH_RECORDED_ONLY = reach_apply.ROUTE_NOT_APPLIED[""]
#: Where row 0's values come from: they ARE the mesh's (never "inherited").
OWN_SOURCE_WORDS = "the mesh's own setting"
#: Row 0 edits the mesh's own Tor and egress in place (the mesh-wide step's values).
OWN_REACH_EDIT = ("this is the mesh's own domain: its Tor address and its egress ARE the "
                  "mesh's, so changing them here changes the mesh-wide step's setting "
                  "too (the same value, one home)")
#: The mesh's own row: its VPN and egress ARE the mesh's.
OWN_REACH_HOME = ("this is the mesh's own domain: its VPN is the mesh's (on in "
                  "production), its egress is the mesh's egress VPN (the Mesh "
                  "infrastructure step, or the image's egress setting) and its onion is "
                  "the mesh's own Tor address")
# ── a Mesh desktop CLIENT image (the image wizard in cloud mode) ───────────────────
# A client image serves no domain. The builder takes only the NAMES of the domains it
# is tied to (--domains -> /etc/hugmesh/domains) and the mesh-wide --idp; no --domain-idp,
# no domain look and no domain way reaches it. These three sentences are what each tab
# says on that route, in both faces, so nothing on a client screen claims an effect.
CLIENT_SIGNIN_NOTE = ("Mesh desktop client image: a domain's own sign-in is kept with "
                      "this configuration only. The image carries the names of its "
                      "domains and nothing else about them, so no builder reads this "
                      "choice for a client yet.")
CLIENT_LOOK_NOTE = ("Mesh desktop client image: it serves no sign-in page, so no domain's "
                    "web look is shown by it. The desktop's own look (theme, wallpaper, "
                    "accent) is set on the Branding step.")
CLIENT_SERVICES_NOTE = ("Mesh desktop client image: it runs no services for its domains "
                        "and writes no mesh manifest, so the services ticked here are kept "
                        "with this configuration only. Which services the image itself "
                        "carries is the Network step's choice.")
#: What a client image's start does with a domain's own VPN and egress (the sentence
#: under the Ways controls on cloud, in place of the node-image one).
CLIENT_REACH_EFFECT = ("Not applied: a Mesh desktop client image joins the mesh's VPN and "
                       "uses an egress VPN as one whole computer (the Network step), so "
                       "this domain's own VPN and egress are kept with the configuration "
                       "only.")
CLIENT_WAYS_NOTE = ("Mesh desktop client image: it serves no domain, so this domain's Tor, "
                    "VPN and egress choices are kept with this configuration only. The "
                    "computer joins the mesh's VPN and uses an egress VPN as a whole: "
                    "both are set on the Network step.")

WAYS_HOME = ("the internal name and the public name are chosen in the Go-Live wizard: "
             "run it with the --go-live option, or press ‘" + WAYS_BUTTON + "’ in the "
             "window (Tor, VPN and egress are chosen above, per domain)")
#: The Ways line on a window that cannot open the Go-Live wizard itself (no checkout to
#: run its driver from): no button is drawn, so the line names only the option.
WAYS_HOME_NO_BUTTON = ("the internal name and the public name are chosen in the Go-Live "
                       "wizard: run it with the --go-live option (Tor, VPN and egress "
                       "are chosen above, per domain)")
#: The text face's twin of the button: typed in section 4, it opens the Go-Live screen
#: with this domain already picked.
WAYS_GO_LIVE_COMMAND = "go-live"
WAYS_TUI_LINE = ("here: type ‘" + WAYS_GO_LIVE_COMMAND + "’ to open the Go-Live screen "
                 "with this domain picked (b on its first step comes back)")


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

    def client_image(self) -> bool:
        """Is this screen building a Mesh desktop client image (cloud mode)? Then every
        tab says its choices are kept with the configuration only (CLIENT_*_NOTE)."""
        try:
            return bool(self.session.host.client_image())
        except Exception:                       # noqa: BLE001 — screens never raise
            return False

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
        idp = f"{idp}: {self.signin_words()}"
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

    # ── 1b. Sign-in: per domain ───────────────────────────────────────────────────
    def mesh(self):
        """The mesh's own configuration (what a 'through the mesh' domain inherits),
        as the host knows it — or None."""
        try:
            return self.session.host.mesh()
        except Exception:                       # noqa: BLE001 — screens never raise
            return None

    def _others(self) -> list:
        row = self.row
        return [d for d in self.session.host._live_rows() if d is not row]

    def writes(self):
        """Row 0's writers (``superbrand_step.MeshWrites``) for this route."""
        return self.session.host.mesh_writes()

    def signin_choices(self) -> tuple[tuple[str, str], ...]:
        """What the sign-in choice offers: a brand's own sign-in, or on row 0 the mesh's
        own provider (row 0 IS the mesh: 'through the mesh' would name itself)."""
        return MESH_SIGNIN_CHOICES if self.own else SIGNIN_CHOICES

    def signin_refusal(self) -> str:
        """Why this row's sign-in cannot be changed on this route ("" = it can)."""
        if not self.own:
            return ""
        why = self.writes().signin_refusal
        return (why[:1].upper() + why[1:]) if why else ""

    def signin_choice(self) -> str:
        """The SIGNIN_CHOICES key the row says now (row 0: the mesh's own provider)."""
        if self.own:
            return self.writes().signin()[0] or "casdoor"
        r = self.row
        if r is None or (r.idp or "") != DOMAIN_IDP_OWN:
            return "mesh"
        prov = str((r.idp_settings or {}).get("provider") or "casdoor")
        return prov if prov in SIGNIN_EXTERNAL else "casdoor"

    def signin_values(self) -> dict[str, str]:
        """The row's own provider values: sign-in address, client id, key address."""
        if self.own:
            _idp, issuer, client_id, jwks = self.writes().signin()
            return {"issuer": issuer, "client_id": client_id, "jwks": jwks}
        r = self.row
        st = dict((r.idp_settings or {}) if r is not None else {})
        return {k: str(st.get(k) or "") for k in ("issuer", "client_id", "jwks")}

    def set_signin(self, choice: str, issuer: str = "", client_id: str = "",
                   jwks: str = "") -> list[str]:
        """Write this domain's sign-in through ``set_domain_signin`` (the one writer).
        Returns the problems; nothing is written while there is one. On the mesh's own
        row the choice IS the mesh's sign-in: it is written where the Identity provider
        step keeps it (``MeshWrites.set_signin``), or refused with the reason on a route
        that keeps none."""
        if self.own:
            why = self.signin_refusal()
            if why:
                return [why]
            # the mesh's sign-in is not in the brand record: nothing for it to save
            return [_plain_signin(p) for p in
                    self.writes().set_signin(choice, issuer, client_id, jwks)]
        r = self.row
        if r is None:
            return [f"no domain named {self.name} on this screen"]
        keys = dict(SIGNIN_CHOICES)
        if choice not in keys:
            return [f"‘{choice}’ is not a sign-in choice "
                    f"({', '.join(k for k, _l in SIGNIN_CHOICES)})"]
        idp = DOMAIN_IDP_SUPERDOMAIN if choice == "mesh" else DOMAIN_IDP_OWN
        provider = choice if choice in SIGNIN_EXTERNAL else ""
        ext = choice in SIGNIN_EXTERNAL
        problems = set_domain_signin(
            r, idp, provider=provider, issuer=issuer.strip() if ext else "",
            client_id=client_id.strip() if ext else "", jwks=jwks.strip() if ext else "",
            mesh=self.mesh(), others=self._others())
        if not problems:
            self.session.touched = True
        return [_plain_signin(p) for p in problems]

    def signin_words(self) -> str:
        """One plain line: how this domain's people sign in now, and where that comes
        from (inherited from the mesh, or its own)."""
        row = Domain(name=self.name, idp=DOMAIN_IDP_SUPERDOMAIN) if self.own else self.row
        if row is None:
            return ""
        eff = effective_signin(row, self.mesh())
        what = PROVIDER_WORDS.get(eff.provider, eff.provider)
        if eff.source == SIGNIN_FROM_MESH and eff.provider == "casdoor":
            what = "the mesh's central Casdoor"
        at = f" at {eff.issuer}" if eff.issuer else ""
        # row 0 IS the mesh: its sign-in is not inherited from anything
        src = OWN_SOURCE_WORDS if self.own else SIGNIN_SOURCE_WORDS[eff.source]
        return f"{what}{at} — {src}"

    # ── 4b. Ways: Tor, VPN and egress, per domain ─────────────────────────────────
    def _set_ways(self, **kw) -> list[str]:
        """Write this brand's ways through ``brand_model.set_ways`` (the one writer)
        on the record, then put the result on the live row. [] = written. Row 0's
        ways are the mesh's: ``set_tor`` / ``set_egress`` write them through
        ``MeshWrites``, and nothing reaches here for row 0."""
        if self.own:
            return [OWN_REACH_HOME[:1].upper() + OWN_REACH_HOME[1:]]
        r = self.row
        if r is None:
            return [f"no domain named {self.name} on this screen"]
        rec = self.session.record()
        bid = brand_model.brand_id(r)
        problems = brand_model.set_ways(rec, bid, **kw)
        if problems:
            return problems
        new = rec.brand(bid)
        self.session.host.update_row(self.name, ways=dict(new.ways or {}),
                                     tor=bool(new.tor))
        self.session.touched = True
        return []

    def own_way_refusal(self, way: str) -> str:
        """Row 0: why the mesh's ``way`` ("tor", "tailnet" or "egress") cannot be
        changed here ("" = it can). The mesh's VPN never can: it is the mesh's whole
        posture, decided where ``vpn_where`` says."""
        w = self.writes()
        why = {"tor": w.tor_refusal, "egress": w.egress_refusal}.get(
            way, "the mesh's VPN is not chosen per domain: " + w.vpn_where)
        return (why[:1].upper() + why[1:]) if why else ""

    def tor_on(self) -> bool:
        if self.own:
            return bool(self.writes().tor())
        r = self.row
        return bool(getattr(r, "tor", False)) if r is not None else False

    def set_tor(self, on: bool) -> list[str]:
        if self.own:
            why = self.own_way_refusal("tor")
            if why:
                return [why]
            return self.writes().set_tor(bool(on))
        return self._set_ways(tor=bool(on))

    def tailnet_choice(self) -> str:
        if self.own:
            return "on" if domain_reach.mesh_tailnet_default(self.mesh()) else "off"
        r = self.row
        v = ((r.ways or {}).get(domain_reach.WAY_TAILNET)
             if (r is not None and not self.own) else None)
        if isinstance(v, bool):
            return "on" if v else "off"
        return domain_reach.REACH_INHERIT

    def set_tailnet(self, choice: str) -> list[str]:
        if self.own:
            return [self.own_way_refusal("tailnet")]
        val = {"on": True, "off": False,
               domain_reach.REACH_INHERIT: domain_reach.REACH_INHERIT}.get(choice)
        if val is None:
            return [f"‘{choice}’ is not a VPN choice (inherit, on, off)"]
        return self._set_ways(tailnet=val)

    def egress_choice(self) -> tuple[str, str]:
        """(inherit | vpn | direct, the provider file this domain names or ""); row 0:
        the mesh's own egress (vpn with its file, or direct)."""
        if self.own:
            return self.writes().egress()
        r = self.row
        v = ((r.ways or {}).get(domain_reach.WAY_EGRESS)
             if (r is not None and not self.own) else None)
        if isinstance(v, dict) and v.get("mode") in domain_reach.EGRESS_MODES:
            return v["mode"], str(v.get("conf") or "")
        return domain_reach.REACH_INHERIT, ""

    def set_egress(self, choice: str, conf: str = "") -> list[str]:
        if self.own:
            why = self.own_way_refusal("egress")
            if why:
                return [why]
            if choice == domain_reach.REACH_INHERIT:
                return ["This is the mesh's own domain, so there is nothing to inherit "
                        "from: choose the egress VPN (with its provider file) or direct"]
            return self.writes().set_egress(choice, conf)
        if choice == domain_reach.REACH_INHERIT:
            return self._set_ways(egress=domain_reach.REACH_INHERIT)
        if choice not in domain_reach.EGRESS_MODES:
            return [f"‘{choice}’ is not an egress choice (inherit, vpn, direct)"]
        block = {"mode": choice}
        if choice == domain_reach.EGRESS_VPN and conf.strip():
            block["conf"] = conf.strip()
        return self._set_ways(egress=block)

    def reach_effect(self) -> str:
        """What THIS route's start does with this domain's own VPN and egress — the
        sentence under the Ways controls, the same in the window and the text screen
        (core/reach_apply). The Docker route reads the mesh's controls as they stand
        and every row of the Domains step, so a choice made on another domain's tab
        (who runs Mastodon, who names which provider file) shows here at once."""
        if self.own:
            return OWN_REACH_HOME[:1].upper() + OWN_REACH_HOME[1:] + "."
        if self.client_image():
            # a client is not a node image: the image route's sentence ("a node
            # image's private network ...") would be wrong under the client line
            return CLIENT_REACH_EFFECT
        host = self.session.host
        route = getattr(host, "route", "") or ""
        if route != "docker":
            return reach_apply.ROUTE_NOT_APPLIED.get(route,
                                                     reach_apply.ROUTE_NOT_APPLIED[""])
        mesh = self.mesh()
        if mesh is None or not hasattr(mesh, "applied_egress"):
            return reach_apply.ROUTE_NOT_APPLIED[""]
        state = getattr(host, "state", None)
        if state is not None:
            rows = [dataclasses.asdict(d) for d in (state.domains or [])]
            own = (state.own_name or "").strip() or reach_apply.docker_own_name(mesh)
        else:
            rows = [dict(r) for r in (getattr(host.cfg, "domains", None) or ())
                    if isinstance(r, dict)]
            own = reach_apply.docker_own_name(mesh)
        cfg = dataclasses.replace(mesh, domains=tuple(rows))
        return reach_apply.docker_reach_notes(self.name, cfg, rows, own)

    def reach_lines(self) -> dict[str, str]:
        """{'tailnet': line, 'egress': line} in the model's words (row 0's values are
        the mesh's own, never 'inherited')."""
        row = Domain(name=self.name) if self.own else self.row
        if row is None:
            return {}
        words = domain_reach.reach_words(row, self.mesh())
        if self.own:
            words = {k: v.replace(domain_reach.REACH_FROM_MESH, OWN_SOURCE_WORDS)
                     for k, v in words.items()}
        return words

    # ── 2. Look ───────────────────────────────────────────────────────────────────
    def look_model(self) -> brand_look.Look | None:
        """The brand's override model; for the superbrand's own row, the superbrand's
        look itself (design mode — the session's own model, which the route binds to
        wherever it keeps the look: the image config's ``login_*`` fields, the Docker
        mesh's record and stylesheet). One model per brand for the session, so the
        window and the text screen edit the same object."""
        s = self.session
        if self.own:
            return s.look
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
        """Write the brand's overrides to its row (only what the record holds). For the
        superbrand's own row the edit is already in the session's look model (the route
        reads it from there); the session is marked changed when the look the record
        holds differs from the one last written, so leaving the step saves it."""
        m = self.look_model()
        if m is None:
            return
        if self.own:
            if self.session.record_look() != dict(self.session.sb.look or {}):
                self.session.touched = True
            return
        if self.row is None:
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
            eff = self.session.look.effective()
            out = ["The mesh's own look — every domain starts from it.", ""]
            for k in brand_model.LOOK_KEYS:
                out.append(f"   {k:<12}{eff.get(k) or '(shipped)'}")
            out += ["", LOOK_HOME]
            return out
        from ..core import look_serving
        gen = getattr(getattr(self.session, "host", None), "generator_dir", "") or ""
        # the image and Fleet routes: not applied there; the Docker mesh: served by
        # Host, or recorded only on a checkout whose front door does not serve it
        out = [look_serving.own_look_sentence(route, gen), ""]
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


def _plain_signin(sentence: str) -> str:
    """A model sentence in the words screens use ('sign-in address', never the word
    plain_words forbids on screens)."""
    return (sentence.replace("issuer URL", "sign-in address")
            .replace("issuer", "sign-in address").replace("Issuer", "Sign-in address"))


def identity_lines(view: BrandView) -> list[str]:
    out = [f"1. Identity — {view.label()}", ""]
    if view.client_image():
        out += [CLIENT_SIGNIN_NOTE, ""]
    for k, v in view.identity():
        out.append(f"   {k:<14}{v}")
    out += ["", view.identity_home(), ""]
    out.append(f"   Sign-in now   {view.signin_words()}")
    if view.own:
        why = view.signin_refusal()
        if why:
            out += ["", SIGNIN_MESH_HOME, "   " + why]
            return out
        out += ["", SIGNIN_MESH_EDIT]
    vals = view.signin_values()
    out.append("   choices       " + ", ".join(k for k, _l in view.signin_choices())
               + f" (now: {view.signin_choice()})")
    if view.signin_choice() in SIGNIN_EXTERNAL:
        out.append(f"   sign-in address  {vals['issuer'] or '(not set)'}")
        out.append(f"   client id        {vals['client_id'] or '(not set)'}")
        out.append(f"   key address      {vals['jwks'] or '(derived from the sign-in address)'}")
    out += ["", _signin_commands(view)]
    return out


def _signin_commands(view: BrandView) -> str:
    first = "signin casdoor" if view.own else "signin mesh | signin casdoor"
    return f"commands: {first} | signin entra|aws|oidc ADDRESS CLIENT-ID [KEY-ADDRESS]"


def feed_identity(view: BrandView, line: str) -> str:
    """One command of section 1 (the window's sign-in controls, as text). Returns the
    status sentence; nothing is written when it names a problem."""
    words = line.split()
    if not words or words[0].lower() != "signin":
        return _signin_commands(view)
    if len(words) < 2:
        return "signin needs a choice: " + ", ".join(k for k, _l in view.signin_choices())
    choice = words[1].lower()
    rest = words[2:]
    issuer = rest[0] if len(rest) > 0 else ""
    client = rest[1] if len(rest) > 1 else ""
    jwks = rest[2] if len(rest) > 2 else ""
    problems = view.set_signin(choice, issuer, client, jwks)
    if problems:
        return "Not changed: " + problems[0]
    return f"{view.name}: sign-in -> {view.signin_words()}"


def ways_lines(view: BrandView) -> list[str]:
    out = [f"4. Ways to reach it — {view.label()}", ""]
    if view.client_image():
        out += [CLIENT_WAYS_NOTE, ""]
    if view.own:
        mode, conf = view.egress_choice()
        tor_why = view.own_way_refusal("tor")
        egress_why = view.own_way_refusal("egress")
        out += ["   " + OWN_REACH_EDIT[:1].upper() + OWN_REACH_EDIT[1:] + ".", "",
                "   Tor address   " + ("on — the mesh's onion" if view.tor_on() else "off")
                + (f"   ({tor_why})" if tor_why else ""),
                f"   VPN           {view.tailnet_choice()}: "
                f"{view.own_way_refusal('tailnet')}",
                f"   egress        {mode}{(' ' + conf) if conf else ''}"
                + (f"   ({egress_why})" if egress_why else ""), ""]
        verbs = [v for v, why in (("tor on|off", tor_why),
                                  ("egress direct|vpn PROVIDER-FILE", egress_why)) if not why]
        if verbs:
            out += ["commands: " + " · ".join(verbs), ""]
    else:
        words = view.reach_lines()
        mode, conf = view.egress_choice()
        out += [f"   Tor address   {'on — its own onion' if view.tor_on() else 'off'}",
                f"   VPN           {view.tailnet_choice()}: "
                f"{words.get(domain_reach.WAY_TAILNET, '')}",
                f"   egress        {mode}{(' ' + conf) if conf else ''}: "
                f"{words.get(domain_reach.WAY_EGRESS, '')}",
                ""] + ["   " + p for p in view.reach_effect().split("\n")] + ["",
                "commands: tor on|off · vpn inherit|on|off · "
                "egress inherit|direct|vpn [PROVIDER-FILE]", ""]
    last = ""
    for way, value, path, effect in view.ways():
        if way != last:
            out.append(f"   {way}: {value}")
            last = way
        out.append(f"      {path}: {effect}")
    if not view.client_image():
        out += ["", WAYS_HOME, WAYS_TUI_LINE]
    return out


def feed_ways(view: BrandView, line: str) -> str:
    """One command of section 4 (the window's Ways controls, as text)."""
    words = line.split(None, 2)
    verb = words[0].lower() if words else ""
    arg = words[1].lower() if len(words) > 1 else ""
    if verb == "tor" and arg in ("on", "off"):
        problems = view.set_tor(arg == "on")
    elif verb == "vpn" and arg:
        problems = view.set_tailnet(arg)
    elif verb == "egress" and arg:
        conf = words[2] if len(words) > 2 else ""
        problems = view.set_egress(arg, conf)
    else:
        return ("commands: tor on|off · vpn inherit|on|off · "
                "egress inherit|direct|vpn [PROVIDER-FILE]"
                + ("" if view.client_image() else " · " + WAYS_GO_LIVE_COMMAND))
    if problems:
        return "Not changed: " + problems[0]
    w = view.reach_lines()
    return (f"{view.name}: Tor {'on' if view.tor_on() else 'off'}; VPN "
            f"{w.get(domain_reach.WAY_TAILNET, '')}; egress "
            f"{w.get(domain_reach.WAY_EGRESS, '')}")


def look_section_lines(view: BrandView, route: str) -> list[str]:
    """Section 2 as text: the look screen for a brand that can be edited, the read-only
    values where it cannot."""
    out = [f"2. Look — {view.label()}", ""]
    if view.client_image():
        out += [CLIENT_LOOK_NOTE, ""]
    out += view.look_lines(route)
    return out
