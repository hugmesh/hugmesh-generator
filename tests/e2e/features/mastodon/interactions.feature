# THE MASTODON INTERACTIONS — what one signed-in identity does TO another, and
# how the other one finds out.
#
# ../mastodon/two-party-timeline.feature already proves the one interaction this
# suite had: A follows B, B posts, A's home timeline shows it. That leaves the
# rest of what a social network IS — boosting, favouriting, replying, being
# notified, unfollowing — described nowhere. These are those.
#
# ── THE RULE EVERY SCENARIO HERE FOLLOWS ────────────────────────────────────
# The assertion is ALWAYS taken on the RECEIVING side. A 200 from the actor's own
# call proves the request was accepted, not that anything reached the other
# identity — and a scenario that stopped at the actor would look identical in the
# report while proving nothing at all. So a boost is asserted as a 'reblog'
# NOTIFICATION in the author's own notification list, a reply as a 'mention', an
# unfollow as `following: false` in the peer's OWN relationship row.
#
# ── TWO COOKIE-SEPARATED IDENTITIES, NOT ONE PAGE ───────────────────────────
# Every scenario opens a second browser context through steps/social-peers.ts and
# signs a DIFFERENT seeded ROLE_MASTODON persona into it. alice@/bob@gmail.com
# cannot drive these: they hold ROLE_USER only and are DENIED the homeserver
# backend by design (../matrix/platform-access-wall.feature asserts that deny).
#
# ── WHY THE hsproxy AND NOT THE UI ──────────────────────────────────────────
# specs/helpers.ts already drives mastodonFollow this way. The browser holds NO
# Mastodon token: auth is the httpOnly bff_session cookie and the user-bff injects
# the real credential server-side, so an API call from `page.request` is the SAME
# custody model the UI uses, not a back door around it. The composer and the
# timeline ARE driven through their pinned test ids, because those exist; a boost
# button nobody has pinned would have to be invented, and an invented test id is
# a scenario that can never pass.
#
# ── HONEST GATING ───────────────────────────────────────────────────────────
# @env:docker. These need a live compose stack with SOCIAL=1 and a seeded roster.
# With nothing running they SKIP with the reason and the start command
# (`make stack-up ENV=test` then `make stack-seed`) — never a silent pending, and
# never a pass. The offline half of this service's coverage is
# ./function-surface.feature, which asserts the gate for all 31 personas with the
# stack down.
@service:akkoma @layer:ui @env:docker
Feature: Mastodon interactions — boosting, favouriting, replying, being notified, unfollowing

  @role:e2e-mastodon
  Scenario: a peer boosts my status and the boost reaches my notifications
    Given I am signed in as the persona for this scenario
    And my peer and I both hold Mastodon accounts
    And my peer follows me on Mastodon
    When I open the Mastodon timeline
    And I post the Mastodon status "boost me, fediverse" with a unique run marker
    Then my Mastodon timeline shows my status
    When my peer boosts my latest Mastodon status
    Then my Mastodon notifications include a "reblog" from my peer

  @role:e2e-mastodon
  Scenario: a peer favourites my status and the favourite reaches my notifications
    Given I am signed in as the persona for this scenario
    And my peer and I both hold Mastodon accounts
    And my peer follows me on Mastodon
    When I open the Mastodon timeline
    And I post the Mastodon status "favourite me, fediverse" with a unique run marker
    Then my Mastodon timeline shows my status
    When my peer favourites my latest Mastodon status
    Then my Mastodon notifications include a "favourite" from my peer

  @role:e2e-mastodon
  Scenario: a peer replies to my status and the reply reaches me as a mention
    Given I am signed in as the persona for this scenario
    And my peer and I both hold Mastodon accounts
    And my peer follows me on Mastodon
    When I open the Mastodon timeline
    And I post the Mastodon status "reply to me, fediverse" with a unique run marker
    Then my Mastodon timeline shows my status
    When my peer replies "replying from the other identity" to my latest Mastodon status
    Then my Mastodon notifications include a "mention" from my peer

  # The FOLLOW-INDEPENDENT control. The home timeline is decided by the follow
  # graph, so a status missing from home could equally mean the post failed or
  # the follow did. The local public timeline needs no follow at all — a status
  # present here and absent from home isolates the failure to the follow graph.
  @role:e2e-mastodon
  Scenario: my status reaches the local public timeline, which no follow gates
    Given I am signed in as the persona for this scenario
    And my peer and I both hold Mastodon accounts
    When I open the Mastodon timeline
    And I post the Mastodon status "public timeline control" with a unique run marker
    Then my Mastodon timeline shows my status
    And the local public Mastodon timeline carries my latest status

  # The NEGATIVE half of the follow graph. Without it, "my peer sees my post" is
  # satisfiable by an instance that shows every local status to everybody — which
  # is exactly what the light lane's mock-mastodon does, and is how a follow
  # assertion can be green while the follow is a no-op.
  @role:e2e-mastodon
  Scenario: unfollowing removes the edge the timeline depends on
    Given I am signed in as the persona for this scenario
    And my peer and I both hold Mastodon accounts
    And my peer follows me on Mastodon
    When my peer unfollows me on Mastodon
    Then my peer no longer follows me on Mastodon
