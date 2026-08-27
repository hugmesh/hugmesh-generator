# GET /api/federation/capabilities — the ONE federation surface that is
# deliberately unauthenticated, and the only signal the host shell has for which
# optional services exist at all.
#
# WHY IT MATTERS. hugmesh-host-shell's capabilities.service.ts reports NOT
# INSTALLED for an unknown slug AND for a failed fetch, and menu.component.ts
# checks "not installed" BEFORE "not a member" and BEFORE "registration
# incomplete". So this endpoint decides, for every optional service, whether the
# menu entry is greyed and which of three reasons the user is told. A projection
# that answers wrongly does not error anywhere: it greys the whole optional tier
# and blames the user's account.
#
# WHY IT IS UNCOVERED. `grep -rn 'federation/capabilities'` over features/ and
# specs/ returns ZERO. The word "capabilit" appears in exactly one feature file —
# moderation-media/sticker-character-ban-contract.feature — as prose about an
# unbuilt sticker-ban capability. Nothing in this suite has ever issued this
# request, authenticated or not.
#
# THE THREE PROPERTIES ASSERTED (federation-api CapabilityController /
# CapabilityService / CapabilityDto, read 2026-08-26):
#
#  1. PUBLIC READ. permitAll on the controller, PUBLIC in the route-access seed
#     — and forum-tier-stack.feature already pins the seed row offline. This is
#     the other half: that the door actually answers 200 to nobody-at-all.
#  2. FRAGMENT-EXCLUDED. Vanity `profile-<username>` rows are the `fragment`
#     kind, cut IN THE QUERY (findByDomainAndKindNot), never filtered in Java
#     after the fetch. On a permitAll endpoint that distinction is the difference
#     between a capability list and an unauthenticated username enumerator.
#  3. STATE IS NOT ABSENCE. A registered-but-disabled module is LISTED with
#     installed=false (the host greys it BY STATE, and an operator toggle fixes
#     it); a module nobody registered is ABSENT (greyed BY ABSENCE, and no toggle
#     can help). owncast is the live example: 031-register-owncast-module.xml
#     seeds the row with enabled=false, so it must be PRESENT. Collapsing the two
#     is what turns a greyed card into a dead link.
#
# @env:docker, so with no mesh up this SKIPS naming the command to start one
# (`make stack-up ENV=test` then `make stack-seed`) rather than failing as though
# the product were broken. It is listed either way. Every environment on this box
# is down as of 2026-08-26, so this scenario has NEVER been observed green —
# stated here rather than implied by a green run elsewhere.
@service:gateway @layer:bff
Feature: The public capability projection lists install STATE without leaking identities

  @env:docker
  Scenario: an anonymous caller gets the default brand's social modules and no vanity rows @service:gateway @layer:bff @env:docker
    Given I hold an anonymous API client
    When I read the public federation capability list
    Then the capability list contains the slug "forum"
    And the capability list contains the slug "mastodon"
    And the capability list contains the slug "matrix"
    And the capability list contains no slug starting with "profile-"

  # The three M3 social modules ship enabled=true and circuit_state=closed in
  # their registration changesets (022/023/024), which is exactly what
  # CapabilityDto derives installed from. A false here on a stock seeded mesh
  # means the row was flipped, not that the service is missing.
  @env:docker
  Scenario: the three social modules a stock mesh ships report themselves installed @service:gateway @layer:bff @env:docker
    Given I hold an anonymous API client
    When I read the public federation capability list
    Then the capability slug "forum" reports installed "true"
    And the capability slug "mastodon" reports installed "true"
    And the capability slug "matrix" reports installed "true"

  # STATE vs ABSENCE. owncast is registered and DISABLED on a stock mesh, so it
  # must be in the list. Its installed value is deliberately NOT asserted — an
  # operator selection legitimately flips it (seed-e2e.sh leg 4) — but its
  # PRESENCE is not negotiable, because presence is what tells the host shell
  # "this can be turned on" instead of "this deployment does not have it".
  @env:docker
  Scenario: a registered-but-disabled service is listed, not omitted @service:gateway @layer:bff @env:docker
    Given I hold an anonymous API client
    When I read the public federation capability list
    Then the capability list contains the slug "owncast"

  # A SIGNED-IN member reads the same projection through the same public path.
  # The fragment cut is a property of the QUERY, not of the caller, so a session
  # must not widen it — if authenticating is what starts returning profile- rows,
  # the exclusion moved out of the query and the anonymous case above is one
  # refactor away from leaking too.
  @env:docker @role:e2e-user
  Scenario: a signed-in member's projection is fragment-excluded on the same terms @service:gateway @layer:bff @env:docker @role:e2e-user
    Given I hold an API session as the persona for this scenario
    When I read the public federation capability list
    Then the capability list contains no slug starting with "profile-"
    And the capability list contains the slug "matrix"
