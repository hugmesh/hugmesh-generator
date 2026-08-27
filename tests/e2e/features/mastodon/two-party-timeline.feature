# Executable form of tests/e2e/specs/06-mastodon-post.spec.ts.
#
# TWO DISTINCT USERS ON A SHARED TIMELINE. The UI's "Home" tab is the real
# /api/v1/timelines/home, whose contents are decided by the FOLLOW GRAPH — so
# "my peer sees my post" is a claim about a FOLLOWER seeing it, and the follow has
# to exist first. ORDERING IS LOAD-BEARING: a status fans out to its followers'
# home feeds at post time, so following before the post is what makes the
# assertion need no backfill and no polling.
#
# UNIQUE BODIES PER RUN. The timeline is shared and append-only across the whole
# suite, so a fixed string could be satisfied by a PREVIOUS run's post and the
# assertion would stop proving that THIS post landed. The step appends a run
# marker; the Gherkin keeps the readable half.
#
# WHO DRIVES IT. Mastodon is gated on the per-platform ROLE_MASTODON access role
# since the broad ROLE_USER homeserver floor was removed, so alice@/bob@gmail.com
# cannot post here by design (see ../matrix/platform-access-wall.feature). The peer
# is resolved from the seed catalogue's non-domain-locked ROLE_MASTODON holders at
# run time.
@service:akkoma @layer:ui
Feature: Two signed-in users post to Mastodon and see each other on the timeline

  @role:e2e-mastodon
  Scenario: a follower sees the post of the account they follow, and their own
    Given I am signed in as the persona for this scenario
    And one more seeded Mastodon persona signs in as my peer
    And my peer follows me on Mastodon
    When I open the Mastodon timeline
    And I post the Mastodon status "hello fediverse from the author" with a unique run marker
    Then my Mastodon timeline shows my status
    When my peer opens the Mastodon timeline
    And my peer posts the Mastodon status "the follower says hi to the timeline" with a unique run marker
    Then my peer's Mastodon timeline shows both statuses
