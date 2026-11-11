# WHAT THIS ASSERTS — hugmesh-admin-bff-api#57, decision 61 = refuse (operator,
# 2026-09-18), landed in admin-bff PR #79 (14bbe4c), gateway PR #37 and
# generator PR #571; finished by decision 79 = B (operator, 2026-09-23), gateway
# half hugmesh-gateway#40 (f0faca1), generator half in this repo.
#
# AdminController.addRouteRule (and the pathPrefix call site) refuses any
# url_pattern whose first path segment is a BARE wildcard ('/**', '/*') with
# 400 "has no addressable first path segment"; '/' is the one explicit
# exception (a single literal path, not a catch-all). The measured defect was
# the OTHER side: the platform's own seeds shipped a '/**' row the API can
# never recreate. Decision 61 kept the refusal and fixed the seeds, leaving ONE
# named residual: the hugmesh-pki-gateway headscale control-plane catch-all
# (bug #15), Host-routed with no Path predicate. Decision 79 = B closed it: the
# gateway's SecurityConfig requires ROLE_SUPERADMIN for every request on the
# headscale route's Host, ahead of the route-access filter, and the row is
# dropped from every seed. So the seed now ships NO bare '/**' row at all,
# pinned here and by tests/scripts/cluster_manifest_integrity.py
# BARE_DOUBLE_STAR_EXCEPTIONS (empty).
#
# TWO TIERS:
#   * OFFLINE — the cluster seed ships no bare '/**' row: re-add the pki
#     headscale catch-all, or any other, and this names it.
#   * LIVE (@env:docker) — the real admin-bff behind the compose stack's front
#     door (built from admin-bff 6dc72d1, which carries #79): an ADMIN's POST of
#     '/**' or '/*' is REFUSED at validation — a rejected write, so nothing
#     lands in the operator's route-access table — and the same POST from a
#     member, a moderator and an anonymous client never reaches validation at
#     all. The 403s are asserted to come from the GATEWAY (X-Route-Denied), so
#     a forwarded-then-refused caller cannot pass for a governed one.
#
# Every @role: is a roster handle (e2e-admin holds ROLE_ADMIN+ROLE_USER; e2e-mod
# holds ROLE_MOD only; e2e-user holds ROLE_USER only).
@service:admin @issue:admin-bff-api-57
Feature: The route-access write API refuses a bare wildcard, and the seed ships none it cannot recreate

  # ── the seed, offline ──────────────────────────────────────────────────────
  Scenario: the cluster seed ships no bare '/**' row, not even the old pki headscale catch-all @layer:gateway
    Given the cluster route-access seed is loaded
    Then the cluster seed ships no row whose url_pattern is exactly "/**"

  # ── the write API, live ────────────────────────────────────────────────────
  # A REFUSED write: 400 at validation, before any row exists. Both bare shapes,
  # because #79 pinned '/*' alongside the pre-existing '/**' and only '/' passes.
  @env:docker @role:e2e-admin
  Scenario Outline: an admin's POST of url_pattern <pattern> is refused at validation with 400 @role:e2e-admin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client POSTs a route rule with url_pattern "<pattern>" for role "ROLE_SUPERADMIN" at gateway "hugmesh-pki-gateway"
    Then the response status is 400
    And the response error message matches "no addressable first path segment"

    Examples:
      | pattern |
      | /**     |
      | /*      |

  @env:docker
  Scenario Outline: <role> is refused the route-access write at the gateway @role:<role> @env:docker @layer:gateway
    Given an API client signed in as the persona for this scenario
    When the API client POSTs a route rule with url_pattern "/**" for role "ROLE_SUPERADMIN" at gateway "hugmesh-pki-gateway"
    Then the response status is 403
    And the refusal came from the gateway

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |

  @env:docker
  Scenario: an anonymous client is unauthenticated at the route-access write @env:docker @layer:gateway
    Given an anonymous API client
    When the API client POSTs a route rule with url_pattern "/**" for role "ROLE_SUPERADMIN" at gateway "hugmesh-pki-gateway"
    Then the response status is 401
