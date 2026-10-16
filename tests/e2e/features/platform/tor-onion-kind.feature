# The kind lane's .onion front door (hugmesh-generator#577, operator decision 67 = B).
#
# `make kind-tor` runs a HOST tor as the operator (no sudo) that publishes the kind
# node's host ports as a v3 onion — HiddenServicePort 443 -> 127.0.0.1:8443 (TLS)
# and 80 -> 127.0.0.1:8080 — and admits the onion on the fe-gateway Ingress
# (scripts/kind-tor.sh). This feature proves a persona can use the mesh THROUGH
# that onion and never leaves it.
#
# RUN IT WITH:  make kind-up && make kind-images && make kind-tor && make kind-e2e-tor
#
# `make kind-e2e-tor` is `tests/e2e/run.sh --bdd --env kind --via onion`: it takes
# the onion and the SOCKS port from the LIVE kind tor (kind-tor.sh onion / socks),
# exports them as SNAP_ONION_BASE_URL / SNAP_PROXY, runs ONLY @via:onion @env:kind
# scenarios, and FAILS unless at least one passed and none skipped.
#
# @env:kind is the availability gate and it probes the kind lane's LOCAL door
# (https://hugmesh.net:8443) on purpose: that probe is a plain Node request with
# no proxy and could never reach an onion. The onion itself is reached only by the
# steps' own proxied browser context (specs/helpers.ts onionContext — the same
# seam the compose lane's tor-onion-front-door.feature uses), never the `page`
# fixture (steps/kind-onion.steps.ts; pinned by tests/scripts/test-kind-tor.sh).
#
# `@via:onion` is not a dimension axis (steps/dimensions.ts AXES) and not an @issue:
# tag, so the dimension parser and gherkin-harness check 5 ignore it; run.sh
# selects on it with bddgen --tags.
@layer:gateway @env:kind @via:onion @issue:generator-577
Feature: The kind lane's front door answers as a Tor onion service

  @role:e2e-user
  Scenario: a persona signs in through the kind .onion front door @role:e2e-user @env:kind @via:onion
    Given the kind lane publishes its Tor onion front door
    When I open the kind onion's plain http door through Tor
    Then the kind onion redirects me to its https door
    When I open the kind onion login page through Tor
    Then the kind onion login page renders
    When the persona for this scenario signs in through the kind onion
    Then the kind onion session belongs to that persona
    And every request the kind onion browser made stayed on the onion
