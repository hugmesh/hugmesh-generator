"""The spec -> persona index — "the table of users each spec draws from".

WHAT THESE TESTS ARE FOR. The index's whole value is that it is DERIVED. A restated
copy of who-drives-what would pass every parse test on the day it was written and go
on rendering a confident, stale table forever after — which is worse than the blank it
replaced, because a blank invites a question and a wrong table answers it. So the
tests are in three layers and only the middle one is about parsing:

  * DERIVATION, against SYNTHETIC sources built inline. These pin the extraction rules
    that make the index track a spec instead of remembering it.
  * THE REAL CHECKOUT. Every catalogue, every spec, no fixtures. This is what makes a
    change to any of the six source files land here.
  * THE GUARD (test_guard_*), which is the deliverable: a spec, a roster, a matrix or a
    declaration can each be changed in a way that FAILS. `test_guard_real_checkout_is_
    clean` is the one a future change trips.

WHAT THEY DO NOT PROVE. Nothing here runs Playwright, a browser, a seeder or a mesh:
every fact is read from committed source. The index is a TEXT analysis, not a
TypeScript parse, so a spec that computes its actor from data absent from the source
(an env-supplied handle, a fixture read at runtime) is NOT understood — it trips the
actor-less guard instead, and that behaviour is asserted, but "trips a guard" is a
long way from "is indexed correctly". The role-agreement check compares two DECLARED
lists; neither is the mesh, so it cannot see a role Casdoor actually holds. And the
federated-acct rule is asserted to work on the one such handle that exists (spec 21)
and asserted to have exactly the misattribution limitation the module documents.
"""
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import e2e_personas as ep
from hugmesh_studio.core.e2e_catalogue import gated_personas
from hugmesh_studio.core.e2e_personas import (
    CAT_DECLARED, CAT_GAMES_MATRIX, CAT_GAMES_ROSTER, CAT_GATE_LIST, CAT_RBAC_MATRIX,
    CAT_SEED_ROSTER, CAT_SWARM, FINDING_ACTORLESS, FINDING_RESURRECTED,
    FINDING_ROLE_DRIFT, FINDING_SYNC_ONLY, FINDING_UNKNOWN, FINDING_UNSEEDED,
    MECH_ACCT, MECH_CALLSITE, MECH_CATALOGUE, MECH_DECLARED, MECH_LITERAL,
    NEVER_SEEDED_VAR, REALM_GAMES, MatrixPersona, PersonaIndex,
    blank_strings, conditional_operator, declared_never_seeded, extract_uses,
    guard_failures, load_persona_index, parse_games_roster, parse_matrix, parse_swarm,
    parse_superadmin_username, persona_taking_functions, strip_ts,
)
from hugmesh_studio.core.seeded_credentials import Roster, SeededUser, load_roster

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _rbac_text():
    with open(os.path.join(GENERATOR_DIR, ep.RBAC_ROLES_TS), encoding="utf-8") as fh:
        return strip_ts(fh.read())


@pytest.fixture(scope="module")
def index():
    return load_persona_index(GENERATOR_DIR)


def _index_over(sources, *, roster=None, gated=()):
    """An index over SYNTHETIC spec sources plus the REAL helper modules.

    The helpers are not optional scenery: the index learns which arguments are
    personas by reading helpers.ts's own function signatures, so a synthetic spec
    calling ``registerOnly(page, 'x')`` against a helpers-free source set would
    exercise a different resolution path than the checkout does. The real ``.spec.ts``
    files are excluded so a synthetic guard finding stands alone.
    """
    real = {fn: text for fn, text in ep.spec_sources(GENERATOR_DIR).items()
            if not fn.endswith(".spec.ts")}
    assert "helpers.ts" in real
    real.update({k: strip_ts(v) for k, v in sources.items()})
    return load_persona_index(GENERATOR_DIR, roster=roster, gated=gated, sources=real)


# ── comment/string handling: the two scanners everything else stands on ─────────

def test_strip_ts_is_string_aware_where_a_regex_is_not():
    # `/bff/superadmin/**` really is in rbac-roles.ts (SUPERADMIN_ALLOW_ROUTES). A
    # naive /\*.*?\*/ reads the `/*` inside that STRING as a comment opener and eats
    # everything to the next `*/` — which is how a structural parse silently returns
    # an empty catalogue instead of failing.
    # This is the real shape: rbac-roles.ts's e2e-superadmin row carries a `note:`
    # string mentioning '/bff/superadmin/**', and the NEXT row follows before the next
    # `*/` in the file.
    src = ("const users = [\n"
           "  { username: 'e2e-superadmin', note: 'reaches /bff/superadmin/**' },\n"
           "  { username: 'e2e-admin' },\n"
           "];\n"
           "/** a real doc comment */\n")
    got = strip_ts(src)
    assert "/bff/superadmin/**" in got
    assert "a real doc comment" not in got
    assert "e2e-admin" in got

    import re
    naive = re.sub(r"(?m)^[ \t]*//.*$", "",
                   re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL))
    assert "e2e-admin" not in naive, (
        "the naive stripper is supposed to be broken here — if it is not, this test "
        "no longer justifies the string-aware one")


def test_strip_ts_drops_comments_so_prose_personas_are_not_counted():
    # Spec 18 names five personas in prose and drives none: every one of its tests is
    # a test.skip placeholder. Crediting it with that cast is the exact flattery the
    # tree must not do.
    got = strip_ts("// drive e2e-gamesadmin here one day\nconst x = 1;\n")
    assert "e2e-gamesadmin" not in got


def test_blank_strings_blanks_contents_and_preserves_offsets():
    # The escape (`\\'`) is deliberate: it is the one branch that consumes TWO
    # characters, so it is the one place an off-by-one shortens the output and slides
    # every later offset left. Offsets are what `_call_args` indexes back into the RAW
    # text with, so a shifted one reads a call's arguments from the wrong place.
    src = ("const m = 'SYSTEMS_SEED_USERS isn\\'t code'; foo(SYSTEMS_SEED_USERS);")
    got = blank_strings(src)
    assert len(got) == len(src), "offsets must survive an escape sequence"
    assert got.count("SYSTEMS_SEED_USERS") == 1        # the code one only
    assert got.index("SYSTEMS_SEED_USERS") == src.rindex("SYSTEMS_SEED_USERS")


# ── the typed RBAC matrix ───────────────────────────────────────────────────────

def test_matrix_parses_the_real_catalogue_with_its_expectations():
    matrix = parse_matrix(_rbac_text(), "SYSTEMS_SEED_USERS", ep.REALM_SYSTEMS)
    by = {u.username: u for u in matrix}
    assert len(matrix) == len(by) > 10, "every row must have a distinct username"
    # The rows that carry EXPECTATIONS — the reason this catalogue is not a duplicate
    # of the shell roster. Each is asserted by name because dropping any one of them
    # turns a real assertion into a comment.
    assert by["e2e-gamesadmin"].expect_games_admin is True
    assert by["e2e-gamesonly"].expect_games_admin is False
    assert by["e2e-pending"].registration_complete is False
    assert by["e2e-pending"].roles == ()
    assert by["e2e-matrix"].federation_control is True
    assert by["e2e-matrix-domainlocked"].federation_probe == "matrix"
    assert by["e2e-matrix-domainlocked"].federation_control is False
    assert by["e2e-denied"].pinned_deny_route.startswith("/bff/admin/")
    assert by["e2e-mod"].roles == ("ROLE_MOD",)
    assert all(u.realm == ep.REALM_SYSTEMS for u in matrix)


def test_matrix_username_resolves_the_env_default_not_the_environment(monkeypatch):
    # The superadmin row is `process.env.CASDOOR_SUPERADMIN_USERNAME ?? 'e2e-…'`.
    # Reading the ambient env would make the index name a persona a normal run never
    # creates — and make its answer depend on the shell it was invoked from.
    monkeypatch.setenv("CASDOOR_SUPERADMIN_USERNAME", "minted-operator-9")
    names = {u.username for u in parse_matrix(_rbac_text(), "SYSTEMS_SEED_USERS",
                                              ep.REALM_SYSTEMS)}
    assert "minted-operator-9" not in names
    assert parse_superadmin_username(_rbac_text()) in names


def test_games_matrix_records_the_sync_origin():
    games = parse_matrix(_rbac_text(), "GAMES_SEED_USERS", REALM_GAMES)
    synced = [u for u in games if u.synced_from_systems]
    assert synced, ("GAMES_SEED_USERS must keep a syncedFromSystems row, or the index "
                    "reports a deliberately un-seeded identity as a missing one")
    assert all(u.realm == REALM_GAMES for u in games)


def test_a_row_that_omits_registration_complete_is_complete():
    # The default matters and is otherwise unpinned: every committed row states
    # `registrationComplete` explicitly, so flipping the default is behaviour-neutral
    # against the checkout — until someone adds a row without it, at which point a
    # False default silently drops that persona out of every platform pool
    # (_platform_personas filters on it) and out of spec 05/06/10/11's cast.
    # Laid out like the real catalogue: `_roles_field` anchors `roles:` to the start
    # of a line, which is how every committed row is written.
    src = ("export const T: SystemsSeedUser[] = [\n"
           "  {\n    username: 'quiet',\n    roles: ['ROLE_MATRIX'],\n  },\n"
           "  {\n    username: 'pending',\n    roles: ['ROLE_MATRIX'],\n"
           "    registrationComplete: false,\n  },\n"
           "];\n")
    rows = parse_matrix(src, "T", ep.REALM_SYSTEMS)
    assert [(u.username, u.registration_complete) for u in rows] \
        == [("quiet", True), ("pending", False)]
    assert [u.username for u in ep._platform_personas(rows, "ROLE_MATRIX")] == ["quiet"]


def test_matrix_parse_survives_a_typed_array_declaration():
    # `SystemsSeedUser[]` in the declaration: excluding '[' from the gap before '='
    # makes the search miss the array and report ZERO personas as the truth.
    src = ("export const T: Thing[] = [\n"
           "  { username: 'a-one', roles: ['ROLE_USER'], registrationComplete: true },\n"
           "];\n")
    assert [u.username for u in parse_matrix(src, "T", ep.REALM_SYSTEMS)] == ["a-one"]


# ── the swarm: a generator, never a table ───────────────────────────────────────

def test_swarm_is_a_pattern_and_a_count_not_126_rows():
    swarm = parse_swarm(_rbac_text())
    assert not swarm.error
    tiers = {g.tier: g for g in swarm.groups}
    assert set(tiers) == {"user", "mod", "admin"}
    assert swarm.total == sum(g.count for g in swarm.groups) > 100
    assert tiers["user"].count > tiers["mod"].count > tiers["admin"].count
    assert "NNN" in tiers["user"].pattern
    # Each tier's roles are ITS OWN. A single flat search over generateSwarm() pairs
    # the admin tier's marker with the user tier's roles and hands back three tiers'
    # worth concatenated.
    assert "ROLE_MOD" in tiers["mod"].roles and "ROLE_MOD" not in tiers["user"].roles
    assert "ROLE_ADMIN" in tiers["admin"].roles and "ROLE_ADMIN" not in tiers["mod"].roles
    assert len(tiers["user"].roles) < 6
    assert "SWARM_USERS" in tiers["user"].count_source


def test_swarm_members_are_matched_without_being_materialised(index):
    assert index.matches_generated("e2e-swarm-user-042").tier == "user"
    assert index.matches_generated("e2e-swarm-mod-3").tier == "mod"
    assert index.matches_generated("e2e-admin") is None
    # …and none of the 126 leaked into the persona table.
    assert not [n for n in index.personas if index.matches_generated(n)]
    assert index.catalogue_counts()[CAT_SWARM] == index.swarm.total


def _named_swarm_members(index, spec):
    """The names in ``spec``'s cast that belong to the procedural swarm.

    EMPTY is the healthy answer: the population is reported as a pattern and a count
    (``generated_count``) and never as named actors. A non-empty answer means it was
    unrolled, whether by a spec spelling a member out or by the index materialising
    the whole population."""
    return [n for n in spec.usernames if index.matches_generated(n)]


def test_the_swarm_spec_reports_generated_actors_and_names_only_its_two_live_ui_actors(
        index):
    """Spec 24 draws from TWO populations, and the index has to keep them apart.

      * the swarm: 126 procedural identities out of ``swarm()``, reported as a pattern
        and a count (``generated_count``) and never as named rows;
      * the two actors section (E) names since #626: ``e2e-user`` (sees the admin
        launcher card DISABLED, with helptext) and ``e2e-admin`` (the positive control,
        so a shell that greyed the card for everyone would fail). Ordinary seeded
        personas, not swarm members.

    This test used to assert ``usernames == ()``. That was true while (E) was a
    ``test.skip`` stub, but it stood in for a different claim, "the swarm is not
    unrolled", and #626 broke the stand-in while the claim stayed true. The claim is
    asserted directly now (``_named_swarm_members``), and the named cast is pinned BY
    NAME, as PLATFORM_POOLS is, so a third actor is a deliberate edit here and not a
    silent one."""
    sweep = index.for_spec("24-final-e2e-sweep.spec.ts")
    assert sweep.generated_count == index.swarm.total
    assert not _named_swarm_members(index, sweep), (
        "spec 24's swarm is procedural; naming any member of it here means the "
        "population was unrolled after all")
    assert set(sweep.usernames) == {"e2e-user", "e2e-admin"}, (
        "spec 24 names exactly its two section (E) actors; a different cast is a "
        "roster change, so update this pin on purpose")
    assert all(u.known for u in sweep.uses), "a named actor that no catalogue provisions"
    assert sweep.drives_personas and not sweep.actor_less


def test_a_spec_that_spells_out_a_swarm_member_counts_as_unrolling_it():
    """The negative control for the test above. ``_named_swarm_members`` is only worth
    asserting EMPTY if it can be non-empty: a spec that onboards ``e2e-swarm-user-042``
    by name is exactly the unrolled shape, and a real persona beside it must not be
    flagged."""
    idx = _index_over({"x.spec.ts": (
        "import {registerOnly} from './helpers';\n"
        "test('t', async ({page}) => {\n"
        "  await registerOnly(page, 'e2e-swarm-user-042');\n"
        "  await registerOnly(page, 'e2e-admin');\n"
        "});\n")})
    spec = idx.for_spec("x.spec.ts")
    assert _named_swarm_members(idx, spec) == ["e2e-swarm-user-042"]
    assert "e2e-admin" in spec.usernames


# ── the shell side ──────────────────────────────────────────────────────────────

def test_games_roster_is_parsed_from_the_seeder():
    with open(os.path.join(GENERATOR_DIR, ep.SEED_ACCOUNTS_SH), encoding="utf-8") as fh:
        got = parse_games_roster(fh.read())
    assert got, "GAMES_ROLE_USERS must parse, or games personas read as unknown ones"
    assert all(name and roles for name, roles in got)


def test_the_operator_account_is_reported_as_conditional():
    name, why = conditional_operator(GENERATOR_DIR)
    assert name, "seed-e2e.sh must declare LOCAL_OPERATOR_USER"
    assert "SEED_COMPLETE_REGISTRATION=1" in why, (
        "the terminal `make stack-seed` lane does NOT create this account; rendering "
        "it as ordinary sends a terminal-lane operator to a login that is not there")


def test_persona_taking_functions_are_read_from_their_declarations():
    funcs = persona_taking_functions({
        "helpers.ts": "export async function onboard(page: Page, username: string,"
                      " password = P): Promise<S> {}\n"
                      "export async function shot(page: Page, name: string) {}\n",
        "x.spec.ts": "async function loginAs(api: C, username: string) {}\n",
    })
    assert funcs["onboard"] == 1 and funcs["loginAs"] == 1
    assert "shot" not in funcs, "shot() takes a screenshot name, not an actor"


# ── derivation rules, on synthetic sources ──────────────────────────────────────

def _uses(spec_src, **kw):
    idx = _index_over({"x.spec.ts": spec_src})
    return {u.username: u for u in idx.for_spec("x.spec.ts").uses}


def test_a_literal_in_a_helpers_persona_argument_is_an_actor():
    got = _uses("import {registerOnly} from './helpers';\n"
                "test('t', async ({page}) => { await registerOnly(page, 'dragoneer'); });\n")
    assert got["dragoneer"].mechanism == MECH_CALLSITE


def test_a_password_default_is_not_an_actor():
    # `process.env.E2E_PASSWORD ?? 'e2e-pass'` appears in six files. Shape alone puts
    # 'e2e-pass' in the persona table of every one of them.
    got = _uses("const P = process.env.E2E_PASSWORD ?? 'e2e-pass';\n"
                "const Q = process.env.E2E_SWARM_PASSWORD || 'e2e-swarm-pass';\n")
    assert got == {}


def test_a_non_persona_object_key_is_not_an_actor():
    # spec 28 posts `{ name: 'e2e-part', headArchetype: 'round' }` — a character part.
    got = _uses("const r = await api.post('/x', { data: { name: 'e2e-part' } });\n"
                "const p = { username: 'e2e-mod' };\n")
    assert set(got) == {"e2e-mod"}


def test_a_catalogue_named_inside_a_message_string_is_not_an_iteration():
    got = _uses("throw new Error('add a persona to SYSTEMS_SEED_USERS + seed-accounts.sh');\n")
    assert got == {}, ("a failure MESSAGE that mentions the catalogue must not turn a "
                       "three-actor spec into a seventeen-actor one")


#: The platform-access pools, pinned BY NAME. Deriving these from
#: :func:`ep._platform_personas` would make every assertion below CIRCULAR — the
#: expectation and the subject would be the same call, and deleting an exclusion from
#: the filter could not fail any of them. Measured against the committed catalogue on
#: 2026-08-26; a roster change is SUPPOSED to land here.
PLATFORM_POOLS = {
    "ROLE_MATRIX": ["e2e-matrix", "e2e-matrix-groupchat", "e2e-matrix-external-client"],
    "ROLE_MASTODON": ["e2e-mastodon", "e2e-mastodon-external-client"],
}


def test_the_platform_pools_are_the_named_ones_and_the_excluded_rows_exist():
    matrix = parse_matrix(_rbac_text(), "SYSTEMS_SEED_USERS", ep.REALM_SYSTEMS)
    for role, expected in PLATFORM_POOLS.items():
        got = [u.username for u in ep._platform_personas(matrix, role)]
        assert got == expected, (
            f"{role} platform pool changed: {got} != {expected}. If the roster really "
            "grew or lost a platform persona, update PLATFORM_POOLS here AND check the "
            "specs that slice it (05/06/10/11 take two, 31 takes three).")
    # ...and the rows the filter is supposed to REMOVE are still in the catalogue,
    # each still carrying the base role. Without this the pins above would pass
    # vacuously on a roster that had simply dropped the domain-locked identities,
    # and the exclusion would be untested rather than satisfied.
    locked = {u.username: u.roles for u in matrix if "domainlocked" in u.username}
    assert set(locked) == {"e2e-matrix-domainlocked", "e2e-mastodon-domainlocked"}
    assert "ROLE_MATRIX" in locked["e2e-matrix-domainlocked"]
    assert "ROLE_MASTODON" in locked["e2e-mastodon-domainlocked"]


def test_the_platform_filter_drops_locked_and_registration_incomplete_holders():
    # Both halves of the mirror, on a SYNTHETIC matrix so neither depends on the
    # roster happening to contain a row that exercises it. The real catalogue has no
    # registration-incomplete platform-role holder today, so that half is otherwise
    # unpinned: deleting `u.registration_complete` from the filter would be
    # behaviour-neutral against the checkout and survive silently.
    rows = (
        MatrixPersona(username="keep", roles=("ROLE_MATRIX",)),
        MatrixPersona(username="locked",
                      roles=("ROLE_MATRIX", "ROLE_MATRIX_DOMAINLOCKED")),
        MatrixPersona(username="pending", roles=("ROLE_MATRIX",),
                      registration_complete=False),
        MatrixPersona(username="other-platform", roles=("ROLE_MASTODON",)),
    )
    assert [u.username for u in ep._platform_personas(rows, "ROLE_MATRIX")] == ["keep"]
    assert [u.username for u in ep._platform_personas(rows, "ROLE_MASTODON")] \
        == ["other-platform"]


def test_platform_personas_resolve_through_the_real_catalogue_filter():
    got = _uses("import {requirePlatformPersonas} from './helpers';\n"
                "const [A, B] = requirePlatformPersonas('ROLE_MATRIX', 2);\n")
    assert list(got) == PLATFORM_POOLS["ROLE_MATRIX"][:2]
    assert all(u.mechanism == MECH_CATALOGUE for u in got.values())
    # The domain-locked holders carry ROLE_MATRIX and are excluded on purpose: they
    # are the SUBJECT of specs 19-23, and listing them as ordinary Matrix actors tells
    # the operator the wrong story about which proof they belong to.
    assert not any("domainlocked" in n for n in got)


def test_a_two_actor_mastodon_call_excludes_the_domain_locked_holder():
    # ROLE_MASTODON is where the exclusion BITES on a two-actor slice: its
    # domain-locked holder sorts SECOND in the catalogue, so dropping the filter
    # swaps spec 06's second actor for it. In ROLE_MATRIX the locked row sorts THIRD
    # and never enters a 2-slice, which is why a ROLE_MATRIX-only assertion cannot
    # see the mutation at all.
    got = _uses("import {requirePlatformPersonas} from './helpers';\n"
                "const [A, B] = requirePlatformPersonas('ROLE_MASTODON', 2);\n")
    assert list(got) == PLATFORM_POOLS["ROLE_MASTODON"]
    assert not any("domainlocked" in n for n in got)


def test_an_unsliced_platform_persona_call_takes_the_whole_pool():
    got = _uses("import {platformPersonas} from './helpers';\n"
                "const ALL = platformPersonas('ROLE_MATRIX');\n")
    assert list(got) == PLATFORM_POOLS["ROLE_MATRIX"]
    assert len(PLATFORM_POOLS["ROLE_MATRIX"]) > 2, (
        "spec 31 needs three; if the pool shrank, the roster changed and "
        "requirePlatformPersonas would now throw")


def test_a_federated_address_is_attributed_to_the_persona_it_is_drawn_from():
    got = _uses("const acct = `e2e-admin@mastodon.hugmesh.net`;\n")
    assert set(got) == {"e2e-admin"}
    assert got["e2e-admin"].mechanism == MECH_ACCT
    assert "e2e-admin@mastodon.hugmesh.net" in got["e2e-admin"].detail


def test_an_unknown_handle_is_not_swallowed_by_the_acct_rule():
    # The documented limitation is <known>@<anything>. A handle whose LOCAL part is
    # unknown must still reach the guard rather than being explained away.
    idx = _index_over({"x.spec.ts": "const acct = 'nobody-here@mastodon.hugmesh.net';\n"})
    assert [f.kind for f in idx.blocking] == [FINDING_UNKNOWN]


def test_one_edge_per_persona_labelled_with_the_strongest_mechanism():
    got = _uses("import {SYSTEMS_SEED_USERS, systemsUser} from './rbac-roles';\n"
                "for (const u of SYSTEMS_SEED_USERS) {}\n"
                "const M = systemsUser('e2e-mod');\n"
                "const s = 'e2e-mod';\n")
    assert got["e2e-mod"].mechanism == MECH_CATALOGUE
    assert sum(1 for u in _index_over({"x.spec.ts":
               "import {systemsUser} from './rbac-roles';\n"
               "const M = systemsUser('e2e-mod'); const s = 'e2e-mod';\n"
               }).for_spec("x.spec.ts").uses if u.username == "e2e-mod") == 1


def test_a_never_seeded_declaration_wins_over_every_other_mechanism():
    src = ("import {registerOnly} from './helpers';\n"
           f"export const {NEVER_SEEDED_VAR}: readonly string[] = ['mallory@gmail.com'];\n"
           "await registerOnly(page, 'mallory@gmail.com');\n")
    assert declared_never_seeded(src) == ("mallory@gmail.com",)
    got = _uses(src)
    assert got["mallory@gmail.com"].mechanism == MECH_DECLARED


def test_uses_are_ordered_strongest_mechanism_first(index):
    # Named after the mutation that found it: reordering MECH_PRECEDENCE so
    # MECH_DECLARED sorts LAST changed nothing any other test could see, because the
    # declaration step overrides by popping rather than by precedence. Ordering is
    # still a contract: a spec's never-seeded handle is the row that changes what a
    # reader should DO ("do not add this to the roster"), and a table that buries it
    # under the ordinary actors is the table that gets it seeded by mistake.
    for sp in index.by_spec.values():
        ranks = [ep.MECH_PRECEDENCE.index(u.mechanism) for u in sp.uses]
        assert ranks == sorted(ranks), sp.spec_file
    decl = index.for_spec("03-register-gating.spec.ts")
    assert len(decl.uses) > 1
    assert decl.uses[0].mechanism == MECH_DECLARED, (
        "the handle that must NEVER be provisioned leads its spec's table")


# ── the real checkout ───────────────────────────────────────────────────────────

def test_every_spec_file_is_indexed(index):
    on_disk = {fn for fn in os.listdir(os.path.join(GENERATOR_DIR, ep.SPECS_DIR))
               if fn.endswith(".spec.ts")}
    assert on_disk and set(index.by_spec) == on_disk


def test_the_index_reads_the_real_catalogues_without_a_gap(index):
    assert not index.problems, index.problems
    counts = index.catalogue_counts()
    assert counts[CAT_SEED_ROSTER] > counts[CAT_RBAC_MATRIX] > 10
    assert counts[CAT_GAMES_ROSTER] and counts[CAT_GAMES_MATRIX]
    assert counts[CAT_DECLARED] and counts[CAT_GATE_LIST]


def test_specs_that_hardcode_and_specs_that_iterate_both_resolve(index):
    # The two ends of the spread the module exists to bridge: a spec that names a
    # literal, and a spec whose cast is whatever the catalogue holds today.
    hardcoded = index.for_spec("04-five-users.spec.ts")
    assert len(hardcoded.usernames) == 5
    assert all(u.mechanism == MECH_LITERAL for u in hardcoded.uses)
    iterating = index.for_spec("12-rbac-gateway-route-access.spec.ts")
    matrix = {u.username for u in parse_matrix(_rbac_text(), "SYSTEMS_SEED_USERS",
                                              ep.REALM_SYSTEMS)}
    assert set(iterating.usernames) == matrix
    assert all(u.mechanism == MECH_CATALOGUE for u in iterating.uses)


def test_the_platform_specs_cast_the_named_personas(index):
    # The pools, as the REAL index renders them for the specs an operator reads. This
    # is the assertion a change to the platform filter has to get past: spec 06 takes
    # a two-slice of ROLE_MASTODON (where the domain-locked holder sorts second), and
    # spec 31 takes the whole ROLE_MATRIX pool.
    assert index.for_spec("06-mastodon-post.spec.ts").usernames \
        == tuple(PLATFORM_POOLS["ROLE_MASTODON"])
    assert set(index.for_spec("31-matrix-group-chat.spec.ts").usernames) \
        == set(PLATFORM_POOLS["ROLE_MATRIX"])
    assert index.for_spec("05-matrix-chat.spec.ts").usernames \
        == tuple(PLATFORM_POOLS["ROLE_MATRIX"][:2])
    # No spec that only asks for platform access is handed a domain-locked identity.
    for fn in ("05-matrix-chat.spec.ts", "06-mastodon-post.spec.ts",
               "10-matrix-call.spec.ts", "11-matrix-chat-and-call.spec.ts",
               "31-matrix-group-chat.spec.ts", "32-matrix-chat3d.spec.ts"):
        assert not [n for n in index.for_spec(fn).usernames if "domainlocked" in n], fn


def test_the_console_matrix_spec_declaration_is_read(index):
    # 33-console-access-matrix.spec.ts is the pattern the brief pointed at: it already
    # declares `PERSONAS` with `username:` keys, and needed NO edit for the index to
    # read it — including mesh-operator, which matches no persona shape.
    got = index.for_spec("33-console-access-matrix.spec.ts")
    assert "mesh-operator" in got.usernames
    assert {"e2e-admin", "e2e-mod", "e2e-user"} <= set(got.usernames)


def test_the_federated_announcement_spec_resolves_to_its_persona(index):
    got = index.for_spec("21-nofed-admin-announcement-local.spec.ts")
    assert got.usernames == ("e2e-admin",)
    assert got.uses[0].mechanism == MECH_ACCT


def test_specs_that_drive_nobody_are_reported_as_driving_nobody(index):
    # Honest emptiness, not a failure: spec 30 logs nobody in. An index that invented
    # actors for it would be lying in the direction that flatters the suite. Specs 01
    # (#293's e2e-user positive control) and 18 (its live games-entry matrix replaced
    # the all-skip placeholders) used to be here; they are pinned positively below.
    for fn in ("30-node-host-resolution.spec.ts",):
        got = index.for_spec(fn)
        assert got.usernames == () and not got.drives_personas, fn


def test_the_rbac_pending_spec_drives_the_games_personas_it_now_asserts(index):
    got = index.for_spec("18-rbac-phase8-10-pending.spec.ts")
    assert got.drives_personas
    assert {"e2e-gamesonly", "e2e-gamesadmin"} <= set(got.usernames)


def test_the_frontpage_spec_drives_e2e_user_through_its_positive_control(index):
    # #293 added `registerOnly(page, 'e2e-user', personaPassword('e2e-user'))` to spec
    # 01. Pinned positively so a silent rename back to an anonymous control is caught.
    got = index.for_spec("01-frontpage.spec.ts")
    assert got.usernames == ("e2e-user",) and got.drives_personas
    assert got.uses[0].mechanism == MECH_CALLSITE


def test_no_password_or_payload_literal_became_a_persona(index):
    for junk in ("e2e-pass", "e2e-swarm-pass", "e2e-part"):
        assert junk not in index.personas
        assert not [fn for fn, sp in index.by_spec.items() if junk in sp.usernames]


# ── the two catalogues, reconciled and NOT merged ───────────────────────────────

def test_the_rbac_matrix_is_a_subset_of_the_seed_roster_and_says_so(index):
    matrix = {p.username for p in index.personas.values()
              if CAT_RBAC_MATRIX in p.catalogues}
    seeded = {p.username for p in index.personas.values()
              if CAT_SEED_ROSTER in p.catalogues}
    assert matrix and matrix <= seeded, (
        "an expectation about an account nobody provisions is a 401 that reads as a "
        "broken login — this is the 2026-08-06 spec-29 failure")
    extra = seeded - matrix
    assert extra, ("the two lists describe DIFFERENT things; if they ever coincide, "
                   "re-justify keeping both rather than deleting this test")
    for name in extra:
        p = index.personas[name]
        assert not p.in_matrix
        assert p.status_display  # every row explains itself
    # Both lists are exposed; neither is presented as the other.
    assert index.personas["e2e-admin"].seeded_roles
    assert index.personas["e2e-admin"].matrix_roles
    sample = next(iter(extra))
    assert index.personas[sample].matrix_roles == ()


def test_shared_rows_agree_on_roles(index):
    assert [f for f in index.findings if f.kind == FINDING_ROLE_DRIFT] == []
    for p in index.personas.values():
        if p.in_matrix and p.seeded and p.realm == ep.REALM_SYSTEMS:
            assert set(p.seeded_roles) == set(p.matrix_roles), p.username


def test_the_games_realm_asymmetry_is_documented_not_flagged(index):
    sync = [f for f in index.findings if f.kind == FINDING_SYNC_ONLY]
    assert sync, "the systems->games synced admin row must be explained"
    assert all(not f.blocking for f in sync)
    assert "sync" in sync[0].detail.lower()


# ── personas that are broken on purpose ─────────────────────────────────────────

def test_the_deliberately_gated_personas_are_marked_and_reuse_the_one_parser(index):
    # Reused, not re-derived: e2e_catalogue already models BOTH gating mechanisms
    # (the named SEED_REGISTRATION_SKIP list AND seed-e2e.sh's `*@*` shape rule).
    expected = {g.username for g in gated_personas(GENERATOR_DIR)}
    assert expected == {p.username for p in index.gated}
    for name in ("e2e-pending", "rbac-pending-gmail-com", "e2e-banned"):
        p = index.personas[name]
        assert p.gated, f"{name} is un-onboarded ON PURPOSE — specs 17/28/29 assert it"
        assert p.gated_reason and "purpose" in p.gated_reason.lower()
        assert "gated on purpose" in p.status_display


def test_a_gated_persona_never_renders_as_an_ordinary_account(index):
    ordinary = index.personas["e2e-admin"]
    assert not ordinary.gated and "gated" not in ordinary.status_display
    for p in index.gated:
        assert p.status_display != ordinary.status_display


def test_mesh_operator_is_conditional_and_says_which_lane_lacks_it(index):
    name, _ = conditional_operator(GENERATOR_DIR)
    p = index.personas[name]
    assert p.conditional_on and "SEED_COMPLETE_REGISTRATION=1" in p.conditional_on
    assert "conditional" in p.status_display
    assert not p.gated, "conditional is not the same as gated; conflating them hides both"


def test_the_never_seeded_handles_are_declared_by_their_own_specs(index):
    declared = {p.username: p for p in index.personas.values() if p.never_seeded}
    assert declared, "at least the four measured handles must be declared"
    for name, p in declared.items():
        assert p.never_seeded_by, name
        assert not p.seeded, f"{name} is declared un-seedable and IS seeded"
        assert "NEVER" in p.status_display
    assert {"mallory@gmail.com", "rando"} <= set(declared)


# ── THE GUARD ───────────────────────────────────────────────────────────────────

def test_guard_real_checkout_is_clean(index):
    """THE deliverable. Everything below proves this can fail; this proves it is
    green now, so a future change to a spec, a roster or a matrix lands here."""
    assert index.blocking == (), "\n".join(
        f"[{f.kind}] {f.subject}: {f.detail}" for f in index.blocking)


def test_guard_a_spec_that_names_a_persona_the_index_does_not_know(index):
    idx = _index_over({"x.spec.ts": "import {onboard} from './helpers';\n"
                                    "await onboard(page, 'e2e-brand-new');\n"})
    found = [f for f in idx.blocking if f.kind == FINDING_UNKNOWN]
    assert len(found) == 1
    assert "e2e-brand-new" in found[0].subject
    # The finding must name where to fix it, or it gets suppressed instead.
    assert "e2e-extra-personas.sh" in found[0].detail
    assert NEVER_SEEDED_VAR in found[0].detail


def test_guard_an_unshaped_unknown_handle_still_fires():
    # 'wat' matches no persona shape and no catalogue: only its POSITION in a
    # persona-taking helper identifies it, which is why signatures are parsed.
    idx = _index_over({"x.spec.ts": "import {registerOnly} from './helpers';\n"
                                    "await registerOnly(page, 'wat');\n"})
    assert [f.kind for f in idx.blocking] == [FINDING_UNKNOWN]


def test_guard_a_renamed_roster_persona_breaks_the_matrix_expectation():
    # Renaming a persona in the shell roster leaves the RBAC matrix asserting about
    # an account nothing creates — a native-login 401 that reads as a broken password.
    real = load_roster(GENERATOR_DIR)
    renamed = Roster(
        users=[SeededUser(username=("e2e-mod-RENAMED" if u.username == "e2e-mod"
                                    else u.username),
                          roles=u.roles, password=u.password,
                          password_env=u.password_env) for u in real.users],
        source=real.source, operator=real.operator)
    idx = load_persona_index(GENERATOR_DIR, roster=renamed)
    unseeded = [f for f in idx.blocking if f.kind == FINDING_UNSEEDED]
    assert [f.subject for f in unseeded] == ["e2e-mod"]
    assert "never created" in unseeded[0].detail


def test_guard_role_drift_between_the_two_catalogues():
    real = load_roster(GENERATOR_DIR)
    drifted = Roster(
        users=[SeededUser(username=u.username,
                          roles=(("ROLE_ADMIN",) if u.username == "e2e-user" else u.roles),
                          password=u.password, password_env=u.password_env)
               for u in real.users],
        source=real.source, operator=real.operator)
    idx = load_persona_index(GENERATOR_DIR, roster=drifted)
    drift = [f for f in idx.blocking if f.kind == FINDING_ROLE_DRIFT]
    assert [f.subject for f in drift] == ["e2e-user"]
    assert "lock-step" in drift[0].detail


def test_guard_a_resurrected_never_seeded_handle():
    real = load_roster(GENERATOR_DIR)
    resurrected = Roster(
        users=list(real.users) + [SeededUser(username="mallory@gmail.com",
                                             roles=("ROLE_USER",), password="x")],
        source=real.source, operator=real.operator)
    idx = load_persona_index(GENERATOR_DIR, roster=resurrected)
    found = [f for f in idx.blocking if f.kind == FINDING_RESURRECTED]
    assert [f.subject for f in found] == ["mallory@gmail.com"]
    assert "vacuous" in found[0].detail


def test_guard_a_spec_whose_actors_the_index_cannot_name():
    # The tooth that keeps shape (a) honest as the suite grows a sixth grammar: a
    # spec that signs somebody in via a computed handle must FAIL, not index to an
    # empty table under a green heading.
    idx = _index_over({"x.spec.ts": "import {onboard} from './helpers';\n"
                                    "const who = process.env.WHOEVER;\n"
                                    "await onboard(page, who);\n"})
    found = [f for f in idx.blocking if f.kind == FINDING_ACTORLESS]
    assert [f.subject for f in found] == ["x.spec.ts"]
    assert "extract_uses" in found[0].detail


def test_guard_reports_a_missing_gate_list_instead_of_rendering_them_ordinary():
    idx = load_persona_index(GENERATOR_DIR, gated=())
    assert idx.gated == ()
    assert any("17/28/29" in p for p in idx.problems), idx.problems


def test_guard_a_matrix_expectation_with_no_seeder_at_all():
    # guard_failures() called directly, so the finding is pinned independently of how
    # load_persona_index happens to assemble its inputs.
    ghost = MatrixPersona(username="e2e-ghost", roles=("ROLE_USER",))
    got = guard_failures(PersonaIndex(), matrix=[ghost], games_matrix=[], games_roster=[])
    assert [(f.kind, f.subject) for f in got] == [(FINDING_UNSEEDED, "e2e-ghost")]
    assert got[0].blocking


def test_module_imports_no_qt():
    # Qt-free by contract, proven in a FRESH interpreter (this suite may import Qt
    # elsewhere, which would make an in-process check vacuous).
    studio_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    probe = (
        "import hugmesh_studio.core.e2e_personas as m, sys;"
        "assert callable(m.load_persona_index);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad;"
        "assert 'hugmesh_studio.gui' not in sys.modules"
    )
    env = dict(os.environ, PYTHONPATH=studio_root)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
