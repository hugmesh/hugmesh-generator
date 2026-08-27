# WHAT THE DEPLOYED TUBE MEDIA GATE ACTUALLY ENFORCES.
#
# hugmesh-tube-bff-api's TubeMediaController.verify documents itself as "the
# auth_request target for the tube-media nginx serving sidecar": it is PUBLIC
# (SecurityConfig marks /bff/tube/media/verify permitAll — the sidecar's internal
# subrequest carries no bearer, so the short-TTL HMAC IS the credential), it is
# constant-time, and it is fail-closed on every malformed input.
#
# It is also a target NOTHING POINTS AT. The whole gate the generator actually
# deploys is, verbatim, in specs/cluster/manifests/tube/deployment.yaml:
#
#     if ($arg_sig = "") { return 403 "missing sig"; }
#     alias /var/tube-content/;
#
# `grep -rn auth_request specs/ tests/` over this repo returns ZERO hits. So any
# non-empty sig serves the bytes: `?sig=x` is a valid credential for anyone's
# content. The BFF's real HMAC + expiry + (sub,domain,path) tuple check is
# defence in depth that is never reached.
#
# WHY THIS IS A FEATURE FILE AND NOT A BUG REPORT. steps/dimensions.ts already
# records the lament in prose ("/tube/content/ + /tube/deployment appear in the
# compose stack; nothing drives them"). A comment cannot fail. These three
# scenarios turn it into a tripwire: the first two state the posture that holds
# TODAY, and the third is PENDING and describes the desired end state, so the day
# someone wires auth_request the second scenario FAILS and tells them to promote
# the verify rows in tube-signed-media.feature into the live lane.
#
# RUNS WITH EVERYTHING DOWN. Two committed YAML files in THIS repo, no mesh.
@harness @service:tube @layer:gateway
Feature: What the deployed tube media gate actually enforces

  Scenario: the media sidecar is routed and the content prefix is a reserved route @harness @service:tube @layer:gateway
    Then the optional-service catalogue routes "/tube/content/**" on the "hugmesh-be-gateway" gateway for the "tube" service
    And the tube deployment declares a "tube-media" sidecar serving "/tube/content/"

  Scenario: the shipped sidecar gate checks only that a signature is PRESENT @harness @service:tube @layer:gateway
    Then the tube-media nginx config rejects a request whose "sig" query parameter is empty
    And the tube-media nginx config issues no auth_request subrequest

  # The desired end state, stated executably so it costs nothing to land.
  @service:tube @layer:gateway
  # NO @fixme TAG, deliberately — MEASURED, not stylistic. Playwright skips a
  # @fixme test BEFORE its first step runs, so the PENDING step never executes and
  # the skip lands in report.json with an EMPTY reason: a silent skip wearing a
  # tag. The step alone skips with the whole paragraph below printed. (@fixme has
  # a second trap too: a .feature in which EVERY scenario carries it generates
  # nothing at all — bddgen still exits 0 and the file simply never appears.)
  Scenario: PENDING (the ConfigMap calls itself a "stub signed-URL gate") — the sidecar delegates to the BFF verify route @harness @service:tube @layer:gateway
    Given this scenario is PENDING because "specs/cluster/manifests/tube/deployment.yaml's tube-media ConfigMap checks only $arg_sig != '' and then aliases /var/tube-content/, so ANY non-empty sig value serves ANY user's bytes. TubeMediaController.verify exists, is permitAll, is constant-time and is fail-closed on every malformed input — and is invoked by nothing the generator deploys (grep auth_request over specs/ and tests/ returns zero). DESIRED: a `location = /_tube_auth { internal; proxy_pass http://hugmesh-tube-bff-api:8080/bff/tube/media/verify$is_args$args; }` plus `auth_request /_tube_auth;` inside the /tube/content/ location, after which a request bearing sig=x&exp=1&sub=a&domain=b is served 403 instead of 200."
    Then the tube-media nginx config issues an auth_request subrequest to the tube bff verify route
