# THE SOCIAL FUNCTION MATRIX, and THE DRIFT GUARD THAT KEEPS IT HONEST.
#
# ── WHY THIS FILE IS THE DELIVERABLE AND THE OTHERS ARE ITS OUTPUT ──────────
#
# The operator asked for "every user in every function in every service ... with
# all interactions". Counted out, that is 31 seeded personas x 53 catalogued
# social functions x 3 environments x 3 interfaces. Hand-writing a scenario per
# cell would produce a feature file nobody reads and a report nobody can act on —
# decoration by volume, which this suite treats as worse than no coverage at all
# because it LOOKS like coverage.
#
# So the coverage here is generative in the only way playwright-bdd's static
# Examples tables allow, and it is generative in BOTH directions:
#
#   ../matrix|mastodon|forum/function-surface.feature
#       one row per FUNCTION; the step iterates the WHOLE ROSTER inside.
#       Seed a persona -> every function row widens, no feature edit.
#
#   THIS FILE, first outline
#       one row per PERSONA; the step iterates the WHOLE CATALOGUE inside,
#       across all three social services.
#       Catalogue a function -> every persona row widens, no feature edit.
#
# Every cell is therefore asserted twice, from two directions, out of two
# independently maintained artefacts (the hand-declared gate in
# steps/social-functions.ts, and the DEPLOYED route-access seed in
# specs/cluster/manifests/route-access/initdb/20-schema.sql).
#
# And then the DRIFT GUARD below: the scenarios that go RED when the catalogue,
# the roster and the Gherkin tree stop describing each other. Those are what stop
# this lane rotting the first time somebody adds a service function and no row.
#
# ── WHAT THIS DOES NOT PROVE ────────────────────────────────────────────────
# Nothing here contacts a homeserver. It asserts the GATE — who the deployed
# route-access contract admits — never that an endpoint exists, answers, or
# behaves. The behavioural half lives in the @env:docker journeys
# (../mastodon/interactions.feature, ../matrix/interactions.feature and the five
# pre-existing journey features), which skip loudly with the start command when
# nothing is running.
#
# RUNS WITH THE STACK DOWN, THE CLUSTER DOWN AND NO BROWSER ACTION.
@harness @layer:gateway
Feature: Every seeded persona is decided across every social function, and the catalogue cannot drift

  # ── the PERSONA axis, one row each ────────────────────────────────────────
  # The union of BOTH seeders: specs/rbac-roles.ts SYSTEMS_SEED_USERS and
  # tests/e2e-extra-personas.sh. They disagree about who exists (steps/dimensions.ts
  # documents that at length) and the union is accepted rather than a side being
  # picked, because both seeders really run against the same Casdoor.
  Scenario Outline: <role> is decided across every social function exactly as the catalogue declares @role:<role> @layer:gateway
    Then every catalogued social function is decided for this persona exactly as the catalogue declares

    Examples: every persona either seeder creates — the UNION, because both seeders really run
      | role                         |
      | admin@hugmesh.net            |
      | alice@gmail.com              |
      | bob@gmail.com                |
      | carol@gmail.com              |
      | dave@gmail.com               |
      | dragoneer                    |
      | e2e-admin                    |
      | e2e-adminonly                |
      | e2e-banned                   |
      | e2e-denied                   |
      | e2e-fleet                    |
      | e2e-forum                    |
      | e2e-gamesadmin               |
      | e2e-gamesonly                |
      | e2e-mastodon                 |
      | e2e-mastodon-domainlocked    |
      | e2e-mastodon-external-client |
      | e2e-matrix                   |
      | e2e-matrix-domainlocked      |
      | e2e-matrix-external-client   |
      | e2e-matrix-groupchat         |
      | e2e-mod                      |
      | e2e-pending                  |
      | e2e-superadmin               |
      | e2e-suspended                |
      | e2e-user                     |
      | eve@gmail.com                |
      | frank@gmail.com              |
      | rbac-approved@gmail.com      |
      | rbac-login-user@gmail.com    |
      | rbac-pending@gmail.com       |
      | rbac-plain@gmail.com         |

  # ── THE DRIFT GUARD ───────────────────────────────────────────────────────

  # A function in the catalogue that no Examples row names is a function nothing
  # executes. Comment lines are STRIPPED before the search, so a mention in prose
  # does not count — this repo has been bitten five times by a grep that read a
  # comment token as wiring.
  Scenario: a catalogued function with no scenario fails the build @layer:gateway
    Then every catalogued social function is named by an executable scenario

  # …and the mirror image: a persona nothing drives is a persona whose access
  # nobody checks. This is the 2026-08-06 e2e-fleet shape — a handle the seeder
  # created and the suite never exercised, discovered only when a spec 401'd.
  Scenario: a seeded persona with no scenario fails the build @layer:casdoor
    Then every seeded persona is named by the social function matrix

  # The INTERACTIONS half of the requirement, made checkable. Every function the
  # catalogue calls a 'pair' or 'group' interaction must either name a .feature
  # that really exists on disk and drives it, or say in one sentence why it is
  # not driven yet. A silent gap is how "all interactions" becomes a claim
  # nobody can falsify.
  Scenario: every multi-party interaction is driven or has a written reason @layer:ui
    Then every multi-party social function names a driven journey or a written reason

  # The ROSTER GAP tripwire, in both directions. A function nobody can perform is
  # coverage that can never exist; the catalogue must say so out loud
  # (expectNoPersona + the reason) rather than leave it to be discovered. And the
  # day such a gap CLOSES — somebody seeds a ROLE_FORUM_MOD persona — this fails,
  # which is the prompt to go and write the journey. Same shape as
  # ../uncovered-services/access-role-roster.feature uses for wiki/owncast/tube.
  Scenario: every function is reachable by somebody, or the gap is declared @layer:casdoor
    Then every catalogued social function is reachable by a seeded persona or declares the gap

  # A probe path that matches NO route-access pattern is default-denied for
  # everyone, so its row would pass for the wrong reason forever. Only a gate
  # declared `rowless` may legally match nothing — and if a rowless surface ever
  # GAINS a row, that is a posture change and this goes red.
  Scenario: every probe path resolves to a real pattern, and the rowless one to none @layer:gateway
    Then every catalogued probe path resolves to a real route-access pattern

  # The catalogue may not quietly shrink. Floors, not exact counts: growth is the
  # expected direction and should never need an edit here, but a roster or
  # catalogue that SHRINKS turns proofs into vacuum.
  Scenario: the matrix has not shrunk @layer:gateway
    Then the social function matrix sweeps at least 31 personas and 53 functions

  Scenario: every social service carries functions @layer:gateway
    Then every social service the catalogue covers carries at least one function

  # WHY THIS MATRIX READS THE SQL, AND WHY THAT IS NOW THE SAME TABLE THE 33
  # HANDWRITTEN SPECS READ. This scenario used to pin a GAP: the TypeScript
  # mirror was hand-copied, carried 50 of the seed's 150 rows, and the property
  # worth asserting was "it lags but never contradicts". THAT GAP CLOSED on
  # 2026-08-26 — tests/e2e/specs/rbac-route-access.ts now re-exports
  # rbac-route-access.seed.ts, which scripts/gen-route-access-oracle.py GENERATES
  # from this very SQL (tests/scripts/test-route-access-oracle.sh gates the
  # generator; this asserts it from the CONSUMER side, where the function matrix
  # actually decides).
  #
  # The old assertion did not merely become redundant, it became FALSE, and it
  # said so itself: it required "the seed carries rows beyond the mirror" and
  # failed with "the mirror is not a strict SUBSET but a copy ... this scenario
  # should be deleted rather than left claiming a gap that closed". MEASURED on
  # the merged tree: seed 152 rows, mirror 152 rows, 0 beyond the mirror. It also
  # flagged 4 rows as contradictions that are the seed's EXPLICIT DENY rows — the
  # subset test never modelled `allow`, and the generated mirror carries it.
  #
  # So the pin moves to the relationship that now holds, in BOTH directions and
  # including allow/deny: a row either table gains without the other is named.
  Scenario: the TypeScript route-access mirror is generated from the deployed seed and agrees with it exactly @layer:gateway
    Then the route-access mirror the handwritten specs use agrees with the deployed seed exactly

  # The whole matrix in ONE assertion. The per-row scenarios above exist for the
  # REPORT (reporters/hugmesh-reporter.ts pivots perRole off the test title);
  # this exists for the PROOF, so a run that somehow lost the rows still cannot
  # report a green matrix.
  Scenario: every persona x function cell agrees with the deployed contract @layer:gateway
    Then the social function catalogue and the route-access seed agree on every cell
