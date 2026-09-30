# TWO SUPERADMIN-ONLY BFF SEAMS, driven live from BELOW the tier.
#
# Both surfaces landed or changed after 2026-09-01 and both were covered only
# from the superadmin side (hugmesh-superadmin-service-catalog-ui
# curation-cross-user-visibility.feature exercises withdraw on its happy path;
# hugmesh-wiki-ui cross-brand-target-domain.feature reads the brand catalogue as
# the superadmin). Nothing asserted that an ADMIN — the tier one step below,
# and the one the gateway admin-bypass FORWARDS past the route-access row — is
# refused at the method. This file is that assertion, for every seeded tier.
#
#   POST /bff/superadmin/service-store/{domain}/withdraw
#       admin-bff ServiceCurationController#withdraw, @PreAuthorize("hasRole('SUPERADMIN')")
#       and NOTHING ELSE: hugmesh-admin-bff-api#51 added a step-up gate on
#       2026-09-10 00:22 (commit 311f20a5) and commit a9cbfdda REMOVED it the
#       same day after the operator answered "role only" on hugmesh-generator#347
#       decision 6. So — deliberately — no step-up scenario here; the verb takes
#       no step-up header, cookie or Authorization parameter at all.
#       The body is REQUIRED (@Valid @RequestBody ServiceCurationRequest
#       {serviceKey}) and argument binding runs BEFORE method security, so a
#       bodiless probe would answer 400 for every tier and prove nothing about
#       the role gate. Every row therefore sends a valid body.
#
#   GET /bff/wiki/superadmin/brands
#       wiki-bff WikiAccessController:327, WikiController.WIKI_MANAGE =
#       hasRole('SUPERADMIN') (wiki-bff-api#12, commit b124b24c). The seed row
#       ('hugmesh-fe-gateway','/bff/wiki/superadmin/**','ROLE_SUPERADMIN') is
#       MORE SPECIFIC than /bff/wiki/**, so ROLE_WIKI and ROLE_ADMIN never win it.
#       NEEDS THE WIKI BFF IN THE STACK (the WIKI profile): without it the
#       gateway answers 502/503 for every tier and this feature is honestly red,
#       not vacuously green.
#
# All three BFFs' RoleHierarchy is SUPERADMIN > ADMIN / MOD / USER only
# (admin-bff SecurityConfig:608, wiki-bff SecurityConfig:365), so a 403 for
# ROLE_ADMIN is the method gate, not a hierarchy accident; and the seed's
# /bff/superadmin/** floor sits under the mfa_required prefix, so on a mesh with
# the privileged MFA floor ARMED the superadmin control rows answer 403/503 from
# the gateway instead — the compose default leaves the floor off.
#
# LIVE — @env:docker. Skips loudly with the start command when nothing answers.
@service:admin @layer:bff @env:docker
Feature: Superadmin-only BFF seams refuse every lower tier at the method, not just at the route

  # ── service-store withdraw (admin-bff-api#51) ─────────────────────────────

  @issue:admin-bff-api-51
  Scenario Outline: <role> is refused the service-store withdraw verb (<what>) @role:<role> @service:admin @layer:bff
    Given I hold an API session as the persona for this scenario
    When I submit a POST to "/bff/superadmin/service-store/e2e-unoffered.example/withdraw" with body:
      """
      {"serviceKey": "e2e-probe"}
      """
    Then the response status is 403

    Examples:
      | role          | what                                                              |
      | e2e-admin     | ROLE_ADMIN — the admin-bypass forwards it, the method gate refuses |
      | e2e-adminonly | ROLE_ADMIN without any platform role                               |
      | e2e-fleet     | ROLE_FLEET_ADMIN — the fleet tier is not the superadmin tier       |
      | e2e-mod       | bare ROLE_MOD                                                     |
      | e2e-user      | bare ROLE_USER                                                    |

  # The control: the superadmin passes the role gate and reaches the curation
  # SERVICE, which answers 404 for a (domain, serviceKey) nobody offered
  # (ServiceCurationService#withdraw: "no offered service '…' for domain '…'").
  # Asserting the exact 404 + message — not merely "not 403" — is what proves
  # the 403s above came from the ROLE gate: the same request from the right tier
  # got past it and was judged on its merits.
  @issue:admin-bff-api-51 @role:e2e-superadmin
  Scenario: the superadmin passes the withdraw role gate and is answered by the curation service @role:e2e-superadmin @service:admin @layer:bff
    Given I hold an API session as the persona for this scenario
    When I submit a POST to "/bff/superadmin/service-store/e2e-unoffered.example/withdraw" with body:
      """
      {"serviceKey": "e2e-probe"}
      """
    Then the response status is 404
    And the response body contains "no offered service"

  # ── wiki brand catalogue (wiki-bff-api#12) ────────────────────────────────

  @issue:wiki-bff-api-12
  Scenario Outline: <role> is refused the wiki brand catalogue (<what>) @role:<role> @service:wiki @layer:bff
    Given I hold an API session as the persona for this scenario
    When I request "GET /bff/wiki/superadmin/brands"
    Then the response status is 403

    Examples:
      | role          | what                                                           |
      | e2e-admin     | ROLE_ADMIN — reaches /bff/wiki/admin/**, not the superadmin seam |
      | e2e-adminonly | ROLE_ADMIN without any platform role                            |
      | e2e-mod       | bare ROLE_MOD                                                  |
      | e2e-user      | bare ROLE_USER                                                 |

  @issue:wiki-bff-api-12 @role:e2e-superadmin
  Scenario: the superadmin reads the brand catalogue the console's picker needs @role:e2e-superadmin @service:wiki @layer:bff
    Given I hold an API session as the persona for this scenario
    When I request "GET /bff/wiki/superadmin/brands"
    Then the response status is 200
