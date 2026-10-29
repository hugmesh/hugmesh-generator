# THE SECOND GATE ON /bff/provision/{matrix,mastodon}, driven live for the whole
# role matrix.
#
# WHY THIS EXISTS. Both provision legs moved from admin-bff to user-bff's
# LegacyPathParityController (hugmesh-user-bff-api#19, commits 7ea4f753 /
# dc34c8b8; the compose fe table realigned the exact paths onto user-bff in
# tests/stack/gateway-routes/fe/application-routes.yml). Each leg is gated
# TWICE, by two different artefacts:
#
#   the ROUTE   the route-access seed row ('hugmesh-fe-gateway','/bff/provision/**',
#               'ROLE_USER') — asserted OFFLINE by the generative matrices
#               (features/coverage/access-matrix-*.feature rows
#               tuwunel.provision-account / akkoma.provision-account, and the
#               social function-surface rows of the same id);
#   the METHOD  @PreAuthorize("hasRole('MATRIX')") / ("hasRole('MASTODON')") on the
#               controller method (LegacyPathParityController:367 / :384), which
#               the seed CANNOT see. user-bff's RoleHierarchy is SUPERADMIN >
#               ADMIN / MOD / USER and nothing else (SecurityConfig:385-388), so
#               neither ROLE_ADMIN nor ROLE_SUPERADMIN implies a platform role.
#
# Before this file the suite asserted only the first gate; the survey of
# 2026-09-18 found ROLE_USER-without-platform, ROLE_ADMIN and ROLE_MOD uncovered
# at the second. Every row below is the CORRECT behaviour user-bff-api#19
# specifies (parity with admin-bff AuthController), so none is @fixme.
#
# WHAT EACH ROW MEANS. Every 403 below is the METHOD gate. The ROUTE row admits
# every signed-in caller: hugmesh-gateway's BffSessionAuthFilter adds a
# ROLE_USER floor to every bff_ session, so even e2e-mod (Casdoor roles ROLE_MOD
# only) passes /bff/provision/** -> ROLE_USER and is refused by user-bff's
# hasRole('MATRIX'|'MASTODON'). The two 200 rows are the control: without them
# every 403 could be "the stack is broken".
#
# REWRITTEN 2026-10-29: an earlier draft filed the e2e-mod rows as "refused at
# the ROUTE row before user-bff is reached", on the premise that a ROLE_MOD-only
# persona holds no ROLE_USER. Measured through https://localhost:8488 that day,
# e2e-mod passes the ROLE_USER rows /bff/me/** and /bff/register/** (no
# X-Route-Denied) while being refused at ROLE_ADMIN rows, so the premise was
# false. The asserted status (403) is unchanged; the rows moved to the
# method-gate block. These POST rows were NOT run live (they would provision
# homeserver accounts on the operator's stack); they are verified offline only.
#
# LIVE — needs the compose stack (user-bff behind the fe gateway). Skips loudly
# with the start command when nothing answers.
@service:login @layer:bff @env:docker @issue:user-bff-api-19
Feature: Provisioning a homeserver account needs the platform's ACCESS role, not membership

  Scenario Outline: <role> is <outcome> at POST /bff/provision/<platform> (<what>) @role:<role> @service:<service> @layer:bff
    Given I hold an API session as the persona for this scenario
    When I request "POST /bff/provision/<platform>"
    Then the response status is <status>

    Examples: the platform's ACCESS role passes both gates — the control rows
      | role         | service | platform | status | outcome  | what          |
      | e2e-matrix   | tuwunel | matrix   | 200    | admitted | ROLE_MATRIX   |
      | e2e-mastodon | akkoma  | mastodon | 200    | admitted | ROLE_MASTODON |

    Examples: membership, admin or superadmin alone is refused by the METHOD gate — the route row admits ROLE_USER, the method does not
      | role           | service | platform | status | outcome | what                                             |
      | e2e-user       | tuwunel | matrix   | 403    | refused | bare ROLE_USER                                   |
      | e2e-user       | akkoma  | mastodon | 403    | refused | bare ROLE_USER                                   |
      | e2e-adminonly  | tuwunel | matrix   | 403    | refused | ROLE_ADMIN without ROLE_MATRIX                   |
      | e2e-adminonly  | akkoma  | mastodon | 403    | refused | ROLE_ADMIN without ROLE_MASTODON                 |
      | e2e-superadmin | tuwunel | matrix   | 403    | refused | the hierarchy grants USER/ADMIN/MOD, not MATRIX   |
      | e2e-superadmin | akkoma  | mastodon | 403    | refused | the hierarchy grants USER/ADMIN/MOD, not MASTODON |
      | e2e-mod        | tuwunel | matrix   | 403    | refused | ROLE_MOD (+ the gateway's ROLE_USER floor)        |
      | e2e-mod        | akkoma  | mastodon | 403    | refused | ROLE_MOD (+ the gateway's ROLE_USER floor)        |

    Examples: the OTHER platform's role is not this platform's role
      | role         | service | platform | status | outcome | what                            |
      | e2e-matrix   | akkoma  | mastodon | 403    | refused | ROLE_MATRIX is not ROLE_MASTODON |
      | e2e-mastodon | tuwunel | matrix   | 403    | refused | ROLE_MASTODON is not ROLE_MATRIX |
