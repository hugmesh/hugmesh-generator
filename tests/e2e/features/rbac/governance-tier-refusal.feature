# THE REFUSALS — asserted as hard as the admissions, and stated over ROLES.
#
# features/rbac/governance-function-matrix.feature says WHO reaches WHAT. This
# file says what the tier boundaries ARE, and it states them over BARE ROLE-SETS
# rather than personas, because that is the only way to express "holding nothing
# but this role": e2e-admin also carries ROLE_USER, so a persona can never prove
# that ROLE_ADMIN alone is refused. features/rbac/superadmin-tier.feature already
# uses this shape for the three superadmin-gateway routes; this file generalises
# it to every governance CONSOLE and to the whole function surface of each.
#
# THE FOUR BOUNDARIES THIS PINS, all of which were live defects somewhere in this
# repo's history:
#   * SUPERADMIN does not cascade DOWN — an admin reaches no superadmin function.
#   * ADMIN does not cascade UP — a superadmin reaches no admin function either.
#     Both directions matter; a one-way assertion lets a "superadmin is just a
#     bigger admin" refactor pass.
#   * MOD is a SIBLING of admin, not a subset: a moderator reaches no admin
#     function, while an admin IS paired onto every mod row by the seed.
#   * The DERIVED games-admin role is the only key on the games surfaces: neither
#     ROLE_GAMES nor ROLE_ADMIN alone opens them.
#
# The three deliberately un-onboarded identities (e2e-pending, e2e-banned,
# rbac-pending@gmail.com) are UNDER TEST in their gated state. Their gate is
# asserted here; it is never "fixed".
#
# RUNS OFFLINE. Pure functions over the shipped route-access seed.
@service:gateway @layer:gateway
Feature: Governance tier boundaries — what each tier is refused

  # THE DOWN-CASCADE AND THE UP-CASCADE, over bare role-sets.
  Scenario Outline: a principal holding only <role> reaches nothing in the <console> console @layer:gateway
    Then no principal holding only "<role>" reaches any "<console>" governance function

    # SUPERADMIN does not cascade down.
    Examples:
      | role             | console    |
      | ROLE_ADMIN       | superadmin |
      | ROLE_MOD         | superadmin |
      | ROLE_USER        | superadmin |
      | ROLE_GAMES_ADMIN | superadmin |
      | ROLE_FLEET_ADMIN | superadmin |

    # ADMIN does not cascade up, and MOD is a sibling rather than a subset.
    Examples:
      | role             | console     |
      | ROLE_SUPERADMIN  | admin       |
      | ROLE_MOD         | admin       |
      | ROLE_USER        | admin       |
      | ROLE_FLEET_ADMIN | admin       |
      | ROLE_SUPERADMIN  | mod         |
      | ROLE_USER        | mod         |
      | ROLE_SUPERADMIN  | service-admin |

    # The DERIVED games-admin role is the only key: neither input alone admits.
    Examples:
      | role       | console     |
      | ROLE_GAMES | games-admin |
      | ROLE_ADMIN | games-admin |
      | ROLE_MOD   | games-admin |
      | ROLE_USER  | games-admin |

    # The fleet console is keyed on ROLE_FLEET_ADMIN paired with ADMIN and
    # SUPERADMIN as supersets; a moderator and a plain member reach none of it.
    Examples:
      | role      | console |
      | ROLE_MOD  | fleet   |
      | ROLE_USER | fleet   |

  # The other half of a tier boundary: the tier's OWN role must reach the WHOLE
  # console. Without this, "nobody reaches it" would satisfy every row above.
  Scenario Outline: a principal holding only <role> reaches the whole <console> console @layer:gateway
    Then a principal holding only "<role>" reaches every "<console>" governance function

    Examples:
      | role             | console     |
      | ROLE_SUPERADMIN  | superadmin  |
      | ROLE_ADMIN       | admin       |
      | ROLE_ADMIN       | mod         |
      | ROLE_MOD         | mod         |
      | ROLE_GAMES_ADMIN | games-admin |

  # THE GATED IDENTITIES, and the ordinary member beside them for contrast. Each
  # reaches NOTHING in the console named — the strongest refusal shape, and the
  # one a tier boundary is actually made of.
  Scenario Outline: <identity> reaches nothing in the <console> console @layer:gateway
    Then the identity "<identity>" reaches no "<console>" governance function at all

    # e2e-pending holds NO roles at all (registration incomplete); e2e-banned and
    # rbac-pending@gmail.com hold bare ROLE_USER so that the /bff/login step can
    # authenticate them and the DENIAL is what gets asserted, rather than a 401 at
    # setup that never reaches the assertion.
    Examples:
      | identity             | console    |
      | e2e-pending          | admin      |
      | e2e-pending          | mod        |
      | e2e-pending          | superadmin |
      | e2e-pending          | fleet      |
      | e2e-banned           | admin      |
      | e2e-banned           | mod        |
      | e2e-banned           | superadmin |
      | rbac-pending@gmail.com | admin    |
      | rbac-pending@gmail.com | mod      |
      | rbac-pending@gmail.com | superadmin |

    # The ordinary and the specialised members: holding a platform-access role, a
    # forum membership or a games membership buys nothing in any console.
    Examples:
      | identity                     | console       |
      | e2e-user                     | admin         |
      | e2e-user                     | mod           |
      | e2e-matrix                   | mod           |
      | e2e-mastodon                 | mod           |
      | e2e-forum                    | service-admin |
      | e2e-gamesonly                | games-admin   |
      | e2e-denied                   | admin         |
      | e2e-matrix-domainlocked      | mod           |
      | e2e-mastodon-external-client | admin         |
      | e2e-swarm-user-000           | mod           |

    # The cross-tier refusals, on concrete identities rather than bare roles.
    Examples:
      | identity       | console       |
      | e2e-mod        | admin         |
      | e2e-mod        | superadmin    |
      | e2e-mod        | fleet         |
      | e2e-admin      | superadmin    |
      | e2e-adminonly  | superadmin    |
      | e2e-gamesadmin | superadmin    |
      | e2e-superadmin | admin         |
      | e2e-superadmin | mod           |
      | e2e-superadmin | service-admin |
      | e2e-superadmin | games-admin   |
      | e2e-fleet      | admin         |
      | e2e-fleet      | mod           |
      | e2e-fleet      | superadmin    |

  # ═════════════════════════════════════════════════════════════════════════
  # WHY a DENY, not merely THAT it is one. Three different mechanisms produce an
  # identical verdict and rot in three different ways, so each is pinned as the
  # mechanism it is.
  # ═════════════════════════════════════════════════════════════════════════

  # An EXPLICIT allow=false row is a WALL: it refuses a principal that a broader
  # row at the same pattern WOULD admit. The TS mirror cannot express one at all.
  Scenario: the internal bff prefix is a wall and not merely an ungranted path @layer:gateway
    Then the "internal-bff-wall" governance function is an explicit deny wall rather than an absent grant

  # Default-deny asserted as a PROPERTY: the winning pattern must be null. A DENY
  # produced by some over-broad glob quietly swallowing the path looks identical
  # in the verdict and is an entirely different posture.
  Scenario: an unrouted infra path is matched by no row at all @layer:gateway
    Then the "unrouted-infra" governance function is governed by no route row at all

  # Most-specific-match is the part of this contract that changes shape without
  # any single row changing. These pin which pattern actually decided.
  Scenario Outline: the <function> function is decided by <pattern> @layer:gateway
    Then the "<function>" governance function is decided by the route pattern "<pattern>"

    Examples:
      | function                      | pattern                       |
      | usage-analytics               | /bff/admin/**                 |
      | admin-workload-console        | /bff/admin/workloads/**       |
      | fleet-phone-console           | /bff/admin/phone-fleet/**     |
      | mod-console-ui                | /mod/**                       |
      | mod-ban                       | /bff/mod/**                   |
      | superadmin-service-catalog    | /bff/superadmin/**            |
      | superadmin-workload-console   | /bff/superadmin/workloads/**  |
      | superadmin-games-services     | /bff/superadmin/games-services/** |
      | games-admin-console           | /games/admin/**               |
      | login-front-door              | /bff/login                    |

  # ═════════════════════════════════════════════════════════════════════════
  # THE BROWSER DOOR FOR THE SUPERADMIN CONSOLE. #244, ANSWERED ACCEPT.
  #
  # ⚠ THE SECOND SCENARIO USED TO SKIP. It no longer does, and the comment it
  # skipped under was wrong, so both are corrected here.
  #
  # The old text said "there is no browser path to any /bff/superadmin/**
  # endpoint". There always was one: apps/20-gateway-fe.yaml routes Path=/bff/**
  # to admin-bff, and a path no url_pattern matches is Decision.NO_RULE, which
  # the gateway filter FORWARDS — it rejects only on DENY. A browser reached the
  # superadmin BFF and was refused THERE, app-side, by
  # pathMatchers("/bff/superadmin/**").hasRole("SUPERADMIN"): a bare 403 with no
  # X-Route-Denied header. Ungoverned-and-forwarded, never default-denied.
  #
  # #244 ACCEPT added ('hugmesh-fe-gateway','/bff/superadmin/**',
  # 'ROLE_SUPERADMIN',true). For a non-privileged caller the refusal moved to the
  # door: 403 WITH X-Route-Denied, logged, admin-bff never reached. For an admin
  # or a superadmin it changed nothing — both short-circuit in the filter before
  # decide() is consulted. The gain is that the D6/D8 privileged step-up floor
  # now has a governed surface to attach to; it could not fire on an ungoverned
  # path at all.
  #
  # The two halves remain split, but neither is conditional now: the INVARIANT is
  # true on every gateway before and after, and the POSTURE is asserted, with the
  # row's ABSENCE a FAILURE rather than a skip — a decided row that can be
  # deleted while quietly switching off its own coverage is not guarded.
  # ═════════════════════════════════════════════════════════════════════════

  Scenario: nothing but the superadmin tier is admitted under the superadmin bff prefix, on any gateway @layer:gateway
    Then no gateway admits anything but the superadmin tier under the superadmin bff prefix

  Scenario: the browser door for the superadmin console admits the superadmin tier only @layer:gateway
    Given the fe-gateway carries a browser row for the superadmin console
    Then the fe-gateway browser door admits the superadmin tier and refuses every other identity
