# WHAT THIS ASSERTS. Two principals whose reach into the admin plane the central
# suite gets WRONG, for two different reasons.
#
# 1. ROLE_FLEET_ADMIN. The cluster seed carries three /bff/admin/phone-fleet/**
#    rows (FLEET_ADMIN / ADMIN / SUPERADMIN). That pattern is LONGER than the
#    /bff/admin/** ROLE_ADMIN floor, so longest-match makes it the deciding rule
#    and a pure fleet owner is admitted — while staying default-denied on the
#    rest of the admin plane. The central mirror has NONE of those three rows, so
#    gatewayDecision() answers DENY where a deployed gateway answers ALLOW.
#
# 2. ROLE_SUPERADMIN. Measured over BOTH seeds: there is no row granting
#    SUPERADMIN at /admin/** or /bff/admin/**, so the ROWS ALONE decide DENY.
#    Production ALLOWs, via a short-circuit in GatewayRouteAccessFilter that
#    returns chain.filter(exchange) BEFORE decide() is ever consulted. The reach
#    is a FILTER BYPASS, not a grant — and no row-level oracle, this one included,
#    can model it. features/rbac/superadmin-tier.feature asserts only the reverse
#    property (an admin does not reach superadmin routes) and never this one.
#    ⚠ THE BYPASS IS WHY #244's ACCEPT IS DEFENCE-IN-DEPTH AND NOT A FIX FOR AN
#    EXPOSURE. #244 added an fe row for /bff/superadmin/**, which changes what
#    the ROWS say for a non-privileged caller (NO_RULE-and-forwarded becomes DENY
#    at the door, so the 403 finally carries X-Route-Denied). It changes NOTHING
#    for ROLE_ADMIN or ROLE_SUPERADMIN, who never reach decide() at all.
#
# The value of writing the DENY down is that it is the true statement about the
# layer being modelled: anyone reading superadmin-tier.feature and concluding
# "the rows grant superadmin the admin plane" is wrong, and the day somebody
# "fixes" the mirror by adding SUPERADMIN rows, these fail.
#
# THIS RUNS OFFLINE against the in-repo cluster seed.
@layer:gateway
Feature: The fleet owner is admitted by a row; the superadmin is admitted by a bypass

  Background:
    Given the cluster route-access seed is loaded

  # ── the fleet-owner surface ────────────────────────────────────────────────
  Scenario Outline: a principal holding only <granted> is <decision> at the fleet-owner surface @service:admin @layer:gateway
    Given a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "/bff/admin/phone-fleet/devices" from the cluster seed
    Then the seed decision is "<decision>"
    And the deciding url pattern is "/bff/admin/phone-fleet/**"

    Examples:
      | granted          | decision |
      | ROLE_FLEET_ADMIN | ALLOW    |
      | ROLE_ADMIN       | ALLOW    |
      | ROLE_SUPERADMIN  | ALLOW    |
      | ROLE_MOD         | DENY     |
      | ROLE_USER        | DENY     |

  # Longest-match is the MECHANISM, so prove it was the phone-fleet pattern that
  # admitted the fleet owner and not the generic admin floor: the same principal
  # one path over is refused, and the deciding pattern changes.
  Scenario: the fleet owner reaches ONLY the fleet subpath, never the rest of the admin plane @service:admin @layer:gateway
    Given a principal holding only the role "ROLE_FLEET_ADMIN"
    When the "hugmesh-fe-gateway" gateway decides "/bff/admin/allowlist" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "/bff/admin/**"

  # ── the superadmin bypass ──────────────────────────────────────────────────
  Scenario: no seed row grants ROLE_SUPERADMIN on the fe admin surfaces @service:admin @layer:gateway
    Then no cluster seed row grants "ROLE_SUPERADMIN" on the exact pattern "/bff/admin/**" at gateway "hugmesh-fe-gateway"
    And no cluster seed row grants "ROLE_SUPERADMIN" on the exact pattern "/admin/**" at gateway "hugmesh-fe-gateway"

  # THE FE PATTERNS THAT NAME SUPERADMIN — pinned as a CLOSED SET so a future
  # "superadmin needs a row" edit is visible here rather than inferred. This
  # assertion has caught two real landings already and its history is the reason
  # to keep it exhaustive:
  #   * it said "/bff/admin/phone-fleet/** only" and went RED when #329 added
  #     /bff/wiki/superadmin/**, and stayed red on main until now;
  #   * #244 ACCEPT then added /bff/superadmin/** — the platform console at the
  #     public browser door.
  # Deleting any of the three turns this scenario RED naming the missing pattern.
  Scenario: exactly three fe patterns name SUPERADMIN @service:admin @layer:gateway
    Then the only patterns at gateway "hugmesh-fe-gateway" naming "ROLE_SUPERADMIN" are "/bff/admin/phone-fleet/**, /bff/superadmin/**, /bff/wiki/superadmin/**"

  Scenario Outline: the rows alone would refuse a superadmin at <path> @service:admin @layer:gateway
    Given a principal holding only the role "ROLE_SUPERADMIN"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the seed decision is "DENY"
    And the deciding url pattern is "<pattern>"

    Examples:
      | path                 | pattern       |
      | /bff/admin/allowlist | /bff/admin/** |
      | /admin/usage         | /admin/**     |

  # The gateway NAME scopes the decision: the same superadmin BFF prefix that is
  # ungoverned on the fe gateway is a real SUPERADMIN grant on the be gateway.
  # This is a row, not a bypass — so it is the one superadmin reach an oracle CAN
  # model, and the contrast is why the two above are not simply "a missing row".
  Scenario: the superadmin BFF prefix is a real grant on the be gateway @service:admin @layer:gateway
    Given a principal holding only the role "ROLE_SUPERADMIN"
    When the "hugmesh-be-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "ALLOW"
    And the deciding url pattern is "/bff/superadmin/**"

  Scenario: a plain admin gets nothing from the superadmin BFF prefix @service:admin @layer:gateway
    Given a principal holding only the role "ROLE_ADMIN"
    When the "hugmesh-be-gateway" gateway decides "/bff/superadmin/service-store/catalog" from the cluster seed
    Then the seed decision is "DENY"

  # ── the gateway-open admin-ui superadmin routes ────────────────────────────
  # /admin/** is ROLE_ADMIN with no more-specific row for /admin/superadmin/**,
  # so a PLAIN ADMIN is gateway-ALLOWED onto every superadmin-only console route
  # in admin-ui. The only server-side wall behind them is the BFF; the Angular
  # superadminGuard is presentation. Asserting the ALLOW is what makes that
  # dependency explicit instead of assumed.
  Scenario Outline: the gateway ALLOWS a plain admin at <path> — the wall is the BFF @service:admin @layer:gateway
    Given a principal holding only the role "ROLE_ADMIN"
    When the "hugmesh-fe-gateway" gateway decides "<path>" from the cluster seed
    Then the seed decision is "ALLOW"
    And the deciding url pattern is "/admin/**"

    Examples:
      | path                      |
      | /admin/superadmin/domains |
      | /admin/egress-vpn         |
      | /admin/device-licenses    |
      | /admin/backing-services   |
      | /admin/superadmin/anubis  |
