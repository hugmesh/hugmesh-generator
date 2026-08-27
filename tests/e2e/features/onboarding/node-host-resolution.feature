# Executable Gherkin for tests/e2e/specs/30-node-host-resolution.spec.ts.
#
# STACK-FREE BY CONSTRUCTION — no cluster, no compose, no network. Tagged
# @harness, so it runs in the offline lane alongside the persona-roster contract.
#
# WHY THE HELPER EXISTS. `--host-resolver-rules` is BROWSER-ONLY. Kind runs
# address the cluster by its real hostname (the fe-gateway Ingress matches on
# Host) and hand Chromium SNAP_HOST_RESOLVER so no /etc/hosts edit or sudo is
# needed. Node never sees that flag, so request.newContext() — and page.request,
# which is easy to mistake for browser-side because it shares the cookie jar —
# die on `getaddrinfo ENOTFOUND hugmesh.net`. resolveForNode() dials the mapped IP
# and carries the hostname in the Host header, which is what ingress-nginx routes
# on. Proven live on kind with its own control: WITH the Host header the BFF
# answered 401 (routed); WITHOUT it nginx answered 404 (default backend, did not
# route).
#
# THE PROPERTY THE FIRST SCENARIO DEFENDS is what makes the helper safe to adopt
# in specs that only ever run against compose: with SNAP_HOST_RESOLVER unset it
# is a NO-OP. If that stops being true, every compose run silently starts
# rewriting URLs it must not touch and nothing else in the suite would notice.
@harness @service:gateway @layer:gateway
Feature: Node-side host resolution for kind

  Scenario: with the resolver rules unset the compose lane is untouched @service:gateway @layer:gateway
    Given the Node host resolver rules are unset
    When I resolve "https://hugmesh.net:8443/bff/session" for a Node-side API request
    Then the resolved URL is unchanged as "https://hugmesh.net:8443/bff/session"
    And the resolved request adds no extra headers

  Scenario: a mapped host is dialled by IP with the hostname in Host @service:gateway @layer:gateway
    Given the Node host resolver rules are "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    When I resolve "https://hugmesh.net:8443/bff/session" for a Node-side API request
    Then the resolved hostname is "127.0.0.1" and the port is "8443"
    And the resolved request carries the Host header "hugmesh.net"

  Scenario: a wildcard rule covers subdomains @service:gateway @layer:gateway
    Given the Node host resolver rules are "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    When I resolve "https://registry.hugmesh.net/v2/" for a Node-side API request
    Then the resolved hostname is "127.0.0.1" and the port is ""
    And the resolved request carries the Host header "registry.hugmesh.net"

  Scenario: an UNMAPPED host is left alone even when rules are present @service:gateway @layer:gateway
    Given the Node host resolver rules are "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    When I resolve "https://example.invalid/whatever" for a Node-side API request
    Then the resolved URL is unchanged as "https://example.invalid/whatever"
    And the resolved request adds no extra headers

  Scenario: a relative path is left alone rather than throwing on URL parsing @service:gateway @layer:gateway
    Given the Node host resolver rules are "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    When I resolve "/bff/session" for a Node-side API request
    Then the resolved URL is unchanged as "/bff/session"
    And the resolved request adds no extra headers

  # Malformed entries are IGNORED, never half-applied: a typo in SNAP_HOST_RESOLVER
  # must not silently disable the good rules beside it, nor invent a mapping.
  Scenario: malformed resolver entries are ignored instead of half-applied @service:gateway @layer:gateway
    Given the Node host resolver rules are "MAP, NOTARULE, MAP hugmesh.net 127.0.0.1"
    When I resolve "https://hugmesh.net:8443/x" for a Node-side API request
    Then the resolved hostname is "127.0.0.1" and the port is "8443"
    When I resolve "https://elsewhere.test/x" for a Node-side API request
    Then the resolved request adds no extra headers
