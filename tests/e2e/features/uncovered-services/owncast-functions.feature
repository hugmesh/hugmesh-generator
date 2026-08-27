# The owncast FUNCTION surface — what a person can actually DO with live
# streaming, as opposed to whether the console renders.
#
# owncast-console.feature already pins the shell and the nav. This file drives the
# four consoles behind that nav and states, by name, the three functions nothing
# seeded can drive. Read it next to the derived matrix in
# media-games-function-matrix.feature: this one is the journeys, that one is the
# arithmetic that says whether the journeys still cover the roster.
#
# THE ROLE MODEL, WHICH IS SHARPER THAN "ADMIN CAN DO ADMIN THINGS":
#   STREAM     = ROLE_OWNCAST alone   -> "My Stream". An admin is NOT a streamer.
#   MANAGE     = admin | superadmin   -> the Broadcast grants ACTION form.
#   MANAGE_ALL = superadmin ALONE     -> the active-grants list + the per-principal
#                                        history, which are SEPARATE PANELS INSIDE
#                                        the same grants page an admin can open.
#   MODERATE   = mod | admin | superadmin (in-remote) — but the HOST mount guard
#                is admin | superadmin | ROLE_OWNCAST, so a BARE MOD, the persona
#                the moderation view was built for, never reaches /owncast at all.
#
# That MANAGE vs MANAGE_ALL split is the whole reason this file exists. An
# assertion that the grants page opens is green for an admin and a superadmin
# alike; only asking which PANELS rendered can tell them apart, and a regression
# that leaked the superadmin read surface to every admin would pass every
# "is the console there" test in the suite.
#
# Every driven scenario is tagged @env:docker, so with no stack running it SKIPS
# naming the exact command to start one instead of failing on a socket error.
@service:owncast @layer:ui
Feature: What each role can actually do inside the Owncast console

  # ── console: the CLI half of the same question ────────────────────────────
  #
  # Tagged @interface:cli deliberately: the console's browser coverage already
  # exists in owncast-console.feature, and re-driving it here would fragment the
  # journey across two files. What was NOT covered anywhere is the claim
  # underneath it — that the mesh the operator brings up actually contains an
  # owncast UI to mount. That is a shell question with a transcript answer, and it
  # runs with nothing started.
  @function:console @interface:cli @layer:ui
  Scenario: the committed compose stack really defines an owncast UI to mount @function:console @interface:cli @layer:ui @service:owncast
    When I run the shell command "grep -n hugmesh-owncast-ui tests/stack/compose.local.yaml"
    Then the command succeeded
    And the command output contains "hugmesh-owncast-ui"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # ── grant: MANAGE = admin | superadmin ────────────────────────────────────
  @function:grant @env:docker
  Scenario Outline: <role> is offered the broadcast grant controls @role:<role> @function:grant @service:owncast @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast/grants"
    Then the element with test id "owncast-grants-title" is visible
    And the element with test id "owncast-grants-user" is visible
    And the element with test id "owncast-grants-ttl" is visible
    And the element with test id "owncast-grants-reason" is visible
    And the element with test id "owncast-grants-submit" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # ── grant-audit: MANAGE_ALL = superadmin ALONE ────────────────────────────
  #
  # The two halves of this boundary are asserted as a matched pair on purpose. A
  # one-sided assertion ("the superadmin sees the history panel") stays green
  # after a regression that shows it to everybody; the admin's NEGATIVE is the
  # half that actually pins the privilege.
  @function:grant-audit @role:e2e-superadmin @env:docker
  Scenario: a superadmin reads the active grants and the per-principal history @role:e2e-superadmin @function:grant-audit @service:owncast @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast/grants"
    Then the element with test id "owncast-grants-active-panel" is visible
    And the element with test id "owncast-grants-active-reload" is visible
    And the element with test id "owncast-grants-history-panel" is visible
    And the element with test id "owncast-grants-history-user" is visible

  @function:grant-audit @role:e2e-admin @env:docker
  Scenario: an admin may grant but may NOT read the grant audit surfaces @role:e2e-admin @function:grant-audit @service:owncast @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast/grants"
    Then the element with test id "owncast-grants-submit" is visible
    And the element with test id "owncast-grants-active-panel" is not visible
    And the element with test id "owncast-grants-history-panel" is not visible

  # ── moderate: MODERATE, minus the audience it was built for ───────────────
  @function:moderate @env:docker
  Scenario Outline: <role> reaches the stream moderation feed @role:<role> @function:moderate @service:owncast @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast/moderation"
    Then the element with test id "owncast-moderation-title" is visible
    And the element with test id "owncast-moderation-feed" is visible
    And the element with test id "owncast-moderation-reload" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # The cascade the in-remote guard alone would not predict. owncastModGuard
  # admits MOD, so a bare moderator SHOULD see this view — and cannot, because the
  # host shell refuses the whole /owncast mount to anyone who is not admin,
  # superadmin or a ROLE_OWNCAST holder. Asserted at the FUNCTION level rather
  # than only as "e2e-mod is refused /owncast", because the interesting fact is
  # not the redirect: it is that owncast moderation has no moderator.
  @function:moderate @role:e2e-mod @env:docker
  Scenario: a bare moderator cannot reach the moderation feed the mod guard admits @role:e2e-mod @function:moderate @service:owncast @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/owncast/moderation"
    Then the element with test id "owncast-moderation-feed" is not visible
    And the URL matches "/home[?]denied="

  # ── publish / visibility / watch: written, and honestly pending ───────────
  #
  # These are not omitted and they are not faked. Each states the journey it will
  # drive and the exact seeder line that would unblock it, and each SKIPS with
  # that reason printed in the report. When a ROLE_OWNCAST persona is seeded, the
  # matching tripwire in media-games-function-matrix.feature goes red first, which
  # is the prompt to come back here and delete the PENDING line.
  @function:publish
  Scenario: a streamer creates a stream and saves its title and description @function:publish @service:owncast @layer:ui
    Given this scenario is PENDING because "no persona in either e2e roster holds ROLE_OWNCAST, so nothing can open /owncast/stream — the in-remote owncastStreamGuard is canStream() = ROLE_OWNCAST ALONE and an admin is not a streamer. Seed e2e-owncast:ROLE_OWNCAST,ROLE_USER:E2E_OWNCAST_PASSWORD in tests/e2e-extra-personas.sh, then delete this line"
    And I am signed in as the persona for this scenario
    When I open the path "/owncast/stream"
    Then the element with test id "owncast-stream-empty" is visible
    And the element with test id "owncast-stream-title-input" is visible
    And the element with test id "owncast-stream-save" is visible

  @function:visibility
  Scenario: a streamer without a broadcast grant is refused the public radio, with the reason shown @function:visibility @service:owncast @layer:ui
    Given this scenario is PENDING because "same missing ROLE_OWNCAST persona as owncast/publish — the visibility fieldset lives INSIDE /owncast/stream, which nothing seeded can open. This is the canonical disabled+helptext gate: the public radio disables only alongside a VISIBLE explanation of why, and that pairing is what this scenario exists to pin"
    And I am signed in as the persona for this scenario
    When I open the path "/owncast/stream"
    Then the element with test id "owncast-stream-vis-internal" is visible
    And the element with test id "owncast-stream-vis-public" is disabled
    And the element with test id "owncast-stream-public-disabled-help" is visible
    And the element with test id "owncast-stream-try-public" is visible

  @function:watch
  Scenario: a viewer watches a live stream in-platform @function:watch @service:owncast @layer:ui
    Given this scenario is PENDING because "the only in-platform player in the owncast console is the OWNER preview inside /owncast/stream, so watching needs the same un-seeded ROLE_OWNCAST persona AND a live HLS origin. There is no viewer-facing watch surface in the console at all — this scenario is written so that absence is COUNTED rather than folded into publish"
    And I am signed in as the persona for this scenario
    When I open the path "/owncast/stream"
    Then the element with test id "owncast-stream-video" is visible
    And the element with test id "owncast-stream-player" is visible
