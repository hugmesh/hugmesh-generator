# ISSUE hugmesh-generator#362 — "stack-seed echoes the e2e password; Studio
# persists it to <state>/logs at 0644". Two halves:
#   1. Makefile `stack-seed` prints the shared persona password to its OWN
#      stdout — measured on origin/main@9f4d6d30, Makefile:2006-2007:
#        @pw="$$(bash tests/stack/e2e-password.sh)"; echo "==> Seeded. … (e.g. e2e-admin / $$pw) — $$pw is also readable from .e2e-credentials …"
#      That half is reachable from a terminal and is what this file covers.
#   2. The Studio banks every make line into a run log written 0644 under
#      <state>/logs. Driving Bootstrapping / Add user / Restore needs a Studio
#      driver action tests/e2e/studio-driver.py does not have (it grabs pages;
#      it does not run verbs), so that half is NOT covered here and stays on
#      the issue's "human still to verify" list.
#
# THE PASSWORD IS NEVER READ BY RUNNING tests/stack/e2e-password.sh. Executing
# that script MINTS a new value when the file is absent and rotates every
# persona's password under everyone else's feet. Sourcing it only defines
# functions (asserted below), and the secrecy step reads the value through
# the suite's own resolver (specs/rbac-roles.ts sharedPassword: E2E_PASSWORD,
# else the run-state file) — a READ, never a script.
#
# The live scenario re-seeds a running stack. seed-e2e.sh is idempotent (it
# probes before it creates), but it is still a mutation of a shared stack, so
# it runs only when a person opts in with SNAP_STACK_MUTATE=1 and skips loudly
# otherwise:
#   SNAP_STACK_MUTATE=1 bash tests/e2e/run.sh --bdd --env docker --tags '@issue:generator-362'
@interface:cli @issue:generator-362
Feature: seeding the stack never prints the shared e2e persona password

  # Baseline, green today, and the contract everything else here rests on:
  # sourcing the helper defines its functions and prints NOTHING — no value,
  # no banner. `declare -F` is the only stdout the script may produce.
  Scenario: sourcing the password helper defines its functions and prints nothing
    When I run the shell script:
      """
      set -euo pipefail
      . tests/stack/e2e-password.sh
      declare -F e2e_password_ensure e2e_password_read
      """
    Then the command succeeded
    And every non-empty line of the command's stdout matches "^e2e_password_(ensure|read)$"

  # The offline half of the defect: `make -n` prints the recipe without running
  # it (the password helper is NOT executed under -n). Today the banner line
  # interpolates the value twice; after the fix it names WHERE the value is.
  @fixme
  Scenario: the seed recipe's banner names where the password lives instead of interpolating it
    When I run the shell command "make -n stack-seed"
    Then the command succeeded
    And the command output contains ".e2e-credentials"
    And the command output does not contain "/ $pw"
    And the command output does not contain "$pw is"

  # The live half: the real seed, its real stdout, against the resolved value.
  @env:docker @service:gateway @layer:casdoor @fixme
  Scenario: re-seeding the running stack names where the password lives and never its value
    Given this scenario mutates the "docker" lane and the operator opted in with "SNAP_STACK_MUTATE=1"
    When I run the shell command "make stack-seed" allowing 20 minutes
    Then the command succeeded
    And the command output contains ".e2e-credentials"
    And the command output does not contain the shared e2e persona password
