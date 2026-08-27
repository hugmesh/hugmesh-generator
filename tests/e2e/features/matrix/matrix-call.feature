# Executable form of tests/e2e/specs/10-matrix-call.spec.ts.
#
# A REAL WebRTC call, not a mocked one: two browser contexts with fake media
# devices establish a peer connection, signalled over a shared Matrix room by the
# hugmesh-matrix-ui call module. "Connected" is asserted on BOTH sides, and then
# the remote <video> is inspected for an actual MediaStream track — because a call
# UI can reach 'connected' with nothing flowing.
#
# KNOWN PRODUCT BLOCKER: the call is signalled by m.call.* events on the SAME
# room-scoped /rooms/<id>/send/... path the chat composer uses, so it fails today
# for the identical hsproxy encoding reason (see two-party-chat.feature). The
# assertions describe the contract this scenario exists to prove and will pass once
# the proxy is fixed.
@service:tuwunel @layer:ui
Feature: Two signed-in users hold a room-signalled Matrix video call

  @role:e2e-matrix
  Scenario: two platform-access personas reach a connected WebRTC video call
    Given I am signed in as the persona for this scenario
    And one more seeded Matrix persona signs in as my peer
    And my peer and I share a Matrix room named "callroom"
    When I open the Matrix call view for our room
    And my peer opens the Matrix call view for our room
    Then the Matrix call view is rendered for both of us
    When I start the Matrix call
    Then my peer's call state becomes "ringing"
    When my peer answers the Matrix call
    Then both call states become "connected"
    And both of us receive a live remote video track
