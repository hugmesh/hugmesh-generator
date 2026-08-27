# Executable form of tests/e2e/specs/11-matrix-chat-and-call.spec.ts — the single
# journey a real user takes: chat first, then escalate to voice IN THE SAME ROOM.
#
# It is not a copy of 05 plus 10. The claim is that the escalation works over the
# room the two of them were already talking in, and the final assertion is about
# VOICE specifically — a LIVE remote AUDIO track on both peers, not merely a
# 'connected' label. The call module also carries video; this scenario pins the
# audio path.
#
# Same known hsproxy encoding blocker as the two features above; the assertions are
# left intact.
@service:tuwunel @layer:ui
Feature: Two users chat and then escalate to a voice call in the same room

  @role:e2e-matrix
  Scenario: a text conversation escalates to a connected voice call
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "chat-then-call"
    When I open the Matrix chat view for our room
    And my peer opens the Matrix chat view for our room
    Then the Matrix chat view is rendered for both of us
    When I send the Matrix chat message "voice call in a sec?"
    Then my peer's Matrix log contains "voice call in a sec?"
    When my peer sends the Matrix chat message "sure — ring me"
    Then my Matrix log contains "sure — ring me"
    When I open the Matrix call view for our room
    And my peer opens the Matrix call view for our room
    Then the Matrix call view is rendered for both of us
    When I start the Matrix call
    Then my peer's call state becomes "ringing"
    When my peer answers the Matrix call
    Then both call states become "connected"
    And both of us receive a live remote audio track
