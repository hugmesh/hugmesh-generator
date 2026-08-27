# MINED FROM: hugmesh-user-bff-api ProfileController.java:29-37 — "the owner is
#             ALWAYS the JWT subject (jwt.getSubject()) — never a path/body
#             field ... There is deliberately NO /profile/{userId} route" — and
#             :79-86, where upsert() derives BOTH the owner and the vanity
#             username from the token so the reserved-username guard cannot be
#             bypassed by spoofing the body.
#   BACKED BY: RawApiDenyOwnerScopedIdorTest, "PUT /profile: attacker's body
#             userId=victim is IGNORED — write lands on attacker, victim
#             untouched", plus its cross-tenant brand-X/brand-Y rows.
#
# COVERAGE MEASURED, comments stripped: the central suite returns ZERO for IDOR,
# cross-tenant and forged. This is the strongest owner-scoping guarantee in M1
# and the suite tests none of it.
#
# WHY END-TO-END ON TOP OF THE COMPONENT TEST. The component test proves the
# CONTROLLER ignores the body field, against a slice. End to end the same
# guarantee also has to survive the gateway's cookie-to-bearer mint and the
# JWT-subject-vs-username distinction — two layers the slice never sees, either
# of which could reintroduce the body field as the effective owner.
#
# PORTED IN SHAPE (not verbatim) FROM: hugmesh-user-ui/e2e/features/cross-user/
# owner-subject-isolation.feature and elevated-role-owner-subject.feature. Those
# 14 scenarios are written as parallel two-user runs over self-blocks, login
# sessions, connected clients and self-silences — resources this suite has no
# vocabulary for at all. What is adopted here is the SHAPE that makes them
# non-vacuous and that the central suite lacks entirely: every DENY is paired
# with a re-read through the VICTIM'S OWN session, because a status code on the
# attacker's call says nothing about where the write landed. Only the PROFILE
# resource is ported; the other four belong to the user-ui unit.

@layer:bff @env:docker
Feature: A profile write can only ever land on its own author

  @role:e2e-user
  Scenario: a body userId naming another user is ignored and the victim's row is untouched @role:e2e-user @layer:bff
    Given the seeded persona "e2e-mod" holds a profile with displayName "Mod Original"
    And an API client signed in as the persona for this scenario
    When the API client PUTs a profile whose body userId names "e2e-mod" and displayName "Hijacked"
    Then the response status is 200
    And my own profile displayName is "Hijacked"
    And the seeded persona "e2e-mod" still holds displayName "Mod Original"

  # ELEVATION STOPS AT THE PERSONAL-DATA BOUNDARY. The rbac lane proves elevated
  # roles reach MORE surfaces; nothing proves they stop here. This is the highest-
  # value single row of the user-ui port.
  @role:e2e-admin
  Scenario: an admin is bound by owner==subject exactly like a plain member @role:e2e-admin @layer:bff
    Given the seeded persona "e2e-user" holds a profile with displayName "User Original"
    And an API client signed in as the persona for this scenario
    When the API client PUTs a profile whose body userId names "e2e-user" and displayName "Admin Overwrote"
    Then the response status is 200
    And my own profile displayName is "Admin Overwrote"
    And the seeded persona "e2e-user" still holds displayName "User Original"

  @role:e2e-superadmin
  Scenario: a superadmin is bound by owner==subject exactly like a plain member @role:e2e-superadmin @layer:bff
    Given the seeded persona "e2e-user" holds a profile with displayName "User Original"
    And an API client signed in as the persona for this scenario
    When the API client PUTs a profile whose body userId names "e2e-user" and displayName "Superadmin Overwrote"
    Then the response status is 200
    And the seeded persona "e2e-user" still holds displayName "User Original"

  # There is no addressable route for another user's profile. A 404 here is the
  # CONTRACT (ProfileController:29-37), not an accident of routing — if someone
  # adds /profile/{userId} it becomes a 200 and this is the only thing that says
  # it should not.
  @role:e2e-user
  Scenario: there is no addressable profile route for another user @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/user/profile/e2e-mod"
    Then the response status is 404

  # The ALLOW contrast that stops the DENYs above passing vacuously: the owner
  # reads and writes their OWN row perfectly well.
  @role:e2e-admin
  Scenario: an admin still manages their OWN profile @role:e2e-admin @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client PUTs a profile with displayName "Admin Own Name" and screenReaderName "Admin Own Name"
    Then the response status is 200
    And my own profile displayName is "Admin Own Name"

  Scenario: an anonymous client is refused every owner-scoped profile verb @layer:bff
    Given an anonymous API client
    When the API client GETs "/bff/user/profile"
    Then the response status is 401
    When the API client GETs "/bff/user/profile/avatar/body"
    Then the response status is 401
