# The Tube FUNCTION surface — queue, watch, subscribe, and the two management
# consoles.
#
# tube-console.feature pins the shell and the three nav entries. This file drives
# what is behind them, and it splits cleanly in two, which is the point:
#
#   THE MANAGEMENT HALF IS DRIVABLE. TUBE_MANAGE = admin | superadmin, and both
#   are seeded, so /tube/access and /tube/budgets can be opened and their controls
#   asserted for real.
#
#   THE MEMBER HALF IS NOT. Every member-facing function — enqueue a download,
#   watch a completed one, connect a Google account — is gated on ROLE_TUBE, and
#   NOTHING in either e2e roster holds ROLE_TUBE. An admin renders /tube/my
#   through the gateway admin-bypass, but "the view rendered" is not "the queue
#   worked": tube access is a per-PRINCIPAL grant the admin does not have either.
#   So those three are written as PENDING with the seeder line that unblocks them,
#   not driven as an admin standing in for a member they are not.
#
# tube/subscribe is the one function here that a SEED CANNOT UNBLOCK. It is a real
# Google OAuth consent flow plus a YouTube Data API quota; driving a third-party
# consent screen from Playwright would be asserting Google, not hugmesh. It is
# catalogued 'absent' rather than 'no-audience' precisely so the difference
# between "waiting on a seeder line" and "waiting on something that will never
# arrive" stays visible in the census.
#
# ONE CONTRACT ASYMMETRY WORTH NOTING, pinned in the matrix feature rather than
# here: owncast has a dedicated /bff/owncast/admin/** -> ROLE_ADMIN route-access
# row; tube has NO /bff/tube/admin/** row at all and its management consoles ride
# the gateway admin-bypass instead. Both work. Only one is legible from the seed.
@service:tube @layer:ui
Feature: What each role can actually do inside the Tube console

  @function:console @interface:cli @layer:ui
  Scenario: the committed compose stack really defines a tube UI to mount @function:console @interface:cli @layer:ui @service:tube
    When I run the shell command "grep -n hugmesh-tube-ui tests/stack/compose.local.yaml"
    Then the command succeeded
    And the command output contains "hugmesh-tube-ui"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # ── access: TUBE_MANAGE = admin | superadmin ──────────────────────────────
  @function:access @env:docker
  Scenario Outline: <role> is offered the tube access controls @role:<role> @function:access @service:tube @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/tube/access"
    Then the element with test id "tube-access-user" is visible
    And the element with test id "tube-access-ttl" is visible
    And the element with test id "tube-access-reason" is visible
    And the element with test id "tube-access-submit" is visible
    And the element with test id "tube-access-manage" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # ── budgets: the SAME guard, asserted separately on purpose ───────────────
  #
  # /tube/access and /tube/budgets share tubeManageGuard. Sharing a guard is
  # exactly why a regression drops BOTH, and exactly why one assertion covering
  # "the management consoles" would stay green on whichever of the two it happened
  # to pick.
  @function:budgets @env:docker
  Scenario Outline: <role> is offered the per-user storage budget controls @role:<role> @function:budgets @service:tube @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/tube/budgets"
    Then the element with test id "tube-budget-user" is visible
    And the element with test id "tube-budget-gb" is visible
    And the element with test id "tube-budget-submit" is visible
    And the element with test id "tube-budgets-current" is visible

    Examples:
      | role           |
      | e2e-admin      |
      | e2e-superadmin |

  # A persona with no tube role at all is refused the management console by the
  # HOST mount guard, before the in-remote guard is ever consulted. Asserted at
  # the child route rather than at /tube so the two layers are not conflated: the
  # redirect target here proves it was the mount guard, not tubeManageGuard, which
  # would have sent them to /tube/forbidden instead.
  @function:budgets @env:docker
  Scenario Outline: <role> is refused the tube management consoles at the mount, not in the remote @role:<role> @function:budgets @service:tube @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/tube/budgets"
    Then the element with test id "tube-budget-submit" is not visible
    And the URL matches "/home[?]denied="
    And the URL matches "denied=.*tube"

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |

  # ── the member half: written, pending, and each says what would unblock it ──
  #
  # NOTE none of these carries a @role: tag. It would have to name a persona no
  # seeder creates, and steps/dimensions.ts validates @role: in the Before hook —
  # before the PENDING step could skip — so a fictional handle would turn an
  # honest pending into a hard error. The seeder line each reason quotes is what
  # to add first; the @role: tag comes with it.
  @function:queue
  Scenario: a tube member enqueues a download from a subscribed channel @function:queue @service:tube @layer:ui
    Given this scenario is PENDING because "no persona in either e2e roster holds ROLE_TUBE. An admin renders /tube/my through the gateway admin-bypass, but the queue is a per-PRINCIPAL tube grant the admin does not hold either, so the view answers access-not-granted (tube-my-access-denied) instead of a queue. Seed e2e-tube:ROLE_TUBE,ROLE_USER:E2E_TUBE_PASSWORD in tests/e2e-extra-personas.sh, then delete this line"
    And I am signed in as the persona for this scenario
    When I open the path "/tube/my"
    Then the element with test id "tube-usage" is visible
    And the element with test id "tube-enqueue" is visible
    And the element with test id "tube-queue-empty" is visible

  @function:watch
  Scenario: a tube member watches a completed download in-platform @function:watch @service:tube @layer:ui
    Given this scenario is PENDING because "needs the same un-seeded ROLE_TUBE persona AND a COMPLETED job: playback is an HMAC-signed URL minted by GET /bff/tube/media/sign for a contentPath that only exists once a real download finished, and nothing in this suite can make one finish. This is also the one tube function whose gate sits on the BE gateway (/tube/content/** = ROLE_TUBE), not the fe gateway"
    And I am signed in as the persona for this scenario
    When I open the path "/tube/my"
    Then the element with test id "tube-watch-empty" is not visible

  @function:subscribe
  Scenario: a tube member connects a Google account and syncs subscriptions @function:subscribe @service:tube @layer:ui
    Given this scenario is PENDING because "this function leaves the mesh entirely — a real Google OAuth consent flow against accounts.google.com plus a YouTube Data API quota. There is no seeded credential and no stub, and driving a third-party consent screen from Playwright would be asserting Google, not hugmesh. Unlike tube/queue and tube/watch, seeding a ROLE_TUBE persona does NOT unblock this one"
    And I am signed in as the persona for this scenario
    When I open the path "/tube/my"
    Then the element with test id "tube-google" is visible
    And the element with test id "tube-google-connect" is visible
    And the element with test id "tube-google-sync" is visible
