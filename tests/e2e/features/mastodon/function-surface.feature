# THE MASTODON FUNCTION SURFACE — every thing a user can DO on akkoma, and who
# the deployed gateway lets do it.
#
# The driven Mastodon coverage in this suite is ONE journey (two-party-timeline:
# follow, post, read) plus the access wall. That leaves boosting, favouriting,
# replying, notifications, unfollowing, media, streaming, the OAuth surface, the
# external-client plane and the whole moderation plane described nowhere. This
# feature describes them, offline, for the whole roster; ./interactions.feature
# drives the ones that can be driven.
#
# SAME TWO SOURCES as the Matrix sibling: the hand-declared gate in
# steps/social-functions.ts versus the deployed route-access seed. Three rows
# here are worth reading twice because they are NOT the obvious answer:
#
#   external-client-apps  /api/v1/apps is an EXACT-PATH row granted only to
#                         ROLE_MASTODON_EXTERNAL_CLIENT — a plain ROLE_MASTODON
#                         holder is DENIED it. That asymmetry is the entire
#                         reason the external-client role exists.
#   streaming             /api/v1/streaming/** is MORE SPECIFIC than /api/v1/**
#                         and therefore its own winning pattern. Delete the row
#                         and the surface silently falls through to the broader
#                         one instead of closing.
#   mod-*                 the moderation plane is a DIFFERENT gate: ROLE_MASTODON
#                         does not reach it at all, which is what stops a member
#                         moderating.
#
# RUNS WITH THE STACK DOWN.
@service:akkoma @layer:gateway @harness
Feature: Every Mastodon function is gated for every seeded persona as the catalogue declares

  Scenario Outline: <function> is gated for the whole roster exactly as the catalogue declares @service:akkoma @layer:gateway
    Then the route-access seed gates the "<function>" function of the service dimension for every seeded persona
    And the "<function>" function of the service dimension is a "<arity>" interaction

    Examples:
      | function             | arity |
      | verify-credentials   | solo  |
      | home-timeline        | pair  |
      | public-timeline      | pair  |
      | post-status          | solo  |
      | reply-status         | pair  |
      | boost-status         | pair  |
      | favourite-status     | pair  |
      | follow-account       | pair  |
      | unfollow-account     | pair  |
      | notifications        | pair  |
      | account-statuses     | pair  |
      | upload-media         | solo  |
      | media-proxy          | solo  |
      | streaming            | pair  |
      | oauth-authorize      | solo  |
      | external-client-apps | solo  |
      | mod-list-statuses    | pair  |
      | mod-delete-status    | pair  |
      | mod-ban-account      | pair  |
      | shell-route          | solo  |
      | provision-account    | solo  |
      | federate-outbound    | pair  |

  # The same sweep in ONE scenario, so a run that lost the rows above still
  # cannot report green with a broken matrix. The rows exist for the REPORT
  # (the reporter pivots perService off the title); this exists for the PROOF.
  Scenario: every akkoma function agrees with the deployed route-access seed for every persona @service:akkoma @layer:gateway
    Then every function of the service dimension agrees with the route-access seed for every seeded persona
    And every catalogued probe path resolves to a real route-access pattern
