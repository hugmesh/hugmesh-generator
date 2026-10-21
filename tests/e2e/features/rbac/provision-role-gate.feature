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
# WHAT EACH ROW MEANS. A 403 for a bare member is the method gate; a 403 for
# e2e-mod (ROLE_MOD only, no ROLE_USER) is the ROUTE gate refusing before the
# BFF is reached — same code, different artefact, both correct. The two 200
# rows are the control: without them every 403 could be "the stack is broken".
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

    Examples: the OTHER platform's role is not this platform's role
      | role         | service | platform | status | outcome | what                            |
      | e2e-matrix   | akkoma  | mastodon | 403    | refused | ROLE_MATRIX is not ROLE_MASTODON |
      | e2e-mastodon | tuwunel | matrix   | 403    | refused | ROLE_MASTODON is not ROLE_MATRIX |

    Examples: no ROLE_USER at all — refused at the ROUTE row before user-bff is reached
      | role    | service | platform | status | outcome | what                                             |
      | e2e-mod | tuwunel | matrix   | 403    | refused | bare ROLE_MOD; /bff/provision/** grants ROLE_USER |
      | e2e-mod | akkoma  | mastodon | 403    | refused | bare ROLE_MOD; /bff/provision/** grants ROLE_USER |
