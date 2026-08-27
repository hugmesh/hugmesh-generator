# The executable Gherkin form of tests/e2e/specs/13-rbac-admin-api-gating.spec.ts.
#
# The ROLE_ADMIN surface (/bff/admin/**) is enforced at the APPLICATION layer by a
# BFF that runs in the rootless mock stack RIGHT NOW — unlike the gateway
# route-access table, which is still a contract. So this is the live half of the
# admin gate, over the full set of admin-protected BFF endpoints.
#
# IDENTITY. The browser's only auth is the opaque httpOnly bff_session cookie
# minted by POST /bff/login; no bearer token is ever exposed. Each API client keeps
# its OWN cookie jar, so "admin" / "plain user" / "anonymous" are three separate
# contexts rather than three token strings.
#
# 401 vs 403 IS THE POINT, not an implementation detail. An ANONYMOUS caller is
# UNAUTHENTICATED: every gateway SecurityConfig chain ends with
# anyExchange().authenticated() and /bff/admin/** is not in PUBLIC_PATHS, so the
# authentication entry-point rejects it (401) before any role rule runs. 403 is
# reserved for an AUTHENTICATED principal that lacks ROLE_ADMIN — the fail-closed
# route-access path. Collapsing them would hide an auth regression behind an
# authz assertion.
#
# PLATFORM is a real axis here: this BFF runs on the mesh under test, and rpi5 and
# x86 are separate images. SNAP_PLATFORM narrows to the one actually up; unset,
# both rows run (the harness over-tests rather than under-tests).
@service:admin @layer:bff
Feature: BFF admin API gating

  Scenario Outline: <role> gets <status> from every admin BFF endpoint on <platform> @role:<role> @platform:<platform> @service:admin @layer:bff
    Given the admin principal "admin@hugmesh.net" has invited "rbac-plain@gmail.com" onto the allowlist
    And an API client signed in as the persona for this scenario
    When the API client GETs every admin BFF endpoint
    Then every admin BFF endpoint answered with status <status>

    Examples:
      | role                 | platform | status |
      | admin@hugmesh.net    | rpi5     | 200    |
      | admin@hugmesh.net    | x86      | 200    |
      | rbac-plain@gmail.com | rpi5     | 403    |
      | rbac-plain@gmail.com | x86      | 403    |

  Scenario: an anonymous caller is UNAUTHENTICATED at every admin BFF endpoint @service:admin @layer:bff
    Given an anonymous API client
    When the API client GETs every admin BFF endpoint
    Then every admin BFF endpoint answered with status 401

  Scenario: a plain member's admin WRITE is refused too @role:rbac-plain@gmail.com @service:admin @layer:bff
    Given the admin principal "admin@hugmesh.net" has invited "rbac-plain@gmail.com" onto the allowlist
    And an API client signed in as the persona for this scenario
    Then the API client is refused a write to the admin allowlist with status 403
