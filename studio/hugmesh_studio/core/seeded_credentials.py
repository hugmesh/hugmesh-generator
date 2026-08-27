"""Seeded persona credentials — what `make stack-seed` actually provisions, in a
form the GUI can show and the operator can copy.

WHY THIS EXISTS. A freshly-seeded local mesh is useless to the operator until they
know WHICH account to sign in with. That roster lives in a shell script
(tests/qemu/seed-accounts.sh `SYSTEMS_ROLE_USERS`), so before this module the only
ways to learn it were reading that script or scraping the seeder's stdout. The
wizard's Local-Docker-mesh page now shows the roster in a copyable table instead.

THE ROSTER IS PARSED, NEVER RESTATED. `SYSTEMS_ROLE_USERS` is the single source of
truth for who gets seeded; hardcoding a copy here would silently drift the moment a
persona is added to the seeder. So :func:`load_roster` reads that assignment out of
the shell script. The password precedence is likewise a MIRROR of the shared chain
(seed-accounts.sh `role_password()`, tests/stack/e2e-password.sh
`e2e_password_ensure()`): per-user ``E2E_<UPPER>_PASSWORD`` -> shared
``E2E_PASSWORD`` -> the run-state credentials file -> nothing, resolved against the
SAME env mapping the Studio hands `make stack-seed` (core/local_stack_node.py
`_build_env`), so what the table shows is what the seeder actually set — never a
literal this module invents on its own.

SECRET DISCIPLINE. These are generated fresh EACH RUN by `tests/stack/e2e-password.sh`
(a 32-char CSPRNG value, never a fixed literal) and persisted to the gitignored
run-state file ``${E2E_CREDENTIALS_FILE:-<repo-root>/.e2e-credentials}``, which `make
stack-seed`'s banner also prints in the clear — so showing it here discloses nothing
new. This module only READS that value, through the same precedence the seeder
itself resolves; it never generates one and never writes one anywhere: no logging,
no config file, no argv. When nothing has been seeded yet it says so plainly instead
of guessing — a wrong password is worse than none. The GUI copies to the clipboard
on explicit operator action only.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

# The roster is assembled from the SAME three places the seeder assembles it from,
# because a persona missing here is a persona the operator cannot discover:
#   1. seed-accounts.sh  SYSTEMS_ROLE_USERS — the base RBAC matrix.
#   2. e2e-extra-personas.sh  E2E_EXTRA_PERSONAS — superadmin/fleet/banned + the
#      invite-flow handles, appended by seed-e2e.sh as EXTRA_SPECS.
#   3. seed-e2e.sh  LOCAL_OPERATOR_* — the broad local-mesh operator account, which
#      only exists on the SEED_COMPLETE_REGISTRATION path the Studio drives. This is
#      the one that matters most: it is the only account that opens every app, so a
#      dialog that omitted it would hide its own best answer.
ROSTER_SCRIPT = os.path.join("tests", "qemu", "seed-accounts.sh")
EXTRAS_SCRIPT = os.path.join("tests", "e2e-extra-personas.sh")
OPERATOR_SCRIPT = os.path.join("tests", "stack", "seed-e2e.sh")

# The shell variables holding each, and the shared-password fallback chain.
_ROSTER_VAR = "SYSTEMS_ROLE_USERS"
_EXTRAS_VAR = "E2E_EXTRA_PERSONAS"
_SHARED_PASSWORD_ENV = "E2E_PASSWORD"

# The run-state file tests/stack/e2e-password.sh writes and every consumer reads
# (CONTRACT rule 3): plain KEY=value lines, no quotes, no export keyword, path
# overridable via E2E_CREDENTIALS_FILE and defaulting to the checkout root.
_CREDENTIALS_FILE_ENV = "E2E_CREDENTIALS_FILE"
_CREDENTIALS_FILE_NAME = ".e2e-credentials"

# Shown in place of a password when NOTHING resolved: no per-user env, no shared
# env, no credentials file. Deliberately not a plausible-looking password — an
# operator copy-pasting a WRONG value that happens to authenticate somewhere is
# worse than one who sees plainly that nothing has been seeded yet.
_NOT_SEEDED = "(not seeded — run `make stack-seed`)"

# `SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:-\` ... `}"` — a line-continued default.
# Captures the body of the ${VAR:-...} default so a caller-set override in the
# operator's own environment does not change what we report (the seeder would use
# the override, but the Studio never sets one; see resolve_password's env arg).
_ROSTER_RE = re.compile(
    r'^\s*' + _ROSTER_VAR + r'="\$\{' + _ROSTER_VAR + r':-(?P<body>.*?)\}"\s*$',
    re.DOTALL | re.MULTILINE)

# `E2E_EXTRA_PERSONAS="\` … `"` — a plain line-continued assignment (no ${VAR:-…}).
_EXTRAS_RE = re.compile(
    r'^\s*' + _EXTRAS_VAR + r'="(?P<body>.*?)"\s*$', re.DOTALL | re.MULTILINE)

# The operator account, declared as two knobs in seed-e2e.sh.
_OPERATOR_USER_RE = re.compile(
    r'^\s*LOCAL_OPERATOR_USER="\$\{LOCAL_OPERATOR_USER:-(?P<v>[^}]*)\}"', re.MULTILINE)
_OPERATOR_ROLES_RE = re.compile(
    r'^\s*LOCAL_OPERATOR_ROLES="\$\{LOCAL_OPERATOR_ROLES:-(?P<v>[^}]*)\}"', re.MULTILINE)

# A `${NAME:-default}` reference inside a persona entry. The extras file writes its
# superadmin row as `${SUPERADMIN_PERSONA}:ROLE_SUPERADMIN:…`, so without resolving
# this the table would show a literal `${SUPERADMIN_PERSONA}` as a username.
_SHELL_DEFAULT_RE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}')


# Which app each access role actually opens. THE POINT: app access is ROLE-GATED, and
# signing in as the most privileged-sounding persona is the wrong instinct — e2e-admin
# holds no ROLE_MATRIX, so its Matrix tab renders the whole UI shell and then 403s on
# every call (whoami/joined_rooms/sync). An operator reading a roster of usernames and
# raw ROLE_* strings cannot predict that, so the table spells the mapping out.
# Roles absent here (ROLE_USER, the *_DOMAINLOCKED / *_EXTERNAL_CLIENT markers) grant no
# app of their own: they are the baseline, or modifiers on another role.
ROLE_APPS = {
    "ROLE_MATRIX": "Matrix",
    "ROLE_MASTODON": "Mastodon",
    "ROLE_FORUM": "Forum",
    "ROLE_WIKI": "Wiki",
    "ROLE_GAMES": "Games",
    "ROLE_ADMIN": "Admin",
    "ROLE_MOD": "Moderation",
    "ROLE_SUPERADMIN": "Superadmin",
    "ROLE_FLEET_ADMIN": "Fleet",
}


@dataclass(frozen=True)
class SeededUser:
    """One persona the seeder creates: its Casdoor username, granted roles, and the
    password the seeder set for it (already resolved through the env precedence)."""
    username: str
    roles: tuple[str, ...]
    password: str
    #: The ``E2E_<UPPER>_PASSWORD`` variable that would override this user's
    #: password. Kept for display so an operator can see WHICH knob to set.
    password_env: str = ""

    @property
    def roles_display(self) -> str:
        return ", ".join(self.roles) if self.roles else "(none — awaiting approval)"

    @property
    def apps_display(self) -> str:
        """The apps this persona can actually open, named the way the nav names them.

        The roles column alone does not answer the operator's real question. Knowing
        e2e-admin holds ROLE_ADMIN does not tell you its Matrix tab will load and then
        403 — only the absence of ROLE_MATRIX does, and absence is invisible in a
        list. Naming the apps makes the wall predictable BEFORE they hit it."""
        apps = [ROLE_APPS[r] for r in self.roles if r in ROLE_APPS]
        if not apps:
            return "sign-in only" if self.roles else "—"
        return ", ".join(dict.fromkeys(apps))


@dataclass
class Roster:
    """The parsed seed roster plus where it came from, so the GUI can explain an
    empty table instead of silently showing nothing."""
    users: list[SeededUser] = field(default_factory=list)
    source: str = ""
    #: Empty on success; otherwise why the roster could not be read.
    error: str = ""
    #: Username of the broad local-mesh operator account, when the seeder declares
    #: one. This is the account the dialog should lead with — every other persona is
    #: deliberately narrow and will hit a 403 somewhere.
    operator: str = ""

    def __bool__(self) -> bool:
        return bool(self.users)


# `NAME="${OTHER:-default}"` / `NAME="literal"` assignments, so a persona row that
# references a variable declared earlier in the SAME file resolves. The extras file
# writes its superadmin row as a bare `${SUPERADMIN_PERSONA}` (no inline default) and
# declares `SUPERADMIN_PERSONA="${CASDOOR_SUPERADMIN_USERNAME:-e2e-superadmin}"` above
# it — without this pass that row is unresolvable and e2e-superadmin, one of the
# personas the docs tell operators to sign in as, silently vanishes from the table.
_ASSIGN_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)="([^"\n]*)"\s*$', re.MULTILINE)


def _file_vars(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for name, raw in _ASSIGN_RE.findall(text):
        val = _expand_shell_default(raw, out)
        if "${" not in val:
            out[name] = val
    return out


def _expand_shell_default(text: str, variables: dict[str, str] | None = None) -> str:
    """Resolve ``${NAME:-default}`` to its DEFAULT (not to the ambient environment),
    and ``${NAME}`` to ``variables[NAME]`` when the same file declared it.

    The default is what the seeder uses on a normal run, and it is the value that
    will actually exist in Casdoor; reading os.environ here would show a username
    that the seed did not create. Anything still unresolved is left as-is so the
    caller can drop the entry rather than invent one.
    """
    def sub(m: re.Match) -> str:
        if m.group(2) is not None:
            return m.group(2)
        if variables and m.group(1) in variables:
            return variables[m.group(1)]
        return m.group(0)
    return _SHELL_DEFAULT_RE.sub(sub, text)


def _strip_line_continuations(body: str) -> str:
    """A shell ``\\``-newline continuation joins two tokens with whitespace, not
    nothing — collapse it that way before splitting on whitespace."""
    return body.replace("\\\n", " ")


def parse_roster_body(body: str, variables: dict[str, str] | None = None
                      ) -> list[tuple[str, tuple[str, ...], str]]:
    """Split a ``SYSTEMS_ROLE_USERS`` body into ``(username, roles, password_env)``.

    Entry grammar (the seeder's own comment): ``username:ROLE_A,ROLE_B:passwordEnv``.
    A malformed entry is SKIPPED rather than raising — a roster that gains an
    unexpected shape should degrade to showing the personas we do understand, not
    blank the whole dialog.
    """
    out: list[tuple[str, tuple[str, ...], str]] = []
    for token in _strip_line_continuations(body).split():
        parts = token.split(":")
        if len(parts) != 3:
            continue
        username, roles_csv, pw_env = (_expand_shell_default(p.strip(), variables)
                                       for p in parts)
        # A username we could not resolve to a literal (an unexpanded ${…}) is worse
        # than absent: it would be shown as a login that cannot possibly work.
        if not username or "${" in username:
            continue
        roles = tuple(r for r in (x.strip() for x in roles_csv.split(",")) if r)
        out.append((username, roles, pw_env))
    return out


def _read_credentials_file(generator_dir: str | None, src: dict[str, str]) -> dict[str, str]:
    """Parse the run-state file tests/stack/e2e-password.sh writes: plain
    ``KEY=value`` lines, no quotes, no export keyword (CONTRACT rule 3) — the same
    shape `set -a; . file; set +a` and `docker compose --env-file` both accept.

    Path: ``src[E2E_CREDENTIALS_FILE]`` if the caller's env sets it, else
    ``<generator_dir>/.e2e-credentials``. Best-effort like the rest of this module:
    a missing/unreadable/unparseable file yields {} so the caller falls through to
    the not-seeded marker instead of raising.
    """
    path = src.get(_CREDENTIALS_FILE_ENV) or (
        os.path.join(generator_dir, _CREDENTIALS_FILE_NAME) if generator_dir else "")
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return {}
    out: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip()
    return out


def resolve_password(password_env: str, env: dict[str, str] | None = None,
                     generator_dir: str | None = None) -> str:
    """Mirror the shared chain (seed-accounts.sh ``role_password()``,
    tests/stack/e2e-password.sh ``e2e_password_ensure()``): per-user
    ``E2E_<UPPER>_PASSWORD`` wins, else the shared ``E2E_PASSWORD``, else whatever
    the run-state credentials file holds, else :data:`_NOT_SEEDED`.

    ``env`` is the mapping the SEEDER will see (the Studio passes the same dict it
    builds for `make stack-seed`), NOT necessarily os.environ — showing the operator
    a password the seeder did not set would be worse than showing nothing.
    ``generator_dir``, when given, locates the default credentials-file path;
    without it (e.g. a bare unit-test call) the file step is simply skipped.

    Unlike the shell generator this function NEVER MINTS a password — it only
    resolves what a run already produced (consumers resolve, they do not invent).
    """
    src = os.environ if env is None else env
    if password_env:
        val = src.get(password_env, "")
        if val:
            return val
    val = src.get(_SHARED_PASSWORD_ENV, "")
    if val:
        return val
    file_vals = _read_credentials_file(generator_dir, src)
    if password_env:
        val = file_vals.get(password_env, "")
        if val:
            return val
    return file_vals.get(_SHARED_PASSWORD_ENV, "") or _NOT_SEEDED


def load_roster(generator_dir: str, env: dict[str, str] | None = None) -> Roster:
    """Read + resolve the seeded persona roster from a generator checkout.

    Never raises: an unreadable/again-shaped seeder yields a Roster carrying an
    ``error`` the dialog can render, because a missing roster must not break the
    bring-up page it is embedded in.
    """
    path = os.path.join(generator_dir, ROSTER_SCRIPT)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        return Roster(source=path, error=f"could not read the seed roster: {e}")

    m = _ROSTER_RE.search(text)
    if not m:
        return Roster(source=path,
                      error=(f"{_ROSTER_VAR} not found in {ROSTER_SCRIPT} — the seeder's "
                             "roster format changed; report this."))

    specs = parse_roster_body(m.group("body"))
    specs += _read_extras(generator_dir)
    operator = _read_operator(generator_dir)
    if operator:
        specs.append(operator)

    # First declaration wins, so a persona is never listed twice if the seeder ever
    # repeats one across the three sources.
    seen: set[str] = set()
    users: list[SeededUser] = []
    for u, r, pw_env in specs:
        if u in seen:
            continue
        seen.add(u)
        users.append(SeededUser(username=u, roles=r,
                                password=resolve_password(pw_env, env, generator_dir),
                                password_env=pw_env))
    if not users:
        return Roster(source=path,
                      error=f"{_ROSTER_VAR} parsed but declared no usable personas.")
    return Roster(users=users, source=path, operator=operator[0] if operator else "")


def _read_extras(generator_dir: str) -> list[tuple[str, tuple[str, ...], str]]:
    """The E2E_EXTRA_PERSONAS rows seed-e2e.sh appends. Best-effort: the base roster
    is still worth showing if this file moves or changes shape."""
    try:
        with open(os.path.join(generator_dir, EXTRAS_SCRIPT), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return []
    m = _EXTRAS_RE.search(text)
    # Resolve variables the extras file declares about itself (SUPERADMIN_PERSONA).
    return parse_roster_body(m.group("body"), _file_vars(text)) if m else []


def _read_operator(generator_dir: str) -> tuple[str, tuple[str, ...], str] | None:
    """The local-mesh operator account, declared as two knobs in seed-e2e.sh.

    Seeded ONLY on the SEED_COMPLETE_REGISTRATION path — which is exactly the path
    the Studio's bring-up takes, so from this dialog's point of view it always
    exists. Its password follows the same shared-E2E_PASSWORD default as the rest."""
    try:
        with open(os.path.join(generator_dir, OPERATOR_SCRIPT), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    mu, mr = _OPERATOR_USER_RE.search(text), _OPERATOR_ROLES_RE.search(text)
    if not mu or not mr:
        return None
    roles = tuple(r for r in (x.strip() for x in mr.group("v").split(",")) if r)
    return (mu.group("v").strip(), roles, _SHARED_PASSWORD_ENV)


def grantable_roles(generator_dir: str) -> tuple[str, ...]:
    """The role catalogue an Add-user surface may offer: LOCAL_OPERATOR_ROLES
    parsed from seed-e2e.sh — the broadest DIRECTLY-grantable set, and a strict
    subset of the roles seed-e2e.sh ensure_roles() pre-creates. Derived roles
    (ROLE_GAMES_ADMIN, ROLE_FORUM_MOD) and the *_DOMAINLOCKED /
    *_EXTERNAL_CLIENT restriction markers are deliberately absent: the first
    two are materialized by reconcile Jobs, the rest take capability away."""
    op = _read_operator(generator_dir)
    return op[1] if op else ("ROLE_USER",)


def suggested_signin(roster: Roster) -> SeededUser | None:
    """The persona to lead with in the UI: the most privileged ordinary account an
    operator would try first. Falls back to the first entry so the dialog always has
    something to feature."""
    if not roster.users:
        return None
    by_name = {u.username: u for u in roster.users}
    # The operator account FIRST. Leading with e2e-admin (the instinctive choice, and
    # what this used to return) sends the operator straight into the trap: it opens
    # the admin panel and API docs, and its Matrix/Mastodon tabs render fully and then
    # 403 every call, because it holds no platform-access role.
    for preferred in (roster.operator, "e2e-admin", "e2e-superadmin", "e2e-user"):
        if preferred and preferred in by_name:
            return by_name[preferred]
    return roster.users[0]


def as_copyable_text(roster: Roster) -> str:
    """The whole roster as one paste-able block (the dialog's 'Copy all' payload)."""
    lines = ["# HugMesh local mesh — seeded sign-in credentials",
             "# username\tpassword\troles"]
    lines += [f"{u.username}\t{u.password}\t{u.roles_display}" for u in roster.users]
    return "\n".join(lines) + "\n"
