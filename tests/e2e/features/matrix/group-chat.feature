# Executable form of tests/e2e/specs/31-matrix-group-chat.spec.ts — the GROUP
# surfaces beyond a two-party room: pending-invite rows with an explicit Accept,
# per-message sender attribution once three members talk, and the room-list unread
# badge across a room switch.
#
# THREE MEMBERS, NOT TWO WEARING A GROUP'S NAME. The creator plus TWO invitees is
# what makes "all members see all messages" and "each message is attributed to its
# own sender" multi-party claims. The seed catalogue now carries three
# non-domain-locked ROLE_MATRIX holders (e2e-matrix, e2e-matrix-groupchat,
# e2e-matrix-external-client), which is asserted offline by
# social-access-contract.feature — so this scenario does NOT skip on a roster
# shortfall the way the handwritten spec had to when only two existed.
# Domain-locked holders stay excluded: they are the SUBJECT of the non-federation
# proof and borrowing them here would entangle two proofs.
#
# THE UNREAD-BADGE SCENARIO IS KNOWN RED, and left that way on purpose. The
# homeserver and the proxy really do deliver the counts (verified with a long-poll
# through the hsproxy carrying unread_notifications), and the shipped bundle
# contains both the mapping and the badge markup — but the room list is
# simultaneously failing every room-scoped call for the hsproxy encoding reason, so
# room /state is dead and nothing renders correctly. Whether a SECOND independent
# UI defect hides behind that cannot be settled until the proxy is fixed. A red
# scenario reports a real user-visible breakage; a skip would hide it.
@service:tuwunel @layer:ui
Feature: Matrix group rooms — pending invites, multi-party attribution and unread badges

  @role:e2e-matrix
  Scenario: two invitees accept a pending invite in the UI and all three members see every message
    Given I am signed in as the persona for this scenario
    And two more seeded Matrix personas sign in as my peers
    And my peers and I share a private Matrix room named "e2e group" with the invites still pending
    Then each of my peers sees a pending Matrix invite from me and accepts it in the UI
    When every member opens the Matrix chat view for our room
    And I send the Matrix chat message "group message one — from the room creator"
    And my peer sends the Matrix chat message "group message two — from the first invitee"
    And my second peer sends the Matrix chat message "group message three — from the second invitee"
    Then every member's Matrix log shows every message sent in this room
    And on my peer's page every message is attributed to its own sender

  @role:e2e-matrix
  Scenario: a backgrounded room grows an unread badge and opening it clears the badge
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share two private Matrix rooms named "e2e switch room a" and "e2e switch room b"
    When my peer parks in the first room
    Then neither room row carries an unread badge
    When I send "ping into room b while my peer reads room a" into the second room while my peer reads the first
    Then the second room row grows a positive unread badge
    When my peer opens the second room from the room list
    Then my peer sees the backgrounded message and the unread badge is cleared
