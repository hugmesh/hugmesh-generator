# THE LOCAL MESH OVER TOR — the compose stack's .onion front door, driven THROUGH
# the real Tor network the way a Tor Browser user reaches it (hugmesh-generator#576).
#
# Run it:   make stack-up TOR=1 && make stack-seed && make stack-e2e-tor
#
# `make stack-e2e-tor` is `tests/e2e/run.sh --bdd --env docker --via onion`: it
# resolves https://<onion> from tests/stack/tor-onion/hostname, points the browser
# at hugmesh-tor-client's SOCKS5 port, and runs ONLY @via:onion scenarios. In any
# other lane this scenario SKIPS with that command as its reason.
#
# @env:docker is the availability gate and it probes the stack's LOCAL https door
# on purpose: the probe is a plain Node request with no proxy, and the onion is
# only ever served by a running stack. The onion itself is reached by the steps'
# own proxied browser context, never the `page` fixture (steps/tor-onion.steps.ts).
#
# https://<onion>/, not http: the onion's :443 (the TLS front) is the door a person
# is told to use, a secure context and the node's :443, so this scenario enters
# there (docs/TOR-HIDDEN-SERVICE.md "Why :443"; not CSP upgrade-insecure-requests,
# which the SPA document never carries, #628).
#
# @via: is not a dimension axis — like @issue: it passes through the Before hook
# untouched; run.sh selects on it with bddgen --tags.
@env:docker @via:onion @service:login @layer:ui
Feature: The local mesh is usable over its Tor onion front door

  @role:e2e-user @issue:generator-576
  Scenario: a persona signs in through the .onion front door @role:e2e-user
    Given the stack publishes its Tor onion front door
    When I open the onion login page through Tor
    Then the onion login page renders
    When the persona for this scenario signs in through the onion
    Then the onion session belongs to that persona
    And every request the browser made went to the onion
