# MINED FROM: hugmesh-user-bff-api ProfileService.java
#             :175-190  reserved / reserved-CONFUSABLE username -> 400 when
#                       enabling a vanity subdomain or a public profile
#             :271-287  guardDisplayName: forbidden-invisible -> 400,
#                       reserved-confusable displayName -> 400
#             :304-317  guardScreenReaderName: non-ASCII screenReaderName -> 400,
#                       non-ASCII displayName with no usable one -> 422
#   AGAINST:  hugmesh-user-ui profile.component.ts:241-242 — every one of those
#             refusals is caught and replaced with "Could not save your profile.
#             Please try again." A user whose input can NEVER succeed is told to
#             retry.
#
# COVERAGE MEASURED, comments stripped: the central suite has ZERO occurrences of
# screenReader, screen-reader or vanity across all 51 features and 33 specs, and
# its 8 hits for "reserved" are all the word "preserved". This rule has three
# independent implementations — the login remote's complete-registration card,
# the user remote's profile editor, and the service leg that answers 422 — and
# the suite exercises none of them.

@layer:bff @env:docker
Feature: Impersonation and a11y guards refuse a profile with a reason the user can act on

  @role:e2e-user
  Scenario: a displayName confusable with a reserved platform name is refused @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client PUTs a profile with displayName "4dmin" and screenReaderName "admin"
    Then the response status is 400
    And the response error message matches "confusable"

  @role:e2e-user
  Scenario: a displayName carrying an invisible code point is refused @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client PUTs a profile whose displayName carries a zero-width joiner
    Then the response status is 400
    And the response error message matches "zero-width|invisible|control"

  # 422, not 400, and the difference is the whole contract: 400 says "that value
  # is wrong", 422 says "I need one more field". The client gate is
  # defence-in-depth over this, never the only wall.
  @role:e2e-user
  Scenario: a non-ASCII displayName with no screen-reader name is a 422 PROMPT @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client PUTs a profile with displayName "凛" and no screenReaderName
    Then the response status is 422
    And the response error message matches "screenReaderName"

  @role:e2e-user
  Scenario: a non-ASCII screen-reader name is a 400, not a 422 @role:e2e-user @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client PUTs a profile with displayName "Rin" and screenReaderName "凛"
    Then the response status is 400
    And the response error message matches "ASCII"

  # The reserved-USERNAME leg (ProfileService:175-190) cannot be driven: it keys
  # on the CALLER'S OWN Casdoor username, and no seeder provisions a persona
  # whose handle is a reserved label or a look-alike of one.
  @role:e2e-user
  Scenario: enabling a vanity subdomain as a reserved-confusable handle is refused @role:e2e-user @layer:bff
    Given this scenario is PENDING because "ProfileService:175-190 keys the reserved / reserved-confusable check on the CALLER'S OWN Casdoor username (usernameOf(jwt)), never on the request body — deliberately, so the guard cannot be spoofed. No seeder provisions a persona named '4dmin', 'akk0ma' or any other ReservedNames look-alike, so there is no identity that can reach this branch. Seed one (e.g. 4dmin:ROLE_USER in tests/e2e-extra-personas.sh) to unblock."
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/user/profile"
    Then the response status is 400

  # THE UI HALF, and it is expected RED: profile.component.ts:241-242 catches
  # every 400/422 above and shows "Could not save your profile. Please try
  # again." — a retry prompt in front of input that can never succeed. @fail
  # makes that a recorded defect rather than a broken lane; when the component
  # surfaces the server's message the tag has to come off.
  @fail @role:e2e-user
  Scenario: the profile editor shows the server's refusal, not a generic retry prompt @role:e2e-user @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/user/profile"
    And I type the profile display name "4dmin"
    And I click the element with test id "profile-save"
    Then the element with test id "profile-status" does not contain the text "Please try again"
