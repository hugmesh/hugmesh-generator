# The executable Gherkin form of the CONTRACT half of
# tests/e2e/specs/17-rbac-user-and-pending.spec.ts.
#
# A plain ROLE_USER reaches the login/social-shell UI and its own profile, and is
# denied every admin/mod/games-admin route AND — since commit 0100d3b removed the
# broad ROLE_USER homeserver floor — the Matrix/Mastodon HOMESERVER BACKEND
# surfaces on the be-gateway.
#
# The "a plain member reaches their own homeserver" intent did not disappear with
# that floor; it moved to the per-platform ACCESS roles. e2e-matrix and
# e2e-mastodon are the dedicated personas that model it, and they are the real
# successor rows to the old bare-ROLE_USER expectation — so they are in the SAME
# outline, distinguished only by the role column.
#
# The LIVE half of spec 17 (the two-stage registration gate) is
# features/rbac/pending-approval-gate.feature.
@layer:gateway
Feature: Plain members and per-platform access holders

  Scenario Outline: <role> is <decision> at <path> (<what>) @role:<role> @service:<service> @layer:gateway
    Given the persona for this scenario presents its effective role set
    When the "<gateway>" gateway evaluates the request path "<path>"
    Then the gateway route-access decision is "<decision>"

    # ALLOW — the surfaces a plain member legitimately reaches.
    Examples:
      | role         | service | gateway            | path                          | decision | what              |
      | e2e-user     | tuwunel | hugmesh-fe-gateway | /social/matrix/room           | ALLOW    | Matrix MFE        |
      | e2e-user     | akkoma  | hugmesh-fe-gateway | /social/mastodon/feed         | ALLOW    | Mastodon MFE      |
      | e2e-user     | login   | hugmesh-fe-gateway | /login/callback               | ALLOW    | login UI          |
      | e2e-user     | gateway | hugmesh-fe-gateway | /bff/me/namespaces            | ALLOW    | own profile       |

    # DENY — every privileged surface, plus the homeserver BACKEND surfaces the
    # per-platform roles now gate.
    Examples:
      | role         | service | gateway            | path                          | decision | what              |
      | e2e-user     | admin   | hugmesh-fe-gateway | /admin/usage                  | DENY     | admin UI          |
      | e2e-user     | admin   | hugmesh-be-gateway | /api/admin/route-access       | DENY     | admin API         |
      | e2e-user     | admin   | hugmesh-fe-gateway | /bff/admin/allowlist          | DENY     | BFF admin         |
      | e2e-user     | akkoma  | hugmesh-be-gateway | /api/v1/pleroma/admin/config  | DENY     | akkoma moderation |
      | e2e-user     | games   | hugmesh-fe-gateway | /games/admin/sessions         | DENY     | games admin UI    |
      | e2e-user     | games   | hugmesh-fe-gateway | /games/api/admin/role-grants  | DENY     | games admin API   |
      | e2e-user     | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | DENY     | needs ROLE_MATRIX |
      | e2e-user     | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | DENY     | needs MASTODON    |

    # THE SUCCESSOR ROWS — a member granted the per-platform access role reaches
    # its own homeserver's backend surface.
    Examples:
      | role         | service | gateway            | path                          | decision | what              |
      | e2e-matrix   | tuwunel | hugmesh-be-gateway | /_matrix/client/v3/sync       | ALLOW    | ROLE_MATRIX       |
      | e2e-mastodon | akkoma  | hugmesh-be-gateway | /api/v1/timelines/home        | ALLOW    | ROLE_MASTODON     |
