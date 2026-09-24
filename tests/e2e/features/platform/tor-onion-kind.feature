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
# With nothing up it SKIPS twice over, each time naming what to start: the @env:kind
# gate (world.ts Before) when the kind door does not answer, and the first step when
# SNAP_KIND_ONION is unset. It FAILS — never skips — when the onion is set but the
# browser is not routed through SNAP_PROXY (the playwright.config.ts plumbing is the
# compose-lane work, #576), because then it cannot be testing Tor at all.
#
# `@via:onion` is not a dimension axis (steps/dimensions.ts AXES) and not an @issue:
# tag, so the dimension parser and gherkin-harness check 5 ignore it; it is the
# selector `--tags '@env:kind and @via:onion'` uses.
@layer:gateway @env:kind @via:onion @issue:generator-577
Feature: The kind lane's front door answers as a Tor onion service

  @role:e2e-user
  Scenario: a persona signs in through the kind .onion front door @role:e2e-user @env:kind @via:onion
    Given the front door under test is the kind lane's live onion
    When I open the onion's plain http door
    Then I am redirected to the onion's https door
    When I open the path "/login"
    Then the element with test id "login-username" is visible
    Given I am signed in as the persona for this scenario
    Then my session registration is complete
    And the session endpoint answers for the signed-in persona through the onion
    And every request this scenario made went to the onion host
