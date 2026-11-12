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
# anyExchange().authenticated() floor (hugmesh-gateway SecurityConfig.java) —
# never 403. A 403 to a caller that presented nothing means something
# AUTHENTICATED the request, and a 403 carrying X-Route-Denied means the
# route-access table was consulted for an anonymous caller, which hugmesh-gateway
# GatewayRouteAccessFilter.java says never happens ("Anonymous requests forward
# without a route-access decision"). Both are the finding this feature exists to catch, so the
# header's ABSENCE is asserted, not just the status.
#
# A BROWSER PAGE LOAD IS A DIFFERENT REQUEST SHAPE, AND IT IS PROBED HERE TOO.
# Since hugmesh-gateway GUI-08 the fe tier tells a top-level document navigation
# (a GET whose Accept names text/html, with Sec-Fetch-Mode absent or `navigate`,
# Sec-Fetch-Dest absent or `document`, and no X-Requested-With: XMLHttpRequest)
# apart from every other request, and answers it differently in exactly two ways:
#   * a page load of a walled route gets 302 /login?next=<path> instead of the
#     bodiless 401, which a browser can only show as its own "HTTP ERROR 401";
#   * a page load of /home or /about, the host shell's two public pages, is
#     SERVED: 200 and the same index.html `/` serves. Nothing else is.
# NOTHING ELSE MOVED. The API client sends Accept: */*, so every row of the wall
# below still meets the 401, /home and /about included: those two paths are
# public to a page load ONLY (hugmesh-gateway SecurityConfig.FE_SHELL_PUBLIC_PAGES).
# A script's fetch(), an XHR, curl and an API client get the 401 there that they
# always got. The request shape keeps the anonymous surface as small as the
# defect needed; it is not a secret, the headers are the caller's to send, and
# the document is the one `/` already gives anyone.
#
# The public floor is the CONTROL: without the 200s below, every 401 above could
# be a dead front door rather than a wall. `/bff/login` is the ONLY anonymous
# door into authentication and is deliberately not probed here — a wrong-password
# POST counts toward Casdoor's sign-in lockout for whatever account it names.
@service:gateway @layer:gateway @env:docker
Feature: The anonymous 401 wall at the public front door

  @issue:generator-290
  Scenario Outline: an anonymous caller is UNAUTHENTICATED at <path> @service:<service> @layer:gateway
    Given I hold an anonymous API client
    When the API client GETs "<path>"
    Then the response status is 401
    And the response header "www-authenticate" contains "Bearer"
    And the response header "x-route-denied" is "<absent>"

    # The session-backed member surfaces (the plan's N12), and /home and /about.
    # Those two are the host shell's public pages, but only a browser PAGE LOAD is
    # served them (the page-load scenarios below). To this API client they are
    # behind the wall like everything else, and this table holds that half of the
    # contract: a 200 on either row means the two pages leaked out of the page-load
    # rule into every GET.
    Examples:
      | path                     | service |
      | /bff/session             | login   |
      | /bff/me                  | login   |
      | /bff/me/namespaces       | login   |
      | /bff/user/profile        | login   |
      | /bff/user/connected-clients | login |
      | /user/                   | login   |
      | /home                    | gateway |
      | /about                   | gateway |
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

  # The credential doors (/bff/login, /bff/password-reset/{request,confirm}) are EXACT PUBLIC paths;
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

  # THE PAGE-LOAD HALF (hugmesh-gateway GUI-08; needs a mesh whose gateway carries
  # hugmesh-gateway#68). The API client is made to send what a browser sends for a
  # typed URL, a bookmark or a reload, and redirects are NOT followed, so what is
  # asserted is the gateway's own answer.
  #
  # The host shell's two public pages (host-shell app.routes.ts mounts 'home' and
  # 'about' unguarded, and nothing links to either: a hard load is how a visitor
  # gets there) are served to that request and to no other. The same two paths sit
  # in the 401 table above for the plain API client.
  @issue:generator-290
  Scenario Outline: an anonymous page load of <path> is served the shell's public page
    Given I hold an anonymous API client
    When the API client GETs "<path>" as a browser page load
    Then the response status is 200
    And the response header "content-type" contains "text/html"
    And the response header "x-route-denied" is "<absent>"

    Examples:
      | path   |
      | /home  |
      | /about |

  # The same Accept: text/html, sent the way fetch() sends it (Sec-Fetch-Mode: cors).
  # It is not a page load, so it meets the wall: on the two pages, and on a console.
  @issue:generator-290
  Scenario Outline: a script asking for <path> as HTML is still UNAUTHENTICATED
    Given I hold an anonymous API client
    When the API client GETs "<path>" as a script asking for HTML
    Then the response status is 401
    And the response header "www-authenticate" contains "Bearer"
    And the response header "x-route-denied" is "<absent>"

    Examples:
      | path    |
      | /home   |
      | /about  |
      | /admin/ |

  # ONLY the two pages. A page load of anything else behind the wall is sent to
  # sign in: 302, never 200, and still no route-access decision. The last three
  # rows are the near misses: a trailing slash or a child of a public page is not
  # the page (the permit is two exact paths).
  @issue:generator-290
  Scenario Outline: an anonymous page load of <path> is sent to sign in, never served @service:<service> @layer:gateway
    Given I hold an anonymous API client
    When the API client GETs "<path>" as a browser page load
    Then the response status is 302
    And the response header "location" is "/login?next=<next>"
    And the response header "x-route-denied" is "<absent>"

    Examples:
      | path         | next             | service |
      | /admin/      | %2Fadmin%2F      | admin   |
      | /mod/        | %2Fmod%2F        | admin   |
      | /user/       | %2Fuser%2F       | login   |
      | /bff/session | %2Fbff%2Fsession | login   |
      | /home/       | %2Fhome%2F       | gateway |
      | /home/x      | %2Fhome%2Fx      | gateway |
      | /about/team  | %2Fabout%2Fteam  | gateway |

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
