# WHAT THIS ASSERTS — hugmesh-admin-bff-api#8 (label: Manual): the MDM phone
# fleet control plane is shipped and tested; its aggregate DefaultPhoneLockEnforcer
# fans a lock out to THREE enforcement legs — Headwind device-owner DPC,
# headscale tailnet mesh-deny, Azure Intune Graph remoteLock — and all three
# ship DARK behind independent flags, so today a lock records authoritative DB
# state and reports DEGRADED with the Headwind-console fallback reason. The
# issue's remaining work is a live smoke of each leg, not code.
#
# What the GENERATOR can honestly say about that, re-measured 2026-09-23:
#   * WHO may lock. Two planes: the fleet-OWNER plane at /bff/admin/phone-fleet/**
#     (PhoneFleetOwnerController — FLEET_ADMIN/ADMIN/SUPERADMIN at the method,
#     then an owner+domain wall and a fleet ENTITLEMENT for everyone but a
#     superadmin) and the superadmin plane at /bff/superadmin/phone-devices/**
#     (PhoneManagementSuperadminController). The seed pairs three explicit
#     /bff/admin/phone-fleet/** rows so longest-match admits the pure fleet
#     owner while the /bff/admin/** ROLE_ADMIN floor keeps it out of the rest of
#     the admin plane; and decision 56's blanket flip makes every /bff/admin/%
#     allow row mfa_required — the lock endpoint is an MFA-gated surface.
#   * THE LEGS ARE DARK, by construction of THIS repo's config: neither the kind
#     admin-bff Deployment nor tests/stack/compose.local.yaml sets any
#     app.phone-lock.<leg>.enabled flag, and (sibling read) PhoneLockConfig
#     wires the real client of each leg ONLY on an explicit `true`, the no-op
#     that reports the leg disabled on `false`/absent. That is the mechanism
#     behind "DEGRADED with the fallback reason".
#   * WHO reaches the fleet list, live: superadmin unscoped 200; a plain admin
#     passes the gateway and is refused by the ENTITLEMENT wall in the BFF (403
#     without X-Route-Denied — a different wall from the member's, and the
#     scenario says which); member and moderator 403 at the gateway; anonymous
#     401. The pure fleet owner (e2e-fleet) is deliberately NOT driven here: on
#     this stack the gateway MFA leg is ON (APP_MFA_ENABLED=true) and e2e-fleet
#     is exactly the principal decide() MFA-gates, which is spec 29's proof
#     (features/moderation-media, mfa-privileged-floor) and not this file's.
#
# WHAT IS NOT WRITTEN, and why:
#   * the lock itself, live — no e2e mesh seeds a phone device for any persona
#     (grep of tests/stack and specs/compose: nothing), so "lock the first
#     phone" has no first phone; PENDING below names the seeder line needed.
#   * the three legs' live smoke — each needs a real Headwind / headscale /
#     Intune endpoint with its flag flipped ON; there is no fixture for any of
#     them in docker/kind/qemu and flipping a flag is the operator's action.
#     That is the manual work the issue's label already says it is.
@service:admin @issue:admin-bff-api-8
Feature: The phone-fleet lock plane — who may lock, MFA-gated, with every enforcement leg dark

  # ── the rows the cluster loads ─────────────────────────────────────────────
  Scenario Outline: a principal holding only <granted> is <decision> at the fleet-owner lock endpoint @layer:gateway
    Given the cluster route-access seed is loaded
    And a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "/bff/admin/phone-fleet/e2e-device/lock" from the cluster seed
    Then the seed decision is "<decision>"
    And the deciding url pattern is "/bff/admin/phone-fleet/**"
    And the deciding rule requires MFA

    Examples:
      | granted          | decision |
      | ROLE_FLEET_ADMIN | ALLOW    |
      | ROLE_ADMIN       | ALLOW    |
      | ROLE_SUPERADMIN  | ALLOW    |
      | ROLE_MOD         | DENY     |
      | ROLE_USER        | DENY     |

  # ── the legs ship dark ─────────────────────────────────────────────────────
  Scenario: every enforcement leg ships dark in both e2e meshes and is wired only on an explicit true @layer:bff
    Then neither the kind admin-bff Deployment nor the compose stack sets a phone-lock leg flag
    And the admin-bff phone-lock legs are exactly "headwind, mesh-deny, azure-intune", each wired only when its flag is explicitly true

  # ── who reaches the fleet list, live ───────────────────────────────────────
  @env:docker @role:e2e-superadmin
  Scenario: the superadmin lists the whole fleet unscoped @role:e2e-superadmin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/phone-fleet"
    Then the response status is 200

  # A plain admin clears the gateway (ROLE_ADMIN is paired on the row) and is
  # stopped by the BFF's fleet-entitlement wall — 403 with NO X-Route-Denied.
  @env:docker @role:e2e-admin
  Scenario: an admin without a fleet entitlement is refused by the BFF, not the gateway @role:e2e-admin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/phone-fleet"
    Then the response status is 403
    And the refusal came from the BFF, not the gateway

  @env:docker
  Scenario Outline: <role> is refused the fleet list at the gateway @role:<role> @env:docker @layer:gateway
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/phone-fleet"
    Then the response status is 403
    And the refusal came from the gateway

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |

  @env:docker
  Scenario: an anonymous client is unauthenticated at the fleet list @env:docker @layer:gateway
    Given an anonymous API client
    When the API client GETs "/bff/admin/phone-fleet"
    Then the response status is 401

  # ── the lock itself ────────────────────────────────────────────────────────
  @env:docker @role:e2e-superadmin
  Scenario: PENDING (no device seeded) — a lock with every leg dark records authoritative state and reports DEGRADED @role:e2e-superadmin @env:docker @layer:bff
    Given this scenario is PENDING because "no e2e mesh seeds a phone device: tests/stack/ and specs/compose/ carry no phone-fleet / phone_device fixture, and PhoneFleetOwnerController answers 404 (not 403) for a device id that is not owned-in-domain, so 'lock the first phone' has no first phone to lock. DESIRED: a seeded device row for e2e-fleet (owner subject e2e-fleet, the e2e domain) plus a fleet entitlement for it, after which this scenario POSTs /bff/superadmin/phone-devices/<id>/lock with reason 'e2e lockout drill' and asserts the row reads locked AND the enforcement status reads DEGRADED with the Headwind-console fallback reason — the behaviour hugmesh-admin-bff-api#8 describes for every leg dark. The three legs' live smoke (Headwind DPC, headscale mesh-deny, Intune remoteLock) stays manual: each needs a real endpoint and its flag flipped on, which no e2e mesh provides."
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/phone-fleet"
    Then the response status is 200
