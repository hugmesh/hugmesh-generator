# WHAT THE DEPLOYED TUBE MEDIA GATE ACTUALLY ENFORCES.
#
# hugmesh-tube-bff-api's TubeMediaController.verify documents itself as "the
# auth_request target for the tube-media nginx serving sidecar": it is PUBLIC
# (SecurityConfig marks /bff/tube/media/verify permitAll — the sidecar's internal
# subrequest carries no bearer, so the short-TTL HMAC IS the credential), it is
# constant-time, and it is fail-closed on every malformed input.
#
# WHEN THIS LANE WAS WRITTEN IT WAS A TARGET NOTHING POINTED AT. The whole gate
# the generator deployed was, verbatim:
#
#     if ($arg_sig = "") { return 403 "missing sig"; }
#     alias /var/tube-content/;
#
# `grep -rn auth_request specs/ tests/` returned ZERO hits, so any non-empty sig
# served the bytes: `?sig=x` was a valid credential for anyone's content. The
# scenarios below stated that posture as a TRIPWIRE — "the day someone wires
# auth_request the second scenario FAILS and tells them to promote the verify rows
# in tube-signed-media.feature into the live lane" — and left the desired wiring
# PENDING, spelled out directive by directive.
#
# THE TRIPWIRE FIRED. specs/cluster/manifests/tube/deployment.yaml now declares an
# `upstream tube_bff_verify`, matches the content tree with a regex location
# capturing the media path, runs `auth_request /__tube_media_verify;` BEFORE the
# alias, and proxies that internal target at /bff/tube/media/verify. So the
# scenarios below assert the ENFORCED gate, and the PENDING one is closed. What
# they cannot assert offline is unchanged: nothing here contacts a mesh, so this
# is the wiring, not the verdict — the behaviour is tube-signed-media.feature's.
#
# RUNS WITH EVERYTHING DOWN. Two committed YAML files in THIS repo, no mesh.
@harness @service:tube @layer:gateway
Feature: What the deployed tube media gate actually enforces

  Scenario: the media sidecar is routed and the content prefix is a reserved route @harness @service:tube @layer:gateway
    Then the optional-service catalogue routes "/tube/content/**" on the "hugmesh-be-gateway" gateway for the "tube" service
    And the tube deployment declares a "tube-media" sidecar serving "/tube/content/"

  Scenario: the shipped sidecar gate delegates every content request to the BFF verifier @harness @service:tube @layer:gateway
    Then the tube-media nginx config issues an auth_request subrequest to the tube bff verify route

  # WAS PENDING, NOW CLOSED. It shipped as the desired end state, stated
  # executably so it would cost nothing to land: "a location ... { internal;
  # proxy_pass .../bff/tube/media/verify } plus auth_request ... inside the
  # /tube/content/ location". That landed. What remains worth asserting is the
  # SHAPE that makes it a gate rather than a decoration: the verifier target must
  # be `internal` (unreachable from outside nginx, so nobody can call the
  # authoriser directly) and the auth_request must come BEFORE the alias that
  # serves the bytes — an alias reachable without passing the subrequest is a
  # second, weaker path to the same content.
  @service:tube @layer:gateway
  Scenario: the verifier target is internal and the bytes are only served after it @harness @service:tube @layer:gateway
    Then the tube-media nginx config keeps its auth_request target internal and ahead of the alias
