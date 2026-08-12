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
the shell script. The password precedence is likewise a MIRROR of the script's
`role_password()`: per-user ``E2E_<UPPER>_PASSWORD`` -> shared ``E2E_PASSWORD`` ->
``e2e-pass``, resolved against the SAME env mapping the Studio hands `make
stack-seed` (core/local_stack_node.py `_build_env`), so what the table shows is what
the seeder actually set.

SECRET DISCIPLINE. These are DETERMINISTIC TEST credentials for a throwaway local
stack — the same values already printed in the clear by the Makefile's stack-seed
banner and committed in the seeder's defaults. They are not cluster secrets. This
module therefore reads them but NEVER writes them anywhere: no logging, no config
file, no argv. The GUI copies to the clipboard on explicit operator action only.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

# The seeder that declares the roster, relative to the generator checkout.
ROSTER_SCRIPT = os.path.join("tests", "qemu", "seed-accounts.sh")

# The shell variable holding the roster, and the shared-password fallback chain.
_ROSTER_VAR = "SYSTEMS_ROLE_USERS"
_SHARED_PASSWORD_ENV = "E2E_PASSWORD"
_DEFAULT_PASSWORD = "e2e-pass"

# `SYSTEMS_ROLE_USERS="${SYSTEMS_ROLE_USERS:-\` ... `}"` — a line-continued default.
# Captures the body of the ${VAR:-...} default so a caller-set override in the
# operator's own environment does not change what we report (the seeder would use
# the override, but the Studio never sets one; see resolve_password's env arg).
_ROSTER_RE = re.compile(
    r'^\s*' + _ROSTER_VAR + r'="\$\{' + _ROSTER_VAR + r':-(?P<body>.*?)\}"\s*$',
    re.DOTALL | re.MULTILINE)


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


@dataclass
class Roster:
    """The parsed seed roster plus where it came from, so the GUI can explain an
    empty table instead of silently showing nothing."""
    users: list[SeededUser] = field(default_factory=list)
    source: str = ""
    #: Empty on success; otherwise why the roster could not be read.
    error: str = ""

    def __bool__(self) -> bool:
        return bool(self.users)


def _strip_line_continuations(body: str) -> str:
    """A shell ``\\``-newline continuation joins two tokens with whitespace, not
    nothing — collapse it that way before splitting on whitespace."""
    return body.replace("\\\n", " ")


def parse_roster_body(body: str) -> list[tuple[str, tuple[str, ...], str]]:
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
        username, roles_csv, pw_env = (p.strip() for p in parts)
        if not username:
            continue
        roles = tuple(r for r in (x.strip() for x in roles_csv.split(",")) if r)
        out.append((username, roles, pw_env))
    return out


def resolve_password(password_env: str, env: dict[str, str] | None = None) -> str:
    """Mirror seed-accounts.sh ``role_password()``: per-user ``E2E_<UPPER>_PASSWORD``
    wins, else the shared ``E2E_PASSWORD``, else the literal ``e2e-pass``.

    ``env`` is the mapping the SEEDER will see (the Studio passes the same dict it
    builds for `make stack-seed`), NOT necessarily os.environ — showing the operator
    a password the seeder did not set would be worse than showing nothing.
    """
    src = os.environ if env is None else env
    if password_env:
        val = src.get(password_env, "")
        if val:
            return val
    return src.get(_SHARED_PASSWORD_ENV, "") or _DEFAULT_PASSWORD


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

    users = [SeededUser(username=u, roles=r,
                        password=resolve_password(pw_env, env), password_env=pw_env)
             for u, r, pw_env in parse_roster_body(m.group("body"))]
    if not users:
        return Roster(source=path,
                      error=f"{_ROSTER_VAR} parsed but declared no usable personas.")
    return Roster(users=users, source=path)


def suggested_signin(roster: Roster) -> SeededUser | None:
    """The persona to lead with in the UI: the most privileged ordinary account an
    operator would try first. Falls back to the first entry so the dialog always has
    something to feature."""
    if not roster.users:
        return None
    by_name = {u.username: u for u in roster.users}
    for preferred in ("e2e-admin", "e2e-superadmin", "e2e-user"):
        if preferred in by_name:
            return by_name[preferred]
    return roster.users[0]


def as_copyable_text(roster: Roster) -> str:
    """The whole roster as one paste-able block (the dialog's 'Copy all' payload)."""
    lines = ["# HugMesh local mesh — seeded sign-in credentials",
             "# username\tpassword\troles"]
    lines += [f"{u.username}\t{u.password}\t{u.roles_display}" for u in roster.users]
    return "\n".join(lines) + "\n"
