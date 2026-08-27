# THE MATRIX INTERACTIONS the five existing journey features do not reach.
#
# two-party-chat, matrix-call, chat-then-call, group-chat and chat3d drive
# sending, calling, inviting, accepting and unread badges. What none of them
# touches is what happens AFTER: a message the author deletes, a display name the
# other member has to see, a member who leaves. Each of those is a two-party
# claim whose whole meaning lives on the OTHER side — the author's own 200 says
# nothing about the room.
#
# ── DRIVEN THROUGH THE CLIENT API, ON PURPOSE ───────────────────────────────
# These three functions have NO pinned UI test id anywhere in this repo (there is
# no redact control, no profile editor and no leave button in any spec), so a
# UI-driven version would need invented selectors — a scenario that can never
# pass. They are driven instead through the SAME user-bff hsproxy the UI uses:
# the browser holds no homeserver token, auth is the httpOnly bff_session cookie,
# and the server injects the credential. specs/helpers.ts createRoom /
# inviteToRoom / joinRoom already work exactly this way.
#
# ── KNOWN PRODUCT BLOCKER, NAMED RATHER THAN DESIGNED AROUND ────────────────
# Every step below touches a ROOM-SCOPED CS-API path (/rooms/<id>/send,
# /rooms/<id>/redact, /rooms/<id>/state, /rooms/<id>/leave). The shipped
# hugmesh-matrix-ui percent-encodes the room id and the user-bff HsReverseProxy
# re-escapes the '%' (it hands an already-encoded path to WebClient.uri(String)),
# which is why ../matrix/two-party-chat.feature is deliberately RED today. These
# scenarios will fail for that SAME single cause once a stack is up — not for
# three new ones. The assertions describe the contract they exist to prove and
# stay as they are; deleting them would turn a reported product defect into
# invisible green. Fixing it needs a rebuilt hugmesh-user-bff-api image.
#
# ── HONEST GATING ───────────────────────────────────────────────────────────
# @env:docker: with nothing running these SKIP with the reason and the start
# command, never a silent pending. The offline half of this service's coverage is
# ./function-surface.feature.
@service:tuwunel @layer:ui @env:docker
Feature: Matrix interactions — redaction, profile identity and leaving a room

  # A redaction only matters if the OTHER member's copy loses the message. A
  # scenario that checked the author's own timeline would pass against a purely
  # local hide.
  @role:e2e-matrix
  Scenario: a message I redact disappears from my peer's copy of the room
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "e2e redaction"
    When I send the Matrix message "this one gets taken back" through the client API
    Then my peer sees that Matrix message in the room timeline
    When I redact that Matrix message
    Then my peer no longer sees that Matrix message in the room timeline

  # A display name only I can read is a local cache, not a profile. The claim is
  # about what the peer resolves for MY user id.
  @role:e2e-matrix
  Scenario: the display name I set is the one my peer resolves for me
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "e2e displayname"
    When I set my Matrix display name to "the room creator"
    Then my peer sees my new Matrix display name

  # Leaving is observable only as membership state in the room the OTHER member
  # still holds. Asserting 'join' first is what makes the 'leave' a transition
  # rather than a state that was already true.
  @role:e2e-matrix
  Scenario: a peer who leaves is recorded as having left, in my copy of the room
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "e2e departure"
    Then the room shows my peer as "join"
    When my peer leaves our Matrix room
    Then the room shows my peer as "leave"
