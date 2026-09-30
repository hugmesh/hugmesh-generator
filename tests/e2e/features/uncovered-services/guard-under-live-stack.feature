# tests/scripts/test-e2e-func-media-games.sh under a compose stack that happens
# to be UP — hugmesh/hugmesh-generator#562.
#
# THE COLLISION #562 DIAGNOSED: the guard's docstring promised it was "offline by
# construction", yet two independently-correct behaviours make that false the
# moment the operator's real hugmesh-local door answers: steps/dimensions.ts
# probes the door with a REAL GET (so @env:docker scenarios that used to skip
# start running), and specs/rbac-roles.ts sharedPassword() refuses to fall back
# to a guessable literal (so, with no E2E_PASSWORD and no run-state
# .e2e-credentials, the 60 promoted scenarios all die on the same throw). Sixty
# identical "no run-state credentials file was found" failures read exactly like
# a product regression.
#
# DECISION 64 (operator, 2026-09-18) = SEED: the guard self-seeds a run-local
# credential through tests/stack/e2e-password.sh's e2e_password_ensure(), pointed
# at its OWN scratch dir via E2E_CREDENTIALS_FILE — never the operator's real
# .e2e-credentials — sourced, not executed; and the false docstring is corrected.
# That is PR #573, OPEN on origin/main 9f4d6d30 as of 2026-09-23, so the two
# scenarios that assert the fixed contract are @fixme until it merges.
#
# WHY THE GUARD IS NOT RUN FROM INSIDE A SCENARIO: it regenerates .features-gen/
# in the tree it runs in and then runs the media/games lane through playwright
# ("NEVER call this while a test run is in flight — .features-gen is shared
# mutable state", its own words). A Gherkin scenario IS a test run in flight in
# that same tree. The assertions below therefore read the guard's source — its
# contract with the credential resolver and with the reader — the way
# games-functions.feature reads compose.local.yaml: a measurement, not a claim.
@service:gateway @layer:gateway @harness @interface:cli
Feature: the media/games offline guard survives a compose stack that happens to be up

  # The control that runs today and keeps this file generating: the guard is
  # present and parses. A guard that does not parse is a guard that never ran.
  @issue:generator-562
  Scenario: the media/games function guard is present and parses
    When I run the shell command "bash -n tests/scripts/test-e2e-func-media-games.sh"
    Then the command succeeded

  # Decision 64's mechanism: the guard resolves a credential the SAME way the
  # stack does (e2e_password_ensure), scoped to its own file, never the
  # operator's. Absent both, a live door turns every promoted scenario into the
  # credentials throw #562 reproduced.
  @issue:generator-562 @fixme
  Scenario: the guard self-seeds a run-local credential instead of throwing when the door answers
    When I run the shell command "grep -c 'e2e_password_ensure' tests/scripts/test-e2e-func-media-games.sh"
    Then the command succeeded
    When I run the shell command "grep -c 'E2E_CREDENTIALS_FILE' tests/scripts/test-e2e-func-media-games.sh"
    Then the command succeeded

  # The false claim goes, or becomes true. #562's own scope bullet: "the
  # docstring's 'offline by construction' claim needs to either become true or be
  # corrected to state the real precondition". With decision 64 it is corrected.
  @issue:generator-562 @fixme
  Scenario: the guard no longer claims to be offline by construction
    When I run the shell command "grep -c 'offline by construction' tests/scripts/test-e2e-func-media-games.sh"
    Then the command failed
    And the command exit code was 1
