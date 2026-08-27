# The executable Gherkin form of part (ii) of
# tests/e2e/specs/25-rbac-cross-realm-superadmin.spec.ts.
#
# The SYSTEMS Casdoor and the GAMES Casdoor are INDEPENDENT issuers. A token
# minted by one carries that realm's roles ONLY; the other realm's gateway must
# treat its claims as absent. So a games-realm identity presenting its role-set to
# a systems gateway is DENY on every privileged route, and no systems ROLE_* is
# ever a native games role.
#
# The ONLY systems->games link is the ROLE_GAMES_ADMIN -> admin SYNC: a row
# MATERIALIZED in the games Casdoor by hugmesh-actions, never a claim a systems
# token carries across. The PROPAGATION proof is owned by hugmesh-actions/e2e
# (sync-steps.ts) and is deliberately NOT duplicated here; what IS asserted here
# is the catalogue half of the seam, so the two catalogues cannot silently
# disagree about it.
#
# Runs OFFLINE.
@layer:casdoor
Feature: Cross-realm issuer isolation between systems and games

  Scenario: the two realms have distinct issuers @layer:casdoor
    Then the systems realm and the games realm have distinct issuers

  Scenario: a games-realm identity carries no systems role into a systems gateway @service:games @layer:gateway
    Then no games-realm identity reaches any privileged systems route

  Scenario: a systems identity carries no native games role into the games realm @service:games @layer:casdoor
    Then no systems role is a native games role

  Scenario: the synced games admin agrees with the systems ROLE_GAMES_ADMIN derivation @service:games @layer:casdoor
    Then the synced games admin derives from a systems persona that earns ROLE_GAMES_ADMIN
