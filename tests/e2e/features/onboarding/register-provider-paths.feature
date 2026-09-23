# The five legacy user paths that operator decision 40 (hugmesh-generator#347,
# implemented by #422 / tracked on #366) realigned onto user-bff on BOTH fe
# route tables — GET /bff/me/namespaces, POST /bff/provision/matrix,
# POST /bff/provision/mastodon, POST /bff/register/google and
# POST /bff/register/discord — driven THROUGH THE FRONT DOOR with a real bff_
# session, which is the probe #366 and hugmesh-user-bff-api#16 have asked for
# since 2026-09-10 and nobody had run. Route SHAPE is pinned offline elsewhere
# (fe-route-tables.feature, tests/scripts/test-fe-bff-route-lane-parity.sh);
# this file is the BEHAVIOUR.
#
# WHAT CHANGED SINCE THE SURVEY THAT PLANNED THIS FILE (2026-09-18 04:00 PT). The
# survey's sketch asserted the two register paths "answer 404 on BOTH lanes
# today" — the accepted regression decision 40 recorded. That is no longer the
# truth on origin/main: hugmesh-user-bff-api#20 merged the same morning
# (b90cd8f) and LegacyPathParityController now serves both, keyed google:/
# discord: on admin-bff's invite allowlist. A scenario pinning the 404 would be
# a fence around a state that has already moved, so the served behaviour is
# what is asserted here. Re-measured 2026-09-23 on user-bff origin/main 666ab2f.
#
# WHO CAN CALL A REGISTRATION PATH, AND WHY THAT IS THE MATRIX. user-bff treats
# /bff/register/{google,discord} as permitAll — registration is pre-auth by
# definition — but the front door does not: the route-access seed grants
# /bff/register/** to ROLE_USER (20-schema.sql:627) and the gateway's
# PUBLIC_PATHS carry no /bff/register/* entry, so an anonymous POST is 401'd by
# the coarse authenticated() floor before any BFF sees it (hugmesh-gateway#29
# records the identical posture for /bff/register itself). So through the front
# door the ALLOWED callers are ROLE_USER holders plus the two bypass tiers
# (SUPERADMIN cross-domain, ADMIN own-domain — GatewayRouteAccessFilter), the
# DENIED callers are a ROLE_MOD-only persona (403 + X-Route-Denied from the
# gateway, never reaching user-bff) and anonymous (401). The two 403s are told
# apart by the header: user-bff's own refusal carries a "not invited" body and
# no X-Route-Denied. That distinction is the whole point — a route-access 403
# and a "not invited" 403 look identical to a status-only assertion.
#
# STATE THESE SCENARIOS CREATE, STATED PLAINLY. The "fresh identity" rows invite
# a per-run `bdd-invite-<stamp>` handle as admin@hugmesh.net (the same
# POST /bff/admin/allowlist spec 02 drives), register it, complete it, and
# un-invite it again in an After hook. The ACCOUNT row a successful
# registration creates has no front-door delete and stays; the stamp makes it
# recognisable and never collides with a seeded persona. The decision-57 rows
# use a FIXED handle on purpose (see the step's own doc) so the "already
# complete" precondition is stable across runs of a persistent stack.
@service:login @layer:bff @env:docker
Feature: The realigned legacy user paths are served by user-bff through the front door

  # ── GET /bff/me/namespaces — served, with the caller's own grants ───────────
  @issue:generator-366 @issue:user-bff-api-16
  Scenario Outline: <role> reads their own namespace grants through the realigned path @role:<role> @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client GETs "/bff/me/namespaces"
    Then the response status is 200
    And the response JSON field "namespaces" is present
    And the response carries no header "X-Route-Denied"

    Examples:
      | role           |
      | e2e-user       |
      | e2e-admin      |
      | e2e-superadmin |

  # ── POST /bff/provision/{matrix,mastodon} — served, role-gated APP-SIDE ─────
  # The provision legs are @PreAuthorize(hasRole('MATRIX'|'MASTODON')) in
  # user-bff (LegacyPathParityController), mirroring admin-bff's own gate. The
  # body is {"ok":true} — user-bff keeps the minted homeserver token in custody
  # and the browser never receives one (the shape tests/stack/mock-bff.mjs:318
  # already answers, and tests/stack/seed-e2e.sh provision_platform() branches
  # on the status alone). A 502 here on a live run is the broker failing to
  # mint against the real tuwunel/Akkoma (recorded before on this stack for
  # Akkoma with registrations closed) — that is a mesh-state finding, not a
  # routing regression, and the step's failure message carries the body.
  @issue:generator-366 @issue:user-bff-api-16
  Scenario Outline: <role> provisions <platform> through the realigned path @role:<role> @service:<service> @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client POSTs "/bff/provision/<platform>"
    Then the response status is 200
    And the response JSON field "ok" is "true"

    Examples:
      | role         | platform | service |
      | e2e-matrix   | matrix   | tuwunel |
      | e2e-mastodon | mastodon | akkoma  |

  # The negative half that proves the 200s above are the ROLE and not the path:
  # a plain member passes the gateway's ROLE_USER row on /bff/provision/** and is
  # refused by user-bff's method-level gate — 403 with NO X-Route-Denied, the
  # signature of an app-side refusal. A gateway-side 403 here would mean the
  # /bff/provision/** row moved and every provision call now dies at the door.
  @issue:generator-366 @issue:user-bff-api-16
  Scenario Outline: <role> is refused <platform> provisioning by user-bff itself, not by the door @role:<role> @service:<service> @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client POSTs "/bff/provision/<platform>"
    Then the response status is 403
    And the response carries no header "X-Route-Denied"

    Examples:
      | role     | platform | service |
      | e2e-user | matrix   | tuwunel |
      | e2e-user | mastodon | akkoma  |

  # ── POST /bff/register/{google,discord} — SERVED (the invite gate answers) ──
  # A never-invited handle is the cheapest proof that user-bff, not a 404, is on
  # the other end: the allowlist gate refuses BEFORE ensureAccount, so nothing is
  # created, and the refusal names the reason. These are the rows that would
  # have read 404 before hugmesh-user-bff-api#20.
  @issue:generator-366 @issue:user-bff-api-19
  Scenario Outline: <role> reaches the <provider> registration handler, which refuses a never-invited identity @role:<role> @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client registers the handle "<handle>" through "/bff/register/<provider>"
    Then the response status is 403
    And the response error message matches "not invited"
    And the response carries no header "X-Route-Denied"

    Examples:
      | role           | provider | handle                        |
      | e2e-user       | google   | never-invited-bdd@example.test |
      | e2e-user       | discord  | never-invited-bdd              |
      | e2e-admin      | google   | never-invited-bdd@example.test |
      | e2e-superadmin | discord  | never-invited-bdd              |

  # A persona holding no ROLE_USER (e2e-mod is ROLE_MOD only — specs/rbac-roles.ts)
  # never reaches user-bff: the route-access row on /bff/register/** decides
  # DENY and the gateway stamps the path it refused.
  @issue:generator-366 @issue:user-bff-api-19
  Scenario Outline: <role> is refused the <provider> registration path at the door @role:<role> @service:login @layer:gateway
    Given I hold an API session as the persona for this scenario
    When the API client registers the handle "<handle>" through "/bff/register/<provider>"
    Then the response status is 403
    And the response header "X-Route-Denied" contains "/bff/register/<provider>"

    Examples:
      | role    | provider | handle                         |
      | e2e-mod | google   | never-invited-bdd@example.test |
      | e2e-mod | discord  | never-invited-bdd              |

  @issue:generator-366 @issue:user-bff-api-19
  Scenario Outline: an anonymous caller is refused the <provider> registration path at the door @service:login @layer:gateway
    Given I hold an anonymous API client
    When the API client registers the handle "<handle>" through "/bff/register/<provider>"
    Then the response status is 401

    Examples:
      | provider | handle                         |
      | google   | never-invited-bdd@example.test |
      | discord  | never-invited-bdd              |

  # ── the invited path, end to end: register -> complete -> the parity legs ──
  # This is the google:/discord: half hugmesh-user-bff-api#16 says a casdoor:-only
  # probe cannot settle: "a cluster holds only casdoor: accounts today, so a
  # casdoor:-only probe passes whether or not the fix works." The account these
  # rows create IS a google:/discord: account, minted by user-bff's own register
  # leg, and the session that follows is the synthetic-principal carrier PR #15
  # fixed ownAccountId() for. /bff/me/namespaces answering 200 on it is the
  # retraction on #366 pinned end to end.
  @issue:user-bff-api-19 @issue:user-bff-api-16 @role:e2e-user
  Scenario: a freshly invited Gmail identity registers through user-bff, completes onboarding and reaches the parity legs as a google: account @role:e2e-user @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    And a freshly invited Gmail identity for this scenario
    When the API client registers the invited identity through "/bff/register/google"
    Then the response status is 200
    And the response JSON field "provider" is "google"
    And the response JSON field "registrationComplete" is "false"
    And the response JSON field "token" is present
    And the API client session is a "google" account for the invited identity
    And the API client session registration is not complete
    When the API client completes registration with the display name "BDD Google Identity"
    Then the response status is 200
    And the API client session registration is complete
    When the API client GETs "/bff/me/namespaces"
    Then the response status is 200
    And the response JSON field "namespaces" is present
    When the API client POSTs "/bff/provision/matrix"
    Then the response status is 403
    And the response carries no header "X-Route-Denied"

  @issue:user-bff-api-19 @issue:user-bff-api-16 @role:e2e-user
  Scenario: a freshly invited Discord identity registers through user-bff, completes onboarding and reaches the parity legs as a discord: account @role:e2e-user @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    And a freshly invited Discord identity for this scenario
    When the API client registers the invited identity through "/bff/register/discord"
    Then the response status is 200
    And the response JSON field "provider" is "discord"
    And the response JSON field "registrationComplete" is "false"
    And the response JSON field "token" is present
    And the API client session is a "discord" account for the invited identity
    And the API client session registration is not complete
    When the API client completes registration with the display name "BDD Discord Identity"
    Then the response status is 200
    And the API client session registration is complete
    When the API client GETs "/bff/me/namespaces"
    Then the response status is 200
    And the response JSON field "namespaces" is present

  # ── decision 57: re-registering an already-complete account answers 409 ────
  # admin-bff's handlers reset registrationComplete (AccountStore.restartOnboarding)
  # and send the user back through stage 2; user-bff has no internal endpoint for
  # that reset (hugmesh-admin-bff-api#84, still open) and REFUSES instead of
  # minting a session whose registrationComplete:true would skip onboarding. It
  # ships as 503 on origin/main 666ab2f. Operator decision 57 (hugmesh-generator
  # #347, answers of 2026-09-18) chose 409 over the recommended 503; a user-bff
  # lane is landing that change. @fixme until it is on user-bff origin/main;
  # the assertion is the decided contract, never today's 503.
  @issue:user-bff-api-19 @fixme @role:e2e-user
  Scenario Outline: re-registering an already-complete <provider> account is a 409 conflict, not a 503 @role:e2e-user @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    And the invited "<provider>" identity "<handle>" already holds a completed registration
    When the API client registers the handle "<handle>" through "/bff/register/<provider>"
    Then the response status is 409
    And the response carries no header "X-Route-Denied"

    Examples:
      | provider | handle                        |
      | google   | bdd-complete-google@gmail.com |
      | discord  | bdd-complete-discord          |

  # ── hugmesh-user-bff-api#14: the residual resolver key-miss ─────────────────
  # CanonicalIdentityResolver.resolveOwnAccount still keys a bff_ session off
  # SUBJECT_CLAIMS, so a google:/discord: account with a BLANK persisted localpart
  # gets 401 "no registered account for this token's OWN identity" where a
  # casdoor: account gets 409 "no persisted homeserver localpart yet". Both are
  # fail-closed; the issue is the inconsistency. Observable only through a leg
  # that reaches the resolver — the provision legs do, but they are also gated
  # on ROLE_MATRIX/ROLE_MASTODON — so the fixture this needs is a google: or
  # discord: persona that HOLDS the platform role AND whose account row has a
  # blank localpart. user-bff's own register leg persists a collision-checked
  # localpart on every account it creates (ensureAccount -> withLocalpart), so no
  # front-door journey can produce that row. PENDING with the reason, tagged for
  # the day a seeder line exists; the Then-steps state the decided behaviour.
  @issue:user-bff-api-14 @fixme @role:e2e-matrix
  Scenario Outline: a blank-localpart <provider>: session is told 409 at the provision leg, exactly like casdoor: @role:e2e-matrix @service:tuwunel @layer:bff
    Given this scenario is PENDING because "no seeder creates a <provider>: account holding ROLE_MATRIX with a BLANK persisted localpart (user-bff's register leg always persists one), and no front-door API can blank it — a seeder line in tests/e2e-extra-personas.sh plus a sign-in step for a <provider>: persona are needed before this can run"
    When the API client POSTs "/bff/provision/matrix"
    Then the response status is 409
    And the response error message matches "no persisted homeserver localpart"

    Examples:
      | provider |
      | google   |
      | discord  |

  # ── the internal legs the registration cutover is growing ──────────────────
  # hugmesh-admin-bff-api#84 (POST /bff/internal/accounts/{id}/restart-onboarding)
  # and #85 (POST /bff/internal/usage, decision 55 = yes) are ROLE_SERVICE +
  # InternalTokenWebFilter surfaces with no persona caller by design. What a
  # persona-driven suite CAN and must assert is that neither is reachable from
  # the front door: /bff/internal/** carries an EXPLICIT deny row (20-schema
  # .sql:1017) and admin-bff permitAll()s the prefix app-side, so the gateway
  # row is the only wall a plain member meets. The offline decision is in
  # mined-identity/internal-ingest-deny.feature; these are the live rows.
  # ADMIN/SUPERADMIN are deliberately absent: GatewayRouteAccessFilter forwards
  # both tiers on a bypass before decide() runs, so what they meet is admin-bff's
  # internal-token filter — a different contract this lane does not own.
  @issue:admin-bff-api-84 @issue:admin-bff-api-85
  Scenario Outline: <role> cannot reach the internal onboarding leg <path> from the front door @role:<role> @service:admin @layer:gateway
    Given I hold an API session as the persona for this scenario
    When the API client POSTs "<path>"
    Then the response status is 403
    And the response header "X-Route-Denied" contains "<path>"

    Examples:
      | role     | path                                                        |
      | e2e-user | /bff/internal/accounts/casdoor:nobody/restart-onboarding    |
      | e2e-user | /bff/internal/usage                                         |
      | e2e-mod  | /bff/internal/accounts/casdoor:nobody/restart-onboarding    |

  @issue:admin-bff-api-84 @issue:admin-bff-api-85
  Scenario Outline: an anonymous caller cannot reach the internal onboarding leg <path> @service:admin @layer:gateway
    Given I hold an anonymous API client
    When the API client POSTs "<path>"
    Then the response status is 401

    Examples:
      | path                                                        |
      | /bff/internal/accounts/casdoor:nobody/restart-onboarding    |
      | /bff/internal/usage                                         |
