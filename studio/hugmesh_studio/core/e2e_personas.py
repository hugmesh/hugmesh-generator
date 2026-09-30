"""A spec -> persona INDEX: which table of users each e2e spec draws its actors from.

WHY THIS EXISTS. The feature tree (core/e2e_catalogue) can say WHICH spec failed. It
cannot say WHO was acting when it did, and that is the operator's actual next
question: "the table of users that they draw from". That mapping did not exist
anywhere in this repo. It is only PARTLY derivable, and the honest shape of this
module is a direct consequence of how partly. Measured in this checkout, the 33 specs
name their actors five different ways:

  * 12 specs hardcode persona literals (``onboard(page, 'admin@hugmesh.net')``);
  * 5 iterate a seeded-users constant (``for (const u of SYSTEMS_SEED_USERS)``);
  * 6 compute their actors at runtime (``requirePlatformPersonas('ROLE_MATRIX', 2)``
    filters the catalogue by role, so WHO acts depends on the roster's contents);
  * spec 24 generates 126 swarm identities procedurally;
  * 4 name handles that must NEVER exist, because the failed sign-in IS the assertion.

WHICH SHAPE, AND WHY (the brief offered two).

  (a) specs DECLARE their personas — static, complete, works for a spec that has
      never been run.
  (b) helpers RECORD personas at runtime and the reporter emits them — no spec edits,
      but a spec that was never run has NO persona data, and this suite skipped 62 of
      259 results in its last recorded run. Under (b) those 62 rows would be blank in
      exactly the tree that exists to explain them, and a spec deleted-then-restored
      would look actor-less until someone ran it.

THIS MODULE IS (a). The operator asks the question BEFORE a run, not after, so the
index must answer for specs that have never executed. But (a)'s stated cost — "requires
touching many specs" — is mostly avoidable, because a spec ALREADY declares its
personas in its own source; it just declares them in five grammars instead of one. So
this module DERIVES the declaration from the spec text (see :func:`extract_uses`) and
only four specs needed an added declaration — the four whose personas are, by design,
absent from every roster (:data:`NEVER_SEEDED_VAR`). tests/e2e/specs/33-console-access-
matrix.spec.ts is the pattern the brief pointed at, and it needs no edit at all: its
``PERSONAS`` table writes ``username: 'mesh-operator'``, and the persona-key rule below
reads it.

THE CHECKED-NOTHING PASS HAZARD, and the deliverable. An index that RESTATES a list of personas
would be wrong the first time a spec changed, and — worse — would go on rendering a
confident, stale table. Nothing here is restated: the RBAC matrix is parsed out of
tests/e2e/specs/rbac-roles.ts, the seed roster out of the three shell scripts (via
core.seeded_credentials, which already does exactly that), the swarm out of its own
generator's constants, and the spec->persona edges out of the spec sources. Where
derivation CANNOT reach, the gap is converted into a hard failure rather than a blank
cell — that is what :func:`guard_failures` is, and it is the deliverable:

  1. UNKNOWN REFERENCE — a spec names a persona no catalogue knows. Adding a persona
     to a spec and not to the seeder is the exact bug e2e-extra-personas.sh was written
     for (spec 29, 2026-08-06: "native login e2e-fleet -> 401", which reads like a
     broken login and is really a persona that was never created).
  2. UNSEEDED EXPECTATION — a persona the RBAC matrix carries expectations for that the
     seeder never provisions. Same 401, from the other direction.
  3. ROLE DRIFT — a persona in BOTH catalogues whose role lists disagree. The two
     files say they are "kept in lock-step"; nothing checked it until now.
  4. RESURRECTED NEVER-SEEDED HANDLE — a handle a spec declares must not exist, that
     the roster now provisions. Seeding `mallory@gmail.com` turns spec 03's
     denied-sign-in assertion vacuous, silently.
  5. ACTOR-LESS SPEC — a spec that calls a persona-taking helper but yields no persona
     the index can name. This is the tooth that makes (a) hold as the suite grows: a
     new grammar for naming actors fails here instead of quietly indexing to nothing.

TWO CATALOGUES THAT DISAGREE, AND WHY BOTH ARE RIGHT. tests/e2e/specs/rbac-roles.ts
lists 17 personas; the shell roster (seed-accounts.sh + e2e-extra-personas.sh +
seed-e2e.sh) has 32. They are NOT two copies of one list and merging them would lose
what each is for:

  * :data:`CAT_SEED_ROSTER` (32) is a PROVISIONING list — every identity the seeder
    creates in the systems Casdoor. Its authority is "this account exists".
  * :data:`CAT_RBAC_MATRIX` (17) is an EXPECTATION matrix — a typed catalogue whose
    rows carry assertions the specs check (``expectGamesAdmin``, ``federationProbe``,
    ``pinnedDeny``, ``registrationComplete``). Its authority is "this is what this
    account must and must not reach". The 15 it omits are the ad-hoc UI handles
    (alice@…, dragoneer, mesh-operator, e2e-fleet, e2e-banned) — real accounts with no
    declared RBAC expectation, which is a fact worth SHOWING, not smoothing over.

Measured today: the RBAC matrix is a strict subset of the roster (17 of 32) and every
shared row's roles agree. Both facts are CHECKED, not assumed — findings 2 and 3 above.
The same split exists in the games realm at smaller scale, with one legitimate
exception the index models rather than flags: ``GAMES_SEED_USERS`` carries an
``e2e-gamesadmin`` row that the games seeder deliberately does NOT create, because it
appears via the systems->games ROLE_GAMES_ADMIN sync (:data:`FINDING_SYNC_ONLY`).

THE SWARM IS A GENERATOR, NOT A TABLE. Spec 24 drives 126 procedural identities
(120 users / 4 mods / 2 admins). Unrolling them into the index would bury the 32 real
personas under 126 rows that carry no information a pattern does not, and would go
stale the moment SWARM_USERS is overridden — the counts are env-overridable on both
sides. :class:`GeneratedGroup` therefore records the name PATTERN, the tier, the count
and where the count came from, and :meth:`PersonaIndex.matches_generated` answers
"is this name a swarm member" without materialising the population.

THREE PERSONAS ARE BROKEN ON PURPOSE. e2e-pending, rbac-pending-gmail-com and
e2e-banned are never onboarded, and their un-onboarded state is what specs 17/28/29
assert. Anyone who "fixes" them voids three specs silently. The index marks them
:attr:`Persona.gated` with the reason, reusing e2e_catalogue.gated_personas so the two
surfaces cannot drift — that parser already models BOTH gating mechanisms (the named
SEED_REGISTRATION_SKIP list and seed-e2e.sh's shape rule that gates every ``*@*``
handle). A fourth persona, mesh-operator, is CONDITIONAL rather than gated: it exists
only when SEED_COMPLETE_REGISTRATION=1, which the Studio always sets
(core/local_stack_node.py) and the terminal `make stack-seed` lane never does. A tree
that renders it as an ordinary account tells a terminal-lane operator to sign in as
somebody who is not there — so it carries :attr:`Persona.conditional_on`.

WHAT THIS MODULE DOES NOT DO. It does not run anything: every fact here comes from
reading committed source. It does not resolve an actor that a spec computes from data
the source does not contain (an env-supplied username, a handle read from a fixture) —
such a spec trips finding 5 rather than being indexed to nothing. It is a TEXT
analysis, not a TypeScript parse: the string-aware scanner below is materially more
careful than a regex (see :func:`strip_ts`) but it is still not a compiler, and a spec
that hides an actor behind computation will not be understood.
"""
from __future__ import annotations

import os
import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field

from .e2e_catalogue import SPECS_DIR, GatedPersona, gated_personas
from .seeded_credentials import Roster, load_roster

# ── where the catalogues live ───────────────────────────────────────────────────
RBAC_ROLES_TS = os.path.join(SPECS_DIR, "rbac-roles.ts")
HELPERS_TS = os.path.join(SPECS_DIR, "helpers.ts")
SEED_ACCOUNTS_SH = os.path.join("tests", "qemu", "seed-accounts.sh")
SEED_E2E_SH = os.path.join("tests", "stack", "seed-e2e.sh")

# Names for the catalogues, so a surface can label a row with WHICH list vouches for
# it instead of implying one merged truth.
CAT_SEED_ROSTER = "seed-roster"    # shell; what the seeder provisions (systems realm)
CAT_RBAC_MATRIX = "rbac-matrix"    # rbac-roles.ts; what the RBAC specs assert
CAT_GAMES_ROSTER = "games-roster"  # shell; games-realm Casdoor
CAT_GAMES_MATRIX = "games-matrix"  # rbac-roles.ts GAMES_SEED_USERS
CAT_SWARM = "swarm"                # procedural, both sides
CAT_DECLARED = "spec-declared"     # a spec says this handle must NEVER be seeded
# A handle that appears ONLY in seed-e2e.sh's SEED_REGISTRATION_SKIP. The roster
# spells the pending invite handle `rbac-pending@gmail.com`; Casdoor stores the
# normalised `rbac-pending-gmail-com`, and the skip list uses the normalised form. Both
# spellings are real, both are gated, and dropping the one the roster does not carry
# would hide one of the three personas whose gated state specs 17/28/29 depend on.
CAT_GATE_LIST = "gate-list"

REALM_SYSTEMS = "systems"
REALM_GAMES = "games"

# ── how a spec named its actor ──────────────────────────────────────────────────
# Ordered strongest-first. A surface may render them differently; it must not treat
# them as equally precise, because they are not.
MECH_CATALOGUE = "catalogue"    # iterates/filters a typed catalogue — always current.
MECH_CALLSITE = "call-site"     # a literal in a persona-taking helper's username arg.
MECH_LITERAL = "literal"        # a persona-shaped/known literal in persona position.
MECH_ACCT = "federated-acct"    # `<persona>@<host>` — an address DERIVED from a persona.
MECH_GENERATED = "generated"    # a procedural population; see GeneratedGroup.
MECH_DECLARED = "declared"      # the spec declares it, and declares it must not exist.

# Strongest-first, and used as a PRECEDENCE: one edge per (spec, persona), labelled
# with the strongest mechanism that named it. A persona is routinely named twice — a
# catalogue iteration that includes it AND a literal that pins it — and emitting both
# would double every row of the table and every guard finding about it.
MECH_PRECEDENCE = (MECH_DECLARED, MECH_CATALOGUE, MECH_CALLSITE,
                   MECH_ACCT, MECH_LITERAL, MECH_GENERATED)

# The declaration a spec adds for the handles no roster may ever carry. Kept to ONE
# exported const so the grammar the index has to understand does not grow.
NEVER_SEEDED_VAR = "NEVER_SEEDED_PERSONAS"

# ── guard findings ──────────────────────────────────────────────────────────────
FINDING_UNKNOWN = "unknown-persona"
FINDING_UNSEEDED = "unseeded-expectation"
FINDING_ROLE_DRIFT = "role-drift"
FINDING_RESURRECTED = "resurrected-never-seeded"
FINDING_ACTORLESS = "actor-less-spec"
# NOT a guard failure — an expected, documented asymmetry, surfaced so a reader does
# not "fix" it into one.
FINDING_SYNC_ONLY = "sync-created"

# Parameter names that mark a function argument as taking a persona handle, and object
# keys that mark a literal as sitting in persona position. Both are POSITIVE rules:
# a literal is a persona reference because of where it sits, never merely because of
# how it is spelled. `name: 'e2e-part'` in spec 28 is a character-part payload, not an
# account, and a shape-only rule indexes it as a missing persona.
PERSONA_PARAMS = frozenset({"username", "persona", "handle", "login"})
PERSONA_KEYS = frozenset({"username", "user", "persona", "email", "handle", "login",
                          "actor", "subject"})

# A handle SHAPE worth investigating even when no catalogue knows it — this is what
# makes finding 1 fire on a NEW name instead of only on a known one.
_SHAPE_RE = re.compile(
    r"^(?:e2e-[a-z0-9][a-z0-9-]*|[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})$")

# A literal that is the right-hand side of `??`/`||` is a DEFAULT, not an actor:
# every password fallback in this suite is written `process.env.E2E_PASSWORD ?? 'e2e-pass'`.
# Without this, 'e2e-pass' and 'e2e-swarm-pass' index as personas in six files.
_NULLISH_RE = re.compile(r"(?:\?\?|\|\|)\s*$")
_PROP_KEY_RE = re.compile(r"([A-Za-z_$][\w$]*)\s*:\s*$")
_STRING_RE = re.compile(r"""'([^'\\\n]*)'|"([^"\\\n]*)"|`([^`\\$\n]*)`""")
_FUNC_SIG_RE = re.compile(r"function\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)", re.DOTALL)


def strip_ts(text: str) -> str:
    """Remove TypeScript comments, STRING-AWARE.

    Not the regex stripper in e2e_catalogue, and the difference is relied on here.
    A naive ``/\\*.*?\\*/`` treats the ``/*`` inside the string ``'/bff/superadmin/**'``
    (rbac-roles.ts, SUPERADMIN_ALLOW_ROUTES) as the start of a block comment and
    swallows everything up to the next ``*/`` — measured: it eats the tail of the file
    and the SYSTEMS_SEED_USERS parse below returns ZERO entries. That is fine for a
    coverage token search, which only ever loses a hit; it is fatal for a structural
    parse, which would silently report an empty catalogue as the truth.

    Block comments become a single space so two tokens they separated stay separated.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in "'\"`":
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                if text[i] == "\\":
                    out.append(text[i:i + 2])
                    i += 2
                    continue
                out.append(text[i])
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch == "/" and i + 1 < n:
            if text[i + 1] == "/":
                nl = text.find("\n", i)
                i = n if nl < 0 else nl
                continue
            if text[i + 1] == "*":
                end = text.find("*/", i + 2)
                out.append(" ")
                i = n if end < 0 else end + 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def blank_strings(text: str) -> str:
    """``text`` with every string literal's CONTENTS replaced by spaces, same length.

    Symbol searches must run over CODE, not prose-in-strings. Measured: spec 31's
    ``requirePlatformPersonas`` failure message contains the words "SYSTEMS_SEED_USERS
    + seed-accounts.sh", and a search over raw text reads that as the spec ITERATING
    the whole 17-row catalogue — turning a three-actor group-chat spec into a
    seventeen-actor one in the very table the operator is reading to find out who
    acted. Length is preserved so an offset found here still indexes into ``text``,
    which is where the call arguments are read from.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in "'\"`":
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


# ── the RBAC expectation matrix (rbac-roles.ts) ─────────────────────────────────

@dataclass(frozen=True)
class MatrixPersona:
    """One row of the TYPED catalogue — an identity plus what specs assert about it.

    The expectation fields are why this catalogue is not redundant with the shell
    roster: they are claims, and a claim about an account nobody provisions is a
    401 waiting to be misread as a broken login."""
    username: str
    roles: tuple[str, ...]
    registration_complete: bool = True
    expect_games_admin: bool = False
    federation_probe: str = ""
    federation_control: bool = False
    pinned_deny_route: str = ""
    #: Games realm only: the systems role whose sync CREATES this row, so the index
    #: does not report a deliberately un-seeded identity as a missing one.
    synced_from_systems: str = ""
    realm: str = REALM_SYSTEMS

    @property
    def carries_expectations(self) -> bool:
        """True when this row asserts something beyond "the account exists"."""
        return bool(self.expect_games_admin or self.federation_probe
                    or self.federation_control or self.pinned_deny_route
                    or not self.registration_complete)


def _object_entries(body: str) -> list[str]:
    """Split a ``[{...}, {...}]`` array body into its top-level object bodies."""
    out: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 1:
                cur = []
                continue
        elif ch == "}":
            depth -= 1
            if depth == 0:
                out.append("".join(cur))
                continue
        if depth >= 1:
            cur.append(ch)
    return out


def _array_decl(text: str, name: str) -> str:
    """The body of ``export const NAME... = [ ... \\n];``, or ""."""
    # `[^=]*` and NOT `[^=\[]*`: the declaration carries a TypeScript array TYPE
    # (`SYSTEMS_SEED_USERS: SystemsSeedUser[] = [`), so excluding `[` from the gap
    # makes the pattern miss the only two arrays this module needs — and miss them
    # SILENTLY, reporting a 17-row catalogue as empty.
    m = re.search(r"export const " + re.escape(name) + r"[^=]*=\s*\[(.*?)\n\];",
                  text, re.DOTALL)
    return m.group(1) if m else ""


def _last_literal(expr: str) -> str:
    """The LAST string literal in an expression — the DEFAULT of a ``x ?? 'y'`` chain.

    The superadmin row is ``process.env.CASDOOR_SUPERADMIN_USERNAME ?? 'e2e-superadmin'``.
    Reading os.environ here would name a persona that a normal run never creates, and
    would make the index's answer depend on the shell it was invoked from; the same
    default-not-environment rule seeded_credentials applies to the shell scripts."""
    lits = [g for m in _STRING_RE.finditer(expr) for g in m.groups() if g]
    return lits[-1] if lits else ""


def _field(entry: str, key: str) -> str:
    """The VALUE of ``key:`` in an object body, read to the next top-level comma.

    Scanned rather than line-matched. A line-anchored regex silently depends on the
    catalogue being formatted one field per line, which is a formatting convention,
    not a fact — and when it stops holding the parse does not fail, it returns a
    neighbouring field's text as the username.
    """
    m = re.search(r"(?<![A-Za-z0-9_$])" + re.escape(key) + r"\s*:", entry)
    if not m:
        return ""
    i, depth, n = m.end(), 0, len(entry)
    out: list[str] = []
    while i < n:
        ch = entry[i]
        if ch in "'\"`":
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                if entry[i] == "\\":
                    out.append(entry[i:i + 2])
                    i += 2
                    continue
                out.append(entry[i])
                if entry[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch == "," and depth == 0:
            break
        out.append(ch)
        i += 1
    return "".join(out).strip()


def _bool_field(entry: str, key: str, default: bool = False) -> bool:
    v = _field(entry, key)
    return default if v not in ("true", "false") else v == "true"


def _roles_field(entry: str) -> tuple[str, ...]:
    m = re.search(r"(?m)^\s*roles:\s*\[(.*?)\]", entry, re.DOTALL)
    if not m:
        return ()
    return tuple(g for lm in _STRING_RE.finditer(m.group(1))
                 for g in lm.groups() if g)


def parse_matrix(text: str, decl: str, realm: str) -> tuple[MatrixPersona, ...]:
    """Parse a typed persona array out of rbac-roles.ts source."""
    body = _array_decl(text, decl)
    out: list[MatrixPersona] = []
    for entry in _object_entries(body):
        username = _last_literal(_field(entry, "username"))
        if not username:
            continue
        deny = ""
        dm = re.search(r"pinnedDeny:\s*\{(.*?)\}", entry, re.DOTALL)
        if dm:
            deny = _last_literal(_field(dm.group(1), "route")) or _field(dm.group(1), "route")
        out.append(MatrixPersona(
            username=username,
            roles=_roles_field(entry),
            registration_complete=_bool_field(entry, "registrationComplete", True),
            expect_games_admin=_bool_field(entry, "expectGamesAdmin", False),
            federation_probe=_last_literal(_field(entry, "federationProbe")),
            federation_control=_bool_field(entry, "federationControl", False),
            pinned_deny_route=deny,
            synced_from_systems=_last_literal(_field(entry, "syncedFromSystems")),
            realm=realm))
    return tuple(out)


# ── the swarm generator (never unrolled) ────────────────────────────────────────

@dataclass(frozen=True)
class GeneratedGroup:
    """A PROCEDURAL population, represented as a pattern and a count.

    Spec 24 drives 126 of these. Materialising them would drown the 32 real personas
    and would be a lie the moment SWARM_USERS is overridden — the count is
    env-overridable on BOTH sides (rbac-roles.ts reads process.env.SWARM_USERS,
    seed-accounts.sh reads ${SWARM_USERS}), so :attr:`count` is the DEFAULT and
    :attr:`count_source` says so."""
    tier: str
    #: A human-readable name pattern, e.g. ``e2e-swarm-user-NNN``.
    pattern: str
    count: int
    roles: tuple[str, ...] = ()
    count_source: str = ""
    password_env: str = "E2E_SWARM_PASSWORD"

    def matches(self, username: str) -> bool:
        return bool(re.fullmatch(self.pattern.replace("NNN", r"\d{3}")
                                 .replace("N", r"\d+"), username))


@dataclass(frozen=True)
class SwarmSpec:
    groups: tuple[GeneratedGroup, ...] = ()
    error: str = ""

    @property
    def total(self) -> int:
        return sum(g.count for g in self.groups)


_SWARM_DEFAULTS_RE = re.compile(
    r"export const SWARM_DEFAULTS\s*=\s*\{\s*users:\s*(\d+)\s*,\s*mods:\s*(\d+)\s*,"
    r"\s*admins:\s*(\d+)\s*\}")


def parse_swarm(text: str) -> SwarmSpec:
    """The swarm population's SHAPE, from rbac-roles.ts's own constants.

    The username patterns are read from generateSwarm()'s template literals rather
    than written here, so a rename of the ``e2e-swarm-user-`` prefix moves the
    index with it instead of leaving a pattern that matches nothing (which would
    make every swarm identity read as an unknown persona)."""
    m = _SWARM_DEFAULTS_RE.search(text)
    if not m:
        return SwarmSpec(error=(
            "SWARM_DEFAULTS not found in rbac-roles.ts — the swarm's size cannot be "
            "reported, and spec 24's 126 actors would render as no actors at all."))
    counts = {"user": int(m.group(1)), "mod": int(m.group(2)), "admin": int(m.group(3))}
    body = text[text.find("export function generateSwarm"):]
    # Per-tier BLOCKS, not one flat search over the function: the three out.push({…})
    # objects are textually similar, and a regex spanning them pairs the admin tier's
    # swarmTier with the user tier's roles (measured: the admin group came back
    # holding 15 roles, three tiers' worth concatenated).
    blocks = [b for b in body.split("out.push({")[1:]]
    by_tier: dict[str, str] = {}
    for b in blocks:
        tm = re.search(r"swarmTier:\s*'([a-z]+)'", b)
        if tm:
            by_tier.setdefault(tm.group(1), b)
    groups: list[GeneratedGroup] = []
    for tier, count in counts.items():
        block = by_tier.get(tier, "")
        pm = re.search(r"username:\s*`([^`]*)`", block)
        if not pm:
            return SwarmSpec(error=(
                f"generateSwarm() declares no username template for the '{tier}' tier "
                "— the swarm pattern cannot be derived and must not be guessed."))
        pattern = re.sub(r"\$\{pad\(i,\s*3\)\}", "NNN", pm.group(1))
        pattern = re.sub(r"\$\{[^}]*\}", "N", pattern)
        rm = re.search(r"roles:\s*\[(.*?)\]", block, re.DOTALL)
        roles = tuple(g for lm in _STRING_RE.finditer(rm.group(1))
                      for g in lm.groups() if g) if rm else ()
        groups.append(GeneratedGroup(
            tier=tier, pattern=pattern, count=count, roles=roles,
            count_source="rbac-roles.ts SWARM_DEFAULTS (override: SWARM_"
                         f"{tier.upper()}S / seed-accounts.sh SWARM_{tier.upper()}S)"))
    return SwarmSpec(groups=tuple(groups))


# ── the games-realm shell roster ────────────────────────────────────────────────
_SUPERADMIN_USERNAME_RE = re.compile(
    r"export const SUPERADMIN_USERNAME\s*=\s*([^;]*);", re.DOTALL)


def parse_superadmin_username(rbac_text: str) -> str:
    """The superadmin's DEFAULT login handle from rbac-roles.ts SUPERADMIN_USERNAME.

    Parsed by name rather than taken as "the catalogue row holding ROLE_SUPERADMIN":
    the handle is env-driven (``process.env.CASDOOR_SUPERADMIN_USERNAME ?? 'e2e-…'``),
    so it is the ONE persona whose spelling differs between a Studio-bootstrapped mesh
    and the terminal lane, and specs reference it through this constant precisely so
    they do not 401 on the former (the spec-28 failure of 2026-08-14). The DEFAULT is
    what the index reports, for the same reason seeded_credentials reports shell
    defaults: reading os.environ would make the answer depend on the shell this ran in.
    """
    m = _SUPERADMIN_USERNAME_RE.search(rbac_text)
    return _last_literal(m.group(1)) if m else ""


_GAMES_ROLE_USERS_RE = re.compile(
    r'^\s*GAMES_ROLE_USERS="\$\{GAMES_ROLE_USERS:-(?P<v>[^}]*)\}"', re.MULTILINE)


def parse_games_roster(text: str) -> tuple[tuple[str, tuple[str, ...]], ...]:
    """``GAMES_ROLE_USERS`` from seed-accounts.sh — the GAMES Casdoor's provisioning
    list. seeded_credentials deliberately reads only the systems realm (it answers
    "which account do I sign into this mesh with"); the index needs both realms
    because specs 15/25/26 drive games identities too."""
    m = _GAMES_ROLE_USERS_RE.search(text)
    if not m:
        return ()
    out: list[tuple[str, tuple[str, ...]]] = []
    for token in m.group("v").replace("\\\n", " ").split():
        parts = token.split(":")
        if len(parts) != 3 or not parts[0] or "${" in parts[0]:
            continue
        out.append((parts[0], tuple(r for r in parts[1].split(",") if r)))
    return tuple(out)


_COMPLETE_REG_RE = re.compile(
    r'^\s*SEED_COMPLETE_REGISTRATION="\$\{SEED_COMPLETE_REGISTRATION:-(?P<v>[^}]*)\}"',
    re.MULTILINE)
_OPERATOR_USER_RE = re.compile(
    r'^\s*LOCAL_OPERATOR_USER="\$\{LOCAL_OPERATOR_USER:-(?P<v>[^}]*)\}"', re.MULTILINE)
CONDITIONAL_OPERATOR_REASON = (
    "exists ONLY when SEED_COMPLETE_REGISTRATION=1. The Studio's bring-up always sets "
    "it (core/local_stack_node.py); the terminal `make stack-seed` lane defaults to "
    "{default} and never creates this account. Offering it unconditionally sends a "
    "terminal-lane operator to a login that is not there.")


def conditional_operator(generator_dir: str) -> tuple[str, str]:
    """``(username, why-it-may-be-absent)`` for the local-mesh operator, or ``("","")``.

    seeded_credentials appends this persona to the roster unconditionally — correct
    for the Studio dialog it serves, since the Studio always takes the
    SEED_COMPLETE_REGISTRATION path. The index serves BOTH lanes, so it carries the
    condition instead of dropping it."""
    try:
        with open(os.path.join(generator_dir, SEED_E2E_SH), encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return ("", "")
    mu = _OPERATOR_USER_RE.search(text)
    if not mu:
        return ("", "")
    mc = _COMPLETE_REG_RE.search(text)
    default = mc.group("v").strip() if mc else "0"
    if default == "1":
        # The seeder's default flipped: the account is now unconditional and saying
        # otherwise would be the stale claim this module exists to avoid.
        return (mu.group("v").strip(), "")
    return (mu.group("v").strip(),
            CONDITIONAL_OPERATOR_REASON.format(default=default))


# ── the reconciled identity ─────────────────────────────────────────────────────

@dataclass(frozen=True)
class Persona:
    """One identity, with EVERY catalogue that vouches for it named.

    Deliberately not flattened into a single "roles" field: which list a persona
    appears in is the fact the operator needs. A row present in the seed roster and
    absent from the RBAC matrix is a real account with no declared expectations; the
    reverse is an expectation about an account that does not exist. Collapsing them
    into one list makes those two opposite situations look identical."""
    username: str
    realm: str = REALM_SYSTEMS
    #: Which of CAT_* vouch for this identity.
    catalogues: tuple[str, ...] = ()
    #: Roles the SEEDER grants (shell). Empty when not provisioned.
    seeded_roles: tuple[str, ...] = ()
    #: Roles the RBAC matrix declares. Empty when the matrix omits this persona.
    matrix_roles: tuple[str, ...] = ()
    expectations: MatrixPersona | None = None
    #: Un-onboarded ON PURPOSE — the state specs 17/28/29 assert. NEVER "fix" these.
    gated: bool = False
    gated_reason: str = ""
    #: Non-empty when the account exists only under some condition (mesh-operator).
    conditional_on: str = ""
    #: Declared by a spec as a handle that must NEVER be provisioned.
    never_seeded: bool = False
    never_seeded_by: tuple[str, ...] = ()

    @property
    def seeded(self) -> bool:
        return CAT_SEED_ROSTER in self.catalogues or CAT_GAMES_ROSTER in self.catalogues

    @property
    def in_matrix(self) -> bool:
        return CAT_RBAC_MATRIX in self.catalogues or CAT_GAMES_MATRIX in self.catalogues

    @property
    def status_display(self) -> str:
        """One line a tree row can show. The gated and conditional cases lead,
        because those are the two a reader would otherwise misdiagnose."""
        if self.never_seeded:
            return ("must NEVER be provisioned — a spec asserts its ABSENCE ("
                    + ", ".join(self.never_seeded_by) + ")")
        if self.gated:
            return f"gated on purpose — {self.gated_reason}"
        if self.conditional_on:
            return f"conditional — {self.conditional_on}"
        if not self.seeded:
            return "NOT provisioned by any seeder"
        if not self.in_matrix:
            return "provisioned; no declared RBAC expectations"
        return "provisioned, with declared RBAC expectations"


@dataclass(frozen=True)
class PersonaUse:
    """One spec -> persona edge, carrying HOW the spec named the actor."""
    spec_file: str
    username: str
    mechanism: str
    #: What the spec actually wrote, when that differs from the resolved username
    #: (``requirePlatformPersonas('ROLE_MATRIX', 2)``, ``e2e-admin@mastodon.…``).
    detail: str = ""
    #: False when no catalogue knows this name — finding 1.
    known: bool = True


@dataclass(frozen=True)
class SpecPersonas:
    """The table of users ONE spec draws from."""
    spec_file: str
    uses: tuple[PersonaUse, ...] = ()
    generated: tuple[GeneratedGroup, ...] = ()
    #: True when the spec calls a persona-taking helper (so it HAS actors).
    drives_personas: bool = False

    @property
    def usernames(self) -> tuple[str, ...]:
        seen: dict[str, None] = {}
        for u in self.uses:
            seen.setdefault(u.username, None)
        return tuple(seen)

    @property
    def generated_count(self) -> int:
        return sum(g.count for g in self.generated)

    @property
    def actor_less(self) -> bool:
        return self.drives_personas and not self.uses and not self.generated


@dataclass(frozen=True)
class Finding:
    """A guard result. ``blocking`` False is a documented asymmetry, not a defect."""
    kind: str
    subject: str
    detail: str
    blocking: bool = True


@dataclass
class PersonaIndex:
    personas: dict[str, Persona] = field(default_factory=dict)
    by_spec: dict[str, SpecPersonas] = field(default_factory=dict)
    swarm: SwarmSpec = field(default_factory=SwarmSpec)
    findings: tuple[Finding, ...] = ()
    #: Non-fatal narration for a surface: what could not be read at all.
    problems: list[str] = field(default_factory=list)

    def __bool__(self) -> bool:
        return bool(self.personas)

    def for_spec(self, spec_file: str) -> SpecPersonas:
        return self.by_spec.get(spec_file, SpecPersonas(spec_file=spec_file))

    def matches_generated(self, username: str) -> GeneratedGroup | None:
        """Is this name a member of a procedural population? Answered WITHOUT
        materialising 126 rows."""
        for g in self.swarm.groups:
            if g.matches(username):
                return g
        return None

    @property
    def blocking(self) -> tuple[Finding, ...]:
        return tuple(f for f in self.findings if f.blocking)

    @property
    def gated(self) -> tuple[Persona, ...]:
        return tuple(p for p in self.personas.values() if p.gated)

    def catalogue_counts(self) -> dict[str, int]:
        """Per-catalogue sizes — the reconciliation, shown as the several lists it is.
        The swarm entry is the GENERATED total, which is why it is not a persona count."""
        out = {c: 0 for c in (CAT_SEED_ROSTER, CAT_RBAC_MATRIX, CAT_GAMES_ROSTER,
                              CAT_GAMES_MATRIX, CAT_DECLARED, CAT_GATE_LIST)}
        for p in self.personas.values():
            for c in p.catalogues:
                if c in out:
                    out[c] += 1
        out[CAT_SWARM] = self.swarm.total
        return out


# ── extracting a spec's actors ──────────────────────────────────────────────────

def persona_taking_functions(sources: dict[str, str]) -> dict[str, int]:
    """``{function name: index of its persona parameter}``, DERIVED from declarations.

    Reading the signatures is what lets the index follow a bare handle like
    ``registerOnly(page, 'rando')`` — 'rando' matches no persona shape and no
    catalogue, so only its POSITION identifies it as an actor. Spec-local helpers
    count too (spec 13's ``loginAs``, spec 33's ``signIn``), which is why every
    source is scanned rather than only helpers.ts."""
    out: dict[str, int] = {}
    for text in sources.values():
        for name, params in _FUNC_SIG_RE.findall(text):
            for i, raw in enumerate(p.strip() for p in params.split(",")):
                pm = re.match(r"([A-Za-z_$][\w$]*)", raw.lstrip("."))
                if pm and pm.group(1) in PERSONA_PARAMS:
                    out.setdefault(name, i)
                    break
    return out


def _call_args(text: str, open_paren: int) -> list[str]:
    """Top-level argument texts of the call whose ``(`` is at ``open_paren``."""
    args: list[str] = [""]
    depth = 1
    i = open_paren + 1
    while i < len(text) and depth:
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                break
        if depth == 1 and ch == ",":
            args.append("")
        else:
            args[-1] += ch
        i += 1
    return args


def _literal(expr: str) -> str:
    m = _STRING_RE.fullmatch(expr.strip())
    if not m:
        return ""
    return next((g for g in m.groups() if g), "")


def declared_never_seeded(text: str) -> tuple[str, ...]:
    """The ``NEVER_SEEDED_PERSONAS`` a spec declares — handles that must not exist.

    This is the one place shape (a) needed a spec edit, and it needed it for a reason
    no derivation can substitute for: `mallory@gmail.com` is indistinguishable in
    source from a persona someone forgot to seed. Only the spec knows the difference,
    and the difference decides whether the right fix is "add it to the roster" or
    "never add it to the roster"."""
    # `[^=]*` for the same reason as _array_decl: the declaration is typed
    # `readonly string[]`, and excluding `[` from the gap makes this silently find
    # nothing — which would turn four deliberate declarations into four guard
    # failures and invite someone to "fix" them by seeding the handles.
    m = re.search(r"export const " + NEVER_SEEDED_VAR + r"[^=]*=\s*\[(.*?)\]",
                  text, re.DOTALL)
    if not m:
        return ()
    return tuple(g for lm in _STRING_RE.finditer(m.group(1))
                 for g in lm.groups() if g)


def _platform_personas(matrix: Sequence[MatrixPersona], role: str
                       ) -> tuple[MatrixPersona, ...]:
    """Mirror helpers.ts platformPersonas(): holders of the access role, minus the
    domain-locked holders, minus the registration-incomplete. Mirrored rather than
    approximated because the exclusions are the point — a domain-locked holder is the
    SUBJECT of specs 19-23, and listing it as an ordinary Matrix actor would tell an
    operator the wrong story about which proof it belongs to.

    Both pools are pinned BY NAME in ``PLATFORM_POOLS`` (studio/tests/
    test_e2e_personas.py), NOT derived from this function — an expectation built by
    calling this function would be circular and no deletion here could fail it. Note
    which pool a change is tested against: in ROLE_MATRIX the domain-locked holder
    sorts THIRD and never enters the two-slice specs 05/10/11 take, so only the
    ROLE_MASTODON pool (locked holder SECOND) can see the exclusion disappear."""
    locked = role + "_DOMAINLOCKED"
    return tuple(u for u in matrix
                 if role in u.roles and locked not in u.roles and u.registration_complete)


def extract_uses(spec_file: str, text: str, *, matrix: Sequence[MatrixPersona],
                 games_matrix: Sequence[MatrixPersona], swarm: SwarmSpec,
                 known: Iterable[str], funcs: dict[str, int],
                 superadmin: str) -> SpecPersonas:
    """Every actor ONE spec draws, and how it named each.

    ``text`` must already be comment-stripped: persona names appear constantly in this
    suite's comments (spec 18 names five in prose and drives NONE, because every one of
    its tests is a ``test.skip`` placeholder), and a raw scan would credit it with a
    cast it does not have. Symbol lookups additionally run over :func:`blank_strings`,
    so a persona catalogue named inside an error MESSAGE is not read as an iteration
    over it.

    Exactly one edge is emitted per (spec, persona), labelled with the strongest
    mechanism that named it (:data:`MECH_PRECEDENCE`).
    """
    known_set = set(known)
    code = blank_strings(text)
    found: dict[str, PersonaUse] = {}
    drives = False

    def add(username: str, mechanism: str, detail: str = "", *, is_known: bool = True):
        if not username:
            return
        prev = found.get(username)
        if prev is not None and (MECH_PRECEDENCE.index(prev.mechanism)
                                 <= MECH_PRECEDENCE.index(mechanism)):
            return
        found[username] = PersonaUse(spec_file=spec_file, username=username,
                                     mechanism=mechanism, detail=detail, known=is_known)

    # 1. CATALOGUE mechanisms — the spec iterates or filters a typed list, so its cast
    #    is whatever the catalogue holds TODAY. Resolved from the parsed catalogue,
    #    never from a copy of it.
    if re.search(r"(?<![A-Za-z0-9_])SYSTEMS_SEED_USERS(?![A-Za-z0-9_])", code):
        drives = True
        for u in matrix:
            add(u.username, MECH_CATALOGUE, "iterates SYSTEMS_SEED_USERS")
    if re.search(r"(?<![A-Za-z0-9_])GAMES_SEED_USERS(?![A-Za-z0-9_])", code):
        drives = True
        for u in games_matrix:
            add(u.username, MECH_CATALOGUE, "iterates GAMES_SEED_USERS")
    for m in re.finditer(r"(?<![A-Za-z0-9_])(require)?[Pp]latformPersonas\s*\(", code):
        args = _call_args(text, m.end() - 1)
        role = _literal(args[0]) if args else ""
        if not role:
            continue
        drives = True
        pool = _platform_personas(matrix, role)
        count = len(pool)
        called = "platformPersonas"
        if m.group(1):
            called = "requirePlatformPersonas"
            if len(args) > 1:
                try:
                    count = min(int(args[1].strip()), len(pool))
                except ValueError:
                    count = len(pool)
        for u in pool[:count]:
            add(u.username, MECH_CATALOGUE,
                f"{called}('{role}'" + (f", {count}" if m.group(1) else "")
                + ") over the seed catalogue")
    if superadmin and re.search(r"(?<![A-Za-z0-9_])SUPERADMIN_USERNAME(?![A-Za-z0-9_])",
                                code):
        drives = True
        add(superadmin, MECH_CATALOGUE,
            "SUPERADMIN_USERNAME (the minted CASDOOR_SUPERADMIN_USERNAME on a "
            "Studio-bootstrapped mesh; this default on the terminal lane)")

    # 2. GENERATED — a procedural population, kept as a pattern and a count.
    generated: tuple[GeneratedGroup, ...] = ()
    if re.search(r"(?<![A-Za-z0-9_])(generateSwarm|swarm)\s*\(", code):
        drives = True
        generated = swarm.groups

    # 3. CALL-SITE — a literal in a persona-taking helper's persona parameter. The only
    #    mechanism that can see a handle with no persona shape and no catalogue row
    #    (spec 07's `registerOnly(page, 'rando')`).
    for name, idx in funcs.items():
        for m in re.finditer(r"(?<![A-Za-z0-9_$.])" + re.escape(name) + r"\s*\(", code):
            drives = True
            args = _call_args(text, m.end() - 1)
            if idx >= len(args):
                continue
            lit = _literal(args[idx])
            if lit:
                add(lit, MECH_CALLSITE, f"{name}(…, '{lit}')",
                    is_known=lit in known_set)

    # 4. LITERAL — a persona-shaped or catalogue-known string sitting in persona
    #    position. Position is checked TWICE: not a `??`/`||` default (every password
    #    fallback in this suite is one, which is how 'e2e-pass' reads as a persona in
    #    six files), and, when it is an object value, under a persona-ish key (spec
    #    28's `name: 'e2e-part'` is a character part, not an account).
    for m in _STRING_RE.finditer(text):
        val = next((g for g in m.groups() if g), "")
        if not val or not (_SHAPE_RE.match(val) or val in known_set):
            continue
        before = text[max(0, m.start() - 48):m.start()]
        if _NULLISH_RE.search(before):
            continue
        key = _PROP_KEY_RE.search(before)
        if key and key.group(1) not in PERSONA_KEYS:
            continue
        add(val, MECH_LITERAL, "", is_known=val in known_set)

    # 5. FEDERATED ACCT — `<known persona>@<host>`. Spec 21 posts as
    #    `e2e-admin@mastodon.hugmesh.net`, which is not a login handle but IS drawn
    #    from e2e-admin; reporting it unknown would send someone to add it to the seed
    #    roster. LIMITATION, stated because it is real: the rule attributes ANY
    #    `<known>@<anything>` to <known>, so a genuinely new persona whose handle
    #    begins with an existing persona's name plus '@' would be misattributed
    #    instead of failing the guard. One such handle exists today (spec 21).
    for username, use in list(found.items()):
        if use.known or "@" not in username:
            continue
        local = username.split("@", 1)[0]
        if local in known_set:
            del found[username]
            add(local, MECH_ACCT, f"federated address {username}")

    # 6. DECLARED — handles the spec says must NEVER exist. Declared last so the
    #    declaration overrides whatever mechanism found the handle first.
    for handle in declared_never_seeded(text):
        found.pop(handle, None)
        add(handle, MECH_DECLARED, f"{NEVER_SEEDED_VAR} — must never be provisioned")

    # Sorted by mechanism only: Python's sort is stable, so within a mechanism the
    # RESOLUTION order survives. That order is meaningful — requirePlatformPersonas
    # hands a spec its actors in catalogue order (ALICE, BOB), and re-alphabetising
    # would tell the operator the second party was the first.
    uses = tuple(sorted(found.values(), key=lambda u: MECH_PRECEDENCE.index(u.mechanism)))
    return SpecPersonas(spec_file=spec_file, uses=uses, generated=generated,
                        drives_personas=drives)


# ── assembling the index ────────────────────────────────────────────────────────

def _read(generator_dir: str, rel: str) -> str:
    try:
        with open(os.path.join(generator_dir, rel), encoding="utf-8",
                  errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def spec_sources(generator_dir: str) -> dict[str, str]:
    """Every ``.ts`` under tests/e2e/specs, COMMENT-STRIPPED. Helper modules are
    included: the index needs their function signatures, and a spec that reaches a
    persona only through a helper still reaches it."""
    d = os.path.join(generator_dir, SPECS_DIR)
    try:
        names = sorted(fn for fn in os.listdir(d) if fn.endswith(".ts"))
    except OSError:
        return {}
    return {fn: strip_ts(_read(generator_dir, os.path.join(SPECS_DIR, fn)))
            for fn in names}


def load_persona_index(generator_dir: str, *, roster: Roster | None = None,
                       gated: Sequence[GatedPersona] | None = None,
                       sources: dict[str, str] | None = None) -> PersonaIndex:
    """Build the spec -> persona index for a generator checkout. Never raises.

    Every input degrades independently and SAYS SO in ``problems``: an unreadable
    rbac-roles.ts still yields the shell roster and the literal/call-site edges; an
    unreadable roster still yields the RBAC matrix. What it must never do is return a
    confident empty index, because an empty persona table renders exactly like a suite
    that drives nobody."""
    idx = PersonaIndex()
    src = spec_sources(generator_dir) if sources is None else sources
    if not src:
        idx.problems.append(
            f"no spec sources under {SPECS_DIR} — the spec->persona index is empty, "
            "which is NOT the same as a suite that drives no personas.")

    rbac_text = strip_ts(_read(generator_dir, RBAC_ROLES_TS))
    matrix = parse_matrix(rbac_text, "SYSTEMS_SEED_USERS", REALM_SYSTEMS)
    games_matrix = parse_matrix(rbac_text, "GAMES_SEED_USERS", REALM_GAMES)
    if not matrix:
        idx.problems.append(
            f"could not parse SYSTEMS_SEED_USERS from {RBAC_ROLES_TS} — the RBAC "
            "expectations cannot be reconciled against the seed roster.")
    idx.swarm = parse_swarm(rbac_text)
    if idx.swarm.error:
        idx.problems.append(idx.swarm.error)

    r = load_roster(generator_dir) if roster is None else roster
    if r.error:
        idx.problems.append(r.error)
    games_roster = parse_games_roster(_read(generator_dir, SEED_ACCOUNTS_SH))
    if not games_roster:
        idx.problems.append(
            f"could not parse GAMES_ROLE_USERS from {SEED_ACCOUNTS_SH} — games-realm "
            "personas cannot be told apart from unknown ones.")

    gated_rows = tuple(gated_personas(generator_dir, r)) if gated is None else tuple(gated)
    if not gated_rows:
        idx.problems.append(
            "no deliberately-gated personas could be read — e2e-pending / "
            "rbac-pending-gmail-com / e2e-banned would render as ordinary broken "
            "logins, and specs 17/28/29 die the moment someone 'fixes' them.")
    gated_by_name = {g.username: g.reason for g in gated_rows}
    operator, operator_condition = conditional_operator(generator_dir)

    # ── build the reconciled identities ────────────────────────────────────────
    rows: dict[str, dict] = {}

    def row(username: str, realm: str = REALM_SYSTEMS) -> dict:
        return rows.setdefault(username, {"realm": realm, "catalogues": [],
                                          "seeded_roles": (), "matrix_roles": (),
                                          "expectations": None, "never_by": []})

    for u in r.users:
        d = row(u.username)
        d["catalogues"].append(CAT_SEED_ROSTER)
        d["seeded_roles"] = tuple(u.roles)
    for name, roles in games_roster:
        d = row(name, REALM_GAMES)
        d["catalogues"].append(CAT_GAMES_ROSTER)
        # A handle seeded in BOTH realms keeps its systems roles under seeded_roles;
        # the games grant is recorded by the catalogue tag. Merging the two role lists
        # would invent a principal holding both realms' roles, which no issuer mints.
        if not d["seeded_roles"]:
            d["seeded_roles"] = roles
    for name in gated_by_name:
        row(name)["catalogues"].append(CAT_GATE_LIST)
    for u in matrix:
        d = row(u.username)
        d["catalogues"].append(CAT_RBAC_MATRIX)
        d["matrix_roles"] = u.roles
        d["expectations"] = u
    for u in games_matrix:
        d = row(u.username, REALM_GAMES)
        d["catalogues"].append(CAT_GAMES_MATRIX)
        if not d["matrix_roles"]:
            d["matrix_roles"] = u.roles
        if d["expectations"] is None:
            d["expectations"] = u

    # Spec-declared never-seeded handles, harvested before the per-spec extraction so
    # the extraction can resolve them as known-and-deliberately-absent.
    never: dict[str, list[str]] = {}
    for fn, text in src.items():
        for handle in declared_never_seeded(text):
            never.setdefault(handle, []).append(fn)
    for handle, files in never.items():
        d = row(handle)
        d["catalogues"].append(CAT_DECLARED)
        d["never_by"] = sorted(files)

    for username, d in rows.items():
        idx.personas[username] = Persona(
            username=username, realm=d["realm"],
            catalogues=tuple(dict.fromkeys(d["catalogues"])),
            seeded_roles=d["seeded_roles"], matrix_roles=d["matrix_roles"],
            expectations=d["expectations"],
            gated=username in gated_by_name,
            gated_reason=gated_by_name.get(username, ""),
            conditional_on=operator_condition if username == operator else "",
            never_seeded=bool(d["never_by"]), never_seeded_by=tuple(d["never_by"]))

    # ── the spec -> persona edges ──────────────────────────────────────────────
    funcs = persona_taking_functions(src)
    superadmin = parse_superadmin_username(rbac_text)
    if matrix and not superadmin:
        idx.problems.append(
            f"SUPERADMIN_USERNAME could not be read from {RBAC_ROLES_TS} — every spec "
            "that drives the superadmin through that constant (25/26/28) will show no "
            "superadmin actor at all.")
    known = set(idx.personas)
    for fn, text in sorted(src.items()):
        if not fn.endswith(".spec.ts"):
            continue
        idx.by_spec[fn] = extract_uses(
            fn, text, matrix=matrix, games_matrix=games_matrix, swarm=idx.swarm,
            known=known, funcs=funcs, superadmin=superadmin)

    idx.findings = guard_failures(idx, matrix=matrix, games_matrix=games_matrix,
                                  games_roster=games_roster)
    return idx


def guard_failures(idx: PersonaIndex, *, matrix: Sequence[MatrixPersona],
                   games_matrix: Sequence[MatrixPersona],
                   games_roster: Sequence[tuple[str, tuple[str, ...]]]
                   ) -> tuple[Finding, ...]:
    """THE DELIVERABLE. Five checks, each one a way the index could silently go stale.

    A derived index that only ever agrees with itself is worth nothing; what makes it
    relied on is that a spec, a roster or a matrix can be changed in a way that
    makes this FAIL. Each finding names the file to change, because a guard that says
    only "mismatch" gets suppressed rather than fixed."""
    out: list[Finding] = []
    seeded_names = {p.username for p in idx.personas.values() if p.seeded}

    # 1. A spec names an actor no catalogue knows.
    for sp in idx.by_spec.values():
        for u in sp.uses:
            if u.known or u.mechanism == MECH_DECLARED:
                continue
            if idx.matches_generated(u.username):
                continue
            out.append(Finding(
                kind=FINDING_UNKNOWN, subject=f"{sp.spec_file}: {u.username}",
                detail=(f"{sp.spec_file} drives '{u.username}' ({u.mechanism}"
                        + (f", {u.detail}" if u.detail else "") + ") and NO catalogue "
                        "provisions it. Either add it to tests/e2e-extra-personas.sh "
                        "(reaching BOTH the compose and kind lanes) or, if the failed "
                        f"sign-in is the assertion, declare it in that spec's "
                        f"{NEVER_SEEDED_VAR}. Left as-is it 401s at setup and every "
                        "assertion after it is vacuous.")))

    # 2. The RBAC matrix carries expectations about an account nobody provisions.
    for u in matrix:
        if u.username not in seeded_names:
            out.append(Finding(
                kind=FINDING_UNSEEDED, subject=u.username,
                detail=(f"{RBAC_ROLES_TS} declares roles/expectations for "
                        f"'{u.username}' but no seeder creates it. This is the "
                        "2026-08-06 spec-29 failure exactly: a native login 401 that "
                        "reads as a broken password and is a persona that was never "
                        f"created. Add it to {SEED_ACCOUNTS_SH} or "
                        "tests/e2e-extra-personas.sh.")))
    for u in games_matrix:
        if u.username in {n for n, _ in games_roster}:
            continue
        if u.synced_from_systems:
            out.append(Finding(
                kind=FINDING_SYNC_ONLY, subject=u.username, blocking=False,
                detail=(f"games-realm '{u.username}' is absent from GAMES_ROLE_USERS "
                        "ON PURPOSE: it is created by the systems->games "
                        f"{u.synced_from_systems} sync, and seeding it natively would "
                        "make the sync assertion pass without the sync.")))
        elif u.username not in seeded_names:
            out.append(Finding(
                kind=FINDING_UNSEEDED, subject=u.username,
                detail=(f"games-realm '{u.username}' is in GAMES_SEED_USERS but not in "
                        f"GAMES_ROLE_USERS ({SEED_ACCOUNTS_SH}) and claims no sync "
                        "origin, so nothing creates it.")))

    # 3. Both catalogues know the persona and disagree about its roles.
    for u in matrix:
        p = idx.personas.get(u.username)
        if p is None or not p.seeded or p.realm != REALM_SYSTEMS:
            continue
        if set(p.seeded_roles) != set(u.roles):
            out.append(Finding(
                kind=FINDING_ROLE_DRIFT, subject=u.username,
                detail=(f"'{u.username}' holds {sorted(u.roles)} in {RBAC_ROLES_TS} "
                        f"but {sorted(p.seeded_roles)} in the shell roster. Both files "
                        "claim to be kept in lock-step; the specs assert against the "
                        "first and the mesh grants the second, so every assertion "
                        "about this persona is decided by a list the mesh ignores.")))

    # 4. A handle a spec says must never exist is now provisioned.
    for p in idx.personas.values():
        if p.never_seeded and p.seeded:
            out.append(Finding(
                kind=FINDING_RESURRECTED, subject=p.username,
                detail=(f"'{p.username}' is declared {NEVER_SEEDED_VAR} by "
                        + ", ".join(p.never_seeded_by) + " — those specs assert that "
                        "signing in as it FAILS — and the seed roster now provisions "
                        "it. The assertion is now vacuous: remove it from the roster, "
                        "do not remove it from the declaration.")))

    # 5. A spec drives personas the index cannot name. This is the tooth that keeps
    #    the derivation honest as the suite grows a sixth way of naming actors.
    for sp in idx.by_spec.values():
        if sp.actor_less:
            out.append(Finding(
                kind=FINDING_ACTORLESS, subject=sp.spec_file,
                detail=(f"{sp.spec_file} calls a persona-taking helper but the index "
                        "resolved NO actor for it, so the tree would show this spec "
                        "drawing from an empty table. Either the spec names its actor "
                        "in a way this module does not read — teach extract_uses() — "
                        f"or declare the cast in the spec (the {NEVER_SEEDED_VAR} / "
                        "spec-33 `PERSONAS` pattern).")))
    return tuple(out)
