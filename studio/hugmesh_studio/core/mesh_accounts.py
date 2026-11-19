"""People on the RUNNING local mesh, per domain — created straight through Casdoor's
admin API, with no e2e script in the path.

WHY THIS EXISTS. Adding a person used to mean re-running the e2e seeder
(``make stack-seed`` with ``EXTRA_ROLE_USERS`` appended, ``tests/stack/seed-e2e.sh``
-> ``tests/qemu/seed-accounts.sh``). That works only from a checkout that carries the
test scripts, re-applies every e2e persona to add one account, drags the run's shared
E2E password into an operator's account, and its role catalogue was parsed out of
seed-e2e.sh (an installed Studio without it offered ROLE_USER only). An operator adding
a real person to a real domain needs none of that. This module is the whole apply:

  1. sign in as the Casdoor admin with this checkout's ``CASDOOR_ADMIN_PASSWORD``
     (exported ``CASDOOR_ADMIN_PASS`` wins; else ``tests/stack/.env``, READ ONLY);
     a Casdoor whose admin still has the factory password is moved onto it first and
     both sides are proven (the seed's ``casdoor_admin_session``, LEG 0 for the
     per-domain Casdoors), so a domain's Casdoor started after the last seed works too;
  2. make sure the organization and the granted role objects exist (a fresh per-domain
     Casdoor has neither);
  3. add the account (refusing a name that is already taken: this never re-passwords
     somebody), set its password and PROVE it through Casdoor's own already-current
     refusal, the only read-back a password has;
  4. ADD the account to each granted role's member list (never replacing the list) and
     read every role back.

WHICH CASDOOR. A domain signs in either through the mesh (the central Casdoor on
:8000, shared by every domain that inherits it, and by the mesh's own domain), through
its OWN Casdoor (one per domain, published at the port the generated
``tests/stack/.compose.own-domains.yaml`` gives it — the file the running containers
were started from), or through an external provider (Entra ID, Cognito, OIDC), where
the mesh keeps no accounts and adding one here is refused with that reason.
On the central Casdoor the domain is recorded on the account
(``properties.hugmesh_domain``) so the domain's list can show its own people; nothing
enforces it there yet, and the screens say so.

THE SEEDER KEEPS THESE ACCOUNTS. ``apply-systems-roles.sh`` used to set each role to
EXACTLY its rendered persona list, which would have stripped every role granted here
at the next ``make stack-seed``. It now manages only the members it renders and keeps
the rest (tests/qemu/seed-accounts.sh, the same change).

Secrets: the admin password and the person's password travel in request bodies only;
neither is ever logged, returned in a message, or put in argv. Qt-free; every network
call goes through one ``opener`` a test can replace.
"""
from __future__ import annotations

import http.cookiejar
import json
import os
import re
import secrets
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

from .config import has_external_signin, runs_own_casdoor

__all__ = ["GRANTABLE_ROLES", "FLOOR_ROLE", "ROLE_WORDS", "Target", "Account",
           "Outcome", "CasdoorError", "CasdoorAdmin", "username_problem",
           "password_problem", "generate_password", "admin_password", "target_for",
           "own_casdoor_port", "create_account", "list_accounts",
           "complete_registration", "DOMAIN_PROPERTY"]

#: The organization every mesh Casdoor keeps its people in (seed-e2e.sh CASDOOR_ORG;
#: the per-domain Casdoors use the same name — compose.brand-b.yaml's proof).
ORG = "hugmesh"
ADMIN_USER = "admin"
#: casbin/casdoor's public factory password for the built-in admin of an empty
#: database (upstream docs; seed-e2e.sh CASDOOR_BOOTSTRAP_PASSWORD). Used only to take
#: such an admin over, exactly once, never left behind.
FACTORY_ADMIN_PASSWORD = "123"
CENTRAL_URL = "http://127.0.0.1:8000"
ENV_FILE_REL = os.path.join("tests", "stack", ".env")
OVERLAY_REL = os.path.join("tests", "stack", ".compose.own-domains.yaml")
ADMIN_ENV_KEY = "CASDOOR_ADMIN_PASSWORD"
#: the sign-in application the mesh's BFF uses (seed-e2e.sh CASDOOR_APP_CLIENT_ID)
APP_CLIENT_ID = "app-user-bff"
#: where the central Casdoor records which domain an account belongs to
DOMAIN_PROPERTY = "hugmesh_domain"

#: The roles a person can be given here: seed-e2e.sh LOCAL_OPERATOR_ROLES, the
#: broadest directly-grantable set. Derived roles (ROLE_GAMES_ADMIN, ROLE_FORUM_MOD)
#: are filled by reconcile jobs; the *_DOMAINLOCKED / *_EXTERNAL_CLIENT markers take
#: capability away. Spelled here so no script has to be present to offer them;
#: studio/tests/test_mesh_accounts.py keeps the two lists equal.
GRANTABLE_ROLES = ("ROLE_USER", "ROLE_ADMIN", "ROLE_MOD", "ROLE_MATRIX",
                   "ROLE_MASTODON", "ROLE_FORUM", "ROLE_WIKI", "ROLE_GAMES",
                   "ROLE_FLEET_ADMIN", "ROLE_SUPERADMIN")
#: every account holds it: the gateway refuses a principal without it
FLOOR_ROLE = "ROLE_USER"
#: plain words for each role, for the screens
ROLE_WORDS = {
    "ROLE_USER": "a member (signs in; the floor every account has)",
    "ROLE_ADMIN": "an administrator (opens Admin)",
    "ROLE_MOD": "a moderator (opens Moderation)",
    "ROLE_MATRIX": "chat (opens Matrix)",
    "ROLE_MASTODON": "social (opens Mastodon)",
    "ROLE_FORUM": "the forum",
    "ROLE_WIKI": "the wiki",
    "ROLE_GAMES": "games",
    "ROLE_FLEET_ADMIN": "fleet administration",
    "ROLE_SUPERADMIN": "a superadmin (the whole mesh)",
}

_LEGAL_NAME = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$")
_BAD_PAIRS = ("--", "__", "-_", "_-")
LOCKOUT_MARKER = "too many times"
PASSWORD_ALREADY_SET = "must be different from your current password"
MIN_PASSWORD = 8
TIMEOUT_S = 15


class CasdoorError(Exception):
    """A refusal or failure, worded for the screen. Never carries a secret."""


# ── the inputs ───────────────────────────────────────────────────────────────────────
def username_problem(name: str) -> str:
    """Why ``name`` cannot be a Casdoor account name ("" = it can): Casdoor's legal
    name (seed-accounts.sh casdoor_legal_name), with the doubled separators it
    refuses. An email-shaped name is refused too: the address goes in the email box."""
    name = (name or "").strip()
    if not name:
        return "Type a user name."
    if "@" in name:
        return ("A user name cannot be an email address; put the address in the "
                "email box and give the person a short name.")
    if len(name) > 39:
        return "A user name is at most 39 characters."
    if not _LEGAL_NAME.match(name) or any(p in name for p in _BAD_PAIRS):
        return ("A user name is letters and digits, with - or _ only between them "
                "(never two in a row, never at either end).")
    return ""


def password_problem(password: str) -> str:
    if len(password or "") < MIN_PASSWORD:
        return f"A password is at least {MIN_PASSWORD} characters."
    if any(c.isspace() for c in password):
        return "A password cannot contain spaces."
    return ""


def generate_password() -> str:
    """20 characters from [A-Za-z0-9_-] (form- and dotenv-safe)."""
    return secrets.token_urlsafe(15)


def admin_password(generator_dir: str, env=None) -> str:
    """This checkout's Casdoor admin password: an exported ``CASDOOR_ADMIN_PASS``, else
    ``CASDOOR_ADMIN_PASSWORD`` from ``tests/stack/.env`` (read, never written: that file
    is gen-casdoor-admin-env.sh's to create). "" when neither has one."""
    src = os.environ if env is None else env
    val = str(src.get("CASDOOR_ADMIN_PASS") or "").strip()
    if val:
        return val
    path = os.path.join(generator_dir or "", ENV_FILE_REL)
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and key.strip() == ADMIN_ENV_KEY:
                    return value.strip().strip("'\"")
    except OSError:
        pass
    return ""


# ── which Casdoor a domain's people live in ──────────────────────────────────────────
@dataclass(frozen=True)
class Target:
    """One Casdoor a domain's people live in."""
    url: str
    domain: str
    #: True for the mesh's central Casdoor (shared by every inheriting domain)
    central: bool
    #: what the screens say about where the accounts go
    words: str
    #: an HTTPS door's CA bundle ("" = plain http on loopback)
    cafile: str = ""


def own_casdoor_port(generator_dir: str, domain: str) -> int:
    """The host port the RUNNING mesh publishes ``domain``'s own Casdoor at, read from
    the overlay the containers were started from (each service carries the domain in
    its ``hugmesh.net/domain`` label and publishes ``…:<port>:8000``). 0 = none."""
    path = os.path.join(generator_dir or "", OVERLAY_REL)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return 0
    label = f'"hugmesh.net/domain": "{domain}"'
    for block in re.split(r"\n(?=  [A-Za-z0-9][^\n]*:\n)", text):
        if label not in block or "-db:" in block.split("\n", 1)[0]:
            continue
        m = re.search(r':(\d+):8000"', block)
        if m:
            return int(m.group(1))
    return 0


def target_for(domain: str, row, generator_dir: str, *, own: bool = False,
               env=None) -> tuple[Target | None, str]:
    """(Target, "") for the Casdoor ``domain``'s people live in, or (None, why not).
    ``row`` is the domain's Domain row (None on the mesh's own row, ``own=True``)."""
    src = os.environ if env is None else env
    central = str(src.get("CASDOOR_URL") or "").strip() or CENTRAL_URL
    domain = (domain or "").strip()
    if own or row is None or not (runs_own_casdoor(row) or has_external_signin(row)):
        return Target(central, domain, True,
                      "the mesh's central sign-in (its Casdoor), which every domain "
                      "that signs in through the mesh shares; the account is marked "
                      "with this domain"), ""
    if has_external_signin(row):
        prov = str((getattr(row, "idp_settings", None) or {}).get("provider") or "")
        return None, (f"{domain} signs in through its own {prov or 'external'} "
                      "provider, which keeps its people: add the person there. The mesh "
                      "has no accounts of its own for this domain.")
    port = own_casdoor_port(generator_dir, domain)
    if not port:
        return None, (f"{domain} has its own sign-in, but the running mesh has not "
                      "started a Casdoor for it (there is none in "
                      f"{OVERLAY_REL}). Start the mesh with this domain, then add "
                      "people.")
    return Target(f"http://127.0.0.1:{port}", domain, False,
                  f"{domain}'s own Casdoor (port {port}), which only this domain uses"), ""


# ── the client ───────────────────────────────────────────────────────────────────────
def _opener(cafile: str = ""):
    jar = http.cookiejar.CookieJar()
    handlers = [urllib.request.HTTPCookieProcessor(jar)]
    if cafile:
        handlers.append(urllib.request.HTTPSHandler(
            context=ssl.create_default_context(cafile=cafile)))
    # a proxy in the environment must never see a loopback admin session
    handlers.append(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(*handlers)


class CasdoorAdmin:
    """An admin session on one Casdoor. Every call is checked for Casdoor's envelope:
    a denied call answers HTTP 200 with ``status: error``, which is how an unseeded run
    once looked successful."""

    def __init__(self, url: str, *, org: str = ORG, opener=None, cafile: str = "",
                 timeout: float = TIMEOUT_S):
        self.url = url.rstrip("/")
        self.org = org
        self.timeout = timeout
        self._new_opener = (lambda: opener) if opener is not None else (
            lambda: _opener(cafile))
        self._op = self._new_opener()

    # transport
    def _raw(self, method: str, path: str, *, body=None, form=None, op=None) -> dict:
        data, headers = None, {}
        if body is not None:
            data = json.dumps(body).encode()
            headers["content-type"] = "application/json"
        elif form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["content-type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(self.url + path, data=data, method=method,
                                     headers=headers)
        what = f"{method} {path.split('?', 1)[0]}"
        try:
            with (op or self._op).open(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise CasdoorError(f"Casdoor at {self.url} answered {what} with HTTP "
                               f"{e.code}.") from None
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise CasdoorError(f"Casdoor at {self.url} did not answer ({reason}). Is "
                               "the mesh running?") from None
        try:
            out = json.loads(raw.decode("utf-8", "replace") or "{}")
        except ValueError:
            raise CasdoorError(f"Casdoor at {self.url} answered {what} with something "
                               "that is not JSON.") from None
        if not isinstance(out, dict):
            raise CasdoorError(f"Casdoor at {self.url} answered {what} with an "
                               "unexpected shape.")
        return out

    def _ok(self, method: str, path: str, **kw):
        out = self._raw(method, path, **kw)
        if out.get("status") != "ok":
            raise CasdoorError(f"Casdoor refused {method} {path.split('?', 1)[0]}: "
                               f"{out.get('msg') or 'no message'}.")
        return out.get("data")

    # the admin session
    def _try_login(self, password: str, op=None) -> tuple[bool, str]:
        out = self._raw("POST", "/api/login", op=op, body={
            "application": "app-built-in", "organization": "built-in",
            "username": ADMIN_USER, "password": password, "type": "login",
            "autoSignin": True})
        if out.get("status") != "ok":
            return False, str(out.get("msg") or "")
        acct = self._raw("GET", "/api/get-account", op=op)
        data = acct.get("data") if isinstance(acct.get("data"), dict) else acct
        if (data or {}).get("name") != ADMIN_USER:
            raise CasdoorError(f"Casdoor at {self.url} accepted the admin login, but the "
                               "session is not the admin's. Nothing was changed.")
        return True, ""

    def login(self, password: str, on_line=None) -> None:
        """An admin session for ``password``, first moving an admin still on the
        factory password onto it (and proving both sides). Raises CasdoorError."""
        if not password:
            raise CasdoorError(
                "This checkout has no Casdoor admin password yet (CASDOOR_ADMIN_PASSWORD "
                f"in {ENV_FILE_REL}). Start the mesh from the Studio once: its start "
                "writes it and moves the sign-in's admin onto it.")
        if password == FACTORY_ADMIN_PASSWORD:
            raise CasdoorError("The Casdoor admin password is the public factory one; "
                               "refusing to use it.")
        ok, msg = self._try_login(password)
        if ok:
            return
        if LOCKOUT_MARKER in msg.lower():
            raise CasdoorError(f"Casdoor at {self.url} is refusing every admin sign-in "
                               f"for now ({msg}). That is its throttle, not a wrong "
                               "password: wait the minutes it names, then try again.")
        ok, msg2 = self._try_login(FACTORY_ADMIN_PASSWORD)
        if not ok:
            if LOCKOUT_MARKER in msg2.lower():
                raise CasdoorError(f"Casdoor at {self.url} is throttling admin sign-ins "
                                   f"({msg2}); wait, then try again.")
            raise CasdoorError(
                f"Casdoor at {self.url} refused this checkout's admin password and its "
                "factory one, so its admin was moved onto a value this checkout does not "
                f"hold. Put that value back in {ENV_FILE_REL} (CASDOOR_ADMIN_PASSWORD) or "
                "export CASDOOR_ADMIN_PASS. Nothing was changed.")
        if on_line:
            on_line(f"[people] {self.url}: the admin still had the factory password; "
                    "moving it onto this checkout's value")
        self._ok("POST", "/api/set-password", form={
            "userOwner": "built-in", "userName": ADMIN_USER,
            "oldPassword": FACTORY_ADMIN_PASSWORD, "newPassword": password})
        # a scratch session (a fresh cookie jar), so the probe cannot clobber this one
        still, _ = self._try_login(FACTORY_ADMIN_PASSWORD, op=self._new_opener())
        if still:
            raise CasdoorError(f"Casdoor at {self.url} said ok to the admin move, but the "
                               "factory password still signs in. Nothing else was done.")
        ok, _ = self._try_login(password)
        if not ok:
            raise CasdoorError(f"Casdoor at {self.url} moved its admin, but this "
                               "checkout's password does not sign in afterwards.")

    # the organization and its roles
    def ensure_org(self) -> None:
        if self._ok("GET", f"/api/get-organization?id=admin/{self.org}"):
            return
        self._ok("POST", "/api/add-organization", body={
            "owner": "admin", "name": self.org, "displayName": self.org,
            "passwordType": "plain", "tags": [], "languages": [], "initScore": 2000,
            "enableSoftDeletion": False, "isProfilePublic": True})
        if not self._ok("GET", f"/api/get-organization?id=admin/{self.org}"):
            raise CasdoorError(f"Casdoor at {self.url} did not keep the organization "
                               f"{self.org}.")

    def ensure_role(self, role: str) -> None:
        if self._ok("GET", f"/api/get-role?id={self.org}/{role}"):
            return
        self._ok("POST", "/api/add-role", body={
            "owner": self.org, "name": role, "displayName": role, "users": [],
            "roles": [], "isEnabled": True})
        if not self._ok("GET", f"/api/get-role?id={self.org}/{role}"):
            raise CasdoorError(f"Casdoor at {self.url} did not keep the role {role}.")

    def has_app(self) -> bool:
        try:
            return bool(self._ok("GET", f"/api/get-application?id=admin/{APP_CLIENT_ID}"))
        except CasdoorError:
            return False

    # people
    def get_user(self, name: str) -> dict | None:
        data = self._ok("GET", f"/api/get-user?id={self.org}/{urllib.parse.quote(name)}")
        return data if isinstance(data, dict) and data.get("name") else None

    def users(self) -> list[dict]:
        data = self._ok("GET", f"/api/get-users?owner={self.org}")
        return [u for u in (data or []) if isinstance(u, dict)]

    def roles(self) -> list[dict]:
        data = self._ok("GET", f"/api/get-roles?owner={self.org}")
        return [r for r in (data or []) if isinstance(r, dict)]

    def add_user(self, name: str, password: str, *, email: str = "",
                 properties: dict | None = None) -> None:
        out = self._ok("POST", "/api/add-user", body={
            "owner": self.org, "name": name, "displayName": name,
            "email": email or None, "password": password, "type": "normal-user",
            "isAdmin": False, "isForbidden": False, "isDeleted": False,
            "signupApplication": "app-built-in", "properties": dict(properties or {})})
        if out == "Unaffected":
            raise CasdoorError(f"Casdoor said ok but did not create {name}.")

    def _setpw(self, name: str, password: str) -> tuple[bool, str]:
        out = self._raw("POST", "/api/set-password", form={
            "userOwner": self.org, "userName": name, "oldPassword": "",
            "newPassword": password})
        return out.get("status") == "ok", str(out.get("msg") or "")

    def set_password(self, name: str, password: str) -> None:
        """Make ``password`` the account's and PROVE it: a second identical write must
        be refused as already current (the seed's apply_password contract)."""
        ok, msg = self._setpw(name, password)
        if not ok and PASSWORD_ALREADY_SET not in msg:
            raise CasdoorError(f"Casdoor refused the password for {name}: {msg}")
        ok, msg = self._setpw(name, password)
        if ok or PASSWORD_ALREADY_SET not in msg:
            raise CasdoorError(f"The password for {name} did not stick (Casdoor accepted "
                               "the same write twice).")

    def grant(self, name: str, role: str) -> None:
        """ADD ``name`` to ``role``'s members (other members kept) and read it back."""
        member = f"{self.org}/{name}"
        cur = self._ok("GET", f"/api/get-role?id={self.org}/{role}")
        if not isinstance(cur, dict):
            raise CasdoorError(f"The role {role} does not exist on {self.url}.")
        users = list(cur.get("users") or [])
        if member not in users:
            cur["users"] = users + [member]
            self._ok("POST", f"/api/update-role?id={self.org}/{role}", body=cur)
        back = self._ok("GET", f"/api/get-role?id={self.org}/{role}") or {}
        if member not in (back.get("users") or []):
            raise CasdoorError(f"Casdoor said ok, but {role} still does not list {name}.")


# ── what the screens call ────────────────────────────────────────────────────────────
@dataclass
class Account:
    name: str
    email: str = ""
    roles: tuple[str, ...] = ()
    domain: str = ""


@dataclass
class Outcome:
    ok: bool
    message: str
    accounts: list[Account] = field(default_factory=list)
    #: the generated password, when one was generated (shown once, never stored)
    password: str = ""


def _admin(target: Target, opener=None) -> CasdoorAdmin:
    return CasdoorAdmin(target.url, opener=opener, cafile=target.cafile)


def list_accounts(target: Target, generator_dir: str, *, env=None,
                  opener=None) -> Outcome:
    """The accounts of ``target``'s domain: on the central Casdoor, those marked with
    the domain (and on the mesh's own domain, the unmarked ones too); on a domain's
    own Casdoor, all of them."""
    try:
        cd = _admin(target, opener)
        cd.login(admin_password(generator_dir, env))
        users = cd.users()
        member_of: dict[str, list[str]] = {}
        for r in cd.roles():
            for m in r.get("users") or []:
                member_of.setdefault(str(m), []).append(str(r.get("name") or ""))
    except CasdoorError as e:
        return Outcome(False, str(e))
    out = []
    for u in users:
        name = str(u.get("name") or "")
        dom = str((u.get("properties") or {}).get(DOMAIN_PROPERTY) or "")
        out.append(Account(name, str(u.get("email") or ""),
                           tuple(sorted(member_of.get(f"{ORG}/{name}", []))), dom))
    return Outcome(True, "", sorted(out, key=lambda a: a.name.lower()))


def create_account(target: Target, generator_dir: str, username: str, password: str,
                   roles, *, email: str = "", env=None, opener=None,
                   on_line=None) -> Outcome:
    """Create ``username`` with ``roles`` (ROLE_USER always) in ``target``'s Casdoor.
    An empty ``password`` generates one, returned once in ``Outcome.password``."""
    username = (username or "").strip()
    why = username_problem(username)
    if why:
        return Outcome(False, why)
    generated = ""
    if not password:
        password = generated = generate_password()
    why = password_problem(password)
    if why:
        return Outcome(False, why)
    bad = [r for r in roles or () if r not in GRANTABLE_ROLES]
    if bad:
        return Outcome(False, f"Not a role a person can be given here: {', '.join(bad)}.")
    want = [FLOOR_ROLE] + [r for r in GRANTABLE_ROLES if r in set(roles or ())
                           and r != FLOOR_ROLE]

    def note(s):
        if on_line:
            on_line(s)

    try:
        cd = _admin(target, opener)
        cd.login(admin_password(generator_dir, env), on_line=on_line)
        cd.ensure_org()
        for r in want:
            cd.ensure_role(r)
        if cd.get_user(username) is not None:
            return Outcome(False, f"{username} already exists in {target.words}. "
                                  "Nothing was changed (an existing person is never "
                                  "re-passworded from here).")
        props = {DOMAIN_PROPERTY: target.domain} if target.central and target.domain else {}
        note(f"[people] creating {username} in {target.url}")
        cd.add_user(username, password, email=(email or "").strip(), properties=props)
        cd.set_password(username, password)
        for r in want:
            cd.grant(username, r)
        if cd.get_user(username) is None:
            raise CasdoorError(f"{username} is not there when read back.")
        app = cd.has_app()
    except CasdoorError as e:
        return Outcome(False, str(e))
    msg = (f"{username} was created in {target.words}, with "
           f"{', '.join(want)} (read back).")
    if not app:
        msg += (" This Casdoor has no sign-in application for the mesh yet "
                f"({APP_CLIENT_ID}), so the person cannot sign in through the mesh until "
                "it has one.")
    return Outcome(True, msg, [Account(username, email, tuple(want), target.domain)],
                   password=generated)


def complete_registration(front_door: str, username: str, password: str, *,
                          cafile: str = "", opener=None) -> tuple[bool, str]:
    """Registration stage 2 for a just-created account, through the mesh's front door
    (POST /bff/login, then /bff/register/complete — the same two calls seed-e2e.sh
    leg 1c makes). Without it the person completes registration at first sign-in.
    Returns (done, what happened)."""
    op = opener or _opener(cafile)
    base = front_door.rstrip("/")

    def post(path, body):
        req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                     method="POST",
                                     headers={"content-type": "application/json"})
        try:
            with op.open(req, timeout=20) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code
        except (urllib.error.URLError, OSError):
            return 0

    code = post("/bff/login", {"username": username, "password": password})
    if code != 200:
        return False, (f"the front door at {base} answered the sign-in with "
                       f"{code or 'nothing'}, so registration was left for the person's "
                       "first sign-in")
    code = post("/bff/register/complete", {"displayName": username})
    if code != 200:
        return False, (f"registration was not completed ({code or 'no answer'}); the "
                       "person completes it at first sign-in")
    return True, "registration completed, so the roles work at the first sign-in"
