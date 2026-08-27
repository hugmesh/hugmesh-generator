# THE TUBE MEDIA SIGNED-URL GATE IS A WALL, NOT AN ORACLE.
#
# /bff/tube/media/verify is the ONE route under /bff/tube/media/** that
# SecurityConfig marks permitAll: the nginx sidecar's auth_request subrequest
# carries no bearer, so the short-TTL HMAC minted by /sign IS the credential.
# Because it is public and because nginx auth_request only separates 2xx from
# everything else, EVERY failure mode must be the same empty 403 — a 400 for a
# malformed parameter and a 403 for a forged signature would tell a prober which
# of the two they got wrong, for no benefit at all.
#
# grep 'media/verify' and 'media/sign' across this suite returns zero, and
# tube-ui's own isolation.feature covers exactly ONE of the seven branches (a user
# signing another user's path -> 403).
#
# Eight cases, eight distinct early returns in TubeMediaController.verify:
# missing parameters, three blank-field guards, an unparseable exp, an expired
# exp, and a forged signature. The anonymous client is deliberate — this route
# takes no session, and driving it with one would test a path the sidecar never
# takes.
#
# WHAT THIS FEATURE DOES **NOT** PROVE, said plainly:
#
#   * It does not prove the DEPLOYED gate calls verify at all. It does not:
#     see tube-media-gate.feature, which pins that the shipped nginx ConfigMap
#     checks only that `sig` is non-empty and issues no auth_request. So a green
#     run here is a statement about the BFF, not about the mesh.
#
#   * It does not cover the /sign side at all. Signing is gated on
#     TubeAccessGuard.assertCanUse, which needs ROLE_TUBE — and
#     features/uncovered-services/access-role-roster.feature pins that NO persona
#     in either e2e roster holds ROLE_TUBE. The sign rows would 403 at setup for
#     an identity reason and read like a broken gate. They are PENDING below
#     rather than written against an admin, because an admin is not the audience
#     and driving one would assert a different code path while looking like
#     coverage of this one.
#
#   * It does not cover TTL EXPIRY by waiting. TTL_MILLIS is 300_000 — five
#     minutes. A test that sleeps five minutes is not a test worth having, and
#     rewriting `exp` to the past does not test expiry: exp is inside the signed
#     (sub, domain, path, exp) tuple, so a rewritten exp fails the HMAC first and
#     is already the forged-sig row. Named here rather than faked.
#
# NEEDS A MESH. @env:docker — skips with the start command named when the door
# does not answer.
@service:tube @layer:bff @env:docker @interface:browser
Feature: The tube media signed-URL verify gate is a wall, not an oracle

  Scenario Outline: verify answers a uniform empty 403 for the <case> case @service:tube @layer:bff
    Given I hold an anonymous API client
    When I call the tube media verify route with the "<case>" parameters
    Then the tube media verify verdict is 403
    And the tube media verify response body is empty

    Examples:
      | case            |
      | no-parameters   |
      | missing-path    |
      | blank-sig       |
      | blank-sub       |
      | blank-domain    |
      | non-numeric-exp |
      | expired-exp     |
      | forged-sig      |

  @service:tube @layer:bff
  # NO @fixme TAG, deliberately — MEASURED, not stylistic. Playwright skips a
  # @fixme test BEFORE its first step runs, so the PENDING step never executes and
  # the skip lands in report.json with an EMPTY reason: a silent skip wearing a
  # tag. The step alone skips with the whole paragraph below printed. (@fixme has
  # a second trap too: a .feature in which EVERY scenario carries it generates
  # nothing at all — bddgen still exits 0 and the file simply never appears.)
  Scenario: PENDING (nothing seeds ROLE_TUBE) — signing a path that is not mine is refused before any URL is minted @service:tube @layer:bff
    Given this scenario is PENDING because "GET /bff/tube/media/sign is gated on TubeAccessGuard.assertCanUse, which requires ROLE_TUBE, and features/uncovered-services/access-role-roster.feature pins that NO persona in specs/rbac-roles.ts SYSTEMS_SEED_USERS or tests/e2e-extra-personas.sh holds ROLE_TUBE. Every sign row would 403 at the use gate for an IDENTITY reason, never reaching the path allowlist or the owner two-wall this scenario is about — the right status from the wrong wall, which is worse than no coverage. DESIRED: seed e2e-tube:ROLE_TUBE,ROLE_USER:E2E_TUBE_PASSWORD, after which this drives the five rows the source distinguishes — '/acme/../etc/passwd/videos/x.mp4', 'acme/alice/videos/x.mp4' and '/acme/alice//videos/x.mp4' are 400 at PATH_PATTERN; a foreign brand and a foreign subject are 403 at the owner two-wall; and the roster scenario in access-role-roster.feature fails on the same day, which is the prompt to come back here."
    Then the tube media verify verdict is 403
