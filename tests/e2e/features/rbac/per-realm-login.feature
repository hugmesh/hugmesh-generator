# The executable Gherkin form of tests/e2e/specs/15-rbac-per-realm-login.spec.ts.
#
# TWO INDEPENDENT REALMS:
#   * SYSTEMS Casdoor (org "hugmesh",      issuer id.hugmesh.net)
#   * GAMES   Casdoor (org "threewizards", issuer id.hugmesh.games)
#
# WHAT IS TESTABLE TODAY. The mock BFF models exactly two role tiers it can tell
# apart by username (admin via ADMIN_EMAILS, else plain user). Both sign in
# through OUR native /bff/login and carry the right roles back from
# GET /bff/session — the realistic FLOOR of the systems login at a surface that
# runs right now. A full per-ROLE login (mod / games / games-admin / pending)
# needs a real seeded Casdoor and is exercised by
# features/rbac/live-gateway-enforcement.feature; here the seed CATALOGUE is
# asserted internally consistent so the seeder and that live login agree on
# usernames, passwords and roles.
#
# The GAMES realm login itself is owned by hugmesh.games/e2e (roles.ts login());
# this feature only asserts the cross-realm catalogue agrees.
@layer:casdoor
Feature: Per-realm login and seed-catalogue consistency

  Scenario: the systems admin signs in through the BFF and carries the admin role @role:admin@hugmesh.net @service:admin @layer:bff
    Given an API client signed in as the persona for this scenario
    Then the API client session carries the role "admin"

  Scenario: an invited plain member signs in WITHOUT the admin role @role:rbac-login-user@gmail.com @service:login @layer:bff
    Given the admin principal "admin@hugmesh.net" has invited "rbac-login-user@gmail.com" onto the allowlist
    And an API client signed in as the persona for this scenario
    Then the API client session carries exactly the roles "user"

  # Offline catalogue invariants — these run with the stack DOWN.
  Scenario: the systems seed catalogue is internally consistent @layer:casdoor
    Then every systems seed persona has a deterministic password and never a directly-granted ROLE_GAMES_ADMIN
    And the systems catalogue contains the personas "e2e-admin, e2e-mod, e2e-gamesadmin, e2e-gamesonly, e2e-adminonly, e2e-user, e2e-pending"

  Scenario: the awaiting-approval persona holds nothing until an admin approves it @role:e2e-pending @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona for this scenario holds no roles and is not registration-complete

  Scenario: the games realm has a native player and a games admin that only the sync explains @service:games @layer:casdoor
    Then the games catalogue carries a native player holding the "player" role
    And the synced games admin derives from a systems persona that earns ROLE_GAMES_ADMIN
