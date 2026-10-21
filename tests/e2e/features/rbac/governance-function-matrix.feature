# THE FUNCTION SURFACE OF THE GOVERNANCE CONSOLES — every identity, every function.
#
# WHAT THE OPERATOR ASKED FOR: "every user in every function in every service".
# features/rbac/ already crossed PERSONA x ROUTE. This file adds the FUNCTION —
# approve a user, manage the allowlist, ban/unban, grant a namespace, assign a
# role, act on the fleet, read a backing service, drive the workload console,
# curate the superadmin service catalog — and crosses all 33 of them against all
# 34 seeded identities.
#
# WHY THE BIG MATRIX IS ONE SCENARIO AND NOT 1122. 34 identities x 33 functions
# is 1122 decisions. As Gherkin rows that is decoration by volume, and adding one
# persona would leave 33 silent holes. So the catalogue in steps/governance.ts is
# the single source, "every governance function is decided for every seeded
# identity" ITERATES it, and features/rbac/governance-drift-guard.feature goes RED
# when a catalogued function, console or identity is reached by no scenario. The
# guard is the deliverable; the decisions are its output. The named rows below
# exist so a failure is LEGIBLE — two per function, one admission and one
# refusal, chosen to be the diagnostic pair rather than an arbitrary one.
#
# THE ORACLE IS THE SHIPPED SEED, NOT THE TS MIRROR. specs/rbac-route-access.ts
# carries 50 of the seed's 150 rows, and TWELVE governance patterns exist only in
# specs/cluster/manifests/route-access/initdb/20-schema.sql — the whole moderator
# console (/mod/**, /bff/mod/**), the fleet console
# (/bff/admin/phone-fleet/** -> ROLE_FLEET_ADMIN), both workload prefixes, and
# forum/wiki/owncast admin. In the mirror those patterns are simply ABSENT, so
# every identity default-denies and every DENY expectation passes without testing
# anything. ROLE_FLEET_ADMIN appears in ZERO mirror rows, which makes "the fleet
# owner reaches the fleet console" un-assertable there. So this tier decides
# against the SQL; the gap is measured and pinned in the drift guard, not papered
# over. steps/governance.ts does NOT edit the mirror — a sibling branch holds it.
#
# RUNS OFFLINE. Every step here is a pure function over two files that ship in the
# repo, so the whole tier is green with the compose stack, the kind cluster and
# every emulator DOWN.
@service:gateway @layer:gateway
Feature: Governance functions — every seeded identity against every console function

  # The catalogue declares, per function, WHICH url_pattern governs its probe and
  # WHICH roles that pattern is keyed on. Both are checked against the seed. Skip
  # this and a seed edit that re-homes a probe under a weaker pattern leaves the
  # whole matrix green while asserting a different door — which is what makes a
  # big matrix worse than no matrix.
  Scenario: the governance catalogue still describes the shipped mesh @layer:gateway
    Then the governance function catalogue agrees with the shipped route-access seed

  # Deciding against the SQL needs Spring's most-specific-pattern-wins, which
  # lives in a NON-EXPORTED function of the oracle. The transcription is not
  # trusted: both engines score every triple the mirror can generate. A previous
  # agent's transcription of this same function inverted exact-vs-glob and the
  # collision was live in the seed — see fix/superadmin-route-access-row MAJOR #3.
  Scenario: the transcribed decision engine is the same function as the oracle @layer:gateway
    Then the governance decision engine agrees with the route-access oracle on every mirrored route

  # THE GENERATIVE CORE. What the catalogue's hand-declared keying SAYS should
  # happen, versus what the shipped seed DECIDES — two independently written
  # encodings, 1122 pairs, and they must agree on all of them.
  Scenario: every identity is decided against every governance function @layer:gateway
    Then every governance function is decided for every seeded identity

  # "Who can do anything at all in THIS console" — the question an operator
  # actually asks. Asserted as an EXACT set, so a NEW admission fails too: a plain
  # member appearing on the mod console is as much a defect as a moderator losing
  # it, and only an exact-set assertion catches the first kind.
  Scenario Outline: the <console> console admits exactly its own tier @layer:gateway
    Then the "<console>" governance console admits exactly the identities "<identities>"

    Examples:
      | console       | identities                                                                                              |
      | admin         | admin@hugmesh.net,e2e-admin,e2e-adminonly,e2e-gamesadmin,e2e-swarm-admin-0                               |
      | mod           | admin@hugmesh.net,e2e-admin,e2e-adminonly,e2e-gamesadmin,e2e-mod,e2e-swarm-admin-0,e2e-swarm-mod-0       |
      | superadmin    | e2e-superadmin                                                                                          |
      | fleet         | admin@hugmesh.net,e2e-admin,e2e-adminonly,e2e-fleet,e2e-gamesadmin,e2e-superadmin,e2e-swarm-admin-0      |
      | games-admin   | e2e-gamesadmin                                                                                          |
      | service-admin | admin@hugmesh.net,e2e-admin,e2e-adminonly,e2e-gamesadmin,e2e-swarm-admin-0                              |
      | gateway       |                                                                                                         |
      # The PUBLIC door. Every identity the two seeders create reaches it — the
      # banned, the un-onboarded and the role-less included — because the gate is
      # what happens after the door. This row is also the identity-side drift
      # guard: adding a persona to either seeder and not to this list fails here.
      | login         | admin@hugmesh.net,alice@gmail.com,bob@gmail.com,carol@gmail.com,dave@gmail.com,dragoneer,e2e-admin,e2e-adminonly,e2e-banned,e2e-denied,e2e-fleet,e2e-forum,e2e-gamesadmin,e2e-gamesonly,e2e-mastodon,e2e-mastodon-domainlocked,e2e-mastodon-external-client,e2e-matrix,e2e-matrix-domainlocked,e2e-matrix-external-client,e2e-matrix-groupchat,e2e-mod,e2e-pending,e2e-superadmin,e2e-suspended,e2e-swarm-admin-0,e2e-swarm-mod-0,e2e-swarm-user-000,e2e-user,eve@gmail.com,frank@gmail.com,rbac-approved@gmail.com,rbac-login-user@gmail.com,rbac-pending@gmail.com,rbac-plain@gmail.com |

  # ═════════════════════════════════════════════════════════════════════════
  # THE NAMED ROWS — two per catalogued function, the diagnostic pair.
  # The DENY half is chosen to be a NEAR MISS (the neighbouring tier, the other
  # half of a derived role, the service member who is not its administrator), so
  # the row states a boundary rather than restating that a stranger is a stranger.
  # ═════════════════════════════════════════════════════════════════════════
  Scenario Outline: <identity> is <decision> the <function> function @layer:gateway
    Then the identity "<identity>" is "<decision>" the "<function>" governance function

    # ── ADMIN CONSOLE. Keyed on ROLE_ADMIN alone. Note route-access-view and
    #    admin-workload-console: the SUPERADMIN is refused, because superadmin is
    #    a SIBLING tier and does not inherit downward any more than admin
    #    inherits upward.
    Examples:
      | identity           | decision | function               |
      | e2e-admin          | ALLOW    | user-approval          |
      | e2e-mod            | DENY     | user-approval          |
      | e2e-adminonly      | ALLOW    | allowlist-manage       |
      | e2e-user           | DENY     | allowlist-manage       |
      | e2e-gamesadmin     | ALLOW    | role-assign            |
      | e2e-mod            | DENY     | role-assign            |
      | e2e-swarm-admin-0  | ALLOW    | feature-ban            |
      | e2e-swarm-mod-0    | DENY     | feature-ban            |
      | admin@hugmesh.net  | ALLOW    | namespace-grant        |
      | e2e-fleet          | DENY     | namespace-grant        |
      | e2e-admin          | ALLOW    | route-access-view      |
      | e2e-superadmin     | DENY     | route-access-view      |
      | e2e-admin          | ALLOW    | usage-analytics        |
      | e2e-pending        | DENY     | usage-analytics        |
      | e2e-admin          | ALLOW    | domain-lock            |
      | e2e-banned         | DENY     | domain-lock            |
      | e2e-adminonly      | ALLOW    | image-builds           |
      | e2e-gamesonly      | DENY     | image-builds           |
      | e2e-admin          | ALLOW    | admin-workload-console |
      | e2e-superadmin     | DENY     | admin-workload-console |
      | e2e-admin          | ALLOW    | admin-console-ui       |
      | e2e-mod            | DENY     | admin-console-ui       |

    # ── MODERATOR CONSOLE. A SIBLING of admin, and the seed pairs ROLE_ADMIN on
    #    every mod row as a superset — so an admin DOES reach it, while a
    #    superadmin does not. Four of these five patterns are absent from the TS
    #    mirror, so these rows are coverage that tier could not express.
    Examples:
      | identity             | decision | function          |
      | e2e-mod              | ALLOW    | mod-console-ui    |
      | e2e-user             | DENY     | mod-console-ui    |
      | e2e-mod              | ALLOW    | mod-ban           |
      | rbac-plain@gmail.com | DENY     | mod-ban           |
      | e2e-swarm-mod-0      | ALLOW    | mod-findings      |
      | e2e-swarm-user-000   | DENY     | mod-findings      |
      | e2e-admin            | ALLOW    | mod-audit         |
      | e2e-superadmin       | DENY     | mod-audit         |
      | e2e-mod              | ALLOW    | akkoma-moderation |
      | e2e-mastodon         | DENY     | akkoma-moderation |

    # ── FLEET. The ONLY row in the whole seed keyed on ROLE_FLEET_ADMIN, and the
    #    reason the e2e-fleet persona exists. Un-assertable through the TS mirror,
    #    which carries that role nowhere.
    Examples:
      | identity  | decision | function            |
      | e2e-fleet | ALLOW    | fleet-phone-console |
      | e2e-mod   | DENY     | fleet-phone-console |

    # ── SUPERADMIN. A DISTINCT tier: the refusals name the identity that is most
    #    plausibly entitled and still is not. e2e-fleet is refused the ENTITLEMENT
    #    surface for its own fleet, and e2e-gamesadmin the games app-store — a
    #    fleet owner drives devices but does not grant itself the right to.
    Examples:
      | identity       | decision | function                      |
      | e2e-superadmin | ALLOW    | superadmin-service-catalog    |
      | e2e-admin      | DENY     | superadmin-service-catalog    |
      | e2e-superadmin | ALLOW    | superadmin-catalog-remote     |
      | e2e-mod        | DENY     | superadmin-catalog-remote     |
      | e2e-superadmin | ALLOW    | superadmin-backing-services   |
      | e2e-admin      | DENY     | superadmin-backing-services   |
      | e2e-superadmin | ALLOW    | superadmin-fleet-entitlements |
      | e2e-fleet      | DENY     | superadmin-fleet-entitlements |
      | e2e-superadmin | ALLOW    | superadmin-phone-devices      |
      | e2e-fleet      | DENY     | superadmin-phone-devices      |
      | e2e-superadmin | ALLOW    | superadmin-workload-console   |
      | e2e-admin      | DENY     | superadmin-workload-console   |
      | e2e-superadmin | ALLOW    | superadmin-games-services     |
      | e2e-gamesadmin | DENY     | superadmin-games-services     |

    # ── GAMES-ADMIN. The DERIVED intersection tier: neither half alone admits.
    Examples:
      | identity       | decision | function            |
      | e2e-gamesadmin | ALLOW    | games-admin-console |
      | e2e-adminonly  | DENY     | games-admin-console |
      | e2e-gamesadmin | ALLOW    | games-admin-api     |
      | e2e-gamesonly  | DENY     | games-admin-api     |

    # ── PER-SERVICE ADMIN. e2e-forum holds ROLE_FORUM — MEMBERSHIP of the forum,
    #    not administration of it. forum-moderation is keyed on ROLE_FORUM_MOD,
    #    which NO seeded identity holds, so both its rows are refusals: that row
    #    is currently unreachable by every identity the mesh creates, and saying
    #    so is the assertion.
    Examples:
      | identity  | decision | function         |
      | e2e-admin | ALLOW    | forum-admin      |
      | e2e-forum | DENY     | forum-admin      |
      | e2e-mod   | DENY     | forum-moderation |
      | e2e-admin | DENY     | forum-moderation |
      | e2e-admin | ALLOW    | wiki-admin       |
      | e2e-mod   | DENY     | wiki-admin       |
      | e2e-admin | ALLOW    | owncast-admin    |
      | e2e-user  | DENY     | owncast-admin    |

    # ── LOGIN + THE GATEWAY'S OWN WALLS. The login door is PUBLIC and must admit
    #    the un-onboarded and the banned alike — the gate is what happens AFTER
    #    the door, and a door that pre-judges cannot be tested. The two gateway
    #    functions are the two DIFFERENT mechanisms, and they do NOT produce the
    #    same verdict:
    #
    #      internal-bff-wall  an explicit allow=false row -> DENY. The table
    #                         refuses it, and it stays refused even if somebody
    #                         adds an allow row at the same pattern (deny-wins).
    #      unrouted-infra     NO ROW AT ALL -> NO_RULE. The table decides nothing,
    #                         GatewayRouteAccessFilter forwards, and the request
    #                         meets the coarse anyExchange().authenticated() floor.
    #
    #    These two rows said DENY while the oracle collapsed NO_RULE into it. They
    #    are opposite claims — "the route-access table shuts this door" versus "the
    #    route-access table has no opinion" — and the second is what /infra is.
    #    See features/mined-platform-edge/ungoverned-vs-denied.feature.
    Examples:
      | identity       | decision | function          |
      | e2e-banned     | ALLOW    | login-front-door  |
      | e2e-pending    | ALLOW    | login-front-door  |
      | e2e-superadmin | DENY     | internal-bff-wall |
      | e2e-admin      | DENY     | internal-bff-wall |
      | e2e-superadmin | NO_RULE  | unrouted-infra    |
      | e2e-admin      | NO_RULE  | unrouted-infra    |

  # ═════════════════════════════════════════════════════════════════════════
  # THE SAME CELLS, ADDRESSED THROUGH THE HARNESS'S OWN @role: AXIS rather than
  # by a literal handle. Every other feature under features/rbac/ varies personas
  # on that axis, so the FUNCTION tier has to be reachable from it too — and the
  # axis buys a real check the literal form does not: it resolves through
  # steps/dimensions.ts persona(), so a handle the seeders stop creating fails
  # with the full legal-handle list at Before-hook time instead of quietly
  # deciding about somebody who does not exist.
  #
  # The three swarm representatives are deliberately NOT addressed this way:
  # persona() resolves against the two SEEDER rosters, and the swarm is generated
  # by specs/rbac-roles.ts generateSwarm() rather than listed in either. They are
  # named literally in the tables above, which is the honest spelling for them.
  # ═════════════════════════════════════════════════════════════════════════
  Scenario Outline: <role> is <decision> the <function> function via the role axis @role:<role> @layer:gateway
    Then the persona for this scenario is "<decision>" the "<function>" governance function

    Examples:
      | role           | decision | function                   |
      | e2e-admin      | ALLOW    | allowlist-manage           |
      | e2e-mod        | DENY     | allowlist-manage           |
      | e2e-mod        | ALLOW    | mod-ban                    |
      | e2e-superadmin | ALLOW    | superadmin-service-catalog |
      | e2e-fleet      | ALLOW    | fleet-phone-console        |
      | e2e-user       | DENY     | fleet-phone-console        |
