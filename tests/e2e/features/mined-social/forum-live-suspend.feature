# The phpBB SUSPEND leg, live — hugmesh/hugmesh-forum-bff-api#1.
#
# WHAT THE ISSUE ASKS: wire PhpbbAdminClient.doSuspend() to a real phpBB admin
# call, flip `phpbb.enabled` + `external.forum.enabled` on in a staging profile,
# and exercise the live-phpBB path instead of documenting it as possible. The
# first part has landed (forum-bff-api origin/main 52a2866: doSuspend POSTs
# …/users/{sub}/ban when external.forum.enabled=true and short-circuits to
# BlockOutcome.STUBBED when false). The second has not: this repo's PHPBB=1
# compose profile arms `PHPBB_ENABLED: "true"` and pins
# `EXTERNAL_FORUM_ENABLED: "false"` on forum-bff, so every ban still answers
# 202 + external="stubbed". The CI automation of the smoke test is pipeline
# wiring, not a scenario.
#
# The forum features that already exist (forum-tier-stack.feature,
# forum/function-surface.feature) are OFFLINE route-contract checks. This is the
# first @service:phpbb @env:docker write against a live forum-bff, and it asserts
# the REAL outcome the issue asks for: a 200 whose state is `applied` and whose
# external outcome is not the stub. It is @fixme until a profile flips the flag;
# the offline posture pin below is what turns red on the day it does.
@service:phpbb @layer:bff
Feature: A real phpBB suspend call lands once the forum flags are on

  # The posture pin (runs today, with everything down). PHPBB=1 arms the phpBB
  # client and leaves the external suspend leg dark. When someone flips it, this
  # goes red — the prompt to drop @fixme from the live scenario below.
  @issue:forum-bff-api-1 @harness @interface:cli
  Scenario: the PHPBB=1 compose profile arms phpbb.enabled and leaves the external suspend leg dark
    When I run the shell command "grep -c 'PHPBB_ENABLED: \"true\"' tests/stack/compose.local.yaml"
    Then the command succeeded
    When I run the shell command "grep -c 'EXTERNAL_FORUM_ENABLED: \"false\"' tests/stack/compose.local.yaml"
    Then the command succeeded

  # The live leg. e2e-banned is the standing banned persona, so a phpBB ban on it
  # changes nothing another scenario expects; the lift restores the row either way.
  @issue:forum-bff-api-1 @fixme @env:docker @role:e2e-admin @service:phpbb @layer:bff
  Scenario: an admin's forum ban reaches the live phpBB extension as an applied outcome
    Given an API client signed in as the persona for this scenario
    When the admin bans the forum subject "e2e-banned" with the reason "bdd: forum-bff-api#1 live suspend"
    Then the forum ban reached phpBB as a real applied outcome
    When the admin lifts the forum ban on "e2e-banned"

  # The role wall in front of the same leg holds whatever the flags say: the
  # ban is ROLE_ADMIN at the controller and the fe gateway's /bff/forum/admin/**
  # row (forum-tier-stack.feature pins the row; this drives it).
  @issue:forum-bff-api-1 @env:docker @service:phpbb @layer:gateway
  Scenario Outline: <role> is refused the forum admin ban surface @role:<role> @service:phpbb @layer:gateway
    Given I hold an API session as the persona for this scenario
    When I request the governed path "/bff/forum/admin/users/e2e-banned/ban"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "/bff/forum/admin/users/e2e-banned/ban"

    Examples:
      | role      |
      | e2e-forum |
      | e2e-mod   |
      | e2e-user  |
