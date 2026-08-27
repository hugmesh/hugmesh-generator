# The Wiki console — the first e2e coverage this service has EVER had.
#
# WHAT IS ACTUALLY BEING DRIVEN. /wiki is a federated remote (hugmesh-wiki-ui)
# mounted by the host shell behind wikiGuard = admin | superadmin | (mod AND
# ROLE_WIKI). Inside the remote the console shell renders a role-aware menubar
# and redirects '' -> 'pages' behind wikiReadGuard, so a successful open is
# THREE gates deep: gateway route, host guard, in-remote guard. Every assertion
# below is a fact one of those three produces.
#
# WHY ADMIN AND NOT A WIKI MEMBER. No persona in either e2e roster holds
# ROLE_WIKI — see access-role-roster.feature, which asserts that gap and will
# fail the day it closes. The admin path is the one the seeded roster can
# actually walk, so it is the one driven here; the member path is honestly absent
# rather than faked.
#
# WHY THE NEGATIVE ROWS MATTER AS MUCH. A signed-in identity that lacks the role
# is sent to /home?denied=<path>, NOT to /login. Sending it to /login was a real
# defect (operator report 2026-08-14, "moderation menu option just redirects to
# login"): it tells someone who just signed in that they are not signed in, and
# it made an AUTHORIZATION problem present as a SESSION problem, which is where
# the diagnosis went wrong. Pinning the destination is what stops that
# regressing.
@service:wiki @layer:ui
Feature: The wiki console opens for the roles that hold it and refuses the rest

  Scenario Outline: <role> opens the wiki console and lands on the content view @role:<role> @service:wiki @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/wiki"
    Then the URL matches "/wiki/pages"
    And the level 1 heading "Wiki" is visible
    And the element with test id "wiki-nav-pages" is visible
    And the element with test id "wiki-nav-new" is visible
    And the element with test id "wiki-nav-access" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # WIKI_MANAGE is superadmin-only (the list-all + history + audit views). The
  # pair of scenarios below is the whole point of a role-aware menubar: the
  # boundary is only proved when the SAME nav entry is asserted present for one
  # identity and absent for the other.
  @role:e2e-superadmin
  Scenario: the superadmin additionally sees the wiki management entry @layer:ui @role:e2e-superadmin @service:wiki
    Given I am signed in as the persona for this scenario
    When I open the path "/wiki"
    Then the element with test id "wiki-nav-manage" is visible

  @role:e2e-admin
  Scenario: a platform admin does not see the superadmin-only wiki management entry @layer:ui @role:e2e-admin @service:wiki
    Given I am signed in as the persona for this scenario
    When I open the path "/wiki"
    Then the element with test id "wiki-nav-access" is visible
    And the element with test id "wiki-nav-manage" is not visible

  # e2e-mod is the interesting negative: wikiGuard admits a mod ONLY when they
  # additionally hold ROLE_WIKI (an AND a path-level hasAnyRole cannot express).
  # Nothing seeds ROLE_WIKI, so a bare mod is refused — and the refusal must land
  # on the shell home page carrying the attempted path, not on the login form.
  Scenario Outline: <role> is refused the wiki console and told which console was refused @role:<role> @service:wiki @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/wiki"
    Then the URL matches "/home[?]denied="
    And the URL matches "denied=.*wiki"

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |
