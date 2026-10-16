# A TOR DOMAIN'S OWN ONION — the compose stack's PER-DOMAIN .onion front doors, driven
# THROUGH the real Tor network (hugmesh-generator#582, operator decision 68 = A on #347:
# "a Tor domain = its own HiddenService stanza fronting the SAME gateway, distinguished
# by the onion Host").
#
# Run it:   make stack-up TOR=1 BRAND_B=1 && make stack-seed && make stack-e2e-tor-domains
#
# `make stack-e2e-tor-domains` is `tests/e2e/run.sh --bdd --env docker --via
# onion-domains`: it resolves the mesh's own onion exactly as --via onion does, plus one
# https://<onion> per `<slug>.hostname` readout hugmesh-tor publishes beside the
# primary's (SNAP_ONION_DOMAIN_URLS), points the browser at hugmesh-tor-client's SOCKS5
# port, and runs ONLY @via:onion-domains scenarios. Its own tag, not @via:onion: a skip
# fails an onion lane, so `make stack-e2e-tor` on a stack with no Tor domain must never
# collect this scenario. In any other lane the Given SKIPS with that command as its
# reason.
#
# WHAT IT PROVES — both halves of the ruling. hugmesh-tor writes the gateway's host map
# (hugmesh-gateway#38/#39): the mesh's onion as `default`, brand B's onion as `brandb`.
#   * The brand wall holds over Tor: a session signed in on the MESH'S onion (the default
#     brand) is refused on brand B's onion — 403 with X-Route-Denied, exactly what brand
#     B's HTTPS door answers that session (the live baseline on hugmesh-gateway#38).
#   * Brand B's own persona (e2e-tenant2-user, seeded into brand B's Casdoor by `make
#     stack-seed` under BRAND_B=1 — tests/stack/seed-e2e.sh leg 1b) signs in on brand
#     B's onion and holds a session there.
# The same claims tests/stack/tor-domains-live-check.sh grades with curl (rows P and B);
# this is the browser, through Tor, in the Gherkin lane.
#
# @env:docker is the availability gate and probes the stack's LOCAL https door on
# purpose (a plain Node request with no proxy). The onions are reached only by the
# steps' own proxied browser contexts (steps/tor-onion-domains.steps.ts, the
# specs/helpers.ts onionContext seam), never the `page` fixture. @via:onion-domains is
# not a dimension axis: like @via:onion it passes through the Before hook untouched, and
# run.sh selects on it with bddgen --tags.
@env:docker @via:onion-domains @service:login @layer:ui @issue:generator-582
Feature: A Tor domain's own onion opens that domain, and only that domain

  @role:e2e-user
  Scenario: the mesh's onion session is refused on brand B's onion, where brand B's own persona signs in @role:e2e-user
    Given the stack publishes a Tor onion of its own for the brand-B domain
    When I open the brand-B onion login page through Tor
    Then the brand-B onion login page renders
    When the persona for this scenario signs in through the mesh onion
    Then that session is refused on the brand-B onion with X-Route-Denied
    When the brand-B persona signs in through the brand-B onion
    Then the brand-B onion session belongs to the brand-B persona
    And every request the brand-B onion browser made stayed on that onion
