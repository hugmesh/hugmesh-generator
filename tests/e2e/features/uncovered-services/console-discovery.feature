# DISCOVERY — "a console you cannot find is, for the operator, a console that
# does not exist."
#
# That sentence is quoted from tests/e2e/specs/33-console-access-matrix.spec.ts,
# which was written for the 2026-08-14 operator report: "this functionality
# should already exist but we can't find it nor any control UIs for any of the
# services." Spec 33 fixed and pinned the discovery half for exactly TWO
# consoles — Admin and Moderation. It stops there.
#
# MEASURED, NOT SUSPECTED: hugmesh-host-shell's menu.component.ts `navEntries`
# list contains Home, Mastodon, Matrix, Forum, Admin, Moderation and NOTHING
# ELSE. There is no entry for wiki, tube, owncast, character-studio,
# character-forge or games — even though each has a host route, a guard that
# admits somebody, a gateway route and a route-access row. `serviceCardEntries()`
# derives the home-page service cards from the SAME list, so those six services
# have no card either. Every console this domain drives is therefore reachable
# only by typing its URL, which is precisely the state the operator reported.
#
# WHY @fixme AND NOT A RED BUILD. The fix is one entry per service in ANOTHER
# repo's menu component; this unit does not own that file, and a permanently red
# lane trains people to ignore it. So each scenario is PENDING with the reason
# and the exact fix named, still appears in `--list`, and still has every step
# resolved by the generator. Add the nav entry, drop the @fixme, and the scenario
# becomes the regression test that keeps it there.
#
# The REACH half of the same question is NOT pending — wiki-console.feature,
# tube-console.feature, owncast-console.feature, games-console.feature,
# character-remotes.feature and forum-console.feature all open these consoles by
# URL and assert they render. Discovery is the only half that is missing.
@layer:ui
Feature: The uncovered consoles are findable in the shell menubar, not URL-only

  @fixme @role:e2e-admin @service:wiki
  Scenario: PENDING (host-shell menu.component.ts navEntries has no wiki entry) — an admin finds the Wiki console in the menubar @layer:ui @role:e2e-admin @service:wiki
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-wiki" is visible

  @fixme @role:e2e-admin @service:tube
  Scenario: PENDING (host-shell menu.component.ts navEntries has no tube entry) — an admin finds the Tube console in the menubar @layer:ui @role:e2e-admin @service:tube
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-tube" is visible

  @fixme @role:e2e-admin @service:owncast
  Scenario: PENDING (host-shell menu.component.ts navEntries has no owncast entry) — an admin finds the Owncast console in the menubar @layer:ui @role:e2e-admin @service:owncast
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-owncast" is visible

  @fixme @role:e2e-user @service:character-studio
  Scenario: PENDING (host-shell menu.component.ts navEntries has no character-studio entry) — a member finds Character Studio in the menubar @layer:ui @role:e2e-user @service:character-studio
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-character-studio" is visible

  @fixme @role:e2e-user @service:character-forge
  Scenario: PENDING (host-shell menu.component.ts navEntries has no character-forge entry) — a member finds Character Forge in the menubar @layer:ui @role:e2e-user @service:character-forge
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-character-forge" is visible

  @fixme @role:e2e-gamesonly @service:games
  Scenario: PENDING (host-shell menu.component.ts navEntries has no games entry) — a games member finds the games entry point in the menubar @layer:ui @role:e2e-gamesonly @service:games
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-games" is visible

  # The one that DOES exist today, kept as the positive control for the six
  # pending rows above: if `nav-forum` ever stops rendering, the pending
  # scenarios' reason ("the list has no entry for X") is no longer the whole
  # story, and this is what says so.
  @role:e2e-forum @service:phpbb
  Scenario: the forum entry IS listed in the menubar, which is what the six pending rows are missing @layer:ui @role:e2e-forum @service:phpbb
    Given I am signed in as the persona for this scenario
    When I open the path "/"
    Then the element with test id "nav-forum" is visible
