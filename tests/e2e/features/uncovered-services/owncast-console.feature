# The Owncast console — the first e2e coverage this service has EVER had.
#
# THIS FEATURE ENCODES A GAP RATHER THAN HIDING IT. Owncast's console shell is
# reachable by an admin (the host-shell owncastGuard admits admin | superadmin |
# ROLE_OWNCAST), but the console's DEFAULT view — '' redirects to 'stream' —
# is guarded on canStream(), which is ROLE_OWNCAST *alone*: an admin is not a
# streamer. Nothing in either e2e roster holds ROLE_OWNCAST, so the honest,
# reproducible journey for the seeded roster is:
#
#   admin opens /owncast  ->  console shell renders  ->  redirected to
#   /owncast/forbidden, offering only the actions the admin really has.
#
# That is not a broken test. It is the accurate shape of the service on a
# default-seeded mesh, and it is a far more useful thing to pin than a
# fabricated streaming flow nobody can run. When a ROLE_OWNCAST persona is
# seeded, access-role-roster.feature goes red and this feature is where the
# streamer journey gets added.
#
# The nav assertions carry the real role boundary: Broadcast grants (admin),
# Moderation (mod|admin|superadmin), My Stream (owncast streamers only).
@service:owncast @layer:ui
Feature: The Owncast console shows an admin exactly the surfaces an admin holds

  Scenario Outline: <role> reaches the Owncast console and is offered only the admin surfaces @role:<role> @service:owncast @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast"
    Then the level 1 heading "Owncast" is visible
    And the element with test id "owncast-nav-grants" is visible
    And the element with test id "owncast-nav-moderation" is visible
    And the element with test id "owncast-nav-stream" is not visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # The redirect itself, pinned. '' -> 'stream' -> owncastStreamGuard -> the
  # IN-REMOTE forbidden screen (not '/forbidden', not '/login'): the host already
  # authgated the user in, so a denial here is a within-owncast privilege
  # boundary and must read as one.
  @role:e2e-admin
  Scenario: an admin without the streamer role lands on the in-remote privilege boundary @layer:ui @role:e2e-admin @service:owncast
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast"
    Then the URL matches "/owncast/forbidden"
    And the element with test id "owncast-forbidden-title" is visible
    And the element with test id "owncast-forbidden-moderation" is visible
    And the element with test id "owncast-forbidden-stream" is not visible

  Scenario Outline: <role> is refused the Owncast console entirely @role:<role> @service:owncast @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast"
    Then the URL matches "/home[?]denied="
    And the URL matches "denied=.*owncast"

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |
