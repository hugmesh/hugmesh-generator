# THE ANONYMOUS 401 WALL — hugmesh/hugmesh-generator#290, the anonymous-visitor
# persona plan, made automated.
#
# The plan is manual because "no automated suite in this repo probes anonymous
# HTTP status codes at the gateway end to end": spec 01 asserts the redirect and
# the rendered login markers, spec 14 needs LIVE_GATEWAY=1 + SYSTEMS_CASDOOR_URL
# and `make stack-e2e` sets neither. This feature is that probe, against
# whichever mesh the @env: axis points at, with NO cookie jar and NO token.
#
# THE 401 RULE, stated once (the plan's own words): an anonymous denial is 401
# with `www-authenticate: Bearer`, from the gateway's coarse
# anyExchange().authenticated() floor (SecurityConfig.java:357) — never 403. A
# 403 to a caller that presented nothing means something AUTHENTICATED the
# request, and a 403 carrying X-Route-Denied means the route-access table was
# consulted for an anonymous caller, which GatewayRouteAccessFilter.java:73
# says never happens ("Anonymous requests forward untouched — SecurityConfig
# already decided"). Both are the finding this feature exists to catch, so the
# header's ABSENCE is asserted, not just the status.
#
# The public floor is the CONTROL: without the 200s below, every 401 above could
# be a dead front door rather than a wall. `/bff/login` is the ONLY anonymous
# door into authentication and is deliberately not probed here — a wrong-password
# POST spends one of Casdoor's five sign-in strikes on whatever account it names.
@service:gateway @layer:gateway @env:docker
Feature: The anonymous 401 wall at the public front door

  @issue:generator-290
  Scenario Outline: an anonymous caller is UNAUTHENTICATED at <path> @service:<service> @layer:gateway
    Given I hold an anonymous API client
    When the API client GETs "<path>"
    Then the response status is 401
    And the response header "www-authenticate" contains "Bearer"
    And the response header "x-route-denied" is "<absent>"

    # The session-backed member surfaces (the plan's N12) and the member home.
    Examples:
      | path                     | service |
      | /bff/session             | login   |
      | /bff/me                  | login   |
      | /bff/me/namespaces       | login   |
      | /bff/user/profile        | login   |
      | /bff/user/connected-clients | login |
      | /user/                   | login   |
      | /home                    | gateway |
      | /api/federation/manifest | gateway |
      | /_fragments/             | gateway |

    # The role-gated consoles and their BFFs (N1, N2, N4, N11 of the plan). An
    # anonymous 401 here, never 403: the role rule must not even be reached.
    Examples:
      | path                        | service |
      | /admin/                     | admin   |
      | /admin/remoteEntry.json     | admin   |
      | /admin/games-services       | admin   |
      | /bff/admin/allowlist        | admin   |
      | /bff/admin/announcements/   | admin   |
      | /bff/admin/domains          | admin   |
      | /bff/superadmin/workloads/  | admin   |
      | /mod/                       | admin   |
      | /bff/mod/moderation         | admin   |
      | /api-docs/                  | admin   |
      | /actuator/env               | gateway |
      | /api/admin/cluster/         | gateway |

    # Exact-path public permits do NOT bleed into siblings or subtrees (N5, N6,
    # N9): a 200 on any of these would mean a `/bff/**` or `/bff/public/**`
    # blanket replaced an exact allowance.
    Examples:
      | path                              | service |
      | /bff/password-reset/status        | login   |
      | /bff/public/                      | login   |
      | /bff/public/theme/x               | login   |
      | /bff/public/appeal-contact/anything | login |

  # The credential and registration doors are exact PUBLIC paths for POST alone;
  # an anonymous POST to a sibling, or to the stage-2 completion, is walled (N9,
  # N10, N16). Self-registration is closed BY DESIGN — the gateway floor is the
  # only thing keeping it closed, so this row is the sharpest one in the file.
  @issue:generator-290
  Scenario Outline: an anonymous POST to <path> is walled @service:login @layer:gateway
    Given I hold an anonymous API client
    When the API client POSTs "<path>" with the JSON body "{}"
    Then the response status is 401
    And the response header "x-route-denied" is "<absent>"

    Examples:
      | path                   |
      | /bff/register          |
      | /bff/register/complete |
      | /bff/login/anything    |
      | /bff/mod/ban           |
      | /bff/admin/allowlist   |

  # THE CONTROL — the public floor answers, so the 401s above are a wall and not
  # a dead door. Every path here is in the gateway's PUBLIC_PATHS /
  # FE_SHELL_PUBLIC_GET_PATHS (the plan's steps 5-8, 11) and must stay anonymous:
  # a 401 on any of them locks every visitor out of the sign-in page itself.
  @issue:generator-290
  Scenario Outline: the public floor answers <path> to an anonymous caller @service:<service> @layer:gateway
    Given I hold an anonymous API client
    When the API client GETs "<path>"
    Then the response status is 200

    Examples:
      | path                              | service |
      | /login/                           | login   |
      | /login/remoteEntry.json           | login   |
      | /login/appeal                     | login   |
      | /login/forgot-password            | login   |
      | /bff/public/announcements/login   | login   |
      | /bff/public/appeal-contact        | login   |
      | /bff/public/theme                 | login   |
      | /bff/public/theme.css             | login   |
      | /api/federation/capabilities      | gateway |

  # The public theme projection is `DomainTheme` minus `updatedBy` — an
  # administrator's JWT subject, i.e. an email. Its presence is PII exposure to
  # every visitor before any session exists (plan step 8).
  @issue:generator-290
  Scenario: the anonymous login-page theme carries no administrator identity @service:login @layer:bff
    Given I hold an anonymous API client
    When the API client GETs "/bff/public/theme"
    Then the response status is 200
    And the response header "content-type" contains "json"
    And the response body does not contain "updatedBy"
