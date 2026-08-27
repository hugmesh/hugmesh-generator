# The FOUR explicit-DENY rows — the only negative rows in a 150-row seed.
#
# WHY THEY EXIST. Each of these surfaces is permitAll APP-SIDE: the service behind
# it does no authorization of its own, because it is meant to be reached only by
# another service inside the mesh. The gateway is therefore the ONLY thing
# standing in front of them, and an allow=false row keyed on ROLE_USER is how it
# stands there. Deleting one does not restore a default-deny — a shorter allow row
# (/bff/user/**, /bff/**) is sitting directly above it and would take over.
#
# WHY NOTHING COVERS THEM. tests/e2e/specs/rbac-route-access.ts's Row type has no
# `allow` field at all, so the oracle every rbac scenario evaluates cannot
# represent a negative row in any form. These four are invisible to the entire
# offline lane. The seed-side decision function in steps/mined-platform-edge.steps.ts
# mirrors GatewayRouteAccessService.decide()'s deny-wins model instead.
#
# RUNS OFFLINE.
@harness @layer:gateway @service:gateway
Feature: The SERVICE-only ingest surfaces are closed by explicit DENY rows

  Scenario Outline: a plain member is refused the SERVICE-only ingest at <path> @role:e2e-user @layer:gateway @service:gateway
    Given the persona for this scenario presents its effective role set
    When the seeded route-access table is evaluated for the path "<path>" on the "hugmesh-fe-gateway" gateway
    Then the seeded route-access decision is "DENY"

    Examples:
      | path                           |
      | /bff/user/internal/mesh-bridge |
      | /bff/mesh/internal/bridge-sync |
      | /bff/internal/announcements    |

  # HOW the deny actually wins, which is the part a reader gets wrong. It is not
  # "deny overrides the allow above it" — the allow above it is never consulted.
  # Longest url_pattern wins outright, and the deny row IS the longest match, so
  # a change that made /bff/user/** longer-matching would open the ingest without
  # touching the deny row at all.
  Scenario Outline: the winning row at <path> is the internal-ingest pattern, not the BFF prefix @layer:gateway @service:gateway
    Then the winning seeded pattern for "<path>" on the "hugmesh-fe-gateway" gateway is "<winner>"
    And the route-access seed carries an explicit DENY row at "<winner>" on the "hugmesh-fe-gateway" gateway

    Examples:
      | path                           | winner                  |
      | /bff/user/internal/mesh-bridge | /bff/user/internal/**   |
      | /bff/mesh/internal/bridge-sync | /bff/mesh/internal/**   |
      | /bff/internal/announcements    | /bff/internal/**        |

  # The fourth negative row lives on the tailnet-only superadmin gateway and gates
  # a handler with NO app-layer auth whatsoever. It is denied even to the only
  # role that gateway grants anything to.
  Scenario: the attestation create-account handler is denied to superadmin itself @layer:gateway @service:gateway
    Given a caller holding the roles "ROLE_SUPERADMIN"
    When the seeded route-access table is evaluated for the path "/attest/api/create-account" on the "hugmesh-superadmin-gateway" gateway
    Then the seeded route-access decision is "DENY"
    And the route-access seed carries an explicit DENY row at "/attest/api/create-account" on the "hugmesh-superadmin-gateway" gateway

  # The sibling that is NOT denied, so the scenario above cannot pass by asserting
  # that the whole /attest tree is shut. The device check-in surfaces are PUBLIC on
  # purpose: they carry their own device tokens and no Casdoor identity exists.
  Scenario: the device-facing attestation surfaces stay open to an anonymous device @layer:gateway @service:gateway
    Given an anonymous caller presenting no roles
    When the seeded route-access table is evaluated for the path "/attest/api/status" on the "hugmesh-superadmin-gateway" gateway
    Then the seeded route-access decision is "ALLOW"
