# Executable form of tests/e2e/specs/05-matrix-chat.spec.ts.
#
# TWO DISTINCT USERS, TWO COOKIE-SEPARATED CONTEXTS, ONE SHARED ROOM. That is the
# whole claim: not "the chat view renders", but "the message one signed-in identity
# composes arrives in another signed-in identity's log". A single-page version of
# this scenario would look identical in the report and prove nothing.
#
# WHO DRIVES IT. Not alice@/bob@gmail.com: those hold ROLE_USER and nothing else,
# and the broad ROLE_USER homeserver floor was removed in favour of the
# per-platform ROLE_MATRIX access role — so they are DENIED the Matrix backend BY
# DESIGN (features/matrix/platform-access-wall.feature asserts that deny, and
# granting them ROLE_MATRIX to "revive" this scenario would contradict it). The
# peer is resolved from the seed catalogue's NON-domain-locked ROLE_MATRIX holders
# at run time, so a roster change re-arms this with no edit here.
#
# KNOWN PRODUCT BLOCKER, deliberately left RED rather than deleted: the shipped
# hugmesh-matrix-ui percent-encodes the room id in the room-scoped CS-API path and
# the user-bff hsproxy mangles that spelling (HsReverseProxy hands an already-
# encoded path to WebClient.uri(String), which re-escapes the '%'). The composer
# send therefore fails today with a status this scenario reports by name. Fixing it
# needs a rebuilt hugmesh-user-bff-api image; the assertion stays, because deleting
# it would turn a reported product defect into invisible green.
@service:tuwunel @layer:ui
Feature: Two signed-in users chat with each other through the Matrix UI

  @role:e2e-matrix
  Scenario: two platform-access personas exchange messages in a shared room
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "general"
    When I open the Matrix chat view for our room
    And my peer opens the Matrix chat view for our room
    Then the Matrix chat view is rendered for both of us
    When I send the Matrix chat message "hi peer — the room creator here"
    Then my peer's Matrix log contains "hi peer — the room creator here"
    When my peer sends the Matrix chat message "hey creator — the invitee here"
    Then my Matrix log contains "hey creator — the invitee here"
