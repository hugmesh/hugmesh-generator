"""Proposed setting changes: parsed from the model, validated, applied on a press (Qt-free).

The model never changes anything. It may answer a request like "turn off the forum for
this domain" with one sentence and one fenced ```change block (core/assistant_prompt
CHANGE_FORMAT); :func:`parse_proposal` reads that block, :func:`validate` checks it
against the catalogue (core/assistant_catalogue) and the page's OWN validators
(brand_look.check_value, domain_reach, config.signin_problems), reads the current
value from the page (never from the model), refuses a no-op or a field this page does
not edit, and returns a :class:`Validated` change the face shows as a card:
``<label>: <from> -> <to>`` with Apply and Cancel. Only a press applies it.

TARGETS are thin adapters over the same objects the page uses, so Apply goes through
the page's own functions and its widgets show the new value:

* :class:`GuiTabsTarget` — a ``DomainServicesBody`` (image route: the wizard's page;
  Docker route: ``mesh_page.domain_services``). Readers: ``body.selected_slugs()``,
  ``body.tor_front_door()`` and the ``BrandView`` on ``body.brand_tabs.view``. Writers:
  the view's ``set_signin``/``set_tailnet``/``set_egress``/``set_tor``, its look model's
  ``choose_preset``/``hand_edit_colour``/``try_set`` then ``commit_look``, the Ways tab's
  ``tor_changed`` signal (the one route a click takes) and the Services tab's own
  check boxes (``body._boxes`` — an underscore attribute, accepted and covered by a test
  that fails loudly if it goes). After every apply ``brand_tabs.set_view(view)`` re-fills
  the visible widgets and ``row_changed``/``look_changed`` fire as after a click.
* :class:`TuiTarget` — the text UI's ``BrandView`` plus the ``config.Domain`` row the
  journey holds; services and Tor are written exactly as tui/domain_services_step does.
* :class:`MeshTarget` — the local-mesh page's own controls (``env_prod``, ``with_tor``,
  ``service_boxes``, ``web_locales``, ``superadmin``) through their Qt setters.

Re-read at Apply: :func:`validate` runs again against fresh readers; a ``from`` that
moved since the proposal is refused ("changed since I proposed this; ask again").
ONLY THE DOMAIN ON SCREEN: a proposal naming another domain is refused, and Apply or
Undo after the page moved to another domain is refused (the GUI target's ``domain`` is
read live from the page, as its readers and writers are). :func:`undo` puts the page
back exactly: look, egress and sign-in from a snapshot of the whole route taken before
the write (a preset fills three look fields; egress carries its provider file), the
rest by writing the before value back. One level per target AND domain (:func:`undo_key`).
"""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from . import assistant_catalogue as acat
from . import assistant_context as actxt
from . import config

__all__ = [
    "Proposal", "Validated", "Refusal", "Applied", "FIELD_ROUTES", "SYNONYMS", "parse_proposal",
    "normalise_value", "validate", "apply", "undo", "Target", "GuiTabsTarget", "TuiTarget",
    "MeshTarget", "RowTarget", "NO_BLOCK_HINT", "card_lines", "as_refusal", "current_values",
    "secret_request_note", "live_domain", "undo_key",
]

NO_BLOCK_HINT = "Say which setting and which value and I will propose the change."

#: key -> (scope, apply route). The allowlist of what the assistant may propose.
FIELD_ROUTES: dict = {
    "services": ("domain", "services"),
    "tor": ("domain", "tor"),
    "signin": ("domain", "signin"),
    "provider": ("domain", "signin"),
    "issuer": ("domain", "signin"),
    "client_id": ("domain", "signin"),
    "jwks": ("domain", "signin"),
    "tailnet": ("domain", "tailnet"),
    "egress": ("domain", "egress"),
    "look.preset": ("domain", "look"),
    "look.mode": ("domain", "look"),
    "look.primary": ("domain", "look"),
    "look.secondary": ("domain", "look"),
    "look.font": ("domain", "look"),
    "look.style": ("domain", "look"),
    "look.decor": ("domain", "look"),
    "look.bg_effect": ("domain", "look"),
    "env": ("mesh", "env"),
    "with_tor": ("mesh", "with_tor"),
    "services@mesh": ("mesh", "mesh_services"),
    "web_locales": ("mesh", "web_locales"),
    "superadmin_username": ("mesh", "superadmin_username"),
}

#: Words a person uses -> service slugs (built from the catalogue's own descriptions
#: plus the obvious nouns). "video" names both video services.
SYNONYMS: dict = {
    "forum": ("phpbb",), "phpbb": ("phpbb",), "boards": ("phpbb",),
    "chat": ("tuwunel",), "matrix": ("tuwunel",), "tuwunel": ("tuwunel",),
    "social": ("akkoma",), "fediverse": ("akkoma",), "akkoma": ("akkoma",), "mastodon": ("akkoma",),
    "video": ("owncast", "tube"), "live": ("owncast",), "streaming": ("owncast",),
    "owncast": ("owncast",), "tube": ("tube",), "peertube": ("tube",),
    "games": ("games",), "game": ("games",),
    "characters": ("character-studio",), "character-studio": ("character-studio",),
    "avatars": ("character-forge",), "character-forge": ("character-forge",),
}
_SIGNIN_WORDS = {"mesh": "superdomain", "superdomain": "superdomain", "inherited": "superdomain",
                 "own": "own", "casdoor": "own", "entra": "own", "aws": "own", "cognito": "own",
                 "oidc": "own"}
_PROVIDER_WORDS = {"casdoor": "casdoor", "entra": "entra", "azure": "entra", "aws": "aws",
                   "cognito": "aws", "oidc": "oidc", "other": "oidc"}
_FENCE_RE = re.compile(r"```change\s*\n(.*?)```", re.S)
#: The providers that carry a sign-in address and client id (tui/brand_step SIGNIN_EXTERNAL:
#: every IDP choice but Casdoor, which derives its own).
_EXTERNAL_PROVIDERS = tuple(p for p in config.IDP_CHOICES if p != "casdoor")


@dataclass(frozen=True)
class Proposal:
    domain: str
    field: str
    to: Any
    question: str = ""
    raw: str = ""


@dataclass(frozen=True)
class Validated:
    key: str
    label: str
    domain: str
    scope: str
    route: str
    before: Any
    after: Any
    extra: dict = field(default_factory=dict)       # sign-in: provider/issuer/client_id/jwks
    note: str = ""                                   # e.g. "pick the VPN file on the page"
    question: str = ""

    def row_text(self) -> str:
        return f"{self.label}: {_words(self.before)} -> {_words(self.after)}"


@dataclass(frozen=True)
class Refusal:
    text: str


@dataclass
class Applied:
    change: Validated
    before: Any
    after: Any
    target_id: str                                  # undo_key(target): the target AND its domain
    time: float = field(default_factory=time.time)
    snapshot: Any = None                            # the route's whole state before (see undo)
    after_snapshot: Any = None                      # ... and right after the write


def _words(v: Any) -> str:
    if isinstance(v, bool):
        return "on" if v else "off"
    if isinstance(v, (list, tuple, set, frozenset)):
        return ", ".join(str(x) for x in v) or "none"
    if v is None or v == "":
        return "not set"
    return str(v)


def as_refusal(problems) -> Optional[Refusal]:
    if isinstance(problems, Refusal):
        return problems
    if isinstance(problems, (list, tuple)):
        problems = [p for p in problems if p]
        return Refusal("Not applied: " + "; ".join(str(p) for p in problems)) if problems else None
    ok = getattr(problems, "ok", None)
    if ok is False:
        return Refusal("Not applied: " + (getattr(problems, "text", "") or "refused by the page"))
    return None


# ── parsing ──────────────────────────────────────────────────────────────────────────
def parse_proposal(answer: str, question: str = "") -> Optional[Proposal]:
    """The first ```change block as a Proposal, or None (a plain answer)."""
    m = _FENCE_RE.search(answer or "")
    if not m:
        return None
    try:
        data = json.loads(m.group(1).strip())
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    dom, fld, to = data.get("domain"), data.get("field"), data.get("to")
    if not isinstance(fld, str) or not isinstance(dom, str):
        return None
    if not isinstance(to, (str, bool, list, int, float)) or isinstance(to, float) and not to.is_integer():
        return None
    if isinstance(to, list) and not all(isinstance(x, str) for x in to):
        return None
    return Proposal(dom.strip(), fld.strip(), to, question, m.group(0))


# ── value normalisation ──────────────────────────────────────────────────────────────
def _bool(v: Any) -> Optional[bool]:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("on", "true", "yes", "1", "enabled"):
        return True
    if s in ("off", "false", "no", "0", "disabled"):
        return False
    return None


def _services(v: Any) -> "tuple[list, list]":
    """(slugs, unknown words) from a list or a comma/space string, through SYNONYMS."""
    from . import domain_services
    words = v if isinstance(v, list) else re.split(r"[,\s]+", str(v))
    out, bad = [], []
    for w in words:
        w = str(w).strip().lower().strip("'\"")
        if not w:
            continue
        if w in config.OPTIONAL_SERVICES_CHOICES:
            out.append(w)
        elif w in SYNONYMS:
            out += [s for s in SYNONYMS[w] if s not in out]
        elif w in ("none", "nothing", "no", "off"):
            continue
        else:
            bad.append(w)
    return domain_services.normalise_slugs(out), bad


def normalise_value(key: str, to: Any) -> "tuple[Any, str]":
    """``(normalised value, problem)`` for ``key``; problem "" when the value is fine."""
    from . import brand_look, domain_reach
    opt = acat.find(key.replace("@mesh", ""), "mesh" if key.endswith("@mesh") or
                    FIELD_ROUTES.get(key, ("",))[0] == "mesh" else "domain")
    if key in ("services", "services@mesh"):
        if key == "services":
            slugs, bad = _services(to)
            if bad:
                return None, (f"I do not know a service called {', '.join(bad)}. Valid values "
                              f"for services: {', '.join(config.OPTIONAL_SERVICES_CHOICES)}.")
            return slugs, ""
        want = to if isinstance(to, list) else re.split(r"[,\s]+", str(to))
        choices = acat.mesh_service_choices()
        bad = [w for w in want if w and w not in choices]
        if bad:
            return None, f"No mesh service called {', '.join(bad)}. Valid values: {', '.join(choices)}."
        return [w for w in choices if w in want], ""
    if key in ("tor", "with_tor"):
        b = _bool(to)
        return (b, "") if b is not None else (None, f"Valid values for {key}: on, off.")
    if key == "signin":
        s = _SIGNIN_WORDS.get(str(to).strip().lower())
        return (s, "") if s else (None, "Valid values for signin: superdomain, own.")
    if key == "provider":
        p = _PROVIDER_WORDS.get(str(to).strip().lower())
        return (p, "") if p else (None, f"Valid values for provider: {', '.join(config.IDP_CHOICES)}.")
    if key in ("issuer", "client_id", "jwks", "superadmin_username"):
        s = str(to).strip()
        if key == "superadmin_username" and not s:
            return None, "superadmin_username needs a name."
        return s, ""
    if key == "tailnet":
        s = str(to).strip().lower()
        if isinstance(to, bool):
            s = "on" if to else "off"
        if s in (domain_reach.REACH_INHERIT, "on", "off"):
            return s, ""
        return None, "Valid values for tailnet: inherit, on, off."
    if key == "egress":
        s = str(to).strip().lower()
        if s in (domain_reach.REACH_INHERIT,) + tuple(domain_reach.EGRESS_MODES):
            return s, ""
        return None, "Valid values for egress: inherit, vpn, direct."
    if key == "env":
        s = str(to).strip().lower()
        return (s, "") if s in config.ENV_CHOICES else (None, f"Valid values for env: {', '.join(config.ENV_CHOICES)}.")
    if key == "web_locales":
        want = to if isinstance(to, list) else re.split(r"[,\s]+", str(to))
        return [w.strip() for w in want if w.strip()], ""
    if key.startswith("look."):
        fld = key[len("look."):]
        if fld in ("preset", "mode", "style", "decor", "bg_effect", "font") and isinstance(to, str) \
                and opt is not None and opt.choices:
            plain = [c.split(" (")[0] for c in opt.choices]
            cand = str(to).strip()
            low = {c.lower(): c for c in plain}
            if cand.lower() in low:
                cand = low[cand.lower()]
            if cand not in plain:
                return None, f"Valid values for {key}: {', '.join(plain)}."
            if any(c.startswith(cand) and "not selectable" in c for c in opt.choices):
                return None, f"{cand} is saved but not selectable yet. Valid values for {key}: " + \
                    ", ".join(c for c in plain if not any(x.startswith(c) and "not selectable" in x for x in opt.choices)) + "."
            to = cand
        why = brand_look.check_value(fld, to)
        if why:
            return None, f"{why}. Valid values for {key}: {opt.choices_text() if opt else '#RRGGBB'}."
        return (str(to).strip() if isinstance(to, str) else to), ""
    return None, f"I cannot change {key}."


def _page_keys(where) -> "list[str]":
    try:
        opts = acat.options_for(where)
    except Exception:                        # noqa: BLE001
        return []
    keys = [o.key for o in opts if o.setter]
    slug = (getattr(where, "slug", "") or "")
    if slug in acat.MESH_PAGES and "services" in keys and slug != "localmesh_domain_services":
        keys = ["services@mesh" if k == "services" else k for k in keys]
    return keys


def _route_key(key: str, where) -> str:
    slug = (getattr(where, "slug", "") or "")
    if key == "services" and slug in acat.MESH_PAGES and slug != "localmesh_domain_services":
        return "services@mesh"
    return key


_CHANGE_VERB_RE = re.compile(r"\b(set|change|reset|update|use|make|put|give|switch|type|enter|fill)\b", re.I)
_SECRET_NOUN_RE = re.compile(r"\b(pass(word|phrase)?s?|passwd|secrets?|tokens?|api[ _-]?keys?|auth[ _-]?keys?|"
                             r"private keys?|keys?|unseal|kubeconfig|client[ _]secret|pins?)\b", re.I)


def secret_request_note(question: str, where, answer: str = "") -> str:
    """When the person asks to SET a password, key or token and the answer proposes
    nothing, the footer says so plainly (a small model may only say "I do not know"):
    the assistant never sets secrets, and these are the keys this page lets it change.
    "" otherwise. Deterministic; never depends on the model."""
    q = question or ""
    if not (_CHANGE_VERB_RE.search(q) and _SECRET_NOUN_RE.search(q)):
        return ""
    if "```change" in (answer or "") or "```diff" in (answer or ""):
        return ""
    keys = [k.replace("@mesh", "") for k in _page_keys(where)] if where is not None else []
    tail = (f" I can only change these on this page: {', '.join(keys)}." if keys else "")
    return ("I never set passwords, keys or tokens: you type those on the page itself, "
            "and they never reach me." + tail)


# ── validation ───────────────────────────────────────────────────────────────────────
def validate(proposal: Proposal, where, target: "Target | None") -> "Validated | Refusal":
    """Check ``proposal`` against the catalogue, the page's validators and the target's
    readers. A proposal for any domain but the one on screen is refused (its readers and
    writers act on the domain on screen)."""
    key = _route_key(proposal.field, where)
    allowed = _page_keys(where)
    shown = [k.replace("@mesh", "") for k in allowed]
    if key not in FIELD_ROUTES or key not in allowed:
        opt = acat.find(proposal.field)
        valid = f" Valid values for {proposal.field}: {opt.choices_text()}." if opt and opt.choices else ""
        return Refusal(f"I can only change these on this page: {', '.join(shown) or 'nothing'}.{valid}")
    scope, route = FIELD_ROUTES[key]
    if target is None:
        return Refusal("Open this domain's tabs first." if scope == "domain" else
                       "Change this on the screen.")
    if scope == "domain":
        on_screen = live_domain(target)
        asked = (proposal.domain or "").strip()
        if asked and on_screen and asked.lower() != on_screen.lower():
            # Never a write to a domain other than the one whose tabs are on screen:
            # every reader and writer here follows the page, so a proposal for another
            # row would land on this one (wrong-domain write, PR #832 review).
            return Refusal(f"I only change the domain on screen ({on_screen}). To change "
                           f"{asked}, open its tabs (Next domain) and ask there.")
        if getattr(target, "own", False) and route in ("signin", "tailnet", "egress"):
            return Refusal("The mesh's own sign-in and ways are set on the Identity provider "
                           "page and the mesh's own steps, not here.")
    value, problem = normalise_value(key, proposal.to)
    if problem:
        return Refusal(problem)
    opt = acat.find(key.replace("@mesh", ""), scope)
    label = opt.label if opt else key
    try:
        before = target.read(route if route != "look" else key, key)
    except LookupError as exc:
        return Refusal(str(exc) or "Open this domain's tabs first.")
    extra: dict = {}
    note = ""
    if route == "signin":
        cur = target.read("signin", "signin")            # {"choice", "provider", "issuer", ...}
        cur = dict(cur) if isinstance(cur, dict) else {}
        extra = {"choice": cur.get("choice", "superdomain"), "provider": cur.get("provider", "casdoor"),
                 "issuer": cur.get("issuer", ""), "client_id": cur.get("client_id", ""),
                 "jwks": cur.get("jwks", "")}
        before = cur.get({"signin": "choice"}.get(key, key), "")
        if key == "signin":
            # "its own Casdoor" / "its own Entra": the word names the provider too
            named = _PROVIDER_WORDS.get(str(proposal.to).strip().lower()) if value == "own" else None
            if named and cur.get("choice") == "own" and cur.get("provider") != named:
                # already its own sign-in, on another provider: the provider is what changes
                key, before, value = "provider", cur.get("provider", ""), named
                opt = acat.find("provider", scope)
                label = opt.label if opt else "provider"
                extra["provider"] = named
            else:
                extra["choice"] = value
                if value == "superdomain":
                    extra["provider"] = "casdoor"
                elif named:
                    extra["provider"] = named
        elif key == "provider":
            extra["choice"] = "own"
            extra["provider"] = value
        else:
            extra["choice"] = "own"
            extra[key] = value
            if extra["provider"] == "casdoor":
                return Refusal(f"{label} is only used by an external provider (entra, aws, oidc); "
                               "choose the provider first.")
        ext = extra["choice"] == "own" and extra["provider"] in _EXTERNAL_PROVIDERS
        if not ext:
            # The page's writer (BrandView.set_signin -> config.set_domain_signin) drops
            # the external values for the mesh's sign-in and for an own Casdoor; checking
            # the stale ones here refused "switch back to Casdoor" (PR #832 review, D2).
            extra.update(issuer="", client_id="", jwks="")
        else:
            # An external provider is checked with exactly the values the writer gets.
            r = as_refusal(config.signin_problems(extra["provider"], extra["issuer"],
                                                  extra["client_id"], extra["jwks"]))
            if r:
                if key in ("signin", "provider"):
                    return Refusal(r.text + ". Type the sign-in address and client id on "
                                   "the Identity tab first, then ask again.")
                return r
    if route == "egress" and value == "vpn":
        note = "pick the VPN file on the page"
    if _words(before) == _words(value) and route != "signin":
        return Refusal(f"Already set to {_words(value)}.")
    if route == "signin" and _words(before) == _words(value):
        return Refusal(f"Already set to {_words(value)}.")
    return Validated(key, label, getattr(target, "domain", "") or proposal.domain, scope, route,
                     before, value, extra, note, proposal.question)


def card_lines(v: "Validated | Refusal") -> "list[str]":
    """The plain lines a text face prints for a card."""
    if isinstance(v, Refusal):
        return [v.text]
    out = [f"Proposed change for {v.domain or 'this mesh'}:", f"  {v.row_text()}"]
    if v.note:
        out.append(f"  ({v.note})")
    out.append("type  apply  to make this change, or  cancel  (undo afterwards with  undo )")
    return out


# ── applying ─────────────────────────────────────────────────────────────────────────
def live_domain(target) -> str:
    """The domain the target's readers and writers act on NOW. The GUI target follows
    the page ("Next domain" moves it), so this is read at every check, never cached."""
    return str(getattr(target, "domain", "") or "").strip() if target is not None else ""


def undo_key(target) -> str:
    """The key a face files an :class:`Applied` under: the target AND its domain, so an
    undo on another domain's tabs finds nothing (one level per domain)."""
    return f"{getattr(target, 'id', '')}:{live_domain(target).lower()}"


def _domain_moved(v: Validated, target, verb: str) -> Optional[Refusal]:
    if v.scope != "domain" or not v.domain:
        return None
    now = live_domain(target)
    if now.lower() != v.domain.lower():
        return Refusal(f"This change is for {v.domain}, but the page now shows "
                       f"{now or 'no domain'}. Go back to {v.domain} to {verb} it; "
                       f"nothing was changed on {now or 'this page'}.")
    return None


def _snapshot(target, route: str, key: str):
    fn = getattr(target, "snapshot", None)
    if not callable(fn):
        return None
    try:
        return fn(route, key)
    except LookupError:
        return None


def apply(v: Validated, where, target: "Target") -> "Applied | Refusal":
    """Re-validate against fresh readers, then write through the target. The window
    thread owns this call in the GUI. Refused when the page moved to another domain
    since the proposal (the readers follow the page, so the write would land there)."""
    moved = _domain_moved(v, target, "apply")
    if moved:
        return moved
    fresh = validate(Proposal(v.domain, v.key.replace("@mesh", ""), v.after, v.question), where, target)
    if isinstance(fresh, Refusal):
        return fresh
    if _words(fresh.before) != _words(v.before):
        return Refusal(f"{v.label} changed to {_words(fresh.before)} since I proposed this; ask again.")
    snap = _snapshot(target, v.route, v.key)
    problems = target.write(v.route, v.key, v.after, fresh.extra)
    r = as_refusal(problems)
    if r:
        return r
    try:
        target.refresh(v.route)
    except Exception:                        # noqa: BLE001 — the write stood; the refresh is cosmetic
        pass
    return Applied(v, v.before, v.after, undo_key(target), snapshot=snap,
                   after_snapshot=_snapshot(target, v.route, v.key))


def undo(applied: Applied, where, target: "Target") -> "Applied | Refusal":
    """Put the page back exactly as it was before the apply, through the same setters.
    A route with a snapshot (look: the whole record, which a preset fills three fields
    of; egress: the mode AND its provider file; sign-in: choice, provider and values)
    is restored from it; the others write the before value back. Refused on another
    domain's tabs and when the value moved since the apply."""
    v = applied.change
    moved = _domain_moved(v, target, "undo")
    if moved:
        return moved
    if applied.snapshot is not None and callable(getattr(target, "restore", None)):
        now = _snapshot(target, v.route, v.key)
        if now is None:
            return Refusal("Nothing to undo: open this domain's tabs first.")
        if now != applied.after_snapshot:
            return Refusal(f"{v.label} changed since I applied this; nothing undone.")
        problems = target.restore(v.route, v.key, applied.snapshot)
    elif v.route == "signin":
        extra = dict(v.extra)
        cur = target.read("signin", "signin")
        if not isinstance(cur, dict):
            return Refusal("Nothing to undo: open this domain's tabs first.")
        back_extra = {"choice": applied.before if v.key == "signin" else cur.get("choice"),
                      "provider": applied.before if v.key == "provider" else extra.get("provider", "casdoor"),
                      "issuer": cur.get("issuer", ""), "client_id": cur.get("client_id", ""),
                      "jwks": cur.get("jwks", "")}
        if v.key == "signin" and applied.before == "superdomain":
            back_extra["provider"] = "casdoor"
        if v.key in ("issuer", "client_id", "jwks"):
            back_extra[v.key] = applied.before
        problems = target.write("signin", v.key, applied.before, back_extra)
    else:
        try:
            now = target.read(v.route if v.route != "look" else v.key, v.key)
        except LookupError as exc:
            return Refusal("Nothing to undo: " + (str(exc) or "the domain is gone."))
        if _words(now) != _words(applied.after):
            return Refusal(f"{v.label} changed to {_words(now)} since I applied this; nothing undone.")
        problems = target.write(v.route, v.key, applied.before, {})
    r = as_refusal(problems)
    if r:
        return r
    try:
        target.refresh(v.route)
    except Exception:                        # noqa: BLE001
        pass
    undone = Validated(v.key, v.label, v.domain, v.scope, v.route, applied.after, applied.before,
                       v.extra, "", v.question)
    return Applied(undone, applied.after, applied.before, undo_key(target))


def current_values(target, where=None) -> "tuple[tuple[str, str], ...]":
    """``((option key, value on screen), ...)`` read through the SAME readers
    :func:`validate` uses, so the Options block can say ``current: ...`` and a request
    like "turn the forum off" or "a darker purple" starts from what the page shows.
    Window thread (widget reads). A reader that raises is skipped; values pass
    :func:`assistant_context.scrub_rows` (secret keys never shown)."""
    if target is None:
        return ()
    rows: list = []
    signin = None
    for key, (scope, route) in FIELD_ROUTES.items():
        if (scope == "mesh") != isinstance(target, MeshTarget):
            continue
        try:
            if route == "signin":
                if signin is None:
                    signin = dict(target.read("signin", "signin") or {})
                value = signin.get({"signin": "choice"}.get(key, key), "")
            else:
                value = target.read(route if route != "look" else key, key)
        except Exception:                    # noqa: BLE001 — a reader that cannot answer is left out
            continue
        if isinstance(value, (list, tuple, set, frozenset)):
            value = ", ".join(str(x) for x in value) or "none"
        elif isinstance(value, bool):
            value = "on" if value else "off"
        elif value in (None, ""):
            value = "not set (inherited)" if key.startswith("look.") else "not set"
        rows.append((key.replace("@mesh", ""), str(value)))
    return actxt.scrub_rows(rows)


# ── targets ──────────────────────────────────────────────────────────────────────────
class Target:
    """What a face hands :func:`validate`/:func:`apply`: readers and writers over the
    page's own objects. ``read`` raises LookupError when there is nothing on screen."""
    id = "target"
    domain = ""
    own = False

    def read(self, route: str, key: str):
        raise LookupError("nothing on screen")

    def write(self, route: str, key: str, value, extra: dict):
        return ["this target cannot write"]

    def refresh(self, route: str) -> None:
        pass

    def snapshot(self, route: str, key: str):
        """The route's whole state for an exact undo, or None (undo writes ``before``)."""
        return None

    def restore(self, route: str, key: str, snap):
        return ["this target cannot restore"]


def _signin_read(view) -> dict:
    choice = view.signin_choice()
    vals = view.signin_values()
    if choice == "mesh":
        return {"choice": "superdomain", "provider": "casdoor", **vals}
    return {"choice": "own", "provider": choice, **vals}


def _signin_write(view, extra: dict):
    choice = "mesh" if extra.get("choice") == "superdomain" else (extra.get("provider") or "casdoor")
    return view.set_signin(choice, extra.get("issuer", ""), extra.get("client_id", ""),
                           extra.get("jwks", ""))


def _look_read(view, key: str):
    m = view.look_model()
    if m is None:
        raise LookupError("this domain has no look to edit here")
    fld = key[len("look."):]
    rec = m.record()
    return rec.get(fld, "") or ""


def _look_write(view, key: str, value):
    m = view.look_model()
    if m is None:
        return ["this domain has no look to edit here"]
    fld = key[len("look."):]
    if fld == "preset" and value:
        out = m.choose_preset(str(value))
    elif fld in ("primary", "secondary"):
        out = m.hand_edit_colour(fld, str(value))
    else:
        out = m.try_set(fld, value)
    if getattr(out, "ok", True):
        view.commit_look()
    return out


_MISSING = object()


def _look_restore(view, snap: dict):
    """Put the look record back to ``snap`` through the model's own verbs: a field the
    snapshot did not hold goes back to the superbrand's (``use_superbrand``), a field it
    held is set again (``try_set``; the raw ``set`` only when an override equal to the
    inherited value would otherwise be dropped). Then ``commit_look`` as after a click."""
    m = view.look_model()
    if m is None:
        return ["this domain has no look to edit here"]
    for fld in [f for f in m.record() if f not in snap]:
        m.use_superbrand(fld)
    for fld, val in snap.items():
        if m.record().get(fld, _MISSING) == val:
            continue
        out = m.try_set(fld, val)
        if not getattr(out, "ok", True):
            return [getattr(out, "text", "") or f"{fld} could not be put back"]
        if m.record().get(fld, _MISSING) != val:
            m.set(fld, val)
    view.commit_look()
    return []


class RowTarget(Target):
    """Readers and writers over a ``BrandView`` (shared by the GUI and TUI targets);
    services and Tor are added by the subclass that knows where they live."""

    def __init__(self, view, domain: str = ""):
        self.view = view
        self.domain = domain or (getattr(view, "name", "") if view is not None else "")
        self.own = bool(getattr(view, "own", False)) if view is not None else False

    def _view(self):
        if self.view is None:
            raise LookupError("Open this domain's tabs first.")
        return self.view

    def read(self, route: str, key: str):
        v = self._view()
        if route == "signin":
            return _signin_read(v)
        if route == "tailnet":
            return v.tailnet_choice()
        if route == "egress":
            return v.egress_choice()[0]
        if route == "tor":
            return v.tor_on()
        if key.startswith("look."):
            return _look_read(v, key)
        raise LookupError(f"no reader for {key}")

    def write(self, route: str, key: str, value, extra: dict):
        v = self._view()
        if route == "signin":
            return _signin_write(v, extra)
        if route == "tailnet":
            return v.set_tailnet(value)
        if route == "egress":
            return v.set_egress(value, "")
        if route == "tor":
            return v.set_tor(bool(value))
        if route == "look":
            return _look_write(v, key, value)
        return [f"no writer for {key}"]

    def snapshot(self, route: str, key: str):
        v = self._view()
        if route == "look":
            m = v.look_model()
            return dict(m.record()) if m is not None else None
        if route == "egress":
            return tuple(v.egress_choice())
        if route == "signin":
            return dict(_signin_read(v))
        return None

    def restore(self, route: str, key: str, snap):
        v = self._view()
        if route == "look":
            return _look_restore(v, dict(snap))
        if route == "egress":
            mode, conf = snap
            return v.set_egress(mode, conf)
        if route == "signin":
            return _signin_write(v, dict(snap))
        return [f"no exact undo for {key}"]


class GuiTabsTarget(RowTarget):
    """Over a ``DomainServicesBody`` with its brand tabs (see the module docstring)."""

    id = "gui-tabs"

    def __init__(self, body):
        self.body = body
        tabs = getattr(body, "brand_tabs", None)
        super().__init__(getattr(tabs, "view", None), "")

    @property
    def domain(self) -> str:
        """LIVE: the domain the page shows now. Every reader and writer here follows the
        page ("Next domain" moves them), so the domain they are checked against must too;
        a copy taken at construction let Apply and Undo land on the next domain."""
        try:
            return (self.body.current_domain() or "") if self.body is not None else ""
        except RuntimeError:                     # the page was closed
            return ""

    @domain.setter
    def domain(self, _value) -> None:
        pass                                     # RowTarget.__init__ assigns; the page decides

    def _view(self):
        tabs = getattr(self.body, "brand_tabs", None)
        self.view = getattr(tabs, "view", None)
        if self.view is None:
            raise LookupError("Open this domain's tabs first.")
        self.own = bool(getattr(self.view, "own", False))
        return self.view

    def read(self, route: str, key: str):
        self._view()                             # no tabs on screen: nothing is proposed
        if route == "services":
            return list(self.body.selected_slugs())
        if route == "tor":
            return bool(self.body.tor_front_door())
        return super().read(route, key)

    def write(self, route: str, key: str, value, extra: dict):
        if route == "services":
            boxes = getattr(self.body, "_boxes", None)
            if not boxes:
                return ["this domain's services are not on screen"]
            want = set(value or ())
            missing = [s for s in want if s not in boxes]
            if missing:
                return [f"{', '.join(missing)} is not offered on this page"]
            for slug, box in boxes.items():
                box.setChecked(slug in want)
            self.body._capture()
            return []
        if route == "tor":
            v = self._view()
            if v.own:
                return v.set_tor(bool(value))
            self.body.brand_tabs.tor_changed.emit(bool(value))
            return []
        return super().write(route, key, value, extra)

    def refresh(self, route: str) -> None:
        tabs = self.body.brand_tabs
        if tabs.view is not None:
            tabs.set_view(tabs.view)
        if route == "look":
            tabs.look_changed.emit()
        elif route in ("signin", "tailnet", "egress", "tor"):
            tabs.row_changed.emit()
        for name in ("_paint_tor_note", "_refresh_plan"):
            fn = getattr(self.body, name, None)
            if callable(fn):
                try:
                    fn()
                except Exception:            # noqa: BLE001 — cosmetic
                    pass


class TuiTarget(RowTarget):
    """The text UI's view plus the Domain row it edits (services and Tor are written
    as tui/domain_services_step writes them)."""

    id = "tui"

    def __init__(self, view, row, own_name: str = ""):
        super().__init__(view, getattr(row, "name", "") or (getattr(view, "name", "") if view else ""))
        self.row = row
        if row is not None and own_name and getattr(row, "name", "") == own_name:
            self.own = True

    def read(self, route: str, key: str):
        if self.row is None and route in ("services", "tor"):
            raise LookupError("no domain on this screen")
        if route == "services":
            from . import domain_services
            return domain_services.normalise_slugs(self.row.optional_services)
        if route == "tor":
            return bool(getattr(self.row, "tor", False))
        return super().read(route, key)

    def write(self, route: str, key: str, value, extra: dict):
        if route == "services":
            from . import domain_services
            self.row.optional_services = domain_services.normalise_slugs(value)
            return []
        if route == "tor":
            if self.own:
                return [f"{self.row.name} is this mesh's own domain — its front door is the "
                        "mesh's own onion; nothing to toggle"]
            self.row.tor = bool(value)
            return []
        return super().write(route, key, value, extra)


class MeshTarget(Target):
    """The local-mesh page's controls (Docker route, mesh-level keys)."""

    id = "mesh-page"

    def __init__(self, page):
        self.page = page
        self.domain = ""

    def read(self, route: str, key: str):
        p = self.page
        if p is None:
            raise LookupError("no local-mesh page in this window")
        if route == "env":
            return "prod" if p.env_prod.isChecked() else "test"
        if route == "with_tor":
            return bool(p.with_tor.isChecked())
        if route == "mesh_services":
            return [s for s, b in p.service_boxes.items() if b.isChecked()]
        if route == "web_locales":
            return [w for w in re.split(r"[,\s]+", p.web_locales.text()) if w]
        if route == "superadmin_username":
            return p.superadmin.text().strip() or "superadmin"
        raise LookupError(f"no reader for {key}")

    def write(self, route: str, key: str, value, extra: dict):
        p = self.page
        if route == "env":
            (p.env_prod if value == "prod" else p.env_test).setChecked(True)
            return []
        if route == "with_tor":
            p.with_tor.setChecked(bool(value))
            return []
        if route == "mesh_services":
            missing = [s for s in value if s not in p.service_boxes]
            if missing:
                return [f"{', '.join(missing)} is not offered on this page"]
            for slug, box in p.service_boxes.items():
                box.setChecked(slug in value)
            return []
        if route == "web_locales":
            p.web_locales.setText(", ".join(value))
            return []
        if route == "superadmin_username":
            p.superadmin.setText(str(value))
            return []
        return [f"no writer for {key}"]

    def refresh(self, route: str) -> None:
        fn = getattr(self.page, "_refresh_plan", None)
        if callable(fn):
            fn()
