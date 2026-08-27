# THE DRIFT GUARD for the media/games function surface — and the reason the
# scenarios beside it are output rather than decoration.
#
# WHAT WENT WRONG BEFORE. owncast, tube, games and the two character tools each
# got their first e2e coverage last round: a console opens, a nav renders, a route
# resolves. That is a real result and it is also the shape of coverage that ages
# worst, because it answers "is the page there" and never "can anybody publish a
# stream / watch a download / launch an instance / save a character". Those are
# FUNCTIONS. Four of them can be driven by a seeded persona today; six exist and
# have literally no audience; seven have nothing mounted to drive at all. Nothing
# in the suite could tell those three cases apart, so nothing could report the
# difference shrinking or growing.
#
# WHAT THIS FEATURE DOES. It is the census and the tripwires, all offline:
#
#   1. THE CENSUS. Every function in steps/function-catalogue.ts must be named by
#      a scenario tagged '@function:<id>' somewhere under features/. Add a
#      function to the catalogue and this goes RED until a scenario exists — a
#      PENDING one naming what it needs counts, a comment does not. That is the
#      whole anti-decoration contract: the catalogue is the claim, the tag is the
#      receipt.
#   2. THE SCOPE PIN. A service added to the catalogue but not to the census
#      Examples table would never be censused, so the table itself is checked
#      against the catalogue.
#   3. THE GATE. For every function, the role and url pattern written HERE, the
#      catalogue's copy of them, and the committed route-access seed must all
#      three agree. The seed leg is the one that bites: the gateway is
#      DEFAULT-DENY, so a function whose surface has no row is a 403 for every
#      principal however correct the UI guard above it looks.
#   4. THE ACCESS MATRIX, DERIVED. The persona sets below are not typed from
#      memory — they are computed by walking BOTH seeded rosters
#      (specs/rbac-roles.ts SYSTEMS_SEED_USERS and tests/e2e-extra-personas.sh)
#      and asking who holds a role the seed grants at that surface. Seed one more
#      persona and the computed set moves while the written one does not, and the
#      row goes red naming exactly who arrived. Coverage that expands when the
#      mesh does.
#
# WHAT THE MATRIX DELIBERATELY DOES NOT MODEL: the gateway ADMIN-BYPASS. The
# seed's own comments say admins reach a floor row "via the gateway admin-bypass",
# which is why /owncast/**, /tube/** and /social/forum/** pair no ROLE_ADMIN. So
# "reachable by exactly <nobody>" below means THE SEED NAMES NOBODY — not that
# nobody gets through. Who actually gets through is what the driven @env:docker
# scenarios in the four sibling features answer. Two honest facts, each checkable
# on its own terms, beat one blended number that is evidence for neither.
#
# Runs with the stack DOWN. Every assertion reads a file in THIS repo.
@harness @layer:gateway
Feature: Every media and games function is catalogued, gated and censused

  # ── 1 + 2. the census and its scope ────────────────────────────────────────
  Scenario Outline: every catalogued <service> function has a scenario that names it @service:<service> @layer:gateway
    Then every catalogued function of this service is named by a scenario

    Examples:
      | service          |
      | owncast          |
      | tube             |
      | games            |
      | character-studio |
      | character-forge  |

  @layer:gateway
  Scenario: the census table covers every service the catalogue carries @layer:gateway
    Then the function catalogue covers exactly the services "owncast, tube, games, character-studio, character-forge"

  # ── 3. the gate: feature file, catalogue and route-access seed agree ───────
  #
  # Read the `pattern` column as "where this function's traffic actually goes".
  # Several functions share one pattern — every owncast function except the admin
  # grant surface rides /bff/owncast/**, and both tube management consoles ride
  # /bff/tube/** — which is precisely why they are listed separately: sharing a
  # gate is the reason a regression drops BOTH and one assertion stays green on
  # the other.
  Scenario Outline: the <service> <function> function is gated by <role> at <pattern> @service:<service> @function:<function> @layer:gateway
    Then the "<function>" function is gated by "<role>" at "<pattern>"
    And the "<function>" function is catalogued as "<verdict>"

    Examples: owncast
      | service | function    | role         | pattern               | verdict     |
      | owncast | console     | ROLE_OWNCAST | /owncast/**           | ui          |
      | owncast | publish     | ROLE_OWNCAST | /bff/owncast/**       | no-audience |
      | owncast | visibility  | ROLE_OWNCAST | /bff/owncast/**       | no-audience |
      | owncast | watch       | ROLE_OWNCAST | /bff/owncast/**       | no-audience |
      | owncast | grant       | ROLE_ADMIN   | /bff/owncast/admin/** | ui          |
      | owncast | grant-audit | ROLE_OWNCAST | /bff/owncast/**       | ui          |
      | owncast | moderate    | ROLE_OWNCAST | /bff/owncast/**       | ui          |

    Examples: tube
      | service | function  | role      | pattern           | verdict     |
      | tube    | console   | ROLE_TUBE | /tube/**          | ui          |
      | tube    | queue     | ROLE_TUBE | /bff/tube/**      | no-audience |
      | tube    | watch     | ROLE_TUBE | /tube/content/**  | no-audience |
      | tube    | subscribe | ROLE_TUBE | /bff/tube/**      | absent      |
      | tube    | access    | ROLE_TUBE | /bff/tube/**      | ui          |
      | tube    | budgets   | ROLE_TUBE | /bff/tube/**      | ui          |

    Examples: games
      | service | function         | role                      | pattern                          | verdict |
      | games   | entry            | ROLE_GAMES                | /games/**                        | ui      |
      | games   | admin            | ROLE_GAMES_ADMIN          | /games/admin/**                  | ui      |
      | games   | catalogue        | ROLE_GAMES_SERVICES       | /bff/games-services/catalog/**   | absent  |
      | games   | launch           | ROLE_GAMES_SERVICES_ADMIN | /bff/games-services/instances/** | absent  |
      | games   | instance-console | ROLE_GAMES_SERVICES       | /games/servers/**                | absent  |
      | games   | operator-ui      | ROLE_GAMES_SERVICES_ADMIN | /admin/games-services/**         | absent  |

    Examples: the character tools
      | service          | function | role      | pattern                  | verdict |
      | character-studio | open     | ROLE_USER | /character-studio/**     | ui      |
      | character-studio | create   | ROLE_USER | /character-studio/**     | ui      |
      | character-studio | export   | ROLE_USER | /character-studio/**     | ui      |
      | character-studio | save     | ROLE_USER | /bff/user/**             | ui      |
      | character-forge  | open     | ROLE_USER | /character-forge/**      | ui      |
      | character-forge  | create   | ROLE_USER | /character-forge/**      | ui      |
      | character-forge  | save     | ROLE_USER | /bff/character-forge/**  | ui      |
      | character-forge  | export   | ROLE_USER | /bff/user/**             | absent  |

  # ── 4a. the derived access matrix — who the SEED names ─────────────────────
  #
  # An empty cell is the loudest row in this table. It says the seed grants that
  # surface exactly one role and NOT ONE of the 31 seeded personas holds it — the
  # whole owncast and tube function surface is in that state. The admin who does
  # reach the console gets there through the gateway admin-bypass, unnamed.
  Scenario Outline: the seed names exactly <personas> for the <service> <function> function @service:<service> @function:<function> @layer:gateway
    Then the "<function>" function is reachable by exactly the roster personas "<personas>"

    Examples: nobody at all — the six wired-but-unreachable functions
      | service | function    | personas |
      | owncast | console     |          |
      | owncast | publish     |          |
      | owncast | grant-audit |          |
      | owncast | moderate    |          |
      | tube    | console     |          |
      | tube    | queue       |          |

    Examples: the games app-store, gated on roles nothing mints
      | service | function    | personas |
      | games   | catalogue   |          |
      | games   | launch      |          |
      | games   | operator-ui |          |

    Examples: surfaces with a real seeded audience
      | service | function         | personas                                                                             |
      | owncast | grant            | admin@hugmesh.net, e2e-admin, e2e-adminonly, e2e-gamesadmin                           |
      | games   | entry            | admin@hugmesh.net, e2e-admin, e2e-adminonly, e2e-gamesadmin, e2e-gamesonly, e2e-mod   |
      | games   | instance-console | admin@hugmesh.net, e2e-admin, e2e-adminonly, e2e-gamesadmin, e2e-mod                  |

  # games/admin is the row that would be misread as a gap. ROLE_GAMES_ADMIN is
  # DERIVED — ROLE_GAMES intersect (ROLE_ADMIN union ROLE_MOD), materialised at
  # run time by the games-admin-sync job — so NO roster grants it directly and the
  # seed names nobody, while e2e-gamesadmin and e2e-superadmin really do reach
  # /games/admin on a live mesh (games-console.feature drives exactly that). The
  # two facts are both true and this scenario exists so the empty set is read as
  # "not directly granted" rather than "unreachable".
  @service:games @function:admin @layer:gateway
  Scenario: no roster grants the DERIVED games-admin role directly @service:games @function:admin @layer:gateway
    Then the "admin" function is reachable by exactly the roster personas ""
    And the "entry" function is reachable by exactly the roster personas "admin@hugmesh.net, e2e-admin, e2e-adminonly, e2e-gamesadmin, e2e-gamesonly, e2e-mod"

  # ── 4b. the complement, for the floor rows ────────────────────────────────
  #
  # /character-studio/**, /character-forge/**, /bff/user/** and
  # /bff/character-forge/** are all granted to ROLE_USER, which 28 of 31 seeded
  # handles hold — the interesting fact is the three that do NOT, and they are a
  # surprising three. e2e-superadmin carries ROLE_SUPERADMIN ALONE and e2e-mod
  # carries ROLE_MOD ALONE; neither holds ROLE_USER, so no allow row at the
  # character tools' floor names either of them. e2e-pending holds no roles at all
  # by design. A superadmin plausibly still passes on the admin-bypass; a BARE MOD
  # is named by nothing and is not an admin, which makes that the row of this
  # matrix most worth a live check.
  Scenario Outline: the <service> <function> floor names every seeded persona except three @service:<service> @function:<function> @layer:gateway
    Then the "<function>" function is refused by exactly the roster personas "e2e-mod, e2e-pending, e2e-superadmin"

    Examples:
      | service          | function |
      | character-studio | open     |
      | character-studio | create   |
      | character-studio | export   |
      | character-studio | save     |
      | character-forge  | open     |
      | character-forge  | create   |
      | character-forge  | save     |
      | character-forge  | export   |

  # ── 4c. the zero-audience tripwires ───────────────────────────────────────
  #
  # access-role-roster.feature asks this question once per SERVICE. It has to be
  # asked per FUNCTION too, because a service can have a healthy audience for its
  # console and none at all for the thing it exists to do — which is exactly
  # owncast's shape: admins govern broadcasting and nobody can broadcast.
  Scenario Outline: nothing seeded can drive the <service> <function> function @service:<service> @function:<function> @layer:casdoor
    Then the "<function>" function has no seeded persona holding its own access role

    Examples:
      | service | function         |
      | owncast | publish          |
      | owncast | visibility       |
      | owncast | watch            |
      | tube    | queue            |
      | tube    | watch            |
      | tube    | subscribe        |
      | games   | catalogue        |
      | games   | launch           |
      | games   | instance-console |
      | games   | operator-ui      |
